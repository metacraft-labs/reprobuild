#!/usr/bin/env bash
# M9.R.36.1 — G1 installed-system DE smoke driver.
#
# Two-stage UEFI QEMU run:
#   Stage 1 — install: boot ISO with a virtio disk attached; the
#     ISO's tty1 profile hook auto-launches reproos-installer in
#     --automated mode against /etc/reproos/auto-config.toml.  After
#     the installer exits we poweroff via the tty1 console.
#   Stage 2 — boot installed: boot the same disk (no ISO) and DE-probe
#     the installed system the same way the M9.R.33 live-ISO smoke
#     probed the live one.
#
# The installer config baked into the ISO targets ``/dev/vda``
# (REPRO_LIVE_TARGET=graphical sets diskoPreset=simple), so a
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
  # Give boot + autologin + installer enough time to finish.  The
  # installer's automated path runs disko-zap + nixos-install-style
  # population + bootloader install; on a virtio-blk disk that's
  # 2-4 minutes on modern hardware.  We budget 8 minutes before
  # forcing poweroff.
  sleep 480
  # After the installer prints "=== Installer exited with rc=0 ===",
  # the profile hook returns control to the autologin shell.  Type
  # poweroff to clean-shutdown.
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
while kill -0 $QPID 2>/dev/null && [ $T -lt 600 ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r36-install] timeout, killing QEMU" | tee -a "$INSTALL_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null
echo "=== Stage 1 transcript tail (last 80 lines) ==="
tail -80 "$INSTALL_LOG"

# ---------------------------------------------------------------------------
# Stage 2 — boot installed system
# ---------------------------------------------------------------------------

BOOT_FIFO="$(mktemp -d)/boot-in.fifo"
mkfifo "$BOOT_FIFO"
(
  # Wait for boot + autologin (SDDM autologin to the installer session
  # is live-only; the installed system boots into a regular login
  # shell on tty1 or — if graphical.target — into SDDM).  Give
  # systemd 60s for unit ordering then attempt the DE probes via
  # the serial console.
  sleep 60
  echo ""
  sleep 2
  # If autologin landed us in a shell, the probes go straight through.
  # If we're at a login prompt, type alice / reproos.
  echo "alice"
  sleep 2
  echo "reproos"
  sleep 4
  echo "echo === M9R36_INSTALLED_DE_SMOKE_BEGIN ==="
  sleep 1
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
  echo "ls -la /usr/bin/sway /usr/bin/kwin_wayland /usr/bin/plasmashell /usr/bin/startplasma-wayland 2>&1"
  sleep 3
  echo "uname -a"
  sleep 2
  echo "cat /etc/os-release 2>&1 | head -10"
  sleep 2
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
