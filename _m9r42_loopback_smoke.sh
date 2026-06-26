#!/usr/bin/env bash
# M9.R.42.1 Phase A loopback smoke — exercise the disk-apply driver
# against a 4 GiB loopback file with REPRO_DISK_DIAG set, so the
# kernel-state snapshots fire on a Linux host that has sgdisk +
# udev + partprobe but is NOT inside the live ISO.  This tests
# whether the M9.R.41 sgdisk-exit-4 race reproduces OUTSIDE the
# live-ISO autorun path (i.e. on a fully-booted Debian Trixie or
# a NixOS host) — a critical signal for whether the race is
# inherent to sgdisk/Trixie OR specific to the live-ISO udev/devtmpfs.
set -uo pipefail

IMG="${IMG:-/tmp/m9r42_loop.img}"
DIAG_OUT="${DIAG_OUT:-/tmp/m9r42_loop_diag.log}"
DISKO_NIM="${DISKO_NIM:-/tmp/m9r42_loop_disko.nim}"
REPRO_BIN="${REPRO_BIN:-/opt/repro/reprobuild/build/bin/repro}"

# Reset
sudo umount -lf /tmp/m9r42_mnt 2>/dev/null || true
sudo umount -lf /tmp/m9r42_mnt/boot 2>/dev/null || true
sudo losetup -D 2>/dev/null || true
rm -f "$IMG" "$DIAG_OUT"

# 4 GiB loopback image
truncate -s 4G "$IMG"
LOOPDEV="$(sudo losetup --find --show "$IMG")"
echo "[loop] LOOPDEV=$LOOPDEV"
LOOPBASE="$(basename "$LOOPDEV")"

cat > "$DISKO_NIM" <<NIM
import repro_profile

hardware "01M9R42-LOOP":
  cpu:
    arch: "x86_64"
  disko:
    disks:
      "main":
        device: "$LOOPDEV"
        table: gpt
        partitions:
          "esp":
            kind: esp
            size: "512M"
            bootable: true
            content:
              filesystem:
                format: "vfat"
                mountpoint: "/boot"
          "root":
            kind: linux
            size: "100%"
            content:
              filesystem:
                format: "ext4"
                mountpoint: "/"
NIM

export REPRO_DISK_DIAG="$DIAG_OUT"
echo "[loop] starting repro disk apply against $LOOPDEV"
echo "[loop] BEFORE state:"
ls -la "/dev/${LOOPBASE}"* 2>&1
cat /proc/partitions 2>&1 | head -20

cd /opt/repro/reprobuild
sudo -E "$REPRO_BIN" disk apply "$DISKO_NIM" --confirm --device "$LOOPDEV" 2>&1
APPLY_RC=$?
echo "[loop] apply RC=$APPLY_RC"
echo "[loop] AFTER state:"
ls -la "/dev/${LOOPBASE}"* 2>&1
cat /proc/partitions 2>&1 | head -20

echo ""
echo "=== M9.R.42.1 diag file ($DIAG_OUT) ==="
if [ -f "$DIAG_OUT" ]; then
  cat "$DIAG_OUT"
else
  echo "MISSING — diag file not created"
fi

# Cleanup
sudo losetup -d "$LOOPDEV" 2>/dev/null || true
rm -f "$IMG"

exit $APPLY_RC
