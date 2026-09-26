#!/bin/sh
# M3 HOSTING+REPOS+INSTALLER gate, pacman/Arch arm.
#
#   scripts/run_multi_distro_tests.sh m3_install_pacman arch
#
# The pacman equivalent of m3_install_apt / m3_install_dnf. It exists
# because pacman/arch support was implemented in repro-install.sh and
# repro-publish-repos.sh and had NO gate arm at all -- and untested
# shipped code is how this campaign's worst defects got in.
#
# Proves, with pacman's own messages and pacman's own exit codes:
#
#   P1  the installer FAILS CLOSED when no trust anchor digest is pinned
#   P2  the installer REJECTS a keyring whose digest does not match
#   P3  the installer installs reprobuild from the pacman repository
#   P4  a SECOND (and THIRD) installer run changes nothing (measured)
#   P5  publishing a newer release makes pacman OFFER it as an upgrade
#   P6  `pacman -Syu` MOVES the box to the newer release
#   P7  a tampered package is rejected THROUGH THE INSTALLER's own path
#       (the signed database's checksum chain)
#   P7b a package signed by an UNTRUSTED key is rejected (SigLevel Required)
#   P8  a tampered sync DATABASE is rejected (SigLevel DatabaseRequired)
#   P9  --uninstall leaves no pacman.conf block, no keyring, no package,
#       and no trust anchor in pacman's own keyring
#   P10 a tampered tarball is rejected through the installer's fallback
#
# with the control that makes P3 mean anything:
#
#   N0  the SAME genuine repository is REJECTED under a DIFFERENT trust
#       anchor. Without it, P3 would pass just as happily against a
#       pacman that never verified anything.
#
# ## The constant-length tamper, which is the whole of P7
#
# M2's pacman arm learned this the hard way and it is inherited here
# deliberately: APPENDING bytes to a package trips the SIGNED DATABASE's
# `size` field before the signature or the checksum is ever consulted.
# The rejection is real but it is the wrong rejection, and the first
# version of M2's arm passed for exactly that reason. So P7 mutates the
# package IN PLACE at CONSTANT LENGTH, and asserts the length is
# unchanged before believing anything pacman says. P8 does the same to
# the database, and additionally asserts the database's detached
# signature is byte-identical -- a missing .sig would be rejected too,
# and for a different reason.
#
# ## Why Arch's own repositories are excluded from our transactions
#
# `pacman -Syu` with [core] and [extra] enabled is a FULL SYSTEM UPGRADE
# of the box -- hundreds of megabytes, and not something a gate may do to
# a shared host. So P5-P9 run against a pacman.conf with the distro
# sections stripped: the same isolation the dnf arm gets from
# `--disablerepo='*' --enablerepo=reprobuild`, and for the same second
# reason: with Arch's mirrors in scope a flaky mirror produces the same
# non-zero exit as a rejected signature.
#
# P3 and P4 deliberately run with [core] and [extra] ENABLED, because
# that is the configuration a real user has and pacman resolving our
# package alongside them is part of the claim.
#
# ## The fixture payload, stated plainly
#
# As in the other two arms, the packaged `repro` is a SHELL SCRIPT that
# prints its version, not a compiled reprobuild. This arm therefore does
# NOT prove reprobuild builds or runs. What it does prove is that the
# version the INSTALLED PAYLOAD reports changes across the upgrade, so
# the upgrade replaced real installed bytes and not just a row in
# pacman's local database.

set -eu

REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
INSTALL_SH="$REPO_ROOT/scripts/install/repro-install.sh"
BUILD_PKGS="$REPO_ROOT/scripts/release/repro-build-packages.sh"
PUBLISH="$REPO_ROOT/scripts/release/repro-publish-repos.sh"

WORK="${REPRO_M3_WORK:-/tmp/m3-install-pacman}"
WWW="$WORK/www"
PORT="${REPRO_M3_PORT:-8734}"
BASE="http://127.0.0.1:$PORT"

V1='0.1.3'
V2='0.1.4'
PKG='reprobuild'
DB='reprobuild'
BIN='/usr/bin/repro'
KEYRING_DEST='/usr/share/keyrings/reprobuild-archive-keyring.gpg'
PACCONF='/etc/pacman.conf'
BEGIN_MARK='# >>> reprobuild installer >>>'
END_MARK='# <<< reprobuild installer <<<'

fails=0
checks=0
# The number of checks a COMPLETE run performs, asserted at the end: an
# arm that dies half way must never be able to print a short all-PASS
# summary. The Scoop arm printed "2 checks, 0 failure(s)" after aborting
# at step 3, and this is the guard that class of false green needs.
MIN_CHECKS=80

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { checks=$((checks + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }

# rc captured around a SIMPLE command, inside a script FILE. Never an
# inline `$?` read across a wsl.exe boundary: that prints 0 for a command
# that failed (confirmed twice in this campaign).
run_capture() {
  _out="$1"; shift
  set +e
  "$@" > "$_out" 2>&1
  _rc=$?
  set -e
  return $_rc
}

grep_count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# Counts, never truthiness: a grep that matches zero lines is a vacuous
# pass, so every pattern assertion compares a NUMBER.
assert_matches() {
  _file="$1"; _pat="$2"; _what="$3"
  _n="$(grep_count "$_file" "$_pat")"
  if [ "${_n:-0}" -ge 1 ]; then
    ok "$_what (matched $_n line(s) on '$_pat')"
  else
    bad "$_what: pattern '$_pat' matched 0 lines in $_file"
    printf 'vvv %s vvv\n' "$_file"; sed -n '1,60p' "$_file"; printf '^^^ end ^^^\n'
  fi
}
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3 (= $1)"; else bad "$3: expected '$2', got '$1'"; fi
}
assert_ne() {
  if [ "$1" != "$2" ]; then ok "$3 ('$1' != '$2')"; else bad "$3: both are '$1'"; fi
}
assert_file() {
  if [ -e "$1" ]; then ok "$2 exists: $1"; else bad "$2 missing: $1"; fi
}
assert_absent() {
  if [ ! -e "$1" ]; then ok "$2 is absent: $1"; else bad "$2 still present: $1"; fi
}

# ---------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------
[ -r /etc/os-release ] || { echo 'no /etc/os-release' >&2; exit 1; }
. /etc/os-release
case "${ID:-}" in
  arch|archarm|manjaro|endeavouros) ;;
  *) echo "m3_install_pacman: expected arch, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root' >&2; exit 1; }
for f in "$INSTALL_SH" "$BUILD_PKGS" "$PUBLISH" "$SIGN_DIR/make-test-key.sh"; do
  [ -f "$f" ] || { echo "missing required script: $f" >&2; exit 1; }
