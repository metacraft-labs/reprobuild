## Peer-cache TCP client — Peer-Cache M0.
##
## `asyncnet` + `asyncdispatch` based client. `start` dials each seed
## peer, completes the `mkHello` / `mkHelloOk` handshake, registers
## the remote peer ID + endpoint with the local registry, and reads
## the initial `mkAdvertise` snapshot. Connections are kept open
## (one per peer) so subsequent fetch requests and advertisements
## reuse them; `stop` sends `mkGoodbye` to each peer and closes.

import std/[algorithm, asyncdispatch, asyncnet, monotimes, nativesockets,
            options, sets, tables, times]
when defined(posix):
  from std/posix import nil

import blake3

import ./auth
import ./boundary
import ./codec
import ./evidence_record
import ./identity
import ./memo_store
import ./metrics
import ./multicast
import ./pki
import ./registry
import ./secret_key
import ./server  # for inAllowlist + CidrV4
import ./tls
import ./types

export metrics
export evidence_record

type
  PooledConn* = ref object
    ## Peer-Cache-Scale M4: a single pooled outbound connection.
    ## The wire-level socket is opened by `acquireConn` and (re)used
    ## across multiple `requestFetch` calls until either
    ## `reapIdle` evicts it or `close` is called explicitly.
    socket*: AsyncSocket
    peerId*: PeerId
    endpoint*: Endpoint
    lastUsed*: MonoTime
    inUse*: bool
    valid*: bool
      ## Set to `false` when the socket is closed (e.g. peer FIN, send
      ## error). Reused as a tombstone so concurrent waiters don't
      ## hand back a half-closed connection.
    hasHandshaked*: bool
      ## `true` after the first `mkHello` / `mkHelloOk` round on this
      ## connection. The pool reuses the same socket for subsequent
      ## fetches; the handshake only fires on the fresh-dial path.

  PeerConnPool* = ref object
    ## Per-client outbound connection pool keyed by peer ID. Pools are
    ## created with `newPeerConnPool` and held by `PeerCacheClient`. The
    ## counter fields are public so verification tests can assert pool
    ## behaviour without depending on internal HTTP scraping.
    maxPerPeer*: int
    idleTimeoutMs*: int
    conns*: Table[PeerId, seq[PooledConn]]
    totalCheckouts*: uint64
      ## Number of `acquireConn` calls that returned a `PooledConn`.
    totalCheckoutHits*: uint64
      ## Subset of `totalCheckouts` that reused an existing pooled
      ## entry (i.e. a cache hit).
    totalOpened*: uint64
      ## Number of fresh TCP connections opened (cache miss path).
    totalEvicted*: uint64
      ## Connections closed by `reapIdle` because they were idle past
      ## `idleTimeoutMs`.
    totalLruEvicted*: uint64
      ## Connections closed because the per-peer cap was reached and
      ## the oldest non-`inUse` entry was kicked.
    peakConcurrentInUse*: int
      ## Highest observed `inUse` count summed across all peers.
      ## Updated on every `acquireConn` return.
    metrics*: PeerCacheMetrics
      ## Optional shared metrics shell. Pool counters are mirrored into
      ## the gauges (`poolConnsActive`, `poolConnsIdle`) after every
      ## acquire/release/reap.

const DefaultSelectorFanout* = 16
  ## Distributed-Execution M0: how many connected peers `requestSelectors`
  ## asks directly when no peer's advertisement names the weak fingerprint
  ## (an advertisement can lag a publish by one refresh interval).

const DefaultFetchTimeoutMs* = 5_000
  ## Per-candidate fetch timeout for `requestFetch`. The spec
  ## (`Peer-Cache.md` §"Fetch semantics") doesn't pin a value; 5 s is
  ## generous for LAN round-trips and short enough that an unresponsive
  ## peer doesn't block the engine for long. Tests override this via
  ## `PeerCacheClient.fetchTimeoutMs`.

type
  PeerCacheClient* = ref object
    selfPeerId*: PeerId
    listenPort*: uint16
    registry*: PeerRegistry
    seedPeers*: seq[Endpoint]
    allowlist*: seq[CidrV4]
    localStoreWriter*: LocalStoreWriter
      ## Peer-Cache M1: optional writer. When non-nil,
      ## `requestFetch` writes the verified payload to the local
      ## store and advertises the new blob via `registry.selfAddBlob`
      ## so subsequent advertise rounds carry it.
    fetchTimeoutMs*: int
      ## Per-candidate fetch timeout in milliseconds.
    fetchRoundTripCount*: int
      ## Test instrumentation: number of `mkFetchRequest` sends that
      ## the client has issued. The action-cache-reader verification
      ## test asserts a single round-trip per logical fetch (the
      ## second read hits the local cache).
    advertiseIntervalMs*: int
      ## Peer-Cache M2: cadence (ms) at which `multicastBroadcast`
      ## re-sends the peer's `mkHello` announcement. Matches the spec
      ## default `peer_cache.advertise_interval_ms` (`Peer-Cache.md`
      ## §"Configuration surface"); defaults to 5_000.
    multicastSocket*: AsyncSocket
      ## Peer-Cache M2: held open across the broadcast loop. Created on
      ## first `multicastBroadcast` invocation; closed by `stop()`.
    multicastRunning*: bool
      ## Peer-Cache M2: `multicastBroadcast`'s loop terminates when
      ## this flips to `false` (set by `stop()`).
    pendingFetches: Table[BlobDigest,
                          Future[Option[seq[byte]]]]
      ## In-flight `mkFetchRequest` correlation table. Entries are
      ## keyed by the *expected* digest carried in the request
      ## envelope; the reader loop completes the future when the
      ## matching `mkFetchResponse` arrives (after BLAKE3
      ## verification). Only one outstanding request per digest per
      ## client is tracked — concurrent requests for the same digest
      ## share the same future.
    connections*: Table[PeerId, AsyncSocket]
    running: bool
    capTier2*: bool
      ## Peer-Cache-Scale M2: this peer's tier-2 capability. Stamped
      ## into outbound `Hello` frames so remote peers can record us
      ## as a tier-2 candidate in their registries.
    trustMode*: TrustMode
      ## Peer-Cache-BearSSL M3: trust gating. `tmCidr` preserves the
      ## M0-M2 path; `tmTls` wraps every dial with a BearSSL TLS 1.2
      ## mutual-auth handshake (see `tls.nim`).
    ourCert*: CertAndKey
      ## Peer-Cache-BearSSL M3: this client's X.509 cert + key. Only
      ## used when `trustMode == tmTls`.
    trustAnchorSet*: TrustAnchorSet
      ## Peer-Cache-BearSSL M3: parsed allowed-peer cert directory.
      ## Only used when `trustMode == tmTls`.
    tlsConnsByPeerId*: Table[PeerId, TlsConn]
      ## Peer-Cache-BearSSL M3: live TLS tunnels keyed by remote peer
      ## ID. Mirror of `connections` for the `tmTls` path so callers
      ## that send signed advertisements via `sendAdvertiseV2` can find
      ## the active tunnel without re-keying through the socket table.
    peerKeyByPeerId*: Table[PeerId, PublicKeyBytes]
      ## Peer-Cache-BearSSL M3: TLS-validated remote pubkey per peer ID.
    signatureRejectedCount*: int
      ## Peer-Cache-Scale M3: signed advertisement frames the client's
      ## receiver path rejected.
    signatureRejectedPeers: HashSet[PeerId]
    tlsHandshakeRejectedCount*: int
      ## Peer-Cache-BearSSL M3: outbound dials whose TLS handshake
      ## failed (cert not in anchors, expired, malformed, I/O,
      ## timeout).
    pool*: PeerConnPool
      ## Peer-Cache-Scale M4: per-peer connection pool. Used by
      ## `requestFetchPooled`; the legacy long-lived `connections`
      ## table is left intact so the handshake / advertise side stays
      ## on its existing path.
    metrics*: PeerCacheMetrics
      ## Peer-Cache-Scale M4: optional shared metrics shell.
      ## `requestFetch`'s increment sites are no-ops when nil.
    pendingSelectors: Table[string, Future[Option[seq[MemoSelector]]]]
      ## Distributed-Execution M0: outstanding `mkGetSelectorsRequest`s,
      ## keyed by `<peerId>/<weak>`. A selector reply arrives on the
      ## connection to the peer that was asked, so the reader loop knows
      ## which peer answered and the key needs no extra correlation id.
    pendingMemoEntries: Table[string, Future[Option[seq[byte]]]]
      ## Outstanding `mkGetActionRecordRequest`s, keyed by
      ## `<peerId>/<weak>/<strong>`.
    memoRoundTripCount*: int
      ## Instrumentation: memo requests (selector + entry) sent.
    suspectMarks*: int
      ## Instrumentation: how many times this client marked a peer suspect
      ## because a content-plane reply failed `BLAKE3(payload) == digest`.
      ## Unlike the registry's `suspect` flag, which the next advertise
      ## snapshot clears, this counter is monotonic, so a test can assert
      ## that an honest exchange produced NO suspect marks at all.
    maxSelectorFanout*: int
      ## Upper bound on peers asked for selectors when none of them
      ## advertises the weak fingerprint (see `requestSelectors`).
    leafProvider*: LeafProvider
      ## Distributed-Execution M7: this process's current short-lived leaf
      ## (`identity.nim`). When set, every TLS dial presents it and sends
      ## it as an `mkIdentityProof`; when nil, `ourCert` is presented.
    requireShortLivedLeaves*: bool
      ## Distributed-Execution M7 (CRED-1): refuse a server that does not
      ## prove a host-CA leaf.
    reporter*: DetectionReporter
      ## Distributed-Execution M7 (DET-2, DET-6): where content-plane and
      ## memoization-plane detections go — the off-host evidence sink.
      ## A detection with no reporter is still counted locally.
    revokedIssuers*: HashSet[PeerId]
      ## Hosts whose memo attestations are refused (M8 containment).
    peerRoles*: Table[PeerId, LeafRole]
      ## The leaf role each connected peer proved.
    detectionsReported*: int
      ## Detections handed to `reporter` (instrumentation).
    reportFlusher*: proc() {.gcsafe, closure.}
      ## Blocks until reported detections have left the host (DET-6). A
      ## synchronous caller — the build engine's fetch hook — runs it after
      ## a lookup that reported something, because the engine stops driving
      ## the dispatcher once the lookup returns.
    refusalsReceived*: int
      ## `mkRefused` notices received from servers (instrumentation).
    lastRefusal*: RefusedNotice
    pendingGoals: Table[PeerId, Future[GoalReply]]
      ## Distributed-Execution M7: the outstanding `mkReachGoalRequest` per
      ## worker (one at a time per connection).
    maxResponseBytes*: uint64
      ## Cap on any frame this client reads: a hostile server must not be
      ## able to make us allocate an arbitrary payload (FLOW-2 applies to
      ## every receiver, including the one reading replies).
    gate*: ReceiverGate
      ## Distributed-Execution M7 (threat model G29): every frame a peer
      ## sends on a connection THIS client opened passes
      ## `ReceiverGate.decideOutbound` — per-kind size, rate, "was it asked
      ## for", the peer's credential judged now — and is audited through
      ## `gate.audit`. Never nil after construction.
    outstanding: Table[PeerId, OutboundContext]
      ## What this client is waiting for from each peer.
    peerIdentity*: Table[PeerId, CallerIdentity]
      ## Each connected peer as this client verified it at the handshake
      ## (host, leaf role, leaf expiry).
    ownLeafNotAfter: Table[PeerId, int64]
      ## The expiry of the leaf this client presented on each connection.
    hydration: Table[PeerId, HydrationSet]
      ## While a `ReachGoal` to a worker is outstanding: what that worker
      ## may fetch back over this connection (FLOW-1, threat model D4).
    hydrationServed*: int
      ## Hydration fetches answered (instrumentation).
    dialDiscovered*: bool
      ## Whether `connectKnownPeers` dials peers the registry learned from
      ## inbound Hellos and multicast. A WORKER sets it false: it never
      ## opens a connection to a requester or orchestrator (FLOW-1); it
      ## dials only its declared seeds.
    discoveredEndpoints*: seq[Endpoint]
      ## Multicast-announced endpoints to dial through TLS (fed by the
      ## node's server; see `server.dialAnnouncedPeer`).
    revokedPeers*: HashSet[PeerId]
      ## Hosts this client neither dials nor keeps a connection to.
    clock*: proc(): int64 {.gcsafe, closure.}
      ## Unix milliseconds; nil = the system clock (a test seam, G15).

  HydrationSet* = object
    ## What a worker may fetch back from the caller while the caller's
    ## `ReachGoal` is outstanding: exactly the digests the caller published
    ## for that goal (the descriptor, the snapshot manifest and the
    ## snapshot's blobs), read from `reader`.
    digests*: HashSet[BlobDigest]
    reader*: LocalStoreReader

  GoalReplyKind* = enum
    grkResponse, grkRefused, grkNoAnswer

  GoalReply* = object
    ## What a worker answered a `mkReachGoalRequest` with.
    kind*: GoalReplyKind
    payload*: seq[byte]
      ## The encoded `ReachGoalResponse` (grkResponse).
    refusal*: RefusedNotice
      ## The receiver gate's refusal (grkRefused).

  PeerSelector* = object
    ## A selector together with the peer that vouched for it.
    peerId*: PeerId
    selector*: MemoSelector

  PeerCacheClientError* = object of CatchableError

