## Peer-Cache M1 verification test: the engine's action-cache reader
## is configured with a `peerCacheClient`; on local miss, the reader
## consults the peer cache; on peer hit, it writes the blob locally;
## the next read for the same digest hits the local cache without a
## second peer round trip. Asserted via counters on the
## `PeerCacheClient` and the `PeerCacheActionCacheReader`.
##
## See `Peer-Cache.milestones.org` §M1.

import std/[asyncdispatch, options, os, tables, unittest]

import blake3

import repro_peer_cache

const
  PollIntervalMs = 25
  MaxWaitMs = 5_000

proc digestFor(payload: openArray[byte]): BlobDigest =
  blobDigestFromBytes(blake3.digest(payload))

proc makeReader(store: TableRef[BlobDigest, seq[byte]]): LocalStoreReader =
  result = proc(digest: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    if store[].hasKey(digest):
      some(store[][digest])
    else:
      none(seq[byte])

proc makeWriter(store: TableRef[BlobDigest, seq[byte]]): LocalStoreWriter =
  result = proc(digest: BlobDigest; payload: seq[byte]) {.gcsafe.} =
    if not store[].hasKey(digest):
      store[][digest] = payload

proc allRegistriesReady(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

proc peerKnowsAboutBlob(peer: LoopbackPeer; digest: BlobDigest): bool =
  peer.registry.findPeersWithBlob(digest).len > 0

suite "peer-cache M1 action-cache reader consults peer on miss":
  test "two reads: first fetches from peer C, second hits local cache":
    let payload: seq[byte] = @[byte 0xA0, 0xA1, 0xA2, 0xA3,
                               0xB0, 0xB1, 0xB2, 0xB3]
    let digest = digestFor(payload)
    let storeA = newTable[BlobDigest, seq[byte]]()
    let storeB = newTable[BlobDigest, seq[byte]]()
    let storeC = newTable[BlobDigest, seq[byte]]()
    storeC[digest] = payload

    var opts: seq[LoopbackPeerOptions] = @[
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeA),
        localStoreWriter: makeWriter(storeA)),
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeB),
        localStoreWriter: makeWriter(storeB)),
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeC),
        localStoreWriter: makeWriter(storeC))]

    let peers = spawnLoopbackPeers(3, opts)
    peers[2].registry.selfAddBlob(digest)
    try:
      waitFor dialAllLoopbackClients(peers)
      var waited = 0
      while waited < MaxWaitMs and
            (not allRegistriesReady(peers) or
             not peerKnowsAboutBlob(peers[0], digest)):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      check peerKnowsAboutBlob(peers[0], digest)

      # Build A's action-cache reader wired to A's local store and
      # A's peer-cache client. (The reader and client share the same
      # writer closure so a peer-hit warms the local store before
      # the reader returns.)
      let reader = newPeerCacheActionCacheReader(
        localRead = makeReader(storeA),
        localWrite = makeWriter(storeA),
        peerCacheClient = peers[0].client)

      # First read — local miss, peer hit.
      let first = reader.readActionOutput(digest)
      check first.isSome
      check first.get() == payload
      check reader.peerHits == 1
      check reader.localHits == 0
      check peers[0].client.fetchRoundTripCount == 1

      # Second read — should be served by the local store. No second
      # peer round trip.
      let second = reader.readActionOutput(digest)
      check second.isSome
      check second.get() == payload
      check reader.peerHits == 1
      check reader.localHits == 1
      check peers[0].client.fetchRoundTripCount == 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
