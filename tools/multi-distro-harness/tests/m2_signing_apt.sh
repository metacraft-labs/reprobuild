#!/bin/sh
# M2 SIGNING gate, apt arm. Runs inside repro-debian / repro-ubuntu.
#
#   scripts/run_multi_distro_tests.sh m2_signing_apt ubuntu
#
# Proves, with apt's own messages and apt's own exit codes:
#
#   G1  a genuine signed repository installs
#   G2  a tampered ARTIFACT is rejected by apt
#   G3  a tampered REPOSITORY INDEX is rejected by apt (both a tampered
#       Packages file and a tampered InRelease signature)
#   G4  the installer's pre-install verification accepts the genuine
#       bundle and rejects both tampers
#
# and, as the control that makes G1 mean anything:
#
#   N0  the SAME genuine repository is REJECTED when the trust anchor is
#       a different key. Without this, G1 would also pass against an
#       unsigned repository, or against apt not checking at all.
#
# Every rejection below is asserted three ways: a non-zero exit from the
# package manager, a non-zero count of lines matching the manager's own
# diagnostic, and (for installs) the absence of the installed file. A
# grep that matches zero lines is a vacuous pass, so the counts are
# compared to numbers, never tested for truthiness.

set -eu

# `env VAR=x apt_only ...` cannot work: env execs a BINARY, and
# apt_only is a shell function. The first hermetic version of this
# file did exactly that and produced an empty log with a non-zero
# exit, which read as "apt rejected it" in one step and as a plain
# failure in another. Set the variable once, for the whole script.
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# The repo root is derived from THIS script's location, not hardcoded:
# scripts/run_multi_distro_tests.sh execs the test by absolute path and
# passes no environment, and the checkout is not always at the same
# place (a git worktree is not the main checkout). $REPRO_REPO_ROOT
# still overrides, for running the arm by hand.
REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
WORK="${REPRO_M2_WORK:-/tmp/m2-signing-apt}"
PKG=repro-m2-probe
VER=1.0
MARKER=/usr/share/repro-m2-probe/marker.txt

fails=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# rc of a command, captured in a script file (never an inline $? read
# across a wsl.exe boundary), with its output kept for the report.
run_capture() {
  _out="$1"; shift
  set +e
  "$@" > "$_out" 2>&1
  _rc=$?
  set -e
  return $_rc
}

# Assert that $2 appears at least once in file $1, and say how often.
grep_count() {
  _file="$1"; _pat="$2"
  grep -c -- "$_pat" "$_file" 2>/dev/null || true
}
assert_matches() {
  _file="$1"; _pat="$2"; _what="$3"
  _n="$(grep_count "$_file" "$_pat")"
  if [ "${_n:-0}" -ge 1 ]; then
    ok "$_what (matched $_n line(s) on '$_pat')"
  else
    bad "$_what: pattern '$_pat' matched 0 lines in $_file"
    printf '%s\n' "vvv $_file vvv"; cat "$_file"; printf '%s\n' '^^^ end ^^^'
  fi
}

# ---------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------

[ -r /etc/os-release ] || { echo 'no /etc/os-release'; exit 1; }
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) echo "m2_signing_apt: expected debian|ubuntu, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root'; exit 1; }
[ -d "$SIGN_DIR" ] || { echo "signing scripts not found at $SIGN_DIR" >&2; exit 1; }

need_install=''
for t in dpkg-scanpackages apt-ftparchive gpg; do
  command -v "$t" >/dev/null 2>&1 || need_install="$need_install $t"
done
if [ -n "$need_install" ]; then
  echo "installing prerequisites for:$need_install"
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dpkg-dev apt-utils gnupg >/dev/null 2>&1 || true
fi
for t in dpkg-scanpackages apt-ftparchive gpg dpkg-deb; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
ARCH="$(dpkg --print-architecture)"
echo "arch=$ARCH  apt=$(apt-get --version | head -1)"

rm -rf "$WORK"
mkdir -p "$WORK"

# ---------------------------------------------------------------------
step 'generate the throwaway signing key and an adversary key'
# ---------------------------------------------------------------------

GOOD_HOME="$WORK/gnupg-good"
ADV_HOME="$WORK/gnupg-adversary"
GOOD_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$GOOD_HOME")"
ADV_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$ADV_HOME")"
[ -n "$GOOD_FPR" ] || { echo 'no signing key'; exit 1; }
[ -n "$ADV_FPR" ] || { echo 'no adversary key'; exit 1; }
[ "$GOOD_FPR" != "$ADV_FPR" ] || { echo 'the two throwaway keys collided'; exit 1; }
echo "signing  key: $GOOD_FPR"
echo "adversary key: $ADV_FPR"

