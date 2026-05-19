#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

mkdir -p bench-results test-logs build

if [ ! -x build/bin/repro ]; then
  ./scripts/build_apps.sh >/dev/null
fi

if [ ! -x ../runquota/build/bin/runquotad ]; then
  (cd ../runquota && just build >/dev/null)
fi

if [ ! -x ../reprobuild-cmake/build/bin/cmake ]; then
  echo "missing ../reprobuild-cmake/build/bin/cmake; build the CMake fork first" >&2
  exit 2
fi

python3 scripts/cmake_generator_competitiveness_bench.py "$@"
