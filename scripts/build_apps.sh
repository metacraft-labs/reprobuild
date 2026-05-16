#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/bin build/nimcache

if [ "$(uname -s)" = "Darwin" ]; then
  mkdir -p build/lib
  if [ -d /Users/zahary/metacraft/ct_interpose/src ]; then
    nim c \
      --app:lib \
      --threads:on \
      --path:/Users/zahary/metacraft/ct_interpose/src \
      --nimcache:build/nimcache/repro-monitor-shim-dylib \
      --out:build/lib/librepro_monitor_shim.dylib \
      libs/repro_monitor_shim/src/repro_monitor_shim/macos_interpose.nim
  else
    echo "warning: /Users/zahary/metacraft/ct_interpose/src missing; skipping macOS monitor shim dylib" >&2
  fi
fi

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  nim c \
    --nimcache:"build/nimcache/${name}" \
    --out:"build/bin/${name}" \
    "${path}"
done < apps/entrypoints.txt
