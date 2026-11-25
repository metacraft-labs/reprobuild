#!/usr/bin/env bash
# The test phase of scripts/run_tests.sh bounds the memory of every process it
# starts, so a runaway case dies of its own failed allocation instead of
# driving the host into the kernel OOM killer.
#
# This sources the real helper (scripts/lib/test_process_memory_limit.sh) and
# runs a REAL allocator under it: a python3 process that grabs 64 MiB chunks,
# touching each, up to a 3 GiB self-imposed ceiling (so that, with the helper
# broken, the test costs 3 GiB and terminates instead of taking the host down).
# Nothing is stubbed.
#
# Cases: with a 512 MiB limit the allocator is refused well short of the
# ceiling; with the limit disabled (0) it reaches the ceiling (the control
# proving the allocator would otherwise run on); a non-numeric value is refused
# with status 2; an existing lower hard limit is not raised; run_tests.sh
# applies the helper to BOTH runner launches (checked on the script's text,
# because running the whole suite is not a test of one launch).
#
# Falsifying mutation: a helper whose apply function is a no-op fails the first
# case (the allocator reaches the 3 GiB ceiling).
#
#   bash tests/test_run_tests_bounds_process_memory.sh
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v python3 >/dev/null || fail "python3 is required (the real allocator)"
# shellcheck source=../scripts/lib/test_process_memory_limit.sh
. "$repo/scripts/lib/test_process_memory_limit.sh"

alloc_py='
import sys
chunks = []
mib = 0
try:
    while mib < 3072:
        chunks.append(bytearray(b"x") * (64 << 20))
        mib += 64
except MemoryError:
    pass
print(mib)
'
# run_alloc <limit-setting...>: MiB the allocator reached under the limit.
run_alloc() {
	( env "$@" bash -c '. "$1"; repro_test_apply_process_data_limit || exit $?
		python3 -c "$2"' _ "$repo/scripts/lib/test_process_memory_limit.sh" "$alloc_py" 2>/dev/null )
}

reached="$(run_alloc REPRO_TEST_PROCESS_DATA_LIMIT_MB=512 || true)"
[ -n "$reached" ] || fail "allocator died instead of being refused cleanly"
[ "$reached" -lt 1024 ] || fail "512 MiB limit let the allocator reach ${reached} MiB"

control="$(run_alloc REPRO_TEST_PROCESS_DATA_LIMIT_MB=0)"
[ "$control" -eq 3072 ] || fail "control: unlimited allocator reached only ${control} MiB"

rc=0
( REPRO_TEST_PROCESS_DATA_LIMIT_MB=lots repro_test_apply_process_data_limit ) 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "a non-numeric limit must be refused with status 2, got $rc"

# A lower hard limit already in force is kept, never raised.
kept="$( ( ulimit -d 262144; REPRO_TEST_PROCESS_DATA_LIMIT_MB=4096 repro_test_apply_process_data_limit 2>/dev/null; ulimit -H -d ) )"
[ "$kept" -eq 262144 ] || fail "an existing lower hard limit was changed to $kept"

# Both runner launches go through the helper.
grep -qF 'test_process_memory_limit.sh' "$repo/scripts/run_tests.sh" || fail "run_tests.sh does not source the helper"
n="$(grep -c 'repro_test_apply_process_data_limit' "$repo/scripts/run_tests.sh")"
[ "$n" -ge 2 ] || fail "run_tests.sh applies the limit to $n runner launches, expected 2"

echo "PASS"
