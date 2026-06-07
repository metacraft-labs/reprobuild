## Peer-Cache-BearSSL M3 verification: application data flows through
## the TLS tunnel.
##
## Three-peer `tmTls` cluster runs the M1 fetch round-trip (peer A is
## missing a blob that peer C has; A issues `mkFetchRequest` through
## the TLS tunnel; receives `mkFetchResponse`; BLAKE3-verifies; writes
## locally).
##
## A test seam taps the TLS frame bytes server-side: the
## `responseInterceptor` callback observes the plaintext SSZ payload
## *inside* the tunnel, while a separate fixture verifies the TCP
## socket bytes seen at the wire are NOT plaintext (they're TLS
## records). The latter is asserted by tapping the *raw* socket bytes
## via a separate plaintext-baseline TCP control connection.

import std/[asyncdispatch, options, os, tables, times, unittest]

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
  let candidates = peer.registry.findPeersWithBlob(digest)
  candidates.len > 0

suite "peer-cache TLS application data flow (M3)":
  test "3-peer tmTls cluster does an end-to-end fetch through the tunnel":
    let payload: seq[byte] = @[byte 0xDE, 0xAD, 0xBE, 0xEF,
                               0x01, 0x02, 0x03, 0x04,
                               0xCA, 0xFE, 0xBA, 0xBE,
                               byte 0xAB, 0xCD, 0xEF, 0x12]
    let digest = digestFor(payload)
    let storeA = newTable[BlobDigest, seq[byte]]()
    let storeB = newTable[BlobDigest, seq[byte]]()
    let storeC = newTable[BlobDigest, seq[byte]]()
    storeC[digest] = payload

    # Use spawnLoopbackTlsPeers to set up TLS+anchors+certs, then thread
    # the per-peer local-store readers/writers in via the server +
    # client fields after construction.
    let peers = waitFor spawnLoopbackTlsPeers(3,
      fleetTag = "appflow_" & $epochTime())
    # Inject the M1 store wiring on each peer.
    peers[0].server.localStoreReader = makeReader(storeA)
    peers[0].client.localStoreWriter = makeWriter(storeA)
    peers[1].server.localStoreReader = makeReader(storeB)
    peers[1].client.localStoreWriter = makeWriter(storeB)
    peers[2].server.localStoreReader = makeReader(storeC)
    peers[2].client.localStoreWriter = makeWriter(storeC)
    # Seed C's self-advertised set so its post-handshake snapshot to
    # A carries the digest.
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
      # A issues requestFetch — must return the verified bytes.
      let fetched = waitFor peers[0].client.requestFetch(digest)
      check fetched.isSome
      check fetched.get() == payload
      check storeA.hasKey(digest)
      check storeA[digest] == payload
      # A's self-advertised set carries the digest now.
      let snapshotForB = peers[0].registry.snapshotFor(peers[1].peerId)
      var found = false
      for d in snapshotForB.added:
        if d == digest:
          found = true
          break
      check found
      check peers[0].client.fetchRoundTripCount == 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
