#!/bin/bash
# build-musl-tcc.sh -- R5 Phase 3: build musl 1.2.6 with R4's tcc.
#
# Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/musl/tcc.nix.
#
# Result: $OUT/{include,lib,bin} -- musl libc with libtcc1.a copied in.
# This is what nixpkgs calls `musl-tcc` (and is the libc used by
# `tinycc-musl`, which in turn is what builds binutils + gcc 4.6.4).
#
# musl is `-std=c99 -ffreestanding -nostdinc` so it ships its OWN libc
# headers and doesn't need the shim's mes-libc include overlay -- the
# only host requirement is tcc itself + libtcc1.a for the final link.
#
# Inputs (positional):
#   $1 = vendor dir        (with musl-1.2.6.tar.gz, musl-sigsetjmp.patch)
#   $2 = tcc-shim dir      (R5 Phase 2 output -- $shim/bin/tcc +
#                           $shim/lib/libtcc1.a)
#   $3 = output dir        (will hold include/, lib/, bin/)

set -euo pipefail

: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

VENDOR="${1:?usage: build-musl-tcc.sh <vendor-dir> <tcc-shim-dir> <out-dir>}"
SHIM="${2:?usage: build-musl-tcc.sh <vendor-dir> <tcc-shim-dir> <out-dir>}"
OUT="${3:?usage: build-musl-tcc.sh <vendor-dir> <tcc-shim-dir> <out-dir>}"

VENDOR_ABS="$(cd "$VENDOR" && pwd)"
SHIM_ABS="$(cd "$SHIM" && pwd)"
mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

log() { echo "[musl-tcc] $*"; }
log "VENDOR=$VENDOR_ABS"
log "SHIM=$SHIM_ABS"
log "OUT=$OUT_ABS"

# Sanity.
for f in "$VENDOR_ABS/musl-1.2.6.tar.gz" \
         "$VENDOR_ABS/musl-sigsetjmp.patch" \
         "$SHIM_ABS/bin/tcc" \
         "$SHIM_ABS/lib/libtcc1.a"; do
  [ -e "$f" ] || { echo "[musl-tcc] ERROR: missing $f" >&2; exit 1; }
done

# Need a working make + sed + grep + tar.  Use host (Debian).
MAKE="${MAKE:-make}"
command -v "$MAKE" >/dev/null || { echo "[musl-tcc] ERROR: no make on PATH"; exit 1; }

WORK="$(mktemp -d -t reproos-r5-musltcc-XXXXXX)"
# Keep WORK alive on failure for debug; only remove on success.
KEEP_WORK="${KEEP_WORK:-0}"
trap 'rc=$?; if [ "$rc" -ne 0 ] || [ "$KEEP_WORK" = 1 ]; then echo "[musl-tcc] keeping WORK=$WORK for debug (rc=$rc)"; else rm -rf "$WORK"; fi' EXIT
log "WORK=$WORK (tmpfs)"

cd "$WORK"

log "Stage 1: unpack musl 1.2.6"
tar -xzf "$VENDOR_ABS/musl-1.2.6.tar.gz"
cd musl-1.2.6

log "Stage 2: apply patches (sigsetjmp + popen/system/wordexp/asm cleanups)"
# Apply the live-bootstrap sigsetjmp patch (works around tcc's missing
# backward-jumping jecxz).
patch -Np0 -i "$VENDOR_ABS/musl-sigsetjmp.patch"

# Per nixpkgs musl/tcc.nix: remove complex (tcc has no complex types).
rm -rf src/complex

# /dev/null must exist for configure (yes it does in WSL).
[ -e /dev/null ] || { echo "[musl-tcc] ERROR: /dev/null missing"; exit 1; }

