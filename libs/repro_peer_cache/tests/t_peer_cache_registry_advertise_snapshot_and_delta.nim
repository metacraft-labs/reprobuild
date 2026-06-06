## Peer-Cache M0 verification test (updated for Peer-Cache-Scale M1):
## `PeerRegistry` correctly applies snapshot vs delta advertisements,
## and a sequence-number gap is surfaced via `needsSnapshot`.
##
## M1 note: `PeerEntry.advertised` is now a `CuckooFilter`, so the
## v1-style `len` / `in` checks have been replaced with `cuckoo.query`.
## Cuckoo filters are probabilistic — the assertions here only depend
## on the no-false-negatives guarantee (every inserted digest must
## query as present), not on counting the set.

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

proc has(cf: CuckooFilter; d: BlobDigest): bool =
  cf.query(bytes(d))

suite "peer-cache registry advertise":
  test "snapshot replaces the known set; delta applies; gap surfaces":
    let selfPeerId = peerIdN(0xaa)
    let selfEndpoint = initEndpoint("127.0.0.1", Port(1))
    let registry = newPeerRegistry(selfPeerId, selfEndpoint)

    let remotePeerId = peerIdN(0xbb)
    let remoteEndpoint = initEndpoint("127.0.0.1", Port(40000))
    registry.addPeer(remotePeerId, remoteEndpoint)

    let d1 = digestN(0x01)
    let d2 = digestN(0x02)
    let d3 = digestN(0x03)

    # Apply a snapshot: advertised becomes {d1, d2}.
    registry.applyAdvertise(remotePeerId, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[d1, d2],
      removed: @[]))
    block:
      let entry = registry.entries[remotePeerId]
      check not entry.advertised.isNil
      check entry.advertised.has(d1)
      check entry.advertised.has(d2)
      check not entry.advertised.has(d3)
      check entry.advertised.count == 2'u32
      check entry.lastAdvertiseSequence == 1'u64
      check entry.hasAdvertiseSequence
    check not registry.needsSnapshot(remotePeerId)

    # Apply a delta with sequence = prev + 1: advertised becomes {d2, d3}.
    registry.applyAdvertise(remotePeerId, Advertise(
      sequence: 2'u64,
      mode: amDelta,
      added: @[d3],
      removed: @[d1]))
    block:
      let entry = registry.entries[remotePeerId]
      check not entry.advertised.has(d1)
      check entry.advertised.has(d2)
      check entry.advertised.has(d3)
      check entry.lastAdvertiseSequence == 2'u64
    check not registry.needsSnapshot(remotePeerId)
    check registry.findPeersWithBlob(d2) == @[remotePeerId]
    check registry.findPeersWithBlob(d3) == @[remotePeerId]
    check registry.findPeersWithBlob(d1).len == 0

    # Skip a sequence number (gap): advertised set is preserved, but
    # `needsSnapshot` returns true.
    registry.applyAdvertise(remotePeerId, Advertise(
      sequence: 5'u64,  # gap — expected 3
      mode: amDelta,
      added: @[digestN(0x04)],
      removed: @[]))
    check registry.needsSnapshot(remotePeerId)
    block:
      let entry = registry.entries[remotePeerId]
      # Gap is rejected — the gap-causing delta is NOT applied.
      check not entry.advertised.has(digestN(0x04))
      check entry.lastAdvertiseSequence == 2'u64
      check entry.suspect

    # A fresh snapshot clears the suspect flag and replaces the set.
    registry.applyAdvertise(remotePeerId, Advertise(
      sequence: 6'u64,
      mode: amSnapshot,
      added: @[d1, d3, digestN(0x05)],
      removed: @[]))
    check not registry.needsSnapshot(remotePeerId)
    block:
      let entry = registry.entries[remotePeerId]
      check entry.advertised.has(d1)
      check not entry.advertised.has(d2)
      check entry.advertised.has(d3)
      check entry.advertised.has(digestN(0x05))
      check entry.lastAdvertiseSequence == 6'u64

  test "advertise from unknown peer is dropped":
    let registry = newPeerRegistry(peerIdN(0x00),
      initEndpoint("127.0.0.1", Port(1)))
    let stranger = peerIdN(0xff)
    registry.applyAdvertise(stranger, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[digestN(0x00)],
      removed: @[]))
    check not registry.hasPeer(stranger)
    check registry.peerCount() == 0

  test "markSuspect / clearSuspect toggles findPeersWithBlob visibility":
    let registry = newPeerRegistry(peerIdN(0x00),
      initEndpoint("127.0.0.1", Port(1)))
    let peer = peerIdN(0x10)
    registry.addPeer(peer, initEndpoint("127.0.0.1", Port(40001)))
    registry.applyAdvertise(peer, Advertise(
      sequence: 1'u64,
      mode: amSnapshot,
      added: @[digestN(0x10)],
      removed: @[]))
    check registry.findPeersWithBlob(digestN(0x10)) == @[peer]
    registry.markSuspect(peer)
    check registry.findPeersWithBlob(digestN(0x10)).len == 0
    registry.clearSuspect(peer)
    check registry.findPeersWithBlob(digestN(0x10)) == @[peer]
