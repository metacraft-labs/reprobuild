#!/usr/bin/env bash
# Must run inside a nix-shell -p gcc patchelf so gcc / patchelf are on PATH.
stdcxx_dir=$(gcc -print-file-name=libstdc++.so.6)
PATCHELF=patchelf
stdcxx_dirname=$(dirname "$stdcxx_dir")
echo "stdcxx_dirname=$stdcxx_dirname"

patch_tree() {
  local ROOT=$1
  for f in "$ROOT/bin"/* "$ROOT/lib"/*.so* "$ROOT/libexec"/*; do
    if [ -f "$f" ] && head -c 4 "$f" 2>/dev/null | od -An -c | tr -d " " | head -c 4 | grep -q "177E"; then
      oldrpath=$($PATCHELF --print-rpath "$f" 2>/dev/null)
      if ! echo "$oldrpath" | grep -q "$stdcxx_dirname"; then
        $PATCHELF --set-rpath "$oldrpath:$stdcxx_dirname" "$f" 2>/dev/null && echo "patched $f"
      fi
    fi
  done
}

QT6BASE=/opt/repro/reprobuild/recipes/packages/source/qt6-base/.repro/output/install/usr
QT6TOOLS=/opt/repro/reprobuild/recipes/packages/source/qt6-tools/.repro/output/install/usr

patch_tree "$QT6BASE"
patch_tree "$QT6TOOLS"

echo "---"
"$QT6BASE/bin/qtpaths" --query QT_INSTALL_BINS
