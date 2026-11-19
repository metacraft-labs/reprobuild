## Reading a Nimble index by hash: the root first, then only the shards the
## names a caller asks for live in.
##
## An index is read through an ``IndexObjectSource``: anything that returns
## an object's bytes given its id (a directory, a git object store, a
## mirror, the content-addressed store). The source is NOT trusted. Every
## object is checked before it is decoded:
##
## 1. the root's bytes must hash (BLAKE3-256) to the id the caller pinned --
##    the index identity a lock records;
## 2. a shard's bytes must have exactly the size the root records for it and
##    hash to the id the root records for it (threat model G3: a substituted
##    or corrupted shard is refused before its decoder runs);
## 3. only then is the object decoded, by the bounded, fail-closed,
##    canonical codec of ``repro_domain_types/nimble_index``.
##
## A shard is fetched the first time a name in it is asked for, and kept;
## the root names every shard, so nothing else is ever listed or scanned.

import std/[algorithm, options, os, tables]
from std/memfiles import nil

import repro_domain_types/nimble_index

export nimble_index

type
  IndexObjectFetch* = proc (id: IndexObjectId; maxBytes: int): seq[byte] {.closure.}
    ## Return the bytes stored under ``id``. Raise ``NimbleIndexError`` with
    ## ``nrMissingObject`` when there is none, and with ``nrOversize`` rather
    ## than read more than ``maxBytes``. The bytes are checked by the caller.

  IndexObjectSource* = object
    fetch*: IndexObjectFetch
    description*: string ## for diagnostics: where the objects come from

  NimbleIndex* = object
    ## An opened index: its verified root and the shards read so far.
    source: IndexObjectSource
    rootId*: IndexObjectId
    root*: NimbleIndexRoot
    shards: Table[uint32, NimbleShard]

  PackageLookup* = object
    found*: bool
    package*: PackageEnvelope
    requestedAs*: string ## the name asked for
    alias*: string       ## non-empty when the name was an alias

proc readVerified*(source: IndexObjectSource; id: IndexObjectId;
                   expectedSize: int; maxBytes: int; what: string): seq[byte] =
  ## Fetch ``id`` and check size and hash before anyone decodes it.
  ## ``expectedSize`` < 0: not known in advance (the root).
  result = source.fetch(id, maxBytes)
  if result.len > maxBytes:
    refuse(nrOversize, what & " " & $id & " from " & source.description &
      " is " & $result.len & " bytes, more than " & $maxBytes)
  if expectedSize >= 0 and result.len != expectedSize:
    refuse(nrSizeMismatch, what & " " & $id & " from " & source.description &
      " is " & $result.len & " bytes; the root records " & $expectedSize)
  let actual = indexObjectId(result)
  if actual != id:
    refuse(nrHashMismatch, what & " " & $id & " from " & source.description &
      " hashes to " & $actual & ", not to the id it was requested by; " &
      "nothing read from it is used")

proc openIndex*(source: IndexObjectSource; rootId: IndexObjectId): NimbleIndex =
  ## Fetch and verify the root named by ``rootId``. Reads nothing else.
  let bytes = readVerified(source, rootId, -1, MaxRootBytes, "root")
  NimbleIndex(source: source, rootId: rootId, root: decodeRoot(bytes))

proc shardRefFor(idx: NimbleIndex; bucket: uint32): int =
  idx.root.shards.binarySearch(bucket, proc (s: ShardRef; b: uint32): int =
    cmp(s.bucket, b))

proc loadShard*(idx: var NimbleIndex; bucket: uint32): Option[NimbleShard] =
  ## The shard of ``bucket``: none when the root lists no shard there (no
  ## package of the index hashes to it). Fetched, verified and decoded once.
  if bucket in idx.shards:
    return some(idx.shards[bucket])
  let at = shardRefFor(idx, bucket)
  if at < 0:
    return none(NimbleShard)
  let r = idx.root.shards[at]
  let bytes = readVerified(idx.source, r.id, int(r.size), MaxShardBytes,
    "shard " & $bucket)
  let shard = decodeShard(bytes)
  if shard.bucket != bucket or shard.shardBits != idx.root.shardBits:
    refuse(nrWrongShard, "shard " & $r.id & " says it is bucket " &
      $shard.bucket & " at " & $shard.shardBits & " bits; the root lists it " &
      "as bucket " & $bucket & " at " & $idx.root.shardBits)
  if uint32(shard.packages.len) != r.packages:
    refuse(nrInconsistent, "shard " & $r.id & " holds " &
      $shard.packages.len & " packages; the root records " & $r.packages)
  idx.shards[bucket] = shard
  some(shard)

proc findIn(shard: NimbleShard; key: string): int =
  shard.packages.binarySearch(key, proc (p: PackageEnvelope; k: string): int =
    cmp(nameKey(p.name), k))

proc findAliasIn(shard: NimbleShard; key: string): int =
  shard.aliases.binarySearch(key, proc (a: PackageAlias; k: string): int =
    cmp(nameKey(a.alias), k))

