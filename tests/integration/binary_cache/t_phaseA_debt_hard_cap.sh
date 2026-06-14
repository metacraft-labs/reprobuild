#!/usr/bin/env bash
# t_phaseA_debt_hard_cap.sh — Phase A debt-closure D2 gate.
#
# Drives the hard-cap rejection path on the publish handler (the
# TODO that A4 P4's EVICTION-POLICY.md called out for the P6
# follow-up: the policy primitive shipped, but the publish handler
# wasn't gated on it).
#
# Scenario:
#
#   1. Boot the daemon under a tight 16 KiB hard cap so a couple of
#      ~6 KiB payloads exceed it.
#   2. Publish a small entry: must succeed (200 OK + entry-key hex).
#   3. Publish a second small entry: still under cap, must succeed.
#   4. Publish a third small entry: projected footprint exceeds cap.
#      Must reject with HTTP 507.
#   5. Verify the on-disk footprint did NOT change after the rejected
#      publish (i.e. no orphan payload bytes leaked into the CAS).
#
# Additionally probes the "soft cap disabled" leg: the soft cap is
# set above the hard cap so the test isn't racing the sweeper.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Custom server bring-up: we need a tight hard cap that the
# default a2_start_server doesn't expose. We replicate the helper's
# wiring inline with a per-test override on the env vars.
a2_pick_port() {
  python3 -c '
import socket, random
random.seed()
for _ in range(50):
    p = random.randint(24000, 31000)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        s.close()
        print(p)
        raise SystemExit(0)
    except OSError:
        s.close()
raise SystemExit(1)
'
}

PORT="$(a2_pick_port)"
ROOT="$(mktemp -d -t rbc-hardcap-XXXXXX)"
DAEMON="$(a2_daemon_binary)"
if [[ ! -f "$DAEMON" ]]; then
  echo "daemon binary not found at $DAEMON" >&2
  exit 1
fi

A2_ROOT="$ROOT"
A2_PORT="$PORT"
A2_BASE_URL="http://127.0.0.1:$PORT"
A2_REMOTE=0

HARD_CAP_BYTES=16384      # 16 KiB
SOFT_CAP_BYTES=131072     # 128 KiB — well above the hard cap so the
                          # sweeper doesn't interfere with our footprint
                          # measurement.

ROOT_WIN="$(cygpath -w "$ROOT" 2>/dev/null || echo "$ROOT")"

REPRO_BINARY_CACHE_HARD_CAP_BYTES="$HARD_CAP_BYTES" \
REPRO_BINARY_CACHE_SOFT_CAP_BYTES="$SOFT_CAP_BYTES" \
"$DAEMON" --root="$ROOT_WIN" \
          --listen="127.0.0.1:$PORT" \
          >"$ROOT/stderr.log" 2>&1 &
A2_PID=$!

