# Native-Store Bundles

> **Status:** Draft, not yet reviewed. Implemented by `repro store closure`,
> `repro store export` and `repro store import`. Nothing here relaxes the
> store's receipt checks or the action cache's output checks.

## 1. Purpose

A fresh, short-lived Linux container (for example a cloud agent session) has a
setup budget of a few minutes. It has no access to private binary caches.
Rebuilding a workspace project's from-source dependencies there takes longer
than the budget allows.

A **native-store bundle** is a pre-built archive of everything Reprobuild's own
store and caches need for one workspace, so that after unpacking it:

* `repro build` in the restored workspace runs no producer that already ran
  when the bundle was made.
* The project's dev environment can be entered without running provider
  compilation, the build engine or the network.

The bundle is one *half* of a larger dev-shell bundle. The other halves (the
Nix closure and the source checkouts) already exist. This half reuses their
packaging conventions (§4).

## 2. What a bundle contains (the closure)

The closure is computed from a set of **workspace roots**, which are absolute
directories. Typically these are the project checkout, the from-source recipe
catalog (`REPRO_FROM_SOURCE_ROOT`) and the work root (`REPROBUILD_WORK_ROOT`)
when one is set. It has these parts:

1. **Action-cache edges.** Every per-edge record directory under
   `<action-cache>/hot-records/` that holds at least one record with an input
   or an output inside a workspace root. The whole edge directory is included:
   the `.rec` files and their sidecars (`.octime`, `.det`, the
   execution-observation and input-access sidecars).
2. **Recorded outputs.** Every output path named by an included record that
   exists on disk. Directory outputs are included recursively. The CAS blobs
   of payload-backed records are included too.

   A record is exported as *re-witnessable* (§5.1) only if three things hold.
   Its outputs pass the in-place check on the exporting host. All of its
   outputs lie inside the bundle roots. And, for a relocatable record (one
   whose paths are relative to the action's directory, which the record does
   not name), there is a project directory under the roots where its in-place
   check passes; that directory is recorded with it. Any other record that
   touches a root is reported by `closure` with the reason, and is not
   re-witnessed. It simply misses on the importing machine.
3. **Project state.** Every `.repro/` directory under a workspace root (not
   under `.git/`), recursively. This covers the legacy install mirrors
   (`.repro/output/install`), their `.realization-info` sidecars, the engine's
   per-target caches and the dev-env activation directories.
4. **Store prefixes.** Every `prefixes/<pkg>/<dir>/` and
   `tool-store/prefixes/<pkg>/<dir>/` under the store root that an included
   path, a `.realization-info` sidecar (`store-relative-path=`) or a frozen
   dev-env script names. The prefix is included whole, together with its
   sealed `.repro-receipt`.
5. **Compiler probe results.** The `compiler-probes/` success markers under
   the store root (one per probed compiler identity), so the first build does
   not re-probe every recipe toolchain.
6. **Frozen dev-env scripts** (§6), written under
   `<store>/frozen-dev-env/<key>/`.

The closure deliberately does **not** include:

* Source files tracked by version control. Those come from the sources half.
  Instead, for every input that an included record fingerprints and that lies
  in a workspace root but outside the bundle, the bundle records a
  **restamp entry**: path, size, mtime and BLAKE3 digest (§5.3).
* `index.db`. The index is rebuilt from receipts at import (§5.2), which is
  what `repro store recover` already does.
* The action cache's shared-memory tier and any index files. Both are optional
  accelerators that rebuild themselves from the per-edge files.
* Tool-store download archives (`tool-store/downloads/`). They are only needed
  to re-extract prefixes that the bundle already carries.

`repro store closure` prints the closure without writing anything.

## 3. Path invariance

Records, receipts, install mirrors and dev-env scripts all embed absolute
paths. A first version of bundles therefore requires the importing machine to
use the **same absolute paths** as the exporting one:

* the same store root,
* the same action-cache root,
* the same workspace roots,
* (for frozen dev envs) the same project roots.

The bundle records all of them. Import compares each one with the local value
(resolved exactly as `repro build` resolves it: flags, then environment, then
default). On any difference it **refuses before it writes anything**, and names
the recorded value, the local value and the variable that sets it. Relocation
is out of scope.

## 4. Format

The published form is the same as the other dev-shell bundle halves:

```
<out>/native-store.json             transport manifest
<out>/native-store.tar.zst.0000     part 0
<out>/native-store.tar.zst.0001     part 1
...
```

* **Stream:** `tar --format=posix` (pax headers keep nanosecond mtimes, which
  the timestamp fingerprint policy compares), piped through
  `zstd -19 --long=27`, split into parts of 64 MiB.
* **Entries:** absolute paths stored relative to `/`. Hard links between
  entries stay hard links (store prefixes are often hardlinked to install
  mirrors).
* **First entry:** `<store>/bundles/<bundle-id>/contents`. This is the
  authoritative description of the bundle (§4.1). It is listed first so an
  importer can read it without decompressing the rest.
* **Transport manifest:** `native-store.json`. It is emitted for the publisher
  and the setup script, like the other halves' manifests. It carries the part
  names, each part's size and SHA-256, the compression settings, the roots and
  the SHA-256 of the `contents` entry. JSON is only the transport and
  inspection form here. Import checks part hashes against it, and then takes
  every decision from `contents`.

### 4.1 `contents`

A line-oriented UTF-8 text file. Fields are separated by TAB. Path and link-target fields are escaped,
with `\`, TAB and newline written as `\\`, `\t` and `\n`.

```
reprobuild.store-bundle.contents.v1
root  store  <abs>
root  action-cache  <abs>
root  workspace  <abs>          (one per workspace root)
devenv  <project-root>  <script-abs-path>
edge  <abs edge dir>
record  <strong-hex>  <abs edge dir>  <abs action dir, or empty>
prefix  <abs prefix dir>
entry  <kind>  <mode-octal>  <size>  <mtime-ns>  <blake3-hex|->  <abs path>
restamp  <size>  <mtime-ns>  <blake3-hex>  <abs path>
```

The fields above are spaced for reading; on disk each line separates them with
a single TAB. `kind` is `f` (file), `d` (directory) or `l` (symlink, whose digest field holds
the escaped link target). Every tar entry has exactly one `entry` line, and
there are no others.

## 5. Import

`repro store import <dir>` runs these steps in order:

1. **Verify the transport.** Read `native-store.json`. Each part is read whole
   into memory and its SHA-256 is checked *before* any byte of it is passed on
   to the decompressor. No unverified byte reaches the filesystem, and the
   cost is one pass over the parts.
2. **Check the roots.** Decompress only the first tar entry (`contents`) and
   compare its roots with the local ones (§3). Refuse on mismatch.
3. **Unpack.** Stream the verified parts into `zstd -d | tar -x -C /`. Prefix
   directories that already exist locally with a receipt whose realization
   hash matches their name are excluded from extraction. They are
   content-addressed, so this is what makes a repeated import cheap and leaves
   read-only prefixes alone.
4. **Verify the content.** For every `entry`, check its lstat kind and size
   and its BLAKE3 digest (files) or link target (symlinks) against `contents`.
   Any mismatch fails the import. Nothing is registered and no record is
   re-witnessed.
5. **Register.**
   1. *Prefixes:* run store recovery, which re-inserts index rows from the
      sealed receipts and quarantines any prefix whose receipt does not match
      its directory name. Then register a root `bundle:<bundle-id>`
      (kind `workspace`) that holds every imported prefix, so GC keeps them.
   2. *Re-witness outputs:* §5.1.
   3. *Restamp inputs:* §5.3.
6. **Mark.** Write `<store>/bundles/<bundle-id>/imported`. A later import of
   the same bundle that finds the marker and finds every `entry` still
   matching on lstat skips step 3 and re-runs only steps 4 and 5.

The command is idempotent. Its cost is the disk write of the unpacked bytes,
plus one read of them for step 4. It makes no per-entry network or database
round trips.

### 5.1 Re-witnessing imported records

A cache hit compares each output's live inode change time (`st_ctime`) with
the value witnessed when the record was written. For directories it compares a
digest that folds every entry's ctime. The kernel sets ctime and nothing in
userspace can set it, so every unpacked output has a new one, and an
un-witnessed record would be rejected as "output changed after it was
recorded". This is the tamper check working as intended.

After step 4 has proven that every output's bytes are the bytes the exporter
had, import re-observes the outputs of each included record and rewrites its
witness. This is the existing `refreshRestoredOutputs` operation, the one a
restore from the CAS or from a LAN peer already uses, and it runs under the
same precondition: the restored bytes were verified against a content digest
first.

The exporter, for its part, includes only records whose outputs **pass the
in-place check on the exporting host** (`outputStateMismatch` is clean). So
what the bundle's digests vouch for is exactly what the record vouched for.

Fingerprints, policies, determinism classes and relocation labels are not
touched.

### 5.2 Receipts

Prefix integrity is the receipt rule that already applies to recovery: the
directory leaf must equal the receipt's realization hash, or the prefix is
quarantined. A receipt is never rewritten by import.

### 5.3 Restamping source inputs

The default input policy (`timestamp`) compares an input's size and mtime. A
fresh checkout from the sources half has the right bytes but new mtimes, so
every record would miss. For each `restamp` entry whose live file has the
recorded size **and the recorded BLAKE3 digest**, import sets the file's mtime
back to the recorded value. A file whose content differs is left alone, and
its records miss, which is correct. Import never restamps a path outside a
workspace root.

## 6. Frozen dev-env activation

`repro store export --freeze-dev-env=<project-root>` runs the ordinary hook
export (`repro dev-env export bash`) for that project at bundle time, with
auto-allow on, and writes the result to
`<store>/frozen-dev-env/<key>/activate.bash`, where `<key>` is the BLAKE3 hex
of the project root. It appends:

* `export __REPRO_PROJECT_ROOT=<project-root>`. The shell hook does not call
  `repro` while this equals the directory it finds, so the frozen activation
  stays in force with no engine run on each prompt. `__REPRO_APPLIED` keeps the
  bundle-time key. That key cannot match after an unpack (it folds lstat state
  including inode numbers), and nothing relies on it matching.

Sourcing the script runs no `repro` process. It is the analogue of a captured
`nix print-dev-env` script. The activation directory it names
(`__REPRO_ACTIVE_MANIFEST`) is under the project's `.repro/`, so it is in the
bundle and leaving the project deactivates normally.

`repro store import --allow-dev-env` also writes the allow file
(`<config>/repro/allow/<hash>`) for each frozen project, exactly as `repro
allow <project-root>` would. This is opt-in, because it is the user's consent
to run that project's environment, and the setup script is where that consent
is given.

## 7. Command summary

```
repro store closure --root=<dir>... [--json]
repro store export  --root=<dir>... --out=<dir> [--freeze-dev-env=<project>]...
                    [--part-size=64M] [--zstd-level=19]
