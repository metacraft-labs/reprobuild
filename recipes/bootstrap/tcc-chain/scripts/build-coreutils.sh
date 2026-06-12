#!/bin/sh
set -e
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf coreutils-9.11
tar xf coreutils-9.11.tar.xz
cd coreutils-9.11
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
# coreutils requires fseeko detection workaround when ./configure compiles autoconf tests using -Werror
export FORCE_UNSAFE_CONFIGURE=1
./configure --prefix=/tmp/r7-build/coreutils --enable-no-install-program=kill,uptime --disable-nls 2>&1 | tail -10
make -j$(nproc)
make install
echo OK
ls /tmp/r7-build/coreutils/bin | head -30
