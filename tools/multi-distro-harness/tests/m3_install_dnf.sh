#!/bin/sh
# M3 HOSTING+REPOS+INSTALLER gate, dnf/rpm arm.
#
#   scripts/run_multi_distro_tests.sh m3_install_dnf fedora
#
# The rpm equivalent of m3_install_apt. Proves, with dnf's and rpm's own
# messages and exit codes:
#
#   R1  the installer FAILS CLOSED with no pinned trust anchor digest
#   R2  the installer REJECTS a keyring whose digest does not match
#   R3  the installer installs reprobuild from the dnf repository
#   R4  a SECOND installer run changes nothing (measured)
#   R5  publishing a newer release makes dnf OFFER it as an upgrade
#   R6  `dnf upgrade` MOVES the box to the newer release
#   R7  a tampered .rpm is rejected (gpgcheck, on the package header)
#   R8  a tampered repomd.xml is rejected (repo_gpgcheck, on the metadata)
#   R9  --uninstall leaves no repo file, no key, no package
#
# with the control that makes R3 mean anything:
#
#   N0  the SAME genuine repository is REJECTED under a DIFFERENT trust
#       anchor.
#
# and one step that is its own control:
#
#   N1  a GENUINELY BINARY trust anchor installs, because the installer
#       re-encodes it as ASCII armour -- proved by running the SAME
#       installer with that conversion short-circuited and watching rpm
#       refuse the key in its own words.
#
# ## Why gpgcheck AND repo_gpgcheck both get their own step
#
# They are independent and neither implies the other: R7 tampers a
# PACKAGE with intact metadata (only gpgcheck can catch that) and R8
# tampers the METADATA (only repo_gpgcheck can). Fedora's own
# repositories historically shipped repo_gpgcheck=0, so a repository
# whose metadata is signed but whose client config does not check it is
# an unsigned repository in practice. The installer writes both.
#
# ## Fedora's own repositories are excluded from OUR transactions
#
# Every dnf call below runs with --disablerepo='*' --enablerepo=reprobuild.
# Not for speed: with Fedora's mirrors in scope, a mirror hiccup produces
# the same non-zero exit as a rejected signature, and this arm would
# report a green rejection for the wrong reason. The commands are still
# dnf's own generic `install` / `upgrade`, not a scripted assertion.
#
# ## The fixture payload, stated plainly
#
# As in the apt arm, the packaged `repro` is a shell script that prints
# its version, not a compiled reprobuild: building real reprobuild is a
# heavy compile and this arm's subject is the hosting/upgrade machinery.
# It still means the version the INSTALLED PAYLOAD reports changes across
# the upgrade, so the upgrade replaced real bytes and not just an rpm
# database row.

set -eu

REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
INSTALL_SH="$REPO_ROOT/scripts/install/repro-install.sh"
BUILD_PKGS="$REPO_ROOT/scripts/release/repro-build-packages.sh"
PUBLISH="$REPO_ROOT/scripts/release/repro-publish-repos.sh"

WORK="${REPRO_M3_WORK:-/tmp/m3-install-dnf}"
WWW="$WORK/www"
PORT="${REPRO_M3_PORT:-8732}"
BASE="http://127.0.0.1:$PORT"

V1='0.1.3'
V2='0.1.4'
PKG='reprobuild'
BIN='/usr/bin/repro'
KEYRING_DEST='/usr/share/keyrings/reprobuild-archive-keyring.gpg'
REPO_DEST='/etc/yum.repos.d/reprobuild.repo'

fails=0
checks=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { checks=$((checks + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }

run_capture() {
  _out="$1"; shift
  set +e
  "$@" > "$_out" 2>&1
  _rc=$?
  set -e
  return $_rc
}

grep_count() { grep -c -- "$2" "$1" 2>/dev/null || true; }
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
assert_eq() { if [ "$1" = "$2" ]; then ok "$3 (= $1)"; else bad "$3: expected '$2', got '$1'"; fi }
assert_ne() { if [ "$1" != "$2" ]; then ok "$3 ('$1' != '$2')"; else bad "$3: both are '$1'"; fi }
assert_file()   { if [ -e "$1" ]; then ok "$2 exists: $1"; else bad "$2 missing: $1"; fi }
assert_absent() { if [ ! -e "$1" ]; then ok "$2 is absent: $1"; else bad "$2 still present: $1"; fi }

# ---------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------
[ -r /etc/os-release ] || { echo 'no /etc/os-release' >&2; exit 1; }
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *' fedora '*|*' rhel '*|*' centos '*) ;;
  *) echo "m3_install_dnf: expected a fedora/rhel family, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root' >&2; exit 1; }
for f in "$INSTALL_SH" "$BUILD_PKGS" "$PUBLISH" "$SIGN_DIR/make-test-key.sh"; do
  [ -f "$f" ] || { echo "missing required script: $f" >&2; exit 1; }
done
# Preconditions of the GATE (the repo generator's tools and the one-liner's
# curl), not things the installer provides.
for t in rpmbuild createrepo_c rpmsign gpg python3 curl rpm; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t (dnf install rpm-build createrepo_c rpm-sign)" >&2; exit 1; }
done

DNF='dnf5'
command -v dnf5 >/dev/null 2>&1 || DNF='dnf'
# Every transaction is scoped to OUR repository; see the header.
dnf_only() { "$DNF" -y --disablerepo='*' --enablerepo=reprobuild "$@"; }

echo "os=${PRETTY_NAME:-?} dnf=$("$DNF" --version 2>&1 | head -1) rpm=$(rpm --version)"
ARCH="$(rpm --eval '%{_arch}')"
echo "arch=$ARCH"

rm -rf "$WORK"
mkdir -p "$WORK" "$WWW"

