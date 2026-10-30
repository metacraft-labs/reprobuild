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
  local require_package_rpaths=${4:-1}
  local rpaths
  local required
  local install_id
  local dependency
  local dependencies

  "$otool_cmd" -arch "$arch" -h "$image" >/dev/null
  rpaths=$(slice_rpaths "$image" "$arch")
  for required in "${required_rpaths[@]}"; do
    ((require_package_rpaths)) || break
    # Read from a here-string rather than a pipe.  Under `set -o pipefail`,
    # `printf ... | grep -Fxq` reports the pipeline as failed whenever grep
    # matches early and exits while printf is still writing: printf takes
    # SIGPIPE, the pipeline status becomes 141, and a *present* LC_RPATH is
    # misreported as missing.  That race is load-dependent, which made it a
    # nondeterministic audit failure.  A here-string has no second process to
    # race with, and matches how audit_dependency already reads $rpaths.
    if ! grep -Fxq "$required" <<<"$rpaths"; then
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

  # Process substitution would discard otool's failure status and falsely
  # accept unavailable metadata as an empty dependency list.
  dependencies=$(slice_dependencies "$image" "$arch") || {
    fail "$image [$arch] dependency inspection failed"
    return
  }
  while IFS= read -r dependency; do
    [[ -n $dependency ]] || continue
    audit_dependency "$dependency" "$image" "$arch" "$root_executable" \
      "$rpaths" || return
  done <<<"$dependencies"
}

# This one shipped support role is intentionally Python. Validate the actual
# native interpreter, never an ambient PATH lookup or an arbitrary script role.
# Python owns its own runtime closure, not the SDK's six library search paths.
audit_interpreted_helper() {
  local helper=$1 first_line interpreter arch interpreter_archs required_archs
  [[ -x $helper ]] || { fail "interpreted helper is not executable: $helper"; return; }
  IFS= read -r first_line < "$helper"
  case "$first_line" in
    '#!'/nix/store/*) interpreter=${first_line#\#!} ;;
    *) fail "interpreted helper lacks a pinned store interpreter: $helper"; return ;;
  esac
  if [[ $interpreter == *[[:space:]]* || ! -x $interpreter ]]; then
    fail "interpreted helper has malformed or missing executable interpreter: $helper"
    return
  fi
  interpreter=$(realpath "$interpreter")
  case "$interpreter" in
    /nix/store/*) ;;
    *) fail "interpreted helper principal resolves outside the store: $interpreter"; return ;;
  esac
  interpreter_archs=$("$lipo_cmd" -archs "$interpreter" 2>/dev/null) || {
    fail "interpreted helper principal is not Mach-O: $interpreter"; return
  }
  required_archs=$("$lipo_cmd" -archs "$package_root/bin/.repro-wrapped")
  [[ -n $required_archs && -n $interpreter_archs ]] || {
    fail "interpreted helper principal has no architectures: $interpreter"; return
  }
  for arch in $required_archs; do
    case " $interpreter_archs " in
      *" $arch "*) ;;
      *) fail "interpreted helper principal lacks architecture $arch: $interpreter"; return ;;
    esac
  done
  for arch in $interpreter_archs; do
    audit_slice "$interpreter" "$arch" "$interpreter" 0
    if [[ $arch == arm64 || $arch == arm64e ]]; then
      "$codesign_cmd" --verify --strict "$interpreter" >/dev/null
    fi
  done
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
      "$package_root"/bin/.reprobuild-nix-daemon-wrapped)
        audit_interpreted_helper "$candidate"
        ;;
      "$package_root"/lib/*|"$package_root"/bin/.*-wrapped)
        fail "required binary/library role is not Mach-O: $candidate"
        ;;
    esac
  fi
done < <(find "$package_root/bin" "$package_root/lib" -maxdepth 1 -type f \
  -print0 | sort -z)

((macho_count > 0)) || fail "no Mach-O images found under $package_root"
