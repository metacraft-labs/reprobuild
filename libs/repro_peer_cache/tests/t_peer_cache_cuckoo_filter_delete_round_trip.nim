## Peer-Cache-Scale M1 verification test:
## insert 500 random digests, delete a random subset of 200, then
## check membership semantics:
##   - the 300 still-inserted digests all return true (no false
##     negatives).
##   - the 200 deleted digests all return false.
##   - re-inserting 50 of the deleted digests restores their
##     presence.

import std/[random, unittest]

import repro_peer_cache

proc randomDigest(rng: var Rand): array[32, byte] =
  for i in 0 ..< 32:
    result[i] = byte(rng.rand(255))

suite "peer-cache cuckoo filter delete round trip":
  test "inserts/deletes preserve no-false-negatives + re-insert works":
    let cf = newCuckooFilter(capacity = 2000'u32,
                             falsePositiveRate = 0.01,
                             seed = 0xde1e7e'i64)

    var rng = initRand(0xabc123'i64)
    var inserted: seq[array[32, byte]] = @[]
    var insertFailed = false
    while inserted.len < 500 and not insertFailed:
      let d = randomDigest(rng)
      if cf.insert(d):
        inserted.add(d)
      else:
        insertFailed = true
    check (not insertFailed)

    # Sanity: every inserted digest is present.
    for d in inserted:
      check cf.query(d)

    # Delete a deterministic-but-shuffled subset of 200.
    var shuffleRng = initRand(0xdeadbeef'i64)
    var indices: seq[int] = @[]
    for i in 0 ..< inserted.len:
      indices.add(i)
    shuffleRng.shuffle(indices)
    let toDelete = indices[0 ..< 200]
    let toKeep = indices[200 ..< 500]
    var deletedDigests: seq[array[32, byte]] = @[]
    var keptDigests: seq[array[32, byte]] = @[]
    for idx in toDelete:
      deletedDigests.add(inserted[idx])
    for idx in toKeep:
      keptDigests.add(inserted[idx])

    for d in deletedDigests:
      check cf.delete(d)

    # 300 kept digests still present — no false negatives.
    for d in keptDigests:
      check cf.query(d)

    # 200 deleted digests now absent. Cuckoo-filter delete is exact
    # against the single-insert-per-key contract that the test
    # honours, so the deleted set should query false even though the
    # filter is probabilistic — see Fan et al. §4.2.
    for d in deletedDigests:
      check (not cf.query(d))

    # Re-insert 50 of the deleted digests; they must query true again.
    let reinserted = deletedDigests[0 ..< 50]
    for d in reinserted:
      check cf.insert(d)
    for d in reinserted:
      check cf.query(d)
