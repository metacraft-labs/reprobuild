#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/test-bin build/nimcache

bash ./scripts/build_apps.sh

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
  if [[ "${test_name}" == "t_hcr_agent_process_target" ]] &&
      [[ "$(uname -s)" == "Darwin" ]] &&
      [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
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
