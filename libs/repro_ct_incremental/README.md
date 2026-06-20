# repro_ct_incremental

Trace-based incremental testing engine for `repro watch` (prototype). It
implements the CodeTracer test runner's runtime-based incremental testing
(codetracer-specs `Planned-Features/Nim-Parallel-Test-Framework.md` §16.7):
skip re-running a test when none of the functions it previously executed have
changed.

See `docs/Trace-Based-Incremental-Testing.milestones.org` (reprobuild repo) for
the campaign plan and milestone status.

## M0

`readExecutedFunctions(traceDir)` reads a CodeTracer JSON trace
(`trace.json` + `trace_paths.json` + `trace_metadata.json`) and returns the
de-duplicated, name-sorted set of executed functions — the `Function` records
referenced by `Call` records. Depends only on `std/json` + `results`; no CTFS
binary parsing and no `codetracer-trace-format-nim` dependency (those are later
milestones).

The confirmed JSON trace schema (and the real recording it was modeled on) is
documented in `tests/fixtures/m0_three_funcs/README.md`.

## M12 — modern CTFS `.ct` ingestion

`readExecutedFunctionsCtfs(traceDirOrCtFile)` (in `ctfs_trace.nim`) reads the
executed-function set from a **modern CTFS `.ct` bundle** — the binary container
the native recorders emit — rather than the legacy 3-file JSON. It runs
`ct-print --json-events <bundle>` (from `codetracer-trace-format-nim`) and parses
the resulting `type`-tagged event array (`path`/`function`/`call`/`step`),
mapping `call.function_id → function.name` for the executed set and resolving
each function's source `file`/`defLine` best-effort from the call's `entry_step`.

Two correctness-critical details:

- **Tolerant parsing of non-UTF-8 bytes.** `--json-events` embeds recorded
  `value` payloads as a `data` string that can carry **raw non-UTF-8 bytes**
  (CBOR), so the whole dump is not valid UTF-8. The reader sanitizes invalid
  bytes to U+FFFD before `std/json` parses it; the structural records it reads
  are pure ASCII, so they are never corrupted.
- **A read error can NEVER yield a skip.** `ct-print` unavailable, an
  unresolvable/corrupt bundle, a non-zero subprocess exit, or malformed output
  all produce an `Err`. The engine turns any `Err` into a re-run.

**Backend wiring.** An interpreted-language `.ct` bundle is selected by the new
`tbSourceCtfs` backend via an explicit `recorder_backend: "ctfs-interpreted"`
metadata signal — it pairs **CTFS dependency discovery** with the **same
source-text shallow hasher** the legacy `tbSourceInterpreted` path uses (the
bundle is from an interpreted recorder, so a function's identity is its source
text). A bare `.ct` container with no explicit metadata still detects as
`tbNativeDwarf` (instruction-byte hashing), so the existing native and
source-JSON paths are untouched.

The `ct-print` resolution order is `CT_PRINT` env → `PATH` → the known build path
`/tmp/ctprint_build/ct-print`. The prototype reads CTFS via this subprocess; the
**production path** is to link `codetracer-trace-format-nim`'s reader directly
(no subprocess). The M12 fixture (`tests/fixtures/m12_ctfs/`) is a **real** `.ct`
bundle recorded from `live_demo.rb` by the native Ruby recorder.

## Supported languages (M10 — the full matrix)

CodeTracer has exactly **two** incremental-testing mechanisms (spec §16.7),
differing on both axes — dependency discovery AND shallow hashing:

| mechanism             | dependency discovery                          | shallow hash               |
| --------------------- | --------------------------------------------- | -------------------------- |
| **source/interpreted** (`tbSourceInterpreted`) | canonical `Function`/`Call` records (`readExecutedFunctions`) | source body text (extractors) |
| **native / MCR**      (`tbNativeDwarf`)         | native calltrace (`readExecutedFunctionsNative`)              | compiled instruction bytes (`shallowHashNative`) |

`languageStrategy(lang)` (in `language_matrix.nim`, re-exported from the
package) maps every language in the CodeTracer **Language-Support-Matrix**
(`codetracer-specs/Language-Support-Matrix.md`) to its expected
`(TraceBackend, dependency-discovery, shallow-hash)`. **The table is advisory:**
the engine never picks a backend by language name — `detectBackend(traceDir)`
inspects the actual trace and is the single source of truth. The table is for
reporting/validation (`backendIsExpected`) and to prove every language is
classified. An **unknown language ⇒ `Err`** (a conservative re-run, never a
guessed hash, never a silent skip).

| language    | mechanism            | expected backend(s)                         | path | validation in this prototype |
| ----------- | -------------------- | ------------------------------------------- | ---- | ----------------------------- |
| Python      | source/interpreted   | `tbSourceInterpreted`                        | source text | HAND-CRAFTED trace + REAL source extraction (m3 fixture) |
| Ruby        | source/interpreted   | `tbSourceInterpreted`                        | source text | HAND-CRAFTED trace + REAL source extraction (m0 fixture) |
| JavaScript  | source/interpreted   | `tbSourceInterpreted`                        | source text | HAND-CRAFTED trace + REAL source extraction (m3 fixture) |
| TypeScript  | source/interpreted   | `tbSourceInterpreted`                        | source text | classified (traced via the JS recorder); table-only |
| Lua         | source/interpreted   | `tbSourceInterpreted`                        | source text | table-only (classified) |
| WASM        | source/interpreted   | `tbSourceInterpreted`                        | source text | table-only (classified) |
| C           | native / MCR         | `tbNativeDwarf`                              | instruction bytes | HAND-CRAFTED calltrace + REAL compiled binary (m7/m8 fixtures) |
| C++         | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Rust        | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Go          | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Pascal      | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| D           | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Fortran     | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Ada         | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Crystal     | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Odin        | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| V           | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| Lean        | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified; partial value extraction upstream) |
| Julia       | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified; partial upstream) |
| Assembly    | native / MCR         | `tbNativeDwarf`                              | instruction bytes | table-only (classified) |
| **Nim**     | **DUAL**             | `tbSourceInterpreted` **and** `tbNativeDwarf` | per-trace (`detectBackend` wins) | BOTH arms validated: HAND-CRAFTED traces + REAL `nim c` binary (m9 fixture) |

### LIVE vs HAND-CRAFTED — an honest note

In this prototype the **traces** (the executed-function sets) are HAND-CRAFTED
in the real CodeTracer trace shapes (the JSON `Function`/`Call` form for source,
a calltrace projection for native — each documented per fixture), because a live
recorder / MCR-RR run is not available in the dev shell. What runs on **real
artifacts** is the load-bearing machinery: the **source body extraction** runs
over real source files, and the **instruction-byte hashing** runs over real
binaries the tests compile at test time (`cc` for C, `nim c` for Nim). So the
hashing + extraction + skip/rerun *decision logic* is exercised for real on
every milestone; the trace *ingestion* uses fixtures whose shapes are pinned to
the real schemas.

The representative end-to-end coverage (M10) proves both MECHANISMS — one
interpreted language (Python), one native (C), and Nim on BOTH arms — drive a
correct skip AND a correct rerun through the SAME engine, with only the strategy
varying.

See `docs/Trace-Based-Incremental-Testing.milestones.org` (M10) for the same
table with full matrix citations and the campaign acceptance criteria.
