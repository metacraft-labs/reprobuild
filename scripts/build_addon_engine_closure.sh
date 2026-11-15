#!/usr/bin/env bash
# Build the full engine (the Nix package `reprobuild`) from this checkout's
# committed revision and print its store path: the closure an add-on VM
# gate installs in its guests (REPRO_ADDON_ENGINE_CLOSURE).
#
#   scripts/build_addon_engine_closure.sh [--mutation NAME]
#
# With --mutation, the package is built with REPRO_ADDON_MUTATION=NAME
# (scripts/build_apps.sh compiles it in as -d:reproAddonMutation=NAME): the
# engine of a gate's falsifying run, e.g. `arch-realisation-accepts-deb-closure`
# for e2e_arch_addon_apt_closure_refused.
#
# WHY A GIT FLAKE REFERENCE. The package stamps the revision it was built
# from (REPROBUILD_SOURCE_REVISION, from the flake's `self.rev`) into the
# engine, and the gates check that the engine reports the revision they run
# at. A path reference (`builtins.getFlake (toString ./.)`) carries no
# revision, so its engine reports none and the gate refuses it. This script
# therefore refers to the checkout as `git+file://<repository>?rev=<HEAD>`,
# and refuses to run on a tree with uncommitted changes to tracked files:
# their build would not be the revision it names.
#
# The repository is the one the checkout's objects live in (`git
# rev-parse --git-common-dir`), so a linked worktree builds its own commit
# too.
set -euo pipefail

mutation=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutation) mutation="${2:?--mutation needs a name}"; shift 2 ;;
    --mutation=*) mutation="${1#--mutation=}"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "build_addon_engine_closure.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$mutation" in
  *[!A-Za-z0-9-]*) echo "build_addon_engine_closure.sh: invalid mutation name: $mutation" >&2; exit 2 ;;
esac

root="$(git rev-parse --show-toplevel)"
cd "$root"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "build_addon_engine_closure.sh: the checkout has uncommitted changes to" \
    "tracked files; commit them first (the engine is built from HEAD)" >&2
  exit 1
fi
rev="$(git rev-parse HEAD)"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
repo="${common%/.git}"
if [ "$repo" = "$common" ]; then
  repo="$common" # a bare repository: the git directory is the repository
fi
flake="git+file://${repo}?rev=${rev}"

if [ -z "$mutation" ]; then
  nix build --no-link --print-out-paths "${flake}#reprobuild"
else
  nix build --no-link --print-out-paths --impure --expr \
    "((builtins.getFlake \"${flake}\").packages.\${builtins.currentSystem}.reprobuild).overrideAttrs (_: { REPRO_ADDON_MUTATION = \"${mutation}\"; })"
fi
