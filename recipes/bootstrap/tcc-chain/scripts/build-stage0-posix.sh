#!/bin/bash
# build-stage0-posix.sh — Phase 3 (R4b): build the stage0-posix
# mescc-tools-boot chain, port of nixpkgs's
# pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/mescc-tools-boot.nix.
#
# Produces, in order, the eleven canonical stage0-posix binaries:
#   hex1   hex2-0    catm   M0   cc_arch   M2
#   blood-elf-0     M1-0   hex2-1   M1   hex2   kaem-unwrapped
#
# Each binary is built from prior outputs + source files inside the
# vendored minimal-bootstrap-sources.tar.gz tree.
#
# Inputs (positional):
#   $1 = vendor dir (containing hex0-seed.AMD64.bin + tarball + the
#        already-built hex0 from build-hex0.sh)
#   $2 = output dir (will hold all eleven binaries)
#
# Required env:
#   SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
#
# Refs:
#   - nixpkgs mescc-tools-boot.nix (commit 06a4933d0, the R3-mined ref)
#   - upstream stage0-posix Release_1.9.1

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-stage0-posix.sh <vendor-dir> <out-dir>}"
OUT="${2:?usage: build-stage0-posix.sh <vendor-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "[stage0-posix] VENDOR_ABS=$VENDOR_ABS"
echo "[stage0-posix] OUT_ABS=$OUT_ABS"

# We expect the hex0 binary to be available either in $OUT/hex0 (if a
# prior Phase 2 run wrote it there) or in $VENDOR/../build/hex0/hex0
# (the standard build-output location). Source it in:
HEX0=""
if [ -x "$OUT_ABS/hex0" ]; then
  HEX0="$OUT_ABS/hex0"
elif [ -x "$VENDOR_ABS/../build/hex0/hex0" ]; then
  HEX0="$(cd "$VENDOR_ABS/../build/hex0" && pwd)/hex0"
fi

if [ -z "$HEX0" ]; then
  echo "[stage0-posix] ERROR: cannot find hex0 binary in $OUT_ABS or sibling build/hex0/" >&2
  echo "                    run build-hex0.sh first" >&2
  exit 1
fi

# Stage source tree
WORK="$(mktemp -d -t reproos-r4b-stage0-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "[stage0-posix] WORK=$WORK"

tar -xzf "$VENDOR_ABS/minimal-bootstrap-sources.tar.gz" -C "$WORK"
SRC="$WORK/stage0-posix"
M2LIBC="$SRC/M2libc"

# AMD64 platform pins from nixpkgs platforms.nix
ARCH=AMD64           # stage0Arch
M2_ARCH=amd64        # m2libcArch (lower-case)
ENDIAN_FLAG=--little-endian
BLOOD_FLAGS=--64

# Copy hex0 into work so the chain reads consistent paths
cp "$HEX0" "$WORK/hex0"
chmod +x "$WORK/hex0"

# Mirror nixpkgs's `out = placeholder "out"` per-step output convention.
# We pass each step's output via an absolute path under $OUT_ABS.
B="$OUT_ABS"
mkdir -p "$B"

# Common runner: invoke the named builder with given args, expect args
# to include the output path the builder will write.
log() { echo "[stage0-posix] $*"; }

# Phase 1: hex1 = hex0(hex1_AMD64.hex0)
log "phase-1: hex1"
"$WORK/hex0" "$SRC/$ARCH/hex1_${ARCH}.hex0" "$B/hex1"
chmod +x "$B/hex1"

# Phase 2: hex2-0 = hex1(hex2_AMD64.hex1)
log "phase-2: hex2-0"
"$B/hex1" "$SRC/$ARCH/hex2_${ARCH}.hex1" "$B/hex2-0"
chmod +x "$B/hex2-0"

# Phase 2b: catm (AMD64 builds via hex2-0; aarch64 via hex1)
log "phase-2b: catm"
"$B/hex2-0" "$SRC/$ARCH/catm_${ARCH}.hex2" "$B/catm"
chmod +x "$B/catm"

# Phase 3: M0 = hex2-0(catm(ELF-amd64.hex2, M0_AMD64.hex2))
log "phase-3: M0"
"$B/catm" "$B/M0.hex2" "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}.hex2" "$SRC/$ARCH/M0_${ARCH}.hex2"
"$B/hex2-0" "$B/M0.hex2" "$B/M0"
chmod +x "$B/M0"

# Phase 4: cc_arch (cc_amd64) — single-arch minimal C compiler
log "phase-4: cc_arch"
"$B/M0" "$SRC/$ARCH/cc_${M2_ARCH}.M1" "$B/cc_arch-0.hex2"
"$B/catm" "$B/cc_arch-1.hex2" "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}.hex2" "$B/cc_arch-0.hex2"
"$B/hex2-0" "$B/cc_arch-1.hex2" "$B/cc_arch"
chmod +x "$B/cc_arch"

