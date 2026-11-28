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
    --cargo CARGO --rustc RUSTC [--store-root DIR] \
    [--crate NAME@VERSION=PREFIX]... -- [CARGO ARGS...]
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
- **Registry crates.** Each crates.io crate of `Cargo.lock` is given with the
  store prefix its fetch edge made (`--crate`). A `directory` source needs a
  `.cargo-checksum.json` in every crate directory and a prefix is a read-only
  extraction without one, so the run writes, in its scratch directory, a
  vendor directory with one entry `<name>-<version>` per crate: a symbolic
  link to each top-level entry of the prefix and a `.cargo-checksum.json` of
  `{"files":{},"package":"<checksum from Cargo.lock>"}`. Two `--config`
  values replace `crates-io` with it, for `cargo metadata` and `cargo build`.
  The prefixes are only read, and the derivation maps each vendor entry back
  to the prefix it links to, from the entries the run wrote.
- **What it refuses.** Cargo arguments other than the build's selection
  (`--release`, `--profile`, `--target`, `-p`/`--package`, `--workspace`,
  `--exclude`, `--lib`, `--bin`, `--bins`, `--features`, `--all-features`,
  `--no-default-features`); a cargo configuration file in a directory above
  the workspace root, which cargo would read; a workspace package whose
  manifest lies outside the workspace root; a `Cargo.lock` package from a
  source other than crates.io (git, another registry); a crates.io package
  with a malformed name, version or checksum, no `--crate` prefix, or a
  prefix that is not that crate's store prefix (spelled with `..`, resolving
  outside the store root, not named for the crate's name, version and
  checksum, or holding another package's manifest); a `--crate` given twice
  or for a crate the lock does not hold; a `[patch]` or `[replace]` table in
  the workspace's `Cargo.toml`; and `paths`, `[source]`, `[patch]` or
  `include` in its `.cargo/config.toml` or `.cargo/config`.
- **What it checks after `cargo metadata`.** Cargo's workspace root is the
  working directory (not an enclosing workspace with its own lock), and every
  package with a source was read from exactly its vendor entry's
  `Cargo.toml`: whatever a configuration might do to re-route a source,
  cargo's own answer must show each crate coming from the store.

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

## Edges from the plan: library and binary units

`repro_cargo_edge/plan_units` turns a plan into build-graph edges, one rustc
edge per unit, `cargo.rustc/<package>@<version>-<hash>` with cargo's own
hash. In a workspace these edges cover, every library and binary unit comes
from the plan, workspace members as well as crates.io crates, so a member's
features and cfgs are the ones cargo's feature unification gave it across the
whole build, never ones derived from the manifests or `cargo metadata`.

- **What an edge runs.** The unit's command line exactly as cargo wrote it,
  in the working directory cargo used, with the plan's roots expanded on this
  host (`${project}`, `${store}`, `${nix}`, and `${out}`, the output root the
  caller gives). A crates.io crate's edge adds one flag,
  `--remap-path-prefix=<prefix>=<name>-<version>`, as the registry-crate edge
  always has (`repro_cargo_fetch/crate_compile.registryCrateUnitEdge`, which
  also checks that the store holds the crate and refuses one that needs a
  build script, a proc-macro or `links`). A member's edge runs cargo's command
  line unchanged.
- **The environment.** Each edge is launched from its declared environment
  alone: the variables cargo set for the unit, plus the toolchain variables
  the caller names (the `PATH` that finds the linker). The project's
  development environment is not given to a compile, and neither are the
  variables a shell-script `cargo` (such as a dev shell's) changes for itself
  (`PATH`, `SHLVL`, `PWD`, `OLDPWD`, `_`), so the toolchain's `PATH` is an
  edge's only `PATH` and a dev-shell change does not change an edge's key. A
  toolchain variable that cargo also set, or removed, for a unit is refused.
- **Incremental state.** Cargo's `-C incremental=` directory stays in the
  argv and is a scratch directory of the edge, emptied before every run.
- **Outputs and ordering.** The files the unit's `--emit` writes, without
  the dep-info file. An edge depends on the edges of the units it consumes;
  its key comes from what the monitor records it reading, checked by content.
- **One builder per workspace.** A plan holding anything these edges do not
  build yet (a build script's compile or run, a unit fed by a build script, a
  proc-macro, a crate type other than `lib`, `rlib` or `bin`, a test target,
  split debug information, `-C prefer-dynamic`) is refused as a whole
  (`PlanUnitsRefusal`, naming each unit and why). Every check, a registry
  crate's included, is made before anything is written, so a refused plan
  makes no edge and no directory: such a workspace is built by cargo.

## Building a crates.io workspace from its plan (opt-in)

The Rust convention builds a workspace with crates.io dependencies from
cargo's plan when `REPRO_CARGO_MODE_A_REGISTRY=on` is set (only that exact
value; the default is off). With it off, such a workspace is built by cargo
through the delegated edge, as before. The convention reads the variable
when it decides the workspace's mode and records it as an evaluation input
of the graph it emits, so changing it re-decides the workspace.

With it on, and when the workspace's members have no build script, no
proc-macro, no feature or optional dependency, and every dependency that is
not a member comes from crates.io, evaluating the workspace runs no tool. It
declares graph-production edges, which run as part of the build:

1. one `cargo.fetch/<name>@<version>` edge per locked crates.io crate, run by
   `repro build` itself: it finds the crate's prefix in the store, or fetches
   and verifies it (receipts under `.repro/build/cargo-fetch`). It runs on
   every build, so a prefix the store has lost is fetched again;
2. the plan edge `cargo.plan/<workspace>`, the record run (`--cargo-plan`,
   planning `cargo build --release --workspace`) under the io monitor, whose
   one output is the plan (`.repro/build/cargo-plan/plan.rbsz`). It is
   launched from a closed environment, the toolchain's `PATH` (the
   directories of `cargo`, `rustc` and `cc`), and sets its own private
   `TMPDIR`, `CARGO_HOME` and `HOME`, so no variable of the caller's
   environment (`RUSTFLAGS`, `CARGO_PROFILE_*`, `CARGO_BUILD_*`, ...) shapes
   the plan. It is cached on what it reads;
3. the units edge `cargo.plan-units/<workspace>`, which reads the plan and
   writes a dynamic graph fragment with one rustc edge per unit
   (`planUnitEdges`, outputs under `.repro/build/cargo-units`, that same
   `PATH` as the one toolchain variable);
4. the collector `cargo.workspace/<workspace>`, in the default target: the
   engine creates the fragment's edges when it is about to run.

Each rustc edge is launched from its declared environment alone, and nothing
runs cargo. The record wrapper is found beside the provider, or at
`REPRO_RUSTC_WRAPPER_PATH`; without it, or with a git or alternate-registry
source, the workspace is built by cargo. A crate that cannot be fetched fails
its fetch edge. When the record run refuses the workspace (a cargo
configuration above it, `[patch]`, ...) or the plan holds a unit these edges
do not build (a build script, a proc-macro, ...), the units edge writes the
delegated cargo edge instead, so the whole workspace is built by cargo.
The `test` target stays the delegated one (`cargo
test`), outside the default target: test targets are not taken from the plan
yet. A fallback to cargo is not reported yet.
