#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

mkdir -p bench-results test-logs build

export REPROBUILD_BUILD_MODE=release
./scripts/build_apps.sh >/dev/null

case "$(uname -s)" in
  Darwin)
    monitor_shim="${repo_root}/build/lib/librepro_monitor_shim.dylib"
    ;;
  Linux)
    monitor_shim="${repo_root}/build/lib/librepro_monitor_shim.so"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    monitor_shim="${repo_root}/build/lib/librepro_monitor_shim.dll"
    ;;
  *)
    monitor_shim=""
    ;;
esac

if [ -n "${monitor_shim}" ]; then
  if [ ! -f "${monitor_shim}" ]; then
    echo "missing monitor shim: ${monitor_shim}" >&2
    exit 2
  fi
  export REPRO_MONITOR_SHIM_LIB="${monitor_shim}"
fi

if [ ! -x ../runquota/build/bin/runquotad ] || [ "${REPROBUILD_BUILD_MODE:-}" = "release" ]; then
  (cd ../runquota && RUNQUOTA_BUILD_MODE="${REPROBUILD_BUILD_MODE:-release}" just build >/dev/null)
fi

if [ ! -x ../reprobuild-cmake/build/bin/cmake ]; then
  echo "missing ../reprobuild-cmake/build/bin/cmake; build the CMake fork first" >&2
  exit 2
fi

python3 scripts/cmake_generator_competitiveness_bench.py "$@"
