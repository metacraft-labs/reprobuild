#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

mkdir -p bench-results/history build/bin build/nimcache test-logs

if [ ! -x ../runquota/build/bin/runquotad ]; then
  (cd ../runquota && just build)
fi

./scripts/build_apps.sh >/dev/null

bench_bin="build/bin/reprobuild_m23_bench"
nimcache="build/nimcache/reprobuild_m23_bench"
output="bench-results/reprobuild-core-mvp-performance.json"
history="bench-results/history/reprobuild-core-mvp-performance.latest.json"

nim c \
  --threads:on \
  --verbosity:0 \
  --hints:off \
  --nimcache:"${nimcache}" \
  --out:"${bench_bin}" \
  benchmarks/lib/reprobuild_m23_bench.nim >/dev/null

echo "running Reprobuild M23 production benchmark gate" >&2
"${bench_bin}" \
  --output="${output}" \
  --history="${history}" \
  "$@"
