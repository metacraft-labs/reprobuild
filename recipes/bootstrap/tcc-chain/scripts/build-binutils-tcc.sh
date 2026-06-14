#!/bin/bash
# build-binutils-tcc.sh -- R5 Phase D: build binutils 2.46.0 with tinycc-musl.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/binutils/default.nix.
# Output: $OUT/{bin,lib,include}/ with ld, as, ar, etc.
#
# Inputs (positional):
#   $1 = vendor dir         (with binutils-2.46.0.tar.xz)
#   $2 = patches dir        (deterministic.patch + fix-tinycc-attribute.patch)
#   $3 = tinycc-musl dir    (R5 Phase C output -- bin/tcc + lib/ + include/)
#   $4 = output dir         (will hold bin/ + lib/ + SHA256SUMS)

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-binutils-tcc.sh <vendor> <patches> <tinycc-musl> <out>}"
PATCHES="${2:?usage: build-binutils-tcc.sh <vendor> <patches> <tinycc-musl> <out>}"
TINYCC_MUSL="${3:?usage: build-binutils-tcc.sh <vendor> <patches> <tinycc-musl> <out>}"
OUT="${4:?usage: build-binutils-tcc.sh <vendor> <patches> <tinycc-musl> <out>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
PATCHES_ABS="$(cd "$PATCHES" && pwd)"
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
  _depfile="${TINYCC_MUSL_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=binutils \
    --package-version=2.46.0 \
    --toolchain-name=tinycc-musl \
    --toolchain-version=0.9.27 \
    "${_phase_deps[@]}"
  echo "[cache] binutils cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] binutils from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] binutils: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[binutils-tcc] $*"; }
log "VENDOR=$VENDOR_ABS"
log "PATCHES=$PATCHES_ABS"
log "TINYCC_MUSL=$TINYCC_MUSL_ABS"
log "OUT=$OUT_ABS"

for f in "$VENDOR_ABS/binutils-2.46.0.tar.xz" \
         "$PATCHES_ABS/deterministic.patch" \
         "$PATCHES_ABS/fix-tinycc-attribute.patch" \
         "$TINYCC_MUSL_ABS/bin/tcc" \
         "$TINYCC_MUSL_ABS/lib/libtcc1.a" \
         "$TINYCC_MUSL_ABS/include/stdio.h"; do
  [ -e "$f" ] || { echo "[binutils-tcc] ERROR: missing $f" >&2; exit 1; }
done

WORK="$(mktemp -d -t reproos-r5-binutils-XXXXXX)"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[binutils-tcc] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack binutils 2.46.0"
tar -xf "$VENDOR_ABS/binutils-2.46.0.tar.xz"
cd binutils-2.46.0

log "Stage 2: apply patches"
patch -Np1 -i "$PATCHES_ABS/deterministic.patch" || true  # ldlang.c -- may not exist
patch -Np1 -i "$PATCHES_ABS/fix-tinycc-attribute.patch"

# Tooling fixes per nixpkgs.
log "Stage 2b: fix /bin/sh references"
sed -i 's|/bin/sh|/bin/bash|' missing install-sh mkinstalldirs 2>/dev/null || true
# libtool fix
sed -i 's/| $NL2SP/| sort | $NL2SP/' ltmain.sh 2>/dev/null || true

# alias makeinfo to true (we don't have makeinfo).
mkdir -p aliases
ln -sf /bin/true aliases/makeinfo
export PATH="$(pwd)/aliases:$PATH"

log "Stage 3: configure"
# tinycc-musl's tcc has musl-include baked in via CONFIG_TCC_SYSINCLUDEPATHS,
# so a bare `tcc` works (no -nostdinc needed -- baked includes resolve).
# We still need -B for libtcc1.a.
export CC="$TINYCC_MUSL_ABS/bin/tcc -B $TINYCC_MUSL_ABS/lib"
export AR="$TINYCC_MUSL_ABS/bin/tcc -B $TINYCC_MUSL_ABS/lib -ar"
export RANLIB=true
export lt_cv_sys_max_cmd_len=32768
export CFLAGS="-D__LITTLE_ENDIAN__=1"

bash ./configure \
  --prefix="$OUT_ABS" \
  --build=x86_64-pc-linux-musl \
  --host=x86_64-pc-linux-musl \
  --with-sysroot=/ \
  --disable-dependency-tracking \
  --disable-nls \
  --enable-deterministic-archives \
  --disable-gprofng \
  --enable-new-dtags \
  --with-lib-path=: \
  2>&1 | tee "$WORK/configure.log" | tail -20

log "Stage 4: make all-libiberty all-gas all-bfd all-libctf all-zlib all-gprof"
# Serial build (parallel under tcc is unstable per nixpkgs note).
make all-libiberty all-gas all-bfd all-libctf all-zlib all-gprof 2>&1 | \
  tee "$WORK/make1.log" | tail -20 || {
  echo "[binutils-tcc] ERROR: make all-libiberty/etc failed"
  tail -60 "$WORK/make1.log" >&2
  exit 1
}

log "Stage 5: make all-ld"
make all-ld 2>&1 | tee "$WORK/make2.log" | tail -20 || {
  echo "[binutils-tcc] ERROR: make all-ld failed"
  tail -60 "$WORK/make2.log" >&2
  exit 1
}

log "Stage 6: make (remaining)"
make 2>&1 | tee "$WORK/make3.log" | tail -20 || {
  echo "[binutils-tcc] ERROR: make failed"
  tail -60 "$WORK/make3.log" >&2
  exit 1
}

log "Stage 7: make install"
make install 2>&1 | tee "$WORK/install.log" | tail -20

# Verify ld, as, ar exist.
for tool in ld as ar nm ranlib strip; do
  if [ ! -x "$OUT_ABS/bin/$tool" ]; then
    echo "[binutils-tcc] WARN: missing $OUT_ABS/bin/$tool"
  fi
done

# Smoke test: ld --version
if [ -x "$OUT_ABS/bin/ld" ]; then
  log "  ld version: $("$OUT_ABS/bin/ld" --version | head -1)"
fi
if [ -x "$OUT_ABS/bin/as" ]; then
  log "  as version: $("$OUT_ABS/bin/as" --version | head -1)"
fi

# SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase D (binutils-2.46.0 / tinycc-musl) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s LC_ALL=%s TZ=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH" "$LC_ALL" "$TZ"
  for tool in ld as ar nm ranlib strip objcopy objdump readelf; do
    f="bin/$tool"
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "binutils-tcc ready at $OUT_ABS"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
