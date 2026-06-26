#!/usr/bin/env bash
# M9.R.46 boot driver - same shape as _m9r43_boot_installed.sh but adds
# a /nix/store presence check + ldd verification that no DE binary
# resolves any DT_NEEDED via /nix/store.
set -uo pipefail
DISK="${DISK:-/tmp/m9r46_install.qcow2}"
BOOT_LOG="${BOOT_LOG:-/tmp/m9r46_boot_installed.log}"
TIMEOUT="${TIMEOUT:-480}"

[ -f "$DISK" ] || { echo "Disk $DISK does not exist" >&2; exit 2; }

OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"

BOOT_VARS=/tmp/m9r46_boot_ovmf_vars.fd
cp "$OVMF_DIR/OVMF_VARS.fd" "$BOOT_VARS"
chmod u+w "$BOOT_VARS"

date

BOOT_FIFO="$(mktemp -d)/boot-in.fifo"
mkfifo "$BOOT_FIFO"
(
  # Wait through GRUB boot + multi-user.target + login prompt.
  sleep 180
  echo "root"
  sleep 3
  echo "reproos"
  sleep 5
  echo "echo === M9R46_INSTALLED_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "uname -a"
  sleep 2
  echo "cat /etc/os-release 2>&1 | head -10"
  sleep 2
  echo "systemctl is-system-running 2>&1 || true"
  sleep 2
  # M9.R.46 architectural verification: no /nix/store anywhere.
  echo "echo --- M9R46_NIX_PRESENCE_CHECK ---"
  sleep 1
  echo "ls -d /nix /nix/store 2>&1 || echo NIX_NOT_PRESENT"
  sleep 1
  echo "ls -d /repro /repro/store 2>&1 | head -2"
  sleep 1
  echo "echo --- DE BINARY EXISTENCE ---"
  sleep 1
  echo "ls -la /usr/bin/sway /usr/bin/kwin_wayland /usr/bin/mutter /usr/bin/plasmashell /usr/bin/startplasma-wayland /usr/bin/sddm 2>&1"
  sleep 3
  echo "echo --- DE BINARY VERSIONS ---"
  sleep 1
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
  # M9.R.46 architectural verification: ldd shows ZERO /nix/store.
  echo "echo --- M9R46_LDD_NIX_LEAK_CHECK ---"
  sleep 1
  for b in sway kwin_wayland mutter plasmashell startplasma-wayland sddm; do
    echo "echo --- ldd /usr/bin/$b nix-store grep count ---"
    sleep 0
    echo "ldd /usr/bin/$b 2>/dev/null | grep -c /nix/store || echo 0"
    sleep 1
  done
  echo "echo === M9R46_INSTALLED_DE_SMOKE_END ==="
  sleep 3
  echo "poweroff"
) > "$BOOT_FIFO" &

echo "=== M9.R.46 boot installed system (timeout ${TIMEOUT}s) ===" | tee "$BOOT_LOG"
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
  echo "[m9r46-boot] ${TIMEOUT}s timeout, killing QEMU" | tee -a "$BOOT_LOG"
  kill -9 $QPID 2>/dev/null
fi
wait $QPID 2>/dev/null

echo ""
echo "=== M9.R.46 boot installed log (last 300 lines, ANSI stripped) ==="
sed 's/\x1B\[[0-9;]*[mK]//g' "$BOOT_LOG" | tail -300

echo ""
echo "=== M9.R.46 smoke markers ==="
grep -E "M9R46|NIX_NOT_PRESENT|sway version|kwin|mutter|plasmashell|startplasma|sddm|SWAY_RC|KWIN_RC|MUTTER_RC|PLASMA_RC|STARTPLASMA_RC|SDDM_RC" "$BOOT_LOG" | tail -50

date
