#!/usr/bin/env bash
set -euo pipefail
# Bootstrap-And-Self-Build B5: the legacy shell loop is compressed to
# project-DSL graph steps. ``.#apps`` builds binaries, ``.#test-helpers``
# builds helpers, and ``.#test-builds`` compiles every test with the HCR
# flags baked into the edges. The runquota sibling build and final test runner
# stay shell-shaped until typed-tool resolver coverage reaches those helpers.
mkdir -p build build/nimcache test-logs
# Protocol evidence describes one execution, never a reusable build artifact.
rm -rf test-logs/results test-logs/parallel-run.json
mkdir -p test-logs/results
repo_root="$(pwd -P)"
# Keep large suite scratch off /tmp and outside the checkout; some tests build
# "outside workspace" fixtures and scan ancestors for repo markers.
cache_home="${XDG_CACHE_HOME:-${HOME:-}/.cache}"
[[ -n "${cache_home}" && "${cache_home}" != "/.cache" ]] || cache_home="${repo_root}/../.cache"
test_tmp_parent="${REPROBUILD_TEST_TMPDIR:-${cache_home}/reprobuild-test-tmp}"
[[ -n "${test_tmp_parent}" && "${test_tmp_parent}" != "/" ]] || {
  echo "refusing unsafe REPROBUILD_TEST_TMPDIR: ${test_tmp_parent}" >&2
  exit 1
}
test_tmp_parent="$(mkdir -p "${test_tmp_parent}" && cd "${test_tmp_parent}" && pwd -P)"
if [[ "${test_tmp_parent}" == "${repo_root}" || "${test_tmp_parent}" == "${repo_root}"/* ]]; then
  echo "refusing REPROBUILD_TEST_TMPDIR inside checkout: ${test_tmp_parent}" >&2
  exit 1
fi
test_tmp_root="${test_tmp_parent%/}/current"
rm -rf "${test_tmp_root}"
mkdir -p "${test_tmp_root}"
export TMPDIR="${test_tmp_root}" TMP="${test_tmp_root}" TEMP="${test_tmp_root}"

if [[ "${REPROBUILD_TEST_WARM_REUSE:-0}" != "1" ]]; then
  rm -rf build/test-bin
fi
mkdir -p build/test-bin
# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh
# shellcheck source=scripts/monitor_shim_probe.sh
source scripts/monitor_shim_probe.sh
# shellcheck source=scripts/test_parallelism.sh
source scripts/test_parallelism.sh
# Test runs exercise user-facing CLI latency gates, so the app bootstrap and
# graph-owned app rebuilds must use optimized binaries by default. Developers
# can still opt into debug apps explicitly with REPROBUILD_BUILD_MODE=debug.
export REPROBUILD_BUILD_MODE="${REPROBUILD_BUILD_MODE:-release}"

# Tests must not depend on the developer's persistent action cache. Large or
# stale user-level metadata can dominate memory use in daemon-hosted cache-hit
# evidence reconstruction, so give this run a clean, reproducible cache root.
export REPROBUILD_ACTION_CACHE_ROOT="$(pwd)/build/test-action-cache"
if [[ "${REPROBUILD_TEST_WARM_REUSE:-0}" != "1" ]]; then
  rm -rf "${REPROBUILD_ACTION_CACHE_ROOT}"
fi
mkdir -p "${REPROBUILD_ACTION_CACHE_ROOT}"

# Use only dev-shell runtime libraries; never scan stale /nix/store closures.
runtime_lib_dirs=()
for candidate in ${CLINGO_LIB:-} ${ZSTD_LIB:-}; do
  if [[ -d "${candidate}" ]]; then
    runtime_lib_dirs+=("${candidate}")
  fi
done
if [[ ${#runtime_lib_dirs[@]} -gt 0 ]]; then
  runtime_lib_path="$(IFS=:; printf '%s' "${runtime_lib_dirs[*]}")"
  export DYLD_LIBRARY_PATH="${runtime_lib_path}:${DYLD_LIBRARY_PATH:-}"
  export DYLD_FALLBACK_LIBRARY_PATH="${runtime_lib_path}:${DYLD_FALLBACK_LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${runtime_lib_path}:${LD_LIBRARY_PATH:-}"
fi
if [[ -z "${REPRO_TEST_ADAPTERS_SRC:-}" &&
      -f "../reprobuild-test-adapters/src/repro_test_adapters/test_runner.nim" ]]; then
  export REPRO_TEST_ADAPTERS_SRC="$(cd ../reprobuild-test-adapters/src && pwd)"
fi
if [[ -z "${REPRO_CT_TEST_RUNNER_SRC:-}" &&
      -f "../reprobuild-ct-test-runner/libs/ct_test_runner_adapter/src/ct_test_runner_adapter.nim" ]]; then
  export REPRO_CT_TEST_RUNNER_SRC="$(cd ../reprobuild-ct-test-runner && pwd)"
fi
if [[ -z "${BEARSSL_SRC:-}" ]]; then
  BEARSSL_SRC="$(find /nix/store -maxdepth 1 -type d -name '*nim-bearssl-*' -print -quit 2>/dev/null || true)"
  if [[ -n "${BEARSSL_SRC}" ]]; then
    export BEARSSL_SRC
  fi
fi
shm_queue_src="$(resolve_shm_queue_src)"
export SHM_QUEUE_SRC="${shm_queue_src}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exe_ext=".exe"
    ;;
  *)
    exe_ext=""
    ;;
esac

# Use an isolated daemon endpoint/state dir so auto-launched daemons do not
# leak into the developer's per-user daemon across test runs.
REPRO_TEST_DAEMON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repro-test-daemon.XXXXXX")"
export REPRO_DAEMON_STATE_DIR="${REPRO_TEST_DAEMON_DIR}/state"
mkdir -p "${REPRO_DAEMON_STATE_DIR}"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    export REPRO_DAEMON_ENDPOINT="\\\\.\\pipe\\repro-daemon-test-$$"
    ;;
  *)
    export REPRO_DAEMON_ENDPOINT="${REPRO_TEST_DAEMON_DIR}/d.sock"
    ;;
esac
_repro_test_daemon_cleanup() {
  if [[ -x "build/bin/repro${exe_ext}" ]]; then
    "build/bin/repro${exe_ext}" daemon stop >/dev/null 2>&1 || true
  fi
  rm -rf "${REPRO_TEST_DAEMON_DIR}" 2>/dev/null || true
}
trap _repro_test_daemon_cleanup EXIT

# Step 1 (B5): bootstrap ./build/bin/repro from nim when missing.
# Idempotent — the recipe no-ops when the binary already exists.
just bootstrap

# Seed the io-monitor shim for provider compilation on warm checkouts; the
# graph-owned ``.#test-fixtures`` edge verifies the canonical artifact later.
bootstrap_monitor_shim() {
  local io_mon_src="${IO_MON_SRC:-../io-mon}"
  case "${io_mon_src}" in
    */src) io_mon_src="${io_mon_src%/src}" ;;
    *\\src) io_mon_src="${io_mon_src%\\src}" ;;
  esac
  if [[ ! -x "${io_mon_src}/scripts/build_shim.sh" ]]; then
    echo "missing io-mon shim builder at ${io_mon_src}/scripts/build_shim.sh; set IO_MON_SRC" >&2
    return 2
  fi
  IO_MON_SHIM_OUT_DIR="$(pwd)/build/lib" \
  IO_MON_SHIM_NIMCACHE_DIR="$(pwd)/build/nimcache/io-mon-shim" \
  IO_MON_BUILD_MODE="${REPROBUILD_BUILD_MODE:-debug}" \
  SHM_QUEUE_SRC="${shm_queue_src}" \
    bash "${io_mon_src}/scripts/build_shim.sh"
}
printf 'Bootstrapping monitor shim for provider compilation\n' >&2
if [[ "${REPROBUILD_TEST_WARM_REUSE:-0}" == "1" ]] &&
    repro_monitor_shim_available "build/lib"; then
  printf 'Reusing warm monitor shim\n' >&2
