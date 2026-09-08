#!/usr/bin/env bash
# Limit repository-specific dev-shell hook installation to this project.
set -eu

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 1
[ "$(pwd -P)" = "$(cd "$root" && pwd -P)" ] || exit 1
git ls-files --error-unmatch -- \
  flake.nix repro.nim scripts/pre_commit_hook_handoff.sh \
  >/dev/null 2>&1
