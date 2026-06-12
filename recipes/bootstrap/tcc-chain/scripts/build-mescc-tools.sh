#!/bin/bash
# build-mescc-tools.sh — Phase 4 (R4c): build the C-rewritten mescc-tools
# binaries on top of stage0-posix.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/
# mescc-tools/{default.nix,build.kaem}. After stage0-posix's
# bootstrapped M2/M1/hex2/blood-elf-0/kaem-unwrapped, this step:
#
#   1. Builds 4 mescc-tools-extra utility binaries (mkdir, cp, chmod,
#      replace) so the kaem build script can use them like nix's
#      ${mkdir} ${cp} ${chmod} ${replace} input refs.
#   2. Runs build.kaem (lifted from nixpkgs) which produces:
#         M2-Mesoplanet, blood-elf (final), get_machine, M2-Planet (C-rewritten)
#      and re-installs M2, M1, hex2 as the canonical bootstrap-tools set.
#
# Inputs (positional):
#   $1 = vendor dir (containing minimal-bootstrap-sources.tar.gz)
#   $2 = stage0 dir (with hex0..kaem-unwrapped from build-stage0-posix.sh)
#   $3 = output dir (will hold mescc-tools binaries + mescc-tools-extra)
#
# Required env: SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-mescc-tools.sh <vendor-dir> <stage0-dir> <out-dir>}"
STAGE0="${2:?usage: build-mescc-tools.sh <vendor-dir> <stage0-dir> <out-dir>}"
OUT="${3:?usage: build-mescc-tools.sh <vendor-dir> <stage0-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
STAGE0_ABS="$(cd "$STAGE0" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

WORK="$(mktemp -d -t reproos-r4c-mescc-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "[mescc-tools] WORK=$WORK"

tar -xzf "$VENDOR_ABS/minimal-bootstrap-sources.tar.gz" -C "$WORK"
SRC="$WORK/stage0-posix"
M2LIBC="$SRC/M2libc"

# AMD64 platform pins
M2_ARCH=amd64
ENDIAN_FLAG=--little-endian
BLOOD_FLAGS=--64
BASE_ADDR=0x00600000

# Stage0 binaries
M2="$STAGE0_ABS/M2"
M1="$STAGE0_ABS/M1"
HEX2="$STAGE0_ABS/hex2"
BLOOD_ELF_0="$STAGE0_ABS/blood-elf-0"
KAEM_UNWRAPPED="$STAGE0_ABS/kaem-unwrapped"

for bin in "$M2" "$M1" "$HEX2" "$BLOOD_ELF_0" "$KAEM_UNWRAPPED"; do
  if [ ! -x "$bin" ]; then
    echo "[mescc-tools] ERROR: missing stage0 binary $bin" >&2
    exit 1
  fi
done

log() { echo "[mescc-tools] $*"; }

mkdir -p "$OUT_ABS/bin"

# Build one mescc-tools-extra utility binary
build_extra() {
  local name="$1"
  log "extra: $name"
  cd "$WORK"
  "$M2" --architecture "$M2_ARCH" \
    -f "$M2LIBC/sys/types.h" \
    -f "$M2LIBC/stddef.h" \
    -f "$M2LIBC/sys/utsname.h" \
    -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
    -f "$M2LIBC/fcntl.c" \
    -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
    -f "$M2LIBC/$M2_ARCH/linux/sys/stat.c" \
    -f "$M2LIBC/ctype.c" \
    -f "$M2LIBC/stdlib.c" \
    -f "$M2LIBC/stdarg.h" \
    -f "$M2LIBC/stdio.h" \
    -f "$M2LIBC/stdio.c" \
    -f "$M2LIBC/string.c" \
    -f "$M2LIBC/bootstrappable.c" \
    -f "$SRC/mescc-tools-extra/$name.c" \
    --debug \
    -o "$WORK/$name.M1"
  "$BLOOD_ELF_0" $ENDIAN_FLAG $BLOOD_FLAGS -f "$WORK/$name.M1" -o "$WORK/$name-footer.M1"
  "$M1" --architecture "$M2_ARCH" \
    $ENDIAN_FLAG \
    -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
    -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
    -f "$WORK/$name.M1" \
    -f "$WORK/$name-footer.M1" \
    -o "$WORK/$name.hex2"
  "$HEX2" --architecture "$M2_ARCH" \
    $ENDIAN_FLAG \
    -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
    -f "$WORK/$name.hex2" \
    --base-address "$BASE_ADDR" \
    -o "$OUT_ABS/bin/$name"
  chmod 0555 "$OUT_ABS/bin/$name"
}

