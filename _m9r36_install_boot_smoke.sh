#!/usr/bin/env bash
# M9.R.36.1 — G1 installed-system DE smoke driver.
#
# Two-stage UEFI QEMU run:
#   Stage 1 — install: boot ISO with a virtio disk attached.  The ISO
#     boots into a serial-console login prompt on ttyS0; we login as
#     root/reproos and invoke ``reproos-installer --automated
#     /etc/reproos/auto-config.toml`` manually (the tty1 autostart
#     hook only fires on graphical tty1, not on the serial console
#     ttyS0 the headless QEMU run uses).
#   Stage 2 — boot installed: boot the same disk (no ISO) and DE-probe
#     the installed system the same way the M9.R.33 live-ISO smoke
#     probed the live one.
#
# The installer config baked into the ISO targets ``/dev/vda``
# (REPRO_LIVE_TARGET=graphical sets diskoPreset=simple); a
# virtio-blk disk presented as the only target is the canonical setup.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
DISK="${DISK:-/tmp/m9r36_installed_disk.qcow2}"
INSTALL_LOG="${INSTALL_LOG:-/tmp/m9r36_install.log}"
BOOT_LOG="${BOOT_LOG:-/tmp/m9r36_boot_installed.log}"

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

INSTALL_VARS=/tmp/m9r36_install_ovmf_vars.fd
BOOT_VARS=/tmp/m9r36_boot_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$INSTALL_VARS"
cp "$OVMF_DIR/OVMF_VARS.fd" "$BOOT_VARS"
chmod u+w "$INSTALL_VARS" "$BOOT_VARS"

date

# ---------------------------------------------------------------------------
# Stage 1 — install
# ---------------------------------------------------------------------------

# Recreate the install target disk every run so the install is reproducible.
rm -f "$DISK"
nix-shell -p qemu --run "qemu-img create -f qcow2 $DISK 32G" >/dev/null

INSTALL_FIFO="$(mktemp -d)/install-in.fifo"
mkfifo "$INSTALL_FIFO"
(
  # Wait for boot + login prompt.  M9.R.33 evidence: ~75-90s from
  # power-on to the "localhost login:" prompt.
  sleep 100
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R36_INSTALL_BEGIN ==="
  sleep 1
  # Verify the installer binary + automated config are present.
  echo "ls -la /usr/bin/reproos-installer /etc/reproos/auto-config.toml 2>&1"
  sleep 2
  echo "cat /etc/reproos/auto-config.toml"
  sleep 2
  echo "lsblk -o NAME,SIZE,TYPE 2>&1 | head -10"
  sleep 2
  # Invoke the installer manually (the tty1 autostart hook is bypassed
  # because the serial console is ttyS0, not tty1).
  echo "echo === M9R36_INSTALLER_LAUNCH ==="
  sleep 1
  echo "QT_QPA_PLATFORM=offscreen /usr/bin/reproos-installer --automated /etc/reproos/auto-config.toml 2>&1 | tail -200; echo INSTALLER_RC=\$?"
  # Installer can take 2-6 minutes depending on disko-zap + nix-pop
  # closure copy speed.  Wait generously.
  sleep 360
  echo "echo === M9R36_INSTALL_END ==="
  sleep 2
  echo "poweroff"
) > "$INSTALL_FIFO" &

echo "=== Stage 1 — install ===" | tee -a "$INSTALL_LOG"
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
while kill -0 $QPID 2>/dev/null && [ $T -lt 720 ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r36-install] 720s timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null
echo "=== Stage 1 transcript tail (last 120 lines) ===" | tee -a "$INSTALL_LOG"
tail -120 "$INSTALL_LOG"

# ---------------------------------------------------------------------------
# Stage 2 — boot installed system
# ---------------------------------------------------------------------------

BOOT_FIFO="$(mktemp -d)/boot-in.fifo"
mkfifo "$BOOT_FIFO"
(
  # Wait for boot + login prompt.
  sleep 90
  echo "root"
  sleep 3
  # The installer's auto-config password is "reproos"; the
  # installed-system root password is set via shadow.
  echo "reproos"
  sleep 5
  echo "echo === M9R36_INSTALLED_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "uname -a"
  sleep 2
  echo "cat /etc/os-release 2>&1 | head -10"
  sleep 2
  echo "lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS 2>&1 | head -10"
  sleep 2
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  echo "sddm --version 2>&1 || echo SDDM_RC=\$?"
  sleep 3
  echo "ls -la /usr/bin/sway /usr/bin/kwin_wayland /usr/bin/plasmashell /usr/bin/startplasma-wayland /usr/bin/sddm 2>&1"
  sleep 3
  echo "echo === M9R36_INSTALLED_DE_SMOKE_END ==="
  sleep 3
  echo "poweroff"
) > "$BOOT_FIFO" &

echo "=== Stage 2 — boot installed ===" | tee -a "$BOOT_LOG"
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
while kill -0 $QPID 2>/dev/null && [ $T -lt 360 ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r36-boot] timeout, killing QEMU" | tee -a "$BOOT_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null
echo "=== Stage 2 transcript tail (last 120 lines) ==="
tail -120 "$BOOT_LOG"

echo ""
echo "=== Stage 2 DE-PROBE EXTRACT ==="
sed -n '/M9R36_INSTALLED_DE_SMOKE_BEGIN/,/M9R36_INSTALLED_DE_SMOKE_END/p' "$BOOT_LOG"
echo "=== END ==="

date
