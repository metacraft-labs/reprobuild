#!/bin/bash
# build-mes.sh — Phase 5 (R4d): build GNU Mes 0.27.1 (Scheme + minimal C
# interpreter/compiler) and its libc.a / libc-mini.a / libmescc.a /
# libc+tcc.a / crt1.o on top of stage0-posix + mescc-tools (Phase 3+4).
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/mes/default.nix
# (commit 06a4933d0 era).  Build wallclock is the heaviest single step
# in the chain (30-60 min CPU): the mes-m2 Scheme interpreter rebuilds
# itself + ~133 C source files via the Scheme-driven mescc.scm pipeline.
#
# Inputs (positional):
#   $1 = vendor dir   (contains mes-0.27.1.tar.gz + nyacc-1.09.1.tar.gz +
#                      minimal-bootstrap-sources.tar.gz)
#   $2 = mescc-tools dir (with bin/{M1,M2,M2-Planet,M2-Mesoplanet,
#                         blood-elf,hex2,replace,mkdir,cp,chmod,
#                         get_machine})
#   $3 = output dir   (will hold bin/mes, lib/x86_64-mes/{libc-mini.a,
#                      libmescc.a,libc.a,libc+tcc.a,crt1.o},
#                      include/, SHA256SUMS, mescc.scm)
#
# Required env: SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC.
#
# Reproducibility notes:
#   * The mescc.scm.in template is patched to embed MES_PREFIX as the
#     INSTALLED mes source tree (under $OUT/share/mes-0.27.1).  This
#     means we install the patched mes source tree alongside the
#     compiler so that the path embedded in mes-m2 + mescc.scm + libs
#     remains valid at "runtime" (i.e. when Phase 6's tcc build
#     re-invokes mes-m2).
#   * GUILE_LOAD_PATH is patched in two .mes files to point to the
#     installed mes module dir + nyacc module dir.
#   * Several arch-specific source patches (per nixpkgs's preBuild) are
#     applied for correctness of x86_64 builds; without them the mes
#     libc has miscompiles / mis-syscalls.
#   * SOURCE_DATE_EPOCH governs every tar/cp/install touch; verified by
#     sha256-bit-identical re-runs (run twice and diff SHA256SUMS).

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-mes.sh <vendor-dir> <mescc-tools-dir> <out-dir>}"
MESCC_TOOLS="${2:?usage: build-mes.sh <vendor-dir> <mescc-tools-dir> <out-dir>}"
OUT="${3:?usage: build-mes.sh <vendor-dir> <mescc-tools-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
MESCC_TOOLS_ABS="$(cd "$MESCC_TOOLS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

# Sanity check inputs.
for bin in M1 M2 M2-Planet M2-Mesoplanet blood-elf hex2 replace mkdir cp chmod get_machine; do
  if [ ! -x "$MESCC_TOOLS_ABS/bin/$bin" ]; then
    echo "[mes] ERROR: missing mescc-tools binary $MESCC_TOOLS_ABS/bin/$bin" >&2
    exit 1
  fi
done

for tarball in mes-0.27.1.tar.gz nyacc-1.09.1.tar.gz; do
  if [ ! -f "$VENDOR_ABS/$tarball" ]; then
    echo "[mes] ERROR: missing vendor tarball $VENDOR_ABS/$tarball" >&2
    exit 1
  fi
done

# Put our locally-built tools on PATH for kaem.  We *append* (not
# prepend) so mescc-tools `cp`/`mkdir`/`chmod` (which don't support
# `-r` / `-p` / standard flags) don't shadow the system coreutils
# the script itself uses.  kaem will resolve M1/M2/hex2/blood-elf
# from this dir because the system doesn't have them.
export PATH="$PATH:$MESCC_TOOLS_ABS/bin"

WORK="$(mktemp -d -t reproos-r4d-mes-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "[mes] WORK=$WORK"
echo "[mes] VENDOR=$VENDOR_ABS"
echo "[mes] MESCC_TOOLS=$MESCC_TOOLS_ABS"
echo "[mes] OUT=$OUT_ABS"

log() { echo "[mes] $*"; }

VERSION=0.27.1
ARCH=x86_64
STAGE0_ARCH=amd64
BLOOD_ELF_FLAGS="--64"

# Stage 1: unpack source trees.
log "unpacking mes-${VERSION}.tar.gz"
tar -xzf "$VENDOR_ABS/mes-${VERSION}.tar.gz" -C "$WORK"
MES_SRC="$WORK/mes-${VERSION}"

log "unpacking nyacc-1.09.1.tar.gz"
mkdir -p "$WORK/nyacc-share"
tar -xzf "$VENDOR_ABS/nyacc-1.09.1.tar.gz" -C "$WORK/nyacc-share"
NYACC_MODULE_DIR="$WORK/nyacc-share/nyacc-1.09.1/module"
if [ ! -d "$NYACC_MODULE_DIR" ]; then
  echo "[mes] ERROR: expected nyacc module dir $NYACC_MODULE_DIR missing" >&2
  exit 1
fi

# We do *not* install nyacc anywhere persistent; we just point the
# patched guile-module.mes at it via a fixed install path.  Copy nyacc
# into $OUT/share/nyacc so the embedded path remains valid post-build.
mkdir -p "$OUT_ABS/share"
log "installing nyacc module tree to $OUT_ABS/share/nyacc-1.09.1"
# mescc-tools cp is single-file only and silently treats -r as
# unknown; use system cp.
cp -r "$WORK/nyacc-share/nyacc-1.09.1" "$OUT_ABS/share/"

