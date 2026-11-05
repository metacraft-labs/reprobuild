# Copying a Store Closure

> **Status:** Draft, not yet reviewed. Implemented by `repro store copy` for a
> destination that is another local store root. POSIX only.

```
repro store copy [PREFIX...] [--root-id=ID]... --to=STORE-ROOT
                 [--store-root=PATH] [--json]
```

`repro store copy` moves already realized store prefixes from one store root
into another: a mirror on another disk, a store you will carry to an
air-gapped machine, or a worker store you want to prewarm. Unlike a store
bundle (see [store-bundles.md](./store-bundles.md)) it carries store prefixes
only, writes straight into the destination store, and the destination may
live at any path.

## What is copied

The source store is the one `--store-root` names (otherwise
`$REPRO_STORE_ROOT`, otherwise the per-user default).

* A `PREFIX` is a prefix of the source store, given as an absolute path or as
  `prefixes/<pkg>/<dir>`. A path inside a prefix, such as an installed
  program, names the prefix that owns it.
* `--root-id=ID` selects every prefix a registered root holds
  (`repro store roots` lists them).

A prefix produced as one output of a multi-output package brings its sibling
outputs along, because its receipt names them.

## What is checked

Before anything is written, every prefix of the closure is checked in the
source: its directory and sealed `.repro-receipt` exist, the receipt agrees
with the index row, the directory name is the one the receipt derives, and
the directory's content digest is the one the receipt records. The
destination is checked too: a prefix it already has with a different
receipt, or a directory it does not index where a prefix would land, is a
conflict. Any failure stops the copy with the prefix and the reason, and the
destination is left as it was.

Each prefix is then copied into the destination's staging area, its digest
is checked again, and it is renamed into place at the same store-relative
path. The receipt is copied byte for byte, so the prefix keeps its identity,
and the source's index row is inserted unchanged. Files are copied, never
hard-linked, so the destination shares no inodes with the source.

A prefix the destination already has is skipped, so copying the same closure
twice transfers nothing the second time. Every prefix of the closure is held
by a destination root `copy:<closure-id>`, so the destination's
`repro store gc` keeps it.

## What the report says

* **unverified**: the receipt records no content digest (an adopted prefix,
  or one sealed by an older store). The copy was checked against the source
  tree, but nothing vouches for the source tree itself.
* **external**: a `nix` or `adopted:` prefix. Its receipt and links were
  copied; the content they point at outside the store was not.

Absolute paths inside a prefix are not rewritten. A prefix that names its own
store root works from the destination only where the destination is mounted
at the source's path.

Exit status: 0 on success, 1 when the copy failed, 2 on a usage error.
