# Cleaning a cargo target directory: `repro cargo gc`

Cargo never removes build units it no longer needs. Renaming a crate, changing
a feature set, a profile or a flag, bumping a dependency, and every toolchain
upgrade each leave the previous units in `target/`, and nothing ever deletes
them. `repro cargo` bounds the directory: it remembers which units the last few
cargo invocations used (their *live sets*) and deletes the rest once they are
also old enough.

```sh
# After every cargo invocation of a target directory, record what it used:
cargo build --message-format=json | repro cargo record-live --tee

# Whenever no build is running (a schedule, the end of a session):
repro cargo gc --dry-run      # list what would go, with byte counts
repro cargo gc
```

## What is deleted

For each profile directory (`target/debug`, `target/release`, a custom profile,
`target/<triple>/<profile>`) that a recorded live set names, a unit goes when

- it is in none of the last **K** live sets of that profile directory, **and**
- nothing in it has been written for **T**,

or, with no waiting, when it was built by a `rustc` that none of those K live
sets was built by (a toolchain that was upgraded away: the equivalent of
`cargo sweep --installed`).

Deleting a unit removes its entries in `deps/`, `.fingerprint/` and `build/`,
the final artifacts that cargo linked or copied out of its `deps/` files (and
their `.d` files), and the `incremental/` caches of crates that no longer have a unit
(or that have more caches than units: the newest are kept).

Everything else is left alone: `test-logs/`, `nextest/`, `flycheck*/` (a
rust-analyzer target directory nested in `target/`), unknown files in profile
directories, and any profile directory that no recorded live set names. A
target directory with no recorded live set is not touched at all; the first
`record-live` starts the clock.

## When it may run

`repro cargo gc` takes cargo's own `.cargo-lock` of every profile directory it
touches, without waiting. If a cargo build holds one it exits with status 75
and deletes nothing; run it again when the build has finished. Cargo takes the
same lock for the whole of a build, so a starting build waits for the janitor
rather than racing it. A damaged live-set record (one that cannot be parsed)
also stops the sweep, since it may have protected units.

## Settings

| Setting | Flag | Environment | User config (`[cargo_gc]`) | Default |
| --- | --- | --- | --- | --- |
| K: recent live sets that protect their units | `--keep-sets N` (N >= 1) | `REPRO_CARGO_GC_KEEP_SETS` | `keep_sets = 3` | 3 |
| T: how long a no-longer-live unit survives | `--min-age 14d` (`30m`, `36h`, `14d`, `2w`, `0`) | `REPRO_CARGO_GC_MIN_AGE` | `min_age = "14d"` | 14 days |

The user config is `$XDG_CONFIG_HOME/reprobuild/config.toml` (else
`$HOME/.config/reprobuild/config.toml`). A flag beats the environment, which
beats the file. A malformed value is reported and ignored.

**The defaults are provisional.** They are a conservative suggestion (three
live sets, fourteen days) until the intended disk budget is settled; set them
explicitly where it matters.

## `record-live`

`repro cargo record-live` reads cargo's `--message-format=json` stream from
standard input (or `--from FILE`). From `compiler-artifact` messages (fresh
ones included) it takes each unit's hash and toolchain fingerprint, from
`build-script-executed` messages the build script's output directory. Binary
artifacts, which cargo reports only by their final name, are matched to their
`deps/` file by file identity where cargo hard-linked them (Linux), by byte
equality where it copied them (macOS), and, for the `.dSYM` bundle macOS
debug builds can carry, by the symlink cargo makes to the bundle in `deps/`.
A copy equal to a surviving unit's file is that unit's artifact and is kept. `--tee` copies the stream to
standard output so the recorder can sit in a pipe. `--pass-through` is for a
MIXED stream, such as `cargo test --message-format=json-render-diagnostics`,
whose standard output carries the test binaries' own output among the JSON
messages: the recorder takes the lines that begin with `{"reason":` and copies
every other line to standard output unchanged, as it arrives (a partial last line
too). The summary line then goes to standard error. The live sets are stored as
TOML under `target/.repro-cargo-gc/live-sets/`, one file per invocation, and
only the last K per profile directory are kept.

Paths outside the target directory are ignored. If the build directory is split
from the target directory (`build.build-dir`), point `--target-dir` at the
build directory, where `deps/` and `.fingerprint/` live.

Library entry points for callers that already hold the stream (a cargo
wrapper, a build edge): `recordLiveSet`, `recordLiveSetFromStream`,
`recordLiveSetPassThrough` and `collectGarbage` in `libs/repro_cargo_gc`.

## The cargo shim

Nothing calls `record-live` by itself, so a target directory that was only ever
built by bare `cargo` has no live set and `repro cargo gc` skips it. The shim
makes every cargo invocation record one without anyone changing a call site.

`repro-cargo-shim` is installed as a file named `cargo` in a directory of its
own, `libexec/repro-cargo-shim/` beside `bin/` (a symlink to `bin/repro-cargo-shim`
in the Nix package, and in `install-on-distributions.sh`). Put that directory
FIRST on `PATH`: in a dev shell's `shellHook` or `devEnv`, and in the session
launcher for commands typed outside a dev shell. A dev shell that puts its own
Rust toolchain ahead of the inherited `PATH` hides a shim that was only
prepended by the launcher. Only the Nix package and
`install-on-distributions.sh` create the `cargo`-named link; no other packaging
was examined. Windows is not supported (the shim says so and exits 127).