# tools/*.sh expect /bin/sh -- repoint at host bash.
for f in tools/*.sh; do
  if [ -f "$f" ]; then
    sed -i 's|/bin/sh|/bin/bash|' "$f"
    chmod +x "$f"
  fi
done

# popen/system/wordexp hardcode /bin/sh; repoint to PATH-based sh.
sed -i 's|posix_spawn(&pid, "/bin/sh",|posix_spawnp(\&pid, "sh",|' \
  src/stdio/popen.c src/process/system.c
sed -i 's|execl("/bin/sh", "sh", "-c",|execlp("sh", "-c",|' \
  src/misc/wordexp.c

# @PLT specifier unsupported by tcc.
sed -i 's|@PLT||' src/math/x86_64/expl.s
sed -i 's|@PLT||' src/signal/x86_64/sigsetjmp.s

# Remove asm with 'x'/'t' constraints (tcc unsupported); musl
# polyfills with pure C.
rm -f src/math/i386/*.c src/math/x86_64/*.c

log "Stage 3: ./configure CC=tcc"
# We use the shim's wrapper-less tcc plus explicit -B for libtcc1.a.
# Make tcc visible as just "tcc" so configure's heuristics work; add a
# wrapper that injects -B.
mkdir -p "$WORK/bin-tcc"
cat > "$WORK/bin-tcc/tcc" <<EOF
#!/bin/bash
exec "$SHIM_ABS/bin/tcc" -B "$SHIM_ABS/lib" "\$@"
EOF
chmod +x "$WORK/bin-tcc/tcc"
export PATH="$WORK/bin-tcc:$PATH"

# Need tcc -ar to act as an archiver too.
cat > "$WORK/bin-tcc/ar" <<EOF
#!/bin/bash
exec "$SHIM_ABS/bin/tcc" -B "$SHIM_ABS/lib" -ar "\$@"
EOF
chmod +x "$WORK/bin-tcc/ar"

bash ./configure \
  --prefix="$OUT_ABS" \
  --build=x86_64-pc-linux-musl \
  --host=x86_64-pc-linux-musl \
  --disable-shared \
  CC=tcc \
  2>&1 | tee "$WORK/configure.log" | tail -30

log "Stage 4: make (tcc; CFLAGS=-DSYSCALL_NO_TLS; AR=tcc-ar; RANLIB=true)"
# nixpkgs notes parallel build under tcc is unstable; run serial.
$MAKE \
  AR="$SHIM_ABS/bin/tcc -B $SHIM_ABS/lib -ar" \
  RANLIB=true \
  CFLAGS="-DSYSCALL_NO_TLS" \
  2>&1 | tee "$WORK/make.log" | tail -40
# Don't fail on the tee here -- final-line check is below.

if [ ! -f "$WORK/musl-1.2.6/lib/libc.a" ]; then
  echo "[musl-tcc] ERROR: lib/libc.a not produced; make.log tail:" >&2
  tail -60 "$WORK/make.log" >&2
  exit 1
fi
log "  built lib/libc.a ($(stat -c %s "$WORK/musl-1.2.6/lib/libc.a") bytes)"

log "Stage 5: make install"
$MAKE install 2>&1 | tee "$WORK/install.log" | tail -20

# Copy libtcc1.a into musl lib (per nixpkgs musl/tcc.nix).
log "Stage 6: copy libtcc1.a from shim"
cp "$SHIM_ABS/lib/libtcc1.a" "$OUT_ABS/lib/libtcc1.a"

# Smoke: there should be $OUT/lib/libc.a, $OUT/include/stdio.h, etc.
for f in lib/libc.a lib/libtcc1.a include/stdio.h include/string.h \
         include/sys/types.h include/unistd.h; do
  if [ ! -e "$OUT_ABS/$f" ]; then
    echo "[musl-tcc] ERROR: install missing $f" >&2
    exit 1
  fi
done
log "  install OK: libc.a + libtcc1.a + headers verified"

# Emit SHA256SUMS.
log "writing SHA256SUMS"
{
  cd "$OUT_ABS"
  printf "# R5 Phase 3 (musl-tcc 1.2.6) outputs -- built %s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')"
  for f in lib/libc.a lib/libtcc1.a lib/crt1.o lib/crti.o lib/crtn.o \
           lib/Scrt1.o lib/rcrt1.o; do
    if [ -f "$f" ]; then
      printf "%-20s %10d  %s\n" "$f" \
        "$(stat -c %s "$f")" "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"

log "musl-tcc ready at $OUT_ABS"
