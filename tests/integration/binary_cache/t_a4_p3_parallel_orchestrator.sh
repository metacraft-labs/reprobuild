#!/usr/bin/env bash
# t_a4_p3_parallel_orchestrator.sh — A4 P3 integration gate.
#
# Spawns 2 shell processes both running the SAME stub build against
# the SAME A2 binary-cache server. The build uses the new
# sentinel-aware path: the first process claims the sentinel, the
# second observes the claim and waits.
#
# Asserts:
#   * Both processes report PASS (exit 0).
#   * Exactly ONE process actually built (the other hit cache via
#     sentinel-wait OR via the post-publish cache HIT path).
#   * The resulting hex0 binary is byte-identical between the two
#     processes (same content-addressed bytes).
#
# Notes:
#
#  This test uses the process-parallel fallback (no real WSL distros)
#  to keep CI fast. The orchestrator's WSL mode is exercised in a
#  separate manual gate; the per-process flow is unchanged.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli.exe"
if [[ ! -f "$CLI_BIN" ]]; then
  CLI_BIN="$REPO_ROOT/build/test-bin/repro_binary_cache_client_cli"
fi
if [[ ! -f "$CLI_BIN" ]]; then
  a2_fail "CLI binary missing; build with:
  nim c -o:build/test-bin/repro_binary_cache_client_cli.exe \\
    apps/repro-binary-cache-client/repro_binary_cache_client_cli.nim"
fi

a2_start_server
TMP_PREFIX="$(mktemp -d -t a4p3-XXXXXX)"
trap 'a2_stop_server; rm -rf "$TMP_PREFIX"' EXIT

KEY_PATH="$TMP_PREFIX/producer.key"
CERT_PATH="$TMP_PREFIX/producer.cert"
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" gen-key >/dev/null

export REPRO_BINARY_CACHE_URL="$A2_BASE_URL"
export REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH"
export REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH"

# The stub build wraps the same prelude/postlude as build-hex0.sh.
# Each worker uses its OWN local store + output dir, but shares the
# binary cache URL.
STUB_BUILD="$TMP_PREFIX/stub_build.sh"
cat > "$STUB_BUILD" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
worker_id="$1"
out_dir="$2"
local_store="$3"
sleep_seconds="$4"
mkdir -p "$out_dir" "$local_store"

export REPRO_LOCAL_STORE="$local_store"
source "$REPRO_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"

cache_phase_prepare "$REPRO_REPO_ROOT/recipes/bootstrap/tcc-chain/scripts/build-hex0.sh" \
  "$out_dir" \
  --package-name=hex0 \
  --package-version=stage0-posix-Release_1.9.1 \
  --toolchain-name=stage0-posix \
  --toolchain-version=Release_1.9.1

echo "[worker $worker_id] cache-entry-key=$CACHE_KEY_HEX"

# A4 P3 sentinel-aware path: try to claim the sentinel BEFORE the
# expensive build. If the claim fails (409), poll until released.
SENT_BASE="$REPRO_BINARY_CACHE_URL"
SENT_KEY="$CACHE_KEY_HEX"

claim_sentinel() {
  curl -fsS -o /dev/null -w '%{http_code}' \
    -X POST --data "" \
    -H "X-Repro-Producer: worker-$worker_id" \
    -H "X-Repro-Sentinel-TTL: 300" \
    "$SENT_BASE/sentinel/$SENT_KEY" || true
}
get_sentinel_status() {
  curl -sS -o /dev/null -w '%{http_code}' \
    "$SENT_BASE/sentinel/$SENT_KEY"
}
release_sentinel() {
  curl -fsS -o /dev/null -X DELETE "$SENT_BASE/sentinel/$SENT_KEY" || true
}

if [[ "$CACHE_HIT" == "1" ]]; then
  if [[ -f "$out_dir/prefix/hex0" ]]; then
    mv "$out_dir/prefix/hex0" "$out_dir/hex0"
    rm -rf "$out_dir/prefix"
    echo "[worker $worker_id] [cache hit] hex0 from cache"
    exit 0
  fi
  rm -rf "$out_dir/prefix"
fi

# Try to claim. If a different producer holds it, wait until released
# OR up to 60s, then re-attempt the cache lookup.
status="$(claim_sentinel)"
if [[ "$status" == "201" ]]; then
  echo "[worker $worker_id] sentinel claimed; building"
  # Simulate a slow build so the parallel worker has time to observe
  # the sentinel and wait.
  sleep "$sleep_seconds"
  printf 'stub-hex0-binary-deterministic-content\n' > "$out_dir/hex0"
  chmod +x "$out_dir/hex0" || true
  cache_phase_publish "$out_dir/hex0"   # auto-releases the sentinel (X-Repro-Producer matches)
  release_sentinel
  echo "[worker $worker_id] [cache miss] built + published"
