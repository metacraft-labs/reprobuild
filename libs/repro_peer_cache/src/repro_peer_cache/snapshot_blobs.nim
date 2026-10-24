## Workspace snapshots on the content plane — Distributed-Execution M1.
##
## A remote goal names its `WorkspaceSnapshotManifest` by BLAKE3 digest
## (`repro_workspace_snapshot`). The worker needs the manifest and exactly
## the blobs of the files that differ from the base commit — every other
## byte comes from its own git objects. This module carries both ends:
##
## * REQUESTER — `SnapshotStore`, a CAS of its own, owner-only, holding the
##   manifests and the modified files' bytes a capture exported
##   (`repro_workspace_snapshot/capture.BlobSink` → `putBlob`).
##   `publishSnapshot` stores the manifest and returns the digests the
##   requester publishes for its goal; `hydrationSetFor` turns them into the
##   `HydrationSet` the requester's client answers a worker's fetches from —
##   over the connection the REQUESTER opened, and only for those digests
##   (FLOW-1; `client.requestReachGoal`). The snapshot store is not served on
##   the general content plane and is not advertised: a snapshot holds a
##   developer's uncommitted source (threat model asset 3), and the only
##   host that needs it is the worker the goal was sent to.
## * WORKER — `snapshotBlobDigests` lists what to fetch (the manifest's
##   modified, non-submodule entries, deduplicated, over the primary
##   repository and every `repro develop` sibling) and `fetchSnapshotBlobs`
##   fetches exactly those through the caller-provided fetcher (production:
##   the hydration channel of the caller's connection), BLAKE3-verifying
##   each, at most `MaxSnapshotFetchesInFlight` at a time. The bytes are kept
##   in memory for materialization and are not put into the worker's own
##   stores. A repository's BASE PACK (the requester's unpushed history,
##   `manifest.basePack`) is published with the snapshot and fetched only
##   for the repositories the caller says need it (`needsPack`: the worker's
##   cache lacks the base commit).
##
## EVID-6 (threat model §10.4) for the requester's snapshot store: scope —
## the manifests and modified-file bytes of snapshots this host captured;
## retention — each digest is listed with the time it was last published in
## `<root>/snapshots.index` and `sweepSnapshotStore` deletes a blob
## `SnapshotRetentionSeconds` after its LAST publication; readers — the
## owner (the store root is `0700`, blobs are read-only), and over the
## network only the worker of the goal that published it, by digest;
## redaction — not applicable to the store itself (it IS the content); no
## detection or audit record carries a snapshot byte (a content-plane
## detection records digest and size only, `evidence_record`).

import std/[asyncdispatch, options, os, sets, strutils, tables, times]
when defined(posix):
  import std/posix

import blake3

import repro_cas_store
import repro_workspace_snapshot/manifest

import ./types
import ./client

const
  SnapshotRetentionSeconds* = 30'i64 * 24 * 3600
    ## How long a snapshot blob outlives its last publication (the same
    ## thirty days as the trusted profile's other stores, §10.4).
  SnapshotIndexFile = "snapshots.index"
  MaxSnapshotFetchesInFlight* = 16
    ## Fetches a worker keeps in flight while hydrating one snapshot.

type
  SnapshotStore* = ref object
    root*: string
    cas: CasStore

  SnapshotPublication* = object
    manifestDigest*: BlobDigest
    digests*: HashSet[BlobDigest]
      ## The manifest and every blob it names — what the requester's
      ## `HydrationSet` answers for.

  SnapshotBlobs* = object
    ok*: bool
    reason*: string
    blobs*: Table[Blake3Digest, seq[byte]]
    fetched*: int
      ## Blobs fetched through the fetcher (one per distinct digest).
    fetchedBytes*: uint64

  SnapshotFetcher* = proc(digest: array[32, byte]): Future[Option[seq[byte]]]
    {.gcsafe, closure.}

  PackNeed* = proc(repo: RepoSnapshot): bool {.gcsafe, closure.}
    ## Whether the worker needs `repo`'s base pack.

proc toHex(d: array[32, byte]): string =
  const H = "0123456789abcdef"
  result = newString(64)
  for i, b in d:
    result[2 * i] = H[int(b) shr 4]
    result[2 * i + 1] = H[int(b) and 0xf]

