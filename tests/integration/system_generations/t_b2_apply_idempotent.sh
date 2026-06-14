#!/usr/bin/env bash
# t_b2_apply_idempotent.sh — B2 P5 integration gate.
#
# Exercises the idempotency of `reproos-rebuild apply`:
#
#   1. Apply config A -> generation 1 recorded on disk.
#   2. Apply config A AGAIN -> no transitions executed; generation
#      directory count stays at 1; `staged-next` flag stays at 1.
#
# The test uses a freshly-provisioned temp state directory so the gate
# is hermetic on every host. It also passes `--activation-ts` so the
# manifest bytes are deterministic across runs (the second apply must
# resolve to the same content-addressed desired manifest as the first).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Pick up the reproos-rebuild binary; build if missing.
BIN="$REPRO_ROOT/apps/reproos-rebuild/reproos_rebuild"
case "$(uname -s)" in
  CYGWIN*|MINGW*|MSYS*) BIN="$BIN.exe" ;;
esac
if [[ ! -x "$BIN" ]]; then
  (cd "$REPRO_ROOT" && nim c --hints:off --warnings:off \
    apps/reproos-rebuild/reproos_rebuild.nim >/dev/null)
fi
[[ -x "$BIN" ]] || { echo "FAIL: reproos-rebuild binary not built at $BIN"; exit 1; }

WORK="$(mktemp -d -t reproos-b2-idempotent.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"
BOOT="$WORK/boot"
RUN="$WORK/run"
mkdir -p "$STATE" "$BOOT" "$RUN"

CONFIG="$REPRO_ROOT/recipes/reproos-sample-config/configuration.nim"
[[ -f "$CONFIG" ]] || { echo "FAIL: sample config not at $CONFIG"; exit 1; }

echo "=== apply #1 ==="
"$BIN" apply \
  --config "$CONFIG" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700000000 \
  --yes

# Confirm generation 1 was recorded.
GEN1_DIR="$STATE/generations/1"
[[ -d "$GEN1_DIR" ]] || { echo "FAIL: generation 1 directory missing"; exit 1; }
[[ -f "$GEN1_DIR/manifest.txt" ]] || { echo "FAIL: manifest.txt missing"; exit 1; }
[[ -f "$STATE/staged-next" ]] || { echo "FAIL: staged-next flag missing"; exit 1; }
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "1" ]] || { echo "FAIL: staged-next records '$STAGED', expected 1"; exit 1; }

echo "=== apply #2 (same config) ==="
"$BIN" apply \
  --config "$CONFIG" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700000500 \
  --yes

# Generation 2 must NOT exist.
[[ ! -d "$STATE/generations/2" ]] || { echo "FAIL: generation 2 was created on idempotent apply"; exit 1; }

# staged-next should not change (still 1).
STAGED="$(cat "$STATE/staged-next" | tr -d '[:space:]')"
[[ "$STAGED" == "1" ]] || { echo "FAIL: staged-next changed from 1 to '$STAGED' on idempotent apply"; exit 1; }

# Only one generation directory should be present.
GEN_COUNT=$(ls -1 "$STATE/generations" | wc -l)
[[ "$GEN_COUNT" == "1" ]] || { echo "FAIL: expected 1 generation, found $GEN_COUNT"; exit 1; }

echo "PASS: t_b2_apply_idempotent.sh"