# Phase 5: M2-Planet (M2)
# nixpkgs:
#   M2-0_c     = catm(out, bootstrap.c, cc.h, bootstrappable.c, cc_globals.c, cc_reader.c, cc_strings.c, cc_types.c, cc_emit.c, cc_core.c, cc_macro.c, cc.c)
#   M2-0_M1    = cc_arch(M2-0_c -> out)
#   M2-0-0_M1  = catm(out, amd64_defs.M1, libc-core.M1, M2-0_M1)
#   M2-0_hex2  = M0(M2-0-0_M1 -> out)
#   M2-0-0_hex2= catm(out, ELF-amd64.hex2, M2-0_hex2)
#   M2         = hex2-0(M2-0-0_hex2 -> out)
log "phase-5: M2 (M2-Planet)"
"$B/catm" "$B/M2-0.c" \
  "$M2LIBC/$M2_ARCH/linux/bootstrap.c" \
  "$SRC/M2-Planet/cc.h" \
  "$M2LIBC/bootstrappable.c" \
  "$SRC/M2-Planet/cc_globals.c" \
  "$SRC/M2-Planet/cc_reader.c" \
  "$SRC/M2-Planet/cc_strings.c" \
  "$SRC/M2-Planet/cc_types.c" \
  "$SRC/M2-Planet/cc_emit.c" \
  "$SRC/M2-Planet/cc_core.c" \
  "$SRC/M2-Planet/cc_macro.c" \
  "$SRC/M2-Planet/cc.c"
"$B/cc_arch" "$B/M2-0.c" "$B/M2-0.M1"
"$B/catm" "$B/M2-0-0.M1" \
  "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  "$M2LIBC/$M2_ARCH/libc-core.M1" \
  "$B/M2-0.M1"
"$B/M0" "$B/M2-0-0.M1" "$B/M2-0.hex2"
"$B/catm" "$B/M2-0-0.hex2" \
  "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}.hex2" \
  "$B/M2-0.hex2"
"$B/hex2-0" "$B/M2-0-0.hex2" "$B/M2"
chmod +x "$B/M2"

# Phase 6: blood-elf-0
log "phase-6: blood-elf-0"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/$M2_ARCH/linux/bootstrap.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/stringify.c" \
  -f "$SRC/mescc-tools/blood-elf.c" \
  --bootstrap-mode \
  -o "$B/blood-elf-0.M1"
"$B/catm" "$B/blood-elf-0-0.M1" \
  "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  "$M2LIBC/$M2_ARCH/libc-core.M1" \
  "$B/blood-elf-0.M1"
"$B/M0" "$B/blood-elf-0-0.M1" "$B/blood-elf-0.hex2"
"$B/catm" "$B/blood-elf-0-0.hex2" \
  "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}.hex2" \
  "$B/blood-elf-0.hex2"
"$B/hex2-0" "$B/blood-elf-0-0.hex2" "$B/blood-elf-0"
chmod +x "$B/blood-elf-0"

# Phase 7: M1-0
log "phase-7: M1-0"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/$M2_ARCH/linux/bootstrap.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/stringify.c" \
  -f "$SRC/mescc-tools/M1-macro.c" \
  --bootstrap-mode --debug \
  -o "$B/M1-macro-0.M1"
"$B/blood-elf-0" $BLOOD_FLAGS \
  -f "$B/M1-macro-0.M1" \
  $ENDIAN_FLAG \
  -o "$B/M1-macro-0-footer.M1"
"$B/catm" "$B/M1-macro-0-0.M1" \
  "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  "$M2LIBC/$M2_ARCH/libc-core.M1" \
  "$B/M1-macro-0.M1" \
  "$B/M1-macro-0-footer.M1"
"$B/M0" "$B/M1-macro-0-0.M1" "$B/M1-macro-0.hex2"
"$B/catm" "$B/M1-macro-0-0.hex2" \
  "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  "$B/M1-macro-0.hex2"
"$B/hex2-0" "$B/M1-macro-0-0.hex2" "$B/M1-0"
chmod +x "$B/M1-0"

# Phase 8: hex2-1
log "phase-8: hex2-1"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/$M2_ARCH/linux/sys/stat.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/hex2.h" \
  -f "$SRC/mescc-tools/hex2_linker.c" \
  -f "$SRC/mescc-tools/hex2_word.c" \
  -f "$SRC/mescc-tools/hex2.c" \
  --debug \
  -o "$B/hex2_linker-0.M1"
"$B/blood-elf-0" $BLOOD_FLAGS \
  -f "$B/hex2_linker-0.M1" \
  $ENDIAN_FLAG \
  -o "$B/hex2_linker-0-footer.M1"
"$B/M1-0" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$B/hex2_linker-0.M1" \
  -f "$B/hex2_linker-0-footer.M1" \
  -o "$B/hex2_linker-0.hex2"
