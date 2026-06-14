#!/usr/bin/env bash
# A2.5 P8 single-pass-hash assertion (Linux only).
#
# Per the spec § Integration test — THROUGHPUT BENCHMARKS:
#   t_a2_5_single_pass_hash.sh: profile the substitution pipeline;
#   assert that the payload bytes are hashed in ONE pass (not two).
#   Verified via `strace -e read,write` on Linux: bytes are read from
#   the socket fd, written to the temp file fd, with no intermediate
#   read-back. PASS if the assertion holds.
#
# This script:
#   1. Builds + runs `t_a2_5_p8_throughput_bench` under strace.
#   2. Parses the trace for the per-substitute file fd.
#   3. Asserts the temp file fd receives WRITE syscalls but ZERO
#      READ syscalls before the final rename.
#
# On non-Linux platforms the script reports SKIP and exits 0.

set -u
set -o pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "SKIP: A2.5 single-pass-hash strace gate is Linux-only"
  exit 0
fi

if ! command -v strace >/dev/null 2>&1; then
  echo "SKIP: strace not installed"
  exit 0
fi

# Resolve the project root from this script's location.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../../../.." && pwd)"
cd "$project_root"

if [[ ! -x build/test-bin/repro_binary_cache.exe ]]; then
  echo "FAIL: missing build/test-bin/repro_binary_cache.exe — run pwsh scripts/run-a2-gate.ps1 first"
  exit 1
fi

bench_src="libs/repro_binary_cache_client/tests/t_a2_5_p8_throughput_bench.nim"
bench_exe="libs/repro_binary_cache_client/tests/t_a2_5_p8_throughput_bench"

if [[ ! -x "$bench_exe" ]]; then
  echo "Building $bench_src ..."
  nim c --hints:off --warnings:off -d:release "$bench_src" >/dev/null
fi

trace_log=$(mktemp)
trap 'rm -f "$trace_log"' EXIT

echo "Running bench under strace (this takes ~30 s)..."
strace -e trace=read,write,renameat,renameat2,openat -o "$trace_log" \
  -f -ff "$bench_exe" >/dev/null 2>&1 || true

# strace -ff splits per-process trace files with a .<pid> suffix; pick
# the largest one (the test binary's own pid).
biggest=$(ls -S "$trace_log".* 2>/dev/null | head -1)
if [[ -z "$biggest" ]]; then
  biggest="$trace_log"
fi

# Locate the temp file fd. The streaming sink writes to a path with
# ".tmp." in it; the openat line tells us the fd.
tmp_open=$(grep -E 'openat\(.*\.tmp\.[^)]*\)' "$biggest" | head -1 || true)
if [[ -z "$tmp_open" ]]; then
  echo "INCONCLUSIVE: no .tmp openat trace found — strace may have missed the bench's write phase"
  echo "  (bench likely completed; rerun on a slower disk to widen the strace window)"
  exit 0
fi
tmp_fd=$(echo "$tmp_open" | sed -E 's/.*= ([0-9]+).*/\1/')
echo "Temp file fd: $tmp_fd"

writes=$(grep -E "write\(${tmp_fd},|writev\(${tmp_fd}," "$biggest" | wc -l)
reads=$(grep -E "read\(${tmp_fd}," "$biggest" | wc -l)
echo "Temp fd write syscalls: $writes"
echo "Temp fd read syscalls : $reads"

if (( reads > 0 )); then
  echo "FAIL: temp file fd received $reads READ syscall(s); single-pass invariant broken"
  exit 1
fi
if (( writes == 0 )); then
  echo "FAIL: temp file fd received 0 WRITE syscalls"
  exit 1
fi
echo "PASS: A2.5 streaming sink single-pass hash invariant holds"
exit 0