# Install the mes source under $OUT/share so embedded MES_PREFIX
# references stay valid.  We copy from $MES_SRC after we apply patches
# (below).

# Stage 2: generate config.h.
log "generating include/mes/config.h (uintptr_t=unsigned long for x86_64)"
cat > "$MES_SRC/include/mes/config.h" <<'EOF'
#ifndef _MES_CONFIG_H
#undef SYSTEM_LIBC
#define MES_VERSION "0.27.1"
#ifndef __M2__
typedef unsigned long uintptr_t;
typedef unsigned long size_t;
typedef long ssize_t;
typedef long intptr_t;
typedef long ptrdiff_t;
#define __MES_SIZE_T
#define __MES_SSIZE_T
#define __MES_INTPTR_T
#define __MES_UINTPTR_T
#define __MES_PTRDIFF_T
#endif
#endif
EOF

REPLACE="$MESCC_TOOLS_ABS/bin/replace"

# Convenience wrapper: edit a file in place with `replace`.
# Usage: rep <file> <match> <replacement>
rep() {
  local file="$1" match="$2" rep="$3"
  "$REPLACE" --file "$file" --output "$file" --match-on "$match" --replace-with "$rep"
}

# Stage 3: apply ~15 source-text patches.
log "patching lib/linux/x86_64-mes-gcc/_exit.c (rax/rdi clobber list)"
rep "$MES_SRC/lib/linux/x86_64-mes-gcc/_exit.c" \
    '(code)' \
    '(code) : "rax", "rdi"'

log "replacing lib/x86_64-mes-gcc/setjmp.c with x86_64 asm version"
cat > "$MES_SRC/lib/x86_64-mes-gcc/setjmp.c" <<'EOF'
/*
 * setjmp() & longjmp() implementation for x86_64.
 * Replaces a buggy C implementation.  Copied verbatim from
 * nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/mes/setjmp_x86_64.c.
 */

#include <setjmp.h>
#include <stdlib.h>

asm (".global __longjmp\n\t"
     ".global _longjmp\n\t"
     ".global longjmp\n\t"
     ".type __longjmp, %function\n\t"
     ".type _longjmp,  %function\n\t"
     ".type longjmp,   %function\n\t"
     "__longjmp:\n\t"
     "_longjmp:\n\t"
     "longjmp:\n\t"

     /* ensure return value is non-zero */
     "mov    %rsi,     %rax\n\t"
     "test   %rax,     %rax\n\t"
     "sete   %bl\n\t"
     "movsbq %bl,      %rbx\n\t"
     "add    %rbx,     %rax\n\t"

     "movq 0x00(%rdi), %rbp\n\t" /* rbp = env->__bp */
     "movq 0x10(%rdi), %rsp\n\t" /* rsp = env->__sp */
     "movq 0x08(%rdi), %rbx\n\t" /* rbx = env->__pc */
     "jmp  *%rbx\n\t"
);

asm (".global __setjmp\n\t"
     ".global _setjmp \n\t"
     ".global setjmp\n\t"
     ".type __setjmp, %function\n\t"
     ".type _setjmp,  %function\n\t"
     ".type setjmp,   %function\n\t"
     "__setjmp:\n\t"
     "_setjmp:\n\t"
     "setjmp:\n\t"
     "movq %rbp,   0x00(%rdi)\n\t" /* env->__bp = base pointer from caller */
     "movq (%rsp), %rax\n\t"       /* rax = return address to caller */
     "movq %rax,   0x08(%rdi)\n\t" /* env->__pc = retaddr */
     "movq %rsp,   %rax\n\t"       /* rax = stack pointer */
     "add  $8,     %rax\n\t"       /* offset sp to skip return addr */
     "movq %rax,   0x10(%rdi)\n\t" /* env->__sp = sp before call */
     "movq $0,     %rax\n\t"
     "ret\n\t");
EOF

log "patching lib/linux/link.c (linkat syscall arg count: 4->5)"
rep "$MES_SRC/lib/linux/link.c" \
    '_sys_call4' '_sys_call5'
rep "$MES_SRC/lib/linux/link.c" \
    'AT_FDCWD, (long) new_name' 'AT_FDCWD, (long) new_name, 0'

log "patching include/linux/x86_64/syscall.h (SYS_nanosleep 0x33->0x23)"
rep "$MES_SRC/include/linux/x86_64/syscall.h" \
    'SYS_nanosleep 0x33' 'SYS_nanosleep 0x23'

log "patching lib/string/strpbrk.c (return NULL on no match)"
# ORDER matters here per nixpkgs preBuild comment.
rep "$MES_SRC/lib/string/strpbrk.c" 'return p;' 'return 0;'
rep "$MES_SRC/lib/string/strpbrk.c" 'break;' 'return p;'

log "patching lib/mes/ntoab.c (size_t -> unsigned long)"
rep "$MES_SRC/lib/mes/ntoab.c" 'size_t' 'unsigned long'

log "patching lib/linux/ioctl3.c (size_t -> unsigned long)"
rep "$MES_SRC/lib/linux/ioctl3.c" 'size_t' 'unsigned long'

log "patching include/mes/lib.h (size_t command -> unsigned long command)"
rep "$MES_SRC/include/mes/lib.h" 'size_t command' 'unsigned long command'

# vfprintf: replace long-arg assumptions with caller-specified width.
# Order matters: more-specific patches first, then more-general.
log "patching lib/stdio/vfprintf.c (long-arg portability)"
rep "$MES_SRC/lib/stdio/vfprintf.c" \
    'int count = 0;' \
    'int count = 0; int has_l = 0;'
