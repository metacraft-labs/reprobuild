#!/bin/sh
# R7 cc-wrapper: gcc 15.2 + binutils-final + glibc 2.42 (from-source)
# Auto-injects: dynamic linker, rpath, lib path, include path, binutils B-path.
# Critical: --sysroot=/ + -nostdinc to isolate from gcc's built-in musl sysroot.
# Explicit -isystem chain: glibc -> gcc-fixed -> gcc-builtins (in include-search order).
set -u
GCC=/tmp/r5-build/gcc152/bin/gcc
GLIBC=/tmp/r6-build/glibc
BINUTILS=/tmp/r5-build/binutils-final
GCCLIB=/tmp/r5-build/gcc152/lib/gcc/x86_64-pc-linux-gnu/15.2.0
exec "$GCC" \
  --sysroot=/ \
  -nostdinc \
  -isystem "$GLIBC/include" \
  -isystem "$GCCLIB/include" \
  -isystem "$GCCLIB/include-fixed" \
  -B"$BINUTILS/bin" \
  -B"$GLIBC/lib" \
  -Wl,--dynamic-linker="$GLIBC/lib/ld-linux-x86-64.so.2" \
  -Wl,-rpath,"$GLIBC/lib" \
  -L"$GLIBC/lib" \
  -L"$GCCLIB" \
  "$@"
