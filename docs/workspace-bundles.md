# Workspace Bundles

> **Status:** Draft, not yet reviewed.

A workspace bundle is a pre-built archive of everything a fresh machine
needs to work on part of a Reprobuild workspace:

- the **Nix half**: the dev-shell closure of every member repository, its Nix
  registration, and each shell's captured environment;
- the **sources half**: a shallow clone of each member checkout, and the
  workspace's checkout state;
- the **native-store half**: Reprobuild's own store and caches for the
  selected part of the workspace ([store-bundles.md](./store-bundles.md)).

It is made for machines that must start quickly and cannot evaluate flakes,
build or clone, such as a cloud agent session whose setup script has a few
minutes and reaches GitHub only for the repositories attached to it.

## Commands

```sh
# On a builder, in a workspace with the selection checked out and built:
repro bundle create <project|variant|repo-set|repo> --out=DIR
# Upload; credentials come from the environment:
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
  repro bundle publish DIR/<bundle> --to=s3://BUCKET/PREFIX \
    --endpoint=https://<account>.r2.cloudflarestorage.com --region=auto
# On the target machine, with no repro installed:
curl -fsS https://<host>/PREFIX/<bundle>/x86_64-linux/restore.sh \
  | bash -s -- https://<host>/PREFIX/<bundle> --activate
```

`repro bundle restore <url-or-dir>` does the same on a machine that already
has `repro`. `repro bundle --help` lists every flag.

## What a bundle of a selection carries

The selector names a project, variant, repository set or repository. The
bundle carries the workspace root's own checkout and the members the
selector resolves to, and nothing of any other checkout in the workspace:

- the sources half clones only those checkouts;
- the Nix half captures the dev shells of those checkouts (and the
  workspace root's);
- the native-store half carries only the action-cache records, recorded
  outputs, project state (`.repro/`) and restamped inputs that lie in them.
  Every Git checkout under the workspace root that the selector does not
  name is excluded, and a member nested inside an excluded checkout is
  included again ([store-bundles.md](./store-bundles.md), "A selection of
  the roots"). The workspace root itself is still the root the restoring
  machine provides.

`repro store closure --selection=<selector>` prints what the native-store half
of that selection would carry, and why any record touching it is left out,
without writing anything.

## Reading a bundle before restoring it

```sh
repro bundle inspect DIR/<bundle> [--json]
```

prints what the restoring machine must provide, without restoring and
without writing anything:

- the roots to provision at the same absolute paths: the workspace
  directory, the store root, the action-cache root, every workspace root of
  the native half, and `/nix/store` when there is a Nix half;
- the `repro` version and source revision that made the bundle;
- the selection: selector, members, and the excluded and re-included
  directories;
- each half's id.

It verifies what it prints: it checks the SHA-256 of the parts that carry
the native half's contents list, of the list itself, and the bundle id, and
takes the roots, the producer and the selection from that list rather than
from the JSON. `--json` prints one object with the schema
`reprobuild.bundle-inspect.v1`:

```json
{
  "schema": "reprobuild.bundle-inspect.v1",
  "kind": "workspace",
  "name": "pair", "selector": "pair", "system": "x86_64-linux",
  "members": [".", "alpha", "beta"],
  "producer": {"version": "0.2.25", "revision": "<commit>"},
  "provision": {
    "workspaceDir": "/work/ws",
    "storeRoot": "/work/store",
    "actionCacheRoot": "/work/action-cache",
    "workspaceRoots": ["/work/ws"],
    "nixStore": "/nix/store"
  },
  "selection": {"exclude": ["/work/ws/gamma"], "include": []},
  "bundleId": "<native half id>",
  "halves": {"nix": "<id>", "sources": "<id>", "native_store": "<id>"}
}
```

`kind` is `native-store` when the directory is a native-store half alone;
such a report has no `name`, `selector`, `system`, `members` or
`workspaceDir`. `nixStore` is present only when there is a Nix half.
Fields are only ever added to `v1`. The same values, unverified, are in
`latest.json` (`repro`, `provision`) and in the native half's
`native-store.json` (`roots`, `selection`, `producer`), for a caller that
has only a URL. `inspect` reads a local directory or a `file://` URL.

A bundle can also be published to a GitHub repository, for machines that
reach GitHub but not object storage. `git push` uses the caller's own git
credentials:

```sh
repro bundle publish DIR/<bundle> --to=github:OWNER/REPO
# On the target machine; COMMIT is the `latest` branch's commit:
curl -fsS https://raw.githubusercontent.com/OWNER/REPO/COMMIT/<bundle>/x86_64-linux/restore.sh \
  | bash -s -- github:OWNER/REPO@COMMIT/<bundle> --activate
```

`repro bundle restore github:OWNER/REPO/<bundle>` resolves `latest` with
`git ls-remote` itself. Files are read from `raw.githubusercontent.com`,
falling back to the contents API; only a public repository is readable before
a session's credentials exist.

## How a restore works

`restore.sh` is generated by `create`. It holds the Nix half's part list and
SHA-256 sums, and needs only `bash`, `curl`, `tar`, `sha256sum`, `df`,
`flock` (util-linux), `nix-store` and `nix-hash`. It:

1. checks free disk space;
2. downloads the parts in parallel into a fresh staging directory in
   `/dev/shm` (or `/var/tmp` when they do not fit), or, from a local bundle
   directory, copies them there (no more of each file than its declared
   size);
3. verifies them there and reads only those copies, so the bytes verified are
   the bytes unpacked even if the source directory changes meanwhile;
4. takes Nix's own lock (`<path>.lock`, an exclusive `flock`) on each of
   the closure's store paths that Nix does not consider valid, waiting while
   a `nix-daemon` or another `nix` holds it. It then holds Nix's `gc.lock`
   shared, so no garbage collection runs until it has registered what it
   restores, and checks validity again; a path Nix finished meanwhile is
   left to Nix. The locks are held until step 8;
5. deletes whatever is on disk at each path that is still invalid: the
   partial files an interrupted restore or an interrupted Nix download
   leaves behind. Valid paths are left alone;
6. unpacks the parts into `/nix/store` with `zstd -d --long=27 | tar
   --skip-old-files`, excluding every valid path, using the `zstd` store
   path it carries when the machine has none;
7. checks each path it unpacked against the NAR hash in the registration
   (`nix-hash --type sha256`), and stops without registering anything if one
   differs;
8. registers the paths it unpacked with `nix-store --load-db`, then
   releases the locks;
9. hands over to the `repro` from that closure.

Registration is the last step, so a restore that is killed part-way leaves
the paths it touched unregistered, and running it again redoes them instead
of trusting a half-written file.

That `repro` restores the sources and the native store. It never overwrites
an existing checkout: when the workspace root is already a clone (a cloud
environment clones it first), only the member repositories are unpacked into
it, and they are added to its `.git/info/exclude`. With `--activate`, it
writes `/etc/profile.d/zz-repro-bundle.sh`, which enters the primary dev
shell in every new shell without evaluating anything, and a marked line in
`/etc/bash.bashrc` that sources it, for shells that are not login shells. The
file guards against being entered twice.

`restore.sh` is meant to run as a setup script, where a failure would stop
the machine from starting. It logs to `/var/log/repro-bundle.log`
(`REPRO_BUNDLE_LOG`) and exits 0 on failure, unless `REPRO_BUNDLE_STRICT=1`.

## Layout

```text
<bundle>/<system>/latest.json            every half's manifest
<bundle>/<system>/restore.sh             the bootstrap
<bundle>/<system>/nix/<id>/              part-NNNN, registration, nix.json
<bundle>/<system>/native-store/<id>/     part-NNNN, native-store.json
<bundle>/sources/<id>/                   part-NNNN, sources.json
```

On GitHub, each half directory `<rel>` becomes orphan branches
`<bundle>/<rel>/bNN`. Branch `bNN` holds files `[NN*20, NN*20+20)` of the
half's sorted file list, so `create` can write each file's branch into
`restore.sh` before anything is pushed. The branch `latest` holds every
bundle's `latest.json` and `restore.sh`, and is pushed last. GitHub refuses
files of 100 MiB or more, so keep the default 64 MiB parts.

Every half is `tar | zstd -19 --long=27`, split into 64 MiB parts, each with
a SHA-256. Each half directory is named by a hash of its content:

- the Nix half by its sorted store-path list;
- the sources half by each repository's path, branch, commit and origin,
  plus the workspace state files;
- the native-store half by its contents list.

So an unchanged half is reused by `create` and skipped by `publish`.
`publish` writes `latest.json` and `restore.sh` last, so a reader never sees
a manifest naming parts that are not there yet.

## Stable ids

`nix print-dev-env` writes the invoking process's working directory into the
environment (`out`, `prefix`, and the `-rpath` in `NIX_LDFLAGS`), and the
building machine's core count into `NIX_BUILD_CORES`. `create` therefore
captures each shell from its member's checkout. It also makes
`NIX_BUILD_CORES` evaluate `$(nproc)` where the file is sourced, and removes
the `shellHook` line, since `repro hooks ensure --vcs` owns the git hooks.
`--check-stable` captures every environment twice and refuses if the two
captures differ.

## Requirements and limits

- The native-store half restores only at the paths it was made at, and
  only with the same `repro` binary. Its import refuses, before writing
  anything, a bundle made by another `repro` version or source revision.
  Taking `repro` from the Nix half guarantees the same binary.
- Shells whose evaluation downloads archives cannot be evaluated on a
  restricted machine; `create` builds every shell's `inputDerivation` so the
  closure is complete.
- devenv-based flakes are evaluated with `--override-input devenv-root
  file+file://<checkout>/.devenv/root`, as their `.envrc` does.
- A bundle is trusted exactly as far as the place it is fetched from: parts
  and entries are verified against the manifest, and the manifest is not
  signed.