rep "$MES_SRC/lib/stdio/vfprintf.c" \
    'long d = va_arg (ap, long);' \
    '
long d;
if (has_l) {
  has_l = 0;
  d = va_arg (ap, long);
} else if (c != '\''d'\'' && c != '\''i'\'') {
  d = (long) (va_arg (ap, unsigned int));
} else {
  d = (long) (va_arg (ap, int));
}
'
rep "$MES_SRC/lib/stdio/vfprintf.c" \
    "if (c == 'l')" \
    "
if (c == 'l') {
  has_l = 1;
  c = *++p;
} else if (0)"
rep "$MES_SRC/lib/stdio/vfprintf.c" 'va_arg8' 'va_arg'

log "patching lib/stdio/vsnprintf.c (long-arg portability)"
rep "$MES_SRC/lib/stdio/vsnprintf.c" \
    'int count = 0;' \
    'int count = 0; int has_l = 0;'
rep "$MES_SRC/lib/stdio/vsnprintf.c" \
    'long d = va_arg (ap, long);' \
    '
long d;
if (has_l) {
  has_l = 0;
  d = va_arg (ap, long);
} else if (c != '\''d'\'' && c != '\''i'\'') {
  d = (long) (va_arg (ap, unsigned int));
} else {
  d = (long) (va_arg (ap, int));
}
'
rep "$MES_SRC/lib/stdio/vsnprintf.c" \
    "if (c == 'l')" \
    "
if (c == 'l') {
  has_l = 1;
  c = *++p;
} else if (0)"
rep "$MES_SRC/lib/stdio/vsnprintf.c" 'va_arg8' 'va_arg'

# Stage 4: arch-symlink fixups (include/arch/* mirrors per-arch).
log "setting up include/arch -> linux/${ARCH}"
mkdir -p "$MES_SRC/include/arch"
cp "$MES_SRC/include/linux/${ARCH}/kernel-stat.h" "$MES_SRC/include/arch/kernel-stat.h"
cp "$MES_SRC/include/linux/${ARCH}/signal.h"      "$MES_SRC/include/arch/signal.h"
cp "$MES_SRC/include/linux/${ARCH}/syscall.h"     "$MES_SRC/include/arch/syscall.h"

# Remove pregenerated psyntax that confuses mes-m2 rebuilds.
log "removing pregenerated psyntax.pp"
rm -f "$MES_SRC/mes/module/mes/psyntax.pp" "$MES_SRC/mes/module/mes/psyntax.pp.header"

# srfi-9 helpers that the tarball ships as symlinks (broken on Windows-
# extracted tarballs / cp -r).  If the symlink target already exists at
# the dest, that means the tarball was extracted with symlinks-as-files
# semantics and the dest IS the source — no work to do.
log "fixing srfi-9 symlinks"
fix_srfi() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    rm -f "$dst"
    cp "$src" "$dst"
  elif [ -f "$dst" ] && [ -f "$src" ] && [ "$(realpath "$src")" = "$(realpath "$dst")" ]; then
    : # already the same file, nothing to do
  else
    cp "$src" "$dst"
  fi
}
fix_srfi "$MES_SRC/mes/module/srfi/srfi-9-struct.mes" \
         "$MES_SRC/mes/module/srfi/srfi-9.mes"
fix_srfi "$MES_SRC/mes/module/srfi/srfi-9/gnu-struct.mes" \
         "$MES_SRC/mes/module/srfi/srfi-9/gnu.mes"

# Stage 5: embed installed-prefix paths into Scheme + C sources.
#
# REPRODUCIBILITY HAZARD: the embedded paths bake into the mes-m2
# binary + mescc.scm bytes.  To keep bytes stable across users / hosts
# we embed FIXED canonical paths under /repro/mes-... (chosen for
# brevity + collision-freedom), NOT $OUT_ABS or $WORK.
#
# Subsequent users of this mes (Phase 6 tcc build, etc.) must arrange
# for /repro/mes-${VERSION} to point at the install (e.g. via symlink
# or bind mount).  This is the same "stable-prefix" convention nixpkgs
# uses (where the embedded path is a nix store path, content-
# addressable but fixed per build).
MES_PREFIX="/repro/mes-${VERSION}"
NYACC_GUILE_PATH="/repro/nyacc-1.09.1/module"
# Also need a STAGING dir on tmpfs for the actual build (cannot read
# 1-byte-at-a-time over 9p drvfs without 100x slowdown).
STAGING="$WORK/staging"
STAGING_MES_PREFIX="$STAGING/repro/mes-${VERSION}"
STAGING_NYACC_DIR="$STAGING/repro/nyacc-1.09.1"
mkdir -p "$STAGING/repro"
GUILE_LOAD_PATH_LITERAL="\"${MES_PREFIX}/mes/module:${MES_PREFIX}/module:${NYACC_GUILE_PATH}\""

log "patching mes/module/mes/guile-module.mes + guile.mes (GUILE_LOAD_PATH)"
rep "$MES_SRC/mes/module/mes/guile-module.mes" \
    '(getenv "GUILE_LOAD_PATH")' \
    "$GUILE_LOAD_PATH_LITERAL"
rep "$MES_SRC/mes/module/mes/guile.mes" \
    '(getenv "GUILE_LOAD_PATH")' \
    "$GUILE_LOAD_PATH_LITERAL"

