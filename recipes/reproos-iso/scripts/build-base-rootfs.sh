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
  libgl1 libegl1 libglx-mesa0 mesa-vulkan-drivers
  # gcc / cxx runtimes
  libgcc-s1 libstdc++6
  # Qt6 runtime for sddm-greeter
  libqt6gui6 libqt6widgets6 libqt6quick6 libqt6qml6
  libqt6quickcontrols2-6 libqt6dbus6 libqt6network6
  libqt6opengl6 libqt6openglwidgets6 libqt6svg6
  libqt6quicktemplates2-6
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
useradd --create-home --shell /bin/bash --uid 1000 --groups audio,video,input,plugdev,netdev,sudo live 2>/dev/null || true
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
