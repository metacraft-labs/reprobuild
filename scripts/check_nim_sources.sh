#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/nimcache

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

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  nim check \
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
  # ``read -r name path extra_flags`` packs everything after ``path``
  # into ``extra_flags`` as a single whitespace-separated string;
  # word-split it here so each token becomes its own ``nim`` argv
  # entry.  Empty when the entry has no extra flags.
  read -r -a extra_flags_array <<<"${extra_flags:-}"
  nim check \
    "${nim_check_flags[@]}" \
    ${extra_flags_array[@]+"${extra_flags_array[@]}"} \
    --nimcache:"build/nimcache/check-${name}" \
    "${path}"
done < apps/entrypoints.txt
