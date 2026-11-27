#!/usr/bin/env bash

# Parallelism policy for the test suite: one worker budget, split between the
# two phases that consume it.
#
# ---------------------------------------------------------------------------
# WHY THERE IS A BUDGET AT ALL
# ---------------------------------------------------------------------------
# The suite has two phases with different shapes:
#
#   BUILD     ``repro build .#test-builds`` compiles ~1200 test binaries. Each
#             worker is one ``nim c`` that forks a C compiler. Nothing nests,
#             so this phase may spend the whole budget on workers.
#   EXECUTION the runner spawns test processes, and many integration tests
#             spawn a NESTED ``repro build`` of their own. Concurrency here is
#             therefore multiplicative: test workers x nested build workers.
#             Spending the whole budget on test workers oversubscribes the
#             host by whatever the nested factor happens to be.
#
# So the budget is computed once and then divided: the execution phase gets
# ``threads`` workers and hands each nested build ``nested`` workers, with
# ``threads * nested <= budget`` by construction.
#
# ---------------------------------------------------------------------------
# WHY THE BUDGET LOOKS AT MEMORY
# ---------------------------------------------------------------------------
# The ceiling this file used to apply unconditionally was introduced to "cap
# parallelism for memory-constrained CI runners" — memory was the named
# constraint, but only cores were ever consulted, so the cap fired on hosts
# with hundreds of gigabytes free. Consult the constraint that is actually
# claimed: available memory divided by a per-worker allowance.
#
# ---------------------------------------------------------------------------
# WHY CI KEEPS THE OLD CEILING
# ---------------------------------------------------------------------------
# On the shared bare-metal CI host ``nproc`` reports the whole machine while a
# dozen runner instances contend for it, so a host-derived budget overstates
# one job's share by an order of magnitude. Under CI — and on any host where
# available memory cannot be measured, because an unverifiable host must not
# be trusted with a larger share — the conservative core-only ladder below is
# used unchanged. CI that wants more says so explicitly:
# .github/workflows/ci.yml pins REPROBUILD_MAX_PARALLELISM and
# REPROBUILD_TEST_THREADS, and an explicit setting always wins over every
# default here.
#
# ---------------------------------------------------------------------------
# EVIDENCE
# ---------------------------------------------------------------------------
# Measured on a 32-core / 377 GB host (~143 GB available), building the same
# 1182 test actions:
#
#   REPROBUILD_MAX_PARALLELISM=8   1112/1182 after 4h00m, then the phase
#                                  timeout. No test ever ran.
#   REPROBUILD_MAX_PARALLELISM=24  all 1182 actions in 1h25m; already past
#                                  the capped run's high-water mark at 1h17m.
#
# and executing the suite:
#
#   REPROBUILD_TEST_THREADS=1      293 of 1183 cases in 3h57m (~16h implied).
#   REPROBUILD_TEST_THREADS=8      1183/1183 in ~3h25m.
#
# and, on the same 32-core host with the ~11,260-case suite (2026-10), the
# runner's own summary (`test-logs/parallel-run.json`):
#
#   REPROBUILD_TEST_THREADS=8      test phase 5.85h; per-case durations sum to
#                                  27.4h; 9 failures.
#   REPROBUILD_TEST_THREADS=12     test phase 9.25h; per-case durations sum to
#                                  57.5h; 19 failures, the extra ones timing
#                                  bounds (HCR agent waits, a 5s runner bound).
#
# More execution threads did not finish sooner: every case ran about twice as
# long, because each test thread also drives a nested build and the host was
# already saturated at 8. Raising the thread count is not the lever.
#
# 24 workers on 32 cores is 3/4 of the machine, and 8 execution threads is the
# best full-suite execution configuration measured; both numbers below are
# chosen so this host reproduces exactly those two configurations.

# Per-worker memory allowance, MiB. One ``nim c`` of a reprobuild test binary
# plus the C compiler it forks. This is a deliberately conservative estimate
# rather than a measurement: it exists to stop a small-memory host from
# running as many workers as it has cores, and on any host with more than
# ~2 GiB per core it does not bind at all.
REPROBUILD_MEM_PER_WORKER_MB="${REPROBUILD_MEM_PER_WORKER_MB:-2048}"