proc newPeerConnPool*(maxPerPeer: int = DefaultPoolMaxPerPeer;
                      idleTimeoutMs: int = DefaultPoolIdleTimeoutMs;
                      metrics: PeerCacheMetrics = nil): PeerConnPool =
  ## Constructs an empty per-peer connection pool. Defaults match the
  ## spec (`Peer-Cache-Scale.md` §"Connection lifecycle + observability"):
  ## 4 connections per peer, 30 s idle window.
  let cap = if maxPerPeer > 0: maxPerPeer else: DefaultPoolMaxPerPeer
  let idle = if idleTimeoutMs > 0: idleTimeoutMs else: DefaultPoolIdleTimeoutMs
  PeerConnPool(
    maxPerPeer: cap,
    idleTimeoutMs: idle,
    conns: initTable[PeerId, seq[PooledConn]](),
    totalCheckouts: 0,
    totalCheckoutHits: 0,
    totalOpened: 0,
    totalEvicted: 0,
    totalLruEvicted: 0,
    peakConcurrentInUse: 0,
    metrics: metrics)

proc newPeerCacheClient*(selfPeerId: PeerId;
                        listenPort: uint16;
                        registry: PeerRegistry;
                        seedPeers: openArray[Endpoint];
                        cidrAllowlist: openArray[CidrV4];
                        localStoreWriter: LocalStoreWriter = nil;
                        fetchTimeoutMs: int = DefaultFetchTimeoutMs;
                        advertiseIntervalMs: int = 5_000;
                        capTier2: bool = false;
                        trustMode: TrustMode = tmCidr;
                        ourCert: CertAndKey = CertAndKey();
                        trustAnchorSet: TrustAnchorSet = TrustAnchorSet();
                        poolMaxPerPeer: int = DefaultPoolMaxPerPeer;
                        poolIdleTimeoutMs: int = DefaultPoolIdleTimeoutMs;
                        metrics: PeerCacheMetrics = nil):
                        PeerCacheClient =
  result = PeerCacheClient(
    selfPeerId: selfPeerId,
    listenPort: listenPort,
    registry: registry,
    seedPeers: @seedPeers,
    allowlist: @cidrAllowlist,
    localStoreWriter: localStoreWriter,
    fetchTimeoutMs: fetchTimeoutMs,
    fetchRoundTripCount: 0,
    advertiseIntervalMs: advertiseIntervalMs,
    multicastSocket: nil,
    multicastRunning: false,
    pendingFetches: initTable[BlobDigest,
                              Future[Option[seq[byte]]]](),
    connections: initTable[PeerId, AsyncSocket](),
    running: false,
    capTier2: capTier2,
    trustMode: trustMode,
    ourCert: ourCert,
    trustAnchorSet: trustAnchorSet,
    tlsConnsByPeerId: initTable[PeerId, TlsConn](),
    peerKeyByPeerId: initTable[PeerId, PublicKeyBytes](),
    signatureRejectedCount: 0,
    signatureRejectedPeers: initHashSet[PeerId](),
    tlsHandshakeRejectedCount: 0,
    pool: newPeerConnPool(poolMaxPerPeer, poolIdleTimeoutMs, metrics),
    metrics: metrics,
    pendingSelectors: initTable[string, Future[Option[seq[MemoSelector]]]](),
    pendingMemoEntries: initTable[string, Future[Option[seq[byte]]]](),
    memoRoundTripCount: 0,
    suspectMarks: 0,
    maxSelectorFanout: DefaultSelectorFanout,
    peerRoles: initTable[PeerId, LeafRole](),
    revokedIssuers: initHashSet[PeerId](),
    pendingGoals: initTable[PeerId, Future[GoalReply]](),
    maxResponseBytes: DefaultMaxBlobBytes + 1024'u64 * 1024'u64,
    gate: newReceiverGate(),
    outstanding: initTable[PeerId, OutboundContext](),
    peerIdentity: initTable[PeerId, CallerIdentity](),
    ownLeafNotAfter: initTable[PeerId, int64](),
    hydration: initTable[PeerId, HydrationSet](),
    dialDiscovered: true,
    revokedPeers: initHashSet[PeerId]())

proc nowMsC(client: PeerCacheClient): int64 =
  if client.clock.isNil: int64(epochTime() * 1000.0)
  else: client.clock()

proc contextOf(client: PeerCacheClient; peerId: PeerId): OutboundContext =
  result = client.outstanding.getOrDefault(peerId, OutboundContext())
  result.goalPending = client.pendingGoals.hasKey(peerId)
  result.hydrationAllowed = result.goalPending and
    client.hydration.hasKey(peerId)

proc expect(client: PeerCacheClient; peerId: PeerId;
            kind: MessageKind; delta = 1) =
  ## Records that a reply of `kind` is (delta > 0) or no longer (delta < 0)
  ## expected from `peerId`.
  var ctx = client.outstanding.getOrDefault(peerId, OutboundContext())
  case kind
  of mkFetchResponse: ctx.fetchesPending = max(0, ctx.fetchesPending + delta)
  of mkGetSelectorsResponse:
    ctx.selectorsPending = max(0, ctx.selectorsPending + delta)
  of mkGetActionRecordResponse:
    ctx.recordsPending = max(0, ctx.recordsPending + delta)
  of mkHelloOk: ctx.helloPending = delta > 0
  else: discard
  client.outstanding[peerId] = ctx

proc peerOf(client: PeerCacheClient; peerId: PeerId;
            address = ""): CallerIdentity =
  client.peerIdentity.getOrDefault(peerId, CallerIdentity(address: address,
    hostId: peerId))

# ---------------------------------------------------------------------------
# Connection-pool ops — Peer-Cache-Scale M4.
# ---------------------------------------------------------------------------

proc countInUseAcrossPeers(pool: PeerConnPool): int =
  result = 0
  for _, lst in pool.conns.pairs:
    for c in lst:
      if c.valid and c.inUse:
        inc result

proc countIdleAcrossPeers(pool: PeerConnPool): int =
  result = 0
  for _, lst in pool.conns.pairs:
    for c in lst:
      if c.valid and not c.inUse:
        inc result

proc updatePoolGauges(pool: PeerConnPool) =
  let active = countInUseAcrossPeers(pool)
  let idle = countIdleAcrossPeers(pool)
  if active > pool.peakConcurrentInUse:
    pool.peakConcurrentInUse = active
  if not pool.metrics.isNil:
    setPoolGauges(pool.metrics, active, idle)

proc idleMs(conn: PooledConn): int =
  ## Milliseconds since the connection was last used. Tests use this to
  ## sanity-check the eviction branch.
  int((getMonoTime() - conn.lastUsed).inMilliseconds)

proc removeFromPeer(pool: PeerConnPool; peerId: PeerId;
                    conn: PooledConn) =
  if not pool.conns.hasKey(peerId):
    return
  var lst = pool.conns[peerId]
  var i = 0
  while i < lst.len:
    if lst[i] == conn:
      lst.delete(i)
    else:
      inc i
  if lst.len == 0:
    pool.conns.del(peerId)
  else:
    pool.conns[peerId] = lst

