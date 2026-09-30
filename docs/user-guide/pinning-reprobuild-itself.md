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

## Without the launcher: the bootstrap hands over

The launcher is optional. Whatever `repro` a host has — the native
package's, a CI image's, `build/bin/reprobuild` from a checkout — reads the
project's pin before it does anything else, and if the project pins a
different reprobuild it runs that one instead:

```console
$ cd myApp && REPRO_SELFHOST_DEBUG=1 repro --version
repro(0.2.5): …/myApp/repro.lock pins reprobuild 0.1.4; this image is 0.2.5, so it hands over to …/prefixes/reprobuild/0.1.4-0f5a178d/bin/repro
repro(0.2.5): exec …/prefixes/reprobuild/0.1.4-0f5a178d/bin/repro (engine …/bin/reprobuild)
repro 0.1.4
```

This is the whole job of the reprobuild a host starts with: provision the
project's pinned reprobuild (and its compiler, below), then hand over. It
never evaluates a recipe it is not pinned to. The rules:

- The pinned image gets your argv and environment unchanged, plus
  `REPRO_SELFHOST_RESOLVED` (the prefix it was handed), `REPRO_PUBLIC_CLI_PATH`
  (the pinned engine) and, when the compiler is pinned, `REPRO_NIM_COMPILER`.
  `REPRO_FULL_CLI` is removed, so nothing can route the pinned thin client
  back to the bootstrap.
- No hand-over when nothing is pinned, when the pinned version is the
  running version, or when the running image *is* the pinned prefix's engine
  (compared by file identity).
- If a hand-over to a prefix already happened in this process tree and the
  image running now is not that prefix, `repro` refuses with exit 72 rather
  than looping or running the recipe with the wrong reprobuild.
- A pinned version that is not in the store is refused with exit 70 and the
  `repro self install` command that would put it there.
- `repro self …` is always answered by the reprobuild you ran: it is how a
  missing version gets installed.
- A daemon-hosted build of a project pinned to another reprobuild is
  declined by the daemon, and the client's engine hands over.

The project is the one enclosing the working directory, as for the
launcher.

## Pinning the compiler that builds the provider

The recipe (`repro.nim`) is compiled into a provider binary before it can be
read, so the Nim compiler that does it decides what your recipe means. Pin it
the same way, as the ordinary `nim` package with a store source and an exact
version:

```nim
package myApp:
  packageSource "nim", "store"
  uses:
    "nim ==2.2.10"
```

`repro lock refresh` records it as a `deps` entry with `coord_kind =
"store"`, exactly like the reprobuild pin. Only a store-sourced `nim` entry
is a pin: the bare `nim` entry most locks already carry pins nothing, and the
provider is compiled with the bootstrap's own Nim.

A pinned compiler lives in the store at `prefixes/nim/<version>-<hash>/`. It
gets there one of two ways:

- automatically, when the pinned version is the one the running reprobuild
  fetches for itself (today `nim 2.2.10` on Windows): the bootstrap realizes
  it on first use;
- otherwise from a Nim distribution directory (it must contain `bin/nim` and
  `lib/system.nim`):

  ```sh
  repro self install --package=nim --from=<nim-dir> --version=2.2.14
  ```

A pinned compiler that is neither is an error naming that command; the
bootstrap never compiles the provider with a compiler the lock does not name.
The pin also wins over an inherited `REPRO_NIM_COMPILER`, with a warning when
the two differ. `repro self which --package=nim`, `repro self list
--package=nim` and `repro store gc` treat it like the reprobuild pin.

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
