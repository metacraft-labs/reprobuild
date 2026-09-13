# repro_selfhost

Pin resolution for reprobuild's own versions. Turns a project's committed
`repro.lock` entry for the `reprobuild` package into the store prefix holding
that version's image, so the resolving launcher
([`apps/repro-trampoline`](../../apps/repro-trampoline)) can exec it.

There is no version file. The only inputs are the committed lock and the
store's own naming contract; see
[`docs/user-guide/pinning-reprobuild-itself.md`](../../docs/user-guide/pinning-reprobuild-itself.md)
for the user-facing shape.

## Why it is its own library

The launcher is the first thing that runs and the last thing that may assume
anything. If resolving "which reprobuild does this project pin" needed the
store runtime, the launcher would open SQLite in order to find the binary that
owns the store — a dependency loop solved by a flag rather than by
construction.

So this library links **`repro_lock`** plus the store's two pure halves —
`repro_local_store/prefix_paths` (the directory arithmetic) and
`repro_local_store/realization_hash` (the hash that arithmetic is keyed on) —
and nothing else. Resolution is arithmetic over a document. The half that
needs a database transaction lives in `repro_selfhost/install`, which the CLI
imports and the launcher does not.

## The pin is an ordinary locked dependency

Nothing here defines a lock format, and nothing here parses one. The pin is
read with `repro_lock.parseLockedDependencies`, and it is the same
`LockedDep` shape a store-realized `nim` or `gcc` would get:

```toml
deps = [{ name = "reprobuild", path = "", coord_kind = "store",
          store_hash = "cba8eeac…", integrity = "blake3:cba8eeac…",
          version = "0.1.4", … }]
```

A recipe produces it by declaring `packageSource "reprobuild", "store"` beside
its `uses:` entry; `repro lock refresh` solves the package, and MO-11's
pre-existing `repro_lock.lockedDepsFromPackages` lifts the solved package into
the coordinate above. This library is the first consumer of that lift, not a
private path beside it.

## Submodules

| Module | Purpose |
|---|---|
| `repro_selfhost` | `SelfPin` / `SelfPinState`, `selfPinFrom`, the prefix arithmetic (`selfPrefixAbsolutePath`, `selfExecutableIn`), `pinRootIdFor`. Store-runtime-free. |
| `repro_selfhost/install` | `installSelfImage` (via the store's generic `realizePrefix`), `attachPinRoot`, `dropPinRoot`, `prunePinRoots`, `listSelfPrefixes`. Needs `repro_local_store`. |

The umbrella module `repro_selfhost` is re-exported by the install half, so a
caller that needs both imports one module.

## A coordinate is checked against its own content

`ckStore` is content-addressed: `store_hash` is a BLAKE3 over the entry's
canonical solved identity (name + version + platform), and `integrity` is that
same value tagged with its algorithm. So the lock states its own checksum, and
a reader that takes it on trust is not reading a content-addressed coordinate
at all.

`pinFromLockText` recomputes the address from the **lock's own** fields and
returns `spsTampered` when either the address or the integrity disagrees. That
state is deliberately distinct from `spsNotAddressable`:

| State | Meaning | What the launcher does |
|---|---|---|
| `spsPinned` | a coordinate that matches its content | exec that prefix |
| `spsTampered` | a pin governs here and its coordinate is not its content | refuse, exit 70, **never** fall back |
| `spsNotAddressable` | a `reprobuild` entry with no usable coordinate (a bare definition identity, as this repository's own lock still has) | delegate to the bootstrap |
| `spsNoPin` / `spsNoProject` | nothing pins here | delegate to the bootstrap |

The refusal matters more than it looks: without it the only obstacle to a
hand-edited version was that the invented address happened to be absent from
the store, and the diagnosis a user then got — "that version is not
installed" — sent them to install the version their edit had invented.

## Pin roots are derived, not declared

`repro_local_store` already had `rkPin` in `RootKind` and nothing used it. A
pin root differs from every other kind in one way: it is not an assertion
somebody made, it is a consequence of what a project's committed lock says
right now, and a project stops pinning by editing a file rather than by
calling an API.

So the root id encodes the project path (`pin:reprobuild:<root>`) and
`prunePinRoots` **re-derives** every pin root from the lock it names — forget
it, read the lock again, re-establish it only if the project still pins
something the store still has. `repro store gc` runs that pass before its
dead-set query, which is what makes "remove the pin, run gc" reclaim the
version with no bookkeeping step a user can forget. It is Nix's
indirect-gcroot rule, and it has that rule's consequence: a pin root whose
project is unreachable (an unmounted volume, a renamed directory) is dropped,
and its version becomes collectable while the lock still pins it.

## Tests

Run from the repo root via `just test`.

- `t_the_pin_lives_in_the_lock` — the pin is an ordinary locked dependency;
  every tamper shape is refused; resolution reads the lock and no other file.
- `t_removing_the_pin_makes_the_version_collectable` — two versions in one
  store, gc collecting exactly the unpinned one, a moved pin repointing its
  root.
- `t_self_store_root_matches_the_store` — the launcher and the store resolve
  the same store root, including where both refuse.

The launcher itself is driven end to end by
`tests/integration/t_the_resolving_launcher_execs_the_pinned_image`.
