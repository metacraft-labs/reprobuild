#!/bin/bash
# build-gcc-4.6-cxx.sh -- R5 Phase F (Stage B): gcc 4.6.4 C+C++ via
# Stage-A gcc + musl-gcc.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/gcc/4.6.cxx.nix.
#
# Inputs (positional):
#   $1 = vendor dir         (gcc-core + gcc-g++ + gmp 4.3.2 + mpfr 2.4.2 + mpc 1.0.3)
#   $2 = patches dir        (no-system-headers.patch)
#   $3 = gcc-4.6 dir        (Stage A gcc — $gcc46/bin/gcc)
#   $4 = musl dir           (musl-gcc46 — has libc.so, libc.a, headers)
#   $5 = binutils dir
#   $6 = output dir

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage}"
PATCHES="${2:?usage}"
GCC46="${3:?usage}"
MUSL="${4:?usage}"
BINUTILS="${5:?usage}"
OUT="${6:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
PATCHES_ABS="$(cd "$PATCHES" && pwd)"
GCC46_ABS="$(cd "$GCC46" && pwd)"
MUSL_ABS="$(cd "$MUSL" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${GCC_4_6_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=gcc-cxx \
    --package-version=4.6.4 \
    --toolchain-name=gcc \
    --toolchain-version=4.6.4 \
    "${_phase_deps[@]}"
  echo "[cache] gcc-cxx cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] gcc-cxx from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] gcc-cxx: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[gcc-4.6-cxx] $*"; }
log "VENDOR=$VENDOR_ABS"
log "GCC46=$GCC46_ABS"
log "MUSL=$MUSL_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/gcc-core-4.6.4.tar.gz" \
         "$VENDOR_ABS/gcc-g++-4.6.4.tar.gz" \
         "$VENDOR_ABS/gmp-4.3.2.tar.gz" \
         "$VENDOR_ABS/mpfr-2.4.2.tar.gz" \
         "$VENDOR_ABS/mpc-1.0.3.tar.gz" \
         "$PATCHES_ABS/no-system-headers.patch" \
         "$GCC46_ABS/bin/gcc" \
         "$MUSL_ABS/lib/libc.so" \
         "$BINUTILS_ABS/bin/ld"; do
  [ -e "$f" ] || { echo "[gcc-4.6-cxx] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-gcc46cxx-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[gcc-4.6-cxx] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack"
tar -xzf "$VENDOR_ABS/gcc-core-4.6.4.tar.gz"
tar -xzf "$VENDOR_ABS/gcc-g++-4.6.4.tar.gz"
tar -xzf "$VENDOR_ABS/gmp-4.3.2.tar.gz"
tar -xzf "$VENDOR_ABS/mpfr-2.4.2.tar.gz"
tar -xzf "$VENDOR_ABS/mpc-1.0.3.tar.gz"

cd gcc-4.6.4
ln -sf ../gmp-4.3.2 gmp
ln -sf ../mpfr-2.4.2 mpfr
ln -sf ../mpc-1.0.3 mpc

log "Stage 2: patches"
patch -Np1 -i "$PATCHES_ABS/no-system-headers.patch"
# musl is not recognised as gnu-linux by libstdc++ configure.host; per
# nixpkgs sed it to use os/generic instead.
sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host

# Stub fixincludes (same reasoning as Stage A).
cat > fixincludes/mkfixinc.sh <<'MKFIXEOF'
#!/bin/sh
target=fixinc.sh
(echo "#! /bin/sh" ; echo "exit 0") > ${target}
chmod 755 ${target}
MKFIXEOF
chmod +x fixincludes/mkfixinc.sh

# binutils-final on PATH first.
export PATH="$BINUTILS_ABS/bin:$GCC46_ABS/bin:$PATH"

# CC = Stage-A gcc, linked against the new musl-shared (libc.so) via
# explicit -Wl,-dynamic-linker.  Per nixpkgs 4.6.cxx.nix.
# Add --sysroot=$MUSL to ensure system headers come from musl only.
# Without this, gcc falls back to /usr/include on impure host systems
# (Debian here), which leaks gnulib-style headers like obstack.h that
# musl doesn't carry — gmp's configure detects them and tries to use
# them, but the host headers reference glibc-only macros.
export CC="$GCC46_ABS/bin/gcc --sysroot=$MUSL_ABS -Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$MUSL_ABS/lib/libc.so"
export C_INCLUDE_PATH="$MUSL_ABS/include"
export CPLUS_INCLUDE_PATH="$C_INCLUDE_PATH"
export LIBRARY_PATH="$MUSL_ABS/lib"

# config.sub doesn't grok 4-component tuples.
fakeBuild=x86_64-pc-linux
fakeHost=x86_64-pc-linux

log "Stage 3: configure (C+C++)"
bash ./configure \
  --prefix="$OUT_ABS" \
  --build="$fakeBuild" \
  --host="$fakeHost" \
  --with-native-system-header-dir="$MUSL_ABS/include" \
  --with-build-sysroot="$MUSL_ABS" \
  --enable-languages=c,c++ \
  --enable-checking=release \
  --disable-bootstrap \
  --disable-dependency-tracking \
  --disable-libgomp \
  --disable-libmudflap \
  --disable-libquadmath \
  --disable-libssp \
  --disable-libstdcxx-pch \
  --disable-lto \
  --disable-multilib \
  --disable-nls \
  2>&1 | tee "$WORK/configure.log" | tail -30

log "Stage 4: make"
make -j"$(nproc)" 2>&1 | tee "$WORK/make.log" | tail -30 || {
  echo "[gcc-4.6-cxx] ERROR: make failed; tail:" >&2
  tail -120 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install-strip"
make install-strip 2>&1 | tee "$WORK/install.log" | tail -20

if [ ! -x "$OUT_ABS/bin/g++" ]; then
  echo "[gcc-4.6-cxx] ERROR: $OUT_ABS/bin/g++ not produced" >&2
  exit 1
fi
log "  g++ version: $("$OUT_ABS/bin/g++" --version | head -1)"

log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase F (gcc 4.6.4 C+C++ / Stage-A gcc + musl) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in bin/gcc bin/g++ bin/cpp libexec/gcc/*/4.6.4/cc1 \
           libexec/gcc/*/4.6.4/cc1plus libexec/gcc/*/4.6.4/collect2; do
    if [ -f "$f" ]; then
      printf "%-60s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "gcc 4.6.4 (Stage B C+C++) ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
