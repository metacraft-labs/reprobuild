#!/usr/bin/env bash
# t_a2_closure_compat.sh — A2 integration gate.
#
# Publish entry C declaring a dep on entry D (not in the store).
# Client lookup of C SUCCEEDS (the manifest is on the server), but
# materialization REJECTS because D's closure is unsatisfied.
#
# A2 ships the SERVER side. The substitution client is A2.5. We
# exercise the materialization-rejects boundary by re-using the
# helper to drive a closure-walker stub: read C's manifest, walk
# depReferences, GET each one, and assert the missing dep produces
# a 404 with a clear error string.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

# Forge a dep-entry-key hex of an entry we will NOT publish.
missingDepHex="$(printf 'f%.0s' {1..64})"  # 64 'f' chars = ff..ff x32 bytes

# Publish entry C with depReference -> missingDepHex.
entryHex="$(a2_publish_entry "closureC" "1.0.0" "C-bytes" "$missingDepHex")"

# Lookup C — succeeds.
Cbin="$A2_ROOT/C.bin"
if ! curl -fsS "$A2_BASE_URL/manifests/$entryHex" >"$Cbin"; then
  a2_fail "GET /manifests/$entryHex (entry C) failed"
fi
# Resolve Cbin to a path the native python can read (cygpath).
CbinWin="$(cygpath -w "$Cbin" 2>/dev/null || echo "$Cbin")"

# Walk C's depReferences (just the one). The server should answer
# 404 for missingDepHex with a clear "manifest not found" message.
code="$(curl -s -o "$A2_ROOT/missing.bin" -w "%{http_code}" \
  "$A2_BASE_URL/manifests/$missingDepHex")"
if [[ "$code" != "404" ]]; then
  a2_fail "expected 404 for missing dep; got $code"
fi
body="$(cat "$A2_ROOT/missing.bin")"
if [[ "$body" != *"not found"* ]]; then
  a2_fail "missing-dep response missing 'not found' citation: $body"
fi

# Closure-walk assertion: a substitute client would refuse to
# materialize C because its dep is unavailable. We model that here
# by asserting at least one dep ref in C's manifest resolves to a
# 404. The A2.5 client library will enforce the full topological
# walk + rejection.
parsed="$(a2_python -c "
import sys
b = open(r'''$CbinWin''','rb').read()
off = 4 + 2 + 2 + 32
key_block_len = int.from_bytes(b[off:off+4], 'little')
off += 4 + key_block_len
payload_count = int.from_bytes(b[off:off+4], 'little')
off += 4
for _ in range(payload_count):
    off += 1 + 1 + 8 + 8 + 32
    name_len = int.from_bytes(b[off:off+4], 'little')
    off += 4 + name_len
# realizedPrefixDigest
off += 32
dep_count = int.from_bytes(b[off:off+4], 'little')
off += 4
deps = []
for _ in range(dep_count):
    deps.append(b[off:off+32].hex())
    off += 32
print('|'.join(deps))
")"
if [[ "$parsed" != *"ffffff"* ]]; then
  a2_fail "C's manifest did not encode the missing dep ref we declared; got: $parsed"
fi

a2_ok "t_a2_closure_compat: lookup C succeeds; missing dep D yields 404; closure walker would reject materialization"
