#!/usr/bin/env bash
# M9.R.37.M — Phase D: boot the installed system + DE smoke.
#
# After M9.R.37's install completes (RC=0, all 6 phases), this driver
# boots the installed disk (no ISO attached) and runs the DE-version
# probe sequence M9.R.36's Phase D documented.  Captures the full
# transcript including each --version output for sway / kwin_wayland /
# mutter / plasmashell / startplasma-wayland.
set -uo pipefail
DISK="${DISK:-/tmp/m9r37_installed_disk.qcow2}"
BOOT_LOG="${BOOT_LOG:-/tmp/m9r37_boot_installed.log}"
TIMEOUT="${TIMEOUT:-360}"

[ -f "$DISK" ] || { echo "Disk $DISK does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

BOOT_VARS=/tmp/m9r37_boot_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$BOOT_VARS"
chmod u+w "$BOOT_VARS"

date

BOOT_FIFO="$(mktemp -d)/boot-in.fifo"
mkfifo "$BOOT_FIFO"
(
  sleep 90
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R37_INSTALLED_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "uname -a"
  sleep 2
  echo "cat /etc/os-release 2>&1 | head -10"
  sleep 2
  echo "lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS 2>&1 | head -10"
  sleep 2
  echo "ls -la /usr/bin/sway /usr/bin/kwin_wayland /usr/bin/mutter /usr/bin/plasmashell /usr/bin/startplasma-wayland /usr/bin/sddm 2>&1"
  sleep 3
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen startplasma-wayland --version 2>&1 || echo STARTPLASMA_RC=\$?"
  sleep 3
  echo "sddm --version 2>&1 || echo SDDM_RC=\$?"
  sleep 3
  echo "echo === M9R37_INSTALLED_DE_SMOKE_END ==="
  sleep 3
  echo "poweroff"
) > "$BOOT_FIFO" &

echo "=== M9.R.37 boot installed system (timeout ${TIMEOUT}s) ===" | tee "$BOOT_LOG"
nix-shell -p qemu OVMF --run "
  qemu-system-x86_64 -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$BOOT_VARS \
    -drive file=$DISK,if=virtio,format=qcow2 \
    -nographic -serial mon:stdio -display none \
    < $BOOT_FIFO
" >> "$BOOT_LOG" 2>&1 &
QPID=$!

T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt $TIMEOUT ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r37-boot] ${TIMEOUT}s timeout, killing QEMU" | tee -a "$BOOT_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== Stage 2 transcript tail (last 200 lines) ==="
tail -200 "$BOOT_LOG"

echo ""
echo "=== Stage 2 DE-PROBE EXTRACT ==="
sed -n '/M9R37_INSTALLED_DE_SMOKE_BEGIN/,/M9R37_INSTALLED_DE_SMOKE_END/p' "$BOOT_LOG"
echo "=== END ==="

date
