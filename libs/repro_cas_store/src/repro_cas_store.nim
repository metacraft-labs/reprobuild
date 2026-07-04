## Reprobuild content-addressed blob-store facade — R11 Layer 1.
##
## Spec: reprobuild-specs/Store-And-Installation-Layout.md
##       §"Human-Friendly Package Store Versus Opaque Content Store"
##       → §R11 — Two-Layer Split (normative).
##
## This module is a deliberately narrow facade over the CAS primitives
## that already live in ``repro_local_store/store.nim`` (the M56
## "unified local content-addressed store"). Downstream code that
## needs only put / get / verify / path / gc semantics MUST import
## ``repro_cas_store`` rather than ``repro_local_store`` so it does
## not silently gain access to the Layer-2 surface (prefixes, roots,
## receipts, per-generation-root registry, recovery).
##
## The layering invariant:
##
##   * Layer 1 (this module) knows about content-addressed blobs only.
##     It MUST NOT reason about packages, versions, receipts,
##     prefixes, roots, or generations.
##   * Layer 2 (``repro_local_store``) knows about the human-friendly
##     realized package prefixes + the root-driven GC graph. Layer 2
##     depends on Layer 1. Layer 1 MUST NOT depend on Layer 2's
##     public surface.
##
## The facade is intentionally implemented BY re-exporting a curated
## subset of ``repro_local_store``. That preserves a single on-disk
## implementation of the CAS layer (no divergence) while still giving
## downstream code a narrower import surface. When the Layer-1
## implementation is later split into its own module (a follow-on
## when the code base has more R11 pressure), this facade's public
## API stays byte-identical and only the underlying import changes.

import std/[hashes, os, sets, strutils]

import repro_local_store

# Re-export the error taxonomy the facade may raise. Layer-2 error
# types (EReceiptMismatch, EStoreSchemaTooNew, ...) are deliberately
# NOT re-exported — they belong to the prefix layer.
export StoreError, ECasMissing, ECasDigestMismatch

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  ContentHash* = distinct array[32, byte]
    ## A BLAKE3-256 digest over blob bytes. The R11 canonical key type
    ## for every Layer-1 operation. Distinct so it does not silently
    ## coerce to raw bytes.

  CasStore* = object
    ## Opaque handle to the CAS on-disk store rooted at ``root``.
    ##
    ## The current implementation holds a ``repro_local_store.Store``
    ## because the CAS + prefix + index tables share one on-disk
    ## layout. That is a private implementation detail: the facade's
    ## consumers MUST NOT reach through to ``inner`` to use the Layer-2
    ## surface.
    inner*: Store

# ---------------------------------------------------------------------------
# Value semantics for ContentHash
# ---------------------------------------------------------------------------

proc `==`*(a, b: ContentHash): bool {.borrow.}

proc hash*(h: ContentHash): Hash =
  var acc: Hash = 0
  let bytes = array[32, byte](h)
  for i in 0 ..< 32:
    acc = acc !& int(bytes[i])
  !$acc

proc bytes*(h: ContentHash): array[32, byte] =
  array[32, byte](h)

proc toContentHash*(bytes: array[32, byte]): ContentHash =
  ContentHash(bytes)

proc `$`*(h: ContentHash): string =
  ## Lowercase hex encoding matching the on-disk layout under
  ## ``cas/blake3/``.
  const HexChars = "0123456789abcdef"
  let raw = array[32, byte](h)
  result = newString(64)
  for i in 0 ..< 32:
    result[2 * i] = HexChars[int(raw[i]) shr 4]
    result[2 * i + 1] = HexChars[int(raw[i]) and 0x0F]

# ---------------------------------------------------------------------------
# Store handle lifecycle
# ---------------------------------------------------------------------------

proc openCasStore*(root: string): CasStore =
  ## Open (or create) the CAS store rooted at ``root``. The underlying
  ## on-disk layout is exactly what
  ## ``Local-Content-Addressed-Store.md`` §"Layout" specifies.
  result.inner = openStore(root)

proc close*(cas: var CasStore) =
  ## Close the underlying handle. Idempotent on already-closed stores.
  cas.inner.close()