done
# These are PRECONDITIONS OF THE GATE, not things the installer provides:
# repo-add is the REPOSITORY GENERATOR's tool and lives on a release
# runner, python3 stands in for R2, and curl is a precondition of
# `curl ... | sh` itself. None of them is installed by the installer.
for t in pacman repo-add pacman-key gpg bsdtar zstd python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
MACHINE="$(uname -m)"
printf 'arch=%s  pacman=%s\n' "$MACHINE" "$(pacman --version 2>&1 | tr ' ' '\n' | grep -m1 '^v[0-9]')"
gpg --version | head -1

rm -rf "$WORK"
mkdir -p "$WORK" "$WWW"

# ---------------------------------------------------------------------
step 'pacman.conf handling: a pristine copy, and a distro-free variant'
# ---------------------------------------------------------------------
# Both are derived from the box's REAL pacman.conf, never written from
# scratch: a hand-written config would stop testing what the installer
# emits into the file a user actually has.
[ -f "$PACCONF" ] || { echo "$PACCONF not found" >&2; exit 1; }
CONF_FULL="$WORK/pacman.conf.full"
CONF_MIN="$WORK/pacman.conf.min"
cp "$PACCONF" "$CONF_FULL"
python3 - "$CONF_FULL" "$CONF_MIN" <<'PYCONF'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, drop = [], False
for line in open(src, 'r', encoding='utf-8', errors='replace'):
    s = line.strip()
    if s.startswith('[') and s.endswith(']'):
        drop = (s != '[options]')
    if drop:
        continue
    out.append(line)
open(dst, 'w', encoding='utf-8', newline='\n').writelines(out)
print('wrote a distro-free pacman.conf with %d lines' % len(out))
PYCONF
assert_eq "$(grep -c '^\[core\]' "$CONF_MIN" || true)" '0' 'the distro-free conf has no [core]'
assert_eq "$(grep -c '^\[extra\]' "$CONF_MIN" || true)" '0' 'the distro-free conf has no [extra]'
assert_eq "$(grep -c '^\[options\]' "$CONF_MIN" || true)" '1' 'the distro-free conf still has [options]'
assert_eq "$(grep -c '^\[core\]' "$CONF_FULL" || true)" '1' 'the full conf does have [core] (so P3 runs like a real box)'

# Our fenced block, captured from what the INSTALLER wrote, so swapping
# the base config never invents installer output.
BLOCK="$WORK/reprobuild.block"
: > "$BLOCK"
capture_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { f = 1 }
    f == 1  { print }
    $0 == e { f = 0 }
  ' "$PACCONF" > "$BLOCK"
}
# set_conf <base>: install <base> as /etc/pacman.conf and re-append the
# captured installer block, if there is one.
set_conf() {
  cp "$1" "$PACCONF"
  if [ -s "$BLOCK" ]; then cat "$BLOCK" >> "$PACCONF"; fi
}

