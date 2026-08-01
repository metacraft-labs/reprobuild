#!/usr/bin/env bash
# Strict installed-package Mach-O audit.  Every check is per architecture:
# LC_RPATH entries, dylib IDs, and dependency resolution are never unioned
# across slices.  This script is used unchanged by the Nix package gate and by
# Linux-hosted tests that supply deterministic fake lipo/otool/codesign tools.

set -euo pipefail

if (($# < 2)); then
  echo "usage: audit_macho_runtime.sh PACKAGE_ROOT RUNTIME_DIR..." >&2
  exit 64
fi

package_root=$1
shift
required_rpaths=("$@")

lipo_cmd=${LIPO:-lipo}
otool_cmd=${OTOOL:-otool}
codesign_cmd=${CODESIGN:-codesign}

fail() {
  echo "Mach-O runtime audit: $*" >&2
  return 1
}

slice_rpaths() {
  local image=$1
  local arch=$2
  "$otool_cmd" -arch "$arch" -l "$image" | awk '
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

slice_install_id() {
  local image=$1
  local arch=$2
  "$otool_cmd" -arch "$arch" -D "$image" | sed -n '2p'
}

slice_dependencies() {
  local image=$1
  local arch=$2
  "$otool_cmd" -arch "$arch" -L "$image" | sed -n '2,$p' | awk '{ print $1 }'
}

expand_token_path() {
  local value=$1
  local image=$2
  local root_executable=$3
  case "$value" in
    /*)
      printf '%s\n' "$value"
      ;;
    @loader_path)
      dirname "$image"
      ;;
    @loader_path/*)
      printf '%s/%s\n' "$(dirname "$image")" "${value#@loader_path/}"
      ;;
    @executable_path)
      [[ -n $root_executable ]] || return 1
      dirname "$root_executable"
      ;;
    @executable_path/*)
      [[ -n $root_executable ]] || return 1
      printf '%s/%s\n' "$(dirname "$root_executable")" \
        "${value#@executable_path/}"
      ;;
    *)
      return 1
      ;;
  esac
}

audit_dependency() {
  local dependency=$1
  local image=$2
  local arch=$3
  local root_executable=$4
  local rpaths=$5
  local expanded
  local rpath
  local dependency_name

  case "$dependency" in
    /usr/lib/*|/System/Library/*)
      return 0
      ;;
    /nix/store/*)
      [[ -e $dependency ]] || fail \
        "$image [$arch] missing absolute dependency: $dependency"
      ;;
    @loader_path|@loader_path/*)
      expanded=$(expand_token_path "$dependency" "$image" "$root_executable")
      [[ -e $expanded ]] || fail \
        "$image [$arch] missing @loader_path dependency: $dependency -> $expanded"
      ;;
    @executable_path|@executable_path/*)
      if [[ -z $root_executable ]]; then
        fail "$image [$arch] has ambiguous @executable_path dependency: $dependency"
        return
      fi
      expanded=$(expand_token_path "$dependency" "$image" "$root_executable")
      [[ -e $expanded ]] || fail \
        "$image [$arch] missing @executable_path dependency: $dependency -> $expanded"
      ;;
    @rpath/*)
      dependency_name=${dependency#@rpath/}
      while IFS= read -r rpath; do
        [[ -n $rpath ]] || continue
        if ! expanded=$(expand_token_path "$rpath" "$image" "$root_executable"); then
          fail "$image [$arch] has unresolvable LC_RPATH entry: $rpath"
          return
        fi
        if [[ -e $expanded/$dependency_name ]]; then
          return 0
        fi
      done <<<"$rpaths"
      fail "$image [$arch] unresolved @rpath dependency: $dependency"
      ;;
    /*)
      fail "$image [$arch] has untrusted absolute dependency: $dependency"
      ;;
    *)
      fail "$image [$arch] has bare or unsupported dependency: $dependency"
      ;;
  esac
}

audit_slice() {
  local image=$1
  local arch=$2
  local root_executable=$3
  local rpaths
  local required
  local install_id
  local dependency

  "$otool_cmd" -arch "$arch" -h "$image" >/dev/null
  rpaths=$(slice_rpaths "$image" "$arch")
  for required in "${required_rpaths[@]}"; do
    if ! printf '%s\n' "$rpaths" | grep -Fxq "$required"; then
      fail "$image [$arch] missing LC_RPATH: $required"
      return
    fi
  done

  if [[ $image == "$package_root"/lib/* ]]; then
    install_id=$(slice_install_id "$image" "$arch")
    if [[ $install_id != "$image" ]]; then
      fail "$image [$arch] incorrect install ID: $install_id"
      return
    fi
  fi

  while IFS= read -r dependency; do
    [[ -n $dependency ]] || continue
    audit_dependency "$dependency" "$image" "$arch" "$root_executable" \
      "$rpaths" || return
  done < <(slice_dependencies "$image" "$arch")
}

macho_count=0
while IFS= read -r -d '' candidate; do
  architectures_text=
  if architectures_text=$("$lipo_cmd" -archs "$candidate" 2>/dev/null); then
    read -r -a architectures <<<"$architectures_text"
    ((${#architectures[@]} > 0)) || fail "$candidate has no architectures"
    ((macho_count += 1))
    root_executable=
    if [[ $candidate == "$package_root"/bin/* ]]; then
      root_executable=$candidate
    fi
    needs_arm_signature=0
    for arch in "${architectures[@]}"; do
      audit_slice "$candidate" "$arch" "$root_executable"
      if [[ $arch == arm64 || $arch == arm64e ]]; then
        needs_arm_signature=1
      fi
    done
    if ((needs_arm_signature)); then
      "$codesign_cmd" --verify --strict "$candidate" >/dev/null
    fi
  else
    case "$candidate" in
      "$package_root"/lib/*|"$package_root"/bin/.*-wrapped)
        fail "required binary/library role is not Mach-O: $candidate"
        ;;
    esac
  fi
done < <(find "$package_root/bin" "$package_root/lib" -maxdepth 1 -type f \
  -print0 | sort -z)

((macho_count > 0)) || fail "no Mach-O images found under $package_root"