cleanup() {
  if [[ -n "${A2_PID:-}" ]]; then
    kill "$A2_PID" 2>/dev/null || true
    wait "$A2_PID" 2>/dev/null || true
  fi
  if [[ -d "$ROOT" ]]; then
    rm -rf "$ROOT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Wait for bind.
for i in $(seq 1 50); do
  if curl -fsS "$A2_BASE_URL/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! curl -fsS "$A2_BASE_URL/healthz" >/dev/null 2>&1; then
  echo "daemon failed to bind on $A2_BASE_URL within 5s. Logs:" >&2
  cat "$ROOT/stderr.log" >&2 || true
  exit 1
fi

# Construct a payload sized so 3 publishes push us over the hard cap.
# Each payload is ~7 KiB; 3 * 7 KiB = 21 KiB > 16 KiB hard cap.
mk_payload() {
  local label="$1"
  # Each block is ~53 chars; repeat 144 times to land ~7600 bytes.
  # Each label produces a distinct payload so the CAS digest is
  # different and the conservative projection sees 3 distinct
  # payload byte streams.
  local block="${label}-XXXX-${label}-YYYY-${label}-ZZZZ-${label}-WWWW-${label}-PPPP-${label}-QQQQ"
  local out=""
  for i in $(seq 1 144); do
    out+="$block"
  done
  printf '%s' "$out"
}

# Footprint helper: sum CAS blob sizes under <root>/store/cas/blake3.
cas_footprint() {
  local root="$1"
  local total=0
  if [[ -d "$root/store/cas/blake3" ]]; then
    total="$(find "$root/store/cas/blake3" -type f -printf '%s\n' 2>/dev/null | awk 'BEGIN{s=0}{s+=$1}END{print s+0}')"
  fi
  printf '%s' "$total"
}

PAYLOAD_A="$(mk_payload aaa)"
PAYLOAD_B="$(mk_payload bbb)"
PAYLOAD_C="$(mk_payload ccc)"

# Per the conservative projection (sum of incoming bytes) the third
# publish's incoming-size + current footprint will exceed the cap.
HELPER="$(a2_repo_root)/build/test-bin/a2_publish_helper.exe"
if [[ ! -f "$HELPER" ]]; then
  echo "publish helper not built" >&2
  exit 1
fi

echo "[hard-cap] publish 1: expect 200 OK"
"$HELPER" --url="$A2_BASE_URL" \
          --package="hcap-pkg-a" --version="1.0.0" \
          --payload="$PAYLOAD_A" >/dev/null
FOOT_AFTER_1="$(cas_footprint "$ROOT")"
if [[ "$FOOT_AFTER_1" -lt 7000 ]]; then
  echo "FAIL: footprint after publish 1 too small: $FOOT_AFTER_1" >&2
  exit 1
fi

echo "[hard-cap] publish 2: expect 200 OK"
"$HELPER" --url="$A2_BASE_URL" \
          --package="hcap-pkg-b" --version="1.0.0" \
          --payload="$PAYLOAD_B" >/dev/null
FOOT_AFTER_2="$(cas_footprint "$ROOT")"
if [[ "$FOOT_AFTER_2" -le "$FOOT_AFTER_1" ]]; then
  echo "FAIL: footprint should grow after publish 2 (was $FOOT_AFTER_1, now $FOOT_AFTER_2)" >&2
  exit 1
fi

echo "[hard-cap] publish 3: expect 507 Insufficient Storage"
"$HELPER" --url="$A2_BASE_URL" \
          --package="hcap-pkg-c" --version="1.0.0" \
          --payload="$PAYLOAD_C" \
          --expect-status=507 >/dev/null
FOOT_AFTER_3="$(cas_footprint "$ROOT")"
# Footprint must NOT have changed: no orphan blob from the rejected
# publish. Allow exact equality.
if [[ "$FOOT_AFTER_3" != "$FOOT_AFTER_2" ]]; then
  echo "FAIL: hard-cap rejection leaked bytes: before=$FOOT_AFTER_2 after=$FOOT_AFTER_3" >&2
  exit 1
fi

# Sanity: the over-cap publish should also leave no manifest behind
# (manifest is written AFTER payload checks succeed).
MANIFEST_COUNT="$(find "$ROOT/manifests" -name '*.manifest' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$MANIFEST_COUNT" != "2" ]]; then
  echo "FAIL: expected 2 manifests on disk (publish 1+2 succeeded), got $MANIFEST_COUNT" >&2
  exit 1
fi

# Sanity: the daemon's stderr log should mention the hard-cap rejection.
# (The PublishCapacityError message includes 'hard-cap=' and 'incoming='.)
# Note: the message lives inside the 507 response body the helper prints
# on stderr; we don't fail the test if it's missing from the daemon log
# because asynchttpserver's logging is conservative.

echo "PASS: t_phaseA_debt_hard_cap"
echo "  publish 1 footprint: $FOOT_AFTER_1 bytes"
echo "  publish 2 footprint: $FOOT_AFTER_2 bytes"
echo "  publish 3 rejected   (no footprint change): $FOOT_AFTER_3 bytes"
echo "  hard cap:            $HARD_CAP_BYTES bytes"