cleanup() {
  set +e
  [ -z "${HTTP_PID:-}" ] || kill "$HTTP_PID" 2>/dev/null
  pacman -Rns --noconfirm "$PKG" >/dev/null 2>&1
  [ -f "$CONF_FULL" ] && cp "$CONF_FULL" "$PACCONF"
  rm -f /usr/share/keyrings/*reprobuild*
  rm -rf /var/lib/reprobuild
  rm -f /var/lib/pacman/sync/"$DB".db /var/lib/pacman/sync/"$DB".db.sig \
        /var/lib/pacman/sync/"$DB".files /var/lib/pacman/sync/"$DB".files.sig
  rm -f /var/cache/pacman/pkg/"$PKG"-*
  [ -z "${GOOD_FPR:-}" ] || pacman-key --delete "$GOOD_FPR" >/dev/null 2>&1
  [ -z "${ADV_FPR:-}" ]  || pacman-key --delete "$ADV_FPR"  >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

installed_version() { pacman -Q "$PKG" 2>/dev/null | awk '{print $2}' || true; }
payload_version()   { if [ -x "$BIN" ]; then "$BIN" --version 2>/dev/null || true; fi; }
block_count()       { grep -c "^\[$DB\]" "$PACCONF" || true; }
pac_reset() {
  rm -f /var/lib/pacman/sync/"$DB".db /var/lib/pacman/sync/"$DB".db.sig \
        /var/lib/pacman/sync/"$DB".files /var/lib/pacman/sync/"$DB".files.sig
  rm -f /var/cache/pacman/pkg/"$PKG"-*
}

# ---------------------------------------------------------------------
step 'hermetic reset: remove any reprobuild state from a previous run'
# ---------------------------------------------------------------------
# Load-bearing, not tidiness: P1 and P2 assert that a REFUSED install
# left nothing behind, and a keyring surviving from a previous run would
# make them fail -- or, written differently, PASS while measuring the
# previous run's leftovers. So the clearing is itself ASSERTED.
pacman -Rns --noconfirm "$PKG" >/dev/null 2>&1 || true
rm -f /usr/share/keyrings/*reprobuild*
rm -rf /var/lib/reprobuild
python3 - "$PACCONF" "$BEGIN_MARK" "$END_MARK" <<'PYSTRIP'
import sys
p, b, e = sys.argv[1], sys.argv[2], sys.argv[3]
out, skip = [], False
for line in open(p, 'r', encoding='utf-8', errors='replace'):
    if line.rstrip('\n') == b:
        skip = True
    if not skip:
        out.append(line)
    if line.rstrip('\n') == e:
        skip = False
open(p, 'w', encoding='utf-8', newline='\n').writelines(out)
PYSTRIP
# Re-derive both bases from the now-clean file, so CONF_FULL never
# carries a previous run's block back in.
cp "$PACCONF" "$CONF_FULL"
python3 - "$CONF_FULL" "$CONF_MIN" <<'PYCONF2'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, drop = [], False
for line in open(src, 'r', encoding='utf-8', errors='replace'):
    s = line.strip()
    if s.startswith('[') and s.endswith(']'):
        drop = (s != '[options]')
    if drop:
        continue
    out.append(line)
open(dst, 'w', encoding='utf-8', newline='\n').writelines(out)
PYCONF2
pac_reset
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' 2>/dev/null | wc -l | tr -d ' ')" '0' \
  'reset: no reprobuild keyring on the box before the arm starts'
assert_eq "$(block_count)" '0' 'reset: no [reprobuild] block in pacman.conf before the arm starts'
assert_eq "$(installed_version)" '' 'reset: reprobuild is not installed before the arm starts'

# ---------------------------------------------------------------------
step 'throwaway signing key + an adversary key (M2 make-test-key.sh)'
# ---------------------------------------------------------------------
GOOD_HOME="$WORK/gnupg-good"
ADV_HOME="$WORK/gnupg-adversary"
GOOD_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$GOOD_HOME")"
ADV_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$ADV_HOME")"
[ -n "$GOOD_FPR" ] || { echo 'no signing key' >&2; exit 1; }
[ -n "$ADV_FPR" ]  || { echo 'no adversary key' >&2; exit 1; }
assert_ne "$GOOD_FPR" "$ADV_FPR" 'the two throwaway keys are distinct'
echo "signing key:   $GOOD_FPR"
echo "adversary key: $ADV_FPR"
# pacman-key must be initialised before --add works. The box's keyring is
# already populated, so --init is a no-op there; it is here so the arm
# does not silently depend on that.
pacman-key --init >/dev/null 2>&1 || true
pacman-key --delete "$GOOD_FPR" >/dev/null 2>&1 || true
pacman-key --delete "$ADV_FPR" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------
step 'build two fixture release tarballs (the release.yml asset shape)'
# ---------------------------------------------------------------------
make_tarball() {
  _v="$1"
  _top="reprobuild-$_v-linux-$MACHINE"
  _d="$WORK/tarballs/$_top"
  rm -rf "$_d"
  mkdir -p "$_d/bin" "$_d/lib"
  # The payload reports its OWN version, so the upgrade can be asserted
  # against INSTALLED BYTES and not only against pacman's database.
  # Shaped like the release launcher: what it runs lives at
  # "$(dirname "$0")/../lib". The version comes from there, so a package
  # that installs bin/ and lib/ apart installs a command that cannot start,
  # and the upgrade assertions on installed bytes fail instead of passing.
  cat > "$_d/bin/repro" <<'PAYLOAD'
#!/bin/sh
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
lib="$here/../lib/libreprofixture.so"
[ -f "$lib" ] || { echo "repro: missing $lib" >&2; exit 127; }
v=$(sed -n 's/^version //p' "$lib")
case "${1:-}" in
  --version|-V) printf 'reprobuild %s\n' "$v" ;;
  *) printf 'reprobuild %s (M3 gate fixture payload)\n' "$v" ;;
esac
PAYLOAD
  chmod 0755 "$_d/bin/repro"
  printf 'version %s\n' "$_v" > "$_d/lib/libreprofixture.so"
  ( cd "$WORK/tarballs" && tar -czf "$_top.tar.gz" "$_top" )
  echo "$WORK/tarballs/$_top.tar.gz"
}
mkdir -p "$WORK/tarballs"
TB1="$(make_tarball "$V1")"
TB2="$(make_tarball "$V2")"
assert_file "$TB1" "fixture tarball $V1"
assert_file "$TB2" "fixture tarball $V2"

# ---------------------------------------------------------------------
step "build the $V1 .pkg.tar.zst via scripts/release/repro-build-packages.sh"
# ---------------------------------------------------------------------
mkdir -p "$WORK/pkgs-v1" "$WORK/pkgs-v2"
run_capture "$WORK/build-v1.log" sh "$BUILD_PKGS" \
  --version "$V1" --tarball "$TB1" --out "$WORK/pkgs-v1" --ecosystem arch \
  --asset-arch "$MACHINE" \
  || { echo 'repro-build-packages.sh failed for v1:'; cat "$WORK/build-v1.log"; exit 1; }
PKG1="$WORK/pkgs-v1/reprobuild-$V1-1-$MACHINE.pkg.tar.zst"
assert_file "$PKG1" "generated $V1 pacman package"

# ---------------------------------------------------------------------
step "publish $V1 to the local repo root via repro-publish-repos.sh"
# ---------------------------------------------------------------------
# --target local:$WWW is the SAME code path production uses with
# --target r2:<bucket>; only the scheme differs.
KEYRING_PUB="$WORK/reprobuild-archive-keyring.gpg"
run_capture "$WORK/publish-v1.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V1" --packages "$WORK/pkgs-v1" --key "$GOOD_FPR" \
      --ecosystem arch --repo-root "$WORK/repo" --target "local:$WWW" \
      --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v1 failed:'; cat "$WORK/publish-v1.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v1.log"
assert_file "$WWW/arch/$DB.db"                                    'published sync database'
assert_file "$WWW/arch/$DB.db.sig"                                'published sync database SIGNATURE'
assert_file "$WWW/arch/reprobuild-$V1-1-$MACHINE.pkg.tar.zst"     'published package'
assert_file "$WWW/arch/reprobuild-$V1-1-$MACHINE.pkg.tar.zst.sig" 'published package SIGNATURE'
assert_file "$WWW/keys/reprobuild-archive-keyring.gpg"            'published trust anchor'
assert_matches "$WORK/publish-v1.log" 'TRUST ANCHOR sha256' 'publish printed the anchor digest'

ANCHOR_SHA="$(cat "$WWW/keys/reprobuild-archive-keyring.gpg.sha256")"
[ -n "$ANCHOR_SHA" ] || { echo 'no anchor digest published' >&2; exit 1; }
echo "anchor sha256 = $ANCHOR_SHA"

# ---------------------------------------------------------------------
step 'serve the repo root over local HTTP (stands in for R2)'
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# N51 -- THE SERVER THIS STEP ASSERTS MUST BE THE SERVER THIS STEP STARTED.
#
# Observed on the dnf arm: a stale `python3 -m http.server` left over from
# an EARLIER run still held $PORT. This run's own server died immediately
# with `[Errno 98] Address already in use`, and the probe -- which asked
# only whether the URL answered -- printed PASS. Every later step then ran
# against the orphan, and the whole arm collapsed when the orphan exited.
# The probe measured the URL. It never measured its own process.
#
# This arm shares the shape and is fixed with it: it was never
# measured failing, but it is the same probe and the same fixed $WORK path.
#
# Why the obvious remedy does NOT work here, stated so it is not tried
# again: $WORK is a FIXED path, this script `rm -rf`s and recreates it, and
# python's http.server resolves its document root as a STRING on every
# request. A stale server from a previous run therefore serves THIS run's
# files -- including any nonce dropped into the tree. "Put a unique token in
# the served tree and fetch it back" is vacuous against the failure that was
# actually observed, because the orphan serves the token too.
#
# What is asserted instead:
#   (1) the port is FREE before we bind. A pre-bound port is REFUSED, never
#       adopted. This alone is fatal to the observed failure.
#   (2) the process WE started is alive after the readiness poll, with
#       `kill -0`'s zombie hole closed (see `http_server_alive`).
#   (3) the port answers.
# A listening TCP socket is exclusive, so (1)+(2)+(3) together identify the
# answering server as ours. Where `ss(8)` exists the listener's pid is ALSO
# compared to ours directly, which is the same claim without the inference.
# ---------------------------------------------------------------------
port_is_bound() {
  # Deliberately the same python3 that is about to serve: "no python3 on
  # this host" therefore cannot make this quietly answer "the port is free".
  python3 - "$PORT" <<'N51_PORT_PY'
import socket, sys
s = socket.socket()
s.settimeout(2)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)          # nothing is listening
finally:
    s.close()
sys.exit(0)              # something is listening
N51_PORT_PY
}

http_server_alive() {
  [ -n "${HTTP_PID:-}" ] || return 1
  kill -0 "$HTTP_PID" 2>/dev/null || return 1
  # `kill -0` SUCCEEDS on a zombie, and a background child that exited but
  # has not been waited for IS a zombie -- so `kill -0` on its own passes
  # for exactly the failure this function exists to catch (a server that
  # died instantly of EADDRINUSE). Reject state Z explicitly.
  if [ -r "/proc/$HTTP_PID/stat" ]; then
    # `|| true`: the process can exit between the `-r` test and this read,
    # and under `set -e` a failed command substitution inside an assignment
    # aborts the whole arm. An unreadable stat means "not a zombie we can
    # see", which the `kill -0` above has already ruled on.
    _n51_state="$(sed -n 's/.*) \([A-Za-z]\) .*/\1/p' "/proc/$HTTP_PID/stat" || true)"
    [ "$_n51_state" != "Z" ] || return 1
  fi
  return 0
}

