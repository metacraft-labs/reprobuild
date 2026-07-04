#!/usr/bin/env bash
# M9.R.70 mount qcow2 for inspection
set -euo pipefail

QCOW="${QCOW:-/opt/repro/reprobuild/recipes/reproos-image/build/reproos-installed.qcow2}"
MNT="/mnt/m9r70_inspect"
MODPROBE=/nix/store/3g7kf7v14kgwpjs3xs03mbfxavcldfii-kmod-31/bin/modprobe
QNBD=/nix/store/bjn6s1mqinmp0csj8mlaisd9dhz88shc-qemu-10.2.2/bin/qemu-nbd

"$MODPROBE" nbd 2>&1 || true
"$QNBD" --disconnect /dev/nbd0 2>/dev/null || true
sleep 1
"$QNBD" --read-only --connect=/dev/nbd0 "$QCOW"
sleep 3
mkdir -p "$MNT"
mount /dev/nbd0p2 "$MNT"
echo "=== sddm dir ==="
ls "$MNT/home/repro/.local/share/sddm/" 2>&1
echo "=== wayland-session.log ==="
cat "$MNT/home/repro/.local/share/sddm/wayland-session.log" 2>&1 || echo "(no wayland-session.log)"
