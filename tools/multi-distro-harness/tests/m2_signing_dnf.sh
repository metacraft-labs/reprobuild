#!/bin/sh
# M2 SIGNING gate, rpm/dnf arm. Runs inside repro-fedora.
#
#   scripts/run_multi_distro_tests.sh m2_signing_dnf fedora
#
# Proves, with dnf's and rpm's own messages and exit codes:
#
#   G1   a genuine signed repository installs
#   G2a  a tampered ARTIFACT (rpm bytes edited) is rejected
#   G2b  an rpm whose HEADER SIGNATURE is by an untrusted key is
#        rejected even though the repository metadata is genuine and
#        correctly signed -- the check `gpgcheck=1` exists for, which
#        `repo_gpgcheck=1` cannot make
#   G3   a tampered REPOSITORY INDEX (repomd.xml edited after signing)
#        is rejected -- the check `repo_gpgcheck=1` exists for, which
#        `gpgcheck=1` cannot make
#   G4   the installer's pre-install verification accepts the genuine
#        bundle and rejects the tampers
#   N0   CONTROL: the same genuine repository is REJECTED when the
#        client's trust anchor is a different key
#
# G2b and G3 together are why this arm is not simply the apt arm with
# different verbs: rpm's two checks are independent, and a repository
# that passes one and not the other is a repository whose signature
# proves less than it looks like it proves.

set -eu

# The repo root is derived from THIS script's location, not hardcoded:
# scripts/run_multi_distro_tests.sh execs the test by absolute path and
# passes no environment, and the checkout is not always at the same
# place (a git worktree is not the main checkout). $REPRO_REPO_ROOT
# still overrides, for running the arm by hand.
REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
WORK="${REPRO_M2_WORK:-/tmp/m2-signing-dnf}"
PKG=repro-m2-probe
VER=1.0
MARKER=/usr/share/repro-m2-probe/marker.txt
REPOFILE=/etc/yum.repos.d/reprobuild-gate.repo

fails=0
step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

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
    printf '%s\n' "vvv $_file vvv"; cat "$_file"; printf '%s\n' '^^^ end ^^^'
  fi
}

# ---------------------------------------------------------------------
step 'preconditions'
# ---------------------------------------------------------------------

[ -r /etc/os-release ] || { echo 'no /etc/os-release'; exit 1; }
. /etc/os-release
case "${ID:-}" in
  fedora|rhel|centos) ;;
  *) echo "m2_signing_dnf: expected an rpm distro, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root'; exit 1; }
[ -d "$SIGN_DIR" ] || { echo "signing scripts not found at $SIGN_DIR" >&2; exit 1; }

for t in createrepo_c rpmsign rpmbuild; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "installing createrepo_c + rpm-sign + rpm-build"
    dnf install -y --setopt=install_weak_deps=False createrepo_c rpm-sign rpm-build >/dev/null 2>&1 || true
    break
  }
done
for t in createrepo_c rpmsign rpmbuild rpm dnf gpg; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
ARCH="$(rpm --eval '%{_arch}')"
echo "arch=$ARCH  rpm=$(rpm --version)  dnf=$(dnf --version | head -1)"

rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------------
step 'generate the throwaway signing key and an adversary key'
# ---------------------------------------------------------------------

GOOD_HOME="$WORK/gnupg-good"
ADV_HOME="$WORK/gnupg-adversary"
GOOD_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$GOOD_HOME")"
ADV_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$ADV_HOME")"
[ -n "$GOOD_FPR" ] && [ -n "$ADV_FPR" ] || { echo 'key generation failed'; exit 1; }
[ "$GOOD_FPR" != "$ADV_FPR" ] || { echo 'keys collided'; exit 1; }
echo "signing   key: $GOOD_FPR"
echo "adversary key: $ADV_FPR"

GOOD_PUB="$WORK/RPM-GPG-KEY-reprobuild-gate"
ADV_PUB="$WORK/RPM-GPG-KEY-adversary"
GNUPGHOME="$GOOD_HOME" gpg --batch --armor --export "$GOOD_FPR" > "$GOOD_PUB"
GNUPGHOME="$ADV_HOME"  gpg --batch --armor --export "$ADV_FPR"  > "$ADV_PUB"
[ -s "$GOOD_PUB" ] && [ -s "$ADV_PUB" ] || { echo 'key export failed'; exit 1; }

# ---------------------------------------------------------------------
step 'build a minimal rpm'
# ---------------------------------------------------------------------

TOP="$WORK/rpmbuild"
mkdir -p "$TOP/SPECS" "$TOP/BUILD" "$TOP/RPMS" "$TOP/SOURCES" "$TOP/BUILDROOT"
cat > "$TOP/SPECS/$PKG.spec" <<SPEC
Name:           $PKG
Version:        $VER
Release:        1
Summary:        M2 signing gate probe
License:        MIT
BuildArch:      $ARCH
%description
A single file, so that "did it install" is a one-line question.
%install
mkdir -p %{buildroot}/usr/share/$PKG
printf 'reprobuild m2 signing probe\\n' > %{buildroot}/usr/share/$PKG/marker.txt
%files
/usr/share/$PKG/marker.txt
SPEC
rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/$PKG.spec" >"$WORK/rpmbuild.log" 2>&1 \
  || { echo 'rpmbuild failed'; tail -30 "$WORK/rpmbuild.log"; exit 1; }
