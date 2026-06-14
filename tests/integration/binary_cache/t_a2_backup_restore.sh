#!/usr/bin/env bash
# t_a2_backup_restore.sh — A2 integration gate.
#
# Publish entries E + F. Simulate the rsync-mirror by snapshotting
# the daemon's state-dir to a side path. Tear down the daemon AND
# delete the state-dir. "Restore from backup" by copying the
# snapshot back into a fresh state-dir + bringing up a new daemon
# against it. Verify entries E + F are retrievable AND their
# signatures still verify (the producer key was preserved in the
# snapshot).
#
# The campaign spec calls for the same flow against a real
# `repro-cache` distro:
#   wsl --unregister repro-cache -> restore-from-backup.ps1 -> retrieve.
# The in-process bash test exercises the same on-disk layout that
# the rsync helper script targets; the WSL path is documented in
# recipes/cache/README.md § "Recovery".

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

trap a2_stop_server EXIT
a2_start_server

# Publish E + F.
payloadE="entry-E-bytes-$$"
payloadF="entry-F-bytes-$$"
entryE="$(a2_publish_entry "backupE" "1.0.0" "$payloadE")"
entryF="$(a2_publish_entry "backupF" "1.0.0" "$payloadF")"

# Snapshot. We use cp -a (preserving hardlinks + xattrs) to
# emulate the rsync --link-dest path.
snapshotDir="$A2_ROOT/snapshot"
mkdir -p "$snapshotDir"
for sub in manifests store index trust; do
  if [[ ! -d "$A2_ROOT/$sub" ]]; then
    a2_fail "expected daemon state subdir $A2_ROOT/$sub missing before snapshot"
  fi
  cp -a "$A2_ROOT/$sub" "$snapshotDir/$sub"
done

# Tear down + wipe state-dir.
kill "$A2_PID"
wait "$A2_PID" 2>/dev/null || true
oldRoot="$A2_ROOT"
oldPort="$A2_PORT"
oldBase="$A2_BASE_URL"
# Move the snapshot subdir SIBLING to A2_ROOT so deleting A2_ROOT's
# children doesn't take it down.
backup="${oldRoot%/}.bak"
mv "$oldRoot/snapshot" "$backup"
rm -rf "$oldRoot/store" "$oldRoot/manifests" "$oldRoot/index" "$oldRoot/trust"

# Restore: re-create the state-dir from the snapshot.
mkdir -p "$oldRoot"
for sub in manifests store index trust; do
  cp -a "$backup/$sub" "$oldRoot/$sub"
done

# Re-bind a fresh daemon on the same port + root.
daemon="$(a2_daemon_binary)"
"$daemon" --root="$(cygpath -w "$oldRoot" 2>/dev/null || echo "$oldRoot")" \
          --listen="127.0.0.1:$oldPort" \
          >"$oldRoot/stderr-restored.log" 2>&1 &
A2_PID=$!
for i in $(seq 1 50); do
  if curl -fsS "$oldBase/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# Retrieve E + F.
for k in "$entryE" "$entryF"; do
  if ! curl -fsS "$oldBase/manifests/$k" >"$oldRoot/restored-$k.bin"; then
    a2_fail "post-restore GET /manifests/$k failed"
  fi
done

# Verify signatures.
verify="$(a2_repo_root)/build/test-bin/a2_verify_helper.exe"
for k in "$entryE" "$entryF"; do
  out="$oldRoot/restored-$k.bin"
  if ! "$verify" --in="$(cygpath -w "$out" 2>/dev/null || echo "$out")"; then
    a2_fail "post-restore signature verify for $k FAILED"
  fi
done

a2_ok "t_a2_backup_restore: entries E + F retrievable post-restore; signatures still verify"
