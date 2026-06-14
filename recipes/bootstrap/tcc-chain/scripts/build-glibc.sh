#!/bin/bash
# build-glibc.sh -- R6 Phase 2: glibc 2.42 via R5's gcc 15.2.0 + binutils 2.46.0.
#
# Ports nixpkgs's pkgs/development/libraries/glibc/{common.nix,default.nix}.
# nixpkgs uses 2.42 + 254 KB of upstream stable-branch backports (2.42-master.patch
# = "glibc 2.42-61").  For R6 we build vanilla 2.42 to keep the patch surface
# tractable -- the R6 gate is "libc.so.6 loads, hello-world links and runs".
# Backports are upstream bug fixes, not behaviour changes; can be added in
# R6.1 if needed.
#
# Inputs (positional):
#   $1 = vendor dir       (glibc-2.42.tar.xz)
#   $2 = gcc dir          (R5's gcc 15.2.0)
#   $3 = binutils dir     (R5's binutils 2.46.0)
#   $4 = linux-headers dir (R6 Phase 1 output)
#   $5 = output dir       (will contain lib/, include/, bin/, etc.)
#
# Wall-clock budget: ~30-50 min on 16+ core x86_64.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: $0 VENDOR GCC BINUTILS LINUX_HEADERS OUT}"
GCC="${2:?usage}"
BINUTILS="${3:?usage}"
LINUX_HEADERS="${4:?usage}"
OUT="${5:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
GCC_ABS="$(cd "$GCC" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
LINUX_HEADERS_ABS="$(cd "$LINUX_HEADERS" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${GCC_10_4_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  _depfile="${LINUX_HEADERS_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=glibc \
    --package-version=2.42 \
    --toolchain-name=gcc-10.4 \
    --toolchain-version=10.4.0 \
    "${_phase_deps[@]}"
  echo "[cache] glibc cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] glibc from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] glibc: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[glibc] $*"; }