# module/mescc/mescc.scm: replace getenv lookups with embedded paths.
log "patching module/mescc/mescc.scm (M1/HEX2/BLOOD_ELF/srcdest paths)"
rep "$MES_SRC/module/mescc/mescc.scm" \
    '(getenv "M1")' "\"${MESCC_TOOLS_ABS}/bin/M1\""
rep "$MES_SRC/module/mescc/mescc.scm" \
    '(getenv "HEX2")' "\"${MESCC_TOOLS_ABS}/bin/hex2\""
rep "$MES_SRC/module/mescc/mescc.scm" \
    '(getenv "BLOOD_ELF")' "\"${MESCC_TOOLS_ABS}/bin/blood-elf\""
rep "$MES_SRC/module/mescc/mescc.scm" \
    '(getenv "srcdest")' "\"${MES_PREFIX}\""

log "patching src/mes.c (MES_PREFIX + srcdest)"
rep "$MES_SRC/src/mes.c" \
    'getenv ("MES_PREFIX")' "\"${MES_PREFIX}\""
rep "$MES_SRC/src/mes.c" \
    'getenv ("srcdest")' "\"${MES_PREFIX}\""

log "patching src/gc.c (MES_ARENA/MES_MAX_ARENA/MES_STACK)"
rep "$MES_SRC/src/gc.c" \
    'getenv ("MES_ARENA")' '"100000000"'
rep "$MES_SRC/src/gc.c" \
    'getenv ("MES_MAX_ARENA")' '"100000000"'
rep "$MES_SRC/src/gc.c" \
    'getenv ("MES_STACK")' '"6000000"'

# Stage 6: generate mescc.scm from mescc.scm.in template.
log "patching scripts/mescc.scm.in template"
rep "$MES_SRC/scripts/mescc.scm.in" \
    '(getenv "MES_PREFIX")' "\"${MES_PREFIX}\""
rep "$MES_SRC/scripts/mescc.scm.in" \
    '(getenv "includedir")' "\"${MES_PREFIX}/include\""
rep "$MES_SRC/scripts/mescc.scm.in" \
    '(getenv "libdir")' "\"${MES_PREFIX}/lib\""
rep "$MES_SRC/scripts/mescc.scm.in" \
    '@prefix@' "${MES_PREFIX}"
rep "$MES_SRC/scripts/mescc.scm.in" \
    '@VERSION@' "${VERSION}"
rep "$MES_SRC/scripts/mescc.scm.in" \
    '@mes_cpu@' "${ARCH}"
rep "$MES_SRC/scripts/mescc.scm.in" \
    '@mes_kernel@' "linux"

mkdir -p "$OUT_ABS/bin"
# scripts/mescc.scm.in was patched in-place; install both at the
# canonical /repro path (via the staging symlink — copied just below
# when we stage the source tree) and at $OUT_ABS/bin (the persistent
# install).  Use the in-place patched file as the source.
cp "$MES_SRC/scripts/mescc.scm.in" "$OUT_ABS/bin/mescc.scm"
chmod 0555 "$OUT_ABS/bin/mescc.scm"
# The mescc.scm at staging path will be created when we stage the
# source tree (the .scm.in gets carried as-is; we install a copy at
# bin/mescc.scm separately).

# Stage 7: install the patched mes source tree to $OUT_ABS/share AND
# stage a copy on tmpfs for the build.  We use symlinks: create
# /repro/mes-VERSION -> $STAGING_MES_PREFIX (on /tmp/.../staging).
# That way the embedded paths in mes-m2 resolve to the FAST tmpfs copy
# during this build session.  The persistent share dir in $OUT_ABS
# survives the build's trap cleanup so Phase 6 can restage it.
log "staging patched mes source tree to $STAGING_MES_PREFIX (tmpfs, fast)"
mkdir -p "$STAGING_MES_PREFIX"
cp -r "$MES_SRC/." "$STAGING_MES_PREFIX/"

log "staging nyacc to $STAGING_NYACC_DIR"
mkdir -p "$STAGING_NYACC_DIR"
cp -r "$WORK/nyacc-share/nyacc-1.09.1/." "$STAGING_NYACC_DIR/"

log "creating /repro -> staging symlinks"
mkdir -p /repro 2>/dev/null || sudo mkdir -p /repro
# If /repro/mes-VERSION already exists (previous run), unlink it.
rm -rf "/repro/mes-${VERSION}" "/repro/nyacc-1.09.1" 2>/dev/null || true
ln -snf "$STAGING_MES_PREFIX" "/repro/mes-${VERSION}"
ln -snf "$STAGING_NYACC_DIR"  "/repro/nyacc-1.09.1"
# Verify the symlink resolves:
if [ ! -d "/repro/mes-${VERSION}/include" ]; then
  echo "[mes] ERROR: /repro/mes-${VERSION} symlink failed; cannot proceed" >&2
  ls -la /repro/ >&2 || true
  exit 1
fi

# Persist the patched mes source tree under OUT_ABS so Phase 6 (and
# Phase 5 re-runs) can restage it without needing the original tarball
# + patch sequence again.  Do this BEFORE the slow compile, in case
# the build aborts mid-way (so we don't lose the patched source).
log "installing persistent mes share tree to $OUT_ABS/share/mes-${VERSION}"
mkdir -p "$OUT_ABS/share"
rm -rf "$OUT_ABS/share/mes-${VERSION}"
cp -r "$STAGING_MES_PREFIX" "$OUT_ABS/share/mes-${VERSION}"

