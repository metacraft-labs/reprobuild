#!/bin/sh
# M3 HOSTING+REPOS+INSTALLER gate, apt arm.
#
#   scripts/run_multi_distro_tests.sh m3_install_apt debian
#   (or, on the clean container/box: sh tools/multi-distro-harness/tests/m3_install_apt.sh)
#
# Proves, with apt's own messages and apt's own exit codes, that:
#
#   A1  the installer FAILS CLOSED when no trust anchor digest is pinned
#   A2  the installer REJECTS a keyring whose digest does not match the pin
#   A3  the installer installs reprobuild from the apt repository
#   A4  a SECOND installer run changes nothing (measured, not asserted)
#   A5  publishing a newer release makes apt offer it as an upgrade
#   A6  `apt-get upgrade` MOVES the box to the newer release
#   A7  a tampered .deb is rejected by apt (hash, not size -- see below)
#   A8  a tampered InRelease is rejected by apt
#   A9  --uninstall leaves no repo registration, no keyring, no package
#   A10 a tampered tarball is rejected THROUGH the installer's fallback
#
# and, as the controls that make the ACCEPTANCES mean anything:
#
#   N0  the SAME genuine repository is REJECTED under a DIFFERENT trust
#       anchor. Without this, A3 would also pass against an unsigned
#       repository, or against an apt that never checks.
#   N1  the tampered .deb of A7 has the SAME BYTE SIZE as the original.
#       This is load-bearing. A previous campaign test "proved" a
#       rejection by APPENDING bytes, which tripped the signed index's
#       Size: field before the hash was ever consulted -- proving nothing
#       about hashing or signing. Same size means the only field that can
#       fire is SHA256.
#
# ## Why the repository is served over HTTP and not file://
#
# M2's arms used file:// URIs, which is right for testing signatures. M3
# is about HOSTING, and file:// exercises neither the URL construction
# nor apt's HTTP acquire path -- the two things that break when the base
# URL is wrong. So a local HTTP server stands in for R2, and the
# installer is pointed at it with its ONE documented knob,
# REPRO_BASE_URL. Nothing here edits the installer.
#
# ## The fixture payload, stated plainly
#
# The package installed here carries a SHELL SCRIPT named `repro` that
# prints its version, not a compiled reprobuild. Building real reprobuild
# is a heavy compile, and this arm's subject is the hosting/installer/
# upgrade machinery, not the compiler. What that costs: this arm does NOT
# prove reprobuild builds or runs. What it still proves: the version the
# PAYLOAD reports changes across the upgrade, so the upgrade replaced
# real installed bytes and not merely a dpkg metadata row.

set -eu

DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
INSTALL_SH="$REPO_ROOT/scripts/install/repro-install.sh"
BUILD_PKGS="$REPO_ROOT/scripts/release/repro-build-packages.sh"
PUBLISH="$REPO_ROOT/scripts/release/repro-publish-repos.sh"

WORK="${REPRO_M3_WORK:-/tmp/m3-install-apt}"
WWW="$WORK/www"
PORT="${REPRO_M3_PORT:-8731}"
BASE="http://127.0.0.1:$PORT"

V1='0.1.3'
V2='0.1.4'
PKG='reprobuild'
BIN='/usr/bin/repro'
KEYRING_DEST='/usr/share/keyrings/reprobuild-archive-keyring.gpg'
SOURCES_DEST='/etc/apt/sources.list.d/reprobuild.sources'

fails=0
checks=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { checks=$((checks + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }

# rc captured around a SIMPLE command inside a script file. Never an
# inline `$?` read across a wsl.exe boundary: that prints 0 for a failed
# command (confirmed twice in this campaign).
run_capture() {
  _out="$1"; shift
  set +e
  "$@" > "$_out" 2>&1
  _rc=$?
  set -e
  return $_rc
}

grep_count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# Assert a pattern appears at least once AND say how many times. A grep
# that matches zero lines is a vacuous pass, so counts are compared to
# numbers and never tested for truthiness.
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
  debian|ubuntu) ;;
  *) echo "m3_install_apt: expected debian|ubuntu, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root' >&2; exit 1; }
for f in "$INSTALL_SH" "$BUILD_PKGS" "$PUBLISH" "$SIGN_DIR/make-test-key.sh"; do
  [ -f "$f" ] || { echo "missing required script: $f" >&2; exit 1; }
done

# These are PRECONDITIONS OF THE ONE-LINER, not things the installer
# provides: `curl ... | sh` presupposes curl. dpkg-dev/apt-utils are the
# REPO GENERATOR's tools and would live on a release runner, not a user
# box. Stated so nobody reads their installation here as installer work.
need=''
for t in curl gpg dpkg-scanpackages apt-ftparchive python3; do
  command -v "$t" >/dev/null 2>&1 || need="$need $t"
done
if [ -n "$need" ]; then
  echo "installing gate prerequisites for:$need"
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl gnupg dpkg-dev apt-utils python3 >/dev/null 2>&1 || true
fi
for t in curl gpg dpkg-scanpackages apt-ftparchive python3 dpkg-deb; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
ARCH="$(dpkg --print-architecture)"
echo "arch=$ARCH apt=$(apt-get --version | head -1) os=${PRETTY_NAME:-?}"