# Nested build workers handed to each test process during the execution
# phase. The budget is split ``threads = budget / 3``, so a nested build gets
# about this many workers back. Three is the smallest split that still lets a
# nested build overlap its Nim front end with a C compile.
REPROBUILD_NESTED_BUILD_WORKERS=3

# True when this looks like an automated CI job rather than a developer host.
reprobuild_is_ci() {
  [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]
}

# Headroom, in MiB, under the tightest cgroup v2 memory limit that binds this
# process, or empty when no limit binds it or none can be read.
#
# A process is bound by `memory.max` of its own cgroup AND of every ancestor
# (https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files),
# so the walk starts at the cgroup /proc/self/cgroup names (the `0::<path>`
# line of the unified hierarchy) and goes up to the root of the cgroup2 mount.
# Each limited level contributes `memory.max` minus what that subtree already
# holds; the smallest wins. "Holds" is `memory.current` less the page cache on
# the file LRU lists of `memory.stat` (`active_file` + `inactive_file`),
# because the kernel reclaims those before it OOM-kills inside a cgroup -- the
# cgroup analogue of MemAvailable. Not `file`: that also counts tmpfs and
# shared memory (`shmem`), which live on the anon lists and, with no swap,
# cannot be reclaimed at all.
#
# This is what a transient `systemd-run --user --scope -p MemoryMax=16G`
# sets, and the fleet's build hosts require one around every Nim step; a
# budget from MemAvailable alone sees the whole host and over-commits the
# scope. Linux only: elsewhere there is no /proc/self/cgroup and the result is
# empty.
reprobuild_cgroup_memory_headroom_mb() {
  [[ -r /proc/self/cgroup && -r /proc/self/mounts ]] || { printf '\n'; return 0; }
  local rel root dir limit current file held headroom best=""
  rel="$(sed -n 's/^0::\(.*\)$/\1/p' /proc/self/cgroup 2>/dev/null | head -n 1)"
  root="$(awk '$3 == "cgroup2" { print $2; exit }' /proc/self/mounts 2>/dev/null || true)"
  if [[ -z "${rel}" || -z "${root}" || ! -d "${root}" ]]; then
    printf '\n'
    return 0
  fi
  dir="${root}${rel%/}"
  while :; do
    limit="$(cat "${dir}/memory.max" 2>/dev/null || true)"
    if [[ "${limit}" =~ ^[0-9]+$ ]]; then
      current="$(cat "${dir}/memory.current" 2>/dev/null || true)"
      [[ "${current}" =~ ^[0-9]+$ ]] || current=0
      file="$(awk '$1 == "active_file" || $1 == "inactive_file" { n += $2; seen = 1 }
        END { if (seen) print n }' "${dir}/memory.stat" 2>/dev/null || true)"
      [[ "${file}" =~ ^[0-9]+$ ]] || file=0
      held=$((current - file))
      (( held >= 0 )) || held=0
      headroom=$(((limit - held) / 1024 / 1024))
      (( headroom >= 0 )) || headroom=0
      if [[ -z "${best}" ]] || (( headroom < best )); then
        best="${headroom}"
      fi
    fi
    [[ "${dir}" == "${root}" || "${dir}" == / || -z "${dir}" ]] && break
    dir="${dir%/*}"
    [[ -n "${dir}" ]] || dir=/
  done
  printf '%s\n' "${best}"
}

# Available memory in MiB, or empty when it cannot be measured.
#
# "Available" rather than "free" on Linux: MemAvailable already discounts the
# page cache the kernel would reclaim, which is the number a compiler fleet
# actually gets. Under a cgroup memory limit the headroom below that limit
# (reprobuild_cgroup_memory_headroom_mb) is used when it is the smaller of
# the two. macOS has no equivalent, so hw.memsize (physical total) is
# used and the caller is on notice that it is an over-estimate; the core
# fraction is the binding term on every Mac we build on.
reprobuild_available_memory_mb() {
  if [[ -r /proc/meminfo ]]; then
    local kb cg
    kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
    if [[ "${kb}" =~ ^[0-9]+$ ]] && (( kb > 0 )); then
      local mb=$((kb / 1024))
      cg="$(reprobuild_cgroup_memory_headroom_mb)"
      if [[ "${cg}" =~ ^[0-9]+$ ]] && (( cg < mb )); then
        mb="${cg}"
      fi
      printf '%s\n' "${mb}"
      return 0
    fi
  fi
  if command -v sysctl >/dev/null 2>&1; then
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    if [[ "${bytes}" =~ ^[0-9]+$ ]] && (( bytes > 0 )); then
      printf '%s\n' "$((bytes / 1024 / 1024))"
      return 0
    fi
  fi
  printf '\n'
}