build_extra mkdir
build_extra cp
build_extra chmod
build_extra replace

# Install M2/M1/hex2 as canonical bootstrap tools
"$OUT_ABS/bin/cp" "$M2" "$OUT_ABS/bin/M2"     ; chmod 0555 "$OUT_ABS/bin/M2"
"$OUT_ABS/bin/cp" "$M1" "$OUT_ABS/bin/M1"     ; chmod 0555 "$OUT_ABS/bin/M1"
"$OUT_ABS/bin/cp" "$HEX2" "$OUT_ABS/bin/hex2" ; chmod 0555 "$OUT_ABS/bin/hex2"

# Now run the kaem-driven Phase-12 through Phase-15 (M2-Mesoplanet,
# blood-elf, get_machine, M2-Planet re-build). We translate the
# nixpkgs build.kaem into a sequence of direct invocations here rather
# than running kaem-unwrapped on a synthetic kaem file, because the
# nixpkgs build.kaem uses ${variable} interpolation that kaem doesn't
# natively support (nix substitutes those at builder-derivation time).

cd "$WORK"

# Patch M2-Mesoplanet/cc.c + cc_spawn.c so M2LIBC_PATH + PATH lookups
# return our hardcoded paths.
#
# IMPORTANT REPRODUCIBILITY NOTE: nixpkgs's build.kaem embeds the nix
# store path of `${m2libc}` (content-addressable -> same bytes -> same
# string -> bit-stable M2-Mesoplanet binary). Our chain embeds whatever
# absolute paths the build was invoked with, which differs by user/CI
# environment. To keep M2-Mesoplanet reproducible we pin canonical
# install prefixes that don't depend on the build environment:
#   M2LIBC_PATH = /repro/m2libc
#   PATH        = /repro/bin:
# At runtime, the user (or the next-phase wrapper) must point M2libc at
# the right location via `--m2libc-path` or by symlinking into /repro/
# (we use --m2libc-path in the higher-level scripts).
M2LIBC_PIN=/repro/m2libc
PATH_PIN=/repro/bin:

log "patching M2-Mesoplanet cc.c + cc_spawn.c (pin paths to /repro/...)"
"$OUT_ABS/bin/replace" \
  --file "$SRC/M2-Mesoplanet/cc.c" \
  --output "$WORK/cc_patched.c" \
  --match-on 'env_lookup("M2LIBC_PATH")' \
  --replace-with "\"$M2LIBC_PIN\""
"$OUT_ABS/bin/replace" \
  --file "$SRC/M2-Mesoplanet/cc_spawn.c" \
  --output "$WORK/cc_spawn_patched.c" \
  --match-on 'env_lookup("PATH")' \
  --replace-with "\"$PATH_PIN\""

# Phase-12: M2-Mesoplanet
log "phase-12: M2-Mesoplanet"
"$M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/sys/stat.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/string.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/M2-Mesoplanet/cc.h" \
  -f "$SRC/M2-Mesoplanet/cc_globals.c" \
  -f "$SRC/M2-Mesoplanet/cc_env.c" \
  -f "$SRC/M2-Mesoplanet/cc_reader.c" \
  -f "$WORK/cc_spawn_patched.c" \
  -f "$SRC/M2-Mesoplanet/cc_core.c" \
  -f "$SRC/M2-Mesoplanet/cc_macro.c" \
  -f "$WORK/cc_patched.c" \
  --debug \
  -o "$WORK/M2-Mesoplanet-1.M1"
