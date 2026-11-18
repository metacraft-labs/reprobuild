## NPC-M3 verification ``test_npc_m3_shard_hash_mismatch_refused``: a shard
## whose bytes do not hash to the root's entry is refused (threat model G3,
## first half: the hash check runs before the decoder).
##
## The substitutes are VALID shards -- the decoder alone accepts them (the
## positive control below) -- so only the hash check can refuse them.

import std/[sequtils, tables, unittest]

import repro_nimble_index

import ./index_fixtures

proc refusal(body: proc ()): string =
  try:
    body()
    "no refusal"
  except NimbleIndexError as e:
    $e.reason

proc fixturePackages(): seq[PackageEnvelope] =
  for i in 0 ..< 40:
    let name = "pkg" & $i
    result.add package(name, @[record(name, "1.0.0", @[req("dep", ">= 1.0.0")])])

suite "NPC-M3: a shard that does not hash to the root's entry is refused":
  let built = buildIndex(buildInput(fixturePackages(), shardBits = 3))
  let target = "pkg7"
  let bucket = shardBucket(nameKey(target), int(built.root.shardBits))
  var entry: ShardRef
  for s in built.root.shards:
    if s.bucket == bucket: entry = s
  let genuine = objectTable(built)[entry.id]

  proc substitute(): seq[byte] =
    ## The same shard with the target's requirement changed: same bucket,
    ## same package count, a valid encoding -- other bytes.
    var shard = decodeShard(genuine)
    for p in shard.packages.mitems:
      if p.name == target:
        p.versions[0].requires = @[req("evil", ">= 6.6.6")]
    encodeShard(shard)

  test "the genuine shard is read (positive control)":
    var idx = openIndex(memorySource(objectTable(built)), built.rootId)
    let found = lookupPackage(idx, target)
    check found.found
    check found.package.versions[0].requires.mapIt(it.target) == @["dep"]

  test "a substituted valid shard under the genuine id is refused before decoding":
    let bad = substitute()
    check bad != genuine
    # The decoder alone accepts it: only the hash check stands in its way.
    check decodeShard(bad).packages.anyIt(it.name == target)
    var objects = objectTable(built)
    objects[entry.id] = bad
    var idx = openIndex(memorySource(objects), built.rootId)
    let reason = refusal(proc () = discard lookupPackage(idx, target))
    # Same length when the substitute is the same size; either refusal is
    # the hash check's half (size, then hash), and neither decodes.
    check reason in [$nrHashMismatch, $nrSizeMismatch]

  test "a substitute of the recorded size is refused by its hash":
    var shard = decodeShard(genuine)
    for p in shard.packages.mitems:
      if p.name == target:
        # Same length: change one character of a constraint.
        p.versions[0].requires[0].constraint = ">= 1.0.1"
        p.versions[0].requires[0].source = "dep >= 1.0.1"
    let bad = encodeShard(shard)
    check bad.len == genuine.len
    check bad != genuine
    var objects = objectTable(built)
    objects[entry.id] = bad
    var idx = openIndex(memorySource(objects), built.rootId)
    check refusal(proc () = discard lookupPackage(idx, target)) ==
      $nrHashMismatch

  test "one flipped byte is refused by the hash":
    var bad = genuine
    bad[bad.len div 2] = bad[bad.len div 2] xor 0x01
    var objects = objectTable(built)
    objects[entry.id] = bad
    var idx = openIndex(memorySource(objects), built.rootId)
    check refusal(proc () = discard lookupPackage(idx, target)) ==
      $nrHashMismatch

  test "another valid shard of the index served under this id is refused":
    var other: ShardRef
    for s in built.root.shards:
      if s.bucket != bucket and s.size == entry.size: other = s
    var objects = objectTable(built)
    if other.size == entry.size and other.id != entry.id:
      objects[entry.id] = objectTable(built)[other.id]
    else:
      # No same-size neighbour in this fixture: serve any other shard.
      objects[entry.id] = objectTable(built)[built.root.shards[
        (if built.root.shards[0].bucket == bucket: 1 else: 0)].id]
    var idx = openIndex(memorySource(objects), built.rootId)
    check refusal(proc () = discard lookupPackage(idx, target)) in
      [$nrHashMismatch, $nrSizeMismatch]

  test "a root that does not hash to the pinned identity is refused":
    var root = built.root
    root.generatedAt += 1
    let bad = encodeRoot(root)
    var objects = objectTable(built)
    objects[built.rootId] = bad
    check refusal(proc () =
      discard openIndex(memorySource(objects), built.rootId)) ==
      $nrHashMismatch
