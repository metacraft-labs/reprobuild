#!/usr/bin/env bash
# scripts/dev-shell.sh — `nix develop` entry that survives private inputs.
#
# Why
# ---
# flake.nix's `codetracer-native-recorder` input points at a private
# GitHub repo. `nix develop` against a public-only flake fetches that
# input via GitHub's `archive/<rev>.tar.gz` HTTP endpoint which returns
# 404 to unauthenticated requests. Hosts without a Nix-aware GitHub
# token (e.g. NixOS WSL distros where `gh auth setup-git` only wires
# `git`, not Nix's curl-based fetcher) cannot enter the dev shell.
#
# This wrapper detects a sibling checkout of
# `codetracer-native-recorder` and passes `--override-input` so the
# input is sourced from the local path instead of fetched from GitHub.
# If no sibling is found and the public fetch would fail, we exit
# early with a clear diagnostic rather than letting Nix's stack trace
# bury the cause.
#
# Usage:
#   scripts/dev-shell.sh                # spawn the dev shell
#   scripts/dev-shell.sh nim --version  # run a command in the shell
#   CTNR_PATH=/abs/path scripts/dev-shell.sh   # explicit sibling path
#
# Sibling-detection order:
#   1. $CTNR_PATH if set + readable
#   2. `<repo>/../codetracer-native-recorder` (the default workspace
#      layout under D:/metacraft/ or ~/projects/)
#   3. fall through to a public `github:` fetch (only works if the
#      repo is reachable anonymously, which it currently is not)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SIBLING_DEFAULT="$(cd -- "$REPO_ROOT/.." && pwd)/codetracer-native-recorder"

CTNR="${CTNR_PATH:-}"
if [[ -z "$CTNR" && -d "$SIBLING_DEFAULT/ct_interpose/src" ]]; then
  CTNR="$SIBLING_DEFAULT"
fi

OVERRIDE_ARGS=()
if [[ -n "$CTNR" ]]; then
  if [[ ! -d "$CTNR/ct_interpose/src" ]]; then
    printf 'dev-shell: CTNR path %s exists but lacks ct_interpose/src; check the checkout.\n' \
      "$CTNR" >&2
    exit 2
  fi
  OVERRIDE_ARGS=(--override-input codetracer-native-recorder "path:$CTNR")
  printf 'dev-shell: using codetracer-native-recorder override -> %s\n' "$CTNR" >&2
else
  printf 'dev-shell: no sibling codetracer-native-recorder found; relying on github fetch.\n' >&2
  printf '          if `nix develop` hangs on 404, clone the repo at %s\n' \
    "$SIBLING_DEFAULT" >&2
  printf '          (gh repo clone metacraft-labs/codetracer-native-recorder) and retry.\n' >&2
fi

if [[ $# -eq 0 ]]; then
  exec nix develop "${OVERRIDE_ARGS[@]}" "$REPO_ROOT"
else
  exec nix develop "${OVERRIDE_ARGS[@]}" "$REPO_ROOT" --command "$@"
fi
