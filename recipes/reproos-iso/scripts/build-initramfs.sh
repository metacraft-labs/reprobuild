#!/usr/bin/env bash
# M9.R.17c.1 - Build a custom live-boot-capable initramfs for reproos-iso.
#
# The historical R2 vendored kernel + initramfs were Debian Installer
# (d-i) blobs: the initramfs runs busybox + the d-i framework and DOES
# NOT pivot_root into a SquashFS payload. The M9.R.16 milestone added a
# /live/filesystem.squashfs payload to the ISO root, but without a
# live-init-capable initramfs the kernel boots straight into d-i,
# ignoring the payload.
#
# This script assembles a from-scratch initramfs that:
#   1) Probes block devices for /live/filesystem.squashfs.
#   2) Loop-mounts the SquashFS as the rootfs lower layer.
#   3) Layers a tmpfs upper via overlayfs at /run/live/rootfs.
#   4) switch_root into the overlay.
#
# The init script is custom (~150 lines bash, vendored under
# initramfs/init in this directory) - we do NOT vendor upstream
# live-boot's 4,000-line script tree because:
#   * upstream live-boot depends on the initramfs-tools framework
#     (klibc + busybox-initramfs + the initramfs-tools scripts/init
#     orchestrator), which would balloon the initramfs size + recipe
#     surface;
#   * the M9.R.17c goal is "boot to sddm", not "match Debian Live's
#     full feature surface" (network-boot, NFS, encrypted overlays,
#     toram, persistence) - those features are deferred.
#
# Inputs (positional):
#   $1 = absolute path to write the output initramfs cpio.gz
#
# Required env:
#   SOURCE_DATE_EPOCH (for cpio --reproducible)
#
# Dependencies in PATH:
#   busybox  - statically linked, downloaded from upstream busybox
#              binary tree on demand (cached host-side).
#   linux-image-6.12.86+deb13-amd64-unsigned.deb - upstream kernel
#              modules.deb downloaded from deb.debian.org on demand
#              (cached host-side).
#   cpio, gzip, xz-utils, ar, tar, zstd, wget/curl  - host packages.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-initramfs.img>" >&2
  exit 64
fi
OUT_INITRAMFS="$1"

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set for reproducibility}"

# Host tooling.
for tool in cpio gzip xz curl ar tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-initramfs.sh: required host tool missing: $tool" >&2
    exit 66
  fi
done

# zstd is optional on hosts where the upstream .deb uses gzip data.tar.
# .deb files extracted below pick the archiver dynamically.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INITRAMFS_SRC="$RECIPE_DIR/initramfs"   # vendored /init + helper scripts

# Cache directory. Persistent across builds so the heavy 108 MB
# linux-image .deb download happens at most once.
CACHE_DIR="${REPRO_INITRAMFS_CACHE:-/var/cache/reprobuild/initramfs}"
mkdir -p "$CACHE_DIR"

# Pinned upstream sources.
#
# Kernel modules: the linux-image .deb that matches the
# vmlinuz-debian-netinst kernel release (6.12.86+deb13-amd64). This
# .deb ships every module the netinst's vmlinuz can load - including
# the squashfs/overlay/loop/ext4 trio the live-init needs.
KERNEL_RELEASE='6.12.86+deb13-amd64'
LINUX_IMAGE_DEB='linux-image-6.12.86+deb13-amd64-unsigned_6.12.86-1_amd64.deb'
LINUX_IMAGE_URL="https://deb.debian.org/debian/pool/main/l/linux/${LINUX_IMAGE_DEB}"
LINUX_IMAGE_SHA256='99f1a0bde6332e7c785e053807c3cd14a875ed0cfca21e4faf6632db4010b53f'

# Busybox: statically linked single binary. We use the upstream
# build from busybox.net to avoid a glibc/musl mismatch with whatever
# host built it.
BUSYBOX_VERSION='1.36.1'
BUSYBOX_URL='https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox'
BUSYBOX_SHA256='6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348'

