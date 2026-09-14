#!/bin/sh
# M2 SIGNING gate, key-policy arm. Needs only `gpg` and `sha256sum`, so
# it runs on every distro in the harness (and on any CI runner).
#
#   scripts/run_multi_distro_tests.sh m2_signing_keypolicy --all
#
# The three distro arms prove that a signature is verified. This arm
# proves the thing that makes those signatures worth anything: that the
# THROWAWAY key used to produce them cannot be mistaken for a release
# key, in either direction, by accident or by an environment variable.
#
#   P1  a test key is REFUSED by default
#   P2  a test key signs only under REPRO_SIGNING_ALLOW_TEST_KEY=1, and
#       the output then carries the marker file
#   P3  an UNKNOWN key (neither listed nor marked) is refused EVEN WITH
#       REPRO_SIGNING_ALLOW_TEST_KEY=1 -- the escape hatch admits test
#       keys and nothing else
#   P4  a key whose fingerprint IS in the trusted list signs as a
#       release: no marker file, and the verifier accepts it without
#       --allow-test-key
#   P5  a key that is both listed AND marked is a hard error, not a
#       coin toss
#   P6  the committed trusted-release-keys.txt lists ZERO fingerprints,
#       so the repository as it stands cannot sign a release at all
#   P7  cosign keyless REFUSES (exit 2) with no ambient OIDC identity,
#       and says so, rather than reporting success
#   P8  the signer refuses to fall back to the operator's ~/.gnupg

set -eu

# The repo root is derived from THIS script's location, not hardcoded:
# scripts/run_multi_distro_tests.sh execs the test by absolute path and
# passes no environment, and the checkout is not always at the same
# place (a git worktree is not the main checkout). $REPRO_REPO_ROOT
# still overrides, for running the arm by hand.
REPO_ROOT="${REPRO_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)}"
SIGN_DIR="$REPO_ROOT/scripts/release-signing"
WORK="${REPRO_M2_WORK:-/tmp/m2-signing-keypolicy}"

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
assert_matches() {
  _file="$1"; _pat="$2"; _what="$3"
  _n="$(grep -c -- "$_pat" "$_file" 2>/dev/null || true)"
  if [ "${_n:-0}" -ge 1 ]; then
    ok "$_what (matched $_n line(s))"
  else
    bad "$_what: pattern '$_pat' matched 0 lines in $_file"
    printf '%s\n' "vvv $_file vvv"; cat "$_file"; printf '%s\n' '^^^ end ^^^'
  fi
}

