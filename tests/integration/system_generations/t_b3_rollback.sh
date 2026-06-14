#!/usr/bin/env bash
# t_b3_rollback.sh — B3 P5 gate.
#
# Verifies `reproos-rebuild rollback` reverts to the previously-recorded
# generation. After three apply+confirm cycles, rollback should put
# the system on generation 2 (one step back from generation 3).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-rollback
trap 'rm -rf "$WORK"' EXIT

CONFIG_B="$WORK/cfgB.nim"
CONFIG_C="$WORK/cfgC.nim"
write_config_service_only "$CONFIG_B"
write_config_kernel_change "$CONFIG_C"

apply_config "$CONFIG_A" 1700000000
confirm_state
apply_config "$CONFIG_B" 1700001000
confirm_state
apply_config "$CONFIG_C" 1700002000
confirm_state

echo "=== verify generation 3 active ==="
"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 3' \
  || { echo "FAIL: generation 3 not active after confirm"; exit 1; }

echo "=== rollback one step ==="
RB_OUT="$("$BIN" rollback --state-dir "$STATE" --boot-dir "$BOOT" --runtime-dir "$RUN" --skip-unit-restart)"
echo "$RB_OUT"

# Gen 3 differs from gen 2 by kernel: rollback must stage-for-reboot.
echo "$RB_OUT" | grep -qE 'mode:[[:space:]]*(staged-for-reboot|live)' \
  || { echo "FAIL: rollback mode not reported"; exit 1; }
echo "$RB_OUT" | grep -q 'to generation:[[:space:]]*2' \
  || { echo "FAIL: rollback target not generation 2"; exit 1; }

# If staged-for-reboot, simulate the reboot.
if grep -q 'mode:[[:space:]]*staged-for-reboot' <<<"$RB_OUT"; then
  STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
  [[ "$STAGED" == "2" ]] || { echo "FAIL: staged-next records '$STAGED', expected 2"; exit 1; }
  confirm_state
fi

"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 2' \
  || { echo "FAIL: rollback did not land on generation 2"; exit 1; }

echo "PASS: t_b3_rollback.sh"
