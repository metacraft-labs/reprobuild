## Peer-Cache-Scale M5 verification: mixed-tenant fleet stays isolated.
##
## Builds a fleet of 80 `tmMtls` peers split into two tenants (40 +
## 40). After convergence each peer's SWIM membership view must
## contain only peers from its own tenant — the cross-tenant trust
## anchors don't overlap, so `spawnSimFleet` restricts the bootstrap
## seed list to same-tenant peers and the in-process directory keeps
## them isolated by topology.

import std/[asyncdispatch, os, sets, tables, unittest]

import repro_peer_cache

const
  PeersPerTenant = 40
  NumTenants = 2
  NumPeers = PeersPerTenant * NumTenants
  ProbePeriodMs = 50
  ConvergenceBudgetMs = 8_000

suite "peer-cache simulation mixed-tenant isolation":
  test "tmMtls fleet keeps tenants in disjoint membership views":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 20

    var specs = newSeq[SimPeerSpec](NumPeers)
    for i in 0 ..< NumPeers:
      specs[i] = SimPeerSpec(
        peerId: makePeerId(i),
        listenPort: 42100 + i,
        rackId: i mod 4,
        tenantId: i div PeersPerTenant,
        trustMode: tmMtls)
    let fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = 5)
    try:
      startSwim(fleet)
      # Wait for each tenant's peers to converge among themselves.
      let convergeMs = waitFor waitForConvergence(
        fleet, PeersPerTenant - 1, ConvergenceBudgetMs)
      check convergeMs >= 0
      # Per-peer assertion: alive members never cross tenant boundaries.
      var tenantOf = initTable[PeerId, int]()
      for sim in fleet.sims:
        tenantOf[sim.peerId] = sim.spec.tenantId
      for sim in fleet.sims:
        let myTenant = sim.spec.tenantId
        for otherId in sim.swim.aliveMembers():
          check tenantOf[otherId] == myTenant
        # Each peer sees at most (tenant size - 1) peers.
        check sim.swim.aliveMembers().len <= PeersPerTenant - 1
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
