## Peer-Cache M0 verification test: three peer instances spun up on
## distinct loopback ports via `loopback.nim` helpers, each seeded
## with the other two's endpoints. After the handshake round
## completes, every peer's registry contains exactly the other two
## with the right endpoints.
##
## Deterministic-budget polling: 100 ms granularity, 5 s ceiling.

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

const
  PollIntervalMs = 100
  MaxWaitMs = 5_000

proc allRegistriesPopulated(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

suite "peer-cache loopback three-peer discovery":
  test "three loopback peers discover each other after handshake":
    let peers = spawnLoopbackPeers(3)
    try:
      # Dial all clients concurrently.
      waitFor dialAllLoopbackClients(peers)

      # Poll until every registry has populated the other two peers,
      # or until the 5 s ceiling expires.
      var waited = 0
      while waited < MaxWaitMs and not allRegistriesPopulated(peers):
        # Pump the async dispatcher a few times so any in-flight reads
        # of the server's initial advertise snapshot complete during
        # the poll interval.
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # Final assertion: every registry contains exactly the other
      # two peer IDs with the right endpoints.
      for i, peer in peers:
        let expectedCount = peers.len - 1
        check peer.registry.peerCount() == expectedCount
        for j, other in peers:
          if i == j: continue
          check peer.registry.hasPeer(other.peerId)
          let endpoint = peer.registry.endpointOf(other.peerId)
          check endpoint.host == "127.0.0.1"
          check endpoint.port.int == other.server.actualPort.int
    finally:
      waitFor shutdownLoopbackPeers(peers)