# `rpm -q` prints "package <name> is not installed" ON STDOUT and exits
# non-zero. Piping that through `|| true` captures the SENTENCE as if it
# were a version, so a not-installed box reported a non-empty "version".
# That produced spurious failures here; the same shape in an assertion
# written the other way round (expect non-empty) would have been a false
# GREEN. So presence is tested first, separately, and only then queried.
installed_version() {
  if rpm -q "$PKG" >/dev/null 2>&1; then rpm -q --qf '%{VERSION}' "$PKG" 2>/dev/null; fi
}
installed_nevra() {
  if rpm -q "$PKG" >/dev/null 2>&1; then rpm -q "$PKG" 2>/dev/null; fi
}
payload_version()   { if [ -x "$BIN" ]; then "$BIN" --version 2>/dev/null || true; fi }

# Remove every gpg-pubkey rpm whose description mentions reprobuild. rpm
# keeps imported keys as pseudo-packages, and one left behind would make
# a later "the wrong key is rejected" step pass or fail for the wrong
# reason.
purge_reprobuild_rpm_keys() {
  for _k in $(rpm -qa 'gpg-pubkey*' 2>/dev/null || true); do
    if rpm -qi "$_k" 2>/dev/null | grep -qi 'reprobuild\|UNTRUSTED TEST KEY'; then
      rpm -e --allmatches "$_k" >/dev/null 2>&1 || true
    fi
  done
}

