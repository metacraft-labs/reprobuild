#!/usr/bin/env bash
# Build helper for the M9 Nim dual-path fixture (NATIVE path).
#
# Usage: build.sh <source.nim> <output-binary>
#
# Compiles the SAME calc.nim the source path uses, via `nim c` (Nim's default
# C backend), into a native binary so the native / MCR path can be exercised
# against real compiled instruction bytes (NOT source text).
#
# Flags rationale — make usedA/usedB genuine POSITION-INDEPENDENT leaves so the
# native instruction-byte hash is relocation-invariant (the M7/M8 precision
# property). Nim's DEFAULTS inject per-function machinery that would defeat this:
#   * stack traces / line directives embed the absolute SOURCE FILE PATH as a
#     string literal in every proc (so a leaf would carry the temp-dir path and
#     hash differently per build dir);
#   * runtime checks insert a pc-relative `bl callDepthLimitReached` CALL into
#     every proc (a relocation-SENSITIVE branch — defeats leaf stability);
#   * the C stack protector / async unwind tables add incidental codegen.
# Disabling them leaves each leaf as just its own arithmetic + ret:
#   --opt:none          : no inlining/merging — each proc is its own block.
#   --stackTrace:off --lineTrace:off --lineDir:off : drop the embedded source
#                         path + per-proc trace bookkeeping.
#   --checks:off -d:danger --panics:on : drop the per-proc runtime-check calls.
#   --passC:-fno-stack-protector --passC:-fno-asynchronous-unwind-tables :
#                         trim incidental C codegen (same as the M7/M8 fixtures).
#   -g                  : emit symbols so nm/otool can locate each proc.
#
# IMPORTANT (the M9 name-matching requirement): Nim MANGLES proc names when
# compiling via C, so the native calltrace's `functionName`s MUST be the names
# that actually appear in THIS binary's symbol table — the test discovers them
# by running `nm` on the built binary (see t_nim_dual.nim's `mangledName`),
# never hardcodes them. With `-g` (this script) the dev-shell Nim emits an
# Itanium-style symbol `_ZN<len>calc<len>usedAE` (module `calc` + proc name,
# verified via `nm`); without `-g` it emits `usedA__<modulehash>_uN` instead.
# Either way the mangled name is NOT the source identifier, which is exactly why
# it must be discovered from the binary rather than assumed.
set -euo pipefail

src="${1:?source file required}"
out="${2:?output binary path required}"

nim c --hints:off \
  --opt:none \
  --stackTrace:off --lineTrace:off --lineDir:off \
  --checks:off -d:danger --panics:on \
  --passC:-fno-stack-protector --passC:-fno-asynchronous-unwind-tables \
  -g \
  -o:"$out" "$src"