rm -rf "$WORK"
mkdir -p "$WORK" "$WWW"

# Leave the box as we found it, whatever happens below.
cleanup() {
  set +e
  [ -z "${HTTP_PID:-}" ] || kill "$HTTP_PID" 2>/dev/null
  restore_distro_sources 2>/dev/null
  # Leave the box as clean as the hermetic reset expects to find it. The
  # A10 tarball phase installs a system trust anchor, and leaving it
  # behind is what broke A1/A2 on the second run of this arm.
  apt-get remove -y --purge "$PKG" >/dev/null 2>&1
  rm -f /usr/share/keyrings/*reprobuild* /etc/apt/sources.list.d/*reprobuild*
  rm -rf /var/lib/reprobuild
}
trap cleanup EXIT INT TERM

# The distro's own sources are moved aside ONLY for the rejection
# phases. Reason: with deb.debian.org in scope, a flaky mirror produces
# the same non-zero apt exit as a rejected signature, and the gate would
# report a green rejection for the wrong reason. The ACCEPTANCE phases
# keep them enabled, because that is the configuration a real user has.
DISTRO_SRC_BACKUP="$WORK/distro-sources"
hide_distro_sources() {
  mkdir -p "$DISTRO_SRC_BACKUP"
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    case "$f" in
      *reprobuild*) continue ;;
      *'*'*) continue ;;
    esac
    [ -f "$f" ] || continue
    mv "$f" "$DISTRO_SRC_BACKUP/"
  done
  if [ -s /etc/apt/sources.list ]; then
    mv /etc/apt/sources.list "$DISTRO_SRC_BACKUP/sources.list.main"
  fi
}
restore_distro_sources() {
  [ -d "$DISTRO_SRC_BACKUP" ] || return 0
  for f in "$DISTRO_SRC_BACKUP"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      sources.list.main) mv "$f" /etc/apt/sources.list ;;
      *) mv "$f" /etc/apt/sources.list.d/ ;;
    esac
  done
}

apt_reset() {
  rm -rf /var/lib/apt/lists
  mkdir -p /var/lib/apt/lists/partial
  apt-get clean >/dev/null 2>&1 || true
}

installed_version() {
  dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true
}
payload_version() {
  if [ -x "$BIN" ]; then "$BIN" --version 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------
step 'hermetic reset: remove any reprobuild state from a previous run'
# ---------------------------------------------------------------------
# Load-bearing, not tidiness. A1 and A2 assert that a REFUSED install
# left no keyring behind. The first time this arm ran twice on one box,
# both failed -- a keyring survived from the previous run's A10 tarball
# phase. A differently-written assertion would instead have PASSED while
# measuring the previous run's leftovers, which is the false green this
# campaign keeps finding. So the state is cleared, and the clearing is
# then ASSERTED: a reset that silently did nothing would put the vacuity
# straight back.
apt-get remove -y --purge "$PKG" >/dev/null 2>&1 || true
rm -f /usr/share/keyrings/*reprobuild* /etc/apt/sources.list.d/*reprobuild*
rm -rf /var/lib/reprobuild
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' | wc -l | tr -d ' ')" '0' \
  'reset: no reprobuild keyring on the box before the arm starts'
assert_eq "$(find /etc/apt/sources.list.d -name '*reprobuild*' | wc -l | tr -d ' ')" '0' \
  'reset: no reprobuild apt source on the box before the arm starts'
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

# ---------------------------------------------------------------------
step 'build two fixture release tarballs (the release.yml asset shape)'
# ---------------------------------------------------------------------
make_tarball() {
  _v="$1"
  _top="reprobuild-$_v-linux-x86_64"
  _d="$WORK/tarballs/$_top"
  rm -rf "$_d"
  mkdir -p "$_d/bin" "$_d/lib"
  # The payload reports its own version, so the upgrade assertion can be
  # made against INSTALLED BYTES and not only against dpkg's database.
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
step "build the $V1 .deb via scripts/release/repro-build-packages.sh"
# ---------------------------------------------------------------------
mkdir -p "$WORK/pkgs-v1" "$WORK/pkgs-v2"
run_capture "$WORK/build-v1.log" sh "$BUILD_PKGS" \
  --version "$V1" --tarball "$TB1" --out "$WORK/pkgs-v1" --ecosystem deb \
  || { echo 'repro-build-packages.sh failed for v1:'; cat "$WORK/build-v1.log"; exit 1; }
DEB1="$WORK/pkgs-v1/reprobuild_${V1}-1_${ARCH}.deb"
assert_file "$DEB1" "generated $V1 .deb"

# ---------------------------------------------------------------------
step "publish $V1 to the local repo root via repro-publish-repos.sh"
# ---------------------------------------------------------------------
# --target local:$WWW is the SAME code path production uses with
# --target r2:<bucket>; only the scheme differs. That is the point of
# making the upload target a variable.
KEYRING_PUB="$WORK/reprobuild-archive-keyring.gpg"
run_capture "$WORK/publish-v1.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V1" --packages "$WORK/pkgs-v1" --key "$GOOD_FPR" \
      --ecosystem deb --repo-root "$WORK/repo" --target "local:$WWW" \
      --deb-arch "$ARCH" --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v1 failed:'; cat "$WORK/publish-v1.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v1.log"
assert_file "$WWW/deb/dists/stable/InRelease" 'published InRelease'
assert_file "$WWW/keys/reprobuild-archive-keyring.gpg" 'published trust anchor'
assert_matches "$WORK/publish-v1.log" "TRUST ANCHOR sha256" 'publish printed the anchor digest'

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
  if curl -fsS -o /dev/null "$BASE/deb/dists/stable/InRelease" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 0.2
done
if ! http_server_alive; then
  bad "the HTTP server THIS run started (pid ${HTTP_PID:-none}) is not running"
  cat "$WORK/http.log"
elif run_capture "$WORK/http-probe.log" curl -fsS -o /dev/null "$BASE/deb/dists/stable/InRelease"; then
  ok "local HTTP server (pid $HTTP_PID, started by THIS run) serves InRelease over $BASE"
else
  bad "local HTTP server did not serve $BASE/deb/dists/stable/InRelease"
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

# =====================================================================
step 'A1  installer FAILS CLOSED with no pinned trust anchor digest'
# =====================================================================
# VACUITY: this would pass for any failure at all, so the specific
# fail-closed diagnostic is matched, AND we assert the repo was NOT
# registered. A crash before reaching the anchor check would leave the
# same non-zero exit but a different message.
apt_reset
set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method apt >"$WORK/a1.log" 2>&1
A1_RC=$?
set -e
assert_ne "$A1_RC" '0' 'A1 installer exited non-zero with no digest pinned'
assert_matches "$WORK/a1.log" 'no trust anchor digest is pinned' 'A1 refused for the fail-closed reason'
assert_absent "$SOURCES_DEST" 'A1 registered no apt source'
assert_absent "$KEYRING_DEST" 'A1 installed no keyring'

# =====================================================================
step 'A2  installer REJECTS a trust anchor whose digest != the pin'
# =====================================================================
# VACUITY: a wrong-but-nonempty digest could also fail by 404 or by an
# empty download. So the digest used is a VALID sha256 of *different*
# bytes, the fetch is the same URL that succeeded in A1's setup, and the
# message asserted is the mismatch one specifically.
WRONG_SHA="$(printf 'not the anchor' | sha256sum | awk '{print $1}')"
assert_ne "$WRONG_SHA" "$ANCHOR_SHA" 'A2 the wrong digest differs from the real one'
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$WRONG_SHA" \
  sh "$INSTALL_SH" --method apt >"$WORK/a2.log" 2>&1
A2_RC=$?
set -e
assert_ne "$A2_RC" '0' 'A2 installer exited non-zero on digest mismatch'
assert_matches "$WORK/a2.log" 'trust anchor digest MISMATCH' 'A2 refused for the digest-mismatch reason'
assert_absent "$SOURCES_DEST" 'A2 registered no apt source'
assert_absent "$KEYRING_DEST" 'A2 installed no keyring'

# =====================================================================
step "N0  CONTROL: the genuine repo under the ADVERSARY anchor is REJECTED"
# =====================================================================
# This is what makes A3 mean something. The repository below is byte-for-
# byte the one A3 installs from; only the trust anchor differs. If apt
# were not verifying, this would install just as happily as A3 does.
hide_distro_sources
GNUPGHOME="$ADV_HOME" gpg --batch --export "$ADV_FPR" > "$WORK/adversary-keyring.gpg"
[ -s "$WORK/adversary-keyring.gpg" ] || { echo 'adversary keyring empty' >&2; exit 1; }
ADV_SHA="$(sha256sum "$WORK/adversary-keyring.gpg" | awk '{print $1}')"
apt_reset
set +e
env REPRO_BASE_URL="$BASE" \
    REPRO_KEYRING_LOCAL="$WORK/adversary-keyring.gpg" \
    REPRO_KEYRING_SHA256="$ADV_SHA" \
  sh "$INSTALL_SH" --method apt >"$WORK/n0.log" 2>&1
N0_RC=$?
set -e
assert_ne "$N0_RC" '0' 'N0 installer exited non-zero under the adversary anchor'
# apt 2.x: "NO_PUBKEY"/"is not signed". apt 3.x (Sequoia sqv): "Missing key
# <fpr>". Both wordings are accepted; matching only one would make this
# arm silently vacuous on the other apt generation.
assert_matches "$WORK/n0.log" \
  'NO_PUBKEY\|Missing key\|not signed\|no longer signed\|Certificate.*not found\|signatures were invalid' \
  'N0 apt refused the repository under the wrong anchor'
assert_eq "$(installed_version)" '' 'N0 left reprobuild uninstalled'
rm -f "$SOURCES_DEST" "$KEYRING_DEST"
restore_distro_sources

# =====================================================================
step "A3  installer installs reprobuild $V1 from the apt repository"
# =====================================================================
# Distro sources are ENABLED here: this is the configuration a real user
# has, and apt resolving our package alongside them is part of the claim.
apt_reset
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method apt >"$WORK/a3.log" 2>&1
A3_RC=$?
set -e
sed -n '1,60p' "$WORK/a3.log"
assert_eq "$A3_RC" '0' 'A3 installer exited 0'
assert_matches "$WORK/a3.log" 'trust anchor digest OK' 'A3 the pinned digest matched'
# apt's OWN output, not a script asserting success.
assert_matches "$WORK/a3.log" "Setting up $PKG" 'A3 apt reported setting up the package'
assert_file "$SOURCES_DEST" 'A3 apt source registered'
assert_file "$KEYRING_DEST" 'A3 trust anchor installed'
assert_file "$BIN" 'A3 the payload binary landed'
assert_eq "$(installed_version)" "$V1-1" "A3 dpkg reports $V1-1 installed"
assert_eq "$(payload_version)" "reprobuild $V1" "A3 the INSTALLED PAYLOAD reports $V1"

# Signed-By must point at our keyring: without it the anchor would be a
# global apt trust root (the deprecated apt-key add behaviour), trusted
# for every repository on the box rather than only ours.
assert_matches "$SOURCES_DEST" "^Signed-By: $KEYRING_DEST" 'A3 Signed-By pins the anchor to this repo only'

# =====================================================================
step 'A4  IDEMPOTENCE: a second identical run changes nothing (measured)'
# =====================================================================
# Measured, not asserted. Four independent observations are taken before
# and after: the number of apt source stanzas for us, the sha256 of the
# sources file, the sha256 of the keyring, and the installed version.
#
# VACUITY: if the second run simply failed early it would also change
# nothing, so its exit code is asserted to be 0.
before_sources_sha="$(sha256sum "$SOURCES_DEST" | awk '{print $1}')"
before_keyring_sha="$(sha256sum "$KEYRING_DEST" | awk '{print $1}')"
before_version="$(installed_version)"
before_src_files="$(find /etc/apt/sources.list.d -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
before_keyrings="$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
before_uris="$(grep -c '^URIs:' "$SOURCES_DEST" || true)"

set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method apt >"$WORK/a4.log" 2>&1
A4_RC=$?
set -e
assert_eq "$A4_RC" '0' 'A4 second installer run exited 0 (so "no change" is not "it crashed")'

after_sources_sha="$(sha256sum "$SOURCES_DEST" | awk '{print $1}')"
after_keyring_sha="$(sha256sum "$KEYRING_DEST" | awk '{print $1}')"
after_version="$(installed_version)"
after_src_files="$(find /etc/apt/sources.list.d -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
after_keyrings="$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
after_uris="$(grep -c '^URIs:' "$SOURCES_DEST" || true)"

assert_eq "$after_src_files" "$before_src_files" 'A4 apt source file count unchanged'
assert_eq "$after_src_files" '1'                 'A4 exactly ONE apt source file for reprobuild'
assert_eq "$after_uris" "$before_uris"           'A4 URIs stanza count unchanged'
assert_eq "$after_uris" '1'                      'A4 exactly ONE URIs line (no duplicate registration)'
assert_eq "$after_keyrings" "$before_keyrings"   'A4 keyring file count unchanged'
assert_eq "$after_keyrings" '1'                  'A4 exactly ONE reprobuild keyring'
assert_eq "$after_sources_sha" "$before_sources_sha" 'A4 sources file byte-identical'
assert_eq "$after_keyring_sha" "$before_keyring_sha" 'A4 keyring byte-identical'
assert_eq "$after_version" "$before_version"     'A4 installed version unchanged'
# apt must report nothing to do. That is apt's own judgement that the
# state already matches, which a script cannot fake.
assert_matches "$WORK/a4.log" 'is already the newest version\|0 upgraded, 0 newly installed' \
  'A4 apt itself reported there was nothing to do'

# =====================================================================
step "A5  publish $V2 ADDITIVELY; apt then OFFERS it as an upgrade"
# =====================================================================
run_capture "$WORK/build-v2.log" sh "$BUILD_PKGS" \
  --version "$V2" --tarball "$TB2" --out "$WORK/pkgs-v2" --ecosystem deb \
  || { echo 'build v2 failed:'; cat "$WORK/build-v2.log"; exit 1; }
DEB2="$WORK/pkgs-v2/reprobuild_${V2}-1_${ARCH}.deb"
assert_file "$DEB2" "generated $V2 .deb"

# --fetch-existing pulls the CURRENT published pool down first, so v1
# survives. A publish that replaced the tree would make `apt upgrade`
# work exactly once and break every pinned install.
run_capture "$WORK/publish-v2.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V2" --packages "$WORK/pkgs-v2" --key "$GOOD_FPR" \
      --ecosystem deb --repo-root "$WORK/repo2" --target "local:$WWW" \
      --deb-arch "$ARCH" --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v2 failed:'; cat "$WORK/publish-v2.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v2.log"

# Both versions must be in the pool: that is what makes this an UPGRADE
# rather than a republish.
POOL_DEBS="$(find "$WWW/deb/pool" -name '*.deb' | wc -l | tr -d ' ')"
assert_eq "$POOL_DEBS" '2' 'A5 the published pool carries BOTH versions'
PKGS_INDEX="$WWW/deb/dists/stable/main/binary-$ARCH/Packages"
assert_eq "$(grep -c "^Version: $V1" "$PKGS_INDEX" || true)" '1' "A5 index still lists $V1"
assert_eq "$(grep -c "^Version: $V2" "$PKGS_INDEX" || true)" '1' "A5 index now lists $V2"

# The BEFORE picture, from apt's own mouth.
run_capture "$WORK/a5-update.log" apt-get update \
  || { echo 'apt-get update failed after publishing v2:'; cat "$WORK/a5-update.log"; }
step 'A5  apt-cache policy BEFORE the upgrade'
run_capture "$WORK/a5-policy-before.log" apt-cache policy "$PKG" || true
cat "$WORK/a5-policy-before.log"
assert_matches "$WORK/a5-policy-before.log" "Installed: $V1-1" "A5 apt says $V1-1 is installed"
assert_matches "$WORK/a5-policy-before.log" "Candidate: $V2-1" "A5 apt says $V2-1 is the candidate"

step 'A5  apt list --upgradable BEFORE the upgrade'
run_capture "$WORK/a5-upgradable.log" apt list --upgradable || true
cat "$WORK/a5-upgradable.log"
assert_matches "$WORK/a5-upgradable.log" "^$PKG/" 'A5 apt lists reprobuild as upgradable'
assert_matches "$WORK/a5-upgradable.log" "$V2-1" "A5 the upgradable entry names $V2-1"

# =====================================================================
step "A6  apt-get upgrade MOVES the box from $V1 to $V2"
# =====================================================================
# VACUITY, the important one: this must be a TRANSITION, not a first
# install. So $V1-1 is asserted installed immediately before, the
# upgrade is apt's own command with NO installer involvement, and $V2-1
# is asserted after -- in BOTH dpkg's database and the installed payload.
assert_eq "$(installed_version)" "$V1-1" "A6 precondition: $V1-1 installed before the upgrade"
assert_eq "$(payload_version)" "reprobuild $V1" "A6 precondition: payload reports $V1 before the upgrade"

set +e
apt-get upgrade -y >"$WORK/a6.log" 2>&1
A6_RC=$?
set -e
sed -n '1,60p' "$WORK/a6.log"
assert_eq "$A6_RC" '0' 'A6 apt-get upgrade exited 0'
assert_matches "$WORK/a6.log" "$PKG" 'A6 apt named reprobuild in the upgrade transaction'
assert_matches "$WORK/a6.log" "Setting up $PKG" 'A6 apt set up the new version'
assert_eq "$(installed_version)" "$V2-1" "A6 dpkg now reports $V2-1"
assert_eq "$(payload_version)" "reprobuild $V2" "A6 the INSTALLED PAYLOAD now reports $V2"
# And nothing is left to upgrade.
run_capture "$WORK/a6-after.log" apt-cache policy "$PKG" || true
assert_matches "$WORK/a6-after.log" "Installed: $V2-1" "A6 apt-cache policy confirms $V2-1 installed"

# =====================================================================
step 'A7  a TAMPERED .deb is rejected by apt (same size: hash, not Size)'
# =====================================================================
hide_distro_sources
TARGET_DEB="$(find "$WWW/deb/pool" -name "*${V2}*.deb" | head -1)"
assert_file "$TARGET_DEB" 'A7 found the published .deb to tamper'
cp "$TARGET_DEB" "$WORK/pristine-v2.deb"
SIZE_BEFORE="$(wc -c < "$TARGET_DEB" | tr -d ' ')"

# In-place, SAME-SIZE mutation. N1: appending bytes would change Size:,
# which apt checks BEFORE the digest -- a rejection then proves nothing
# about hashing. Flipping bytes in place leaves SHA256 as the only field
# that can fire.
python3 - "$TARGET_DEB" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2)
    n = f.tell()
    # Mutate deep inside the compressed data payload, past the ar header.
    off = n - 64
    f.seek(off)
    orig = f.read(8)
    flipped = bytes((b ^ 0xFF) for b in orig)
    f.seek(off)
    f.write(flipped)
print("flipped 8 bytes at offset", off, "of", n)
PY
SIZE_AFTER="$(wc -c < "$TARGET_DEB" | tr -d ' ')"
assert_eq "$SIZE_AFTER" "$SIZE_BEFORE" 'N1 the tampered .deb has the SAME byte size (so Size: cannot be what fires)'
assert_ne "$(sha256sum "$TARGET_DEB" | awk '{print $1}')" \
          "$(sha256sum "$WORK/pristine-v2.deb" | awk '{print $1}')" \
          'N1 the tampered .deb does differ in content'

# Force a re-download of that .deb: remove the package, reset the lists.
apt-get remove -y --purge "$PKG" >/dev/null 2>&1 || true
apt_reset
run_capture "$WORK/a7-update.log" apt-get update || true
set +e
apt-get install -y "$PKG" >"$WORK/a7.log" 2>&1
A7_RC=$?
set -e
sed -n '1,40p' "$WORK/a7.log"
assert_ne "$A7_RC" '0' 'A7 apt-get install exited non-zero on the tampered .deb'
assert_matches "$WORK/a7.log" 'Hash Sum mismatch\|hash sum mismatch\|Mismatch\|corrupt' \
  'A7 apt reported a hash mismatch on the package'
assert_eq "$(installed_version)" '' 'A7 nothing was installed from the tampered .deb'
cp "$WORK/pristine-v2.deb" "$TARGET_DEB"

# =====================================================================
step 'A8a a MALFORMED InRelease signature packet is rejected by apt'
# =====================================================================
INREL="$WWW/deb/dists/stable/InRelease"
cp "$INREL" "$WORK/pristine.InRelease"
python3 - "$INREL" <<'PY'
import sys, re
p = sys.argv[1]
d = open(p, 'rb').read()
m = re.search(rb'-----BEGIN PGP SIGNATURE-----\r?\n', d)
assert m, 'no PGP signature block found in InRelease'
start = m.end()
seg = bytearray(d[start:start+200])
for i in range(len(seg)):
    c = seg[i]
    if 65 <= c <= 90:      # A-Z
        seg[i] = 90 if c != 90 else 65
        break
out = d[:start] + bytes(seg) + d[start+200:]
assert len(out) == len(d), 'tamper changed the file length'
open(p, 'wb').write(out)
print('flipped one base64 char inside the PGP SIGNATURE block')
PY
apt_reset
set +e
apt-get update >"$WORK/a8a.log" 2>&1
A8A_RC=$?
set -e
sed -n '1,40p' "$WORK/a8a.log"
assert_ne "$A8A_RC" '0' 'A8a apt-get update exited non-zero on a corrupt signature packet'
assert_matches "$WORK/a8a.log" 'is not signed\|BADSIG\|signatures were invalid\|Malformed packet' \
  'A8a apt refused the repository'
cp "$WORK/pristine.InRelease" "$INREL"

# =====================================================================
step 'A8b a MODIFIED InRelease BODY is rejected -- the signature is really verified'
# =====================================================================
# A8a is NOT enough, and saying so is the point of splitting it.
#
# Flipping base64 inside the signature armour yields a MALFORMED OpenPGP
# packet, and apt 3's sqv then fails in its PARSER ("Malformed packet:
# Truncated packet") before any cryptography happens. That is the same
# empty result as this campaign's earlier false green, where appending
# bytes tripped a signed database's Size: field before the signature was
# ever consulted: a rejection that proves the file was unparsable, not
# that it was unauthentic.
#
# So here the signature block is left BYTE-FOR-BYTE INTACT and
# well-formed, and one hex digit of one SHA256 in the SIGNED BODY is
# changed instead. The signature now parses perfectly and simply does not
# match the content. Only real verification can reject this, and the
# assertion below therefore REFUSES to accept a "malformed/truncated"
# diagnosis as a pass.
python3 - "$INREL" <<'PY'
import sys, re
p = sys.argv[1]
d = open(p, 'rb').read()
sig = d.index(b'-----BEGIN PGP SIGNATURE-----')
body, tail = d[:sig], d[sig:]
# Change exactly one hex digit of one 64-hex-digit checksum in the body.
m = None
for cand in re.finditer(rb'(?m)^ ([0-9a-f]{64}) ', body):
    m = cand
    break
assert m, 'no 64-hex checksum line found in the InRelease body'
s, e = m.start(1), m.end(1)
old = body[s:e]
c = old[0:1]
new = (b'1' if c == b'0' else b'0') + old[1:]
assert len(new) == len(old)
out = body[:s] + new + body[e:] + tail
assert len(out) == len(d), 'tamper changed the file length'
open(p, 'wb').write(out)
print('changed one hex digit of a SHA256 in the SIGNED BODY;')
print('  signature armour left byte-for-byte intact:', old.decode(), '->', new.decode())
PY
# The signature block must be untouched, or this degenerates into A8a.
SIG_BEFORE="$(sed -n '/BEGIN PGP SIGNATURE/,$p' "$WORK/pristine.InRelease" | sha256sum | awk '{print $1}')"
SIG_AFTER="$(sed -n '/BEGIN PGP SIGNATURE/,$p' "$INREL" | sha256sum | awk '{print $1}')"
assert_eq "$SIG_AFTER" "$SIG_BEFORE" 'A8b the signature armour is byte-identical (so this is not a parse failure)'
assert_eq "$(wc -c < "$INREL" | tr -d ' ')" "$(wc -c < "$WORK/pristine.InRelease" | tr -d ' ')" \
  'A8b the tampered InRelease has the SAME byte size'

apt_reset
set +e
apt-get update >"$WORK/a8b.log" 2>&1
A8B_RC=$?
set -e
sed -n '1,40p' "$WORK/a8b.log"
assert_ne "$A8B_RC" '0' 'A8b apt-get update exited non-zero on a modified signed body'
# apt 2.x wording: BADSIG / "signatures were invalid".
# apt 3.x via Sequoia sqv: "Message has been manipulated".
assert_matches "$WORK/a8b.log" \
  'BADSIG\|signatures were invalid\|Message has been manipulated\|Bad signature' \
  'A8b apt reported a CRYPTOGRAPHIC signature failure'
# The discriminator: a parser complaint here would mean the tamper was
# malformed rather than unauthentic, and the check above would have
# passed for the wrong reason.
A8B_MALFORMED="$(grep_count "$WORK/a8b.log" 'Malformed packet\|Truncated packet')"
assert_eq "${A8B_MALFORMED:-0}" '0' \
  'A8b apt did NOT complain about a malformed packet (so verification, not parsing, rejected it)'
cp "$WORK/pristine.InRelease" "$INREL"

# =====================================================================
step 'A8c a TAMPERED Packages index is rejected -- the hash chain holds'
# =====================================================================
# InRelease -> Packages -> .deb is one hash chain rooted in ONE signature.
# A8b broke the root; this breaks the middle link, over HTTP, which is
# the link that only exists because the repository is hosted rather than
# local.
PKGS_FILE="$WWW/deb/dists/stable/main/binary-$ARCH/Packages"
PKGS_GZ="$PKGS_FILE.gz"
cp "$PKGS_FILE" "$WORK/pristine.Packages"
cp "$PKGS_GZ"   "$WORK/pristine.Packages.gz"
# BOTH indices are tampered. apt chooses which compression variant to
# fetch (it normally prefers Packages.gz), so tampering only the plain
# file would let apt fetch an intact .gz, verify it happily, and this
# step would report a FAILURE TO REJECT rather than the rejection we are
# after. Same size in both cases, so Size: cannot be what fires.
python3 - "$PKGS_FILE" "$PKGS_GZ" <<'PY'
import sys
plain, gz = sys.argv[1], sys.argv[2]

d = open(plain, 'rb').read()
s = d.index(b'SHA256: ') + len(b'SHA256: ')
old = d[s:s+64]
new = (b'1' if old[0:1] == b'0' else b'0') + old[1:]
out = d[:s] + new + d[s+64:]
assert len(out) == len(d)
open(plain, 'wb').write(out)
print('Packages: changed one hex digit of the .deb SHA256')

with open(gz, 'r+b') as f:
    f.seek(0, 2); n = f.tell()
    off = n // 2
    f.seek(off); orig = f.read(4)
    f.seek(off); f.write(bytes(b ^ 0xFF for b in orig))
print('Packages.gz: flipped 4 bytes at', off, 'of', n)
PY
assert_eq "$(wc -c < "$PKGS_FILE" | tr -d ' ')" "$(wc -c < "$WORK/pristine.Packages" | tr -d ' ')" \
  'A8c the tampered Packages has the SAME byte size'
assert_eq "$(wc -c < "$PKGS_GZ" | tr -d ' ')" "$(wc -c < "$WORK/pristine.Packages.gz" | tr -d ' ')" \
  'A8c the tampered Packages.gz has the SAME byte size'
apt_reset
set +e
apt-get update >"$WORK/a8c.log" 2>&1
A8C_RC=$?
set -e
sed -n '1,30p' "$WORK/a8c.log"
assert_ne "$A8C_RC" '0' 'A8c apt-get update exited non-zero on a tampered Packages index'
assert_matches "$WORK/a8c.log" 'Hash Sum mismatch\|hash sum mismatch\|Mismatch' \
  'A8c apt reported a hash mismatch on the index (InRelease -> Packages link)'
cp "$WORK/pristine.Packages" "$PKGS_FILE"
cp "$WORK/pristine.Packages.gz" "$PKGS_GZ"
apt_reset
restore_distro_sources

# =====================================================================
step 'A9  --uninstall leaves NO trace'
# =====================================================================
# VACUITY: "all gone" is trivially true if nothing was ever there, so the
# package is reinstalled first and its presence asserted before removal.
run_capture "$WORK/a9-update.log" apt-get update || true
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method apt >"$WORK/a9-install.log" 2>&1
A9I_RC=$?
set -e
assert_eq "$A9I_RC" '0' 'A9 precondition: reinstall succeeded'
assert_eq "$(installed_version)" "$V2-1" "A9 precondition: $V2-1 is installed"
assert_file "$SOURCES_DEST" 'A9 precondition: the apt source exists'
assert_file "$KEYRING_DEST" 'A9 precondition: the keyring exists'
assert_file "$BIN"          'A9 precondition: the binary exists'

set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method apt --uninstall >"$WORK/a9.log" 2>&1
A9_RC=$?
set -e
sed -n '1,40p' "$WORK/a9.log"
assert_eq "$A9_RC" '0' 'A9 uninstaller exited 0'
assert_matches "$WORK/a9.log" "Removing $PKG\|Purging" 'A9 apt itself reported removing the package'
assert_eq "$(installed_version)" '' 'A9 dpkg no longer reports the package'
assert_absent "$SOURCES_DEST" 'A9 the apt source registration'
assert_absent "$KEYRING_DEST" 'A9 the trust anchor'
assert_absent "$BIN"          'A9 the installed binary'
LEFTOVER_SRC="$(find /etc/apt/sources.list.d -name '*reprobuild*' | wc -l | tr -d ' ')"
LEFTOVER_KR="$(find /usr/share/keyrings -name '*reprobuild*' | wc -l | tr -d ' ')"
assert_eq "$LEFTOVER_SRC" '0' 'A9 no reprobuild file left under sources.list.d'
assert_eq "$LEFTOVER_KR" '0' 'A9 no reprobuild keyring left under /usr/share/keyrings'

# A second uninstall must also be clean (idempotent removal).
set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method apt --uninstall >"$WORK/a9b.log" 2>&1
A9B_RC=$?
set -e
assert_eq "$A9B_RC" '0' 'A9 a SECOND uninstall is a no-op, not an error'

# =====================================================================
step 'A10 a TAMPERED TARBALL is rejected THROUGH the installer fallback'
# =====================================================================
# The installer is the thing that calls M2's verifier, so the rejection
# has to be demonstrated through the installer, not by calling the
# verifier directly. M2's own arms prove the verifier; this proves the
# installer cannot be made to unpack unverified bytes.
DL="$WWW/downloads/v$V2"
mkdir -p "$DL"
ASSET="reprobuild-$V2-linux-x86_64.tar.gz"
cp "$TB2" "$DL/$ASSET"
( cd "$DL" && sha256sum "$ASSET" > SHA256SUMS )
run_capture "$WORK/sign-release.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-release.sh" --dir "$DL" --key "$GOOD_FPR" \
  || { echo 'repro-sign-release.sh failed:'; cat "$WORK/sign-release.log"; exit 1; }
assert_file "$DL/SHA256SUMS.asc" 'A10 manifest signature published'
assert_file "$DL/$ASSET.asc"     'A10 per-artifact signature published'

# A10a: the GENUINE signed tarball installs through the fallback. Without
# this, A10b's rejection could be caused by a broken fixture rather than
# by the tamper.
rm -rf "$WORK/prefix-a10"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
    REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT="$SIGN_DIR/repro-verify-release.sh" \
    REPRO_INSTALL_PREFIX="$WORK/prefix-a10" \
    REPRO_TARBALL_MANIFEST="$WORK/prefix-a10/manifest.txt" \
  sh "$INSTALL_SH" --method tarball --version "$V2" >"$WORK/a10a.log" 2>&1
A10A_RC=$?
set -e
sed -n '1,40p' "$WORK/a10a.log"
assert_eq "$A10A_RC" '0' 'A10a the GENUINE signed tarball installs through the fallback'
assert_matches "$WORK/a10a.log" 'signature verification passed' 'A10a the verifier passed the genuine bundle'
assert_file "$WORK/prefix-a10/bin/repro" 'A10a the fallback unpacked the payload'

# A10b: tamper the artifact, same size again, and require the installer
# to refuse AND to leave nothing unpacked.
cp "$DL/$ASSET" "$WORK/pristine-asset.tar.gz"
python3 - "$DL/$ASSET" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2); n = f.tell()
    off = n // 2
    f.seek(off); orig = f.read(8)
    f.seek(off); f.write(bytes(b ^ 0xFF for b in orig))
print("flipped 8 bytes at", off, "of", n)
PY
TSIZE="$(wc -c < "$DL/$ASSET" | tr -d ' ')"
PSIZE="$(wc -c < "$WORK/pristine-asset.tar.gz" | tr -d ' ')"
assert_eq "$TSIZE" "$PSIZE" 'A10b the tampered tarball has the SAME byte size'
rm -rf "$WORK/prefix-a10b"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
    REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT="$SIGN_DIR/repro-verify-release.sh" \
    REPRO_INSTALL_PREFIX="$WORK/prefix-a10b" \
    REPRO_TARBALL_MANIFEST="$WORK/prefix-a10b/manifest.txt" \
  sh "$INSTALL_SH" --method tarball --version "$V2" >"$WORK/a10b.log" 2>&1
A10B_RC=$?
set -e
sed -n '1,40p' "$WORK/a10b.log"
assert_ne "$A10B_RC" '0' 'A10b the installer exited non-zero on the tampered tarball'
assert_matches "$WORK/a10b.log" 'REJECTED\|refusing to install' 'A10b the installer refused to install'
assert_absent "$WORK/prefix-a10b/bin/repro" 'A10b nothing was unpacked from the tampered tarball'
cp "$WORK/pristine-asset.tar.gz" "$DL/$ASSET"

# A10c: remove the signature entirely. "No signature" must be a
# rejection, not an unsigned install.
mv "$DL/$ASSET.asc" "$WORK/held.asc"
rm -rf "$WORK/prefix-a10c"
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
    REPRO_ALLOW_TEST_KEY=1 REPRO_VERIFY_SCRIPT="$SIGN_DIR/repro-verify-release.sh" \
    REPRO_INSTALL_PREFIX="$WORK/prefix-a10c" \
    REPRO_TARBALL_MANIFEST="$WORK/prefix-a10c/manifest.txt" \
  sh "$INSTALL_SH" --method tarball --version "$V2" >"$WORK/a10c.log" 2>&1
A10C_RC=$?
set -e
assert_ne "$A10C_RC" '0' 'A10c a MISSING per-artifact signature is a rejection'
assert_absent "$WORK/prefix-a10c/bin/repro" 'A10c nothing was unpacked with no signature'
mv "$WORK/held.asc" "$DL/$ASSET.asc"

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------
printf 'm3_install_apt: %d checks, %d failure(s)\n' "$checks" "$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
