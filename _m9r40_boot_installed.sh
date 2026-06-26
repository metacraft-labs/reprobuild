#!/usr/bin/env bash
# M9.R.40.3 — Phase D: boot the installed disk + DE smoke.
#
# After M9.R.40.1's install completes (RC=0, all 6 phases), this driver
# boots the installed disk (no ISO attached) and runs the DE-version
# probe sequence M9.R.36's Phase D documented.  Captures the full
# transcript including each --version output for sway / kwin_wayland /
# mutter / plasmashell / startplasma-wayland / sddm.
#
# DISK defaults to ``/tmp/m9r39_install.qcow2`` (the install driver's
# output).  Override via env if running against a different install.
set -uo pipefail
DISK="${DISK:-/tmp/m9r39_install.qcow2}"
BOOT_LOG="${BOOT_LOG:-/tmp/m9r40_boot_installed.log}"
TIMEOUT="${TIMEOUT:-360}"

[ -f "$DISK" ] || { echo "Disk $DISK does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

BOOT_VARS=/tmp/m9r40_boot_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$BOOT_VARS"
chmod u+w "$BOOT_VARS"

date

BOOT_FIFO="$(mktemp -d)/boot-in.fifo"
mkfifo "$BOOT_FIFO"
(
  # Sleep through GRUB timeout + boot + login prompt before sending
  # anything.  Bumped to 150 from M9.R.36's 90 to be safe in case the
  # OVMF firmware adds a "Press any key to continue" extra step.
  sleep 150
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R40_INSTALLED_DE_SMOKE_BEGIN ==="
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
  echo "echo === M9R40_INSTALLED_DE_SMOKE_END ==="
  sleep 3
  echo "poweroff"
) > "$BOOT_FIFO" &

echo "=== M9.R.40 boot installed system (timeout ${TIMEOUT}s) ===" | tee "$BOOT_LOG"
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
  echo "[m9r40-boot] ${TIMEOUT}s timeout, killing QEMU" | tee -a "$BOOT_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.40 boot installed log (last 200 lines, ANSI stripped) ==="
sed 's/\x1B\[[0-9;]*[mK]//g' "$BOOT_LOG" | tail -200

echo ""
echo "=== smoke markers ==="
grep -E "M9R40_INSTALLED_DE_SMOKE|sway version|kwin|mutter|plasmashell|startplasma|sddm|SWAY_RC|KWIN_RC|MUTTER_RC|PLASMA_RC|STARTPLASMA_RC|SDDM_RC" "$BOOT_LOG" | tail -40

date
