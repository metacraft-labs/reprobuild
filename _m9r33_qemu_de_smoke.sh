#!/usr/bin/env bash
# M9.R.33.13 — QEMU UEFI live-ISO DE smoke driver. Mirrors the M9.R.32
# probe set + adds checks for the from-source binaries that should
# resolve via $PATH after the M9.R.33.3 stage-loop shadow links land
# (systemctl, mount, modprobe, dbus-daemon, passwd, ...).
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
TRANSCRIPT="${TRANSCRIPT:-/tmp/m9r33_qemu_de_smoke.log}"
OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS=/tmp/m9r33_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$OVMF_VARS"
chmod u+w "$OVMF_VARS"
INPUT_FIFO="$(mktemp -d)/in.fifo"
mkfifo "$INPUT_FIFO"
(
  sleep 90
  echo ""
  sleep 2
  echo "root"
  sleep 2
  echo "reproos"
  sleep 4
  echo "echo === M9R33_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  echo "startplasma-wayland --help 2>&1 | head -5 || echo STARTPLASMAWL_RC=\$?"
  sleep 3
  echo "sddm --version 2>&1 || echo SDDM_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen sddm-greeter-qt6 --help 2>&1 | head -3 || echo SDDM_GREETER_RC=\$?"
  sleep 3
  # M9.R.33.3 base-userspace shadow-link verification.
  echo "echo --- M9R33_BASE_USERSPACE_BEGIN ---"
  sleep 1
  echo "readlink /usr/bin/systemctl 2>&1 || echo NOLINK_SYSTEMCTL"
  sleep 1
  echo "readlink /sbin/mount.btrfs 2>&1 || true"
  sleep 1
  echo "readlink /usr/bin/dbus-daemon 2>&1 || echo NOLINK_DBUS"
  sleep 1
  echo "readlink /usr/bin/passwd 2>&1 || echo NOLINK_PASSWD"
  sleep 1
  echo "readlink /usr/bin/sudo 2>&1 || echo NOLINK_SUDO"
  sleep 1
  echo "readlink /usr/share/zoneinfo 2>&1 || echo NOLINK_TZ"
  sleep 1
  echo "readlink /usr/bin/modprobe 2>&1 || echo NOLINK_MODPROBE"
  sleep 1
  echo "readlink /usr/bin/mount 2>&1 || echo NOLINK_MOUNT"
  sleep 1
  echo "readlink /usr/sbin/mkfs.btrfs 2>&1 || echo NOLINK_BTRFS"
  sleep 1
  echo "readlink /usr/sbin/mke2fs 2>&1 || echo NOLINK_MKE2FS"
  sleep 1
  echo "echo --- M9R33_BASE_USERSPACE_END ---"
  sleep 2
  echo "echo === M9R33_DE_SMOKE_END ==="
  sleep 2
  echo "poweroff"
) > "$INPUT_FIFO" &

nix-shell -p qemu OVMF --run "
  qemu-system-x86_64 -machine q35 -m 4096 \
    -drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=raw,file=$OVMF_VARS \
    -cdrom $ISO \
    -nographic -serial mon:stdio -display none \
    < $INPUT_FIFO
" > "$TRANSCRIPT" 2>&1 &
QPID=$!

T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt 360 ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r33-smoke] timeout, killing QEMU"
  kill -9 $QPID 2>/dev/null
fi

echo "=== TRANSCRIPT ==="
cat "$TRANSCRIPT"
echo "=== END ==="

if grep -q M9R33_DE_SMOKE_BEGIN "$TRANSCRIPT"; then
  echo "--- DE PROBE OUTPUT ---"
  sed -n '/M9R33_DE_SMOKE_BEGIN/,/M9R33_DE_SMOKE_END/p' "$TRANSCRIPT"
fi
