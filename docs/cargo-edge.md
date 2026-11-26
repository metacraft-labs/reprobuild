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
the absolute path of the directory the recordings go into (a build-script stub
runs in its package's directory, so a relative path is refused). The directory
should be empty when the run starts; the wrapper cannot tell where a run
starts, so that is the caller's check. Record mode is independent of
`REPRO_RUSTC_WRAPPER`, and it never connects to the resource manager, takes no
sub-lease and starts no measurement, because nothing is compiled. It is
refused on Windows until drive-letter paths are rewritten against the roots.

- **A compile unit is recorded and not run.** The wrapper writes an empty file
  for each output the unit's `--emit` asks for, with the names `rustc` would
  have used (under `--out-dir`, with `-C extra-filename`), and exits 0. Cargo
  finds the files it expects and starts the dependents.
- **Only probes pass through.** A line runs the real compiler only when it is
  positively a probe: it names no crate (`rustc -vV`, `--version`,
  `--print sysroot`), it is cargo's target-info call (crate `___`), or it
  reads its source from standard input. Cargo needs their answers (a build
  script's `TARGET`, `HOST` and `CARGO_CFG_*` come from them). Any other line
  that names a crate is recorded, even one that carries `--print` (a
  project's `build.rustflags` can add `--print=native-static-libs` to every
  unit) or lacks cargo's `--error-format=json`. `@path` argument files are
  expanded before a line is classified, and the expanded arguments are what
  is recorded.
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
- **Paths are recorded against the declared logical roots.**
  `REPRO_RUSTC_WRAPPER_RECORD_ROOTS` holds `<label>=<absolute path>` lines
  (the checkout, the store, the scratch target directory). A path under one of
  them, in its given or its resolved spelling, is written as `${<label>}` and
  the rest of the path, and a literal `$` as `$$`. Only the declared roots are
  rewritten: the home directory, `TMPDIR` and `PATH` entries outside them stay
  physical, and which variables the record run sees at all is up to its
  caller. The rewriting fails closed: a recording in which any spelling of a
  root is still present anywhere is refused, and so is a `links` provider in
  a path member outside every root.
- **The record run's own variables are not recorded.** The three
  `REPRO_RUSTC_WRAPPER_RECORD*` variables and every `RUNQUOTA_*` variable
  describe the record run (its directory, its lease, its session), not the
  build, and would make every recording differ from the last.

Each recorded process writes one JSON file (`"format": "repro-rustc-record-v1"`)
with its `kind` (`unit` or `build-script-run`), `argv`, `cwd` and `env`; a unit
adds the placeholders it wrote, a run the manifest it matched and the lines it
printed. Use a scratch target directory for a record run, never the project's
`target/`: the placeholders would enter cargo's freshness state and a later
real build would trust them.

## The plan: a record run as a graph-production edge

The record run is wrapped in one build-graph edge, `cargo.plan/<workspace>`,
whose process is `repro-rustc-wrapper --cargo-plan` and whose one output is the
**plan**: every unit and build-script run cargo would start, with its command
line, working directory and environment, and the links between them. Nothing is
compiled and no build script runs.

```sh
repro-rustc-wrapper --cargo-plan --plan FILE --scratch DIR \
    --cargo CARGO --rustc RUSTC [--store-root DIR] -- [CARGO ARGS...]
```

- **The edge.** It runs in the workspace root, monitored, with its inputs
  checked by content, from a closed environment (the project's development
  environment and nothing of the engine's own), and with the network denied.
  It runs after the edges that fetch the workspace's registry crates and
  declares their store prefixes as inputs. It is relocatable: its argv and
  its output are relative to the workspace root, its key holds the depth of
  the workspace root rather than its path, and the tools and stores it
  reaches by absolute path are its relocation anchors, so two checkouts of
  one workspace give it the same key.
- **Scratch.** The edge has one scratch directory, which the engine empties
  before the run and never counts as evidence. It holds the recordings, the
  scratch target directory with its placeholders, the saved `cargo metadata`,
  and an empty `CARGO_HOME` and `HOME` for cargo; the run refuses to start if
  any of those directories is not empty or the saved metadata already exists.
- **Cargo's run.** `cargo metadata --offline --locked`, then `cargo build
  --offline --locked -j 1 --target-dir <scratch>/target` with the given
  arguments and four `--config` values: the record wrapper as
  `build.rustc-wrapper`, the compiler as `build.rustc`, an empty
  `build.rustc-workspace-wrapper` (a project's own workspace wrapper would
  otherwise run between the record wrapper and rustc), and `build.build-dir`
  set to the scratch target directory (a project's `build.build-dir` would
  otherwise move cargo's intermediate files, placeholders included, outside
  the scratch directory). The command line keeps them out of a compile's
  environment and outranks configuration files and `CARGO_BUILD_*`
  variables. `RUSTC`, `RUSTC_WRAPPER` and `RUSTC_WORKSPACE_WRAPPER` outrank
  it (measured for `RUSTC_WRAPPER` with cargo 1.94), so an environment that
  sets one is refused. `-j 1` makes the `NUM_JOBS` a build script receives
  the same on every host.
- **What it refuses.** Cargo arguments other than the build's selection
  (`--release`, `--profile`, `--target`, `-p`/`--package`, `--workspace`,
  `--exclude`, `--lib`, `--bin`, `--bins`, `--features`, `--all-features`,
  `--no-default-features`); a cargo configuration file in a directory above
  the workspace root, which cargo would read; a workspace package whose
  manifest lies outside the workspace root; and, for now, a `Cargo.lock`
  that holds any package with a `source` (registry dependencies would reach
  cargo through a source replacement over the fetched store prefixes, which
  the run does not write yet).

**The derivation** turns the recordings into the plan, reading every link
from paths cargo wrote: a unit's `--extern` paths name the units it consumes;
its `OUT_DIR` is the one its package's build-script run received; a run's
executable lies in the output directory of the build-script compile that
wrote it; each sentinel names the run that feeds it. Paths are recorded
against the logical roots `project`, `store`, `nix` (the Nix store, where
there is one) and the run's own `target` and `scratch`. Paths under the
scratch target directory are rewritten into one output directory per unit
under the `${out}` root, `<package>-<version>-<hash>` with cargo's own
`-C extra-filename` hash: the unit's `--out-dir`, outputs and incremental
directory, a run's `OUT_DIR`, and, because every unit has its own directory,
cargo's one `-L dependency=` under the target directory (and a `deps` or
profile directory on a dynamic-library path) becomes one entry per unit of
the closure. A sentinel becomes a slot, `${slot:<kind>:<run>}`, standing for
the whole group of arguments cargo emitted for it. A unit with a slot or an
`OUT_DIR` is *fed* by a build-script run and is completed when that run's
output is known; a build-script run is fed too when a build-dependency's
link-search path (inside its `OUT_DIR`) is on its dynamic-library path.
Environments are stored as the difference from the record run's own; the
variables cargo documents setting for a crate or a build script are kept
even when their value is the same, and the run's own variables
(`RUSTC_WRAPPER` naming the record wrapper, `CARGO_MAKEFLAGS`, jobserver
descriptors) and those cargo's own process sets for itself (`SSL_CERT_FILE`,
`SSL_CERT_DIR`) are dropped. A path the derivation cannot place, a scratch
path, a sentinel left anywhere, an absolute path under no logical root, a
program between the record wrapper and rustc's arguments, or a plan with no
unit fails the edge.

**The format.** The plan is a fixed-schema binary record: a length-prefixed
magic (`reprobuild.cargoPlan.v1`), a 16-bit schema version (2), a 32-bit
payload length and an SSZ payload (`repro_cargo_edge/cargo_plan`). Every list
is bounds-checked when it is written, and a plan read back is checked for
unique ids, resolved references and outputs inside their units' directories.
It is read back by the edges built from it; the JSON recordings it was
derived from stay inside the edge.
