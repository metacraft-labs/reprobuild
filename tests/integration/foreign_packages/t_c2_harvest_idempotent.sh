#!/usr/bin/env bash
# t_c2_harvest_idempotent.sh — C2 integration gate.
#
# Re-run the harvester with identical args and verify byte-for-byte
# catalog file stability. Closes the C2 idempotency requirement
# ("re-running with same args produces bit-identical catalog files").

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

workdir="$(c2_make_workdir c2-idem)"
trap 'rm -rf "$workdir"' EXIT

c2_build_fixture "$workdir"
out1="$workdir/out1"
out2="$workdir/out2"
mkdir -p "$out1" "$out2"

c2_run_harvester "$workdir" "$out1" \
  "apt:git@debian/bookworm:20260601T000000Z" >/dev/null
c2_run_harvester "$workdir" "$out2" \
  "apt:git@debian/bookworm:20260601T000000Z" >/dev/null

# Compare every catalog byte-for-byte.
diff -r "$out1" "$out2" > "$workdir/diff.log" 2>&1 || true
if [[ -s "$workdir/diff.log" ]]; then
  cat "$workdir/diff.log" >&2
  c2_fail "two harvest runs produced different catalog bytes"
fi
c2_ok "two harvest runs produced byte-identical catalog files"

# Verify the file count is stable.
n1=$(find "$out1/apt" -maxdepth 1 -name '*.json' | wc -l)
n2=$(find "$out2/apt" -maxdepth 1 -name '*.json' | wc -l)
if [[ "$n1" -ne "$n2" ]]; then
  c2_fail "catalog file count differs: $n1 vs $n2"
fi
c2_ok "catalog file count stable: $n1"

echo "PASS: t_c2_harvest_idempotent"
