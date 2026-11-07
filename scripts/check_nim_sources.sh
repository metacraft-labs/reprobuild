#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/nimcache

# Keep standalone ``nim check`` invocations on the same source-path resolver
# as the app build and test-suite entry points.  In particular,
# ``io_mon`` imports the extracted ``shm_queue`` package even when a
# sibling checkout is absent and the dev shell supplies it from the Nix store.
# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh
export SHM_QUEUE_SRC="$(resolve_shm_queue_src)"
export BEARSSL_SRC="$(resolve_bearssl_src)"

# Mirror the compile defines used by the real app build in
# scripts/build_apps.sh:
#   --define:reproProviderMode  — gates the repro_provider_runtime
#     re-export inside repro_project_dsl, plus several proc bodies in
#     runtime_provider.nim that the standard provider and trycompile
#     direct providers depend on. Without it, `nim check` on
#     libs/repro_standard_provider/* (and any other lib that walks
#     through buildPackageFragment) reports spurious "undeclared
#     identifier" errors because the visibility of the conditionally-
#     gated symbols differs from a real build.
nim_check_flags=(--define:reproProviderMode)

# Every ``nim check`` below is independent of the others (each has its own
# nimcache), so they run concurrently, ``REPRO_LINT_JOBS`` at a time (default:
# one per processor). Serially the sweep took about five minutes on a 32-core
# machine; concurrently, under one. Each check's output is held until all have
# finished and then printed in list order, so the log reads exactly as a serial
# run's would, and the exit status is non-zero if any check failed.
jobs_max="${REPRO_LINT_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
out_dir="$(mktemp -d)"
trap 'rm -rf "${out_dir}"' EXIT
labels=()

run_check() {
  local index=$1
  shift
  while (( $(jobs -rp | wc -l) >= jobs_max )); do
    wait -n || true
  done
  (
    status=0
    nim check "$@" >"${out_dir}/${index}.log" 2>&1 || status=$?
    echo "${status}" >"${out_dir}/${index}.status"
  ) &
}

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  labels+=("libs/${lib}/src/${lib}.nim")
  run_check "${#labels[@]}" \
    "${nim_check_flags[@]}" \
    --nimcache:"build/nimcache/check-${lib}" \
    "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

# ``apps/entrypoints.txt`` is ``name path [extra-nim-flags...]`` per
# its header: every token AFTER ``path`` is an extra ``nim`` flag the
# entrypoint needs (``--define:ssl``, ``--path:apps/<name>/src``,
# ``--define:reproProviderMode``, …).  ``nim check`` MUST receive
# them too — without ``--path:apps/repro-harvest-apt/src`` the
# repro_harvest_apt entry's local sub-module imports
# (``repro_harvest_apt/fetch`` / ``signature`` / ``source_spec``)
# fail to resolve and the lint reports spurious "cannot open file"
# errors while the actual ``nim c`` build in
# ``scripts/build_apps.sh`` succeeds.
while read -r name path extra_flags; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  # Git may check this file out with CRLF on Windows. Bash does not include
  # carriage return in its default IFS, so strip it from the final field.
  path="${path%$'\r'}"
  extra_flags="${extra_flags%$'\r'}"
  # ``read -r name path extra_flags`` packs everything after ``path``
  # into ``extra_flags`` as a single whitespace-separated string;
  # word-split it here so each token becomes its own ``nim`` argv
  # entry.  Empty when the entry has no extra flags.
  read -r -a extra_flags_array <<<"${extra_flags:-}"
  labels+=("${path}")
  run_check "${#labels[@]}" \
    "${nim_check_flags[@]}" \
    ${extra_flags_array[@]+"${extra_flags_array[@]}"} \
    --nimcache:"build/nimcache/check-${name}" \
    "${path}"
done < apps/entrypoints.txt
wait

failed=()
for index in "${!labels[@]}"; do
  n=$((index + 1))
  cat "${out_dir}/${n}.log"
  status="$(cat "${out_dir}/${n}.status" 2>/dev/null || echo missing)"
  [[ "${status}" == 0 ]] || failed+=("${labels[$index]} (exit ${status})")
done
if (( ${#failed[@]} )); then
  printf 'check_nim_sources: nim check failed for %d of %d source(s):\n' "${#failed[@]}" "${#labels[@]}" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf 'check_nim_sources: nim check passed for %d source(s), %s at a time.\n' "${#labels[@]}" "${jobs_max}"
