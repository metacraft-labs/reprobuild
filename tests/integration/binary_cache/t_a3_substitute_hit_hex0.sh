#!/usr/bin/env bash
# t_a3_substitute_hit_hex0.sh — ReproOS-Generations-And-Foreign-Packages A3 P3 gate.
#
# Validates the build-hex0.sh cache wiring without needing the
# upstream stage0-posix vendor blob (which is not vendored into the
# Windows host CI). The test:
#
#   1. Spins up an A2 binary-cache server.
#   2. Generates a producer ECDSA-P256 keypair under a temp dir.
#   3. Sets REPRO_BINARY_CACHE_URL / KEY_PATH / CERT_PATH so the
#      cache-helper.sh prelude/postlude in build-hex0.sh can find
#      them.
#   4. Invokes a STUB build-hex0.sh (the cache-aware harness body
#      from the real script with the actual hex0-seed step replaced
#      by a deterministic synthetic output). The first run hits a
#      cache MISS, runs the synthetic "build", publishes.
#   5. Wipes the output dir, invokes the stub a second time. Verifies
#      a cache HIT — the synthetic build does NOT run; the bytes are
#      recovered from the binary cache.
#   6. Asserts the second run's wall-clock < 8 s (the substitute path
#      is bounded by the local network + tiny payload size).
#
# This test exercises the SAME prelude / postlude that the real
# build-hex0.sh uses. The cache key is derived from the same
# identity-flag block; behaviour-equivalence with the actual build
# script is enforced by sharing cache-helper.sh.

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
trap 'a2_stop_server' EXIT

# Ephemeral state directories for the test.
TMP_PREFIX="$(mktemp -d -t a3p3-XXXXXX)"
trap 'a2_stop_server; rm -rf "$TMP_PREFIX"' EXIT
KEY_PATH="$TMP_PREFIX/producer.key"
CERT_PATH="$TMP_PREFIX/producer.cert"
OUT_DIR_1="$TMP_PREFIX/out1"
OUT_DIR_2="$TMP_PREFIX/out2"
CLIENT_STORE="$TMP_PREFIX/client-store"
mkdir -p "$CLIENT_STORE"

# Materialise a producer keypair via the CLI's gen-key subcommand.
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" gen-key >/dev/null
if [[ ! -f "$KEY_PATH" || ! -f "$CERT_PATH" ]]; then
  a2_fail "producer keypair generation failed under $TMP_PREFIX"
fi

export REPRO_BINARY_CACHE_URL="$A2_BASE_URL"
export REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH"
export REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH"
export REPRO_LOCAL_STORE="$CLIENT_STORE"

# ---------------------------------------------------------------------------
# Stub build-hex0.sh harness — mirrors the cache prelude + postlude from
# the real script, with the actual hex0-seed run replaced by a synthetic
# deterministic "build".
# ---------------------------------------------------------------------------

source "$REPO_ROOT/recipes/cache/scripts/cache-helper.sh"

run_stub_build() {
  local out_abs="$1"
  mkdir -p "$out_abs"

  # Use the SAME cache-helper prelude that build-hex0.sh uses so this
  # test stays in lockstep with the real script.
  cache_phase_prepare "$REPO_ROOT/recipes/bootstrap/tcc-chain/scripts/build-hex0.sh" \
    "$out_abs" \
    --package-name=hex0 \
    --package-version=stage0-posix-Release_1.9.1 \
    --toolchain-name=stage0-posix \
    --toolchain-version=Release_1.9.1
  echo "[stub] cache-entry-key=$CACHE_KEY_HEX"

  if [[ "$CACHE_HIT" == "1" ]]; then
    if [[ -f "$out_abs/prefix/hex0" ]]; then
      mv "$out_abs/prefix/hex0" "$out_abs/hex0"
      rm -rf "$out_abs/prefix"
      echo "[stub] [cache hit] hex0 from cache"
      return 0
    fi
    rm -rf "$out_abs/prefix"
  fi
  echo "[stub] cache miss; running stub build."

  # Synthetic build: write deterministic bytes for the hex0 binary.
  printf 'stub-hex0-binary-deterministic-content\n' > "$out_abs/hex0"
  chmod +x "$out_abs/hex0" || true

  # Publish via the shared postlude helper.
  cache_phase_publish "$out_abs/hex0"
}

# --- Run 1: expect MISS -----------------------------------------------------
echo "=== Run 1 (clean cache) ==="
t0=$(date +%s)
run_stub_build "$OUT_DIR_1"
t1=$(date +%s)
elapsed1=$((t1 - t0))
echo "Run 1 wall-clock: ${elapsed1}s"

if grep -q "cache hit" <<<"$(run_stub_build "$TMP_PREFIX/probe")" 2>/dev/null; then
  # The probe run above is for the next clean iteration; do not assert
  # on its output. (Kept simple: we just need run-2 below.)
  :
fi

# --- Run 2: expect HIT ------------------------------------------------------
echo "=== Run 2 (post-publish) ==="
t2=$(date +%s)
RUN2_OUT="$(run_stub_build "$OUT_DIR_2")"
t3=$(date +%s)
elapsed2=$((t3 - t2))
echo "$RUN2_OUT"
echo "Run 2 wall-clock: ${elapsed2}s"

if ! grep -q "cache hit" <<<"$RUN2_OUT"; then
  a2_fail "Run 2 did NOT report 'cache hit'; got:
$RUN2_OUT"
fi

# Bytes match between runs.
hash1="$(sha256sum "$OUT_DIR_1/hex0" | awk '{print $1}')"
hash2="$(sha256sum "$OUT_DIR_2/hex0" | awk '{print $1}')"
if [[ "$hash1" != "$hash2" ]]; then
  a2_fail "hex0 hash mismatch: run1=$hash1 run2=$hash2"
fi

# Wall-clock budget: substitute path < 8 s on a local network.
if (( elapsed2 > 8 )); then
  a2_fail "Run 2 wall-clock ${elapsed2}s exceeded 8s budget"
fi

a2_ok "t_a3_substitute_hit_hex0 — publish + substitute + byte-identical round-trip"
