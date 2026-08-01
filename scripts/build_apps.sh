#!/usr/bin/env bash
set -euo pipefail

# Disable active dynamic injection hooks (DYLD_INSERT_LIBRARIES / LD_PRELOAD) during the build process.
# This prevents tools (like mv, cp, ld) from failing to load active shims that are currently being rebuilt.
unset DYLD_INSERT_LIBRARIES
unset LD_PRELOAD

mkdir -p build/bin build/lib build/nimcache

# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh

if [ -z "${BEARSSL_SRC:-}" ]; then
  bearssl_store_src="$(find /nix/store -maxdepth 1 -type d -name '*nim-bearssl-*' -print -quit 2>/dev/null || true)"
  if [ -n "${bearssl_store_src}" ] && [ -f "${bearssl_store_src}/bearssl.nim" ]; then
    export BEARSSL_SRC="${bearssl_store_src}"
  fi
fi

nim_mode_flags=()
case "${REPROBUILD_BUILD_MODE:-debug}" in
  debug)
    ;;
  release)
    nim_mode_flags+=("-d:release")
    ;;
  *)
    echo "unsupported REPROBUILD_BUILD_MODE=${REPROBUILD_BUILD_MODE}; expected debug or release" >&2
    exit 2
    ;;
esac

# Incremental-Test-Runner M7: the interpose monitor shim
# (``librepro_monitor_shim.{dylib,so,dll}``) is now produced by the shared
# ``io-mon`` sibling rather than reprobuild's deleted ``repro_monitor_shim``
# library. io-mon's ``scripts/build_shim.sh`` is the byte-identical relocation
# of the shim build above — same shared-library name, same exported interpose
# ABI (the ``repro_*`` / ``ct_linux_*`` symbols + the macOS
# ``__DATA,__interpose`` section), same per-platform flags (macOS arm64/arm64e
# fat build, Linux PRELOAD, Windows IAT DLL) — so the runtime contract every
# consumer locates via ``findShimLibrary`` is unchanged. We point its output
# at reprobuild's ``build/lib`` (``IO_MON_SHIM_OUT_DIR``) so the library lands
# exactly where ``candidateShimLibraries`` expects (``<cwd>/build/lib`` and
# ``<appDir>/../lib``). io-mon resolves nim-stackable-hooks at
# ``../nim-stackable-hooks/src`` (override with ``$STACKABLE_HOOKS_SRC``),
# the same sibling reprobuild's monitor tests use.
io_mon_src="${IO_MON_SRC:-../io-mon}"
# M9.R.33 drive-by — env.ps1 + the cross-OS dev shell wire IO_MON_SRC to
# the io-mon ``src/`` dir (consistent with the way reprobuild's
# ``config.nims`` switch("path", ioMonSrc) lookup picks up
# ``<root>/src/io_mon.nim``).  This script wants the io-mon repo ROOT
# so ``scripts/build_shim.sh`` resolves.  Strip a trailing ``/src``
# segment (with either separator — the Windows env.ps1 hands us
# ``...\io-mon\src`` with backslashes, so the ``/src`` glob would
# otherwise leave the trailing segment attached) so the same env value
# works for both consumers.
case "$io_mon_src" in
  */src)   io_mon_src="${io_mon_src%/src}" ;;
  *\\src)  io_mon_src="${io_mon_src%\\src}" ;;
esac
if [ ! -x "${io_mon_src}/scripts/build_shim.sh" ]; then
  echo "missing io-mon shim builder at ${io_mon_src}/scripts/build_shim.sh; set IO_MON_SRC" >&2
  exit 2
fi
# SHM-QUEUE-MIGRATE: io-mon's shim (its dep queue) + reprobuild's action-cache
# ring BOTH sit on the extracted ``shm_queue/ring`` MPSC ring (nim-shm-queue).
shm_queue_src="$(resolve_shm_queue_src)"
export SHM_QUEUE_SRC="${shm_queue_src}"

