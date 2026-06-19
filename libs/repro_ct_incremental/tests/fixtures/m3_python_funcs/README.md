# M3 fixture: `m3_python_funcs`

A tiny Python program (`src/three_funcs.py`) plus a CodeTracer JSON trace
(`trace/`) used by the M3 multi-language tests of the
Trace-Based-Incremental-Testing prototype. It proves the engine is
language-agnostic: the SAME `decide()`/`record()` engine drives Python via the
`.py` indentation extractor, with no per-language branching outside the
extractor.

## The program

`main` calls `used_a` and `used_b`. `unused_c` is defined but never called. So
the executed-function set is exactly `{main, used_a, used_b}` and `unused_c`
must be absent. Definition lines (1-based) are pinned in the source comment and
in the trace's `Function` records: `used_a`=20, `used_b`=24, `unused_c`=28,
`main`=32.

## Extraction strategy (Python)

Python is indentation-delimited. The `.py` extractor
(`src/repro_ct_incremental/extractors.nim`) captures each body from the `def`
line through the last line indented deeper than the `def` line (the next line
at `<= def indent` ends the suite). This is a genuinely indentation-based
strategy — distinct from the brace-based JavaScript extractor.

## Trace schema (same real schema as M0)

`trace.json` + `trace_paths.json` + `trace_metadata.json`, identical to the M0
`m0_three_funcs` fixture — see that fixture's README for the full confirmation
of the real CodeTracer JSON schema
(`codetracer-trace-format/codetracer_trace_writer`, externally-tagged
`Vec<TraceLowLevelEvent>`). Executed functions = the `Function` records
referenced by `Call` records; this trace's call stream references `function_id`
0/1/2 (`main`/`used_a`/`used_b`) and never 3 (`unused_c`).

## Live-recording validation (deferred)

This trace was hand-crafted in the real CodeTracer JSON schema, exactly as the
M0 fixture was. The real Python recorder
(`codetracer-python-recorder`) is a PyO3/Rust extension that is not prebuilt in
this dev environment (no compiled `.so`; building it requires a full
Rust+maturin build in its own nix shell). Live-recording validation with the
real recorder is therefore deferred. The property the M3 tests exercise — the
executed-function SET and per-function source extraction — is fully determined
by the schema fields above, which match the M0-confirmed real schema. To
re-record with the real recorder once available:

```
# inside codetracer-python-recorder's dev shell, once the extension is built
python -m codetracer_python_recorder --trace-out <dir> src/three_funcs.py
# (then point the trace fixture at <dir>'s trace.json/trace_paths.json/…)
```
