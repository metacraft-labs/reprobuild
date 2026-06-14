#!/bin/bash
# build-linux-kernel.sh -- R8: Linux 6.6.142 LTS bootable bzImage for
# Hyper-V Gen-2 UEFI.
#
# Builds a minimal x86_64 kernel suitable for a Hyper-V Gen-2 UEFI VM
# with serial console output on COM1 (ttyS0). The kernel is freestanding
# C — does not link against glibc — so using the host gcc is
# ideologically acceptable for R8 (R9 will need our bootstrapped glibc
# for systemd; the kernel doesn't).
#
# Inputs (positional):
#   $1 = vendor dir   (must contain linux-6.6.142.tar.xz)
#   $2 = config file  (the x86_64-hyperv .config snapshot)
#   $3 = output dir   (will contain bzImage + System.map + KERNELRELEASE + SHA256SUMS)
#
# Required env (all set by the recipe driver; defaulted here for manual repros):
#   SOURCE_DATE_EPOCH      = 1735689600 (2025-01-01T00:00:00Z)
#   KBUILD_BUILD_TIMESTAMP = "2025-01-01 00:00:00 UTC"
#   KBUILD_BUILD_USER      = reproos
#   KBUILD_BUILD_HOST      = reproos
#   KBUILD_BUILD_VERSION   = 1
#   LC_ALL                 = C
#   TZ                     = UTC
#
# Wall-clock budget: ~10-15 min on 8+ cores for the minimal config.
#
# Reproducibility notes:
#   - The Linux build system honours SOURCE_DATE_EPOCH for embedded
#     timestamps (Documentation/kbuild/reproducible-builds.rst).
#   - Embedded build-host strings come from KBUILD_BUILD_{USER,HOST};
#     pinning both removes the host-name leak in the kernel's
#     `linux_banner[]`.
#   - Embedded source paths: the build copies the kernel tree into a
#     fixed-path workdir (/tmp/reproos-r8-linux-build/linux-6.6.142) so
#     __FILE__ macros + DWARF source paths land at deterministic
#     locations. Use `KEEP_WORK=1` to inspect the workdir on failure;
#     otherwise it's removed on success.
#   - Modules: the config below sets every required driver as `=y`
#     (built-in), so we do NOT build or install any `.ko` modules. The
#     bzImage is self-sufficient for a Hyper-V Gen-2 boot.

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${KBUILD_BUILD_TIMESTAMP:=2025-01-01 00:00:00 UTC}"
: "${KBUILD_BUILD_USER:=reproos}"
: "${KBUILD_BUILD_HOST:=reproos}"
: "${KBUILD_BUILD_VERSION:=1}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_USER \
       KBUILD_BUILD_HOST KBUILD_BUILD_VERSION LC_ALL TZ

VENDOR="${1:?usage: $0 VENDOR CONFIG OUT}"
CONFIG="${2:?usage: $0 VENDOR CONFIG OUT}"
OUT="${3:?usage: $0 VENDOR CONFIG OUT}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
CONFIG_ABS="$(readlink -f "$CONFIG")"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"
# ---- A3 P5 cache prelude (auto-wired) ----

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../../../.." && pwd)"
# shellcheck source=/dev/null
source "${_repo_root}/recipes/cache/scripts/cache-helper.sh"

if cache_repro_binary_cache_client_bin >/dev/null 2>&1; then
  _phase_deps=()
  _depfile="${CC_WRAPPER_ABS%/bin}/.cache-key.hex"
  if [[ -f "${_depfile}" ]]; then
    _phase_deps+=( --dep="$(cat "${_depfile}")" )
  fi
  cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
    --package-name=linux-kernel \
    --package-version=6.6.142 \
    --toolchain-name=gcc-wrapper \
    --toolchain-version=1.0 \
    "${_phase_deps[@]}"
  echo "[cache] linux-kernel cache-entry-key=${CACHE_KEY_HEX}"
  echo "${CACHE_KEY_HEX}" > "${OUT_ABS}/.cache-key.hex"
  if [[ "${CACHE_HIT}" == "1" ]]; then
    if [[ -d "${OUT_ABS}/prefix" ]]; then
      cp -a "${OUT_ABS}/prefix/." "${OUT_ABS}/"
      rm -rf "${OUT_ABS}/prefix"
      echo "[cache hit] linux-kernel from cache"
      exit 0
    fi
    rm -rf "${OUT_ABS}/prefix"
  elif [[ "${CACHE_HIT}" == "2" ]]; then
    echo "[cache] linux-kernel: REPRO_CACHE_DRY_RUN=1; skipping build."
    exit 0
  fi
fi
# ---- /A3 P5 cache prelude --------------------

log() { echo "[kernel] $*"; }
log "VENDOR=$VENDOR_ABS"
log "CONFIG=$CONFIG_ABS"
log "OUT=$OUT_ABS"
log "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
log "KBUILD_BUILD_TIMESTAMP=$KBUILD_BUILD_TIMESTAMP"
log "KBUILD_BUILD_USER=$KBUILD_BUILD_USER"
log "KBUILD_BUILD_HOST=$KBUILD_BUILD_HOST"

