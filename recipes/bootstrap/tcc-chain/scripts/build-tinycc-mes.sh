#!/bin/bash
# build-tinycc-mes.sh -- R5 Phase A: build the modern (cb41cbfe7) tinycc
# from R4's tcc + the tcc-shim, mirroring nixpkgs's `tinycc-mes` derivation.
#
# nixpkgs ref: pkgs/os-specific/linux/minimal-bootstrap/tinycc/mes.nix at
# commit 06a4933d0.  Source: tinycc rev cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341
# (repo.or.cz "unstable-2025-12-03").
#
# This builds the missing link between R4's tinycc-bootstrappable (an old
# fork compatible with mescc) and musl 1.2.6.  The cb41cbfe7 tinycc has
# CONFIG_TCC_PREDEFS=1 + a generated tccdefs_.h, which together inject the
# C99 features (__builtin_va_list, [static N], etc.) that musl 1.2.6 uses.
#
# Two-stage bootstrap per mes.nix:
#   Stage 0: R4 tcc (input) compiles conftest.c -> c2str -> tccdefs_.h
#   Stage 1: R4 tcc compiles tcc.c -> tinycc-mes-boot binary (with PREDEFS)
#            Then re-runs to build libtcc1.a + crt + libc + libgetopt.
#   Stage 2: tinycc-mes-boot compiles tcc.c -> tinycc-mes (with -std=c99)
#            Then re-runs to build libtcc1.a + crt + libc + libgetopt.
#
# Inputs (positional):
#   $1 = vendor dir       (contains tinycc-mes.tar.gz)
#   $2 = R4 tcc-shim dir  (R5 Phase 2 output -- bin/tcc + lib/ + include/)
#   $3 = mes share dir    (build/mes/share/mes-0.27.1/ -- libc.c, crt*.c)
#   $4 = output dir       (will hold bin/tcc + lib/ + SHA256SUMS)
#
# Required env: SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-tinycc-mes.sh <vendor> <tcc-shim> <mes-share> <out>}"
SHIM="${2:?usage: build-tinycc-mes.sh <vendor> <tcc-shim> <mes-share> <out>}"
MES_SHARE="${3:?usage: build-tinycc-mes.sh <vendor> <tcc-shim> <mes-share> <out>}"
OUT="${4:?usage: build-tinycc-mes.sh <vendor> <tcc-shim> <mes-share> <out>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
SHIM_ABS="$(cd "$SHIM" && pwd)"
MES_SHARE_ABS="$(cd "$MES_SHARE" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${MES_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  _depfile="${TCC_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=tinycc-mes \
    --package-version=0.9.27 \
    --toolchain-name=mes \
    --toolchain-version=0.27.1 \
    "${_phase_deps[@]}"
  echo "[cache] tinycc-mes cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] tinycc-mes from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] tinycc-mes: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[tinycc-mes] $*"; }
log "VENDOR=$VENDOR_ABS"
log "SHIM=$SHIM_ABS"
log "MES_SHARE=$MES_SHARE_ABS"
log "OUT=$OUT_ABS"

