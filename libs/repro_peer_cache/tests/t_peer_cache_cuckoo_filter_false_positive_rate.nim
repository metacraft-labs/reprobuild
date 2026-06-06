## Peer-Cache-Scale M1 verification test:
## a cuckoo filter sized for 1 000 blobs at 1% target FPR delivers a
## measured FPR ≤ 3% over 10 000 non-inserted queries. The looser
## bound accounts for finite-set variance (sqrt(10 000) ≈ 100 → ~1%
## standard deviation around the measured rate) and the rounding-up
## of `fingerprintBits` in the constructor.

import std/[random, unittest]

import repro_peer_cache

proc randomDigest(rng: var Rand): array[32, byte] =
  for i in 0 ..< 32:
    result[i] = byte(rng.rand(255))

suite "peer-cache cuckoo filter false-positive rate":
  test "1000 inserts + 10000 negative queries yields FPR <= 3%":
    var rng = initRand(0xfa15ec0de'i64)
    let cf = newCuckooFilter(capacity = 1000'u32,
                             falsePositiveRate = 0.01,
                             seed = 0x515eed'i64)
    var inserted: seq[array[32, byte]] = @[]
    var insertFailed = false
    while inserted.len < 1000 and not insertFailed:
      let d = randomDigest(rng)
      if cf.insert(d):
        inserted.add(d)
      else:
        # On the unlikely insertion failure (paper's maxKicks budget),
        # the 1% FPR target at 95% load should not normally trigger
        # this; fail loudly so the test surface flags a real
        # regression.
        insertFailed = true
    check (not insertFailed)
    check cf.count == 1000'u32

    # Sanity: every inserted digest queries true (no false negatives).
    for d in inserted:
      check cf.query(d)

    var rngQ = initRand(0xc0ffee'i64)
    var falsePositives = 0
    const Trials = 10_000
    var tested = 0
    while tested < Trials:
      let d = randomDigest(rngQ)
      # Skip the (vanishingly unlikely) collision with an inserted
      # digest so we don't accidentally count a true positive as a
      # false positive.
      var clash = false
      for ins in inserted:
        if ins == d:
          clash = true
          break
      if clash:
        continue
      if cf.query(d):
        inc falsePositives
      inc tested

    let fpr = falsePositives.float / Trials.float
    echo "  measured FPR = ", fpr, " (", falsePositives, " of ", Trials, ")"
    check fpr <= 0.03