# Platform detection must not depend on an external ``uname``.
#
# This script runs BOTH directly (``just bootstrap``) and as a monitored build
# action under ``repro build``. In the monitored case on macOS the engine
# injects the io-mon shim into every child process, and ``$(uname -s)`` has
# been observed to expand to the EMPTY string there: the v0.1.3 release's macOS
# leg died on ``unsupported platform  for the io-mon shim`` -- note the doubled
# space where the platform name should be -- 3 minutes after the very same
# script had run this same dispatch successfully outside the engine.
#
# An empty ``uname`` is worse than a hard failure here, because two of the case
# statements below carry a ``*)`` arm that silently means "Linux": ``dll_ext``
# would resolve to ``so`` on macOS and the build would emit
# ``librepro_project_dsl_runtime.so`` where repro.nim's macOS branch expects
# ``.dylib``. That is a wrong artifact, not a stopped build.
#
# ``$OSTYPE`` is a bash builtin -- no fork, no PATH lookup, nothing for a
# monitoring shim to interpose. Consult it first, fall back to ``uname -s``,
# and REFUSE to continue when neither answers rather than guessing.
repro_host_platform() {
  case "${OSTYPE:-}" in
    darwin*) printf 'darwin\n'; return 0 ;;
    linux*) printf 'linux\n'; return 0 ;;
    msys*|cygwin*|win32) printf 'windows\n'; return 0 ;;
  esac
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) printf 'darwin\n'; return 0 ;;
    Linux) printf 'linux\n'; return 0 ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf 'windows\n'; return 0 ;;
  esac
  return 1
}

if ! REPRO_HOST_PLATFORM="$(repro_host_platform)"; then
  echo "error: cannot determine the host platform." >&2
  echo "       \$OSTYPE='${OSTYPE:-}'; 'uname -s' gave '$(uname -s 2>/dev/null || true)'." >&2
  echo "       Refusing to guess: the dynamic-library extension and every" >&2
  echo "       staging step below depend on it, and a wrong guess silently" >&2
  echo "       produces the wrong artifact instead of stopping." >&2
  exit 2
fi
export REPRO_HOST_PLATFORM

case "${REPRO_HOST_PLATFORM}" in
  windows)
    dll_ext="dll" ;;
  darwin)
    dll_ext="dylib" ;;
  *)
    dll_ext="so" ;;
esac

# Point BOTH the shim's output dir and its nimcache at reprobuild's own
# (writable) build tree. io-mon's source is read-only when it comes from a Nix
# flake input / store path (the package build + dev shell), so the shim must not
# write its nimcache into its own source — pass an absolute writable dir.
mkdir -p build/lib/tmp
IO_MON_SHIM_OUT_DIR="$(pwd)/build/lib/tmp" \
IO_MON_SHIM_NIMCACHE_DIR="$(pwd)/build/nimcache/io-mon-shim" \
IO_MON_BUILD_MODE="${REPROBUILD_BUILD_MODE:-debug}" \
SHM_QUEUE_SRC="${shm_queue_src}" \
  bash "${io_mon_src}/scripts/build_shim.sh"

# Publishing the shim = replacing the library this very process's children are
# being monitored with.
#
# When this script runs as the ``reprobuild.build_apps`` engine action it is
# monitor-wrapped: the engine exports REPRO_MONITOR_SHIM_LIB pointing at
# ``build/lib/librepro_monitor_shim.<ext>`` and injects it into every child. The
# lines below used to move that exact file aside and swap a freshly built one
# into its place WHILE the action was still spawning children. repro.nim's own
# comment on the shim edge already names the hazard: "Running that compiler
# process under the same preload shim can trigger host compiler ICEs."
#
# So the build and the publish are now separate steps, per the house pattern for
# this class of problem: build the binary in one location, copy it into the live
# location in a FOLLOW-UP edge, once nothing is spawning children against it.
# ``REPRO_DEFER_SHIM_PUBLISH=1`` (set by the engine action in repro.nim, which
# then runs ``reprobuild.build_apps.publish_monitor_shim`` afterwards) stops this
# script from doing the swap in-band. Standalone runs (``just bootstrap`` /
# ``just build``) are not monitored and keep publishing inline, so local
# workflows are unchanged.
staged_shim="build/lib/tmp/librepro_monitor_shim.${dll_ext}"
if [ ! -f "${staged_shim}" ]; then
  echo "error: io-mon shim builder did not produce ${staged_shim}" >&2
  exit 2
