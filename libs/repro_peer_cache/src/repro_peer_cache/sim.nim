## In-process scaling simulation harness — Peer-Cache-Scale M5.
##
## Spawns hundreds of peers inside a single Nim process, drives SWIM
## convergence + a randomised content-addressed fetch workload against
## the existing `PeerCacheServer` / `PeerCacheClient` / `SwimEngine`
## primitives, and produces a structured `SimReport` that the M5
## demonstration report consumes.
##
## Why in-process rather than 200 actual TCP sockets? At 200 peers a
## fully meshed kernel-port topology requires ~40 000 sockets just for
## the SWIM probe layer plus another N² for advertise/fetch — well past
## what `asyncdispatch` on a single thread schedules cleanly. The SWIM
## engine already ships an in-process transport (`newInProcessTransport`)
## that routes encoded frames between engines via a synthetic endpoint
## directory. M5 reuses that transport for SWIM and layers an
## *equivalent* in-process fetch helper for the workload step: the
## helper updates the same `PeerCacheMetrics` counters that the wire-
## level fetch path would, so the report numbers are produced through
## the production observability surface rather than a side channel.
##
## Layout per peer:
##
##   `SimPeer` =
##     selfPeerId, registry, swim engine, metrics shell, blobs map,
##     rack id, tenant id, trust mode
##
## The `PeerCacheServer` / `PeerCacheClient` objects from the milestone
## brief are constructed but never `start()`-ed (no TCP bind) — they
## hold the metrics + registry so the surface mirrors production code,
## and the sim's fetch helper writes through those metrics shells.

import std/[asyncdispatch, math, monotimes, random,
            sequtils, sets, strformat, tables, times]

import ./client
import ./loopback
import ./metrics
import ./registry
import ./server
import ./swim
import ./types

type
  SimPeerSpec* = object
    ## Per-peer configuration knob for `spawnSimFleet`. The caller
    ## supplies one of these per peer; the helper allocates the peer ID
    ## from the loopback `makePeerId` deterministically.
    peerId*: PeerId
    listenPort*: int
      ## Synthetic port used as the in-process directory key. Distinct
      ## per peer; the in-process SWIM transport never opens a real
      ## socket.
    rackId*: int
      ## Tier-2 / rack grouping. The simulation seeds blobs and reports
      ## rack-local hit ratios via this field.
    tenantId*: int
      ## Per-tenant CA isolation. Two peers with the same `tenantId`
      ## share trust anchors; two peers with distinct `tenantId`s do
      ## not. Drives `tmTls` isolation tests.
    trustMode*: TrustMode
      ## `tmCidr` for the M0 / M2-style CIDR path; `tmTls` for the
      ## BearSSL TLS 1.2 mutual-auth path. The simulation respects
      ## this for SWIM membership and the simulated fetch routing.

  SimPeer* = object
    spec*: SimPeerSpec
    peerId*: PeerId
    endpoint*: Endpoint
    registry*: PeerRegistry
    swim*: SwimEngine
    server*: PeerCacheServer
    client*: PeerCacheClient
    metrics*: PeerCacheMetrics
    blobs*: Table[BlobDigest, seq[byte]]
      ## Locally seeded blobs this peer can serve. Indexed by digest.

  SimFleet* = ref object
    peers*: seq[PeerCacheServer]
      ## Per-spec shape: servers held to satisfy the milestone brief's
      ## `peers*` field. Use `sims` for the richer per-peer state.
    clients*: seq[PeerCacheClient]
    metrics*: seq[PeerCacheMetrics]
    sims*: seq[SimPeer]
    rng*: Rand

  SimReport* = object
    peerCount*: int
    durationMs*: int
    swimConvergenceMs*: int
    swimProtocolPeriods*: int
    advertisementsSent*: uint64
    advertisementsReceived*: uint64
    fetchesAttempted*: uint64
    fetchesHitLocal*: uint64
    fetchesHitPeer*: uint64
    fetchesHitTier2*: uint64
    fetchesMissed*: uint64
    signatureRejections*: uint64
    swimPingsSent*: uint64
    swimPingAcksSent*: uint64
    poolReuseRatio*: float
    p50FetchLatencyMs*: int
    p95FetchLatencyMs*: int
    p99FetchLatencyMs*: int
    rackCount*: int
    tenantCount*: int

const
  SimBasePort = 41000
    ## Base of the synthetic-port allocation. Distinct from the
    ## 50-peer SWIM convergence test's `30000` so the in-process
    ## directory keys never collide if both run in the same process.

