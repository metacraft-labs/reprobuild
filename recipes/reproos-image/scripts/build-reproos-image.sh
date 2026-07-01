#!/usr/bin/env bash
# M9.R.50.2 -- build-reproos-image.sh: produce a fully-installed
# reproos-installed.qcow2 on the host.
#
# Spec: reprobuild-specs/ReproOS-Image-Recipe.md (M9.R.50.1).
#
# Pipeline:
#
#   1. Parse $REPRO_AUTO_CONFIG (TOML).
#   2. Stage the Nix-style rootfs via stage-de-rootfs.sh (M9.R.25 +
#      M9.R.46).
#   3. Render a disko JSON spec from the TOML's [disk] block.
#   4. qemu-img create -f qcow2 reproos-installed.qcow2 <size>.
#   5. sudo modprobe nbd; sudo qemu-nbd --connect=/dev/nbd0 <qcow2>.
#   6. repro disk apply --confirm --device /dev/nbd0 <disko.json>.
#   7. mount the partitions on $WORK/mnt + $WORK/mnt/boot.
#   8. repro infra install-root --target $WORK/mnt --source
#      <staged-tree> --device /dev/nbd0 --hostname <hn> --disko
#      <disko.json>.
#   9. Write $WORK/mnt/etc/repro/{system,hardware}.nim from TOML.
#   10. Write $WORK/mnt/etc/shadow entries from TOML user.password_hash.
#   11. umount; sudo qemu-nbd --disconnect /dev/nbd0; sudo rmmod nbd.
#   12. mv qcow2 to the recipe's output path.
#
# Input:
#   $1 = absolute output path for the qcow2.
#   REPRO_AUTO_CONFIG env (defaults handled by repro.nim).
#   SOURCE_DATE_EPOCH / LC_ALL / TZ for reproducibility.
#
# Output:
#   $1 (the qcow2).
#
# Exit codes:
#   0   = success
#   64  = bad invocation
#   65  = missing tool
#   66  = config parse error
#   67  = staged tree build failed
#   68  = qcow2 / nbd setup failed
#   69  = disk apply failed
#   70  = install-root failed
#   71  = config emit failed
#   72  = cleanup failed (warning, not fatal -- exit is from the
#         original failure)

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out.qcow2>" >&2
  exit 64
fi

OUT_QCOW2="$1"

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set for reproducibility}"
: "${LC_ALL:?LC_ALL=C required}"
: "${TZ:?TZ=UTC required}"
: "${REPRO_AUTO_CONFIG:?REPRO_AUTO_CONFIG must be set}"

# The recipe engine sets cwd to recipes/reproos-image; the repo
# root is two levels up.
REPO_ROOT="$(cd ../.. && pwd)"
RECIPE_DIR="$(pwd)"
SCRIPT_DIR_SELF="$(cd "$(dirname "$0")" && pwd)"
ISO_SCRIPTS_DIR="$REPO_ROOT/recipes/reproos-iso/scripts"