# Stage 8: run kaem to build mes-m2 (the bootstrap mes binary).  We
# run it FROM the installed prefix so the srcdest=./ relative paths in
# kaem.run resolve against the same tree the patches embedded.
log "running kaem to build mes-m2 (this is the long step: ~10-30 min CPU)"
cd "$MES_PREFIX"
# Set up env vars kaem.run references via ${srcdest}.  kaem.run uses
# ${srcdest} prefix-style, so we need srcdest set to "" (cwd-relative).
export srcdest=""
KAEM="$WORK/../stage0-posix-kaem"
# Actually use the one passed via PATH (we'll set PATH to include
# stage0/kaem-unwrapped).  Easier: use a stable PATH.

# Re-export PATH with kaem-unwrapped present (assumed to be sibling
# of mescc-tools dir).
KAEM_DIR="$(dirname "$MESCC_TOOLS_ABS")/stage0-posix"
if [ ! -x "$KAEM_DIR/kaem-unwrapped" ]; then
  # Fall back: search upward for stage0-posix/kaem-unwrapped under build/.
  KAEM_DIR=""
  for d in "$MESCC_TOOLS_ABS/../stage0-posix" \
           "$(dirname "$MESCC_TOOLS_ABS")/stage0-posix"; do
    if [ -x "$d/kaem-unwrapped" ]; then
      KAEM_DIR="$d"
      break
    fi
  done
fi
if [ -z "$KAEM_DIR" ] || [ ! -x "$KAEM_DIR/kaem-unwrapped" ]; then
  echo "[mes] ERROR: cannot locate kaem-unwrapped relative to $MESCC_TOOLS_ABS" >&2
  exit 1
fi
log "using kaem from $KAEM_DIR/kaem-unwrapped"
export PATH="$KAEM_DIR:$PATH"

# kaem.x86_64 is a 5-line shell script that sets cc_cpu/mes_cpu/etc
# then exec's `kaem --verbose --strict` (which reads kaem.run by
# default).  We need to evaluate the shell vars and then invoke kaem
# manually because our kaem-unwrapped is not on a /bin/sh-shebang
# path.
# Easiest: source kaem.x86_64 in *this* shell (it just sets vars and
# runs kaem) — but redirect the kaem call to our kaem-unwrapped.

# Inline what kaem.x86_64 does:
export cc_cpu=x86_64
export mes_cpu=x86_64
export stage0_cpu=amd64
export blood_elf_flag=--64

log "kaem-unwrapped --verbose --strict --file kaem.run"
"$KAEM_DIR/kaem-unwrapped" --verbose --strict --file kaem.run \
  > "$WORK/kaem.log" 2>&1 || {
    rc=$?
    echo "[mes] kaem-unwrapped failed (exit $rc); tail of log:" >&2
    tail -40 "$WORK/kaem.log" >&2
    exit "$rc"
  }
log "kaem build OK (log: $WORK/kaem.log, $(wc -l < "$WORK/kaem.log") lines)"

# After kaem.run, we should have bin/mes-m2 and bin/mes (a copy).
if [ ! -x "bin/mes-m2" ]; then
  echo "[mes] ERROR: mes-m2 not built at $MES_PREFIX/bin/mes-m2" >&2
  exit 1
fi
# Stage mes-m2 + mescc.scm on tmpfs for fast invocation.  Also write
# them to OUT_ABS for the persistent install.
mkdir -p "$STAGING/repro/bin"
cp "bin/mes-m2" "$STAGING/repro/bin/mes-m2"
chmod 0555 "$STAGING/repro/bin/mes-m2"
cp "$MES_SRC/scripts/mescc.scm.in" "$STAGING/repro/bin/mescc.scm"
chmod 0555 "$STAGING/repro/bin/mescc.scm"
cp "bin/mes-m2" "$OUT_ABS/bin/mes-m2"
chmod 0555 "$OUT_ABS/bin/mes-m2"

# Sanity: ensure mes-m2 runs (via the tmpfs copy).
log "smoke: mes-m2 -c '(display 1)(newline)'"
"$STAGING/repro/bin/mes-m2" -c '(display 1)(newline)' || {
  echo "[mes] ERROR: mes-m2 smoke failed" >&2
  exit 1
}

# Stage 9: drive mescc.scm via mes-m2 to compile libc/libc-mini/libmescc
# and libc+tcc and crt1.o.  Because mes-m2 is slow, we batch each
# library: compile each .c -> .o (one mes-m2 invocation per file),
# then `catm` to make the .a.
#
# CRITICAL: read from /repro/mes-VERSION (tmpfs symlink), write to /tmp
# (tmpfs).  Reading from drvfs would slow each compile 100x.

LIBDIR="$OUT_ABS/lib/${ARCH}-mes"
mkdir -p "$LIBDIR"

CC="$STAGING/repro/bin/mes-m2"
CCARGS=(
  -e main "$STAGING/repro/bin/mescc.scm" --
  -D HAVE_CONFIG_H=1
  -I "$MES_PREFIX/include"
  -I "$MES_PREFIX/include/linux/${ARCH}"
)

# Compile a single .c -> .o via mes-m2.
compile_one() {
  local src="$1" out="$2"
  log "  mescc: $src -> $out"
  "$CC" "${CCARGS[@]}" -c -o "$out" "$MES_PREFIX/$src" \
    > "$WORK/mescc.log" 2>&1 || {
      rc=$?
      echo "[mes] ERROR: compile of $src failed (exit $rc); log:" >&2
      tail -40 "$WORK/mescc.log" >&2
      exit "$rc"
    }
}

