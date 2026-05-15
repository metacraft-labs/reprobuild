#!/usr/bin/env bash
set -euo pipefail

if command -v nimpretty >/dev/null 2>&1; then
  find apps libs tests -type f -name '*.nim' -print0 | xargs -0 nimpretty
fi

if command -v nixfmt >/dev/null 2>&1; then
  nixfmt flake.nix
elif command -v nixfmt-rfc-style >/dev/null 2>&1; then
  nixfmt-rfc-style flake.nix
fi