# Free disk in MiB on the filesystem holding $1 (default: the current
# directory), or empty when it cannot be measured.
#
# `df -Pk` (POSIX output, 1 KiB blocks) is portable across Linux and macOS.
# The build phase writes only below the repository, so that is the filesystem
# whose headroom matters; a pool shared with other runners is still measured
# correctly because df reports the pool's free space, not a quota.
reprobuild_available_disk_mb() {
  local path="${1:-.}" kb
  kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2 { print $4; exit }' || true)"
  if [[ "${kb}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((kb / 1024))"
    return 0
  fi
  printf '\n'
}

# Refuse, naming the cause, when the build phase cannot fit on the disk.
#   $1 path on the filesystem the build writes to
#   $2 MiB the phase needs
# Returns 0 when there is room or the free space cannot be measured (an
# unverifiable host is not refused: the guard must never invent a failure).
# Returns 1 with one explanatory line on stderr otherwise. Without it a full
# disk surfaces ~25 minutes in as "the engine never reached its post-mortem".
reprobuild_require_free_disk() {
  local path="$1" need_mb="$2" free_mb
  free_mb="$(reprobuild_available_disk_mb "${path}")"
  if [[ -z "${free_mb}" ]]; then
    return 0
  fi
  if (( free_mb < need_mb )); then
    printf 'error: only %s MiB free on the disk holding %s, but the build phase needs at least %s MiB. Free space (expire stale CI GC roots, remove old snapshots) or lower REPROBUILD_TEST_MIN_FREE_DISK_MB if you know better.\n' \
      "${free_mb}" "${path}" "${need_mb}" >&2
    return 1
  fi
  return 0
}

# The conservative core-only ladder: the behaviour every host had before the
# budget existed. Retained verbatim for CI and for hosts whose memory cannot
# be measured, so neither can be made worse by this file.
_reprobuild_conservative_budget() {
  local cores="$1"
  local cap=$((cores / 2))
  if (( cap < 1 )); then
    cap=1
  fi
  local max_cap=4
  if (( cores >= 24 )); then
    max_cap=8
  fi
  if (( cores >= 32 )); then
    max_cap=16
  fi
  if (( cap > max_cap )); then
    cap="${max_cap}"
  fi
  printf '%s\n' "${cap}"
}

# The one worker budget every default below is derived from.
#   $1 logical cores
#   $2 available memory in MiB (empty/invalid => unmeasurable)
#   $3 optional CI override for tests: "ci" or "local"; defaults to detection
reprobuild_worker_budget() {
  local cores="${1:-1}"
  local mem_mb="${2:-}"
  local ci_mode="${3:-}"

  if [[ ! "${cores}" =~ ^[0-9]+$ ]] || (( cores < 1 )); then
    cores=1
  fi

  local is_ci=1
  case "${ci_mode}" in
    ci) is_ci=0 ;;
    local) is_ci=1 ;;
    *)
      if reprobuild_is_ci; then
        is_ci=0
      fi
      ;;
  esac

  if (( is_ci == 0 )) ||
      [[ ! "${mem_mb}" =~ ^[0-9]+$ ]] ||
      (( mem_mb < 1 )); then
    _reprobuild_conservative_budget "${cores}"
    return 0
  fi

  # Three quarters of the machine. A ``nim c`` worker alternates between the
  # Nim front end and the C compiler it forks rather than running both flat
  # out, so a worker costs roughly one core on average; the reserved quarter
  # covers the overlap and leaves the host usable.
  local core_budget=$((cores * 3 / 4))
  if (( core_budget < 1 )); then
    core_budget=1
  fi

  local mem_budget=$((mem_mb / REPROBUILD_MEM_PER_WORKER_MB))
  if (( mem_budget < 1 )); then
    mem_budget=1
  fi

  local budget="${core_budget}"
  if (( mem_budget < budget )); then
    budget="${mem_budget}"
  fi
  printf '%s\n' "${budget}"
}

