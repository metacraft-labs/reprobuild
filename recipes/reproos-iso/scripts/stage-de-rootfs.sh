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
mkdir -p "$STAGE_DIR/usr/share/wayland-sessions"

cat > "$STAGE_DIR/usr/share/wayland-sessions/sway.desktop" <<EOF
[Desktop Entry]
Name=Sway
Comment=An i3-compatible Wayland compositor
Exec=/usr/bin/sway
Type=Application
DesktopNames=sway
EOF

cat > "$STAGE_DIR/usr/share/wayland-sessions/plasma.desktop" <<EOF
[Desktop Entry]
Name=Plasma (Wayland)
Comment=Plasma by KDE
Exec=/usr/bin/startplasma-wayland
TryExec=/usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

cat > "$STAGE_DIR/usr/share/wayland-sessions/gnome.desktop" <<EOF
[Desktop Entry]
Name=GNOME
Comment=This session logs you into GNOME (Wayland)
Exec=/usr/bin/gnome-session
Type=Application
DesktopNames=GNOME
EOF

# M9.R.18.14 -- ReproOS Installer session. SDDM autologin (M9.R.18.1)
# routes to this session once the installer binary lands in the base
# rootfs. The launcher script starts a minimal Wayland compositor
# (sway in kiosk mode per ReproOS-Installer-PRD.md §7.5) and execs
# the wizard binary.
cat > "$STAGE_DIR/usr/share/wayland-sessions/reproos-installer.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ReproOS Installer
Comment=First-boot ReproOS installer wizard (kiosk mode)
Exec=/usr/bin/reproos-installer-launcher
DesktopNames=reproos-installer
EOF

# Companion launcher script -- starts sway in kiosk mode and execs the
# installer binary. If the binary is missing (pre-M9.R.18.14 ISO), the
# script falls through to a plain plasma session so the boot smoke still
# reaches a desktop.
mkdir -p "$STAGE_DIR/usr/bin"
cat > "$STAGE_DIR/usr/bin/reproos-installer-launcher" <<'EOF'
#!/bin/sh
# ReproOS Installer kiosk launcher.
#
# Per ReproOS-Installer-PRD.md §7.5, starts a minimal Wayland
# compositor (sway in kiosk mode) and execs the wizard full-screen.
# Closing the wizard logs the session out and returns to sddm.

INSTALLER_BIN=/usr/bin/reproos-installer
if [ ! -x "$INSTALLER_BIN" ]; then
  exec /usr/bin/startplasma-wayland
fi

# Drop a minimal sway config that launches the installer full-screen
# without a status bar or output decorations. Forces QT_QPA_PLATFORM
# to wayland so the wizard binds to sway's compositor directly; sets
# QT_QUICK_CONTROLS_STYLE to Material so the QML uses the dark token
# theme even when the system style file is absent.
SWAY_CFG=$(mktemp -t reproos-installer-sway-XXXXXX.cfg)
cat > "$SWAY_CFG" <<SWAY
output * background #0a0a0a solid_color
exec "QT_QPA_PLATFORM=wayland QT_QUICK_CONTROLS_STYLE=Material $INSTALLER_BIN; swaymsg exit"
default_border none
font pango:Sans 11
SWAY

exec /usr/bin/sway -c "$SWAY_CFG"
EOF
chmod +x "$STAGE_DIR/usr/bin/reproos-installer-launcher"

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

# M9.R.18.1 -- SDDM autologin config for the live ISO. Closes the
# boot-to-desktop round-trip: SDDM appears (proved by M9.R.17c.6) but
# without autologin the user has to type a password the live-rootfs
# doesn't prompt them about. The live-rootfs's `live` user has its
# password cleared in build-base-rootfs.sh; autologin sidesteps the
# prompt entirely.
#
# Per ReproOS-Installer-PRD.md §7.5 the live ISO autologs into the
# custom installer session (reproos-installer.desktop). M9.R.19.4
# flipped this default now that the installer binary is mandatory in
# the live ISO (M9.R.19.3 -- the engine-driven build artifact at
# apps/reproos-installer/.repro/output/install/usr/bin is enforced
# above; this script bails with exit 66 if it's missing).
#
# Session choice is env-gated for opt-out:
#   REPRO_AUTOLOGIN_SESSION=reproos-installer (default, M9.R.19.4)
#   REPRO_AUTOLOGIN_SESSION=plasma            (opt-out for DE smoke)
REPRO_AUTOLOGIN_SESSION="${REPRO_AUTOLOGIN_SESSION:-reproos-installer}"
mkdir -p "$STAGE_DIR/etc/sddm.conf.d"
cat > "$STAGE_DIR/etc/sddm.conf.d/00-autologin.conf" <<EOF
[Autologin]
User=live
Session=${REPRO_AUTOLOGIN_SESSION}
Relogin=true

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
EOF