command -v gpg >/dev/null 2>&1 || { echo 'no gpg on PATH' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'no sha256sum on PATH' >&2; exit 1; }
[ -d "$SIGN_DIR" ] || { echo "signing scripts not found at $SIGN_DIR" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
SIGN="$SIGN_DIR/repro-sign-release.sh"
VERIFY="$SIGN_DIR/repro-verify-release.sh"

fresh_dir() {
  _d="$WORK/$1"
  rm -rf "$_d"; mkdir -p "$_d"
  printf 'payload %s\n' "$1" > "$_d/reprobuild-probe.tar.gz"
  printf '%s\n' "$_d"
}

# ---------------------------------------------------------------------
step 'keys'
# ---------------------------------------------------------------------

TEST_HOME="$WORK/gnupg-test"
TEST_FPR="$(sh "$SIGN_DIR/make-test-key.sh" --home "$TEST_HOME")"
echo "test key:    $TEST_FPR"
GNUPGHOME="$TEST_HOME" gpg --batch --armor --export "$TEST_FPR" > "$WORK/test.pub"
[ -s "$WORK/test.pub" ] || { echo 'could not export the test key'; exit 1; }

# An "unknown" key: a perfectly ordinary key with no marker in any UID
# and no entry in any trusted list. This is what a maintainer's own key,
# or an attacker's, looks like to the signer.
UNK_HOME="$WORK/gnupg-unknown"
mkdir -p "$UNK_HOME"; chmod 700 "$UNK_HOME"
GNUPGHOME="$UNK_HOME" gpg --batch --no-tty --yes --pinentry-mode loopback \
  --passphrase '' --quick-generate-key \
  'Some Unlabelled Maintainer <nobody@reprobuild.invalid>' rsa3072 sign never \
  >/dev/null 2>&1
UNK_FPR="$(GNUPGHOME="$UNK_HOME" gpg --batch --with-colons --fingerprint --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[ -n "$UNK_FPR" ] || { echo 'could not generate the unlabelled key'; exit 1; }
printf '%s:6:\n' "$UNK_FPR" | GNUPGHOME="$UNK_HOME" gpg --batch --import-ownertrust >/dev/null 2>&1 || true
echo "unknown key: $UNK_FPR"
GNUPGHOME="$UNK_HOME" gpg --batch --with-colons --list-keys 2>/dev/null \
  | awk -F: '$1=="uid"{print $10}' | grep -q 'REPROBUILD UNTRUSTED TEST KEY' \
  && { echo 'the unlabelled key accidentally carries the test marker'; exit 1; }
ok 'the unlabelled key carries no test marker (so P3 tests what it claims)'

# ---------------------------------------------------------------------
step 'P1 - a test key is refused by default'
# ---------------------------------------------------------------------

D="$(fresh_dir p1)"
if run_capture "$WORK/p1.log" env GNUPGHOME="$TEST_HOME" \
     sh "$SIGN" --dir "$D" --key "$TEST_FPR"; then
  bad 'P1: the signer signed with a TEST key with no opt-in'
  cat "$WORK/p1.log"
else
  ok 'P1: the signer refused the test key'
  assert_matches "$WORK/p1.log" 'REPRO_SIGNING_ALLOW_TEST_KEY' 'P1: it named the required opt-in'
  [ -f "$D/SHA256SUMS.asc" ] && bad 'P1: it produced a signature anyway' || ok 'P1: nothing was signed'
fi

# ---------------------------------------------------------------------
step 'P2 - a test key signs only with the opt-in, and is marked'
# ---------------------------------------------------------------------

D="$(fresh_dir p2)"
if run_capture "$WORK/p2.log" env GNUPGHOME="$TEST_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
     sh "$SIGN" --dir "$D" --key "$TEST_FPR"; then
  ok 'P2: the signer signed with the opt-in'
  [ -s "$D/SHA256SUMS.asc" ] || bad 'P2: no manifest signature was produced'
  if [ -f "$D/SIGNING-KEY-IS-A-TEST-KEY" ]; then
    ok 'P2: the output carries the test-key marker'
  else
    bad 'P2: a test-signed bundle carries NO marker, so it can be mistaken for a release'
  fi
else
  bad 'P2: the signer refused even with the opt-in'; cat "$WORK/p2.log"
fi

# The same bundle must be refused by the verifier in RELEASE mode, and
# refused FOR THE RIGHT REASON: with a real, populated keyring, so the
# rejection cannot be "there was nothing to verify against".
if run_capture "$WORK/p2v.log" sh "$VERIFY" --keyring "$WORK/test.pub" --dir "$D" --require-all; then
  bad 'P2: release-mode verification accepted a test-signed bundle'
  cat "$WORK/p2v.log"
else
  ok 'P2: release-mode verification refuses the test-signed bundle'
  assert_matches "$WORK/p2v.log" 'TEST KEY' 'P2: it refused because of the test key, not for want of a keyring'
fi

# ...and the SAME bundle with the SAME keyring must be ACCEPTED once
# --allow-test-key is given. Without this, P2's rejection could be
# hiding a broken signature.
if run_capture "$WORK/p2v2.log" sh "$VERIFY" --keyring "$WORK/test.pub" --dir "$D" --allow-test-key --require-all; then
  ok 'P2: the same bundle verifies with --allow-test-key, so the signature itself is sound'
else
  bad 'P2: the test-signed bundle does not verify even with --allow-test-key'
  cat "$WORK/p2v2.log"
fi

# ---------------------------------------------------------------------
step 'P3 - an UNKNOWN key is refused even with the opt-in'
# ---------------------------------------------------------------------

D="$(fresh_dir p3)"
if run_capture "$WORK/p3.log" env GNUPGHOME="$UNK_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
     sh "$SIGN" --dir "$D" --key "$UNK_FPR"; then
  bad 'P3: REPRO_SIGNING_ALLOW_TEST_KEY admitted a key that is not a test key'
  cat "$WORK/p3.log"
else
  ok 'P3: the opt-in admits test keys and nothing else'
  assert_matches "$WORK/p3.log" 'neither listed' 'P3: it named the missing trust decision'
  [ -f "$D/SHA256SUMS.asc" ] && bad 'P3: it produced a signature anyway' || ok 'P3: nothing was signed'
fi

# ---------------------------------------------------------------------
step 'P4 - a LISTED key signs as a release'
# ---------------------------------------------------------------------
#
# The list is swapped for a throwaway one via
# $REPRO_TRUSTED_RELEASE_KEYS. The committed list is not touched, and
# P6 below asserts it is still empty.

LIST="$WORK/trusted.txt"
printf '# throwaway list for P4\n%s\n' "$UNK_FPR" > "$LIST"
D="$(fresh_dir p4)"
if run_capture "$WORK/p4.log" env GNUPGHOME="$UNK_HOME" REPRO_TRUSTED_RELEASE_KEYS="$LIST" \
     sh "$SIGN" --dir "$D" --key "$UNK_FPR"; then
  ok 'P4: a listed key signs as a release with no opt-in'
  assert_matches "$WORK/p4.log" 'RELEASE key' 'P4: the signer said RELEASE'
  if [ -f "$D/SIGNING-KEY-IS-A-TEST-KEY" ]; then
    bad 'P4: a release-signed bundle was marked as a test bundle'
  else
    ok 'P4: no test marker on a release bundle'
  fi
else
  bad 'P4: a listed key was refused'; cat "$WORK/p4.log"
fi

GNUPGHOME="$UNK_HOME" gpg --batch --armor --export "$UNK_FPR" > "$WORK/unknown.pub"
if run_capture "$WORK/p4v.log" sh "$VERIFY" --keyring "$WORK/unknown.pub" \
     --dir "$D" --require-all; then
  ok 'P4: release-mode verification (no --allow-test-key) ACCEPTED it'
else
  bad 'P4: release-mode verification rejected a release-signed bundle'; cat "$WORK/p4v.log"
fi

# ---------------------------------------------------------------------
step 'P5 - listed AND marked is a hard error'
# ---------------------------------------------------------------------

printf '%s\n' "$TEST_FPR" > "$WORK/trusted-conflict.txt"
D="$(fresh_dir p5)"
if run_capture "$WORK/p5.log" env GNUPGHOME="$TEST_HOME" \
     REPRO_TRUSTED_RELEASE_KEYS="$WORK/trusted-conflict.txt" \
     sh "$SIGN" --dir "$D" --key "$TEST_FPR"; then
  bad 'P5: a key that is both listed and marked was silently resolved one way'
  cat "$WORK/p5.log"
else
  ok 'P5: the contradiction is an error'
  assert_matches "$WORK/p5.log" 'refusing to guess' 'P5: it refused to guess'
fi

# ---------------------------------------------------------------------
step 'P6 - the COMMITTED trusted list is empty'
# ---------------------------------------------------------------------

COMMITTED="$SIGN_DIR/trusted-release-keys.txt"
[ -f "$COMMITTED" ] || bad "P6: $COMMITTED is missing"
n_fpr="$(sed 's/#.*//' "$COMMITTED" | tr -d ' \t' | grep -c '^[0-9A-Fa-f]\{40\}$' || true)"
if [ "${n_fpr:-0}" -eq 0 ]; then
  ok 'P6: the committed list holds zero fingerprints, so no release can be signed from this checkout'
else
  bad "P6: the committed list holds $n_fpr fingerprint(s); a release key was added without review of this gate"
fi

# ---------------------------------------------------------------------
step 'P7 - cosign keyless refuses without an ambient OIDC identity'
# ---------------------------------------------------------------------

D="$(fresh_dir p7)"
# Strip anything that could look like an ambient identity, so the
# refusal is about the absence and not about a malformed value.
if run_capture "$WORK/p7.log" env GNUPGHOME="$TEST_HOME" REPRO_SIGNING_ALLOW_TEST_KEY=1 \
     ACTIONS_ID_TOKEN_REQUEST_URL= ACTIONS_ID_TOKEN_REQUEST_TOKEN= SIGSTORE_ID_TOKEN= \
     sh "$SIGN" --dir "$D" --key "$TEST_FPR" --cosign; then
  ok 'P7: the GPG half succeeded'
  if grep -q 'cosign keyless SKIPPED' "$WORK/p7.log"; then
    ok 'P7: cosign keyless was SKIPPED, with a reason, rather than claimed'
    assert_matches "$WORK/p7.log" 'OIDC\|cosign. on PATH' 'P7: it named what is missing'
  else
    bad 'P7: no cosign skip line; the script may be claiming a keyless signature it did not make'
    cat "$WORK/p7.log"
  fi
  [ -f "$D/SHA256SUMS.sigstore" ] \
    && bad 'P7: a sigstore bundle exists despite no OIDC identity' \
    || ok 'P7: no sigstore bundle was fabricated'
else
  bad 'P7: --cosign made the whole signing run fail'; cat "$WORK/p7.log"
fi

# ---------------------------------------------------------------------
step 'P8 - no fallback to the operator keyring'
# ---------------------------------------------------------------------

D="$(fresh_dir p8)"
if run_capture "$WORK/p8.log" env -u GNUPGHOME \
     sh "$SIGN" --dir "$D" --key "$TEST_FPR"; then
  bad 'P8: the signer ran with no GNUPGHOME, so it used whatever keyring it found'
  cat "$WORK/p8.log"
else
  ok 'P8: the signer refused to run without an explicit GNUPGHOME'
  assert_matches "$WORK/p8.log" 'will not fall back' 'P8: it said so'
fi

# ---------------------------------------------------------------------
step 'summary'
# ---------------------------------------------------------------------

if [ "$fails" -eq 0 ]; then
  echo; echo 'm2_signing_keypolicy: ALL CHECKS PASSED'; exit 0
fi
echo; echo "m2_signing_keypolicy: $fails CHECK(S) FAILED"; exit 1
