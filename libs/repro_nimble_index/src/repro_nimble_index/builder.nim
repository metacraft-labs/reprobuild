## Writing a Nimble index: shards, name map, events and the root, from
## package envelopes. This is the library the generator's `shard` and `root`
## edges call, and what tests build fixtures with.
##
## Deterministic: the output is a function of the input VALUES alone. Input
## order does not matter -- packages, aliases, versions, modules and events
## are put in their canonical order here -- and nothing reads a clock, a
## path or the environment (`generatedAt` is an input). The same input
## therefore produces the same bytes and the same root id on any host.

import std/[algorithm, options, os, sets, tables]

import repro_domain_types/nimble_index
import ./reader

type
  IndexBuildInput* = object
    generator*: string
    sourceSet*: IndexObjectId
    generatedAt*: uint64
    previousRoot*: Option[IndexObjectId]
    shardBits*: int
      ## bits of the shard keying hash; < 0 chooses ``defaultShardBits``
    packages*: seq[PackageEnvelope]
    aliases*: seq[PackageAlias]
    events*: seq[OriginEvent]

  BuiltIndex* = object
    rootId*: IndexObjectId
    root*: NimbleIndexRoot
    rootBytes*: seq[byte]
    objects*: seq[(IndexObjectId, seq[byte])]
      ## every object, the root included, sorted by id

const TargetPackagesPerShard* = 16

proc defaultShardBits*(packageCount: int): int =
  ## The fewest bits that keep the average shard at or below
  ## ``TargetPackagesPerShard`` packages: 8 bits (256 shards) for the 3009
  ## registry packages.
  result = 0
  while result < MaxShardBits and
      (packageCount + (1 shl result) - 1) div (1 shl result) >
        TargetPackagesPerShard:
    inc result

proc canonicalPackage*(p: PackageEnvelope): PackageEnvelope =
  ## ``p`` with its versions and module lists in canonical order.
  result = p
  for v in result.versions.mitems:
    v.layout.modules.sort()
  result.versions.sort(proc (a, b: VersionRecord): int =
    cmp(versionSortKey(a), versionSortKey(b)))

proc buildShard*(shardBits: int; bucket: uint32;
                 packages: seq[PackageEnvelope];
                 aliases: seq[PackageAlias]): seq[byte] =
  ## One shard's bytes. Refuses (``NimbleIndexError``) what the reader would
  ## refuse: a package in the wrong bucket, a duplicate name, a bound.
  var s = NimbleShard(shardBits: uint8(shardBits), bucket: bucket)
  for p in packages: s.packages.add canonicalPackage(p)
  s.packages.sort(proc (a, b: PackageEnvelope): int =
    cmp(nameKey(a.name), nameKey(b.name)))
  s.aliases = aliases
  s.aliases.sort(proc (a, b: PackageAlias): int =
    cmp(nameKey(a.alias), nameKey(b.alias)))
  encodeShard(s)

proc buildIndex*(input: IndexBuildInput): BuiltIndex =
  ## Every object of one index generation and its root.
  let bits =
    if input.shardBits < 0: defaultShardBits(input.packages.len)
    else: input.shardBits
  if bits > MaxShardBits:
    refuse(nrBound, "shardBits " & $bits & " exceeds " & $MaxShardBits)
  var canonical = initTable[string, string]()
  for p in input.packages:
    let k = nameKey(p.name)
    if k in canonical:
      refuse(nrDuplicate, "two packages are named " & p.name & " and " &
        canonical[k] & " under the style-insensitive comparison")
    canonical[k] = p.name
  for a in input.aliases:
    if nameKey(a.target) notin canonical or
        canonical[nameKey(a.target)] != a.target:
      refuse(nrInconsistent, "alias " & a.alias & " names " & a.target &
        ", which is not a canonical package name of this index")
  var byBucket = initTable[uint32, (seq[PackageEnvelope], seq[PackageAlias])]()
  var versionCount = 0
  for p in input.packages:
    let b = shardBucket(nameKey(p.name), bits)
    byBucket.mgetOrPut(b, (@[], @[]))[0].add p
    versionCount += p.versions.len
  for a in input.aliases:
    let b = shardBucket(nameKey(a.alias), bits)
    byBucket.mgetOrPut(b, (@[], @[]))[1].add a
  var buckets: seq[uint32]
  for b in byBucket.keys: buckets.add b
  buckets.sort()
  var root = NimbleIndexRoot(generator: input.generator,
    sourceSet: input.sourceSet, generatedAt: input.generatedAt,
    previousRoot: input.previousRoot, packageCount: uint32(input.packages.len),
    versionCount: uint32(versionCount), eventCount: uint32(input.events.len),
    shardBits: uint8(bits))
  var objects = initTable[IndexObjectId, seq[byte]]()
  for b in buckets:
    let (ps, als) = byBucket[b]
    let bytes = buildShard(bits, b, ps, als)
    let id = indexObjectId(bytes)
    objects[id] = bytes
    root.shards.add ShardRef(bucket: b, id: id, size: uint64(bytes.len),
      packages: uint32(ps.len))
  var names = NimbleNameMap()
  for p in input.packages: names.entries.add NameEntry(name: p.name)
  for a in input.aliases:
    names.entries.add NameEntry(name: a.alias, target: a.target)
  names.entries.sort(proc (a, b: NameEntry): int =
    cmp(nameKey(a.name), nameKey(b.name)))
  let nameBytes = encodeNameMap(names)
  let nameId = indexObjectId(nameBytes)
  objects[nameId] = nameBytes
  root.nameMap = ObjectRef(id: nameId, size: uint64(nameBytes.len))
  var events = NimbleEvents(events: input.events)
  events.events.sort(proc (a, b: OriginEvent): int =
    cmp(eventSortKey(a), eventSortKey(b)))
  let eventBytes = encodeEvents(events)
  let eventId = indexObjectId(eventBytes)
  objects[eventId] = eventBytes
  root.events = ObjectRef(id: eventId, size: uint64(eventBytes.len))
  let rootBytes = encodeRoot(root)
  let rootId = indexObjectId(rootBytes)
  objects[rootId] = rootBytes
  result = BuiltIndex(rootId: rootId, root: root, rootBytes: rootBytes)
  for id, bytes in objects: result.objects.add (id, bytes)
  result.objects.sort(proc (a, b: (IndexObjectId, seq[byte])): int =
    cmp($a[0], $b[0]))

proc objectTable*(b: BuiltIndex): Table[IndexObjectId, seq[byte]] =
  for (id, bytes) in b.objects: result[id] = bytes

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc writeIndexDir*(b: BuiltIndex; dir: string) =
  ## Write ``root`` and ``objects/<id>`` under ``dir`` (an index
  ## repository's ``published-index/``). ``objects/`` ends up holding
  ## exactly this generation's objects.
  createDir(dir / IndexObjectsDir)
  var keep = initHashSet[string]()
  for (id, bytes) in b.objects:
    keep.incl $id
    writeFile(objectPath(dir, id), toStr(bytes))
  for kind, path in walkDir(dir / IndexObjectsDir):
    if extractFilename(path) notin keep:
      removeFile(path)
  writeFile(dir / IndexRootFile, toStr(b.rootBytes))