proc closeAndCount(pool: PeerConnPool; peerId: PeerId;
                   conn: PooledConn; bumpEvict: bool;
                   bumpLru: bool = false) =
  if conn.valid:
    conn.valid = false
    try: conn.socket.close() except CatchableError: discard
  removeFromPeer(pool, peerId, conn)
  if bumpEvict:
    inc pool.totalEvicted
  if bumpLru:
    inc pool.totalLruEvicted

proc reapIdle*(pool: PeerConnPool) =
  ## Closes every pooled connection that is idle past `idleTimeoutMs`.
  ## Idempotent and synchronous (no `await`); production callers run
  ## this from a periodic loop.
  if pool.isNil:
    return
  var peerKeys: seq[PeerId] = @[]
  for k in pool.conns.keys:
    peerKeys.add(k)
  for peerId in peerKeys:
    var lst = pool.conns[peerId]
    var keep: seq[PooledConn] = @[]
    for c in lst:
      if c.valid and not c.inUse and
         (pool.idleTimeoutMs > 0 and idleMs(c) > pool.idleTimeoutMs):
        # Idle-expired — close + count.
        c.valid = false
        try: c.socket.close() except CatchableError: discard
        inc pool.totalEvicted
      else:
        keep.add(c)
    if keep.len == 0:
      pool.conns.del(peerId)
    else:
      pool.conns[peerId] = keep
  updatePoolGauges(pool)

proc findIdleConn(pool: PeerConnPool; peerId: PeerId): PooledConn =
  if not pool.conns.hasKey(peerId):
    return nil
  let lst = pool.conns[peerId]
  # Idle-eviction sweep happens lazily on acquire so the caller never
  # gets handed a connection that's been sitting beyond the window.
  for c in lst:
    if c.valid and not c.inUse:
      if pool.idleTimeoutMs > 0 and idleMs(c) > pool.idleTimeoutMs:
        # Will be closed on the next pass; treat as missing.
        continue
      return c
  return nil

proc activeForPeerCount*(pool: PeerConnPool; peerId: PeerId): int
proc activeForPeer(pool: PeerConnPool; peerId: PeerId): int =
  result = 0
  if not pool.conns.hasKey(peerId):
    return 0
  for c in pool.conns[peerId]:
    if c.valid:
      inc result

proc activeForPeerCount*(pool: PeerConnPool; peerId: PeerId): int =
  activeForPeer(pool, peerId)

proc lruEvict(pool: PeerConnPool; peerId: PeerId) =
  ## When the per-peer cap is reached and no idle conn is available,
  ## close the *oldest non-inUse* entry to make room for the new dial.
  if not pool.conns.hasKey(peerId):
    return
  let lst = pool.conns[peerId]
  var victim: PooledConn = nil
  for c in lst:
    if c.valid and not c.inUse:
      if victim.isNil or c.lastUsed < victim.lastUsed:
        victim = c
  if not victim.isNil:
    closeAndCount(pool, peerId, victim, bumpEvict = false, bumpLru = true)

proc openFreshConn(pool: PeerConnPool; peerId: PeerId;
                   endpoint: Endpoint): Future[PooledConn] {.async.} =
  let sock = newAsyncSocket()
  try:
    await sock.connect(endpoint.host, endpoint.port)
  except CatchableError as err:
    try: sock.close() except CatchableError: discard
    raise err
  result = PooledConn(
    socket: sock,
    peerId: peerId,
    endpoint: endpoint,
    lastUsed: getMonoTime(),
    inUse: true,
    valid: true,
    hasHandshaked: false)
  if not pool.conns.hasKey(peerId):
    pool.conns[peerId] = @[]
  var lst = pool.conns[peerId]
  lst.add(result)
  pool.conns[peerId] = lst
  inc pool.totalOpened

proc acquireConn*(pool: PeerConnPool; peerId: PeerId;
                  endpoint: Endpoint): Future[PooledConn] {.async.} =
  ## Returns a pooled connection to `peerId`. Reuses an existing
  ## not-inUse entry whose idle age is below the configured window
  ## (cache hit, bumps `totalCheckoutHits`). On miss, opens a new TCP
  ## connection — respecting `maxPerPeer` by evicting the oldest idle
  ## entry or, if every slot is currently `inUse`, polling until one is
  ## released (max wait 200 ms).
  if pool.isNil:
    raise newException(PeerCacheClientError, "acquireConn on nil pool")
  # Lazy reap before we look — keeps cache-hit logic honest.
  reapIdle(pool)
  inc pool.totalCheckouts
  # Cache hit path.
  let cached = findIdleConn(pool, peerId)
  if not cached.isNil:
    cached.inUse = true
    cached.lastUsed = getMonoTime()
    inc pool.totalCheckoutHits
    updatePoolGauges(pool)
    return cached
  # No idle conn. Try to honour the cap: if room, dial fresh; if all
  # slots full and any is idle, evict; else wait briefly for a release.
  if activeForPeer(pool, peerId) >= pool.maxPerPeer:
    # First try to evict an idle entry to free a slot.
    lruEvict(pool, peerId)
  # If we still have no room (everyone in-use), poll.
  var waitedMs = 0
  while activeForPeer(pool, peerId) >= pool.maxPerPeer and
        waitedMs < 200:
    await sleepAsync(10)
    waitedMs += 10
    # Someone may have released — try the hit path again.
    let now = findIdleConn(pool, peerId)
    if not now.isNil:
      now.inUse = true
      now.lastUsed = getMonoTime()
      inc pool.totalCheckoutHits
      updatePoolGauges(pool)
      return now
    lruEvict(pool, peerId)
  result = await openFreshConn(pool, peerId, endpoint)
  updatePoolGauges(pool)

proc releaseConn*(pool: PeerConnPool; conn: PooledConn) =
  ## Marks the connection as available for reuse. Caller MUST NOT use
  ## the socket after release. If `conn.valid == false` (peer FIN /
  ## send error), the entry is removed instead of returned to the
  ## pool.
  if pool.isNil or conn.isNil:
    return
  conn.inUse = false
  conn.lastUsed = getMonoTime()
  if not conn.valid:
    removeFromPeer(pool, conn.peerId, conn)
  updatePoolGauges(pool)

proc invalidate*(pool: PeerConnPool; conn: PooledConn) =
  ## Marks a connection as broken (failed I/O). The pool closes it on
  ## the next release / reap.
  if pool.isNil or conn.isNil:
    return
  conn.valid = false
  try: conn.socket.close() except CatchableError: discard
  removeFromPeer(pool, conn.peerId, conn)
  updatePoolGauges(pool)

proc closeAll*(pool: PeerConnPool) =
  ## Closes every pooled connection. Called from `client.stop()`.
  if pool.isNil:
    return
  var peerKeys: seq[PeerId] = @[]
  for k in pool.conns.keys:
    peerKeys.add(k)
  for peerId in peerKeys:
    let lst = pool.conns[peerId]
    for c in lst:
      if c.valid:
        c.valid = false
        try: c.socket.close() except CatchableError: discard
    pool.conns.del(peerId)
  updatePoolGauges(pool)

# ---------------------------------------------------------------------------
# Frame I/O — mirrors the server's helpers.
# ---------------------------------------------------------------------------

proc sendFrame(sock: AsyncSocket; messageKind: MessageKind;
               payload: seq[byte]): Future[void] {.async.} =
  let bytes = encodeFrame(messageKind, payload)
  var asString = newString(bytes.len)
  for i, b in bytes:
    asString[i] = char(b)
  await sock.send(asString)

# ---------------------------------------------------------------------------
# Per-peer handshake + idle reader.
# ---------------------------------------------------------------------------

type
  GatedRead = object
    ## One frame from a connection this client opened, after the outbound
    ## gate (threat model G29).
    ok: bool
      ## A frame was admitted and decoded.
    closed: bool
      ## The peer closed the connection (or sent a short frame).
    frame: Frame

const MaxCapturedOutboundRefusal = 64 * 1024

type
  ContextProvider = proc(): tuple[peer: CallerIdentity; ctx: OutboundContext]
    {.gcsafe, closure.}
    ## Evaluated when a frame's header has ARRIVED — not when the reader
    ## started waiting for it, which can be long before the request it
    ## answers was even sent.

proc fixedContext(peer: CallerIdentity; ctx: OutboundContext): ContextProvider =
  result = proc(): tuple[peer: CallerIdentity; ctx: OutboundContext]
      {.gcsafe, closure.} = (peer, ctx)

