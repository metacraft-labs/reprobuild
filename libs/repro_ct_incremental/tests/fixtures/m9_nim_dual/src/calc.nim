## M9 Nim dual-path fixture for the Trace-Based-Incremental-Testing campaign.
##
## Nim is SPECIAL: a Nim program is recordable BOTH ways (CodeTracer
## Language-Support-Matrix, "Nim dual-path"):
##
##   * MATERIALIZED SOURCE path — CodeTracer records Nim at the source level,
##     emitting canonical `Function`/`Call` records exactly like the interpreted
##     languages (Python/Ruby/JS). A function's identity is then its SOURCE TEXT,
##     hashed by the `.nim` source extractor (indentation-delimited proc bodies).
##     The committed `../trace_source/` fixture is in this canonical shape.
##
##   * NATIVE / MCR path — Nim compiles VIA C to a native binary, which the
##     Multi-Core Recorder (RR + DWARF) records like any other system language.
##     A function's identity is then its COMPILED INSTRUCTION BYTES, located in
##     the binary by its (mangled) symbol name and hashed by `shallowHashNative`.
##     The `../trace_native/` fixture is in the native calltrace shape and the
##     test compiles THIS SAME `calc.nim` with `nim c` to produce the binary.
##
## The incremental engine picks the strategy PER TRACE via `detectBackend`,
## purely from the trace's backend — never from the language name. The same
## `calc.nim` therefore decides correctly on either path.
##
## # Roles (kept identical to the M7/M8 native fixtures so the native path's
## # position-independence + layout guarantees carry over)
##
##   * usedA   — EXECUTED. A pure, position-independent LEAF (no calls). On the
##               native path its instruction bytes are relocation-invariant, so
##               editing a sibling does not change its hash.
##   * usedB   — EXECUTED. Also a pure leaf.
##   * unusedC — NOT executed. Edited by the unexecuted-edit tests. Placed AFTER
##               usedA/usedB in SOURCE ORDER so that growing it relocates only
##               functions declared LATER (mainCalc), never the earlier executed
##               leaves. The executed leaves are pure position-independent code,
##               so even when they relocate their instruction BYTES — and thus
##               their hashes — are unchanged across an unusedC edit, giving a
##               genuine native skip. (With the build's `-g` Itanium mangling the
##               leaf symbol NAMES `_ZN<len>calc<len>usedAE` carry no
##               declaration-order suffix and are also edit-stable; the test
##               re-discovers them from each binary regardless, since the
##               alternative `usedA__<modulehash>_uN` mangling would renumber.)
##   * mainCalc — entry; calls usedA + usedB (and references unusedC behind a
##                runtime-false guard so unusedC is EMITTED into the binary but
##                never EXECUTED). mainCalc is NOT in the executed set (it is the
##                call-containing, relocation-sensitive function — excluded for
##                the same reason `main` is excluded from the M8 fixture).
##
## # Line numbers (the source path depends on these — keep the `proc` lines stable)
##
##   usedA    -> line 60
##   usedB    -> line 63
##   unusedC  -> line 66
##   mainCalc -> line 69
##
## The `../trace_source/` Function records carry these definition lines; the
## `.nim` source extractor captures each proc body from its `proc` line through
## the next line indented at or below the `proc`'s indentation.

import std/os

proc usedA(): int {.noinline.} =
  result = 1 + 1

proc usedB(x: int): int {.noinline.} =
  result = x * 2 + 7

proc unusedC(): int {.noinline.} =
  result = 99

proc mainCalc(): int {.noinline.} =
  result = usedA() + usedB(3)
  # Reference unusedC so the C backend EMITS it into the binary (it is a leaf
  # the native path must be able to locate + hash), but guard the call behind a
  # runtime-false condition (`paramCount()` is 0 in the test run) so it is never
  # EXECUTED — keeping it out of the executed set on BOTH paths.
  if paramCount() > 100000:
    result += unusedC()

echo mainCalc()