fetch_if_missing() {
  # $1 = url, $2 = output path, $3 = expected sha256 (optional)
  local url="$1"
  local out="$2"
  local expected_sha256="${3:-}"
  if [ -f "$out" ]; then
    if [ -n "$expected_sha256" ]; then
      local got
      got="$(sha256sum "$out" | awk '{print $1}')"
      if [ "$got" = "$expected_sha256" ]; then
        echo "[fetch] cache-hit $(basename "$out") sha256=$got"
        return 0
      fi
      echo "[fetch] cache sha256 mismatch ($got != $expected_sha256); re-fetching"
      rm -f "$out"
    else
      echo "[fetch] cache-hit $(basename "$out") (no sha256 pin)"
      return 0
    fi
  fi
  echo "[fetch] $url -> $out"
  curl -fsSL --retry 3 -o "$out" "$url"
  if [ -n "$expected_sha256" ]; then
    local got
    got="$(sha256sum "$out" | awk '{print $1}')"
    if [ "$got" != "$expected_sha256" ]; then
      echo "[fetch] sha256 mismatch for $out: got $got, expected $expected_sha256" >&2
      exit 67
    fi
  fi
}

# Fetch upstream blobs (cached).
LINUX_IMAGE_PATH="$CACHE_DIR/$LINUX_IMAGE_DEB"
fetch_if_missing "$LINUX_IMAGE_URL" "$LINUX_IMAGE_PATH" "$LINUX_IMAGE_SHA256"
BUSYBOX_PATH="$CACHE_DIR/busybox-$BUSYBOX_VERSION"
fetch_if_missing "$BUSYBOX_URL" "$BUSYBOX_PATH" "$BUSYBOX_SHA256"

# Stage area. Deleted on exit unless REPRO_INITRAMFS_KEEP_STAGE=1.
WORK="$(mktemp -d -t reproos-initramfs-XXXXXX)"
trap 'if [ "${REPRO_INITRAMFS_KEEP_STAGE:-0}" != "1" ]; then rm -rf "$WORK"; else echo "[initramfs] stage kept at $WORK"; fi' EXIT
STAGE="$WORK/rootfs"
mkdir -p "$STAGE"/{bin,sbin,etc,proc,sys,dev,run,tmp,mnt,root,usr/bin,usr/sbin,lib,lib64}
mkdir -p "$STAGE/run/live"
mkdir -p "$STAGE/scripts"

# 1) Busybox + applet symlinks. Busybox is the only userspace binary;
#    every standard tool the /init script invokes (mount, switch_root,
#    sh, sed, awk, mkdir, mknod, modprobe, etc.) resolves to a
#    busybox applet via symlink. This is the standard initramfs
#    pattern; Debian Live's live-boot uses it too (its
#    klibc-installed busybox-initramfs is the same shape).
cp "$BUSYBOX_PATH" "$STAGE/bin/busybox"
chmod +x "$STAGE/bin/busybox"
# Standard applet list. ``busybox --install -s`` would emit these but
# we control the explicit list so the recipe is deterministic.
BUSYBOX_APPLETS=(
  sh ash mount umount switch_root mkdir mknod cat echo ls cp mv rm
  modprobe insmod lsmod findfs blkid losetup ln chmod chown sed awk
  grep tr cut head tail wc test sleep printf env true false test
  date dmesg sync poweroff reboot init halt killall ps pidof kill
  uname free df mountpoint readlink basename dirname which xargs
  tee touch find
)
for applet in "${BUSYBOX_APPLETS[@]}"; do
  ln -sf busybox "$STAGE/bin/$applet"
done

# 2) Kernel modules. Extract linux-image .deb -> get
#    /lib/modules/<kver>/kernel/{fs,drivers,...}. We only ship the
#    modules the live-init pipeline needs - selected by name to keep
#    the initramfs small.
DEB_EXTRACT="$WORK/linux-image"
mkdir -p "$DEB_EXTRACT"
(cd "$DEB_EXTRACT" && ar x "$LINUX_IMAGE_PATH")
# Identify the data archive (data.tar.xz / data.tar.zst / data.tar.gz)
data_tar=""
for cand in data.tar.zst data.tar.xz data.tar.gz; do
  if [ -f "$DEB_EXTRACT/$cand" ]; then data_tar="$DEB_EXTRACT/$cand"; break; fi
