#!/usr/bin/env bash
set -euo pipefail

# Test-Edges-And-Parallel-Runner M3 — ``scripts/run_tests.sh`` is now
# a thin shim around the protocol-level parallel runner shipped at
# ``tools/test-runner/repro_test_runner.nim``. The build phase is
# unchanged (sibling daemons, test helpers, the provider-mode
# carry-forward ``nim c`` loop, then ``repro build test`` for the
# engine-driven majority); execution is delegated to the new runner,
# which speaks the Tier-1 binary protocol shipped in
# ``ct_test_unittest_parallel`` (M2) and fans out per-test ``--run``
# invocations across ``nproc`` workers.
#
# The provider-mode carry-forward loop stays for now: the
# ``ct_test_nim_unittest`` adapter learned a ``defines:`` parameter in
# M2 but the mechanical migration of the affected test sources to
# routed-through-engine builds is tracked separately. M3 keeps the
# carry-forward in place so all 385 test binaries land in
# ``build/test-bin/`` either way; the runner doesn't care which build
# path produced them.

mkdir -p build/test-bin build/nimcache test-logs

bash ./scripts/build_apps.sh

# Build out-of-repo test prerequisites BEFORE compiling the suite.
build_sibling() {
  local sibling_dir="$1"
  local marker_path="$2"
  if [[ ! -d "${sibling_dir}" ]]; then
    return 0
  fi
  if [[ -x "${marker_path}" ]]; then
    return 0
  fi
  printf 'Building prerequisite: %s\n' "${sibling_dir}" >&2
  (cd "${sibling_dir}" && just build)
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exe_ext=".exe"
    ;;
  *)
    exe_ext=""
    ;;
esac
build_sibling "../runquota" "../runquota/build/bin/runquotad${exe_ext}"

# Test-side helper binaries that more than one suite reuses.
build_test_helper() {
  local source_path="$1"
  local output_path="$2"
  local cache_name="$3"
  if [[ -x "${output_path}" ]]; then
    return 0
  fi
  printf 'Building test helper: %s\n' "${output_path}" >&2
  nim c \
    --threads:on \
    --hints:off \
    --warnings:off \
    --nimcache:"build/nimcache/${cache_name}" \
    --out:"${output_path}" \
    "${source_path}"
}

build_test_helper \
  "tests/fixtures/local-daemons-control-plane/live-endpoint-helper/live_endpoint_helper.nim" \
  "build/test-bin/live_endpoint_helper${exe_ext}" \
  "live_endpoint_helper"
build_test_helper \
  "tests/fixtures/local-daemons-control-plane/fake-protocol-daemon-helper/fake_protocol_daemon_helper.nim" \
  "build/test-bin/fake_protocol_daemon_helper${exe_ext}" \
  "fake_protocol_daemon_helper"

if [[ -f tests/e2e/home-generations/harness_apply_lock_holder.nim ]]; then
  nim c \
    --threads:on \
    --hints:off \
    --nimcache:build/nimcache/harness_apply_lock_holder \
    --out:build/test-bin/harness_apply_lock_holder \
    tests/e2e/home-generations/harness_apply_lock_holder.nim
fi

# Provider-mode carry-forward: ``--define:reproProviderMode`` for the
# tests that exercise ``buildPackageFragment`` directly. These remain
# direct ``nim c`` invocations until per-edge migration through the
# ``defines:`` adapter parameter is mechanical-merged.
needs_provider_mode() {
  local test_file="$1"
  case "${test_file}" in
    libs/repro_standard_provider/tests/*|*/libs/repro_standard_provider/tests/*)
      return 0 ;;
    libs/repro_build_engine/tests/t_engine_implicit_*|*/libs/repro_build_engine/tests/t_engine_implicit_*|\
    libs/repro_build_engine/tests/t_engine_multiple_outputs_*|*/libs/repro_build_engine/tests/t_engine_multiple_outputs_*|\
    libs/repro_build_engine/tests/t_engine_target_export_*|*/libs/repro_build_engine/tests/t_engine_target_export_*)
      return 0 ;;
    libs/repro_build_engine/tests/t_engine_typed_output_*|*/libs/repro_build_engine/tests/t_engine_typed_output_*|\
    libs/repro_build_engine/tests/t_engine_method_call_on_typed_field_*|*/libs/repro_build_engine/tests/t_engine_method_call_on_typed_field_*)
      return 0 ;;
    tests/e2e/local-build-engine/t_repro_build_ambiguous_target_diagnostic.nim|*/tests/e2e/local-build-engine/t_repro_build_ambiguous_target_diagnostic.nim)
      return 0 ;;
    tests/e2e/local-build-engine/t_repro_build_qualified_target_resolves.nim|*/tests/e2e/local-build-engine/t_repro_build_qualified_target_resolves.nim)
      return 0 ;;
  esac
  return 1
}

