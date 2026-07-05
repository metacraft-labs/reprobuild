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

# Local Nix builds of repro link libclingo/libzstd dynamically. Make the
# freshly bootstrapped ./build/bin/repro usable for every test-run invocation,
# including the repro build collections below.
CLINGO_LIB="${CLINGO_LIB:-$(find /nix/store -maxdepth 1 -type d -name '*clingo-5.*' -print -quit 2>/dev/null)/lib}"
ZSTD_LIB="${ZSTD_LIB:-$(find /nix/store -maxdepth 1 -type d -name '*zstd-1.*' -print -quit 2>/dev/null)/lib}"
if [[ -d "${CLINGO_LIB}" && -d "${ZSTD_LIB}" ]]; then
  export DYLD_LIBRARY_PATH="${CLINGO_LIB}:${ZSTD_LIB}:${DYLD_LIBRARY_PATH:-}"
  export DYLD_FALLBACK_LIBRARY_PATH="${CLINGO_LIB}:${ZSTD_LIB}:${DYLD_FALLBACK_LIBRARY_PATH:-}"
  export LD_LIBRARY_PATH="${CLINGO_LIB}:${ZSTD_LIB}:${LD_LIBRARY_PATH:-}"
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

# Provision the NDE0-A jammy .deb fixtures (sha-pinned download, no
# binaries vendored into git) so t_nde0a_apt_jammy has its inputs. The
# step is idempotent, Linux-only, and best-effort — a network failure
# warns and continues; the test stays the loud gate if a fixture is
# absent.
bash recipes/reproos-mvp-config/fetch-test-fixtures.sh || true

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exe_ext=".exe"
    ;;
  *)
    exe_ext=""
    ;;
esac

# Controlled, throwaway repro-daemon for the whole test run.
#
# The spec mandates that `repro build` auto-launches the per-user daemon
# and keeps it alive across invocations. That is correct for real use,
# but a CI / local test run that lets daemon-hosted tests fall through to
# the default per-user endpoint (`~/.local/state/repro/daemon`) leaves a
# live daemon behind after the suite finishes — it accumulates across
# runs and on a shared host shows up as a leaked, sometimes busy, daemon
# process. Point the whole run at an isolated endpoint + state dir so any
# daemon a test auto-launches is OUR throwaway instance, then stop it and
# remove its state on exit. Tests that drive their own daemon lifecycle
# (the daemon control-plane / watch / dev-session suites) set their own
# REPRO_DAEMON_ENDPOINT per invocation and are unaffected.
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
  # Best-effort: stop the controlled daemon (no-op if none was launched)
  # then drop its isolated state dir. Never fail the run on cleanup.
  if [[ -x "build/bin/repro${exe_ext}" ]]; then
    "build/bin/repro${exe_ext}" daemon stop >/dev/null 2>&1 || true
  fi
  rm -rf "${REPRO_TEST_DAEMON_DIR}" 2>/dev/null || true
}
trap _repro_test_daemon_cleanup EXIT

# Step 1 (B5): bootstrap ./build/bin/repro from nim when missing.
# Idempotent — the recipe no-ops when the binary already exists.
just bootstrap

# Provider compilation uses the io-monitor path, so it needs a valid
# monitor shim before the graph can build the canonical ``.#test-fixtures``
# shim edge. ``just bootstrap`` only runs ``scripts/build_apps.sh`` when
# ``build/bin/repro`` is missing; on warm checkouts that can leave a present
# repro binary with no shim artifact. Seed the shim directly from io-mon here,
# then let ``.#test-fixtures`` rebuild/verify the graph-owned artifact below.
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

# Step 2 (B5): build the runquota sibling so ``runquotad`` is on
# PATH before the engine starts. The cross-project ``uses: runquota``
# resolver isn't online yet (B0 outcome), so the daemon still builds
# via the sibling's own Justfile; reprobuild's repro.nim declares
# ``uses: "runquotad"`` (B0) which the path-mode resolver checks
# during the engine's tool-resolution phase. Without runquotad on
# PATH, Step 3 fails with ``tool-resolution failed: runquotad ...
# was not found in PATH``. Once the cross-project selector lands,
# this step folds into Step 3 as another ``.#`` fragment.
if [[ -d "../runquota" ]]; then
  if [[ ! -x "../runquota/build/bin/runquotad${exe_ext}" ]]; then
    printf 'Building prerequisite sibling: ../runquota\n' >&2
    (cd ../runquota && just build) > test-logs/runquota-build.log 2>&1 || {
      echo "runquota build failed; see test-logs/runquota-build.log" >&2
      exit 1
    }
  fi
  # Prepend ../runquota/build/bin so the path-mode resolver finds
  # runquotad during the engine pass below.
  RUNQUOTA_BIN_ABS="$(cd ../runquota/build/bin && pwd)"
  export PATH="${RUNQUOTA_BIN_ABS}:${PATH}"
