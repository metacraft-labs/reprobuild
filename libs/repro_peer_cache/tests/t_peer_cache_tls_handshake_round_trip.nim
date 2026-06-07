## Peer-Cache-BearSSL M3 verification: TLS handshake round trip.
##
## Two loopback peers, each with its own self-signed cert + the other's
## cert in its anchor directory. TCP dial -> BearSSL TLS 1.2 mutual-auth
## handshake -> `mkHello` -> `mkHelloOk` -> initial advertise snapshot.
## Both peers' registries contain each other once the dispatcher has had
## a chance to pump.

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

const
  PollIntervalMs = 50
  MaxWaitMs = 3_000

proc waitForBothPeers(peers: seq[LoopbackPeer]; budgetMs: int): bool =
  var waited = 0
  while waited < budgetMs:
    var allOk = true
    for peer in peers:
      if peer.registry.peerCount() < peers.len - 1:
        allOk = false
        break
    if allOk:
      return true
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

suite "peer-cache TLS handshake round trip (M3)":
  test "two peers complete TLS handshake and Hello flow":
    let peers = waitFor spawnLoopbackTlsPeers(2,
      fleetTag = "round_trip_" & $epochTime())
    try:
      waitFor dialAllLoopbackClients(peers)
      check waitForBothPeers(peers, MaxWaitMs)
      # Both peers see each other.
      check peers[0].registry.peerCount() == 1
      check peers[1].registry.peerCount() == 1
      check peers[0].registry.hasPeer(peers[1].peerId)
      check peers[1].registry.hasPeer(peers[0].peerId)
      # No TLS handshake rejections on either side — both certs were in
      # the anchor directory.
      check peers[0].server.tlsHandshakeRejectedCount == 0
      check peers[1].server.tlsHandshakeRejectedCount == 0
      check peers[0].client.tlsHandshakeRejectedCount == 0
      check peers[1].client.tlsHandshakeRejectedCount == 0
    finally:
      waitFor shutdownLoopbackPeers(peers)
