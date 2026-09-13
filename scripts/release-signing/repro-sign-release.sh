#!/bin/sh
# Sign a directory of release artifacts.
#
#   repro-sign-release.sh --dir <staging-dir> --key <key-spec>
#                         [--export-key <path>] [--cosign]
#
# Emits, in <staging-dir>:
#
#   SHA256SUMS                 sorted manifest over every artifact
#   SHA256SUMS.asc             detached OpenPGP signature over it
#   <artifact>.asc             detached OpenPGP signature per artifact
#   SIGNING-KEY-IS-A-TEST-KEY  iff a test-class key signed (see lib)
#   <artifact>.sigstore        iff --cosign AND ambient OIDC exists
#
# The per-artifact detached signatures are not redundant with
# SHA256SUMS.asc. A consumer that fetches ONE asset (which is what the
# installer does, and what a user who clicks one release file does) can
# verify it without fetching and parsing the manifest; and a mirror that
# serves one file without the manifest cannot strip trust by omission.
# The manifest signature is what binds the SET together, so that
# *removing* an artifact is also detectable.
#
# GNUPGHOME handling: this script NEVER writes to the caller's keyring.
# It creates an ephemeral one and imports the secret key material the
# caller points at, so a run leaves no trace and cannot accidentally
# sign with whatever key the operator happened to have.

set -eu

RS_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
export RS_LIB_DIR
# shellcheck source=./lib-signing.sh
. "$RS_LIB_DIR/lib-signing.sh"

dir=''
key=''
secret_key_file=''
export_key_to=''
want_cosign=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --secret-key-file) secret_key_file="$2"; shift 2 ;;
    --export-key) export_key_to="$2"; shift 2 ;;
    --cosign) want_cosign=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) rs_die "unknown argument: $1" ;;
  esac
done

[ -n "$dir" ] || rs_die '--dir is required'
[ -d "$dir" ] || rs_die "--dir $dir is not a directory"
[ -n "$key" ] || rs_die '--key is required'

# ── Key custody ──────────────────────────────────────────────────────
#
# Two supported shapes, and they are NOT interchangeable:
#
#   --secret-key-file <path>   the governance pipeline materialised the
#                              key into a file for the duration of the
#                              job. We import it into an ephemeral home
#                              and shred our copy.
#   (neither)                  $GNUPGHOME already holds the key, e.g. a
#                              gpg-agent socket forwarded by the secret
#                              pipeline with no key bytes on disk at
#                              all. This is the preferred shape.
#
# In BOTH shapes this script runs against an ephemeral GNUPGHOME.

if [ -n "$secret_key_file" ]; then
  [ -f "$secret_key_file" ] || rs_die "--secret-key-file $secret_key_file not found"
  home="$(rs_ephemeral_gnupghome)"
  trap 'rs_cleanup_gnupghomes' EXIT INT TERM
  rs_gpg --import "$secret_key_file" >/dev/null 2>&1 \
    || rs_die "gpg --import failed for $secret_key_file"
  rs_log "imported signing key material into ephemeral $home"
elif [ -n "${GNUPGHOME:-}" ]; then
  rs_log "using caller-supplied GNUPGHOME=$GNUPGHOME"
else
  rs_die 'no key material: pass --secret-key-file, or set GNUPGHOME to a home the governance pipeline prepared. This script will not fall back to ~/.gnupg.'
fi

class="$(rs_require_signing_key "$key")"
fpr="$(rs_fingerprint_of "$key")"

# ── The manifest ─────────────────────────────────────────────────────

rm -f "$dir/$RS_SUMS_FILE" "$dir/$RS_SUMS_SIG" "$dir/$RS_TEST_MARKER_FILE"
count="$(rs_write_sha256sums "$dir")"

# ── Signatures ───────────────────────────────────────────────────────

rs_detach_sign "$key" "$dir/$RS_SUMS_FILE"
rs_log "signed $RS_SUMS_FILE -> $RS_SUMS_SIG"

signed=0
rs_artifact_names "$dir" | while IFS= read -r b; do
  rs_detach_sign "$key" "$dir/$b"
done
signed="$(rs_artifact_names "$dir" | wc -l | tr -d ' ')"
rs_log "signed $signed artifact(s) with detached .asc"

# Assert, rather than assume, that every artifact got a signature. A
# `while` loop that iterates zero times is the classic vacuous pass.
missing=0
for b in $(rs_artifact_names "$dir"); do
  [ -s "$dir/$b.asc" ] || { rs_log "MISSING signature for $b"; missing=$((missing + 1)); }
done
[ "$missing" -eq 0 ] || rs_die "$missing artifact(s) ended up unsigned"
[ "$signed" -eq "$count" ] \
  || rs_die "manifest covers $count artifact(s) but $signed were signed"

# ── The test-key marker ──────────────────────────────────────────────

if [ "$class" = test ]; then
  {
    printf 'This bundle was signed with a THROWAWAY TEST KEY.\n'
    printf 'Fingerprint: %s\n' "$fpr"
    printf 'It is NOT a reprobuild release. Do not publish it.\n'
    printf '\n'
    printf 'repro-verify-release.sh refuses this bundle unless it is\n'
    printf 'passed --allow-test-key, so nothing downstream can treat it\n'
    printf 'as genuine by accident.\n'
  } > "$dir/$RS_TEST_MARKER_FILE"
  rs_log "dropped $RS_TEST_MARKER_FILE"
fi

# ── Optional public key export (for a repo's client config) ──────────

if [ -n "$export_key_to" ]; then
  rs_gpg --armor --export "$key" > "$export_key_to" \
    || rs_die "gpg --export failed"
  [ -s "$export_key_to" ] || rs_die "exported key at $export_key_to is empty"
  rs_log "exported public key to $export_key_to"
fi

# ── Optional cosign keyless ──────────────────────────────────────────

if [ "$want_cosign" -eq 1 ]; then
  rs_cosign_sign_blob "$dir/$RS_SUMS_FILE" || cosign_rc=$?
  cosign_rc="${cosign_rc:-0}"
  case "$cosign_rc" in
    0) rs_log 'cosign keyless: signed' ;;
    2) rs_log 'cosign keyless: NOT performed (see reason above). The GPG signatures above stand on their own.' ;;
    *) rs_die 'cosign keyless was available but failed' ;;
  esac
fi

rs_log "done: $count artifact(s), key class=$class, fingerprint=$fpr"
