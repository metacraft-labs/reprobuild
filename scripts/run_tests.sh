#!/usr/bin/env bash
set -euo pipefail

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
#
# We compile the sibling when its directory is present and the marker
# binary is missing. The check is intentionally idempotent and silent
# on a hot cache — a `just build` invocation on a fully-built tree is
# a no-op.
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

# `runquotad` and `runquota` ship out of ../runquota. The Windows
# binary carries `.exe`; the POSIX one does not. Both naming forms
# are covered by listing the candidate paths explicitly.
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
# and lock each other out of the output file.
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

found=0
failed_tests=()
while IFS= read -r -d '' test_file; do
  found=1
  python3 "${test_file}"
done < <(
  find tests -type f -name 'test_*.py' -print0
)

while IFS= read -r -d '' test_file; do
  found=1
  test_name="$(basename "${test_file}" .nim)"
  extra_flags=()
  if [[ "${test_name}" == "t_hcr_agent_process_target" ||
        "${test_name}" == "t_e2e_repro_watch_hcr_multi_target_independent_patches" ||
        "${test_name}" == "t_e2e_repro_watch_hcr_one_target_agent_inject_failure" ]] &&
      [[ "$(uname -s)" == "Darwin" ]] &&
      [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    # Named-Targets M4: the two M4 multi-target HCR e2e tests live in
    # ``tests/e2e/hcr-watch/`` and depend on the same Mach-O patch-
    # extraction primitives as ``t_hcr_agent_process_target``. They are
    # gated ``when defined(macosx) and defined(arm64)`` and need the
    # same patchable-function-entry / __HCR-segprot compile flags so
    # the per-target HCR session lifecycle's
    # ``objectFunctionBytes`` / ``minimalAarch64EhFrameTemplate``
    # codepaths land valid bytes.
    extra_flags+=(
      "--passC:-fpatchable-function-entry=16,0"
      "--passL:-Wl,-segprot,__HCR,rwx,rwx"
    )
  fi
  # Provider-mode tests gate on `--define:reproProviderMode` because the
  # libs/repro_standard_provider conventions exercise procs that are
  # `when defined(reproProviderMode)`-gated in repro_project_dsl/runtime_provider.nim
  # (buildPackageFragment / GraphFragment / StoredGraphFragment /
  # nimEmitFragment). The standard-provider binary itself ships this define
  # via apps/entrypoints.txt; the convention tests under
  # libs/repro_standard_provider/tests/ need the same define to compile.
  # Path-based detection keeps the runner schema-free and avoids per-test
  # sidecar files. (Tests under libs/repro_cmake_trycompile/tests/ do not
  # need the define — only the provider conventions do.)
  case "${test_file}" in
    libs/repro_standard_provider/tests/*|*/libs/repro_standard_provider/tests/*)
      extra_flags+=("--define:reproProviderMode")
      ;;
    # Named-Targets M1 engine tests: the new ``t_engine_implicit_*``
    # / ``t_engine_target_export_*`` / ``t_engine_multiple_outputs_*``
    # suites under ``libs/repro_build_engine/tests/`` invoke
    # ``buildPackageFragment`` directly to assert against the
    # normalized provider-graph artifact. That entry point is gated
    # on ``reproProviderMode`` in
    # ``libs/repro_project_dsl/src/repro_project_dsl/runtime_provider.nim``,
    # so the test file needs the same define.
    libs/repro_build_engine/tests/t_engine_implicit_*|*/libs/repro_build_engine/tests/t_engine_implicit_*|\
    libs/repro_build_engine/tests/t_engine_multiple_outputs_*|*/libs/repro_build_engine/tests/t_engine_multiple_outputs_*|\
    libs/repro_build_engine/tests/t_engine_target_export_*|*/libs/repro_build_engine/tests/t_engine_target_export_*)
      extra_flags+=("--define:reproProviderMode")
      ;;
    # Test-Edges-And-Parallel-Runner M0 DSL tests: the ``t_dsl_test_block_*``
    # suite under ``libs/repro_project_dsl/tests/`` drives
    # ``buildPackageFragment`` directly so it can assert against the
    # synthesised ``BuildActionDef`` (``targetNames``, ``kind = bakTest``,
    # the ``output`` argument and the bool-flag argv values) produced by
    # the new ``test`` block sugar. That entry point is gated on
    # ``reproProviderMode`` in ``runtime_provider.nim``.
    libs/repro_project_dsl/tests/t_dsl_test_block_*|*/libs/repro_project_dsl/tests/t_dsl_test_block_*)
      extra_flags+=("--define:reproProviderMode")
      ;;
    # Named-Targets M2 ambiguity resolver test: builds two fragments
    # via ``buildPackageFragment`` (provider-mode-gated) so it asserts
    # the cross-package resolver path in-process without standing up
    # the multi-fragment provider machinery. The other three M2 e2e
    # tests are normal CLI invocations and don't need the define.
    tests/e2e/local-build-engine/t_repro_build_ambiguous_target_diagnostic.nim|*/tests/e2e/local-build-engine/t_repro_build_ambiguous_target_diagnostic.nim)
      extra_flags+=("--define:reproProviderMode")
      ;;
    # Named-Targets M5 qualified-target resolution test: same
    # in-process pattern as the M2 ambiguity test — drives
    # ``buildPackageFragment`` directly to assert the
    # qualified-form resolution path in-process.
    tests/e2e/local-build-engine/t_repro_build_qualified_target_resolves.nim|*/tests/e2e/local-build-engine/t_repro_build_qualified_target_resolves.nim)
      extra_flags+=("--define:reproProviderMode")
      ;;
  esac
  # Use the `${arr[@]+"${arr[@]}"}` idiom so the expansion is a no-op
  # when `extra_flags` is empty. macOS's bundled Bash 3.2.57 aborts under
  # `set -u` on a bare `"${extra_flags[@]}"` against an empty array;
  # Bash 4+ tolerates it. Same fix as scripts/build_apps.sh.
  #
  # Continue past per-test failures so we surface every failing test in
  # one run instead of aborting at the first failure. The aggregate exit
  # code is computed after the loop. Set REPRO_TEST_FAIL_FAST=1 to
  # restore the legacy stop-at-first-failure behaviour.
  set +e
  nim c -r \
    --threads:on \
    ${extra_flags[@]+"${extra_flags[@]}"} \
    --nimcache:"build/nimcache/${test_name}" \
    --out:"build/test-bin/${test_name}" \
    "${test_file}"
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
done < <(
  find tests -type f -name 't*.nim' -print0
  find libs -path '*/tests/t*.nim' -type f -print0
  # M66 harvester: tools/catalog-harvester/tests/test_*.nim — discovery is
  # name-prefixed `test_` (not `t*`) to distinguish maintainer-tool tests
  # from library / repository tests. The runner's existing add-extra-flags
  # logic doesn't apply to them (no provider-mode, no HCR).
  find tools -path '*/tests/test_*.nim' -type f -print0 2>/dev/null
)

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
