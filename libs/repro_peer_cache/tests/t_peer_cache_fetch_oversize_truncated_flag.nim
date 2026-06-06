## Peer-Cache M1 verification test: peer C's local store has a blob
## that exceeds `maxBlobBytes`. On `mkFetchRequest`, C replies with
## `truncated: true, payload: @[]`; A treats the response as a miss
## and (with no other candidates) the `requestFetch` returns `none`.
##
## Pragmatism note: the spec default for `maxBlobBytes` is 100 MB, so
## a truly oversize blob would be expensive to allocate in a test.
## We instead configure C's server with a tiny cap (`1024` bytes)
## and seed its store with a `2048`-byte payload — same code path,
## negligible memory footprint. See `Peer-Cache.milestones.org`
## §M1.

import std/[asyncdispatch, options, os, tables, unittest]

import blake3

import repro_peer_cache

const
  PollIntervalMs = 25
  MaxWaitMs = 5_000
  TinyMaxBlobBytes = 1024'u64
  OversizePayloadLen = 2048

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

suite "peer-cache M1 fetch oversize truncated flag":
  test "A receives truncated:true from C and reports a miss":
    var payload = newSeq[byte](OversizePayloadLen)
    for i in 0 ..< payload.len:
      payload[i] = byte(i and 0xff)
    let digest = digestFor(payload)
    let storeA = newTable[BlobDigest, seq[byte]]()
    let storeC = newTable[BlobDigest, seq[byte]]()
    storeC[digest] = payload

    var opts: seq[LoopbackPeerOptions] = @[
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeA),
        localStoreWriter: makeWriter(storeA)),
      LoopbackPeerOptions(
        localStoreReader: makeReader(storeC),
        localStoreWriter: makeWriter(storeC),
        maxBlobBytes: TinyMaxBlobBytes)]

    let peers = spawnLoopbackPeers(2, opts)
    peers[1].registry.selfAddBlob(digest)
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

      let fetched = waitFor peers[0].client.requestFetch(digest)
      check fetched.isNone

      # A's local store remains empty (truncated reply ≠ writable).
      check not storeA.hasKey(digest)

      # One round trip happened (C was the only candidate).
      check peers[0].client.fetchRoundTripCount == 1

      # C is *not* marked suspect — a truncated reply is a legitimate
      # protocol response, not a protocol violation. (The corrupted-
      # payload test is the suspect path.)
      check not peers[0].registry.needsSnapshot(peers[1].peerId)
    finally:
      waitFor shutdownLoopbackPeers(peers)
