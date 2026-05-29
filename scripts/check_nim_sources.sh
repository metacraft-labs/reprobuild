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

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim check \
    "${nim_check_flags[@]}" \
    --nimcache:"build/nimcache/check-${name}" \
    "${path}"
done < apps/entrypoints.txt
