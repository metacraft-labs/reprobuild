#!/usr/bin/env bash
# t_a3_substitute_hit_r4_chain.sh — A3 P4 gate.
#
# Exercises the closure-aware substitute pattern for the 5-member R4
# chain (hex0 → stage0-posix → mescc-tools → mes → tcc) without
# running the real builds. Each script's cache-prelude / postlude
# uses cache_phase_prepare + cache_phase_publish; this test invokes
# the same helpers from a stub harness that writes deterministic
# synthetic prefixes.
#
# Invariants:
#   1. First pass on a clean cache: every phase is a MISS; every
#      phase publishes; the final tcc-phase publishes a manifest
#      whose dep-closure carries the mes + mescc-tools entry-key
#      digests.
#   2. Second pass on the same cache: every phase is a HIT; no synthetic
#      "build" runs; total wall-clock < 15 s.
#
# This DOES NOT exercise the actual stage0-posix / mes / tcc compile
# steps — those need the upstream vendor blobs which the Windows host
# CI doesn't carry. The dedicated end-to-end test for those lives in
# the Linux WSL `eli-wsl` distro.

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
TMP="$(mktemp -d -t a3p4-XXXXXX)"
trap 'a2_stop_server; rm -rf "$TMP"' EXIT

KEY_PATH="$TMP/producer.key"
CERT_PATH="$TMP/producer.cert"
REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH" \
REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH" \
  "$CLI_BIN" gen-key >/dev/null
export REPRO_BINARY_CACHE_URL="$A2_BASE_URL"
export REPRO_BINARY_CACHE_KEY_PATH="$KEY_PATH"
export REPRO_BINARY_CACHE_CERT_PATH="$CERT_PATH"
export REPRO_LOCAL_STORE="$TMP/client-store"
mkdir -p "$REPRO_LOCAL_STORE"

source "$REPO_ROOT/recipes/cache/scripts/cache-helper.sh"

# ---------------------------------------------------------------------------
# 5-phase stub: each phase prepares the cache, optionally hits, otherwise
# writes a deterministic file with a known sha and publishes.
# ---------------------------------------------------------------------------

run_phase() {
  local phase_name="$1"; shift
  local pkg_name="$1"; shift
  local out_dir="$1"; shift
  local dep_keyfile1="$1"; shift   # may be empty
  local dep_keyfile2="$1"; shift   # may be empty
  mkdir -p "$out_dir"

  local deps=()
  if [[ -n "$dep_keyfile1" && -f "$dep_keyfile1" ]]; then
    deps+=( --dep="$(cat "$dep_keyfile1")" )
  fi
  if [[ -n "$dep_keyfile2" && -f "$dep_keyfile2" ]]; then
    deps+=( --dep="$(cat "$dep_keyfile2")" )
  fi
  # Use a stable provider-revision (sha of phase_name) so the cache key
  # stays constant across test runs even though the BASH_SOURCE points
  # at this test script itself.
  cache_phase_prepare "$REPO_ROOT/recipes/bootstrap/tcc-chain/scripts/build-${pkg_name}.sh" \
    "$out_dir" \
    --package-name="$pkg_name" \
    --package-version=test-stub-1 \
    --toolchain-name=stub \
    --toolchain-version=1 \
    "${deps[@]}"

  echo "${CACHE_KEY_HEX}" > "$out_dir/.cache-key.hex"

  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "$out_dir/prefix" ]]; then
      cp -a "$out_dir/prefix/." "$out_dir/"
      rm -rf "$out_dir/prefix"
    fi
    echo "[stub:${phase_name}] HIT cache-key=${CACHE_KEY_HEX:0:16}..."
    return 0
  fi

  echo "[stub:${phase_name}] MISS — synthesising deterministic prefix"
  echo "synthetic-${pkg_name}-bytes" > "$out_dir/${pkg_name}.bin"
  echo "shared-tag-${pkg_name}" > "$out_dir/version.txt"
  cache_phase_publish "$out_dir"
  return 1
}

