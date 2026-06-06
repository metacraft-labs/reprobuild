## Peer-Cache-Scale M1 verification test:
## an `AdvertiseV2` record with `filterCapacity = 1000`,
## `mode = amSnapshot`, and a non-empty filter containing 100 random
## digests round-trips through `encodeAdvertiseV2` / `decodeAdvertiseV2`
## with byte-equal `filterBytes` and a working deserialised filter.

import std/[random, unittest]

import repro_peer_cache

proc randomDigest(rng: var Rand): array[32, byte] =
  for i in 0 ..< 32:
    result[i] = byte(rng.rand(255))

suite "peer-cache AdvertiseV2 codec round trip":
  test "AdvertiseV2 round-trips and the decoded filter answers queries":
    var rng = initRand(0x1234abcd'i64)
    let cf = newCuckooFilter(capacity = 1000'u32,
                             falsePositiveRate = 0.01,
                             seed = 0x5eed5eed'i64)
    var digests: seq[array[32, byte]] = @[]
    var insertFailed = false
    while digests.len < 100 and not insertFailed:
      let d = randomDigest(rng)
      if cf.insert(d):
        digests.add(d)
      else:
        insertFailed = true
    check (not insertFailed)
    check cf.count == 100'u32

    let ad = AdvertiseV2(
      sequence: 0xfeed_dead_beef_cafe'u64,
      mode: amSnapshot,
      filterCapacity: 1000'u32,
      filterCount: cf.count,
      filterBytes: cf.serialize())

    let encoded = encodeAdvertiseV2(ad)
    let decoded = decodeAdvertiseV2(encoded)

    check decoded.sequence == ad.sequence
    check decoded.mode == ad.mode
    check decoded.filterCapacity == ad.filterCapacity
    check decoded.filterCount == ad.filterCount
    check decoded.filterBytes == ad.filterBytes

    # Frame-level round trip too — the v2 frame is stamped with
    # protocol version 2 by `encodeFrame`.
    let framed = encodeFrame(mkAdvertiseV2, encoded)
    let frame = decodeFrame(framed)
    check frame.version == PeerCacheProtocolVersionV2
    check frame.messageKind == mkAdvertiseV2
    let decodedFromFrame = decodeAdvertiseV2(frame.payload)
    check decodedFromFrame.filterBytes == ad.filterBytes

    # The decoded filter answers every original digest as present.
    let restored = deserialize(decoded.filterBytes)
    check restored.numBuckets == cf.numBuckets
    check restored.bucketSize == cf.bucketSize
    check restored.fingerprintBits == cf.fingerprintBits
    check restored.count == cf.count
    for d in digests:
      check restored.query(d)
