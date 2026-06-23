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

# Companion launcher script -- starts a Wayland compositor in kiosk
# mode and execs the installer binary full-screen. If the binary is
# missing (pre-M9.R.18.14 ISO), the script falls through to a plain
# plasma session so the boot smoke still reaches a desktop.
#
# M9.R.24.1c -- the launcher previously embedded the env-var prefix
# inside sway's `exec` command which sway forks via /bin/sh -c; the
# inner quote made sway treat the whole `FOO=bar cmd; swaymsg exit`
# as a single argv[0], producing a NULL fn-pointer crash at IP=0x91
# under SDDM autologin. Move every env var into the launcher itself
# and use a dedicated init script for sway's `exec` directive.
mkdir -p "$STAGE_DIR/usr/bin"
cat > "$STAGE_DIR/usr/bin/reproos-installer-launcher" <<'EOF'
#!/bin/sh
# ReproOS Installer kiosk launcher.
#
# Per ReproOS-Installer-PRD.md §7.5, starts a minimal Wayland
# compositor (sway in kiosk mode) and execs the wizard full-screen.
# Closing the wizard logs the session out and returns to sddm.

set -eu

INSTALLER_BIN=/usr/bin/reproos-installer
if [ ! -x "$INSTALLER_BIN" ]; then
  exec /usr/bin/startplasma-wayland
fi

# Env vars travel via the parent shell so sway's exec hook gets a
# clean command. The QT vars apply to the wizard fork sway spawns.
export QT_QPA_PLATFORM=wayland
export QT_QUICK_CONTROLS_STYLE=Material
# XDG_RUNTIME_DIR is needed by libwayland-client; sddm-helper sets
# this normally but kiosk wrappers run before the user session is
# fully initialised on some Debian builds. Synthesise if absent.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
fi

# Install-once init script that sway's `exec` runs as a child shell.
SWAY_INIT=$(mktemp -t reproos-installer-sway-init-XXXXXX.sh)
cat > "$SWAY_INIT" <<'INIT'
#!/bin/sh
# Sway exec hook -- runs the installer, then asks sway to exit when
# the installer process closes (either by user click or by --automated
# finish).
/usr/bin/reproos-installer "$@"
/usr/bin/swaymsg exit
INIT
chmod +x "$SWAY_INIT"

# Drop a minimal sway config that launches the installer full-screen
# without a status bar or output decorations.
SWAY_CFG=$(mktemp -t reproos-installer-sway-XXXXXX.cfg)
cat > "$SWAY_CFG" <<SWAY
output * background #0a0a0a solid_color
exec $SWAY_INIT
default_border none
font pango:Sans 11
SWAY

exec /usr/bin/sway -c "$SWAY_CFG"
EOF
chmod +x "$STAGE_DIR/usr/bin/reproos-installer-launcher"

# M9.R.17c.4 + M9.R.24.1c -- target selection.
#
# Pre-M9.R.24, the default boot target was `graphical.target` with
# SDDM as the display manager and a kiosk Wayland session running the
# reproos-installer. M9.R.24 diagnosed two cascading bugs:
#   1. SDDM execs sway via `exec /usr/bin/sway` but our from-source
#      sway recipe was missing dynamic-linker deps -> exit 127.
#   2. Even with Debian's sway in place, sway crashes at IP=0x91 in
#      the qemu virtio-gpu / SDDM-VT-handoff environment.
#
# REPRO_LIVE_TARGET selects which surface the autologin lands on:
#   - "console" (M9.R.24 default): `multi-user.target` + a getty
#       autologin that runs the installer in --automated mode if a
#       config TOML is present, else drops to an interactive shell.
#       No compositor needed; works against any vgafb-capable QEMU.
#   - "graphical": the legacy SDDM + Wayland-kiosk session
#       (M9.R.18.14). Reserved for future once the wlroots/virtio_gpu
#       trip lands; pre-M9.R.24 path retained behind the gate.
mkdir -p "$STAGE_DIR/etc/systemd/system"
REPRO_LIVE_TARGET="${REPRO_LIVE_TARGET:-console}"
case "$REPRO_LIVE_TARGET" in
  graphical)
    ln -sf /usr/lib/systemd/system/sddm.service \
      "$STAGE_DIR/etc/systemd/system/display-manager.service"
    ln -sf /usr/lib/systemd/system/graphical.target \
      "$STAGE_DIR/etc/systemd/system/default.target"
    ;;
  console)
    ln -sf /usr/lib/systemd/system/multi-user.target \
      "$STAGE_DIR/etc/systemd/system/default.target"
    ;;
  *)
    echo "[stage-de-rootfs] unknown REPRO_LIVE_TARGET=$REPRO_LIVE_TARGET" >&2
    exit 64
    ;;
