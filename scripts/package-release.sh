#!/usr/bin/env bash
# package-release.sh — assemble a portable reprobuild release archive
# from the contents of ./build/.
#
# Layout produced inside the archive (per docs/PACKAGING.md):
#
#   reprobuild-<ver>-<triple>/
#     bin/        — repro + sibling binaries (+ clingo.dll on Windows)
#     lib/        — librepro_monitor_shim.*, librepro_project_dsl_runtime.*
#     README.md
#     LICENSE
#     docs/PACKAGING.md
#
# A `<archive>.sha256` companion file is emitted next to the archive.
#
# Usage:
#   scripts/package-release.sh --version 1.4.0 --out-dir dist [--triple TRIPLE]
#
# The triple defaults to one of the MR17 canonical names, derived from
# `uname -s` / `uname -m`:
#
#   Linux x86_64  -> x86_64-unknown-linux-gnu
#   Linux aarch64 -> aarch64-unknown-linux-gnu
#   Darwin x86_64 -> x86_64-apple-darwin
#   Darwin arm64  -> aarch64-apple-darwin
#   MSYS/MINGW    -> x86_64-pc-windows-msvc   (see also package-release.ps1)
#
# The Windows-native packaging path lives in scripts/package-release.ps1;
# this bash script is also runnable under MSYS2 / Git Bash but emits a
# .tar.gz instead of a .zip — release.yml uses the PowerShell variant
# on `windows-latest` so the published artifact is a .zip per spec.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<USAGE
usage: scripts/package-release.sh --version <ver> --out-dir <dir> [--triple <triple>] [--build-dir <dir>]

Required:
  --version VER       Release version, e.g. 1.4.0 or 0.0.1-dev
  --out-dir  DIR      Destination directory for the archive + .sha256

Optional:
  --triple   TRIPLE   Target triple (auto-detected from uname when absent)
  --build-dir DIR     Directory holding bin/ and lib/ (default: ./build)
  --repo-root DIR     Reprobuild source root (default: cwd)
  -h | --help         Show this help and exit
USAGE
}

version=""
out_dir=""
triple=""
build_dir=""
repo_root=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)   version="$2";   shift 2 ;;
    --out-dir)   out_dir="$2";   shift 2 ;;
    --triple)    triple="$2";    shift 2 ;;
    --build-dir) build_dir="$2"; shift 2 ;;
    --repo-root) repo_root="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)
      err "package-release.sh: unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "${version}" ] || [ -z "${out_dir}" ]; then
  err "package-release.sh: --version and --out-dir are required"
  usage
  exit 2
fi

# Strip a leading `v` from the version (so `v1.4.0` and `1.4.0` both work).
version="${version#v}"

if [ -z "${repo_root}" ]; then
  repo_root="$(pwd)"
fi
if [ -z "${build_dir}" ]; then
  build_dir="${repo_root}/build"
fi

if [ ! -d "${build_dir}/bin" ]; then
  err "package-release.sh: ${build_dir}/bin does not exist; run 'just build' first"
  exit 3
fi

# --- Triple auto-detection ---------------------------------------------------
if [ -z "${triple}" ]; then
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "${uname_s}-${uname_m}" in
    Linux-x86_64)        triple="x86_64-unknown-linux-gnu" ;;
    Linux-aarch64)       triple="aarch64-unknown-linux-gnu" ;;
    Linux-arm64)         triple="aarch64-unknown-linux-gnu" ;;
    Darwin-x86_64)       triple="x86_64-apple-darwin" ;;
    Darwin-arm64)        triple="aarch64-apple-darwin" ;;
    MINGW*-*|MSYS*-*|CYGWIN*-*)
      triple="x86_64-pc-windows-msvc" ;;
    *)
      err "package-release.sh: cannot auto-detect triple for ${uname_s} ${uname_m}; pass --triple"
      exit 2
      ;;
  esac
fi

# --- Archive format per OS ---------------------------------------------------
case "${triple}" in
  *windows*)
    archive_ext="zip"
    ;;
  *)
    archive_ext="tar.gz"
    ;;
esac

