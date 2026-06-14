#!/usr/bin/env bash
# t_b3_switch_reboot.sh — B3 P5 gate.
#
# Verifies that switching to a generation with a different kernel
# stages-for-reboot (current pointer untouched, staged-next records
# the target, GRUB default flips). A simulated post-reboot
# `reproos-rebuild confirm` then confirms the transition.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-switch-reboot
trap 'rm -rf "$WORK"' EXIT

CONFIG_C="$WORK/cfgC.nim"
write_config_kernel_change "$CONFIG_C"

echo "=== apply A -> generation 1, confirm boot ==="
apply_config "$CONFIG_A" 1700000000
confirm_state

echo "=== apply C -> generation 2 (different kernel), confirm boot ==="
apply_config "$CONFIG_C" 1700001000
confirm_state
[[ -d "$STATE/generations/2" ]] || { echo "FAIL: generation 2 missing"; exit 1; }

echo "=== switch back to generation 1 — must stage-for-reboot ==="
SWITCH_OUT="$("$BIN" switch 1 --state-dir "$STATE" --boot-dir "$BOOT" --runtime-dir "$RUN" --skip-unit-restart)"
echo "$SWITCH_OUT"
echo "$SWITCH_OUT" | grep -q 'mode:[[:space:]]*staged-for-reboot' \
  || { echo "FAIL: switch did not stage-for-reboot; saw:"; echo "$SWITCH_OUT"; exit 1; }
echo "$SWITCH_OUT" | grep -q 'reboot reason' \
  || { echo "FAIL: reboot reason not reported"; exit 1; }

# Current pointer must NOT have moved.
"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 2' \
  || { echo "FAIL: current pointer moved off generation 2 before confirm"; exit 1; }

# staged-next must reference generation 1.
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "1" ]] || { echo "FAIL: staged-next records '$STAGED', expected 1"; exit 1; }

# grub.cfg's default must now point at generation 1.
GRUB_CFG="$BOOT/grub/grub.cfg"
[[ -f "$GRUB_CFG" ]] || { echo "FAIL: grub.cfg missing after switch"; exit 1; }
grep -q 'set default="reproos-gen-1"' "$GRUB_CFG" \
  || { echo "FAIL: grub.cfg default not flipped to gen 1"; cat "$GRUB_CFG"; exit 1; }

echo "=== simulate reboot: confirm the staged generation ==="
confirm_state
"$BIN" list --state-dir "$STATE" | grep -E '^[[:space:]]*\*[[:space:]]+generation 1' \
  || { echo "FAIL: confirm did not promote staged generation 1 to current"; exit 1; }

echo "PASS: t_b3_switch_reboot.sh"