esac

# Console-mode autologin override -- replaces base-rootfs's
# `agetty --autologin live tty1`. We want root (full install perms)
# autologging in and the launcher script auto-running.
mkdir -p "$STAGE_DIR/etc/systemd/system/getty@tty1.service.d"
cat > "$STAGE_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM
EOF

# Profile hook to auto-launch the installer on root login (tty1 only).
# Falls through to a normal shell if the installer is missing or the
# user types Ctrl+C during the 3-second grace period.
mkdir -p "$STAGE_DIR/etc/profile.d"
cat > "$STAGE_DIR/etc/profile.d/zz-reproos-installer-autostart.sh" <<'EOF'
# ReproOS live-ISO console-mode installer autostart.
# Triggers on tty1 only (avoids reentry when the install runs `bash`).
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${REPRO_INSTALLER_RAN:-}" ]; then
  export REPRO_INSTALLER_RAN=1
  AUTO_CFG=""
  for cand in /etc/reproos/auto-config.toml /run/reproos/auto-config.toml; do
    if [ -f "$cand" ]; then
      AUTO_CFG="$cand"
      break
    fi
  done
  if [ -x /usr/bin/reproos-installer ] && [ -n "$AUTO_CFG" ]; then
    echo ""
    echo "=== ReproOS Installer (automated) starting in 3 seconds; Ctrl+C aborts. ==="
    echo "Config: $AUTO_CFG"
    echo ""
    sleep 3
    # --automated path doesn't need a display server but QGuiApplication
    # still initialises a QPA plugin. Force `offscreen` so Qt doesn't
    # try to connect to xcb (which fails on a tty boot) and instead
    # uses the headless rasteriser.
    QT_QPA_PLATFORM=offscreen \
    LD_LIBRARY_PATH=/usr/lib:/usr/lib64:/usr/lib/x86_64-linux-gnu \
      /usr/bin/reproos-installer --automated "$AUTO_CFG"
    rc=$?
    echo ""
    echo "=== Installer exited with rc=$rc ==="
    echo "Type \`poweroff\` to shut down or \`reboot\` to boot into the installed system."
    echo ""
  elif [ -x /usr/bin/reproos-installer ]; then
    echo ""
    echo "=== ReproOS Installer console ==="
    echo "No automated config found at /etc/reproos/auto-config.toml."
    echo "Run \`reproos-installer --help\` to see options, or drop a config"
    echo "TOML at /etc/reproos/auto-config.toml and re-login to run the"
    echo "automated path."
    echo ""
  fi
fi
EOF
chmod 0644 "$STAGE_DIR/etc/profile.d/zz-reproos-installer-autostart.sh"

# Bake a default automated config for the demo run. Honours the M9.R.23
# --automated TOML shape (smoke-test-config.toml format).
mkdir -p "$STAGE_DIR/etc/reproos"
cat > "$STAGE_DIR/etc/reproos/auto-config.toml" <<'EOF'
# M9.R.24 demo -- automated ReproOS install against the QEMU
# /dev/vda virtio-blk disk. Targets the simplest disko preset so the
# end-to-end demo runs in under a minute.
hostname = "reproos-vm"
defaultUser = "alice"
password = "reproos"
diskoPreset = "simple"
targetDevice = "/dev/vda"
preferredDE = "plasma"
activities = ["daily-computing", "system-tools"]
EOF

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

# M9.R.24.1 -- Live-ISO debug tap (env-gated).
#
# When REPRO_LIVE_DEBUG=1 is set at ISO-build time, drop a systemd unit
# that journal-tails sddm + the autologin session to /dev/ttyS1. QEMU
# `-serial file:...` captures ttyS1 for post-boot analysis so we can
# see WHY SDDM never paints the framebuffer. Off by default so
# production ISOs don't leak diagnostic data to a (non-existent) ttyS1.
REPRO_LIVE_DEBUG="${REPRO_LIVE_DEBUG:-0}"
if [ "$REPRO_LIVE_DEBUG" = "1" ]; then
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cat > "$STAGE_DIR/etc/systemd/system/repro-debug-tap.service" <<'EOF'
[Unit]
Description=ReproOS live-ISO debug journal tap to /dev/ttyS1
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
# Tail the full journal (every unit + kernel) to /dev/ttyS1. -f =
# follow forever; --no-pager because there's no tty.
ExecStart=/bin/sh -c '/usr/bin/journalctl -f -o short-monotonic --no-pager > /dev/ttyS1 2>&1'
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p "$STAGE_DIR/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/repro-debug-tap.service \
    "$STAGE_DIR/etc/systemd/system/multi-user.target.wants/repro-debug-tap.service"
  echo "[stage-de-rootfs] REPRO_LIVE_DEBUG=1; tap enabled at ttyS1"