build_lib() {
  local libname="$1"
  shift
  local sources=("$@")
  local objs=()
  local sfiles=()
  local objdir="$WORK/obj/${libname}"
  mkdir -p "$objdir"
  log "building ${libname}.a + ${libname}.s from ${#sources[@]} sources..."
  for src in "${sources[@]}"; do
    local base
    base="$(basename "$src" .c)"
    local obj="$objdir/${base}.o"
    compile_one "$src" "$obj"
    objs+=("$obj")
    # mescc.scm emits both base.o and base.s; collect the .s too.
    sfiles+=("${obj%.o}.s")
  done
  log "  catm -> $WORK/obj/${libname}.a (object archive)"
  local tmp_lib="$WORK/obj/${libname}.a"
  local tmp_libs="$WORK/obj/${libname}.s"
  "$MESCC_TOOLS_ABS/../stage0-posix/catm" "$tmp_lib" "${objs[@]}" 2>/dev/null \
    || cat "${objs[@]}" > "$tmp_lib"
  log "  catm -> $WORK/obj/${libname}.s (source archive)"
  "$MESCC_TOOLS_ABS/../stage0-posix/catm" "$tmp_libs" "${sfiles[@]}" 2>/dev/null \
    || cat "${sfiles[@]}" > "$tmp_libs"
  cp "$tmp_lib"  "$LIBDIR/${libname}.a"
  cp "$tmp_libs" "$LIBDIR/${libname}.s"
}

# libc-mini sources for x86_64 / mescc (from sources.json[x86_64].linux.mescc).
LIBC_MINI_SOURCES=(
  lib/mes/__init_io.c
  lib/mes/eputs.c
  lib/mes/oputs.c
  lib/mes/globals.c
  lib/stdlib/exit.c
  lib/linux/x86_64-mes-mescc/_exit.c
  lib/linux/x86_64-mes-mescc/_write.c
  lib/stdlib/puts.c
  lib/string/strlen.c
  lib/mes/write.c
)

LIBMESCC_SOURCES=(
  lib/mes/globals.c
  lib/linux/x86_64-mes-mescc/syscall-internal.c
)

# Common "libc" tail shared between libc / libc+tcc.  Extracted from
# sources.json[x86_64].linux.mescc.libc_SOURCES (133 entries).
LIBC_SOURCES=(
  lib/mes/__init_io.c
  lib/mes/eputs.c
  lib/mes/oputs.c
  lib/mes/globals.c
  lib/stdlib/exit.c
  lib/linux/x86_64-mes-mescc/_exit.c
  lib/linux/x86_64-mes-mescc/_write.c
  lib/stdlib/puts.c
  lib/string/strlen.c
  lib/ctype/isnumber.c
  lib/mes/abtol.c
  lib/mes/cast.c
  lib/mes/eputc.c
  lib/mes/fdgetc.c
  lib/mes/fdputc.c
  lib/mes/fdputs.c
  lib/mes/fdungetc.c
  lib/mes/itoa.c
  lib/mes/ltoa.c
  lib/mes/ltoab.c
  lib/mes/mes_open.c
  lib/mes/ntoab.c
  lib/mes/oputc.c
  lib/mes/ultoa.c
  lib/mes/utoa.c
  lib/stub/__raise.c
  lib/ctype/isdigit.c
  lib/ctype/isspace.c
  lib/ctype/isxdigit.c
  lib/mes/assert_msg.c
  lib/posix/write.c
  lib/stdlib/atoi.c
  lib/linux/lseek.c
  lib/dirent/__getdirentries.c
  lib/dirent/closedir.c
  lib/dirent/opendir.c
  lib/mes/__assert_fail.c
  lib/mes/__buffered_read.c
  lib/mes/__mes_debug.c
  lib/posix/execv.c
  lib/posix/getcwd.c
  lib/posix/getenv.c
  lib/posix/isatty.c
  lib/posix/open.c
  lib/posix/buffered-read.c
  lib/posix/setenv.c
  lib/posix/wait.c
  lib/stdio/fgetc.c
  lib/stdio/fputc.c
  lib/stdio/fputs.c
  lib/stdio/getc.c
  lib/stdio/getchar.c
  lib/stdio/putc.c
  lib/stdio/putchar.c
  lib/stdio/ungetc.c
  lib/stdlib/calloc.c
  lib/stdlib/free.c
  lib/stdlib/realloc.c
  lib/string/memchr.c
  lib/string/memcmp.c
  lib/string/memcpy.c
  lib/string/memmove.c
  lib/string/memset.c
  lib/string/strcmp.c
  lib/string/strcpy.c
  lib/string/strncmp.c
  lib/posix/raise.c
  lib/linux/access.c
  lib/linux/brk.c
  lib/linux/chdir.c
  lib/linux/chmod.c
  lib/linux/clock_gettime.c
  lib/linux/close.c
  lib/linux/dup.c
  lib/linux/dup2.c
  lib/linux/execve.c
  lib/linux/fcntl.c
  lib/linux/fork.c
  lib/linux/fstat.c
  lib/linux/fsync.c
  lib/linux/_getcwd.c
  lib/linux/getdents.c
  lib/linux/gettimeofday.c
  lib/linux/ioctl3.c
  lib/linux/link.c
  lib/linux/lstat.c
  lib/linux/_open3.c
  lib/linux/malloc.c
  lib/linux/mkdir.c
  lib/linux/nanosleep.c
  lib/linux/pipe.c
  lib/linux/_read.c
  lib/linux/readdir.c
  lib/linux/rename.c
  lib/linux/rmdir.c
  lib/linux/stat.c
  lib/linux/symlink.c
  lib/linux/time.c
  lib/linux/umask.c
  lib/linux/uname.c
  lib/linux/unlink.c
  lib/linux/utimensat.c
  lib/linux/wait4.c
  lib/linux/waitpid.c
  lib/linux/x86_64-mes-mescc/syscall.c
  lib/linux/getpid.c
  lib/linux/kill.c
)

