#!/bin/bash
# Helper: regenerate $OUT/SHA256SUMS for an already-installed glibc.
# Invoked by build-glibc.sh (and by hand if needed).
set -euo pipefail
OUT_ABS="${1:?usage: $0 OUT_DIR}"
: "${SOURCE_DATE_EPOCH:=1735689600}"

{
  cd "$OUT_ABS"
  printf "# R6 Phase 2 (glibc 2.42 / via R5 gcc 15.2.0 + binutils 2.46.0) outputs\n"
  printf "# Built %s SOURCE_DATE_EPOCH=%s\n" \
    "$(date -u --date="@$SOURCE_DATE_EPOCH" '+%Y-%m-%d')" \
    "$SOURCE_DATE_EPOCH"
  for f in lib/libc.so.6 \
           lib/ld-linux-x86-64.so.2 \
           lib/libm.so.6 \
           lib/libpthread.so.0 \
           lib/librt.so.1 \
           lib/libdl.so.2 \
           lib/libresolv.so.2 \
           lib/libcrypt.so.1 \
           lib/libutil.so.1 \
           lib/libc_nonshared.a \
           lib/libpthread.a \
           lib/crt1.o \
           lib/crti.o \
           lib/crtn.o \
           bin/ldd \
           bin/getconf \
           bin/getent \
           bin/locale; do
    if [ -f "$f" ]; then
      printf "%-44s %12d  %s\n" "$f" \
        "$(stat -c %s "$f")" \
        "$(sha256sum "$f" | awk '{print $1}')"
    fi
  done
} > "$OUT_ABS/SHA256SUMS"
cat "$OUT_ABS/SHA256SUMS"