# Sanity.
for f in "$VENDOR_ABS/tinycc-mes.tar.gz" \
         "$SHIM_ABS/bin/tcc" \
         "$SHIM_ABS/lib/libc.a" \
         "$SHIM_ABS/lib/libtcc1.a" \
         "$SHIM_ABS/lib/crt1.o" \
         "$SHIM_ABS/lib/crti.o" \
         "$SHIM_ABS/lib/crtn.o" \
         "$MES_SHARE_ABS/include/mes/config.h"; do
  [ -e "$f" ] || { echo "[tinycc-mes] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-tinyccmes-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[tinycc-mes] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"

cd "$WORK"

log "Stage 0a: unpack tinycc-mes source"
tar -xzf "$VENDOR_ABS/tinycc-mes.tar.gz"
# nixpkgs uses short SHA prefix tinycc-${first 7 of rev}/.
SRC_DIR="$WORK/tinycc-cb41cbf"
[ -d "$SRC_DIR" ] || { echo "[tinycc-mes] ERROR: expected $SRC_DIR"; ls "$WORK"; exit 1; }

# Sysinclude path: modern-tinycc/include + mes-libc/include (per mes.nix:132).
# We CANNOT reuse the R4 shim include dir directly because it has the OLD
# stdarg.h (which uses runtime __va_start/__va_arg functions provided by
# R4 libtcc1.a), incompatible with modern tinycc's __builtin_va_list-based
# stdarg.h.  Build a fresh sysinclude with modern tinycc headers on top.
SYSINC="$WORK/sysinc"
mkdir -p "$SYSINC"
# First lay down mes-libc headers (the layer the shim takes from
# build/mes/share/mes-0.27.1/include).
cp -r "$MES_SHARE_ABS/include/." "$SYSINC/"
# Then overlay tinycc-mes's own include/ -- compiler-intrinsic headers
# (stddef.h, stdarg.h, stdalign.h, float.h, etc.) win.
cp -r "$SRC_DIR/include/." "$SYSINC/"
log "  built fresh sysinclude at $SYSINC ($(find "$SYSINC" -type f | wc -l) files)"

log "Stage 0b: apply mes.nix patches to tinycc-mes source"
cd "$SRC_DIR"

# Patch 1: static link by default (libtcc.c).
sed -i 's|s->ms_extensions = 1;|s->ms_extensions = 1; s->static_link = 1;|' \
  libtcc.c

# Patch 2: i386-asm.c reg-aware (replace 'switch(size)' with reg>=8 prelude).
# Be careful: only the FIRST `switch(size)` in the file is the target (the
# one in g_register).  We use a one-shot perl-style sed.
python3 - <<'PYEOF' || python - <<'PYEOF'
import sys, re
p = 'i386-asm.c'
with open(p, 'r') as f: src = f.read()
needle = 'switch(size)'
i = src.find(needle)
if i < 0:
    print('PATCH ERROR: i386-asm.c no switch(size)', file=sys.stderr); sys.exit(2)
prelude = ('if (reg >= 8) { cstr_printf(add_str, "%%r%d%c", reg, '
           '(size == 1) ? \'b\' : ((size == 2) ? \'w\' : ((size == 4) ? \'d\' : \' \'))); '
           'return; } ')
src = src[:i] + prelude + src[i:]
with open(p, 'w') as f: f.write(src)
print('PATCH OK: i386-asm.c reg-aware prelude inserted')
PYEOF

# Patch 3: tccgen.c ptrdiff_t cast for ptr + negative-int.
python3 - <<'PYEOF' || python - <<'PYEOF'
import sys
p = 'tccgen.c'
with open(p, 'r') as f: src = f.read()
needle = 'vpush_type_size(pointed_type(&vtop[-1].type), &align);'
i = src.find(needle)
if i < 0:
    print('PATCH ERROR: tccgen.c no vpush_type_size', file=sys.stderr); sys.exit(2)
addition = ' if (!(vtop[-1].type.t & VT_UNSIGNED)) gen_cast_s(VT_PTRDIFF_T);'
# Insert after the needle.
src = src[:i+len(needle)] + addition + src[i+len(needle):]
with open(p, 'w') as f: f.write(src)
print('PATCH OK: tccgen.c ptrdiff_t cast inserted')
PYEOF

log "Stage 0c: generate tccdefs_.h (CONFIG_TCC_PREDEFS=1 input)"
# Build c2str from conftest.c using R4 tcc + shim.
"$SHIM_ABS/bin/tcc" \
  -B "$SHIM_ABS/lib" \
  -I "$SHIM_ABS/include" \
  -DC2STR \
  -o "$WORK/c2str" \
  "$SRC_DIR/conftest.c"

# Run c2str over include/tccdefs.h to get tccdefs_.h.
"$WORK/c2str" "$SRC_DIR/include/tccdefs.h" "$WORK/tccdefs_unmerged.h"

# Append the mes config.h include line (per mes.nix `config_h`).
{
  cat "$WORK/tccdefs_unmerged.h"
  printf '"#include <mes/config.h>\\n"\n'
} > "$WORK/tccdefs_.h"
log "  tccdefs_.h is $(wc -l < "$WORK/tccdefs_.h") lines"

# The build needs tccdefs_.h on the -I search path.  Put it in $WORK/tccdefs/.
mkdir -p "$WORK/tccdefs"
cp "$WORK/tccdefs_.h" "$WORK/tccdefs/tccdefs_.h"

# ---------------------------------------------------------------------------
# Stage 1: build tinycc-mes-boot using R4 tcc.
# ---------------------------------------------------------------------------
log "Stage 1a: build tinycc-mes-boot compiler (R4 tcc -> tcc.c)"
BOOT_DIR="$WORK/boot"
mkdir -p "$BOOT_DIR/bin" "$BOOT_DIR/lib"
cd "$SRC_DIR"
# Per common.nix: catm config.h (just an empty config.h since CONFIG_H is
# defined by -D's).
> config.h

# Build command per mes.nix tinycc-mes-boot buildOptions:
"$SHIM_ABS/bin/tcc" \
  -B "$SHIM_ABS/lib" \
  -I "$SHIM_ABS/include" \
  -g \
  -o "$BOOT_DIR/bin/tcc" \
  -D BOOTSTRAP=1 \
  -D HAVE_BITFIELD=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D HAVE_SETJMP=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -I . \
  -I "$SRC_DIR" \
  -D TCC_TARGET_X86_64=1 \
  '-DCONFIG_TCCDIR=""' \
  '-DCONFIG_SYSROOT=""' \
  '-DCONFIG_TCC_CRTPREFIX="{B}"' \
  '-DCONFIG_TCC_ELFINTERP=""' \
  '-DCONFIG_TCC_LIBPATHS="{B}"' \
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$SYSINC\"" \
  '-DTCC_LIBGCC="libc.a"' \
  '-DTCC_LIBTCC1="libtcc1.a"' \
  -D CONFIG_TCCBOOT=1 \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  -D TCC_MES_LIBC=1 \
  '-DTCC_VERSION="0.9.28-unstable-2025-12-03"' \
  -D ONE_SOURCE=1 \
  "$SRC_DIR/tcc.c" \
  2>&1 | tee "$WORK/stage1-compile.log" | tail -20

if [ ! -x "$BOOT_DIR/bin/tcc" ]; then
  echo "[tinycc-mes] ERROR: Stage 1 tcc binary not produced" >&2
  tail -50 "$WORK/stage1-compile.log" >&2
  exit 1
fi
log "  Stage 1 tcc: $(stat -c %s "$BOOT_DIR/bin/tcc") bytes"

# Stage 1b: rebuild libs (crt, libc, libgetopt, libtcc1) using Stage 1 tcc.
log "Stage 1b: build Stage 1 libs (crt, libc, libgetopt, libtcc1)"
# mes-libc CFLAGS for compiling its libc.c.
# Per nixpkgs pkgs/os-specific/linux/minimal-bootstrap/mes/libc.nix:39
# (passthru.CFLAGS = "-std=c11").  We add -I $SYSINC because Stage 1 tcc
# needs to find the modern stdarg.h + mes-libc headers AND tccdefs's
# `#include <mes/config.h>` predef.
MES_LIBC_CFLAGS="-std=c11 -I $SYSINC"

# Where do the mes-libc sources live?  Our shim doesn't directly expose
# the mes-libc lib/ sources, only the compiled .a files + headers.  The R4
# build staged them under build/mes/share/mes-0.27.1/lib/{libc.c, crt1.c,
# crtn.c, crti.c, libgetopt.c} — these are the synthetic concatenations
# from the R4 build.
# But R4 used a synthesised mes-libc directory under WORK.  We need to
# either re-synthesise it or use the persistent staged copy.  Check whether
# the shim has _mes-libc/ staged.

# Synthesise mes-libc (libc.c + crt{1,n,i}.c + libgetopt.c) from the
# canonical source files.  Required because Stage 1 tcc (modern) cannot
# link against R4-shim libc.a, which references `__va_start`/`__va_arg`
# runtime functions that don't exist in modern tcc's __builtin_va_list
# machinery.  We MUST rebuild libc.a per stage so it uses the matching
# va_list convention.
MES_LIBC_LIB="$WORK/mes-libc-syn/lib"
mkdir -p "$MES_LIBC_LIB"
log "  synthesising mes-libc (libc.c + crt + libgetopt) at $MES_LIBC_LIB"
bash "$(dirname "$0")/_synth-mes-libc.sh" "$MES_SHARE_ABS" "$MES_LIBC_LIB"
log "  libc.c: $(wc -l < "$MES_LIBC_LIB/libc.c") lines"

log "  Stage 1 crt1.o"
"$BOOT_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$BOOT_DIR/lib/crt1.o" "$MES_LIBC_LIB/crt1.c"
log "  Stage 1 crtn.o"
"$BOOT_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$BOOT_DIR/lib/crtn.o" "$MES_LIBC_LIB/crtn.c"
log "  Stage 1 crti.o"
"$BOOT_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$BOOT_DIR/lib/crti.o" "$MES_LIBC_LIB/crti.c"

# libtcc1.a: per mes.nix, libtccSources = [libtcc1.c, alloca.S].
log "  Stage 1 libtcc1.o + alloca.o"
"$BOOT_DIR/bin/tcc" \
  -c \
  -D TCC_TARGET_X86_64=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -I "$SYSINC" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -o "$BOOT_DIR/lib/libtcc1.o" \
  "$SRC_DIR/lib/libtcc1.c"
"$BOOT_DIR/bin/tcc" \
  -c \
  -D TCC_TARGET_X86_64=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -I "$SYSINC" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -o "$BOOT_DIR/lib/alloca.o" \
  "$SRC_DIR/lib/alloca.S"
"$BOOT_DIR/bin/tcc" -ar cr "$BOOT_DIR/lib/libtcc1.a" \
  "$BOOT_DIR/lib/libtcc1.o" "$BOOT_DIR/lib/alloca.o"

# libc.a — rebuilt by Stage 1 tcc so va_list machinery matches.
log "  Stage 1 libc.a"
"$BOOT_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$BOOT_DIR/lib/libc.o" \
  "$MES_LIBC_LIB/libc.c"
"$BOOT_DIR/bin/tcc" -ar cr "$BOOT_DIR/lib/libc.a" "$BOOT_DIR/lib/libc.o"

# libgetopt.a — same.
log "  Stage 1 libgetopt.a"
"$BOOT_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$BOOT_DIR/lib/libgetopt.o" \
  "$MES_LIBC_LIB/libgetopt.c"
"$BOOT_DIR/bin/tcc" -ar cr "$BOOT_DIR/lib/libgetopt.a" "$BOOT_DIR/lib/libgetopt.o"

log "Stage 1 OK; tinycc-mes-boot binary + libs ready at $BOOT_DIR"

# Smoke-test Stage 1: does it compile a hello.c with stdio + C99 features?
SMOKE_STAGE1="$WORK/smoke-stage1"
mkdir -p "$SMOKE_STAGE1"
cat > "$SMOKE_STAGE1/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) {
  puts("hello-stage1");
  return 23;
}
CEOF
if "$BOOT_DIR/bin/tcc" -B "$BOOT_DIR/lib" -I "$SYSINC" \
     -o "$SMOKE_STAGE1/hello" "$SMOKE_STAGE1/hello.c" 2>&1 | head -5; then
  if [ -x "$SMOKE_STAGE1/hello" ]; then
    rc=0; "$SMOKE_STAGE1/hello" || rc=$?
    log "  Stage 1 smoke (hello -> exit 23): exit=$rc"
  fi
