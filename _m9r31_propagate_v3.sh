#!/usr/bin/env bash
# M9.R.31.2v3 — propagation that preserves recipe's OWN manifest too,
# so nix-store paths captured from prior LD_LIBRARY_PATH walks don't
# get lost when binary RPATHs are reset.
set -uo pipefail
cd /opt/repro/reprobuild

nix-shell -p patchelf --run bash << 'NIX'
cd /opt/repro/reprobuild

extract_deps() {
  local recipe="$1"
  local nim="$recipe/repro.nim"
  [ -f "$nim" ] || return
  awk '
    /^  nativeBuildDeps:/ { mode=1; next }
    /^  buildDeps:/ { mode=1; next }
    /^  [a-zA-Z]+:/ { mode=0 }
    mode && /^    "/ {
      s = $0
      sub(/^    "/, "", s)
      sub(/".*$/, "", s)
      sub(/[ <>=~^].*$/, "", s)
      if (s != "") print s
    }
  ' "$nim"
}

count=0
total=0
for recipe in recipes/packages/source/*/; do
  recipe="${recipe%/}"
  install_dir="$recipe/.repro/output/install"
  [ -d "$install_dir/usr" ] || continue
  total=$((total+1))
  pkg_name="$(basename "$recipe")"

  : > "$install_dir/.m9r31_extra_rpath.tmp"
  # Preserve recipe's own manifest first (captures original
  # nix-store paths from LD_LIBRARY_PATH-walk that might be lost
  # otherwise).
  if [ -f "$install_dir/.m9r30_propagated_libdirs.txt" ]; then
    cat "$install_dir/.m9r30_propagated_libdirs.txt" >> "$install_dir/.m9r31_extra_rpath.tmp"
  fi
  # Add deps' manifests.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dep_install="recipes/packages/source/$dep/.repro/output/install"
    [ -d "$dep_install/usr/lib" ] && echo "$dep_install/usr/lib" >> "$install_dir/.m9r31_extra_rpath.tmp"
    [ -d "$dep_install/usr/lib64" ] && echo "$dep_install/usr/lib64" >> "$install_dir/.m9r31_extra_rpath.tmp"
    if [ -f "$dep_install/.m9r30_propagated_libdirs.txt" ]; then
      cat "$dep_install/.m9r30_propagated_libdirs.txt" >> "$install_dir/.m9r31_extra_rpath.tmp"
    fi
  done < <(extract_deps "$recipe")

  if [ ! -s "$install_dir/.m9r31_extra_rpath.tmp" ]; then
    rm -f "$install_dir/.m9r31_extra_rpath.tmp"
    continue
  fi
  awk '/^\// && !seen[$0]++' "$install_dir/.m9r31_extra_rpath.tmp" > "$install_dir/.m9r31_extra_rpath"
  rm -f "$install_dir/.m9r31_extra_rpath.tmp"
  extra_rpath=$(tr '\n' ':' < "$install_dir/.m9r31_extra_rpath" | sed 's/:$//')
  rm -f "$install_dir/.m9r31_extra_rpath"
  [ -n "$extra_rpath" ] || continue

  patched=0
  while IFS= read -r f; do
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -c | head -1 | tr -d ' ')
    case "$magic" in 177ELF*) ;;
      *) continue;;
    esac
    old_rpath=$(patchelf --print-rpath "$f" 2>/dev/null)
    new_rpath="$old_rpath:$extra_rpath"
    new_rpath=$(echo "$new_rpath" | tr ':' '\n' | awk '!seen[$0]++' | grep -v '^$' | tr '\n' ':' | sed 's/:$//')
    if [ "$new_rpath" != "$old_rpath" ]; then
      patchelf --set-rpath "$new_rpath" "$f" 2>/dev/null && patched=$((patched+1)) || true
    fi
  done < <(find "$install_dir/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null)

  # Re-synthesize manifest from updated RPATH.
  : > "$install_dir/.m9r30_propagated_libdirs.txt.tmp"
  while IFS= read -r f; do
    magic=$(head -c 4 "$f" 2>/dev/null | od -An -c | head -1 | tr -d ' ')
    case "$magic" in 177ELF*) ;;
      *) continue;;
    esac
    patchelf --print-rpath "$f" 2>/dev/null | tr ':' '\n' | while IFS= read -r rp; do
      case "$rp" in
        ''|'$ORIGIN'*) ;;
        /*) printf '%s\n' "$rp" >> "$install_dir/.m9r30_propagated_libdirs.txt.tmp";;
      esac
    done
  done < <(find "$install_dir/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null)
  if [ -s "$install_dir/.m9r30_propagated_libdirs.txt.tmp" ]; then
    awk '!seen[$0]++' "$install_dir/.m9r30_propagated_libdirs.txt.tmp" > "$install_dir/.m9r30_propagated_libdirs.txt"
  fi
  rm -f "$install_dir/.m9r30_propagated_libdirs.txt.tmp"

  count=$((count+1))
  echo "[m9r31] $pkg_name: patched=$patched"
done
echo "[m9r31] processed $count of $total recipes"
NIX
