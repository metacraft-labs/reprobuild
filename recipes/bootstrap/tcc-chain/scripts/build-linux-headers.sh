#!/bin/bash
# build-linux-headers.sh -- R6 Phase 1: linux 6.18.7 sanitised kernel headers.
#
# Ports nixpkgs's pkgs/os-specific/linux/kernel-headers/default.nix.
# glibc needs sanitised <asm/...> + <linux/...> headers; the upstream
# kernel ships `make headers_install` for exactly this.  We don't build
# any kernel code -- just the userspace-facing header tree.
#
# Inputs (positional):
#   $1 = vendor dir   (must contain linux-6.18.7.tar.xz)
#   $2 = output dir   (will contain include/{asm,linux,...} after success)
#
# Toolchain: builds with the *host* gcc (Debian 12's gcc-12).  The kernel
# headers_install target is plain-C + sh + perl + rsync, none of which
# touch the R5-produced gcc chain; using R5's gcc 15.2 here would just
# add risk for zero benefit (the output is sanitized .h files; no compiled
# code).
#
# Wall-clock budget: ~30 s (headers_install is tiny vs. a full kernel build).

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: $0 VENDOR OUT}"
OUT="${2:?usage: $0 VENDOR OUT}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

log() { echo "[linux-headers] $*"; }
log "VENDOR=$VENDOR_ABS"
log "OUT=$OUT_ABS"

SRC="$VENDOR_ABS/linux-6.18.7.tar.xz"
[ -f "$SRC" ] || { echo "[linux-headers] ERROR: missing $SRC" >&2; exit 1; }

WORK="$(mktemp -d -t reproos-r6-linux-headers-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[linux-headers] keeping WORK=$WORK for debug (rc=$rc)" >&2; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack linux-6.18.7.tar.xz"
tar -xf "$SRC"
cd linux-6.18.7

log "Stage 2: make headers (ARCH=x86_64)"
# Per nixpkgs/kernel-headers/default.nix:
#   - cc-version / cc-fullversion stubs (avoid host compiler probes)
#   - HOST_LFS_CFLAGS=-D_FILE_OFFSET_BITS=64 (avoid getconf in early bootstrap)
#   - HOSTCC=$(CC_FOR_BUILD) (already the default in our case)
#
# The order is: mrproper -> headers -> headers_install.
make ARCH=x86_64 \
     HOSTCC=gcc \
     "cc-version:=9999" \
     "cc-fullversion:=999999" \
     "HOST_LFS_CFLAGS=-D_FILE_OFFSET_BITS=64" \
     mrproper >/dev/null

make ARCH=x86_64 \
     HOSTCC=gcc \
     "cc-version:=9999" \
     "cc-fullversion:=999999" \
     "HOST_LFS_CFLAGS=-D_FILE_OFFSET_BITS=64" \
     -j"$(nproc)" \
     headers 2>&1 | tee "$WORK/headers.log" | tail -10

log "Stage 3: headers_install -> $OUT_ABS"
rm -rf "$OUT_ABS/include"
make ARCH=x86_64 \
     INSTALL_HDR_PATH="$OUT_ABS" \
     -j"$(nproc)" \
     headers_install 2>&1 | tee "$WORK/install.log" | tail -10

# Per nixpkgs (cp -r usr/include $out): drop anything non-.h.
find "$OUT_ABS" -type f \! -name '*.h' -delete

# Some builds want a kernel.release.
mkdir -p "$OUT_ABS/include/config"
echo "6.18.7-reproos-r6" > "$OUT_ABS/include/config/kernel.release"

if [ ! -d "$OUT_ABS/include/asm" ] || [ ! -d "$OUT_ABS/include/linux" ]; then
  echo "[linux-headers] ERROR: missing asm/ or linux/ subdir under $OUT_ABS/include" >&2
  ls -la "$OUT_ABS/include" >&2 || true
  exit 1
fi

log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R6 Phase 1 (linux 6.18.7 headers) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  printf "# Top-level subdirs:\n"
  for d in include/*/; do
    printf "#   %s (%d files)\n" "$d" \
      "$(find "$d" -type f -name '*.h' | wc -l)"
  done
  total_files=$(find include -type f -name '*.h' | wc -l)
  total_size=$(find include -type f -name '*.h' -printf '%s\n' | awk '{s+=$1} END {print s}')
  printf "# total: %d .h files, %d bytes\n" "$total_files" "$total_size"
  printf "# spot-check sha256 of key headers:\n"
  for f in include/asm/unistd.h \
           include/asm/unistd_64.h \
           include/linux/version.h \
           include/linux/types.h \
           include/asm-generic/unistd.h; do
    if [ -f "$f" ]; then
      printf "%-44s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "linux 6.18.7 headers ready at $OUT_ABS"