fi

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

# M9.R.24.1f -- the wizard's install() driver shells out to
# /usr/bin/repro for the 6-phase apply (hardware probe -> disk apply
# -> mount -> system apply -> unmount). Without the CLI in the live
# ISO the installer fails at Phase 1 with
#   "spawn failed: Child process set up failed: execve: No such file"
# Bake the engine-built repro binary at build/bin/repro into the
# live ISO so the installer's QProcess shell-outs resolve.
REPRO_CLI_BIN="${REPRO_CLI_BIN:-}"
if [ -z "$REPRO_CLI_BIN" ]; then
  REPRO_CLI_BIN="$REPO_ROOT/build/bin/repro"
fi
if [ ! -x "$REPRO_CLI_BIN" ]; then
  echo "[stage-de-rootfs] repro CLI binary missing or not executable at $REPRO_CLI_BIN" >&2
  echo "[stage-de-rootfs] build it first: \`just build\` or run the bootstrap script" >&2
  exit 67
fi
cp "$REPRO_CLI_BIN" "$STAGE_DIR/usr/bin/repro"
chmod +x "$STAGE_DIR/usr/bin/repro"
echo "[stage-de-rootfs] overlayed repro CLI (bytes=$(stat -c %s "$STAGE_DIR/usr/bin/repro"))"

# M9.R.24.1g.2 -- the repro CLI uses Nim's dynlib runtime which
# dlopens libraries by their *linker* name (no SONAME version) by
# default: dlopen("libsqlite3.so"). Debian's libsqlite3-0 ships only
# the SONAME form (libsqlite3.so.0); the unversioned linker name is
# in libsqlite3-dev. Symlink the SONAME -> linker name so the
# unversioned dlopen succeeds without dragging in the -dev package.
sqlite_so="$(find "$STAGE_DIR/usr/lib" "$STAGE_DIR/usr/lib64" \
              -maxdepth 4 -name 'libsqlite3.so.0' -type f -o \
              -name 'libsqlite3.so.0' -type l 2>/dev/null | head -1)"
if [ -n "$sqlite_so" ]; then
  ln -sf "$(basename "$sqlite_so")" "$(dirname "$sqlite_so")/libsqlite3.so"
  echo "[stage-de-rootfs] symlinked libsqlite3.so -> $(basename "$sqlite_so")"
fi
# Qt6 dlopens libvulkan.so (bare linker name); Debian's libvulkan1
# package only ships libvulkan.so.1.
vulkan_so="$(find "$STAGE_DIR/usr/lib" "$STAGE_DIR/usr/lib64" \
              -maxdepth 4 \( -name 'libvulkan.so.1' -type f -o \
              -name 'libvulkan.so.1' -type l \) 2>/dev/null | head -1)"
if [ -n "$vulkan_so" ]; then
  ln -sf "$(basename "$vulkan_so")" "$(dirname "$vulkan_so")/libvulkan.so"
  echo "[stage-de-rootfs] symlinked libvulkan.so -> $(basename "$vulkan_so")"
fi

# M9.R.24.1g.3 -- libclingo is the ASP solver Repro's engine action-cache
# planner dlopens at runtime. Debian doesn't package it (Potassco
# upstream releases binary tarballs but no debian/control). Lift the
# host's nix-shell libclingo into the staged tree at /usr/lib/.
# M9.R.24.2 -- Qt6 9.x bundle from the nix-shell. The reproos-installer
# is built against nix-shell Qt 6.9.x; Debian trixie ships Qt 6.8.x.
# Without the bundle, the installer aborts at startup with:
#   libQt6Core.so.6: version `Qt_6.9' not found
# Mirror the nix-store Qt6 .so files into /usr/lib so the loader picks
# them up via ld.so.cache. The bundled libs are SONAME-suffixed
# (libQt6Core.so.6.9.x); we create the symlink chain that maps the
# major-SONAME (libQt6Core.so.6) to the bundled file.
qt6_core_src="$(find /nix/store -maxdepth 4 -path '*qtbase*/lib/libQt6Core.so.6.9*' \
                -type f 2>/dev/null | head -1)"
