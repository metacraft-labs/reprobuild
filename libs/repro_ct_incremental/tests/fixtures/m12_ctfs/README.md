# m12_ctfs — modern CTFS `.ct` bundle fixture (M12)

A **real** CodeTracer CTFS bundle (`ruby.ct`) plus its Ruby source
(`live_demo.rb`), used by the M12 CTFS-reader tests
(`tests/t_ctfs_reader.nim`). This is the first fixture that consumes the
**modern CTFS `.ct`** trace format (what the native recorders emit) rather than
the legacy 3-file JSON or a hand-crafted native calltrace.

## Files

- `ruby.ct` — a real, binary CTFS bundle (143 KB) recorded from `live_demo.rb`
  by the **native Ruby recorder** (the Rust-extension recorder, NOT the
  pure-Ruby oracle). Committed as a binary fixture.
- `live_demo.rb` — the recorded source. Its function definition lines are pinned
  (used by `engine_decides_over_ctfs`):

  | line | function       | executed? |
  |------|----------------|-----------|
  | 1    | `used_a`       | YES       |
  | 2    | `used_b`       | YES       |
  | 3    | `unused_c`     | NO (defined but never called — absent from the trace) |
  | 4    | `main`         | YES       |
  | 5    | `main` (call)  | (top-level call site) |

  The bundle's executed-function set is exactly
  **{`<top-level>`, `main`, `used_a`, `used_b`}**; `unused_c` is absent (it is
  never called, so the recorder never even emits a `function` record for it).

## How the bundle was recorded

```sh
# Build the native Ruby recorder in its own dev shell:
direnv exec /Users/zahary/m/dev/codetracer-ruby-recorder bash -c 'just build'

# Record live_demo.rb into a CTFS bundle:
direnv exec /Users/zahary/m/dev/codetracer-ruby-recorder bash -c \
  'gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder --out-dir <dir> live_demo.rb'
# The resulting <dir>/<...>.ct was copied here as ruby.ct.
```

The recorded source path inside the bundle is `/tmp/live_demo.rb`; the engine
strips the leading `/` and resolves it under `sourceRoot`, so the
`engine_decides_over_ctfs` test mirrors the source at
`<sourceRoot>/tmp/live_demo.rb`.

## The modern CTFS event-dump format (what the reader consumes)

The reader (`src/repro_ct_incremental/ctfs_trace.nim`) reads the bundle via the
`ct-print --json-events <bundle>.ct` subprocess (the documented prototype
stand-in for linking `codetracer-trace-format-nim`'s reader directly). That
emits a JSON **array** of `type`-tagged objects:

```json
{ "type": "path",     "path_id": 0, "name": "/tmp/live_demo.rb" }
{ "type": "function", "function_id": 2, "name": "used_a" }
{ "type": "call",     "function_id": 2, "function": "used_a", "entry_step": 9 }
{ "type": "step",     "step_index": 9, "path": "/tmp/live_demo.rb", "line": 1, ... }
```

Executed functions = the distinct functions referenced by `call` records
(`function_id → function.name`). Each call's `entry_step` resolves, best-effort,
to the step carrying the function's entry `path`/`line` (its definition site),
giving the `file`/`defLine` the source extractor needs.

**Tolerant parsing:** `--json-events` embeds recorded `value` payloads as a
`data` string that can contain **raw non-UTF-8 bytes** (CBOR). The whole blob is
therefore NOT valid UTF-8; the reader sanitizes invalid bytes to U+FFFD before
parsing (the structural `path`/`function`/`call`/`step` records are pure ASCII,
so they are never corrupted). See `ctfs_trace.nim`'s module doc.

## ct-print

The tests need `ct-print` from `codetracer-trace-format-nim`. The test setup
builds it once into `/tmp/ctprint_build/ct-print` (or honours `CT_PRINT`). Build
command (run in the trace-format-nim dev shell):

```sh
nim c -d:release --mm:arc -p:src \
  --passC:"$(pkg-config --cflags libzstd)" \
  --passL:"$(pkg-config --libs libzstd)" \
  -o:/tmp/ctprint_build/ct-print src/codetracer_ct_print.nim
```
