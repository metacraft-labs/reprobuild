#!/usr/bin/env bash
# M9.R.17c.5 -- assemble a minimum base userspace tarball for the
# reproos-iso live DE rootfs.
#
# stage-de-rootfs.sh consumes the output tarball BEFORE unioning in
# the from-source DE binaries; this gets systemd + libc + login +
# Qt/GL stack into the live filesystem.squashfs so the staged sddm /
# kwin / mutter / sway binaries can actually run + so /sbin/init is
# present for the live-init's switch_root.
#
# Implementation: pull debian:trixie-slim, apt-install the curated
# package list, export the running container, xz-compress the
# tarball. Cached host-side under $CACHE_DIR so subsequent runs are
# near-instantaneous.
#
# Inputs:
#   $1 = absolute path to write the output tarball (tar.xz)
#
# Required env: SOURCE_DATE_EPOCH (currently advisory; docker export
# does not honour SOURCE_DATE_EPOCH at the file level).
#
# Dependencies in PATH: docker, xz, tar, sha256sum.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-tarball.tar.xz>" >&2
  exit 64
fi
OUT_TAR="$1"

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"

for tool in docker xz tar sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-base-rootfs.sh: required tool missing: $tool" >&2
    exit 66
  fi
done

CACHE_DIR="${REPRO_BASE_ROOTFS_CACHE:-/var/cache/reprobuild/base-rootfs}"
mkdir -p "$CACHE_DIR"

# Cache key: image tag + package list digest. Anything that changes
# the rootfs forces a rebuild.
BASE_IMAGE='debian:trixie-slim'
PKG_LIST=(
  # systemd init system
  systemd systemd-sysv libpam-systemd dbus dbus-user-session
  # essential userspace
  util-linux mount kmod udev tzdata passwd login procps less nano
  # locale
  locales
  # PAM + polkit (DE permission prompts)
  libpam0g libpam-runtime polkitd
  # keyboard + console
  xkb-data console-data console-setup keyboard-configuration
  # X11/Wayland client libs (compositor + xwayland)
  libxcursor1 libxext6 libxrandr2 libxi6 libxkbcommon0 xwayland
  libwayland-server0 libwayland-client0
  # fonts so SDDM can render text
  fontconfig fonts-dejavu-core
  # GL/Vulkan stack
  libgl1 libegl1 libglx-mesa0 mesa-vulkan-drivers libvulkan1
  # gcc / cxx runtimes
  libgcc-s1 libstdc++6
  # Qt6 runtime for sddm-greeter + reproos-installer
  libqt6gui6 libqt6widgets6 libqt6quick6 libqt6qml6
  libqt6quickcontrols2-6 libqt6dbus6 libqt6network6
  libqt6opengl6 libqt6openglwidgets6 libqt6svg6
  libqt6quicktemplates2-6
  # M9.R.18.14 -- Qt6 Wayland QPA plugin for the reproos-installer
  # (kiosk sway session). Without this the binary aborts at
  # QGuiApplication construction with "Could not find the Qt platform
  # plugin 'wayland'" since the launcher script forces WAYLAND_DISPLAY.
  qt6-wayland
  # audio
  libpipewire-0.3-0
  # network / CA
  ca-certificates iputils-ping iproute2
  # users
  sudo
  # display manager + DE runtime - we install the Debian-packaged
  # sddm even though the from-source recipe builds its own binary;
  # the Debian package ships the systemd .service + PAM glue that the
  # bare from-source build doesn't, and the overlayed from-source
  # /usr/bin/sddm wins anyway.
  sddm
  # session-bus support for the DE that sddm spawns
  xdg-desktop-portal
  # M9.R.24.1 -- Wayland-session DE runtimes.
  #
  # Pre-M9.R.24, the live ISO only had from-source DE binaries unioned
  # into the staged tree. The from-source sway/kwin/mutter recipes
  # don't bundle their full dep graph (libwlroots, libpango, libKF6*,
  # libGLESv2) so the moment SDDM execs the launcher (`exec sway`)
  # the loader aborts with "shared library: cannot open shared object
  # file" -- which propagates as exec exit 127, sddm-helper returns
  # 127, and SDDM busy-loops adding+removing displays without ever
  # painting the framebuffer.
  #
  # Fix: apt-install the full Debian DE stack so the loader finds
  # every NEEDED soname at the standard /usr/lib search paths.
  # stage-de-rootfs.sh's `cp -rL --no-clobber` overlay then preserves
  # the working Debian binaries; the from-source binaries only
  # contribute libs+resources that aren't already in the Debian set
  # (because the from-source linkage targets versions Debian doesn't
  # ship -- libwlroots-0.19 vs Debian's 0.18, etc).
  #
  # Compositors: sway (autologin kiosk wrapper for the reproos
  # installer), kwin-wayland (Plasma session), mutter (GNOME session).
  sway kwin-wayland mutter
  # GL ES 2 runtime -- mutter + Qt6 RHI need libGLESv2.so.2 unrelated
  # to the compositor packages above.
  libgles2
  # Plasma + GNOME session managers.
  plasma-workspace gnome-session
  # KF6 frameworks (transitive deps of plasma-workspace + kwin).
  libkf6coreaddons6 libkf6i18n6 libkf6configcore6 libkf6configgui6
  libkf6configwidgets6 libkf6colorscheme6 libkf6service6 libkf6svg6
  libkf6widgetsaddons6 libkf6windowsystem6 libkf6crash6
  libkf6globalaccel6 libkf6idletime6
  # qt6-concurrent (kwin link target)
  libqt6concurrent6
  # M9.R.24.1g -- the repro CLI links against libsqlite3 (engine
  # action-cache backend). Without it the wizard's Phase 1 hardware
  # probe shell-out fails with "error while loading shared libraries:
  # libsqlite3.so".
  libsqlite3-0
  # M9.R.24.2 -- disko apply tools the installer's Phase 2 driver
  # shells out to. wipefs (util-linux), sgdisk (gdisk), parted,
  # mkfs.ext4 / mkfs.vfat (e2fsprogs + dosfstools), partprobe
  # (parted post-install hook script). These let the installer's
  # libs/repro_profile/src/repro_profile/disk_apply.nim driver run
  # against the QEMU virtio-blk target.
  gdisk parted e2fsprogs dosfstools btrfs-progs cryptsetup lvm2
  # Bootloader tools the installer's Phase 5 (system apply) shells
  # out to via the disko/system stage. grub-efi + grub-pc cover both
  # UEFI and BIOS GRUB installs.
  grub-efi-amd64-bin grub-pc-bin grub-common grub2-common
)

