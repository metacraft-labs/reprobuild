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

## M13 — LIVE-recording integration tests

M13 replaces hand-crafted traces with **live recordings from the production
recorders** wherever the recorder builds and records on the host. The test-support
harness `tests/live_record.nim` builds a recorder in ITS OWN Nix dev shell
(`direnv exec <recorder-repo> <build>`, the CodeTracer build-siblings strategy),
records a small program into a modern CTFS `.ct` bundle, and hands the bundle to
the SAME `record()`/`decide()` engine. Builds are cached (build-once): each
recorder exposes a cheap on-disk *built-marker* and the heavy build runs only when
the marker is absent; `ct-print` reuses the M12 known-build-path cache.

A recorder that genuinely cannot build/record on the host does NOT produce a
`unittest.skip`. The harness returns a `RecorderOutcome` that distinguishes a
real `.ct` (`roSuccess`) from a **documented gate** (`roGated`, carrying the
EXACT captured failure); the per-language test then emits a LOUD, ASSERTED gate.

### Validated LIVE vs gated (this host: arm64 macOS)

Three languages record **genuinely live** here (Ruby, Python and JavaScript); the
native path is **platform-gated** (RR is Linux-only). None of the gates is a wrong
dev shell or a missing package install — and the JS "upstream break" a prior
revision claimed was a **stale-sibling misdiagnosis**, now corrected.

| language | status on this host | how |
|----------|---------------------|-----|
| **Ruby** | ✅ **LIVE, end-to-end** (required, passes) | native Rust-extension recorder; `just build` then `codetracer-ruby-recorder --out-dir <dir> prog.rb` |
| **Python** | ✅ **LIVE, end-to-end** (required, passes) | maturin/PyO3 recorder; `just venv 3.13 dev` (build once) then `.venv/bin/python -m codetracer_python_recorder --out-dir <dir> prog.py`. Builds + records here after the recorder's **flake fix gating `cargo-llvm-cov` off darwin** (pushed upstream); the prior "dev shell won't build" gate used the WRONG entry (`just dev` + `uv`). |
| **JavaScript** | ✅ **LIVE, end-to-end** (required, passes) | SWC instrumenter + napi-rs native runtime; `just build` then `node packages/cli/dist/index.js record --out-dir <dir> prog.js` (bundle nests under `<out-dir>/trace-N/`). Builds + records here once the workspace siblings `codetracer-trace-format` + `codetracer-trace-format-nim` are **synced to mainline**; the prior "napi addon won't compile / `enable_column_*_support` missing" gate was caused by STALE sibling checkouts (old writer API → build failure, then SIGSEGV at record time), NOT a genuine upstream break. |
| **Native / Nim (MCR/RR)** | ⛔ **GATED** — platform/format limitation (build+record OK) | `ct-mcr` (from `ct_cli`) **builds clean** on arm64-macOS and **records a real `.ct`** (exit 0, ~200 events). The gate is downstream: the native `.ct` decodes via `ct-print --json-events` to only a `path` record (no `Function`/`Call` events here), and the engine's native backend still reads a legacy `native_calltrace.json` sidecar the modern CTFS recorder no longer writes. Full function-level native traces need a Linux MCR/RR host; wiring the native backend to the modern CTFS `.ct` is the documented follow-up. (The prior "recorder CI red on main+dev / license FFI can't load" gate was a misdiagnosis — corrected.) |

The real, validated commands per recorder live in `tests/live_record.nim`
(`recordRubyLive` / `recordPythonLive` / `recordJsLive` / `recordNativeLive`).
**Ruby and Python are genuinely live** here: a real `.ct` is recorded at test
time and the engine's skip/rerun decisions are made from that live bundle's
executed set — Ruby ({`<top-level>`, `main`, `used_a`, `used_b`}), Python
({`<__main__>`, `main`, `used_a`, `used_b`}); `unused_c` is never called and is
absent from both. The JS and native gates are HONEST: each ATTEMPTS the real
build/record, prints the underlying captured failure (the JS compiler error / the
native license-FFI load failure), and asserts a documented gate that states the
VERIFIED upstream-break root cause — never a hidden skip, never a hand-crafted
substitute, never the old "dev shell won't build" misdiagnosis.

Tests: `t_live_ruby.nim` and `t_live_python.nim` (LIVE, must pass here),
`t_live_js.nim`, `t_live_native.nim` (attempt-or-gate against verified CI-red
upstream breaks), and `t_live_full_suite.nim`
(`full_suite_green_with_live_recordings` — compiles and runs every campaign test
file and asserts all exit 0).

## M11 — compile-time `symBodyHash` deep path (deep when reported; shallow retained)

When the CodeTracer Nim unit-testing library reports a per-test compile-time
**deep** hash (`symBodyHash`, spec §16.2) in its `--list-json` catalog (§16.3),
the engine compares that hash DIRECTLY: equal ⇒ skip, differ ⇒ re-run, with **no
trace and no shallow hashing** (§16.5/§3.7). `symBodyHash` already folds the
test's entire transitive call graph into one digest, so it *is* the deep hash.

- Catalog reader: `src/repro_ct_incremental/catalog.nim` →
  `BodyHashCatalog` (`test → bodyHash`). Accepts the flat `{testId: bodyHash}`
  shape and the §16.3 `--list-json` `{tests:[{name,bodyHash}]}` shape.
- Deep decision: `engine.decideByCatalog` (no trace); `engine.recordBodyHash`
  records a test purely by its deep hash.
- **Tiered selector**: `engine.decideTiered` is
  *deep-when-the-library-reports-it, shallow-otherwise* — it uses the catalog
  deep path iff a `bodyHash` is reported for the test, else dispatches to the
  existing runtime **shallow** `decide` (M1/M9). The shallow path is **retained
  on purpose**: every non-Nim language, and Nim built without the library, has
  no catalog `bodyHash`, so removing it would break the no-library case.

Catalog source here is **path 1b**: the in-tree `ct_test_unittest_parallel`
`--list-json` does not yet emit `bodyHash` (its `emitListJson` writes only
`name`/`suite`/`file`/`line`), so M11 produces a **genuine** `symBodyHash`
catalog with `std/macros.symBodyHash` via the
`tests/symbodyhash_catalog.nim` macro — not a hand-invented hash. A static
`symBodyHash` may over-estimate the dynamic dependency set, which only ever
causes *more* re-runs (always safe), never a false skip.

Tests: `t_symbodyhash.nim`.

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
