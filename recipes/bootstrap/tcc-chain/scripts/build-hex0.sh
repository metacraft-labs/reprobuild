#!/bin/bash
# build-hex0.sh — Phase 2 (R4a): build the hex0 binary from the
# hex0-seed + hex0_AMD64.hex0 source.
#
# Inputs (resolved from script args, defaults wired for repo-relative use):
#   $1 = vendor dir (containing hex0-seed.AMD64.bin + minimal-bootstrap-sources.tar.gz)
#   $2 = output dir (will be created if missing)
#
# Output:
#   $2/hex0           — the hex0 binary
#   $2/hex0.sha256    — text record of the sha256
#
# Env determinism flags (caller may pre-set; defaults are wired):
#   SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-hex0.sh <vendor-dir> <out-dir>}"
OUT="${2:?usage: build-hex0.sh <vendor-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "[build-hex0] VENDOR_ABS=$VENDOR_ABS"
echo "[build-hex0] OUT_ABS=$OUT_ABS"

WORK="$(mktemp -d -t reproos-r4a-hex0-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
echo "[build-hex0] WORK=$WORK"

# Stage seed + source
cp "$VENDOR_ABS/hex0-seed.AMD64.bin" "$WORK/hex0-seed"
chmod +x "$WORK/hex0-seed"

tar -xzf "$VENDOR_ABS/minimal-bootstrap-sources.tar.gz" -C "$WORK"
SRC="$WORK/stage0-posix"

if [ ! -f "$SRC/AMD64/hex0_AMD64.hex0" ]; then
  echo "[build-hex0] ERROR: expected $SRC/AMD64/hex0_AMD64.hex0 missing" >&2
  exit 1
fi

echo "[build-hex0] running hex0-seed against $SRC/AMD64/hex0_AMD64.hex0"
"$WORK/hex0-seed" "$SRC/AMD64/hex0_AMD64.hex0" "$OUT_ABS/hex0"
chmod +x "$OUT_ABS/hex0"

sha256sum "$OUT_ABS/hex0" | awk '{print $1}' > "$OUT_ABS/hex0.sha256"
echo "[build-hex0] hex0 sha256: $(cat "$OUT_ABS/hex0.sha256")"
echo "[build-hex0] hex0 size:   $(stat -c %s "$OUT_ABS/hex0")"