done
if [ -z "$data_tar" ]; then
  echo "build-initramfs.sh: linux-image deb missing data.tar.*" >&2
  exit 68
fi
DATA_DIR="$WORK/data"
mkdir -p "$DATA_DIR"
case "$data_tar" in
  *.zst)
    if ! command -v zstd >/dev/null 2>&1; then
      echo "build-initramfs.sh: data.tar.zst but zstd not installed" >&2
      exit 66
    fi
    zstd -d -c "$data_tar" | tar -C "$DATA_DIR" -xf -
    ;;
  *.xz)
    xz -d -c "$data_tar" | tar -C "$DATA_DIR" -xf -
    ;;
  *.gz)
    gzip -d -c "$data_tar" | tar -C "$DATA_DIR" -xf -
    ;;
esac

MOD_ROOT="$DATA_DIR/usr/lib/modules/$KERNEL_RELEASE"
if [ ! -d "$MOD_ROOT" ]; then
  # Some debs ship modules under lib/ rather than usr/lib/.
  if [ -d "$DATA_DIR/lib/modules/$KERNEL_RELEASE" ]; then
    MOD_ROOT="$DATA_DIR/lib/modules/$KERNEL_RELEASE"
  else
    echo "build-initramfs.sh: modules root not found for $KERNEL_RELEASE" >&2
    find "$DATA_DIR" -maxdepth 4 -name 'modules' -type d 2>&1 | head -5
    exit 69
  fi
fi

# The .deb's modules tree contains modules.builtin + modules.order but
# NOT modules.dep / modules.alias / modules.symbols (those are emitted
# by depmod post-install on the target system). Run depmod ourselves
# against the staged tree so we have a real dep graph.
if [ ! -f "$MOD_ROOT/modules.dep" ]; then
  if ! command -v depmod >/dev/null 2>&1; then
    echo "build-initramfs.sh: depmod not in PATH (needed to regenerate modules.dep)" >&2
    exit 70
  fi
  SYSTEM_MAP_SRC="$DATA_DIR/boot/System.map-$KERNEL_RELEASE"
  if [ ! -f "$SYSTEM_MAP_SRC" ]; then
    SYSTEM_MAP_SRC=""
  fi
  echo "[initramfs] running depmod for $KERNEL_RELEASE"
  # depmod -b <basedir> hard-codes the layout <basedir>/lib/modules/<kver>.
  # The .deb stages modules under <basedir>/usr/lib/modules; symlink so
  # depmod finds them, then depmod writes the meta files alongside.
  if [ ! -e "$DATA_DIR/lib" ]; then
    mkdir -p "$DATA_DIR/lib"
    ln -s ../usr/lib/modules "$DATA_DIR/lib/modules"
  fi
  if [ -n "$SYSTEM_MAP_SRC" ]; then
    depmod -b "$DATA_DIR" -F "$SYSTEM_MAP_SRC" "$KERNEL_RELEASE"
  else
    depmod -b "$DATA_DIR" "$KERNEL_RELEASE"
  fi
fi

STAGE_MOD_ROOT="$STAGE/lib/modules/$KERNEL_RELEASE"
mkdir -p "$STAGE_MOD_ROOT/kernel"

