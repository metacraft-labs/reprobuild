## Loopback peer-cache spawn helper — Peer-Cache M0.
##
## Spins up N peer instances each bound to `127.0.0.1:<ephemeral>` on
## the same OS, all seeded with each other's endpoints, all using a
## CIDR allowlist of `127.0.0.0/8`. Useful for both the M0
## verification tests and ad-hoc smoke runs.

import std/[asyncdispatch, nativesockets]

import ./auth
import ./client
import ./registry
import ./server
import ./swim
import ./types

type
  LoopbackPeer* = object
    peerId*: PeerId
    server*: PeerCacheServer
    client*: PeerCacheClient
    registry*: PeerRegistry
    swim*: SwimEngine
      ## Peer-Cache-Scale M0: optional SWIM engine. Non-nil when the
      ## peer was spawned via `spawnLoopbackSwimPeers`.

  LoopbackPeerOptions* = object
    ## Per-peer M1 wiring: optional store reader (consulted by the
    ## peer's *server* when answering `mkFetchRequest`), optional
    ## store writer (called by the peer's *client* after a verified
    ## `mkFetchResponse`), and optional response interceptor (test
    ## seam for the corrupted-payload verification).
    localStoreReader*: LocalStoreReader
    localStoreWriter*: LocalStoreWriter
    responseInterceptor*: ResponseInterceptor
    maxBlobBytes*: uint64
      ## When non-zero, overrides the default `maxBlobBytes` (100 MB).

const LoopbackCidr* = "127.0.0.0/8"

proc makePeerId*(index: int): PeerId =
  var raw: array[32, byte]
  # Deterministic-but-distinct: byte 0 marks "loopback test peer",
  # byte 1 carries the index. Production code derives peer IDs from
  # `nimcrypto.sysrand`; the loopback helper deliberately uses a
  # cheap deterministic scheme so failing tests are easy to triage.
  raw[0] = byte(ord('L'))
  raw[1] = byte(index and 0xff)
  raw[2] = byte((index shr 8) and 0xff)
  peerIdFromBytes(raw)

proc spawnLoopbackPeers*(n: int;
                         options: seq[LoopbackPeerOptions] = @[]):
                         seq[LoopbackPeer] =
  ## Spawns `n` peers on `127.0.0.1:0` (ephemeral OS-assigned ports).
  ## Each peer's server is started before the next peer is created so
  ## the ephemeral port is settled before being used as a seed for
  ## the others. After all servers are up, each peer's client is
  ## dialled with the other peers' endpoints as seeds.
  ##
  ## The optional `options` argument, when provided, must have length
  ## `n` and supplies per-peer M1 wiring (store reader / writer,
  ## response interceptor, maxBlobBytes override). When omitted, all
  ## peers run the M0 stub fetch path.
  ##
  ## Returns handles in the order they were created. Use
  ## `shutdownLoopbackPeers` for a graceful close.
  if options.len != 0 and options.len != n:
    raise newException(ValueError,
      "spawnLoopbackPeers: options.len must equal n (got " &
      $options.len & " vs " & $n & ")")
  let allowlist = @[parseCidrV4(LoopbackCidr)]
  result = newSeq[LoopbackPeer](n)
  # Phase 1: build all peers and start their servers so endpoints
  # are known before any client dials.
  for i in 0 ..< n:
    let peerId = makePeerId(i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    var reader: LocalStoreReader = nil
    var interceptor: ResponseInterceptor = nil
    var maxBytes: uint64 = DefaultMaxBlobBytes
    if options.len > 0:
      reader = options[i].localStoreReader
      interceptor = options[i].responseInterceptor
      if options[i].maxBlobBytes != 0:
        maxBytes = options[i].maxBlobBytes
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist,
      maxBlobBytes = maxBytes,
      localStoreReader = reader,
      responseInterceptor = interceptor)
    server.start()
    result[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)
  # Phase 2: now that every peer has a bound port, construct the
  # seed list for each one (all the others) and create the client.
  for i in 0 ..< n:
    var seeds: seq[Endpoint] = @[]
    for j in 0 ..< n:
      if j == i: continue
      seeds.add(initEndpoint("127.0.0.1", result[j].server.actualPort))
    var writer: LocalStoreWriter = nil
    if options.len > 0:
      writer = options[i].localStoreWriter
    let client = newPeerCacheClient(
      selfPeerId = result[i].peerId,
      listenPort = uint16(result[i].server.actualPort),
      registry = result[i].registry,
      seedPeers = seeds,
      cidrAllowlist = allowlist,
      localStoreWriter = writer)
    result[i].client = client

