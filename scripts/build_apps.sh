#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/bin build/nimcache

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim c \
    --nimcache:"build/nimcache/${name}" \
    --out:"build/bin/${name}" \
    "${path}"
done < apps/entrypoints.txt
