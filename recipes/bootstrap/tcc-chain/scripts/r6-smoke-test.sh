#!/bin/bash
# r6-smoke-test.sh -- R6 Phase 3 acceptance gate.
#
# Compiles a hello-world C program with R5's gcc 15.2.0 + R6's glibc 2.42,
# runs it, and verifies the printed output + exit code (42).
#
# Inputs (positional):
#   $1 = gcc dir       (R5's gcc 15.2.0)
#   $2 = binutils dir  (R5's binutils 2.46.0)
#   $3 = glibc dir     (R6's glibc 2.42)
#
# Exit codes:
#   0 = PASS
#   non-zero = FAIL (with diagnostic on stderr)

set -uo pipefail

GCC="${1:?usage: $0 GCC BINUTILS GLIBC}"
BINUTILS="${2:?usage}"
GLIBC="${3:?usage}"

GCC_ABS="$(cd "$GCC" && pwd)"
BINUTILS_ABS="$(cd "$BINUTILS" && pwd)"
GLIBC_ABS="$(cd "$GLIBC" && pwd)"

log() { echo "[r6-smoke] $*"; }
log "GCC=$GCC_ABS"
log "BINUTILS=$BINUTILS_ABS"
log "GLIBC=$GLIBC_ABS"

WORK="$(mktemp -d -t reproos-r6-smoke-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
  printf("Hello from glibc!\n");
  return 42;
}
EOF

log "Compiling with gcc 15.2 + glibc include + glibc dynamic-linker"
"$GCC_ABS/bin/gcc" \
  -B"$BINUTILS_ABS/bin/" \
  -Wl,--dynamic-linker="$GLIBC_ABS/lib/ld-linux-x86-64.so.2" \
  -Wl,-rpath,"$GLIBC_ABS/lib" \
  -nostdinc \
  -isystem "$GLIBC_ABS/include" \
  -isystem "$GCC_ABS/lib/gcc/x86_64-pc-linux-gnu/15.2.0/include" \
  -L "$GLIBC_ABS/lib" \
  -B "$GLIBC_ABS/lib/" \
  -o "$WORK/hello" \
  "$WORK/hello.c"
if [ $? -ne 0 ]; then
  echo "[r6-smoke] FAIL: gcc compile failed" >&2
  exit 1
fi

log "Built binary $(ls -la "$WORK/hello" | awk '{print $5}') bytes"

# Capture stdout AND exit code in a single shell invocation
log "Running ..."
out="$("$WORK/hello" 2>&1)"
rc=$?
log "stdout: $out"
log "exit code: $rc"

expected_out="Hello from glibc!"
expected_rc=42

if [ "$out" != "$expected_out" ]; then
  echo "[r6-smoke] FAIL: stdout mismatch" >&2
  echo "  expected: $expected_out" >&2
  echo "  got:      $out" >&2
  exit 1
fi

if [ "$rc" -ne "$expected_rc" ]; then
  echo "[r6-smoke] FAIL: exit code $rc (expected $expected_rc)" >&2
  exit 1
fi

log "Verifying interpreter via readelf"
interp="$(env -u PATH PATH=/usr/bin:/bin readelf -l "$WORK/hello" 2>&1 | grep -oP 'interpreter: \K[^]]*' || true)"
log "interpreter: $interp"
if [ "$interp" != "$GLIBC_ABS/lib/ld-linux-x86-64.so.2" ]; then
  echo "[r6-smoke] FAIL: interpreter is '$interp', expected '$GLIBC_ABS/lib/ld-linux-x86-64.so.2'" >&2
  exit 1
fi

log "Verifying NEEDED libc via ldd"
ldd_out="$("$GLIBC_ABS/bin/ldd" "$WORK/hello" 2>&1)"
log "ldd:"
echo "$ldd_out" | sed 's/^/  /'
if ! echo "$ldd_out" | grep -q "$GLIBC_ABS/lib/libc.so.6"; then
  echo "[r6-smoke] FAIL: ldd output does not reference glibc's libc.so.6" >&2
  exit 1
fi

log "PASS"