# ---------------------------------------------------------------------
step 'build a minimal .deb'
# ---------------------------------------------------------------------

STAGE="$WORK/stage"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/share/$PKG"
printf 'reprobuild m2 signing probe\n' > "$STAGE/usr/share/$PKG/marker.txt"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VER
Section: devel
Priority: optional
Architecture: $ARCH
Maintainer: Reprobuild Gate <m2-gate-test@reprobuild.invalid>
Description: M2 signing gate probe
 A single file, so that "did it install" is a one-line question.
CONTROL
mkdir -p "$WORK/repo/pool/main"
dpkg-deb --build --root-owner-group "$STAGE" \
  "$WORK/repo/pool/main/${PKG}_${VER}_${ARCH}.deb" >/dev/null
DEB="$WORK/repo/pool/main/${PKG}_${VER}_${ARCH}.deb"
[ -f "$DEB" ] || { echo 'dpkg-deb produced nothing'; exit 1; }
cp "$DEB" "$WORK/pristine.deb"

# ---------------------------------------------------------------------
step 'sign the repository'
# ---------------------------------------------------------------------

KEYRING=/usr/share/keyrings/reprobuild-gate-test.gpg
ADV_KEYRING=/usr/share/keyrings/reprobuild-gate-adversary.gpg
mkdir -p /usr/share/keyrings

GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-apt-repo.sh" \
     --root "$WORK/repo" --key "$GOOD_FPR" \
     --suite stable --component main --arch "$ARCH" \
     --export-key "$KEYRING"

GNUPGHOME="$ADV_HOME" gpg --batch --export "$ADV_FPR" > "$ADV_KEYRING"
[ -s "$ADV_KEYRING" ] || { echo 'adversary keyring empty'; exit 1; }

cp "$WORK/repo/dists/stable/InRelease"   "$WORK/pristine.InRelease"
cp "$WORK/repo/dists/stable/Release"     "$WORK/pristine.Release"
cp "$WORK/repo/dists/stable/Release.gpg" "$WORK/pristine.Release.gpg"
cp "$WORK/repo/dists/stable/main/binary-$ARCH/Packages" "$WORK/pristine.Packages"
cp "$WORK/repo/dists/stable/main/binary-$ARCH/Packages.gz" "$WORK/pristine.Packages.gz"

SOURCES=/etc/apt/sources.list.d/reprobuild-gate.sources
write_sources() {
  cat > "$SOURCES" <<SRC
Types: deb
URIs: file://$WORK/repo
Suites: stable
Components: main
Architectures: $ARCH
Signed-By: $1
SRC
}

# Every apt invocation is restricted to OUR sources file. Not for speed
# (though it saves ~300 MB of Contents downloads per phase): with the
# distro's own repositories in scope, a flaky mirror produces the same
# non-zero exit as a rejected signature, and the gate would report a
# green rejection for the wrong reason.
apt_only() {
  apt-get -o Dir::Etc::sourcelist="$SOURCES"           -o Dir::Etc::sourceparts='-'           -o APT::Get::List-Cleanup='0' "$@"
}

apt_reset() {
  rm -rf /var/lib/apt/lists
  mkdir -p /var/lib/apt/lists/partial
  apt-get clean >/dev/null 2>&1 || true
}

restore_repo() {
  cp "$WORK/pristine.deb" "$DEB"
  cp "$WORK/pristine.InRelease"   "$WORK/repo/dists/stable/InRelease"
  cp "$WORK/pristine.Release"     "$WORK/repo/dists/stable/Release"
  cp "$WORK/pristine.Release.gpg" "$WORK/repo/dists/stable/Release.gpg"
  cp "$WORK/pristine.Packages"    "$WORK/repo/dists/stable/main/binary-$ARCH/Packages"
  cp "$WORK/pristine.Packages.gz" "$WORK/repo/dists/stable/main/binary-$ARCH/Packages.gz"
}

purge_pkg() {
  dpkg --purge "$PKG" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$MARKER")"
}

# ---------------------------------------------------------------------
step 'N0 CONTROL - the genuine repo under the WRONG trust anchor'
# ---------------------------------------------------------------------
#
# This runs BEFORE G1 on purpose: if apt accepted this, every later
# "accepted" result would be meaningless.

restore_repo; purge_pkg; apt_reset
write_sources "$ADV_KEYRING"
if run_capture "$WORK/n0.log" apt_only update; then
  bad 'N0: apt-get update SUCCEEDED against a repo signed by a key the client does not trust'
  cat "$WORK/n0.log"
else
  ok "N0: apt-get update failed as required"
  assert_matches "$WORK/n0.log" 'NO_PUBKEY\|not signed\|no valid OpenPGP\|following signatures.*invalid\|couldn.t be verified' \
    'N0: apt named the signature problem'
fi