hcr_extra_flags() {
  local test_name="$1"
  if [[ "${test_name}" == "t_hcr_agent_process_target" ||
        "${test_name}" == "t_e2e_repro_watch_hcr_multi_target_independent_patches" ||
        "${test_name}" == "t_e2e_repro_watch_hcr_one_target_agent_inject_failure" ]] &&
      [[ "$(uname -s)" == "Darwin" ]] &&
      [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    printf '%s\n' "--passC:-fpatchable-function-entry=16,0"
    printf '%s\n' "--passL:-Wl,-segprot,__HCR,rwx,rwx"
  fi
}

compile_carry_forward_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "${test_file}" .nim)"
  local extra_flags=()
  if needs_provider_mode "${test_file}"; then
    extra_flags+=("--define:reproProviderMode")
  fi
  while IFS= read -r flag; do
    [[ -n "${flag}" ]] && extra_flags+=("${flag}")
  done < <(hcr_extra_flags "${test_name}")
  printf 'Compiling carry-forward test: %s\n' "${test_file}" >&2
  nim c \
    --threads:on \
    --hints:off \
    --warnings:off \
    ${extra_flags[@]+"${extra_flags[@]}"} \
    --nimcache:"build/nimcache/${test_name}" \
    --out:"build/test-bin/${test_name}" \
    "${test_file}"
}

carry_forward_tests=()
engine_built_tests=()
while IFS= read -r -d '' test_file; do
  if needs_provider_mode "${test_file}"; then
    carry_forward_tests+=("${test_file}")
  else
    engine_built_tests+=("${test_file}")
  fi
done < <(
  find tests -type f -name 't_*.nim' -print0
  find libs -path '*/tests/t_*.nim' -type f -print0
  find libs -path '*/tests/test_*.nim' -type f -print0
  find tools -path '*/tests/test_*.nim' -type f -print0 2>/dev/null
)

# HCR carry-forward: a handful of macOS arm64 tests need extra
# compile flags beyond the --define carry-forward.
for test_file in "${engine_built_tests[@]}"; do
  test_name="$(basename "${test_file}" .nim)"
  if [[ -n "$(hcr_extra_flags "${test_name}")" ]]; then
    carry_forward_tests+=("${test_file}")
  fi
done

filtered_engine_tests=()
for test_file in "${engine_built_tests[@]}"; do
  test_name="$(basename "${test_file}" .nim)"
  if [[ -n "$(hcr_extra_flags "${test_name}")" ]]; then
    continue
  fi
  filtered_engine_tests+=("${test_file}")
done
engine_built_tests=("${filtered_engine_tests[@]}")

for test_file in "${carry_forward_tests[@]+"${carry_forward_tests[@]}"}"; do
  compile_carry_forward_test "${test_file}"
done

if [[ "${#engine_built_tests[@]}" -gt 0 ]]; then
  printf 'Building %d test binaries via repro build test\n' \
    "${#engine_built_tests[@]}" >&2
  ./build/bin/repro build test
fi

# Python tests run before the Nim suite so a Python regression surfaces
# fast and doesn't get buried in the Nim output.
while IFS= read -r -d '' test_file; do
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

# M3 runner: build if missing, then delegate the entire Nim test
# execution phase to the parallel runner. The runner discovers test
# binaries under ``build/test-bin/``, probes each for the M2
# protocol surface, and fans out per-test invocations across
# ``nproc`` workers. Sequential per-binary execution is gone.
runner_bin="build/bin/repro_test_runner${exe_ext}"
if [[ ! -x "${runner_bin}" ]]; then
  printf 'Building test runner: %s\n' "${runner_bin}" >&2
  nim c \
    -d:release \
    --threads:on \
    --hints:off \
    --warnings:off \
    --nimcache:build/nimcache/repro_test_runner \
    --out:"${runner_bin}" \
    tools/test-runner/repro_test_runner.nim
fi

# The runner already ran ``repro build test`` for us above; tell it to
# skip its own build step so we don't double-build.
"${runner_bin}" \
  --no-build \
  --bin-dir=build/test-bin \
  --summary-json=test-logs/parallel-run.json \
  --results-dir=test-logs/results