stage_name="reprobuild-${version}-${triple}"
mkdir -p "${out_dir}"
stage_dir="${out_dir}/${stage_name}"
rm -rf "${stage_dir}"
mkdir -p "${stage_dir}/bin" "${stage_dir}/lib" "${stage_dir}/docs"

echo "staging ${stage_dir}"

# bin/ — copy everything from build/bin (includes clingo.dll on Windows).
cp -R "${build_dir}/bin/." "${stage_dir}/bin/"

# lib/ — optional; on builds that didn't produce a shared lib (unusual
# cross-builds) the directory is absent and we just leave it empty so
# the layout is still consistent.
if [ -d "${build_dir}/lib" ]; then
  # Skip backup files (*.old.* — see scripts/build_apps.sh on Windows).
  find "${build_dir}/lib" -maxdepth 1 -type f \
    ! -name '*.old.*' \
    -exec cp {} "${stage_dir}/lib/" \;
fi

# Top-level metadata.
for f in README.md LICENSE; do
  if [ -f "${repo_root}/${f}" ]; then
    cp "${repo_root}/${f}" "${stage_dir}/${f}"
  else
    err "package-release.sh: warning — ${f} missing at ${repo_root}/${f}"
  fi
done

# docs/PACKAGING.md goes under docs/ to preserve the source path; recipes
# and SBOM are deferred (see docs/PACKAGING.md > "Open Items").
if [ -f "${repo_root}/docs/PACKAGING.md" ]; then
  cp "${repo_root}/docs/PACKAGING.md" "${stage_dir}/docs/PACKAGING.md"
fi

# Embed a tiny VERSION file so `repro --version` and the archive name
# always agree and so downstream installers can sanity-check.
printf 'reprobuild %s\ntriple %s\n' "${version}" "${triple}" \
  > "${stage_dir}/VERSION"

# --- Archive -----------------------------------------------------------------
archive_path="${out_dir}/${stage_name}.${archive_ext}"
rm -f "${archive_path}"

echo "building ${archive_path}"
case "${archive_ext}" in
  tar.gz)
    # -C so the archive's top-level entry is the stage dir itself rather
    # than a long ./out/dir/… prefix; --owner/--group keep ownership
    # deterministic for byte-identical reproducibility (when paired with
    # a stable mtime — left to the caller / CI workflow today).
    if tar --help 2>&1 | grep -q -- '--owner'; then
      tar -C "${out_dir}" \
        --owner=0 --group=0 \
        -czf "${archive_path}" "${stage_name}"
    else
      # BSD tar (macOS): no --owner / --group; rely on --uid / --gid.
      tar -C "${out_dir}" \
        --uid 0 --gid 0 \
        -czf "${archive_path}" "${stage_name}"
    fi
    ;;
  zip)
    # Prefer the system `zip` when present (MSYS2 ships it); fall back
    # to bsdtar's zip mode (BSD `tar -a` infers format from extension).
    if command -v zip >/dev/null 2>&1; then
      ( cd "${out_dir}" && zip -qr "${archive_path}" "${stage_name}" )
    elif tar --version 2>&1 | grep -qi bsdtar; then
      ( cd "${out_dir}" && tar -a -cf "${archive_path}" "${stage_name}" )
    else
      err "package-release.sh: need either 'zip' or bsdtar to produce ${archive_path}"
      exit 4
    fi
    ;;
esac

# --- Checksum ----------------------------------------------------------------
sha_path="${archive_path}.sha256"
( cd "${out_dir}" && \
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${stage_name}.${archive_ext}" > "$(basename "${sha_path}")"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${stage_name}.${archive_ext}" > "$(basename "${sha_path}")"
  else
    err "package-release.sh: no sha256sum / shasum on PATH; skipping checksum"
    exit 5
  fi
)

echo "wrote ${archive_path}"
echo "wrote ${sha_path}"

# Emit machine-readable metadata for downstream steps (release.yml uses
# this to set per-matrix outputs).
cat <<EOF
::set-output-key archive_path=${archive_path}
::set-output-key sha256_path=${sha_path}
::set-output-key stage_name=${stage_name}
::set-output-key triple=${triple}
EOF
