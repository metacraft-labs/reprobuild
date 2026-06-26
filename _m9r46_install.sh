#!/usr/bin/env bash
# M9.R.46 install driver - same shape as _m9r43_install.sh but pinned
# to the M9.R.46 ISO output + log files.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r46_install.qcow2}"
DIAG_DISK="${DIAG_DISK:-/tmp/m9r46_diag.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r46_install.log}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-3600}"
DIAG_OUT="${DIAG_OUT:-/tmp/m9r46_diag}"

[ -f "$ISO" ] || { echo "ISO $ISO does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r46_install_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
chmod u+w "$INSTALL_VARS"

date

rm -f "$DISK" "$DIAG_DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null
truncate -s 64M "$DIAG_DISK"

echo "=== M9.R.46 instrumented install (timeout ${INSTALL_TIMEOUT}s) ===" | tee "$INSTALL_LOG"
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
  echo "[m9r46-install] ${INSTALL_TIMEOUT}s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.46 install log (last 200 lines, ANSI stripped) ==="
sed 's/\x1B\[[0-9;]*[mK]//g' "$INSTALL_LOG" | tail -200

echo ""
echo "=== M9.R.46 post-mortem diag extraction ==="
rm -rf "$DIAG_OUT"
mkdir -p "$DIAG_OUT"
HEADER="$(dd if="$DIAG_DISK" bs=512 count=1 status=none 2>/dev/null | tr -d '\0' | head -1)"
echo "diag-header=$HEADER"
DIAG_SIZE="$(echo "$HEADER" | sed -nE 's/^M9R39DIAGv1 SIZE=([0-9]+).*$/\1/p')"
if [ -z "$DIAG_SIZE" ] || [ "$DIAG_SIZE" = "0" ]; then
  echo "[m9r46-install] no M9R39DIAGv1 header on /dev/vdb; launcher diag-persist did not fire"
  date
  exit 0
fi
dd if="$DIAG_DISK" bs=512 skip=1 count=$(( (DIAG_SIZE + 511) / 512 )) \
  status=none 2>/dev/null \
  | head -c "$DIAG_SIZE" \
  > "$DIAG_OUT/installer.diag.tar.gz"
tar -xzf "$DIAG_OUT/installer.diag.tar.gz" -C "$DIAG_OUT" 2>&1 | tail -10
ls -la "$DIAG_OUT" | head -20
date
