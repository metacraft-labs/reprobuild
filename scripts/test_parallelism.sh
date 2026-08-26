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
# 24 workers on 32 cores is 3/4 of the machine, and 8 execution threads is the
# only full-suite execution measurement that exists; both numbers below are
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

# Available memory in MiB, or empty when it cannot be measured.
#
# "Available" rather than "free" on Linux: MemAvailable already discounts the
# page cache the kernel would reclaim, which is the number a compiler fleet
# actually gets. macOS has no equivalent, so hw.memsize (physical total) is
# used and the caller is on notice that it is an over-estimate; the core
# fraction is the binding term on every Mac we build on.
reprobuild_available_memory_mb() {
  if [[ -r /proc/meminfo ]]; then
    local kb
    kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
    if [[ "${kb}" =~ ^[0-9]+$ ]] && (( kb > 0 )); then
      printf '%s\n' "$((kb / 1024))"
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

# EXECUTION phase: worker count for the test runner.
#
# Capped at eight because eight is the largest full-suite execution ever
# measured (1183/1183). Above it there is no evidence, and the runner's own
# notes record false failures at sixteen workers from CPU starvation — the
# defect fixed in "Decide a test is hung from lack of progress, not from
# silence". Raising this cap is a measurement, not an edit.
reprobuild_default_test_threads() {
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

# EXECUTION phase: the build parallelism each nested ``repro build`` inside a
# test process gets. ``threads * nested <= budget`` holds for every input,
# which is the whole point of deriving both from one number.
reprobuild_default_nested_build_parallelism() {
  local budget threads
  budget="$(reprobuild_worker_budget "$@")"
  threads="$(reprobuild_default_test_threads "$@")"
  local nested=$((budget / threads))
  if (( nested < 1 )); then
    nested=1
  fi
  printf '%s\n' "${nested}"
}