# Modules we need for the live-boot path. Each name is the upstream
# .ko basename (no path); we resolve dependencies via modules.dep.
# The initrd ships a subset of the full module set + the modules.dep
# subset for that subset, so modprobe works inside the initramfs.
REQUIRED_MODULES=(
  # block + storage
  loop sd_mod sr_mod cdrom virtio_blk virtio_scsi ata_piix ahci
  pata_acpi libahci scsi_mod usb-storage uas
  # filesystems
  isofs squashfs overlay ext4 vfat fat exfat nls_cp437 nls_utf8 nls_ascii
  # block crypto used by some squashfs payloads + EXT4 needs crc32c
  # to mount on x86_64 (load: crc32c-generic; ext4 mount fails with
  # "Cannot load crc32c driver" without it).
  crc32_generic crc32c_generic crc16 libcrc32c crc32c-intel
  crc-ccitt crct10dif_pclmul crct10dif_generic crct10dif_common
  # dm-mod / dm-crypt for encrypted disko apply paths.
  dm_mod dm_crypt
  # usb hosts (so usb-storage actually attaches)
  ohci-hcd ohci-pci ehci-hcd ehci-pci xhci-hcd xhci-pci uhci-hcd
  usb-common usbcore
  # virtio infrastructure (qemu)
  virtio virtio_ring virtio_pci virtio_pci_modern_dev virtio_pci_legacy_dev
  virtio_mmio virtio_balloon virtio_input
  # virtio-gpu + DRM stack so sddm/sway/mutter/kwin can open a display
  # under qemu's -device virtio-gpu-pci.
  drm drm_kms_helper virtio-gpu drm-shmem-helper drm_panel_orientation_quirks
  # qxl + bochs_drm as fallbacks for VGA-only qemu invocations
  qxl bochs
  # input + tty
  evdev hid hid-generic usbhid
)

modules_dep_src="$MOD_ROOT/modules.dep"
if [ ! -f "$modules_dep_src" ]; then
  echo "build-initramfs.sh: $modules_dep_src missing" >&2
  exit 70
fi

# Resolve module file paths (relative to MOD_ROOT) for each requested
# module + its dependency chain. The modules.dep format is:
#   <module-relpath>:<space-separated dep relpaths>
declare -A MODFILE   # module-name -> relpath
declare -A MODDEP    # module-name -> space-sep dep names
while IFS= read -r line; do
  rel="${line%%:*}"
  deps_rel="${line#*:}"
  base="$(basename "$rel" | sed -E 's/\.ko(\.(xz|gz|zst))?$//' | tr '_' '-')"
  base_underscore="$(basename "$rel" | sed -E 's/\.ko(\.(xz|gz|zst))?$//' | tr '-' '_')"
  MODFILE[$base]="$rel"
  MODFILE[$base_underscore]="$rel"
  # dep names
  dep_names=""
  for d in $deps_rel; do
    dn="$(basename "$d" | sed -E 's/\.ko(\.(xz|gz|zst))?$//')"
    dep_names+=" $dn"
  done
  MODDEP[$base]="$dep_names"
  MODDEP[$base_underscore]="$dep_names"
done < "$modules_dep_src"

declare -A SELECTED
queue=()
for m in "${REQUIRED_MODULES[@]}"; do
  queue+=("$m" "$(echo "$m" | tr '-' '_')")
done

ptr=0
while [ "$ptr" -lt "${#queue[@]}" ]; do
  m="${queue[$ptr]}"
  ptr=$((ptr+1))
  if [ -n "${SELECTED[$m]:-}" ]; then continue; fi
  if [ -z "${MODFILE[$m]:-}" ]; then
    # Module missing - not in the linux-image; that's OK for
    # nice-to-have modules (will be silently absent from initramfs).
    continue
  fi
  SELECTED[$m]=1
  # Mark deps
  for d in ${MODDEP[$m]:-}; do
    queue+=("$d" "$(echo "$d" | tr '-' '_')")
  done
done

# Copy selected modules + emit a slimmed modules.dep restricted to
# the selected set (so depmod-free modprobe resolution works).
copied_count=0
> "$WORK/modules.dep.selected"
declare -A COPIED_REL
for m in "${!SELECTED[@]}"; do
  rel="${MODFILE[$m]}"
  if [ -n "${COPIED_REL[$rel]:-}" ]; then continue; fi
  COPIED_REL[$rel]=1
  src="$MOD_ROOT/$rel"
  dst="$STAGE_MOD_ROOT/$rel"
  mkdir -p "$(dirname "$dst")"
  # Decompress .xz/.zst into plain .ko so kmod can load them even
  # without xz/zstd inside the initramfs.
  case "$src" in
    *.ko.xz)
      out="${dst%.xz}"
      xz -d -c "$src" > "$out"
      ;;
    *.ko.zst)
      out="${dst%.zst}"
      zstd -d -c "$src" > "$out"
      ;;
    *.ko.gz)
      out="${dst%.gz}"
      gzip -d -c "$src" > "$out"
      ;;
    *)
      cp "$src" "$dst"
      ;;
  esac
  copied_count=$((copied_count+1))
