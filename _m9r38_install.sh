#!/usr/bin/env bash
# M9.R.38.2 — clean install run on a fresh qcow2 disk.
#
# Boots the freshly-rebuilt ISO with M9.R.37.7 + M9.R.37.8 + M9.R.38.1
# fixes, runs the installer in --automated mode, and waits for the
# installer to complete cleanly (not the M9.R.37 diagnostic-wedge
# pattern that killed the installer mid-run).  Captures full serial
# transcript.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r38_install.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r38_install.log}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-900}"

[ -f "$ISO" ] || { echo "ISO $ISO does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r38_install_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
chmod u+w "$INSTALL_VARS"

date

rm -f "$DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null

INSTALL_FIFO="$(mktemp -d)/install-in.fifo"
mkfifo "$INSTALL_FIFO"
(
  # Wait for live ISO to boot + login prompt to surface on ttyS0.
  sleep 100
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R38_INSTALL_BEGIN ==="
  sleep 1
  # Run installer in foreground; do NOT use REPRO_INSTALLER_DIAG=1 -- we
  # want a clean run, not the strace/kernelstack diagnostic mode.
  echo "QT_QPA_PLATFORM=offscreen /usr/bin/reproos-installer-launcher.sh --automated /etc/reproos/auto-config.toml; echo INSTALLER_RC=\$?"
  sleep 5
  echo "echo === M9R38_INSTALL_END ==="
  sleep 2
  echo "echo === M9R38_VERIFY_GRUB ==="
  sleep 1
  echo "cat /mnt/boot/grub/grub.cfg 2>&1"
  sleep 2
  echo "ls -la /mnt/boot/ /mnt/vmlinuz /mnt/initrd.img 2>&1"
  sleep 2
  echo "echo === M9R38_SHUTDOWN ==="
  sleep 2
  echo "poweroff"
) > "$INSTALL_FIFO" &

echo "=== M9.R.38.2 clean install (timeout ${INSTALL_TIMEOUT}s) ===" | tee "$INSTALL_LOG"
nix-shell -p qemu OVMF --run "
  qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$INSTALL_VARS \
    -cdrom $ISO \
    -drive file=$DISK,if=virtio,format=qcow2 \
    -nographic -serial mon:stdio -display none \
    < $INSTALL_FIFO
" >> "$INSTALL_LOG" 2>&1 &
QPID=$!

T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt $INSTALL_TIMEOUT ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r38-install] ${INSTALL_TIMEOUT}s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.38.2 install log (last 200 lines) ==="
tail -200 "$INSTALL_LOG"

echo ""
echo "=== M9.R.38.2 install summary extract ==="
sed -n '/M9R38_INSTALL_BEGIN/,/M9R38_SHUTDOWN/p' "$INSTALL_LOG" | head -200

date