proc liveContext(client: PeerCacheClient; peerId: PeerId): ContextProvider =
  let c = client
  result = proc(): tuple[peer: CallerIdentity; ctx: OutboundContext]
      {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      (c.peerOf(peerId), c.contextOf(peerId))

proc gateOutbound(client: PeerCacheClient; provider: ContextProvider;
                  header: seq[byte];
                  readBody: proc(n: int): Future[seq[byte]] {.gcsafe, closure.}):
                  Future[GatedRead] {.async.} =
  var payloadLen: uint32 = 0
  for i in 0 ..< 4:
    payloadLen = payloadLen or (uint32(header[4 + i]) shl uint32(i * 8))
  let tag = uint16(header[2]) or (uint16(header[3]) shl 8)
  let now = client.nowMsC()
  let (peer, ctx) = provider()
  let decision = client.gate.decideOutbound(peer, tag, payloadLen, ctx, now)
  if not decision.allowed:
    # Captured for the record (EVID-1), bounded, then the connection is
    # dropped: every outbound refusal closes it.
    var captured: seq[byte] = @[]
    let n = min(int(payloadLen), MaxCapturedOutboundRefusal)
    if n > 0:
      try: captured = await readBody(n)
      except CatchableError: discard
    client.gate.record(peer, tag, payloadLen, decision, captured,
      outbound = true, nowMs = now)
    return GatedRead(closed: true)
  var bytes = header
  if payloadLen > 0'u32:
    let body = await readBody(int(payloadLen))
    if body.len != int(payloadLen):
      return GatedRead(closed: true)
    bytes.add(body)
  let frame = decodeFrame(bytes)
  client.gate.recordAdmitted(peer, tag, frame.payload, outbound = true)
  return GatedRead(ok: true, frame: frame)

proc plainExact(sock: AsyncSocket; n: int): Future[seq[byte]] {.async.} =
  var got = ""
  while got.len < n:
    let chunk = await sock.recv(n - got.len)
    if chunk.len == 0:
      break
    got.add(chunk)
  result = newSeq[byte](got.len)
  for i in 0 ..< got.len:
    result[i] = byte(ord(got[i]))

proc readGatedPlain(client: PeerCacheClient; sock: AsyncSocket;
                    provider: ContextProvider): Future[GatedRead] {.async.} =
  let header = await plainExact(sock, 8)
  if header.len != 8:
    return GatedRead(closed: true)
  return await client.gateOutbound(provider, header,
    proc(n: int): Future[seq[byte]] {.gcsafe, closure.} = plainExact(sock, n))

proc readGatedPlain(client: PeerCacheClient; sock: AsyncSocket;
                    peer: CallerIdentity; ctx: OutboundContext):
                    Future[GatedRead] =
  client.readGatedPlain(sock, fixedContext(peer, ctx))

proc handshakePeer(client: PeerCacheClient;
                   sock: AsyncSocket;
                   endpoint: Endpoint): Future[PeerId] {.async.} =
  ## Sends Hello, waits for HelloOk + initial Advertise snapshot,
  ## registers the remote peer in the registry. Returns the
  ## remote peer ID. Used on the `tmCidr` path; the TLS path uses
  ## `handshakePeerTls` below. Every frame passes the outbound gate.
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32,
    capTier2: client.capTier2)
  await sendFrame(sock, mkHello, encodeHello(hello))
  let peer = CallerIdentity(address: endpoint.host)
  let ok = await client.readGatedPlain(sock, peer,
    OutboundContext(helloPending: true))
  if not ok.ok:
    raise newException(PeerCacheClientError,
      "no admissible HelloOk from " & endpoint.host & ":" & $endpoint.port.int)
  if ok.frame.messageKind != mkHelloOk:
    raise newException(PeerCacheClientError,
      "expected mkHelloOk, got " & $ok.frame.messageKind)
  let helloOk = decodeHelloOk(ok.frame.payload)
  client.registry.addPeer(helloOk.peerId, endpoint)
  client.registry.setPeerTier2(helloOk.peerId, helloOk.capTier2)
  client.peerIdentity[helloOk.peerId] = CallerIdentity(address: endpoint.host,
    hostId: helloOk.peerId, helloDone: true)

  # Send our initial advertise snapshot.
  let snapshot = client.registry.snapshotFor(helloOk.peerId)
  await sendFrame(sock, mkAdvertise, encodeAdvertise(snapshot))
  if not client.metrics.isNil:
    inc client.metrics.advertisementsSentTotal

  # Read the server's initial advertise snapshot.
  let adv = await client.readGatedPlain(sock,
    client.peerOf(helloOk.peerId, endpoint.host), OutboundContext())
  if adv.ok and adv.frame.messageKind == mkAdvertise:
    client.registry.applyAdvertise(helloOk.peerId,
      decodeAdvertise(adv.frame.payload))
  return helloOk.peerId

proc completePending(client: PeerCacheClient;
                     digest: BlobDigest;
                     value: Option[seq[byte]]) =
  ## Looks up the digest in the pending-fetch table and completes its
  ## future with `value` (or `none` on miss / verification failure).
  ## Removes the entry from the table so subsequent responses for the
  ## same digest (e.g. duplicate sends from a misbehaving peer) are
  ## dropped silently. Idempotent: if the future is already finished
  ## (e.g. the request timed out) the late response is discarded.
  if not client.pendingFetches.hasKey(digest):
    return
  let fut = client.pendingFetches[digest]
  client.pendingFetches.del(digest)
  if not fut.finished:
    fut.complete(value)

proc selectorKey(peerId: PeerId; weak: BlobDigest): string =
  $peerId & "/" & $weak

proc memoEntryKey(peerId: PeerId; weak, strong: BlobDigest): string =
  $peerId & "/" & $weak & "/" & $strong

proc completeSelectors(client: PeerCacheClient; key: string;
                       value: Option[seq[MemoSelector]]) =
  if not client.pendingSelectors.hasKey(key):
    return
  let fut = client.pendingSelectors[key]
  client.pendingSelectors.del(key)
  if not fut.finished:
    fut.complete(value)

proc completeMemoEntry(client: PeerCacheClient; key: string;
                       value: Option[seq[byte]]) =
  if not client.pendingMemoEntries.hasKey(key):
    return
  let fut = client.pendingMemoEntries[key]
  client.pendingMemoEntries.del(key)
  if not fut.finished:
    fut.complete(value)

proc reportDetection*(client: PeerCacheClient; record: EvidenceRecord) =
  ## Hands a detection to the off-host reporter (DET-6). Never raises.
  inc client.detectionsReported
  if client.reporter.isNil:
    return
  try:
    client.reporter(record)
  except CatchableError:
    discard

proc flushDetections*(client: PeerCacheClient) =
  ## Synchronous flush of reported detections; call only from a context
  ## that is not itself inside the dispatcher.
  if not client.reportFlusher.isNil:
    try:
      client.reportFlusher()
    except CatchableError:
      discard

proc markPeerSuspect*(client: PeerCacheClient; peerId: PeerId;
                      trigger, reason: string) =
  ## Marks `peerId` suspect AND reports the mark off-host: a suspicion that
  ## is only a local flag teaches us nothing about who sent the bad bytes
  ## (DET-2), and the mark is itself the event an attacker abusing
  ## suspicion to evict honest peers would produce (M8).
  client.registry.markSuspect(peerId)
  inc client.suspectMarks
  client.reportDetection(newEvidenceRecord(ecDetection, "peer-suspicion",
    "mark-suspect", [("peer", $peerId), ("reason", trigger & ": " & reason)]))

proc completeGoal(client: PeerCacheClient; peerId: PeerId; reply: GoalReply) =
  if not client.pendingGoals.hasKey(peerId):
    return
  let fut = client.pendingGoals[peerId]
  client.pendingGoals.del(peerId)
  if not fut.finished:
    fut.complete(reply)

proc handleRefusal(client: PeerCacheClient; peerId: PeerId; frame: Frame) =
  let notice = decodeRefused(frame.payload)
  inc client.refusalsReceived
  client.lastRefusal = notice
  if notice.refusedTag == uint16(ord(mkReachGoalRequest)):
    client.completeGoal(peerId, GoalReply(kind: grkRefused, refusal: notice))

proc handleContentReply(client: PeerCacheClient; peerId: PeerId;
                        resp: FetchResponse) =
  ## The content-plane rule, applied identically on both transports:
  ## `BLAKE3-256(payload) == digest` or the reply is dropped and the peer
  ## marked suspect (`Peer-Cache.md` §"Fetch semantics" step 3).
  if resp.truncated:
    client.completePending(resp.digest, none(seq[byte]))
    return
  let observed = blake3.digest(resp.payload)
  let expected = bytes(resp.digest)
  if observed != expected:
    # Mismatch is always the *peer's* fault: the digest was supplied by
    # the receiver, the payload was supplied by the peer. The payload is
    # NOT captured (it may be source); its digest and size are.
    client.reportDetection(newEvidenceRecord(ecDetection,
      "peer-cache-content", "blob-digest-mismatch",
      [("peer", $peerId), ("digest", $resp.digest),
       ("observedDigest", $blobDigestFromBytes(observed)),
       ("size", $resp.payload.len)], payload = resp.payload))
    client.markPeerSuspect(peerId, "blob-digest-mismatch",
      "payload does not hash to " & $resp.digest)
    client.completePending(resp.digest, none(seq[byte]))
  else:
    client.completePending(resp.digest, some(resp.payload))

proc handleMemoReply(client: PeerCacheClient; peerId: PeerId;
                     frame: Frame) =
  ## Memoization-plane replies. These are looked up by FINGERPRINT, not by
  ## content digest, so the content rule does not apply to them and a
  ## memo reply can never mark a peer suspect. The entry reply is checked
  ## for identity (its header must name the selector that was asked for)
  ## by `two_phase.fetchTwoPhase`, which decodes it.
  case frame.messageKind
  of mkGetSelectorsResponse:
    let resp = decodeGetSelectorsResponse(frame.payload)
    client.completeSelectors(selectorKey(peerId, resp.weakFingerprint),
      some(resp.selectors))
  of mkGetActionRecordResponse:
    let resp = decodeGetActionRecordResponse(frame.payload)
    let key = memoEntryKey(peerId, resp.weakFingerprint,
      resp.strongFingerprint)
    if resp.found:
      client.completeMemoEntry(key, some(resp.entry))
    else:
      client.completeMemoEntry(key, none(seq[byte]))
  else:
    discard

proc dropConnection(client: PeerCacheClient; peerId: PeerId;
                    sock: AsyncSocket) =
  ## Forget a connection whose reader loop ended (peer closed it or sent
  ## garbage), so later requests do not write into a dead socket and a
  ## membership refresh can re-dial the peer. Only removes the entry when
  ## it still names THIS socket — a re-dial may already have replaced it.
  if client.connections.hasKey(peerId) and
      client.connections[peerId] == sock:
    client.connections.del(peerId)

proc sendFrameTls(conn: TlsConn; messageKind: MessageKind;
                  payload: seq[byte]): Future[void] {.async.} =
  let bytes = encodeFrame(messageKind, payload)
  await tls.send(conn, bytes)

proc noteReply(client: PeerCacheClient; peerId: PeerId; kind: MessageKind) =
  ## An admitted reply settles one expectation of its kind.
  case kind
  of mkFetchResponse, mkGetSelectorsResponse, mkGetActionRecordResponse:
    client.expect(peerId, kind, -1)
  else:
    discard

proc serveHydrationFetch(client: PeerCacheClient; peerId: PeerId;
                         frame: Frame;
                         send: proc(kind: MessageKind; payload: seq[byte]):
                           Future[void] {.gcsafe, closure.}):
                         Future[bool] {.async.} =
  ## A worker fetching back over this client's connection (FLOW-1, threat
  ## model D4). Answered only for a digest the caller published for the
  ## outstanding goal; anything else is refused, reported and ends the
  ## connection (returns false).
  let req = decodeFetchRequest(frame.payload)
  let set = client.hydration.getOrDefault(peerId)
  if req.digest notin set.digests or set.reader.isNil:
    let decision = GateDecision(allowed: false, refusal: rcUnauthorized,
      reason: "the worker asked for " & $req.digest & ", which the caller " &
        "did not publish for its goal", closeConnection: true)
    client.gate.record(client.peerOf(peerId), uint16(ord(mkFetchRequest)),
      uint32(frame.payload.len), decision, frame.payload, outbound = true,
      nowMs = client.nowMsC())
    return false
  var resp = FetchResponse(digest: req.digest, truncated: true, payload: @[])
  let bytes = set.reader(req.digest)
  if bytes.isSome:
    resp = FetchResponse(digest: req.digest, truncated: false,
      payload: bytes.get())
  await send(mkFetchResponse, encodeFetchResponse(resp))
  inc client.hydrationServed
  return true

