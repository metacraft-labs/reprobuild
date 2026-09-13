# Pinning the reprobuild version a project builds with

A reprobuild release is a reprobuild **package**. A project that needs a
particular one pins it the way it pins `nim` or `gcc` — one `uses:` entry in
the build graph, solved once, recorded in the committed `repro.lock` — and a
thin launcher called `repro` on your `PATH` reads that pin and runs the
matching version out of the store.

There is no `.reprobuild-version` file, no `.tool-versions`, and no field
anywhere that only the launcher knows how to read. If you want to know which
reprobuild a project will use, read its `repro.lock`; if you want to change
it, change the recipe and re-lock. That is the whole mechanism.

## Pinning a version

Two lines in your `repro.nim`:

```nim
package myApp:
  # Where the realized `reprobuild` artifact comes from. Without this the
  # lock records a version with no coordinate, and a version with no
  # coordinate is not something a launcher can resolve.
  packageSource "reprobuild", "store"

  uses:
    "reprobuild >=0.1.4"
```

Then:

```sh
repro lock refresh
```

The solved package lands in `repro.lock`'s `packages` list beside every other
dependency, and because its source is `store` it is also lifted into `deps`
as a first-class locked dependency with a content-addressed coordinate:

```toml
packages = [ …, { name = "reprobuild", version = "0.1.4", source = "store", selection = "selected" } ]
deps = [ …, { name = "reprobuild", path = "", coord_kind = "store",
              store_hash = "cba8eeac…", integrity = "blake3:cba8eeac…",
              version = "0.1.4", … } ]
```

`store_hash` is the store **address** of that version on this platform, and
it is also its integrity — for a content-addressed store those are the same
value, exactly as a git commit id is both a coordinate and a checksum.

## Running it

Put the resolving launcher on `PATH` as `repro`, and point it at a bootstrap
reprobuild:

```sh
export REPRO_BOOTSTRAP_CLI=/opt/reprobuild/libexec/reprobuild/repro
```

Then `repro` inside the project runs the pinned version:

```console
$ cd myApp && repro --version
repro 0.1.4
$ cd ../otherApp && repro --version     # pins 0.1.5
repro 0.1.5
$ cd /tmp && repro --version            # no project, no pin
repro 0.1.3
```

Outside a project — or inside one that pins no reprobuild — the launcher runs
the bootstrap, so `repro` behaves as it always did.

**The bootstrap must be installed under the name `repro`.** A reprobuild
schedules its own interface-extraction and provider-compile edges by
self-spawning its image with an internal verb, and it accepts only an image
actually called `repro`. A bootstrap installed as, say, `repro-bootstrap`
answers `cannot schedule the provider-compile edge … no 'repro' image to
spawn it with`. Give it a directory of its own rather than a different name.

## Installing versions into the store

```sh
repro self install --from=<built-tree> --version=0.1.4
```

`<built-tree>` is the directory that *contains* `bin/repro`, not the binary.
Several versions coexist; each gets its own content-addressed prefix:

```console
$ repro self list
repro self list: store-root=~/.cache/repro/store
resident reprobuild versions: 2
  - 0.1.4  0f5a178dcbbae6e5…  prefixes/reprobuild/0.1.4-0f5a178dcbbae6e5
  - 0.1.5  6b21d3c4a9f0e7b2…  prefixes/reprobuild/0.1.5-6b21d3c4a9f0e7b2
```

`repro self which` reports what the launcher would run here, and why:

```console
$ repro self which
state: pinned
version: 0.1.4 (amd64-linux)
store address: cba8eeac…
prefix: prefixes/reprobuild/0.1.4-0f5a178d
executable: …/prefixes/reprobuild/0.1.4-0f5a178d/bin/repro
resident: yes
```

It exits 0 only when a pin resolves to a version that is actually installed,
so a script can gate on it. When it cannot resolve, it says which of the four
situations it is in — no project, no pin, a pin with no coordinate, or a pin
whose version is not installed — because the remedies differ.

## Fetching a version instead of building it

A version that is pinned but not resident is fetched from a configured binary
cache and installed:

```sh
repro cache substitute <entry-key> /tmp/reprobuild-0.1.5
repro self install --from=/tmp/reprobuild-0.1.5 --version=0.1.5
```

Two steps rather than one, because `repro cache substitute` writes into
`$REPRO_LOCAL_STORE` while realized prefixes live under `$REPRO_STORE_ROOT`.
`repro self provision --version=…` does the resident check and prints exactly
these commands when it cannot complete on its own.

## Removing a pin, and reclaiming the version

Remove the `uses:` entry, re-lock, and collect:

```sh
repro lock refresh
repro store gc
```

The version a project pins is held by a **pin root** in the store, named
after the project. A pin root is *derived*, not declared: `repro store gc`
re-reads each pin root's project lock before it sweeps, drops any root whose
project no longer pins what it holds, and then reclaims what nothing holds.
So deleting the pin is all it takes — there is no second bookkeeping step to
forget:

```console
$ repro store gc
repro store gc: store-root=~/.cache/repro/store
pin roots re-derived: 2 (dropped: 1)
  - pin:reprobuild:/home/me/otherApp praDropped
  - pin:reprobuild:/home/me/myApp praKept -> 0f5a178dcbbae6e5…
quarantined: 1
  - reprobuild-self reprobuild 0.1.5
reclaimed: 1
  - ~/.cache/repro/store/gc/pending-deletion/0.1.5-6b21d3c4a9f0e7b2.…
```

A version that another project still pins is not collected; `repro store
roots` shows who is holding what.

## Environment

| Variable | Meaning |
|---|---|
| `REPRO_STORE_ROOT` | the store the launcher resolves against (default: the per-user store) |
| `REPRO_BOOTSTRAP_CLI` | the bootstrap reprobuild, used when nothing is pinned and to install a pin that is missing |
| `REPRO_SELFHOST_DEBUG` | `1` makes the launcher narrate its resolution on stderr |
| `REPRO_SELFHOST_RESOLVED` | set by the launcher to the prefix it ran; a launcher that sees it already set refuses, because that means a store prefix contains a launcher rather than a reprobuild |