port_listener_pid() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltnp "sport = :$PORT" 2>/dev/null |
    sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
}

if port_is_bound; then
  printf 'FATAL: %s is already bound BEFORE this run started its own server.\n' "$BASE" >&2
  printf '       Refusing to adopt it. A previous run left an orphan there, and\n' >&2
  printf '       every check below would have measured the orphan instead of\n' >&2
  printf '       anything this run published.\n' >&2
  if command -v ss >/dev/null 2>&1; then ss -ltnp "sport = :$PORT" >&2 || true; fi
  exit 1
fi
ok "port $PORT was FREE before this run bound it (no orphan server adopted)"

( cd "$WWW" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) \
  >"$WORK/http.log" 2>&1 &
HTTP_PID=$!
i=0
while [ "$i" -lt 50 ]; do
  http_server_alive || break
  if curl -fsS -o /dev/null "$BASE/arch/$DB.db" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 0.2
done
if ! http_server_alive; then
  bad "the HTTP server THIS run started (pid ${HTTP_PID:-none}) is not running"
  cat "$WORK/http.log"
elif run_capture "$WORK/http-probe.log" curl -fsS -o /dev/null "$BASE/arch/$DB.db"; then
  ok "local HTTP server (pid $HTTP_PID, started by THIS run) serves $DB.db over $BASE"
else
  bad "local HTTP server did not serve $BASE/arch/$DB.db"
  cat "$WORK/http.log"
fi
N51_LISTENER="$(port_listener_pid)"
if [ -n "$N51_LISTENER" ]; then
  if [ "$N51_LISTENER" = "${HTTP_PID:-}" ]; then
    ok "port $PORT is held by OUR server (ss reports pid $N51_LISTENER, = \$HTTP_PID)"
  else
    bad "port $PORT is held by pid $N51_LISTENER, NOT the server this run started (pid ${HTTP_PID:-none})"
  fi
else
  printf 'note: no ss(8) on this host; port ownership rests on the pre-bind\n'
  printf '      refusal plus pid liveness asserted above, not on a direct read.\n'
fi
# The .db and .db.sig are SYMLINKS to the .tar.gz pair in the generated
# tree, and pacman fetches the symlink names. If publishing to the hosting
# target had dropped or flattened them, pacman would 404 and every
# rejection step below would "pass" for the wrong reason.
if run_capture "$WORK/http-probe-sig.log" curl -fsS -o /dev/null "$BASE/arch/$DB.db.sig"; then
  ok "local HTTP server serves $DB.db.sig (the symlinked signature survived publishing)"
else
  bad "local HTTP server did not serve $BASE/arch/$DB.db.sig"
fi

# =====================================================================
step 'P1  installer FAILS CLOSED with no pinned trust anchor digest'
# =====================================================================
# VACUITY: any failure at all exits non-zero, so the SPECIFIC fail-closed
# diagnostic is matched AND the absence of the registration is asserted.
set_conf "$CONF_MIN"
pac_reset
set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method pacman >"$WORK/p1.log" 2>&1
P1_RC=$?
set -e
assert_ne "$P1_RC" '0' 'P1 installer exited non-zero with no digest pinned'
assert_matches "$WORK/p1.log" 'no trust anchor digest is pinned' 'P1 refused for the fail-closed reason'
assert_eq "$(block_count)" '0' 'P1 registered no pacman repository'
assert_absent "$KEYRING_DEST" 'P1 installed no keyring'

# =====================================================================
step 'P2  installer REJECTS a trust anchor whose digest != the pin'
# =====================================================================
# VACUITY: a wrong-but-nonempty digest could also fail by 404 or by an
# empty download, so the digest is a VALID sha256 of DIFFERENT bytes, the
# URL is the one that works, and the mismatch message specifically is
# what is matched.
WRONG_SHA="$(printf 'not the anchor' | sha256sum | awk '{print $1}')"
assert_ne "$WRONG_SHA" "$ANCHOR_SHA" 'P2 the wrong digest differs from the real one'
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$WRONG_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p2.log" 2>&1
P2_RC=$?
set -e
assert_ne "$P2_RC" '0' 'P2 installer exited non-zero on digest mismatch'
assert_matches "$WORK/p2.log" 'trust anchor digest MISMATCH' 'P2 refused for the digest-mismatch reason'
assert_eq "$(block_count)" '0' 'P2 registered no pacman repository'
assert_absent "$KEYRING_DEST" 'P2 installed no keyring'

# =====================================================================
step 'N0  CONTROL: the genuine repo under the ADVERSARY anchor is REJECTED'
# =====================================================================
# Byte-for-byte the repository P3 installs from; only the trust anchor
# differs. If pacman were not verifying, this would install exactly as P3
# does, and P3 would prove nothing.
GNUPGHOME="$ADV_HOME" gpg --batch --armor --export "$ADV_FPR" > "$WORK/adversary-keyring.gpg"
[ -s "$WORK/adversary-keyring.gpg" ] || { echo 'adversary keyring empty' >&2; exit 1; }
ADV_SHA="$(sha256sum "$WORK/adversary-keyring.gpg" | awk '{print $1}')"
set_conf "$CONF_MIN"
pac_reset
set +e
env REPRO_BASE_URL="$BASE" \
    REPRO_KEYRING_LOCAL="$WORK/adversary-keyring.gpg" \
    REPRO_KEYRING_SHA256="$ADV_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/n0.log" 2>&1
N0_RC=$?
set -e
sed -n '1,40p' "$WORK/n0.log"
assert_ne "$N0_RC" '0' 'N0 installer exited non-zero under the adversary anchor'
assert_matches "$WORK/n0.log" \
  'invalid or corrupted database\|signature from\|unknown trust\|is not trusted\|marginal trust\|key .* is unknown\|could not be verified' \
  'N0 pacman named the trust failure on the signed database'