proc root*(cas: CasStore): string =
  ## The absolute store-root path this facade was opened against. Used
  ## by higher-layer callers that need to build a Layer-2 path from a
  ## Layer-1 handle without re-parsing the environment.
  cas.inner.root

# ---------------------------------------------------------------------------
# Core Layer-1 operations
# ---------------------------------------------------------------------------

proc casPut*(cas: var CasStore; payload: openArray[byte]): ContentHash =
  ## Insert ``payload`` into the CAS. Returns the BLAKE3-256 digest
  ## the caller MUST use to read it back. Idempotent: repeat calls
  ## with the same bytes are cheap after the first because the on-
  ## disk atomic-rename layer sees the target already exists.
  let raw = storeCasBlob(cas.inner, payload)
  ContentHash(raw)

proc casGet*(cas: CasStore; hash: ContentHash): seq[byte] =
  ## Retrieve the blob whose digest is ``hash``. The bytes are
  ## verified against ``hash`` BEFORE they reach the caller — a
  ## mismatch raises ``ECasDigestMismatch``. A missing blob raises
  ## ``ECasMissing``.
  readCasBlob(cas.inner, PrefixIdBytes(array[32, byte](hash)))

proc casExists*(cas: CasStore; hash: ContentHash): bool =
  ## Fast existence check that does NOT read + verify the bytes. Use
  ## ``casVerify`` when integrity matters. This is the appropriate
  ## check for "have I already published this blob?" call sites.
  fileExists(cas.inner.casPath(PrefixIdBytes(array[32, byte](hash))))

proc casVerify*(cas: CasStore; hash: ContentHash): bool =
  ## Read the blob and confirm its BLAKE3-256 digest matches
  ## ``hash``. Returns ``false`` on missing / mismatched / read
  ## error. Callers that want the mismatch reason should use
  ## ``casGet`` and catch ``ECasMissing`` / ``ECasDigestMismatch``.
  try:
    discard cas.casGet(hash)
    true
  except ECasMissing, ECasDigestMismatch:
    false

proc casPath*(cas: CasStore; hash: ContentHash): string =
  ## Absolute on-disk path for the blob whose digest is ``hash``. The
  ## caller MUST NOT open the returned path for write — every Layer-1
  ## mutation MUST go through ``casPut`` so the atomic-rename
  ## semantics are preserved.
  cas.inner.casPath(PrefixIdBytes(array[32, byte](hash)))

# ---------------------------------------------------------------------------
# Garbage collection
# ---------------------------------------------------------------------------

proc casBlobRoot(cas: CasStore): string =
  ## The absolute directory under which the sharded blob tree lives.
  cas.inner.root / "cas"

proc parseHexToBytes(hex: string): array[32, byte] {.raises: [].} =
  ## Best-effort parse of a 64-char lowercase hex digest to bytes.
  ## Returns the zero array on any malformation — callers that
  ## receive zero must ignore the blob.
  if hex.len != 64:
    return
  for i in 0 ..< 32:
    let hi = hex[2 * i]
    let lo = hex[2 * i + 1]
    let hiVal =
      if hi >= '0' and hi <= '9': int(hi) - int('0')
      elif hi >= 'a' and hi <= 'f': 10 + int(hi) - int('a')
      elif hi >= 'A' and hi <= 'F': 10 + int(hi) - int('A')
      else: return
    let loVal =
      if lo >= '0' and lo <= '9': int(lo) - int('0')
      elif lo >= 'a' and lo <= 'f': 10 + int(lo) - int('a')
      elif lo >= 'A' and lo <= 'F': 10 + int(lo) - int('A')
      else: return
    result[i] = byte((hiVal shl 4) or loVal)

type
  CasMaterialization* = object
    ## One (hash → destination) pair passed to ``casMaterialize`` for
    ## the cache-hit rehydrate flow. The destination path is treated
    ## as an absolute host path; the caller is responsible for
    ## ensuring parent dirs exist iff ``createParentDirs`` is false.
    hash*: ContentHash
    destination*: string