proc fromHex(hex: string; d: var array[32, byte]): bool =
  if hex.len != 64:
    return false
  for i in 0 ..< 32:
    try: d[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError: return false
  true

proc openSnapshotStore*(root: string): SnapshotStore =
  ## The requester's snapshot store under `root` (created owner-only).
  createDir(root)
  when defined(posix):
    setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
  SnapshotStore(root: root, cas: openCasStore(root / "cas"))

proc close*(store: SnapshotStore) =
  store.cas.close()

proc indexPath(store: SnapshotStore): string = store.root / SnapshotIndexFile

when defined(posix):
  proc c_flock(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}

template withIndexLock(store: SnapshotStore; body: untyped) =
  when defined(posix):
    let lockFd = posix.open((store.indexPath & ".lock").cstring,
      O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
    if lockFd >= 0:
      discard c_flock(lockFd, cint(2))
    try:
      body
    finally:
      if lockFd >= 0:
        discard posix.close(lockFd)
  else:
    body

proc putBlob*(store: SnapshotStore; digest: Blake3Digest;
              bytes: seq[byte]) =
  ## Stores one exported blob (a `capture.BlobSink`). Raises when the bytes
  ## do not hash to `digest`.
  if blake3.digest(bytes) != digest:
    raise newException(ValueError, "snapshot blob does not hash to its digest")
  discard store.cas.casPut(bytes)

proc hasBlob*(store: SnapshotStore; digest: array[32, byte]): bool =
  store.cas.casExists(toContentHash(digest))

proc readBlob*(store: SnapshotStore; digest: BlobDigest): Option[seq[byte]] =
  try:
    some(store.cas.casGet(toContentHash(bytes(digest))))
  except CatchableError:
    none(seq[byte])

proc snapshotBlobDigests*(m: WorkspaceSnapshotManifest;
                          needsPack: PackNeed = nil;
                          allPacks = false): seq[Blake3Digest] =
  ## The blobs a worker must fetch: every modified, non-submodule entry of
  ## the primary repository and the siblings, and the base pack of each
  ## repository `needsPack` names (every one with `allPacks`), each digest
  ## once.
  var seen = initHashSet[Blake3Digest]()
  for repo in @[m.primaryRepo] & m.developSiblings:
    for e in repo.modified:
      if e.mode == ModeGitlink:
        continue
      if e.blake3Digest notin seen:
        seen.incl(e.blake3Digest)
        result.add(e.blake3Digest)
    if repo.hasBasePack and (allPacks or
        (not needsPack.isNil and needsPack(repo))):
      if repo.basePack notin seen:
        seen.incl(repo.basePack)
        result.add(repo.basePack)

proc publishSnapshot*(store: SnapshotStore; m: WorkspaceSnapshotManifest;
                      nowS = 0'i64): SnapshotPublication =
  ## Stores the manifest and lists it and every blob it names (which must
  ## already be in the store) with the publication time. Raises when a blob
  ## is missing.
  let now = if nowS != 0: nowS else: getTime().toUnix
  let encoded = encodeManifest(m)
  let manifestDigest = blake3.digest(encoded)
  result.manifestDigest = blobDigestFromBytes(manifestDigest)
  result.digests = initHashSet[BlobDigest]()
  result.digests.incl(result.manifestDigest)
  var lines = $now & " " & toHex(manifestDigest) & "\n"
  store.withIndexLock:
    # Under the lock the sweep holds while it deletes: a blob checked here
    # is listed with this publication before any sweep can run again.
    discard store.cas.casPut(encoded)
    for d in snapshotBlobDigests(m, allPacks = true):
      if not store.hasBlob(d):
        raise newException(ValueError, "snapshot blob " & toHex(d) &
          " is not in the snapshot store")
      result.digests.incl(blobDigestFromBytes(d))
      lines.add($now & " " & toHex(d) & "\n")
    let f = open(store.indexPath, fmAppend)
    try: f.write(lines)
    finally: f.close()
    when defined(posix):
      setFilePermissions(store.indexPath, {fpUserRead, fpUserWrite})

proc hydrationSetFor*(store: SnapshotStore;
                      publications: openArray[SnapshotPublication];
                      extra: openArray[BlobDigest] = []): HydrationSet =
  ## What a requester's client answers a worker's fetches from while its
  ## goal is outstanding: exactly the published digests (plus `extra`, e.g.
  ## the graph descriptor), read from the snapshot store.
  var digests = initHashSet[BlobDigest]()
  for p in publications:
    for d in p.digests: digests.incl(d)
  for d in extra: digests.incl(d)
  HydrationSet(digests: digests,
    reader: proc(d: BlobDigest): Option[seq[byte]] {.gcsafe.} =
      {.cast(gcsafe).}:
        store.readBlob(d))

proc sweepSnapshotStore*(store: SnapshotStore;
                         retentionSeconds = SnapshotRetentionSeconds;
                         nowS = 0'i64): int =
  ## Deletes every blob whose LAST publication is `retentionSeconds` old and
  ## rewrites the index without it; returns the blobs deleted. A blob whose
  ## deletion fails stays listed. Never raises. The index is read, the
  ## blobs deleted and the index rewritten all under the index lock, which
  ## `publishSnapshot` takes too: a blob published again meanwhile is never
  ## deleted under its new publication.
  let now = if nowS != 0: nowS else: getTime().toUnix
  if not fileExists(store.indexPath):
    return 0
  try:
    store.withIndexLock:
      var newest = initTable[string, int64]()
      let lines = readFile(store.indexPath).splitLines
      for line in lines:
        let parts = line.splitWhitespace()
        if parts.len != 2: continue
        var at: int64
        try: at = parseBiggestInt(parts[0]) except ValueError: continue
        if at > newest.getOrDefault(parts[1], low(int64)):
          newest[parts[1]] = at
      var deleted = initHashSet[string]()
      for hex, at in newest.pairs:
        if now - at < retentionSeconds:
          continue
        var d: array[32, byte]
        if not fromHex(hex, d):
          continue
        let path = store.cas.casPath(toContentHash(d))
        try:
          if fileExists(path):
            removeFile(path)
          deleted.incl(hex)
          inc result
        except OSError:
          discard
      var kept: seq[string] = @[]
      for line in lines:
        let parts = line.splitWhitespace()
        if parts.len != 2: continue
        if parts[1] in deleted:
          continue
        kept.add(line)
      let tmp = store.indexPath & ".tmp"
      writeFile(tmp, (if kept.len > 0: kept.join("\n") & "\n" else: ""))
      when defined(posix):
        setFilePermissions(tmp, {fpUserRead, fpUserWrite})
      moveFile(tmp, store.indexPath)
  except CatchableError:
    discard

proc fetchSnapshotBlobs*(m: WorkspaceSnapshotManifest;
                         fetch: SnapshotFetcher;
                         needsPack: PackNeed = nil;
                         maxInFlight = MaxSnapshotFetchesInFlight):
                         Future[SnapshotBlobs] {.async.} =
  ## Fetches exactly the blobs `snapshotBlobDigests(m, needsPack)` lists,
  ## each through `fetch` (which verifies; checked again here), at most
  ## `maxInFlight` at a time. Fails on the first blob that is not served.
  var res = SnapshotBlobs(blobs: initTable[Blake3Digest, seq[byte]]())
  let digests = snapshotBlobDigests(m, needsPack)
  let window = max(1, maxInFlight)
  # A sliding window: blob i+window is requested once blob i arrived.
  var pending = newSeq[Future[Option[seq[byte]]]](digests.len)
  for i in 0 ..< min(window, digests.len):
    pending[i] = fetch(digests[i])
  for i, d in digests:
    let got = await pending[i]
    if i + window < digests.len:
      pending[i + window] = fetch(digests[i + window])
    if got.isNone:
      res.reason = "snapshot blob " & toHex(d) & " could not be hydrated"
      return res
    if blake3.digest(got.get()) != d:
      res.reason = "snapshot blob " & toHex(d) & " does not hash to its digest"
      return res
    res.blobs[d] = got.get()
    inc res.fetched
    res.fetchedBytes += uint64(got.get().len)
  res.ok = true
  return res