assert_eq "$(installed_version)" '' 'N0 left reprobuild uninstalled'
# The discriminator. If the installer had merely failed to ADD the key to
# pacman's keyring, pacman would never have evaluated the repository and
# this control would be vacuous -- the exact shape of the dnf arm's N0
# false green, where `rpm --import` refused a binary keyring and nothing
# about trust was ever tested.
N0_KEYERR="$(grep_count "$WORK/n0.log" 'pacman-key --add .* failed\|pacman-key --lsign-key .* failed\|no OpenPGP key found')"
assert_eq "${N0_KEYERR:-0}" '0' \
  'N0 the rejection was NOT a keyring-import failure (so pacman really evaluated the repo)'
pacman-key --delete "$ADV_FPR" >/dev/null 2>&1 || true
rm -f "$KEYRING_DEST"
pac_reset

# =====================================================================
step "P3  installer installs reprobuild $V1 from the pacman repository"
# =====================================================================
# [core] and [extra] are ENABLED here: this is the configuration a real
# user has, and pacman resolving our package alongside them is part of
# the claim.
set_conf "$CONF_FULL"
pac_reset
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p3.log" 2>&1
P3_RC=$?
set -e
sed -n '1,60p' "$WORK/p3.log"
assert_eq "$P3_RC" '0' 'P3 installer exited 0'
assert_matches "$WORK/p3.log" 'trust anchor digest OK' 'P3 the pinned digest matched'
# pacman's OWN output, not a script asserting success.
assert_matches "$WORK/p3.log" "installing $PKG\|$PKG-$V1-1" 'P3 pacman reported installing the package'
assert_file "$KEYRING_DEST" 'P3 trust anchor installed'
assert_file "$BIN"          'P3 the payload binary landed'
assert_eq "$(installed_version)" "$V1-1" "P3 pacman reports $V1-1 installed"
assert_eq "$(payload_version)" "reprobuild $V1" "P3 the INSTALLED PAYLOAD reports $V1"
capture_block
assert_eq "$(block_count)" '1' 'P3 exactly ONE [reprobuild] section in pacman.conf'
# The strict SigLevel is the whole point: Arch's default DatabaseOptional
# leaves the sync database unverified, which is one MITM away from a
# silent downgrade. P8 below is what proves this line does something.
assert_matches "$PACCONF" '^SigLevel = Required DatabaseRequired' \
  'P3 the emitted stanza asks for Required DatabaseRequired'
assert_matches "$PACCONF" "^Server = $BASE/arch" \
  'P3 the emitted stanza points at the configured base URL (REPRO_BASE_URL, no hardcoded host)'
# The anchor must be LOCALLY SIGNED, or pacman does not trust it for
# package verification however present it is in the keyring.
run_capture "$WORK/p3-key.log" pacman-key --list-sigs "$GOOD_FPR" || true
assert_matches "$WORK/p3-key.log" 'Pacman Keyring Master Key\|^sig' \
  "P3 the trust anchor was locally signed into pacman's keyring"

# =====================================================================
step 'P4  IDEMPOTENCE: a second (and third) run changes nothing (measured)'
# =====================================================================
# Measured, not asserted. Six independent observations before and after.
# VACUITY: a second run that simply crashed would also change nothing, so
# its exit code is asserted to be 0.
before_conf_sha="$(sha256sum "$PACCONF" | awk '{print $1}')"
before_keyring_sha="$(sha256sum "$KEYRING_DEST" | awk '{print $1}')"
before_version="$(installed_version)"
before_blocks="$(block_count)"
before_keyrings="$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
before_servers="$(grep -c "^Server = $BASE/arch" "$PACCONF" || true)"

set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p4.log" 2>&1
P4_RC=$?
set -e
assert_eq "$P4_RC" '0' 'P4 second installer run exited 0 (so "no change" is not "it crashed")'
assert_eq "$(block_count)" "$before_blocks" 'P4 [reprobuild] section count unchanged'
assert_eq "$(block_count)" '1'              'P4 exactly ONE [reprobuild] section (no duplicated database)'
assert_eq "$(grep -c "^Server = $BASE/arch" "$PACCONF" || true)" "$before_servers" \
  'P4 Server line count unchanged'
assert_eq "$(grep -c "^Server = $BASE/arch" "$PACCONF" || true)" '1' 'P4 exactly ONE Server line'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')" \
          "$before_keyrings" 'P4 keyring file count unchanged'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')" \
          '1' 'P4 exactly ONE reprobuild keyring'
assert_eq "$(sha256sum "$PACCONF" | awk '{print $1}')" "$before_conf_sha" 'P4 pacman.conf byte-identical'
assert_eq "$(sha256sum "$KEYRING_DEST" | awk '{print $1}')" "$before_keyring_sha" 'P4 keyring byte-identical'
assert_eq "$(installed_version)" "$before_version" 'P4 installed version unchanged'
# pacman's own judgement that the state already matches, which a script
# cannot fake.
assert_matches "$WORK/p4.log" 'is up to date -- reinstalling\|there is nothing to do\|up to date' \
  'P4 pacman itself reported there was nothing new to do'
# A THIRD run, because pacman.conf is the one APPEND-structured config
# here: the marker block is stripped before being re-appended, and
# appending without the strip is how a third run earns pacman's
# "duplicated database" error.
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p4c.log" 2>&1
P4C_RC=$?
set -e
assert_eq "$P4C_RC" '0' 'P4 a THIRD installer run also exited 0'
assert_eq "$(block_count)" '1' 'P4 still exactly ONE [reprobuild] section after three runs'
assert_eq "$(grep_count "$WORK/p4c.log" 'duplicated database')" '0' \
  'P4 pacman never complained about a duplicated database'
capture_block

# =====================================================================
step "P5  publish $V2 ADDITIVELY; pacman then OFFERS it as an upgrade"
# =====================================================================
run_capture "$WORK/build-v2.log" sh "$BUILD_PKGS" \
  --version "$V2" --tarball "$TB2" --out "$WORK/pkgs-v2" --ecosystem arch \
  --asset-arch "$MACHINE" \
  || { echo 'build v2 failed:'; cat "$WORK/build-v2.log"; exit 1; }
PKG2="$WORK/pkgs-v2/reprobuild-$V2-1-$MACHINE.pkg.tar.zst"
assert_file "$PKG2" "generated $V2 pacman package"

# --fetch-existing pulls the CURRENT published tree down first, so $V1
# survives. A publish that replaced the tree would make one upgrade work
# and break every pinned install.
run_capture "$WORK/publish-v2.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V2" --packages "$WORK/pkgs-v2" --key "$GOOD_FPR" \
      --ecosystem arch --repo-root "$WORK/repo2" --target "local:$WWW" \
      --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v2 failed:'; cat "$WORK/publish-v2.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v2.log"
