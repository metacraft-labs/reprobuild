## A tiny GENUINE compile-time `symBodyHash` catalog producer (M11, path 1b).
##
## # Why this exists
##
## The in-tree CodeTracer unit-testing library (`ct_test_unittest_parallel`)
## does NOT (yet) emit a `bodyHash`/`symBodyHash` field in its `--list-json`
## catalog — it carries only `name`/`suite`/`file`/`line`. So the M11 catalog
## source path (1a) ("read a real test binary's `--list-json` bodyHash") is not
## available out of the box. We therefore take path (1b): produce a REAL
## `symBodyHash` catalog directly with `std/macros.symBodyHash`.
##
## `std/macros.symBodyHash(sym)` (spec §16.2) returns the compiler's
## COMPILE-TIME DEEP hash of a symbol: it recursively walks the symbol's entire
## transitive call graph and folds every referenced proc's body into a single
## digest (implemented in `compiler/sighashes.nim`). It changes whenever ANY
## function in the dependency chain changes, and is unaffected by comments /
## whitespace / line moves. This is exactly the per-test `bodyHash` the library
## is specified to embed (§16.3) — here we compute it ourselves so the M11 tests
## drive the engine's deep path against GENUINE compile-time hashes, never
## hand-invented ones.
##
## # Usage
##
## `symBodyHashOf(theProc)` yields the real `symBodyHash` for a proc symbol.
## `catalogJson(...)` assembles a flat `{testId: bodyHash}` JSON document (the
## shape `catalog.parseBodyHashCatalog` reads). The M11 test calls these to
## build a catalog whose hashes are real, then mutates which proc a "test" maps
## to in order to simulate a changed vs unchanged deep hash across builds.

import std/[macros, json]

macro symBodyHashOf*(sym: typed): string =
  ## Expand to the COMPILE-TIME `symBodyHash` of `sym` as a string literal.
  ##
  ## `sym` must resolve to a single proc/func symbol (pass the proc by name).
  ## We unwrap a `nnkSym` directly, or a `nnkClosedSymChoice`/`nnkOpenSymChoice`
  ## (an overloaded name) by taking its first symbol — enough for the simple,
  ## non-overloaded test procs the M11 fixture uses. The resulting string is a
  ## genuine compile-time deep hash (§16.2), embedded as a literal in the binary
  ## exactly as the library would embed a test's `bodyHash` (§16.3).
  var s = sym
  if s.kind in {nnkClosedSymChoice, nnkOpenSymChoice} and s.len > 0:
    s = s[0]
  result = newLit(symBodyHash(s))

proc catalogJson*(entries: openArray[(string, string)]): string =
  ## Build a flat `{testId: bodyHash}` catalog JSON document from
  ## `(testId, bodyHash)` pairs — the shape `parseBodyHashCatalog` reads.
  var doc = newJObject()
  for (testId, hash) in entries:
    doc[testId] = newJString(hash)
  doc.pretty()
