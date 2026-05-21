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
  nim c -r \
    --threads:on \
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
