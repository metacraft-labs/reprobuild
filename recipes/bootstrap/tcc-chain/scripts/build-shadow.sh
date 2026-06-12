#!/bin/sh
set -e
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
