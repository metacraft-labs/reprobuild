## Peer-Cache M1 verification test: peer C is configured to corrupt
## one byte of every `mkFetchResponse` payload. Peer A requests a
## blob both B and C have; A's BLAKE3-256 verification rejects C's
## reply, marks C suspect, then falls through to B (next candidate
## in the sorted list) and receives the verified payload.
##
## Candidate ordering note: `registry.findPeersWithBlob` returns
## peer IDs sorted by raw bytes (Peer-Cache M1 makes this stable so
## tests don't ride on `std/tables` hash-bucket nondeterminism). We
## name the peers so the *corrupted* one sorts first: A = peer 0,
## C = peer 1 (corrupted), B = peer 2 (clean). `makePeerId` in
## `loopback.nim` packs the index into byte 1; peer 1 < peer 2.

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

proc flipFirstByte(payload: seq[byte]): seq[byte] =
  result = payload
  if result.len > 0:
    result[0] = result[0] xor 0xff'u8

proc allRegistriesReady(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

proc bothCandidatesKnown(peer: LoopbackPeer; digest: BlobDigest): bool =
  peer.registry.findPeersWithBlob(digest).len >= 2

suite "peer-cache M1 fetch corrupted payload rejected":
  test "A detects C's corruption, marks suspect, and falls through to B":
    let payload: seq[byte] = @[byte 0x11, 0x22, 0x33, 0x44, 0x55, 0x66]
    let digest = digestFor(payload)
    let storeA = newTable[BlobDigest, seq[byte]]()
    let storeC = newTable[BlobDigest, seq[byte]]()
    let storeB = newTable[BlobDigest, seq[byte]]()
    storeB[digest] = payload
    storeC[digest] = payload

    var opts: seq[LoopbackPeerOptions] = @[
      # A — index 0; no store seed, just the writer for the test.
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeA),
        localStoreWriter: makeWriter(storeA)),
      # C — index 1; corrupted. Sorts BEFORE B by peer ID, so the
      # candidate iterator tries C first.
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeC),
        localStoreWriter: makeWriter(storeC),
        responseInterceptor: flipFirstByte),
      # B — index 2; clean responder. Sorts AFTER C.
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeB),
        localStoreWriter: makeWriter(storeB))]

    let peers = spawnLoopbackPeers(3, opts)
    peers[1].registry.selfAddBlob(digest)  # C advertises
    peers[2].registry.selfAddBlob(digest)  # B advertises
    try:
      waitFor dialAllLoopbackClients(peers)
      var waited = 0
      while waited < MaxWaitMs and
            (not allRegistriesReady(peers) or
             not bothCandidatesKnown(peers[0], digest)):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      check bothCandidatesKnown(peers[0], digest)
      # Sanity: A's pre-fetch candidate list orders C before B.
      let preCandidates = peers[0].registry.findPeersWithBlob(digest)
      check preCandidates.len == 2
      check preCandidates[0] == peers[1].peerId  # C first

      # The fetch should fail against C (mismatch → markSuspect) and
      # then succeed against B.
      let fetched = waitFor peers[0].client.requestFetch(digest)
      check fetched.isSome
      check fetched.get() == payload

      # C is now marked suspect on A's registry.
      check peers[0].registry.needsSnapshot(peers[1].peerId)
      # B is *not* marked suspect (we used it).
      check not peers[0].registry.needsSnapshot(peers[2].peerId)

      # A's local store now has the blob (via B's clean payload).
      check storeA.hasKey(digest)
      check storeA[digest] == payload

      # Two round trips: one to C (rejected) + one to B (accepted).
      check peers[0].client.fetchRoundTripCount == 2
    finally:
      waitFor shutdownLoopbackPeers(peers)