# ---------------------------------------------------------------------
step 'G1 - genuine repository, correct trust anchor'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; apt_reset
write_sources "$KEYRING"
if run_capture "$WORK/g1-update.log" apt_only update; then
  ok 'G1: apt-get update accepted the signed repository'
else
  bad 'G1: apt-get update rejected the GENUINE repository'
  cat "$WORK/g1-update.log"
fi
if run_capture "$WORK/g1-install.log" \
     apt_only install -y "$PKG"; then
  if [ -f "$MARKER" ]; then
    ok 'G1: genuine package installed and its file is on disk'
  else
    bad 'G1: apt reported success but the package file is absent'
  fi
else
  bad 'G1: apt-get install rejected the genuine package'
  cat "$WORK/g1-install.log"
fi

# ---------------------------------------------------------------------
step 'G2 - tampered ARTIFACT'
# ---------------------------------------------------------------------
#
# The index stays genuine and signed; only the .deb's bytes change. apt
# must catch this through the signed index's SHA256 over the pool file.

restore_repo; purge_pkg; apt_reset
write_sources "$KEYRING"
run_capture "$WORK/g2-update.log" apt_only update || true
# Append a byte. The file stays a valid ar archive, so any rejection
# comes from the hash chain and not from dpkg failing to parse it.
printf 'TAMPER' >> "$DEB"
if run_capture "$WORK/g2-install.log" \
     apt_only install -y "$PKG"; then
  bad 'G2: apt INSTALLED a tampered .deb'
  cat "$WORK/g2-install.log"
else
  ok 'G2: apt-get install failed on the tampered .deb'
  assert_matches "$WORK/g2-install.log" 'Hash Sum mismatch\|Size mismatch\|mismatch' \
    'G2: apt named the integrity failure'
  if [ -f "$MARKER" ]; then
    bad 'G2: the tampered package left its file installed anyway'
  else
    ok 'G2: nothing was installed'
  fi
fi

# ---------------------------------------------------------------------
step 'G3a - tampered repository INDEX (Packages), signature untouched'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; apt_reset
write_sources "$KEYRING"
P="$WORK/repo/dists/stable/main/binary-$ARCH/Packages"
sed -i 's/^Description: M2 signing gate probe/Description: M2 signing gate pwned/' "$P"
gzip -9nc "$P" > "$P.gz"
if run_capture "$WORK/g3a.log" apt_only update; then
  bad 'G3a: apt-get update ACCEPTED a Packages file the signed Release does not cover'
  cat "$WORK/g3a.log"
else
  ok 'G3a: apt-get update failed on the tampered index'
  assert_matches "$WORK/g3a.log" 'Hash Sum mismatch\|Size mismatch\|mismatch' \
    'G3a: apt named the index integrity failure'
fi

# ---------------------------------------------------------------------
step 'G3b - tampered SIGNED index (InRelease body edited)'
# ---------------------------------------------------------------------
#
# Here the attacker rewrites the signed document itself, keeping the old
# signature block. Only the signature check can catch this.

restore_repo; purge_pkg; apt_reset
write_sources "$KEYRING"
IR="$WORK/repo/dists/stable/InRelease"
sed -i 's/^Origin: Reprobuild$/Origin: Reprobuilt/' "$IR"
# Release.gpg + Release would still be genuine and apt would fall back
# to them, which would be a real-world-correct outcome but not the
# thing under test here -- so break the pair the same way.
sed -i 's/^Origin: Reprobuild$/Origin: Reprobuilt/' "$WORK/repo/dists/stable/Release"
if run_capture "$WORK/g3b.log" apt_only update; then
  bad 'G3b: apt-get update ACCEPTED an InRelease whose body was edited after signing'
  cat "$WORK/g3b.log"
else
  ok 'G3b: apt-get update failed on the edited InRelease'
  assert_matches "$WORK/g3b.log" 'BADSIG\|signatures.*invalid\|not signed\|no valid OpenPGP\|couldn.t be verified\|clearsigned file isn' \
    'G3b: apt named the signature failure'
fi

restore_repo; purge_pkg; apt_reset

# ---------------------------------------------------------------------
step 'G4 - the installer pre-install verification'
# ---------------------------------------------------------------------

DL="$WORK/download"
rm -rf "$DL"; mkdir -p "$DL"
cp "$WORK/pristine.deb" "$DL/${PKG}_${VER}_${ARCH}.deb"
tar -C "$STAGE/usr/share" -czf "$DL/reprobuild-${ARCH}-linux.tar.gz" "$PKG"

GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-release.sh" --dir "$DL" --key "$GOOD_FPR"

cp -a "$DL" "$WORK/download-pristine"

VERIFY="$SIGN_DIR/repro-verify-release.sh"

