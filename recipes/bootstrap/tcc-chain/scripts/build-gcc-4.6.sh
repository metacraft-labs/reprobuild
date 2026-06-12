#!/bin/bash
# build-gcc-4.6.sh -- R5 Phase E (Stage A): build gcc 4.6.4 with tinycc-musl
# + binutils.  C-only.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/gcc/4.6.nix.
#
# Inputs (positional):
#   $1 = vendor dir         (gcc-core-4.6.4.tar.gz + gmp 4.3.2 + mpfr 2.4.2 + mpc 1.0.3)
#   $2 = patches dir        (no-system-headers.patch)
#   $3 = tinycc-musl dir    (R5 Phase C output)
#   $4 = binutils dir       (R5 Phase D output)
#   $5 = output dir
#
# Required env: SOURCE_DATE_EPOCH + LC_ALL + TZ.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage}"
PATCHES="${2:?usage}"
TINYCC_MUSL="${3:?usage}"
BINUTILS="${4:?usage}"
OUT="${5:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
PATCHES_ABS="$(cd "$PATCHES" && pwd)"
TINYCC_MUSL_ABS="$(cd "$TINYCC_MUSL" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

log() { echo "[gcc-4.6] $*"; }
log "VENDOR=$VENDOR_ABS"
log "PATCHES=$PATCHES_ABS"
log "TINYCC_MUSL=$TINYCC_MUSL_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/gcc-core-4.6.4.tar.gz" \
         "$VENDOR_ABS/gmp-4.3.2.tar.gz" \
         "$VENDOR_ABS/mpfr-2.4.2.tar.gz" \
         "$VENDOR_ABS/mpc-1.0.3.tar.gz" \
         "$PATCHES_ABS/no-system-headers.patch" \
         "$TINYCC_MUSL_ABS/bin/tcc" \
         "$TINYCC_MUSL_ABS/lib/libtcc1.a" \
         "$BINUTILS_ABS/bin/ld" \
         "$BINUTILS_ABS/bin/as"; do
  [ -e "$f" ] || { echo "[gcc-4.6] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-gcc46-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[gcc-4.6] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack gcc + gmp + mpfr + mpc"
tar -xzf "$VENDOR_ABS/gcc-core-4.6.4.tar.gz"
tar -xzf "$VENDOR_ABS/gmp-4.3.2.tar.gz"
tar -xzf "$VENDOR_ABS/mpfr-2.4.2.tar.gz"
tar -xzf "$VENDOR_ABS/mpc-1.0.3.tar.gz"

cd gcc-4.6.4
ln -sf ../gmp-4.3.2 gmp
ln -sf ../mpfr-2.4.2 mpfr
ln -sf ../mpc-1.0.3 mpc

log "Stage 2: apply patches"
patch -Np1 -i "$PATCHES_ABS/no-system-headers.patch"

# Force fixincludes to produce a no-op fixinc.sh by overriding mkfixinc.sh.
# Upstream mkfixinc.sh emits a real fixinc.sh that scans SYSTEM_HEADER_DIR
# (= NATIVE_SYSTEM_HEADER_DIR after our patch) and rewrites headers into
# include-fixed/.  Even though we point SYSTEM_HEADER_DIR at tinycc-musl-final's
# clean musl headers (not /usr/include), the scan is unnecessary for a
# bootstrap libc and a no-op avoids any host /usr/include leakage hazard
# regardless of how fixincludes resolves relative paths.
# IMPORTANT: mkfixinc.sh takes <target-triple> as $1 and writes fixinc.sh in
# the build dir's $PWD.  Our replacement must honor that contract.
log "Stage 2b: stub fixincludes to a no-op"
cat > fixincludes/mkfixinc.sh <<'MKFIXEOF'
#!/bin/sh
target=fixinc.sh
(echo "#! /bin/sh" ; echo "exit 0") > ${target}
chmod 755 ${target}
MKFIXEOF
chmod +x fixincludes/mkfixinc.sh

# Add binutils to PATH so configure finds ld/as.
export PATH="$BINUTILS_ABS/bin:$PATH"

# CC = tinycc-musl with -B for libtcc1.
export CC="$TINYCC_MUSL_ABS/bin/tcc -B $TINYCC_MUSL_ABS/lib"
export C_INCLUDE_PATH="$TINYCC_MUSL_ABS/include:$WORK/gcc-4.6.4/mpfr/src"
export CPLUS_INCLUDE_PATH="$C_INCLUDE_PATH"
export lt_cv_shlibpath_overrides_runpath=yes
export ac_cv_func_memcpy=yes
export ac_cv_func_strerror=yes

# config.sub gets confused by 4-component target tuples.
fakeBuild=x86_64-pc-linux
fakeHost=x86_64-pc-linux

log "Stage 3: configure"
bash ./configure \
  --prefix="$OUT_ABS" \
  --build="$fakeBuild" \
  --host="$fakeHost" \
  --with-native-system-header-dir="$TINYCC_MUSL_ABS/include" \
  --with-build-sysroot="$TINYCC_MUSL_ABS/include" \
  --enable-checking=release \
  --disable-bootstrap \
  --disable-decimal-float \
  --disable-dependency-tracking \
  --disable-libatomic \
  --disable-libcilkrts \
  --disable-libgomp \
  --disable-libitm \
  --disable-libmudflap \
  --disable-libquadmath \
  --disable-libsanitizer \
  --disable-libssp \
  --disable-libvtv \
  --disable-lto \
  --disable-lto-plugin \
  --disable-multilib \
  --disable-nls \
  --disable-plugin \
  --disable-threads \
  --enable-languages=c \
  --enable-static \
  --disable-shared \
  --enable-threads=single \
  --disable-libstdcxx-pch \
  --disable-build-with-cxx \
  2>&1 | tee "$WORK/configure.log" | tail -30

log "Stage 4: make"
# Use parallel make to speed up (nixpkgs does -j $NIX_BUILD_CORES).
make -j2 2>&1 | tee "$WORK/make.log" | tail -30 || {
  echo "[gcc-4.6] ERROR: make failed"
  tail -100 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install-strip"
make install-strip 2>&1 | tee "$WORK/install.log" | tail -20

if [ -x "$OUT_ABS/bin/gcc" ]; then
  log "  gcc version: $("$OUT_ABS/bin/gcc" --version | head -1)"
else
  echo "[gcc-4.6] ERROR: $OUT_ABS/bin/gcc not produced" >&2
  exit 1
fi

# SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase E (gcc 4.6.4 C-only / tinycc-musl + binutils) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in bin/gcc bin/cpp libexec/gcc/*/4.6.4/cc1 libexec/gcc/*/4.6.4/collect2; do
    if [ -f "$f" ]; then
      printf "%-50s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "gcc 4.6.4 (Stage A) ready at $OUT_ABS"