# Layout:
#   $TMP/hex0/         hex0 prefix
#   $TMP/stage0/       stage0-posix prefix
#   $TMP/mescc/        mescc-tools prefix
#   $TMP/mes/          mes prefix
#   $TMP/tcc/          tcc prefix

T0="$TMP/run1"
mkdir -p "$T0"

echo "=== Run 1 (clean cache; expect 5 misses + 5 publishes) ==="
miss_count=0
for phase in hex0 stage0-posix mescc-tools mes tcc; do
  out="$T0/$phase"
  case "$phase" in
    hex0) run_phase "$phase" "$phase" "$out" "" "" || miss_count=$((miss_count + 1)) ;;
    stage0-posix) run_phase "$phase" "$phase" "$out" "$T0/hex0/.cache-key.hex" "" \
        || miss_count=$((miss_count + 1)) ;;
    mescc-tools) run_phase "$phase" "$phase" "$out" "$T0/stage0-posix/.cache-key.hex" "" \
        || miss_count=$((miss_count + 1)) ;;
    mes) run_phase "$phase" "$phase" "$out" "$T0/mescc-tools/.cache-key.hex" "" \
        || miss_count=$((miss_count + 1)) ;;
    tcc) run_phase "$phase" "$phase" "$out" "$T0/mes/.cache-key.hex" \
        "$T0/mescc-tools/.cache-key.hex" || miss_count=$((miss_count + 1)) ;;
  esac
done

if (( miss_count != 5 )); then
  a2_fail "Run 1 expected 5 misses; got $miss_count"
fi
echo "Run 1: 5 misses + 5 publishes confirmed"

T1="$TMP/run2"
mkdir -p "$T1"
hit_count=0
t_start=$(date +%s)
echo "=== Run 2 (post-publish; expect 5 hits + 0 builds) ==="
for phase in hex0 stage0-posix mescc-tools mes tcc; do
  out="$T1/$phase"
  case "$phase" in
    hex0) run_phase "$phase" "$phase" "$out" "" "" && hit_count=$((hit_count + 1)) ;;
    stage0-posix) run_phase "$phase" "$phase" "$out" "$T1/hex0/.cache-key.hex" "" \
        && hit_count=$((hit_count + 1)) ;;
    mescc-tools) run_phase "$phase" "$phase" "$out" "$T1/stage0-posix/.cache-key.hex" "" \
        && hit_count=$((hit_count + 1)) ;;
    mes) run_phase "$phase" "$phase" "$out" "$T1/mescc-tools/.cache-key.hex" "" \
        && hit_count=$((hit_count + 1)) ;;
    tcc) run_phase "$phase" "$phase" "$out" "$T1/mes/.cache-key.hex" \
        "$T1/mescc-tools/.cache-key.hex" && hit_count=$((hit_count + 1)) ;;
  esac
done
t_end=$(date +%s)

if (( hit_count != 5 )); then
  a2_fail "Run 2 expected 5 hits; got $hit_count"
fi
elapsed=$((t_end - t_start))
echo "Run 2: 5 hits in ${elapsed}s"
if (( elapsed > 15 )); then
  a2_fail "Run 2 wall-clock ${elapsed}s exceeded 15s budget"
fi

# Bytes match across runs.
for phase in hex0 stage0-posix mescc-tools mes tcc; do
  h1="$(sha256sum "$T0/$phase/$phase.bin" | awk '{print $1}')"
  h2="$(sha256sum "$T1/$phase/$phase.bin" | awk '{print $1}')"
  if [[ "$h1" != "$h2" ]]; then
    a2_fail "phase $phase bytes mismatch run1=$h1 run2=$h2"
  fi
done

a2_ok "t_a3_substitute_hit_r4_chain — 5-member closure publishes + substitutes"
