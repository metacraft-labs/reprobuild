## Registry crates in the store root: one read-only prefix per locked crate
## version, published through the local content-addressed store.
##
## A crate's sources live at
##
##   <store root>/prefixes/<name>/<version>-<realization hash>/
##
## (Local-Content-Addressed-Store layout), holding the extracted `.crate`
## exactly as cargo extracts it into `<name>-<version>/`, plus the store's
## `.repro-receipt`. The prefix is published by the store's own write
## protocol (`realizePrefix`: stage, seal the receipt, rename, index row), so
## it either holds a verified tree or does not exist, and it is read-only
## from the moment the index names it.
##
## **Identity.** The realization hash is the store's (`computeRealizationHash`)
## over exactly what determines the prefix's bytes: the registry identity,
## `cargo:<name>`, the version, the `.crate`'s SHA-256 and the extraction
## layout's version. Nothing host- or project-specific enters it, in
## particular no project path, mirror or URL, so two checkouts or two
## projects that lock the same crate share one prefix, and a store at
## another path on another host names it the same. The acquisition is
## "acquisition-addressed" in the store's terms: the prefix is a pure
## function of the verified archive and the extractor's layout.
##
## **The archive.** The verified `.crate` is also kept as a blob in the
## store's `cas/` (keyed, as every blob there is, by its BLAKE3 digest), so
## it can be re-checked against the lock's SHA-256 without the network. The
## prefix's receipt names that blob as its provenance (`cas:blake3:<hex>`)
## and records `sha256:<cksum>` as its provenance checksum, so a lock row
## leads to the realization hash, the index row, the receipt and the blob.
## Where the bytes were downloaded from is the fetch edge's own receipt's
## business, not the prefix's.
##
## Reads of a prefix are reads inside the `store` logical root, which is what
## lets the compile edges that read crate sources be portable.

import std/os

import blake3

import repro_local_store
import repro_nimble_fetch/archive_extract
import repro_core/zlib_inflate

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
  ## The realization hash of ``row``'s prefix (see the module docstring).
  computeRealizationHash(row.name, row.version, CrateAdapter,
    "sha256:" & row.cksum, "", "", "sha256:" & row.cksum,
    ["registry=" & CratesIoRegistry, "crate=cargo:" & row.name,
     "layout=" & CrateExtractLayout])

proc crateTopDirectory*(row: CrateRow): string =
  ## The one top directory a `.crate` holds: `<name>-<version>`.
  row.name & "-" & row.version

proc presentCratePrefix*(s: var Store; row: CrateRow): string =
  ## The absolute path of ``row``'s prefix when the store's index names it
  ## and the directory verifies against the index's record, else "".
  ## A prefix that does not verify is treated as absent, so the crate is
  ## fetched again and the store replaces it.
  let id = crateRealizationId(row)
  let lookup = s.lookupPrefix(id)
  if not lookup.found:
    return ""
  let abs = s.absolutePrefixPath(lookup.row.realizedPath)
  if not dirExists(abs):
    return ""
  let check = s.verifyRealizedPrefix(id, abs)
  if check.outcome in {pvVerified, pvCached, pvRecordedFirst, pvUnrecorded}:
    abs
  else:
    ""

proc crateArchiveTar*(crateBytes: string; limits: ExtractLimits): string =
  ## The tar inside a `.crate` (a gzip stream of exactly one member),
  ## decompressed in process and bounded by ``limits.maxBytes``. Raises
  ## `InflateError` for anything else.
  let plain = gzipDecompress(crateBytes, int(limits.maxBytes))
  result = newString(plain.len)
  if plain.len > 0:
    copyMem(addr result[0], unsafeAddr plain[0], plain.len)

proc crateBlobRef*(crateBytes: string): string =
  ## How a prefix's receipt names its `.crate` blob in the store's `cas/`.
  "cas:blake3:" & hexOf(blake3.digest(crateBytes.toOpenArrayByte(0,
    crateBytes.high)))

proc installCrate*(s: var Store; row: CrateRow; crateBytes: string;
                   limits: ExtractLimits): string =
  ## Publish ``row``'s prefix from ``crateBytes``, which the caller has
  ## ALREADY verified against ``row.cksum``, and return its absolute path.
  ##
  ## The archive is decompressed and extracted into the store's private
  ## staging directory under the confined extractor's rules (no absolute
  ## name, no `..` component, nothing outside `<name>-<version>/`, no link
  ## that leaves the tree, no write through a link, no hard link or special
  ## file). Raises `ExtractRefusal` (naming the member and the rule) or
  ## `InflateError`; the store then removes the staging directory, so a
  ## refused archive leaves nothing behind.
  let tarBytes = crateArchiveTar(crateBytes, limits)
  let options = ExtractOptions(stripComponents: 1,
    topDirectory: crateTopDirectory(row), gnuLongNames: true, limits: limits)
  let hint = StoreReceiptHint(adapter: CrateAdapter, packageName: row.name,
    version: row.version, lockIdentity: "sha256:" & row.cksum,
    provenanceUrl: crateBlobRef(crateBytes),
    provenanceChecksum: "sha256:" & row.cksum,
    materializationMechanism: "extract")
  let realized = s.realizePrefix(crateRealizationId(row), hint,
    proc (stagingDir: string; mechanism: var string) =
      discard extractArchive(tarBytes, stagingDir, options)
      mechanism = "extract",
    readOnly = true)
  # Only an archive that extracted cleanly is kept: a refused one leaves no
  # blob behind either.
  discard s.storeCasBlob(crateBytes.toOpenArrayByte(0, crateBytes.high))
  realized.absolutePath