POOL_PKGS="$(find "$WWW/arch" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l | tr -d ' ')"
assert_eq "$POOL_PKGS" '2' 'P5 the published repository still carries the OLD package file too'
# ... and the SIGNED DATABASE lists the new one. Files on disk that the
# database does not mention are not an upgrade.
#
# A pacman sync database holds exactly ONE entry per package NAME -- that
# is pacman's model, not a bug and not something --fetch-existing could
# change; Arch's own [core] carries only the newest build of each package.
# So the additive property being asserted here is the one that actually
# exists for pacman: the OLD package FILE survives the publish (so a
# pinned `pacman -U <url>` still resolves), while the database moves
# forward. The measurement below is a count compared to a number, so a
# database that somehow listed both, or neither, fails.
run_capture "$WORK/p5-db.log" bsdtar -tf "$WWW/arch/$DB.db.tar.gz" || true
assert_matches "$WORK/p5-db.log" "reprobuild-$V2-1/" "P5 the signed database lists $V2-1"
assert_eq "$(grep_count "$WORK/p5-db.log" "^reprobuild-[0-9].*/$")" '1' \
  'P5 the signed database holds exactly ONE entry for the package (pacman is single-version)'
if run_capture "$WORK/p5-old.log" curl -fsS -o /dev/null \
     "$BASE/arch/reprobuild-$V1-1-$MACHINE.pkg.tar.zst"; then
  ok "P5 the OLD $V1-1 package file is still served (a pinned install still resolves)"
else
  bad "P5 the OLD $V1-1 package file is no longer served: the publish was destructive"
fi

# The BEFORE picture, from pacman's own mouth. Arch's own repositories go
# out of scope from here on: see the header.
set_conf "$CONF_MIN"
pac_reset
run_capture "$WORK/p5-sy.log" pacman -Sy --noconfirm \
  || { echo 'pacman -Sy failed after publishing v2:'; cat "$WORK/p5-sy.log"; }
assert_matches "$WORK/p5-sy.log" "$DB" 'P5 pacman synced our database'
run_capture "$WORK/p5-qu.log" pacman -Qu || true
cat "$WORK/p5-qu.log"
assert_matches "$WORK/p5-qu.log" "^$PKG $V1-1 -> $V2-1" \
  "P5 pacman -Qu reports the transition $V1-1 -> $V2-1 in its own words"

# =====================================================================
step "P6  pacman -Syu MOVES the box from $V1 to $V2"
# =====================================================================
# VACUITY, the important one: this must be a TRANSITION, not a first
# install. $V1-1 is asserted installed immediately before, the upgrade is
# PACMAN's own command with NO installer involvement, and $V2-1 is
# asserted after in BOTH pacman's database AND the installed payload, so
# a metadata-only change cannot satisfy it.
assert_eq "$(installed_version)" "$V1-1" "P6 precondition: $V1-1 installed before the upgrade"
assert_eq "$(payload_version)" "reprobuild $V1" "P6 precondition: payload reports $V1 before the upgrade"
set +e
pacman -Syu --noconfirm >"$WORK/p6.log" 2>&1
P6_RC=$?
set -e
sed -n '1,60p' "$WORK/p6.log"
assert_eq "$P6_RC" '0' 'P6 pacman -Syu exited 0'
assert_matches "$WORK/p6.log" "$PKG-$V1-1 -> $V2-1\|upgrading $PKG" \
  'P6 pacman named the upgrade transaction in its own words'
assert_eq "$(installed_version)" "$V2-1" "P6 pacman now reports $V2-1"
assert_eq "$(payload_version)" "reprobuild $V2" "P6 the INSTALLED PAYLOAD now reports $V2"
run_capture "$WORK/p6-qu.log" pacman -Qu || true
assert_eq "$(grep_count "$WORK/p6-qu.log" "^$PKG ")" '0' 'P6 nothing is left to upgrade'

# =====================================================================
step 'P7  a TAMPERED package is rejected by the SIGNED-DATABASE checksum'
# =====================================================================
# The installer is what invokes pacman, so the rejection is demonstrated
# through the installer rather than by a hand-written pacman command: if
# the installer could be made to install unverified bytes, that is a
# defect no matter what pacman does on its own.
#
# What this step proves, stated precisely: replacing a package on the
# mirror is caught by the sha256 recorded in the sync DATABASE, which is
# itself covered by the database signature. So it is a real rejection
# rooted in a signature -- but it is NOT a test of the package's own
# `.sig`, because pacman discards the download before it gets that far.
# P7b below isolates the package signature, and the two are kept apart
# because conflating them is how a check that never runs looks green
# (the dnf arm's R7/R7b, for the same reason).
ARCH_PRISTINE="$WORK/arch-pristine"
rm -rf "$ARCH_PRISTINE"
cp -a "$WWW/arch" "$ARCH_PRISTINE"
restore_arch_repo() { rm -rf "$WWW/arch"; cp -a "$ARCH_PRISTINE" "$WWW/arch"; }
TARGET_PKG="$WWW/arch/reprobuild-$V2-1-$MACHINE.pkg.tar.zst"
assert_file "$TARGET_PKG" 'P7 found the published package to tamper'
cp "$TARGET_PKG" "$WORK/pristine-v2.pkg.tar.zst"
SIZE_BEFORE="$(wc -c < "$TARGET_PKG" | tr -d ' ')"
# IN PLACE, SAME LENGTH. M2's pacman arm learned this: appending six
# bytes tripped the signed database's `size` field before the signature
# was ever consulted, and the step passed for a reason it never claimed.
python3 - "$TARGET_PKG" <<'PYTAMPER'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2)
    n = f.tell()
    off = n // 2
    f.seek(off)
    orig = f.read(8)
    f.seek(off)
    f.write(bytes(b ^ 0xFF for b in orig))
print('flipped 8 bytes at offset %d of %d' % (off, n))
PYTAMPER
SIZE_AFTER="$(wc -c < "$TARGET_PKG" | tr -d ' ')"
assert_eq "$SIZE_AFTER" "$SIZE_BEFORE" \
  "P7 the tampered package has the SAME byte size (so the database's size field cannot be what fires)"
assert_ne "$(sha256sum "$TARGET_PKG" | awk '{print $1}')" \
          "$(sha256sum "$WORK/pristine-v2.pkg.tar.zst" | awk '{print $1}')" \
          'P7 the tampered package does differ in content'

# The package must be RE-FETCHED, not taken from pacman's cache: a cached
# good copy would make this step "pass" while installing untouched bytes,
# which is exactly how the Scoop arm's S5 was wrong.
pacman -Rns --noconfirm "$PKG" >/dev/null 2>&1 || true
pac_reset
assert_eq "$(find /var/cache/pacman/pkg -name "$PKG-*" 2>/dev/null | wc -l | tr -d ' ')" '0' \
  "P7 pacman's package cache holds no reprobuild (so the tampered bytes are the ones fetched)"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p7.log" 2>&1
