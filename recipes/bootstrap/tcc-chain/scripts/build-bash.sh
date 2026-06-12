#!/bin/sh
set -e
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf bash-5.3
tar xf bash-5.3.tar.gz
cd bash-5.3
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
export CFLAGS='-DSYS_BASHRC=\"/etc/bashrc\" -DSYS_BASH_LOGOUT=\"/etc/bash_logout\" -DNON_INTERACTIVE_LOGIN_SHELLS -DSSH_SOURCE_BASHRC'
./configure --prefix=/tmp/r7-build/bash --without-bash-malloc --disable-readline --disable-nls
make -j$(nproc)
make install
echo "OK"
ls /tmp/r7-build/bash/bin/
