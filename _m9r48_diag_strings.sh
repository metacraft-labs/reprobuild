#!/usr/bin/env bash
set -uo pipefail
cd /opt/repro/reprobuild
B=recipes/reproos-iso/build/de-rootfs/usr/bin/repro
echo "=== staged repro: $B ==="
ls -la "$B"
echo "=== first 20 /nix/store strings ==="
strings "$B" | grep /nix/store | head -20
echo "=== absolute libclingo paths ==="
strings "$B" | grep -E '/nix/store/.*libclingo' | head -5
echo "=== interp + rpath ==="
patchelf --print-interpreter "$B"
patchelf --print-rpath "$B"