# ---------------------------------------------------------------------------
# Peer construction.
# ---------------------------------------------------------------------------

proc defaultSimSpecs*(n: int;
                      racks: int = 5;
                      tenants: int = 2;
                      trustMode: TrustMode = tmCidr): seq[SimPeerSpec] =
  ## Convenience: build `n` per-peer specs partitioned across `racks`
  ## racks and `tenants` tenants in a round-robin pattern. Each
  ## peer's `trustMode` is uniform; the mixed-tenant verification test
  ## supplies its own specs to pin `tmTls`.
  result = newSeq[SimPeerSpec](n)
  let r = max(1, racks)
  let t = max(1, tenants)
  for i in 0 ..< n:
    result[i] = SimPeerSpec(
      peerId: makePeerId(i),
      listenPort: SimBasePort + i,
      rackId: i mod r,
      tenantId: i mod t,
      trustMode: trustMode)

proc spawnSimFleet*(specs: seq[SimPeerSpec];
                    swimCfg: SwimConfig = defaultSwimConfig();
                    seedsPerPeer: int = 5;
                    seed: int64 = 0xC0FFEE): Future[SimFleet] {.async.} =
  ## Allocates one `SimPeer` per spec, wires every SWIM engine in the
  ## in-process directory, and seeds the membership table with
  ## bootstrap endpoints. Returns once every engine is constructed but
  ## *not* started — the caller drives `startSwim` so tests can pre-
  ## populate state.
  let n = specs.len
  let fleet = SimFleet(
    peers: newSeq[PeerCacheServer](n),
    clients: newSeq[PeerCacheClient](n),
    metrics: newSeq[PeerCacheMetrics](n),
    sims: newSeq[SimPeer](n),
    rng: initRand(seed))

  # Pre-compute endpoints so the seed list can refer to any peer.
  var endpoints = newSeq[Endpoint](n)
  for i in 0 ..< n:
    endpoints[i] = initEndpoint("127.0.0.1", Port(specs[i].listenPort))

  let allowlist = @[parseCidrV4(LoopbackCidr)]

  for i in 0 ..< n:
    let spec = specs[i]
    let peerId = spec.peerId
    let endpoint = endpoints[i]
    let reg = newPeerRegistry(peerId, endpoint)
    let met = newPeerCacheMetrics()
    # Server + client are constructed but not start()-ed. They carry
    # the shared `metrics` + `registry` so per-peer counter increments
    # flow through the production shell.
    let srv = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(spec.listenPort),
      registry = reg,
      cidrAllowlist = allowlist,
      capTier2 = (spec.rackId == 0),
      trustMode = spec.trustMode,
      metrics = met)
    let cli = newPeerCacheClient(
      selfPeerId = peerId,
      listenPort = uint16(spec.listenPort),
      registry = reg,
      seedPeers = newSeq[Endpoint](),
      cidrAllowlist = allowlist,
      capTier2 = (spec.rackId == 0),
      trustMode = spec.trustMode,
      metrics = met)
    fleet.peers[i] = srv
    fleet.clients[i] = cli
    fleet.metrics[i] = met
    fleet.sims[i] = SimPeer(
      spec: spec,
      peerId: peerId,
      endpoint: endpoint,
      registry: reg,
      swim: nil,
      server: srv,
      client: cli,
      metrics: met,
      blobs: initTable[BlobDigest, seq[byte]]())

  # Build SWIM engines with per-peer bootstrap seed sets so the
  # membership table converges on roughly-random graph topology.
  for i in 0 ..< n:
    var chosen = initHashSet[int]()
    while chosen.len < min(seedsPerPeer, n - 1):
      let pick = fleet.rng.rand(n - 1)
      if pick == i: continue
      # In `tmTls` mode peers from a foreign tenant never accept each
      # other's traffic, so we restrict the seed list to same-tenant
      # peers up front. (CIDR mode keeps the cross-tenant edges.)
      if specs[i].trustMode == tmTls and
         specs[pick].tenantId != specs[i].tenantId:
        continue
      chosen.incl(pick)
    var seeds: seq[Endpoint] = @[]
    for idx in chosen:
      seeds.add(endpoints[idx])
    let engine = newSwimEngine(
      selfPeerId = fleet.sims[i].peerId,
      selfEndpoint = endpoints[i],
      registry = fleet.sims[i].registry,
      config = swimCfg,
      transport = newInProcessTransport(),
      seedEndpoints = seeds,
      metrics = fleet.metrics[i])
    fleet.sims[i].swim = engine

  return fleet

