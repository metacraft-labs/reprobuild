#!/usr/bin/env bash
# scripts/dev-shell.sh — `nix develop` entry point for this repository.
#
# Why this exists
# ---------------
# It used to exist for a reason that is gone. The flake declared a
# source-only input on a repository an anonymous caller cannot fetch, so
# `nix develop` failed outright on any host without a Nix-aware GitHub
# token — a class of host that includes every fresh clone by an outside
# contributor. This wrapper detected a local checkout of that repository
# and passed `--override-input` so the fetch never happened, and printed a
# diagnostic naming the cause when it could not.
#
# That input was removed: nothing read it, and the one expression that
# named it required a store path the package could not contain. Every
# input this flake declares is now fetchable by anyone, so there is nothing
# left to override and this script is a thin convenience: it is `nix
# develop` rooted at the repository, whatever directory you call it from.
#
# Keep it that way. If entering the dev shell ever needs a credential
# again, that is a change to who can build this project, not a wrapper
# detail — say so in `flake.nix` beside the input, and expect the lock gate
# under `tests/unit` to have an opinion about it first.
#
# Usage:
#   scripts/dev-shell.sh                # spawn the dev shell
#   scripts/dev-shell.sh nim --version  # run a command in the shell

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
  exec nix develop "$REPO_ROOT"
else
  exec nix develop "$REPO_ROOT" --command "$@"
fi
