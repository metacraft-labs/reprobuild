#!/bin/bash
PATCHELF=/nix/store/5wf9wpdkxs30811kfgkicn9i3nz9jhsh-patchelf-0.15.0/bin/patchelf
GCC=/nix/store/y28c83zz73yr4vwz1fsl4nsrn6yz5fj0-gcc-14.3.0/bin/gcc
stdcxx_dir=$($GCC -print-file-name=libstdc++.so.6)
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
