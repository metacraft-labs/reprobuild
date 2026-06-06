## Disk-backed content-addressed blob store — Peer-Cache-Scale M2.
##
## A small wrapper for the tier-2 daemon (`apps/repro-peer-cache-tier2`).
## The on-disk layout matches `repro_local_store`'s convention: a
## two-character shard directory keyed on the first byte of the digest
## hex, then the remaining 62 hex characters as the file name. This
## keeps any single directory's fan-out bounded (≤ 256 entries) even at
## millions of blobs.
##
## LRU semantics are mtime-based: every successful `load` touches the
## file's modification time, and `evictLru` walks the tree sorted by
## mtime ascending and unlinks oldest-first until `currentBytes`
## drops to the requested target. This is the simplest scheme that
## works on every POSIX filesystem without a separate index — at
## reasonable working-set sizes (10–100 GB, ~10⁵ blobs) the full sweep
## costs a single readdir-and-stat pass per eviction event. Tier-3
## (M3+) deployments may want a real LRU index, but for M2 the
## mtime-based sweep is sufficient.

import std/[algorithm, options, os, strutils, times]

import ./cuckoo
import ./types

const
  HexChars = "0123456789abcdef"
  ShardDigits = 2
    ## First two hex chars of the digest name a shard directory.

type
  DiskStore* = ref object
    rootDir*: string
    maxBytes*: uint64
    currentBytes*: uint64
    evictionCount*: uint64

proc digestToHex(d: BlobDigest): string =
  let raw = bytes(d)
  result = newString(64)
  for i, b in raw:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc hexToDigest(hex: string): BlobDigest =
  ## Inverse of `digestToHex` — used by `filterContents` and the LRU
  ## scan to recover a `BlobDigest` from an on-disk file name.
  var raw: array[32, byte]
  for i in 0 ..< 32:
    let hi = parseHexInt(hex[2 * i .. 2 * i + 1])
    raw[i] = byte(hi)
  blobDigestFromBytes(raw)

proc shardDir(ds: DiskStore; hex: string): string =
  ds.rootDir / hex[0 ..< ShardDigits]

proc blobPath(ds: DiskStore; hex: string): string =
  shardDir(ds, hex) / hex[ShardDigits ..^ 1]

proc walkBytes(ds: DiskStore): uint64 =
  ## Recomputes `currentBytes` by walking the store. Called at
  ## construction and after eviction sweeps to stay in sync with the
  ## filesystem.
  var total: uint64 = 0
  if not dirExists(ds.rootDir):
    return 0
  for shard in walkDir(ds.rootDir, relative = false):
    if shard.kind != pcDir: continue
    for entry in walkDir(shard.path, relative = false):
      if entry.kind != pcFile: continue
      try:
        total += uint64(getFileSize(entry.path))
      except CatchableError:
        discard
  total