repro store import  <dir> [--root=<dir>...] [--allow-dev-env] [--force]
```

All three accept `--store-root=` and `--action-cache-root=`, which resolve as
for `repro build`.

## 8. Producing and consuming the half in the dev-shell bundle scripts

Publisher side, after the project has been built once in a builder that uses
the session's paths. The builder must also have the closure's tools: GNU tar,
zstd and bash.

```sh
# The same roots the session will use.
export REPRO_STORE_ROOT=/root/.cache/repro/store
export REPROBUILD_ACTION_CACHE_ROOT=/root/.cache/repro/action-cache
repro build                                   # in each project to pre-seed
repro store export \
  --root="$WS/<project>" --root="$WS/recipes" \
  --freeze-dev-env="$WS/<project>" \
  --out="$BUNDLE_DIR/native-store"
# -> native-store/native-store.json + native-store.tar.zst.NNNN (64 MiB parts)
```

Session side, in the setup script, after the Nix half has been loaded and the
sources half has been checked out. The parts are fetched in parallel, like
the other halves' parts, into `$DL/native-store/`:

```sh
export REPRO_STORE_ROOT=/root/.cache/repro/store
export REPROBUILD_ACTION_CACHE_ROOT=/root/.cache/repro/action-cache
# Whatever compiler selection the publisher used (§10), e.g.
# export REPRO_NIM_COMPILER=/nix/store/...-nim-wrapper-2.2.4/bin/nim
repro store import "$DL/native-store" --allow-dev-env
# Enter the project environment without running repro:
echo ". <store>/frozen-dev-env/<key>/activate.bash" >> ~/.bashrc
```

The JSON manifest's `frozenDevEnvs[].script` gives the exact path to source.
`repro store import` exits non-zero, with the reason, if the roots differ,
a part or entry fails its hash, or a prefix is quarantined. On a non-zero
exit the setup script should fall back to building (or simply continue).
Nothing is registered in that case.

## 9. Open questions

* Relocation (a different store root or workspace path) needs path rewriting
  in records and receipts. That is a separate design.
* Whether imported prefixes should also be published to a remote cache. Source
  identities are still `pending`, and the substitution rules forbid that today.
* Whether workspace builds should register a `workspace:<root>` GC root as
  they run, so the closure can be read from roots instead of scanning the
  action cache.
* The transport manifest's field names follow the description of the
  dev-shell bundle format, not its source, which this draft could not read.
  They should be aligned with `scripts/devshell-bundles` before the half is
  published.
* A relocatable record with no outputs cannot be placed in a project
  directory, so it is not re-witnessed. Stale records (for example, from an
  earlier engine binary) are reported and skipped, but they still travel in
  their edge directories. Pruning them at export would shrink bundles.
* The package recipe builds `repro` in debug mode. That roughly doubles
  import time (§10), and the same holds for every other `repro` operation.

## 10. Verification and measurements

All numbers were measured at commit `0b68582`. The container was a cloud
session host with 4 vCPU, 15 GiB RAM and ~600 MB/s sequential disk write. The
`repro` binaries were built by `scripts/build_apps.sh` in its default
(debug) mode, the mode the package recipe uses today.

**Fixture.** `tests/integration/source_producer_fixture.nim`'s layout: a
consumer whose `buildDeps` producer `probe` is built from source
(`--tool-provisioning=from-source`). The provider compile and the recipe
compile ran with a Nix gcc and Nim, through wrappers that log every
invocation.

**Procedure.**
1. Build the fixture, then build again until warm.
2. `repro store export --root=<fixture> --freeze-dev-env=<consumer>`.
3. Move the fixture away. Recreate it with only its source files, copied
   without preserving mtimes (a fresh checkout), and delete the compile
   scratch under `/tmp`.
4. `repro store import <out> --allow-dev-env`.
5. Source the frozen script with no `repro` on PATH.
6. `repro build` with `HTTPS_PROXY`/`HTTP_PROXY` pointing at a closed port.

| Case | Unpacked | Parts | Import | Rebuild after import | Compiler runs |
| --- | --- | --- | --- | --- | --- |
| Fixture | 56 MB, 263 entries | 1 (1.3 MB, `-19`) | 8.0 s | 7.8 s, all up to date | 0 |
| Fixture + 1.8 GB install-mirror payload | 2.48 GB, 75 131 entries | 6 (350 MB, `-9`) | 35.9 s | 8.0 s, all up to date | 0 |
| Control: fresh checkout, no bundle | — | — | — | 158.8 s, both producers executed | 278 |

The frozen dev-env script activated in 7 ms, with no `repro` process.

**Import phases** (library harness on the 2.35 GB bundle, into empty roots,
caches dropped between runs):

| Phase | debug | `-d:release` |
| --- | --- | --- |
| verify parts + read `contents` + check roots | 5.1 s | 1.1 s |
| unpack (`zstd -d \| tar -x`) | 15.7 s | 7.3 s |
| verify every entry (BLAKE3) | 6.8 s | 5.5 s |
| register prefixes | 0.0 s | 0.0 s |
| re-witness records | 5.8 s | 1.1 s |
| total | 33.5 s | 16.4 s |

Plain `cat parts | zstd -d | tar -x` of the same bundle into an empty
directory took 7.1 s, so the release unpack runs at the disk floor. Before
`0b68582`, the debug import of that bundle took 268 s. Nearly all of it was
verification: a zeroed 1 MiB buffer per hashed file, and BLAKE3's C compiled
at `-O0`. In the debug build, re-witnessing costs about 200 ms per
provider-compile record (15–20k inputs each), spent in the record encoder.

Things the measurement depended on:

* **The same compiler selection on both sides.** The recipe and provider
  compiles key on the compiler that runs them. The bundle can only hit if the
  session selects the same compiler (here `REPRO_NIM_COMPILER` and
  `REPRO_BOOTSTRAP_CC`, both pointing into `/nix/store`). Without those
  variables `repro` provisions the pinned compilers from `github:` flake
  references, and a cloud session refuses those GitHub archive downloads.
* **The same `repro` binary.** Provider-compile records fingerprint the
  engine binary, so publisher and session must run the same build (in
  practice, the same Nix-half closure).
