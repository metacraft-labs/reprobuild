#!/bin/sh
# M2 SIGNING gate, pacman arm. Runs inside repro-arch.
#
#   scripts/run_multi_distro_tests.sh m2_signing_pacman arch
#
# Proves, with pacman's own messages and exit codes:
#
#   G1   a genuine signed repository + signed package installs under
#        SigLevel = Required DatabaseRequired
#   G2   a tampered PACKAGE is rejected (SigLevel Required)
#   G3   a tampered DATABASE is rejected (SigLevel DatabaseRequired) --
#        the sync db is what pacman's DEFAULT `DatabaseOptional` does
#        NOT check, so this arm is the one that would silently pass on
#        a stock configuration
#   G4   the installer's pre-install verification accepts the genuine
#        bundle and rejects the tampers
#   N0   CONTROL: the same genuine repository is REJECTED when its key
#        is not in pacman's keyring
#
# pacman is the strictest of the three about signature FORM: `.sig`
# files must be raw OpenPGP packets, not ASCII armour. An armoured
# signature is rejected as "invalid or corrupted package" -- which looks
# exactly like a successful tamper detection. So G1 running FIRST and
# succeeding is what makes G2's and G3's rejections mean what they say.

set -eu

# The repo root is derived from THIS script's location, not hardcoded:
# scripts/run_multi_distro_tests.sh execs the test by absolute path and
# passes no environment, and the checkout is not always at the same
# place (a git worktree is not the main checkout). $REPRO_REPO_ROOT
# still overrides, for running the arm by hand.
REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
WORK="${REPRO_M2_WORK:-/tmp/m2-signing-pacman}"
PKG=repro-m2-probe
VER=1.0
MARKER=/usr/share/repro-m2-probe/marker.txt
DB=reprobuild-gate
PACCONF="$WORK/pacman.conf"

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
  arch|archarm|manjaro) ;;
  *) echo "m2_signing_pacman: expected arch, got ID=${ID:-?}" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo 'must run as root'; exit 1; }
[ -d "$SIGN_DIR" ] || { echo "signing scripts not found at $SIGN_DIR" >&2; exit 1; }
for t in pacman repo-add pacman-key gpg bsdtar zstd; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
ARCH="$(uname -m)"
echo "arch=$ARCH  $(pacman --version 2>&1 | grep -i 'Pacman v' | head -1)"

rm -rf "$WORK"; mkdir -p "$WORK"

# pacman's own keyring must exist before pacman-key --add works.
pacman-key --init >/dev/null 2>&1 || true

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
GOOD_PUB="$WORK/reprobuild-gate.key"
ADV_PUB="$WORK/adversary.key"
GNUPGHOME="$GOOD_HOME" gpg --batch --armor --export "$GOOD_FPR" > "$GOOD_PUB"
GNUPGHOME="$ADV_HOME"  gpg --batch --armor --export "$ADV_FPR"  > "$ADV_PUB"

# ---------------------------------------------------------------------
step 'build a minimal pacman package'
# ---------------------------------------------------------------------
#
# Assembled with bsdtar rather than makepkg: makepkg refuses to run as
# root, and creating a build user would put the gate's outcome behind
# an unrelated moving part. The archive shape is the documented one --
# .PKGINFO first, then the payload -- and G1 installing it proves the
# shape is right.

BUILDROOT="$WORK/pkgroot"
mkdir -p "$BUILDROOT/usr/share/$PKG"
printf 'reprobuild m2 signing probe\n' > "$BUILDROOT/usr/share/$PKG/marker.txt"
SIZE="$(du -sb "$BUILDROOT" | awk '{print $1}')"
cat > "$BUILDROOT/.PKGINFO" <<PKGINFO
pkgname = $PKG
pkgbase = $PKG
pkgver = $VER-1
pkgdesc = M2 signing gate probe
url = https://reprobuild.invalid
builddate = $(date +%s)
packager = Reprobuild Gate <m2-gate-test@reprobuild.invalid>
size = $SIZE
arch = $ARCH
license = MIT
PKGINFO

mkdir -p "$WORK/repo"
PKGFILE="$WORK/repo/$PKG-$VER-1-$ARCH.pkg.tar.zst"
( cd "$BUILDROOT" && bsdtar -cf - .PKGINFO usr ) | zstd -q -o "$PKGFILE" -f
[ -s "$PKGFILE" ] || { echo 'package assembly failed'; exit 1; }
echo "built $PKGFILE"

