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
    observations*: seq[PackageObservation]
      ## the origin answers the generator recorded (the generator's state
      ## for the next generation); each in its own name key's shard

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
    v.submodules.sort(proc (a, b: RecordSubmodule): int = cmp(a.path, b.path))
  result.versions.sort(proc (a, b: VersionRecord): int =
    cmp(versionSortKey(a), versionSortKey(b)))

proc canonicalObservation*(o: PackageObservation): PackageObservation =
  ## ``o`` with its tags and held versions in canonical order.
  result = o
  result.tags.sort(proc (a, b: ObservedTag): int = cmp(a.name, b.name))
  result.held.sort(proc (a, b: HeldVersion): int =
    cmp(heldSortKey(a), heldSortKey(b)))

proc buildShard*(shardBits: int; bucket: uint32;
                 packages: seq[PackageEnvelope];
                 aliases: seq[PackageAlias];
                 observations: seq[PackageObservation] = @[]): seq[byte] =
  ## One shard's bytes. Refuses (``NimbleIndexError``) what the reader would
  ## refuse: a package in the wrong bucket, a duplicate name, a bound.
  var s = NimbleShard(shardBits: uint8(shardBits), bucket: bucket)
  for p in packages: s.packages.add canonicalPackage(p)
  s.packages.sort(proc (a, b: PackageEnvelope): int =
    cmp(nameKey(a.name), nameKey(b.name)))
  s.aliases = aliases
  s.aliases.sort(proc (a, b: PackageAlias): int =
    cmp(nameKey(a.alias), nameKey(b.alias)))
  for o in observations: s.observations.add canonicalObservation(o)
  s.observations.sort(proc (a, b: PackageObservation): int =
    cmp(nameKey(a.name), nameKey(b.name)))
  encodeShard(s)

proc buildRootFromShards*(input: IndexBuildInput; shardBits: int;
                          shards: seq[seq[byte]]): BuiltIndex =
  ## The root, name map and events of one generation whose shards are
  ## ``shards`` (encoded, any order). ``input.packages``, ``aliases`` and
  ## ``observations`` are ignored: the shards are what the root names, and
  ## each is decoded (bounded, canonical) to count and to name its packages.
  ## This is the generator's `root` edge; ``buildIndex`` ends with it too.
  var decoded: seq[(NimbleShard, seq[byte])]
  for bytes in shards:
    let s = decodeShard(bytes)
    if int(s.shardBits) != shardBits:
      refuse(nrInconsistent, "a shard at " & $s.shardBits & " bits in a " &
        "root at " & $shardBits)
    decoded.add (s, bytes)
  decoded.sort(proc (a, b: (NimbleShard, seq[byte])): int =
    cmp(a[0].bucket, b[0].bucket))
  var canonical = initTable[string, string]()
  var aliases: seq[PackageAlias]
  var packageCount, versionCount = 0
  for i, (s, _) in decoded:
    if i > 0 and decoded[i - 1][0].bucket == s.bucket:
      refuse(nrDuplicate, "two shards of bucket " & $s.bucket)
    for p in s.packages:
      let k = nameKey(p.name)
      if k in canonical:
        refuse(nrDuplicate, "two packages are named " & p.name & " and " &
          canonical[k] & " under the style-insensitive comparison")
      canonical[k] = p.name
      inc packageCount
      versionCount += p.versions.len
    for a in s.aliases: aliases.add a
  for a in aliases:
    if nameKey(a.target) notin canonical or
        canonical[nameKey(a.target)] != a.target:
      refuse(nrInconsistent, "alias " & a.alias & " names " & a.target &
        ", which is not a canonical package name of this index")
  var root = NimbleIndexRoot(generator: input.generator,
    sourceSet: input.sourceSet, generatedAt: input.generatedAt,
    previousRoot: input.previousRoot, packageCount: uint32(packageCount),
    versionCount: uint32(versionCount), eventCount: uint32(input.events.len),
    shardBits: uint8(shardBits))
  var objects = initTable[IndexObjectId, seq[byte]]()
  for (s, bytes) in decoded:
    let id = indexObjectId(bytes)
    objects[id] = bytes
    root.shards.add ShardRef(bucket: s.bucket, id: id,
      size: uint64(bytes.len), packages: uint32(s.packages.len))
  var names = NimbleNameMap()
  for k, n in canonical: names.entries.add NameEntry(name: n)
  for a in aliases:
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
  type Bucket = tuple[packages: seq[PackageEnvelope];
                      aliases: seq[PackageAlias];
                      observations: seq[PackageObservation]]
  var byBucket = initTable[uint32, Bucket]()
  for p in input.packages:
    let b = shardBucket(nameKey(p.name), bits)
    byBucket.mgetOrPut(b, (@[], @[], @[])).packages.add p
  for a in input.aliases:
    let b = shardBucket(nameKey(a.alias), bits)
    byBucket.mgetOrPut(b, (@[], @[], @[])).aliases.add a
  for o in input.observations:
    let b = shardBucket(nameKey(o.name), bits)
    byBucket.mgetOrPut(b, (@[], @[], @[])).observations.add o
  var buckets: seq[uint32]
  for b in byBucket.keys: buckets.add b
  buckets.sort()
  var shards: seq[seq[byte]]
  for b in buckets:
    let x = byBucket[b]
    shards.add buildShard(bits, b, x.packages, x.aliases, x.observations)
  buildRootFromShards(input, bits, shards)

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