BUILT="$(find "$TOP/RPMS" -name "$PKG-*.rpm" | head -1)"
[ -n "$BUILT" ] || { echo 'no rpm produced'; exit 1; }
echo "built $BUILT"
cp "$BUILT" "$WORK/unsigned.rpm"

mkdir -p "$WORK/repo"
cp "$BUILT" "$WORK/repo/"
RPM="$WORK/repo/$(basename "$BUILT")"

# ---------------------------------------------------------------------
step 'sign the repository'
# ---------------------------------------------------------------------

GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-rpm-repo.sh" \
     --root "$WORK/repo" --key "$GOOD_FPR" --id reprobuild-gate \
     --export-key "$GOOD_PUB"

cp -a "$WORK/repo" "$WORK/repo-pristine"

write_repofile() {
  # $1 = gpgkey path
  cat > "$REPOFILE" <<REPO
[reprobuild-gate]
name=Reprobuild M2 gate
baseurl=file://$WORK/repo
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$1
metadata_expire=1
REPO
}

dnf_reset() {
  dnf clean all >/dev/null 2>&1 || true
  rm -rf /var/cache/dnf /var/cache/libdnf5 2>/dev/null || true
}

rpm_forget_keys() {
  for k in $(rpm -qa 'gpg-pubkey*' 2>/dev/null); do
    rpm -e --allmatches "$k" >/dev/null 2>&1 || true
  done
}

restore_repo() {
  rm -rf "$WORK/repo"
  cp -a "$WORK/repo-pristine" "$WORK/repo"
}

purge_pkg() {
  rpm -e "$PKG" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$MARKER")"
}

dnf_install() {
  dnf --disablerepo='*' --enablerepo=reprobuild-gate \
      --setopt=reprobuild-gate.gpgcheck=1 \
      --setopt=reprobuild-gate.repo_gpgcheck=1 \
      -y install "$PKG"
}

# ---------------------------------------------------------------------
step 'N0 CONTROL - the genuine repo under the WRONG trust anchor'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; rpm_forget_keys; dnf_reset
write_repofile "$ADV_PUB"
if run_capture "$WORK/n0.log" dnf_install; then
  bad 'N0: dnf INSTALLED from a repository whose signer the client does not trust'
  cat "$WORK/n0.log"
else
  ok 'N0: dnf refused the repository under the wrong trust anchor'
  assert_matches "$WORK/n0.log" 'repomd.xml GPG signature verification error' \
    'N0: dnf named the repository-metadata signature failure'
fi

# ---------------------------------------------------------------------
step 'G1 - genuine repository, correct trust anchor'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; rpm_forget_keys; dnf_reset
write_repofile "$GOOD_PUB"
rpm --import "$GOOD_PUB" || bad 'G1: rpm --import of the trusted key failed'
if run_capture "$WORK/g1.log" dnf_install; then
  if [ -f "$MARKER" ]; then
    ok 'G1: genuine signed rpm installed from the signed repository'
  else
    bad 'G1: dnf reported success but the package file is absent'
  fi
else
  bad 'G1: dnf rejected the GENUINE signed repository'
  cat "$WORK/g1.log"
fi

# ---------------------------------------------------------------------
step 'G2a - tampered ARTIFACT (rpm bytes edited)'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; dnf_reset
write_repofile "$GOOD_PUB"
printf 'TAMPER' >> "$RPM"
if run_capture "$WORK/g2a.log" dnf_install; then
  bad 'G2a: dnf INSTALLED a tampered rpm'
  cat "$WORK/g2a.log"
else
  ok 'G2a: dnf refused the tampered rpm'
  assert_matches "$WORK/g2a.log" "checksum doesn't match" \
    'G2a: dnf named the checksum mismatch'
  [ -f "$MARKER" ] && bad 'G2a: the tampered rpm installed anyway' || ok 'G2a: nothing was installed'
fi

# ---------------------------------------------------------------------
step 'G2b - rpm signed by an UNTRUSTED key, metadata genuine'
# ---------------------------------------------------------------------
#
# The repository is rebuilt and re-signed with the TRUSTED key, so
# repo_gpgcheck passes. Only the package header carries the adversary's
# signature. Nothing but gpgcheck can catch this.

