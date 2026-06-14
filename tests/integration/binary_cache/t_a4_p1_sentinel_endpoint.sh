#!/usr/bin/env bash
# t_a4_p1_sentinel_endpoint.sh — A4 P1 integration gate.
#
# Exercises the four sentinel REST operations end-to-end against a
# freshly-provisioned in-process daemon:
#
#   1. POST /sentinel/<key> with producer A    -> 201
#   2. GET  /sentinel/<key>                     -> 200, TTL > 0,
#                                                 X-Repro-Sentinel-Producer = producer-a
#   3. POST /sentinel/<key> with producer B    -> 409
#   4. DELETE /sentinel/<key>                    -> 200
#   5. GET  /sentinel/<key>                     -> 404
#   6. POST /sentinel/<key> with TTL=1s         -> 201
#   7. sleep 2.5s
#   8. GET  /sentinel/<key>                     -> 404 (expired; lazy sweep)
#   9. POST /sentinel/<key> (same key)          -> 201 (overwrites expired)
#
# Plus a publish auto-release leg: POST sentinel, publish a manifest
# under the same entry-key with the SAME producer header, GET sentinel
# -> 404. (We exercise the auto-release path via the same
# a2_publish_helper used by the A2.5 / A3 tests; the helper passes
# through the X-Repro-Producer header when given --producer.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

KEY="$(printf '%064s' '' | tr ' ' 'a')"  # 64 hex 'a' chars

# 1) Fresh claim
status="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -X POST \
  --data "" \
  -H "X-Repro-Producer: producer-a" \
  -H "X-Repro-Sentinel-TTL: 60" \
  "$A2_BASE_URL/sentinel/$KEY" || echo "ERR")"
if [[ "$status" != "201" ]]; then
  a2_fail "fresh claim should return 201, got $status"
fi

# 2) GET sees the claim
body_file="$(mktemp)"
hdr_file="$(mktemp)"
status="$(curl -fsS -D "$hdr_file" -o "$body_file" -w '%{http_code}' \
  "$A2_BASE_URL/sentinel/$KEY")"
if [[ "$status" != "200" ]]; then
  a2_fail "GET on live sentinel should return 200, got $status"
fi
remain="$(cat "$body_file" | tr -d '\r\n ')"
if [[ -z "$remain" ]] || [[ "$remain" -lt 1 ]]; then
  a2_fail "remaining TTL should be > 0, got '$remain'"
fi
prod_hdr="$(grep -i '^x-repro-sentinel-producer:' "$hdr_file" | tr -d '\r' | awk -F': ' '{print $2}')"
if [[ "$prod_hdr" != "producer-a" ]]; then
  a2_fail "GET should echo producer header = producer-a, got '$prod_hdr'"
fi

# 3) Conflict from a different producer
status="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST \
  --data "" \
  -H "X-Repro-Producer: producer-b" \
  "$A2_BASE_URL/sentinel/$KEY" || echo "ERR")"
if [[ "$status" != "409" ]]; then
  a2_fail "second-claim by different producer should return 409, got $status"
fi

# 4) Release
status="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -X DELETE \
  "$A2_BASE_URL/sentinel/$KEY" || echo "ERR")"
if [[ "$status" != "200" ]]; then
  a2_fail "DELETE on live sentinel should return 200, got $status"
fi

# 5) GET sees the absence
status="$(curl -sS -o /dev/null -w '%{http_code}' \
  "$A2_BASE_URL/sentinel/$KEY")"
if [[ "$status" != "404" ]]; then
  a2_fail "GET on released sentinel should return 404, got $status"
fi

# 6) Short-TTL claim
status="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -X POST \
  --data "" \
  -H "X-Repro-Producer: producer-a" \
  -H "X-Repro-Sentinel-TTL: 1" \
  "$A2_BASE_URL/sentinel/$KEY" || echo "ERR")"
if [[ "$status" != "201" ]]; then
  a2_fail "TTL=1 fresh claim should return 201, got $status"
fi

# 7) Sleep past TTL
sleep 2

# 8) Lazy-sweep eviction on GET
status="$(curl -sS -o /dev/null -w '%{http_code}' \
  "$A2_BASE_URL/sentinel/$KEY")"
if [[ "$status" != "404" ]]; then
  a2_fail "GET past TTL should return 404 (lazy sweep), got $status"
fi

# 9) Reclaim after expiry
status="$(curl -fsS -o /dev/null -w '%{http_code}' \
  -X POST \
  --data "" \
  -H "X-Repro-Producer: producer-c" \
  -H "X-Repro-Sentinel-TTL: 30" \
  "$A2_BASE_URL/sentinel/$KEY" || echo "ERR")"
if [[ "$status" != "201" ]]; then
  a2_fail "reclaim after expiry should return 201, got $status"
fi

# Clean up the synthetic key.
curl -fsS -X DELETE "$A2_BASE_URL/sentinel/$KEY" > /dev/null

# 10) Publish auto-release leg.
# Publish goes through the helper which derives the entry-key from
# the package metadata; we issue a claim under a known producer with
# the SAME key the helper will derive, then verify publish drops it.

# Helper publishes a manifest and prints its entry-key hex. We claim
# the sentinel under that key with --producer=producer-publish, then
# the second helper invocation in publish-mode releases on success.
PUBLISH_HEX="$(a2_publish_entry p1-auto-release 1.0.0 sentinel-payload)"
if [[ -z "$PUBLISH_HEX" ]]; then
  a2_fail "publish helper produced empty entry-key"
fi
# Re-publish with producer header — but the helper doesn't send it.
# Instead, do an end-to-end test directly: claim then publish via
# helper that DOES carry the producer header (helper supports
# --producer flag for the A4 auto-release check).
KEY2="$PUBLISH_HEX"
curl -fsS -o /dev/null -X POST \
  --data "" \
  -H "X-Repro-Producer: producer-publish" \
  "$A2_BASE_URL/sentinel/$KEY2"

# Re-publish the same manifest with the auto-release producer header.
a2_publish_entry_with_producer p1-auto-release 1.0.0 sentinel-payload producer-publish > /dev/null

status="$(curl -sS -o /dev/null -w '%{http_code}' \
  "$A2_BASE_URL/sentinel/$KEY2")"
if [[ "$status" != "404" ]]; then
  a2_fail "publish should auto-release sentinel for matching producer (key=$KEY2), got $status"
fi

a2_ok "t_a4_p1_sentinel_endpoint: claim+GET+conflict+release+TTL-expiry+publish-auto-release all PASS"