# libc+tcc — sources.json[x86_64].linux.mescc.libc_tcc_SOURCES PLUS
# lib/linux/symlink.c (added per nixpkgs default.nix).
LIBC_TCC_SOURCES=(
  lib/mes/__init_io.c
  lib/mes/eputs.c
  lib/mes/oputs.c
  lib/mes/globals.c
  lib/stdlib/exit.c
  lib/linux/x86_64-mes-mescc/_exit.c
  lib/linux/x86_64-mes-mescc/_write.c
  lib/stdlib/puts.c
  lib/string/strlen.c
  lib/ctype/isnumber.c
  lib/mes/abtol.c
  lib/mes/cast.c
  lib/mes/eputc.c
  lib/mes/fdgetc.c
  lib/mes/fdputc.c
  lib/mes/fdputs.c
  lib/mes/fdungetc.c
  lib/mes/itoa.c
  lib/mes/ltoa.c
  lib/mes/ltoab.c
  lib/mes/mes_open.c
  lib/mes/ntoab.c
  lib/mes/oputc.c
  lib/mes/ultoa.c
  lib/mes/utoa.c
  lib/stub/__raise.c
  lib/ctype/isdigit.c
  lib/ctype/isspace.c
  lib/ctype/isxdigit.c
  lib/mes/assert_msg.c
  lib/posix/write.c
  lib/stdlib/atoi.c
  lib/linux/lseek.c
  lib/dirent/__getdirentries.c
  lib/dirent/closedir.c
  lib/dirent/opendir.c
  lib/mes/__assert_fail.c
  lib/mes/__buffered_read.c
  lib/mes/__mes_debug.c
  lib/posix/execv.c
  lib/posix/getcwd.c
  lib/posix/getenv.c
  lib/posix/isatty.c
  lib/posix/open.c
  lib/posix/buffered-read.c
  lib/posix/setenv.c
  lib/posix/wait.c
  lib/stdio/fgetc.c
  lib/stdio/fputc.c
  lib/stdio/fputs.c
  lib/stdio/getc.c
  lib/stdio/getchar.c
  lib/stdio/putc.c
  lib/stdio/putchar.c
  lib/stdio/ungetc.c
  lib/stdlib/calloc.c
  lib/stdlib/free.c
  lib/stdlib/realloc.c
  lib/string/memchr.c
  lib/string/memcmp.c
  lib/string/memcpy.c
  lib/string/memmove.c
  lib/string/memset.c
  lib/string/strcmp.c
  lib/string/strcpy.c
  lib/string/strncmp.c
  lib/posix/raise.c
  lib/linux/access.c
  lib/linux/brk.c
  lib/linux/chdir.c
  lib/linux/chmod.c
  lib/linux/clock_gettime.c
  lib/linux/close.c
  lib/linux/dup.c
  lib/linux/dup2.c
  lib/linux/execve.c
  lib/linux/fcntl.c
  lib/linux/fork.c
  lib/linux/fstat.c
  lib/linux/fsync.c
  lib/linux/_getcwd.c
  lib/linux/getdents.c
  lib/linux/gettimeofday.c
  lib/linux/ioctl3.c
  lib/linux/link.c
  lib/linux/lstat.c
  lib/linux/_open3.c
  lib/linux/malloc.c
  lib/linux/mkdir.c
  lib/linux/nanosleep.c
  lib/linux/pipe.c
  lib/linux/_read.c
  lib/linux/readdir.c
  lib/linux/rename.c
  lib/linux/rmdir.c
  lib/linux/stat.c
  lib/linux/symlink.c
  lib/linux/time.c
  lib/linux/umask.c
  lib/linux/uname.c
  lib/linux/unlink.c
  lib/linux/utimensat.c
  lib/linux/wait4.c
  lib/linux/waitpid.c
  lib/linux/x86_64-mes-mescc/syscall.c
  lib/linux/getpid.c
  lib/linux/kill.c
  lib/ctype/islower.c
  lib/ctype/isupper.c
  lib/ctype/tolower.c
  lib/ctype/toupper.c
  lib/mes/abtod.c
  lib/mes/dtoab.c
  lib/mes/search-path.c
  lib/posix/execvp.c
  lib/stdio/fclose.c
  lib/stdio/fdopen.c
  lib/stdio/ferror.c
  lib/stdio/fflush.c
  lib/stdio/fopen.c
  lib/stdio/fprintf.c
  lib/stdio/fread.c
  lib/stdio/fseek.c
  lib/stdio/ftell.c
  lib/stdio/fwrite.c
  lib/stdio/printf.c
  lib/stdio/remove.c
  lib/stdio/snprintf.c
  lib/stdio/sprintf.c
  lib/stdio/sscanf.c
  lib/stdio/vfprintf.c
  lib/stdio/vprintf.c
  lib/stdio/vsnprintf.c
  lib/stdio/vsprintf.c
  lib/stdio/vsscanf.c
  lib/stdlib/qsort.c
  lib/stdlib/strtod.c
  lib/stdlib/strtof.c
  lib/stdlib/strtol.c
  lib/stdlib/strtold.c
  lib/stdlib/strtoll.c
  lib/stdlib/strtoul.c
  lib/stdlib/strtoull.c
  lib/string/memmem.c
  lib/string/strcat.c
  lib/string/strchr.c
  lib/string/strlwr.c
  lib/string/strncpy.c
  lib/string/strrchr.c
  lib/string/strstr.c
  lib/string/strupr.c
  lib/stub/sigaction.c
  lib/stub/ldexp.c
  lib/stub/mprotect.c
  lib/stub/localtime.c
  lib/stub/putenv.c
  lib/stub/realpath.c
  lib/stub/sigemptyset.c
  lib/x86_64-mes-mescc/setjmp.c
  # The "symlink" trailer added by nixpkgs default.nix:
  lib/linux/symlink.c
)