fi
if [ "${REPRO_DEFER_SHIM_PUBLISH:-0}" = "1" ]; then
  echo "Staged ${staged_shim}; publish deferred to the follow-up edge."
else
  if [ -f "build/lib/librepro_monitor_shim.${dll_ext}" ]; then
    mv -f "build/lib/librepro_monitor_shim.${dll_ext}" "build/lib/librepro_monitor_shim.${dll_ext}.old" || true
  fi
  mv -f "${staged_shim}" "build/lib/librepro_monitor_shim.${dll_ext}"
  rm -rf build/lib/tmp
fi

# M9.R.47.3 — clear LD_LIBRARY_PATH and NIX_LDFLAGS for every ``nim c``
# invocation in this loop so Nim's compile-time ``{.dynlib: <const>.}``
# resolution (``stdlib.dynlib.libCandidates`` walking those vars when the
# nixpkgs-shipped Nim was built with ``define:nixbuild``) cannot bake an
# absolute ``/nix/store/<hash>-<pkg>/lib/<name>.so`` path into the
# binary's .rodata.
#
# Background: the M9.R.46 stage-time /nix/store -> /repro/store relocation
# rewrites every ELF's DT_RUNPATH, DT_NEEDED, and PT_INTERP, but it cannot
# touch .rodata.  A baked dlopen path inside a Nim binding (e.g. clingo's
# libclingo.so) therefore breaks ``repro hardware probe`` on the installed
# system — the user's M9.R.46 task brief documented exactly this failure.
#
# Workaround scope: only the nim-compile path needs these vars cleared.
# Runtime (re-)exporting LD_LIBRARY_PATH to point at clingo still works for
# the engine's runtime dlopen lookup; the M9.R.46 relocate + the M9.R.46.6
# glibc-cache carve-out cover the installed-system path.
unset_clingo_searchpath() {
  unset LD_LIBRARY_PATH
  unset NIX_LDFLAGS
}

# M9.R.47.4 — restore OpenSSL's link search dir for --define:ssl entrypoints.
# unset_clingo_searchpath clears NIX_LDFLAGS for every ``nim c`` above, but
# NIX_LDFLAGS is also the *only* carrier of OpenSSL's
# ``-L/nix/store/<hash>-openssl-<ver>/lib`` in this dev shell (there is no
# pkg-config ``openssl.pc`` here). An entrypoint compiled with --define:ssl
# (e.g. repro-harvest-apt, which talks HTTPS to snapshot.debian.org) therefore
# fails to link ``-lcrypto``/``-lssl`` once NIX_LDFLAGS is gone.
#
# Capture OpenSSL's -L from the original NIX_LDFLAGS *here*, while it is still
# set in this parent shell (the unset only happens inside the per-entrypoint
# subshells), and replay it via --passL only for ssl entrypoints. The store
# hash is derived from NIX_LDFLAGS rather than hardcoded, and non-ssl
# entrypoints are byte-identical (they never receive openssl_passl). The
# NIX_LDFLAGS/LD_LIBRARY_PATH clearing for the .rodata-bake guard is preserved.
openssl_passl=()
for tok in ${NIX_LDFLAGS:-}; do
  case "$tok" in
    -L*openssl*)
      openssl_passl=("--passL:${tok}" "--passL:-lssl" "--passL:-lcrypto")
      break
      ;;
  esac
done

has_any_library() {
  local dir="$1"
  shift
  local lib
  for lib in "$@"; do
    if [ -f "${dir}/${lib}" ]; then
      return 0
    fi
  done
  return 1
}

add_unique_lib_dir() {
  local candidate="$1"
  shift
  local existing
  [ -n "${candidate}" ] || return 0
  [ -d "${candidate}" ] || return 0
  for existing in "$@"; do
    if [ "${existing}" = "${candidate}" ]; then
      return 1
    fi
  done
  return 0
}

