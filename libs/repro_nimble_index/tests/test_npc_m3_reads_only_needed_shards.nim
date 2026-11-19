## NPC-M3 verification ``test_npc_m3_reads_only_needed_shards``:
## resolving a three-package closure from a 3000-package index opens the
## root and at most three shards.
##
## The shards opened are counted from OUTSIDE the reader: every object it
## asks its source for goes through ``countingSource``, which records the
## id and the kind the object's frame names. Nothing the reader says about
## itself is consulted.

import std/[algorithm, os, sequtils, sets, tempfiles, unittest]

import repro_nimble_index

import ./index_fixtures

suite "NPC-M3: a closure reads the root and only the shards it touches":
  let built = syntheticIndex(3000)

  test "a three-package closure of a 3000-package index opens the root and at most three shards":
    check built.root.packageCount == 3000
    # The index really is sharded: reading all of it would be visible.
    check built.root.shardBits == 8
    check built.root.shards.len > 200
    let log = FetchLog()
    var idx = openIndex(countingSource(memorySource(objectTable(built)), log),
      built.rootId)
    let input = solverInput(idx, ["alpha"], LinuxAmd64)
    check input.packages.mapIt(it.name) == @["alpha", "beta", "gamma"]
    check input.missing.len == 0
    check log.kinds("root") == @[built.rootId]
    let shards = log.kinds("shard")
    check shards.len >= 1
    check shards.len <= 3
    check shards.toHashSet.len == shards.len # each opened once
    # Exactly the shards of the three names, and nothing else at all.
    var expected = initHashSet[IndexObjectId]()
    for name in ["alpha", "beta", "gamma"]:
      let b = shardBucket(nameKey(name), int(built.root.shardBits))
      for s in built.root.shards:
        if s.bucket == b: expected.incl s.id
    check shards.toHashSet == expected
    check log.fetches.len == 1 + shards.len
    check log.kinds("name-map").len == 0
    check log.kinds("events").len == 0

  test "each candidate carries its own version's requirements":
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let input = solverInput(idx, ["alpha"], LinuxAmd64)
    let alpha = input.packages[0]
    check alpha.candidates.mapIt(it.version) == @["1.0.0", "1.1.0"]
    check alpha.candidates.mapIt(it.requires.mapIt(it.range)) ==
      @[@[">= 1.0.0"], @[">= 1.1.0"]]
    let deps = perVersionDependencies(input, input.packages[1])
    check deps.mapIt(it[0]) == @["1.0.0", "1.1.0"]
    # `Gamma` is written in another style; the closure resolved it to the
    # canonical name.
    check deps.mapIt(it[1].mapIt(it.name)) == @[@["nimble:gamma"],
      @["nimble:gamma"]]
    check deps.mapIt(it[1].mapIt(it.range)) == @[@[""], @[">= 0.1.0"]]

  test "the same closure read from an index directory on disk":
    let dir = createTempDir("npc-m3-index-", "")
    defer: removeDir(dir)
    writeIndexDir(built, dir)
    check indexDirRootId(dir) == built.rootId
    let log = FetchLog()
    var idx = openIndex(countingSource(directorySource(dir), log),
      indexDirRootId(dir))
    let input = solverInput(idx, ["alpha"], LinuxAmd64)
    check input.packages.mapIt(it.name) == @["alpha", "beta", "gamma"]
    check log.kinds("root").len == 1
    check log.kinds("shard").len <= 3
    check log.fetches.len == 1 + log.kinds("shard").len

  test "a name the index does not hold opens at most the one shard it would be in":
    let log = FetchLog()
    var idx = openIndex(countingSource(memorySource(objectTable(built)), log),
      built.rootId)
    let input = solverInput(idx, ["no-such-package"], LinuxAmd64)
    check input.packages.len == 0
    check input.missing == @["no-such-package"]
    check log.kinds("shard").len <= 1
    check log.fetches.len <= 2
