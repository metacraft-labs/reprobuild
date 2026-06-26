#!/usr/bin/env bash
# M9.R.41 — install driver running the M9.R.41 ISO.
#
# Same shape as _m9r39_install.sh; just bumps the timeout to 900s
# (15 min) since Phase 5 now actually copies bytes (rsync -aHAX of
# the live ISO root onto /mnt) rather than the M9.R.24 stub's
# kernel+initrd-only no-op.
#
# Outputs:
#   /tmp/m9r41_install.qcow2     — installed disk image
#   /tmp/m9r41_install.log       — serial transcript
#   /tmp/m9r41_diag/             — extracted launcher diag (rc + log)
#
# Per-step state for the M9.R.41 close-out evidence:
#   /tmp/m9r41_diag/installer.rc       — installer exit code
#   /tmp/m9r41_diag/installer.log      — Phase 1-6 transcript
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r41_install.qcow2}"
DIAG_DISK="${DIAG_DISK:-/tmp/m9r41_diag.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r41_install.log}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-900}"
DIAG_OUT="${DIAG_OUT:-/tmp/m9r41_diag}"

[ -f "$ISO" ] || { echo "ISO $ISO does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r41_install_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
chmod u+w "$INSTALL_VARS"

date

rm -f "$DISK" "$DIAG_DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null
truncate -s 64M "$DIAG_DISK"

ISO_GRUB_HAS_AUTORUN="$(strings "$ISO" 2>/dev/null | grep -c 'repro.installer.autorun=1' || true)"
if [ "${ISO_GRUB_HAS_AUTORUN:-0}" -lt 1 ]; then
  echo "[m9r41-install] WARNING: '$ISO' does NOT carry repro.installer.autorun=1"
  echo "[m9r41-install] Rebuild with REPRO_INSTALLER_AUTORUN=1 via _m9r41_iso_rebuild.sh."
fi

echo "=== M9.R.41 instrumented install (timeout ${INSTALL_TIMEOUT}s) ===" | tee "$INSTALL_LOG"
nix-shell -p qemu OVMF --run "
  tail -f /dev/null | qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$INSTALL_VARS \
    -cdrom $ISO \
    -drive file=$DISK,if=virtio,format=qcow2 \
    -drive file=$DIAG_DISK,if=virtio,format=raw \
    -nographic -serial mon:stdio -display none
" >> "$INSTALL_LOG" 2>&1 &
QPID=$!

T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt $INSTALL_TIMEOUT ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r41-install] ${INSTALL_TIMEOUT}s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.41 install log (last 300 lines, ANSI stripped) ==="
sed 's/\x1B\[[0-9;]*[mK]//g' "$INSTALL_LOG" | tail -300

echo ""
echo "=== M9.R.41 post-mortem diag extraction ==="
rm -rf "$DIAG_OUT"
mkdir -p "$DIAG_OUT"
HEADER="$(dd if="$DIAG_DISK" bs=512 count=1 status=none 2>/dev/null | tr -d '\0' | head -1)"
echo "diag-header=$HEADER"
DIAG_SIZE="$(echo "$HEADER" | sed -nE 's/^M9R39DIAGv1 SIZE=([0-9]+).*$/\1/p')"
if [ -z "$DIAG_SIZE" ] || [ "$DIAG_SIZE" = "0" ]; then
  echo "[m9r41-install] no M9R39DIAGv1 header on /dev/vdb; launcher diag-persist did not fire"
  date
  exit 0
fi
dd if="$DIAG_DISK" bs=512 skip=1 count=$(( (DIAG_SIZE + 511) / 512 )) \
  status=none 2>/dev/null \
  | head -c "$DIAG_SIZE" \
  > "$DIAG_OUT/installer.diag.tar.gz"
tar -xzf "$DIAG_OUT/installer.diag.tar.gz" -C "$DIAG_OUT" 2>&1

echo ""
echo "=== installer.rc ==="
cat "$DIAG_OUT/installer.rc" 2>&1 || echo MISSING
echo ""
echo "=== installer.log (last 200) ==="
tail -200 "$DIAG_OUT/installer.log" 2>&1
echo ""
date