P7_RC=$?
set -e
sed -n '1,40p' "$WORK/p7.log"
assert_ne "$P7_RC" '0' 'P7 the installer exited non-zero on the tampered package'
# NOT 'failed to commit transaction': that generic line is also what
# pacman prints when the SIZE field fires, so matching it would let the
# appended-bytes false green straight back in. The specific integrity
# wording is required instead...
assert_matches "$WORK/p7.log" 'invalid or corrupted package' \
  'P7 pacman named the package integrity failure specifically'
# ...and the size path is explicitly excluded. With six bytes appended
# instead of flipped in place, pacman says "Maximum file size exceeded"
# and never looks at a hash; this discriminator is what tells the two
# apart.
assert_eq "$(grep_count "$WORK/p7.log" 'Maximum file size exceeded\|size mismatch')" '0' \
  "P7 pacman did NOT reject on the database's SIZE field (so a hash, not a length, is what fired)"
assert_eq "$(installed_version)" '' 'P7 nothing was installed from the tampered package'
assert_absent "$BIN" 'P7 the payload binary'
restore_arch_repo
pac_reset

# =====================================================================
step 'P7b a package signed by an UNTRUSTED key is rejected (SigLevel Required)'
# =====================================================================
# THIS is the test of the package's own signature. The package bytes are
# the genuine ones, its detached `.sig` is regenerated with the ADVERSARY
# key, and the database is then regenerated and re-signed with the GOOD
# key -- so the recorded size and sha256 MATCH and DatabaseRequired
# passes. Every check except the package signature is satisfied, and a
# rejection can therefore only come from `SigLevel = Required`.
#
# The database is rebuilt with repo-add directly rather than with
# repro-sign-pacman-repo.sh, because that script also re-signs every
# PACKAGE with the good key and would put back exactly the signature this
# step replaces -- turning it into a test of nothing.
rm -f "$TARGET_PKG.sig"
GNUPGHOME="$ADV_HOME" gpg --batch --no-tty --yes --pinentry-mode loopback \
  --local-user "$ADV_FPR" --detach-sign --no-armor --output "$TARGET_PKG.sig" "$TARGET_PKG"
assert_file "$TARGET_PKG.sig" 'P7b the package carries an adversary-made signature'
# pacman rejects an ARMOURED .sig as malformed, which would look exactly
# like a successful detection. Assert it is a raw packet.
assert_eq "$(head -c 5 "$TARGET_PKG.sig" | grep -c -- '-----' || true)" '0' \
  'P7b the adversary signature is a RAW OpenPGP packet, not armour (or pacman would reject its FORM)'
( cd "$WWW/arch" && rm -f "$DB".db* "$DB".files* \
  && GNUPGHOME="$GOOD_HOME" repo-add --sign --key "$GOOD_FPR" "$DB.db.tar.gz" \
       reprobuild-*.pkg.tar.zst ) >"$WORK/p7b-repoadd.log" 2>&1 \
  || { echo 'p7b repo-add failed:'; cat "$WORK/p7b-repoadd.log"; }
( cd "$WWW/arch" \
  && ln -sf "$DB.db.tar.gz" "$DB.db" \
  && ln -sf "$DB.db.tar.gz.sig" "$DB.db.sig" \
  && ln -sf "$DB.files.tar.gz" "$DB.files" \
  && ln -sf "$DB.files.tar.gz.sig" "$DB.files.sig" )
assert_file "$WWW/arch/$DB.db.sig" 'P7b the database is signed again with the GOOD key'
pacman -Rns --noconfirm "$PKG" >/dev/null 2>&1 || true
pac_reset
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p7b.log" 2>&1
P7B_RC=$?
set -e
sed -n '1,40p' "$WORK/p7b.log"
assert_ne "$P7B_RC" '0' 'P7b the installer exited non-zero on the untrusted-signer package'
assert_matches "$WORK/p7b.log" \
  'required key missing from keyring\|invalid or corrupted package (PGP signature)\|signature from .* is invalid' \
  'P7b pacman named the PACKAGE SIGNATURE failure'
# The discriminator: a checksum complaint here would mean the database
# regeneration failed and SigLevel=Required was never consulted -- which
# is exactly the false green this step exists to avoid.
assert_eq "$(grep_count "$WORK/p7b.log" 'invalid or corrupted package (checksum)\|Maximum file size exceeded')" '0' \
  'P7b pacman did NOT complain about a checksum or a size (so the package SIGNATURE is what rejected it)'
assert_eq "$(installed_version)" '' 'P7b nothing was installed from the untrusted-signer package'
restore_arch_repo
pac_reset

# =====================================================================
step 'P8  a TAMPERED sync DATABASE is rejected (DatabaseRequired)'
# =====================================================================
# The classic "serve a different index under a stale signature". This is
# the check Arch's DEFAULT SigLevel does NOT perform, so it is the one
# that would silently pass on a stock configuration -- and the reason the
# installer writes DatabaseRequired.
cp "$WWW/arch/$DB.db.tar.gz" "$WORK/pristine.db.tar.gz"
SIZE_DB_BEFORE="$(wc -c < "$WWW/arch/$DB.db.tar.gz" | tr -d ' ')"
DBSIG_BEFORE="$(sha256sum "$WWW/arch/$DB.db.tar.gz.sig" | awk '{print $1}')"
python3 - "$WWW/arch/$DB.db.tar.gz" <<'PYDBTAMPER'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2)
    n = f.tell()
    off = n // 2
    f.seek(off)
    orig = f.read(4)
    f.seek(off)
    f.write(bytes(b ^ 0xFF for b in orig))
print('flipped 4 bytes at offset %d of %d in the sync database' % (off, n))
PYDBTAMPER
assert_eq "$(wc -c < "$WWW/arch/$DB.db.tar.gz" | tr -d ' ')" "$SIZE_DB_BEFORE" \
  'P8 the tampered database has the SAME byte size'
assert_eq "$(sha256sum "$WWW/arch/$DB.db.tar.gz.sig" | awk '{print $1}')" "$DBSIG_BEFORE" \
  'P8 the database SIGNATURE is byte-identical (so this is a verification failure, not a missing file)'
pac_reset
set +e
pacman -Sy --noconfirm >"$WORK/p8.log" 2>&1
P8_RC=$?
set -e
sed -n '1,30p' "$WORK/p8.log"
assert_ne "$P8_RC" '0' 'P8 pacman -Sy exited non-zero on the tampered database'
assert_matches "$WORK/p8.log" \
  'invalid or corrupted database\|signature from .* is invalid\|database .* is not valid\|could not be verified' \
  'P8 pacman named the database signature failure'
