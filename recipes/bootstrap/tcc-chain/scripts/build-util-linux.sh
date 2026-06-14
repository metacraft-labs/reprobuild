#!/bin/sh
set -e
# ---- A3 P5 cache prelude (auto-wired) ----
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="/tmp/r7-build/util-linux"
__R7_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${BASH_SOURCE[0]}" "$OUT_ABS" \
      --package-name=util-linux \
      --package-version=2.41 \
      --toolchain-name=gcc-wrapper \
      --toolchain-version=1.0
    echo "[cache] util-linux cache-entry-key=${CACHE_KEY_HEX}"
    echo "${CACHE_KEY_HEX}" > "$OUT_ABS/.cache-key.hex"
    if [ "${CACHE_HIT}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] util-linux from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${CACHE_HIT}" = "2" ]; then
      echo "[cache] util-linux: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
# ---- /A3 P5 cache prelude --------------------
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf util-linux-2.42
tar xf util-linux-2.42.tar.xz
cd util-linux-2.42
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
# point at ncurses
export NCURSES_CFLAGS="-I/tmp/r7-build/ncurses/include -I/tmp/r7-build/ncurses/include/ncursesw"
export NCURSES_LIBS="-L/tmp/r7-build/ncurses/lib -Wl,-rpath,/tmp/r7-build/ncurses/lib -lncursesw"
export NCURSESW_CFLAGS="$NCURSES_CFLAGS"
export NCURSESW_LIBS="$NCURSES_LIBS"
export TINFO_CFLAGS="-I/tmp/r7-build/ncurses/include"
export TINFO_LIBS="-L/tmp/r7-build/ncurses/lib -Wl,-rpath,/tmp/r7-build/ncurses/lib -ltinfo"
./configure \
  --prefix=/tmp/r7-build/util-linux \
  --disable-nls \
  --disable-static \
  --disable-su \
  --disable-runuser \
  --disable-libcryptsetup \
  --without-cryptsetup \
  --without-systemd \
  --without-systemdsystemunitdir \
  --disable-makeinstall-chown \
  --disable-makeinstall-setuid \
  --disable-mountpoint \
  --disable-pylibmount \
  --without-python \
  --without-readline \
  --without-libmagic \
  --without-audit \
  --without-selinux \
  --without-utempter \
  --without-econf \
  --without-btrfs \
  --without-tinfo \
  --disable-asciidoc \
  --disable-rpath \
  --disable-liblastlog2 \
  --without-zlib \
  --without-libiconv-prefix \
  --without-libintl-prefix \
  >/tmp/r7-build/util-linux-configure.log 2>&1
echo "configure rc=$?"
tail -3 /tmp/r7-build/util-linux-configure.log
make -j$(nproc) >/tmp/r7-build/util-linux-make.log 2>&1
echo "make rc=$?"
make install >/tmp/r7-build/util-linux-install.log 2>&1
echo "install rc=$?"
ls /tmp/r7-build/util-linux/bin /tmp/r7-build/util-linux/sbin 2>&1

# ---- A3 P5 cache postlude (auto-wired) ----
if [ -n "${CACHE_KEY_HEX:-}" ]; then
  cache_phase_publish "${OUT_ABS}" || true
fi
# ---- /A3 P5 cache postlude -------------------
