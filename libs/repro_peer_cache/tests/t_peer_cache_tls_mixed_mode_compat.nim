## Peer-Cache-BearSSL M4 verification: tmCidr / tmTls mixed-mode
## compatibility (or lack thereof).
##
## 3 `tmCidr` peers + 3 `tmTls` peers, every peer seeded with every
## other's endpoint. The `tmCidr` peers form a SWIM cluster among
## themselves; the `tmTls` peers form a separate one. Cross-mode
## connections fail at the handshake boundary:
##
##   * `tmCidr` client -> `tmTls` server: client speaks plain framed
##     protocol bytes; server's BearSSL engine treats them as a
##     malformed ClientHello and rejects.
##   * `tmTls` client -> `tmCidr` server: client speaks TLS; server
##     reads what it thinks are SSZ frames; the unrecognised bytes
##     fail to decode and the connection is dropped.
##
## We assert this by membership tables: each side sees only its own
## three peers; no cross-mode membership.

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

{.used.}

const
  CidrCount = 3
  TlsCount = 3
  Total = CidrCount + TlsCount
  LoopbackCidrLocal = "127.0.0.0/8"
  PollIntervalMs = 100
  MaxWaitMs = 6_000

proc allSawTheirMode(cidrPeers: seq[LoopbackPeer];
                    tlsPeers: seq[LoopbackPeer]): bool =
  for p in cidrPeers:
    if p.registry.peerCount() < CidrCount - 1: return false
  for p in tlsPeers:
    if p.registry.peerCount() < TlsCount - 1: return false
  true

suite "peer-cache TLS / CIDR mixed-mode compat (M4)":
  test "tmCidr and tmTls peers form disjoint SWIM clusters":
    # Stand up the tmTls fleet via the existing loopback helper —
    # it'll generate per-peer certs and cross-install anchors.
    let tlsTag = "mixed_mode_" & $epochTime()
    var tlsPeers = waitFor spawnLoopbackTlsPeers(TlsCount,
      fleetTag = tlsTag)
    # Stand up the tmCidr fleet on its own ephemeral ports.
    var cidrPeers = spawnLoopbackPeers(CidrCount)
    try:
      # Re-wire each peer's client with seeds that include peers from
      # the *other* fleet. The tmTls helper hands out clients seeded
      # only with same-tenant peers; we want cross-mode dials so the
      # rejection path is actually exercised.
      let allowlist = @[parseCidrV4(LoopbackCidrLocal)]
      var crossSeeds: seq[Endpoint] = @[]
      for p in cidrPeers:
        crossSeeds.add(initEndpoint("127.0.0.1", p.server.actualPort))
      for p in tlsPeers:
        crossSeeds.add(initEndpoint("127.0.0.1", p.server.actualPort))

      # tmCidr clients seed everything (including TLS endpoints).
      for i in 0 ..< CidrCount:
        var seeds: seq[Endpoint] = @[]
        for s in crossSeeds:
          if uint16(s.port) != uint16(cidrPeers[i].server.actualPort):
            seeds.add(s)
        # Replace the existing client with one that has the broader seeds.
        cidrPeers[i].client = newPeerCacheClient(
          selfPeerId = cidrPeers[i].peerId,
          listenPort = uint16(cidrPeers[i].server.actualPort),
          registry = cidrPeers[i].registry,
          seedPeers = seeds,
          cidrAllowlist = allowlist)

      # Start the tmCidr clients; the tmTls clients are already wired by
      # spawnLoopbackTlsPeers but not yet dialed.
      waitFor dialAllLoopbackClients(tlsPeers)
      waitFor dialAllLoopbackClients(cidrPeers)

      var waited = 0
      while waited < MaxWaitMs:
        if allSawTheirMode(cidrPeers, tlsPeers):
          break
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # Within-mode membership: each side sees its own.
      for i in 0 ..< CidrCount:
        check cidrPeers[i].registry.peerCount() == CidrCount - 1
        for j in 0 ..< CidrCount:
          if i == j: continue
          check cidrPeers[i].registry.hasPeer(cidrPeers[j].peerId)
      for i in 0 ..< TlsCount:
        check tlsPeers[i].registry.peerCount() == TlsCount - 1
        for j in 0 ..< TlsCount:
          if i == j: continue
          check tlsPeers[i].registry.hasPeer(tlsPeers[j].peerId)

      # Cross-mode membership: zero. Each fleet sees none of the other.
      for i in 0 ..< CidrCount:
        for j in 0 ..< TlsCount:
          check (not cidrPeers[i].registry.hasPeer(tlsPeers[j].peerId))
      for i in 0 ..< TlsCount:
        for j in 0 ..< CidrCount:
          check (not tlsPeers[i].registry.hasPeer(cidrPeers[j].peerId))
    finally:
      waitFor shutdownLoopbackPeers(tlsPeers)
      waitFor shutdownLoopbackPeers(cidrPeers)