# ---------------------------------------------------------------------------
# Lifecycle.
# ---------------------------------------------------------------------------

proc startSwim*(fleet: SimFleet) =
  ## Mirrors `startLoopbackSwimPeers`: phase 1 registers every engine
  ## in the in-process directory + seeds its self-gossip entry; phase 2
  ## fires the bootstrap + period scheduler. The two-phase split is
  ## load-bearing — without it a peer's first probe lands at a peer
  ## that hasn't yet registered itself.
  for sim in fleet.sims:
    if sim.swim.isNil: continue
    sim.swim.running = true
    registerEngineInDirectory(sim.swim)
    sim.swim.enqueueGossip(SwimMember(
      peerId: sim.peerId,
      endpoint: sim.endpoint,
      status: smsAlive,
      incarnation: sim.swim.selfIncarnation))
  for sim in fleet.sims:
    if sim.swim.isNil: continue
    asyncCheck sim.swim.bootstrap()
    asyncCheck sim.swim.periodLoop()

proc shutdownFleet*(fleet: SimFleet): Future[void] {.async.} =
  ## Stops every SWIM engine and clears in-process state. Servers /
  ## clients were never started, so there are no TCP sockets to close.
  for sim in fleet.sims:
    if not sim.swim.isNil:
      sim.swim.stop()
  # Drain the async dispatcher so any pending probe/ack futures get
  # finalised before the caller exits. Without this, a fleet-shutdown
  # followed immediately by `poll(0)` can leave a few cancelled futures
  # holding callback references.
  for _ in 0 ..< 5:
    try: poll(0) except ValueError: discard
    await sleepAsync(1)

# ---------------------------------------------------------------------------
# Convergence wait.
# ---------------------------------------------------------------------------

proc isolatedForTenant(fleet: SimFleet; sim: SimPeer): int =
  ## Number of peers in the same tenant as `sim` (excluding itself).
  result = 0
  for other in fleet.sims:
    if other.peerId == sim.peerId: continue
    if other.spec.tenantId == sim.spec.tenantId:
      inc result

proc waitForConvergence*(fleet: SimFleet; targetMembership: int;
                        timeoutMs: int): Future[int] {.async.} =
  ## Polls every 100 ms until every peer's SWIM membership table has at
  ## least `targetMembership` alive members. Returns the elapsed
  ## milliseconds when the predicate holds, or `-1` if the timeout
  ## fires first. Honours tenant isolation in `tmTls` mode by capping
  ## the per-peer expectation at the tenant-local population.
  let started = getMonoTime()
  while true:
    var allOk = true
    for sim in fleet.sims:
      if sim.swim.isNil: continue
      let cap =
        if sim.spec.trustMode == tmTls:
          min(targetMembership, isolatedForTenant(fleet, sim))
        else:
          targetMembership
      if sim.swim.aliveMembers().len < cap:
        allOk = false
        break
    if allOk:
      return int((getMonoTime() - started).inMilliseconds)
    if int((getMonoTime() - started).inMilliseconds) >= timeoutMs:
      return -1
    # Yield to the dispatcher.
    try: poll(0) except ValueError: discard
    await sleepAsync(100)

# ---------------------------------------------------------------------------
# Blob seeding + workload.
# ---------------------------------------------------------------------------

proc digestForBlob(payload: seq[byte]): BlobDigest =
  ## Tiny deterministic digest. Not BLAKE3 — the simulation never
  ## crosses the wire, so we only need a uniform 32-byte identifier
  ## that the registry's `findPeersWithBlob` can index. A real BLAKE3
  ## call per seed-blob would double the simulation's warm-up time
  ## without adding fidelity.
  var raw: array[32, byte]
  var h: uint64 = 0xcbf29ce484222325'u64  # FNV offset basis
  for b in payload:
    h = h xor uint64(b)
    h = h * 0x100000001b3'u64
  for i in 0 ..< 32:
    raw[i] = byte((h shr ((i mod 8) * 8)) and 0xff)
    if (i mod 8) == 7:
      h = h * 0x100000001b3'u64
  blobDigestFromBytes(raw)

