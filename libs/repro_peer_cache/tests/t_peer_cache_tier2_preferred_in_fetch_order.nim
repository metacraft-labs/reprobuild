## Peer-Cache-Scale M2 verification test: tier-2 candidates sort
## before tier-1 candidates in `requestFetch`'s candidate list.
##
## A 5-peer rack-local cluster plus 1 tier-2 node. Both peer B and
## the tier-2 node advertise digest D. The sorted candidate list
## returned by `sortTier2First(findPeersWithBlob(D))` has the tier-2
## node first; the relative order among non-tier-2 peers is
## preserved from `findPeersWithBlob`.
##
## See `Peer-Cache-Scale.milestones.org` §M2 verification list.

import std/[algorithm, random, sequtils, tables, unittest]

import repro_peer_cache

proc peerIdN(tag: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(tag) + 7 * i + 11) and 0xff)
  peerIdFromBytes(raw)

proc randomDigest(rng: var Rand): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte(rng.rand(255))
  blobDigestFromBytes(raw)

suite "peer-cache-scale M2 tier-2 sorts ahead of tier-1 candidates":
  test "tier-2 candidate is first in the sorted findPeersWithBlob list":
    var rng = initRand(0xABCD_1234'i64)
    let selfPeerId = peerIdN(0x01)
    let registry = newPeerRegistry(selfPeerId,
                                   initEndpoint("127.0.0.1", Port(1)))

    # 5-peer cluster: peers A..E (ordinary). Plus one tier-2 node T.
    let peerA = peerIdN(0x10)
    let peerB = peerIdN(0x20)
    let peerC = peerIdN(0x30)
    let peerD = peerIdN(0x40)
    let peerE = peerIdN(0x50)
    let peerT = peerIdN(0x80)

    for p in [peerA, peerB, peerC, peerD, peerE]:
      registry.addPeer(p, initEndpoint("127.0.0.1", Port(40000)))
    registry.addPeer(peerT, initEndpoint("127.0.0.1", Port(50000)))
    # Mark T as tier-2.
    registry.setPeerTier2(peerT, true)

    check registry.isPeerTier2(peerT)
    check not registry.isPeerTier2(peerA)
    check not registry.isPeerTier2(peerB)

    let blobD = randomDigest(rng)

    # B and T advertise D; the other peers stay empty.
    for p in [peerA, peerC, peerD, peerE]:
      registry.applyAdvertise(p, Advertise(
        sequence: 1'u64, mode: amSnapshot,
        added: @[], removed: @[]))
    registry.applyAdvertise(peerB, Advertise(
      sequence: 1'u64, mode: amSnapshot,
      added: @[blobD], removed: @[]))
    registry.applyAdvertise(peerT, Advertise(
      sequence: 1'u64, mode: amSnapshot,
      added: @[blobD], removed: @[]))

    let raw = registry.findPeersWithBlob(blobD)
    # Both B and T should show up in the raw list (filter has no
    # false negatives). Any other peer that appears is a false
    # positive — accept that but require B and T to be present.
    check peerB in raw
    check peerT in raw

    let sorted = sortTier2First(registry, raw)
    check sorted.len == raw.len
    # Tier-2 (T) must be first.
    check sorted[0] == peerT
    # Within tier-1 candidates the order from the raw list is preserved.
    var rawTier1: seq[PeerId] = @[]
    for p in raw:
      if not registry.isPeerTier2(p):
        rawTier1.add(p)
    var sortedTier1: seq[PeerId] = @[]
    for p in sorted:
      if not registry.isPeerTier2(p):
        sortedTier1.add(p)
    check sortedTier1 == rawTier1