proc dispatchReply(client: PeerCacheClient; peerId: PeerId; frame: Frame;
                   send: proc(kind: MessageKind; payload: seq[byte]):
                     Future[void] {.gcsafe, closure.}):
                   Future[bool] {.async.} =
  ## Acts on one ADMITTED frame from a connection this client opened (both
  ## transports). Returns false when the connection must end.
  client.noteReply(peerId, frame.messageKind)
  case frame.messageKind
  of mkAdvertise:
    client.registry.applyAdvertise(peerId, decodeAdvertise(frame.payload))
  of mkAdvertiseV2:
    let ad = decodeAdvertiseV2(frame.payload)
    # Peer-Cache-BearSSL M3: signed-advertisement enforcement when
    # `tmTls`. The pubkey was bound to `peerId` at TLS-handshake
    # time via `peerKeyByPeerId`.
    if client.trustMode == tmTls and ad.signature.len > 0:
      var verified = false
      if ad.signature.len == 64 and client.peerKeyByPeerId.hasKey(peerId):
        var sig: SignatureBytes
        for i in 0 ..< 64:
          sig[i] = ad.signature[i]
        verified = verifySignature(client.peerKeyByPeerId[peerId],
          canonicaliseAdvertiseForSigning(peerId, ad), sig)
      if not verified:
        if peerId notin client.signatureRejectedPeers:
          client.signatureRejectedPeers.incl(peerId)
          inc client.signatureRejectedCount
        return true
    client.registry.applyAdvertiseV2(peerId, ad)
  of mkPing:
    await send(mkPong, encodePong(Pong()))
  of mkPong:
    client.registry.updateLastSeen(peerId)
  of mkGoodbye:
    return false
  of mkFetchResponse:
    # M1: correlate the digest with an outstanding `requestFetch`
    # call, BLAKE3-verify the payload, mark the peer suspect on
    # mismatch, and complete the future with `some(payload)` or
    # `none`. The spec's fetch semantics
    # (`Peer-Cache.md` §"Fetch semantics" step 3) live here.
    client.handleContentReply(peerId, decodeFetchResponse(frame.payload))
  of mkGetSelectorsResponse, mkGetActionRecordResponse:
    client.handleMemoReply(peerId, frame)
  of mkRefused:
    client.handleRefusal(peerId, frame)
  of mkReachGoalResponse:
    client.completeGoal(peerId, GoalReply(kind: grkResponse,
      payload: frame.payload))
  of mkFetchRequest:
    return await client.serveHydrationFetch(peerId, frame, send)
  else:
    # The outbound gate admits nothing else (`OutboundVocabulary`).
    discard
  return true

proc readerLoop(client: PeerCacheClient; sock: AsyncSocket;
                peerId: PeerId) {.async.} =
  ## After the handshake, keep reading framed messages — each through the
  ## outbound gate — applying advertise updates, responding to ping,
  ## completing fetch-response futures (M1).
  let send = proc(kind: MessageKind; payload: seq[byte]): Future[void]
      {.gcsafe, closure.} = sendFrame(sock, kind, payload)
  try:
    while client.running:
      let got = await client.readGatedPlain(sock,
        client.liveContext(peerId))
      if not got.ok:
        break
      if not await client.dispatchReply(peerId, got.frame, send):
        break
  except CatchableError:
    discard
  client.dropConnection(peerId, sock)
  try: sock.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Peer-Cache-BearSSL M3: TLS-side frame I/O + handshake + reader loop.
# ---------------------------------------------------------------------------

proc tlsExact(conn: TlsConn; n: int; idle = false): Future[seq[byte]]
    {.async.} =
  ## Exactly `n` bytes (fewer only when the tunnel closed). `idle`: this
  ## read waits for the next frame, so no deadline applies until its first
  ## byte (an idle connection is not a closed one).
  var got = ""
  while got.len < n:
    let chunk = await tls.recv(conn, n - got.len,
      idleTimeoutMs = (if idle and got.len == 0: 0 else: 60_000))
    if chunk.len == 0:
      break
    got.add(chunk)
  result = newSeq[byte](got.len)
  for i in 0 ..< got.len:
    result[i] = byte(ord(got[i]))

proc readGatedTls(client: PeerCacheClient; conn: TlsConn;
                  provider: ContextProvider;
                  idle = false): Future[GatedRead] {.async.} =
  let header = await tlsExact(conn, 8, idle)
  if header.len != 8:
    return GatedRead(closed: true)
  return await client.gateOutbound(provider, header,
    proc(n: int): Future[seq[byte]] {.gcsafe, closure.} = tlsExact(conn, n))

proc readGatedTls(client: PeerCacheClient; conn: TlsConn;
                  peer: CallerIdentity; ctx: OutboundContext;
                  idle = false): Future[GatedRead] =
  client.readGatedTls(conn, fixedContext(peer, ctx), idle)

proc handshakePeerTls(client: PeerCacheClient;
                      conn: TlsConn;
                      endpoint: Endpoint): Future[PeerId] {.async.} =
  ## TLS handshake continuation. With a leaf (Distributed-Execution M7) the
  ## client first proves it (`mkIdentityProof`) and expects the server to
  ## prove its own; the server's identity is then the host that SIGNED its
  ## leaf, and a HelloOk naming any other peer id aborts the dial. Without
  ## a leaf (the Peer-Cache-BearSSL shape) the identity is the key the
  ## handshake authenticated. Every frame passes the outbound gate.
  let remoteKey = remotePublicKey(conn)
  if remoteKey.isNone:
    raise newException(PeerCacheClientError,
      "TLS handshake authenticated no peer key: " & endpoint.host)
  var serverIdentity = legacyIdentityFromKey(remoteKey.get())
  var peer = CallerIdentity(address: endpoint.host)
  var proved = false
  if not client.leafProvider.isNil:
    await sendFrameTls(conn, mkIdentityProof,
      encodeIdentityProof(client.leafProvider().cert.certDer))
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32,
    capTier2: client.capTier2)
  await sendFrameTls(conn, mkHello, encodeHello(hello))
  var helloOkFrame: Frame
  while true:
    let got = await client.readGatedTls(conn, peer,
      OutboundContext(helloPending: true))
    if not got.ok:
      raise newException(PeerCacheClientError,
        "no admissible HelloOk over TLS from " & endpoint.host & ":" &
        $endpoint.port.int)
    let frame = got.frame
    if frame.messageKind == mkIdentityProof:
      let verified = verifyLeaf(decodeIdentityProof(frame.payload),
        client.trustAnchorSet, client.nowMsC() div 1000,
        expectedPublicKey = remoteKey,
        requireShortLived = client.requireShortLivedLeaves)
      if not verified.ok:
        raise newException(PeerCacheClientError,
          "server identity proof refused: " & verified.reason)
      serverIdentity = verified
      peer = CallerIdentity(authenticated: true, hostId: verified.hostId,
        leafRole: verified.role, leafNotAfter: verified.notAfter,
        address: endpoint.host)
      proved = true
      continue
    if frame.messageKind == mkRefused:
      let notice = decodeRefused(frame.payload)
      inc client.refusalsReceived
      client.lastRefusal = notice
      raise newException(PeerCacheClientError,
        "server refused the handshake: " & notice.reason)
    helloOkFrame = frame
    break
  if helloOkFrame.messageKind != mkHelloOk:
    raise newException(PeerCacheClientError,
      "expected mkHelloOk over TLS, got " & $helloOkFrame.messageKind)
  if client.requireShortLivedLeaves and not proved:
    raise newException(PeerCacheClientError,
      "server presented no short-lived leaf proof (CRED-1)")
  let helloOk = decodeHelloOk(helloOkFrame.payload)
  if helloOk.peerId != serverIdentity.hostId:
    raise newException(PeerCacheClientError,
      "HelloOk claims peer " & $helloOk.peerId &
      " but the authenticated host is " & $serverIdentity.hostId)
  if helloOk.peerId in client.revokedPeers:
    raise newException(PeerCacheClientError,
      "peer " & $helloOk.peerId & " is revoked")
  if not proved:
    peer = CallerIdentity(authenticated: true, hostId: serverIdentity.hostId,
      leafRole: serverIdentity.role, address: endpoint.host)
  peer.helloDone = true
  client.registry.addPeer(helloOk.peerId, endpoint)
  client.registry.setPeerTier2(helloOk.peerId, helloOk.capTier2)
  client.peerRoles[helloOk.peerId] = serverIdentity.role
  client.peerIdentity[helloOk.peerId] = peer
  # Bind the validated peer cert pubkey to the registered peer ID so
  # subsequent signed advertisements verify against the TLS-anchored
  # identity (not a self-asserted one).
  client.peerKeyByPeerId[helloOk.peerId] = remoteKey.get()
  let snapshot = client.registry.snapshotFor(helloOk.peerId)
  await sendFrameTls(conn, mkAdvertise, encodeAdvertise(snapshot))
  if not client.metrics.isNil:
    inc client.metrics.advertisementsSentTotal
  let adv = await client.readGatedTls(conn, peer, OutboundContext())
  if adv.ok and adv.frame.messageKind == mkAdvertise:
    client.registry.applyAdvertise(helloOk.peerId,
      decodeAdvertise(adv.frame.payload))
  elif not adv.ok:
    raise newException(PeerCacheClientError,
      "no admissible advertisement after HelloOk")
  return helloOk.peerId

proc failPendingFor(client: PeerCacheClient; peerId: PeerId) =
  ## The connection to `peerId` ended: nothing more will arrive on it.
  client.outstanding.del(peerId)
  client.peerIdentity.del(peerId)
  client.ownLeafNotAfter.del(peerId)
  if client.pendingGoals.hasKey(peerId):
    let fut = client.pendingGoals[peerId]
    client.pendingGoals.del(peerId)
    if not fut.finished:
      fut.complete(GoalReply(kind: grkNoAnswer))