proc dialAllLoopbackClients*(peers: seq[LoopbackPeer]):
    Future[void] {.async.} =
  ## Dials every peer's client. Separate from `spawnLoopbackPeers` so
  ## tests can inspect the registry state before / after the dial.
  var futures: seq[Future[void]] = @[]
  for peer in peers:
    futures.add(peer.client.start())
  if futures.len > 0:
    await all(futures)

proc shutdownLoopbackPeers*(peers: seq[LoopbackPeer]) {.async.} =
  ## Gracefully closes each peer's client (sends Goodbye, closes
  ## sockets) and stops each server.
  for peer in peers:
    if not peer.client.isNil:
      await peer.client.stop()
  for peer in peers:
    if not peer.server.isNil:
      peer.server.stop()

# ---------------------------------------------------------------------------
# Peer-Cache M2: multicast-based loopback spawn helper.
# ---------------------------------------------------------------------------

proc spawnLoopbackMulticastPeers*(n: int;
                                 group: MulticastGroup;
                                 advertiseIntervalMs: int = 200):
                                 seq[LoopbackPeer] =
  ## Spawns `n` peers configured for UDP multicast discovery on the
  ## loopback interface. Mirrors `spawnLoopbackPeers` but replaces
  ## the seed-list discovery with `pdmMulticast`: each peer's server
  ## runs both the TCP accept loop AND a multicast receive loop on
  ## `group`; each peer's client runs the multicast broadcast loop.
  ##
  ## The shorter default `advertiseIntervalMs` (200 ms vs the spec's
  ## 5000 ms) keeps the M2 verification test fast — three peers
  ## settle within a few hundred ms on a quiet loopback. Production
  ## callers leave the default to the spec value.
  ##
  ## Returns handles in creation order; use `dialAllLoopbackClients`
  ## (a no-op for multicast peers, since dialing happens reactively
  ## inside the server's multicast receiver) — for symmetry with the
  ## M0 helper we still expose a `start` entrypoint via
  ## `startLoopbackMulticastClients`.
  let allowlist = @[parseCidrV4(LoopbackCidr)]
  result = newSeq[LoopbackPeer](n)
  # Phase 1: construct every server + start the TCP listener + start
  # the multicast receiver. Each server gets its own ephemeral TCP
  # port; the multicast group is shared.
  for i in 0 ..< n:
    let peerId = makePeerId(i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist)
    server.start()
    server.multicastListen(group)
    result[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)
  # Phase 2: each peer's client uses an empty seed list — discovery
  # is multicast-only — and starts its broadcast loop. The client
  # still carries the listen port + peer ID so its `mkHello`
  # announcements advertise the correct TCP endpoint.
  for i in 0 ..< n:
    let client = newPeerCacheClient(
      selfPeerId = result[i].peerId,
      listenPort = uint16(result[i].server.actualPort),
      registry = result[i].registry,
      seedPeers = newSeq[Endpoint](),
      cidrAllowlist = allowlist,
      advertiseIntervalMs = advertiseIntervalMs)
    result[i].client = client
    client.multicastBroadcast(group)

# ---------------------------------------------------------------------------
# Peer-Cache-Scale M0: SWIM-based loopback spawn helper.
# ---------------------------------------------------------------------------

import std/[random, sets]

proc spawnLoopbackSwimPeers*(n: int;
                             swimConfig: SwimConfig;
                             seedsPerPeer: int = 5;
                             seed: int64 = 0xC0FFEE): seq[LoopbackPeer] =
  ## Spawns `n` SWIM peers entirely in-process. Each peer gets a
  ## distinct synthetic endpoint (host `127.0.0.1`, port = 30000 + i),
  ## registers itself in the in-process SWIM directory, and is seeded
  ## with `seedsPerPeer` other random peers' endpoints so the
  ## bootstrap layer has somewhere to send its first probe.
  ##
  ## Ports here are synthetic — the in-process transport uses them as
  ## directory keys, not as real TCP sockets. This keeps the 50-peer
  ## convergence test from contending with kernel ephemeral-port
  ## allocation. A future M-step can layer the engine over real
  ## UDP/TCP transport without touching this helper.
  result = newSeq[LoopbackPeer](n)
  var rng = initRand(seed)
  # First construct every peer + registry so we can build the seed
  # list across the full population.
  var endpoints = newSeq[Endpoint](n)
  for i in 0 ..< n:
    endpoints[i] = initEndpoint("127.0.0.1", Port(30000 + i))
  for i in 0 ..< n:
    let peerId = makePeerId(i)
    let registry = newPeerRegistry(peerId, endpoints[i])
    result[i] = LoopbackPeer(
      peerId: peerId,
      server: nil,
      client: nil,
      registry: registry,
      swim: nil)
  # Now build per-peer seed lists (small random subsets) and create
  # the SWIM engines.
  for i in 0 ..< n:
    var chosen = initHashSet[int]()
    while chosen.len < min(seedsPerPeer, n - 1):
      let pick = rng.rand(n - 1)
      if pick == i: continue
      chosen.incl(pick)
    var seeds: seq[Endpoint] = @[]
    for idx in chosen:
      seeds.add(endpoints[idx])
    let engine = newSwimEngine(
      selfPeerId = result[i].peerId,
      selfEndpoint = endpoints[i],
      registry = result[i].registry,
      config = swimConfig,
      transport = newInProcessTransport(),
      seedEndpoints = seeds)
    result[i].swim = engine

