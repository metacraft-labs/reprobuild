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

if [ "$(uname -s)" = "Darwin" ]; then
  nim c \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    --app:lib \
    --threads:on \
    --nimcache:build/nimcache/repro-monitor-shim-dylib \
    --out:build/lib/librepro_monitor_shim.dylib \
    libs/repro_monitor_shim/src/repro_monitor_shim/macos_interpose.nim
fi

if [ "$(uname -s)" = "Linux" ]; then
  nim c \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    --app:lib \
    --threads:on \
    --nimcache:build/nimcache/repro-monitor-shim-so \
    --out:build/lib/librepro_monitor_shim.so \
    libs/repro_monitor_shim/src/repro_monitor_shim/linux_preload.nim
fi

# Windows: build the IAT-patching DLL counterpart of the macOS dylib.
# Detect MSYS/Cygwin/Git Bash builds running under Windows by checking uname.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    # The monitor shim imports the framework primitives (hook_registry,
    # reentrancy, propagation, inline-detour C primitive) from
    # `metacraft-labs/nim-stackable-hooks`. The sibling lives at
    # $STACKABLE_HOOKS_SRC or, by default, at ../nim-stackable-hooks/src
    # relative to the reprobuild repo root. CI clones the sibling.
    stackable_hooks_src="${STACKABLE_HOOKS_SRC:-../nim-stackable-hooks/src}"
    if [ ! -d "${stackable_hooks_src}" ]; then
      stackable_hooks_src="libs/repro_monitor_shim/vendor/nim-stackable-hooks/src"
    fi
    nim c \
      ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
      --app:lib \
      --threads:on \
      --mm:orc \
      --cc:gcc \
      --hints:off \
      --warnings:off \
      --path:libs/repro_monitor_depfile/src \
      --path:libs/repro_core/src \
      --path:libs/repro_monitor_shim/src \
      --path:"${stackable_hooks_src}" \
      --nimcache:build/nimcache/repro-monitor-shim-dll \
      --out:build/lib/librepro_monitor_shim.dll \
      libs/repro_monitor_shim/src/repro_monitor_shim/windows_interpose.nim
    ;;
esac

while read -r name path extra_flags; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  # extra_flags is the optional third field of apps/entrypoints.txt — used
  # to opt individual binaries into per-entrypoint nim defines without
  # forking the loop (e.g. -d:reproProviderMode for the direct provider).
  # shellcheck disable=SC2206
  extra_flag_array=(${extra_flags})
  nim c \
    ${nim_mode_flags[@]+"${nim_mode_flags[@]}"} \
    ${extra_flag_array[@]+"${extra_flag_array[@]}"} \
    --nimcache:"build/nimcache/${name}" \
    --out:"build/bin/${name}" \
    "${path}"
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
