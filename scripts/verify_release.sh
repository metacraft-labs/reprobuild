#!/usr/bin/env bash
# verify_release.sh — Verify that reprobuild binaries run cleanly when unzipped/untarred.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-archive>" >&2
  exit 64
fi

archive_path="$1"
# Get the absolute path to the archive
if [[ ! "$archive_path" =~ ^/|[a-zA-Z]:\\ ]]; then
  archive_path="$(pwd)/$archive_path"
fi

archive_name=$(basename "$archive_path")
mkdir -p "$(pwd)/build"
tmp_dir=$(mktemp -d "$(pwd)/build/reprobuild-verify-XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

echo "=== Extracting $archive_name to $tmp_dir ==="
if [[ "$archive_name" == *.zip ]]; then
  unzip -q "$archive_path" -d "$tmp_dir"
else
  tar -xzf "$archive_path" -C "$tmp_dir"
fi

# Find the unzipped directory (it should contain bin/ and lib/)
pkg_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [[ -z "$pkg_dir" ]]; then
  echo "ERROR: Failed to locate extracted package directory in $tmp_dir" >&2
  exit 1
fi

repro_bin="$pkg_dir/bin/repro"
if [[ "$archive_name" == *.zip ]]; then
  repro_bin="${repro_bin}.exe"
fi

echo "=== Verifying binary execution at $repro_bin ==="
if [[ ! -f "$repro_bin" ]]; then
  echo "ERROR: repro executable not found at $repro_bin" >&2
  exit 1
fi

# Check version and help
"$repro_bin" --version
"$repro_bin" --help > /dev/null

# Check capabilities
capabilities=$("$repro_bin" capabilities 2>&1)
echo "Capabilities: $capabilities"

# On Linux, run docker tests across multiple distros
if [[ "$(uname -s)" == Linux* ]]; then
  distros=(
    "ubuntu:24.04"
    "ubuntu:22.04"
    "debian:12"
    "debian:11"
    "fedora:40"
    "almalinux:9"
  )
  
  for distro in "${distros[@]}"; do
    echo "=== Running smoke test on Docker distro: $distro ==="
    # Mount the worktree-specific package directory read-only
    docker run --rm \
      -v "${pkg_dir}:/reprobuild:ro" \
      "$distro" \
      /reprobuild/bin/repro --version
  done
  echo "=== All Linux distros passed! ==="
fi

echo "=== Smoke test PASSED successfully for $archive_name ==="
