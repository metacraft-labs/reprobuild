#!/usr/bin/env bash
# t_a2_5_single_user_mode.sh — ReproOS-Generations-And-Foreign-Packages
# A2.5 single-user gate.
#
# Spec § Multi-user vs single-user mode:
#
#   Same gcc-15.2.0-equivalent substitution test as the P8 throughput
#   bench, but via ``substituteInProcess`` (no daemon). Reports wall-
#   clock; documents margin vs multi-user.
#
# This is the bash entry point that the campaign spec lists as a gate.
# The actual workload is a thin Nim driver
# (``lib/a2_5_single_user_runner.nim``) that spawns the A2 server,
# substitutes a synthetic 3-member closure (the same shape the
# concurrent-clients gate uses) via ``substituteInProcess``, and
# reports wall-clock + total bytes.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

runner="$REPO_ROOT/build/test-bin/a2_5_single_user_runner.exe"
if [[ ! -f "$runner" ]]; then
  echo "a2_5 single-user runner not built. Build with:" >&2
  echo "  nim c -o:build/test-bin/a2_5_single_user_runner.exe \\" >&2
  echo "    tests/integration/binary_cache/lib/a2_5_single_user_runner.nim" >&2
  exit 1
fi

"$runner"
echo "PASS: t_a2_5_single_user_mode — substituteInProcess realized the " \
     "synthetic 3-member closure without a daemon"