**What it records.** For a compiling subcommand (`build`, `check`, `clippy`,
`doc`, with their short aliases, and `test`, `bench`) it adds
`--message-format=json-render-diagnostics` before a bare `--` when the caller
gave no `--message-format`. With that format cargo renders rustc's diagnostics
to standard error itself, as a human build does, and standard output carries
only JSON artifact messages. The shim forwards every line that is not one of
those at once, and diverts the JSON lines to
`<target>/.repro-cargo-gc/shim-<pid>.stream` (the system temporary directory
when the target directory does not exist yet, so the shim never creates it
before cargo does). When cargo has exited 0 it stores the live set from that
file with the same code as `repro cargo record-live --pass-through`, then
deletes the file. If the caller already chose a JSON format (`json`,
`json-render-diagnostics`, `json-diagnostic-short`, ...), argv is not touched;
the caller receives the stream byte for byte and the recorder reads a copy.
A failed build records nothing: its partial set would count as one of the last
K and weaken the protection of units that are still live. K is
`REPRO_CARGO_GC_KEEP_SETS` / the user config, resolved as the CLI resolves it.

The target directory is `--target-dir`, else `CARGO_TARGET_DIR`, else
`CARGO_BUILD_TARGET_DIR`, else `target_directory` of one silenced
`cargo metadata --no-deps --format-version 1` run with the caller's toolchain
and global options. A split `build.build-dir` is not followed (see
`record-live`).

**What it never touches.** It does not interpose at all (it `exec`s the real
cargo: no pipe, no extra process, the terminal stays) for `run`, `install`,
`fetch`, `metadata`, `clean`, `tree`, `nextest` and every other subcommand,
`--version`, `-h`/`--help`, an unparseable command line, a non-JSON
`--message-format` (`human`, `short`), `--build-plan`, `--unit-graph`, `--no-run`
(in a JSON message format cargo does not print the `Executable ...` lines it
prints otherwise: measured with cargo 1.94), and when
`REPRO_CARGO_RECORD=0` (also `off`, `false`, `no`) or `REPRO_CARGO_SHIM_ACTIVE`
is set. What the person sees is byte-identical to bare cargo in standard
output, standard error and exit status (a signal N is reported as 128+N). The
cargo the shim starts shares its process group, so Ctrl-C reaches it directly;
SIGINT, SIGTERM, SIGHUP and SIGQUIT sent to the shim alone are forwarded, a
signal the caller had ignored (`nohup`) stays ignored, and on Linux cargo is
killed if the shim is. The shim never writes to either stream itself, and never
reads standard input.

**The terminal rule.** `test` and `bench` let the program they run write to
cargo's standard output, and a test binary that finds a terminal there behaves
differently from one that finds a pipe. So for those two the shim stands aside
whenever standard output is a terminal, and records nothing. It also stands aside
when standard output and standard error are the same open file (`2>&1`): what a
test binary writes to standard output would then reach that file through the
shim's pipe, later than what it writes to standard error, and the interleaving
the caller sees would differ from bare cargo's. `build`, `check`,
`clippy` and `doc` print nothing of their own to standard output and are
recorded on a terminal too. One consequence of diverting by line prefix: a
program that prints a line beginning with exactly `{"reason":` through cargo's
standard output loses that line to the recorder, as it would to any consumer of
`--message-format=json`.

**Recursion.** The cargo the shim starts has `REPRO_CARGO_SHIM_ACTIVE=1` in its
environment, so a `cargo` that its build scripts or test binaries run through
`PATH` passes straight through. Cargo's own `CARGO` variable names the real
cargo, which the shim is not in front of.

**Finding the real cargo.** `REPRO_CARGO_REAL` if it names an executable file,
else the next `cargo` on `PATH` that is not the shim (same file by identity, or
in the shim's directory). The path is not resolved through symlinks, so a rustup
proxy still sees the name `cargo`. A copy of the shim binary (a different file)
under the name `cargo` is not recognised as itself: install a link.

**`cargo nextest` is not covered.** `cargo nextest` runs the cargo named by the
`CARGO` environment variable, which is the real cargo, not the shim, and it asks
that cargo for `--message-format json` itself. Whether the shim sees nextest's
compile, and what it must do about it, has still to be measured; until then
nextest runs leave no live set.

**The log.** Anything that goes wrong while recording (an unreadable stream, a
failure to store the set, a stream naming no unit under the target directory)
is appended to `<target>/.repro-cargo-gc/shim.log` and nowhere else: a recording
problem never changes the caller's output or exit status. The log is truncated
when it passes 1 MB.

## `CARGO_HOME`

`repro cargo gc --cargo-home[=DIR]` also removes extracted crate sources from
`registry/src` that are older than T and whose `.crate` download is still in
`registry/cache`, so cargo can re-extract them offline. Cargo's own automatic
cleanup is off whenever cargo runs offline, so this is the only thing that
shrinks such a cache. Downloads and git checkouts are never touched. It takes
cargo's `.package-cache` lock and exits 75 if cargo holds it.
