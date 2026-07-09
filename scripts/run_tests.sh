#!/usr/bin/env bash
set -euo pipefail
# Bootstrap-And-Self-Build B5: the legacy shell loop is compressed to
# project-DSL graph steps. ``.#apps`` builds binaries, ``.#test-helpers``
# builds helpers, and ``.#test-builds`` compiles every test with the HCR
# flags baked into the edges. The runquota sibling build and final test runner
# stay shell-shaped until typed-tool resolver coverage reaches those helpers.
mkdir -p build build/nimcache test-logs
rm -rf build/test-bin
mkdir -p build/test-bin

# Test runs exercise user-facing CLI latency gates, so the app bootstrap and
# graph-owned app rebuilds must use optimized binaries by default. Developers
# can still opt into debug apps explicitly with REPROBUILD_BUILD_MODE=debug.
export REPROBUILD_BUILD_MODE="${REPROBUILD_BUILD_MODE:-release}"

# Tests must not depend on the developer's persistent action cache. Large or
# stale user-level metadata can dominate memory use in daemon-hosted cache-hit
# evidence reconstruction, so give this run a clean, reproducible cache root.
export REPROBUILD_ACTION_CACHE_ROOT="$(pwd)/build/test-action-cache"
rm -rf "${REPROBUILD_ACTION_CACHE_ROOT}"
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

# Provision sha-pinned NDE0-A fixtures; the test remains the loud gate.
bash recipes/reproos-mvp-config/fetch-test-fixtures.sh || true

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
  esac
  if [[ ! -x "${io_mon_src}/scripts/build_shim.sh" ]]; then
    echo "missing io-mon shim builder at ${io_mon_src}/scripts/build_shim.sh; set IO_MON_SRC" >&2
    return 2
  fi
  IO_MON_SHIM_OUT_DIR="$(pwd)/build/lib" \
  IO_MON_SHIM_NIMCACHE_DIR="$(pwd)/build/nimcache/io-mon-shim" \
  IO_MON_BUILD_MODE="${REPROBUILD_BUILD_MODE:-debug}" \
    bash "${io_mon_src}/scripts/build_shim.sh"
}
printf 'Bootstrapping monitor shim for provider compilation\n' >&2
bootstrap_monitor_shim > test-logs/monitor-shim-bootstrap.log 2>&1 || {
  echo "monitor shim bootstrap failed; see test-logs/monitor-shim-bootstrap.log" >&2
  exit 1
}

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

# Step 3: build the apps, helpers, fixtures, and test binaries through
# the engine. Cap parallelism for memory-constrained CI runners.
if [[ -z "${REPROBUILD_MAX_PARALLELISM:-}" ]]; then
  available_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  cap=$(( available_cores / 2 ))
  if (( cap < 1 )); then cap=1; fi
  if (( cap > 4 )); then cap=4; fi
  export REPROBUILD_MAX_PARALLELISM="${cap}"
fi
printf 'Building apps + test-helpers + test-builds via repro (REPROBUILD_MAX_PARALLELISM=%s)\n' \
  "${REPROBUILD_MAX_PARALLELISM}" >&2

# M3 accepts one fragment selector per invocation; loop over collections.
repro_build_collection() {
  local collection="$1"
  # Suite setup uses the local pool gate; dedicated tests cover RunQuota itself.
  if ! ./build/bin/repro build --tool-provisioning=path --daemon=off --no-runquota "${collection}"; then
    report_path=".repro/build/repro/build-report.json"
    if [[ -f "${report_path}" ]]; then
      printf '\n=== Failed actions for %s (from %s) ===\n' "${collection}" "${report_path}" >&2
      if command -v jq >/dev/null 2>&1; then
        jq '.actions[] | select(.exitCode != 0 and .exitCode != null) | {id, exitCode, executable, args, stdout, stderr, evidence}' "${report_path}" >&2 || true
      else
        printf '(jq not available; copying full report to test-logs/build-report.json)\n' >&2
      fi
      mkdir -p test-logs
      cp "${report_path}" "test-logs/build-report-${collection//[^a-zA-Z0-9]/_}.json" 2>/dev/null || true
    fi
    return 1
  fi
}
repro_build_collection ".#apps" || exit 1
repro_build_collection ".#test-helpers" || exit 1
# M2: build canonical test fixtures, including the io-monitor shim.
repro_build_collection ".#test-fixtures" || exit 1
repro_build_collection ".#test-builds" || exit 1

# Step 4 (B5): run Python tests first, then the Nim binaries via
# ct-test-runner when available or the M3 fallback runner.
while IFS= read -r -d '' test_file; do
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

# D6 per-test timeout plus an outer wall-clock backstop for runner wedges.
RUNNER_TIMEOUT="${REPROBUILD_RUNNER_TIMEOUT:-4h}"
TEST_TIMEOUT="${REPROBUILD_TEST_TIMEOUT:-600}"

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
  if [[ ! -x "${runner_bin}" ]]; then
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
  # The engine already built build/test-bin; default to one worker for heavy
  # nested-build tests unless callers explicitly set REPROBUILD_TEST_THREADS.
  timeout --kill-after=30s "${RUNNER_TIMEOUT}" "${runner_bin}" \
    --no-build \
    --threads=${REPROBUILD_TEST_THREADS:-1} \
    --test-timeout=${TEST_TIMEOUT} \
    --bin-dir=build/test-bin \
    --summary-json=test-logs/parallel-run.json \
    --results-dir=test-logs/results
fi