runtime_passl_for_libraries() {
  local -a libs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    libs+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift

  local -a dirs=()
  local tok dir prefix
  for tok in ${NIX_LDFLAGS:-}; do
    case "$tok" in
      -L*)
        dir="${tok#-L}"
        if has_any_library "${dir}" "${libs[@]}" &&
            add_unique_lib_dir "${dir}" "${dirs[@]+"${dirs[@]}"}"; then
          dirs+=("${dir}")
        fi
        ;;
    esac
  done

  for prefix in "$@"; do
    [ -n "${prefix}" ] || continue
    for dir in "${prefix}" "${prefix}/lib" "${prefix}/lib64"; do
      if has_any_library "${dir}" "${libs[@]}" &&
          add_unique_lib_dir "${dir}" "${dirs[@]+"${dirs[@]}"}"; then
        dirs+=("${dir}")
      fi
    done
  done

  for dir in "${dirs[@]}"; do
    printf '%s\n' "--passL:-L${dir}"
    printf '%s\n' "--passL:-Wl,-rpath,${dir}"
  done
}

# ``repro`` dlopens two libraries by bare soname: libclingo (the ASP solver,
# loaded eagerly in the module's DatInit, i.e. before ``main``) and libzstd
# (loaded lazily by the binary-cache client on the first ckZstd payload). Keep
# the Nim compile-time search path scrubbed -- an absolute ``/nix/store`` path
# baked into .rodata survives the stage-time store relocation and breaks the
# installed system -- but thread the runtime loader path into the ELF/Mach-O so
# clean shells and SSH sessions work.
#
# This is the ONLY thing that makes those sonames resolvable off the dev shell.
# The dev shell's LD_LIBRARY_PATH is not available to a ``repro`` on the far
# side of an SSH transport (sshd does not propagate it into a non-interactive
# session, which is how the M71 remote-apply phases invoke ``repro home
# __receive-bundle`` on the target host), to a CI step that is not wrapped in
# ``nix develop``, or to an installed ``repro`` -- flake.nix deliberately
# refuses to inject a loader search path into the installed wrapper (arbitrary
# user build actions inherit the wrapper environment) and patches the same
# directories into the packaged binaries' RPATH instead.
#
# ``tests/integration/t_repro_runtime_dlopen_without_library_path.nim`` is the
# gate: it runs the built binary with the loader search-path variables removed
# from the child environment, so this threading silently disappearing is a test
# failure rather than a remote-only outage.
mapfile -t repro_runtime_passl < <(
  runtime_passl_for_libraries \
    libclingo.so libclingo.dylib libzstd.so.1 libzstd.1.dylib -- \
    "${CLINGO_PREFIX:-}" \
    /opt/homebrew/opt/clingo \
    /usr/local/opt/clingo \
    "${ZSTD_PREFIX:-}" \
    /opt/homebrew/opt/zstd \
    /usr/local/opt/zstd
)

# Mach-O load commands live in a fixed-size header pad decided at LINK time,
# and every `-Wl,-rpath,<dir>` above consumes part of it. Packaging then adds
# MORE LC_RPATH entries after the fact (flake.nix's postFixup replays the
# packaged runtime library dirs through install_name_tool), which fails with
# "larger updated load commands do not fit ... the program must be relinked"
# once the pad is exhausted. Reserving the maximum pad at link time is the
# standard remedy and costs only header bytes, so ask for it on every darwin
# link rather than tuning it per binary as the rpath set grows.
darwin_headerpad=()
if [ "${REPRO_HOST_PLATFORM}" = "darwin" ]; then
  darwin_headerpad=("--passL:-Wl,-headerpad_max_install_names")
fi