# ---------------------------------------------------------------------------
# Cache-hit rehydrate helper (R11 Layer-1 primitive)
# ---------------------------------------------------------------------------

proc casMaterialize*(cas: CasStore;
                     entries: openArray[CasMaterialization];
                     createParentDirs = true) =
  ## R11 Layer-1 cache-hit rehydrate. Reads each ``entries[i].hash``
  ## from CAS (with the mandatory hash-on-read verification) and
  ## writes the bytes to ``entries[i].destination`` via temp-file +
  ## atomic rename so a partial write is never observable.
  ##
  ## This is the seam a future ``repro_build_engine`` migration MUST
  ## call in place of ``LocalCas.restoreOutputs`` — the current
  ## engine still uses the pre-M56 API in
  ## ``libs/repro_local_store/src/repro_local_store.nim``. Migrating
  ## every callsite is a multi-week effort; ``casMaterialize`` is the
  ## documented R11-clean replacement that ``opkCasBlobs`` cache-hit
  ## restore paths route through as they migrate.
  ##
  ## Every mismatch / missing blob raises immediately — a partial
  ## restore is never left on disk, matching the "trust the CAS,
  ## verify on read" contract from
  ## ``Local-Content-Addressed-Store.md`` §"Corruption Detection".
  for entry in entries:
    let bytes = cas.casGet(entry.hash)
    let dest = entry.destination
    if createParentDirs:
      let parent = parentDir(dest)
      if parent.len > 0:
        createDir(parent)
    let tmp = dest & ".reprocastmp"
    var raw = newString(bytes.len)
    for i, b in bytes:
      raw[i] = char(b)
    writeFile(tmp, raw)
    if fileExists(dest):
      removeFile(dest)
    moveFile(tmp, dest)

# ---------------------------------------------------------------------------
# Garbage collection
# ---------------------------------------------------------------------------

proc casGc*(cas: var CasStore;
            retainRoots: HashSet[ContentHash]): int =
  ## CAS-only garbage collection. Walks the on-disk blob tree,
  ## unlinks every blob whose digest is NOT in ``retainRoots``, and
  ## returns the freed bytes.
  ##
  ## This is the narrow Layer-1 GC — it does NOT consult the Layer-2
  ## prefix or root tables. Callers that want the full store GC
  ## (walking the prefix graph and reclaiming everything unreachable
  ## from any live root) use ``repro store gc`` which delegates into
  ## ``repro_local_store.Store.gc``.
  ##
  ## The R11 canonical use is:
  ##   * builder computes a HashSet of blobs it wants to keep (e.g.
  ##     every output referenced by the current build plan);
  ##   * calls this to reclaim everything else.
  ##
  ## The ``retainRoots`` set is checked with O(1) membership; the
  ## on-disk walk is O(n) in the number of stored blobs.
  let blobRoot = cas.casBlobRoot() / "blake3"
  if not dirExists(blobRoot):
    return 0
  var freed = 0
  for shardKind, shardPath in walkDir(blobRoot):
    if shardKind != pcDir:
      continue
    let shardName = extractFilename(shardPath)
    if shardName.len != 2:
      continue
    for blobKind, blobPath in walkDir(shardPath):
      if blobKind != pcFile:
        continue
      let blobName = extractFilename(blobPath)
      # ``casBlobRelative`` writes the FULL 64-char hex as the blob
      # filename under the 2-char shard dir; the shard is a
      # duplicated prefix for FS-level fan-out, not a suffix
      # concatenation. If the layout is unexpected, skip.
      if blobName.len != 64:
        continue
      if not blobName.startsWith(shardName):
        continue
      let bytesArr = parseHexToBytes(blobName)
      # Zero-array from parseHexToBytes means malformed hex; skip.
      var allZero = true
      for i in 0 ..< 32:
        if bytesArr[i] != 0'u8:
          allZero = false
          break
      let candidate = ContentHash(bytesArr)
      if not allZero and candidate in retainRoots:
        continue
      let size =
        try: getFileSize(blobPath).int
        except: 0
      try:
        removeFile(blobPath)
        freed += size
      except OSError:
        discard
  freed
