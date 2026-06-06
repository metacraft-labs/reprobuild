## Peer-Cache M2 verification test: three peers configured for UDP
## multicast discovery on the admin-scope group ``239.255.42.42:17654``
## bound to ``127.0.0.1``. No seed list. After the announce interval
## settles, every peer's registry contains the other two — same shape
## as the M0 unicast loopback test.
##
## The admin-scope address (``239.255.x.x``) avoids the link-local
## kernel filtering that ``224.0.0.x`` is subject to on some Linux
## hosts. The high port (``17654``) sidesteps any IANA-reserved or
## firewalld-filtered low ports. Both are documented in the M2
## "strategy notes" block in the milestone spec.
##
## Deterministic-budget polling: 100 ms granularity, 10 s ceiling
## (the multicast loop in `multicast.nim` runs at
## `advertiseIntervalMs = 200` for the loopback helper so 3-5 ticks
## should suffice; the ceiling is the milestone's "may need up to
## 10 seconds for discovery to settle" budget).

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

const
  PollIntervalMs = 100
  MaxWaitMs = 10_000
  MulticastAddress = "239.255.42.42"
  MulticastPort = 17654

proc allRegistriesPopulated(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < peers.len - 1:
      return false
  true

suite "peer-cache multicast loopback discovery":
  test "three loopback peers discover each other via multicast":
    let group = loopbackMulticastGroup(MulticastAddress,
                                       Port(MulticastPort))
    let peers = spawnLoopbackMulticastPeers(3, group)
    try:
      var waited = 0
      while waited < MaxWaitMs and not allRegistriesPopulated(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # Every registry contains exactly the other two peers (not
      # itself — the multicast receiver drops self-announcements
      # by peer ID; see `multicastReceiveLoop` in server.nim).
      for i, peer in peers:
        check peer.registry.peerCount() == peers.len - 1
        for j, other in peers:
          if i == j: continue
          check peer.registry.hasPeer(other.peerId)
          # Endpoint host is whatever the kernel reported as the
          # multicast packet's source IP. On loopback that is
          # ``127.0.0.1``; the TCP connection back was made
          # against that address + the announced listen port.
          let endpoint = peer.registry.endpointOf(other.peerId)
          check endpoint.host == "127.0.0.1"
          check endpoint.port.int == other.server.actualPort.int
    finally:
      waitFor shutdownLoopbackPeers(peers)