if [ -n "$qt6_core_src" ]; then
  qt6_libdir="$(dirname "$qt6_core_src")"
  echo "[stage-de-rootfs] bundling Qt6 9.x from $qt6_libdir"
  # Put EVERY bundled Qt6 lib at /usr/lib/x86_64-linux-gnu/ so the
  # loader picks up a coherent 6.9 set rather than mixing 6.9 Core
  # with 6.8 Qml/Quick from Debian (which produces
  # "undefined symbol Qt_6_PRIVATE_API"). Force-overwrite Debian's
  # Qt6 libs (the package files; the SONAME symlinks point at the
  # bundled 6.9.x file after this step).
  qt6_dst="$STAGE_DIR/usr/lib/x86_64-linux-gnu"
  mkdir -p "$qt6_dst"
  for f in "$qt6_libdir"/libQt6*.so.6*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    cp -f "$f" "$qt6_dst/$base"
    # Strip "6.9.3" tail to "6" for the major-SONAME symlink that
    # the installer's binary actually NEEDED.
    soname6="$(echo "$base" | sed -E 's/(libQt6[^.]+)\.so\.6\.[0-9]+\.[0-9]+/\1.so.6/')"
    if [ "$soname6" != "$base" ]; then
      ln -sf "$base" "$qt6_dst/$soname6"
    fi
  done
  # Mirror the same Qt6 set into /usr/lib so cache+ldconfig finds it.
  for f in "$qt6_libdir"/libQt6*.so.6*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    cp -f "$f" "$STAGE_DIR/usr/lib/$base"
    soname6="$(echo "$base" | sed -E 's/(libQt6[^.]+)\.so\.6\.[0-9]+\.[0-9]+/\1.so.6/')"
    if [ "$soname6" != "$base" ]; then
      ln -sf "$base" "$STAGE_DIR/usr/lib/$soname6"
    fi
  done
  # Also bundle the Qt6 plugins dir (platforms/, etc) so the installer
  # can find the offscreen QPA plugin.
  qt6_pluginsdir="$qt6_libdir/qt-6/plugins"
  if [ -d "$qt6_pluginsdir" ]; then
    mkdir -p "$STAGE_DIR/usr/lib/qt6/plugins"
    cp -rL "$qt6_pluginsdir/." "$STAGE_DIR/usr/lib/qt6/plugins/" 2>/dev/null || true
  fi
  # Same for Qt6 qml/
  qt6_qmldir="$qt6_libdir/qt-6/qml"
  if [ -d "$qt6_qmldir" ]; then
    mkdir -p "$STAGE_DIR/usr/lib/qt6/qml"
    cp -rL "$qt6_qmldir/." "$STAGE_DIR/usr/lib/qt6/qml/" 2>/dev/null || true
  fi
fi

clingo_src="$(find /nix/store -maxdepth 3 -name 'libclingo.so.4*' \
              -type f 2>/dev/null | head -1)"
if [ -n "$clingo_src" ]; then
  cp "$clingo_src" "$STAGE_DIR/usr/lib/$(basename "$clingo_src")"
  ln -sf "$(basename "$clingo_src")" "$STAGE_DIR/usr/lib/libclingo.so.4"
  ln -sf "libclingo.so.4" "$STAGE_DIR/usr/lib/libclingo.so"
  echo "[stage-de-rootfs] bundled $clingo_src + linker-name symlink"

  # M9.R.24.1g.10 -- the repro CLI's clingo dynlib path is baked at
  # compile-time as the nix-store ABSOLUTE path (e.g.
  # /nix/store/07zxk485h58ab97j335174ana4xp13kh-clingo-5.8.0/lib/libclingo.so).
  # Nim's dlopen tries that path FIRST and never falls back to the
  # bare name (`libclingo.so`) if the file exists at the absolute
  # path's parent dir... actually it doesn't fall back at all because
  # the ELF's embedded path stops the search. Mirror the nix-store
  # layout inside the staged tree so the absolute path resolves.
  # Two candidate nix-store paths in eli-wsl (the binary was built
  # under one specific hash); mirror BOTH to be safe.
  for nsdir in /nix/store/07zxk485h58ab97j335174ana4xp13kh-clingo-5.8.0 \
               /nix/store/kgibywhn2k14lr2mwwx2sp08p57pdizp-clingo-5.8.0; do
    mkdir -p "$STAGE_DIR$nsdir/lib"
    ln -sf "/usr/lib/$(basename "$clingo_src")" \
      "$STAGE_DIR$nsdir/lib/$(basename "$clingo_src")"
    ln -sf "$(basename "$clingo_src")" \
      "$STAGE_DIR$nsdir/lib/libclingo.so.4"
    ln -sf "libclingo.so.4" "$STAGE_DIR$nsdir/lib/libclingo.so"
  done
  echo "[stage-de-rootfs] mirrored libclingo at nix-store absolute paths"