proc startLoopbackSwimPeers*(peers: seq[LoopbackPeer]) =
  ## Starts each peer's SWIM engine. Splits start from spawn so tests
  ## can pre-seed registries (e.g. inject a fake suspect) before the
  ## scheduler runs.
  ##
  ## Two-phase to avoid the race where peer A's bootstrap probe lands
  ## at peer B before B has registered itself in the in-process
  ## directory: phase 1 marks each engine `running` and adds it to
  ## the directory, phase 2 fires the bootstrap probes + period loop.
  # Phase 1: directory registration only.
  for peer in peers:
    if not peer.swim.isNil:
      peer.swim.running = true
      registerEngineInDirectory(peer.swim)
      # Seed gossip with self so the first ack teaches the seed about us.
      peer.swim.enqueueGossip(SwimMember(
        peerId: peer.swim.selfPeerId,
        endpoint: peer.swim.selfEndpoint,
        status: smsAlive,
        incarnation: peer.swim.selfIncarnation))
  # Phase 2: kick the bootstrap + period scheduler for each engine.
  for peer in peers:
    if not peer.swim.isNil:
      asyncCheck peer.swim.bootstrap()
      asyncCheck peer.swim.periodLoop()

proc shutdownLoopbackSwimPeers*(peers: seq[LoopbackPeer]) =
  for peer in peers:
    if not peer.swim.isNil:
      peer.swim.stop()

# ---------------------------------------------------------------------------
# Peer-Cache-Scale M3: mTLS loopback spawn helper.
# ---------------------------------------------------------------------------

type
  MtlsPeerSpec* = object
    ## Per-peer mTLS configuration for `spawnLoopbackMtlsPeers`.
    ## `keypair` is the peer's own keypair; `anchors` is the trust-
    ## anchor table the peer uses to gate inbound + outbound peers.
    ## When `keypair.privateKey` is all zeros, the helper generates a
    ## fresh keypair.
    keypair*: PeerKeypair
    anchors*: TrustAnchors

proc spawnLoopbackMtlsPeers*(specs: openArray[MtlsPeerSpec];
                            seedAll: bool = true): seq[LoopbackPeer] =
  ## Spawns one peer per `specs` entry, each configured with
  ## `trustMode = tmMtls`. Mirrors `spawnLoopbackPeers` but plumbs the
  ## per-peer keypair + trust-anchor table through to the server +
  ## client constructors. When `seedAll` is true (default) each peer
  ## seeds with every other peer's endpoint (the M3 verification tests
  ## want this all-to-all topology so they can observe which dials
  ## succeed and which the auth handshake rejects).
  let allowlist = @[parseCidrV4(LoopbackCidr)]
  let n = specs.len
  result = newSeq[LoopbackPeer](n)
  # Phase 1: spawn every server first so endpoints are known.
  for i in 0 ..< n:
    let peerId = makePeerId(i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist,
      trustMode = tmMtls,
      keypair = specs[i].keypair,
      trustAnchors = specs[i].anchors)
    server.start()
    result[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)
  # Phase 2: spawn clients with all-to-all seed lists.
  for i in 0 ..< n:
    var seeds: seq[Endpoint] = @[]
    if seedAll:
      for j in 0 ..< n:
        if j == i: continue
        seeds.add(initEndpoint("127.0.0.1", result[j].server.actualPort))
    let client = newPeerCacheClient(
      selfPeerId = result[i].peerId,
      listenPort = uint16(result[i].server.actualPort),
      registry = result[i].registry,
      seedPeers = seeds,
      cidrAllowlist = allowlist,
      trustMode = tmMtls,
      keypair = specs[i].keypair,
      trustAnchors = specs[i].anchors)
    result[i].client = client
