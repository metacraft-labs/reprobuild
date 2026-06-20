# m6_backends — backend-detection fixtures (M6)

Tiny trace directories that exercise `backends.detectBackend` over every
detection branch. They carry NO executed-function payload of their own — M6 is
about selecting the right backend by trace SHAPE / metadata, not about running a
decision (the `source_path_unchanged_through_abstraction` test reuses the real
m0/m4 trace fixtures for that).

Detection precedence (see `backends.detectBackend`): an explicit
`recorder_backend` string field in `trace_metadata.json` or
`trace_db_metadata.json` WINS over structure; otherwise structure decides.

| fixture                  | shape / metadata                                  | expected backend          |
|--------------------------|---------------------------------------------------|---------------------------|
| `source_canonical/`      | canonical `trace.json` (+ `trace_paths.json`)     | `tbSourceInterpreted`     |
| `native_rr/`             | an `rr/` subdir                                    | `tbNativeDwarf`           |
| `native_ctfs/`           | a `*.ct` CTFS container file                       | `tbNativeDwarf`           |
| `native_dbmeta/`         | a `trace_db_metadata.json` (no explicit field)    | `tbNativeDwarf`           |
| `empty_ambiguous/`       | no signal at all (only an unrelated README)       | `Err`                     |
| `both_ambiguous/`        | BOTH a `trace.json` AND an `rr/` subdir           | `Err` (ambiguous)         |
| `meta_override_native/`  | canonical `trace.json` + `recorder_backend: rr`   | `tbNativeDwarf` (override)|
| `meta_override_source/`  | `rr/` subdir + `recorder_backend: interpreter`    | `tbSourceInterpreted`     |

## Relation to real CodeTracer traces

- A **canonical** `trace.json` is the externally-tagged `TraceLowLevelEvent`
  array emitted by `codetracer-trace-format` (the same shape the M0 fixture
  README documents). Its presence means the source/interpreted path.
- An **`rr/`** subdir is the RR replay capture of the native / Multi-Core
  Recorder (MCR) path; a **`*.ct`** file is the CTFS binary trace container; a
  **`trace_db_metadata.json`** is the native trace-db sidecar. Any of these is a
  native-shape signal. The fixtures here are placeholders (the directory / file
  exists but is not parsed) because M6 detects by shape only; M7-M9 add the real
  native trace + binary fixtures.
- The **`recorder_backend`** field mirrors the recorder identifiers used across
  CodeTracer recorders (`rr` / `mcr` / `ttd` ⇒ native, `interpreter` ⇒ source,
  `nim-instrumented` ⇒ the reserved Nim instrumented path). When present it is
  authoritative, so a trace recorded by an unusual pipeline can declare its
  backend explicitly instead of relying on structure heuristics.
