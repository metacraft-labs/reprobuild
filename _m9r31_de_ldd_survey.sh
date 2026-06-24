#!/bin/bash
set -uo pipefail
declare -a BINS=(
  "recipes/packages/source/sway/.repro/output/install/usr/bin/sway"
  "recipes/packages/source/sway/.repro/output/install/usr/bin/swaymsg"
  "recipes/packages/source/sway/.repro/output/install/usr/bin/swaybar"
  "recipes/packages/source/sway/.repro/output/install/usr/bin/swaynag"
  "recipes/packages/source/kwin/.repro/output/install/usr/bin/kwin_wayland"
  "recipes/packages/source/mutter/.repro/output/install/usr/bin/mutter"
  "recipes/packages/source/plasma-workspace/.repro/output/install/usr/bin/plasmashell"
  "recipes/packages/source/plasma-workspace/.repro/output/install/usr/bin/startplasma-wayland"
  "recipes/packages/source/sddm/.repro/output/install/usr/bin/sddm"
  "recipes/packages/source/sddm/.repro/output/install/usr/bin/sddm-greeter-qt6"
  "recipes/packages/source/gnome-shell/.repro/output/install/usr/bin/gnome-shell"
  "recipes/packages/source/gdm/.repro/output/install/usr/sbin/gdm"
)
cd /opt/repro/reprobuild
for bin in "${BINS[@]}"; do
  if [ -f "$bin" ]; then
    missing=$(ldd "$bin" 2>&1 | grep "not found" | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [ -n "$missing" ]; then
      echo "FAIL: $bin: $missing"
    else
      echo "OK:   $bin"
    fi
  else
    echo "MISS: $bin (does not exist)"
  fi
done
