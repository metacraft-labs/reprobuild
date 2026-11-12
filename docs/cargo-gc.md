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
the final artifacts that cargo hard-linked out of its `deps/` files (and their
`.d` files), and the `incremental/` caches of crates that no longer have a unit
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
artifacts, which cargo reports only by their hard-linked final name, are
matched to their `deps/` file by file identity. `--tee` copies the stream to
standard output so the recorder can sit in a pipe. The live sets are stored as
TOML under `target/.repro-cargo-gc/live-sets/`, one file per invocation, and
only the last K per profile directory are kept.

Paths outside the target directory are ignored. If the build directory is split
from the target directory (`build.build-dir`), point `--target-dir` at the
build directory, where `deps/` and `.fingerprint/` live.

Library entry points for callers that already hold the stream (a cargo
wrapper, a build edge): `recordLiveSet`, `recordLiveSetFromStream` and
`collectGarbage` in `libs/repro_cargo_gc`.

## `CARGO_HOME`

`repro cargo gc --cargo-home[=DIR]` also removes extracted crate sources from
`registry/src` that are older than T and whose `.crate` download is still in
`registry/cache`, so cargo can re-extract them offline. Cargo's own automatic
cleanup is off whenever cargo runs offline, so this is the only thing that
shrinks such a cache. Downloads and git checkouts are never touched. It takes
cargo's `.package-cache` lock and exits 75 if cargo holds it.