elif [[ "$status" == "409" ]]; then
  echo "[worker $worker_id] sentinel held by another producer; waiting"
  waited=0
  while (( waited < 60 )); do
    sleep 1
    waited=$((waited + 1))
    gs="$(get_sentinel_status)"
    if [[ "$gs" == "404" ]]; then
      echo "[worker $worker_id] sentinel released after ${waited}s; re-checking cache"
      break
    fi
  done
  # Now expect a cache HIT.
  if cache_lookup_and_substitute "$CACHE_KEY_HEX" "$out_dir/prefix"; then
    if [[ -f "$out_dir/prefix/hex0" ]]; then
      mv "$out_dir/prefix/hex0" "$out_dir/hex0"
      rm -rf "$out_dir/prefix"
      echo "[worker $worker_id] [cache hit] hex0 from cache (post-wait)"
      exit 0
    fi
  fi
  echo "[worker $worker_id] cache miss after wait; falling back to local build"
  printf 'stub-hex0-binary-deterministic-content\n' > "$out_dir/hex0"
  chmod +x "$out_dir/hex0" || true
  echo "[worker $worker_id] [cache miss] built without publish (fallback)"
else
  echo "[worker $worker_id] unexpected sentinel status: $status"
  exit 1
fi
EOS
chmod +x "$STUB_BUILD"

# Worker A starts first (claims), sleeps 3s during "build".
# Worker B starts 500ms later, sees the claim, waits, then hits cache.
LOG_A="$TMP_PREFIX/worker-A.log"
LOG_B="$TMP_PREFIX/worker-B.log"
OUT_A="$TMP_PREFIX/out-A"
OUT_B="$TMP_PREFIX/out-B"
STORE_A="$TMP_PREFIX/store-A"
STORE_B="$TMP_PREFIX/store-B"
export REPRO_REPO_ROOT="$REPO_ROOT"

bash "$STUB_BUILD" A "$OUT_A" "$STORE_A" 3 > "$LOG_A" 2>&1 &
PID_A=$!
sleep 0.5
bash "$STUB_BUILD" B "$OUT_B" "$STORE_B" 3 > "$LOG_B" 2>&1 &
PID_B=$!

wait "$PID_A" || true
exit_A=$?
wait "$PID_B" || true
exit_B=$?

echo "--- Worker A log ---"
cat "$LOG_A"
echo "--- Worker B log ---"
cat "$LOG_B"

if [[ "$exit_A" -ne 0 ]]; then
  a2_fail "Worker A exited $exit_A"
fi
if [[ "$exit_B" -ne 0 ]]; then
  a2_fail "Worker B exited $exit_B"
fi

# Exactly one worker should have published (cache miss + build).
# grep -c returns exit 1 when no matches; tolerate via || true so
# set -e doesn't kill the command substitution.
# Count via wc on per-file greps. Avoids the Windows-grep multi-file
# behavior that was returning early on the first no-match file.
count_lines() {
  # Count occurrences of a literal substring in a file without
  # tripping bash's set -e on grep's no-match exit status.
  local needle="$1" file="$2"
  set +e
  local n
  n=$(grep -Fc -- "$needle" "$file" 2>/dev/null)
  set -e
  echo "${n:-0}"
}
build_count_A=$(count_lines '[cache miss]' "$LOG_A")
build_count_B=$(count_lines '[cache miss]' "$LOG_B")
hit_count_A=$(count_lines '[cache hit]' "$LOG_A")
hit_count_B=$(count_lines '[cache hit]' "$LOG_B")
build_count=$((build_count_A + build_count_B))
hit_count=$((hit_count_A + hit_count_B))
if [[ "$build_count" -ne 1 ]]; then
  a2_fail "expected exactly 1 cache miss across the 2 workers, got $build_count"
fi
if [[ "$hit_count" -ne 1 ]]; then
  a2_fail "expected exactly 1 cache hit across the 2 workers, got $hit_count"
fi

# Bytes match.
if [[ ! -f "$OUT_A/hex0" ]] || [[ ! -f "$OUT_B/hex0" ]]; then
  a2_fail "hex0 binary missing from one worker output: A=$(test -f $OUT_A/hex0 && echo yes || echo no) B=$(test -f $OUT_B/hex0 && echo yes || echo no)"
fi
hash_A="$(sha256sum "$OUT_A/hex0" | awk '{print $1}')"
hash_B="$(sha256sum "$OUT_B/hex0" | awk '{print $1}')"
if [[ "$hash_A" != "$hash_B" ]]; then
  a2_fail "hex0 hash mismatch across workers: A=$hash_A B=$hash_B"
fi

a2_ok "t_a4_p3_parallel_orchestrator: 1-build / 1-cache-hit / byte-identical PASS"