else
  log "  Stage 1 smoke: compile failed (acceptable for stage 1)"
fi

# ---------------------------------------------------------------------------
# Stage 2: build tinycc-mes (-std=c99) using tinycc-mes-boot.
# ---------------------------------------------------------------------------
log "Stage 2a: build tinycc-mes compiler (Stage 1 tcc -> tcc.c -std=c99)"
STAGE2_DIR="$WORK/stage2"
mkdir -p "$STAGE2_DIR/bin" "$STAGE2_DIR/lib"
cd "$SRC_DIR"

"$BOOT_DIR/bin/tcc" \
  -B "$BOOT_DIR/lib" \
  -nostdinc \
  -I "$SYSINC" \
  -g \
  -o "$STAGE2_DIR/bin/tcc" \
  -D BOOTSTRAP=1 \
  -std=c99 \
  -D HAVE_BITFIELD=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D HAVE_SETJMP=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -I . \
  -I "$SRC_DIR" \
  -D TCC_TARGET_X86_64=1 \
  '-DCONFIG_TCCDIR=""' \
  '-DCONFIG_SYSROOT=""' \
  '-DCONFIG_TCC_CRTPREFIX="{B}"' \
  '-DCONFIG_TCC_ELFINTERP=""' \
  '-DCONFIG_TCC_LIBPATHS="{B}"' \
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$SYSINC\"" \
  '-DTCC_LIBGCC="libc.a"' \
  '-DTCC_LIBTCC1="libtcc1.a"' \
  -D CONFIG_TCCBOOT=1 \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  -D TCC_MES_LIBC=1 \
  '-DTCC_VERSION="0.9.28-unstable-2025-12-03"' \
  -D ONE_SOURCE=1 \
  "$SRC_DIR/tcc.c" \
  2>&1 | tee "$WORK/stage2-compile.log" | tail -20

