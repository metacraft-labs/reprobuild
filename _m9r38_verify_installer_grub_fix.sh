#!/usr/bin/env bash
set -uo pipefail
INST=/opt/repro/reprobuild/apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer
ls -l "$INST"
echo "=== M9.R.37.7 serial+terminal_input strings ==="
nix-shell -p binutils --run "strings $INST" 2>&1 | grep -E "serial --unit=0|terminal_input console serial|timeout_style=hidden" | head -10
echo "=== M9.R.37.8 vmlinuz/initrd path strings ==="
nix-shell -p binutils --run "strings $INST" 2>&1 | grep -E "linux /vmlinuz|initrd /initrd.img|/boot/vmlinuz|/boot/initrd" | head -10
echo "=== DONE ==="
