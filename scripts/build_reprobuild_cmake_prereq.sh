#!/usr/bin/env bash
set -euo pipefail

exe_ext="${1:-}"
cmake_root="../reprobuild-cmake"

if [[ ! -d "${cmake_root}" ]]; then
  exit 0
fi

activate_msvc_dev_env() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;
  esac

  if [[ -n "${VCToolsInstallDir:-}" && -n "${INCLUDE:-}" &&
        -n "${LIB:-}" ]]; then
    return 0
  fi

  local vsdevcmd=""
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  if [[ -x "${vswhere}" ]]; then
    local install_path
    install_path="$("${vswhere}" -latest -products '*' \
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
      -property installationPath | tr -d '\r')"
    if [[ -n "${install_path}" ]]; then
      vsdevcmd="$(cygpath -u "${install_path}\\Common7\\Tools\\VsDevCmd.bat")"
    fi
  fi

  if [[ ! -f "${vsdevcmd}" ]]; then
    local candidate
    for candidate in \
      /c/Program\ Files/Microsoft\ Visual\ Studio/2022/*/Common7/Tools/VsDevCmd.bat \
      /c/Program\ Files\ \(x86\)/Microsoft\ Visual\ Studio/2019/*/Common7/Tools/VsDevCmd.bat; do
      if [[ -f "${candidate}" ]]; then
        vsdevcmd="${candidate}"
        break
      fi
    done
  fi

  if [[ ! -f "${vsdevcmd}" ]]; then
    echo "Visual Studio C++ environment unavailable: VsDevCmd.bat not found" >&2
    return 1
  fi

  local activation_script
  activation_script="$(mktemp "${TMPDIR:-/tmp}/repro-msvc-env.XXXXXX.bat")"
  printf '@call "%s" -arch=x64 -host_arch=x64 -no_logo >nul\r\n' \
    "$(cygpath -w "${vsdevcmd}")" > "${activation_script}"
  printf '@if errorlevel 1 exit /b %%errorlevel%%\r\n@set\r\n' \
    >> "${activation_script}"

  local env_dump
  if ! env_dump="$(MSYS2_ARG_CONV_EXCL='/d;/c' cmd.exe /d /c \
      "$(cygpath -w "${activation_script}")")"; then
    rm -f "${activation_script}"
    echo "Visual Studio C++ environment activation failed" >&2
    return 1
  fi
  rm -f "${activation_script}"

  local key value windows_path=""
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"
    case "${key}" in
      INCLUDE|LIB|LIBPATH|UniversalCRTSdkDir|UCRTVersion|VCINSTALLDIR|\
      VCToolsInstallDir|VCToolsVersion|VSINSTALLDIR|WindowsLibPath|\
      WindowsSdkBinPath|WindowsSdkDir|WindowsSDKLibVersion|\
      WindowsSDKVersion)
        export "${key}=${value}"
        ;;
      Path|PATH)
        windows_path="${value}"
        ;;
    esac
  done <<< "${env_dump}"

  if [[ -n "${windows_path}" ]]; then
    export PATH="$(cygpath -p "${windows_path}")"
  fi
}

activate_msvc_dev_env

# A previously-built binary is NOT evidence that it is current. This guard used
# to `exit 0` whenever build/bin/cmake existed, so no change to the fork's
# sources was ever compiled again: consumers silently kept exercising a stale
# binary. That is how a fix to the Reprobuild generator's CLI flags reached the
# repository but never reached the tests — the binary was four days older than
# the fix, and test-logs/reprobuild-cmake-build.log was itself a stale artefact
# from that same date, so even the evidence of building looked convincing.
#
# When a configured build tree already exists, delegate staleness to the
# generator, which does correct incremental dependency tracking. An up-to-date
# tree relinks nothing and costs about a second; a changed source recompiles
# exactly what it must. The expensive cold configure below still runs only when
# there is no build tree to reuse.
if [[ -x "${cmake_root}/build/bin/cmake${exe_ext}" && -f "${cmake_root}/build/CMakeCache.txt" ]]; then
  mkdir -p test-logs
  printf 'Refreshing prerequisite sibling: ../reprobuild-cmake (incremental)\n' >&2
  cmake_jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  if (( cmake_jobs > 16 )); then cmake_jobs=16; fi
  if (cd "${cmake_root}" && cmake --build build --target cmake \
        --parallel "${cmake_jobs}") >> test-logs/reprobuild-cmake-build.log 2>&1; then
    exit 0
  fi
  # An incremental refresh can legitimately fail when the cached configuration
  # no longer matches (a moved toolchain, a changed generator). Fall through to
  # the full configure below, which reconfigures from scratch, rather than
  # failing the caller with a stale tree.
  printf 'Incremental refresh failed; reconfiguring from scratch\n' >&2
