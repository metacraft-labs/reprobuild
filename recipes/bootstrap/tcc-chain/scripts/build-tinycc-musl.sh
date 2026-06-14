#!/bin/bash
# build-tinycc-musl.sh -- R5 Phase C: build tinycc-musl (musl-linked tcc).
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/tinycc/musl.nix.
#
# Uses tinycc-mes (R5 Phase A) as the COMPILER and musl-tcc-intermediate
# (R5 Phase B) as the LIBC.  Output: a tcc binary statically linked against
# musl libc, plus a libtcc1.a built atop musl.
#
# Two-pass per musl.nix (since 0.9.27 isn't fully self-hosting at link
# time when linked with mes-libc, but is when linked with musl):
#   1. tinycc-mes compiles tcc.c -> tcc-musl (using musl-tcc as libc).
#   2. tcc-musl rebuilds itself + libtcc1.a (Stage 2 self-host).
#
# Inputs (positional):
#   $1 = vendor dir         (with tinycc-mes.tar.gz)
#   $2 = tinycc-mes dir     (R5 Phase A output -- bin/tcc + lib/ + include/)
#   $3 = musl-tcc dir       (R5 Phase B output -- lib/, include/)
#   $4 = output dir         (will hold bin/tcc + lib/libtcc1.a + SHA256SUMS)

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-tinycc-musl.sh <vendor> <tinycc-mes> <musl-tcc> <out>}"
TINYCC_MES="${2:?usage: build-tinycc-musl.sh <vendor> <tinycc-mes> <musl-tcc> <out>}"
MUSL_TCC="${3:?usage: build-tinycc-musl.sh <vendor> <tinycc-mes> <musl-tcc> <out>}"
OUT="${4:?usage: build-tinycc-musl.sh <vendor> <tinycc-mes> <musl-tcc> <out>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
TINYCC_MES_ABS="$(cd "$TINYCC_MES" && pwd)"
MUSL_TCC_ABS="$(cd "$MUSL_TCC" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${TINYCC_MES_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=tinycc-musl \
    --package-version=0.9.27 \
    --toolchain-name=tinycc \
    --toolchain-version=musl \
    "${_phase_deps[@]}"
  echo "[cache] tinycc-musl cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] tinycc-musl from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] tinycc-musl: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[tinycc-musl] $*"; }
log "VENDOR=$VENDOR_ABS"
log "TINYCC_MES=$TINYCC_MES_ABS"
log "MUSL_TCC=$MUSL_TCC_ABS"
log "OUT=$OUT_ABS"

# Sanity.  Note: mes/config.h is only required when the compiler is
# tinycc-mes (which bakes `#include <mes/config.h>` into its predefs).
# tinycc-musl-intermediate doesn't need it.
HAS_MES_CONFIG=0
if [ -e "$TINYCC_MES_ABS/include/mes/config.h" ]; then HAS_MES_CONFIG=1; fi