fi

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
  echo "[stage-de-rootfs] patchelf not in PATH; skipping RPATH/interpreter cleanup -- the live ISO's from-source binaries WILL NOT find their .so deps" >&2
else
  patched=0
  # M9.R.24.1d -- in addition to RPATH/RUNPATH, the from-source recipes
  # build under nix-shell which bakes a nix-store glibc interpreter
  # path into every ELF's PT_INTERP segment, e.g.
  #   /nix/store/<hash>-glibc-2.40/lib/ld-linux-x86-64.so.2
  # That path DOES NOT EXIST in the live ISO -- /nix/store/ is a
  # build-host fiction. `bash` reports "cannot execute: required file
  # not found" the moment it tries to exec the binary because the
  # kernel loader can't find the interpreter named in PT_INTERP.
  # Fix: rewrite PT_INTERP to the staged Debian glibc ld-linux path.
  STAGE_LDLINUX=/lib64/ld-linux-x86-64.so.2
  interp_patched=0
  while IFS= read -r elf; do
    # RPATH/RUNPATH cleanup -- strip any bake-time RUNPATH that points
    # outside the live ISO's filesystem. The loader honours RUNPATH
    # strictly: a single missing directory aborts the search (the
    # dynamic linker checks each entry, and ENOENT on one terminates
    # resolution). Targets BOTH /opt/repro/reprobuild/ (from-source
    # recipes' install-mirror) and /nix/store/ (nix-shell glibc/gcc-
    # lib RUNPATHs baked into libclingo and Qt6 libs).
    rp="$($patchelf_bin --print-rpath "$elf" 2>/dev/null || true)"
    if echo "$rp" | grep -qE "/opt/repro/reprobuild/|/nix/store/"; then
      $patchelf_bin --remove-rpath "$elf" 2>/dev/null || true
      patched=$((patched + 1))
    fi
    # Interpreter cleanup -- only ELFs that have a PT_INTERP segment
    # (executables, not shared libs).
    interp="$($patchelf_bin --print-interpreter "$elf" 2>/dev/null || true)"
    if echo "$interp" | grep -q "^/nix/store/"; then
      $patchelf_bin --set-interpreter "$STAGE_LDLINUX" "$elf" 2>/dev/null || true
      interp_patched=$((interp_patched + 1))
    fi
  done < <(find "$STAGE_DIR/usr/bin" "$STAGE_DIR/usr/lib" "$STAGE_DIR/usr/lib64" \
                "$STAGE_DIR/usr/libexec" \
              -type f \( -name '*.so*' -o -perm -u+x \) 2>/dev/null)
  echo "[stage-de-rootfs] patchelf cleaned RPATH on $patched from-source ELFs"
  echo "[stage-de-rootfs] patchelf rewrote PT_INTERP on $interp_patched nix-store-built ELFs"
fi

# M9.R.24.1g.4 -- rebuild ld.so.cache so the unioned /usr/lib libs
# (libclingo, the from-source overlays, the symlinked libsqlite3.so)
# are discoverable by dlopen() at runtime. Without this the live-init
# does NOT regenerate the cache; libclingo isn't found because the
# stock Debian cache only knows /usr/lib/x86_64-linux-gnu/.
# Use the staged Debian glibc /sbin/ldconfig inside a chroot so the
# cache writes resolve naturally against $STAGE_DIR. The nix-shell
# host glibc-bin ldconfig's -r doesn't redirect the cache temp file
# correctly and falls over creating ld.so.cache~ on a read-only path.
chroot_ldconfig="$STAGE_DIR/sbin/ldconfig"
if [ -x "$chroot_ldconfig" ]; then
  # Add /usr/lib (where libclingo + from-source overlays live) to the
  # search path so ldconfig indexes it. The stock Debian
  # /etc/ld.so.conf.d/x86_64-linux-gnu.conf only covers the multiarch
  # subdir.
  mkdir -p "$STAGE_DIR/etc/ld.so.conf.d"
  cat > "$STAGE_DIR/etc/ld.so.conf.d/zz-reproos-overlay.conf" <<'EOF'
/usr/lib
/usr/lib64
EOF
  chroot "$STAGE_DIR" /sbin/ldconfig 2>&1 | \
    grep -vE 'is not a symbolic link|file format not recognized' || true
  echo "[stage-de-rootfs] rebuilt ld.so.cache via chroot/sbin/ldconfig"
else
  echo "[stage-de-rootfs] no chroot/sbin/ldconfig; dlopen() bare-name libs may fail" >&2
fi

echo "[stage-de-rootfs] stage-dir bytes=$(du -sb "$STAGE_DIR" | awk '{print $1}')"
