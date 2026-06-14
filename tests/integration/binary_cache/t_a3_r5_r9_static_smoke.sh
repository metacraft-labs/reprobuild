#!/usr/bin/env bash
# t_a3_r5_r9_static_smoke.sh — A3 P5 static-validation gate.
#
# Per the campaign spec § A3 P5:
#
#   "Smoke gate: verify each build-*.sh script parses + sources
#    cache-helper.sh correctly via a static check (bash -n build-X.sh)."
#
# For each R4-R9 build-*.sh script we:
#   1. Run ``bash -n <script>`` to verify shell-syntax correctness.
#   2. Grep for ``cache-helper.sh`` to confirm the wiring is present.
#   3. Grep for ``cache_phase_prepare`` + ``cache_phase_publish`` to
#      confirm the prelude + postlude hooks are wired.
#
# A small allowlist documents scripts that intentionally lack the
# wiring (build-cc-wrapper-glibc.sh is an exec wrapper, not a build;
# the R9 systemd / initramfs scripts ship deferred wiring).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ALLOWLIST_NO_CACHE_WIRING=(
  build-cc-wrapper-glibc.sh         # exec wrapper, not a build
  build-systemd.sh                   # R9: deferred; CPU-heavy chain
  build-initramfs.sh                 # R9: deferred
  build-minimal-initramfs.sh         # R9: deferred
)

in_allowlist() {
  local name="$1"
  for entry in "${ALLOWLIST_NO_CACHE_WIRING[@]}"; do
    if [[ "$entry" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

fail() { echo "FAIL: $*" >&2; exit 1; }

scripts=()
for dir in tcc-chain kernel systemd; do
  while IFS= read -r f; do
    scripts+=("$f")
  done < <(find "$REPO_ROOT/recipes/bootstrap/$dir/scripts" -maxdepth 1 \
            -name "build-*.sh" 2>/dev/null | sort)
done

total=0
wired=0
syntax_ok=0
allowed=0
for script in "${scripts[@]}"; do
  total=$((total + 1))
  base="$(basename "$script")"

  # Syntax check.
  if ! bash -n "$script" 2>/dev/null; then
    fail "bash -n $base reported syntax error"
  fi
  syntax_ok=$((syntax_ok + 1))

  if in_allowlist "$base"; then
    allowed=$((allowed + 1))
    continue
  fi

  if ! grep -q "cache-helper.sh" "$script"; then
    fail "$base does NOT source cache-helper.sh"
  fi
  if ! grep -q "cache_phase_prepare" "$script"; then
    fail "$base does NOT call cache_phase_prepare"
  fi
  if ! grep -q "cache_phase_publish" "$script"; then
    fail "$base does NOT call cache_phase_publish"
  fi
  wired=$((wired + 1))
done

echo "$total build-*.sh scripts inspected; $syntax_ok parsed cleanly"
echo "$wired scripts wired with cache prelude+postlude; $allowed in allowlist"
echo "PASS: t_a3_r5_r9_static_smoke"
