#!/usr/bin/env bash
set -euo pipefail

PRODUCT="Reprobuild"
DEFAULT_FLAKE_REF="github:metacraft-labs/reprobuild#reprobuild"

eprint_note() {
  echo "[${PRODUCT} installer] $1" >&2
}

eprint_error() {
  printf '\033[31m[%s installer Error]: %s\033[0m\n' "${PRODUCT}" "$1" >&2
  exit 1
}

eprint_warning() {
  printf '\033[33m[%s installer Warning]: %s\033[0m\n' "${PRODUCT}" "$1" >&2
}

eprint_success() {
  printf '\033[32mSuccessfully installed %s. Run '\''repro --help'\'' to get started.\033[0m\n' "${PRODUCT}" >&2
  exit 0
}

script_dir() {
  local source="${BASH_SOURCE[0]}"
  while [ -L "$source" ]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    case "$source" in
      /*) ;;
      *) source="$dir/$source" ;;
    esac
  done
  cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

install_with_nix_profile() {
  local flake_ref="${REPROBUILD_FLAKE_REF:-$DEFAULT_FLAKE_REF}"

  if ! have_command nix; then
    return 1
  fi

  eprint_note "Installing ${PRODUCT} with nix profile from ${flake_ref}"
  nix profile install "$flake_ref" || eprint_error "nix profile install failed"
  eprint_success
}

copy_tree_files() {
  local source_dir="$1"
  local target_dir="$2"
  local mode="$3"

  [ -d "$source_dir" ] || return 0
  mkdir -p "$target_dir"

  local path
  while IFS= read -r -d '' path; do
    install "-m${mode}" "$path" "$target_dir/$(basename "$path")"
  done < <(find "$source_dir" -maxdepth 1 -type f -print0)
}

ensure_local_build() {
  local root="$1"

  if [ -x "$root/build/bin/repro" ]; then
    return 0
  fi

  if ! have_command just; then
    eprint_error "local install needs an existing build/bin/repro or 'just' on PATH"
  fi

  eprint_note "Building ${PRODUCT} from local checkout"
  (cd "$root" && just build) || eprint_error "local build failed"
}

install_from_local_checkout() {
  local root="${REPROBUILD_SOURCE_ROOT:-$(script_dir)}"
  local prefix="${REPROBUILD_INSTALL_PREFIX:-$HOME/.local}"

  [ -f "$root/apps/entrypoints.txt" ] ||
    eprint_error "cannot find Reprobuild source root at $root"

  ensure_local_build "$root"

  eprint_note "Installing binaries into $prefix/bin"
  copy_tree_files "$root/build/bin" "$prefix/bin" 755

  eprint_note "Installing runtime libraries into $prefix/lib"
  copy_tree_files "$root/build/lib" "$prefix/lib" 755

  if ! command -v repro >/dev/null 2>&1; then
    case ":$PATH:" in
      *":$prefix/bin:"*) ;;
      *) eprint_warning "$prefix/bin is not on PATH; add it to your shell profile to run 'repro'" ;;
    esac
  fi

  eprint_success
}

usage() {
  cat <<'EOF'
Usage: install-on-distributions.sh [--method auto|nix-profile|local-prefix] [--prefix PATH]

Environment:
  REPROBUILD_FLAKE_REF        Nix flake package to install
                              default: github:metacraft-labs/reprobuild#reprobuild
  REPROBUILD_INSTALL_PREFIX   Prefix for local-prefix installs
                              default: $HOME/.local
  REPROBUILD_SOURCE_ROOT      Source checkout for local-prefix installs
                              default: directory containing this script
EOF
}

method="${REPROBUILD_INSTALL_METHOD:-auto}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --method)
      [ "$#" -ge 2 ] || eprint_error "--method requires an argument"
      method="$2"
      shift 2
      ;;
    --prefix)
      [ "$#" -ge 2 ] || eprint_error "--prefix requires an argument"
      export REPROBUILD_INSTALL_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      eprint_error "unknown argument: $1"
      ;;
  esac
done

case "$method" in
  auto)
    if have_command nix; then
      install_with_nix_profile
    fi
    eprint_warning "nix was not found; falling back to local prefix install"
    install_from_local_checkout
    ;;
  nix-profile)
    install_with_nix_profile ||
      eprint_error "nix was not found"
    ;;
  local-prefix)
    install_from_local_checkout
    ;;
  *)
    eprint_error "unsupported install method: $method"
    ;;
esac
