## Peer-Cache-BearSSL M3 verification: TLS handshake rejects an
## unknown client cert.
##
## Peers A and B share each other's certs; peer C presents its own
## cert, which is NOT in A's or B's anchor directory. The TLS
## handshake C <-> A fails at cert validation, the connection closes
## without any Hello flow, and A's `tlsHandshakeRejectedCount`
## increments.

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

const
  PollIntervalMs = 50
  MaxWaitMs = 3_000

suite "peer-cache TLS handshake rejects unknown cert (M3)":
  test "unknown peer C is rejected at TLS validation":
    # Two tenants. Peers 0 + 1 are tenant 0 (cross-installed). Peer 2
    # is tenant 1 — its cert is unknown to the others, and its anchor
    # dir doesn't contain theirs either.
    let opts = @[
      LoopbackTlsOptions(tenantId: 0),
      LoopbackTlsOptions(tenantId: 0),
      LoopbackTlsOptions(tenantId: 1)]
    let peers = waitFor spawnLoopbackTlsPeers(3, opts,
      fleetTag = "unknown_cert_" & $epochTime())
    try:
      waitFor dialAllLoopbackClients(peers)
      # Settle: wait until A + B see each other; C remains alone.
      var waited = 0
      while waited < MaxWaitMs:
        let abOk = peers[0].registry.peerCount() >= 1 and
                   peers[1].registry.peerCount() >= 1
        if abOk:
          break
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      # A sees B (and only B); B sees A; C sees nobody.
      check peers[0].registry.peerCount() == 1
      check peers[0].registry.hasPeer(peers[1].peerId)
      check peers[1].registry.peerCount() == 1
      check peers[1].registry.hasPeer(peers[0].peerId)
      check peers[2].registry.peerCount() == 0
      # Aggregate TLS handshake rejection count across the cluster
      # exceeds zero — every C <-> {A, B} pair fails. Counting in
      # detail is timing-sensitive (the dispatcher may interleave
      # accept/dial in different orders), so we just assert the sum.
      let totalRejections =
        peers[0].server.tlsHandshakeRejectedCount +
        peers[1].server.tlsHandshakeRejectedCount +
        peers[2].server.tlsHandshakeRejectedCount +
        peers[0].client.tlsHandshakeRejectedCount +
        peers[1].client.tlsHandshakeRejectedCount +
        peers[2].client.tlsHandshakeRejectedCount
      check totalRejections >= 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