"$BLOOD_ELF_0" $ENDIAN_FLAG $BLOOD_FLAGS -f "$WORK/M2-Mesoplanet-1.M1" -o "$WORK/M2-Mesoplanet-1-footer.M1"
"$M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$WORK/M2-Mesoplanet-1.M1" \
  -f "$WORK/M2-Mesoplanet-1-footer.M1" \
  -o "$WORK/M2-Mesoplanet-1.hex2"
"$HEX2" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$WORK/M2-Mesoplanet-1.hex2" \
  -o "$OUT_ABS/bin/M2-Mesoplanet"
chmod 0555 "$OUT_ABS/bin/M2-Mesoplanet"

# Phase-13: final blood-elf
log "phase-13: blood-elf (final)"
"$M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/stringify.c" \
  -f "$SRC/mescc-tools/blood-elf.c" \
  --debug \
  -o "$WORK/blood-elf-1.M1"
"$BLOOD_ELF_0" $ENDIAN_FLAG $BLOOD_FLAGS -f "$WORK/blood-elf-1.M1" -o "$WORK/blood-elf-1-footer.M1"
"$M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$WORK/blood-elf-1.M1" \
  -f "$WORK/blood-elf-1-footer.M1" \
  -o "$WORK/blood-elf-1.hex2"
"$HEX2" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$WORK/blood-elf-1.hex2" \
  -o "$OUT_ABS/bin/blood-elf"
chmod 0555 "$OUT_ABS/bin/blood-elf"

# Phase-14: get_machine
log "phase-14: get_machine"
"$M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/get_machine.c" \
  --debug \
  -o "$WORK/get_machine.M1"
"$OUT_ABS/bin/blood-elf" $ENDIAN_FLAG $BLOOD_FLAGS -f "$WORK/get_machine.M1" -o "$WORK/get_machine-footer.M1"
"$M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$WORK/get_machine.M1" \
  -f "$WORK/get_machine-footer.M1" \
  -o "$WORK/get_machine.hex2"
"$HEX2" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$WORK/get_machine.hex2" \
  -o "$OUT_ABS/bin/get_machine"
chmod 0555 "$OUT_ABS/bin/get_machine"

# Phase-15: M2-Planet (rebuilt with debug info)
log "phase-15: M2-Planet (final)"
"$M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/M2-Planet/cc.h" \
  -f "$SRC/M2-Planet/cc_globals.c" \
  -f "$SRC/M2-Planet/cc_reader.c" \
  -f "$SRC/M2-Planet/cc_strings.c" \
  -f "$SRC/M2-Planet/cc_types.c" \
  -f "$SRC/M2-Planet/cc_emit.c" \
  -f "$SRC/M2-Planet/cc_core.c" \
  -f "$SRC/M2-Planet/cc_macro.c" \
  -f "$SRC/M2-Planet/cc.c" \
  --debug \
  -o "$WORK/M2-1.M1"
"$OUT_ABS/bin/blood-elf" $ENDIAN_FLAG $BLOOD_FLAGS -f "$WORK/M2-1.M1" -o "$WORK/M2-1-footer.M1"
"$M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$WORK/M2-1.M1" \
  -f "$WORK/M2-1-footer.M1" \
  -o "$WORK/M2-1.hex2"
"$HEX2" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$WORK/M2-1.hex2" \
  -o "$OUT_ABS/bin/M2-Planet"
chmod 0555 "$OUT_ABS/bin/M2-Planet"

# Final sha256 record
log "writing SHA256SUMS"
{
  cd "$OUT_ABS/bin"
  for bin in M1 M2 hex2 mkdir cp chmod replace M2-Mesoplanet blood-elf get_machine M2-Planet; do
    if [ -f "$bin" ]; then
      printf "  %-18s %10d  %s\n" "$bin" "$(stat -c %s "$bin")" "$(sha256sum "$bin" | awk '{print $1}')"
    else
      printf "  %-18s MISSING\n" "$bin"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"
log "wrote $OUT_ABS/SHA256SUMS"