if [ ! -x "$STAGE2_DIR/bin/tcc" ]; then
  echo "[tinycc-mes] ERROR: Stage 2 tcc binary not produced" >&2
  tail -80 "$WORK/stage2-compile.log" >&2
  exit 1
fi
log "  Stage 2 tcc: $(stat -c %s "$STAGE2_DIR/bin/tcc") bytes"

# Stage 2b: rebuild libs with Stage 2 tcc.
log "Stage 2b: build Stage 2 libs"
"$STAGE2_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$STAGE2_DIR/lib/crt1.o" "$MES_LIBC_LIB/crt1.c"
"$STAGE2_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$STAGE2_DIR/lib/crtn.o" "$MES_LIBC_LIB/crtn.c"
"$STAGE2_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$STAGE2_DIR/lib/crti.o" "$MES_LIBC_LIB/crti.c"

"$STAGE2_DIR/bin/tcc" \
  -c \
  -D TCC_TARGET_X86_64=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -I "$SYSINC" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -o "$STAGE2_DIR/lib/libtcc1.o" \
  "$SRC_DIR/lib/libtcc1.c"
"$STAGE2_DIR/bin/tcc" \
  -c \
  -D TCC_TARGET_X86_64=1 \
  -D HAVE_FLOAT=1 \
  -D HAVE_LONG_LONG=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -I "$WORK/tccdefs" \
  -I "$SYSINC" \
  -D CONFIG_TCC_SEMLOCK=0 \
  -o "$STAGE2_DIR/lib/alloca.o" \
  "$SRC_DIR/lib/alloca.S"
