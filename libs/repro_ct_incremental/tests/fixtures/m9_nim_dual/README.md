# m9_nim_dual — Nim's dual recording path (M9)

A single Nim program (`src/calc.nim`) that CodeTracer can record **two ways**,
proving the incremental engine picks its shallow-hash strategy **per trace by
backend detection** — never by the language name (CodeTracer
Language-Support-Matrix, "Nim dual-path").

## The two paths

| path                | trace dir        | `detectBackend` ⇒    | shallow hash                     |
|---------------------|------------------|----------------------|----------------------------------|
| materialized source | `trace_source/`  | `tbSourceInterpreted`| `.nim` SOURCE extractor (text)   |
| native / MCR (via C)| `trace_native/`  | `tbNativeDwarf`      | compiled INSTRUCTION BYTES       |

* **Source path** — `trace_source/` is a canonical CodeTracer JSON trace
  (`trace.json` + `trace_paths.json` + `trace_metadata.json`) in the exact
  schema the M0/M3 fixtures use (externally-tagged `Function`/`Call` records).
  Its `recorder_backend: "interpreter"` makes the source path explicit. CodeTracer
  records Nim at the source level here, so a proc's identity is its SOURCE TEXT,
  hashed by the `.nim` extractor (indentation-delimited proc bodies — registered
  in `extractors.nim`, reusing the Ruby/Python indentation strategy).

* **Native path** — `trace_native/` carries a native structural signal
  (`trace_db_metadata.json`, `recorder_backend: "rr"`) and a native calltrace
  (`native_calltrace.json`). The committed calltrace is **illustrative**: the
  test compiles the SAME `calc.nim` with `nim c` (via `build.sh`) into a temp
  dir and regenerates the calltrace pointing at that fresh binary, with each
  `functionName` set to the MANGLED symbol discovered by running `nm` on the
  binary (see below). A proc's identity is then its compiled INSTRUCTION BYTES,
  hashed by `native_hash.shallowHashNative`.

## Why the native names are discovered from the binary, not hardcoded

Nim mangles proc names when compiling via C. With this fixture's `-g` build the
dev-shell Nim emits an **Itanium-style** symbol, e.g. proc `usedA` in module
`calc` becomes `_ZN4calc5usedAE` (verified with `nm`); without `-g` it emits
`usedA__<modulehash>_uN` with a build-specific declaration-order suffix that
shifts when an earlier proc is edited. Either way the symbol is NOT the source
identifier, so the native calltrace's `functionName`s must be read from the
binary's own symbol table at test time (`t_nim_dual.nim`'s `mangledName`), so
`shallowHashNative` can locate each function.

## Layout that makes the native unexecuted-edit a genuine skip

The executed set is exactly the two pure, position-independent leaves
`{usedA, usedB}`. `mainCalc` (the only call-containing, relocation-sensitive
proc) is excluded from the executed set, and `unusedC` is emitted-but-not-
executed (referenced behind a runtime-false guard so the C backend keeps it).
`unusedC` is declared AFTER the executed leaves, so editing/growing it cannot
change the leaves' instruction bytes (they relocate but their
position-independent bytes are identical) nor — under the alternative `_uN`
mangling — renumber their symbols. The test asserts both empirically (the
executed leaves' instruction-byte hashes and symbol names are unchanged across
the `unusedC` edit, while `unusedC`'s own hash changes), so the skip is real,
not coincidental.

## Re-recording (live)

A live re-record would replace the hand-crafted fixtures with real CodeTracer
output: record `calc.nim` with the Nim source recorder for `trace_source/`, and
record the `nim c`-compiled binary with the native MCR/RR recorder for
`trace_native/`. Neither recorder is prebuilt in this dev shell, so — exactly as
the Phase-1 and M7/M8 fixtures do — the traces are hand-crafted in the real
schema (canonical Function/Call for source; the documented native-calltrace
projection for native, see `native_trace.nim`).

## Building the native binary by hand

```
bash build.sh src/calc.nim /tmp/calc
nm -n --defined-only /tmp/calc | grep -E 'usedA|usedB'
```
