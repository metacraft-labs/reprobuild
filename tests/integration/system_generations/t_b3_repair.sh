#!/usr/bin/env bash
# t_b3_repair.sh — B3 P5 gate.
#
# Verifies `reproos-rebuild repair` surfaces incomplete generation
# directories and that a subsequent apply lazily cleans them up.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-repair
trap 'rm -rf "$WORK"' EXIT

apply_config "$CONFIG_A" 1700000000
confirm_state

# Simulate a crash mid-apply: create generations/2/ with no manifest.txt
BAD="$STATE/generations/2"
mkdir -p "$BAD/boot"
echo "stub kernel" > "$BAD/boot/vmlinuz"
[[ ! -f "$BAD/manifest.txt" ]] || { echo "FAIL: incomplete dir already has manifest.txt"; exit 1; }

echo "=== repair --dry-run reports the partial dir ==="
DRY="$("$BIN" repair --state-dir "$STATE" --dry-run)"
echo "$DRY"
echo "$DRY" | grep -q 'partial-apply generation 2' \
  || { echo "FAIL: repair --dry-run did not surface generation 2"; exit 1; }
echo "$DRY" | grep -q 'summary: removed=0' \
  || { echo "FAIL: dry-run modified state"; exit 1; }
[[ -d "$BAD" ]] || { echo "FAIL: dry-run removed the dir"; exit 1; }

echo "=== repair (live) removes the partial dir ==="
REP="$("$BIN" repair --state-dir "$STATE")"
echo "$REP"
echo "$REP" | grep -q 'partial-apply generation 2' \
  || { echo "FAIL: repair did not surface generation 2"; exit 1; }
echo "$REP" | grep -q 'summary: removed=1' \
  || { echo "FAIL: repair summary unexpected"; exit 1; }
[[ ! -d "$BAD" ]] || { echo "FAIL: partial dir still on disk after repair"; exit 1; }

echo "=== a subsequent apply lazily skips half-written dirs ==="
# Re-create a half-written generation directory; the next apply
# should reap it transparently and pick generation 2 cleanly.
mkdir -p "$STATE/generations/2"
CFG_B="$WORK/cfgB.nim"; write_config_service_only "$CFG_B"
apply_config "$CFG_B" 1700001000
[[ -f "$STATE/generations/2/manifest.txt" ]] \
  || { echo "FAIL: re-apply did not produce a clean generation 2"; exit 1; }

echo "PASS: t_b3_repair.sh"