"$STAGE2_DIR/bin/tcc" -ar cr "$STAGE2_DIR/lib/libtcc1.a" \
  "$STAGE2_DIR/lib/libtcc1.o" "$STAGE2_DIR/lib/alloca.o"

# Stage 2 libc.a + libgetopt.a — same rebuild as Stage 1 but with Stage 2 tcc.
log "  Stage 2 libc.a"
"$STAGE2_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$STAGE2_DIR/lib/libc.o" \
  "$MES_LIBC_LIB/libc.c"
"$STAGE2_DIR/bin/tcc" -ar cr "$STAGE2_DIR/lib/libc.a" "$STAGE2_DIR/lib/libc.o"
log "  Stage 2 libgetopt.a"
"$STAGE2_DIR/bin/tcc" $MES_LIBC_CFLAGS -c -o "$STAGE2_DIR/lib/libgetopt.o" \
  "$MES_LIBC_LIB/libgetopt.c"
"$STAGE2_DIR/bin/tcc" -ar cr "$STAGE2_DIR/lib/libgetopt.a" "$STAGE2_DIR/lib/libgetopt.o"

# ---------------------------------------------------------------------------
# Acceptance smoke test: does the Stage 2 binary really accept C99 features?
# ---------------------------------------------------------------------------
log "Stage 2c: acceptance smoke tests"
SMOKE="$WORK/smoke-stage2"
mkdir -p "$SMOKE"

