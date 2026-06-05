#!/usr/bin/env bash
set -euo pipefail

# Test-Edges-And-Parallel-Runner M1 — the suite is now described as
# declared typed-output build edges in ``repro.tests.nim`` (generated
# by ``scripts/generate_test_edges.nim`` and ``include``d from
# ``repro.nim`` inside the ``package reprobuild:`` body). Each entry
# is a ``buildNimUnittest.build(...)`` call whose typed-output handle
# (``NimUnittestBinary``) points at ``build/test-bin/<basename>``. The
# aggregate target ``test`` selects every edge in one engine pass.
#
# This script:
#   1. Builds the apps + non-test prerequisites (sibling daemons,
#      legacy ``nim c`` test helpers, etc.) the same way the M0 script
#      did. Those are still expressed outside the engine for now.
#   2. Compiles the provider-mode-gated tests by hand: the
#      ``ct_test_nim_unittest`` adapter's ``cli:`` block doesn't yet
#      accept a ``defines:`` parameter (see the M1 spec). The path
#      rules that drove the per-test ``--define:reproProviderMode``
#      injection in the legacy script are preserved here as a
#      carry-forward — a follow-on milestone teaches the adapter the
#      parameter and reroutes these tests through the engine like the
#      rest.
#   3. Invokes ``repro build test`` to compile every other test binary
#      via the engine (action cache + parallel scheduler).
#   4. Runs each ``build/test-bin/t_*`` / ``build/test-bin/test_*``
#      binary sequentially, surfacing per-test exit codes and respecting
#      ``REPRO_TEST_FAIL_FAST``.

mkdir -p build/test-bin build/nimcache

bash ./scripts/build_apps.sh

# Build out-of-repo test prerequisites BEFORE compiling the suite. The
# tests assume sibling daemons (runquotad, the runquota CLI, etc.) are
# already on disk — the test code must not spawn `just build` for a
# neighbouring repo, both because that hangs the runner if the sibling
# has its own slow build graph AND because the test author has no way
# to control which version is built. The dev shell / CI runner is the
# correct place to decide which siblings exist and which version to
# build.
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

# Test-side helper binaries that more than one suite reuses. Building
# them here once (instead of inside each test's setup) keeps the per-
# test wall time predictable and avoids the Windows-specific failure
# where parallel ``nim c`` invocations contend on the same nimcache
# and lock each other out of the output file. These are NOT test
# binaries themselves — they're helpers the tests spawn — so they
# stay outside the typed-edge graph.
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
# direct ``nim c`` invocations until the ``ct_test_nim_unittest``
# adapter accepts a ``defines:`` parameter (see the M1 spec comment in
# ``scripts/generate_test_edges.nim``).
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

# Some tests need extra compile flags beyond --define:reproProviderMode
# (M4 HCR multi-target tests on Darwin arm64). Surface those as a per-
# test list; they fall under the same direct-nim-c carry-forward as the
# provider-mode tests until the adapter grows the right knobs.
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
# compile flags beyond the --define carry-forward. They are not
# provider-mode tests, but they still need the direct-nim-c path
# until the adapter grows the right knobs.
for test_file in "${engine_built_tests[@]}"; do
  test_name="$(basename "${test_file}" .nim)"
  if [[ -n "$(hcr_extra_flags "${test_name}")" ]]; then
    carry_forward_tests+=("${test_file}")
  fi
done

# Move the HCR-tagged tests out of the engine-built list. ``comm`` is
# not always available with the right options across platforms, so we
# do the set difference in pure shell.
filtered_engine_tests=()
for test_file in "${engine_built_tests[@]}"; do
  test_name="$(basename "${test_file}" .nim)"
  if [[ -n "$(hcr_extra_flags "${test_name}")" ]]; then
    continue
  fi
  filtered_engine_tests+=("${test_file}")
done
engine_built_tests=("${filtered_engine_tests[@]}")

# Compile the carry-forward tests by hand.
for test_file in "${carry_forward_tests[@]+"${carry_forward_tests[@]}"}"; do
  compile_carry_forward_test "${test_file}"
done

# Engine-driven build of the remaining test binaries. ``repro build
# test`` selects the aggregate emitted by ``repro.tests.nim`` so a
# single engine pass schedules every typed-edge compilation with
# action-cache reuse + parallelism.
if [[ "${#engine_built_tests[@]}" -gt 0 ]]; then
  printf 'Building %d test binaries via repro build test\n' \
    "${#engine_built_tests[@]}" >&2
  ./build/bin/repro build test
fi

# Python tests run before the Nim suite so a Python regression surfaces
# fast and doesn't get buried in the Nim output.
found=0
while IFS= read -r -d '' test_file; do
  found=1
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

# Run every compiled Nim test binary. We iterate the same source list
# we used to drive the build so missing binaries surface as failures
# (instead of silently being skipped).
failed_tests=()
all_tests=("${carry_forward_tests[@]+"${carry_forward_tests[@]}"}" \
  "${engine_built_tests[@]+"${engine_built_tests[@]}"}")

# Stable run order: source-path lex sort so failure output is
# reproducible across invocations.
mapfile -t all_tests < <(printf '%s\n' \
  "${all_tests[@]+"${all_tests[@]}"}" | LC_ALL=C sort)

for test_file in "${all_tests[@]+"${all_tests[@]}"}"; do
  found=1
  test_name="$(basename "${test_file}" .nim)"
  test_binary="build/test-bin/${test_name}${exe_ext}"
  if [[ ! -x "${test_binary}" ]]; then
    printf 'missing test binary: %s\n' "${test_binary}" >&2
    failed_tests+=("${test_file}")
    if [[ "${REPRO_TEST_FAIL_FAST:-0}" == "1" ]]; then
      break
    fi
    continue
  fi
  set +e
  "${test_binary}"
  test_rc=$?
  set -e
  if (( test_rc != 0 )); then
    failed_tests+=("${test_file}")
    if [[ "${REPRO_TEST_FAIL_FAST:-0}" == "1" ]]; then
      printf '\n[REPRO_TEST_FAIL_FAST] aborting after first failure: %s\n' \
        "${test_file}" >&2
      break
    fi
  fi
done

if [ "${found}" -eq 0 ]; then
  echo "no Nim tests found" >&2
  exit 1
fi

if (( ${#failed_tests[@]} > 0 )); then
  printf '\n========== FAILED TESTS (%d) ==========\n' "${#failed_tests[@]}" >&2
  for t in "${failed_tests[@]}"; do
    printf '  %s\n' "$t" >&2
  done
  exit 1
fi