# G4a: genuine bundle accepted.
if run_capture "$WORK/g4a.log" sh "$VERIFY" --keyring "$KEYRING" \
     --dir "$DL" --allow-test-key --require-all; then
  ok 'G4a: pre-install verification ACCEPTED the genuine bundle'
  assert_matches "$WORK/g4a.log" 'ACCEPTED' 'G4a: verifier said ACCEPTED'
else
  bad 'G4a: pre-install verification rejected the GENUINE bundle'
  cat "$WORK/g4a.log"
fi

# G4b: tampered artifact rejected.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
printf 'TAMPER' >> "$DL/${PKG}_${VER}_${ARCH}.deb"
if run_capture "$WORK/g4b.log" sh "$VERIFY" --keyring "$KEYRING" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4b: pre-install verification ACCEPTED a tampered artifact'
  cat "$WORK/g4b.log"
else
  ok 'G4b: pre-install verification rejected the tampered artifact'
  assert_matches "$WORK/g4b.log" 'digest mismatch' 'G4b: verifier named the digest mismatch'
fi

# G4c: tampered manifest (the artifact-bundle analogue of a repo index)
# rejected -- the attacker updates SHA256SUMS to match the tampered
# bytes, which is what makes this a test of the SIGNATURE.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
printf 'TAMPER' >> "$DL/${PKG}_${VER}_${ARCH}.deb"
( cd "$DL" && sha256sum "${PKG}_${VER}_${ARCH}.deb" "reprobuild-${ARCH}-linux.tar.gz" > SHA256SUMS )
if run_capture "$WORK/g4c.log" sh "$VERIFY" --keyring "$KEYRING" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4c: pre-install verification ACCEPTED a re-hashed, re-written manifest'
  cat "$WORK/g4c.log"
else
  ok 'G4c: pre-install verification rejected the rewritten manifest'
  assert_matches "$WORK/g4c.log" 'not valid\|VALIDSIG' 'G4c: verifier named the manifest signature failure'
fi

# G4d: CONTROL - the genuine bundle under the adversary keyring must
# also be rejected. Without this, G4a would pass for a verifier that
# never looks at the keyring at all.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
if run_capture "$WORK/g4d.log" sh "$VERIFY" --keyring "$ADV_KEYRING" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4d: pre-install verification ACCEPTED a bundle signed by an untrusted key'
  cat "$WORK/g4d.log"
else
  ok 'G4d: pre-install verification rejected the untrusted signer'
  assert_matches "$WORK/g4d.log" 'not valid\|REJECTED' 'G4d: verifier named the trust failure'
fi

# G4e: CONTROL - a test-signed bundle without --allow-test-key must be
# rejected, so a throwaway key can never masquerade as a release key.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
if run_capture "$WORK/g4e.log" sh "$VERIFY" --keyring "$KEYRING" \
     --dir "$DL" --require-all; then
  bad 'G4e: a TEST-key bundle verified as if it were a release'
  cat "$WORK/g4e.log"
else
  ok 'G4e: a TEST-key bundle is refused without --allow-test-key'
  assert_matches "$WORK/g4e.log" 'TEST KEY\|test key' 'G4e: verifier named the test key'
fi

# G4f: CONTROL - a missing signature must be a REJECTION, not a skip.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
rm -f "$DL/SHA256SUMS.asc"
if run_capture "$WORK/g4f.log" sh "$VERIFY" --keyring "$KEYRING" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4f: verification passed with NO manifest signature present'
  cat "$WORK/g4f.log"
else
  ok 'G4f: a missing manifest signature is a rejection'
  assert_matches "$WORK/g4f.log" 'SHA256SUMS.asc missing' 'G4f: verifier named the missing signature'
fi

# G4g: CONTROL - no gpg on PATH must be a REJECTION, not a skip.
rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
if run_capture "$WORK/g4g.log" env PATH=/nonexistent-for-gate REPRO_GPG_BIN= \
     /bin/sh "$VERIFY" --keyring "$KEYRING" --dir "$DL" --allow-test-key --require-all; then
  bad 'G4g: verification passed with no gpg available'
  cat "$WORK/g4g.log"
else
  ok 'G4g: absence of gpg is a rejection'
fi

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------

purge_pkg
rm -f "$SOURCES"
apt_reset

printf '\n### captured package-manager output ###\n'
for f in n0 g1-update g1-install g2-install g3a g3b; do
  printf '\n%s\n' "----- $f.log -----"
  sed -n '1,40p' "$WORK/$f.log" 2>/dev/null || true
done

if [ "$fails" -eq 0 ]; then
  echo
  echo 'm2_signing_apt: ALL CHECKS PASSED'
  exit 0
fi
echo
echo "m2_signing_apt: $fails CHECK(S) FAILED"
exit 1