# Test A: __builtin_va_list (C99 stdarg).
cat > "$SMOKE/test_va.c" <<'CEOF'
#include <stdio.h>
#include <stdarg.h>
static int sum_n(int n, ...) {
  va_list ap;
  va_start(ap, n);
  int total = 0;
  for (int i = 0; i < n; i++) total += va_arg(ap, int);
  va_end(ap);
  return total;
}
int main(void) {
  return sum_n(3, 10, 20, 19);  /* 49 */
}
CEOF
if "$STAGE2_DIR/bin/tcc" -B "$STAGE2_DIR/lib" -nostdinc -I "$SYSINC" \
     -o "$SMOKE/test_va" "$SMOKE/test_va.c" 2>&1 | head -5; then
  rc=0; "$SMOKE/test_va" || rc=$?
  log "  test A va_list: exit=$rc (expected 49)"
  if [ "$rc" -ne 49 ]; then
    echo "[tinycc-mes] ERROR: va_list smoke failed: exit=$rc" >&2
    exit 1
  fi
else
  echo "[tinycc-mes] ERROR: va_list smoke compile failed" >&2
  exit 1
fi

# Test B: C99 `[static N]` array parameter syntax (the syscall.h trigger).
cat > "$SMOKE/test_static_arr.c" <<'CEOF'
#include <stdio.h>
static int sum_arr(int n, const int arr[static 4]) {
  int total = 0;
  for (int i = 0; i < n && i < 4; i++) total += arr[i];
  return total;
}
int main(void) {
  int a[4] = {1, 2, 3, 7};  /* 13 */
  return sum_arr(4, a);
}
CEOF
# Note: this is the key test — R4 tcc rejects this syntax; tinycc-mes
# accepts it.  We try it but failing this means we missed the modern
# tinycc features.
if "$STAGE2_DIR/bin/tcc" -B "$STAGE2_DIR/lib" -nostdinc -I "$SYSINC" \
     -o "$SMOKE/test_static_arr" "$SMOKE/test_static_arr.c" 2>&1 | head -5; then
  rc=0; "$SMOKE/test_static_arr" || rc=$?
  log "  test B [static N]: exit=$rc (expected 13)"
  if [ "$rc" -ne 13 ]; then
    echo "[tinycc-mes] ERROR: [static N] smoke failed: exit=$rc" >&2
    exit 1
  fi
else
  echo "[tinycc-mes] ERROR: [static N] smoke compile failed" >&2
  exit 1
fi