# ---------------------------------------------------------------------
step 'sign the repository'
# ---------------------------------------------------------------------

GNUPGHOME="$GOOD_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
  sh "$SIGN_DIR/repro-sign-pacman-repo.sh" \
     --root "$WORK/repo" --key "$GOOD_FPR" --db "$DB" \
     --export-key "$GOOD_PUB"

cp -a "$WORK/repo" "$WORK/repo-pristine"

# A private pacman.conf so the gate never rewrites the distro's own and
# never consults the distro's repositories (a flaky mirror would produce
# the same non-zero exit as a rejected signature).
write_pacconf() {
  cat > "$PACCONF" <<CONF
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseRequired
LocalFileSigLevel = Required

[$DB]
SigLevel = Required DatabaseRequired
Server = file://$WORK/repo
CONF
}
write_pacconf

pac() { pacman --config "$PACCONF" --noconfirm "$@"; }

keyring_add_good() {
  pacman-key --add "$GOOD_PUB" >/dev/null 2>&1
  pacman-key --lsign-key "$GOOD_FPR" >/dev/null 2>&1
}
keyring_forget() {
  pacman-key --delete "$GOOD_FPR" >/dev/null 2>&1 || true
  pacman-key --delete "$ADV_FPR" >/dev/null 2>&1 || true
}

pac_reset() {
  rm -rf /var/lib/pacman/sync/"$DB".db /var/lib/pacman/sync/"$DB".db.sig \
         /var/lib/pacman/sync/"$DB".files /var/lib/pacman/sync/"$DB".files.sig
  rm -rf /var/cache/pacman/pkg/"$PKG"* 2>/dev/null || true
}

restore_repo() { rm -rf "$WORK/repo"; cp -a "$WORK/repo-pristine" "$WORK/repo"; }
purge_pkg() {
  pacman --config "$PACCONF" --noconfirm -Rdd "$PKG" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$MARKER")"
}

# ---------------------------------------------------------------------
step 'N0 CONTROL - genuine repo, key NOT in pacman keyring'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; keyring_forget; pac_reset
if run_capture "$WORK/n0.log" pac -Sy; then
  bad 'N0: pacman SYNCED a database signed by a key it does not hold'
  cat "$WORK/n0.log"
else
  ok 'N0: pacman refused the database from an unknown signer'
  assert_matches "$WORK/n0.log" 'unknown trust\|signature from\|invalid or corrupted database\|marginal trust\|is not trusted' \
    'N0: pacman named the trust failure'
fi

# ---------------------------------------------------------------------
step 'G1 - genuine repository, key in pacman keyring'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; pac_reset
keyring_add_good
if run_capture "$WORK/g1-sync.log" pac -Sy; then
  ok 'G1: pacman accepted the signed database'
else
  bad 'G1: pacman rejected the GENUINE signed database'; cat "$WORK/g1-sync.log"
fi
if run_capture "$WORK/g1-install.log" pac -S "$PKG"; then
  if [ -f "$MARKER" ]; then
    ok 'G1: genuine signed package installed'
  else
    bad 'G1: pacman reported success but the package file is absent'
  fi
else
  bad 'G1: pacman rejected the genuine signed package'; cat "$WORK/g1-install.log"
fi

# ---------------------------------------------------------------------
step 'G2 - tampered PACKAGE, database untouched'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; pac_reset
run_capture "$WORK/g2-sync.log" pac -Sy || true
# IN PLACE, same length. Appending six bytes made pacman reject on the
# signed database's SIZE field before it ever looked at the signature --
# a real rejection, but not the one this step claims to demonstrate, and
# the first version of this arm passed for exactly that wrong reason.
TARGET="$WORK/repo/$PKG-$VER-1-$ARCH.pkg.tar.zst"
before="$(wc -c < "$TARGET")"
printf 'TAMPER' | dd of="$TARGET" bs=1 seek=48 conv=notrunc status=none
after="$(wc -c < "$TARGET")"
[ "$before" -eq "$after" ] \
  || { echo "G2 tamper changed the file length ($before -> $after); it would test the size check, not the signature"; exit 1; }
