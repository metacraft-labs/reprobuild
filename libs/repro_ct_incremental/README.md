# repro_ct_incremental

Trace-based incremental testing engine for `repro watch` (prototype). It
implements the CodeTracer test runner's runtime-based incremental testing
(codetracer-specs `Planned-Features/Nim-Parallel-Test-Framework.md` §16.7):
skip re-running a test when none of the functions it previously executed have
changed.

See `docs/Trace-Based-Incremental-Testing.milestones.org` (reprobuild repo) for
the campaign plan and milestone status.

## M0 (current)

`readExecutedFunctions(traceDir)` reads a CodeTracer JSON trace
(`trace.json` + `trace_paths.json` + `trace_metadata.json`) and returns the
de-duplicated, name-sorted set of executed functions — the `Function` records
referenced by `Call` records. Depends only on `std/json` + `results`; no CTFS
binary parsing and no `codetracer-trace-format-nim` dependency (those are later
milestones).

The confirmed JSON trace schema (and the real recording it was modeled on) is
documented in `tests/fixtures/m0_three_funcs/README.md`.