while read -r name path extra_flags; do
  name="${name%$'\r'}"
  path="${path%$'\r'}"
  extra_flags="${extra_flags%$'\r'}"
  case "${name}" in
    ""|\#*) continue ;;
  esac
  # extra_flags is the optional third field of apps/entrypoints.txt — used
  # to opt individual binaries into per-entrypoint nim defines without
  # forking the loop (e.g. -d:reproProviderMode for the direct provider).
  # shellcheck disable=SC2206
  extra_flag_array=(${extra_flags})
  # Only ssl entrypoints get OpenSSL's captured -L back (see openssl_passl
  # above); every other entrypoint's nim invocation is unchanged.
  ssl_passl=()
  for f in ${extra_flag_array[@]+"${extra_flag_array[@]}"}; do
    case "$f" in
      --define:ssl|-d:ssl)
        ssl_passl=(${openssl_passl[@]+"${openssl_passl[@]}"})
        break
        ;;
    esac
  done
  runtime_passl=()
  case "${name}" in
    repro)
      runtime_passl=(${repro_runtime_passl[@]+"${repro_runtime_passl[@]}"})
      ;;
  esac
  (
    unset_clingo_searchpath
    nim c \
      ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
      ${extra_flag_array[@]+"${extra_flag_array[@]}"} \
      ${ssl_passl[@]+"${ssl_passl[@]}"} \
      ${runtime_passl[@]+"${runtime_passl[@]}"} \
      ${darwin_headerpad[@]+"${darwin_headerpad[@]}"} \
      --nimcache:"build/nimcache/${name}" \
      --out:"build/bin/${name}" \
      "${path}"
  )
done < apps/entrypoints.txt

# Build the shared DSL runtime DLL — the Tier 1 artifact described in
# reprobuild-specs/Provider-Compile-Tiering.md. Per-project provider
# compiles eventually link against this library instead of statically
# embedding the ~5000-line DSL+runtime surface.
#
# The DLL is consumed by provider binaries which are themselves built
# with `--define:reproProviderMode`, so the DLL must also compile with
# that define to expose the provider-mode-only runtime procs.
mkdir -p build/lib
case "${REPRO_HOST_PLATFORM}" in
  windows)
    dll_ext="dll" ;;
  darwin)
    dll_ext="dylib" ;;
  *)
    dll_ext="so" ;;
esac
(
  # Same /nix/store .rodata-bake guard as the entrypoints loop above.
  unset_clingo_searchpath
  nim c \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    ${darwin_headerpad[@]+"${darwin_headerpad[@]}"} \
    --app:lib \
    --threads:on \
    --mm:orc \
    --define:reproProviderMode \
    --define:reproProviderRuntimeDll \
    --nimcache:build/nimcache/repro-project-dsl-runtime-dll \
    --out:"build/lib/librepro_project_dsl_runtime.new.${dll_ext}" \
    libs/repro_project_dsl_runtime_dll/src/repro_project_dsl_runtime_entry.nim
)
if [ -f "build/lib/librepro_project_dsl_runtime.${dll_ext}" ]; then
  mv -f "build/lib/librepro_project_dsl_runtime.${dll_ext}" "build/lib/librepro_project_dsl_runtime.${dll_ext}.old" || true
fi
mv -f "build/lib/librepro_project_dsl_runtime.new.${dll_ext}" "build/lib/librepro_project_dsl_runtime.${dll_ext}"

# Windows runtime-DLL staging: the blocks below copy each dlopen'd library next
# to the built binaries so LoadLibrary resolves it from the .exe's own
# directory. clingo is unconditionally fatal (module-init dlopen -- see below);
# libzstd and sqlite3 are loaded lazily by specific subcommands, so a dev build
# without them is usable and only warns. A RELEASE build must not ship in that
# state, so release.yml sets REPRO_REQUIRE_WINDOWS_RUNTIME_DLLS=1 to promote
# those warnings to hard errors. scripts/verify_release.sh independently
# enforces the same set against the packaged archive.
windows_dll_staging_problem() {
  if [ "${REPRO_REQUIRE_WINDOWS_RUNTIME_DLLS:-0}" = "1" ]; then
    echo "error: $1" >&2
    echo "       (REPRO_REQUIRE_WINDOWS_RUNTIME_DLLS=1 -- a release build must be self-contained)" >&2
    exit 1
  fi
  echo "warning: $1" >&2
}

