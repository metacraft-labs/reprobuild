#!/usr/bin/env bash
# M9.R.27.7 — OVMF bisect harness for QEMU UEFI boot of the ReproOS ISO.
#
# Run with:
#   nix-shell -p qemu --run "bash recipes/reproos-iso/run-evidence/m9r27_uefi_bisect.sh recipes/reproos-iso/build/reproos.iso"
#
# Tries 6 QEMU configurations (cross-product of machine type / display /
# serial routing); captures stdout+stderr + boot transcript per config
# into /tmp/m9r27-uefi-bisect-<config>.{log,transcript}.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <iso-path>" >&2
  exit 64
fi
ISO="$1"

if [ ! -f "$ISO" ]; then
  echo "ISO not found: $ISO" >&2
  exit 66
fi

OVMF_CODE=/nix/store/7cad50aij6n2j8g1dlkzi81in3fc3p1m-OVMF-202411-fd/FV/OVMF_CODE.fd
OVMF_VARS_TPL=/nix/store/7cad50aij6n2j8g1dlkzi81in3fc3p1m-OVMF-202411-fd/FV/OVMF_VARS.fd

if [ ! -f "$OVMF_CODE" ]; then
  echo "OVMF_CODE.fd not found at $OVMF_CODE" >&2
  exit 67
fi

OUT_DIR="${OUT_DIR:-/tmp/m9r27-uefi-bisect}"
mkdir -p "$OUT_DIR"

run_combo() {
  local name="$1"
  shift
  local extra_args=("$@")
  local vars="$OUT_DIR/$name.vars.fd"
  cp "$OVMF_VARS_TPL" "$vars"
  chmod u+w "$vars"
  echo "[m9r27-uefi-bisect] running combo: $name"
  echo "[m9r27-uefi-bisect]   args: ${extra_args[*]}"
  echo "[m9r27-uefi-bisect]   transcript: $OUT_DIR/$name.transcript"
  # Note: timeout 60s — we just need to see whether OVMF reaches the
  # GRUB stage; full installer boot is downstream of that.
  timeout 60 qemu-system-x86_64 \
    -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$vars" \
    -cdrom "$ISO" \
    -m 2048 \
    -serial "file:$OUT_DIR/$name.transcript" \
    "${extra_args[@]}" \
    > "$OUT_DIR/$name.log" 2>&1 || true

  # Report transcript byte-count + first 200 bytes.
  local bytes=0
  if [ -f "$OUT_DIR/$name.transcript" ]; then
    bytes=$(stat -c %s "$OUT_DIR/$name.transcript")
  fi
  echo "[m9r27-uefi-bisect]   transcript bytes: $bytes"
  if [ "$bytes" -gt 0 ]; then
    echo "[m9r27-uefi-bisect]   first 200 bytes of transcript:"
    head -c 200 "$OUT_DIR/$name.transcript" | tr -d '\r' || true
    echo
  fi
  echo "[m9r27-uefi-bisect]   exit log tail:"
  tail -20 "$OUT_DIR/$name.log" 2>&1
  echo "[m9r27-uefi-bisect] ---"
}

# Combo 1: default pc-i440fx + display none.
run_combo "combo1-i440fx-display-none" \
  -display none

# Combo 2: q35 machine + display none.
run_combo "combo2-q35-display-none" \
  -machine q35 \
  -display none

# Combo 3: q35 machine + std vga + display none.
run_combo "combo3-q35-vga-std" \
  -machine q35 \
  -vga std \
  -display none

# Combo 4: q35 + std vga + nographic (route VGA to serial).
run_combo "combo4-q35-vga-nographic" \
  -machine q35 \
  -vga std \
  -nographic

# Combo 5: pc-i440fx + std vga + nographic.
run_combo "combo5-i440fx-vga-nographic" \
  -vga std \
  -nographic

# Combo 6: q35 + virtio-vga + sdl display.
run_combo "combo6-q35-virtio-vga-sdl" \
  -machine q35 \
  -vga virtio \
  -display sdl

echo "[m9r27-uefi-bisect] all combos done; outputs in $OUT_DIR/"
echo "[m9r27-uefi-bisect] SUMMARY:"
for f in "$OUT_DIR"/*.transcript; do
  name=$(basename "$f" .transcript)
  bytes=$(stat -c %s "$f")
  echo "  $name: $bytes bytes"
done
