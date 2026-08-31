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
  # ── Launchability preflight: can these entry points exec OFF this host? ────
  #
  # Run this BEFORE reaching for Docker, because the sweep's failure mode is
  # actively misleading. `exec /reprobuild/bin/repro: no such file or directory`
  # names the executable but is the kernel reporting a missing PT_INTERP: the
  # file is mounted, is executable, and ran natively two lines above -- it is
  # its *dynamic loader* that does not exist in the container. Chasing that
  # message as a mount/path bug is the expensive wrong turn, so the sweep must
  # never be the thing that reports it.
  #
  # The `.#release` build links with the nix toolchain, so a raw-copied tree's
  # entry points carry a `/nix/store/…-glibc-…/lib/ld-linux-*.so` interpreter
  # that no distro image has. scripts/relocate_release_posix.sh (run from the
  # POSIX packaging step) replaces each `bin/<app>` with a /bin/sh wrapper that
  # execs the BUNDLED loader, so a relocated tree has no ELF entry point left to
  # be store-bound. That is exactly the property the classifier below reads.
  #
  # Pick ONE reader up front and print which. A reader that silently degrades
  # would report "no interpreters found", and an empty scan satisfies every
  # negative check written over it.
  if command -v patchelf > /dev/null 2>&1; then
    interp_reader=patchelf
  elif command -v readelf > /dev/null 2>&1; then
    interp_reader=readelf
  else
    # Read the program headers directly rather than giving up: a classifier
    # that cannot read is a classifier that cannot fail.
    interp_reader=odparse
  fi

  is_elf() {
    [[ -f "$1" ]] &&
      [[ "$(LC_ALL=C od -An -tx1 -N4 "$1" 2> /dev/null | tr -d ' \n')" == "7f454c46" ]]
  }

  # Little-endian unsigned integer of <size> bytes at <offset> of <file>.
  le_num() {
    local b v=0 s=0
    for b in $(LC_ALL=C od -An -tu1 -j "$2" -N "$3" "$1"); do
      v=$((v + (b << s)))
      s=$((s + 8))
    done
    printf '%s\n' "$v"
  }

  # Exact PT_INTERP via the program-header table. Deliberately NOT a `strings`
  # scan for something that looks like a loader path: `.interp` is preceded by
  # `.note.gnu.build-id`, whose random bytes carry no NUL terminator, so the
  # path does not start a line and a `^/…/ld…` pattern silently matches nothing
  # -- a fallback reader that always returns "no interpreter" would classify
  # every store-bound archive as portable.
  od_interp() {
    local f="$1" phoff phentsize phnum i off ptype poff pfsz
    [[ "$(le_num "$f" 4 1)" == "2" ]] || { printf '!unreadable\n'; return 0; } # ELFCLASS64
    [[ "$(le_num "$f" 5 1)" == "1" ]] || { printf '!unreadable\n'; return 0; } # ELFDATA2LSB
    phoff=$(le_num "$f" 32 8)
    phentsize=$(le_num "$f" 54 2)
    phnum=$(le_num "$f" 56 2)
    for ((i = 0; i < phnum; i++)); do
      off=$((phoff + i * phentsize))
      ptype=$(le_num "$f" "$off" 4)
      if ((ptype == 3)); then # PT_INTERP
        poff=$(le_num "$f" $((off + 8)) 8)
        pfsz=$(le_num "$f" $((off + 32)) 8)
        LC_ALL=C dd if="$f" bs=1 skip="$poff" count="$pfsz" 2> /dev/null | tr -d '\0'
        printf '\n'
        return 0
      fi
    done
  }

  read_interp() {
    case "$interp_reader" in
      patchelf) patchelf --print-interpreter "$1" 2> /dev/null || true ;;
      readelf)
        readelf -lW "$1" 2> /dev/null |
          sed -nE 's/.*program interpreter: ([^]]+)\].*/\1/p' | head -n1
        ;;
      odparse) od_interp "$1" ;;
    esac
  }

  entry_points=0
  entry_elfs=0
  store_bound=()
  unreadable=()
  scanned_repro=0
  for app in "$pkg_dir"/bin/*; do
    [[ -f "$app" && -x "$app" ]] || continue
    entry_points=$((entry_points + 1))
    # An `if`, not `[[ … ]] && x=1`: under `set -e` an AND-OR list whose first
    # command fails takes the list's non-zero status with it.
    if [[ "$(basename "$app")" == "repro" ]]; then
      scanned_repro=1
    fi
    is_elf "$app" || continue
    entry_elfs=$((entry_elfs + 1))
    interp="$(read_interp "$app")"
    case "$interp" in
      "!unreadable") unreadable+=("$(basename "$app")") ;;
      /nix/store/*) store_bound+=("$(basename "$app") -> $interp") ;;
    esac
  done

  echo "=== Launchability preflight (interpreter reader: ${interp_reader}) ==="
  echo "    executable entry points in bin/: ${entry_points} (${entry_elfs} ELF, $((entry_points - entry_elfs)) wrapper/script)"

  # Positive control on the scan. Everything below is a "must not contain"
  # question, and universal quantification over an empty set is a free pass --
  # so assert the scan reached the tree before trusting what it did not find.
  # `repro` specifically must be among them: it is the archive's reason to
  # exist, and verify_release.sh already located it above.
  if ((entry_points == 0)); then
    echo "ERROR: no executable entry points found in $pkg_dir/bin." >&2
    echo "       The launchability scan reached nothing, so it can neither pass" >&2
    echo "       nor fail honestly. Check the packaging step's cp of build/bin." >&2
    exit 1
  fi
  if ((scanned_repro == 0)); then
    echo "ERROR: the launchability scan did not see 'repro' among the ${entry_points}" >&2
    echo "       entry points in $pkg_dir/bin, yet $repro_bin exists. The scan is" >&2
    echo "       reading a different tree than the smoke test did." >&2
    exit 1
  fi
  # "Could not read it" must never be spelled the same way as "it was clean".
  if ((${#unreadable[@]} > 0)); then
    echo "ERROR: could not read the ELF interpreter of: ${unreadable[*]}" >&2
    echo "       (reader: ${interp_reader}). Refusing to classify this archive:" >&2
    echo "       an unreadable binary would otherwise be counted as portable." >&2
    echo "       Install patchelf or binutils (readelf) on this host." >&2
    exit 1
  fi

  # State the classification UNCONDITIONALLY, before anything about Docker. It
  # is a property of the archive, not of this host, and burying it inside the
  # "Docker is usable" branch would hide it on exactly the hosts where the
  # sweep cannot run and the fact matters most.
  if ((${#store_bound[@]} > 0)); then
    echo "    NOT relocated: ${#store_bound[@]} of ${entry_elfs} ELF entry point(s) name an interpreter under /nix/store:"
    printf '      %s\n' "${store_bound[@]}"
  else
    echo "    Relocated: no ELF entry point requests a /nix/store interpreter."
  fi

  docker_status=""
  if ((${#store_bound[@]} > 0)); then
    # This is a DIAGNOSIS, not a symptom. Say it here, once, in the terms that
    # identify the fix -- rather than letting `docker run` say ENOENT about a
    # file that is right there.
    if [[ "${REPRO_VERIFY_REQUIRE_DOCKER:-0}" == "1" ]]; then
      echo "ERROR: this archive cannot run off the build host: its entry points" >&2
      echo "       request a dynamic loader under /nix/store, which exists on no" >&2
      echo "       distro image (and on no user's machine). Every distro in the" >&2
      echo "       sweep would report 'exec …/bin/repro: no such file or directory'," >&2
      echo "       which is the kernel reporting the MISSING INTERPRETER above --" >&2
      echo "       not a missing or mis-mounted binary." >&2
      echo "       Fix: run scripts/relocate_release_posix.sh over the packaged" >&2
      echo "       tree before archiving it, as release.yml's POSIX packaging step" >&2
      echo "       does. REPRO_VERIFY_REQUIRE_DOCKER=1 means this caller asked for" >&2
      echo "       real multi-distro coverage, so this is a failure, not a skip." >&2
      exit 1
    fi
    docker_status="the archive is not relocated (see the /nix/store interpreters above)"
  elif ! command -v docker > /dev/null 2>&1; then
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
    echo "    NOT COVERED: this archive has not been shown to run on any machine"
    echo "    other than the one that built it. It was smoke-tested only against"
    echo "    THIS host's loader and glibc, not against"
    echo "    ubuntu/debian/fedora/almalinux. Set REPRO_VERIFY_REQUIRE_DOCKER=1"
    echo "    to make this a hard failure (release.yml does)."
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
