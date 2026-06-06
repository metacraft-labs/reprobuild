## Peer-Cache-Scale M3 verification: mixed-mode compatibility.
##
## 3 `tmCidr` peers + 3 `tmMtls` peers share the same loopback. All
## peers seed all the others. The expected outcome:
##
##   - The 3 `tmCidr` peers form a SWIM-equivalent membership island
##     among themselves (they handshake normally without the auth
##     handshake).
##   - The 3 `tmMtls` peers form a separate island (they require the
##     auth handshake; same-mode peers complete it).
##   - No cross-mode membership: a `tmMtls` peer refuses to accept a
##     `tmCidr` peer's connection because the latter doesn't send
##     `mkAuthChallenge` (so the handshake read times out / decodes
##     the wrong message kind / etc.). And vice-versa: a `tmCidr`
##     peer treats the `tmMtls` peer's `mkAuthChallenge` as a
##     protocol violation (unknown frame before Hello) and closes the
##     connection.

import std/[asyncdispatch, nativesockets, os, unittest]

import repro_peer_cache

const
  NumCidr = 3
  NumMtls = 3
  PollIntervalMs = 100
  MaxWaitMs = 4_000

proc spawnMixedPeers(): tuple[
    cidrPeers, mtlsPeers: seq[LoopbackPeer]] =
  ## Builds a cluster with the all-to-all (cross-mode) seed topology.
  let allowlist = @[parseCidrV4(LoopbackCidr)]
  # Shared anchor for the 3 tmMtls peers.
  let kps = block:
    var v: seq[PeerKeypair] = @[]
    for _ in 0 ..< NumMtls:
      v.add(generateKeypair())
    v
  let tmpDir = getTempDir() / "t_peer_cache_mixed_mode"
  createDir(tmpDir)
  let anchorPath = tmpDir / "shared.anchor"
  writeTrustAnchors(anchorPath, kps)
  let anchors = loadTrustAnchors(anchorPath)

  # Phase 1: spawn all servers. tmCidr peers use indices 0..NumCidr-1
  # of `makePeerId`; tmMtls peers use NumCidr..NumCidr+NumMtls-1.
  var cidrPeers = newSeq[LoopbackPeer](NumCidr)
  var mtlsPeers = newSeq[LoopbackPeer](NumMtls)
  for i in 0 ..< NumCidr:
    let peerId = makePeerId(i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist,
      trustMode = tmCidr)
    server.start()
    cidrPeers[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)
  for i in 0 ..< NumMtls:
    let peerId = makePeerId(NumCidr + i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist,
      trustMode = tmMtls,
      keypair = kps[i],
      trustAnchors = anchors)
    server.start()
    mtlsPeers[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)

  # Phase 2: spawn clients. Each peer seeds with ALL the other peers
  # (cross-mode included) so the mixed-mode failure path is exercised.
  proc allOtherEndpoints(self: PeerCacheServer): seq[Endpoint] =
    result = @[]
    for p in cidrPeers:
      if p.server == self: continue
      result.add(initEndpoint("127.0.0.1", p.server.actualPort))
    for p in mtlsPeers:
      if p.server == self: continue
      result.add(initEndpoint("127.0.0.1", p.server.actualPort))

  for i in 0 ..< NumCidr:
    let client = newPeerCacheClient(
      selfPeerId = cidrPeers[i].peerId,
      listenPort = uint16(cidrPeers[i].server.actualPort),
      registry = cidrPeers[i].registry,
      seedPeers = allOtherEndpoints(cidrPeers[i].server),
      cidrAllowlist = allowlist,
      trustMode = tmCidr,
      fetchTimeoutMs = 1_000)
    cidrPeers[i].client = client

  for i in 0 ..< NumMtls:
    let client = newPeerCacheClient(
      selfPeerId = mtlsPeers[i].peerId,
      listenPort = uint16(mtlsPeers[i].server.actualPort),
      registry = mtlsPeers[i].registry,
      seedPeers = allOtherEndpoints(mtlsPeers[i].server),
      cidrAllowlist = allowlist,
      trustMode = tmMtls,
      keypair = kps[i],
      trustAnchors = anchors,
      fetchTimeoutMs = 1_000)
    mtlsPeers[i].client = client

  result.cidrPeers = cidrPeers
  result.mtlsPeers = mtlsPeers

suite "peer-cache mixed-mode compat":
  test "tmCidr + tmMtls peers form disjoint membership islands":
    let (cidrPeers, mtlsPeers) = spawnMixedPeers()
    let allPeers = cidrPeers & mtlsPeers
    try:
      waitFor dialAllLoopbackClients(allPeers)

      # Poll until both islands have settled their internal
      # memberships, OR the budget expires.
      var waited = 0
      proc bothIslandsConverged(): bool =
        for p in cidrPeers:
          if p.registry.peerCount() < NumCidr - 1: return false
        for p in mtlsPeers:
          if p.registry.peerCount() < NumMtls - 1: return false
        true
      while waited < MaxWaitMs and not bothIslandsConverged():
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # Each tmCidr peer should see the other 2 tmCidr peers — but
      # NONE of the tmMtls peers (the tmMtls server sends an
      # mkAuthChallenge first; the tmCidr client treats it as the
      # mkHelloOk reply and the codec rejects it with an "expected
      # mkHelloOk" error, closing the connection).
      for i in 0 ..< NumCidr:
        check cidrPeers[i].registry.peerCount() == NumCidr - 1
        for j in 0 ..< NumCidr:
          if i == j: continue
          check cidrPeers[i].registry.hasPeer(cidrPeers[j].peerId)
        for j in 0 ..< NumMtls:
          check (not cidrPeers[i].registry.hasPeer(mtlsPeers[j].peerId))

      # Each tmMtls peer should see the other 2 tmMtls peers — but
      # NONE of the tmCidr peers (the tmCidr peer doesn't send an
      # mkAuthChallenge, so the tmMtls accept loop's handshake read
      # either decodes Hello as auth-challenge or sees EOF; either
      # way it closes the connection.).
      for i in 0 ..< NumMtls:
        check mtlsPeers[i].registry.peerCount() == NumMtls - 1
        for j in 0 ..< NumMtls:
          if i == j: continue
          check mtlsPeers[i].registry.hasPeer(mtlsPeers[j].peerId)
        for j in 0 ..< NumCidr:
          check (not mtlsPeers[i].registry.hasPeer(cidrPeers[j].peerId))
    finally:
      waitFor shutdownLoopbackPeers(allPeers)
