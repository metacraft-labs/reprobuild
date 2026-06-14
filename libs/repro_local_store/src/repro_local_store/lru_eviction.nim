## ReproOS-Generations-And-Foreign-Packages A4 P4 — LRU eviction.
##
## A thin policy layer on top of ``store.nim``'s CAS directory: tracks
## per-blob size + last-access time, and evicts the oldest unpinned
## blobs when the on-disk footprint exceeds a configurable soft cap.
##
## ## On-disk model
##
## ``cas/blake3/<aa>/<full-hash>`` already records each blob as a file;
## the file's mtime stands in for last-access. (We deliberately use
## mtime rather than atime because atime is unreliable on Windows + on
## Linux when noatime is set, which is a common SSD-life optimisation.)
## The eviction policy walks the CAS directory once per call and
## evicts in mtime-ascending order until the size cap is met.
##
## ## Pinned entries
##
## Pinned entries are listed in ``recipes/cache/pinned-entries.txt`` —
## one entry-key hex per line, ``#`` comments tolerated. The orchestrator
## passes the resolved pin set to ``evictToSoftCap``; pins are never
## evicted even if they are the oldest.
##
## Pins are keyed on the **payload BLAKE3 digest** (i.e. the CAS blob
## hex), not the binary-cache entry-key. Each binary-cache pin produces
## one or more CAS pins via the manifest's payload list; the operator
## tooling under ``recipes/cache/`` is responsible for materialising
## the entry-key → payload-digest mapping into the resolved pin set
## passed here. The hex format matches what ``casPath`` produces.
##
## ## Soft vs hard cap
##
##  * Soft cap: enforced post-publish. When ``storeCasBlob`` has
##    increased the footprint past the soft cap, the policy evicts
##    oldest unpinned blobs until size is back under cap.
##  * Hard cap: enforced pre-publish. ``willExceedHardCap`` returns
##    true if the projected post-publish size would exceed the hard
##    cap; the caller should reject the publish.

import std/[algorithm, os, sets, strutils, tables, times]

import ./store

const
  DefaultSoftCapBytes* = 50'i64 * 1024 * 1024 * 1024     ## 50 GiB
  DefaultHardCapBytes* = 100'i64 * 1024 * 1024 * 1024    ## 100 GiB

type
  LruEvictionPolicy* = object
    softCapBytes*: int64
    hardCapBytes*: int64
    pins*: HashSet[string]
      ## Set of CAS payload-digest hex strings (64 lowercase chars
      ## each). Members are NEVER evicted.

  LruBlobEntry* = object
    relPath*: string        ## ``cas/blake3/<aa>/<hex>``
    fullPath*: string
    sizeBytes*: int64
    mtimeUnix*: int64
    digestHex*: string

  LruEvictionReport* = object
    bytesBefore*: int64
    bytesAfter*: int64
    evictedCount*: int
    evictedBytes*: int64
    evictedKeys*: seq[string]
    skippedPinned*: int

# ---------------------------------------------------------------------------
# Pin parsing.
# ---------------------------------------------------------------------------

proc parsePinList*(text: string): HashSet[string] =
  ## Parses ``recipes/cache/pinned-entries.txt``. Tolerates
  ## ``#``-comments + leading/trailing whitespace + blank lines.
  ## Each non-blank, non-comment line is treated as a single
  ## entry-key OR payload-digest hex; both lengths (64 hex chars)
  ## are accepted as-is. The caller is responsible for resolving
  ## entry-keys to their payload-digest equivalents before passing
  ## the set to ``evictToSoftCap``.
  result = initHashSet[string]()
  for line in text.splitLines:
    let stripped = line.strip()
    if stripped.len == 0 or stripped[0] == '#':
      continue
    # Tolerate "key  # inline comment" by taking up to the first space.
    var cut = stripped
    for i, ch in cut:
      if ch in {' ', '\t', '#'}:
        cut.setLen(i)
        break
    if cut.len == 0:
      continue
    result.incl(cut.toLowerAscii())

proc loadPinList*(path: string): HashSet[string] =
  if not fileExists(path):
    return initHashSet[string]()
  let body =
    try: readFile(path)
    except IOError: return initHashSet[string]()
  result = parsePinList(body)

# ---------------------------------------------------------------------------
# Policy constructors.
# ---------------------------------------------------------------------------