# BUILD phase: nothing nests, so the whole budget goes to workers.
reprobuild_default_test_build_parallelism() {
  reprobuild_worker_budget "$@"
}

# The width RunQuota granted this process, or empty when it holds no lease.
# ``runquota run`` exports it as RUNQUOTA_RUN_WIDTH to the command it launches
# (libs/repro_runquota: GrantedWidthEnvVar), so a suite started under a lease
# sees its grant here. Anything that is not a positive integer is "no grant":
# a stale or hand-typed value must not zero the worker count.
reprobuild_granted_width() {
  local w="${RUNQUOTA_RUN_WIDTH:-}"
  if [[ "${w}" =~ ^[0-9]+$ ]] && (( w >= 1 )); then
    printf '%s\n' "${w}"
  else
    printf '\n'
  fi
}

# EXECUTION phase: the worker count before the lease grant is applied. This
# is the host-derived number, capped at the measured best (see below). The
# nested-build split is computed from THIS number, never from the grant
# clamped one, so a small grant lowers the test workers without handing the
# freed share to each nested build (which would raise ``threads * nested``
# past the budget's division).
#
# Capped at eight because eight is the largest full-suite execution ever
# measured (1183/1183, and the best of the ~11,260-case runs: see EVIDENCE).
# Above it there is no evidence, and the runner's own notes record false
# failures at sixteen workers from CPU starvation -- the defect fixed in
# "Decide a test is hung from lack of progress, not from silence". Raising
# this cap is a measurement, not an edit. A re-measure at other widths is
# optional later work.
_reprobuild_host_test_threads() {
  local budget
  budget="$(reprobuild_worker_budget "$@")"
  local threads=$((budget / REPROBUILD_NESTED_BUILD_WORKERS))
  if (( threads < 1 )); then
    threads=1
  fi
  if (( threads > 8 )); then
    threads=8
  fi
  printf '%s\n' "${threads}"
}

# EXECUTION phase: worker count for the test runner,
# ``min(measured best, host-derived, RunQuota grant)``.
#
# The measured eight stays the ceiling and the host-derived number stays the
# default; the grant only lowers it, so a suite running under a ``runquota
# run`` lease never uses more test workers than the lease holds, and with a
# grant of eight or more nothing changes. No lease (no RUNQUOTA_RUN_WIDTH)
# leaves the result exactly as before. An explicit REPROBUILD_TEST_THREADS
# still wins over this default in scripts/run_tests.sh.
reprobuild_default_test_threads() {
  local threads grant
  threads="$(_reprobuild_host_test_threads "$@")"
  grant="$(reprobuild_granted_width)"
  if [[ -n "${grant}" ]] && (( grant < threads )); then
    threads="${grant}"
  fi
  printf '%s\n' "${threads}"
}

# EXECUTION phase: the build parallelism each nested ``repro build`` inside a
# test process gets. ``threads * nested <= budget`` holds for every input,
# which is the whole point of deriving both from one number.
reprobuild_default_nested_build_parallelism() {
  local budget threads
  budget="$(reprobuild_worker_budget "$@")"
  threads="$(_reprobuild_host_test_threads "$@")"
  local nested=$((budget / threads))
  if (( nested < 1 )); then
    nested=1
  fi
  printf '%s\n' "${nested}"
}

# EXECUTION phase, EXCLUSIVE part: the build parallelism the nested
# ``repro build`` gets inside a case that runs with no other test active.
#
# The divide above exists because the execution phase is multiplicative:
# ``threads`` cases in flight, each able to spawn ``nested`` build workers.
# The runner's exclusive phase breaks that assumption in the safe direction —
# it runs the ~50 cases on ``ExclusiveStems`` strictly one at a time, on the
# main thread, before any worker exists. With one case in flight the
# multiplier is 1, so the same ``concurrent * nested <= budget`` invariant
# permits the whole budget, and dividing anyway is pure waste: those cases are
# exclusive BECAUSE they drive nested compiles, and they were getting the
# smallest share on the emptiest machine. Below the stock default, even —
# ``buildMaxParallelismResolved`` uses 8 when the variable is unset.
#
# This is the same invariant as the function above, evaluated at a divisor of
# one. It does not change how many TESTS run at once, only how many build
# workers the single running test may use.
reprobuild_default_exclusive_build_parallelism() {
  reprobuild_worker_budget "$@"
}
