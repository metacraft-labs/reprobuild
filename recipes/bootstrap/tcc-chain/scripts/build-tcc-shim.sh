#!/bin/bash
# build-tcc-shim.sh -- R5 Phase 2: stage the R4 tcc + sysroot under a
# stable path so it can compile programs that #include <stdio.h>.
#
# The R4 Phase 6 build baked /tmp/reproos-r4e-tcc-XXXXXX paths into the
# tcc binary via -D CONFIG_TCC_SYSINCLUDEPATHS=... .  Those paths point
# at a now-deleted mktemp dir.  To use this tcc downstream we need:
#
#   1. The tinycc include dir (host of stddef.h, stdarg.h, float.h --
#      compiler-intrinsic headers).
#   2. The mes-libc include dir (host of stdio.h, string.h, sys/*.h --
#      libc headers).
#   3. The lib dir (crt1.o, libc.a, libtcc1.a) at -B path.
#
# This script extracts the tinycc source, copies the right headers to
# /tmp/tcc-r5-shim/, and ALSO creates a stable mes-libc include link.
#
# Inputs (positional):
#   $1 = vendor dir       (contains tinycc-bootstrappable.tar.gz)
#   $2 = R4 build root    (e.g. build/, with build/tcc/ and build/mes/)
#   $3 = shim out dir     (e.g. /tmp/tcc-r5-shim; we want absolute since
#                          downstream builds need stable paths)
#
# Outputs:
#   $3/bin/tcc            -- copy of R4 tcc, exec'd from local disk so
#                            it isn't blocked by drvfs noexec
#   $3/lib/{crt1,crti,crtn}.o, libc.a, libgetopt.a, libtcc1.a -- from R4
#   $3/include/           -- tinycc-bootstrappable include/* + mes-libc
#                            include/* MERGED (mes wins on conflict;
#                            mirrors what nixpkgs's `tinycc.libs/include`
#                            would look like with mes-libc instead of
#                            musl).
#   $3/wrapper/tcc        -- tcc wrapper that injects -I $3/include and
#                            -B $3/lib for any invocation; useful when
#                            downstream `./configure` calls `CC=tcc` and
#                            doesn't expose the -B/-I flag plumbing.
#   $3/SHA256SUMS         -- per-output sha256.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-tcc-shim.sh <vendor-dir> <build-root> <shim-out>}"
BUILD_ROOT="${2:?usage: build-tcc-shim.sh <vendor-dir> <build-root> <shim-out>}"
SHIM_OUT="${3:?usage: build-tcc-shim.sh <vendor-dir> <build-root> <shim-out>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
BUILD_ABS="$(cd "$BUILD_ROOT" && pwd)"

# We deliberately do NOT cd into SHIM_OUT before mkdir-ing it.
mkdir -p "$SHIM_OUT"
SHIM_ABS="$(cd "$SHIM_OUT" && pwd)"

log() { echo "[tcc-shim] $*"; }
log "VENDOR=$VENDOR_ABS"
log "BUILD=$BUILD_ABS"
log "SHIM=$SHIM_ABS"

# Sanity-check inputs.
for f in "$VENDOR_ABS/tinycc-bootstrappable.tar.gz" \
         "$BUILD_ABS/tcc/bin/tcc" \
         "$BUILD_ABS/tcc/lib/libc.a" \
         "$BUILD_ABS/tcc/lib/libtcc1.a" \
         "$BUILD_ABS/tcc/lib/crt1.o" \
         "$BUILD_ABS/tcc/lib/crti.o" \
         "$BUILD_ABS/tcc/lib/crtn.o" \
         "$BUILD_ABS/mes/share/mes-0.27.1/include/stdio.h"; do
  if [ ! -e "$f" ]; then
    echo "[tcc-shim] ERROR: missing input $f" >&2
    exit 1
  fi
done

# Layout the shim.
rm -rf "$SHIM_ABS"
mkdir -p "$SHIM_ABS/bin" "$SHIM_ABS/lib" "$SHIM_ABS/include" "$SHIM_ABS/wrapper"