cleanup() {
  set +e
  [ -z "${HTTP_PID:-}" ] || kill "$HTTP_PID" 2>/dev/null
  "$DNF" -y remove "$PKG" >/dev/null 2>&1
  rm -f "$REPO_DEST" /usr/share/keyrings/*reprobuild*
  purge_reprobuild_rpm_keys
  rm -rf /var/lib/reprobuild
}
trap cleanup EXIT INT TERM

dnf_reset() { "$DNF" clean all >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------
step 'hermetic reset: remove any reprobuild state from a previous run'
# ---------------------------------------------------------------------
# Load-bearing: R1/R2 assert that a REFUSED install left no key behind,
# and leftovers from a previous run would either fail those or, worse,
# let them pass while measuring the previous run.
"$DNF" -y remove "$PKG" >/dev/null 2>&1 || true
rm -f "$REPO_DEST" /usr/share/keyrings/*reprobuild*
purge_reprobuild_rpm_keys
assert_eq "$(installed_version)" '' 'reset: reprobuild is not installed before the arm starts'
assert_absent "$KEYRING_DEST" 'reset: the trust anchor'
assert_absent "$REPO_DEST"    'reset: the dnf repo file'
assert_eq "$(rpm -qa 'gpg-pubkey*' 2>/dev/null | while read -r k; do rpm -qi "$k" 2>/dev/null | grep -qi 'UNTRUSTED TEST KEY' && echo x; done | wc -l | tr -d ' ')" \
  '0' 'reset: no reprobuild test key left in the rpm keyring'

# ---------------------------------------------------------------------
step 'throwaway signing key + an adversary key (M2 make-test-key.sh)'
# ---------------------------------------------------------------------
GOOD_HOME="$WORK/gnupg-good"
ADV_HOME="$WORK/gnupg-adversary"
GOOD_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$GOOD_HOME")"
ADV_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$ADV_HOME")"
[ -n "$GOOD_FPR" ] || { echo 'no signing key' >&2; exit 1; }
assert_ne "$GOOD_FPR" "$ADV_FPR" 'the two throwaway keys are distinct'
echo "signing key:   $GOOD_FPR"
echo "adversary key: $ADV_FPR"

# ---------------------------------------------------------------------
step 'build two fixture release tarballs'
# ---------------------------------------------------------------------
mkdir -p "$WORK/tarballs"
make_tarball() {
  _v="$1"
  _top="reprobuild-$_v-linux-x86_64"
  _d="$WORK/tarballs/$_top"
  rm -rf "$_d"; mkdir -p "$_d/bin" "$_d/lib"
  cat > "$_d/bin/repro" <<PAYLOAD
#!/bin/sh
case "\${1:-}" in
  --version|-V) printf 'reprobuild %s\n' "$_v" ;;
  *) printf 'reprobuild %s (M3 gate fixture payload)\n' "$_v" ;;
esac
PAYLOAD
  chmod 0755 "$_d/bin/repro"
  printf 'fixture runtime lib for %s\n' "$_v" > "$_d/lib/libreprofixture.so"
  ( cd "$WORK/tarballs" && tar -czf "$_top.tar.gz" "$_top" )
  echo "$WORK/tarballs/$_top.tar.gz"
}
TB1="$(make_tarball "$V1")"
TB2="$(make_tarball "$V2")"
assert_file "$TB1" "fixture tarball $V1"
assert_file "$TB2" "fixture tarball $V2"

# ---------------------------------------------------------------------
step "build the $V1 .rpm via scripts/release/repro-build-packages.sh"
# ---------------------------------------------------------------------
mkdir -p "$WORK/pkgs-v1" "$WORK/pkgs-v2"
run_capture "$WORK/build-v1.log" sh "$BUILD_PKGS" \
  --version "$V1" --tarball "$TB1" --out "$WORK/pkgs-v1" --ecosystem rpm \
  || { echo 'build v1 failed:'; cat "$WORK/build-v1.log"; exit 1; }
RPM1="$(find "$WORK/pkgs-v1" -name "*$V1*.rpm" | head -1)"
assert_file "$RPM1" "generated $V1 .rpm"

# ---------------------------------------------------------------------
step "publish $V1 to the local repo root (target local:, same path as r2:)"
# ---------------------------------------------------------------------
KEYRING_PUB="$WORK/reprobuild-archive-keyring.gpg"
run_capture "$WORK/publish-v1.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V1" --packages "$WORK/pkgs-v1" --key "$GOOD_FPR" \
      --ecosystem rpm --repo-root "$WORK/repo" --target "local:$WWW" \
      --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v1 failed:'; cat "$WORK/publish-v1.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v1.log"
assert_file "$WWW/rpm/repodata/repomd.xml"     'published repomd.xml'
assert_file "$WWW/rpm/repodata/repomd.xml.asc" 'published repomd.xml signature'
assert_file "$WWW/keys/reprobuild-archive-keyring.gpg" 'published trust anchor'
ANCHOR_SHA="$(cat "$WWW/keys/reprobuild-archive-keyring.gpg.sha256")"
[ -n "$ANCHOR_SHA" ] || { echo 'no anchor digest' >&2; exit 1; }
echo "anchor sha256 = $ANCHOR_SHA"

# The .rpm in the published tree must really carry a header signature.
# rpmsign can exit 0 having signed nothing when a macro expansion is
# wrong, which would be a silently unsigned release.
PUB_RPM="$(find "$WWW/rpm" -maxdepth 1 -name '*.rpm' | head -1)"
assert_file "$PUB_RPM" 'a published .rpm'
run_capture "$WORK/rpmkv-v1.log" rpm -Kv "$PUB_RPM" || true
cat "$WORK/rpmkv-v1.log"
assert_matches "$WORK/rpmkv-v1.log" 'signature\|Signature\|OpenPGP\|key ID' \
  'the published .rpm carries a signature (rpm -Kv)'

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
  if curl -fsS -o /dev/null "$BASE/rpm/repodata/repomd.xml" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 0.2
done
if ! http_server_alive; then
  bad "the HTTP server THIS run started (pid ${HTTP_PID:-none}) is not running"
  cat "$WORK/http.log"
elif run_capture "$WORK/http-probe.log" curl -fsS -o /dev/null "$BASE/rpm/repodata/repomd.xml"; then
  ok "local HTTP server (pid $HTTP_PID, started by THIS run) serves repomd.xml over $BASE"
else
  bad "local HTTP server did not serve $BASE/rpm/repodata/repomd.xml"
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
step 'R1  installer FAILS CLOSED with no pinned trust anchor digest'
# =====================================================================
set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method dnf >"$WORK/r1.log" 2>&1
R1_RC=$?
set -e
assert_ne "$R1_RC" '0' 'R1 installer exited non-zero with no digest pinned'
assert_matches "$WORK/r1.log" 'no trust anchor digest is pinned' 'R1 refused for the fail-closed reason'
assert_absent "$REPO_DEST"    'R1 wrote no dnf repo file'
assert_absent "$KEYRING_DEST" 'R1 installed no keyring'

# =====================================================================
step 'R2  installer REJECTS a trust anchor whose digest != the pin'
# =====================================================================
WRONG_SHA="$(printf 'not the anchor' | sha256sum | awk '{print $1}')"
assert_ne "$WRONG_SHA" "$ANCHOR_SHA" 'R2 the wrong digest differs from the real one'
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$WRONG_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/r2.log" 2>&1
R2_RC=$?
set -e
assert_ne "$R2_RC" '0' 'R2 installer exited non-zero on digest mismatch'
assert_matches "$WORK/r2.log" 'trust anchor digest MISMATCH' 'R2 refused for the digest-mismatch reason'
assert_absent "$REPO_DEST"    'R2 wrote no dnf repo file'
assert_absent "$KEYRING_DEST" 'R2 installed no keyring'

# =====================================================================
step 'N0  CONTROL: the genuine repo under the ADVERSARY anchor is REJECTED'
# =====================================================================
# Byte-for-byte the repository R3 installs from; only the anchor differs.
# If dnf were not checking, this would install exactly as R3 does.
# ARMOURED, like the real published anchor for rpm. A BINARY export here
# made `rpm --import` fail with "key 1 not an armored public key", and
# this step then "passed" on that import error without dnf ever having
# looked at the repository -- a rejection that proved nothing about trust.
# The adversary anchor must differ from the genuine one ONLY in whose key
# it is.
GNUPGHOME="$ADV_HOME" gpg --batch --armor --export "$ADV_FPR" > "$WORK/adversary-keyring.gpg"
[ -s "$WORK/adversary-keyring.gpg" ] || { echo 'adversary keyring empty' >&2; exit 1; }
grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$WORK/adversary-keyring.gpg" \
  || { echo 'adversary keyring is not ASCII-armoured' >&2; exit 1; }
ADV_SHA="$(sha256sum "$WORK/adversary-keyring.gpg" | awk '{print $1}')"
dnf_reset
set +e
env REPRO_BASE_URL="$BASE" \
    REPRO_KEYRING_LOCAL="$WORK/adversary-keyring.gpg" \
    REPRO_KEYRING_SHA256="$ADV_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/n0.log" 2>&1
N0_RC=$?
set -e
sed -n '1,40p' "$WORK/n0.log"
assert_ne "$N0_RC" '0' 'N0 installer exited non-zero under the adversary anchor'
assert_matches "$WORK/n0.log" \
  'not signed\|signature\|Signature\|GPG\|OpenPGP\|verification\|not available\|repomd.xml' \
  'N0 dnf refused the repository under the wrong anchor'
# The discriminator. If the installer merely failed to IMPORT the key,
# dnf never evaluated the repository and this step would be vacuous --
# which is exactly what happened the first time it was run.
N0_IMPORT_ERR="$(grep_count "$WORK/n0.log" 'not an armored public key\|rpm --import .* failed')"
assert_eq "${N0_IMPORT_ERR:-0}" '0' \
  'N0 the rejection was NOT a key-import failure (so dnf really evaluated the repo)'
assert_eq "$(installed_version)" '' 'N0 left reprobuild uninstalled'
rm -f "$REPO_DEST" "$KEYRING_DEST"
purge_reprobuild_rpm_keys
dnf_reset

# =====================================================================
step "R3  installer installs reprobuild $V1 from the dnf repository"
# =====================================================================
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/r3.log" 2>&1
R3_RC=$?
set -e
sed -n '1,70p' "$WORK/r3.log"
assert_eq "$R3_RC" '0' 'R3 installer exited 0'
assert_matches "$WORK/r3.log" 'trust anchor digest OK' 'R3 the pinned digest matched'
assert_matches "$WORK/r3.log" "$PKG" 'R3 dnf named the package in its transaction'
assert_file "$REPO_DEST"    'R3 dnf repo file written'
assert_file "$KEYRING_DEST" 'R3 trust anchor installed'
assert_file "$BIN"          'R3 the payload binary landed'
assert_eq "$(installed_version)" "$V1" "R3 rpm reports $V1 installed"
assert_eq "$(payload_version)" "reprobuild $V1" "R3 the INSTALLED PAYLOAD reports $V1"
echo "installed NEVRA: $(installed_nevra)"

# Both checks must be on. A signed repo consumed with repo_gpgcheck=0 is
# an unsigned repo.
assert_matches "$REPO_DEST" '^gpgcheck=1'      'R3 gpgcheck=1 in the emitted repo config'
assert_matches "$REPO_DEST" '^repo_gpgcheck=1' 'R3 repo_gpgcheck=1 in the emitted repo config'

# =====================================================================
step 'R4  IDEMPOTENCE: a second identical run changes nothing (measured)'
# =====================================================================
before_repo_sha="$(sha256sum "$REPO_DEST" | awk '{print $1}')"
before_keyring_sha="$(sha256sum "$KEYRING_DEST" | awk '{print $1}')"
before_version="$(installed_version)"
before_nevra="$(installed_nevra)"
before_repo_files="$(find /etc/yum.repos.d -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
before_keyrings="$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')"
before_baseurls="$(grep -c '^baseurl=' "$REPO_DEST" || true)"
before_rpmkeys="$(rpm -qa 'gpg-pubkey*' | wc -l | tr -d ' ')"

set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/r4.log" 2>&1
R4_RC=$?
set -e
assert_eq "$R4_RC" '0' 'R4 second installer run exited 0 (so "no change" is not "it crashed")'

assert_eq "$(find /etc/yum.repos.d -name '*reprobuild*' -type f | wc -l | tr -d ' ')" "$before_repo_files" 'R4 repo file count unchanged'
assert_eq "$(find /etc/yum.repos.d -name '*reprobuild*' -type f | wc -l | tr -d ' ')" '1' 'R4 exactly ONE dnf repo file'
assert_eq "$(grep -c '^baseurl=' "$REPO_DEST" || true)" "$before_baseurls" 'R4 baseurl count unchanged'
assert_eq "$(grep -c '^baseurl=' "$REPO_DEST" || true)" '1' 'R4 exactly ONE baseurl (no duplicate registration)'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')" "$before_keyrings" 'R4 keyring count unchanged'
# TWO files by design, both at FIXED paths: the binary keyring apt wants
# and the ASCII-armoured copy rpm --import requires. Idempotence is that
# the count does not GROW (asserted just above) and that there is exactly
# one of each -- not that there is only one file.
assert_eq "$(find /usr/share/keyrings -name 'reprobuild-archive-keyring.gpg' -type f | wc -l | tr -d ' ')" '1'   'R4 exactly ONE binary trust anchor'
assert_eq "$(find /usr/share/keyrings -name 'reprobuild-archive-keyring.gpg.asc' -type f | wc -l | tr -d ' ')" '1'   'R4 exactly ONE armoured trust anchor copy'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' -type f | wc -l | tr -d ' ')" '2'   'R4 exactly TWO reprobuild key files in total (binary + armoured), not more'
assert_eq "$(sha256sum "$REPO_DEST" | awk '{print $1}')" "$before_repo_sha" 'R4 repo file byte-identical'
assert_eq "$(sha256sum "$KEYRING_DEST" | awk '{print $1}')" "$before_keyring_sha" 'R4 keyring byte-identical'
assert_eq "$(installed_version)" "$before_version" 'R4 installed version unchanged'
assert_eq "$(installed_nevra)" "$before_nevra" 'R4 installed NEVRA unchanged'
# rpm --import is idempotent for the same key: the pseudo-package count
# must not grow, or every re-run would add a trusted key.
assert_eq "$(rpm -qa 'gpg-pubkey*' | wc -l | tr -d ' ')" "$before_rpmkeys" 'R4 rpm gpg-pubkey count unchanged (no duplicate key import)'
assert_matches "$WORK/r4.log" 'already installed\|Nothing to do\|nothing to do' \
  'R4 dnf itself reported there was nothing to do'

# =====================================================================
step "R5  publish $V2 ADDITIVELY; dnf then OFFERS it as an upgrade"
# =====================================================================
run_capture "$WORK/build-v2.log" sh "$BUILD_PKGS" \
  --version "$V2" --tarball "$TB2" --out "$WORK/pkgs-v2" --ecosystem rpm \
  || { echo 'build v2 failed:'; cat "$WORK/build-v2.log"; exit 1; }
RPM2="$(find "$WORK/pkgs-v2" -name "*$V2*.rpm" | head -1)"
assert_file "$RPM2" "generated $V2 .rpm"

run_capture "$WORK/publish-v2.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$PUBLISH" --version "$V2" --packages "$WORK/pkgs-v2" --key "$GOOD_FPR" \
      --ecosystem rpm --repo-root "$WORK/repo2" --target "local:$WWW" \
      --export-keyring "$KEYRING_PUB" --fetch-existing \
  || { echo 'publish v2 failed:'; cat "$WORK/publish-v2.log"; exit 1; }
sed -n '1,40p' "$WORK/publish-v2.log"
assert_eq "$(find "$WWW/rpm" -maxdepth 1 -name '*.rpm' | wc -l | tr -d ' ')" '2' \
  'R5 the published repo carries BOTH versions'

dnf_reset
run_capture "$WORK/r5-upgrades.log" "$DNF" --disablerepo='*' --enablerepo=reprobuild list --upgrades || true
cat "$WORK/r5-upgrades.log"
assert_matches "$WORK/r5-upgrades.log" "$PKG" 'R5 dnf lists reprobuild among available upgrades'
assert_matches "$WORK/r5-upgrades.log" "$V2" "R5 the upgrade entry names $V2"

# =====================================================================
step "R6  dnf upgrade MOVES the box from $V1 to $V2"
# =====================================================================
# VACUITY: this must be a TRANSITION, not a first install. $V1 is
# asserted installed immediately before, the upgrade is dnf's own generic
# `upgrade` with NO installer involvement, and $V2 is asserted after --
# in BOTH the rpm database and the installed payload.
assert_eq "$(installed_version)" "$V1" "R6 precondition: $V1 installed before the upgrade"
assert_eq "$(payload_version)" "reprobuild $V1" "R6 precondition: payload reports $V1 before the upgrade"

set +e
dnf_only upgrade >"$WORK/r6.log" 2>&1
R6_RC=$?
set -e
sed -n '1,60p' "$WORK/r6.log"
assert_eq "$R6_RC" '0' 'R6 dnf upgrade exited 0'
assert_matches "$WORK/r6.log" "$PKG" 'R6 dnf named reprobuild in the upgrade transaction'
assert_matches "$WORK/r6.log" "$V2" "R6 dnf named $V2 in the upgrade transaction"
assert_eq "$(installed_version)" "$V2" "R6 rpm now reports $V2"
assert_eq "$(payload_version)" "reprobuild $V2" "R6 the INSTALLED PAYLOAD now reports $V2"
echo "installed NEVRA after upgrade: $(installed_nevra)"

# =====================================================================
step 'R7  a TAMPERED .rpm is rejected by the SIGNED-METADATA checksum chain'
# =====================================================================
# What this step actually proves, stated precisely, because the first
# version of it claimed to prove something else.
#
# Replacing a .rpm on the mirror is caught by the sha256 recorded in the
# repodata, which is itself covered by the signature over repomd.xml. So
# this is a real rejection rooted in a signature -- the rpm analogue of
# apt's "Hash Sum mismatch" -- but it is NOT a test of gpgcheck: dnf
# never reaches the package header, because the download is discarded
# first. R7b below tests gpgcheck, and the two are kept apart because
# conflating them is how a check that never runs looks green.
#
# Same-size, in-place mutation, so a size field cannot be what fires.
TARGET_RPM="$(find "$WWW/rpm" -maxdepth 1 -name "*$V2*.rpm" | head -1)"
assert_file "$TARGET_RPM" 'R7 found the published .rpm to tamper'
cp "$TARGET_RPM" "$WORK/pristine-v2.rpm"
SIZE_BEFORE="$(wc -c < "$TARGET_RPM" | tr -d ' ')"
python3 - "$TARGET_RPM" <<'PYTAMPER'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(0, 2); n = f.tell()
    off = n - 128          # inside the compressed payload, past the header
    f.seek(off); orig = f.read(8)
    f.seek(off); f.write(bytes(b ^ 0xFF for b in orig))
print('flipped 8 bytes at', off, 'of', n)
PYTAMPER
assert_eq "$(wc -c < "$TARGET_RPM" | tr -d ' ')" "$SIZE_BEFORE" \
  'R7 the tampered .rpm has the SAME byte size (so a size field cannot be what fires)'

# rpm's own verdict on the tampered file, independent of dnf.
run_capture "$WORK/r7-rpmkv.log" rpm -Kv "$TARGET_RPM" || true
cat "$WORK/r7-rpmkv.log"
assert_matches "$WORK/r7-rpmkv.log" 'NOT OK\|BAD\|not OK\|FAILED' \
  'R7 rpm -Kv reports the tampered package as bad'

"$DNF" -y remove "$PKG" >/dev/null 2>&1 || true
dnf_reset
set +e
dnf_only install "$PKG" >"$WORK/r7.log" 2>&1
R7_RC=$?
set -e
sed -n '1,50p' "$WORK/r7.log"
assert_ne "$R7_RC" '0' 'R7 dnf install exited non-zero on the tampered .rpm'
assert_matches "$WORK/r7.log" 'checksum\|Mismatch\|mismatch' \
  'R7 dnf reported a checksum mismatch against the signed metadata'
assert_eq "$(installed_version)" '' 'R7 nothing was installed from the tampered .rpm'
cp "$WORK/pristine-v2.rpm" "$TARGET_RPM"
dnf_reset

# =====================================================================
step 'R7b an UNSIGNED .rpm with VALID signed metadata is rejected (gpgcheck)'
# =====================================================================
# THIS is the gpgcheck test. The package's header signature is stripped,
# then the metadata is regenerated over the stripped package and
# repomd.xml is re-signed with the GOOD key -- so the repodata checksum
# MATCHES and repo_gpgcheck PASSES. Every check except gpgcheck is
# therefore satisfied, and a rejection can only come from the package
# header signature.
#
# The metadata is regenerated with createrepo_c + gpg directly rather
# than with repro-sign-rpm-repo.sh, because that script also runs
# `rpmsign --addsign` over the packages and would put the signature we
# just removed straight back -- turning this into a test of nothing.
cp "$WORK/pristine-v2.rpm" "$WORK/unsigned-v2.rpm"
run_capture "$WORK/r7b-delsign.log" rpmsign --delsign "$WORK/unsigned-v2.rpm" \
  || { echo 'rpmsign --delsign failed:'; cat "$WORK/r7b-delsign.log"; }
# Prove the signature really is gone, or the rest of this step is vacuous.
run_capture "$WORK/r7b-kv-before.log" rpm -Kv "$WORK/unsigned-v2.rpm" || true
cat "$WORK/r7b-kv-before.log"
R7B_SIGLINES="$(grep_count "$WORK/r7b-kv-before.log" 'Signature, key ID\|signature, key ID')"
assert_eq "${R7B_SIGLINES:-0}" '0' 'R7b the stripped package carries NO header signature'
# ...and that it is otherwise INTACT (digests still verify), so the only
# defect is the missing signature.
assert_matches "$WORK/r7b-kv-before.log" 'digests OK\|Digests OK\|DIGESTS\|OK' \
  'R7b the stripped package is otherwise intact (digests still verify)'

cp "$WORK/unsigned-v2.rpm" "$TARGET_RPM"
if ! run_capture "$WORK/r7b-createrepo.log" createrepo_c --update "$WWW/rpm"; then
  run_capture "$WORK/r7b-createrepo.log" createrepo_c "$WWW/rpm" \
    || { echo 'createrepo_c failed:'; cat "$WORK/r7b-createrepo.log"; }
fi
rm -f "$WWW/rpm/repodata/repomd.xml.asc"
run_capture "$WORK/r7b-sign.log" env GNUPGHOME="$GOOD_HOME" \
  gpg --batch --yes --armor --detach-sign --local-user "$GOOD_FPR" \
      -o "$WWW/rpm/repodata/repomd.xml.asc" "$WWW/rpm/repodata/repomd.xml" \
  || { echo 'repomd re-sign failed:'; cat "$WORK/r7b-sign.log"; }
assert_file "$WWW/rpm/repodata/repomd.xml.asc" 'R7b repomd.xml is signed again with the GOOD key'

"$DNF" -y remove "$PKG" >/dev/null 2>&1 || true
dnf_reset
set +e
dnf_only install "$PKG" >"$WORK/r7b.log" 2>&1
R7B_RC=$?
set -e
sed -n '1,60p' "$WORK/r7b.log"
assert_ne "$R7B_RC" '0' 'R7b dnf install exited non-zero on the unsigned package'
assert_matches "$WORK/r7b.log" \
  'not signed\|NOT signed\|GPG\|OpenPGP\|signature\|Signature' \
  'R7b dnf/rpm reported a PACKAGE SIGNATURE failure'
# The discriminator: if dnf had complained about a checksum, the metadata
# regeneration failed and gpgcheck was never consulted -- which is
# precisely the false green this step was rewritten to avoid.
R7B_CKSUM="$(grep_count "$WORK/r7b.log" 'checksum')"
assert_eq "${R7B_CKSUM:-0}" '0' \
  'R7b dnf did NOT complain about a checksum (so gpgcheck, not the hash chain, rejected it)'
assert_eq "$(installed_version)" '' 'R7b nothing was installed from the unsigned .rpm'

# Restore a fully genuine, fully signed repository for R8/R9.
cp "$WORK/pristine-v2.rpm" "$TARGET_RPM"
run_capture "$WORK/r7-restore.log" env \
  GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-rpm-repo.sh" --root "$WWW/rpm" --key "$GOOD_FPR" --id reprobuild \
  || { echo 'restore re-sign failed:'; tail -20 "$WORK/r7-restore.log"; }
dnf_reset

# =====================================================================
step 'R8  a TAMPERED repomd.xml is rejected (repo_gpgcheck, on metadata)'
# =====================================================================
# The signature armour is left byte-for-byte intact and the BODY is
# modified, so this is a real signature verification failure rather than
# a parser complaint about a malformed packet. (The apt arm's A8b
# documents why that distinction is load-bearing.)
REPOMD="$WWW/rpm/repodata/repomd.xml"
cp "$REPOMD" "$WORK/pristine.repomd.xml"
cp "$WWW/rpm/repodata/repomd.xml.asc" "$WORK/pristine.repomd.xml.asc"
python3 - "$REPOMD" <<'PY'
import sys, re
p = sys.argv[1]
d = open(p, 'rb').read()
m = None
for cand in re.finditer(rb'<checksum type="sha256">([0-9a-f]{64})</checksum>', d):
    m = cand
    break
assert m, 'no sha256 checksum element found in repomd.xml'
s, e = m.start(1), m.end(1)
old = d[s:e]
new = (b'1' if old[0:1] == b'0' else b'0') + old[1:]
out = d[:s] + new + d[e:]
assert len(out) == len(d)
open(p, 'wb').write(out)
print('changed one hex digit of a sha256 in repomd.xml (signature left untouched):')
print('  ', old.decode(), '->', new.decode())
PY
assert_eq "$(wc -c < "$REPOMD" | tr -d ' ')" "$(wc -c < "$WORK/pristine.repomd.xml" | tr -d ' ')" \
  'R8 the tampered repomd.xml has the SAME byte size'
assert_eq "$(sha256sum "$WWW/rpm/repodata/repomd.xml.asc" | awk '{print $1}')" \
          "$(sha256sum "$WORK/pristine.repomd.xml.asc" | awk '{print $1}')" \
          'R8 the detached signature is byte-identical (so this is not a parse failure)'

"$DNF" -y remove "$PKG" >/dev/null 2>&1 || true
dnf_reset
set +e
dnf_only install "$PKG" >"$WORK/r8.log" 2>&1
R8_RC=$?
set -e
sed -n '1,50p' "$WORK/r8.log"
assert_ne "$R8_RC" '0' 'R8 dnf exited non-zero on the tampered repomd.xml'
assert_matches "$WORK/r8.log" \
  'repomd\|signature\|Signature\|GPG\|OpenPGP\|verification\|not signed\|BAD' \
  'R8 dnf reported a metadata signature failure'
assert_eq "$(installed_version)" '' 'R8 nothing was installed from the tampered-metadata repo'
cp "$WORK/pristine.repomd.xml" "$REPOMD"
cp "$WORK/pristine.repomd.xml.asc" "$WWW/rpm/repodata/repomd.xml.asc"
dnf_reset

# =====================================================================
step 'R9  --uninstall leaves NO trace'
# =====================================================================
set +e
env REPRO_BASE_URL="$BASE" REPRO_KEYRING_SHA256="$ANCHOR_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/r9-install.log" 2>&1
R9I_RC=$?
set -e
assert_eq "$R9I_RC" '0' 'R9 precondition: reinstall succeeded'
assert_eq "$(installed_version)" "$V2" "R9 precondition: $V2 is installed"
assert_file "$REPO_DEST"    'R9 precondition: the dnf repo file exists'
assert_file "$KEYRING_DEST" 'R9 precondition: the keyring exists'
assert_file "$BIN"          'R9 precondition: the binary exists'

set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method dnf --uninstall >"$WORK/r9.log" 2>&1
R9_RC=$?
set -e
sed -n '1,40p' "$WORK/r9.log"
assert_eq "$R9_RC" '0' 'R9 uninstaller exited 0'
assert_matches "$WORK/r9.log" "$PKG\|Removing\|remove" 'R9 dnf itself reported removing the package'
assert_eq "$(installed_version)" '' 'R9 rpm no longer reports the package'
assert_absent "$REPO_DEST"    'R9 the dnf repo registration'
assert_absent "$KEYRING_DEST" 'R9 the trust anchor'
assert_absent "$BIN"          'R9 the installed binary'
assert_eq "$(find /etc/yum.repos.d -name '*reprobuild*' | wc -l | tr -d ' ')" '0' \
  'R9 no reprobuild file left under /etc/yum.repos.d'
assert_eq "$(find /usr/share/keyrings -name '*reprobuild*' | wc -l | tr -d ' ')" '0' \
  'R9 no reprobuild keyring left under /usr/share/keyrings'
# The imported rpm key must go too: an "uninstalled" box that still
# trusts our signing key is not what a user who uninstalled asked for.
LEFT_KEYS="$(rpm -qa 'gpg-pubkey*' 2>/dev/null | while read -r k; do rpm -qi "$k" 2>/dev/null | grep -qi 'UNTRUSTED TEST KEY' && echo x; done | wc -l | tr -d ' ')"
assert_eq "$LEFT_KEYS" '0' 'R9 the imported rpm signing key was removed too'

set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method dnf --uninstall >"$WORK/r9b.log" 2>&1
R9B_RC=$?
set -e
assert_eq "$R9B_RC" '0' 'R9 a SECOND uninstall is a no-op, not an error'

# =====================================================================
step 'N1  CONTROL+PROOF: a BINARY trust anchor is normalised for rpm --import'
# =====================================================================
# N53. `armour_keyring_to` in the installer converts a binary keyring to
# ASCII armour because `rpm --import` reads ONLY armour. Until this step
# NO arm drove that conversion: every anchor this arm hands the installer
# is ALREADY armoured -- `repro-publish-repos.sh --export-keyring` emits
# armour on the rpm path, and N0's adversary anchor is deliberately
# armoured -- so `armour_keyring_to` took its `cp` fast path in every gate
# run. The product fix that the inert-control discovery produced was
# therefore itself untested: the discovery hardened the test AND the
# product, and only the test half had a test.
#
# The anchor below is a GENUINELY BINARY export of the SAME good key --
# `gpg --export` with no `--armor`, which is exactly what M2's apt signer
# emits and what a publisher who only ever served apt would put on the
# keys host. Both halves are asserted, negative control FIRST:
#
#   * WITHOUT the conversion (the format test short-circuited to the `cp`
#     fast path in a copy of the installer) the run DIES with rpm's own
#     "key 1 not an armored public key";
#   * WITH it the same binary anchor installs, and the two files at the
#     two fixed paths are the binary bytes and the armour respectively.
#
# WHAT WOULD MAKE THIS VACUOUS, and how each is ruled out:
#   (a) the fixture being armoured after all -- then the `cp` fast path is
#       taken and every assertion below passes with the conversion
#       deleted. Ruled out by asserting the fixture has NO armour header
#       and starts with OpenPGP packet tag 0x99.
#   (b) the mutant failing for some unrelated reason (a broken sed, a
#       digest mismatch, a dead HTTP server) -- then "it fails without the
#       conversion" proves nothing. Ruled out by `sh -n` on the mutant, by
#       asserting the mutation touched EXACTLY one line, by asserting the
#       mutant got as far as "trust anchor digest OK", and by requiring
#       rpm's exact message rather than merely a non-zero exit.
#   (c) the positive run passing while still taking the `cp` fast path --
#       ruled out by requiring the "re-encoded as ASCII armour" log line
#       AND by asserting the .asc digest DIFFERS from the binary input's.

BIN_KR="$WORK/binary-keyring.gpg"
GNUPGHOME="$GOOD_HOME" gpg --batch --export "$GOOD_FPR" > "$BIN_KR"
[ -s "$BIN_KR" ] || { echo 'N1 fixture: binary keyring export is empty' >&2; exit 1; }
head -c 64 "$BIN_KR" > "$WORK/binary-keyring.head"
assert_eq "$(LC_ALL=C grep -a -c 'BEGIN PGP PUBLIC KEY BLOCK' "$WORK/binary-keyring.head" || true)" '0' \
  'N1 fixture: the anchor carries NO armour header (so the cp fast path CANNOT be taken)'
assert_eq "$(od -An -tx1 -N1 "$BIN_KR" | tr -d ' \n')" '99' \
  'N1 fixture: the anchor starts with OpenPGP tag 0x99 (a binary public-key packet)'
BIN_SHA="$(sha256sum "$BIN_KR" | awk '{print $1}')"
echo "binary anchor sha256 = $BIN_SHA ($(wc -c < "$BIN_KR") bytes)"

# --- negative control FIRST: the same run with the conversion removed ---
MUT="$WORK/repro-install-no-armour.sh"
sed "s@^  if head -c 64 .*BEGIN PGP PUBLIC KEY BLOCK.*then\$@  if true; then  # N53-MUTATION format test short-circuited to the cp fast path@" \
  "$INSTALL_SH" > "$MUT"
assert_eq "$(grep_count "$MUT" 'N53-MUTATION')" '1' \
  'N1 control: the mutation applied to exactly ONE line'
assert_eq "$(diff "$INSTALL_SH" "$MUT" | grep -c '^[<>]' || true)" '2' \
  'N1 control: the mutant differs from the installer in exactly one line (one < and one >)'
if sh -n "$MUT" 2>"$WORK/n1-mutant-syntax.log"; then
  ok 'N1 control: the mutant is still a syntactically valid shell script'
else
  bad "N1 control: the mutant does not parse: $(cat "$WORK/n1-mutant-syntax.log")"
fi

"$DNF" -y remove "$PKG" >/dev/null 2>&1 || true
rm -f "$REPO_DEST" "$KEYRING_DEST" "$KEYRING_DEST.asc"
purge_reprobuild_rpm_keys
dnf_reset
set +e
env REPRO_BASE_URL="$BASE" \
    REPRO_KEYRING_LOCAL="$BIN_KR" \
    REPRO_KEYRING_SHA256="$BIN_SHA" \
  sh "$MUT" --method dnf >"$WORK/n1-control.log" 2>&1
N1C_RC=$?
set -e
sed -n '1,40p' "$WORK/n1-control.log"
assert_ne "$N1C_RC" '0' 'N1 control: WITHOUT the conversion the installer exits non-zero'
assert_matches "$WORK/n1-control.log" 'trust anchor digest OK' \
  'N1 control: it got PAST verification (so the failure below is not a digest refusal)'
assert_eq "$(grep_count "$WORK/n1-control.log" 're-encoded as ASCII armour')" '0' \
  'N1 control: the mutant did NOT re-encode (the conversion really is disabled)'
assert_matches "$WORK/n1-control.log" 'key 1 not an armored public key' \
  "N1 control: it dies with rpm's own 'key 1 not an armored public key'"
assert_eq "$(sha256sum "$KEYRING_DEST.asc" 2>/dev/null | awk '{print $1}')" "$BIN_SHA" \
  'N1 control: the mutant put the BINARY bytes at the rpm path -- which is WHY rpm refused'
assert_eq "$(installed_version)" '' 'N1 control: nothing was installed'

# --- and now the real installer, same binary anchor, same repository ---
rm -f "$REPO_DEST" "$KEYRING_DEST" "$KEYRING_DEST.asc"
purge_reprobuild_rpm_keys
dnf_reset
set +e
env REPRO_BASE_URL="$BASE" \
    REPRO_KEYRING_LOCAL="$BIN_KR" \
    REPRO_KEYRING_SHA256="$BIN_SHA" \
  sh "$INSTALL_SH" --method dnf >"$WORK/n1.log" 2>&1
N1_RC=$?
set -e
sed -n '1,50p' "$WORK/n1.log"
assert_eq "$N1_RC" '0' 'N1 the installer SUCCEEDS with a binary trust anchor'
assert_matches "$WORK/n1.log" 're-encoded as ASCII armour' \
  'N1 the installer reported re-encoding the anchor (the conversion ran, not the cp fast path)'
assert_eq "$(grep_count "$WORK/n1.log" 'not an armored public key')" '0' \
  'N1 rpm --import did not report an unarmoured key'
assert_file "$KEYRING_DEST"     'N1 the binary anchor at the apt-shaped fixed path'
assert_file "$KEYRING_DEST.asc" 'N1 the armoured copy at the rpm-shaped fixed path'
assert_eq "$(sha256sum "$KEYRING_DEST" | awk '{print $1}')" "$BIN_SHA" \
  'N1 the installed anchor is byte-identical to the BINARY input (apt still gets binary)'
assert_matches "$KEYRING_DEST.asc" 'BEGIN PGP PUBLIC KEY BLOCK' \
  'N1 the rpm copy is ASCII armour'
assert_ne "$(sha256sum "$KEYRING_DEST.asc" | awk '{print $1}')" "$BIN_SHA" \
  'N1 the armoured copy is a re-encoding, not a copy of the binary file'
assert_eq "$(installed_version)" "$V2" "N1 dnf installed $V2 under the binary anchor"
assert_eq "$(payload_version)" "reprobuild $V2" "N1 the INSTALLED PAYLOAD reports $V2"
N1_KEYS="$(rpm -qa 'gpg-pubkey*' 2>/dev/null | while read -r k; do rpm -qi "$k" 2>/dev/null | grep -qi 'UNTRUSTED TEST KEY' && echo x; done | wc -l | tr -d ' ')"
assert_eq "$N1_KEYS" '1' 'N1 rpm --import really imported the CONVERTED key'

set +e
env REPRO_BASE_URL="$BASE" sh "$INSTALL_SH" --method dnf --uninstall >"$WORK/n1-uninstall.log" 2>&1
N1U_RC=$?
set -e
assert_eq "$N1U_RC" '0' 'N1 the box is returned to the uninstalled state'
assert_absent "$KEYRING_DEST"     'N1 teardown: the binary anchor'
assert_absent "$KEYRING_DEST.asc" 'N1 teardown: the armoured copy'
# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------
printf 'm3_install_dnf: %d checks, %d failure(s)\n' "$checks" "$fails"
[ "$fails" -eq 0 ] || exit 1
exit 0