proc lookupPackage*(idx: var NimbleIndex; name: string): PackageLookup =
  ## The package ``name`` names, under Nimble's style-insensitive comparison,
  ## following one alias. Reads the shard of ``name`` and, for an alias,
  ## the shard of its target.
  result.requestedAs = name
  let key = nameKey(name)
  let shard = loadShard(idx, shardBucket(key, int(idx.root.shardBits)))
  if shard.isNone:
    return
  let at = findIn(shard.get, key)
  if at >= 0:
    result.found = true
    result.package = shard.get.packages[at]
    return
  let a = findAliasIn(shard.get, key)
  if a < 0:
    return
  let target = shard.get.aliases[a].target
  let tkey = nameKey(target)
  let tshard = loadShard(idx, shardBucket(tkey, int(idx.root.shardBits)))
  let t = if tshard.isSome: findIn(tshard.get, tkey) else: -1
  if t < 0:
    refuse(nrInconsistent, "alias " & name & " names " & target &
      ", which the index does not hold")
  result.found = true
  result.alias = shard.get.aliases[a].alias
  result.package = tshard.get.packages[t]

proc loadNameMap*(idx: NimbleIndex): NimbleNameMap =
  ## The whole name map (for search and listing; resolution never needs it).
  let r = idx.root.nameMap
  decodeNameMap(readVerified(idx.source, r.id, int(r.size), MaxNameMapBytes,
    "name map"))

proc loadEvents*(idx: NimbleIndex): NimbleEvents =
  let r = idx.root.events
  decodeEvents(readVerified(idx.source, r.id, int(r.size), MaxEventsBytes,
    "events"))

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

proc memorySource*(objects: Table[IndexObjectId, seq[byte]];
                   description = "memory"): IndexObjectSource =
  ## Objects held in memory, keyed by id (tests, an in-process generator).
  let held = objects
  IndexObjectSource(description: description,
    fetch: proc (id: IndexObjectId; maxBytes: int): seq[byte] =
      if id notin held:
        refuse(nrMissingObject, "object " & $id & " is not in " & description)
      result = held[id]
      if result.len > maxBytes:
        refuse(nrOversize, "object " & $id & " is " & $result.len &
          " bytes, more than " & $maxBytes))

const
  IndexRootFile* = "root"
    ## The root object, at the top of an index directory
    ## (``published-index/root`` in an index repository).
  IndexObjectsDir* = "objects"
    ## Every object, the root included, as ``objects/<64 hex id>``.

proc objectPath*(dir: string; id: IndexObjectId): string =
  dir / IndexObjectsDir / $id

proc directorySource*(dir: string): IndexObjectSource =
  ## An index directory: ``root`` and ``objects/<id>``. A file larger than
  ## the caller's bound is refused from its size, before it is read.
  IndexObjectSource(description: dir,
    fetch: proc (id: IndexObjectId; maxBytes: int): seq[byte] =
      let path = objectPath(dir, id)
      var info: FileInfo
      var found = true
      try:
        info = getFileInfo(path, followSymlink = false)
      except OSError:
        found = false
      if not found:
        refuse(nrMissingObject, "object " & $id & " is not in " & dir)
      if info.kind != pcFile:
        refuse(nrMissingObject, path & " is not a regular file")
      if info.size > maxBytes:
        refuse(nrOversize, path & " is " & $info.size & " bytes, more than " &
          $maxBytes)
      var s: string
      var failure = ""
      try:
        s = readFile(path)
      except IOError as e:
        failure = e.msg
      if failure.len > 0:
        refuse(nrMissingObject, "cannot read " & path & ": " & failure)
      result = newSeq[byte](s.len)
      for i, c in s: result[i] = byte(ord(c))
      if result.len > maxBytes:
        refuse(nrOversize, path & " grew while it was read"))

proc indexDirRootId*(dir: string): IndexObjectId =
  ## The identity of the index in ``dir``: the hash of its ``root`` file,
  ## refused unread when it is larger than a root may be.
  let path = dir / IndexRootFile
  if getFileSize(path) > MaxRootBytes:
    refuse(nrOversize, path & " is larger than " & $MaxRootBytes & " bytes")
  let s = readFile(path)
  var b = newSeq[byte](s.len)
  for i, c in s: b[i] = byte(ord(c))
  indexObjectId(b)

type
  MappedIndexObject* = object
    ## An index object memory-mapped for navigator access.
    file: memfiles.MemFile
    view*: ByteView

proc mapIndexObject*(dir: string; id: IndexObjectId;
                     maxBytes: int): MappedIndexObject =
  ## Map ``objects/<id>`` read-only, after checking its size bound and its
  ## hash (which reads the mapped pages once). The view is valid until
  ## ``close``.
  let path = objectPath(dir, id)
  var info: FileInfo
  var found = true
  try:
    info = getFileInfo(path, followSymlink = false)
  except OSError:
    found = false
  if not found:
    refuse(nrMissingObject, "object " & $id & " is not in " & dir)
  if info.kind != pcFile:
    refuse(nrMissingObject, path & " is not a regular file")
  if info.size > maxBytes:
    refuse(nrOversize, path & " is " & $info.size & " bytes, more than " &
      $maxBytes)
  if info.size == 0:
    refuse(nrTruncated, path & " is empty")
  result.file = memfiles.open(path, mode = fmRead)
  # The mapping, not the earlier stat, is what the view reads: check it.
  if result.file.size > maxBytes or result.file.size == 0:
    let mapped = result.file.size
    memfiles.close(result.file)
    refuse(nrOversize, path & " changed size while it was mapped (" &
      $mapped & " bytes)")
  result.view = viewOf(result.file.mem, result.file.size)
  if indexObjectId(bytesOf(result.view)) != id:
    memfiles.close(result.file)
    refuse(nrHashMismatch, path & " does not hash to its name")

proc close*(m: var MappedIndexObject) =
  memfiles.close(m.file)
  m.view = ByteView()