fi

# Step 2b: build the reprobuild-cmake fork so the cmake-develop e2e tests
# (tests/e2e/cmake-develop/) have their forked ``cmake`` carrying the
# Reprobuild generator. Those tests hard-require it (``check
# forkedCMake.len > 0`` — no graceful skip), so the fork is a real test
# prerequisite, not a benchmark-only artifact. Mirror the runquota
# prerequisite above; idempotent — skip when already built (warm
# self-hosted checkout). The CMake self-build is heavy, so cap parallelism
# on shared runners.
if [[ -d "../reprobuild-cmake" ]]; then
  if [[ ! -x "../reprobuild-cmake/build/bin/cmake${exe_ext}" ]]; then
    printf 'Building prerequisite sibling: ../reprobuild-cmake (CMake fork)\n' >&2
    cmake_jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
    if (( cmake_jobs > 16 )); then cmake_jobs=16; fi
    cmake_generator="Unix Makefiles"
    if command -v ninja >/dev/null 2>&1; then
      cmake_generator="Ninja"
    fi
    cmake_cc="$(command -v cc)"
    cmake_cxx="$(command -v c++)"
    cmake_osx_sysroot=""
    cmake_apple_framework_flags=()
    if [[ "$(uname -s)" == "Darwin" ]]; then
      cmake_osx_sysroot="$(find /nix/store -maxdepth 7 -path '*/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk' -type d -print 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
      if [[ -z "${cmake_osx_sysroot}" ]]; then
        echo "reprobuild-cmake build requires a macOS SDK in /nix/store" >&2
        exit 1
      fi
      cmake_apple_framework_dir="${cmake_osx_sysroot}/System/Library/Frameworks"
      if [[ -d "${cmake_apple_framework_dir}" ]]; then
        cmake_apple_framework_flags=(
          "-DCMAKE_C_FLAGS=-F${cmake_apple_framework_dir}"
          "-DCMAKE_CXX_FLAGS=-F${cmake_apple_framework_dir}"
          "-DCMAKE_EXE_LINKER_FLAGS=-F${cmake_apple_framework_dir}"
        )
      fi
    fi
    iconv_header="$(find /nix/store -maxdepth 3 -path '*/include/iconv.h' -print -quit 2>/dev/null || true)"
    iconv_args=()
    if [[ -n "${iconv_header}" ]]; then
      iconv_include_dir="$(dirname "${iconv_header}")"
      iconv_prefix="${iconv_include_dir%/include}"
      iconv_lib="${iconv_prefix}/lib/libiconv.dylib"
      if [[ ! -f "${iconv_lib}" ]]; then
        iconv_lib="$(find /nix/store -maxdepth 3 -path '*/lib/libiconv.dylib' -print -quit 2>/dev/null || true)"
      fi
      if [[ -n "${iconv_lib}" && -f "${iconv_lib}" ]]; then
        iconv_args=(
          "-DICONV_INCLUDE_DIR=${iconv_include_dir}"
          "-DLIBICONV_PATH=${iconv_lib}"
        )
      fi
    fi
    (cd ../reprobuild-cmake \
        && if [[ -f build/CMakeCache.txt ]] && \
             { ! grep -q "^CMAKE_GENERATOR:INTERNAL=${cmake_generator}$" build/CMakeCache.txt || \
               ! grep -q "^CMAKE_C_COMPILER:FILEPATH=${cmake_cc}$" build/CMakeCache.txt || \
               ! grep -q "^CMAKE_CXX_COMPILER:FILEPATH=${cmake_cxx}$" build/CMakeCache.txt || \
               { [[ -n "${cmake_osx_sysroot}" ]] && ! grep -q "^CMAKE_OSX_SYSROOT:.*=${cmake_osx_sysroot}$" build/CMakeCache.txt; } || \
               { [[ -n "${cmake_apple_framework_dir:-}" ]] && ! grep -q "^CMAKE_CXX_FLAGS:STRING=-F${cmake_apple_framework_dir}$" build/CMakeCache.txt; } || \
               ! grep -q "^ENABLE_IPV6:.*=OFF$" build/CMakeCache.txt; }; then \
             rm -rf build; \
           fi \
        && cmake -S . -B build -G "${cmake_generator}" \
             -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_C_COMPILER="${cmake_cc}" \
             -DCMAKE_CXX_COMPILER="${cmake_cxx}" \
             ${cmake_osx_sysroot:+-DCMAKE_OSX_SYSROOT="${cmake_osx_sysroot}"} \
             "${cmake_apple_framework_flags[@]}" \
             -DCMAKE_USE_SYSTEM_CURL=OFF \
             -DCMAKE_USE_SYSTEM_ZLIB=OFF \
             -DENABLE_IPV6=OFF \
             "${iconv_args[@]}" \
        && cmake --build build --target cmake --parallel "${cmake_jobs}") \
        > test-logs/reprobuild-cmake-build.log 2>&1 || {
      echo "reprobuild-cmake build failed; see test-logs/reprobuild-cmake-build.log" >&2
      exit 1
    }
  fi
