#!/bin/sh
set -e
export SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
export PATH=/tmp/r7-build/wrapper/bin:/tmp/r5-build/binutils-final/bin:/usr/bin:/bin
cd /tmp/r7-src
rm -rf Linux-PAM-1.5.3
tar xf Linux-PAM-1.5.3.tar.xz
cd Linux-PAM-1.5.3
# Make examples a no-op subdirectory (uses ancient SysV termio.h not in glibc 2.42)
sed -i 's|SUBDIRS = libpam libpamc libpam_misc modules po doc examples tests xtests|SUBDIRS = libpam libpamc libpam_misc modules po tests|' Makefile.am
# Remove "examples" + "doc" + "xtests" from configure-generated Makefile.in too
sed -i 's| examples | |g; s| doc | |g; s| xtests | |g' Makefile.in
# Replace termio.h with termios.h (modern glibc removed termio.h) (safety belt)
sed -i 's|<termio\.h>|<termios.h>|g' examples/tty_conv.c || true
# Patch opasswd.c: scope of int retval is too narrow — fix by emitting always
python3 -c "
import re
p='modules/pam_pwhistory/opasswd.c'
src=open(p).read()
new=src.replace('  char *outval;\n#ifdef HAVE_CRYPT_R\n  struct crypt_data output;\n  int retval;\n','  char *outval;\n  int retval;\n#ifdef HAVE_CRYPT_R\n  struct crypt_data output;\n')
assert new != src, 'patch did not apply'
open(p,'w').write(new)
print('patched OK')
"
export CC=/tmp/r7-build/wrapper/bin/gcc-glibc
export CPPFLAGS="-I/tmp/r7-build/libxcrypt/include"
export LDFLAGS="-L/tmp/r7-build/libxcrypt/lib -Wl,-rpath,/tmp/r7-build/libxcrypt/lib"
export CRYPT_CFLAGS="-I/tmp/r7-build/libxcrypt/include"
export CRYPT_LIBS="-L/tmp/r7-build/libxcrypt/lib -Wl,-rpath,/tmp/r7-build/libxcrypt/lib -lcrypt"
./configure \
  --prefix=/tmp/r7-build/pam \
  --sysconfdir=/etc \
  --includedir=/tmp/r7-build/pam/include/security \
  --disable-nls \
  --disable-doc \
  --disable-prelude \
  --disable-audit \
  --disable-selinux \
  --disable-regenerate-docu \
  --disable-econf \
  --enable-db=no \
  --disable-pam_userdb \
  --disable-nis \
  --disable-Werror \
  >/tmp/r7-build/pam-configure.log 2>&1
echo "configure rc=$?"
tail -3 /tmp/r7-build/pam-configure.log
make -j$(nproc) >/tmp/r7-build/pam-make.log 2>&1
echo "make rc=$?"
make install >/tmp/r7-build/pam-install.log 2>&1
echo "install rc=$?"
ls /tmp/r7-build/pam/sbin 2>&1
ls /tmp/r7-build/pam/lib 2>&1 | head -20
ls /tmp/r7-build/pam/lib/security 2>&1 | head -20
