#!/usr/bin/env bash
# M9.R.16.8 — stage the DE-rootfs union for the reproos-iso payload.
#
# Walks sibling source recipes' install-mirror trees and unions the
# load-bearing /usr/ subtrees into a single staging directory the
# reproos-iso build-iso.sh wraps in a deterministic SquashFS.
#
# Source recipes ingested:
#   * sway              -- wlroots-based standalone compositor
#   * mutter            -- GNOME Wayland compositor
#   * kwin              -- KDE Plasma's Wayland compositor
#   * sddm              -- Simple Desktop Display Manager (login screen)
#   * plasma-workspace  -- KDE Plasma's plasmashell + supporting bits
#   * gdm               -- GNOME Display Manager
#
# Output: $STAGE_DIR is populated with the union /usr tree; the
# build-iso.sh consumer then squashfses it to /live/filesystem.squashfs.
#
# Invocation (from the reproos-iso recipe directory --- engine cwd):
#   bash scripts/stage-de-rootfs.sh <stage-dir>

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <stage-dir>" >&2
  exit 64
fi
STAGE_DIR="$1"

# The engine sets cwd to the recipe dir; the repo root is two levels up.
REPO_ROOT="$(cd ../.. && pwd)"

# Source recipe install-mirror roots. Each one's
# .repro/output/install/usr/ is the canonical "/usr" we want to merge.
DE_RECIPES=(
  sway
  mutter
  kwin
  sddm
  plasma-workspace
  gdm
)

mkdir -p "$STAGE_DIR/usr"

# M9.R.17c.5 - extract a minimum base userspace (systemd + libc +
# Qt6 + GL stack + login) into the staging dir BEFORE we overlay
# the from-source DE binaries. Without this base the squashfs lacks
# /sbin/init and the live-init's switch_root has nothing to exec.
#
# Driven by build-base-rootfs.sh which pulls debian:trixie-slim,
# apt-installs the curated package list, exports the container as a
# tarball, then xz-compresses it. The tarball is cached host-side at
# $REPRO_BASE_ROOTFS_CACHE (default /var/cache/reprobuild/base-rootfs)
# so subsequent stages are near-instantaneous.
SCRIPT_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"
REPRO_BASE_ROOTFS_DISABLE="${REPRO_BASE_ROOTFS_DISABLE:-0}"
if [ "$REPRO_BASE_ROOTFS_DISABLE" != "1" ]; then
  base_tar="$STAGE_DIR/../base-rootfs.tar.xz"
  echo "[stage-de-rootfs] building base userspace"
  SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1735689600}" \
    bash "$SCRIPT_DIR_SELF/build-base-rootfs.sh" "$base_tar"
  echo "[stage-de-rootfs] extracting base userspace into $STAGE_DIR"
  tar -C "$STAGE_DIR" -xf "$base_tar"
  # Some docker exports include leading ./; tar handles both. Remove
  # the staging-time base tarball to keep STAGE_DIR clean.
  rm -f "$base_tar"
fi

# Stage /etc/wayland-sessions/ session files for SDDM/GDM to enumerate.
# Each .desktop file names the per-DE session entry point.
mkdir -p "$STAGE_DIR/etc/wayland-sessions"

cat > "$STAGE_DIR/etc/wayland-sessions/sway.desktop" <<EOF
[Desktop Entry]
Name=Sway
Comment=An i3-compatible Wayland compositor
Exec=/usr/bin/sway
Type=Application
DesktopNames=sway
EOF

cat > "$STAGE_DIR/etc/wayland-sessions/plasma.desktop" <<EOF
[Desktop Entry]
Name=Plasma (Wayland)
Comment=Plasma by KDE
Exec=/usr/bin/startplasma-wayland
TryExec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

cat > "$STAGE_DIR/etc/wayland-sessions/gnome.desktop" <<EOF
[Desktop Entry]
Name=GNOME
Comment=This session logs you into GNOME (Wayland)
Exec=/usr/bin/gnome-session
Type=Application
DesktopNames=GNOME
EOF

# M9.R.17c.4 -- enable sddm as display-manager.service. systemd starts
# the unit symlinked at /etc/systemd/system/display-manager.service on
# graphical.target. Without this symlink the booted system reaches
# multi-user.target but never spawns the login screen.
mkdir -p "$STAGE_DIR/etc/systemd/system"
# Use a path inside the staged /usr because the squashfs's /usr/lib
# becomes /usr/lib at runtime; the symlink target must be absolute and
# rooted at the live ISO's filesystem layout.
ln -sf /usr/lib/systemd/system/sddm.service \
  "$STAGE_DIR/etc/systemd/system/display-manager.service"

# Wire graphical.target as the default - the rootfs we stage has no
# init/default policy of its own.
ln -sf /usr/lib/systemd/system/graphical.target \
  "$STAGE_DIR/etc/systemd/system/default.target"

# Track which recipes contributed.
contributed=()
missing=()

for pkg in "${DE_RECIPES[@]}"; do
  install_root="$REPO_ROOT/recipes/packages/source/$pkg/.repro/output/install/usr"
  if [ ! -d "$install_root" ]; then
    missing+=("$pkg")
    continue
  fi
  # Recursive copy preserving symlinks + permissions. Use -L to
  # dereference symlinks where the source is a /nix/store path (we
  # need a self-contained rootfs; nix-store paths aren't on the live
  # ISO). Use -n so we don't overwrite when two recipes ship the same
  # file (first wins; the priority order in DE_RECIPES is intentional:
  # sway is smallest and has the fewest collisions).
  cp -rL --no-clobber "$install_root/." "$STAGE_DIR/usr/" 2>/dev/null || true
  contributed+=("$pkg")
done

echo "[stage-de-rootfs] contributed=${contributed[*]}"
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[stage-de-rootfs] missing=${missing[*]} (these recipes aren't built; their binaries WILL NOT be in the ISO)" >&2
fi
if [ "${#contributed[@]}" -eq 0 ]; then
  echo "[stage-de-rootfs] no DE recipes contributed; aborting" >&2
  exit 65
fi
echo "[stage-de-rootfs] stage-dir bytes=$(du -sb "$STAGE_DIR" | awk '{print $1}')"
