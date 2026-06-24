#!/usr/bin/env bash
# M9.R.32 QEMU UEFI live-ISO + DE smoke. Adds startplasma-wayland to
# the M9.R.31 probe set so G1 + G3 closure shows up in the transcript.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
TRANSCRIPT="${TRANSCRIPT:-/tmp/m9r32_qemu_de_smoke.log}"
OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS=/tmp/m9r32_ovmf_vars.fd
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
  echo "echo === M9R32_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  # M9.R.32.1 — new probe.  startplasma-wayland is a Qt6 binary; it
  # exits cleanly with --help when invoked with no Wayland display
  # available (no Qt platform plugin needed for --help / --version,
  # since the binary parses options before constructing QCoreApplication).
  echo "startplasma-wayland --help 2>&1 | head -5 || echo STARTPLASMAWL_RC=\$?"
  sleep 3
  echo "ls -la /usr/bin/reproos-installer-launcher 2>&1 || echo LAUNCHER_RC=\$?"
  sleep 2
  echo "ls -la /usr/bin/startplasma-wayland 2>&1 || echo SPWL_RC=\$?"
  sleep 2
  echo "sddm --version 2>&1 || echo SDDM_RC=\$?"
  sleep 3
  echo "QT_QPA_PLATFORM=offscreen sddm-greeter-qt6 --help 2>&1 | head -3 || echo SDDM_GREETER_RC=\$?"
  sleep 3
  echo "echo === M9R32_DE_SMOKE_END ==="
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

# Wait up to ~5 min for QEMU to finish
T=0
while kill -0 $QPID 2>/dev/null && [ $T -lt 300 ]; do
  sleep 10
  T=$((T+10))
done
if kill -0 $QPID 2>/dev/null; then
  echo "[m9r32-smoke] timeout, killing QEMU"
  kill -9 $QPID 2>/dev/null
fi

echo "=== TRANSCRIPT ==="
cat "$TRANSCRIPT"
echo "=== END ==="

# Capture probe-bracketed output for evidence
if grep -q M9R32_DE_SMOKE_BEGIN "$TRANSCRIPT"; then
  echo "--- DE PROBE OUTPUT ---"
  sed -n '/M9R32_DE_SMOKE_BEGIN/,/M9R32_DE_SMOKE_END/p' "$TRANSCRIPT"
fi
