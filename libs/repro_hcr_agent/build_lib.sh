#!/usr/bin/env bash
# build_lib.sh
#
# Builds the canonical reprobuild HCR agent shared library:
#   macOS:   librepro_hcr_agent.dylib
#   Linux:   librepro_hcr_agent.so
#   Windows: repro_hcr_agent.dll
#
# Usage:
#   ./build_lib.sh [OUTPUT_DIR] [--target-os=darwin|linux|windows] [--print-name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C_DIR="$SCRIPT_DIR/c"
SRC_C="$C_DIR/repro_hcr_agent.c"

TARGET_OS=""
PRINT_NAME=0
OUT_DIR=""

for arg in "$@"; do
  case "$arg" in
    --target-os=*)
      TARGET_OS="${arg#*=}"
      ;;
    --print-name)
      PRINT_NAME=1
      ;;
    -*)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$arg"
      fi
      ;;
  esac
done

if [[ -z "$TARGET_OS" ]]; then
  UNAME_S="$(uname -s 2>/dev/null || echo "Unknown")"
  case "$UNAME_S" in
    Darwin*)
      TARGET_OS="darwin"
      ;;
    Linux*)
      TARGET_OS="linux"
      ;;
    CYGWIN*|MINGW*|MSYS*|Windows*)
      TARGET_OS="windows"
      ;;
    *)
      TARGET_OS="linux"
      ;;
  esac
fi

case "$TARGET_OS" in
  darwin|macos|darwin*)
    LIB_NAME="librepro_hcr_agent.dylib"
    CC_DEFAULT="clang"
    SHARED_FLAGS="-dynamiclib -fPIC"
    EXTRA_LIBS="-lpthread"
    DEFINES=""
    ;;
  linux|linux*)
    LIB_NAME="librepro_hcr_agent.so"
    CC_DEFAULT="gcc"
    SHARED_FLAGS="-shared -fPIC"
    EXTRA_LIBS="-lpthread"
    DEFINES=""
    ;;
  windows|win*|mingw*)
    LIB_NAME="repro_hcr_agent.dll"
    CC_DEFAULT="gcc"
    SHARED_FLAGS="-shared"
    EXTRA_LIBS=""
    DEFINES="-DREPRO_HCR_AGENT_BUILD_DLL"
    ;;
  *)
    echo "Unsupported target OS: $TARGET_OS" >&2
    exit 1
    ;;
esac

if [[ "$PRINT_NAME" -eq 1 ]]; then
  echo "$LIB_NAME"
  exit 0
fi

OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/build}"
mkdir -p "$OUT_DIR"
OUT_PATH="$OUT_DIR/$LIB_NAME"

CC="${CC:-$CC_DEFAULT}"
if ! command -v "$CC" >/dev/null 2>&1; then
  CC="cc"
fi

echo "[repro_hcr_agent] Compiling $LIB_NAME with $CC for $TARGET_OS..."
# Compile shared library
"$CC" -O2 -g -Wall -Wextra \
  $SHARED_FLAGS \
  $DEFINES \
  -I "$C_DIR" \
  "$SRC_C" \
  $EXTRA_LIBS \
  -o "$OUT_PATH"

echo "[repro_hcr_agent] Successfully built: $OUT_PATH"

# Also copy to build/lib for standard -L.../build/lib link conventions
mkdir -p "$SCRIPT_DIR/build/lib"
if [[ "$OUT_PATH" != "$SCRIPT_DIR/build/lib/$LIB_NAME" ]]; then
  cp -f "$OUT_PATH" "$SCRIPT_DIR/build/lib/$LIB_NAME"
fi
