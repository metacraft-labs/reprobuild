#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/nimcache

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  nim check \
    --nimcache:"build/nimcache/check-${lib}" \
    "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim check \
    --nimcache:"build/nimcache/check-${name}" \
    "${path}"
done < apps/entrypoints.txt
