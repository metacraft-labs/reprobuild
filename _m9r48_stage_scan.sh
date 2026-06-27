#!/usr/bin/env bash
# M9.R.48 staged-tree binary leak scan.
set -uo pipefail
cd /opt/repro/reprobuild
STAGE=recipes/reproos-iso/build/de-rootfs

scan() {
  local rel="$1"
  local f="$STAGE/$rel"
  if [ -e "$f" ]; then
    local sz cnt
    sz="$(stat -c %s "$f")"
    cnt="$(strings "$f" 2>/dev/null | grep -c /nix/store)"
    printf '%-50s size=%-10s nix_count=%s\n' "$rel" "$sz" "$cnt"
  else
    printf '%-50s MISSING\n' "$rel"
  fi
}

echo "=== M9.R.48 staged-tree binary /nix/store scan ==="
for b in \
  usr/bin/repro \
  usr/bin/reproos-installer \
  usr/bin/reproos-installer-launcher \
  usr/bin/sway \
  usr/bin/sddm \
  usr/bin/kwin_wayland \
  usr/bin/mutter \
  usr/bin/plasmashell \
  usr/bin/startplasma-wayland; do
  scan "$b"
done

echo ""
echo "=== libclingo bare-name presence in repro ==="
B="$STAGE/usr/bin/repro"
if [ -e "$B" ]; then
  echo "bare libclingo.so refs:"
  strings "$B" | grep -E '^libclingo' | head -5 || true
  echo "absolute /nix/store libclingo refs (must be 0):"
  strings "$B" | grep -E '/nix/store/.*libclingo' | head -5 || true
fi
