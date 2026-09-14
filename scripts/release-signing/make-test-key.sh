#!/bin/sh
# Generate a THROWAWAY signing key for the M2 gate tests.
#
#   eval "$(scripts/release-signing/make-test-key.sh)"
#     -> exports GNUPGHOME and REPRO_TEST_KEY_FPR
#
# or
#
#   scripts/release-signing/make-test-key.sh --home <dir>
#     -> generates into <dir> and prints the fingerprint on stdout
#
# The UID carries the literal marker `REPROBUILD UNTRUSTED TEST KEY`,
# which is what makes `lib-signing.sh` classify it as `test` rather than
# `unknown`, which is in turn the ONLY thing that lets
# REPRO_SIGNING_ALLOW_TEST_KEY=1 admit it. A key generated any other way
# is `unknown` and cannot sign at all -- so a test cannot accidentally
# borrow a real key's privileges by pointing at a different keyring, and
# a real key cannot accidentally acquire a test key's leniency.
#
# rsa3072 rather than the gpg `default`: the same key is fed to apt's
# gpgv, rpm's internal OpenPGP parser and pacman's gpgme, and rpm was
# the last of those to accept EdDSA. Pinning the algorithm keeps a gate
# failure meaning "the signature was rejected", never "this rpm build
# does not know this curve".

set -eu

home=''
uid_name='Reprobuild Gate Test Key'
uid_comment='REPROBUILD UNTRUSTED TEST KEY'
uid_email='m2-gate-test@reprobuild.invalid'
print_eval=1

while [ $# -gt 0 ]; do
  case "$1" in
    --home) home="$2"; print_eval=0; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) printf 'make-test-key: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

GPG="${REPRO_GPG_BIN:-$(command -v gpg 2>/dev/null || command -v gpg2 2>/dev/null || true)}"
[ -n "$GPG" ] || { printf 'make-test-key: no gpg on PATH\n' >&2; exit 1; }

if [ -z "$home" ]; then
  home="$(mktemp -d "${TMPDIR:-/tmp}/repro-testkey-XXXXXX")"
fi
mkdir -p "$home"
chmod 700 "$home"

uid="$uid_name ($uid_comment) <$uid_email>"

GNUPGHOME="$home" "$GPG" --batch --no-tty --yes \
  --pinentry-mode loopback --passphrase '' \
  --quick-generate-key "$uid" rsa3072 sign never >/dev/null 2>&1 \
  || { printf 'make-test-key: key generation failed\n' >&2; exit 1; }

fpr="$(GNUPGHOME="$home" "$GPG" --batch --with-colons --fingerprint \
        --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[ -n "$fpr" ] || { printf 'make-test-key: no fingerprint after generation\n' >&2; exit 1; }

# Prove the marker landed in a UID. If it did not, every later
# `rs_require_signing_key` would classify this key `unknown` and the
# gate would fail with a confusing message instead of this clear one.
GNUPGHOME="$home" "$GPG" --batch --with-colons --list-keys 2>/dev/null \
  | awk -F: '$1=="uid"{print $10}' \
  | grep -qF "$uid_comment" \
  || { printf 'make-test-key: generated key lacks the %s marker\n' "$uid_comment" >&2; exit 1; }

# Ultimate ownertrust on our own throwaway key, so gpg --verify does not
# emit the "not certified with a trusted signature" warning that would
# otherwise be indistinguishable from a real problem in the gate logs.
printf '%s:6:\n' "$fpr" | GNUPGHOME="$home" "$GPG" --batch --import-ownertrust >/dev/null 2>&1 || true

if [ "$print_eval" -eq 1 ]; then
  printf 'GNUPGHOME=%s; export GNUPGHOME; REPRO_TEST_KEY_FPR=%s; export REPRO_TEST_KEY_FPR;\n' \
    "$home" "$fpr"
else
  printf '%s\n' "$fpr"
fi
