#!/usr/bin/env bash
# M9.R.25.3 -- minimum base userspace tarball for the reproos-iso live
# DE rootfs.
#
# Architectural model (revised M9.R.25): this script ships ONLY the
# pieces of the live ISO base that have no from-source recipe yet --
# kernel modules, bootloader tools, kernel-loader stub, the SDDM
# systemd .service glue when sddm is the autologin target, and the
# bare-minimum coreutils/util-linux needed to bootstrap PID 1 until
# the from-source equivalents (M9.R.15q.12 systemd, M9.R.15e.8 pam,
# from-source glibc + util-linux) take over.
#
# The DE stack -- sway, kwin-wayland, mutter, plasma-workspace,
# gnome-session, KF6, Qt6, Wayland, GL, mesa, fontconfig, libdrm,
# libinput, libxkbcommon -- is NO LONGER apt-installed.  Those live
# under recipes/packages/source/ as from-source recipes and the
# `stage-de-rootfs.sh` companion mirrors their full install-mirror
# trees onto the ISO at the absolute paths their RPATHs reference
# (Nix-pattern path preservation).
#
# Inputs:
#   $1 = absolute path to write the output tarball (tar.xz)
#
# Required env: SOURCE_DATE_EPOCH.
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

# Cache key: image tag + package list digest.
BASE_IMAGE='debian:trixie-slim'
#
# Package selection -- the M9.R.25 minimum.
#
# NOT INCLUDED (handled by from-source install-mirrors in stage-de-rootfs.sh):
#   - sway, kwin-wayland, mutter, plasma-workspace, gnome-session
#   - sddm (the BINARY is from-source; the systemd unit + PAM glue
#     stay in the apt set below until the from-source recipe lands
#     the unit files itself)
#   - kf6 frameworks, qt6, qt6-wayland
#   - libqt6gui6, libqt6widgets6, libqt6quick6, libqt6qml6, ...
#   - mesa-vulkan-drivers, libgl1, libegl1, libglx-mesa0, libgles2
#   - libwayland-server0, libwayland-client0, libxkbcommon0,
#     libxcursor1, libxext6, libxrandr2, libxi6, libpipewire-0.3-0
#   - fontconfig, fonts-dejavu-core (from-source recipes)
#   - libpam0g, libpam-runtime, libpam-systemd (from-source pam recipe)
#   - polkitd (genuinely absent from-source recipe -- TODO M9.R.26)
#   - xwayland (genuinely absent from-source recipe -- TODO M9.R.26)
#   - libsqlite3-0, libclingo (handled by nix-store closure mirroring
#     in stage-de-rootfs.sh)
#
# STILL INCLUDED (no from-source recipe yet):
#   - kernel + initrd tools (the live ISO ships a Debian kernel/initrd
#     until the from-source linux kernel recipe lands)
#   - busybox-style bootstrap utilities that PID 1 calls before
#     switch_root into the full systemd
#   - disk-apply / bootloader installer tools the reproos-installer
#     shells out to via libs/repro_profile (these run on the live ISO
#     against the QEMU virtio-blk target; they have no from-source
#     equivalents in this milestone)
#   - tzdata + locales (data-only packages, no build cost; no recipe)
#   - keyboard data (xkb-data, console-data) -- data packages
#   - CA certificate bundle (data package)
#
PKG_LIST=(
  # init shim + libc -- needed by PID 1 until the from-source systemd
  # + glibc install-mirrors are wired into the boot chain.  When
  # M9.R.26 lands the from-source systemd init unit + glibc shim,
  # systemd / systemd-sysv / libpam* drop out of this list.
  systemd systemd-sysv libpam-systemd dbus dbus-user-session
  # Essential userspace -- bootstrap busybox-equivalents until the
  # from-source coreutils/util-linux/grep recipes are wired through.
  util-linux mount kmod udev tzdata passwd login procps less nano
  # Locale data (no build cost; pure data).
  locales
  # Keyboard + console data.
  xkb-data console-data console-setup keyboard-configuration
  # Network / CA / users.
  ca-certificates iputils-ping iproute2 sudo
  # SDDM systemd unit + PAM glue.  The BINARY is shadowed by the
  # from-source recipe in stage-de-rootfs.sh; we keep the package to
  # pick up the .service file and the /etc/pam.d/sddm policy until a
  # from-source sddm recipe ships those files itself (TODO M9.R.26).
  sddm
  # M9.R.24.2 -- disko apply tools the installer's Phase 2 driver
  # shells out to.  These are the on-target install-time utilities;
  # the from-source equivalents are part of a longer-tail recipe
  # campaign (TODO M9.R.27).
  gdisk parted e2fsprogs dosfstools btrfs-progs cryptsetup lvm2
  # Bootloader tools the installer's Phase 5 (system apply) shells
  # out to.  GRUB has no from-source recipe yet (TODO M9.R.27).
  grub-efi-amd64-bin grub-pc-bin grub-common grub2-common
)

