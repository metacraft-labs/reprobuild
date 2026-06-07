## Peer-Cache-BearSSL M3 verification: per-tenant TLS isolation.
##
## Two tenants, each with their own anchor directory (3 peers per
## tenant). Within a tenant peers form a cluster; across tenants peers
## reject each other at TLS cert validation.

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

const
  PerTenant = 3
  TotalPeers = PerTenant * 2
  PollIntervalMs = 100
  MaxWaitMs = 6_000

proc allReachedSameTenantSize(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.registry.peerCount() < PerTenant - 1:
      return false
  true

suite "peer-cache TLS per-tenant CA isolation (M3)":
  test "tenant-A and tenant-B form disjoint membership domains":
    var opts: seq[LoopbackTlsOptions] = @[]
    for i in 0 ..< PerTenant:
      opts.add(LoopbackTlsOptions(tenantId: 0))
    for i in 0 ..< PerTenant:
      opts.add(LoopbackTlsOptions(tenantId: 1))
    let peers = waitFor spawnLoopbackTlsPeers(TotalPeers, opts,
      fleetTag = "per_tenant_" & $epochTime())
    try:
      waitFor dialAllLoopbackClients(peers)
      var waited = 0
      while waited < MaxWaitMs and not allReachedSameTenantSize(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      # Tenant-A peers see exactly the other 2 tenant-A peers and no
      # tenant-B peers.
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
      waitFor shutdownLoopbackPeers(peers)
