#!/usr/bin/env bash
set -euo pipefail

exe_ext="${1:-}"
cmake_root="../reprobuild-cmake"

if [[ ! -d "${cmake_root}" ]]; then
  exit 0
fi

if [[ -x "${cmake_root}/build/bin/cmake${exe_ext}" ]]; then
  exit 0
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