MES_SOURCES=(
  src/builtins.c
  src/cc.c
  src/core.c
  src/display.c
  src/eval-apply.c
  src/gc.c
  src/globals.c
  src/hash.c
  src/lib.c
  src/math.c
  src/mes.c
  src/module.c
  src/posix.c
  src/reader.c
  src/stack.c
  src/string.c
  src/struct.c
  src/symbol.c
  src/variable.c
  src/vector.c
)

# Build crt1 first (single source -> single .o + .s).
# Write to /tmp first (fast), copy to LIBDIR (drvfs) at end.
log "compiling crt1.c -> /tmp/.../crt1.o then $LIBDIR/crt1.o"
mkdir -p "$WORK/obj/crt"
compile_one "lib/linux/${ARCH}-mes-mescc/crt1.c" "$WORK/obj/crt/crt1.o"
cp "$WORK/obj/crt/crt1.o" "$LIBDIR/crt1.o"
cp "$WORK/obj/crt/crt1.s" "$LIBDIR/crt1.s"

log "compiling libc-mini sources (${#LIBC_MINI_SOURCES[@]})"
build_lib libc-mini "${LIBC_MINI_SOURCES[@]}"

log "compiling libmescc sources (${#LIBMESCC_SOURCES[@]})"
build_lib libmescc "${LIBMESCC_SOURCES[@]}"

log "compiling libc sources (${#LIBC_SOURCES[@]})"
build_lib libc "${LIBC_SOURCES[@]}"

log "compiling libc+tcc sources (${#LIBC_TCC_SOURCES[@]})"
build_lib libc+tcc "${LIBC_TCC_SOURCES[@]}"

# Stage 10: link the final mes binary using mes-m2 + mescc.scm.
log "compiling ${#MES_SOURCES[@]} mes binary source files"
MES_OBJDIR="$WORK/obj/mes"
mkdir -p "$MES_OBJDIR"
MES_OBJS=()
for src in "${MES_SOURCES[@]}"; do
  base="$(basename "$src" .c)"
  obj="$MES_OBJDIR/${base}.o"
  compile_one "$src" "$obj"
  MES_OBJS+=("$obj")
done

log "linking mes via mes-m2 + mescc.scm (write to tmpfs first)"
# Stage the per-lib .a + .s files on /tmp under the same -L path
# layout so `-L $TMP_LIB/.. -lc -lmescc` resolves to fast tmpfs reads
# during the link.  The catm-built .a + .s files are already at
# $WORK/obj/*.{a,s}.  mescc.scm needs BOTH libc.a AND libc.s (source
# archive for debug info / linker fallback).
TMP_LIBDIR="$WORK/staging-libs/${ARCH}-mes"
mkdir -p "$TMP_LIBDIR"
for libname in libc-mini libmescc libc libc+tcc; do
  cp "$WORK/obj/${libname}.a" "$TMP_LIBDIR/${libname}.a"
  cp "$WORK/obj/${libname}.s" "$TMP_LIBDIR/${libname}.s"
done
cp "$WORK/obj/crt/crt1.o" "$TMP_LIBDIR/crt1.o"
cp "$WORK/obj/crt/crt1.s" "$TMP_LIBDIR/crt1.s"

"$CC" "${CCARGS[@]}" \
  -L "$MES_PREFIX/lib" \
  -L "$TMP_LIBDIR/.." \
  -lc \
  -lmescc \
  -nostdlib \
  -o "$WORK/mes" \
  "$TMP_LIBDIR/crt1.o" \
  "${MES_OBJS[@]}" \
  > "$WORK/mes-link.log" 2>&1 || {
    rc=$?
    echo "[mes] ERROR: mes link failed (exit $rc); log:" >&2
    tail -40 "$WORK/mes-link.log" >&2
    exit "$rc"
  }
cp "$WORK/mes" "$OUT_ABS/bin/mes"
chmod 0555 "$OUT_ABS/bin/mes"

# Sanity: ensure mes runs.
log "smoke: mes --version"
"$WORK/mes" --version 2>&1 | head -3 || {
  echo "[mes] ERROR: mes --version failed" >&2
  exit 1
}

# Stage 11: emit SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# Phase 5 (mes 0.27.1) output sha256s — built %s\n" "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')"
  for f in bin/mes bin/mes-m2 bin/mescc.scm \
           lib/${ARCH}-mes/libc-mini.a \
           lib/${ARCH}-mes/libmescc.a \
           lib/${ARCH}-mes/libc.a \
           lib/${ARCH}-mes/libc+tcc.a \
           lib/${ARCH}-mes/crt1.o; do
    if [ -f "$f" ]; then
      printf "%-40s %10d  %s\n" "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
    else
      printf "%-40s MISSING\n" "$f"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"
log "done"
