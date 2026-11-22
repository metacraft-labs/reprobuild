#!/usr/bin/env bash
# The dev shell's "hooks ensure failed" warning names the command it ran, and
# the command runs unchanged when pasted: the binary is the one the hook ran
# (the in-tree build/bin/repro) and the checkout path is one shell word even
# when it contains a space. No mocks beyond a stub `repro` that exits 1, which
# stands in for a failing `hooks ensure`; the script under test is the real one
# the flake's shellHook runs.
#
#   bash tests/test_dev_shell_hooks_warning_names_the_command_it_ran.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

CHECKOUT="$SCRATCH/my checkout"
mkdir -p "$CHECKOUT/build/bin"
printf '#!/bin/sh\nexit 1\n' >"$CHECKOUT/build/bin/repro"
chmod +x "$CHECKOUT/build/bin/repro"

warning="$(bash "$REPO/scripts/assert-managed-hooks.sh" "$CHECKOUT" 2>&1 >/dev/null)"
[ -n "$warning" ] || fail "no warning printed for a failing hooks ensure"
cmd="${warning#*\'}"
cmd="${cmd%%\'*}"

# Split the way a shell does and print one word per line.
words="$(eval "printf '%s\n' $cmd")"
[ "$(printf '%s\n' "$words" | wc -l)" -eq 5 ] || fail "expected 5 words, got: $words"
[ "$(printf '%s\n' "$words" | sed -n 1p)" = "$CHECKOUT/build/bin/repro" ] || fail "first word is not the binary the hook ran: $words"
[ "$(printf '%s\n' "$words" | sed -n 5p)" = "$CHECKOUT" ] || fail "checkout path is not one word: $words"

# Positive control: a succeeding binary prints nothing.
printf '#!/bin/sh\nexit 0\n' >"$CHECKOUT/build/bin/repro"
[ -z "$(bash "$REPO/scripts/assert-managed-hooks.sh" "$CHECKOUT" 2>&1)" ] || fail "warned although hooks ensure succeeded"
echo OK
