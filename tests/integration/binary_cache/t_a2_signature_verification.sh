#!/usr/bin/env bash
# t_a2_signature_verification.sh — A2 integration gate.
#
# Publish entry B with a valid signature. Then tamper with the
# server-stored manifest at rest (flip a single byte inside the
# realized-prefix digest region — covered by the signature but not
# by the entry-key sentinel). Verify that:
#
#   1. The unmodified manifest verifies on GET.
#   2. After tampering, the verifier raises BinaryCacheSignatureError
#      via a thin Nim-side verify helper invoked from bash.
#
# The publish-side test (server REJECTS the tampered manifest on
# publish) is exercised separately via --tamper-manifest in
# a2_publish_helper; we exercise the GET-side here.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

# --- Test 1: publish with --tamper-manifest is rejected by the server.
helper="$(a2_repo_root)/build/test-bin/a2_publish_helper.exe"
if "$helper" --url="$A2_BASE_URL" \
             --package="sigreject" --version="1.0.0" \
             --payload="will-be-rejected" \
             --tamper-manifest 2>/dev/null; then
  a2_fail "server accepted a tampered manifest at publish — verifier broken"
fi
a2_ok "t_a2_signature_verification: server rejects tampered manifest at publish boundary"

# --- Test 2: publish a clean manifest, fetch it, byte-tamper it
# client-side, verify the verifier rejects on the consumer side.
entryHex="$(a2_publish_entry "sigaccept" "1.0.0" "valid-payload-bytes")"

# Fetch the manifest, flip a byte, attempt a verify via a small
# Nim helper. The helper is built once at gate time alongside
# a2_publish_helper.
verify_helper="$(a2_repo_root)/build/test-bin/a2_verify_helper.exe"
if [[ ! -f "$verify_helper" ]]; then
  a2_fail "a2_verify_helper not built (run scripts/run-a2-gate.ps1 once to build it)"
fi

# Fresh manifest verifies.
curl -fsS "$A2_BASE_URL/manifests/$entryHex" > "$A2_ROOT/clean.bin"
if ! "$verify_helper" --in="$(cygpath -w "$A2_ROOT/clean.bin" 2>/dev/null || echo "$A2_ROOT/clean.bin")"; then
  a2_fail "verify_helper rejected a freshly-served valid manifest"
fi

# Tamper: flip the byte at offset 50 (lands inside the producer-
# selected payload list).
"$verify_helper" --tamper="$(cygpath -w "$A2_ROOT/clean.bin" 2>/dev/null || echo "$A2_ROOT/clean.bin")" --out="$(cygpath -w "$A2_ROOT/tampered.bin" 2>/dev/null || echo "$A2_ROOT/tampered.bin")"
if "$verify_helper" --in="$(cygpath -w "$A2_ROOT/tampered.bin" 2>/dev/null || echo "$A2_ROOT/tampered.bin")" 2>"$A2_ROOT/verify_err.txt"; then
  a2_fail "verify_helper accepted the tampered manifest"
fi
if ! grep -qiE "signature|tamper" "$A2_ROOT/verify_err.txt"; then
  a2_fail "verify error message missing 'signature' / 'tamper' citation: $(cat "$A2_ROOT/verify_err.txt")"
fi

a2_ok "t_a2_signature_verification: client verifier rejects tampered manifest with signature-citing error"
