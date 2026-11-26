# Cargo in a Reprobuild build: the thin cargo edge

Reprobuild builds a Rust project by letting cargo build it. The edge around
cargo does four things and leaves everything else to cargo.

1. **The width.** The edge is sized: it asks the resource manager for a range of
   slots and passes the granted number to cargo as `-j`. cargo is the jobserver
   of its own `rustc` and build-script processes, so one flag bounds the whole
   tree. The same holds for `cargo test` and for `cargo nextest run`, whose
   `--test-threads` follows the grant.
2. **The target directory is cargo's.** `target/` is cargo's incremental
   state, a cache the tool owns. The edge neither declares it as an output nor
   clears it, so editing one crate recompiles that crate. (Declaring it an
   opaque output, one the engine removes before every run, recompiles every
   unit: the cost of discarding cargo's state.)
3. **Final products come from cargo.** The edge runs cargo with
   `--message-format=json-render-diagnostics` and reads which executables and
   `cdylib`/`staticlib` outputs the project's own packages produced. Paths are
   never predicted from cargo's naming rules. The answer is written to a file
   that is the edge's declared output, and rewritten only when it changes.
4. **Per-crate totals (optional).** `repro-rustc-wrapper` can stand in front
   of `rustc` and report each unit's CPU time and peak memory under a key naming
   the crate, so the next build can be sized by what each crate cost.

## `repro cargo run`

```sh
repro cargo run [-j N] [--products FILE] [--fragment FILE --action-id ID] \
                [--relative-to DIR] [--libs] -- cargo build --release
```

Runs the cargo command after `--` with the JSON message format added (and
`-j N` when given), passes everything that is not a cargo message through, and
writes the final products to `--products` (one path per line) and/or to
`--fragment` (a dynamic-graph fragment declaring them as outputs of
`--action-id`). A product cargo names must exist. A failed build removes both
files: a consumer never reads the products of a build that no longer exists.
`--libs` also lists the project's own `rlib`s.

## The rustc wrapper

Cargo runs `$RUSTC_WRAPPER rustc <args>` for every unit. `repro-rustc-wrapper`
runs `rustc <args>` and, inside a leased action, records the unit's totals.

- It **never changes** the command line, the environment or the standard
  streams of the compiler, and it ends the way the compiler did (same exit code,
  or the same signal). A project's own wrapper (`sccache`, a logging shim) keeps
  running, in front of `rustc`, exactly where cargo would have run it.
- It **falls back to running the compiler unchanged** whenever it cannot
  report: no resource manager, no enclosing lease, a manager too old to grant
  sub-leases, a sub-lease that is not granted within two seconds.
- It never takes a host-wide lease. The compile already runs inside its
  action's grant, so the report is a sub-lease of that grant, of one thousandth
  of a slot: it records and claims no capacity, because more compiles can be
  running than the action's width (cargo pipelines a crate's code generation
  behind the metadata its dependents wait for).
- The key is `rustc/<crate>/<crate types>/o<opt level>`; a `--test` harness is
  `test`. Probes (`rustc -vV`, `--print`, and the compiles a build script runs
  to test the compiler, which name their crate but do not pass cargo's
  `--error-format=json`) are not units.
- Totals are what the kernel returns when the wrapper reaps the compiler. The
  client-side `profiles` and `tree-sampling` measurements, when switched on
  (`RUNQUOTA_MEASUREMENT`), also take a CPU profile of the compile, under the
  resource manager's overhead budget.

The wrapper is **off by default**: its overhead has not been certified against
the resource manager's budget yet. The engine installs it into sized cargo
actions when `REPRO_RUSTC_WRAPPER=on` and the wrapper executable sits beside
the engine (or is named by `REPRO_RUSTC_WRAPPER_PATH`).
`REPRO_RUSTC_WRAPPER=off` turns it off.

## Record mode: cargo's plan without a compile

Stable cargo has no interface that prints, before it builds, the command line,
working directory and environment it would give each `rustc` call and each
build-script run (`--unit-graph` is unstable and carries no command lines;
`--build-plan` was removed). The wrapper's **record mode** learns them by
letting cargo run its whole schedule while every step does nothing but record
what cargo asked for. It is switched on by `REPRO_RUSTC_WRAPPER_RECORD`, set to
the directory the recordings go into; it is independent of
`REPRO_RUSTC_WRAPPER`, and it never takes a sub-lease or starts a
measurement, because nothing is compiled.

- **A compile unit is recorded and not run.** The wrapper writes an empty file
  for each output the unit's `--emit` asks for, with the names `rustc` would
  have used (under `--out-dir`, with `-C extra-filename`), and exits 0. Cargo
  finds the files it expects and starts the dependents.
- **Probes pass through.** `rustc -vV`, `--print …` and cargo's target-info
  call run the real compiler: they compile nothing, and cargo needs their
  answers (a build script's `TARGET`, `HOST` and `CARGO_CFG_*` come from them).
- **A build script is replaced by a recording stub.** For a build script's
  compile the wrapper writes a copy of itself as the executable. When cargo
  runs it, it records the argv, working directory and environment cargo gave
  the build script, prints one *sentinel* directive of each kind a build
  script can pass to a compile (`rustc-cfg`, `rustc-check-cfg`, `rustc-env`,
  `rustc-link-lib`, a `rustc-link-search` inside and one outside `OUT_DIR`,
  and the `rustc-link-arg*` variants for the targets the package has), and
  exits 0. Each sentinel's value is `__repro_slot.<kind>.<run>`, where `<run>`
  is the directory cargo made for that build-script run, so the recordings of
  the compiles show where cargo itself placed each kind of directive. A
  package with `links` also prints `cargo:__repro_provider=<provider>`, and
  cargo hands it to its immediate dependents' build scripts as
  `DEP_<LINKS>___REPRO_PROVIDER`. The stub reads its package's targets from
  the output of `cargo metadata --offline --format-version 1`, saved to the
  file `REPRO_RUSTC_WRAPPER_RECORD_METADATA` names, because cargo refuses a
  `rustc-link-arg-bin` for a binary the package does not have.
- **Paths are recorded against logical roots.** `REPRO_RUSTC_WRAPPER_RECORD_ROOTS`
  holds `<label>=<absolute path>` lines (the checkout, the store, the scratch
  target directory). A path under one of them is written as `${<label>}` and
  the rest of the path, and a literal `$` as `$$`, so a recording names no
  physical path of the machine that made it.

Each recorded process writes one JSON file (`"format": "repro-rustc-record-v1"`)
with its `kind` (`unit` or `build-script-run`), `argv`, `cwd` and `env`; a unit
adds the placeholders it wrote, a run the manifest it matched and the lines it
printed. Use a scratch target directory for a record run, never the project's
`target/`: the placeholders would enter cargo's freshness state and a later
real build would trust them.