proc newLruEvictionPolicy*(softCapBytes = DefaultSoftCapBytes;
                            hardCapBytes = DefaultHardCapBytes;
                            pins: HashSet[string] = initHashSet[string]()):
                              LruEvictionPolicy =
  LruEvictionPolicy(
    softCapBytes: softCapBytes,
    hardCapBytes: hardCapBytes,
    pins: pins)

# ---------------------------------------------------------------------------
# Footprint scanning.
# ---------------------------------------------------------------------------

proc scanCasBlobs*(store: Store): seq[LruBlobEntry] =
  ## Walks ``<root>/cas/blake3/<aa>/`` and returns every blob with its
  ## size + mtime. The result is unordered; sorting happens in the
  ## eviction proc so callers reusing the scan don't pay for a sort
  ## they don't need.
  result = @[]
  let casRoot = store.root / "cas" / "blake3"
  if not dirExists(casRoot):
    return
  for shard in walkDir(casRoot):
    if shard.kind != pcDir:
      continue
    for blob in walkDir(shard.path):
      if blob.kind != pcFile:
        continue
      let info =
        try: getFileInfo(blob.path)
        except OSError: continue
      let leaf = extractFilename(blob.path)
      result.add(LruBlobEntry(
        relPath: relativePath(blob.path, store.root),
        fullPath: blob.path,
        sizeBytes: info.size,
        mtimeUnix: toUnix(info.lastWriteTime),
        digestHex: leaf.toLowerAscii()))

proc currentFootprintBytes*(store: Store): int64 =
  ## Sum of every CAS blob's byte size. O(N) but only when the caller
  ## actually wants to assert/log it; the eviction path uses the cached
  ## value from ``scanCasBlobs`` instead.
  let blobs = scanCasBlobs(store)
  for b in blobs:
    result += b.sizeBytes

# ---------------------------------------------------------------------------
# Hard-cap projection.
# ---------------------------------------------------------------------------

proc willExceedHardCap*(policy: LruEvictionPolicy;
                       currentBytes, incomingBytes: int64): bool =
  ## Returns true if ingesting ``incomingBytes`` would push the
  ## current footprint past the hard cap. The publish endpoint queries
  ## this BEFORE writing the blob; a true result means publish should
  ## be rejected with a structured error.
  return policy.hardCapBytes > 0 and
         currentBytes + incomingBytes > policy.hardCapBytes

# ---------------------------------------------------------------------------
# Eviction.
# ---------------------------------------------------------------------------

proc cmpByMtimeAsc(a, b: LruBlobEntry): int =
  if a.mtimeUnix < b.mtimeUnix: -1
  elif a.mtimeUnix > b.mtimeUnix: 1
  else: cmp(a.digestHex, b.digestHex)

proc evictBlob(b: LruBlobEntry): bool =
  ## Best-effort unlink. Returns true on success so the caller can
  ## update its bookkeeping. A locked or already-deleted blob is a
  ## non-fatal warning.
  try:
    removeFile(b.fullPath)
    return true
  except OSError:
    return false

proc evictToSoftCap*(policy: LruEvictionPolicy;
                    store: Store): LruEvictionReport =
  ## Walks the CAS directory + drops oldest-mtime unpinned blobs until
  ## the on-disk footprint is below the soft cap. Returns a structured
  ## report (count + bytes evicted + skipped-pin count). Safe to call
  ## when the footprint is already under the cap (returns a zero
  ## report).
  let blobs = scanCasBlobs(store)
  result = LruEvictionReport(
    bytesBefore: 0,
    bytesAfter: 0,
    evictedCount: 0,
    evictedBytes: 0,
    evictedKeys: @[],
    skippedPinned: 0)
  for b in blobs:
    result.bytesBefore += b.sizeBytes
  result.bytesAfter = result.bytesBefore
  if result.bytesBefore <= policy.softCapBytes:
    return
  var sorted = blobs
  sorted.sort(cmpByMtimeAsc)
  for b in sorted:
    if result.bytesAfter <= policy.softCapBytes:
      break
    if b.digestHex in policy.pins:
      inc result.skippedPinned
      continue
    if evictBlob(b):
      result.bytesAfter -= b.sizeBytes
      result.evictedBytes += b.sizeBytes
      inc result.evictedCount
      result.evictedKeys.add(b.digestHex)
