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
  nim c -r \
    --threads:on \
    "${extra_flags[@]}" \
    --nimcache:"build/nimcache/${test_name}" \
    --out:"build/test-bin/${test_name}" \
    "${test_file}"
done < <(
  find tests -type f -name 't*.nim' -print0
  find libs -path '*/tests/t*.nim' -type f -print0
)

if [ "${found}" -eq 0 ]; then
  echo "no Nim tests found" >&2
  exit 1
fi