# Stable digest of the package list for the cache key. Sort first so
# reordering the list doesn't bust the cache.
PKG_DIGEST="$(printf '%s\n' "${PKG_LIST[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
CACHE_KEY="trixie-slim-${PKG_DIGEST:0:16}"
CACHED_TAR="$CACHE_DIR/$CACHE_KEY.tar.xz"

if [ -f "$CACHED_TAR" ]; then
  echo "[base-rootfs] cache-hit $CACHED_TAR"
  cp "$CACHED_TAR" "$OUT_TAR"
  bytes="$(stat -c %s "$OUT_TAR")"
  sha="$(sha256sum "$OUT_TAR" | awk '{print $1}')"
  echo "[base-rootfs] OK $OUT_TAR bytes=$bytes sha256=$sha (cached)"
  exit 0
fi

echo "[base-rootfs] building $CACHE_KEY"
echo "[base-rootfs] pulling $BASE_IMAGE"
docker pull "$BASE_IMAGE"

CTR_NAME="reproos-base-build-$$"
trap 'docker rm -f "$CTR_NAME" >/dev/null 2>&1 || true' EXIT

# Run apt-install inside an interactively-named container, then
# export it. --network host because the docker bridge net in WSL2
# can't reach deb.debian.org reliably; the install completes against
# the host's network instead.
docker run --network host --name "$CTR_NAME" "$BASE_IMAGE" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ${PKG_LIST[*]}
rm -rf /var/lib/apt/lists/*
# Reset locale-gen if locales got installed.
if [ -f /etc/locale.gen ]; then
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen >/dev/null 2>&1 || true
fi
# Default systemd to graphical.target.
systemctl set-default graphical.target 2>/dev/null || true
# Create the live user (uid 1000) so the DEs have a session target.
# Ensure the optional groups exist before useradd consumes them.
# debian:trixie-slim ships audio + video by default; plugdev / netdev
# are conditionally created by package post-install. groupadd -f is a
# no-op if the group already exists.
for g in audio video input plugdev netdev sudo; do
  groupadd -f \"\$g\" 2>/dev/null || true
done
useradd --create-home --shell /bin/bash --uid 1000 --groups audio,video,input,plugdev,netdev,sudo live
# chpasswd via libpam-systemd can fail in non-PID-1 contexts; usermod
# -p with a precomputed hash sidesteps PAM entirely. Hashes pre-
# computed via openssl passwd -6 'live' / 'reproos'.
LIVE_HASH='\$6\$reproos\$Rd5gmEZ6lzlf9HZUkY9SuD7Z65xVF7HhYIxQ4Q3Or8sM5wWdfaY0Hv38zXXdpVPsLZD6vN2GjdcS.HnXP/zaR0'
ROOT_HASH='\$6\$reproos\$Rd5gmEZ6lzlf9HZUkY9SuD7Z65xVF7HhYIxQ4Q3Or8sM5wWdfaY0Hv38zXXdpVPsLZD6vN2GjdcS.HnXP/zaR0'
usermod -p \"\$LIVE_HASH\" live 2>/dev/null || true
usermod -p \"\$ROOT_HASH\" root 2>/dev/null || true
# Also clear the password lock - autologin needs an unlocked account.
passwd -u live 2>/dev/null || true
passwd -u root 2>/dev/null || true
# Mark the rootfs as ReproOS.
echo 'reproos' > /etc/hostname
if [ -f /etc/os-release ]; then
  sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME=\"ReproOS\"/' /etc/os-release
fi
# autologin live on tty1 so the session boots even if pam fails for
# the live user.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin live --noclear %I \\\$TERM
EOF2
"

# Export to a tarball.
TMP_TAR="$(mktemp -t reproos-base-XXXXXX.tar)"
trap 'rm -f "$TMP_TAR"; docker rm -f "$CTR_NAME" >/dev/null 2>&1 || true' EXIT
docker export "$CTR_NAME" -o "$TMP_TAR"

# xz-compress for storage. -1 is fast + small enough.
mkdir -p "$(dirname "$CACHED_TAR")"
xz -1 -c < "$TMP_TAR" > "$CACHED_TAR.tmp"
mv "$CACHED_TAR.tmp" "$CACHED_TAR"
cp "$CACHED_TAR" "$OUT_TAR"
rm -f "$TMP_TAR"

bytes="$(stat -c %s "$OUT_TAR")"
sha="$(sha256sum "$OUT_TAR" | awk '{print $1}')"
echo "[base-rootfs] OK $OUT_TAR bytes=$bytes sha256=$sha"