fi

# Step 3 (B5): build the apps, test helpers, and test binaries through
# the engine. Replaces steps 1 (build_apps.sh) + 3 (build_test_helper
# x 3) + 4 (./build/bin/repro build test) + 5 (HCR rebuild loop) of
# the legacy script. Cap parallelism for memory-constrained CI runners
# (same logic as the legacy script: ~300-500 MB peak per nim c).
if [[ -z "${REPROBUILD_MAX_PARALLELISM:-}" ]]; then
  available_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  cap=$(( available_cores / 2 ))
  if (( cap < 1 )); then cap=1; fi
  if (( cap > 4 )); then cap=4; fi
  export REPROBUILD_MAX_PARALLELISM="${cap}"
fi
printf 'Building apps + test-helpers + test-builds via repro (REPROBUILD_MAX_PARALLELISM=%s)\n' \
  "${REPROBUILD_MAX_PARALLELISM}" >&2

# Build each collection in its own invocation. The engine's M3
# selector parser rejects multiple path/fragment selectors in a
# single command ("multiple path / fragment selectors are not
# supported in M3"); name-shaped selectors may follow a single
# path anchor but ``.#apps``/``.#test-helpers``/``.#test-builds``
# are all fragment-shaped and disambiguated against the on-disk
# ``apps/`` directory. Looping is the M3 workaround; a future
# milestone that grows multi-fragment selector support folds the
# three invocations back into one.
repro_build_collection() {
  local collection="$1"
  if ! ./build/bin/repro build --tool-provisioning=path --daemon=off "${collection}"; then
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
# Test-Fixtures-In-Build-Graph M2: rebuild the monitor-shim fixture
# (``build/lib/librepro_monitor_shim.<ext>``) through the graph before
# the tests run. ``prepareMonitorTools`` and the three self-shim outlier
# tests now ``requireBinary`` this artifact instead of compiling it per
# test. The bootstrap shim above is only the provider-compile seed; this
# graph edge remains the canonical fixture build the tests consume.
repro_build_collection ".#test-fixtures" || exit 1
repro_build_collection ".#test-builds" || exit 1

# Step 4 (B5): Python tests + test-binary execution. The Python loop runs
# before the Nim suite so a Python regression surfaces fast and doesn't get
# buried in the Nim output. The Nim suite is driven by ct-test-runner (Tier-1
# Standard --list-json/--run protocol) when installed, with the M3 internal
# runner as the documented fallback. Execution stays shell-shaped until the
# engine's typed-tool resolver grows profiles for ``buildNimUnittest`` /
# ``python_unittest_runner`` — once that lands, ``repro test`` replaces both
# halves of this step.
while IFS= read -r -d '' test_file; do
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

# D6 lands a per-test ``--test-timeout=N`` flag on the M3 internal
# runner. Default below is 600 seconds (10 minutes) per test — well
# above any normal test on CI, but low enough that a single hung test
# fails with a clear TIMEOUT signature in the build report while the
# rest of the suite continues instead of starving every queue slot
# behind it.
#
# The shell ``timeout`` wrapper stays as a very high wall-clock
# backstop (default 4h) in case the runner itself wedges before any
# per-test deadline fires (e.g. fd-race tear-down during spawn, signal
# handler stuck). On CI a clean 500-test sweep at 4 threads completes
# in ~45-60 min, so 4h is far above the normal envelope.
# ``--kill-after=30s`` sends SIGKILL 30 seconds after SIGTERM in case
# the runner is stuck in uninterruptible waits. CI surfaces the
# SIGTERM via exit code 124.
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
  # ``--no-build`` skips the runner's own build step (the engine
  # already produced every binary in build/test-bin via Step 2).
  # The fallback runner defaults to one worker because several heavy e2e
  # tests capture nested ``repro build`` output until the child exits.
  # Running two such tests together on a busy shared host can leave both
  # silent long enough to trip the idle timeout despite real progress.
  # Callers that want the faster, best-effort local path can still set
  # REPROBUILD_TEST_THREADS explicitly. ct-test-runner is unaffected and
  # is the preferred path.
  # ``--test-timeout`` is the D6 per-test SIGKILL deadline; the outer
  # ``timeout`` is the runner-phase wall-clock backstop.
  timeout --kill-after=30s "${RUNNER_TIMEOUT}" "${runner_bin}" \
    --no-build \
    --threads=${REPROBUILD_TEST_THREADS:-1} \
    --test-timeout=${TEST_TIMEOUT} \
    --bin-dir=build/test-bin \
    --summary-json=test-logs/parallel-run.json \
    --results-dir=test-logs/results
fi