fi

mkdir -p test-logs
printf 'Building prerequisite sibling: ../reprobuild-cmake (CMake fork)\n' >&2

cmake_jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
if (( cmake_jobs > 16 )); then cmake_jobs=16; fi

cmake_generator="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
  cmake_generator="Ninja"
fi

cmake_cc=""
cmake_cxx=""
if [[ "$(uname -s)" == "Darwin" || "$(uname -s)" == "Linux" ]]; then
  cmake_cc="$(command -v cc || command -v gcc || echo gcc)"
  cmake_cxx="$(command -v c++ || command -v g++ || echo g++)"
fi
cmake_osx_sysroot=""
cmake_apple_framework_flags=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  cmake_osx_sysroot="$(
    find /nix/store -maxdepth 7 \
      -path '*/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk' \
      -type d -print 2>/dev/null | LC_ALL=C sort | tail -n 1 || true
  )"
  if [[ -z "${cmake_osx_sysroot}" ]]; then
    echo "reprobuild-cmake build requires a macOS SDK in /nix/store" >&2
    exit 1
  fi
  cmake_apple_framework_dir="${cmake_osx_sysroot}/System/Library/Frameworks"
  if [[ -d "${cmake_apple_framework_dir}" ]]; then
    cmake_apple_framework_flags=(
      "-DCMAKE_C_FLAGS=-F${cmake_apple_framework_dir}"
      "-DCMAKE_CXX_FLAGS=-F${cmake_apple_framework_dir}"
      "-DCMAKE_EXE_LINKER_FLAGS=-F${cmake_apple_framework_dir}"
    )
  fi
fi

iconv_header="$(
  find /nix/store -maxdepth 3 -path '*/include/iconv.h' -print -quit 2>/dev/null || true
)"
iconv_args=()
if [[ -n "${iconv_header}" ]]; then
  iconv_include_dir="$(dirname "${iconv_header}")"
  iconv_prefix="${iconv_include_dir%/include}"
  iconv_lib="${iconv_prefix}/lib/libiconv.dylib"
  if [[ ! -f "${iconv_lib}" ]]; then
    iconv_lib="$(
      find /nix/store -maxdepth 3 -path '*/lib/libiconv.dylib' -print -quit 2>/dev/null || true
    )"
  fi
  if [[ -n "${iconv_lib}" && -f "${iconv_lib}" ]]; then
    iconv_args=(
      "-DICONV_INCLUDE_DIR=${iconv_include_dir}"
      "-DLIBICONV_PATH=${iconv_lib}"
    )
  fi
fi

(
  cd "${cmake_root}"
  if [[ -f build/CMakeCache.txt ]] && {
      ! grep -q "^CMAKE_GENERATOR:INTERNAL=${cmake_generator}$" build/CMakeCache.txt ||
      { [[ -n "${cmake_cc}" ]] && ! grep -q "^CMAKE_C_COMPILER:FILEPATH=${cmake_cc}$" build/CMakeCache.txt; } ||
      { [[ -n "${cmake_cxx}" ]] && ! grep -q "^CMAKE_CXX_COMPILER:FILEPATH=${cmake_cxx}$" build/CMakeCache.txt; } ||
      { [[ -n "${cmake_osx_sysroot}" ]] && ! grep -q "^CMAKE_OSX_SYSROOT:.*=${cmake_osx_sysroot}$" build/CMakeCache.txt; } ||
      { [[ -n "${cmake_apple_framework_dir:-}" ]] && ! grep -q "^CMAKE_CXX_FLAGS:STRING=-F${cmake_apple_framework_dir}$" build/CMakeCache.txt; } ||
      ! grep -q "^ENABLE_IPV6:.*=OFF$" build/CMakeCache.txt
    }; then
    rm -rf build
  fi

  cmake -S . -B build -G "${cmake_generator}" \
    -DCMAKE_BUILD_TYPE=Release \
    ${cmake_cc:+-DCMAKE_C_COMPILER="${cmake_cc}"} \
    ${cmake_cxx:+-DCMAKE_CXX_COMPILER="${cmake_cxx}"} \
    ${cmake_osx_sysroot:+-DCMAKE_OSX_SYSROOT="${cmake_osx_sysroot}"} \
    "${cmake_apple_framework_flags[@]}" \
    -DCMAKE_USE_SYSTEM_CURL=OFF \
    -DCMAKE_USE_SYSTEM_ZLIB=OFF \
    -DENABLE_IPV6=OFF \
    "${iconv_args[@]}"

  cmake --build build --target cmake --parallel "${cmake_jobs}"
) > test-logs/reprobuild-cmake-build.log 2>&1 || {
  echo "reprobuild-cmake build failed; see test-logs/reprobuild-cmake-build.log" >&2
  exit 1
}