# Test C: hello world stays alive.
cat > "$SMOKE/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) {
  puts("hello-tinycc-mes");
  return 29;
}
CEOF
"$STAGE2_DIR/bin/tcc" -B "$STAGE2_DIR/lib" -nostdinc -I "$SYSINC" \
  -o "$SMOKE/hello" "$SMOKE/hello.c"
rc=0; "$SMOKE/hello" || rc=$?
log "  test C hello: exit=$rc (expected 29)"
if [ "$rc" -ne 29 ]; then
  echo "[tinycc-mes] ERROR: hello smoke failed" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Install: copy Stage 2 outputs to $OUT.
# ---------------------------------------------------------------------------
log "Install: copying Stage 2 outputs to $OUT_ABS"
rm -rf "$OUT_ABS"
mkdir -p "$OUT_ABS/bin" "$OUT_ABS/lib" "$OUT_ABS/include"
cp "$STAGE2_DIR/bin/tcc" "$OUT_ABS/bin/tcc"
chmod 0755 "$OUT_ABS/bin/tcc"
for f in crt1.o crti.o crtn.o libtcc1.a libc.a libgetopt.a; do
  cp "$STAGE2_DIR/lib/$f" "$OUT_ABS/lib/$f"
done
# Copy the tinycc include/ (gives stddef.h, stdarg.h, stdalign.h etc) +
# the mes-libc headers from the shim.
cp -r "$SRC_DIR/include/." "$OUT_ABS/include/"
# Overlay the shim's libc headers (stdio.h, string.h, sys/*, etc.) but
# preserve tinycc's compiler-intrinsic headers.
INTRINSICS=(stddef.h stdarg.h stdalign.h stdatomic.h stdbool.h
            stdnoreturn.h tgmath.h tccdefs.h float.h varargs.h)
mkdir -p "$WORK/saved-intrinsics"
for h in "${INTRINSICS[@]}"; do
  [ -e "$OUT_ABS/include/$h" ] && cp "$OUT_ABS/include/$h" "$WORK/saved-intrinsics/$h"
done
cp -r "$SHIM_ABS/include/." "$OUT_ABS/include/"
for h in "${INTRINSICS[@]}"; do
  [ -e "$WORK/saved-intrinsics/$h" ] && cp "$WORK/saved-intrinsics/$h" "$OUT_ABS/include/$h"
done

# Wrapper: stable -I/-B injection.
mkdir -p "$OUT_ABS/wrapper"
cat > "$OUT_ABS/wrapper/tcc" <<WEOF
#!/bin/bash
# tinycc-mes wrapper: stable -I/-B injection for downstream builds.
exec "$OUT_ABS/bin/tcc" -B "$OUT_ABS/lib" -nostdinc -I "$OUT_ABS/include" "\$@"
WEOF
chmod +x "$OUT_ABS/wrapper/tcc"

# ---------------------------------------------------------------------------
# Embedded-path check (per project guidelines).
# ---------------------------------------------------------------------------
log "Embedded-path check"
LEAK=$(strings "$OUT_ABS/bin/tcc" | grep -E '/tmp/|/home/' || true)
if [ -n "$LEAK" ]; then
  log "  WARNING: embedded build paths in tcc binary:"
  echo "$LEAK" | head -5 | while IFS= read -r ln; do log "    $ln"; done
  log "  (these are the WORK paths the binary was built in; downstream"
  log "  consumers should use -B/-I overrides, not rely on baked paths)"
fi

# ---------------------------------------------------------------------------
# SHA256SUMS.
# ---------------------------------------------------------------------------
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase A (tinycc-mes 0.9.28-unstable-2025-12-03 / cb41cbf) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s LC_ALL=%s TZ=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH" "$LC_ALL" "$TZ"
  for f in bin/tcc \
           lib/crt1.o lib/crti.o lib/crtn.o \
           lib/libc.a lib/libgetopt.a lib/libtcc1.a; do
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "tinycc-mes ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
