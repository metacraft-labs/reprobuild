## Peer-Cache M1 verification test: three loopback peers; peer A's
## store is missing a blob `D` that peer C has; A issues
## `requestFetch(D)`; the BLAKE3-256-verified bytes come back from C;
## A's local store now has `D` via the injected writer; A's
## advertise snapshot carries `D` on the next round.
##
## See `Peer-Cache.milestones.org` §M1 — this is one of the four
## non-negotiable verification tests.

import std/[asyncdispatch, options, os, tables, unittest]

import blake3

import repro_peer_cache

const
  PollIntervalMs = 25
  MaxWaitMs = 5_000

proc digestFor(payload: openArray[byte]): BlobDigest =
  ## Raw BLAKE3-256 over the payload bytes — same identity model as
  ## `Peer-Cache.md` §"Identity model".
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
  ## Returns true when every peer's registry knows about the other
  ## two peers. The handshake completes asynchronously; the test
  ## polls with a 5 s ceiling.
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

proc peerKnowsAboutBlob(peer: LoopbackPeer; digest: BlobDigest): bool =
  let candidates = peer.registry.findPeersWithBlob(digest)
  candidates.len > 0

suite "peer-cache M1 fetch loopback round trip":
  test "peer A fetches a missing blob from peer C and advertises it":
    # Build per-peer in-memory stores: only C has the blob.
    let payload: seq[byte] = @[byte 0xDE, 0xAD, 0xBE, 0xEF,
                               0x01, 0x02, 0x03, 0x04,
                               0xCA, 0xFE, 0xBA, 0xBE]
    let digest = digestFor(payload)
    let storeA = newTable[BlobDigest, seq[byte]]()
    let storeB = newTable[BlobDigest, seq[byte]]()
    let storeC = newTable[BlobDigest, seq[byte]]()
    storeC[digest] = payload

    var options: seq[LoopbackPeerOptions] = @[
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeA),
        localStoreWriter: makeWriter(storeA)),
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeB),
        localStoreWriter: makeWriter(storeB)),
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeC),
        localStoreWriter: makeWriter(storeC))]

    let peers = spawnLoopbackPeers(3, options)
    # Seed C's self-advertised set so its initial advertise snapshot
    # to A carries the blob digest.
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

      check allRegistriesReady(peers)
      check peerKnowsAboutBlob(peers[0], digest)

      # Now A issues requestFetch — should return the verified bytes.
      let fetched = waitFor peers[0].client.requestFetch(digest)
      check fetched.isSome
      check fetched.get() == payload

      # A's local store now has the blob (writer fired).
      check storeA.hasKey(digest)
      check storeA[digest] == payload

      # A's self-advertised set carries the digest, so the next
      # snapshot to anyone includes it. We don't wait for the actual
      # advertise round (M1 has no periodic re-advertise yet); the
      # invariant is "the snapshot generator emits the new blob".
      let snapshotForB = peers[0].registry.snapshotFor(peers[1].peerId)
      var foundInSnapshot = false
      for d in snapshotForB.added:
        if d == digest:
          foundInSnapshot = true
          break
      check foundInSnapshot

      # Only one round trip happened (single fetch).
      check peers[0].client.fetchRoundTripCount == 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
