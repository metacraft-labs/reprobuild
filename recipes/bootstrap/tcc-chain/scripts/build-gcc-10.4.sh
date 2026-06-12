#!/bin/bash
# build-gcc-10.4.sh -- R5 Phase G: gcc 10.4.0 via Stage-B gcc 4.6.4.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/gcc/10.nix.
#
# Inputs (positional):
#   $1 = vendor dir       (gcc-10.4.0 + gmp 6.2.1 + mpfr 4.2.2 + mpc 1.3.1 + isl 0.24)
#   $2 = gcc 4.6 cxx dir  (Stage B gcc — $gcc46cxx/bin/gcc + g++)
#   $3 = musl dir         (musl-gcc46 — has libc.so/libc.a + headers)
#   $4 = binutils dir
#   $5 = output dir

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage}"
GCC46CXX="${2:?usage}"
MUSL="${3:?usage}"
BINUTILS="${4:?usage}"
OUT="${5:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
GCC46CXX_ABS="$(cd "$GCC46CXX" && pwd)"
MUSL_ABS="$(cd "$MUSL" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

log() { echo "[gcc-10.4] $*"; }
log "VENDOR=$VENDOR_ABS"
log "GCC46CXX=$GCC46CXX_ABS"
log "MUSL=$MUSL_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/gcc-10.4.0.tar.xz" \
         "$VENDOR_ABS/gmp-6.2.1.tar.xz" \
         "$VENDOR_ABS/mpfr-4.2.2.tar.xz" \
         "$VENDOR_ABS/mpc-1.3.1.tar.gz" \
         "$VENDOR_ABS/isl-0.24.tar.bz2" \
         "$GCC46CXX_ABS/bin/gcc" \
         "$GCC46CXX_ABS/bin/g++" \
         "$MUSL_ABS/lib/libc.so" \
         "$BINUTILS_ABS/bin/ld"; do
  [ -e "$f" ] || { echo "[gcc-10.4] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-gcc104-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[gcc-10.4] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack"
tar -xf "$VENDOR_ABS/gcc-10.4.0.tar.xz"
tar -xf "$VENDOR_ABS/gmp-6.2.1.tar.xz"
tar -xf "$VENDOR_ABS/mpfr-4.2.2.tar.xz"
tar -xf "$VENDOR_ABS/mpc-1.3.1.tar.gz"
tar -xf "$VENDOR_ABS/isl-0.24.tar.bz2"

cd gcc-10.4.0
ln -sf ../gmp-6.2.1 gmp
ln -sf ../mpfr-4.2.2 mpfr
ln -sf ../mpc-1.3.1 mpc
ln -sf ../isl-0.24 isl

log "Stage 2: patches"
# libstdc++ doesn't recognise musl as gnu-linux; nixpkgs sed swap.
sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host

# Stub fixincludes.
cat > fixincludes/mkfixinc.sh <<'MKFIXEOF'
#!/bin/sh
target=fixinc.sh
(echo "#! /bin/sh" ; echo "exit 0") > ${target}
chmod 755 ${target}
MKFIXEOF
chmod +x fixincludes/mkfixinc.sh

export PATH="$BINUTILS_ABS/bin:$GCC46CXX_ABS/bin:$PATH"

# CC / CXX: Stage-B gcc 4.6.4, linked against musl libc.so dynamically.
# Add --sysroot=$MUSL so system headers come from musl only.
export CC="$GCC46CXX_ABS/bin/gcc --sysroot=$MUSL_ABS -Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export CXX="$GCC46CXX_ABS/bin/g++ --sysroot=$MUSL_ABS -Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export C_INCLUDE_PATH="$MUSL_ABS/include"
export CPLUS_INCLUDE_PATH="$C_INCLUDE_PATH"
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
  --disable-libmpx \
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
  echo "[gcc-10.4] ERROR: make failed; tail:" >&2
  tail -120 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install-strip"
make install-strip 2>&1 | tee "$WORK/install.log" | tail -20

if [ ! -x "$OUT_ABS/bin/g++" ]; then
  echo "[gcc-10.4] ERROR: $OUT_ABS/bin/g++ not produced" >&2
  exit 1
fi
log "  g++ version: $("$OUT_ABS/bin/g++" --version | head -1)"

log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase G (gcc 10.4.0 / Stage-B gcc 4.6.4 + musl) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in bin/gcc bin/g++ bin/cpp libexec/gcc/*/10.4.0/cc1 \
           libexec/gcc/*/10.4.0/cc1plus libexec/gcc/*/10.4.0/collect2; do
    if [ -f "$f" ]; then
      printf "%-60s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "gcc 10.4.0 ready at $OUT_ABS"
