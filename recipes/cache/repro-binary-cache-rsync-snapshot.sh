#!/usr/bin/env bash
# ReproOS-Generations-And-Foreign-Packages A2 — rsync mirror helper.
#
# Invoked by `repro-binary-cache-rsync.service` every 5 minutes via
# the matching .timer unit. Mirrors the live state under
# `/var/lib/repro-binary-cache/{store,manifests,index}/` into a dated
# subdir under `/mnt/d/metacraft/repro-binary-cache-backup/`.
#
# ## Why no rsync `--link-dest` on Windows mounts
#
# Earlier iterations used `--link-dest=<prev-snapshot>` to make each
# snapshot space-efficient by hardlinking unchanged files against
# the previous snapshot. On `/mnt/d/` (WSL's DrvFs Windows mount)
# rsync can't preserve owner/group/perms/times — the FS rejects
# the chgrp/utime syscalls reprocache lacks CAP_FOWNER for. That
# breaks `--link-dest`'s "compared by metadata" assumption: every
# file looks "different" because mode/owner can't be preserved,
# and we fall back to a full copy AND emit hundreds of errors.
#
# So this script uses content-only sync — `rsync -r --size-only`
# with no metadata preservation — and accepts the disk-space
# trade-off. Each daily snapshot is a full copy. The 7-day
# rotation keeps the footprint bounded. For a 50-GiB cap on the
# source we budget ~350 GiB on the backup.
#
# ## Idempotency
#
# A second invocation against the same day re-runs the rsync into
# the same target. With `--size-only` the no-op pass is cheap (one
# stat per file).

set -euo pipefail

SRC=/var/lib/repro-binary-cache
DST_ROOT=/mnt/d/metacraft/repro-binary-cache-backup
LATEST="$DST_ROOT/latest"
TODAY=$(date +%Y-%m-%d)
TODAY_DIR="$DST_ROOT/$TODAY"
STAGE_DIR="$DST_ROOT/.staging-$$"

mkdir -p "$DST_ROOT"

# rsync flags tuned for the Windows-mount target:
#   -r            recurse into subdirs
#   --delete      remove backup files that no longer exist in src
#   --size-only   skip mtime check (DrvFs can't preserve mtimes)
#   --no-owner    don't try to chown (would fail)
#   --no-group    don't try to chgrp (would fail)
#   --no-perms    don't try to chmod (would fail)
#   --no-times    don't try to set times (would fail)
#   --chmod=...   ensure the receiver writes readable files
#   --inplace     write directly to the target file (no .tmp rename
#                 dance that DrvFs sometimes refuses)
RSYNC_FLAGS=(
  -r --delete --size-only
  --no-owner --no-group --no-perms --no-times
  --chmod=ugo=rwX --inplace
)

# Stage into a tmp dir; only rename on success so a partial rsync
# never overwrites today's snapshot.
mkdir -p "$STAGE_DIR" "$STAGE_DIR/store" "$STAGE_DIR/manifests" "$STAGE_DIR/index"

rsync "${RSYNC_FLAGS[@]}" "$SRC/store/"     "$STAGE_DIR/store/"
rsync "${RSYNC_FLAGS[@]}" "$SRC/manifests/" "$STAGE_DIR/manifests/"
rsync "${RSYNC_FLAGS[@]}" "$SRC/index/"     "$STAGE_DIR/index/"

# Atomic-rename into today's slot. mv -T may not work on DrvFs;
# fall back to rm + mv.
if [[ -d "$TODAY_DIR" ]]; then
  rm -rf "$TODAY_DIR"
fi
mv "$STAGE_DIR" "$TODAY_DIR"

# Refresh the latest symlink. DrvFs may not honour POSIX symlinks
# but a plain dir-symlink works for in-WSL reads; Windows-side
# consumers walk the dated dirs directly anyway.
if [[ -L "$LATEST" ]]; then
  rm -f "$LATEST" || true
fi
ln -sfn "$TODAY_DIR" "$LATEST" 2>/dev/null || true

# Rotation: keep the last 7 daily snapshots; nuke older ones.
cd "$DST_ROOT"
ls -1dt 20*-*-* 2>/dev/null | tail -n +8 | xargs -r rm -rf

echo "[repro-binary-cache-rsync-snapshot] OK $TODAY_DIR"
