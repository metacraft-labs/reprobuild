#!/usr/bin/env bash
# QEMU UEFI boot of the M9.R.28 ISO + auto-login + DE smoke test.
set -euo pipefail
ISO=/opt/repro/reprobuild/recipes/reproos-iso/build/reproos-m9r28.iso
OVMF_CODE=/nix/store/7cad50aij6n2j8g1dlkzi81in3fc3p1m-OVMF-202411-fd/FV/OVMF_CODE.fd
OVMF_VARS_SRC=/nix/store/7cad50aij6n2j8g1dlkzi81in3fc3p1m-OVMF-202411-fd/FV/OVMF_VARS.fd
OVMF_VARS=/tmp/ovmf_vars_m9r28_smoke.fd

cp "$OVMF_VARS_SRC" "$OVMF_VARS"
chmod u+w "$OVMF_VARS"

# Auto-input: wait for login prompt, then send `root\n` + commands.
# We send all input upfront with a long sleep so it queues against the
# kernel before login is presented. The kernel echoes everything back
# on the serial console so we can grep the transcript afterward.
INPUT_FIFO=$(mktemp -d)/in.fifo
mkfifo "$INPUT_FIFO"

# Background writer: delays so the keystrokes arrive when the system
# is ready to consume them.
(
  sleep 65          # wait for boot to settle past multi-user.target
  echo ""
  sleep 2
  echo "root"
  sleep 2
  echo "reproos"   # root password set in build-base-rootfs.sh
  sleep 4
  echo "echo === M9R28_DE_SMOKE_BEGIN ==="
  sleep 1
  echo "sway --version 2>&1 || echo SWAY_RC=\$?"
  sleep 3
  echo "kwin_wayland --version 2>&1 || echo KWIN_RC=\$?"
  sleep 3
  echo "mutter --version 2>&1 || echo MUTTER_RC=\$?"
  sleep 3
  echo "plasmashell --version 2>&1 || echo PLASMA_RC=\$?"
  sleep 3
  echo "echo === M9R28_DE_SMOKE_END ==="
  sleep 2
  echo "poweroff"
) > "$INPUT_FIFO" &

timeout 180 qemu-system-x86_64 \
  -machine q35 \
  -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -cdrom "$ISO" \
  -nographic \
  -serial mon:stdio \
  -display none < "$INPUT_FIFO"

rm -rf "$(dirname "$INPUT_FIFO")"
