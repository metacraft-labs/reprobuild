## A registry crate's prefix identity: the realization hash that names its
## store prefix, a pure function of the lock row (name, version, checksum)
## and the extractor's layout version.
##
## Kept apart from `crate_store` (the store's write and lookup protocol) so
## that a process that only needs to check that a directory IS a given
## crate's prefix (the record-only plan edge, `repro_cargo_edge/plan_run`)
## can compute the name a prefix must have without linking the store. See
## `crate_store`'s module docstring for what enters the hash and why.

import std/os

import repro_local_store/prefix_paths
import repro_local_store/realization_hash

import ./crate_rows

const
  CrateAdapter* = "cargo-crate"
    ## The adapter identity in the realization hash and the receipt.
  CratesIoRegistry* = "crates-io"
    ## The registry identity of crates.io. cargo writes two spellings of the
    ## one crates.io source into `Cargo.lock`, `registry+https://github.com/
    ## rust-lang/crates.io-index` and `sparse+https://index.crates.io/`, and
    ## treats them as the same source (both are crates.io, the same `.crate`
    ## bytes behind one checksum), so both name this one identity: a lock
    ## rewritten from one protocol to the other keeps its prefixes.
  CrateExtractLayout* = "crate-extract.v1"
    ## The extractor's layout version: what it writes for a given archive
    ## (the top directory stripped, files 0644 or 0755, links kept). A change
    ## to what the extractor writes must change this, so the new layout is a
    ## new prefix rather than a stale one served under the old name.

proc crateRealizationId*(row: CrateRow): PrefixIdBytes =
  ## The realization hash of ``row``'s prefix.
  computeRealizationHash(row.name, row.version, CrateAdapter,
    "sha256:" & row.cksum, "", "", "sha256:" & row.cksum,
    ["registry=" & CratesIoRegistry, "crate=cargo:" & row.name,
     "layout=" & CrateExtractLayout])

proc crateTopDirectory*(row: CrateRow): string =
  ## The one top directory a `.crate` holds: `<name>-<version>`.
  row.name & "-" & row.version

proc cratePrefixPath*(storeRoot: string; row: CrateRow): string =
  ## Where the store at ``storeRoot`` (absolute) puts ``row``'s prefix:
  ## `<store root>/prefixes/<name>/<version>-<realization hash>`, a function
  ## of the row alone, so a graph can name the prefix before the fetch edge
  ## that makes it has run. Crate prefixes were first written after the
  ## store's prefix names were widened to 160 bits, so no crate prefix lives
  ## at the older, shorter name (`legacyPrefixRelativePath`).
  storeRoot / prefixRelativePath(row.name, row.version, crateRealizationId(row))