SRC="$VENDOR_ABS/linux-6.6.142.tar.xz"
[ -f "$SRC" ] || { echo "[kernel] ERROR: missing $SRC" >&2; exit 1; }
[ -f "$CONFIG_ABS" ] || { echo "[kernel] ERROR: missing config $CONFIG_ABS" >&2; exit 1; }

# Fixed workdir for path determinism (DWARF source paths embed the
# absolute build dir).
WORK="/tmp/reproos-r8-linux-build"
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[kernel] keeping WORK=$WORK for debug (rc=$rc)" >&2; else rm -rf "$WORK"; fi' EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
log "WORK=$WORK"
cd "$WORK"

log "Stage 1: unpack linux-6.6.142.tar.xz"
tar -xf "$SRC"
cd linux-6.6.142

log "Stage 2: install pinned .config from $CONFIG_ABS"
cp "$CONFIG_ABS" .config

# `make olddefconfig` accepts the pinned .config and fills any new
# options with their default values; this also normalises the
# CONFIG_GCC_VERSION line to match the host gcc, which is expected to
# drift between hosts and is therefore EXCLUDED from the reproducibility
# claim. (The kernel image bytes still depend on the gcc major version;
# pinning gcc 11.x produces stable bytes.)
log "Stage 3: olddefconfig (fill new defaults if any)"
make ARCH=x86_64 olddefconfig >/dev/null

log "Stage 4: build bzImage (-j$(nproc))"
make ARCH=x86_64 -j"$(nproc)" bzImage 2>&1 | tee "$WORK/build.log" | tail -20

# Sanity: bzImage must exist and be > 1 MiB.
[ -f arch/x86/boot/bzImage ] || { echo "[kernel] ERROR: bzImage not produced" >&2; exit 1; }
sz=$(stat -c %s arch/x86/boot/bzImage)
if [ "$sz" -lt 1048576 ]; then
  echo "[kernel] ERROR: bzImage too small ($sz bytes); expected >= 1 MiB" >&2
  exit 1
fi
log "bzImage produced ($sz bytes)"

# Sanity: must be a PE/COFF (EFI stub) image — first 2 bytes "MZ".
mz=$(head -c 2 arch/x86/boot/bzImage | od -An -c | tr -d ' ')
if [ "$mz" != "MZ" ]; then
  echo "[kernel] WARN: bzImage first 2 bytes are '$mz', not 'MZ'; EFI stub may be disabled" >&2
fi

log "Stage 5: stage outputs into $OUT_ABS"
mkdir -p "$OUT_ABS"
cp arch/x86/boot/bzImage "$OUT_ABS/bzImage"
cp System.map "$OUT_ABS/System.map"
make -s ARCH=x86_64 kernelrelease > "$OUT_ABS/KERNELRELEASE"
cp .config "$OUT_ABS/config-used"

# Capture the linux_banner — useful for tracing reproducibility hazards
# (timestamps/usernames embedded by the build).
strings -a "$OUT_ABS/bzImage" | grep -E '^Linux version 6\.6\.142' > "$OUT_ABS/linux_banner.txt" || true

# Embedded-path leak audit: anything under /tmp or /home that survived
# into the bzImage is a reproducibility hazard.
{
  echo "# Embedded-path leak audit of bzImage (R8 reproducibility check)."
  echo "# Generated by build-linux-kernel.sh on $(date -u --date=@$SOURCE_DATE_EPOCH '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "## /tmp leaks:"
  strings -a "$OUT_ABS/bzImage" | grep -E '/tmp/' | sort -u || echo "  (none)"
  echo
  echo "## /home leaks:"
  strings -a "$OUT_ABS/bzImage" | grep -E '/home/' | sort -u || echo "  (none)"
  echo
  echo "## host-user / host-name leaks (should match KBUILD_BUILD_USER/HOST = reproos):"
  strings -a "$OUT_ABS/bzImage" | grep -E '^Linux version' || true
} > "$OUT_ABS/PATH_LEAK_AUDIT.txt"

log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R8 (linux 6.6.142 bzImage) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  printf "# KBUILD_BUILD_USER=%s KBUILD_BUILD_HOST=%s\n" \
    "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST"
  printf "# KERNELRELEASE=%s\n" "$(cat KERNELRELEASE)"
  printf "\n"
  for f in bzImage System.map config-used KERNELRELEASE linux_banner.txt; do
    if [ -f "$f" ]; then
      printf "%-32s %12d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/PATH_LEAK_AUDIT.txt"

log "linux 6.6.142 bzImage ready at $OUT_ABS/bzImage"

# ---- A3 P5 cache postlude (auto-wired) ----
if [[ -n "${CACHE_KEY_HEX:-}" ]]; then
  cache_phase_publish "${OUT_ABS}"
fi
# ---- /A3 P5 cache postlude -------------------