proc newDiskStore*(rootDir: string; maxBytes: uint64): DiskStore =
  ## Constructs (and lazily creates) a disk-backed store rooted at
  ## `rootDir`. The directory is created if it does not exist; if it
  ## already contains blobs, `currentBytes` is initialised from the
  ## walked contents so a daemon restart resumes with the same
  ## accounting it had at shutdown.
  if not dirExists(rootDir):
    createDir(rootDir)
  result = DiskStore(
    rootDir: rootDir,
    maxBytes: maxBytes,
    currentBytes: 0'u64,
    evictionCount: 0'u64)
  result.currentBytes = walkBytes(result)

# ---------------------------------------------------------------------------
# Eviction.
# ---------------------------------------------------------------------------

proc enumerateByMtime(ds: DiskStore): seq[tuple[path: string,
                                                size: int64,
                                                mtime: Time]] =
  ## Returns (path, size, mtime) for every blob, sorted by mtime
  ## ascending (oldest first). Used as the input to `evictLru`.
  result = @[]
  if not dirExists(ds.rootDir):
    return
  for shard in walkDir(ds.rootDir, relative = false):
    if shard.kind != pcDir: continue
    for entry in walkDir(shard.path, relative = false):
      if entry.kind != pcFile: continue
      var size: int64 = 0
      var mtime: Time
      try:
        size = getFileSize(entry.path)
        mtime = getLastModificationTime(entry.path)
      except CatchableError:
        continue
      result.add((path: entry.path, size: size, mtime: mtime))
  result.sort do (a, b: tuple[path: string, size: int64, mtime: Time]) -> int:
    if a.mtime < b.mtime: -1
    elif a.mtime > b.mtime: 1
    else: cmp(a.path, b.path)

proc evictLru*(ds: DiskStore; targetBytes: uint64) =
  ## Evicts oldest-first until `currentBytes <= targetBytes`. Each
  ## unlink bumps `evictionCount` so the daemon's metrics surface the
  ## pressure. Idempotent: if the store is already under the target,
  ## no work is done.
  if ds.currentBytes <= targetBytes:
    return
  let candidates = enumerateByMtime(ds)
  for entry in candidates:
    if ds.currentBytes <= targetBytes:
      break
    try:
      removeFile(entry.path)
      if uint64(entry.size) >= ds.currentBytes:
        ds.currentBytes = 0
      else:
        ds.currentBytes -= uint64(entry.size)
      inc ds.evictionCount
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Public store / load API.
# ---------------------------------------------------------------------------

proc has*(ds: DiskStore; digest: BlobDigest): bool =
  let hex = digestToHex(digest)
  fileExists(blobPath(ds, hex))

proc store*(ds: DiskStore; digest: BlobDigest;
            bytes: openArray[byte]): bool =
  ## Writes `bytes` to the store under `digest`. Returns `true` on a
  ## fresh write, `false` if the blob was already present (idempotent
  ## re-stores). Triggers eviction if the new write would push the
  ## store over `maxBytes` — eviction aims for ~10% headroom so the
  ## next write doesn't immediately re-evict.
  let hex = digestToHex(digest)
  let dir = shardDir(ds, hex)
  let path = blobPath(ds, hex)
  if fileExists(path):
    # Idempotent — refresh mtime so a duplicate write keeps the entry
    # warm in the LRU window.
    try:
      setLastModificationTime(path, getTime())
    except CatchableError:
      discard
    return false
  if not dirExists(dir):
    try: createDir(dir) except CatchableError: discard
  # If storing this blob would push us over the cap, evict oldest
  # entries until we have enough headroom for the new bytes. The goal
  # is `maxBytes - bytes.len` so the resulting `currentBytes + bytes.len`
  # lands at or below the cap.
  let needed = uint64(bytes.len)
  if ds.maxBytes > 0 and ds.currentBytes + needed > ds.maxBytes:
    let goal =
      if needed >= ds.maxBytes: 0'u64
      else: ds.maxBytes - needed
    evictLru(ds, goal)
  # Write atomically via a temp file + rename so a crash mid-write
  # doesn't leave a partial blob masquerading as a complete one.
  let tmpPath = path & ".tmp"
  try:
    var f = open(tmpPath, fmWrite)
    if bytes.len > 0:
      let n = f.writeBuffer(unsafeAddr bytes[0], bytes.len)
      if n != bytes.len:
        f.close()
        removeFile(tmpPath)
        return false
    f.close()
    moveFile(tmpPath, path)
    ds.currentBytes += uint64(bytes.len)
    return true
  except CatchableError:
    try: removeFile(tmpPath) except CatchableError: discard
    return false

proc load*(ds: DiskStore; digest: BlobDigest): Option[seq[byte]] =
  ## Returns `some(bytes)` on hit, `none` on miss. A successful load
  ## bumps the file's mtime so the entry moves to the front of the
  ## LRU window.
  let hex = digestToHex(digest)
  let path = blobPath(ds, hex)
  if not fileExists(path):
    return none(seq[byte])
  var data: seq[byte]
  try:
    let f = open(path, fmRead)
    defer: f.close()
    let size = int(getFileSize(path))
    data = newSeq[byte](size)
    if size > 0:
      let n = f.readBuffer(addr data[0], size)
      if n != size:
        return none(seq[byte])
  except CatchableError:
    return none(seq[byte])
  # Touch mtime so future `evictLru` calls treat the entry as warm.
  try:
    setLastModificationTime(path, getTime())
  except CatchableError:
    discard
  some(data)

proc filterContents*(ds: DiskStore;
                     capacity: uint32 = 1024'u32): CuckooFilter =
  ## Builds a cuckoo filter over the current contents — used by the
  ## tier-2 daemon when emitting an `AdvertiseV2` snapshot of its
  ## store. The `capacity` parameter follows the same sizing heuristic
  ## as `registry.snapshotV2For`: caller picks a target capacity, the
  ## filter widens to fit the actual content count if larger.
  var hexNames = newSeq[string]()
  if dirExists(ds.rootDir):
    for shard in walkDir(ds.rootDir, relative = false):
      if shard.kind != pcDir: continue
      let prefix = extractFilename(shard.path)
      if prefix.len != ShardDigits: continue
      for entry in walkDir(shard.path, relative = false):
        if entry.kind != pcFile: continue
        let leaf = extractFilename(entry.path)
        if leaf.len != 64 - ShardDigits: continue
        hexNames.add(prefix & leaf)
  let cap =
    if capacity < uint32(hexNames.len): uint32(hexNames.len)
    else: capacity
  result = newCuckooFilter(max(cap, 1'u32))
  for hex in hexNames:
    let d = hexToDigest(hex)
    discard result.insert(bytes(d))

proc enumerateDigests*(ds: DiskStore): seq[BlobDigest] =
  ## Returns every blob digest currently in the store. Used by the
  ## tier-2 daemon to seed its registry's self-advertised set on
  ## startup and after each upstream pull.
  result = @[]
  if not dirExists(ds.rootDir):
    return
  for shard in walkDir(ds.rootDir, relative = false):
    if shard.kind != pcDir: continue
    let prefix = extractFilename(shard.path)
    if prefix.len != ShardDigits: continue
    for entry in walkDir(shard.path, relative = false):
      if entry.kind != pcFile: continue
      let leaf = extractFilename(entry.path)
      if leaf.len != 64 - ShardDigits: continue
      result.add(hexToDigest(prefix & leaf))