# MR4 -- Windows self-containment: stage clingo.dll next to repro.exe
# so the Nim ``{.dynlib: "clingo.dll".}`` FFI in
# ``libs/repro_solver/src/repro_solver/clingo_bindings.nim`` resolves
# from the executable's own directory at LoadLibrary time. Without this
# step, ``repro.exe`` running in a fresh pwsh (env.ps1 not sourced)
# crashes at module init with ``could not load: clingo.dll`` because
# Win32's LoadLibrary searches the .exe's dir, then the system dirs,
# then PATH -- and only env.ps1 puts the conda-forge clingo bin dir on
# PATH.
#
# Source resolution policy (no hardcoded ``D:\metacraft-dev-deps`` --
# the env.ps1 install root is not the canonical store): locate the
# clingo.exe sibling on PATH at build time (``command -v clingo.exe``
# works under MSYS / Git Bash, and env.ps1 always co-locates
# clingo.exe with clingo.dll per the conda-forge layout). The
# ``windows/ensure-clingo.ps1`` provisioner downloads the same conda
# package on every install, so the DLL bytes are stable across hosts.
#
# This step FAILS the build when it cannot find clingo, and deliberately so.
# It used to warn and continue, on the reasoning that ``repro.exe`` still
# builds. It does -- but it does not RUN: the dynlib block is resolved at
# module init, before ``main``, so a repro.exe without clingo.dll beside it
# has no working subcommand at all, not even ``--version``. Warning here
# meant a release could be cut, packaged, "verified", and published in that
# state (the release smoke test inherited the build host's PATH, where a
# hand-provisioned C:\clingo satisfied the loader that the archive could not
# -- see scripts/verify_release.sh). Failing at the staging step puts the
# error where the missing input actually is.
#
# M3-style stdlib package resolution (a ``packages/clingo.nim`` entry consumed
# by the engine's tool-provisioning store) is still the durable follow-up.
case "${REPRO_HOST_PLATFORM}" in
  windows)
    # Prefer the provisioner's own install dir when env.ps1 exported it: it is
    # the pinned, checksummed copy. Fall back to PATH so a hand-provisioned
    # host (or one whose clingo came from elsewhere) still builds.
    clingo_src_dll=""
    if [ -n "${REPRO_WINDOWS_CLINGO_DIR:-}" ] &&
       [ -f "${REPRO_WINDOWS_CLINGO_DIR}/clingo.dll" ]; then
      clingo_src_dll="${REPRO_WINDOWS_CLINGO_DIR}/clingo.dll"
    else
      clingo_exe="$(command -v clingo.exe 2>/dev/null || true)"
      if [ -n "${clingo_exe}" ]; then
        candidate="$(dirname "${clingo_exe}")/clingo.dll"
        if [ -f "${candidate}" ]; then
          clingo_src_dll="${candidate}"
        else
          echo "error: clingo.exe found at ${clingo_exe} but its sibling clingo.dll is missing at ${candidate}." >&2
        fi
      fi
    fi
    if [ -z "${clingo_src_dll}" ]; then
      echo "error: cannot stage clingo.dll next to repro.exe -- no clingo found." >&2
      echo "       repro_solver dlopens clingo.dll at module init, so a repro.exe" >&2
      echo "       built without it aborts before main on every invocation." >&2
      echo "       Fix: run '. .\\env.ps1' (which provisions the pinned conda-forge" >&2
      echo "       clingo via windows/ensure-clingo.ps1), or point" >&2
      echo "       REPRO_WINDOWS_CLINGO_DIR at a directory containing clingo.dll." >&2
      exit 1
    fi
    cp -f "${clingo_src_dll}" build/bin/clingo.dll
    echo "Staged clingo.dll from ${clingo_src_dll} -> build/bin/clingo.dll"
    ;;
esac