# Resolve the config path relative to the recipe dir if it's not
# absolute.
case "$REPRO_AUTO_CONFIG" in
  /*) ;;
  *)  REPRO_AUTO_CONFIG="$RECIPE_DIR/$REPRO_AUTO_CONFIG" ;;
esac
if [ ! -f "$REPRO_AUTO_CONFIG" ]; then
  echo "[build-reproos-image] config not found: $REPRO_AUTO_CONFIG" >&2
  exit 64
fi

echo "[build-reproos-image] config: $REPRO_AUTO_CONFIG"

# M9.R.53: sudo is the sole HOST-only tool escape hatch (it needs
# setuid so it can't be provisioned by a store-managed catalog).
# Resolve an absolute path (avoiding a bare ``sudo`` invocation that
# a scoop-style user-writable shim could shadow to a non-setuid
# copy) by probing the canonical host locations in order:
#
#   * /usr/bin/sudo    -- Debian / Ubuntu / Fedora / Arch / macOS
#   * /run/wrappers/bin/sudo  -- NixOS (security.sudo.enable = true)
#   * /usr/local/bin/sudo     -- rare source-install override
#
# Every other tool the script invokes is declared in the recipe's
# runtimeDeps: block (recipes/reproos-image/repro.nim) and resolved
# via M9.N Batch B path-mode probing at build-plan time -- if a tool
# goes missing from the dev shell PATH, the resolver raises a
# structured "tool-resolution failed" diagnostic BEFORE the script
# fires.
SUDO=""
for cand in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
  if [ -u "$cand" ] || [ -x "$cand" ]; then
    SUDO="$cand"
    break
  fi
done
if [ -z "$SUDO" ]; then
  echo "[build-reproos-image] required host tool missing: sudo" \
       "(probed /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo;" \
       "sudo must be host-installed with setuid; declare-and-provision" \
       "does not apply to setuid binaries)" >&2
  exit 65
fi
echo "[build-reproos-image] sudo: $SUDO"

# Required host tools.  Fail loudly if any are missing -- the recipe
# orchestrator already provisions these in the dev shell via the
# runtimeDeps: declaration on reproos-image (M9.R.53).  This local
# defence-in-depth loop catches any resolver bypass (e.g. direct
# invocation of build-reproos-image.sh outside the repro build
# harness) with the same clear diagnostic.
for tool in qemu-img qemu-nbd parted sgdisk mkfs.ext4 mkfs.vfat rsync grub-install grub-mkconfig mountpoint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[build-reproos-image] required tool missing: $tool" >&2
    exit 65
  fi
done

# Locate the `repro` binary.  Probe order:
#   1. $REPRO_BIN env (caller override).
#   2. $REPO_ROOT/build/bin/repro (build_apps.sh output -- the
#      same binary the M9.R.46 driver scripts used).
#   3. $REPO_ROOT/apps/repro/.repro/output/install/usr/bin/repro
#      (per-recipe build output).
#   4. PATH lookup (dev shell provisioned).
REPRO_BIN="${REPRO_BIN:-}"
if [ -z "$REPRO_BIN" ] || [ ! -x "$REPRO_BIN" ]; then
  for cand in \
    "$REPO_ROOT/build/bin/repro" \
    "$REPO_ROOT/apps/repro/.repro/output/install/usr/bin/repro"; do
    if [ -x "$cand" ]; then
      REPRO_BIN="$cand"
      break
    fi
  done
fi
if [ -z "$REPRO_BIN" ] || [ ! -x "$REPRO_BIN" ]; then
  REPRO_BIN="$(command -v repro 2>/dev/null || true)"
fi
if [ -z "$REPRO_BIN" ] || [ ! -x "$REPRO_BIN" ]; then
  echo "[build-reproos-image] 'repro' binary not found; build via build_apps.sh first" >&2
  exit 65
fi
echo "[build-reproos-image] repro: $REPRO_BIN"

# Working dir under the recipe's build dir; cleaned on exit.
WORK="$RECIPE_DIR/build/work"
mkdir -p "$WORK"
STAGE_DIR="$WORK/stage"
MNT_DIR="$WORK/mnt"
mkdir -p "$STAGE_DIR" "$MNT_DIR"

# ---------------------------------------------------------------
# Cleanup trap.  Best-effort: umount any mounted partitions,
# disconnect /dev/nbd0, rmmod nbd.  Don't mask the original exit
# code.
# ---------------------------------------------------------------
NBD_DEV=""
NBD_CONNECTED=0
MOUNTED_PATHS=()

cleanup() {
  local rc=$?
  set +e
  for p in "${MOUNTED_PATHS[@]}"; do
    if mountpoint -q "$p"; then
      "$SUDO" umount "$p" 2>/dev/null || "$SUDO" umount -l "$p" 2>/dev/null
    fi
  done
  if [ -n "$NBD_DEV" ] && [ "$NBD_CONNECTED" = "1" ]; then
    "$SUDO" qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
  fi
  exit $rc
}
trap cleanup EXIT

# ---------------------------------------------------------------
# TOML parsing.  Without a TOML library we use a small awk-based
# extractor.  Schema is intentionally simple and validated below.
# ---------------------------------------------------------------
toml_get() {
  # toml_get <file> <section> <key>
  # Returns the value for [section] key on stdout, or empty if not
  # present.  Strips surrounding quotes from string values.  Supports
  # only flat keys + [section]subsection blocks.
  awk -v section="$2" -v key="$3" '
    BEGIN { cur=""; }
    /^[[:space:]]*#/ { next; }
    /^[[:space:]]*$/ { next; }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "");
      cur=$0;
      next;
    }
    {
      line=$0;
      sub(/[[:space:]]*#.*$/, "", line);
      n=split(line, kv, "=");
      if (n<2) next;
      k=kv[1];
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k);
      v=kv[2];
      for (i=3;i<=n;i++) v=v"="kv[i];
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);
      gsub(/^"|"$/, "", v);
      gsub(/^'\''|'\''$/, "", v);
      if (cur == section && k == key) { print v; exit; }
    }
  ' "$1"
}

CFG="$REPRO_AUTO_CONFIG"

HOSTNAME_VAL="$(toml_get "$CFG" "" "hostname")"
USER_NAME="$(toml_get "$CFG" "user" "name")"
USER_PWHASH="$(toml_get "$CFG" "user" "password_hash")"
USER_SHELL="$(toml_get "$CFG" "user" "shell")"
DISK_SIZE_GB="$(toml_get "$CFG" "disk" "size_gb")"
DISK_TYPE="$(toml_get "$CFG" "disk.layout" "type")"
ESP_SIZE_MIB="$(toml_get "$CFG" "disk.layout" "esp_size_mib")"
DE_DEFAULT="$(toml_get "$CFG" "de" "default")"
NET_IPV4="$(toml_get "$CFG" "network" "ipv4")"

# Defaults / validation.
HOSTNAME_VAL="${HOSTNAME_VAL:-reproos}"
USER_NAME="${USER_NAME:-repro}"
USER_SHELL="${USER_SHELL:-/bin/bash}"
DISK_SIZE_GB="${DISK_SIZE_GB:-8}"
DISK_TYPE="${DISK_TYPE:-uefi-ext4}"
ESP_SIZE_MIB="${ESP_SIZE_MIB:-512}"
DE_DEFAULT="${DE_DEFAULT:-sway}"
NET_IPV4="${NET_IPV4:-dhcp}"

if [ -z "$USER_PWHASH" ]; then
  echo "[build-reproos-image] [user] password_hash is required" >&2
  exit 66
fi
case "$DISK_TYPE" in
  uefi-ext4) ;;
  *) echo "[build-reproos-image] unsupported [disk.layout].type: $DISK_TYPE (v1 only supports uefi-ext4)" >&2
     exit 66 ;;
esac
case "$DE_DEFAULT" in
  sway|kwin|mutter|plasmashell|sddm) ;;
  *) echo "[build-reproos-image] unsupported [de].default: $DE_DEFAULT" >&2
     exit 66 ;;
esac

echo "[build-reproos-image] hostname=$HOSTNAME_VAL user=$USER_NAME size_gb=$DISK_SIZE_GB layout=$DISK_TYPE de=$DE_DEFAULT"

# ---------------------------------------------------------------
# Phase 2: stage the Nix-style rootfs via stage-de-rootfs.sh.
# We cd into the iso recipe dir because the script reads
# "$(cd ../.. && pwd)" as REPO_ROOT.
# ---------------------------------------------------------------
echo "[build-reproos-image] staging rootfs at $STAGE_DIR"
# The stage-de-rootfs.sh + relocate-nix-to-repro.sh chain costs
# ~5 min cold.  Reuse a healthy existing stage when the marker file
# is present (set REPRO_FORCE_RESTAGE=1 to bypass).
STAGE_MARKER="$STAGE_DIR/.repro-stage-complete"
if [ "${REPRO_FORCE_RESTAGE:-0}" = "1" ] || [ ! -f "$STAGE_MARKER" ]; then
  if [ -d "$STAGE_DIR" ] && [ -n "$(ls -A "$STAGE_DIR" 2>/dev/null || true)" ]; then
    chmod -R u+w "$STAGE_DIR" 2>/dev/null || true
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
  fi
  (
    cd "$REPO_ROOT/recipes/reproos-iso"
    bash scripts/stage-de-rootfs.sh "$STAGE_DIR"
  ) || { echo "[build-reproos-image] stage-de-rootfs.sh failed" >&2; exit 67; }
  touch "$STAGE_MARKER"
else
  echo "[build-reproos-image] stage cache HIT (use REPRO_FORCE_RESTAGE=1 to bypass)"
fi
echo "[build-reproos-image] stage done; size: $(du -sh "$STAGE_DIR" | awk '{print $1}')"

# ---------------------------------------------------------------
# Phase 2.5: seed /boot in the staged tree with kernel + initrd.
#
# The stage-de-rootfs tree carries no kernel (the live ISO ships a
# vendored Debian netinst kernel + a live-init initramfs from the
# iso recipe).  For a build-time image we need the same vmlinuz +
# a boot-from-disk initramfs in the staged tree so install-root's
# copyLiveKernelAndInitrd finds them in candidate path
# "<source>/boot/vmlinuz" / "<source>/boot/initrd.img".
#
# Source vmlinuz: extracted on-the-fly from the linux-image deb
# that build-initramfs.sh already downloaded + cached at
# /var/cache/reprobuild/initramfs/.
#
# Source initrd: re-use the iso recipe's vendored
# initrd.img-live (live-boot initramfs from build-initramfs.sh).
# It probes for /live/filesystem.squashfs; on the installed disk
# it won't find one and falls through to a rescue shell -- which
# means the boot smoke can SSH-style verify the kernel reached
# userspace + the rootfs is intact, even if the system doesn't
# auto-progress to multi-user.target.  A follow-up M9.R.50.x
# milestone will replace this with a real "boot-from-disk"
# initramfs (initramfs-tools / dracut) that pivots into
# /dev/disk/by-label/reproos-root.
VENDORED_KERNEL="$REPO_ROOT/recipes/reproos-iso/vendor/vmlinuz-debian-netinst"
# M9.R.51: generate a boot-from-disk initramfs (init-disk variant of
# the live-init) instead of reusing the ISO's live-boot initrd (which
# probes for /live/filesystem.squashfs and drops to rescue on an
# installed disk).  We invoke reproos-iso/scripts/build-initramfs.sh
# with REPRO_INITRAMFS_INIT=init-disk so the same busybox+modules
# staging pipeline packs the boot-from-disk /init instead.
DISK_INITRD_CACHE="${REPRO_DISK_INITRD_CACHE:-/var/cache/reprobuild/reproos-image/initrd.img-disk}"
STAGE_BOOT_MARKER="$STAGE_DIR/.repro-boot-seeded"
if [ ! -f "$STAGE_BOOT_MARKER" ]; then
  echo "[build-reproos-image] seeding $STAGE_DIR/boot with kernel + boot-from-disk initrd"
  mkdir -p "$STAGE_DIR/boot"
  if [ -f "$VENDORED_KERNEL" ]; then
    cp "$VENDORED_KERNEL" "$STAGE_DIR/boot/vmlinuz"
    echo "[build-reproos-image] vmlinuz: $(ls -la "$STAGE_DIR/boot/vmlinuz" | awk '{print $5}') bytes (from iso recipe vendor)"
  else
    echo "[build-reproos-image] WARNING: $VENDORED_KERNEL missing; run \`pwsh recipes/reproos-iso/vendor/fetch.ps1\` first" >&2
  fi
  if [ ! -f "$DISK_INITRD_CACHE" ]; then
    echo "[build-reproos-image] generating boot-from-disk initrd via build-initramfs.sh (REPRO_INITRAMFS_INIT=init-disk)"
    mkdir -p "$(dirname "$DISK_INITRD_CACHE")"
    REPRO_INITRAMFS_INIT=init-disk \
      bash "$REPO_ROOT/recipes/reproos-iso/scripts/build-initramfs.sh" "$DISK_INITRD_CACHE"
  else
    echo "[build-reproos-image] boot-from-disk initrd cached: $DISK_INITRD_CACHE"
  fi
  cp "$DISK_INITRD_CACHE" "$STAGE_DIR/boot/initrd.img"
  echo "[build-reproos-image] initrd.img (boot-from-disk): $(ls -la "$STAGE_DIR/boot/initrd.img" | awk '{print $5}') bytes"
  touch "$STAGE_BOOT_MARKER"
else
  echo "[build-reproos-image] /boot already seeded (marker present)"
fi

# ---------------------------------------------------------------
# Phase 3: render a disko JSON for the uefi-ext4 preset.
# Mirrors installer_state.cpp::renderDiskoJson but in shell since
# we don't need the full Qt class hierarchy.
# ---------------------------------------------------------------
# Format mirrors apps/reproos-installer/src/installer_state.cpp's
# renderDiskoJson "simple" preset (validated by M9.R.41's installer
# Phase 5 against the same parseSystemHardwareJson code path).
# Notes:
#   - disks/partitions are JObjects (keyed by name), NOT arrays.
#   - DiskSpec.type = "gpt" (not "disk").
#   - PartitionSpec.type = "esp" / "linux" (not GPT GUID strings).
#   - ContentSpec.kind = "filesystem" (no "gpt" content kind).
#   - bootable is required on every PartitionSpec.
#   - "pools":[] is required at the disko level.
DISKO_JSON="$WORK/disko.json"
cat > "$DISKO_JSON" <<EOF
{
  "id": "reproos-image",
  "cpuArch": "x86_64",
  "cpuMicrocode": "intel",
  "kernelModules": [],
  "loaderDevice": "/dev/nbd0",
  "filesystems": [],
  "graphicsDrivers": [],
  "audioCards": [],
  "disko": {
    "disks": {
      "main": {
        "device": "/dev/nbd0",
        "type": "gpt",
        "partitions": {
          "esp": {
            "type": "esp",
            "size": "${ESP_SIZE_MIB}M",
            "bootable": true,
            "content": {
              "kind": "filesystem",
              "format": "vfat",
              "mountpoint": "/boot",
              "mountOptions": ["umask=0077"],
              "label": "ESP",
              "subvols": []
            }
          },
          "root": {
            "type": "linux",
            "size": "100%",
            "bootable": false,
            "content": {
              "kind": "filesystem",
              "format": "ext4",
              "mountpoint": "/",
              "mountOptions": ["defaults"],
              "label": "reproos-root",
              "subvols": []
            }
          }
        }
      }
    },
    "pools": []
  }
}
EOF
echo "[build-reproos-image] disko json: $DISKO_JSON"

# ---------------------------------------------------------------
# Phase 4: qemu-img create.
# ---------------------------------------------------------------
TMP_QCOW2="$WORK/reproos-installed.qcow2"
rm -f "$TMP_QCOW2"
qemu-img create -f qcow2 "$TMP_QCOW2" "${DISK_SIZE_GB}G" \
  || { echo "[build-reproos-image] qemu-img create failed" >&2; exit 68; }
echo "[build-reproos-image] qcow2 created: $TMP_QCOW2 (${DISK_SIZE_GB}G)"

# ---------------------------------------------------------------
# Phase 5: nbd module + qemu-nbd --connect.
# ---------------------------------------------------------------
if ! lsmod 2>/dev/null | grep -q '^nbd '; then
  echo "[build-reproos-image] modprobe nbd max_part=16"
  "$SUDO" modprobe nbd max_part=16 \
    || { echo "[build-reproos-image] modprobe nbd failed" >&2; exit 68; }
fi
# Find a free /dev/nbdN.
NBD_DEV=""
for n in 0 1 2 3 4 5 6 7; do
  cand="/dev/nbd$n"
  if [ ! -e "$cand" ]; then continue; fi
  # /sys/block/nbdN/pid exists iff the device is in use.
  if [ -f "/sys/block/nbd$n/pid" ]; then continue; fi
  NBD_DEV="$cand"
  break
done
if [ -z "$NBD_DEV" ]; then
  echo "[build-reproos-image] no free /dev/nbdN available" >&2
  exit 68
fi
echo "[build-reproos-image] qemu-nbd --connect=$NBD_DEV $TMP_QCOW2"
"$SUDO" qemu-nbd --connect="$NBD_DEV" "$TMP_QCOW2" \
  || { echo "[build-reproos-image] qemu-nbd connect failed" >&2; exit 68; }
NBD_CONNECTED=1

# Patch the disko JSON to point at the actual nbd device.
sed -i "s|/dev/nbd0|$NBD_DEV|g" "$DISKO_JSON"

# Wait for the kernel to scan the (empty) partition table.
"$SUDO" partprobe "$NBD_DEV" 2>/dev/null || true
sleep 2

# ---------------------------------------------------------------
# Phase 6: repro disk apply.
#
# Pass LD_LIBRARY_PATH explicitly through sudo because the repro
# binary dlopen()s libclingo.so via the env (the M9.R.46 clingo
# .rodata-bake issue) and sudo strips LD_LIBRARY_PATH by default
# under secure_path policy.  `sudo -E` would propagate the entire
# env but env_keep blocks LD_*; `env VAR=... sudo ...` propagates
# only the var we ask for.
# ---------------------------------------------------------------
echo "[build-reproos-image] repro disk apply --device $NBD_DEV --confirm $DISKO_JSON"
"$SUDO" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$REPRO_BIN" disk apply --device "$NBD_DEV" --confirm "$DISKO_JSON" \
  || { echo "[build-reproos-image] disk apply failed" >&2; exit 69; }

# Re-scan the partition table.
"$SUDO" partprobe "$NBD_DEV" 2>/dev/null || true
sleep 2

# ---------------------------------------------------------------
# Phase 7: mount the partitions.
#
# With our GPT layout the ESP is partition 1, root is partition 2.
# qemu-nbd exposes them as ${NBD_DEV}p1, ${NBD_DEV}p2.
# ---------------------------------------------------------------
ESP_DEV="${NBD_DEV}p1"
ROOT_DEV="${NBD_DEV}p2"

# Wait for the partition device nodes to appear.
for i in 1 2 3 4 5; do
  if [ -b "$ROOT_DEV" ] && [ -b "$ESP_DEV" ]; then break; fi
  sleep 1
done
if [ ! -b "$ROOT_DEV" ] || [ ! -b "$ESP_DEV" ]; then
  echo "[build-reproos-image] expected partition nodes did not appear: $ESP_DEV $ROOT_DEV" >&2
  exit 69
fi

"$SUDO" mount "$ROOT_DEV" "$MNT_DIR" \
  || { echo "[build-reproos-image] mount root failed" >&2; exit 69; }
MOUNTED_PATHS+=("$MNT_DIR")
"$SUDO" mkdir -p "$MNT_DIR/boot"
"$SUDO" mount "$ESP_DEV" "$MNT_DIR/boot" \
  || { echo "[build-reproos-image] mount esp failed" >&2; exit 69; }
MOUNTED_PATHS+=("$MNT_DIR/boot")

# ---------------------------------------------------------------
# Phase 8: repro infra install-root.
#
# --source = the staged Nix-style tree (NOT the live host root)
# --target = our mount point
# --device = the nbd device for grub-install
# --disko  = our generated json
# --hostname = from TOML
# ---------------------------------------------------------------
echo "[build-reproos-image] repro infra install-root --target $MNT_DIR --source $STAGE_DIR --device $NBD_DEV"
"$SUDO" LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$REPRO_BIN" infra install-root \
  --target "$MNT_DIR" \
  --source "$STAGE_DIR" \
  --device "$NBD_DEV" \
  --disko "$DISKO_JSON" \
  --hostname "$HOSTNAME_VAL" \
  || { echo "[build-reproos-image] install-root failed" >&2; exit 70; }

# M9.R.51: rewrite build-time NBD device paths to boot-time virtio
# paths.  install-root's renderInstalledGrubCfg + renderFstab bake
# $NBD_DEV (e.g. /dev/nbd0p2) into grub.cfg's root= and fstab's
# device columns.  At boot, the disk appears as /dev/vda under
# QEMU virtio.  Substitute NBD -> VDA post-render.  A future
# milestone will move this into the render functions themselves
# (parameterize via env or emit LABEL=/UUID= from mkfs.ext4 -L).
NBD_BASE="$(basename "$NBD_DEV")"       # e.g. nbd0
BOOT_DEV_BASE="vda"
echo "[build-reproos-image] rewriting $NBD_BASE -> $BOOT_DEV_BASE in grub.cfg + fstab"
for f in "$MNT_DIR/boot/grub/grub.cfg" "$MNT_DIR/etc/fstab"; do
  if [ -f "$f" ]; then
    "$SUDO" sed -i -E "s|/dev/${NBD_BASE}p([0-9]+)|/dev/${BOOT_DEV_BASE}\\1|g; s|/dev/${NBD_BASE}|/dev/${BOOT_DEV_BASE}|g" "$f"
  fi
done

# ---------------------------------------------------------------
# Phase 9: write etc/repro/{system,hardware}.nim from TOML.
# Skipped for v1; install-root already wrote a baseline copy from
# /etc/repro/ in the source tree.  Future M9.R.50.x will render
# DSL-shaped system.nim from auto-config.toml.
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# Phase 10: write /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow
# user entries + create home directory.
#
# M9.R.56.3 — the M9.R.50 emit only wrote /etc/shadow, so at first
# boot the account had a hashed password on file but no /etc/passwd
# entry (no uid, no home, no shell), and no /etc/group membership.
# ``login: repro`` then failed with ``no such user`` and the system
# fell back to the emergency shell (which prompts for root password
# — root has ``*`` in shadow so no login possible).  We now emit
# all four files.  The uid/gid are pinned to 1000/1000 (first
# non-system id per LSB); the primary group matches ``$USER_NAME``;
# secondary groups come from the TOML ``[user] groups`` array (falls
# back to wheel+audio+video, matching M9.R.50 fixture defaults).
# ---------------------------------------------------------------

# Parse the TOML ``[user] groups`` array.  toml_get returns the raw
# array text (e.g. ``["wheel", "audio", "video"]``); strip brackets +
# whitespace + quotes to get a comma-separated list.
USER_GROUPS_RAW="$(toml_get "$CFG" "user" "groups" || true)"
USER_GROUPS_RAW="${USER_GROUPS_RAW:-[wheel, audio, video]}"
USER_GROUPS="$(echo "$USER_GROUPS_RAW" | sed -E 's/^\[//; s/\]$//; s/"//g; s/ //g')"
# Convert commas to spaces for iteration.
USER_GROUPS_SPACED="$(echo "$USER_GROUPS" | tr ',' ' ')"

USER_UID=1000
USER_GID=1000
USER_HOME="/home/$USER_NAME"

echo "[build-reproos-image] Phase 10: emit passwd + shadow + group + gshadow + home for $USER_NAME (uid=$USER_UID gid=$USER_GID groups='$USER_GROUPS_SPACED')"

"$SUDO" bash -c "
  set -euo pipefail

  # --- /etc/shadow --- (root + user entries).  Preserve any prior
  # rows (e.g. from the stage-de-rootfs Debian base + ``live`` user).
  # M9.R.56.6: also remove any row whose uid collides with the
  # target uid; the stage-de-rootfs baseline ships a ``live`` user
  # at uid=1000 which collides with the auto-config ``repro`` user
  # at uid=1000 --- with both entries present nss lookups for uid
  # 1000 resolve non-deterministically (typically to ``live``) and
  # SDDM's autologin=User=repro fails to find a match.
  if [ ! -f '$MNT_DIR/etc/shadow' ]; then
    echo 'root:*:19000:0:99999:7:::' > '$MNT_DIR/etc/shadow'
  fi
  awk -v u='$USER_NAME' -F: '\$1 != u' '$MNT_DIR/etc/shadow' > '$MNT_DIR/etc/shadow.new'
  echo '$USER_NAME:$USER_PWHASH:19000:0:99999:7:::' >> '$MNT_DIR/etc/shadow.new'
  mv '$MNT_DIR/etc/shadow.new' '$MNT_DIR/etc/shadow'
  chmod 0640 '$MNT_DIR/etc/shadow'
  chown root:root '$MNT_DIR/etc/shadow' 2>/dev/null || true

  # --- /etc/passwd --- (user entry with $USER_HOME + $USER_SHELL).
  if [ ! -f '$MNT_DIR/etc/passwd' ]; then
    echo 'root:x:0:0:root:/root:/bin/bash' > '$MNT_DIR/etc/passwd'
  fi
  # Drop any row matching either the target USER_NAME OR the target USER_UID
  # (M9.R.56.6 UID-collision cleanup) --- the stage baseline live user shares
  # uid=1000 with our repro user and shadows autologin.
  awk -v u='$USER_NAME' -v uid='$USER_UID' -F: '\$1 != u && \$3 != uid' '$MNT_DIR/etc/passwd' > '$MNT_DIR/etc/passwd.new'
  echo '$USER_NAME:x:$USER_UID:$USER_GID::$USER_HOME:$USER_SHELL' >> '$MNT_DIR/etc/passwd.new'
  mv '$MNT_DIR/etc/passwd.new' '$MNT_DIR/etc/passwd'
  chmod 0644 '$MNT_DIR/etc/passwd'

  # Also drop the ``live`` shadow row (matches the ``live`` passwd row we
  # removed above; nss keeps them in lock-step, and dpkg-triggered
  # tools scan shadow via getent).
  awk -v u='$USER_NAME' -F: '\$1 != u && \$1 != \"live\"' '$MNT_DIR/etc/shadow' > '$MNT_DIR/etc/shadow.new2'
  echo '$USER_NAME:$USER_PWHASH:19000:0:99999:7:::' >> '$MNT_DIR/etc/shadow.new2'
  mv '$MNT_DIR/etc/shadow.new2' '$MNT_DIR/etc/shadow'
  chmod 0640 '$MNT_DIR/etc/shadow'
  chown root:root '$MNT_DIR/etc/shadow' 2>/dev/null || true

  # --- /etc/group --- (primary group + secondary group memberships).
  # Primary group: $USER_NAME with gid $USER_GID.
  if [ ! -f '$MNT_DIR/etc/group' ]; then
    echo 'root:x:0:' > '$MNT_DIR/etc/group'
  fi
  # Remove any pre-existing entry for the primary group, then re-add.
  awk -v g='$USER_NAME' -F: '\$1 != g' '$MNT_DIR/etc/group' > '$MNT_DIR/etc/group.new'
  echo '$USER_NAME:x:$USER_GID:' >> '$MNT_DIR/etc/group.new'
  # Add user to each secondary group (append user to member list;
  # create group with gid+100 if it doesn't exist).
  next_gid=1001
  for g in $USER_GROUPS_SPACED; do
    [ -z \"\$g\" ] && continue
    if grep -qE \"^\$g:\" '$MNT_DIR/etc/group.new'; then
      # Group exists: append user to member list if not already there.
      awk -v g=\"\$g\" -v u='$USER_NAME' -F: 'BEGIN{OFS=\":\"} { if (\$1==g) { if (\$4==\"\") { \$4=u } else if (index(\$4,u)==0) { \$4=\$4\",\"u } } print }' '$MNT_DIR/etc/group.new' > '$MNT_DIR/etc/group.new2'
      mv '$MNT_DIR/etc/group.new2' '$MNT_DIR/etc/group.new'
    else
      # Group missing: create with next available gid.
      echo \"\$g:x:\$next_gid:$USER_NAME\" >> '$MNT_DIR/etc/group.new'
      next_gid=\$((next_gid+1))
    fi
  done
  mv '$MNT_DIR/etc/group.new' '$MNT_DIR/etc/group'
  chmod 0644 '$MNT_DIR/etc/group'

  # --- /etc/gshadow --- (shadow-group entries; NSS wants matching).
  if [ ! -f '$MNT_DIR/etc/gshadow' ]; then
    echo 'root:*::' > '$MNT_DIR/etc/gshadow'
  fi
  awk -v g='$USER_NAME' -F: '\$1 != g' '$MNT_DIR/etc/gshadow' > '$MNT_DIR/etc/gshadow.new'
  echo '$USER_NAME:!::' >> '$MNT_DIR/etc/gshadow.new'
  for g in $USER_GROUPS_SPACED; do
    [ -z \"\$g\" ] && continue
    if grep -qE \"^\$g:\" '$MNT_DIR/etc/gshadow.new'; then
      continue
    fi
    echo \"\$g:!::$USER_NAME\" >> '$MNT_DIR/etc/gshadow.new'
  done
  mv '$MNT_DIR/etc/gshadow.new' '$MNT_DIR/etc/gshadow'
  chmod 0640 '$MNT_DIR/etc/gshadow'

  # --- /home/\$USER_NAME --- (chown uid:gid so first login has a
  # writeable home).
  mkdir -p '$MNT_DIR$USER_HOME'
  chown $USER_UID:$USER_GID '$MNT_DIR$USER_HOME'
  chmod 0755 '$MNT_DIR$USER_HOME'
" || { echo "[build-reproos-image] passwd/shadow/group emit failed" >&2; exit 71; }

# Make sure the hostname file matches the TOML value (install-root
# already wrote one but the TOML may differ from the default).
"$SUDO" bash -c "echo '$HOSTNAME_VAL' > '$MNT_DIR/etc/hostname'" || true

# ---------------------------------------------------------------
# Phase 10.5: wire the default systemd target + display-manager +
# SDDM autologin for the installed system.
#
# M9.R.56.4 — the stage-de-rootfs.sh baseline sets
# ``default.target -> multi-user.target`` (console mode) and
# writes an SDDM autologin config for the LIVE ISO (User=live,
# Session=reproos-installer), then overlays those into the staged
# tree.  On the INSTALLED disk we need the graphical target + a
# per-user SDDM autologin per ``[de] default`` + ``[user] name``
# from auto-config.toml.
#
# ``[de] default`` values (validated at Phase 1):
#   sway         -> Session=sway
#   kwin         -> Session=plasma (kwin_wayland runs under plasma)
#   mutter       -> Session=gnome
#   plasmashell  -> Session=plasma
#   sddm         -> Session=sway (fallback -- SDDM is not itself a
#                    session; treat as "graphical with default sway")
# ---------------------------------------------------------------

case "$DE_DEFAULT" in
  sway)         SDDM_SESSION="sway" ;;
  kwin)         SDDM_SESSION="plasma" ;;
  mutter)       SDDM_SESSION="gnome" ;;
  plasmashell)  SDDM_SESSION="plasma" ;;
  sddm)         SDDM_SESSION="sway" ;;
  *)            SDDM_SESSION="sway" ;;
esac

echo "[build-reproos-image] Phase 10.5: wire graphical target + sddm autologin (session=$SDDM_SESSION user=$USER_NAME)"

"$SUDO" bash -c "
  set -euo pipefail

  # Swap default.target to graphical.target (from-source-built
  # graphical.target is present at /usr/lib/systemd/system/).
  mkdir -p '$MNT_DIR/etc/systemd/system'
  if [ -e '$MNT_DIR/usr/lib/systemd/system/graphical.target' ] \\
      || [ -e '$MNT_DIR/lib/systemd/system/graphical.target' ]; then
    ln -sfn /usr/lib/systemd/system/graphical.target \\
      '$MNT_DIR/etc/systemd/system/default.target'
  else
    echo '[build-reproos-image] warning: graphical.target not found in installed rootfs -- staying at multi-user.target' >&2
  fi

  # Wire display-manager.service to sddm (from-source-built sddm.service
  # was installed to /usr/lib/systemd/system/sddm.service by the
  # from-source sddm recipe's install-mirror overlay).
  if [ -e '$MNT_DIR/usr/lib/systemd/system/sddm.service' ] \\
      || [ -e '$MNT_DIR/lib/systemd/system/sddm.service' ]; then
    ln -sfn /usr/lib/systemd/system/sddm.service \\
      '$MNT_DIR/etc/systemd/system/display-manager.service'
    # Enable at graphical.target.
    mkdir -p '$MNT_DIR/etc/systemd/system/graphical.target.wants'
    ln -sfn /usr/lib/systemd/system/sddm.service \\
      '$MNT_DIR/etc/systemd/system/graphical.target.wants/sddm.service'
  else
    echo '[build-reproos-image] warning: sddm.service not found in installed rootfs' >&2
  fi

  # SDDM autologin config: point at the per-TOML user + session,
  # replacing the stage-de-rootfs.sh live-ISO default (User=live,
  # Session=reproos-installer).
  mkdir -p '$MNT_DIR/etc/sddm.conf.d'
  cat > '$MNT_DIR/etc/sddm.conf.d/00-autologin.conf' <<SDDM_EOF
[Autologin]
User=$USER_NAME
Session=$SDDM_SESSION
Relogin=true

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
SDDM_EOF

  # Disable the reproos-installer-autorun.service unit -- it only
  # belongs on the LIVE ISO where the installer needs to run.
  rm -f '$MNT_DIR/etc/systemd/system/multi-user.target.wants/reproos-installer-autorun.service' \\
        '$MNT_DIR/etc/systemd/system/graphical.target.wants/reproos-installer-autorun.service' \\
        2>/dev/null || true

  # M9.R.56.6: strip the live-ISO tty1 autologin drop-in --- the
  # installed disk should not auto-login as root on the text
  # console (the graphical session via SDDM/autologin is where
  # the user lands).  Without this the getty@tty1 unit is racing
  # with sddm.service both trying to own vt1 depending on which
  # gets ahead in unit ordering.
  rm -rf '$MNT_DIR/etc/systemd/system/getty@tty1.service.d' 2>/dev/null || true
" || { echo "[build-reproos-image] display-manager wiring failed" >&2; exit 71; }

# ---------------------------------------------------------------
# Phase 10.6: close dbus.service boot-blockers so the D-Bus system
# bus can start (M9.R.56.4 + M9.R.56.5).
#
# Post-M9.R.56.3 the from-source dbus binary + libdbus + system.conf
# are present at the expected FHS paths, but three latent bugs from
# the Debian base rootfs + the install-mirror layout still prevent
# dbus.service from reaching notify-ready:
#
#   Blocker 1 (runtime dir):  the Debian dbus.service unit lacks
#     ``RuntimeDirectory=dbus``.  dbus-daemon fails with
#     ``Failed to bind socket "/run/dbus/system_bus_socket": No
#     such file or directory`` because /run/dbus doesn't exist and
#     nothing creates it at unit start.  Fix: drop-in override that
#     adds ``RuntimeDirectory=dbus`` (systemd creates
#     /run/dbus/ with mode 0755 before ExecStart).
#
#   Blocker 2 (Debian gdm.conf):  the Debian base rootfs ships
#     /etc/dbus-1/system.d/gdm.conf with ``<policy user="gdm">``.
#     dbus-daemon parses every *.conf in system.d/ at startup and
#     rejects the whole config file when the user is undefined
#     (``Unknown username "gdm" in message bus configuration
#     file``).  We use SDDM not GDM so removing gdm.conf is the
#     correct cleanup; a future GDM-first config can drop it back
#     in via the polkit / dconf split we already ship for KDE.
#
#   Blocker 3 (dbus-daemon-launch-helper):  the from-source dbus
#     ships /usr/libexec/dbus-daemon-launch-helper (a setuid helper
#     the daemon exec()'s for privileged bus-activation), but
#     stage-de-rootfs.sh's ``link_base_recipe_binaries`` only
#     shadow-links ``usr/{bin,sbin}`` from-source binaries, NOT
#     ``usr/libexec/``.  Add a shadow-link at
#     /usr/libexec/dbus-daemon-launch-helper -> install-mirror.
#
# Blocker 4 (falsified):  the LIBDBUS_PRIVATE_1.16.0 warning
# printed at exec time by ld.so is a NON-FATAL diagnostic caused
# by Debian's /etc/ld.so.cache holding a stale entry for the older
# Debian /lib/x86_64-linux-gnu/libdbus-1.so.3 (verified by
# LD_DEBUG=libs: after the warning ld.so falls through to the
# from-source libdbus at
# /opt/repro/reprobuild/.../install/usr/lib/libdbus-1.so.3 via
# dbus-daemon's RUNPATH and completes the load).  The daemon
# succeeds after the warning; the warning is a v2 cleanup.
# ---------------------------------------------------------------

echo "[build-reproos-image] Phase 10.6: wire dbus RuntimeDirectory + strip gdm.conf + shadow-link libexec helper + replace ExecStart"

"$SUDO" bash -c "
  set -euo pipefail

  # Blocker 1 --- drop-in override adding RuntimeDirectory=dbus.
  mkdir -p '$MNT_DIR/etc/systemd/system/dbus.service.d'
  cat > '$MNT_DIR/etc/systemd/system/dbus.service.d/10-runtime-dir.conf' <<'DBUS_DROPIN_EOF'
[Service]
RuntimeDirectory=dbus
RuntimeDirectoryMode=0755
DBUS_DROPIN_EOF

  # Blocker 2 --- remove Debian's gdm.conf (references undefined gdm user).
  rm -f '$MNT_DIR/etc/dbus-1/system.d/gdm.conf'

  # Blocker 3 --- shadow-link the setuid dbus-daemon-launch-helper from
  # the from-source install-mirror so ExecStart's fork() finds it at
  # /usr/libexec/dbus-daemon-launch-helper.
  mkdir -p '$MNT_DIR/usr/libexec'
  ln -sfn /opt/repro/reprobuild/recipes/packages/source/dbus/.repro/output/install/usr/libexec/dbus-daemon-launch-helper \\
    '$MNT_DIR/usr/libexec/dbus-daemon-launch-helper'

  # Blocker 5 (M9.R.56.5) --- the from-source dbus 1.16.0 recipe does
  # NOT enable the meson systemd option (\`\`-Dsystemd=enabled\`\`), so
  # dbus-daemon is compiled without libsystemd support and rejects
  # \`\`--systemd-activation\`\` with \`\`Failed to start message bus: dbus
  # was compiled without systemd support\`\`.  Falsified by injecting a
  # diag unit that runs dbus-daemon manually: variant without
  # \`\`--systemd-activation\`\` runs fine (test1=RUNNING); variant with
  # \`\`--systemd-activation\`\` exits with the compile-support error
  # (test3 stderr).  Also confirmed via readelf: from-source
  # \`\`libdbus-1.so.3.38.3\`\` has NO NEEDED entry for libsystemd.so.0.
  #
  # Fix at v1: override the ExecStart to drop \`\`--systemd-activation\`\`
  # + \`\`--address=systemd:\`\` and switch Type=notify -> Type=simple so
  # systemd doesn't wait for a sd_notify() dbus-daemon can't emit.
  # dbus-daemon then listens on the default /run/dbus/system_bus_socket
  # (which matches dbus.socket's ListenStream anyway).  Type=simple
  # means the unit is Active as soon as the process is running; the
  # Debian unit's TriggeredBy=dbus.socket already gives the correct
  # ordering.  Once the from-source dbus recipe is rebuilt with
  # \`\`-Dsystemd=enabled\`\` we can drop the ExecStart override; the
  # RuntimeDirectory drop-in stays.
  cat > '$MNT_DIR/etc/systemd/system/dbus.service.d/20-no-systemd-activation.conf' <<'DBUS_EXEC_EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile --syslog-only
DBUS_EXEC_EOF
" || { echo "[build-reproos-image] Phase 10.6 dbus wiring failed" >&2; exit 72; }

# ---------------------------------------------------------------
# Phase 10.7 (M9.R.56.7): install a minimal SDDM theme.
#
# The from-source sddm recipe install-mirror ships ONLY the sddm
# binary + libexec helpers; NO themes.  The Debian sddm dpkg
# entry ships /usr/share/sddm/{faces,scripts,flags,translations-qt6}
# but NO themes/ directory.  SDDM's default ``Theme=`` in
# /etc/sddm.conf.d and the greeter's fallback path both expect
# /usr/share/sddm/themes/<name>/Main.qml.  Without one, SDDM's
# greeter renders a blank/black QQuickWindow --- verified in
# M9.R.56.6 boot smoke where all 6 t={0..165}s screendumps are
# 1280x800 grayscale mean=0.
#
# The minimal theme below is a bare-bones QML that just fills
# the window in a solid gray with the "reproos" text --- enough
# to prove the greeter renders SOMETHING, so that on subsequent
# iterations (M9.R.56.8+) we know if SDDM's autologin is firing
# (screen goes to sway session) or falling back to greeter (screen
# stays at gray+text).  A full theme lands with the sddm recipe
# rework in M9.R.57+.
# ---------------------------------------------------------------

echo "[build-reproos-image] Phase 10.7: install minimal SDDM theme /usr/share/sddm/themes/reproos"

"$SUDO" bash -c "
  set -euo pipefail
  mkdir -p '$MNT_DIR/usr/share/sddm/themes/reproos'
  cat > '$MNT_DIR/usr/share/sddm/themes/reproos/metadata.desktop' <<'THEME_META_EOF'
[SddmGreeterTheme]
Name=reproos
Description=ReproOS minimal SDDM theme
Author=reprobuild
Copyright=(c) 2026 Metacraft Labs
License=MIT
Type=sddm-theme
Version=1.0
Website=https://github.com/metacraft-labs/reprobuild
Screenshot=
MainScript=Main.qml
ConfigFile=theme.conf
Theme-Id=reproos
Theme-API=2.0

THEME_META_EOF
  cat > '$MNT_DIR/usr/share/sddm/themes/reproos/Main.qml' <<'THEME_QML_EOF'
import QtQuick 2.15

Rectangle {
  id: root
  width: 1920
  height: 1080
  color: '#1a1a2e'
  Text {
    anchors.centerIn: parent
    color: 'white'
    font.pixelSize: 48
    text: 'reproos'
  }
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.verticalCenter
    anchors.topMargin: 60
    color: '#aaaaaa'
    font.pixelSize: 18
    text: 'M9.R.56.7 minimal greeter'
  }
}
THEME_QML_EOF
  cat > '$MNT_DIR/usr/share/sddm/themes/reproos/theme.conf' <<'THEME_CONF_EOF'
[General]
background=
type=color
color=#1a1a2e
THEME_CONF_EOF

  # Wire /etc/sddm.conf to select the reproos theme.  We layer
  # over the existing /etc/sddm.conf.d/ dir (already contains
  # 00-autologin.conf from Phase 10.5) so the [Autologin] section
  # stays intact.
  cat > '$MNT_DIR/etc/sddm.conf.d/05-theme.conf' <<'SDDM_THEME_EOF'
[Theme]
Current=reproos
SDDM_THEME_EOF
" || { echo "[build-reproos-image] Phase 10.7 sddm theme install failed" >&2; exit 73; }

# ---------------------------------------------------------------
# Phase 10.8 (M9.R.56.8.1): fix compiled-in /usr/local paths in
# the from-source sddm binary + install strace instrumentation
# for the sddm session-launch chain.
#
# ## Diagnosis (Phase A — static, per feedback_mcr_no_speculation)
#
# The from-source sddm 0.21 recipe (recipes/packages/source/sddm/
# repro.nim) does NOT set ``CMAKE_INSTALL_PREFIX`` in its
# ``cmakeFlags:`` block, so CMake defaults to
# ``/usr/local``.  The prefix bakes into the generated
# ``src/common/Constants.h`` (Constants.h.in is templated with
# ``@CMAKE_INSTALL_FULL_LIBEXECDIR@`` etc.), which the sddm
# daemon then references via ``QStringLiteral`` at every session-
# launch and theme-load site:
#
#   #define LIBEXEC_INSTALL_DIR     "/usr/local/libexec"
#   #define DATA_INSTALL_DIR        "/usr/local/share/sddm"
#   #define SESSION_COMMAND         "/usr/local/share/sddm/scripts/Xsession"
#   #define WAYLAND_SESSION_COMMAND "/usr/local/share/sddm/scripts/wayland-session"
#   #define SYSTEM_CONFIG_DIR       "/usr/local/lib/sddm/sddm.conf.d"
#
# Real files ship at:
#   /usr/libexec/sddm-helper                       (from-source install-mirror)
#   /usr/libexec/sddm-helper-start-wayland          (from-source install-mirror)
#   /usr/libexec/sddm-helper-start-x11user          (from-source install-mirror)
#   /usr/share/sddm/scripts/{wayland-session,Xsession,Xsetup,Xstop} (Debian dpkg)
#   /usr/share/sddm/{faces,flags,translations-qt6} (Debian dpkg)
#   /usr/share/sddm/themes/reproos/Main.qml         (Phase 10.7)
#
# Consequences the M9.R.56.7 evidence hit:
#   * Autologin succeeds via PAM (sddm-autologin PAM stack is
#     complete) but the ``sddm-helper`` exec at
#     ``/usr/local/libexec/sddm-helper`` errors ENOENT --- the
#     user session never spawns.
#   * Greeter mode (non-autologin) loads the ``Theme.ThemeDir``
#     default ``/usr/local/share/sddm/themes`` which does not
#     exist; the QQuickWindow falls back to a blank/black surface.
#     This exactly matches the M9.R.56.7 mean-grayscale=0 PPM.
#   * Wayland compositor spawn also fails --- the daemon exec()s
#     ``/usr/local/share/sddm/scripts/wayland-session <sway.desktop-Exec>``
#     but the wayland-session script is not at that path.
#
# Cascade class: install-prefix baked into a compile-time
# constant.  The proper fix is to rebuild sddm with the correct
# CMake flags (documented as a residual for M9.R.57+); the
# image-time fix in this milestone uses shadow-link symlinks in
# the same pattern as Phase 10.6 Blocker 3 (the
# dbus-daemon-launch-helper shim) --- ``/usr/local/libexec ->
# /usr/libexec`` and ``/usr/local/share/sddm -> /usr/share/sddm``.
#
# The ``[Theme] ThemeDir`` / ``[X11] SessionCommand`` /
# ``[Wayland] SessionCommand`` config overrides layered under
# /etc/sddm.conf.d/10-paths.conf are belt-and-suspenders: they
# route the Config-file overridable paths at /usr/share instead of
# /usr/local, so if a future refactor moves sddm to a proper
# CMAKE_INSTALL_PREFIX=/usr build the shim symlinks become
# no-ops and the config overrides pin the correct paths.
#
# ## Instrumentation
#
# We wrap sddm's ExecStart with strace -f piping to
# /var/log/m9r56_diag/sddm-strace.log and dump the sddm
# journal to /var/log/m9r56_diag/sddm-journal.txt via a
# one-shot post-boot unit.  A future M9.R.56.9 can inspect the
# diag files by mounting the resulting qcow2 nbd.
# ---------------------------------------------------------------

echo "[build-reproos-image] Phase 10.8: shim compiled-in /usr/local sddm paths + install strace instrumentation"

"$SUDO" bash -c "
  set -euo pipefail

  # --- Path shims for compiled-in Constants.h defines ---
  # M9.R.56.8.2: point directly at the from-source install-mirror
  # under /opt/repro/reprobuild.  stage-de-rootfs.sh's
  # ``link_base_recipe_binaries`` shadow-links only ``usr/{bin,
  # sbin}`` from the install-mirror --- ``usr/libexec/`` is NOT
  # shadow-linked (same finding as Phase 10.6 Blocker 3 for
  # dbus-daemon-launch-helper).  We therefore link
  # /usr/local/libexec/<helper> DIRECTLY at
  # /opt/repro/reprobuild/recipes/packages/source/sddm/.repro/output/install/usr/libexec/<helper>
  # rather than via /usr/libexec/<helper> (which does not exist
  # on the installed disk).
  #
  # This matches Phase 10.6 Blocker 3's dbus-daemon-launch-helper
  # shim exactly.  A future stage-de-rootfs.sh pass that shadow-
  # links usr/libexec/ from every from-source install-mirror
  # would let this collapse to ``ln -sfn /usr/libexec/<helper>``
  # (a single-hop symlink), but that broader shadow-link rework
  # belongs in M9.R.57+ with the sddm-recipe CMAKE_INSTALL_PREFIX
  # fix.
  mkdir -p '$MNT_DIR/usr/local/libexec'
  SDDM_INSTALL_LIBEXEC=/opt/repro/reprobuild/recipes/packages/source/sddm/.repro/output/install/usr/libexec
  for helper in sddm-helper sddm-helper-start-wayland sddm-helper-start-x11user; do
    ln -sfn \"\$SDDM_INSTALL_LIBEXEC/\$helper\" \"$MNT_DIR/usr/local/libexec/\$helper\"
  done

  # Also shadow-link /usr/libexec/<helper> so any code path that
  # references /usr/libexec/sddm-helper directly (e.g. the
  # /etc/sddm.conf.d/10-paths.conf overrides below, or a rebuilt
  # sddm binary with CMAKE_INSTALL_PREFIX=/usr) resolves too.
  mkdir -p '$MNT_DIR/usr/libexec'
  for helper in sddm-helper sddm-helper-start-wayland sddm-helper-start-x11user; do
    ln -sfn \"\$SDDM_INSTALL_LIBEXEC/\$helper\" \"$MNT_DIR/usr/libexec/\$helper\"
  done

  # /usr/local/share/sddm -> /usr/share/sddm as a full dir
  # symlink so the daemon finds themes, faces, scripts, and
  # translations at their compiled-in DATA_INSTALL_DIR.
  mkdir -p '$MNT_DIR/usr/local/share'
  ln -sfn /usr/share/sddm '$MNT_DIR/usr/local/share/sddm'

  # M9.R.56.8.3: shim /usr/local/bin/sddm-greeter-qt6.  sddm's
  # daemon.Greeter.cpp computes the greeter argv as
  # ``QStringLiteral(BIN_INSTALL_DIR \"/sddm-greeter%1\").arg(suffix)``
  # which bakes to ``/usr/local/bin/sddm-greeter-qt6``.  Point at
  # the from-source install-mirror greeter binary directly (the
  # image's /usr/bin/sddm-greeter-qt6 is already a shadow-link
  # to the same install-mirror path via stage-de-rootfs.sh's
  # link_base_recipe_binaries, so pointing at the install-mirror
  # is equivalent and avoids a two-hop symlink).
  mkdir -p '$MNT_DIR/usr/local/bin'
  ln -sfn /opt/repro/reprobuild/recipes/packages/source/sddm/.repro/output/install/usr/bin/sddm-greeter-qt6 \\
    '$MNT_DIR/usr/local/bin/sddm-greeter-qt6'
  ln -sfn /opt/repro/reprobuild/recipes/packages/source/sddm/.repro/output/install/usr/bin/sddm \\
    '$MNT_DIR/usr/local/bin/sddm'

  # M9.R.56.8.3: shim /lib/security -> from-source pam's install-
  # mirror.  libpam.so.0 from the pam recipe (linked by
  # sddm-helper via RUNPATH) has compiled-in module search path
  # /lib/security/ (verified via ``strings libpam.so.0``).  The
  # from-source pam recipe installs modules at
  # /opt/repro/reprobuild/recipes/packages/source/pam/.repro/output/install/usr/lib/security/
  # but that path is not shadow-linked into /lib/security/ by
  # stage-de-rootfs.sh.  Debian's PAMs at
  # /usr/lib/x86_64-linux-gnu/security/ are ABI-compatible but
  # linked against Debian's libpam.so.0.85.1 (older), so we
  # point at the from-source install-mirror to keep the ABI
  # matched with the sddm-helper's linked libpam.
  #
  # We link the whole /lib/security dir at the pam install-
  # mirror's usr/lib/security subtree.
  mkdir -p '$MNT_DIR/lib'
  ln -sfn /opt/repro/reprobuild/recipes/packages/source/pam/.repro/output/install/usr/lib/security \\
    '$MNT_DIR/lib/security'

  # M9.R.56.8.4: strip pam_selinux.so references from the sddm
  # PAM config files.  The from-source pam recipe does NOT
  # build pam_selinux.so (it's a separate libselinux-dependent
  # module).  The Debian sddm-autologin + sddm-greeter PAM config
  # references pam_selinux.so with control ``[success=ok
  # ignore=ignore module_unknown=ignore default=bad]``; the
  # ``module_unknown=ignore`` semantic SHOULD skip a missing
  # module, but the actual libpam-1.5 pam_start()
  # implementation treats a file-not-found dlopen error
  # differently from a module_unknown case: it silently falls
  # through to /etc/pam.d/other for the affected phase.
  # /etc/pam.d/other's @include common-auth uses pam_unix.so
  # nullok --- with autologin (no password supplied), pam_unix
  # returns PAM_AUTH_ERR, and sddm-helper logs the resulting
  # ``PAM_PERM_DENIED`` as ``Permission denied`` (verified in
  # /var/log/sddm.log from the M9.R.56.8.3 boot smoke).
  #
  # Fix: use sed to comment out every ``pam_selinux.so`` line
  # in the two sddm PAM configs.  We use ONLY sed --- no
  # rewriting the file --- so any future Debian sddm dpkg
  # update to the PAM config gets picked up (except the
  # pam_selinux comment).  ReproOS does not ship SELinux;
  # stripping the module is safe.
  #
  # A future M9.R.57+ can either (a) build pam_selinux from
  # libselinux via a proper from-source module or (b) patch
  # pam_start()'s file-not-found path to honour
  # module_unknown=ignore.
  for f in '$MNT_DIR/etc/pam.d/sddm' '$MNT_DIR/etc/pam.d/sddm-autologin' '$MNT_DIR/etc/pam.d/sddm-greeter'; do
    [ -f \"\$f\" ] || continue
    sed -i 's|^\\(.*pam_selinux.so.*\\)\$|# M9.R.56.8.4 stripped: \\1|' \"\$f\"
  done

  # M9.R.56.8.5: replace the sddm-autologin + sddm-greeter PAM
  # config files with MINIMAL configs that only reference the
  # from-source PAM modules we know are available.  Empirical
  # evidence from the M9.R.56.8.4 boot smoke (/var/log/sddm.log):
  #
  #   [PAM] Authenticating...
  #   [PAM] authenticate: Permission denied
  #
  # even AFTER stripping pam_selinux.so and confirming pam_nologin
  # + pam_permit + pam_keyinit + pam_limits + pam_loginuid +
  # pam_env dlopen successfully.  libpam1.6.1's pam_dispatch.c
  # returns PAM_PERM_DENIED (== PAM_MUST_FAIL_CODE) when
  # \`\`no modules loaded for '<service>' service\`\`.  That means
  # the config file parse failed silently somewhere in the
  # @include common-* chain --- either a common-* file references
  # a module the from-source pam recipe doesnt ship (pam_cap.so,
  # pam_deny.so's specific path, pam_unix.so's Debian
  # multiarch quirk...) OR the from-source pam has a config-
  # parse regression against Debians @include semantics.
  #
  # The minimal configs below drop every @include and reference
  # ONLY: pam_nologin, pam_permit, pam_limits, pam_loginuid,
  # pam_keyinit, pam_env, pam_unix --- all confirmed present at
  # /lib/security/ from the from-source pam recipe install-
  # mirror shim.
  #
  # A future M9.R.57+ can (a) diff the from-source pam parser
  # against Debians libpam to find the include divergence, or
  # (b) reintroduce the @include chain once the pam recipe is
  # aligned with Debians module set.
  cat > '$MNT_DIR/etc/pam.d/sddm-autologin' <<'PAM_AUTOLOGIN_EOF'
#%PAM-1.0
# M9.R.56.8.5 minimal PAM stack for sddm autologin.
# Bypasses the common-* @include chain that fails config parse
# silently on the from-source pam recipe.
# M9.R.56.8.6 adds pam_systemd.so (Debian binary; ABI-compatible
# with the from-source libpam.so.0) to create /run/user/<uid>
# and set XDG_RUNTIME_DIR --- without this, sway aborts at
# startup with ``XDG_RUNTIME_DIR is not set in the environment.
# Aborting.`` (verified in /home/repro/.local/share/sddm/
# wayland-session.log from the M9.R.56.8.5 boot smoke).
auth       required   pam_permit.so
account    required   pam_permit.so
password   required   pam_permit.so
session    required   pam_permit.so
session    optional   pam_keyinit.so force revoke
session    optional   pam_limits.so
session    optional   pam_loginuid.so
session    optional   pam_env.so
session    optional   /usr/lib/x86_64-linux-gnu/security/pam_systemd.so
PAM_AUTOLOGIN_EOF
  cat > '$MNT_DIR/etc/pam.d/sddm-greeter' <<'PAM_GREETER_EOF'
#%PAM-1.0
# M9.R.56.8.5 minimal PAM stack for sddm greeter session (runs
# as the unprivileged sddm user; no autologin, no password
# required, just enough scaffolding to hand off to the greeter).
auth       required   pam_permit.so
account    required   pam_permit.so
password   required   pam_permit.so
session    required   pam_permit.so
session    optional   pam_keyinit.so force revoke
session    optional   pam_limits.so
session    optional   pam_loginuid.so
session    optional   pam_env.so
session    optional   /usr/lib/x86_64-linux-gnu/security/pam_systemd.so
PAM_GREETER_EOF

  # M9.R.56.8.7: create /run/user/1000 out-of-band + export
  # XDG_RUNTIME_DIR in the sway session environment.
  #
  # Phase B evidence after M9.R.56.8.6 (system journal +
  # wayland-session.log):
  #
  #   systemd-logind: Failed to start user service
  #   'user-runtime-dir@1000.service': Failed to execute program
  #   org.freedesktop.systemd1: Permission denied
  #
  #   wayland-session.log: XDG_RUNTIME_DIR is not set in the
  #   environment. Aborting.
  #
  # Root cause: pam_systemd.so calls systemd-logind over dbus
  # to CreateSession(); logind then tries to start
  # user-runtime-dir@1000.service by activating org.freedesktop.
  # systemd1 over the system bus.  The bus service file
  # /usr/share/dbus-1/system-services/org.freedesktop.systemd1.service
  # has ``Exec=/bin/false SystemdService=dbus-org.freedesktop.
  # systemd1.service``, which means dbus MUST use
  # ``--systemd-activation`` to route the request to systemd.
  # But the M9.R.56.5 fix stripped ``--systemd-activation`` from
  # dbus.services ExecStart (because the from-source dbus
  # recipe was compiled without libsystemd support), so dbus
  # falls back to executing /bin/false which returns immediately
  # with the systemd-logind Permission denied error.  Net result:
  # /run/user/1000 is never created; XDG_RUNTIME_DIR is never
  # set; sway aborts at startup.
  #
  # Fix: bypass systemd-logind entirely for the runtime-dir
  # creation.  A tmpfiles.d entry creates /run/user/1000 owned
  # by uid 1000 gid 1000 at boot, and a systemd-tmpfiles
  # --create call reruns it after the graphical.target reaches.
  # We ALSO drop /etc/environment.d/50-xdg-runtime-dir.conf
  # exporting XDG_RUNTIME_DIR=/run/user/1000 so sway inherits
  # the variable via /bin/bash --login (the wayland-session
  # script sources /etc/profile which reads
  # /etc/environment.d/).
  #
  # This is a v1 shim.  A future M9.R.57+ rebuild of dbus with
  # ``-Dsystemd=enabled`` restores the standard flow and the
  # tmpfiles.d + environment.d shims become no-ops (systemd-
  # logind then handles /run/user/<uid> normally).
  mkdir -p '$MNT_DIR/etc/tmpfiles.d'
  cat > '$MNT_DIR/etc/tmpfiles.d/m9r56-8-xdg-runtime.conf' <<'TMPFILES_EOF'
# M9.R.56.8.7 --- create /run/user/1000 for the autologin repro
# user to bypass systemd-logind's user-runtime-dir@.service (which
# fails because dbus can't systemd-activate org.freedesktop.systemd1).
d /run/user 0755 root root -
d /run/user/1000 0700 1000 1000 -
TMPFILES_EOF

  mkdir -p '$MNT_DIR/etc/environment.d'
  cat > '$MNT_DIR/etc/environment.d/50-xdg-runtime-dir.conf' <<'ENVD_EOF'
# M9.R.56.8.7 --- export XDG_RUNTIME_DIR to /run/user/1000
# (the tmpfiles.d entry above creates the dir).  The wayland-
# session script sources /etc/profile which reads
# /etc/environment.d/ via pam_env.so, so sway inherits this.
XDG_RUNTIME_DIR=/run/user/1000
ENVD_EOF

  # Also add to /etc/environment (single-line, older-style) as
  # a belt-and-suspenders fallback for shells that don't process
  # /etc/environment.d/.
  if ! grep -q '^XDG_RUNTIME_DIR=' '$MNT_DIR/etc/environment' 2>/dev/null; then
    echo 'XDG_RUNTIME_DIR=/run/user/1000' >> '$MNT_DIR/etc/environment'
  fi

  # /usr/local/lib/sddm/sddm.conf.d -> /etc/sddm.conf.d so the
  # daemon's SYSTEM_CONFIG_DIR probe finds any drop-ins.
  mkdir -p '$MNT_DIR/usr/local/lib/sddm'
  ln -sfn /etc/sddm.conf.d '$MNT_DIR/usr/local/lib/sddm/sddm.conf.d'

  # --- Config-file overrides (belt-and-suspenders) ---
  # If a future sddm rebuild moves to CMAKE_INSTALL_PREFIX=/usr
  # the shim symlinks above become no-ops; the config overrides
  # continue to pin the paths.  Every key here mirrors a
  # Configuration.h Entry whose default embeds LIBEXEC_INSTALL_DIR
  # or DATA_INSTALL_DIR.
  cat > '$MNT_DIR/etc/sddm.conf.d/10-paths.conf' <<'SDDM_PATHS_EOF'
[Theme]
ThemeDir=/usr/share/sddm/themes
FacesDir=/usr/share/sddm/faces

[X11]
SessionCommand=/usr/share/sddm/scripts/Xsession
DisplayCommand=/usr/share/sddm/scripts/Xsetup
DisplayStopCommand=/usr/share/sddm/scripts/Xstop
SessionDir=/usr/share/xsessions

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM_PATHS_EOF

  # --- Instrumentation: strace sddm's ExecStart ---
  # Diag files land in /var/log/m9r56_diag/ so a
  # post-boot qemu-nbd inspection can pull them.  strace
  # follows forks to capture sddm-helper spawn behaviour +
  # session command exec + PAM helper invocations.
  mkdir -p '$MNT_DIR/var/log/m9r56_diag'
  mkdir -p '$MNT_DIR/etc/systemd/system/sddm.service.d'
  cat > '$MNT_DIR/etc/systemd/system/sddm.service.d/50-strace.conf' <<'SDDM_STRACE_EOF'
[Service]
# M9.R.56.8: wrap sddm with strace -f so the sddm ->
# sddm-helper -> sway spawn chain is captured.  The
# --absolute-timestamps + -f flags follow every child and
# tag every syscall with wall-clock time.  Output goes to
# /var/log/m9r56_diag/sddm-strace.log for post-boot
# extraction.  We trace only the syscalls that reveal the
# session-launch path (execve, openat, connect, dup2,
# setuid, setgid, fork, clone, wait4, kill, exit, exit_group).
ExecStart=
ExecStart=/usr/bin/strace -f -tt -o /var/log/m9r56_diag/sddm-strace.log -e trace=execve,openat,connect,dup2,setuid,setgid,fork,clone,wait4,kill,exit,exit_group /usr/bin/sddm
SDDM_STRACE_EOF

  # --- Instrumentation: post-boot journal capture ---
  # A one-shot unit that runs after graphical.target and
  # dumps the sddm.service + sddm-autologin PAM logs to
  # /var/log/m9r56_diag/sddm-journal.txt.  Runs with a
  # 30 s delay so sddm has time to emit any startup errors.
  cat > '$MNT_DIR/etc/systemd/system/m9r56-diag.service' <<'M9R56_DIAG_EOF'
[Unit]
Description=M9.R.56.8 diagnostic journal capture
After=graphical.target
Wants=graphical.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/mkdir -p /var/log/m9r56_diag
ExecStartPre=/bin/sh -c 'sleep 30'
ExecStart=/bin/sh -c 'journalctl --no-pager -u sddm.service > /var/log/m9r56_diag/sddm-journal.txt 2>&1 || true'
ExecStart=/bin/sh -c 'journalctl --no-pager _PID=1 > /var/log/m9r56_diag/systemd-pid1.txt 2>&1 || true'
ExecStart=/bin/sh -c 'ls -la /var/log/m9r56_diag/ > /var/log/m9r56_diag/ls.txt 2>&1'
ExecStart=/bin/sh -c 'systemctl status sddm.service --no-pager > /var/log/m9r56_diag/sddm-status.txt 2>&1 || true'
ExecStart=/bin/sh -c 'systemctl list-units --failed --no-pager > /var/log/m9r56_diag/failed-units.txt 2>&1 || true'
ExecStart=/bin/sh -c 'ps auxf > /var/log/m9r56_diag/ps.txt 2>&1'
ExecStart=/bin/sh -c 'ls -laR /run/user > /var/log/m9r56_diag/run-user.txt 2>&1 || true'

[Install]
WantedBy=multi-user.target
M9R56_DIAG_EOF
  mkdir -p '$MNT_DIR/etc/systemd/system/multi-user.target.wants'
  ln -sfn /etc/systemd/system/m9r56-diag.service \
    '$MNT_DIR/etc/systemd/system/multi-user.target.wants/m9r56-diag.service'
" || { echo "[build-reproos-image] Phase 10.8 sddm path shims + instrumentation failed" >&2; exit 74; }

echo "[build-reproos-image] phase summary:"
echo "  staged tree:   $STAGE_DIR ($(du -sh "$STAGE_DIR" 2>/dev/null | awk '{print $1}'))"
echo "  mnt root:      $MNT_DIR ($(df -h "$MNT_DIR" 2>/dev/null | tail -1 | awk '{print $3"/"$2}'))"
echo "  mnt esp:       $MNT_DIR/boot ($(df -h "$MNT_DIR/boot" 2>/dev/null | tail -1 | awk '{print $3"/"$2}'))"

# ---------------------------------------------------------------
# Phase 11: unmount + disconnect.
# Cleanup trap handles errors; on success we unmount cleanly so
# the qcow2 is fully flushed before we move it.
# ---------------------------------------------------------------
"$SUDO" sync
sleep 2
# Unmount in reverse order (esp before root) so we don't try to
# unmount the parent while a child is still mounted.  Use lazy
# umount as fallback for stubbornly-busy mounts.
for ((i=${#MOUNTED_PATHS[@]}-1; i>=0; i--)); do
  p="${MOUNTED_PATHS[$i]}"
  "$SUDO" umount "$p" 2>/dev/null \
    || "$SUDO" umount -l "$p" 2>/dev/null \
    || { echo "[build-reproos-image] WARNING: failed to unmount $p" >&2; }
done
"$SUDO" sync
sleep 1
MOUNTED_PATHS=()

"$SUDO" qemu-nbd --disconnect "$NBD_DEV"
NBD_CONNECTED=0

# ---------------------------------------------------------------
# Phase 12: stage the qcow2 at the recipe's output path.
# ---------------------------------------------------------------
mkdir -p "$(dirname "$OUT_QCOW2")"
mv "$TMP_QCOW2" "$OUT_QCOW2"
sha256sum "$OUT_QCOW2" | awk '{print "[build-reproos-image] sha256 " $1 "  " $2}'
ls -la "$OUT_QCOW2"

echo "[build-reproos-image] OK"
exit 0