restore_repo; purge_pkg; dnf_reset
rm -f "$WORK/repo"/*.rpm
cp "$WORK/unsigned.rpm" "$WORK/repo/$(basename "$BUILT")"
GNUPGHOME="$ADV_HOME" rpmsign \
  --define "_gpg_name $ADV_FPR" \
  --define "_gpg_path $ADV_HOME" \
  --addsign "$WORK/repo/$(basename "$BUILT")" >/dev/null 2>&1 \
  || { bad 'G2b: could not adversary-sign the rpm'; }
rpm -Kv "$WORK/repo/$(basename "$BUILT")" 2>&1 | grep -qi 'openpgp.*signature' \
  || bad 'G2b: the adversary signature did not land, so the test would prove nothing'
rm -rf "$WORK/repo/repodata"
createrepo_c --quiet "$WORK/repo"
GNUPGHOME="$GOOD_HOME" gpg --batch --no-tty --yes --pinentry-mode loopback \
  --local-user "$GOOD_FPR" --armor --detach-sign \
  --output "$WORK/repo/repodata/repomd.xml.asc" "$WORK/repo/repodata/repomd.xml"
write_repofile "$GOOD_PUB"
if run_capture "$WORK/g2b.log" dnf_install; then
  bad 'G2b: dnf INSTALLED an rpm signed by an untrusted key'
  cat "$WORK/g2b.log"
else
  ok 'G2b: dnf refused the rpm signed by an untrusted key'
  assert_matches "$WORK/g2b.log" 'Signature verification failed' \
    'G2b: dnf named the package-signature failure'
fi

# ---------------------------------------------------------------------
step 'G3 - tampered REPOSITORY INDEX (repomd.xml edited after signing)'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; dnf_reset
write_repofile "$GOOD_PUB"
RM_XML="$WORK/repo/repodata/repomd.xml"
# Bump the revision. The document stays well-formed XML, so a rejection
# can only come from the signature, not from a parse failure.
sed -i 's|<revision>|<revision>9|' "$RM_XML"
grep -q '<revision>9' "$RM_XML" || { echo 'index tamper did not apply'; exit 1; }
if run_capture "$WORK/g3.log" dnf_install; then
  bad 'G3: dnf INSTALLED from a repository whose repomd.xml was edited after signing'
  cat "$WORK/g3.log"
else
  ok 'G3: dnf refused the edited repomd.xml'
  assert_matches "$WORK/g3.log" 'repomd.xml GPG signature verification error: Bad PGP signature' \
    'G3: dnf named the BAD repository-metadata signature'
fi

restore_repo; purge_pkg; dnf_reset

# ---------------------------------------------------------------------
step 'G4 - the installer pre-install verification'
# ---------------------------------------------------------------------

DL="$WORK/download"
rm -rf "$DL"; mkdir -p "$DL"
cp "$WORK/repo-pristine/$(basename "$BUILT")" "$DL/"
tar -C "$TOP/BUILDROOT" -czf "$DL/reprobuild-${ARCH}-linux.tar.gz" . 2>/dev/null || \
  tar -cf "$DL/reprobuild-${ARCH}-linux.tar.gz" -C "$WORK" unsigned.rpm

GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-release.sh" --dir "$DL" --key "$GOOD_FPR"
cp -a "$DL" "$WORK/download-pristine"

VERIFY="$SIGN_DIR/repro-verify-release.sh"

if run_capture "$WORK/g4a.log" sh "$VERIFY" --keyring "$GOOD_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  ok 'G4a: pre-install verification ACCEPTED the genuine bundle'
else
  bad 'G4a: pre-install verification rejected the GENUINE bundle'; cat "$WORK/g4a.log"
fi

rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
printf 'TAMPER' >> "$DL/$(basename "$BUILT")"
if run_capture "$WORK/g4b.log" sh "$VERIFY" --keyring "$GOOD_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4b: pre-install verification ACCEPTED a tampered artifact'; cat "$WORK/g4b.log"
else
  ok 'G4b: pre-install verification rejected the tampered artifact'
  assert_matches "$WORK/g4b.log" 'digest mismatch' 'G4b: verifier named the digest mismatch'
fi

rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
printf 'TAMPER' >> "$DL/$(basename "$BUILT")"
( cd "$DL" && sha256sum ./*.rpm ./*.tar.gz | sed 's| \./| |' > SHA256SUMS )
if run_capture "$WORK/g4c.log" sh "$VERIFY" --keyring "$GOOD_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4c: pre-install verification ACCEPTED a rewritten manifest'; cat "$WORK/g4c.log"
else
  ok 'G4c: pre-install verification rejected the rewritten manifest'
  assert_matches "$WORK/g4c.log" 'not valid\|VALIDSIG' 'G4c: verifier named the manifest signature failure'
fi

rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
if run_capture "$WORK/g4d.log" sh "$VERIFY" --keyring "$ADV_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4d: pre-install verification ACCEPTED a bundle signed by an untrusted key'; cat "$WORK/g4d.log"
else
  ok 'G4d: pre-install verification rejected the untrusted signer'
fi

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------

purge_pkg; rpm_forget_keys; rm -f "$REPOFILE"; dnf_reset

printf '\n### captured package-manager output ###\n'
for f in n0 g1 g2a g2b g3; do
  printf '\n%s\n' "----- $f.log -----"
  sed -n '1,40p' "$WORK/$f.log" 2>/dev/null || true
done

if [ "$fails" -eq 0 ]; then
  echo; echo 'm2_signing_dnf: ALL CHECKS PASSED'; exit 0
fi
echo; echo "m2_signing_dnf: $fails CHECK(S) FAILED"; exit 1
