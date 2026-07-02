#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/bin build/lib build/nimcache

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
# segment so the same env value works for both consumers.
case "$io_mon_src" in
  */src) io_mon_src="${io_mon_src%/src}" ;;
esac
if [ ! -x "${io_mon_src}/scripts/build_shim.sh" ]; then
  echo "missing io-mon shim builder at ${io_mon_src}/scripts/build_shim.sh; set IO_MON_SRC" >&2
  exit 2
fi
# Point BOTH the shim's output dir and its nimcache at reprobuild's own
# (writable) build tree. io-mon's source is read-only when it comes from a Nix
# flake input / store path (the package build + dev shell), so the shim must not
# write its nimcache into its own source — pass an absolute writable dir.
IO_MON_SHIM_OUT_DIR="$(pwd)/build/lib" \
IO_MON_SHIM_NIMCACHE_DIR="$(pwd)/build/nimcache/io-mon-shim" \
IO_MON_BUILD_MODE="${REPROBUILD_BUILD_MODE:-debug}" \
  bash "${io_mon_src}/scripts/build_shim.sh"

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

while read -r name path extra_flags; do
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
  (
    unset_clingo_searchpath
    nim c \
      ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
      ${extra_flag_array[@]+"${extra_flag_array[@]}"} \
      ${ssl_passl[@]+"${ssl_passl[@]}"} \
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
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    dll_ext="dll" ;;
  Darwin)
    dll_ext="dylib" ;;
  *)
    dll_ext="so" ;;
esac
(
  # Same /nix/store .rodata-bake guard as the entrypoints loop above.
  unset_clingo_searchpath
  nim c \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    --app:lib \
    --threads:on \
    --mm:orc \
    --define:reproProviderMode \
    --define:reproProviderRuntimeDll \
    --nimcache:build/nimcache/repro-project-dsl-runtime-dll \
    --out:"build/lib/librepro_project_dsl_runtime.${dll_ext}" \
    libs/repro_project_dsl_runtime_dll/src/repro_project_dsl_runtime_entry.nim
)

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
# When clingo.exe is not on PATH (e.g. a non-env.ps1 dev shell on a
# host that has never run the bootstrap), we surface a warning rather
# than failing the build -- ``repro.exe`` still builds; it just won't
# self-load until the user provisions clingo. M3-style stdlib package
# resolution (a ``packages/clingo.nim`` entry consumed by the engine's
# tool-provisioning store) is the durable follow-up; this MR4 step is
# the smallest fix that unblocks all 17 recorder tests in the
# clean-shell sweep.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    clingo_exe="$(command -v clingo.exe 2>/dev/null || true)"
    if [ -n "${clingo_exe}" ]; then
      clingo_src_dir="$(dirname "${clingo_exe}")"
      clingo_src_dll="${clingo_src_dir}/clingo.dll"
      if [ -f "${clingo_src_dll}" ]; then
        cp -f "${clingo_src_dll}" build/bin/clingo.dll
        echo "Staged clingo.dll from ${clingo_src_dll} -> build/bin/clingo.dll"
      else
        echo "warning: clingo.exe on PATH but sibling clingo.dll missing at ${clingo_src_dll}; repro.exe will fail to load in a clean shell" >&2
      fi
    else
      echo "warning: clingo.exe not on PATH; cannot stage clingo.dll next to repro.exe -- run env.ps1 or windows/ensure-clingo.ps1 first" >&2
    fi
    ;;
esac

# Windows-Runner-Binary-Cache-Deploy M3a -- Windows self-containment for the
# binary-cache client CLI: stage libzstd.dll next to the built binaries so the
# Nim ``{.dynlib: "libzstd.dll".}`` FFI in
# ``libs/repro_binary_cache_client/src/repro_binary_cache_client/decompress.nim``
# resolves from the executable's own directory at LoadLibrary time (the
# streaming substitute path decompresses zstd frames via dlopen, not a
# DT_NEEDED/import-lib dependency). Without this, a fresh-shell
# ``repro-binary-cache-client-cli.exe substitute`` crashes the first time it
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
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
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
        echo "warning: zstd.exe on PATH at ${zstd_exe} but no sibling libzstd.dll (checked ${zstd_src_dir}/libzstd.dll and ${zstd_src_dir}/dll/libzstd.dll); repro-binary-cache-client-cli.exe will fail to decompress payloads in a clean shell" >&2
      fi
    else
      # TODO(Windows zstd provisioning): once a windows/ensure-zstd.ps1
      # provisioner lands (analogous to the referenced ensure-clingo.ps1), it
      # should put zstd.exe + libzstd.dll on PATH so this staging step resolves.
      # Until then, a build host without zstd on PATH stages nothing and only
      # warns. Intended source: MSYS2 ``pacman -S mingw-w64-x86_64-zstd`` (bin/
      # co-located) or the facebook/zstd v1.5.6 win64 release used by
      # libs/repro_dsl_stdlib/.../packages/zstd.nim.
      echo "warning: zstd.exe not on PATH; cannot stage libzstd.dll next to repro-binary-cache-client-cli.exe -- provision zstd (MSYS2 mingw-w64-x86_64-zstd) first" >&2
    fi
    ;;
esac
