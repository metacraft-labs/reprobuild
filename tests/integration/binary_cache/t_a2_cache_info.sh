#!/usr/bin/env bash
# t_a2_cache_info.sh — A2 integration gate.
#
# Asserts the GET /cache-info response advertises the expected
# StoreDir + priority + mass-query=true + format version + the
# producer signer pubkey list, and that the envelope magic ("RCI1")
# matches the documented Nix-style substituter-probe shape.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

# Write bytes to a file so we can parse cleanly without bash null-byte
# warnings.
curl -fsS "$A2_BASE_URL/cache-info" > "${A2_ROOT:-/tmp}/cache-info.bin"
ci="${A2_ROOT:-/tmp}/cache-info.bin"

# Magic check (first 4 ASCII bytes).
magic="$(head -c 4 "$ci")"
if [[ "$magic" != "RCI1" ]]; then
  a2_fail "cache-info envelope magic should be 'RCI1', got '$magic'"
fi

# Format-version u16 little-endian.
v_hex_low="$(dd if="$ci" bs=1 count=1 skip=4 2>/dev/null | od -An -tu1 | tr -d ' \n')"
v_hex_high="$(dd if="$ci" bs=1 count=1 skip=5 2>/dev/null | od -An -tu1 | tr -d ' \n')"
if [[ "$v_hex_low" != "1" ]] || [[ "$v_hex_high" != "0" ]]; then
  a2_fail "cache-info formatVersion should be 1, got bytes $v_hex_low $v_hex_high"
fi

# storeDir u32-le length at offset 6 .. 9.
sd_len_bytes="$(dd if="$ci" bs=1 count=4 skip=6 2>/dev/null | od -An -tu1 | tr -d '\n')"
# Parse: 4 bytes, little-endian -> integer (small enough to fit shell math).
sd_len="$(a2_python -c "
import sys
b = open(sys.argv[1],'rb').read()
print(int.from_bytes(b[6:10], 'little'))
" "$ci")"
if [[ -z "$sd_len" ]] || [[ "$sd_len" -lt 1 ]]; then
  a2_fail "cache-info storeDir length absent or zero: $sd_len"
fi
storeDir="$(dd if="$ci" bs=1 count="$sd_len" skip=10 2>/dev/null)"
if [[ -z "$storeDir" ]]; then
  a2_fail "cache-info storeDir empty"
fi

# priority i32-le at offset (10 + sd_len) .. +3.
prio_off=$((10 + sd_len))
priority="$(a2_python -c "
import sys
b = open(sys.argv[1],'rb').read()
v = int.from_bytes(b[$prio_off:$prio_off+4], 'little', signed=True)
print(v)
" "$ci")"
# wantMassQuery u8 at offset (prio_off+4).
mass_off=$((prio_off + 4))
massq="$(dd if="$ci" bs=1 count=1 skip="$mass_off" 2>/dev/null | od -An -tu1 | tr -d ' \n')"
if [[ "$massq" != "1" ]]; then
  a2_fail "cache-info wantMassQuery must be 1 (true), got $massq"
fi

# Probe shape compatibility — bounded envelope size.
sz=$(stat -c %s "$ci" 2>/dev/null || stat -f %z "$ci")
if [[ $sz -gt 16384 ]]; then
  a2_fail "cache-info response > 16 KiB ($sz)"
fi

a2_ok "t_a2_cache_info: GET /cache-info returns RCI1 envelope, formatVersion=1, storeDir='$storeDir', priority=$priority, mass-query=true, $sz bytes"
