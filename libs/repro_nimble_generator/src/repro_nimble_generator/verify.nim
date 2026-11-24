## `repro catalog verify`: a second operator repeats a generation and
## compares the roots (NPC-AREQ9).
##
## The repeat runs from the same inputs the index names: the source set
## (its identity must equal the root's `sourceSet`), the previous
## generation (its root must be the root's `previousRoot`) and the
## generation time (the root's `generatedAt`). The repeat fetches the
## origins itself. Equal roots verify the index. A difference is reported
## by package and field: either an origin that changed between the two runs
## (its observation differs) or a defect in the generator or in one
## operator.

import std/[algorithm, options, os, sets, strutils, tables]

import repro_domain_types/nimble_index
import repro_nimble_index

import ./generator
import ./source_set

type
  IndexDifference* = object
    package*: string ## "" for an index-wide difference
    field*: string
    published*: string
    repeated*: string

  VerifyResult* = object
    verified*: bool
    publishedRoot*: IndexObjectId
    repeatedRoot*: IndexObjectId
    differences*: seq[IndexDifference]
    generation*: GenerationResult

  VerifyError* = object of CatchableError

proc allShards(source: IndexObjectSource; rootId: IndexObjectId):
    tuple[root: NimbleIndexRoot; envelopes: Table[string, PackageEnvelope];
          observations: Table[string, PackageObservation];
          aliases: Table[string, string]; events: seq[OriginEvent]] =
  var idx = openIndex(source, rootId)
  result.root = idx.root
  for r in idx.root.shards:
    let s = idx.loadShard(r.bucket)
    if s.isNone: continue
    for p in s.get.packages: result.envelopes[p.name] = p
    for o in s.get.observations: result.observations[o.name] = o
    for a in s.get.aliases: result.aliases[a.alias] = a.target
  result.events = idx.loadEvents().events

proc recordLabel(r: VersionRecord): string =
  $r.version.kind & " " & (if r.version.tag.len > 0: r.version.tag else: "-") &
    " " & r.commit

proc recordText(r: VersionRecord): string =
  ## A record's fields as one line each, for a field-level comparison.
  let shard = NimbleShard(packages: @[PackageEnvelope(name: "x",
    origins: @[PackageOrigin(url: "https://x.invalid/")],
    versions: @[r])])
  renderShard(shard)

proc compareIndexes*(published, repeated: IndexObjectSource;
                     publishedRoot, repeatedRoot: IndexObjectId):
                       seq[IndexDifference] =
  ## Every difference between two generations, by package and field.
  let a = allShards(published, publishedRoot)
  let b = allShards(repeated, repeatedRoot)
  var found: seq[IndexDifference]
  proc diff(pkgName, what, x, y: string) =
    found.add IndexDifference(package: pkgName, field: what, published: x,
      repeated: y)
  for (f, x, y) in [("generator", a.root.generator, b.root.generator),
                    ("source_set", $a.root.sourceSet, $b.root.sourceSet),
                    ("generated_at", $a.root.generatedAt, $b.root.generatedAt),
                    ("shard_bits", $a.root.shardBits, $b.root.shardBits),
                    ("full_history", $a.root.fullHistory, $b.root.fullHistory),
                    ("last_full_check", $a.root.lastFullCheck,
                     $b.root.lastFullCheck)]:
    if x != y: diff("", f, x, y)
  var names = initHashSet[string]()
  for n in a.envelopes.keys: names.incl n
  for n in b.envelopes.keys: names.incl n
  for n in a.observations.keys: names.incl n
  for n in b.observations.keys: names.incl n
  var sorted: seq[string]
  for n in names: sorted.add n
  sorted.sort()
  for n in sorted:
    let ea = a.envelopes.getOrDefault(n)
    let eb = b.envelopes.getOrDefault(n)
    let inA = n in a.envelopes
    let inB = n in b.envelopes
    if inA != inB:
      diff(n, "package", (if inA: "present" else: "absent"),
        (if inB: "present" else: "absent"))
    if inA and inB:
      if ea.origins != eb.origins:
        diff(n, "origins", $ea.origins, $eb.origins)
      if ea.registryOrigin != eb.registryOrigin:
        diff(n, "registry_origin", $ea.registryOrigin, $eb.registryOrigin)
      var ra, rb = initTable[string, VersionRecord]()
      for r in ea.versions: ra[recordLabel(r)] = r
      for r in eb.versions: rb[recordLabel(r)] = r
      var labels = initHashSet[string]()
      for l in ra.keys: labels.incl l
      for l in rb.keys: labels.incl l
      var ls: seq[string]
      for l in labels: ls.add l
      ls.sort()
      for l in ls:
        if l notin ra: diff(n, "version " & l, "absent", "present")
        elif l notin rb: diff(n, "version " & l, "present", "absent")
        elif ra[l] != rb[l]:
          let xa = recordText(ra[l]).splitLines()
          let xb = recordText(rb[l]).splitLines()
          for i in 0 ..< max(xa.len, xb.len):
            let la = if i < xa.len: xa[i] else: ""
            let lb = if i < xb.len: xb[i] else: ""
            if la != lb:
              diff(n, "version " & l, la.strip(), lb.strip())
    let oa = a.observations.getOrDefault(n)
    let ob = b.observations.getOrDefault(n)
    if (n in a.observations) != (n in b.observations) or oa != ob:
      if oa.state != ob.state: diff(n, "origin state", $oa.state, $ob.state)
      if oa.head != ob.head or oa.headRef != ob.headRef:
        diff(n, "origin HEAD", oa.headRef & " " & oa.head,
          ob.headRef & " " & ob.head)
      if oa.tags != ob.tags:
        var ta, tb = initTable[string, string]()
        for t in oa.tags: ta[t.name] = t.commit
        for t in ob.tags: tb[t.name] = t.commit
        var tags = initHashSet[string]()
        for t in ta.keys: tags.incl t
        for t in tb.keys: tags.incl t
        var ts: seq[string]
        for t in tags: ts.add t
        ts.sort()
        for t in ts:
          if ta.getOrDefault(t) != tb.getOrDefault(t):
            diff(n, "origin tag " & t, ta.getOrDefault(t, "absent"),
              tb.getOrDefault(t, "absent"))
      if oa.held != ob.held:
        diff(n, "held versions", $oa.held.len, $ob.held.len)
      if oa.origin != ob.origin:
        diff(n, "observed origin", oa.origin.url, ob.origin.url)
  if a.aliases != b.aliases:
    diff("", "aliases", $a.aliases.len, $b.aliases.len)
  if a.events != b.events:
    diff("", "events", $a.events.len & " events", $b.events.len & " events")
  found