# M9.R.19.3 -- ReproOS Installer binary integration (engine-driven).
#
# The reproos-installer recipe at apps/reproos-installer/ builds the
# wizard binary via the c_cpp_cmake convention and stages it at
#   apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer
# The reproos-iso recipe lists reproos-installer as a buildDep so the
# engine guarantees the binary exists before this script runs.
#
# The binary is MANDATORY in the live ISO: the SDDM autologin session
# (M9.R.18.1) targets reproos-installer.desktop which execs the wizard
# via reproos-installer-launcher. Without the binary, the launcher
# falls through to startplasma-wayland but the autologin session
# advertised at /usr/share/wayland-sessions/reproos-installer.desktop
# would still be misleading. Fail hard if the binary is missing.
#
# A REPROOS_INSTALLER_BIN override is still honoured for ad-hoc smoke
# runs (boot the ISO against a binary built standalone via the
# apps/reproos-installer/CMakeLists.txt + nix-shell -p qt6.qtbase ...);
# the override path takes precedence over the engine-built artifact.
REPROOS_INSTALLER_BIN="${REPROOS_INSTALLER_BIN:-}"
if [ -z "$REPROOS_INSTALLER_BIN" ]; then
  REPROOS_INSTALLER_BIN="$REPO_ROOT/apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer"
fi
if [ ! -x "$REPROOS_INSTALLER_BIN" ]; then
  echo "[stage-de-rootfs] reproos-installer binary missing or not executable at $REPROOS_INSTALLER_BIN" >&2
  echo "[stage-de-rootfs] build the recipe first: \`repro build apps/reproos-installer --tool-provisioning=from-source\`" >&2
  exit 66
fi
mkdir -p "$STAGE_DIR/usr/bin"
cp "$REPROOS_INSTALLER_BIN" "$STAGE_DIR/usr/bin/reproos-installer"
chmod +x "$STAGE_DIR/usr/bin/reproos-installer"
echo "[stage-de-rootfs] overlayed reproos-installer binary (bytes=$(stat -c %s "$STAGE_DIR/usr/bin/reproos-installer"))"

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

# M9.R.19.4 -- patchelf-rewrite RPATH/RUNPATH on every from-source
# binary in the staged tree. The from-source recipes' cmake/meson
# builds bake the BUILD HOST's
#   /opt/repro/reprobuild/recipes/packages/source/<pkg>/.repro/output/install/usr/lib*
# paths into each ELF's DT_RUNPATH. Those paths DO NOT EXIST in the
# live ISO -- /opt/repro/reprobuild/ is a build-host fiction. The
# Debian-trixie base userspace ships shared libs at
# /usr/lib/x86_64-linux-gnu/ and our DE rootfs union copies the
# from-source libs ALSO into /usr/lib/ (via the cp -rL above), so the
# loader can find every dep at the standard search path -- but ONLY
# IF we strip the bogus RUNPATH so the loader doesn't reject the
# missing /opt/repro/... entries.
#
# Without this step, sway's libdrm + libgobject-2.0 + libpixman-1 are
# "not found" at runtime because the loader honours the DT_RUNPATH
# token list strictly: every directory in the list is searched, and a
# missing directory aborts the search. Same trip for the
# reproos-installer Qt6 binary.
#
# Strategy: set RUNPATH to an empty string (let the dynamic loader
# fall back to /etc/ld.so.cache + LD_LIBRARY_PATH + standard search
# paths). This is a destructive in-place edit -- safe because the
# staged tree is a private copy of the install mirrors, not the
# canonical artifact cache.
patchelf_bin="$(command -v patchelf || true)"
if [ -z "$patchelf_bin" ]; then
  echo "[stage-de-rootfs] patchelf not in PATH; skipping RPATH cleanup -- the live ISO's from-source binaries WILL NOT find their .so deps" >&2
else
  patched=0
  while IFS= read -r elf; do
    # Only ELFs with a non-empty RUNPATH/RPATH that we built.
    rp="$($patchelf_bin --print-rpath "$elf" 2>/dev/null || true)"
    if echo "$rp" | grep -q "/opt/repro/reprobuild/"; then
      $patchelf_bin --remove-rpath "$elf" 2>/dev/null || continue
      patched=$((patched + 1))
    fi
  done < <(find "$STAGE_DIR/usr/bin" "$STAGE_DIR/usr/lib" "$STAGE_DIR/usr/lib64" \
                "$STAGE_DIR/usr/libexec" \
              -type f \( -name '*.so*' -o -perm -u+x \) 2>/dev/null)
  echo "[stage-de-rootfs] patchelf cleaned RPATH on $patched from-source ELFs"
fi

echo "[stage-de-rootfs] stage-dir bytes=$(du -sb "$STAGE_DIR" | awk '{print $1}')"
