## Peer-Cache-Scale M1 verification test:
## a v1 `Advertise` record (raw digest lists) routed through the
## registry's `applyAdvertise` proc materialises in the in-memory v2
## shape — `PeerEntry.advertised` is a `CuckooFilter` whose `query`
## returns true for every digest in the v1 `added` list.

import std/[tables, unittest]

import repro_peer_cache

proc digestN(value: byte): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(value) + i) and 0xff)
  blobDigestFromBytes(raw)

proc peerIdN(value: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(value) + 3 * i + 5) and 0xff)
  peerIdFromBytes(raw)

suite "peer-cache v1 Advertise decoded as v2 filter":
  test "applyAdvertise(amSnapshot) builds a CuckooFilter from added digests":
    let registry = newPeerRegistry(peerIdN(0xaa),
      initEndpoint("127.0.0.1", Port(1)))
    let peer = peerIdN(0xbb)
    registry.addPeer(peer, initEndpoint("127.0.0.1", Port(40000)))

    let d1 = digestN(0x01)
    let d2 = digestN(0x02)
    let d3 = digestN(0x03)

    registry.applyAdvertise(peer, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[d1, d2, d3],
      removed: @[]))

    let entry = registry.entries[peer]
    check not entry.advertised.isNil
    check entry.advertised.query(bytes(d1))
    check entry.advertised.query(bytes(d2))
    check entry.advertised.query(bytes(d3))

    # findPeersWithBlob now routes through the cuckoo-filter `query`.
    check registry.findPeersWithBlob(d1) == @[peer]
    check registry.findPeersWithBlob(d2) == @[peer]
    check registry.findPeersWithBlob(d3) == @[peer]