proc readerLoopTls(client: PeerCacheClient; conn: TlsConn;
                   peerId: PeerId) {.async.} =
  let send = proc(kind: MessageKind; payload: seq[byte]): Future[void]
      {.gcsafe, closure.} = sendFrameTls(conn, kind, payload)
  try:
    while client.running:
      let got = await client.readGatedTls(conn, client.liveContext(peerId),
        idle = true)
      if not got.ok:
        break
      if not await client.dispatchReply(peerId, got.frame, send):
        break
  except CatchableError:
    discard
  if client.tlsConnsByPeerId.hasKey(peerId) and
      client.tlsConnsByPeerId[peerId] == conn:
    client.tlsConnsByPeerId.del(peerId)
    client.failPendingFor(peerId)
  try: await tls.close(conn) except CatchableError: discard

proc dialPeer(client: PeerCacheClient;
              endpoint: Endpoint): Future[void] {.async.} =
  var sock = newAsyncSocket()
  try:
    await sock.connect(endpoint.host, endpoint.port)
    # Peer-Cache-BearSSL M3: when `tmTls` is active, run the TLS
    # handshake before the Hello/HelloOk flow. On failure, close +
    # count + return.
    if client.trustMode == tmTls:
      var connOpt: Option[TlsConn]
      var presentedNotAfter = 0'i64
      if client.leafProvider.isNil:
        connOpt = await wrapClientSocket(sock, endpoint.host, client.ourCert,
          client.trustAnchorSet)
      else:
        let leaf = client.leafProvider()
        presentedNotAfter = leaf.cert.notAfter
        if leaf.key.isNil or not leaf.key.available:
          connOpt = none(TlsConn)
        else:
          connOpt = await wrapClientSocket(sock, endpoint.host,
            leaf.cert.certDer, leaf.key, client.trustAnchorSet)
      if connOpt.isNone:
        inc client.tlsHandshakeRejectedCount
        try: sock.close() except CatchableError: discard
        return
      let conn = connOpt.get()
      let peerId = await handshakePeerTls(client, conn, endpoint)
      client.tlsConnsByPeerId[peerId] = conn
      if presentedNotAfter > 0:
        client.ownLeafNotAfter[peerId] = presentedNotAfter
      asyncCheck readerLoopTls(client, conn, peerId)
      return
    let peerId = await handshakePeer(client, sock, endpoint)
    client.connections[peerId] = sock
    asyncCheck readerLoop(client, sock, peerId)
  except CatchableError:
    try: sock.close() except CatchableError: discard

proc start*(client: PeerCacheClient) {.async.} =
  ## Dials every seed peer concurrently. Returns once all dials have
  ## either completed (handshake done, peer registered) or failed
  ## (silently dropped, the peer simply doesn't enter the registry).
  client.running = true
  var futures: seq[Future[void]] = @[]
  for endpoint in client.seedPeers:
    futures.add(dialPeer(client, endpoint))
  if futures.len > 0:
    await all(futures)

proc sendRawFrameForTesting*(client: PeerCacheClient;
                             targetPeerId: PeerId;
                             messageKind: MessageKind;
                             payload: seq[byte];
                             expectReply = false): Future[void] {.async.} =
  ## Test-only seam: encode + send `messageKind` with the supplied
  ## payload bytes over the existing connection to `targetPeerId`.
  ## Routes through whichever transport (TCP or TLS) is live for the
  ## remote peer. `expectReply`: record that a reply to this request is
  ## expected, as the production request procs do — otherwise the outbound
  ## gate treats the reply as unsolicited (Distributed-Execution M7, G29).
  if expectReply:
    case messageKind
    of mkFetchRequest: client.expect(targetPeerId, mkFetchResponse)
    of mkGetSelectorsRequest: client.expect(targetPeerId, mkGetSelectorsResponse)
    of mkGetActionRecordRequest:
      client.expect(targetPeerId, mkGetActionRecordResponse)
    else: discard
  if client.tlsConnsByPeerId.hasKey(targetPeerId):
    let conn = client.tlsConnsByPeerId[targetPeerId]
    await sendFrameTls(conn, messageKind, payload)
    return
  if not client.connections.hasKey(targetPeerId):
    raise newException(PeerCacheClientError,
      "sendRawFrameForTesting: no live connection to target peer")
  let sock = client.connections[targetPeerId]
  await sendFrame(sock, messageKind, payload)

proc sendAdvertiseV2*(client: PeerCacheClient;
                     targetPeerId: PeerId;
                     ad: AdvertiseV2): Future[void] {.async.} =
  ## Peer-Cache-BearSSL M3 helper: sends a signed `mkAdvertiseV2` over
  ## the existing connection to `targetPeerId`. The signature is
  ## computed over the canonical bytes (sender = client.selfPeerId)
  ## using the client's TLS-bound ECDSA keypair when `tmTls`; for
  ## `tmCidr` the signature is left empty so the wire shape stays
  ## backward-compatible.
  var signed = ad
  if client.trustMode == tmTls:
    let msg = canonicaliseAdvertiseForSigning(client.selfPeerId, signed)
    var sig: SignatureBytes
    if client.leafProvider.isNil:
      sig = signMessage(client.ourCert.keypair, msg)
    else:
      # Distributed-Execution M7: the private key is the leaf's protected
      # page, not a field of `ourCert` (threat model G16).
      withKeypair(client.leafProvider().key, kp):
        sig = signMessage(kp, msg)
    signed.signature = newSeq[byte](64)
    for i in 0 ..< 64:
      signed.signature[i] = sig[i]
  if client.tlsConnsByPeerId.hasKey(targetPeerId):
    let conn = client.tlsConnsByPeerId[targetPeerId]
    await sendFrameTls(conn, mkAdvertiseV2, encodeAdvertiseV2(signed))
    if not client.metrics.isNil:
      inc client.metrics.advertisementsSentTotal
    return
  if not client.connections.hasKey(targetPeerId):
    raise newException(PeerCacheClientError,
      "sendAdvertiseV2: no live connection to target peer")
  let sock = client.connections[targetPeerId]
  await sendFrame(sock, mkAdvertiseV2, encodeAdvertiseV2(signed))
  if not client.metrics.isNil:
    inc client.metrics.advertisementsSentTotal

proc sortTier2First*(registry: PeerRegistry;
                     candidates: seq[PeerId]): seq[PeerId] =
  ## Peer-Cache-Scale M2: reorders a candidate list so that tier-2
  ## peers come before ordinary peers. Within each group the relative
  ## order is preserved (stable partition). See
  ## `Peer-Cache-Scale.md` §"Discovery extension".
  result = newSeq[PeerId]()
  var ordinary = newSeq[PeerId]()
  for p in candidates:
    if registry.isPeerTier2(p):
      result.add(p)
    else:
      ordinary.add(p)
  for p in ordinary:
    result.add(p)

proc requestFetch*(client: PeerCacheClient;
                   digest: BlobDigest): Future[Option[seq[byte]]]
                   {.async.} =
  ## Peer-Cache M1: implements the fetch flow described in
  ## `Peer-Cache.md` §"Fetch semantics" (steps 2–4). The local-store
  ## consult (step 1) is the caller's responsibility — wire it
  ## upstream via the engine-seam reader.
  ##
  ## Iterates candidate peers (from `registry.findPeersWithBlob`) in
  ## order. For each, sends `mkFetchRequest{digest}` on the
  ## existing connection and `await`s the matching
  ## `mkFetchResponse` (correlated via `pendingFetches`). On
  ## BLAKE3-verified hit, writes to the injected `localStoreWriter`
  ## (if any), advertises the digest on the next round, and returns
  ## `some(payload)`. On verification failure (or any I/O / timeout
  ## error) tries the next candidate. Returns `none` on exhaustion.
  let candidates = sortTier2First(client.registry,
                                  client.registry.findPeersWithBlob(digest))
  for candidate in candidates:
    let hasTls = client.tlsConnsByPeerId.hasKey(candidate)
    let hasTcp = client.connections.hasKey(candidate)
    if not hasTls and not hasTcp:
      continue
    # Reuse an existing in-flight request for the same digest so
    # concurrent fetchers share one round-trip per blob.
    var fut: Future[Option[seq[byte]]]
    if client.pendingFetches.hasKey(digest):
      fut = client.pendingFetches[digest]
    else:
      fut = newFuture[Option[seq[byte]]]("peer_cache.requestFetch")
      client.pendingFetches[digest] = fut
      let req = FetchRequest(digest: digest)
      try:
        client.expect(candidate, mkFetchResponse)
        if hasTls:
          let conn = client.tlsConnsByPeerId[candidate]
          await sendFrameTls(conn, mkFetchRequest, encodeFetchRequest(req))
        else:
          let sock = client.connections[candidate]
          await sendFrame(sock, mkFetchRequest, encodeFetchRequest(req))
        inc client.fetchRoundTripCount
      except CatchableError:
        # Send failed — the connection is likely broken; remove the
        # entry and try the next candidate.
        client.completePending(digest, none(seq[byte]))
        continue
    # Wait for completion with a timeout. `withTimeout` returns
    # `false` if the timeout fires first; in that case we treat the
    # peer as unresponsive, complete the future with `none`, and try
    # the next candidate.
    let timeoutOk = await withTimeout(fut, client.fetchTimeoutMs)
    if not timeoutOk:
      client.completePending(digest, none(seq[byte]))
      continue
    let outcome = fut.read()
    if outcome.isNone:
      # Verification failure (marked suspect by readerLoop) or
      # truncated/miss — fall through to the next candidate.
      continue
    let payload = outcome.get()
    if not client.localStoreWriter.isNil:
      client.localStoreWriter(digest, payload)
      client.registry.selfAddBlob(digest)
    return some(payload)
  return none(seq[byte])