done

# Emit a stripped modules.dep file - same format upstream depmod
# emits, but only for the modules we kept. busybox modprobe parses
# this directly.
> "$STAGE_MOD_ROOT/modules.dep"
declare -A KEPT
for m in "${!SELECTED[@]}"; do
  rel="${MODFILE[$m]}"
  # Strip compressed suffix - we decompressed above.
  rel_uncompressed="$(echo "$rel" | sed -E 's/\.ko\.(xz|gz|zst)$/.ko/')"
  KEPT[$rel_uncompressed]=1
done
while IFS= read -r line; do
  rel="${line%%:*}"
  rel_uncompressed="$(echo "$rel" | sed -E 's/\.ko\.(xz|gz|zst)$/.ko/')"
  if [ -z "${KEPT[$rel_uncompressed]:-}" ]; then continue; fi
  deps_rel="${line#*:}"
  # Filter deps to those in KEPT.
  filtered_deps=""
  for d in $deps_rel; do
    d_uncompressed="$(echo "$d" | sed -E 's/\.ko\.(xz|gz|zst)$/.ko/')"
    if [ -n "${KEPT[$d_uncompressed]:-}" ]; then
      filtered_deps+="$d_uncompressed "
    fi
  done
  filtered_deps="${filtered_deps% }"
  echo "${rel_uncompressed}:${filtered_deps:+ $filtered_deps}" >> "$STAGE_MOD_ROOT/modules.dep"
done < "$modules_dep_src"

# Touch the auxiliary modules files that modprobe expects. Empty is
# OK - busybox modprobe falls back to modules.dep alone.
: > "$STAGE_MOD_ROOT/modules.alias"
: > "$STAGE_MOD_ROOT/modules.symbols"
echo "[initramfs] modules: ${copied_count} files staged for kernel $KERNEL_RELEASE"

# 3) /init script. Vendored under recipes/reproos-iso/initramfs/<name>.
# The variant is selected by REPRO_INITRAMFS_INIT env (default: "init",
# used by the live-boot ISO; "init-disk" is the M9.R.51 variant used
# by the reproos-image build-artifact qcow2 for boot-from-disk).
INIT_NAME="${REPRO_INITRAMFS_INIT:-init}"
if [ ! -f "$INITRAMFS_SRC/$INIT_NAME" ]; then
  echo "build-initramfs.sh: $INITRAMFS_SRC/$INIT_NAME missing" >&2
  exit 71
fi
cp "$INITRAMFS_SRC/$INIT_NAME" "$STAGE/init"
chmod +x "$STAGE/init"

# 4) /etc minimal files for getty/login - even though we never reach
#    them inside the initramfs, the staged /etc/* are mirrored into
#    the overlay so the very first systemd boot can read them.
cat > "$STAGE/etc/hostname" <<'EOF'
reproos
EOF

# 5) cpio + gzip with SOURCE_DATE_EPOCH-stable timestamps. The
#    --reproducible flag sets every entry's mtime to 0; cpio's newc
#    format zeroes inodes/uids/gids when fed sorted entries with the
#    same numeric metadata. We additionally pre-set every file's mtime
#    to SOURCE_DATE_EPOCH so timestamp-recording tools that touch the
#    initramfs (initrd-tools, gen-initramfs) see a stable value.
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

# Owner all files as root:root (deterministic).
chown -R root:root "$STAGE" 2>/dev/null || true

mkdir -p "$(dirname "$OUT_INITRAMFS")"

# cpio with sorted file list -> stable archive order.
(cd "$STAGE" && find . -print0 | LC_ALL=C sort -z | cpio --null --reproducible -o -H newc 2>/dev/null) \
  | gzip -n -9 > "$OUT_INITRAMFS"

bytes="$(stat -c %s "$OUT_INITRAMFS")"
sha="$(sha256sum "$OUT_INITRAMFS" | awk '{print $1}')"
echo "[initramfs] OK $OUT_INITRAMFS bytes=$bytes sha256=$sha"
