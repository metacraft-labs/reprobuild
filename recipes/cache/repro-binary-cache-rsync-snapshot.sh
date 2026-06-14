#!/usr/bin/env bash
# ReproOS-Generations-And-Foreign-Packages A2 — rsync mirror helper.
#
# Invoked by `repro-binary-cache-rsync.service` every 5 minutes via
# the matching .timer unit. Mirrors the live state under
# `/var/lib/repro-binary-cache/{store,manifests,index}/` into a dated
# subdir under `/mnt/d/metacraft/repro-binary-cache-backup/`, using
# `rsync --link-dest` to hardlink unchanged files against the
# previous snapshot. Then rotates: keeps the last 7 daily snapshots
# (one per day, take-the-latest-of-day semantics — the 5-minute
# fire-rate within a day overwrites the day's slot via `mv -T`).
#
# Idempotent: a second invocation against the same minute does a
# trivial rsync (no bytes change) and the rotate step is a no-op.

set -euo pipefail

SRC=/var/lib/repro-binary-cache
DST_ROOT=/mnt/d/metacraft/repro-binary-cache-backup
LATEST="$DST_ROOT/latest"
TODAY=$(date +%Y-%m-%d)
TODAY_DIR="$DST_ROOT/$TODAY"
STAGE_DIR="$DST_ROOT/.staging-$$"

mkdir -p "$DST_ROOT"

# Decide the --link-dest reference: the symlink "latest" if it
# resolves to a prior snapshot directory.
LINK_ARGS=()
if [[ -L "$LATEST" ]] && [[ -d "$(readlink -f "$LATEST")" ]]; then
  LINK_ARGS=(--link-dest="$(readlink -f "$LATEST")")
fi

# Stage into a tmp dir; only rename on success so a partial rsync
# never overwrites today's snapshot.
mkdir -p "$STAGE_DIR"
rsync -a --delete "${LINK_ARGS[@]}" \
  "$SRC/store/" "$SRC/manifests/" "$SRC/index/" \
  "$STAGE_DIR/" 2>/dev/null || true

# Pick up the three named subtrees explicitly so the destination
# layout mirrors the source layout (rsync of multiple sources flattens
# unless we mirror with explicit subdirs):
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/store" "$STAGE_DIR/manifests" "$STAGE_DIR/index"
rsync -a --delete "${LINK_ARGS[@]/${LATEST}/${LATEST}/store}" \
  "$SRC/store/"     "$STAGE_DIR/store/"
rsync -a --delete "${LINK_ARGS[@]/${LATEST}/${LATEST}/manifests}" \
  "$SRC/manifests/" "$STAGE_DIR/manifests/"
rsync -a --delete "${LINK_ARGS[@]/${LATEST}/${LATEST}/index}" \
  "$SRC/index/"     "$STAGE_DIR/index/"

# Atomic-rename into today's slot.
mv -T "$STAGE_DIR" "$TODAY_DIR.new"
rm -rf "$TODAY_DIR"
mv -T "$TODAY_DIR.new" "$TODAY_DIR"

# Refresh the latest symlink.
ln -sfn "$TODAY_DIR" "$LATEST"

# Rotation: keep the last 7 daily snapshots; nuke older ones.
cd "$DST_ROOT"
ls -1dt 20*-*-* 2>/dev/null | tail -n +8 | xargs -r rm -rf

echo "[repro-binary-cache-rsync-snapshot] OK $TODAY_DIR"
