#!/bin/sh
set -e
# ---- A3 P5 cache prelude (auto-wired) ----
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="/tmp/r7-build/shadow"
__R7_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${BASH_SOURCE[0]}" "$OUT_ABS" \
      --package-name=shadow \
      --package-version=4.16 \
      --toolchain-name=gcc-wrapper \
      --toolchain-version=1.0
    echo "[cache] shadow cache-entry-key=${CACHE_KEY_HEX}"
    echo "${CACHE_KEY_HEX}" > "$OUT_ABS/.cache-key.hex"
    if [ "${CACHE_HIT}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] shadow from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${CACHE_HIT}" = "2" ]; then
      echo "[cache] shadow: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
# ---- /A3 P5 cache prelude --------------------
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf shadow-4.19.4
tar xf shadow-4.19.4.tar.xz
cd shadow-4.19.4
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
export CPPFLAGS="-I/tmp/r7-build/libxcrypt/include -I/tmp/r7-build/pam/include"
export LDFLAGS="-L/tmp/r7-build/libxcrypt/lib -Wl,-rpath,/tmp/r7-build/libxcrypt/lib -L/tmp/r7-build/pam/lib -Wl,-rpath,/tmp/r7-build/pam/lib"
./configure \
  --prefix=/tmp/r7-build/shadow \
  --sysconfdir=/etc \
  --disable-static \
  --disable-nls \
  --without-selinux \
  --without-audit \
  --without-libbsd \
  --without-acl \
  --without-attr \
  --without-tcb \
  --without-su \
  --disable-logind \
  --without-sssd \
  --with-libpam \
  --with-libcrypt \
  --enable-shared \
  >/tmp/r7-build/shadow-configure.log 2>&1
echo "configure rc=$?"
tail -3 /tmp/r7-build/shadow-configure.log
make -j$(nproc) >/tmp/r7-build/shadow-make.log 2>&1
echo "make rc=$?"
make install DESTDIR=/tmp/r7-build/shadow-DESTDIR >/tmp/r7-build/shadow-install.log 2>&1
echo "install rc=$?"
ls /tmp/r7-build/shadow-DESTDIR/tmp/r7-build/shadow/bin 2>&1
ls /tmp/r7-build/shadow-DESTDIR/tmp/r7-build/shadow/sbin 2>&1

# ---- A3 P5 cache postlude (auto-wired) ----
if [ -n "${CACHE_KEY_HEX:-}" ]; then
  cache_phase_publish "${OUT_ABS}" || true
fi
# ---- /A3 P5 cache postlude -------------------
