#!/bin/sh
set -e
# ---- A3 P5 cache prelude (auto-wired) ----
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="/tmp/r7-build/bash"
__R7_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${BASH_SOURCE[0]}" "$OUT_ABS" \
      --package-name=bash \
      --package-version=5.2 \
      --toolchain-name=gcc-wrapper \
      --toolchain-version=1.0
    echo "[cache] bash cache-entry-key=${CACHE_KEY_HEX}"
    echo "${CACHE_KEY_HEX}" > "$OUT_ABS/.cache-key.hex"
    if [ "${CACHE_HIT}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] bash from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${CACHE_HIT}" = "2" ]; then
      echo "[cache] bash: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
# ---- /A3 P5 cache prelude --------------------
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

# ---- A3 P5 cache postlude (auto-wired) ----
if [ -n "${CACHE_KEY_HEX:-}" ]; then
  cache_phase_publish "${OUT_ABS}" || true
fi
# ---- /A3 P5 cache postlude -------------------