cp "$WORK/pristine.db.tar.gz" "$WWW/arch/$DB.db.tar.gz"
pac_reset
run_capture "$WORK/p8-restore.log" pacman -Sy --noconfirm \
  || { echo 'restoring the database did not re-sync:'; cat "$WORK/p8-restore.log"; }
assert_eq "$(grep_count "$WORK/p8-restore.log" 'invalid or corrupted database')" '0' \
  'P8 the restored database syncs cleanly again (so P8 measured the tamper, not a broken fixture)'

# =====================================================================
step 'P9  --uninstall leaves NO trace'
# =====================================================================
# VACUITY: "all gone" is trivially true if nothing was ever there, so the
# package is installed first and its presence asserted before removal.
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method pacman >"$WORK/p9-install.log" 2>&1
P9I_RC=$?
set -e
assert_eq "$P9I_RC" '0' 'P9 precondition: reinstall succeeded'
assert_eq "$(installed_version)" "$V2-1" "P9 precondition: $V2-1 is installed"
assert_eq "$(block_count)" '1' 'P9 precondition: the pacman.conf block exists'
assert_file "$KEYRING_DEST" 'P9 precondition: the keyring exists'
assert_file "$BIN"          'P9 precondition: the binary exists'
capture_block

set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method pacman --uninstall >"$WORK/p9.log" 2>&1
P9_RC=$?
set -e
sed -n '1,40p' "$WORK/p9.log"
assert_eq "$P9_RC" '0' 'P9 uninstaller exited 0'
assert_matches "$WORK/p9.log" "removing $PKG\|$PKG-$V2-1" 'P9 pacman itself reported removing the package'
assert_eq "$(installed_version)" '' 'P9 pacman no longer reports the package'
assert_eq "$(block_count)" '0' 'P9 the [reprobuild] block is gone from pacman.conf'
assert_absent "$KEYRING_DEST" 'P9 the trust anchor'
assert_absent "$BIN"          'P9 the installed binary'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' 2>/dev/null | wc -l | tr -d ' ')" '0' \
  'P9 no reprobuild keyring left under /usr/share/keyrings'
# Leaving the key in PACMAN's keyring would mean an "uninstalled" box
# still trusts reprobuild's signing key for anything that re-adds the
# repository, which is not what a user who uninstalled asked for.
set +e
pacman-key --list-keys "$GOOD_FPR" >"$WORK/p9-key.log" 2>&1
P9K_RC=$?
set -e
assert_ne "$P9K_RC" '0' "P9 pacman's own keyring no longer holds the trust anchor"
: > "$BLOCK"

# A second uninstall must also be clean (idempotent removal).
set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method pacman --uninstall >"$WORK/p9b.log" 2>&1
P9B_RC=$?
set -e
assert_eq "$P9B_RC" '0' 'P9 a SECOND uninstall is a no-op, not an error'

# =====================================================================
step 'P10 a TAMPERED TARBALL is rejected THROUGH the installer fallback'
# =====================================================================
# The repo-less path. The installer is what calls M2's verifier, so the
# rejection has to be demonstrated through the installer; M2's own arms
# prove the verifier itself.
DL="$WWW/downloads/v$V2"
mkdir -p "$DL"
ASSET="reprobuild-$V2-linux-$MACHINE.tar.gz"
cp "$TB2" "$DL/$ASSET"
( cd "$DL" && sha256sum "$ASSET" > SHA256SUMS )
run_capture "$WORK/sign-release.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-release.sh" --dir "$DL" --key "$GOOD_FPR" \
  || { echo 'repro-sign-release.sh failed:'; cat "$WORK/sign-release.log"; exit 1; }
assert_file "$DL/SHA256SUMS.asc" 'P10 manifest signature published'
assert_file "$DL/$ASSET.asc"     'P10 per-artifact signature published'

# P10a: the GENUINE bundle must install first. Without it, P10b's
# rejection could be caused by a broken fixture rather than by the tamper.
rm -rf "$WORK/prefix-p10"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
    REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT="$SIGN_DIR/repro-verify-release.sh" \
    REPRO_INSTALL_PREFIX="$WORK/prefix-p10" \
    REPRO_TARBALL_MANIFEST="$WORK/prefix-p10/manifest.txt" \
  sh "$INSTALL_SH" --method tarball --version "$V2" >"$WORK/p10a.log" 2>&1
P10A_RC=$?
set -e
sed -n '1,40p' "$WORK/p10a.log"
assert_eq "$P10A_RC" '0' 'P10a the GENUINE signed tarball installs through the fallback'
assert_matches "$WORK/p10a.log" 'signature verification passed' 'P10a the verifier passed the genuine bundle'
assert_file "$WORK/prefix-p10/bin/repro" 'P10a the fallback unpacked the payload'

# P10b: tamper the artifact, same size again, and require the installer to
# refuse AND to leave nothing unpacked.
cp "$DL/$ASSET" "$WORK/pristine-asset.tar.gz"
python3 - "$DL/$ASSET" <<'PYTB'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2)
    n = f.tell()
    off = n // 2
    f.seek(off)
    orig = f.read(8)
    f.seek(off)
    f.write(bytes(b ^ 0xFF for b in orig))
print('flipped 8 bytes at offset %d of %d' % (off, n))
PYTB
assert_eq "$(wc -c < "$DL/$ASSET" | tr -d ' ')" "$(wc -c < "$WORK/pristine-asset.tar.gz" | tr -d ' ')" \
  'P10b the tampered tarball has the SAME byte size'
rm -rf "$WORK/prefix-p10b"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
    REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT="$SIGN_DIR/repro-verify-release.sh" \
    REPRO_INSTALL_PREFIX="$WORK/prefix-p10b" \
    REPRO_TARBALL_MANIFEST="$WORK/prefix-p10b/manifest.txt" \
  sh "$INSTALL_SH" --method tarball --version "$V2" >"$WORK/p10b.log" 2>&1
P10B_RC=$?
set -e
sed -n '1,40p' "$WORK/p10b.log"
assert_ne "$P10B_RC" '0' 'P10b the installer exited non-zero on the tampered tarball'
assert_matches "$WORK/p10b.log" 'REJECTED\|refusing to install' 'P10b the installer refused to install'
assert_absent "$WORK/prefix-p10b/bin/repro" 'P10b nothing was unpacked from the tampered tarball'
cp "$WORK/pristine-asset.tar.gz" "$DL/$ASSET"

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------
# A run that bailed out early performed fewer checks than a complete one.
# Without this, an abort after the last assertion could produce a short
# all-PASS report -- the harness-level false green this campaign caught in
# the Scoop arm.
if [ "$checks" -lt "$MIN_CHECKS" ]; then
  bad "the arm performed only $checks checks; a complete run performs at least $MIN_CHECKS. It exited early -- treat this as a FAILURE, not a pass."
fi
printf 'm3_install_pacman: %d checks, %d failure(s)\n' "$checks" "$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