if run_capture "$WORK/g2.log" pac -S "$PKG"; then
  bad 'G2: pacman INSTALLED a tampered package'; cat "$WORK/g2.log"
else
  ok 'G2: pacman refused the tampered package'
  assert_matches "$WORK/g2.log" 'invalid or corrupted package' \
    'G2: pacman named the package integrity/signature failure'
  [ -f "$MARKER" ] && bad 'G2: the tampered package installed anyway' || ok 'G2: nothing was installed'
fi

# ---------------------------------------------------------------------
step 'G2b - package signed by an UNTRUSTED key, database genuine'
# ---------------------------------------------------------------------
#
# Size and hash both match, the sync db is correctly signed by the
# trusted key, and the ONLY thing wrong is who signed the package. This
# is the check `SigLevel = Required` exists for and the one G2 above
# cannot isolate.

restore_repo; purge_pkg; pac_reset
TARGET="$WORK/repo/$PKG-$VER-1-$ARCH.pkg.tar.zst"
rm -f "$TARGET.sig"
GNUPGHOME="$ADV_HOME" gpg --batch --no-tty --yes --pinentry-mode loopback \
  --local-user "$ADV_FPR" --detach-sign --no-armor --output "$TARGET.sig" "$TARGET"
[ -s "$TARGET.sig" ] || { echo 'adversary package signature missing'; exit 1; }
( cd "$WORK/repo" && rm -f "$DB".db* "$DB".files* \
  && GNUPGHOME="$GOOD_HOME" repo-add --sign --key "$GOOD_FPR" \
       "$DB.db.tar.gz" "$PKG-$VER-1-$ARCH.pkg.tar.zst" ) \
  >/dev/null 2>&1
( cd "$WORK/repo" \
  && ln -sf "$DB.db.tar.gz" "$DB.db" \
  && ln -sf "$DB.db.tar.gz.sig" "$DB.db.sig" \
  && ln -sf "$DB.files.tar.gz" "$DB.files" \
  && ln -sf "$DB.files.tar.gz.sig" "$DB.files.sig" )
if run_capture "$WORK/g2b-sync.log" pac -Sy; then
  ok 'G2b: the re-signed database still syncs (so the next step isolates the package signature)'
else
  bad 'G2b: the re-signed database did not sync, so this step cannot isolate the package signature'
  cat "$WORK/g2b-sync.log"
fi
if run_capture "$WORK/g2b.log" pac -S "$PKG"; then
  bad 'G2b: pacman INSTALLED a package signed by an untrusted key'; cat "$WORK/g2b.log"
else
  ok 'G2b: pacman refused the package signed by an untrusted key'
  assert_matches "$WORK/g2b.log" 'required key missing from keyring' \
    'G2b: pacman named the missing signer key'
fi

# ---------------------------------------------------------------------
step 'G3 - tampered DATABASE (db bytes edited, signature stale)'
# ---------------------------------------------------------------------

restore_repo; purge_pkg; pac_reset
# Rebuild the db WITHOUT a signature and keep the old one: the classic
# "serve a different index under a stale signature" attack. repo-add is
# deterministic enough that the bytes differ, which is the point.
cp "$WORK/repo/$DB.db.tar.gz.sig" "$WORK/sig.keep"
( cd "$WORK/repo" && rm -f "$DB".db* "$DB".files* \
  && repo-add "$DB.db.tar.gz" "$PKG-$VER-1-$ARCH.pkg.tar.zst" ) >/dev/null 2>&1
cp "$WORK/sig.keep" "$WORK/repo/$DB.db.tar.gz.sig"
( cd "$WORK/repo" \
  && ln -sf "$DB.db.tar.gz" "$DB.db" \
  && ln -sf "$DB.db.tar.gz.sig" "$DB.db.sig" )
if run_capture "$WORK/g3.log" pac -Sy; then
  bad 'G3: pacman SYNCED a database whose signature does not cover its bytes'
  cat "$WORK/g3.log"
else
  ok 'G3: pacman refused the re-generated database under its stale signature'
  assert_matches "$WORK/g3.log" 'invalid or corrupted database\|signature from.*is invalid\|PGP signature' \
    'G3: pacman named the database signature failure'
fi

# ---------------------------------------------------------------------
step 'G3b - MISSING database signature under DatabaseRequired'
# ---------------------------------------------------------------------
#
# The stock pacman default is `DatabaseOptional`, under which this case
# installs happily. This asserts the emitted stanza really is the strict
# one -- otherwise G3 above could be passing for an unrelated reason.

