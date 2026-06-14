#!/usr/bin/env bash
# t_b3_concurrent_apply_lock.sh — B3 P5 gate.
#
# Spawns two concurrent `reproos-rebuild apply` invocations and
# verifies that exactly one succeeds while the other reports the
# apply-lock-held error (exit code 0 from the lock holder; non-zero +
# "apply lock held" diagnostic from the contender; or both succeed
# sequentially if the OS scheduler serialises them inside the 30 s
# timeout).
#
# The test takes a manual lock first to force a deterministic
# contention path: it acquires the OS-level lock via a long-running
# helper before launching the apply, then releases the helper after
# the apply has returned.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_b3_common.sh"

make_workspace b3-concurrent-lock
trap '[[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null; eval "${HOLDER_TRAP_CLEANUP:-:}"; rm -rf "$WORK"' EXIT

# Build a tiny Nim helper that acquires the system apply lock and
# sleeps until killed. We use this so the contention is deterministic
# (no scheduler races against a second `apply` invocation).
#
# The helper MUST be compiled from within $REPRO_ROOT so the repo's
# config.nims --path entries (which register the
# libs/repro_system_apply/src directory) are picked up.
HOLDER_BASENAME="reproos_b3_holder_$$"
HOLDER_NIM_REL="$REPRO_ROOT/$HOLDER_BASENAME.nim"
HOLDER_OUT_BIN_REL="$REPRO_ROOT/$HOLDER_BASENAME"
cat > "$HOLDER_NIM_REL" <<'EOF'
import std/[os]
import repro_system_apply

let stateDir = paramStr(1)
var lock = acquireApplyLock(stateDir, timeoutSeconds = 5)
# Signal readiness to the parent shell on stdout.
echo "lock-acquired"
flushFile(stdout)
# Sleep until SIGTERM/CTRL_BREAK.
while true:
  sleep(500)
EOF

(cd "$REPRO_ROOT" && nim c --hints:off --warnings:off "$HOLDER_NIM_REL" >/dev/null)
HOLDER_BIN="$HOLDER_OUT_BIN_REL"
case "$(uname -s)" in
  CYGWIN*|MINGW*|MSYS*) HOLDER_BIN="$HOLDER_BIN.exe" ;;
esac
[[ -x "$HOLDER_BIN" ]] || { echo "FAIL: holder helper not built at $HOLDER_BIN"; exit 1; }

# Clean up the in-repo .nim/.exe on exit alongside the workspace.
HOLDER_TRAP_CLEANUP="rm -f '$HOLDER_NIM_REL' '$HOLDER_OUT_BIN_REL'.exe '$HOLDER_OUT_BIN_REL' 2>/dev/null"

# Pre-create state-dir before the holder runs.
mkdir -p "$STATE/locks"

echo "=== launch the lock holder ==="
HOLDER_OUT="$WORK/holder.out"
"$HOLDER_BIN" "$STATE" > "$HOLDER_OUT" 2>&1 &
HOLDER_PID=$!

# Wait for the holder to signal readiness.
for _ in $(seq 1 100); do
  if grep -q 'lock-acquired' "$HOLDER_OUT" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
grep -q 'lock-acquired' "$HOLDER_OUT" \
  || { echo "FAIL: lock holder never signalled readiness"; cat "$HOLDER_OUT"; exit 1; }

echo "=== launch a concurrent apply — must fail with ESystemApplyBusy ==="
APPLY_OUT="$WORK/apply.out"
set +e
"$BIN" apply \
  --config "$CONFIG_A" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700000000 \
  --yes > "$APPLY_OUT" 2>&1
APPLY_RC=$?
set -e
echo "apply rc=$APPLY_RC"
cat "$APPLY_OUT"

# Expect non-zero exit AND the lock diagnostic.
[[ "$APPLY_RC" != "0" ]] || { echo "FAIL: contending apply succeeded under held lock"; exit 1; }
grep -q 'apply lock held' "$APPLY_OUT" \
  || { echo "FAIL: contending apply did not report 'apply lock held'"; exit 1; }

# Kill the holder; the next apply must succeed.
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""

echo "=== now apply succeeds ==="
"$BIN" apply \
  --config "$CONFIG_A" \
  --state-dir "$STATE" \
  --boot-dir "$BOOT" \
  --runtime-dir "$RUN" \
  --activation-ts 1700000500 \
  --yes
[[ -f "$STATE/generations/1/manifest.txt" ]] \
  || { echo "FAIL: post-release apply did not record generation 1"; exit 1; }

echo "PASS: t_b3_concurrent_apply_lock.sh"