proc seedRandomBlobs*(fleet: SimFleet; blobsPerPeer: int;
                     blobBytes: int): Future[void] {.async.} =
  ## Each peer is seeded with `blobsPerPeer` randomly-generated blobs.
  ## The digest is added to the peer's own `selfAdvertised` set and
  ## tracked as a local-served blob. The advertise counters are bumped
  ## once per seed batch as a stand-in for the snapshot advertise that
  ## the production path would send during the post-handshake flush.
  for i in 0 ..< fleet.sims.len:
    var sim = fleet.sims[i]
    var digests: seq[BlobDigest] = @[]
    for j in 0 ..< blobsPerPeer:
      var payload = newSeq[byte](blobBytes)
      for k in 0 ..< blobBytes:
        payload[k] = byte(fleet.rng.rand(255))
      # Prefix with peer index + blob index to guarantee uniqueness
      # across the fleet (otherwise the FNV digest could collide).
      payload[0] = byte(i and 0xff)
      payload[1] = byte((i shr 8) and 0xff)
      payload[2] = byte(j and 0xff)
      payload[3] = byte((j shr 8) and 0xff)
      let d = digestForBlob(payload)
      sim.blobs[d] = payload
      sim.registry.selfAddBlob(d)
      digests.add(d)
    fleet.sims[i] = sim
    # Propagate the seed set to every other peer's registry so
    # `findPeersWithBlob` returns the right peer ID set. Production
    # code would do this via the post-handshake advertise snapshot;
    # the sim folds it into the seed step so the workload phase has a
    # populated index without waiting for SWIM-piggybacked gossip.
    if not fleet.metrics[i].isNil:
      inc fleet.metrics[i].advertisementsSentTotal
  # After each peer's self-set is populated, mirror the digests into
  # every other peer's registry as if the peer had advertised the
  # snapshot. We do this in a second pass so the per-peer
  # advertisedFilter is built once with the final set.
  for i in 0 ..< fleet.sims.len:
    let srcSim = fleet.sims[i]
    let srcDigests = toSeq(srcSim.blobs.keys)
    let ad = Advertise(
      sequence: 1'u64, mode: amSnapshot,
      added: srcDigests, removed: @[])
    for j in 0 ..< fleet.sims.len:
      if j == i: continue
      var dstSim = fleet.sims[j]
      # Mirror the production-style "we know about this peer" addPeer
      # before applying the advertise. In tmTls mode skip across-
      # tenant peers to model the isolated-CA case.
      if dstSim.spec.trustMode == tmTls and
         dstSim.spec.tenantId != srcSim.spec.tenantId:
        continue
      dstSim.registry.addPeer(srcSim.peerId, srcSim.endpoint)
      dstSim.registry.setPeerTier2(srcSim.peerId, srcSim.spec.rackId == 0)
      dstSim.registry.applyAdvertise(srcSim.peerId, ad)
      fleet.sims[j] = dstSim
      if not fleet.metrics[j].isNil:
        inc fleet.metrics[j].advertisementsReceivedTotal

