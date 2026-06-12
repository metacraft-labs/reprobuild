#!/bin/sh
set -e
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
