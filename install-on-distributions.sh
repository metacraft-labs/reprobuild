#!/usr/bin/env bash
# Reprobuild cross-platform POSIX installer.
#
# Dual-mode by design. This script is invoked two ways and must survive both:
#
#   1. `curl -fsSL <base>/install-on-distributions.sh | sh`  (the headline path)
#      A piped `curl | sh` ignores the shebang and runs under whatever `sh` is
#      -- dash on most Linux, bash-in-POSIX-mode on macOS. So the BODY must be
#      POSIX-portable: no process substitution, no `read -d`, no arrays, no
#      `[[ ]]`, no `BASH_SOURCE`, no RETURN traps, and no `set -o pipefail`
#      (dash rejects it). `local` is kept -- dash, busybox ash and macOS sh all
#      support it, and shellcheck (which reads the bash shebang) accepts it.
#
#   2. `./install-on-distributions.sh` from a developer checkout, under bash.
#
# Keep it shellcheck-clean AND dash-safe; the two are not the same constraint.
set -eu

PRODUCT="Reprobuild"
DEFAULT_FLAKE_REF="github:metacraft-labs/reprobuild#reprobuild"
# Public Cloudflare-fronted R2 host that serves the released binary archives and
# this installer (see .github/workflows/release.yml). Override for testing, e.g.
# the hermetic CI integration test points this at a local HTTP server.
DOWNLOAD_BASE="${REPROBUILD_DOWNLOAD_BASE:-https://downloads.reprobuild.com}"

# Temp dir cleaned up on any exit. Set by install_from_download; the trap is
# harmless while it is empty.
REPRO_TMP=""
cleanup() {
  [ -n "${REPRO_TMP}" ] && rm -rf "${REPRO_TMP}"
  return 0
}
trap cleanup EXIT INT TERM

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

# POSIX script-directory resolver based on $0 (BASH_SOURCE does not exist under
# dash, and a piped `curl | sh` has no script file at all -- there $0 is `sh`
# or `-`, `dirname` yields `.`, and have_local_checkout below correctly finds no
# apps/entrypoints.txt, steering to the download path).
script_dir() {
  local source dir
  source="$0"
  while [ -L "$source" ]; do
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

# True only for a developer checkout (piped `curl | sh` has none).
have_local_checkout() {
  local root
  root="$(script_dir 2>/dev/null)" || return 1
  [ -f "$root/apps/entrypoints.txt" ]
}

fetch() {
  local url="$1" out="$2"
  if have_command curl; then
    curl -fSL "$url" -o "$out"
  elif have_command wget; then
    wget -qO "$out" "$url"
  else
    eprint_error "need curl or wget to download ${PRODUCT}"
  fi
}

# reprobuild's .github/release-platforms.json names assets by <os>-<arch>, e.g.
# linux-x86_64, darwin-aarch64. Map the host to the published asset's tag.
detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) eprint_error "unsupported OS '$(uname -s)' for the binary installer; use --method nix-profile, or install.ps1 on Windows" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) eprint_error "unsupported architecture '$(uname -m)'" ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

verify_sha256() {
  local file="$1" expected="$2" actual=""
  if have_command sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif have_command shasum; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    eprint_warning "no sha256 tool found; skipping checksum verification"
    return 0
  fi
  [ "$actual" = "$expected" ] ||
    eprint_error "checksum mismatch for $(basename "$file") (expected ${expected}, got ${actual})"
}

