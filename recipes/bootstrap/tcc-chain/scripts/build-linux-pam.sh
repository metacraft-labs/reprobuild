#!/bin/sh
set -e
# ---- A3 P5 cache prelude (auto-wired) ----
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="/tmp/r7-build/pam"
__R7_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${BASH_SOURCE[0]}" "$OUT_ABS" \
      --package-name=linux-pam \
      --package-version=1.6 \
      --toolchain-name=gcc-wrapper \
      --toolchain-version=1.0
    echo "[cache] linux-pam cache-entry-key=${CACHE_KEY_HEX}"
    echo "${CACHE_KEY_HEX}" > "$OUT_ABS/.cache-key.hex"
    if [ "${CACHE_HIT}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] linux-pam from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${CACHE_HIT}" = "2" ]; then
      echo "[cache] linux-pam: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
# ---- /A3 P5 cache prelude --------------------
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

# ---- A3 P5 cache postlude (auto-wired) ----
if [ -n "${CACHE_KEY_HEX:-}" ]; then
  cache_phase_publish "${OUT_ABS}" || true
fi
# ---- /A3 P5 cache postlude -------------------
