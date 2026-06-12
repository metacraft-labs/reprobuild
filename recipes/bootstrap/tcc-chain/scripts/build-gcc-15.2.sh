#!/bin/bash
# build-gcc-15.2.sh -- R5 Phase H (acceptance gate): gcc 15.2.0 via gcc 10.4.0.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/gcc/latest.nix.
#
# Inputs (positional):
#   $1 = vendor dir      (gcc-15.2.0 + gmp 6.3.0 + mpfr 4.2.2 + mpc 1.3.1 + isl 0.24)
#   $2 = gcc 10.4.0 dir  (boot compiler — $gcc104/bin/{gcc,g++})
#   $3 = musl dir        (musl-gcc46 with libc.so/libc.a + headers)
#   $4 = binutils dir
#   $5 = output dir

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage}"
GCC104="${2:?usage}"
MUSL="${3:?usage}"
BINUTILS="${4:?usage}"
OUT="${5:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
GCC104_ABS="$(cd "$GCC104" && pwd)"
MUSL_ABS="$(cd "$MUSL" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

log() { echo "[gcc-15.2] $*"; }
log "VENDOR=$VENDOR_ABS"
log "GCC104=$GCC104_ABS"
log "MUSL=$MUSL_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/gcc-15.2.0.tar.xz" \
         "$VENDOR_ABS/gmp-6.3.0.tar.xz" \
         "$VENDOR_ABS/mpfr-4.2.2.tar.xz" \
         "$VENDOR_ABS/mpc-1.3.1.tar.gz" \
         "$VENDOR_ABS/isl-0.24.tar.bz2" \
         "$GCC104_ABS/bin/gcc" \
         "$GCC104_ABS/bin/g++" \
         "$MUSL_ABS/lib/libc.so" \
         "$BINUTILS_ABS/bin/ld"; do
  [ -e "$f" ] || { echo "[gcc-15.2] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-gcc152-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[gcc-15.2] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack"
tar -xf "$VENDOR_ABS/gcc-15.2.0.tar.xz"
tar -xf "$VENDOR_ABS/gmp-6.3.0.tar.xz"
tar -xf "$VENDOR_ABS/mpfr-4.2.2.tar.xz"
tar -xf "$VENDOR_ABS/mpc-1.3.1.tar.gz"
tar -xf "$VENDOR_ABS/isl-0.24.tar.bz2"

cd gcc-15.2.0
ln -sf ../gmp-6.3.0 gmp
ln -sf ../mpfr-4.2.2 mpfr
ln -sf ../mpc-1.3.1 mpc
ln -sf ../isl-0.24 isl

log "Stage 2: patches"
sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host

# Stub fixincludes.
cat > fixincludes/mkfixinc.sh <<'MKFIXEOF'
#!/bin/sh
target=fixinc.sh
(echo "#! /bin/sh" ; echo "exit 0") > ${target}
chmod 755 ${target}
MKFIXEOF
chmod +x fixincludes/mkfixinc.sh

export PATH="$BINUTILS_ABS/bin:$GCC104_ABS/bin:$PATH"

# CC / CXX: gcc 10.4.0, linked against musl libc.so dynamically; sysroot=$MUSL.
export CC="$GCC104_ABS/bin/gcc --sysroot=$MUSL_ABS -Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export CXX="$GCC104_ABS/bin/g++ --sysroot=$MUSL_ABS -Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export LIBRARY_PATH="$MUSL_ABS/lib"

log "Stage 3: configure"
bash ./configure \
  --prefix="$OUT_ABS" \
  --build=x86_64-pc-linux-gnu \
  --host=x86_64-pc-linux-gnu \
  --with-native-system-header-dir=/include \
  --with-sysroot="$MUSL_ABS" \
  --enable-languages=c,c++ \
  --enable-checking=release \
  --disable-bootstrap \
  --disable-dependency-tracking \
  --disable-libsanitizer \
  --disable-libssp \
  --disable-libgomp \
  --disable-libquadmath \
  --disable-libitm \
  --disable-libvtv \
  --disable-libatomic \
  --disable-libstdcxx-pch \
  --disable-lto \
  --disable-multilib \
  --disable-nls \
  --disable-plugin \
  2>&1 | tee "$WORK/configure.log" | tail -30

log "Stage 4: make -j$(nproc)"
make -j"$(nproc)" 2>&1 | tee "$WORK/make.log" | tail -30 || {
  echo "[gcc-15.2] ERROR: make failed; tail:" >&2
  tail -120 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install-strip"
make install-strip 2>&1 | tee "$WORK/install.log" | tail -20

# Cleanup per nixpkgs.
rm -rf "$OUT_ABS"/share/gcc-*/python "$OUT_ABS"/share/man "$OUT_ABS"/share/info

if [ ! -x "$OUT_ABS/bin/g++" ]; then
  echo "[gcc-15.2] ERROR: $OUT_ABS/bin/g++ not produced" >&2
  exit 1
fi
log "  g++ version: $("$OUT_ABS/bin/g++" --version | head -1)"

log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase H (gcc 15.2.0 / via gcc 10.4.0 + musl) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in bin/gcc bin/g++ bin/cpp libexec/gcc/*/15.2.0/cc1 \
           libexec/gcc/*/15.2.0/cc1plus libexec/gcc/*/15.2.0/collect2; do
    if [ -f "$f" ]; then
      printf "%-60s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "gcc 15.2.0 ready at $OUT_ABS"
