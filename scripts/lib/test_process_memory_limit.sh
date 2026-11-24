# shellcheck shell=bash
# Bound the memory any single process of the test phase can allocate.
#
#   . scripts/lib/test_process_memory_limit.sh
#   ( repro_test_apply_process_data_limit && exec <test runner> ... )
#
# Why: a test that asserts "fails closed" can instead allocate without bound
# (a decoder test once did, at ~1 GB/s up to 35-44 GB). Under the default
# Linux OOM policy the kernel then picks its victim by badness, and it killed
# unrelated long-running sessions rather than the runaway test. With a limit,
# the runaway's own allocation fails (ENOMEM), so the process that misbehaves is
# the one that dies, and the failure is attributable to its case.
#
# How: RLIMIT_DATA (`ulimit -d`), inherited by every process the runner starts
# and enforced per process on Linux >= 4.7 for brk and private writable
# mappings (the malloc/mmap heap; shared mappings such as the shared-memory
# queues are not counted). A cgroup `MemoryMax` per case would bound the whole
# tree, but creating one needs a delegated cgroup subtree, which an unprivileged
# developer shell or a CI container does not have; the rlimit works everywhere
# the runner does, for both the in-tree runner and ct-test-runner, because it
# is set before either starts. Not enforced by macOS, where it is a no-op.
#
# REPRO_TEST_PROCESS_DATA_LIMIT_MB selects the limit in MiB: unset means
# 16384 (16 GiB: far above any case's measured need, far below a 62 GB host);
# `0` or `unlimited` disables it. Anything else is refused with status 2. A
# limit is never RAISED: an existing lower hard limit is kept.
#
# Prints the limit it applied (or why it applied none) on stderr.
REPRO_TEST_DEFAULT_DATA_LIMIT_MB=16384

repro_test_apply_process_data_limit() {
  local mb="${REPRO_TEST_PROCESS_DATA_LIMIT_MB-${REPRO_TEST_DEFAULT_DATA_LIMIT_MB}}"
  case "${mb}" in
    0|unlimited)
      echo "run_tests: per-process data limit: disabled by REPRO_TEST_PROCESS_DATA_LIMIT_MB=${mb}" >&2
      return 0
      ;;
    ''|*[!0-9]*)
      echo "run_tests: REPRO_TEST_PROCESS_DATA_LIMIT_MB must be a positive integer (MiB), 0 or 'unlimited'; got '${mb}'" >&2
      return 2
      ;;
  esac
  local want_kb=$((mb * 1024)) current
  current="$(ulimit -H -d 2>/dev/null)" || {
    echo "run_tests: per-process data limit: not supported by this shell" >&2
    return 0
  }
  if [[ "${current}" != unlimited && "${current}" -le "${want_kb}" ]]; then
    echo "run_tests: per-process data limit: keeping existing ${current} KiB (<= ${mb} MiB)" >&2
    return 0
  fi
  if ulimit -d "${want_kb}" 2>/dev/null; then
    echo "run_tests: per-process data limit: ${mb} MiB" >&2
  else
    echo "run_tests: per-process data limit: could not set ${mb} MiB; continuing without" >&2
  fi
  return 0
}
