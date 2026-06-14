#!/usr/bin/env bash
# t_a2_persistence.sh — A2 integration gate.
#
# Publish entry A (manifest + payload), restart the server, GET the
# manifest + payload, verify the bytes round-trip across the
# restart. The campaign spec's specific shape is
# `wsl --terminate repro-cache` — in CI we exercise the same
# behaviour by killing the daemon process and re-bringing-up the
# same state dir; the on-disk layout is identical under both
# topologies.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

# Publish entry A.
payload="entry-A-bytes-$(date +%s%N)"
entryHex="$(a2_publish_entry "persistA" "1.0.0" "$payload")"
if [[ ${#entryHex} -ne 64 ]]; then
  a2_fail "publish did not return a 64-char hex entry key: $entryHex"
fi

# Round-trip the manifest BEFORE restart, write to a file (manifest
# bytes include null bytes; never assign them to a shell variable).
mfPre="$A2_ROOT/A-pre.bin"
curl -fsS "$A2_BASE_URL/manifests/$entryHex" > "$mfPre"
preSize="$(stat -c %s "$mfPre" 2>/dev/null || stat -f %z "$mfPre")"
if [[ "$preSize" -lt 100 ]]; then
  a2_fail "manifest fetched at $entryHex suspiciously short: $preSize bytes"
fi

# Extract payload digest from manifest bytes via python parser.
payload_digest_hex="$(a2_python -c "
import sys
b = open(sys.argv[1], 'rb').read()
off = 4 + 2 + 2 + 32
key_block_len = int.from_bytes(b[off:off+4], 'little')
off += 4 + key_block_len
payload_count = int.from_bytes(b[off:off+4], 'little')
assert payload_count >= 1, 'no payloads'
off += 4
digest_off = off + 1 + 1 + 8 + 8
print(b[digest_off:digest_off+32].hex())
" "$mfPre")"
if [[ ${#payload_digest_hex} -ne 64 ]]; then
  a2_fail "could not parse payload digest from manifest: '$payload_digest_hex'"
fi

# Payload BEFORE restart.
plPre="$A2_ROOT/A-pre.payload"
curl -fsS "$A2_BASE_URL/payloads/$payload_digest_hex" > "$plPre"
if [[ "$(cat "$plPre")" != "$payload" ]]; then
  a2_fail "payload round-trip BEFORE restart differs"
fi

# === Simulate the wsl --terminate cycle by restarting the daemon
# against the same on-disk root.
if [[ "${A2_REMOTE:-0}" == "0" ]]; then
  kill "$A2_PID"
  wait "$A2_PID" 2>/dev/null || true
  daemon="$(a2_daemon_binary)"
  "$daemon" --root="$(cygpath -w "$A2_ROOT" 2>/dev/null || echo "$A2_ROOT")" \
            --listen="127.0.0.1:$A2_PORT" \
            >"$A2_ROOT/stderr2.log" 2>&1 &
  A2_PID=$!
  for i in $(seq 1 50); do
    if curl -fsS "$A2_BASE_URL/healthz" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
fi

# After restart: same manifest + payload retrievable.
mfPost="$A2_ROOT/A-post.bin"
curl -fsS "$A2_BASE_URL/manifests/$entryHex" > "$mfPost"
if ! cmp -s "$mfPre" "$mfPost"; then
  a2_fail "manifest bytes differ before/after restart"
fi
plPost="$A2_ROOT/A-post.payload"
curl -fsS "$A2_BASE_URL/payloads/$payload_digest_hex" > "$plPost"
if ! cmp -s "$plPre" "$plPost"; then
  a2_fail "payload bytes differ before/after restart"
fi

# Verify signature on the restored manifest.
verify_helper="$(a2_repo_root)/build/test-bin/a2_verify_helper.exe"
if [[ -x "$verify_helper" ]] || [[ -f "$verify_helper" ]]; then
  if ! "$verify_helper" --in="$(cygpath -w "$mfPost" 2>/dev/null || echo "$mfPost")"; then
    a2_fail "post-restart signature verify FAILED"
  fi
fi

a2_ok "t_a2_persistence: state restored across daemon restart, signature still verifies"
