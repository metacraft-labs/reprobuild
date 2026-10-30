#!/usr/bin/env bash
# Regenerates the object-check fixtures (t_target_object_check.nim).
# Real toolchain output, not hand-made headers: the test's point is that the
# check reads what compilers actually emit. Generated 2026-10-30 with
# nixpkgs zig 0.13.0 (clang) and the dev shell's gcc; run from this
# directory with both on PATH. Outputs are small and committed.
set -euo pipefail
cd "$(dirname "$0")"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export ZIG_GLOBAL_CACHE_DIR=$work/zg ZIG_LOCAL_CACHE_DIR=$work/zl
printf 'int f(double x){return (int)(x*2);}\n' > "$work/a.c"
printf '.text\n.globl g\ng: bx lr\n' > "$work/b.S"
# armhf C object: Tag_ABI_VFP_args = VFP registers, e_flags hard-float.
zig cc -target arm-linux-musleabihf -c "$work/a.c" -o armhf.o
# soft-float C object compiled for an FPU (softfp): base-PCS args.
zig cc -target arm-linux-musleabi -c "$work/a.c" -o armsoft.o
# FP-free armhf assembly: e_flags say soft-float, no Tag_FP_arch.
zig cc -target arm-linux-musleabihf -c "$work/b.S" -o armhf-asm.o
# linked images: lld straight over one object, stripped, so they stay tiny.
zig ld.lld -shared -s armhf.o -o armhf.so
zig ld.lld -shared -s armsoft.o -o armsoft.so
gcc -c "$work/a.c" -o x86_64.o
rm -f mixed.a armhf.a
ar rcs armhf.a armhf.o armhf-asm.o
ar rcs mixed.a armhf.o x86_64.o
