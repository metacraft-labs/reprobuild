#!/bin/sh
set -e
# ---- A3 P5 cache prelude (auto-wired) ----
# Hardcoded-prefix R7+ wiring: prefix derived from --prefix= line.
__R7_OUT_ABS="/tmp/r7-build/coreutils"
__R7_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd 2>/dev/null || echo "")"
if [ -n "$__R7_REPO_ROOT" ] && [ -f "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh" ]; then
  # shellcheck source=/dev/null
  . "$__R7_REPO_ROOT/recipes/cache/scripts/cache-helper.sh"
  if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
    OUT_ABS="$__R7_OUT_ABS"
    mkdir -p "$OUT_ABS"
    cache_phase_prepare "${BASH_SOURCE[0]}" "$OUT_ABS" \
      --package-name=coreutils \
      --package-version=9.5 \
      --toolchain-name=gcc-wrapper \
      --toolchain-version=1.0
    echo "[cache] coreutils cache-entry-key=${CACHE_KEY_HEX}"
    echo "${CACHE_KEY_HEX}" > "$OUT_ABS/.cache-key.hex"
    if [ "${CACHE_HIT}" = "1" ]; then
      if [ -d "$OUT_ABS/prefix" ]; then
        cp -a "$OUT_ABS/prefix/." "$OUT_ABS/"
        rm -rf "$OUT_ABS/prefix"
        echo "[cache hit] coreutils from cache"
        exit 0
      fi
      rm -rf "$OUT_ABS/prefix"
    elif [ "${CACHE_HIT}" = "2" ]; then
      echo "[cache] coreutils: REPRO_CACHE_DRY_RUN=1; skipping build."
      exit 0
    fi
  fi
fi
# ---- /A3 P5 cache prelude --------------------
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

# ---- A3 P5 cache postlude (auto-wired) ----
if [ -n "${CACHE_KEY_HEX:-}" ]; then
  cache_phase_publish "${OUT_ABS}" || true
fi
# ---- /A3 P5 cache postlude -------------------