restore_repo; purge_pkg; pac_reset
rm -f "$WORK/repo/$DB.db.sig" "$WORK/repo/$DB.db.tar.gz.sig"
if run_capture "$WORK/g3b.log" pac -Sy; then
  bad 'G3b: pacman SYNCED an UNSIGNED database under DatabaseRequired'
  cat "$WORK/g3b.log"
else
  ok 'G3b: pacman refused the unsigned database'
  assert_matches "$WORK/g3b.log" "failed retrieving file 'reprobuild-gate.db.sig'" \
    'G3b: pacman demanded the database signature it could not find'
fi

# ---------------------------------------------------------------------
step 'G3c CONTROL - the SAME missing signature under DatabaseOptional'
# ---------------------------------------------------------------------
#
# This is the control that gives G3b its meaning. With pacman's stock
# `DatabaseOptional`, the identical repository state -- an unsigned sync
# database -- syncs FINE. So G3b's rejection is caused by the SigLevel
# the signer emits, not by anything incidental about the fixture.

rm -f "$WORK/repo/$DB.db.sig" "$WORK/repo/$DB.db.tar.gz.sig"
cat > "$WORK/pacman-lax.conf" <<LAX
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional

[$DB]
SigLevel = Required DatabaseOptional
Server = file://$WORK/repo
LAX
pac_reset
if run_capture "$WORK/g3c.log" pacman --config "$WORK/pacman-lax.conf" --noconfirm -Sy; then
  ok 'G3c: the same unsigned database syncs under DatabaseOptional, so G3b measured the SigLevel'
else
  bad 'G3c: even DatabaseOptional refused it, so G3b may have failed for an unrelated reason'
  cat "$WORK/g3c.log"
fi

restore_repo; purge_pkg; pac_reset

# ---------------------------------------------------------------------
step 'G4 - the installer pre-install verification'
# ---------------------------------------------------------------------

DL="$WORK/download"
rm -rf "$DL"; mkdir -p "$DL"
cp "$WORK/repo-pristine/$PKG-$VER-1-$ARCH.pkg.tar.zst" "$DL/"
tar -C "$BUILDROOT" -czf "$DL/reprobuild-${ARCH}-linux.tar.gz" usr

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
printf 'TAMPER' >> "$DL/$PKG-$VER-1-$ARCH.pkg.tar.zst"
if run_capture "$WORK/g4b.log" sh "$VERIFY" --keyring "$GOOD_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4b: pre-install verification ACCEPTED a tampered artifact'; cat "$WORK/g4b.log"
else
  ok 'G4b: pre-install verification rejected the tampered artifact'
  assert_matches "$WORK/g4b.log" 'digest mismatch' 'G4b: verifier named the digest mismatch'
fi

rm -rf "$DL"; cp -a "$WORK/download-pristine" "$DL"
printf 'TAMPER' >> "$DL/$PKG-$VER-1-$ARCH.pkg.tar.zst"
( cd "$DL" && sha256sum "$PKG-$VER-1-$ARCH.pkg.tar.zst" "reprobuild-${ARCH}-linux.tar.gz" > SHA256SUMS )
if run_capture "$WORK/g4c.log" sh "$VERIFY" --keyring "$GOOD_PUB" \
     --dir "$DL" --allow-test-key --require-all; then
  bad 'G4c: pre-install verification ACCEPTED a rewritten manifest'; cat "$WORK/g4c.log"
else
  ok 'G4c: pre-install verification rejected the rewritten manifest'
  assert_matches "$WORK/g4c.log" 'not valid' 'G4c: verifier named the manifest signature failure'
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

purge_pkg; keyring_forget; pac_reset

printf '\n### captured package-manager output ###\n'
for f in n0 g1-sync g1-install g2 g2b g3 g3b g3c; do
  printf '\n%s\n' "----- $f.log -----"
  sed -n '1,30p' "$WORK/$f.log" 2>/dev/null || true
done

if [ "$fails" -eq 0 ]; then
  echo; echo 'm2_signing_pacman: ALL CHECKS PASSED'; exit 0
fi
echo; echo "m2_signing_pacman: $fails CHECK(S) FAILED"; exit 1
