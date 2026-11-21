#!/usr/bin/env bash
# The commit-time `just lint`, run inside this repository's dev shell.
#
# `.pre-commit-config.yaml` runs this on every commit. The lint's verdict
# depends on its tools (nim, python3, actionlint, shellcheck, just itself), so
# they must come from the shell `flake.nix` pins, never from whatever PATH the
# contributor commits from: the same tree would otherwise pass in one terminal
# and fail in another.
#
# The shell is entered from `scripts/`, not from the top level. Entered from
# the top level, the shell hook installs the git hooks and runs `repro hooks
# ensure` (guarded by scripts/is_reprobuild_checkout.sh); a commit must not
# rewrite the hooks that are running it. Everything else about the shell is
# the same from a subdirectory: the sibling-checkout rebinding keys on `git
# rev-parse --show-toplevel`, which a subdirectory answers identically. `just`
# runs the recipe in the Justfile's directory, so the lint sees the whole tree.
#
# pre-commit stashes unstaged changes before running hooks, so the tree this
# lints is the tree being committed.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/scripts"
exec nix develop "$repo_root" --no-write-lock-file --command \
	just --justfile "$repo_root/Justfile" lint