else
  bootstrap_monitor_shim > test-logs/monitor-shim-bootstrap.log 2>&1 || {
    echo "monitor shim bootstrap failed; see test-logs/monitor-shim-bootstrap.log" >&2
    exit 1
  }
fi

# Fail fast when the Nim toolchain cannot complete a compile under the monitor
# shim. Every test that builds anything goes through a monitored provider
# compile, so a toolchain library missing from the loader search path takes the
# entire suite down; without this probe the first symptom is an opaque
# "__repro_provider_compile asFailed" hundreds of lines into the run.
bash scripts/check_toolchain_dlopen.sh build/lib

# Step 2: build sibling prerequisites that path-mode tool resolution needs.
runquotad_bin="${RUNQUOTAD_BIN:-}"
runquota_bin="${RUNQUOTA_BIN:-}"
if [[ -z "${runquotad_bin}" ]]; then
  runquotad_bin="$(command -v "runquotad${exe_ext}" 2>/dev/null || true)"
fi
if [[ -z "${runquota_bin}" ]]; then
  runquota_bin="$(command -v "runquota${exe_ext}" 2>/dev/null || true)"
fi
if [[ -x "${runquotad_bin}" && -x "${runquota_bin}" ]]; then
  runquotad_dir="$(cd "$(dirname "${runquotad_bin}")" && pwd)"
  runquota_dir="$(cd "$(dirname "${runquota_bin}")" && pwd)"
  export RUNQUOTAD_BIN="${runquotad_bin}"
  export RUNQUOTA_BIN="${runquota_bin}"
  export PATH="${runquotad_dir}:${runquota_dir}:${PATH}"