proc runWorkload*(fleet: SimFleet;
                  fetchesPerPeer: int): Future[void] {.async.} =
  ## Each peer fetches `fetchesPerPeer` random blobs it does not own.
  ## The simulator looks up the candidate peer set via
  ## `findPeersWithBlob`, "fetches" by direct table lookup against the
  ## chosen peer's `blobs` map, and bumps the production metrics shell
  ## counters so the report numbers come from the canonical surface.
  for i in 0 ..< fleet.sims.len:
    let sim = fleet.sims[i]
    if sim.metrics.isNil: continue
    var rng = initRand(int64(i) * 2654435761'i64)
    for f in 0 ..< fetchesPerPeer:
      # Pick a random peer-index whose blob we'll try to read.
      var owner = rng.rand(fleet.sims.len - 1)
      if owner == i:
        owner = (owner + 1) mod fleet.sims.len
      let ownerSim = fleet.sims[owner]
      let ownerBlobs = toSeq(ownerSim.blobs.keys)
      if ownerBlobs.len == 0: continue
      let digest = ownerBlobs[rng.rand(ownerBlobs.len - 1)]
      # The sim peer's registry should know about `owner` from the
      # seed phase. Same-tenant `tmTls` peers see each other; cross-
      # tenant `tmTls` peers do not — that fetch becomes a miss.
      let startMs = nowMs()
      let candidates = sim.registry.findPeersWithBlob(digest)
      var found = false
      var fromTier2 = false
      var fromOwner: PeerId
      for cand in candidates:
        # Resolve the candidate's local-blob map.
        var candSim: SimPeer
        var have = false
        for s in fleet.sims:
          if s.peerId == cand:
            candSim = s
            have = true
            break
        if not have: continue
        if candSim.blobs.hasKey(digest):
          found = true
          fromOwner = cand
          if sim.registry.isPeerTier2(cand):
            fromTier2 = true
          break
      let elapsed = int(nowMs() - startMs)
      recordFetchLatency(sim.metrics, max(elapsed, 0))
      if found:
        inc sim.metrics.fetchHitsPeer
        if fromTier2:
          inc sim.metrics.fetchHitsTier2
      else:
        inc sim.metrics.fetchMissesTotal
      # Yield every 50 fetches so the dispatcher keeps SWIM probes alive.
      if (f mod 50) == 0:
        try: poll(0) except ValueError: discard
        await sleepAsync(0)

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------

proc percentileMs(buckets: array[8, uint64]; total: uint64; q: float): int =
  ## Approximates the q-quantile from the bucketed histogram. Returns
  ## the upper bound of the bucket containing the rank. `+Inf` bucket
  ## (index 7) yields the largest finite cap as a stand-in.
  if total == 0:
    return 0
  let target = uint64(float(total) * q)
  var cumulative: uint64 = 0
  for i in 0 ..< 8:
    cumulative += buckets[i]
    if cumulative >= target:
      let cap = FetchLatencyBucketsMs[i]
      if cap == 0:
        return FetchLatencyBucketsMs[6]  # last finite bucket cap
      return cap
  FetchLatencyBucketsMs[6]

proc collectReport*(fleet: SimFleet; durationMs, swimConvergenceMs: int;
                   swimProbePeriodMs: int = 0): SimReport =
  ## Sums every per-peer metric shell into one `SimReport`. The
  ## convergence-time and pool reuse ratio are derived; the percentile
  ## fields fold the per-peer histograms together before bucketing.
  result.peerCount = fleet.sims.len
  result.durationMs = durationMs
  result.swimConvergenceMs = swimConvergenceMs
  if swimProbePeriodMs > 0 and swimConvergenceMs > 0:
    result.swimProtocolPeriods =
      int(round(float(swimConvergenceMs) / float(swimProbePeriodMs)))

  var racks = initHashSet[int]()
  var tenants = initHashSet[int]()
  for sim in fleet.sims:
    racks.incl(sim.spec.rackId)
    tenants.incl(sim.spec.tenantId)
  result.rackCount = racks.len
  result.tenantCount = tenants.len

  var checkouts: uint64 = 0
  var hits: uint64 = 0
  var aggBuckets: array[8, uint64]
  for i in 0 .. 7: aggBuckets[i] = 0
  var aggTotal: uint64 = 0

  for met in fleet.metrics:
    if met.isNil: continue
    result.advertisementsSent += met.advertisementsSentTotal
    result.advertisementsReceived += met.advertisementsReceivedTotal
    result.fetchesHitLocal += met.fetchHitsLocal
    result.fetchesHitPeer += met.fetchHitsPeer
    result.fetchesHitTier2 += met.fetchHitsTier2
    result.fetchesMissed += met.fetchMissesTotal
    result.signatureRejections += met.signatureRejectionsTotal
    result.swimPingsSent += met.swimPingsTotal
    result.swimPingAcksSent += met.swimPingAcksTotal
    for i in 0 .. 7:
      aggBuckets[i] += met.fetchLatencyBuckets[i]
    aggTotal += met.fetchLatencyCount

  for cli in fleet.clients:
    if cli.isNil or cli.pool.isNil: continue
    checkouts += cli.pool.totalCheckouts
    hits += cli.pool.totalCheckoutHits

  result.fetchesAttempted =
    result.fetchesHitLocal + result.fetchesHitPeer + result.fetchesMissed
  if checkouts > 0:
    result.poolReuseRatio = float(hits) / float(checkouts)
  else:
    result.poolReuseRatio = 0.0
  result.p50FetchLatencyMs = percentileMs(aggBuckets, aggTotal, 0.50)
  result.p95FetchLatencyMs = percentileMs(aggBuckets, aggTotal, 0.95)
  result.p99FetchLatencyMs = percentileMs(aggBuckets, aggTotal, 0.99)

# ---------------------------------------------------------------------------
# Renderers.
# ---------------------------------------------------------------------------

proc renderReportJson*(r: SimReport): string =
  ## Hand-rolled JSON so the renderer doesn't pull in `std/json`. The
  ## fields match the public `SimReport` shape one-to-one.
  result = "{"
  result.add(&"\"peerCount\":{r.peerCount},")
  result.add(&"\"durationMs\":{r.durationMs},")
  result.add(&"\"swimConvergenceMs\":{r.swimConvergenceMs},")
  result.add(&"\"swimProtocolPeriods\":{r.swimProtocolPeriods},")
  result.add(&"\"advertisementsSent\":{r.advertisementsSent},")
  result.add(&"\"advertisementsReceived\":{r.advertisementsReceived},")
  result.add(&"\"fetchesAttempted\":{r.fetchesAttempted},")
  result.add(&"\"fetchesHitLocal\":{r.fetchesHitLocal},")
  result.add(&"\"fetchesHitPeer\":{r.fetchesHitPeer},")
  result.add(&"\"fetchesHitTier2\":{r.fetchesHitTier2},")
  result.add(&"\"fetchesMissed\":{r.fetchesMissed},")
  result.add(&"\"signatureRejections\":{r.signatureRejections},")
  result.add(&"\"swimPingsSent\":{r.swimPingsSent},")
  result.add(&"\"swimPingAcksSent\":{r.swimPingAcksSent},")
  result.add(&"\"poolReuseRatio\":{r.poolReuseRatio:0.3f},")
  result.add(&"\"p50FetchLatencyMs\":{r.p50FetchLatencyMs},")
  result.add(&"\"p95FetchLatencyMs\":{r.p95FetchLatencyMs},")
  result.add(&"\"p99FetchLatencyMs\":{r.p99FetchLatencyMs},")
  result.add(&"\"rackCount\":{r.rackCount},")
  result.add(&"\"tenantCount\":{r.tenantCount}")
  result.add("}")

proc renderReportMarkdown*(r: SimReport): string =
  ## Demonstration-report-grade Markdown. Sections: Convergence,
  ## Workload, Latency, Observability. The names matter for the
  ## `t_peer_cache_sim_report_renders_markdown` verification test.
  var s = newStringOfCap(1024)
  s.add(&"# Peer-Cache-Scale {r.peerCount}-peer simulation\n\n")
  s.add(&"Run duration: {r.durationMs} ms\n\n")
  s.add(&"Fleet layout: {r.rackCount} rack(s), {r.tenantCount} tenant(s)\n\n")

  s.add("## Convergence\n\n")
  if r.swimConvergenceMs >= 0:
    s.add(&"- SWIM convergence wall-clock: {r.swimConvergenceMs} ms\n")
    if r.swimProtocolPeriods > 0:
      s.add(&"- SWIM protocol periods to converge: {r.swimProtocolPeriods}\n")
  else:
    s.add("- SWIM convergence did not complete inside the budget\n")
  s.add(&"- SWIM pings sent: {r.swimPingsSent}\n")
  s.add(&"- SWIM ping-acks sent: {r.swimPingAcksSent}\n\n")

  s.add("## Workload\n\n")
  s.add(&"- Advertisements sent: {r.advertisementsSent}\n")
  s.add(&"- Advertisements received: {r.advertisementsReceived}\n")
  s.add(&"- Fetches attempted: {r.fetchesAttempted}\n")
  s.add(&"- Fetch hits (local): {r.fetchesHitLocal}\n")
  s.add(&"- Fetch hits (peer): {r.fetchesHitPeer}\n")
  s.add(&"- Fetch hits (tier-2): {r.fetchesHitTier2}\n")
  s.add(&"- Fetch misses: {r.fetchesMissed}\n")
  let hitRatio =
    if r.fetchesAttempted > 0:
      float(r.fetchesHitLocal + r.fetchesHitPeer) /
        float(r.fetchesAttempted)
    else: 0.0
  s.add(&"- Hit ratio: {hitRatio:0.3f}\n\n")

  s.add("## Latency\n\n")
  s.add(&"- p50: {r.p50FetchLatencyMs} ms\n")
  s.add(&"- p95: {r.p95FetchLatencyMs} ms\n")
  s.add(&"- p99: {r.p99FetchLatencyMs} ms\n\n")

  s.add("## Observability\n\n")
  s.add(&"- Pool reuse ratio: {r.poolReuseRatio:0.3f}\n")
  s.add(&"- Signature rejections: {r.signatureRejections}\n")
  return s
