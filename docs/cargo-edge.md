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