else
  runquota_src="${RUNQUOTA_SRC:-}"
  if [[ -d "../runquota" &&
        ( -z "${runquota_src}" || "${runquota_src}" == /nix/store/* ) ]]; then
    runquota_src="../runquota"
  fi
  if [[ -n "${runquota_src}" && -d "${runquota_src}" ]]; then
    runquota_src_abs="$(cd "${runquota_src}" && pwd)"
    export RUNQUOTA_SRC="${runquota_src_abs}"
    if [[ ! -x "${runquota_src_abs}/build/bin/runquotad${exe_ext}" ||
          ! -x "${runquota_src_abs}/build/bin/runquota${exe_ext}" ]]; then
      if [[ "${runquota_src_abs}" == /nix/store/* ]]; then
        echo "RUNQUOTA_SRC points to source-only Nix store path ${runquota_src_abs}; set RUNQUOTAD_BIN/RUNQUOTA_BIN or use a built runquota checkout" >&2
        exit 1
      fi
      printf 'Building prerequisite sibling: %s\n' "${runquota_src_abs}" >&2
      (cd "${runquota_src_abs}" && just build) > test-logs/runquota-build.log 2>&1 || {
        echo "runquota build failed; see test-logs/runquota-build.log" >&2
        exit 1
      }
    fi
    RUNQUOTA_BIN_ABS="$(cd "${runquota_src_abs}/build/bin" && pwd)"
    export RUNQUOTAD_BIN="${RUNQUOTA_BIN_ABS}/runquotad${exe_ext}"
    export RUNQUOTA_BIN="${RUNQUOTA_BIN_ABS}/runquota${exe_ext}"
    export PATH="${RUNQUOTA_BIN_ABS}:${PATH}"
  fi
fi

if [[ -d "../reprobuild-cmake" ]]; then
  bash scripts/build_reprobuild_cmake_prereq.sh "${exe_ext}"
fi

# RunQuota-Observation-Store M20: the SECOND test runner
# (`tools/tap-test-runner`, built on the `reprobuild-test-adapters` contract).
# `tests/integration/t_m20_second_runner_generic_layer.nim` spawns it, so it is
# an INPUT to that test rather than an output of compiling it — a run that
# rebuilt only the test would drive whatever binary happened to be on disk, and
# the test raises rather than skipping when it is absent.
#
# Rebuilt when missing OR older than any of its sources, for the reason the
# M3 fallback runner below carries the same rule: nothing else in the tree
# builds it (it is not a `repro.nim` target and not in apps/entrypoints.txt),
# so an existence-only check would let a stale binary survive every edit to
# the runner or to the adapter package it links.
tap_runner_bin="build/bin/repro_tap_test_runner${exe_ext}"
tap_runner_stale=0
if [[ ! -x "${tap_runner_bin}" ]]; then
  tap_runner_stale=1
else
  while IFS= read -r tap_src; do
    if [[ "${tap_src}" -nt "${tap_runner_bin}" ]]; then
      tap_runner_stale=1
      break
    fi
  done < <(
    find tools/tap-test-runner libs/repro_generic_test_recorder \
      ../reprobuild-test-adapters/src -name '*.nim' 2>/dev/null
  )
fi
if [[ "${tap_runner_stale}" -eq 1 ]]; then
  printf 'Building M20 second runner: %s\n' "${tap_runner_bin}" >&2
  nim c \
    --threads:on \
    --hints:off \
    --warnings:off \
    --nimcache:build/nimcache/repro_tap_test_runner \
    --out:"${tap_runner_bin}" \
    tools/tap-test-runner/repro_tap_test_runner.nim
fi

# Step 3: build the apps, helpers, fixtures, and test binaries through the
# engine. Parallelism comes from the host's real capacity — cores AND
# available memory — rather than from the profile of the smallest CI runner;
# see scripts/test_parallelism.sh for the budget and the evidence behind it.
available_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
available_mem_mb="$(reprobuild_available_memory_mb)"
# Remember whether the build parallelism is ours to manage. An explicit
# REPROBUILD_MAX_PARALLELISM is a statement about the whole run, so the
# execution phase below must not quietly rewrite it.
repro_parallelism_is_default=0
if [[ -z "${REPROBUILD_MAX_PARALLELISM:-}" ]]; then
  repro_parallelism_is_default=1
  export REPROBUILD_MAX_PARALLELISM="$(
    reprobuild_default_test_build_parallelism \
      "${available_cores}" "${available_mem_mb}"
  )"
fi
printf 'Building apps + test-helpers + test-builds via repro (%s cores, %s MiB available, REPROBUILD_MAX_PARALLELISM=%s)\n' \
  "${available_cores}" "${available_mem_mb:-unknown}" \
  "${REPROBUILD_MAX_PARALLELISM}" >&2
# A cold action cache has to compile every test binary from scratch, which
# exceeds 90m on CI hardware (an observed cold run reached 969/1168 before
# timing out). Match the runner's 4h backstop; a warm cache finishes far
# sooner, so this only raises the ceiling for the cold case.
BUILD_TIMEOUT="${REPROBUILD_BUILD_TIMEOUT:-4h}"

# M3 accepts one fragment selector per invocation; loop over collections.
repro_build_collection() {
  local collection="$1"
  # Suite setup uses the local pool gate; dedicated tests cover RunQuota itself.
  local repro_exe="./build/bin/repro${exe_ext}"
  if [[ -n "${exe_ext}" ]]; then
    cp -f "./build/bin/repro${exe_ext}" "./build/bin/repro_run${exe_ext}"
    repro_exe="./build/bin/repro_run${exe_ext}"
  fi
  local build_status=0
  # ``--write-report`` keeps the full record for the CI artefact. The FAILURE
  # report below needs no flag: a failed build writes it unasked, which is the
  # whole point of the outcome-dependent persist default.
  timeout --kill-after=30s "${BUILD_TIMEOUT}" \
    "${repro_exe}" build --tool-provisioning=path --daemon=off --no-runquota \
    --write-report "${collection}" \
    || build_status=$?
  if (( build_status != 0 )); then
    if (( build_status == 124 )); then
      printf 'Timed out building %s after %s\n' "${collection}" "${BUILD_TIMEOUT}" >&2
    fi

    failure_report_path=".repro/build/repro/build-failure-report.json"
    report_path=".repro/build/repro/build-report.json"
    if [[ -f "${failure_report_path}" ]]; then
      printf '\n=== Failed actions for %s (from %s) ===\n' "${collection}" "${failure_report_path}" >&2
      if command -v jq >/dev/null 2>&1; then
        jq '{counts, failedActions, blockedActions}' "${failure_report_path}" >&2 || true
      else
        cat "${failure_report_path}" >&2 || true
      fi
      mkdir -p test-logs
      cp "${failure_report_path}" "test-logs/build-failure-report-${collection//[^a-zA-Z0-9]/_}.json" 2>/dev/null || true
    fi
    if [[ -f "${report_path}" ]]; then
      mkdir -p test-logs
      cp "${report_path}" "test-logs/build-report-${collection//[^a-zA-Z0-9]/_}.json" 2>/dev/null || true
    fi
    return "${build_status}"
  fi
}
repro_build_collection ".#apps" || exit 1
repro_build_collection ".#test-helpers" || exit 1
# M2: build canonical test fixtures, including the io-monitor shim.
repro_build_collection ".#test-fixtures" || exit 1
repro_build_collection ".#test-builds" || exit 1

REPROBUILD_BIN_ABS="$(cd build/bin && pwd)"
export PATH="${REPROBUILD_BIN_ABS}:${PATH}"

# Step 4 (B5): run Python tests first, then the Nim binaries via
# ct-test-runner when available or the M3 fallback runner.
#
# `.#test-builds` has just completed, so every test binary the checked-in
# graph declares is supposed to be on disk. The suite-inventory tests that
# read a per-binary catalog step aside with a loud reason in a partially
# built working tree; HERE a missing binary is a build defect, so tell them
# to refuse instead. Without this the same shortfall would be reported as a
# skip in the one place it must be an error.
export REPROBUILD_SUITE_INVENTORY_REQUIRE_BUILT_TREE=1
while IFS= read -r -d '' test_file; do
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

# D6 per-test timeout plus an outer wall-clock backstop for runner wedges.
RUNNER_TIMEOUT="${REPROBUILD_RUNNER_TIMEOUT:-4h}"
# ``--test-timeout`` is a *no-progress* deadline: the runner kills a case only
# after it has produced no output AND its process group has consumed no
# measurable CPU for N seconds. (Output alone was the old rule; it read CPU
# starvation under parallelism as a hang and manufactured false failures.) The
# runner also enforces a hard ceiling of AbsoluteTimeoutMultiplier (4) times
# that value -- see drainAndWaitWithTimeout in
# tools/test-runner/repro_test_runner.nim -- which is what actually stops a
# livelock, since a spinner satisfies the CPU signal forever. So this number
# sets a per-binary wall-clock ceiling of 4x, not of 1x.
#
# At the previous 600 that ceiling was 40 minutes, and the slowest binary in
# the suite needs far longer than that: test-logs/parallel-run.json (a full
# 8-thread run, 6828 cases) records t_e2e_codetracer_in_place_project_file at
# 4861s of case time -- about 81 minutes -- with eleven of the suite's twenty
# five slowest cases inside that one binary. A 40-minute ceiling kills it
# every time, so the first execution phase that ever completes would report a
# timeout rather than a result.
#
# 1800 gives a 2h ceiling, which clears the measured 81 minutes with margin
# and still sits inside RUNNER_TIMEOUT above. It also matches the value the
# runner's own documentation already assumes for the per-test timeout
# (repro_test_runner.nim:531); 600 was a drift away from that intent.
TEST_TIMEOUT="${REPROBUILD_TEST_TIMEOUT:-1800}"

# Execution-phase budget. Concurrency here is multiplicative — a test process
# routinely spawns a nested ``repro build`` — so the host budget is SPLIT
# between test workers and the workers each nested build may use, rather than
# handed to either one whole. ``threads * nested`` never exceeds the budget by
# construction; see scripts/test_parallelism.sh.
#
# The old default was one worker, justified by exactly this nested-build
# concern. It is a real concern and the wrong remedy: at one worker a measured
# run completed 293 of 1183 cases in 3h57m (~16h implied), while the same
# suite at eight workers finished 1183/1183 in ~3h25m. Surrendering thirty-one
# of thirty-two cores is not how you avoid oversubscribing them.
if [[ -z "${REPROBUILD_TEST_THREADS:-}" ]]; then
  REPROBUILD_TEST_THREADS="$(
    reprobuild_default_test_threads "${available_cores}" "${available_mem_mb}"
  )"
fi
if (( repro_parallelism_is_default == 1 )); then
  # Only when the build parallelism was ours to pick. An operator who pinned
  # REPROBUILD_MAX_PARALLELISM meant it for the whole run.
  export REPROBUILD_MAX_PARALLELISM="$(
    reprobuild_default_nested_build_parallelism \
      "${available_cores}" "${available_mem_mb}"
  )"
fi
printf 'Executing tests with %s worker(s); nested builds get REPROBUILD_MAX_PARALLELISM=%s\n' \
  "${REPROBUILD_TEST_THREADS}" "${REPROBUILD_MAX_PARALLELISM}" >&2

ct_test_runner="${CT_TEST_RUNNER:-}"
if [[ -z "${ct_test_runner}" ]]; then
  ct_test_runner="$(command -v "ct-test-runner${exe_ext}" 2>/dev/null || true)"
fi
if [[ -n "${ct_test_runner}" && -x "${ct_test_runner}" ]]; then
  printf 'Using ct-test-runner: %s (overall timeout %s)\n' \
    "${ct_test_runner}" "${RUNNER_TIMEOUT}" >&2
  timeout --kill-after=30s "${RUNNER_TIMEOUT}" "${ct_test_runner}" run \
    --bin-dir=build/test-bin \
    --summary-json=test-logs/parallel-run.json \
    --results-dir=test-logs/results
else
  printf 'ct-test-runner not built; falling back to M3 internal runner (overall timeout %s)\n' \
    "${RUNNER_TIMEOUT}" >&2
  runner_bin="build/bin/repro_test_runner${exe_ext}"
  # Rebuild when the binary is missing OR older than its source. Nothing
  # else in the tree builds this binary — it is not a `repro.nim` target
  # and not in apps/entrypoints.txt — so an existence-only check let a
  # stale runner survive every edit to tools/test-runner/, silently
  # running a 2h suite with reporting behaviour that no longer matches
  # the source under review.
  if [[ ! -x "${runner_bin}" ]] ||
     [[ tools/test-runner/repro_test_runner.nim -nt "${runner_bin}" ]]; then
    printf 'Building M3 fallback runner: %s\n' "${runner_bin}" >&2
    nim c \
      -d:release \
      --threads:on \
      --hints:off \
      --warnings:off \
      --nimcache:build/nimcache/repro_test_runner \
      --out:"${runner_bin}" \
      tools/test-runner/repro_test_runner.nim
  fi
  timeout --kill-after=30s "${RUNNER_TIMEOUT}" "${runner_bin}" \
    --no-build \
    --threads=${REPROBUILD_TEST_THREADS} \
    --test-timeout=${TEST_TIMEOUT} \
    --bin-dir=build/test-bin \
    --summary-json=test-logs/parallel-run.json \
    --results-dir=test-logs/results
fi
