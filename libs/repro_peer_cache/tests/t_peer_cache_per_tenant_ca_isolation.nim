## Peer-Cache-Scale M3 verification: per-tenant CA isolation.
##
## Two trust anchor files:
##   - `tenantA.anchor`: 5 pubkeys (peers 0..4).
##   - `tenantB.anchor`: 5 different pubkeys (peers 5..9).
##
## All 10 peers run on the loopback, all-to-all seeded. Each peer
## dials the other 9. The auth handshake succeeds for same-tenant
## peers (4 each) and fails for cross-tenant peers (5 each).
##
## After settling, each peer's registry contains exactly its 4
## same-tenant siblings.

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

const
  PerTenant = 5
  TotalPeers = PerTenant * 2
  PollIntervalMs = 100
  MaxWaitMs = 6_000

proc allReachedSameTenantSize(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < PerTenant - 1:
      return false
  true

suite "peer-cache per-tenant CA isolation":
  test "tenant-A and tenant-B peers form disjoint membership domains":
    let tmpDir = getTempDir() / "t_peer_cache_per_tenant_ca"
    createDir(tmpDir)
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    var tenantAKeys: seq[PeerKeypair] = @[]
    var tenantBKeys: seq[PeerKeypair] = @[]
    for i in 0 ..< PerTenant:
      tenantAKeys.add(generateKeypair())
      tenantBKeys.add(generateKeypair())

    let anchorPathA = tmpDir / "tenantA.anchor"
    let anchorPathB = tmpDir / "tenantB.anchor"
    writeTrustAnchors(anchorPathA, tenantAKeys)
    writeTrustAnchors(anchorPathB, tenantBKeys)
    let anchorsA = loadTrustAnchors(anchorPathA)
    let anchorsB = loadTrustAnchors(anchorPathB)

    var specs: seq[MtlsPeerSpec] = @[]
    for kp in tenantAKeys:
      specs.add(MtlsPeerSpec(keypair: kp, anchors: anchorsA))
    for kp in tenantBKeys:
      specs.add(MtlsPeerSpec(keypair: kp, anchors: anchorsB))

    let peers = spawnLoopbackMtlsPeers(specs, seedAll = true)
    try:
      waitFor dialAllLoopbackClients(peers)
      var waited = 0
      while waited < MaxWaitMs and not allReachedSameTenantSize(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # Tenant-A peers should see exactly the other 4 tenant-A peers.
      for i in 0 ..< PerTenant:
        check peers[i].registry.peerCount() == PerTenant - 1
        for j in 0 ..< PerTenant:
          if i == j: continue
          check peers[i].registry.hasPeer(peers[j].peerId)
        # And NO tenant-B peer.
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
      waitFor shutdownLoopbackPeers(peers)