# Windows-Runner-Binary-Cache-Deploy M3a -- Windows self-containment for the
# binary-cache client CLI: stage libzstd.dll next to the built binaries so the
# Nim ``{.dynlib: "libzstd.dll".}`` FFI in
# ``libs/repro_binary_cache_client/src/repro_binary_cache_client/decompress.nim``
# resolves from the executable's own directory at LoadLibrary time (the
# streaming substitute path decompresses zstd frames via dlopen, not a
# DT_NEEDED/import-lib dependency). The substitute path now ships inside
# ``repro.exe`` as the ``repro cache substitute`` subcommand (the standalone
# ``repro-binary-cache-client`` binary was retired). Without this, a
# fresh-shell ``repro.exe cache substitute`` crashes the first time it
# hits a zstd-compressed payload with ``could not load: libzstd.dll`` because
# Win32's LoadLibrary searches the .exe's dir, then system dirs, then PATH --
# and only a provisioned dev shell puts libzstd.dll on PATH.
#
# Source resolution policy (mirrors the clingo.dll block above -- no hardcoded
# store path): locate ``zstd.exe`` on PATH at build time (``command -v
# zstd.exe`` works under MSYS2 / Git Bash) and stage its co-located
# libzstd.dll. Two layouts are probed: the MSYS2 ``mingw64`` pacman package
# (``mingw-w64-x86_64-zstd``) co-locates ``libzstd.dll`` with ``zstd.exe`` in
# the same ``bin`` dir; the facebook/zstd win64 release (the reprobuild
# ``packages/zstd.nim`` tarball, stripComponents=1) puts ``zstd.exe`` at the
# prefix root with ``libzstd.dll`` under a sibling ``dll/`` subdir. When
# neither is found we WARN rather than fail -- the binaries still build; the
# client just won't self-load a compressed payload until zstd is provisioned.
case "${REPRO_HOST_PLATFORM}" in
  windows)
    zstd_exe="$(command -v zstd.exe 2>/dev/null || true)"
    if [ -n "${zstd_exe}" ]; then
      zstd_src_dir="$(dirname "${zstd_exe}")"
      zstd_src_dll=""
      if [ -f "${zstd_src_dir}/libzstd.dll" ]; then
        zstd_src_dll="${zstd_src_dir}/libzstd.dll"
      elif [ -f "${zstd_src_dir}/dll/libzstd.dll" ]; then
        # facebook/zstd win64 release layout (packages/zstd.nim tarball).
        zstd_src_dll="${zstd_src_dir}/dll/libzstd.dll"
      fi
      if [ -n "${zstd_src_dll}" ]; then
        cp -f "${zstd_src_dll}" build/bin/libzstd.dll
        echo "Staged libzstd.dll from ${zstd_src_dll} -> build/bin/libzstd.dll"
      else
        windows_dll_staging_problem "zstd.exe on PATH at ${zstd_exe} but no sibling libzstd.dll (checked ${zstd_src_dir}/libzstd.dll and ${zstd_src_dir}/dll/libzstd.dll); repro.exe cache substitute will fail to decompress payloads in a clean shell"
      fi
    else
      # TODO(Windows zstd provisioning): once a windows/ensure-zstd.ps1
      # provisioner lands (analogous to the referenced ensure-clingo.ps1), it
      # should put zstd.exe + libzstd.dll on PATH so this staging step resolves.
      # Until then, a build host without zstd on PATH stages nothing and only
      # warns. Intended source: MSYS2 ``pacman -S mingw-w64-x86_64-zstd`` (bin/
      # co-located) or the facebook/zstd v1.5.6 win64 release used by
      # libs/repro_dsl_stdlib/.../packages/zstd.nim.
      windows_dll_staging_problem "zstd.exe not on PATH; cannot stage libzstd.dll next to repro.exe -- provision zstd (MSYS2 mingw-w64-x86_64-zstd) first"
    fi
    ;;
esac

