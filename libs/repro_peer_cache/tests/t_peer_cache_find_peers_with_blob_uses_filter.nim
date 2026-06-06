## Peer-Cache-Scale M1 verification test:
## three peers A/B/C; B advertises `dB`, C advertises `dC`, A is
## empty. `findPeersWithBlob(dB)` returns B and not C;
## `findPeersWithBlob(dC)` returns C and not B; an unrelated
## `unknownDigest` returns the empty seq (within the cuckoo-filter
## false-positive budget — across 3 peers we allow at most 1 hit
## total).

import std/[random, tables, unittest]

import repro_peer_cache

proc peerIdN(value: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(value) + 3 * i + 5) and 0xff)
  peerIdFromBytes(raw)

proc randomDigest(rng: var Rand): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte(rng.rand(255))
  blobDigestFromBytes(raw)

suite "peer-cache findPeersWithBlob routes through cuckoo filter":
  test "A/B/C peer registry returns the right filter-matching peers":
    var rng = initRand(0xface_b00c'i64)
    let registry = newPeerRegistry(peerIdN(0xaa),
      initEndpoint("127.0.0.1", Port(1)))
    let peerA = peerIdN(0x10)
    let peerB = peerIdN(0x20)
    let peerC = peerIdN(0x30)
    registry.addPeer(peerA, initEndpoint("127.0.0.1", Port(40010)))
    registry.addPeer(peerB, initEndpoint("127.0.0.1", Port(40020)))
    registry.addPeer(peerC, initEndpoint("127.0.0.1", Port(40030)))

    let dB = randomDigest(rng)
    let dC = randomDigest(rng)
    let unknownDigest = randomDigest(rng)

    # A's filter stays empty: send an empty snapshot so the registry
    # allocates a filter without inserting anything.
    registry.applyAdvertise(peerA, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[],
      removed: @[]))
    registry.applyAdvertise(peerB, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[dB],
      removed: @[]))
    registry.applyAdvertise(peerC, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[dC],
      removed: @[]))

    let bResult = registry.findPeersWithBlob(dB)
    check peerB in bResult
    check peerC notin bResult

    let cResult = registry.findPeersWithBlob(dC)
    check peerC in cResult
    check peerB notin cResult

    let unknownResult = registry.findPeersWithBlob(unknownDigest)
    # FPR is bounded but non-zero — allow at most one false positive
    # across the 3 peers' filters.
    check unknownResult.len <= 1