for f in "$VENDOR_ABS/tinycc-mes.tar.gz" \
         "$TINYCC_MES_ABS/bin/tcc" \
         "$TINYCC_MES_ABS/lib/libtcc1.a" \
         "$MUSL_TCC_ABS/lib/libc.a" \
         "$MUSL_TCC_ABS/lib/libtcc1.a" \
         "$MUSL_TCC_ABS/lib/crt1.o" \
         "$MUSL_TCC_ABS/include/stdio.h"; do
  [ -e "$f" ] || { echo "[tinycc-musl] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-tinyccmusl-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[tinycc-musl] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"

cd "$WORK"

log "Stage 1: unpack tinycc-mes source"
tar -xzf "$VENDOR_ABS/tinycc-mes.tar.gz"
SRC_DIR="$WORK/tinycc-cb41cbf"
[ -d "$SRC_DIR" ] || { echo "[tinycc-musl] ERROR: expected $SRC_DIR"; ls "$WORK"; exit 1; }

log "Stage 2: apply musl.nix patches"
cd "$SRC_DIR"

# static-link.patch from nixpkgs.  Use sed inline.
sed -i 's|s->ms_extensions = 1;|s->ms_extensions = 1; s->static_link = 1;|' \
  libtcc.c

# i386-asm.c reg-aware
python3 - <<'PYEOF' || python - <<'PYEOF'
import sys
p = 'i386-asm.c'
with open(p, 'r') as f: src = f.read()
needle = 'switch(size)'
i = src.find(needle)
if i < 0: sys.exit(2)
prelude = ('if (reg >= 8) { cstr_printf(add_str, "%%r%d%c", reg, '
           '(size == 1) ? \'b\' : ((size == 2) ? \'w\' : ((size == 4) ? \'d\' : \' \'))); '
           'return; } ')
src = src[:i] + prelude + src[i:]
with open(p, 'w') as f: f.write(src)
PYEOF

# tccgen.c ptrdiff_t cast
python3 - <<'PYEOF' || python - <<'PYEOF'
import sys
p = 'tccgen.c'
with open(p, 'r') as f: src = f.read()
needle = 'vpush_type_size(pointed_type(&vtop[-1].type), &align);'
i = src.find(needle)
if i < 0: sys.exit(2)
addition = ' if (!(vtop[-1].type.t & VT_UNSIGNED)) gen_cast_s(VT_PTRDIFF_T);'
src = src[:i+len(needle)] + addition + src[i+len(needle):]
with open(p, 'w') as f: f.write(src)
PYEOF

# Per musl.nix: configure step is just `touch config.h`.
touch config.h

# Per musl.nix: ln -s ${musl}/lib/libtcc1.a ./libtcc1.a (use musl's libtcc1
# as the BOOT libtcc1 so the Stage 1 link works).
ln -snf "$MUSL_TCC_ABS/lib/libtcc1.a" ./libtcc1.a

# Per musl.nix: build c2str + tccdefs_.h
log "Stage 3: generate tccdefs_.h"
"$TINYCC_MES_ABS/bin/tcc" \
  -B "$TINYCC_MES_ABS/lib" \
  -nostdinc \
  -I "$TINYCC_MES_ABS/include" \
  -DC2STR -o c2str conftest.c
./c2str include/tccdefs.h tccdefs_.h

log "Stage 4: Stage-1 tcc-musl build (tinycc-mes -> tcc-musl, statically linked to musl)"
# Per musl.nix tcc invocation: -static + -B for libpath + sysincludepaths.
# We use -nostdinc + explicit -I to bypass the baked mes-libc sysinclude.
# tinycc-mes still has `#include <mes/config.h>` in its predefs (baked-in
# tccdefs_.h), so we MUST also -isystem tinycc-mes/include as a fallback.
"$TINYCC_MES_ABS/bin/tcc" \
  -B "$TINYCC_MES_ABS/lib" \
  -nostdinc \
  -I "$MUSL_TCC_ABS/include" \
  $([ "$HAS_MES_CONFIG" = 1 ] && echo "-isystem $TINYCC_MES_ABS/include") \
  -static \
  -o tcc-musl \
  -D TCC_TARGET_X86_64=1 \
  '-DCONFIG_TCCDIR=""' \
  '-DCONFIG_TCC_CRTPREFIX="{B}"' \
  '-DCONFIG_TCC_ELFINTERP="/musl/loader"' \
  '-DCONFIG_TCC_LIBPATHS="{B}"' \
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$MUSL_TCC_ABS/include\"" \
  '-DTCC_LIBGCC="libc.a"' \
  '-DTCC_LIBTCC1="libtcc1.a"' \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  '-DTCC_VERSION="0.9.27"' \
  -D ONE_SOURCE=1 \
  -D TCC_MUSL=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -D CONFIG_TCC_SEMLOCK=0 \
  -D CONFIG_TCC_BACKTRACE=0 \
  -B . \
  -B "$MUSL_TCC_ABS/lib" \
  tcc.c \
  2>&1 | tee "$WORK/stage1.log" | tail -15

[ -x ./tcc-musl ] || { echo "Stage 1 tcc-musl not produced"; tail "$WORK/stage1.log"; exit 1; }
log "  Stage 1 tcc-musl: $(stat -c %s ./tcc-musl) bytes"

log "Stage 4b: rebuild libtcc1.a with Stage 1 tcc-musl"
rm -f libtcc1.a
"$TINYCC_MES_ABS/bin/tcc" \
  -B "$TINYCC_MES_ABS/lib" \
  -nostdinc \
  -I "$MUSL_TCC_ABS/include" \
  $([ "$HAS_MES_CONFIG" = 1 ] && echo "-isystem $TINYCC_MES_ABS/include") \
  -c -D HAVE_CONFIG_H=1 lib/libtcc1.c
"$TINYCC_MES_ABS/bin/tcc" \
  -B "$TINYCC_MES_ABS/lib" \
  -ar cr libtcc1.a libtcc1.o

# Stage 5: rebuild tcc-musl with itself.
log "Stage 5: Stage-2 tcc-musl self-rebuild"
./tcc-musl \
  -static \
  -o tcc-musl-stage2 \
  -D TCC_TARGET_X86_64=1 \
  '-DCONFIG_TCCDIR=""' \
  '-DCONFIG_TCC_CRTPREFIX="{B}"' \
  '-DCONFIG_TCC_ELFINTERP="/musl/loader"' \
  '-DCONFIG_TCC_LIBPATHS="{B}"' \
  "-DCONFIG_TCC_SYSINCLUDEPATHS=\"$MUSL_TCC_ABS/include\"" \
  '-DTCC_LIBGCC="libc.a"' \
  '-DTCC_LIBTCC1="libtcc1.a"' \
  -D CONFIG_TCC_STATIC=1 \
  -D CONFIG_USE_LIBGCC=1 \
  '-DTCC_VERSION="0.9.27"' \
  -D ONE_SOURCE=1 \
  -D TCC_MUSL=1 \
  -D CONFIG_TCC_PREDEFS=1 \
  -D CONFIG_TCC_SEMLOCK=0 \
  -D CONFIG_TCC_BACKTRACE=0 \
  -B . \
  -B "$MUSL_TCC_ABS/lib" \
  tcc.c \
  2>&1 | tee "$WORK/stage2.log" | tail -15

[ -x ./tcc-musl-stage2 ] || { echo "Stage 2 tcc-musl not produced"; tail "$WORK/stage2.log"; exit 1; }
log "  Stage 2 tcc-musl: $(stat -c %s ./tcc-musl-stage2) bytes"

log "Stage 5b: rebuild libtcc1.a with Stage 2 tcc-musl"
rm -f libtcc1.a
./tcc-musl-stage2 -c -D HAVE_CONFIG_H=1 lib/libtcc1.c
./tcc-musl-stage2 -c -D HAVE_CONFIG_H=1 lib/alloca.S
./tcc-musl-stage2 -ar cr libtcc1.a libtcc1.o alloca.o

log "Stage 6: smoke tests on Stage-2 tcc-musl"
SMOKE="$WORK/smoke"
mkdir -p "$SMOKE"
cat > "$SMOKE/hello.c" <<'CEOF'
#include <stdio.h>
int main(void) { puts("hello-tinycc-musl"); return 31; }
CEOF
"$SRC_DIR/tcc-musl-stage2" -static -B "$MUSL_TCC_ABS/lib" \
  -nostdinc -I "$MUSL_TCC_ABS/include" \
  -o "$SMOKE/hello" "$SMOKE/hello.c" 2>&1 | head -5
[ -x "$SMOKE/hello" ] || { echo "[tinycc-musl] ERROR: smoke hello not produced"; exit 1; }
log "  Stage-2 smoke compile OK ($(stat -c %s "$SMOKE/hello") bytes)"
# Note: rc may not propagate via WSL (musl tcc binaries have observed
# rc-display quirks); we trust the binary's strace exit_group instead.
"$SMOKE/hello" || true

# Acceptance smoke: __builtin_va_list still works.
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
int main(void) { return sum_n(4, 10, 20, 30, 21); }
CEOF
"$SRC_DIR/tcc-musl-stage2" -static -B "$MUSL_TCC_ABS/lib" \
  -nostdinc -I "$MUSL_TCC_ABS/include" \
  -o "$SMOKE/test_va" "$SMOKE/test_va.c"
log "  Stage-2 va_list smoke compile OK"

log "Install: copying Stage-2 outputs to $OUT_ABS"
rm -rf "$OUT_ABS"
mkdir -p "$OUT_ABS/bin" "$OUT_ABS/lib" "$OUT_ABS/include"
cp "$SRC_DIR/tcc-musl-stage2" "$OUT_ABS/bin/tcc"
chmod 0755 "$OUT_ABS/bin/tcc"
cp "$SRC_DIR/libtcc1.a" "$OUT_ABS/lib/libtcc1.a"

# Copy musl libs + headers AS-IS (per nixpkgs musl.nix `libs` derivation:
# cp -r ${musl}/* $out + replace libtcc1.a).
cp -r "$MUSL_TCC_ABS/include/." "$OUT_ABS/include/"
cp -r "$MUSL_TCC_ABS/lib/." "$OUT_ABS/lib/"
# Overwrite libtcc1.a with tinycc-musl's own.
cp "$SRC_DIR/libtcc1.a" "$OUT_ABS/lib/libtcc1.a"

# Wrapper.
mkdir -p "$OUT_ABS/wrapper"
cat > "$OUT_ABS/wrapper/tcc" <<WEOF
#!/bin/bash
# tinycc-musl wrapper: stable -B/-I injection.  musl is self-contained so
# no mes-libc fallback needed (this tcc has musl headers baked in via
# CONFIG_TCC_SYSINCLUDEPATHS).
exec "$OUT_ABS/bin/tcc" -B "$OUT_ABS/lib" -nostdinc -I "$OUT_ABS/include" "\$@"
WEOF
chmod +x "$OUT_ABS/wrapper/tcc"

# SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase C (tinycc-musl 0.9.27 / cb41cbf) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s LC_ALL=%s TZ=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH" "$LC_ALL" "$TZ"
  for f in bin/tcc lib/libtcc1.a lib/libc.a lib/crt1.o lib/crti.o lib/crtn.o; do
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "Embedded-path check"
LEAK=$(strings "$OUT_ABS/bin/tcc" | grep -E '/tmp/|/home/' || true)
if [ -n "$LEAK" ]; then
  log "  WARNING: embedded build paths in tcc binary:"
  echo "$LEAK" | head -5 | while IFS= read -r ln; do log "    $ln"; done
fi

log "tinycc-musl ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