# POSIX file-tree copy. The bin/ and lib/ trees hold simple leaf names (repro,
# *.so, *.dylib), so a glob loop is enough and avoids `find -print0`/`read -d`,
# neither of which is portable to dash.
copy_tree_files() {
  local source_dir="$1" target_dir="$2" mode="$3" path
  [ -d "$source_dir" ] || return 0
  mkdir -p "$target_dir"
  for path in "$source_dir"/*; do
    [ -e "$path" ] || continue
    [ -f "$path" ] || continue
    install "-m${mode}" "$path" "$target_dir/$(basename "$path")"
  done
}

path_hint() {
  local prefix="$1"
  if ! command -v repro >/dev/null 2>&1; then
    case ":$PATH:" in
      *":$prefix/bin:"*) ;;
      *) eprint_warning "$prefix/bin is not on PATH; add it to your shell profile to run 'repro'" ;;
    esac
  fi
}

# Primary path for `curl <base>/install-on-distributions.sh | sh`: fetch the
# pre-built binary archive from DOWNLOAD_BASE, sha256-verify it, and unpack the
# bin/+lib/ tree into a prefix. Mirrors the CodeTracer installer.
install_from_download() {
  local prefix channel platform asset url
  prefix="${REPROBUILD_INSTALL_PREFIX:-$HOME/.local}"
  channel="${REPROBUILD_CHANNEL:-latest}"
  platform="$(detect_platform)"
  asset="reprobuild-${channel}-${platform}.tar.gz"
  url="${DOWNLOAD_BASE}/${asset}"

  REPRO_TMP="$(mktemp -d)"

  eprint_note "Downloading ${asset} from ${DOWNLOAD_BASE}"
  fetch "$url" "$REPRO_TMP/$asset"

  if fetch "${url}.sha256" "$REPRO_TMP/$asset.sha256" 2>/dev/null; then
    verify_sha256 "$REPRO_TMP/$asset" "$(awk '{print $1}' "$REPRO_TMP/$asset.sha256")"
  else
    eprint_warning "no ${asset}.sha256 published; skipping checksum verification"
  fi

  eprint_note "Extracting ${PRODUCT} into ${prefix}"
  mkdir -p "$REPRO_TMP/unpacked"
  tar -xzf "$REPRO_TMP/$asset" -C "$REPRO_TMP/unpacked"

  # The archive is a bin/+lib/ tree, nested one directory deep
  # (reprobuild-<ver>-<platform>/bin, .../lib).
  local bindir root
  bindir="$(find "$REPRO_TMP/unpacked" -maxdepth 3 -type d -name bin | head -n 1)"
  [ -n "$bindir" ] || eprint_error "unexpected archive layout: no bin/ directory in ${asset}"
  root="$(dirname "$bindir")"

  eprint_note "Installing binaries into ${prefix}/bin"
  copy_tree_files "$root/bin" "$prefix/bin" 755
  eprint_note "Installing runtime libraries into ${prefix}/lib"
  copy_tree_files "$root/lib" "$prefix/lib" 755
  path_hint "$prefix"
  eprint_success
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
  local root prefix
  root="${REPROBUILD_SOURCE_ROOT:-$(script_dir)}"
  prefix="${REPROBUILD_INSTALL_PREFIX:-$HOME/.local}"

  [ -f "$root/apps/entrypoints.txt" ] ||
    eprint_error "cannot find Reprobuild source root at $root"

  ensure_local_build "$root"

  eprint_note "Installing binaries into $prefix/bin"
  copy_tree_files "$root/build/bin" "$prefix/bin" 755

  eprint_note "Installing runtime libraries into $prefix/lib"
  copy_tree_files "$root/build/lib" "$prefix/lib" 755

  path_hint "$prefix"
  eprint_success
}

usage() {
  cat <<'EOF'
Usage: install-on-distributions.sh [--method auto|download|nix-profile|local-prefix] [--prefix PATH]

Methods:
  auto          download a released binary (default for `curl | sh`); a developer
                checkout instead uses nix-profile or a local build.
  download      fetch the released binary archive from downloads.reprobuild.com.
  nix-profile   nix profile install the flake package.
  local-prefix  build from a local checkout and install into a prefix.

Environment:
  REPROBUILD_DOWNLOAD_BASE    Base URL for released archives
                              default: https://downloads.reprobuild.com
  REPROBUILD_CHANNEL          Release channel/version tag (e.g. latest, v1.2.3)
                              default: latest
  REPROBUILD_INSTALL_METHOD   Same values as --method; default: auto
  REPROBUILD_FLAKE_REF        Nix flake package to install
                              default: github:metacraft-labs/reprobuild#reprobuild
  REPROBUILD_INSTALL_PREFIX   Prefix for download/local-prefix installs
                              default: $HOME/.local
  REPROBUILD_SOURCE_ROOT      Source checkout for local-prefix installs
                              default: directory containing this script

Windows: use install.ps1 (`irm <base>/install.ps1 | iex`) instead of this script.
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
    -h | --help)
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
    # Piped `curl | sh` has no checkout -> install a released binary. A developer
    # checkout prefers nix (reproducible) or a local build.
    if have_local_checkout; then
      if have_command nix; then
        install_with_nix_profile
      fi
      install_from_local_checkout
    else
      install_from_download
    fi
    ;;
  download)
    install_from_download
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
