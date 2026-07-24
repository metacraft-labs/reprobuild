#!/usr/bin/env bash
# Add the packaged runtime search paths to every installed Mach-O image.
# Universal binaries are mutated one architecture at a time and reassembled;
# this avoids relying on install_name_tool's whole-file behavior for fat files.

set -euo pipefail

if (($# < 2)); then
  echo "usage: fixup_macho_runtime.sh PACKAGE_ROOT RUNTIME_DIR..." >&2
  exit 64
fi

package_root=$1
shift
runtime_dirs=("$@")

lipo_cmd=${LIPO:-lipo}
otool_cmd=${OTOOL:-otool}
install_name_tool_cmd=${INSTALL_NAME_TOOL:-install_name_tool}
file_cmd=${FILE:-file}
stat_cmd=${STAT:-stat}
cp_cmd=${CP:-cp}
mv_cmd=${MV:-mv}
scratch_roots=()

cleanup() {
  local scratch
  for scratch in "${scratch_roots[@]}"; do
    rm -rf "$scratch"
  done
}
trap cleanup EXIT

read_rpaths() {
  "$otool_cmd" -l "$1" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" {
      path = $0
      sub(/^[[:space:]]*path[[:space:]]+/, "", path)
      sub(/[[:space:]]+\(offset [0-9]+\)[[:space:]]*$/, "", path)
      print path
      in_rpath = 0
    }
  '
}

mutate_slice() {
  local slice=$1
  local installed_path=$2
  local is_library=$3
  local runtime_dir
  local rpaths

  rpaths=$(read_rpaths "$slice")
  for runtime_dir in "${runtime_dirs[@]}"; do
    if ! printf '%s\n' "$rpaths" | grep -Fxq "$runtime_dir"; then
      "$install_name_tool_cmd" -add_rpath "$runtime_dir" "$slice"
      rpaths="${rpaths}${rpaths:+$'\n'}${runtime_dir}"
    fi
  done

  if [[ $is_library == 1 ]]; then
    "$install_name_tool_cmd" -id "$installed_path" "$slice"
  fi
}

fix_image() {
  local image=$1
  local architectures_text
  local -a architectures
  local is_library=0
  local scratch
  local rebuilt
  local original_mode
  local arch
  local thin
  local scratch_parent
  local -a thin_slices=()

  if ! "$file_cmd" -b "$image" | grep -q '^Mach-O'; then
    return 0
  fi
  if ! architectures_text=$("$lipo_cmd" -archs "$image" 2>/dev/null); then
    echo "file identified Mach-O but lipo could not inspect: $image" >&2
    return 1
  fi
  read -r -a architectures <<<"$architectures_text"
  ((${#architectures[@]} > 0)) || {
    echo "Mach-O image has no architectures: $image" >&2
    return 1
  }
  if [[ $image == "$package_root"/lib/* ]]; then
    is_library=1
  fi
  original_mode=$("$stat_cmd" -c '%a' "$image")
  if [[ ! $original_mode =~ ^[0-7]{3,4}$ ]]; then
    echo "stat returned an invalid file mode for $image: $original_mode" >&2
    return 1
  fi

  # Never mutate an installed image in place. Even a thin image is first
  # copied to private scratch, while universal slices are extracted there, so
  # install_name_tool or lipo failure leaves the original bytes and mode
  # untouched. Only a fully mutated/reassembled candidate is atomically
  # renamed over the installed path.
  scratch_parent=$(dirname "$image")
  scratch=$(mktemp -d "$scratch_parent/.repro-macho-fixup.XXXXXX")
  scratch_roots+=("$scratch")
  for arch in "${architectures[@]}"; do
    thin="$scratch/$arch"
    if ((${#architectures[@]} == 1)); then
      # Apple lipo rejects -thin for an input that is already thin. A byte-for-
      # byte scratch copy provides the same isolation without touching the
      # installed image.
      "$cp_cmd" "$image" "$thin"
    else
      "$lipo_cmd" "$image" -thin "$arch" -output "$thin"
    fi
    mutate_slice "$thin" "$image" "$is_library"
    thin_slices+=("$thin")
  done
  if ((${#architectures[@]} == 1)); then
    rebuilt=${thin_slices[0]}
  else
    rebuilt="$scratch/rebuilt"
    "$lipo_cmd" -create "${thin_slices[@]}" -output "$rebuilt"
  fi
  chmod "$original_mode" "$rebuilt"
  "$mv_cmd" -f "$rebuilt" "$image"
  rm -rf "$scratch"
}

[[ -d $package_root && -w $package_root ]] || {
  echo "package root is not a writable directory: $package_root" >&2
  exit 1
}

# Snapshot the installed roles before creating any private scratch directory.
# Candidate-local hidden scratch is therefore never eligible for processing.
candidates=()
while IFS= read -r -d '' candidate; do
  candidates+=("$candidate")
done < <(find "$package_root/bin" "$package_root/lib" -maxdepth 1 -type f \
  -print0 | sort -z)
for candidate in "${candidates[@]}"; do
  fix_image "$candidate"
done