proc compareObjectFiles*(indexDir: string; repeated: BuiltIndex):
    seq[IndexDifference] =
  ## The objects of ``indexDir`` against the repeat's, byte for byte: equal
  ## roots name equal objects, and the directory must hold exactly those.
  ## A reader fetches the objects, not the root alone, so a directory with
  ## a tampered, missing or extra object is not the index that was
  ## repeated, whatever its root says.
  var keep = initHashSet[string]()
  for (id, bytes) in repeated.objects:
    keep.incl $id
    let path = objectPath(indexDir, id)
    if not fileExists(path):
      result.add IndexDifference(field: "object " & $id,
        published: "absent", repeated: "present")
      continue
    let data = readFile(path)
    var same = data.len == bytes.len
    if same:
      for i, c in data:
        if byte(ord(c)) != bytes[i]:
          same = false
          break
    if not same:
      var b = newSeq[byte](data.len)
      for i, c in data: b[i] = byte(ord(c))
      result.add IndexDifference(field: "object " & $id,
        published: "blake3:" & $indexObjectId(b), repeated: "blake3:" & $id)
  var extra: seq[string]
  for kind, path in walkDir(indexDir / IndexObjectsDir):
    if extractFilename(path) notin keep: extra.add extractFilename(path)
  extra.sort()
  for e in extra:
    result.add IndexDifference(field: "object " & e, published: "present",
      repeated: "absent")

proc verifyIndex*(indexDir: string; sourceSet: SourceSet;
                  previousIndex, stateDir: string;
                  base: GeneratorConfig = GeneratorConfig(shardBits: -1)):
                    VerifyResult =
  ## Repeat the generation of the index in ``indexDir`` and compare.
  let publishedRoot = indexDirRootId(indexDir)
  let published = directorySource(indexDir)
  let root = openIndex(published, publishedRoot).root
  if sourceSetIdentity(sourceSet) != root.sourceSet:
    raise newException(VerifyError, "the source set is not the one the " &
      "index was generated from: its identity is " &
      $sourceSetIdentity(sourceSet) & ", the root names " & $root.sourceSet)
  if root.previousRoot.isSome:
    if previousIndex.len == 0:
      raise newException(VerifyError, "the index was generated from a " &
        "previous generation (root " & $root.previousRoot.get & "); name " &
        "its index directory with --previous")
    let prev = indexDirRootId(previousIndex)
    if prev != root.previousRoot.get:
      raise newException(VerifyError, "the previous index has root " &
        $prev & "; the index names " & $root.previousRoot.get)
  elif previousIndex.len > 0:
    raise newException(VerifyError, "the index names no previous " &
      "generation, but --previous was given")
  var cfg = base
  cfg.sourceSet = sourceSet
  cfg.generatedAt = root.generatedAt
  # The same history check the published generation ran (its root says
  # which), so a full-check generation is compared like with like.
  cfg.historyMode = if root.fullHistory: hmFull else: hmPerGeneration
  cfg.previousIndex = previousIndex
  cfg.stateDir = stateDir
  cfg.outputDir = ""
  if cfg.shardBits < 0: cfg.shardBits = int(root.shardBits)
  result.generation = generate(cfg)
  result.publishedRoot = publishedRoot
  result.repeatedRoot = result.generation.built.rootId
  if result.publishedRoot == result.repeatedRoot:
    result.differences = compareObjectFiles(indexDir, result.generation.built)
  else:
    result.differences = compareIndexes(published,
      memorySource(result.generation.built.objectTable(), "repeated run"),
      publishedRoot, result.repeatedRoot)
  result.verified = result.publishedRoot == result.repeatedRoot and
    result.differences.len == 0