# Windows-Runner-Binary-Cache-Deploy M3b -- Windows self-containment for the
# binary-cache client CLI's SQLITE dependency: stage sqlite3_64.dll next to
# the built binaries so the Nim ``{.dynlib: "(sqlite3_64|sqlite3|sqlite3_32).dll".}``
# FFI in
# ``libs/repro_local_store/src/repro_local_store/sqlite3_binding.nim``
# resolves from the executable's own directory at LoadLibrary time. The
# ``repro cache`` dispatch links ``repro_local_store`` (via repro.exe), so it
# HARD-REQUIRES this dynlib even for ``derive-key`` -- without it a fresh-shell
# ``repro.exe cache derive-key`` crashes at module init with
# ``could not load: (sqlite3_64|sqlite3|sqlite3_32).dll`` because Win32's
# LoadLibrary searches the .exe's dir, then system dirs, then PATH -- and only
# a provisioned dev shell puts the Nim ``dist`` dir on PATH.
#
# Source resolution policy (mirrors the libzstd.dll / clingo.dll blocks above
# -- no hardcoded store path): the Windows Nim distribution SHIPS
# ``sqlite3_64.dll`` inside its own tree (under the Nim root's ``bin`` dir or a
# sibling ``dist``/``dlls`` dir). Locate ``nim.exe`` on PATH at build time
# (``command -v nim.exe`` works under MSYS2 / Git Bash) and probe the same-dir
# and sibling ``dist``/``dlls`` layouts for the DLL. As a fallback also probe
# the DLL directly on PATH (``command -v sqlite3_64.dll`` succeeds when the
# Nim bin dir is on PATH). When none is found we WARN rather than fail -- the
# binaries still build; the client just won't self-load its sqlite dynlib
# until it is provisioned.
#
# IMPORTANT (Linux/MinGW cross-build): sqlite3_64.dll is a Windows PE that only
# exists inside a *Windows* Nim install. A Linux host cross-building for MinGW
# has no such DLL to stage, so this whole ``case`` arm is Windows-only and is a
# no-op on Linux (guarded by ``uname -s``). The PRODUCTION seed's
# sqlite3_64.dll is therefore captured from the GUEST's Nim install (the M3b
# approach (b) seed: it is copied out of ``C:\dev-deps\nim\...`` next to the
# guest-built repro.exe), NOT synthesised on Linux. This
# build-time staging covers the from-source Windows build path (install-
# reprobuild.ps1 on the guest), so a guest-side ``build_apps.sh`` run drops
# sqlite3_64.dll next to repro.exe reproducibly.
case "${REPRO_HOST_PLATFORM}" in
  windows)
    sqlite_src_dll=""
    nim_exe="$(command -v nim.exe 2>/dev/null || true)"
    if [ -n "${nim_exe}" ]; then
      nim_bin_dir="$(dirname "${nim_exe}")"
      nim_root_dir="$(dirname "${nim_bin_dir}")"
      for cand in \
        "${nim_bin_dir}/sqlite3_64.dll" \
        "${nim_root_dir}/dist/sqlite3_64.dll" \
        "${nim_root_dir}/dlls/sqlite3_64.dll" \
        "${nim_root_dir}/bin/sqlite3_64.dll"; do
        if [ -f "${cand}" ]; then
          sqlite_src_dll="${cand}"
          break
        fi
      done
    fi
    if [ -z "${sqlite_src_dll}" ]; then
      # Fallback: the DLL itself on PATH (Nim's dist dir on PATH).
      sqlite_on_path="$(command -v sqlite3_64.dll 2>/dev/null || true)"
      if [ -n "${sqlite_on_path}" ]; then
        sqlite_src_dll="${sqlite_on_path}"
      fi
    fi
    if [ -n "${sqlite_src_dll}" ]; then
      if [ ! "${sqlite_src_dll}" -ef build/bin/sqlite3_64.dll ]; then
        cp -f "${sqlite_src_dll}" build/bin/sqlite3_64.dll
        cp -f "${sqlite_src_dll}" build/bin/sqlite3.dll
        echo "Staged sqlite3_64.dll and sqlite3.dll from ${sqlite_src_dll} -> build/bin/"
      fi
    else
      # TODO(Windows sqlite provisioning): the Windows Nim distribution ships
      # sqlite3_64.dll in its own tree; ensure-nim.ps1's provisioned Nim under
      # C:\dev-deps\nim carries it. If a future build host strips it, a
      # windows/ensure-sqlite.ps1 provisioner (analogous to ensure-clingo /
      # the referenced ensure-zstd TODO) should put sqlite3_64.dll on PATH so
      # this staging step resolves. Until then a build host without it stages
      # nothing and only warns. Intended source: the guest's Nim install
      # (dist/sqlite3_64.dll), which is exactly where the M3b production seed's
      # sqlite3_64.dll was captured from.
      windows_dll_staging_problem "sqlite3_64.dll not found near nim.exe or on PATH; cannot stage it next to repro.exe -- repro cache will fail 'could not load: sqlite3_64.dll' in a clean shell until Nim's dist sqlite dll is provisioned"
    fi
    ;;
esac