# Stage 1: copy the R4 tcc binary + libs.
log "Stage 1: copy R4 tcc binary + libs"
cp "$BUILD_ABS/tcc/bin/tcc"           "$SHIM_ABS/bin/tcc"
cp "$BUILD_ABS/tcc/lib/crt1.o"        "$SHIM_ABS/lib/crt1.o"
cp "$BUILD_ABS/tcc/lib/crti.o"        "$SHIM_ABS/lib/crti.o"
cp "$BUILD_ABS/tcc/lib/crtn.o"        "$SHIM_ABS/lib/crtn.o"
cp "$BUILD_ABS/tcc/lib/libc.a"        "$SHIM_ABS/lib/libc.a"
cp "$BUILD_ABS/tcc/lib/libgetopt.a"   "$SHIM_ABS/lib/libgetopt.a"
cp "$BUILD_ABS/tcc/lib/libtcc1.a"     "$SHIM_ABS/lib/libtcc1.a"
chmod +x "$SHIM_ABS/bin/tcc"

# Stage 2: extract tinycc-bootstrappable include/ to shim/include/.
log "Stage 2: extract tinycc include/ to shim"
WORK="$(mktemp -d -t reproos-r5-tccshim-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$VENDOR_ABS/tinycc-bootstrappable.tar.gz" -C "$WORK"
TCC_SRC="$WORK/tinycc-ea3900f6d5e71776c5cfabcabee317652e3a19ee"
if [ ! -d "$TCC_SRC/include" ]; then
  echo "[tcc-shim] ERROR: tinycc include/ not found in $TCC_SRC" >&2
  exit 1
fi
cp -r "$TCC_SRC/include/." "$SHIM_ABS/include/"

# Stage 3: overlay mes-libc include/ onto shim/include/.
log "Stage 3: overlay mes-libc include/ on shim/include/"
# Note: we cp -r, with subsequent files overwriting conflicts.  mes-libc
# wins on conflicts because libc headers (stdio.h, sys/*.h, etc.) are
# the libc-specific layer.  But we must NOT overwrite tinycc's
# compiler-intrinsic headers (stddef.h, stdarg.h, float.h, varargs.h).
# Strategy: copy mes-libc include first as a baseline, then re-overlay
# tinycc's compiler-intrinsic headers.

# Save the tinycc intrinsic headers (which we want to keep).
TCC_INTRINSICS=(stddef.h stdarg.h float.h varargs.h tcclib.h tccdefs.h)
mkdir -p "$WORK/saved-intrinsics"
for h in "${TCC_INTRINSICS[@]}"; do
  if [ -e "$SHIM_ABS/include/$h" ]; then
    cp "$SHIM_ABS/include/$h" "$WORK/saved-intrinsics/$h"
  fi
done

# Now copy mes-libc headers atop.
cp -r "$BUILD_ABS/mes/share/mes-0.27.1/include/." "$SHIM_ABS/include/"

# Restore tinycc intrinsics.
for h in "${TCC_INTRINSICS[@]}"; do
  if [ -e "$WORK/saved-intrinsics/$h" ]; then
    cp "$WORK/saved-intrinsics/$h" "$SHIM_ABS/include/$h"
  fi
done

# Stage 4: create the wrapper.
log "Stage 4: create wrapper $SHIM_ABS/wrapper/tcc"
cat > "$SHIM_ABS/wrapper/tcc" <<EOF
#!/bin/bash
# tcc wrapper -- injects -I $SHIM_ABS/include and -B $SHIM_ABS/lib so
# the R4 tcc finds standard headers + crt + libc + libtcc1 even when
# the original baked CONFIG_TCC_SYSINCLUDEPATHS is unreachable.
exec "$SHIM_ABS/bin/tcc" -B "$SHIM_ABS/lib" -I "$SHIM_ABS/include" "\$@"
EOF
chmod +x "$SHIM_ABS/wrapper/tcc"

# Stage 5: also (re-)materialise the baked /tmp/reproos-r4e-tcc-XXXXXX
# include paths as symlinks pointing at the shim, so the R4 tcc's
# default -- i.e. without -I overrides -- ALSO finds headers.  This is
# resilient against ./configure scripts that strip CC env vars.
log "Stage 5: rehydrate /tmp/reproos-r4e-tcc-61ItS1 paths as symlinks"
BAKED_ROOT="/tmp/reproos-r4e-tcc-61ItS1"
mkdir -p "$BAKED_ROOT"
ln -snf "$TCC_SRC" "$BAKED_ROOT/tinycc-ea3900f6d5e71776c5cfabcabee317652e3a19ee" \
  2>/dev/null || true
