#!/usr/bin/env bash
# M21 — thin wrapper around the deterministic vendor generator
# (sync_ct_test_vendor.nim). Compiles the generator with `nim` (expected to be
# on PATH inside the repo's dev shell) and runs it.
#
# Usage:
#   tools/sync_ct_test_vendor.sh [--check] [codetracerCheckout]
#
#   --check             do not write; exit non-zero if any vendored file drifts.
#   codetracerCheckout  default: $CODETRACER_CHECKOUT, else the workspace sibling
#                       /Users/zahary/m/dev/codetracer.
#
# The generator regenerates codetracer's src/ct_test/incremental/*.nim from THIS
# repo's canonical src/repro_ct_incremental/*.nim by prepending each module's
# provenance banner and applying the marker-driven engine.nim interpreted-only
# trim. See sync_ct_test_vendor.nim for the exact transform.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/sync_ct_test_vendor.nim"

nim_bin="${NIM:-}"
if [[ -z "$nim_bin" ]]; then
  if command -v nim >/dev/null 2>&1; then
    nim_bin="nim"
  else
    echo "ERROR: 'nim' not found on PATH and \$NIM unset. Run inside the dev shell." >&2
    exit 4
  fi
fi

out="$(mktemp -d)/sync_ct_test_vendor"
trap 'rm -rf "$(dirname "$out")"' EXIT

"$nim_bin" c --hints:off --warnings:off -o:"$out" "$src" >/dev/null
exec "$out" "$@"