PKG_DIGEST="$(printf '%s\n' "${PKG_LIST[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
## M9.R.29.17 — also hash the script body so shadow / autologin /
## serial-getty changes invalidate the cache. Without this the cache
## key only changes when PKG_LIST changes, and post-debootstrap
## customisations silently stick from a stale tarball.
SCRIPT_DIGEST="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
CACHE_KEY="trixie-slim-${PKG_DIGEST:0:8}-${SCRIPT_DIGEST:0:8}"
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

docker run --network host --name "$CTR_NAME" "$BASE_IMAGE" bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ${PKG_LIST[*]}
rm -rf /var/lib/apt/lists/*
if [ -f /etc/locale.gen ]; then
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen >/dev/null 2>&1 || true
fi
systemctl set-default graphical.target 2>/dev/null || true
for g in audio video input plugdev netdev sudo; do
  groupadd -f \"\$g\" 2>/dev/null || true
done
useradd --create-home --shell /bin/bash --uid 1000 --groups audio,video,input,plugdev,netdev,sudo live
## M9.R.29.16 — previous hash used a 7-char salt 'reproos' which is
## invalid (modern crypt(3) requires 8-16 chars for SHA-512), and the
## live-ISO 'login: ... Login incorrect' was a real auth failure, not
## a missing-password issue. Regenerate with a valid 9-char salt
## 'reproo123'; password is still 'reproos'.
LIVE_HASH='\$6\$reproo123\$KJGP/pyxIdKyCZBeNLmdzO1b0H3n5klR49gRuog3Qel19.safRMX6YDVU9U2O098qGJMp6pp.NDp.7YcKXFnz/'
ROOT_HASH='\$6\$reproo123\$KJGP/pyxIdKyCZBeNLmdzO1b0H3n5klR49gRuog3Qel19.safRMX6YDVU9U2O098qGJMp6pp.NDp.7YcKXFnz/'
usermod -p \"\$LIVE_HASH\" live 2>/dev/null || true
usermod -p \"\$ROOT_HASH\" root 2>/dev/null || true
passwd -u live 2>/dev/null || true
passwd -u root 2>/dev/null || true
echo 'reproos' > /etc/hostname
if [ -f /etc/os-release ]; then
  sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME=\"ReproOS\"/' /etc/os-release
fi
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \\\$TERM
EOF2
## M9.R.29.17 — serial-console autologin for QEMU -nographic boots
## (the M9.R.28 smoke ran into 'localhost login: Login incorrect'
## because tty1's autologin doesn't help when the kernel cmdline
## sends console=ttyS0). Enable serial-getty@ttyS0 with autologin
## root, mirroring the tty1 override.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EOF2
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I \\\$TERM
EOF2
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
"

TMP_TAR="$(mktemp -t reproos-base-XXXXXX.tar)"
trap 'rm -f "$TMP_TAR"; docker rm -f "$CTR_NAME" >/dev/null 2>&1 || true' EXIT
docker export "$CTR_NAME" -o "$TMP_TAR"

mkdir -p "$(dirname "$CACHED_TAR")"
xz -1 -c < "$TMP_TAR" > "$CACHED_TAR.tmp"
mv "$CACHED_TAR.tmp" "$CACHED_TAR"
cp "$CACHED_TAR" "$OUT_TAR"
rm -f "$TMP_TAR"

bytes="$(stat -c %s "$OUT_TAR")"
sha="$(sha256sum "$OUT_TAR" | awk '{print $1}')"
echo "[base-rootfs] OK $OUT_TAR bytes=$bytes sha256=$sha"
