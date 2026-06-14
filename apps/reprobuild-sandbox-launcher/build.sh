#!/usr/bin/env bash
# Build script for reprobuild-sandbox-launcher.
#
# Usage:
#   ./build.sh                  # builds to ./reprobuild-sandbox-launcher
#   ./build.sh --out <path>     # custom output path
#
# Set CC to override the compiler (default: cc). On Linux this is
# normally gcc or clang.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/launcher.c"
OUT="$SCRIPT_DIR/reprobuild-sandbox-launcher"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --out=*) OUT="${1#--out=}"; shift;;
    *) echo "unknown argument: $1" >&2; exit 1;;
  esac
done

CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2 -Wall -Wextra -Wno-unused-parameter -std=c11}"

# Append ".exe" on Windows MSYS shells so the OS picks the binary up.
case "$(uname -s 2>/dev/null || echo Unknown)" in
  MINGW*|MSYS*|CYGWIN*) [[ "$OUT" == *.exe ]] || OUT="${OUT}.exe" ;;
esac

echo "building: $CC $CFLAGS -o $OUT $SRC"
$CC $CFLAGS -o "$OUT" "$SRC"
echo "built: $OUT"