"$B/catm" "$B/hex2_linker-0-0.hex2" \
  "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  "$B/hex2_linker-0.hex2"
"$B/hex2-0" "$B/hex2_linker-0-0.hex2" "$B/hex2-1"
chmod +x "$B/hex2-1"

# Phase 9: M1
log "phase-9: M1"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/string.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/stringify.c" \
  -f "$SRC/mescc-tools/M1-macro.c" \
  --debug \
  -o "$B/M1-macro-1.M1"
"$B/blood-elf-0" $BLOOD_FLAGS \
  -f "$B/M1-macro-1.M1" \
  $ENDIAN_FLAG \
  -o "$B/M1-macro-1-footer.M1"
"$B/M1-0" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$B/M1-macro-1.M1" \
  -f "$B/M1-macro-1-footer.M1" \
  -o "$B/M1-macro-1.hex2"

# baseAddress for x86_64-linux: 0x00600000 (per platforms.nix)
BASE_ADDR=0x00600000

"$B/hex2-1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$B/M1-macro-1.hex2" \
  -o "$B/M1"
chmod +x "$B/M1"

# Phase 10: hex2 (final hex2 from C sources)
log "phase-10: hex2"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/$M2_ARCH/linux/sys/stat.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/hex2.h" \
  -f "$SRC/mescc-tools/hex2_linker.c" \
  -f "$SRC/mescc-tools/hex2_word.c" \
  -f "$SRC/mescc-tools/hex2.c" \
  --debug \
  -o "$B/hex2_linker-2.M1"
"$B/blood-elf-0" $BLOOD_FLAGS \
  -f "$B/hex2_linker-2.M1" \
  $ENDIAN_FLAG \
  -o "$B/hex2_linker-2-footer.M1"
"$B/M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$B/hex2_linker-2.M1" \
  -f "$B/hex2_linker-2-footer.M1" \
  -o "$B/hex2_linker-2.hex2"
"$B/hex2-1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  --base-address "$BASE_ADDR" \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$B/hex2_linker-2.hex2" \
  -o "$B/hex2"
chmod +x "$B/hex2"

# Phase 11: kaem-unwrapped
log "phase-11: kaem-unwrapped"
"$B/M2" --architecture "$M2_ARCH" \
  -f "$M2LIBC/sys/types.h" \
  -f "$M2LIBC/stddef.h" \
  -f "$M2LIBC/sys/utsname.h" \
  -f "$M2LIBC/$M2_ARCH/linux/unistd.c" \
  -f "$M2LIBC/$M2_ARCH/linux/fcntl.c" \
  -f "$M2LIBC/fcntl.c" \
  -f "$M2LIBC/ctype.c" \
  -f "$M2LIBC/stdlib.c" \
  -f "$M2LIBC/string.c" \
  -f "$M2LIBC/stdarg.h" \
  -f "$M2LIBC/stdio.h" \
  -f "$M2LIBC/stdio.c" \
  -f "$M2LIBC/bootstrappable.c" \
  -f "$SRC/mescc-tools/Kaem/kaem.h" \
  -f "$SRC/mescc-tools/Kaem/variable.c" \
  -f "$SRC/mescc-tools/Kaem/kaem_globals.c" \
  -f "$SRC/mescc-tools/Kaem/kaem.c" \
  --debug \
  -o "$B/kaem.M1"
"$B/blood-elf-0" $BLOOD_FLAGS \
  -f "$B/kaem.M1" \
  $ENDIAN_FLAG \
  -o "$B/kaem-footer.M1"
"$B/M1" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/${M2_ARCH}_defs.M1" \
  -f "$M2LIBC/$M2_ARCH/libc-full.M1" \
  -f "$B/kaem.M1" \
  -f "$B/kaem-footer.M1" \
  -o "$B/kaem.hex2"
"$B/hex2" --architecture "$M2_ARCH" \
  $ENDIAN_FLAG \
  -f "$M2LIBC/$M2_ARCH/ELF-${M2_ARCH}-debug.hex2" \
  -f "$B/kaem.hex2" \
  --base-address "$BASE_ADDR" \
  -o "$B/kaem-unwrapped"
chmod +x "$B/kaem-unwrapped"

# Final summary
log "stage0-posix chain complete; binaries:"
{
  cd "$B"
  for bin in hex0 hex1 hex2-0 catm M0 cc_arch M2 blood-elf-0 M1-0 hex2-1 M1 hex2 kaem-unwrapped; do
    if [ -f "$bin" ]; then
      printf "  %-18s %10d  %s\n" "$bin" "$(stat -c %s "$bin")" "$(sha256sum "$bin" | awk '{print $1}')"
    else
      printf "  %-18s MISSING\n" "$bin"
    fi
  done
} > "$B/SHA256SUMS"
cat "$B/SHA256SUMS"
log "wrote $B/SHA256SUMS"
