#!/usr/bin/env bash
# Run the bundle container gate
# (tests/e2e/bundles/t_bundle_restores_on_a_plain_machine_without_rebuilding.nim)
# end to end: a selection bundle made on this host by the packaged repro of
# this tree, published to a local bare repository and restored in a plain
# rootless podman container, builds the selection with no producer action.
#
# Needs podman, Nix (the static tools come from cache.nixos.org) and the
# dev shell's Nim. The packaged repro is built from this tree with
# `nix build git+file://<tree>#reprobuild` (new files must be `git add`ed to
# be part of it) unless REPRO_BUNDLE_E2E_REPRO names a store path already.
# The gate FAILS when podman cannot run a container: it never passes
# without one. In the ordinary suite the test skips with this script's name.
set -euo pipefail
source "$(dirname "$0")/lib/foreign_preload.sh"
foreign_preload_guard "$@"
cd "$(dirname "$0")/.."

test=t_bundle_restores_on_a_plain_machine_without_rebuilding
src="tests/e2e/bundles/${test}.nim"
mkdir -p build/test-bin build/nimcache
bin="build/test-bin/${test}.run-$$"
(
  flock 8
  nim c --hints:off --warnings:off --nimcache:"build/nimcache/${test}" \
    --out:"build/test-bin/${test}" "$src"
  cp "build/test-bin/${test}" "$bin"
) 8>"build/nimcache/${test}.lock"
trap 'rm -f "$bin"' EXIT
# shellcheck source=scripts/lib/process_group.sh
source scripts/lib/process_group.sh
gate_rc=0
run_in_own_group env REPRO_BUNDLE_CONTAINER_GATE=1 "$bin" || gate_rc=$?
exit "$gate_rc"
