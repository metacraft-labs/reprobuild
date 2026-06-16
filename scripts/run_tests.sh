#!/usr/bin/env bash
set -euo pipefail

# Bootstrap-And-Self-Build B5: the original 6-step shell loop
# (build_apps + build_sibling + build_test_helper x 3 + repro build
# test + macOS-arm64 HCR rebuild + ct-test-runner) has been compressed
# to 4 steps. Steps 1, 3, 4, and 5 from the original now flow through
# the project DSL: ``.#apps`` builds the binaries (B1), ``.#test-helpers``
# builds the helpers (B2), and ``.#test-builds`` compiles every test
# (B3) with the macOS-arm64 HCR ``extraPassC`` / ``extraPassL`` flags
# baked into the build edges (B4) so the standalone HCR re-compile
# loop is no longer needed. The cross-project runquota build and the
# test-execute runner stay shell-shaped until the engine's tool-
# resolver gap closes for ``ct_test_nim_unittest.buildNimUnittest`` and
# ``python_unittest_runner.pythonUnittest`` — see B4 outcome.

mkdir -p build/test-bin build/nimcache test-logs

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exe_ext=".exe"
    ;;
  *)
    exe_ext=""
    ;;
esac

# Step 1 (B5): bootstrap ./build/bin/repro from nim when missing.
# Idempotent — the recipe no-ops when the binary already exists.
just bootstrap

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
# Test-Fixtures-In-Build-Graph M2: build the monitor-shim fixture
# (``build/lib/librepro_monitor_shim.<ext>``) through the graph before
# the tests run. ``prepareMonitorTools`` and the three self-shim outlier
# tests now ``requireBinary`` this artifact instead of compiling it per
# test. ``just bootstrap`` only runs ``build_apps.sh`` (which also
# produces the shim) when ``build/bin/repro`` is MISSING, so on a warm
# checkout the shim would otherwise never be built — this explicit
# fixture build closes that gap.
repro_build_collection ".#test-fixtures" || exit 1
repro_build_collection ".#test-builds" || exit 1

# Step 4 (B5): Python tests + test-binary execution. The Python loop
# runs before the Nim suite so a Python regression surfaces fast and
# doesn't get buried in the Nim output. The Nim suite is driven by
# ct-test-runner (Tier-1 Standard --list-json/--run protocol) with the
# M3 internal runner as the documented fallback. Execution stays
# shell-shaped until the engine's typed-tool resolver grows profiles
# for ``buildNimUnittest`` / ``python_unittest_runner`` — once that
# lands, ``repro test`` replaces both halves of this step.
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

ct_test_runner="../ct-test/build/bin/ct-test-runner${exe_ext}"
if [[ -x "${ct_test_runner}" ]]; then
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
  # Thread count capped at 2 to dodge the runner's known fd-race;
  # callers can lift via REPROBUILD_TEST_THREADS once the runner fix
  # lands. ct-test-runner is unaffected and is the preferred path.
  # ``--test-timeout`` is the D6 per-test SIGKILL deadline; the outer
  # ``timeout`` is the runner-phase wall-clock backstop.
  timeout --kill-after=30s "${RUNNER_TIMEOUT}" "${runner_bin}" \
    --no-build \
    --threads=${REPROBUILD_TEST_THREADS:-2} \
    --test-timeout=${TEST_TIMEOUT} \
    --bin-dir=build/test-bin \
    --summary-json=test-logs/parallel-run.json \
    --results-dir=test-logs/results
fi