proc fetchBlobFrom*(client: PeerCacheClient;
                    peerId: PeerId;
                    endpoint: Endpoint;
                    digest: BlobDigest): Future[Option[seq[byte]]]
                    {.async.} =
  ## Peer-Cache-Scale M4: pool-backed point fetch. Acquires a pooled
  ## outbound connection (opening + handshaking on first use, reusing
  ## an idle one when present), sends `mkFetchRequest{digest}`, reads
  ## the matching `mkFetchResponse`, BLAKE3-verifies, and returns the
  ## bytes (or `none` on truncated / verification failure / I/O).
  ##
  ## The pool is acquired by the caller via `client.pool`; counter
  ## invariants visible to the verification tests:
  ##
  ##   - `totalCheckouts` += 1 per call
  ##   - `totalCheckoutHits` += 1 when the entry was reused
  ##   - `totalEvicted`     += 1 per idle-expired close
  ##   - `totalLruEvicted`  += 1 per cap-driven LRU close
  let conn = await acquireConn(client.pool, peerId, endpoint)
  let startMs = nowMs()
  var result0 = none(seq[byte])
  let req = FetchRequest(digest: digest)
  var ok = true
  try:
    # First-use handshake on a freshly-opened socket. Subsequent
    # acquires for the same `PooledConn` skip this (the pool reused
    # the entry, and `hasHandshaked` is sticky).
    if not conn.hasHandshaked:
      let hello = Hello(
        peerId: client.selfPeerId,
        listenPort: client.listenPort,
        capabilities: 0'u32,
        capTier2: client.capTier2)
      await sendFrame(conn.socket, mkHello, encodeHello(hello))
      # Drain HelloOk + initial Advertise, each through the outbound gate.
      let okFrame = await client.readGatedPlain(conn.socket,
        CallerIdentity(address: endpoint.host),
        OutboundContext(helloPending: true))
      if not okFrame.ok:
        raise newException(PeerCacheClientError, "no admissible HelloOk")
      if okFrame.frame.messageKind == mkHelloOk:
        discard decodeHelloOk(okFrame.frame.payload)
      # Optional advertise frame.
      let advFrame = await client.readGatedPlain(conn.socket,
        CallerIdentity(address: endpoint.host), OutboundContext())
      if not advFrame.ok:
        raise newException(PeerCacheClientError, "no admissible advertisement")
      if advFrame.frame.messageKind == mkAdvertise:
        client.registry.applyAdvertise(peerId,
          decodeAdvertise(advFrame.frame.payload))
      conn.hasHandshaked = true
    await sendFrame(conn.socket, mkFetchRequest, encodeFetchRequest(req))
    inc client.fetchRoundTripCount
    let resp = await client.readGatedPlain(conn.socket,
      CallerIdentity(address: endpoint.host, hostId: peerId),
      OutboundContext(fetchesPending: 1))
    if not resp.ok:
      ok = false
    else:
      let frame = resp.frame
      if frame.messageKind == mkFetchResponse:
        let resp = decodeFetchResponse(frame.payload)
        if not resp.truncated:
          let observed = blake3.digest(resp.payload)
          let expected = bytes(resp.digest)
          if observed == expected:
            result0 = some(resp.payload)
            if not client.localStoreWriter.isNil:
              client.localStoreWriter(digest, resp.payload)
              client.registry.selfAddBlob(digest)
          else:
            client.reportDetection(newEvidenceRecord(ecDetection,
              "peer-cache-content", "blob-digest-mismatch",
              [("peer", $peerId), ("digest", $resp.digest),
               ("observedDigest", $blobDigestFromBytes(observed)),
               ("size", $resp.payload.len)], payload = resp.payload))
            client.markPeerSuspect(peerId, "blob-digest-mismatch",
              "pooled fetch payload does not hash to " & $resp.digest)
  except CatchableError:
    ok = false
  if not ok:
    invalidate(client.pool, conn)
  else:
    releaseConn(client.pool, conn)
  # Latency + metric counters.
  let elapsed = int(nowMs() - startMs)
  if not client.metrics.isNil:
    recordFetchLatency(client.metrics, elapsed)
    if result0.isSome:
      inc client.metrics.fetchHitsPeer
      if client.registry.isPeerTier2(peerId):
        inc client.metrics.fetchHitsTier2
    else:
      inc client.metrics.fetchMissesTotal
  return result0

# ---------------------------------------------------------------------------
# Distributed-Execution M0: peer-addressed requests and the memoization plane.
# ---------------------------------------------------------------------------

proc connectedPeers*(client: PeerCacheClient): seq[PeerId] =
  ## Peers this client currently holds a live connection to (either
  ## transport), in stable lexicographic order.
  for peerId in client.tlsConnsByPeerId.keys:
    result.add(peerId)
  for peerId in client.connections.keys:
    if peerId notin result:
      result.add(peerId)
  result.sort do (a, b: PeerId) -> int:
    cmp($a, $b)

proc isConnected*(client: PeerCacheClient; peerId: PeerId): bool =
  client.tlsConnsByPeerId.hasKey(peerId) or client.connections.hasKey(peerId)

proc sendToPeer(client: PeerCacheClient; peerId: PeerId;
                messageKind: MessageKind;
                payload: seq[byte]): Future[bool] {.async.} =
  ## Writes one frame on the live connection to `peerId`. Returns `false`
  ## (and forgets the connection) when there is none or the write fails.
  try:
    if client.tlsConnsByPeerId.hasKey(peerId):
      await sendFrameTls(client.tlsConnsByPeerId[peerId], messageKind, payload)
      return true
    if client.connections.hasKey(peerId):
      let sock = client.connections[peerId]
      try:
        await sendFrame(sock, messageKind, payload)
        return true
      except CatchableError:
        client.dropConnection(peerId, sock)
        return false
  except CatchableError:
    discard
  return false

proc requestFetchFrom*(client: PeerCacheClient; peerId: PeerId;
                       digest: BlobDigest): Future[Option[seq[byte]]]
                       {.async.} =
  ## Content-plane fetch from ONE named peer — the peer that just vouched
  ## for a selector naming `digest` — rather than from whoever advertises
  ## it. Same verification as `requestFetch` (the reader loop enforces
  ## `BLAKE3-256(payload) == digest` and marks the peer suspect otherwise),
  ## same write-through to `localStoreWriter`.
  var fut: Future[Option[seq[byte]]]
  if client.pendingFetches.hasKey(digest):
    fut = client.pendingFetches[digest]
  else:
    fut = newFuture[Option[seq[byte]]]("peer_cache.requestFetchFrom")
    client.pendingFetches[digest] = fut
    client.expect(peerId, mkFetchResponse)
    let sent = await client.sendToPeer(peerId, mkFetchRequest,
      encodeFetchRequest(FetchRequest(digest: digest)))
    if not sent:
      client.completePending(digest, none(seq[byte]))
      return none(seq[byte])
    inc client.fetchRoundTripCount
  let timeoutOk = await withTimeout(fut, client.fetchTimeoutMs)
  if not timeoutOk:
    client.completePending(digest, none(seq[byte]))
    return none(seq[byte])
  let outcome = fut.read()
  if outcome.isSome and not client.localStoreWriter.isNil:
    client.localStoreWriter(digest, outcome.get())
    client.registry.selfAddBlob(digest)
  return outcome

proc requestSelectorsFrom*(client: PeerCacheClient; peerId: PeerId;
                           weakFingerprint: BlobDigest):
                           Future[Option[seq[MemoSelector]]] {.async.} =
  ## Phase one of the two-phase lookup against one peer:
  ## `mkGetSelectorsRequest{weak}` -> the selectors it holds. `none` means
  ## the peer did not answer (no connection, write failure, timeout);
  ## `some(@[])` is an honest memo miss.
  let key = selectorKey(peerId, weakFingerprint)
  var fut: Future[Option[seq[MemoSelector]]]
  if client.pendingSelectors.hasKey(key):
    fut = client.pendingSelectors[key]
  else:
    fut = newFuture[Option[seq[MemoSelector]]]("peer_cache.requestSelectors")
    client.pendingSelectors[key] = fut
    client.expect(peerId, mkGetSelectorsResponse)
    let sent = await client.sendToPeer(peerId, mkGetSelectorsRequest,
      encodeGetSelectorsRequest(
        GetSelectorsRequest(weakFingerprint: weakFingerprint)))
    if not sent:
      client.completeSelectors(key, none(seq[MemoSelector]))
      return none(seq[MemoSelector])
    inc client.memoRoundTripCount
  let timeoutOk = await withTimeout(fut, client.fetchTimeoutMs)
  if not timeoutOk:
    client.completeSelectors(key, none(seq[MemoSelector]))
    return none(seq[MemoSelector])
  return fut.read()

proc requestSelectors*(client: PeerCacheClient;
                       weakFingerprint: BlobDigest): Future[seq[PeerSelector]]
                       {.async.} =
  ## Phase one across the fleet. Asks, in parallel, every connected peer
  ## whose advertisement carries `memoAdvertKey(weak)`; when none does, asks
  ## up to `maxSelectorFanout` connected peers directly, because an
  ## advertisement can lag a publish by one refresh interval and a memo miss
  ## reply is cheap. Returns every (peer, selector) pair, de-duplicated,
  ## advertised peers first.
  var candidates: seq[PeerId] = @[]
  for peerId in sortTier2First(client.registry,
      client.registry.findPeersWithBlob(memoAdvertKey(weakFingerprint))):
    if client.isConnected(peerId):
      candidates.add(peerId)
  if candidates.len == 0:
    let fanout =
      if client.maxSelectorFanout > 0: client.maxSelectorFanout
      else: DefaultSelectorFanout
    for peerId in client.connectedPeers():
      if candidates.len >= fanout:
        break
      candidates.add(peerId)
  var futures: seq[Future[Option[seq[MemoSelector]]]] = @[]
  for peerId in candidates:
    futures.add(client.requestSelectorsFrom(peerId, weakFingerprint))
  for i, fut in futures:
    let answer = await fut
    if answer.isNone:
      continue
    for sel in answer.get():
      var dup = false
      for existing in result:
        if existing.peerId == candidates[i] and existing.selector == sel:
          dup = true
          break
      if not dup:
        result.add(PeerSelector(peerId: candidates[i], selector: sel))

