#!/bin/sh
# The installer's PRE-INSTALL verification. Clause (b) of the M2 gate.
#
#   repro-verify-release.sh --keyring <file|dir> --dir <download-dir>
#                           [--artifact <name>]... [--allow-test-key]
#                           [--require-all]
#
# Exit 0  — every requested artifact is covered by a signed manifest
#           whose signature was made by a key in <keyring>, its bytes
#           hash to the manifest's digest, and its own detached
#           signature verifies.
# Exit 1  — anything else. There is no "could not check, proceeding".
#
# ## Contract for M3's installer
#
# M3 owns the installer; M2 owns this. The installer calls:
#
#   "$dir/repro-verify-release.sh" --keyring "$keyring" --dir "$tmp" \
#       --artifact "reprobuild-x86_64-linux.tar.gz" \
#     || fail "signature verification failed; refusing to install"
#
# BEFORE it unpacks or executes anything it downloaded. This script
# depends on nothing but a POSIX shell, `sha256sum` and `gpgv` (or
# `gpg`) — deliberately, because a verifier that needs the payload it is
# verifying has verified nothing.
#
# ## Why it has no fallback
#
# apps/repro-harvest-{apt,dnf}/src/*/signature.nim degrade to a BLAKE3
# allowlist when gpg is absent. That is right for a harvester pinned to
# a frozen upstream snapshot. It is wrong here. An installer that
# proceeds because it could not find gpg is an installer with no
# security property at all, and "the check passed because the check did
# not run" is the exact false green this milestone's gate forbids. So:
# no gpg, no install. No signature file, no install. No manifest line
# for the artifact, no install.

set -eu

RV_TEST_KEY_MARKER='REPROBUILD UNTRUSTED TEST KEY'
RV_TEST_MARKER_FILE='SIGNING-KEY-IS-A-TEST-KEY'
RV_SUMS='SHA256SUMS'
RV_SUMS_SIG='SHA256SUMS.asc'

rv_log()  { printf 'repro-verify: %s\n' "$*" >&2; }
rv_fail() { printf 'repro-verify: REJECTED: %s\n' "$*" >&2; exit 1; }

keyring=''
dir=''
artifacts=''
allow_test_key=0
require_all=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keyring) keyring="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --artifact) artifacts="$artifacts $2"; shift 2 ;;
    --allow-test-key) allow_test_key=1; shift ;;
    --require-all) require_all=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) rv_fail "unknown argument: $1" ;;
  esac
done

[ -n "$keyring" ] || rv_fail '--keyring is required'
[ -n "$dir" ]     || rv_fail '--dir is required'
[ -d "$dir" ]     || rv_fail "--dir $dir is not a directory"

# ── 0. The tools must exist. Missing tools are a REJECTION. ──────────

if [ -n "${REPRO_GPG_BIN:-}" ]; then
  GPG="$REPRO_GPG_BIN"
elif command -v gpg >/dev/null 2>&1; then
  GPG="$(command -v gpg)"
elif command -v gpg2 >/dev/null 2>&1; then
  GPG="$(command -v gpg2)"
else
  rv_fail 'no gpg/gpg2 on PATH and $REPRO_GPG_BIN unset. Refusing to install unverified bytes.'
fi
command -v sha256sum >/dev/null 2>&1 \
  || rv_fail 'no sha256sum on PATH. Refusing to install unverified bytes.'

# ── 1. Ephemeral keyring. ────────────────────────────────────────────
#
# gpg is stateful. Verifying against ~/.gnupg would pass for any key the
# operator already trusts, INCLUDING when the release key was never
# imported — the test would then be measuring the operator's keyring.
# Every run starts from an empty home.

GNUPGHOME="$(mktemp -d "${TMPDIR:-/tmp}/repro-verify-gnupg-XXXXXX")"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf "$GNUPGHOME"
}
trap cleanup EXIT INT TERM

gpg_q() { "$GPG" --batch --no-tty --quiet --keyid-format long "$@"; }

imported=0
import_one() {
  f="$1"
  if gpg_q --import "$f" >/dev/null 2>&1; then
    imported=$((imported + 1))
  else
    rv_log "warning: could not import key material from $f"
  fi
}

if [ -d "$keyring" ]; then
  for f in "$keyring"/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.gpg|*.asc|*.key|*.pub) import_one "$f" ;;
    esac
  done
elif [ -f "$keyring" ]; then
  import_one "$keyring"
else
  rv_fail "--keyring $keyring is neither a file nor a directory"
fi

[ "$imported" -gt 0 ] \
  || rv_fail "no OpenPGP keys imported from $keyring; there is nothing to verify against"

key_count="$("$GPG" --batch --with-colons --list-keys 2>/dev/null | grep -c '^pub:' || true)"
[ "$key_count" -gt 0 ] \
  || rv_fail "keyring $keyring imported but holds zero public keys"
rv_log "trust anchor: $key_count key(s) from $keyring"

