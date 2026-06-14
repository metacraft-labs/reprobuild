#!/usr/bin/env bash
# t_b3_boot_failure_auto_rollback.sh — B3 P5 gate.
#
# Simulates a broken generation that never reaches multi-user.target.
# The watchdog primitive (invoked by the reproos-boot-once-watchdog
# systemd unit on a real host) must:
#
#   1. Clear <state>/staged-next so the next reboot reads the
#      previously-confirmed generation.
#   2. Rewrite grub.cfg so the default entry points at the previous
#      generation.
#
# A real boot test is out of scope (vm-harness covers that in Phase D).
# This gate verifies the on-disk side of the auto-rollback contract.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-auto-rollback
trap 'rm -rf "$WORK"' EXIT

CFG_B="$WORK/cfgB.nim"; write_config_service_only "$CFG_B"

apply_config "$CONFIG_A" 1700000000
confirm_state
apply_config "$CFG_B" 1700001000
# Deliberately do NOT confirm — generation 2 is staged-for-boot.

# Pre-conditions: staged-next == 2; current == 1; grub default == 2.
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "2" ]] || { echo "FAIL: staged-next != 2 after second apply"; exit 1; }

GRUB_CFG="$BOOT/grub/grub.cfg"
grep -q 'set default="reproos-gen-2"' "$GRUB_CFG" \
  || { echo "FAIL: grub default not gen 2 before watchdog"; exit 1; }

"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 1' \
  || { echo "FAIL: current pointer moved off gen 1 before watchdog"; exit 1; }

echo "=== invoke watchdog (simulating boot failure of gen 2) ==="
WD_OUT="$("$BIN" watchdog --state-dir "$STATE" --boot-dir "$BOOT" --deadline 60)"
echo "$WD_OUT"
echo "$WD_OUT" | grep -q 'watchdog triggered' \
  || { echo "FAIL: watchdog did not trigger"; exit 1; }
echo "$WD_OUT" | grep -q 'from generation: 2' \
  || { echo "FAIL: watchdog from-generation not 2"; exit 1; }
echo "$WD_OUT" | grep -q 'to generation:   1' \
  || { echo "FAIL: watchdog to-generation not 1"; exit 1; }

# Post-conditions:
#   * staged-next removed
#   * current pointer still on gen 1 (will stay there after the
#     simulated reboot since the GRUB default flipped back)
#   * grub default flipped back to gen 1
[[ ! -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next not cleared"; exit 1; }
"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 1' \
  || { echo "FAIL: current moved off gen 1"; exit 1; }
grep -q 'set default="reproos-gen-1"' "$GRUB_CFG" \
  || { echo "FAIL: grub default not rolled back to gen 1"; cat "$GRUB_CFG"; exit 1; }

echo "PASS: t_b3_boot_failure_auto_rollback.sh"
