#!/usr/bin/env bash
# M9.R.31 QEMU UEFI boot + explicit root login + DE-version probes.
set -uo pipefail
ISO="${ISO:-/opt/repro/reprobuild/recipes/reproos-iso/build/reproos.iso}"
TRANSCRIPT="${TRANSCRIPT:-/tmp/m9r31_qemu_de_smoke_v2.log}"
OVMF_FW="$(find /nix/store -maxdepth 5 -path '*OVMF*/FV/OVMF_CODE.fd' 2>/dev/null | head -1)"
[ -n "$OVMF_FW" ] || { echo "No OVMF firmware in /nix/store" >&2; exit 2; }
OVMF_DIR="$(dirname "$OVMF_FW")"
OVMF_CODE="$OVMF_DIR/OVMF_CODE.fd"
OVMF_VARS=/tmp/m9r31_ovmf_vars.fd
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
  echo "echo === M9R31_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  echo "sddm --version 2>&1 || echo SDDM_RC=\$?"
  sleep 3
  echo "sddm-greeter-qt6 --help 2>&1 | head -3 || echo SDDM_GREETER_RC=\$?"
  sleep 3
  echo "echo === M9R31_DE_SMOKE_END ==="
  sleep 2
  echo "poweroff"
) > "$INPUT_FIFO" &
timeout 240 qemu-system-x86_64 \
  -machine q35 \
  -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -cdrom "$ISO" \
  -nographic \
  -serial mon:stdio \
  -display none < "$INPUT_FIFO" 2>&1 | tee "$TRANSCRIPT"
rm -rf "$(dirname "$INPUT_FIFO")"
echo
echo "Transcript at $TRANSCRIPT"
grep -E "M9R31|--version|version|RC=" "$TRANSCRIPT" | head -40