# ── 2. Test keys must be declared. ───────────────────────────────────

if "$GPG" --batch --with-colons --list-keys 2>/dev/null \
     | awk -F: '$1=="uid" {print $10}' | grep -qF "$RV_TEST_KEY_MARKER"; then
  if [ "$allow_test_key" -ne 1 ]; then
    rv_fail "the keyring contains a key marked '$RV_TEST_KEY_MARKER' and --allow-test-key was not given. A test key never verifies a release."
  fi
  rv_log "NOTE: verifying against a TEST key (--allow-test-key)."
fi

if [ -f "$dir/$RV_TEST_MARKER_FILE" ] && [ "$allow_test_key" -ne 1 ]; then
  rv_fail "$dir carries $RV_TEST_MARKER_FILE: it was signed by a throwaway test key and is not a release."
fi

# ── 3. The manifest signature. ───────────────────────────────────────

[ -f "$dir/$RV_SUMS" ] \
  || rv_fail "$RV_SUMS missing from $dir"
[ -f "$dir/$RV_SUMS_SIG" ] \
  || rv_fail "$RV_SUMS_SIG missing from $dir; an unsigned manifest is not evidence of anything"

status_file="$GNUPGHOME/status.txt"
set +e
"$GPG" --batch --no-tty --keyid-format long \
  --status-file "$status_file" \
  --verify "$dir/$RV_SUMS_SIG" "$dir/$RV_SUMS" >"$GNUPGHOME/verify.log" 2>&1
verify_rc=$?
set -e
if [ "$verify_rc" -ne 0 ]; then
  rv_log "--- gpg --verify output ---"
  cat "$GNUPGHOME/verify.log" >&2 || true
  rv_log "--- end gpg output ---"
  rv_fail "the signature on $RV_SUMS is not valid under $keyring (gpg exit $verify_rc)"
fi
# gpg can exit 0 on a signature it considers valid-but-untrusted; the
# machine-readable status is the thing to assert on, not the exit code.
grep -q '^\[GNUPG:\] VALIDSIG ' "$status_file" \
  || { cat "$GNUPGHOME/verify.log" >&2 || true;
       rv_fail "gpg exited 0 but emitted no VALIDSIG for $RV_SUMS"; }
signer="$(awk '/^\[GNUPG:\] VALIDSIG /{print $3; exit}' "$status_file")"
rv_log "$RV_SUMS signature OK, signer $signer"

# ── 4. Which artifacts? ──────────────────────────────────────────────

if [ -z "$artifacts" ] || [ "$require_all" -eq 1 ]; then
  artifacts="$(awk '{ $1=""; sub(/^[ \t]+/,""); print }' "$dir/$RV_SUMS")"
fi

n_checked=0
for a in $artifacts; do
  [ -n "$a" ] || continue

  # 4a. the manifest must MENTION it. A missing line is a rejection,
  #     never a skip -- otherwise an attacker deletes the line.
  line="$(awk -v want="$a" '{ n=$1; $1=""; sub(/^[ \t]+/,""); if ($0==want) print n }' "$dir/$RV_SUMS")"
  [ -n "$line" ] \
    || rv_fail "$a has no entry in the signed $RV_SUMS"
  hits="$(printf '%s\n' "$line" | grep -c .)"
  [ "$hits" -eq 1 ] \
    || rv_fail "$a appears $hits times in $RV_SUMS; a manifest with duplicate entries is ambiguous"

  # 4b. the bytes must be present and hash to it.
  [ -f "$dir/$a" ] || rv_fail "$a is listed in $RV_SUMS but not present in $dir"
  actual="$(sha256sum "$dir/$a" | awk '{print $1}')"
  if [ "$actual" != "$line" ]; then
    rv_fail "$a digest mismatch: signed manifest says $line, downloaded bytes are $actual"
  fi

  # 4c. and its own detached signature must verify.
  if [ -f "$dir/$a.asc" ]; then
    set +e
    "$GPG" --batch --no-tty --keyid-format long \
      --status-file "$GNUPGHOME/status-$n_checked.txt" \
      --verify "$dir/$a.asc" "$dir/$a" >"$GNUPGHOME/verify-$n_checked.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      cat "$GNUPGHOME/verify-$n_checked.log" >&2 || true
      rv_fail "detached signature $a.asc does not verify (gpg exit $rc)"
    fi
    grep -q '^\[GNUPG:\] VALIDSIG ' "$GNUPGHOME/status-$n_checked.txt" \
      || rv_fail "gpg exited 0 but emitted no VALIDSIG for $a.asc"
  else
    rv_fail "$a has no detached signature $a.asc"
  fi

  n_checked=$((n_checked + 1))
  rv_log "OK  $a  $actual"
done

[ "$n_checked" -gt 0 ] \
  || rv_fail 'zero artifacts were checked; a verification that checked nothing is not a pass'

printf 'repro-verify: ACCEPTED %d artifact(s), signer %s\n' "$n_checked" "$signer" >&2
exit 0
