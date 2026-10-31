#!/usr/bin/env bash
# Check that the static add-on `repro` does not depend on where the checkout
# lives: build HEAD in two fresh worktrees at different paths beside this
# checkout (so both see the same sibling repositories) and require the two
# artefacts to be byte-identical.
#
#   scripts/check_addon_static_reproducible.sh [ARCH]   (default: amd64)
#
# Each worktree starts with an empty build/ and nimcache, so nothing compiled
# at one path is reused at the other. Both are removed afterwards. Run inside
# the reprobuild dev shell (scripts/build_addon_static.sh needs it).
#
# Negative control: REPRO_ADDON_CHECK_NIM=<a nim binary> builds with that
# compiler instead of the dev shell's; with the fork before a0fabc99 (it
# hashed types by absolute path) the check must fail.
#
# Why it could differ: the Nim compiler hashed each type by the absolute path
# of the file defining it, and compiled the hashes into every `of` check.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${REPRO_ADDON_CHECK_NIM:-}" ]; then
  export PATH="$(dirname "$REPRO_ADDON_CHECK_NIM"):$PATH"
fi
echo "check_addon_static_reproducible: compiler $(command -v nim)"
arch="${1:-amd64}"
rev="$(git rev-parse HEAD)"
ws="$(cd .. && pwd -P)"
a="$ws/.reprobuild-repro-check-a-$$"
b="$ws/.reprobuild-repro-check-bb-$$"
cleanup() {
  git worktree remove --force "$a" 2>/dev/null || true
  git worktree remove --force "$b" 2>/dev/null || true
}
trap cleanup EXIT
git worktree add -q --detach "$a" "$rev"
git worktree add -q --detach "$b" "$rev"
for w in "$a" "$b"; do
  (cd "$w" && bash scripts/build_addon_static.sh "$arch" >/dev/null)
done
da="$(cut -d' ' -f1 "$a/build/addon/$arch/repro.sha256")"
db="$(cut -d' ' -f1 "$b/build/addon/$arch/repro.sha256")"
if ! cmp -s "$a/build/addon/$arch/repro" "$b/build/addon/$arch/repro"; then
  echo "check_addon_static_reproducible: $rev $arch differs by path:" >&2
  echo "  $a: $da" >&2
  echo "  $b: $db" >&2
  echo "  $(cmp -l "$a/build/addon/$arch/repro" "$b/build/addon/$arch/repro" | wc -l) bytes differ" >&2
  exit 1
fi
echo "check_addon_static_reproducible: $rev $arch identical at two paths: $da"
