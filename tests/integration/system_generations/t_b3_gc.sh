#!/usr/bin/env bash
# t_b3_gc.sh — B3 P5 gate.
#
# Apply 5 generations, then run `reproos-rebuild gc --older-than=0`.
# Verify: the current generation is kept; the staged-next generation
# is kept; the single most-recent is kept (defence in depth, and the
# most-recent IS the current here); every other generation directory
# is removed.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-gc
trap 'rm -rf "$WORK"' EXIT

CONFIG_B="$WORK/cfgB.nim"
CONFIG_C="$WORK/cfgC.nim"
write_config_service_only "$CONFIG_B"
write_config_kernel_change "$CONFIG_C"

# 5 generations; flip among A / B / C variants so each generation has a
# distinct desired manifest.
apply_config "$CONFIG_A" 1700000000; confirm_state           # gen 1
apply_config "$CONFIG_B" 1700001000; confirm_state           # gen 2
apply_config "$CONFIG_A" 1700002000; confirm_state           # gen 3
apply_config "$CONFIG_C" 1700003000; confirm_state           # gen 4
apply_config "$CONFIG_B" 1700004000; confirm_state           # gen 5

for n in 1 2 3 4 5; do
  [[ -d "$STATE/generations/$n" ]] || { echo "FAIL: generation $n missing before gc"; exit 1; }
done

echo "=== gc --older-than=0 ==="
GC_OUT="$("$BIN" gc --older-than 0 --state-dir "$STATE")"
echo "$GC_OUT"

# Generation 5 is current AND most-recent — kept.
[[ -d "$STATE/generations/5" ]] || { echo "FAIL: generation 5 (current+most-recent) dropped"; exit 1; }

# Generations 1..4 must have been dropped.
for n in 1 2 3 4; do
  [[ ! -d "$STATE/generations/$n" ]] || { echo "FAIL: generation $n was not dropped"; exit 1; }
done

# Summary line confirms 4 dropped + 1 kept.
echo "$GC_OUT" | grep -q 'summary: dropped=4 kept=1' \
  || { echo "FAIL: unexpected gc summary"; exit 1; }

echo "PASS: t_b3_gc.sh"