proc requestMemoEntryFrom*(client: PeerCacheClient; peerId: PeerId;
                           weakFingerprint, strongFingerprint: BlobDigest):
                           Future[Option[seq[byte]]] {.async.} =
  ## Phase two against the peer that offered the selector:
  ## `mkGetActionRecordRequest{weak, strong}` -> the encoded memo entry, or
  ## `none` (not found, no answer). The bytes are NOT trusted here; the
  ## caller decodes them and checks they describe the selector it asked for.
  let key = memoEntryKey(peerId, weakFingerprint, strongFingerprint)
  var fut: Future[Option[seq[byte]]]
  if client.pendingMemoEntries.hasKey(key):
    fut = client.pendingMemoEntries[key]
  else:
    fut = newFuture[Option[seq[byte]]]("peer_cache.requestMemoEntry")
    client.pendingMemoEntries[key] = fut
    client.expect(peerId, mkGetActionRecordResponse)
    let sent = await client.sendToPeer(peerId, mkGetActionRecordRequest,
      encodeGetActionRecordRequest(GetActionRecordRequest(
        weakFingerprint: weakFingerprint,
        strongFingerprint: strongFingerprint)))
    if not sent:
      client.completeMemoEntry(key, none(seq[byte]))
      return none(seq[byte])
    inc client.memoRoundTripCount
  let timeoutOk = await withTimeout(fut, client.fetchTimeoutMs)
  if not timeoutOk:
    client.completeMemoEntry(key, none(seq[byte]))
    return none(seq[byte])
  return fut.read()

proc requestReachGoal*(client: PeerCacheClient; peerId: PeerId;
                       payload: seq[byte];
                       hydration = HydrationSet();
                       timeoutMs = 600_000): Future[GoalReply] {.async.} =
  ## Sends an encoded `ReachGoalRequest` to worker `peerId` over the live
  ## connection — the one THIS node opened — and waits for its response or
  ## the receiver's refusal. While it is outstanding the worker may fetch
  ## exactly the digests in `hydration` back over that connection (the
  ## descriptor, the snapshot manifest, the snapshot's blobs): the worker
  ## never dials this node (FLOW-1, threat model D4).
  if client.pendingGoals.hasKey(peerId):
    raise newException(PeerCacheClientError,
      "a ReachGoal to this worker is already outstanding")
  let fut = newFuture[GoalReply]("peer_cache.requestReachGoal")
  client.pendingGoals[peerId] = fut
  if hydration.digests.len > 0:
    client.hydration[peerId] = hydration
  try:
    if not await client.sendToPeer(peerId, mkReachGoalRequest, payload):
      client.completeGoal(peerId, GoalReply(kind: grkNoAnswer))
    elif not await withTimeout(fut, timeoutMs):
      client.completeGoal(peerId, GoalReply(kind: grkNoAnswer))
  finally:
    client.hydration.del(peerId)
  return fut.read()

proc requestAdvertisementRefresh*(client: PeerCacheClient):
    Future[int] {.async.} =
  ## Asks every connected peer for a fresh advertisement snapshot
  ## (`mkWant{wkSnapshotRequest}`, `Peer-Cache.md` §"Advertisement index").
  ## The snapshot is applied by the reader loop when it arrives. Returns how
  ## many peers were asked. A long-lived membership loop calls this on its
  ## advertise interval so blobs a peer published after the handshake
  ## become findable.
  for peerId in client.connectedPeers():
    if await client.sendToPeer(peerId, mkWant,
        encodeWant(Want(kind: wkSnapshotRequest, digests: @[]))):
      inc result

proc connectKnownPeers*(client: PeerCacheClient): Future[int] {.async.} =
  ## Dials every peer the registry knows about (seed, multicast or SWIM
  ## discovery all land there) but this client holds no connection to, and
  ## every configured seed that is not connected. Returns the number of
  ## dials attempted. Discovery fills the registry; only a connection makes
  ## a peer fetchable, so a membership loop runs this periodically.
  client.running = true
  var targets: seq[Endpoint] = @[]
  if client.dialDiscovered:
    for peerId, entry in client.registry.entries.pairs:
      if peerId == client.selfPeerId or client.isConnected(peerId) or
          peerId in client.revokedPeers:
        continue
      if entry.endpoint.port == Port(0):
        continue
      targets.add(entry.endpoint)
    for endpoint in client.discoveredEndpoints:
      var known = false
      for peerId, entry in client.registry.entries.pairs:
        if entry.endpoint == endpoint and client.isConnected(peerId):
          known = true
          break
      if not known and endpoint notin targets:
        targets.add(endpoint)
  for seed in client.seedPeers:
    var known = false
    for peerId, entry in client.registry.entries.pairs:
      if entry.endpoint == seed and client.isConnected(peerId):
        known = true
        break
    if not known and seed notin targets:
      targets.add(seed)
  var futures: seq[Future[void]] = @[]
  for endpoint in targets:
    futures.add(dialPeer(client, endpoint))
  if futures.len > 0:
    await all(futures)
  targets.len

proc abandonAfterFork*(client: PeerCacheClient) =
  ## Distributed-Execution M0: the forked-child counterpart of `stop` (see
  ## `server.abandonAfterFork`). Closes the child's copies of every
  ## descriptor raw, sends nothing (the connections belong to the parent,
  ## which keeps using them) and leaves the client unusable.
  client.running = false
  client.multicastRunning = false
  when defined(posix):
    if not client.multicastSocket.isNil:
      discard posix.close(cint(client.multicastSocket.getFd()))
    for _, sock in client.connections.pairs:
      discard posix.close(cint(sock.getFd()))
    for _, lst in client.pool.conns.pairs:
      for c in lst:
        if c.valid:
          discard posix.close(cint(c.socket.getFd()))
  # TLS tunnels wrap sockets the parent owns as well; drop the references
  # without running a close-notify through the inherited dispatcher.
  client.multicastSocket = nil
  client.connections.clear()
  client.tlsConnsByPeerId.clear()
  client.pool.conns.clear()

proc stop*(client: PeerCacheClient) {.async.} =
  ## Sends Goodbye to each connected peer and closes the connections.
  ## Also stops any in-flight multicast broadcast loop.
  client.running = false
  client.multicastRunning = false
  if not client.multicastSocket.isNil:
    try: client.multicastSocket.close() except CatchableError: discard
    client.multicastSocket = nil
  # Snapshot and clear the tables BEFORE awaiting anything: closing a
  # connection ends its reader loop, which forgets the connection
  # (`dropConnection`), and that must not mutate a table being iterated.
  var plain: seq[AsyncSocket] = @[]
  for _, sock in client.connections.pairs:
    plain.add(sock)
  client.connections.clear()
  var tunnels: seq[TlsConn] = @[]
  for _, conn in client.tlsConnsByPeerId.pairs:
    tunnels.add(conn)
  client.tlsConnsByPeerId.clear()
  for sock in plain:
    try:
      await sendFrame(sock, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError:
      discard
    try: sock.close() except CatchableError: discard
  for conn in tunnels:
    try:
      await sendFrameTls(conn, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError:
      discard
    try: await tls.close(conn) except CatchableError: discard
  closeAll(client.pool)

# ---------------------------------------------------------------------------
# Peer-Cache M2: multicast broadcast loop.
# ---------------------------------------------------------------------------

proc multicastBroadcastLoop(client: PeerCacheClient;
                            group: MulticastGroup;
                            sock: AsyncSocket): Future[void] {.async.} =
  ## Background loop: repeatedly send the peer's `mkHello` to the
  ## multicast group. Runs while `client.multicastRunning` is true.
  ## Errors on send are swallowed and the loop continues — a transient
  ## network glitch shouldn't terminate discovery.
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32,
    capTier2: client.capTier2)
  let packet = encodeHelloPacket(hello)
  while client.multicastRunning:
    try:
      sendMulticastPacket(sock, group, packet)
    except CatchableError:
      # Drop send failures silently; M2 verification tests assert the
      # discovery outcome, not error reporting on individual sends.
      discard
    let interval =
      if client.advertiseIntervalMs > 0: client.advertiseIntervalMs
      else: 5_000
    await sleepAsync(interval)

proc multicastBroadcast*(client: PeerCacheClient;
                        group: MulticastGroup) =
  ## Peer-Cache M2: start a background loop that re-broadcasts this
  ## peer's `mkHello` to the configured multicast group at
  ## `client.advertiseIntervalMs` cadence. The loop continues until
  ## `client.stop()` is called.
  ##
  ## Sends one immediate hello before yielding to the dispatcher, so
  ## the M2 verification test sees discovery progress on the first
  ## tick rather than waiting a full advertise interval. The
  ## subsequent loop runs via `asyncCheck` and is owned by the
  ## dispatcher.
  if client.multicastRunning:
    return
  client.multicastRunning = true
  let sock = newMulticastSenderSocket(group)
  client.multicastSocket = sock
  asyncCheck multicastBroadcastLoop(client, group, sock)

proc closePeer*(client: PeerCacheClient; peerId: PeerId) {.async.} =
  ## Ends the connection to `peerId` (Goodbye, close); a membership round
  ## re-dials it unless it is revoked.
  if client.tlsConnsByPeerId.hasKey(peerId):
    let conn = client.tlsConnsByPeerId[peerId]
    client.tlsConnsByPeerId.del(peerId)
    client.failPendingFor(peerId)
    try: await sendFrameTls(conn, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError: discard
    try: await tls.close(conn) except CatchableError: discard
  if client.connections.hasKey(peerId):
    let sock = client.connections[peerId]
    client.connections.del(peerId)
    client.failPendingFor(peerId)
    try: await sendFrame(sock, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError: discard
    try: sock.close() except CatchableError: discard

proc rotateExpiringConnections*(client: PeerCacheClient;
                                marginSeconds = 300'i64): Future[int]
                                {.async.} =
  ## Threat model G15: a connection never outlives a leaf. Closes every
  ## connection whose own presented leaf, or the peer's proved leaf, has
  ## less than `marginSeconds` left — the next membership round re-dials it
  ## with the current leaf, before the peer's gate has to end it. Also
  ## drops connections to revoked peers. Returns how many it closed.
  let now = client.nowMsC() div 1000
  var victims: seq[PeerId] = @[]
  for peerId in client.connectedPeers():
    if peerId in client.revokedPeers:
      victims.add(peerId)
      continue
    let mine = client.ownLeafNotAfter.getOrDefault(peerId, 0)
    let theirs = client.peerOf(peerId).leafNotAfter
    if (mine > 0 and mine - now < marginSeconds) or
        (theirs > 0 and theirs - now < marginSeconds):
      victims.add(peerId)
  for peerId in victims:
    await client.closePeer(peerId)
  victims.len
