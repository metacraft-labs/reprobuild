#!/bin/sh
set -e
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf libxcrypt-4.5.2
tar xf libxcrypt-4.5.2.tar.xz
cd libxcrypt-4.5.2
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
./configure \
  --prefix=/tmp/r7-build/libxcrypt \
  --disable-static \
  --enable-hashes=strong,glibc \
  --enable-obsolete-api=glibc \
  --disable-failure-tokens \
  >/tmp/r7-build/libxcrypt-configure.log 2>&1
echo "configure rc=$?"
make -j$(nproc) >/tmp/r7-build/libxcrypt-make.log 2>&1
echo "make rc=$?"
make install >/tmp/r7-build/libxcrypt-install.log 2>&1
echo "install rc=$?"
ls /tmp/r7-build/libxcrypt/lib /tmp/r7-build/libxcrypt/include 2>&1