log "VENDOR=$VENDOR_ABS"
log "GCC=$GCC_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "LINUX_HEADERS=$LINUX_HEADERS_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/glibc-2.42.tar.xz" \
         "$GCC_ABS/bin/gcc" \
         "$GCC_ABS/bin/g++" \
         "$BINUTILS_ABS/bin/ld" \
         "$BINUTILS_ABS/bin/as" \
         "$LINUX_HEADERS_ABS/include/asm/unistd_64.h"; do
  [ -e "$f" ] || { echo "[glibc] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r6-glibc-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[glibc] keeping WORK=$WORK for debug (rc=$rc)" >&2; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack glibc-2.42.tar.xz"
tar -xf "$VENDOR_ABS/glibc-2.42.tar.xz"

log "Stage 2: out-of-tree build dir"
mkdir build
cd build

# Toolchain wiring.
#
# R5's gcc 15.2 was built with `--with-sysroot=$MUSL` and
# `--with-native-system-header-dir=/include`, so by default it reads
# <stdio.h> from $MUSL/include.  glibc's build phase generates its own
# headers + libs, so we MUST keep gcc from picking up musl headers
# at compile time.  Two complementary mechanisms:
#
#   (a) `-nostdinc` tells gcc to skip the sysroot include path; glibc's
#       configure adds its own -isystem flags pointing at the in-tree
#       generated headers + linux-headers.
#   (b) `--with-headers=$LINUX_HEADERS/include` configure flag tells
#       glibc which kernel headers to honour.
#
# For the linker side, we use binutils 2.46 directly (PATH-prepended),
# and pass `-B$BINUTILS/bin` to gcc so it picks up the binutils 2.46
# wrappers rather than any host as/ld.

export PATH="$BINUTILS_ABS/bin:$GCC_ABS/bin:$PATH"

# Run configure with R5's gcc 15.2 as CC.  Don't propagate the
# musl --sysroot here: glibc handles its own header path resolution
# via --with-headers + the in-tree include/ tree.  We DO need to
# strip musl include from gcc's default search, which we do via the
# `-nostdinc` in CFLAGS-passed-to-configure -- but with a catch: the
# configure script also runs a bunch of host-tool probes (sizeof
# (long), etc.), and those probes need to compile-link, which requires
# crt + libc.  So we cannot use `-nostdinc` at configure time -- only
# at build time, via the BUILD_CC_INCLUDES makeflag.
#
# Concretely, the configure-time CC must work as a normal C compiler
# (with musl headers visible), and the build-time CC must use
# linux-headers + glibc's own in-tree headers.  glibc handles this
# split internally via the +ABI flag plumbing in Makeconfig.  Our job
# is just to point `--with-headers` at the right place; glibc will
# inject the right `-nostdinc -isystem <X>` chain.

log "Stage 3: configure"
# `bash` (not `sh`): glibc's configure uses bash-isms.
#
# NB: explicitly set CXX= (empty).  glibc's support/Makefile has a
# test-only `links-dso-program` that, when CXX is set, links against
# libstdc++ which (in our R5 toolchain) pulls in a hidden `atexit`
# symbol that conflicts with libc_nonshared.a's `atexit`.  With CXX
# empty, glibc falls back to the C-only `links-dso-program-c` which
# only needs `-lgcc` and links cleanly.  configure auto-discovers g++
# from PATH if CXX is unset, hence the explicit empty assignment.
unset CXX
CXX=
export CXX
bash ../glibc-2.42/configure \
  --prefix="$OUT_ABS" \
  --build=x86_64-pc-linux-gnu \
  --host=x86_64-pc-linux-gnu \
  --with-headers="$LINUX_HEADERS_ABS/include" \
  --enable-kernel=3.10.0 \
  --enable-add-ons \
  --enable-stack-protector=strong \
  --enable-bind-now \
  --enable-fortify-source \
  --disable-multilib \
  --disable-profile \
  --disable-werror \
  --disable-nscd \
  --without-gd \
  --without-selinux \
  --without-cvs \
  CC="$GCC_ABS/bin/gcc -B$BINUTILS_ABS/bin/" \
  AR="$BINUTILS_ABS/bin/ar" \
  AS="$BINUTILS_ABS/bin/as" \
  LD="$BINUTILS_ABS/bin/ld" \
  NM="$BINUTILS_ABS/bin/nm" \
  OBJCOPY="$BINUTILS_ABS/bin/objcopy" \
  OBJDUMP="$BINUTILS_ABS/bin/objdump" \
  RANLIB="$BINUTILS_ABS/bin/ranlib" \
  READELF="$BINUTILS_ABS/bin/readelf" \
  STRIP="$BINUTILS_ABS/bin/strip" \
  2>&1 | tee "$WORK/configure.log" | tail -50

log "Stage 4: make -j$(nproc)"
# Force CXX= (empty) at make time so the support/Makefile's
# `ifeq (,$(CXX))` branch fires and links-dso-program-c (C-only,
# no libstdc++) is used instead of links-dso-program (C++, breaks
# our R5 chain).
make -j"$(nproc)" CXX= 2>&1 | tee "$WORK/make.log" | tail -30 || {
  echo "[glibc] ERROR: make failed; tail:" >&2
  tail -200 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install"
make install -j"$(nproc)" CXX= 2>&1 | tee "$WORK/install.log" | tail -30

# Cleanup that nixpkgs does post-install.
if [ -d "$OUT_ABS/var" ]; then
  rm -rf "$OUT_ABS/var"
fi
if [ -f "$OUT_ABS/etc/ld.so.cache" ]; then
  rm -f "$OUT_ABS/etc/ld.so.cache"
fi

# x86_64 sanity: glibc installs to $prefix/lib (not lib64 by default for
# --disable-multilib); make `lib64 -> lib` symlink for ld-linux-x86-64.so.2
# search compatibility.  Use junction-aware test (we test for the symlink
# directly, not via -e which would follow it).
if [ ! -L "$OUT_ABS/lib64" ] && [ ! -d "$OUT_ABS/lib64" ]; then
  ln -s lib "$OUT_ABS/lib64"
fi

if [ ! -f "$OUT_ABS/lib/libc.so.6" ]; then
  echo "[glibc] ERROR: $OUT_ABS/lib/libc.so.6 not produced" >&2
  ls -la "$OUT_ABS/lib" >&2 || true
  exit 1
fi
if [ ! -f "$OUT_ABS/lib/ld-linux-x86-64.so.2" ]; then
  echo "[glibc] ERROR: $OUT_ABS/lib/ld-linux-x86-64.so.2 not produced" >&2
  exit 1
fi

log "  libc.so.6: $("$OUT_ABS/bin/ldd" --version 2>&1 | head -1)"

log "writing SHA256SUMS"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/_r6_glibc_shasums.sh" "$OUT_ABS"

# Audit embedded paths that would foil cross-machine reproducibility.
log "embedded-path audit (lib/libc.so.6 + lib/ld-linux-x86-64.so.2):"
for f in lib/libc.so.6 lib/ld-linux-x86-64.so.2; do
  if [ -f "$OUT_ABS/$f" ]; then
    n_repro=$(strings "$OUT_ABS/$f" 2>/dev/null | grep -cE '/repro|/tmp/r6|/tmp/r5' || echo 0)
    n_home=$(strings "$OUT_ABS/$f" 2>/dev/null | grep -cE '/home/|/Users/' || echo 0)
    printf "  %-36s repro/tmp-paths=%d home-paths=%d\n" "$f" "$n_repro" "$n_home"
  fi
done

log "glibc 2.42 ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