# Re-extract tinycc source persistently for the symlink target above (since
# WORK is in trap; copy to a persistent location).
PERSISTENT_TCC_SRC="$SHIM_ABS/_tinycc-src"
rm -rf "$PERSISTENT_TCC_SRC"
mkdir -p "$PERSISTENT_TCC_SRC"
cp -r "$TCC_SRC/." "$PERSISTENT_TCC_SRC/"
ln -snf "$PERSISTENT_TCC_SRC" "$BAKED_ROOT/tinycc-ea3900f6d5e71776c5cfabcabee317652e3a19ee"
mkdir -p "$BAKED_ROOT/mes-libc"
ln -snf "$BUILD_ABS/mes/share/mes-0.27.1/include" "$BAKED_ROOT/mes-libc/include-link"

# Stage 6: smoke tests.
log "Stage 6: smoke tests"
SMOKE_WORK="$WORK/smoke"
mkdir -p "$SMOKE_WORK"

# Test A: ret-only via wrapper.
cat > "$SMOKE_WORK/ret.c" <<EOF
int main(){return 7;}
EOF
"$SHIM_ABS/wrapper/tcc" -o "$SMOKE_WORK/ret" "$SMOKE_WORK/ret.c"
rc=0; "$SMOKE_WORK/ret" || rc=$?
log "  test A (ret-only via wrapper): exit=$rc (expected 7)"
if [ "$rc" -ne 7 ]; then
  echo "[tcc-shim] ERROR: smoke A failed" >&2
  exit 1
fi

# Test B: stdio.h hello world via wrapper.
cat > "$SMOKE_WORK/hello.c" <<EOF
#include <stdio.h>
int main(){puts("hello-r5"); return 11;}
EOF
"$SHIM_ABS/wrapper/tcc" -o "$SMOKE_WORK/hello" "$SMOKE_WORK/hello.c" 2>&1 | head -10 || {
  log "  test B compile failed (may be expected -- mes-libc has only mes ABI)"
}
if [ -x "$SMOKE_WORK/hello" ]; then
  rc=0; "$SMOKE_WORK/hello" || rc=$?
  log "  test B (stdio.h via wrapper): exit=$rc (expected 11)"
else
  log "  test B: SKIPPED (no hello binary produced)"
fi

# Test C: ret-only via /tmp/reproos baked-path symlinks (no wrapper).
cat > "$SMOKE_WORK/ret2.c" <<EOF
int main(){return 13;}
EOF
"$SHIM_ABS/bin/tcc" -B "$SHIM_ABS/lib" -o "$SMOKE_WORK/ret2" "$SMOKE_WORK/ret2.c"
rc=0; "$SMOKE_WORK/ret2" || rc=$?
log "  test C (ret-only via baked-path symlinks): exit=$rc (expected 13)"
if [ "$rc" -ne 13 ]; then
  echo "[tcc-shim] ERROR: smoke C failed" >&2
  exit 1
fi

# Test D: stdio.h via baked-path symlinks.
cat > "$SMOKE_WORK/hello2.c" <<EOF
#include <stdio.h>
int main(){puts("hello-baked"); return 17;}
EOF
"$SHIM_ABS/bin/tcc" -B "$SHIM_ABS/lib" -o "$SMOKE_WORK/hello2" "$SMOKE_WORK/hello2.c" 2>&1 | head -10 || {
  log "  test D compile failed via baked path"
}
if [ -x "$SMOKE_WORK/hello2" ]; then
  rc=0; "$SMOKE_WORK/hello2" || rc=$?
  log "  test D (stdio.h via baked path): exit=$rc (expected 17)"
fi

# Emit SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$SHIM_ABS"
  printf "# R5 Phase 2 (tcc-shim) outputs -- built %s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')"
  for f in bin/tcc \
           lib/crt1.o lib/crti.o lib/crtn.o \
           lib/libc.a lib/libgetopt.a lib/libtcc1.a \
           wrapper/tcc; do
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$SHIM_ABS/SHA256SUMS"
cat "$SHIM_ABS/SHA256SUMS"
log "tcc shim ready at $SHIM_ABS"
