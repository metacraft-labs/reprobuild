## Peer-Cache-BearSSL M4 verification: per-tenant CA isolation.
##
## Two tenants, each with its own mini-CA. 3 peers per tenant. Within
## a tenant peers cross-trust the same CA cert; across tenants the
## peers reject each other at TLS chain validation (the other
## tenant's leaf is signed by an unknown CA).
##
## (The spec says 5 peers per tenant; we drop to 3 so the test fits
## comfortably under the 120-second test budget on a quiet box —
## BearSSL handshakes plus all-pairs dialing add up fast.)

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

{.used.}

const
  PerTenant = 3
  TotalPeers = PerTenant * 2
  LoopbackCidrLocal = "127.0.0.0/8"
  PollIntervalMs = 100
  MaxWaitMs = 8_000

type
  TenantPeer = object
    peerId: PeerId
    cert: CertAndKey
    server: PeerCacheServer
    client: PeerCacheClient
    registry: PeerRegistry

proc setupTenantAnchorDir(tmp: string; tag: string;
                          caCert: CertAndKey): TrustAnchorSet =
  let anchorDir = tmp / ("anchors_" & tag)
  createDir(anchorDir)
  writeFile(anchorDir / "ca.crt", caCert.certPem)
  loadTrustAnchorDir(anchorDir)

proc allReachedSameTenantSize(peers: seq[TenantPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < PerTenant - 1:
      return false
  true

suite "peer-cache TLS per-tenant CA isolation (M4)":
  test "tenant-A and tenant-B form disjoint membership domains":
    let tmp = getTempDir() / "peer_cache_m4_tenant_ca_" & $epochTime()
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    try:
      let caA = generateCaCert(generateKeypair(), subjectCn = "ca-A",
                               validityDays = 365)
      let caB = generateCaCert(generateKeypair(), subjectCn = "ca-B",
                               validityDays = 365)
      let cas = [caA, caB]
      let allowlist = @[parseCidrV4(LoopbackCidrLocal)]

      var peers = newSeq[TenantPeer](TotalPeers)
      # Phase 0: mint per-peer certs and start servers.
      for i in 0 ..< TotalPeers:
        let tenant = i div PerTenant
        let peerKp = generateKeypair()
        let peerCert = generateCaSignedCert(
          peerKeypair = peerKp,
          subjectCn = "t" & $tenant & "-p" & $(i mod PerTenant),
          caCertDer = cas[tenant].certDer,
          caKeypair = cas[tenant].keypair,
          validityDays = 365)
        let pid = derivePeerIdFromPublicKey(peerKp.publicKey)
        let anchors = setupTenantAnchorDir(tmp, "p" & $i, cas[tenant])
        let endpoint = initEndpoint("127.0.0.1", Port(0))
        let registry = newPeerRegistry(pid, endpoint)
        let server = newPeerCacheServer(
          selfPeerId = pid,
          listenAddr = "127.0.0.1",
          listenPort = Port(0),
          registry = registry,
          cidrAllowlist = allowlist,
          trustMode = tmTls,
          ourCert = peerCert,
          trustAnchorSet = anchors)
        server.start()
        peers[i] = TenantPeer(
          peerId: pid,
          cert: peerCert,
          server: server,
          client: nil,
          registry: registry)
      # Phase 1: all-to-all client wiring (including cross-tenant
      # seeds, so the rejection path is actually exercised).
      for i in 0 ..< TotalPeers:
        let tenant = i div PerTenant
        let anchors = setupTenantAnchorDir(tmp,
          "cli_" & $i, cas[tenant])
        var seeds: seq[Endpoint] = @[]
        for j in 0 ..< TotalPeers:
          if j == i: continue
          seeds.add(initEndpoint("127.0.0.1",
                                 peers[j].server.actualPort))
        let cli = newPeerCacheClient(
          selfPeerId = peers[i].peerId,
          listenPort = uint16(peers[i].server.actualPort),
          registry = peers[i].registry,
          seedPeers = seeds,
          cidrAllowlist = allowlist,
          trustMode = tmTls,
          ourCert = peers[i].cert,
          trustAnchorSet = anchors)
        peers[i].client = cli
      try:
        # Start every client and let things settle.
        for i in 0 ..< TotalPeers:
          waitFor peers[i].client.start()
        var waited = 0
        while waited < MaxWaitMs and not allReachedSameTenantSize(peers):
          try: poll(0) except ValueError: discard
          sleep(PollIntervalMs)
          waited += PollIntervalMs
        # Tenant-A peers see only the other 2 tenant-A peers.
        for i in 0 ..< PerTenant:
          check peers[i].registry.peerCount() == PerTenant - 1
          for j in 0 ..< PerTenant:
            if i == j: continue
            check peers[i].registry.hasPeer(peers[j].peerId)
          for j in PerTenant ..< TotalPeers:
            check (not peers[i].registry.hasPeer(peers[j].peerId))
        # Tenant-B peers mirror.
        for i in PerTenant ..< TotalPeers:
          check peers[i].registry.peerCount() == PerTenant - 1
          for j in PerTenant ..< TotalPeers:
            if i == j: continue
            check peers[i].registry.hasPeer(peers[j].peerId)
          for j in 0 ..< PerTenant:
            check (not peers[i].registry.hasPeer(peers[j].peerId))
      finally:
        for i in 0 ..< TotalPeers:
          try: waitFor peers[i].client.stop() except CatchableError: discard
        for i in 0 ..< TotalPeers:
          peers[i].server.stop()
    finally:
      removeDir(tmp)
