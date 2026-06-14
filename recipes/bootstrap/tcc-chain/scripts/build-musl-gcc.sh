#!/bin/bash
# build-musl-gcc.sh -- R5 Phase E.5: rebuild musl 1.2.6 with gcc 4.6.4 Stage A.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/musl/default.nix.
#
# Result: $OUT/{include,lib,bin} -- musl libc with BOTH static libc.a AND
# shared libc.so (the latter is what gcc 4.6.4 Stage B's CC=... -Wl,
# -dynamic-linker -Wl,$musl/lib/libc.so flag points at).
#
# Inputs (positional):
#   $1 = vendor dir       (musl-1.2.6.tar.gz)
#   $2 = gcc 4.6.4 dir    (gcc Stage A output -- $gcc46/bin/gcc, etc.)
#   $3 = binutils dir     (binutils-final -- $bin/bin/{ld,as,ar,...})
#   $4 = tinycc-musl dir  (tinycc-musl-final, for tinycc-musl sysroot to
#                          satisfy gcc's --sysroot when xgcc compiles musl
#                          test sources)
#   $5 = output dir

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage}"
GCC46="${2:?usage}"
BINUTILS="${3:?usage}"
TINYCC_MUSL="${4:?usage}"
OUT="${5:?usage}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
GCC46_ABS="$(cd "$GCC46" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
TINYCC_MUSL_ABS="$(cd "$TINYCC_MUSL" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${GCC_4_6_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  _depfile="${MUSL_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=musl-gcc \
    --package-version=1.2.5 \
    --toolchain-name=gcc \
    --toolchain-version=4.6.4 \
    "${_phase_deps[@]}"
  echo "[cache] musl-gcc cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] musl-gcc from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] musl-gcc: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[musl-gcc] $*"; }
log "VENDOR=$VENDOR_ABS"
log "GCC46=$GCC46_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "TINYCC_MUSL=$TINYCC_MUSL_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/musl-1.2.6.tar.gz" \
         "$GCC46_ABS/bin/gcc" \
         "$BINUTILS_ABS/bin/ld" \
         "$BINUTILS_ABS/bin/as" \
         "$TINYCC_MUSL_ABS/include/stdio.h"; do
  [ -e "$f" ] || { echo "[musl-gcc] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-muslgcc-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[musl-gcc] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack musl 1.2.6"
tar -xzf "$VENDOR_ABS/musl-1.2.6.tar.gz"
cd musl-1.2.6

log "Stage 2: patches per nixpkgs musl/default.nix"
# tools/*.sh: /bin/sh -> host bash
for f in tools/*.sh; do
  if [ -f "$f" ]; then
    sed -i 's|/bin/sh|/bin/bash|' "$f"
  fi
done
# popen/system/wordexp hardcode /bin/sh
sed -i 's|posix_spawn(&pid, "/bin/sh",|posix_spawnp(\&pid, "sh",|' \
  src/stdio/popen.c src/process/system.c
sed -i 's|execl("/bin/sh", "sh", "-c",|execlp("sh", "-c",|' \
  src/misc/wordexp.c

# Put binutils first on PATH so configure finds our ld/as/ar (not host's).
export PATH="$BINUTILS_ABS/bin:$GCC46_ABS/bin:$PATH"

# Stage-A gcc needs --sysroot to find headers/libs at compile-time.
# CC is gcc with sysroot pinned at tinycc-musl-final (which provides
# musl headers + static lib + crt files — exactly what musl needs to
# compile itself with).
export CC="$GCC46_ABS/bin/gcc --sysroot=$TINYCC_MUSL_ABS -isystem $TINYCC_MUSL_ABS/include -B $TINYCC_MUSL_ABS/lib"

log "Stage 3: configure (shared + static, enable-wrapper for musl-gcc)"
bash ./configure \
  --prefix="$OUT_ABS" \
  --build=x86_64-pc-linux-musl \
  --host=x86_64-pc-linux-musl \
  --syslibdir="$OUT_ABS/lib" \
  --enable-wrapper \
  2>&1 | tee "$WORK/configure.log" | tail -30

log "Stage 4: make -j$(nproc)"
make -j"$(nproc)" 2>&1 | tee "$WORK/make.log" | tail -20 || {
  echo "[musl-gcc] ERROR: make failed; tail:" >&2
  tail -80 "$WORK/make.log" >&2
  exit 1
}

log "Stage 5: make install"
make install 2>&1 | tee "$WORK/install.log" | tail -10

# Repoint shipped scripts (musl-gcc, etc.) at host bash.
for f in "$OUT_ABS"/bin/*; do
  if [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q '^#!.*sh'; then
    sed -i 's|/bin/sh|/bin/bash|' "$f"
  fi
done
# Create ldd symlink per nixpkgs.
if [ -e "$OUT_ABS/lib/libc.so" ] && [ ! -e "$OUT_ABS/bin/ldd" ]; then
  ln -sf ../lib/libc.so "$OUT_ABS/bin/ldd"
fi

# Sanity: shared libc.so must exist (this is the whole point).
for f in lib/libc.a lib/libc.so include/stdio.h; do
  if [ ! -e "$OUT_ABS/$f" ]; then
    echo "[musl-gcc] ERROR: install missing $f" >&2
    exit 1
  fi
done

# SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase E.5 (musl 1.2.6 / gcc 4.6.4 Stage A) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in lib/libc.a lib/libc.so lib/crt1.o lib/crti.o lib/crtn.o \
           lib/Scrt1.o lib/rcrt1.o bin/musl-gcc bin/ldd; do
    if [ -f "$f" ] || [ -L "$f" ]; then
      sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
      sh=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || echo missing)
      printf "%-20s %10d  %s\n" "$f" "$sz" "$sh"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "musl (gcc-built) ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
