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
  # Windows-only branch (the .zip archive is the windows leg). `unzip` is NOT
  # guaranteed in the bash that runs this step: Git for Windows' bash ships a
  # GNU tar that cannot read zip, and unzip.exe is not part of every Git
  # install. Prefer unzip when present, but fall back to tools that always
  # exist on a Windows host -- PowerShell's Expand-Archive, or the
  # System32 bsdtar (libarchive tar.exe, which unlike GNU tar DOES read zip) --
  # so a missing unzip does not fail the release AFTER an hour of build time.
  if command -v unzip > /dev/null 2>&1; then
    unzip -q "$archive_path" -d "$tmp_dir"
  elif command -v powershell > /dev/null 2>&1 && command -v cygpath > /dev/null 2>&1; then
    echo "    unzip not found; extracting with PowerShell Expand-Archive"
    powershell -NoProfile -Command \
      "Expand-Archive -LiteralPath '$(cygpath -w "$archive_path")' -DestinationPath '$(cygpath -w "$tmp_dir")' -Force"
  elif [[ -x /c/Windows/System32/tar.exe ]]; then
    echo "    unzip not found; extracting with Windows bsdtar (System32\\tar.exe)"
    /c/Windows/System32/tar.exe -xf "$archive_path" -C "$tmp_dir"
  else
    echo "ERROR: cannot extract $archive_name -- no unzip, no PowerShell, no bsdtar available" >&2
    exit 1
  fi
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

# ── Windows: archive self-containment ────────────────────────────────────────
#
# Every non-system library reprobuild uses on Windows is dlopen'd by leaf name,
# not linked through the import table (`repro.exe` statically imports only
# ADVAPI32/KERNEL32/msvcrt). Win32's LoadLibrary searches the .exe's own
# directory first and PATH last, so the ONLY thing that makes a downloaded
# archive work on a machine that has never built reprobuild is the DLLs sitting
# in `bin/` next to the executables.
#
# Two independent checks, because each catches what the other cannot:
#
#   1. Manifest — assert each required DLL is present in the archive. Catches a
#      staging step that silently no-op'd, including for the lazily-loaded
#      libraries whose absence a smoke test would not reach.
#
#   2. Scrubbed PATH — run the smoke test with PATH reduced to the Windows
#      system directories. This is the check that was missing, and its absence
#      is the whole reason a gap could ship: the build host has clingo on its
#      machine PATH (a hand-provisioned C:\clingo, added outside this repo by
#      infra/machines/server/_windows-runner-001), plus C:\nim-dlls for sqlite.
#      Running the extracted binary with that PATH inherited meant the loader
#      resolved from the HOST what the ARCHIVE never contained, so the smoke
#      test passed on exactly the archives a user would find broken.
#
# Keep these in sync with the staging blocks in scripts/build_apps.sh.
if [[ "$archive_name" == *.zip ]]; then
  required_dlls=(
    clingo.dll             # repro_solver ASP bindings — dlopen'd at MODULE INIT
    vcruntime140.dll       # clingo.dll is MSVC-built; needs the VC++ redist
    vcruntime140_1.dll     #   (VCRUNTIME140_1.dll is the one minimal images lack)
    msvcp140.dll
    libcrypto-3-x64.dll    # OpenSSL, --define:ssl entry points
    libssl-3-x64.dll
    libzstd.dll            # repro cache substitute, zstd frame decompression
    sqlite3_64.dll         # repro_local_store
    sqlite3.dll
  )

  echo "=== Checking required runtime DLLs in $pkg_dir/bin ==="
  missing_dlls=()
  for dll in "${required_dlls[@]}"; do
    if [[ -f "$pkg_dir/bin/$dll" ]]; then
      echo "  ok      $dll"
    else
      echo "  MISSING $dll"
      missing_dlls+=("$dll")
    fi
  done
  if (( ${#missing_dlls[@]} > 0 )); then
    echo "ERROR: $archive_name is not self-contained; missing from bin/: ${missing_dlls[*]}" >&2
    echo "       These are dlopen'd by leaf name, so a user unpacking this archive on a" >&2
    echo "       clean machine gets 'could not load: <dll>'. Check the staging steps in" >&2
    echo "       scripts/build_apps.sh (clingo staging requires env.ps1 to have run)." >&2
    exit 1
  fi

  # Reduce PATH to the system directories only. cygpath is present in Git Bash
  # and MSYS2; the literal fallback covers a stripped-down bash.
  if command -v cygpath > /dev/null 2>&1; then
    win_root=$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")
  else
    win_root="/c/Windows"
  fi
  hermetic_path="${win_root}/System32:${win_root}:${win_root}/System32/Wbem"
  echo "=== Running smoke test with PATH scrubbed to '${hermetic_path}' ==="
  run_repro() { PATH="$hermetic_path" "$@"; }
else
  run_repro() { "$@"; }
fi

# Check version and help
run_repro "$repro_bin" --version
run_repro "$repro_bin" --help > /dev/null

# Check capabilities
capabilities=$(run_repro "$repro_bin" capabilities 2>&1)
echo "Capabilities: $capabilities"

# On Linux, run docker tests across multiple distros.
#
# This sweep is the glibc-compatibility gate: it is the only check that the
# Linux tarball runs anywhere other than the machine that produced it. It is
# also EXTRA coverage on top of the native smoke test above, so a host without
# a usable Docker must not fail the release outright -- that is what happened
# on every release since v0.1.0, where the `eph-linux-x64` runner class has no
# Docker (the fleet's nested-Docker capability lives on `eph-linux-x64-nested`)
# and this loop aborted the job with `docker: command not found` (exit 127),
# taking the Upload step with it. The Linux tarball was built and packaged
# fine; it just never got published.
#
# So: skip when Docker is unusable, but skip LOUDLY, and let a caller that
# knows Docker should be present turn the skip back into a failure with
# REPRO_VERIFY_REQUIRE_DOCKER=1 -- otherwise "no Docker" would silently become
# the permanent normal and the sweep would quietly stop protecting anything.
if [[ "$(uname -s)" == Linux* ]]; then
  docker_status=""
  if ! command -v docker > /dev/null 2>&1; then
    docker_status="docker is not on PATH"
  elif ! docker info > /dev/null 2>&1; then
    docker_status="docker is installed but its daemon is not reachable"
  fi

  if [[ -n "$docker_status" ]]; then
    if [[ "${REPRO_VERIFY_REQUIRE_DOCKER:-0}" == "1" ]]; then
      echo "ERROR: $docker_status, and REPRO_VERIFY_REQUIRE_DOCKER=1." >&2
      echo "       The multi-distro glibc sweep cannot run. Either use a runner" >&2
      echo "       class with nested Docker (eph-linux-x64-nested) or clear the" >&2
      echo "       flag to accept reduced coverage." >&2
      exit 1
    fi
    echo "=== SKIPPING multi-distro Docker sweep: $docker_status ==="
    echo "    Reduced coverage: the archive was smoke-tested only on this host's"
    echo "    glibc, not against ubuntu/debian/fedora/almalinux. Set"
    echo "    REPRO_VERIFY_REQUIRE_DOCKER=1 to make this a hard failure."
  else
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
fi

echo "=== Smoke test PASSED successfully for $archive_name ==="
