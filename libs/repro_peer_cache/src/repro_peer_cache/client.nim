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
import ./codec
import ./memo_store
import ./metrics
import ./multicast
import ./pki
import ./registry
import ./server  # for inAllowlist + CidrV4
import ./tls
import ./types

export metrics

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
    maxSelectorFanout: DefaultSelectorFanout)

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

proc readFrameBytes(sock: AsyncSocket): Future[seq[byte]] {.async.} =
  let header = await sock.recv(8)
  if header.len == 0:
    return @[]
  if header.len != 8:
    raise newException(PeerCacheClientError,
      "short read on peer-cache frame header: " & $header.len)
  var bytes = newSeq[byte](8)
  for i in 0 ..< 8:
    bytes[i] = byte(ord(header[i]))
  var payloadLen: uint32 = 0
  for i in 0 ..< 4:
    payloadLen = payloadLen or (uint32(bytes[4 + i]) shl uint32(i * 8))
  if payloadLen > 0'u32:
    let payload = await sock.recv(int(payloadLen))
    if payload.len != int(payloadLen):
      raise newException(PeerCacheClientError,
        "short read on peer-cache frame payload: expected " &
        $payloadLen & ", got " & $payload.len)
    let prefix = bytes.len
    bytes.setLen(prefix + payload.len)
    for i in 0 ..< payload.len:
      bytes[prefix + i] = byte(ord(payload[i]))
  return bytes

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

proc handshakePeer(client: PeerCacheClient;
                   sock: AsyncSocket;
                   endpoint: Endpoint): Future[PeerId] {.async.} =
  ## Sends Hello, waits for HelloOk + initial Advertise snapshot,
  ## registers the remote peer in the registry. Returns the
  ## remote peer ID. Used on the `tmCidr` path; the TLS path uses
  ## `handshakePeerTls` below.
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32,
    capTier2: client.capTier2)
  await sendFrame(sock, mkHello, encodeHello(hello))

  let helloOkBytes = await readFrameBytes(sock)
  if helloOkBytes.len == 0:
    raise newException(PeerCacheClientError,
      "peer closed connection before HelloOk: " & endpoint.host & ":" &
      $endpoint.port.int)
  let helloOkFrame = decodeFrame(helloOkBytes)
  if helloOkFrame.messageKind != mkHelloOk:
    raise newException(PeerCacheClientError,
      "expected mkHelloOk, got " & $helloOkFrame.messageKind)
  let helloOk = decodeHelloOk(helloOkFrame.payload)
  client.registry.addPeer(helloOk.peerId, endpoint)
  client.registry.setPeerTier2(helloOk.peerId, helloOk.capTier2)

  # Send our initial advertise snapshot.
  let snapshot = client.registry.snapshotFor(helloOk.peerId)
  await sendFrame(sock, mkAdvertise, encodeAdvertise(snapshot))
  if not client.metrics.isNil:
    inc client.metrics.advertisementsSentTotal

  # Read the server's initial advertise snapshot.
  let advBytes = await readFrameBytes(sock)
  if advBytes.len > 0:
    let advFrame = decodeFrame(advBytes)
    if advFrame.messageKind == mkAdvertise:
      let ad = decodeAdvertise(advFrame.payload)
      client.registry.applyAdvertise(helloOk.peerId, ad)

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
    # the receiver, the payload was supplied by the peer.
    client.registry.markSuspect(peerId)
    inc client.suspectMarks
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

proc readerLoop(client: PeerCacheClient; sock: AsyncSocket;
                peerId: PeerId) {.async.} =
  ## After the handshake, keep reading framed messages — applying
  ## advertise updates, responding to ping, completing fetch-response
  ## futures (M1).
  try:
    while client.running:
      let frameBytes = await readFrameBytes(sock)
      if frameBytes.len == 0:
        break
      let frame = decodeFrame(frameBytes)
      case frame.messageKind
      of mkAdvertise:
        client.registry.applyAdvertise(peerId,
          decodeAdvertise(frame.payload))
      of mkAdvertiseV2:
        let ad = decodeAdvertiseV2(frame.payload)
        # Peer-Cache-BearSSL M3: signed-advertisement enforcement when
        # `tmTls`. The pubkey was bound to `peerId` at TLS-handshake
        # time via `peerKeyByPeerId`.
        if client.trustMode == tmTls and ad.signature.len > 0:
          var verified = false
          if ad.signature.len == 64 and
             client.peerKeyByPeerId.hasKey(peerId):
            var sig: SignatureBytes
            for i in 0 ..< 64:
              sig[i] = ad.signature[i]
            let msg = canonicaliseAdvertiseForSigning(peerId, ad)
            verified = verifySignature(
              client.peerKeyByPeerId[peerId], msg, sig)
          if not verified:
            if peerId notin client.signatureRejectedPeers:
              client.signatureRejectedPeers.incl(peerId)
              inc client.signatureRejectedCount
            continue
        client.registry.applyAdvertiseV2(peerId, ad)
      of mkPing:
        await sendFrame(sock, mkPong, encodePong(Pong()))
      of mkPong:
        client.registry.updateLastSeen(peerId)
      of mkGoodbye:
        break
      of mkFetchResponse:
        # M1: correlate the digest with an outstanding `requestFetch`
        # call, BLAKE3-verify the payload, mark the peer suspect on
        # mismatch, and complete the future with `some(payload)` or
        # `none`. The spec's fetch semantics
        # (`Peer-Cache.md` §"Fetch semantics" step 3) live here.
        client.handleContentReply(peerId, decodeFetchResponse(frame.payload))
      of mkGetSelectorsResponse, mkGetActionRecordResponse:
        client.handleMemoReply(peerId, frame)
      of mkGetSelectorsRequest, mkGetActionRecordRequest:
        # Requests travel client -> server; a server never asks.
        discard
      of mkWant, mkHello, mkHelloOk, mkFetchRequest:
        # The client is a fetch *requester*; servers send these.
        # Discard silently — the spec lets either side dispatch any
        # message, so a benign cross-direction send isn't an error.
        discard
      of mkSwimProbe, mkSwimAck, mkSwimProbeReq, mkSwimProbeAckIndirect,
         mkSwimSuspect, mkSwimConfirm, mkSwimRefute:
        # Peer-Cache-Scale M0: SWIM frames don't ride the long-lived
        # peer-cache connection — they have their own transport. If
        # one shows up here, drop it.
        discard
  except CatchableError:
    discard
  client.dropConnection(peerId, sock)

# ---------------------------------------------------------------------------
# Peer-Cache-BearSSL M3: TLS-side frame I/O + handshake + reader loop.
# ---------------------------------------------------------------------------

proc readFrameBytesTls(conn: TlsConn): Future[seq[byte]] {.async.} =
  var header: string = ""
  while header.len < 8:
    let chunk = await tls.recv(conn, 8 - header.len)
    if chunk.len == 0:
      return @[]
    header.add(chunk)
  var bytes = newSeq[byte](8)
  for i in 0 ..< 8:
    bytes[i] = byte(ord(header[i]))
  var payloadLen: uint32 = 0
  for i in 0 ..< 4:
    payloadLen = payloadLen or (uint32(bytes[4 + i]) shl uint32(i * 8))
  if payloadLen > 0'u32:
    var payload: string = ""
    while payload.len < int(payloadLen):
      let chunk = await tls.recv(conn, int(payloadLen) - payload.len)
      if chunk.len == 0:
        raise newException(PeerCacheClientError,
          "short read on TLS peer-cache frame payload: expected " &
          $payloadLen & ", got " & $payload.len)
      payload.add(chunk)
    let prefix = bytes.len
    bytes.setLen(prefix + payload.len)
    for i in 0 ..< payload.len:
      bytes[prefix + i] = byte(ord(payload[i]))
  return bytes

proc sendFrameTls(conn: TlsConn; messageKind: MessageKind;
                  payload: seq[byte]): Future[void] {.async.} =
  let bytes = encodeFrame(messageKind, payload)
  await tls.send(conn, bytes)

proc handshakePeerTls(client: PeerCacheClient;
                      conn: TlsConn;
                      endpoint: Endpoint): Future[PeerId] {.async.} =
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32,
    capTier2: client.capTier2)
  await sendFrameTls(conn, mkHello, encodeHello(hello))
  let helloOkBytes = await readFrameBytesTls(conn)
  if helloOkBytes.len == 0:
    raise newException(PeerCacheClientError,
      "peer closed TLS tunnel before HelloOk: " & endpoint.host & ":" &
      $endpoint.port.int)
  let helloOkFrame = decodeFrame(helloOkBytes)
  if helloOkFrame.messageKind != mkHelloOk:
    raise newException(PeerCacheClientError,
      "expected mkHelloOk over TLS, got " & $helloOkFrame.messageKind)
  let helloOk = decodeHelloOk(helloOkFrame.payload)
  client.registry.addPeer(helloOk.peerId, endpoint)
  client.registry.setPeerTier2(helloOk.peerId, helloOk.capTier2)
  # Bind the validated peer cert pubkey to the registered peer ID so
  # subsequent signed advertisements verify against the TLS-anchored
  # identity (not a self-asserted one).
  let pkOpt = remotePublicKey(conn)
  if pkOpt.isSome:
    client.peerKeyByPeerId[helloOk.peerId] = pkOpt.get()
  let snapshot = client.registry.snapshotFor(helloOk.peerId)
  await sendFrameTls(conn, mkAdvertise, encodeAdvertise(snapshot))
  if not client.metrics.isNil:
    inc client.metrics.advertisementsSentTotal
  let advBytes = await readFrameBytesTls(conn)
  if advBytes.len > 0:
    let advFrame = decodeFrame(advBytes)
    if advFrame.messageKind == mkAdvertise:
      let ad = decodeAdvertise(advFrame.payload)
      client.registry.applyAdvertise(helloOk.peerId, ad)
  return helloOk.peerId

proc readerLoopTls(client: PeerCacheClient; conn: TlsConn;
                   peerId: PeerId) {.async.} =
  try:
    while client.running:
      let frameBytes = await readFrameBytesTls(conn)
      if frameBytes.len == 0:
        break
      let frame = decodeFrame(frameBytes)
      case frame.messageKind
      of mkAdvertise:
        client.registry.applyAdvertise(peerId,
          decodeAdvertise(frame.payload))
      of mkAdvertiseV2:
        let ad = decodeAdvertiseV2(frame.payload)
        if client.trustMode == tmTls and ad.signature.len > 0:
          var verified = false
          if ad.signature.len == 64 and
             client.peerKeyByPeerId.hasKey(peerId):
            var sig: SignatureBytes
            for i in 0 ..< 64:
              sig[i] = ad.signature[i]
            let msg = canonicaliseAdvertiseForSigning(peerId, ad)
            verified = verifySignature(
              client.peerKeyByPeerId[peerId], msg, sig)
          if not verified:
            if peerId notin client.signatureRejectedPeers:
              client.signatureRejectedPeers.incl(peerId)
              inc client.signatureRejectedCount
            continue
        client.registry.applyAdvertiseV2(peerId, ad)
      of mkPing:
        await sendFrameTls(conn, mkPong, encodePong(Pong()))
      of mkPong:
        client.registry.updateLastSeen(peerId)
      of mkGoodbye:
        break
      of mkFetchResponse:
        client.handleContentReply(peerId, decodeFetchResponse(frame.payload))
      of mkGetSelectorsResponse, mkGetActionRecordResponse:
        client.handleMemoReply(peerId, frame)
      of mkGetSelectorsRequest, mkGetActionRecordRequest:
        discard
      of mkWant, mkHello, mkHelloOk, mkFetchRequest,
         mkSwimProbe, mkSwimAck, mkSwimProbeReq, mkSwimProbeAckIndirect,
         mkSwimSuspect, mkSwimConfirm, mkSwimRefute:
        discard
  except CatchableError:
    discard
  if client.tlsConnsByPeerId.hasKey(peerId) and
      client.tlsConnsByPeerId[peerId] == conn:
    client.tlsConnsByPeerId.del(peerId)

proc dialPeer(client: PeerCacheClient;
              endpoint: Endpoint): Future[void] {.async.} =
  var sock = newAsyncSocket()
  try:
    await sock.connect(endpoint.host, endpoint.port)
    # Peer-Cache-BearSSL M3: when `tmTls` is active, run the TLS
    # handshake before the Hello/HelloOk flow. On failure, close +
    # count + return.
    if client.trustMode == tmTls:
      let connOpt = await wrapClientSocket(
        sock, endpoint.host, client.ourCert, client.trustAnchorSet)
      if connOpt.isNone:
        inc client.tlsHandshakeRejectedCount
        try: sock.close() except CatchableError: discard
        return
      let conn = connOpt.get()
      let peerId = await handshakePeerTls(client, conn, endpoint)
      client.tlsConnsByPeerId[peerId] = conn
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
                             payload: seq[byte]): Future[void] {.async.} =
  ## Test-only seam: encode + send `messageKind` with the supplied
  ## payload bytes over the existing connection to `targetPeerId`.
  ## Routes through whichever transport (TCP or TLS) is live for the
  ## remote peer.
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
    let sig = signMessage(client.ourCert.keypair, msg)
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
      # Drain HelloOk + initial Advertise. Best-effort.
      let okFrame = await readFrameBytes(conn.socket)
      if okFrame.len > 0:
        let decoded = decodeFrame(okFrame)
        if decoded.messageKind == mkHelloOk:
          discard decodeHelloOk(decoded.payload)
      # Optional advertise frame.
      let advFrame = await readFrameBytes(conn.socket)
      if advFrame.len > 0:
        let decoded = decodeFrame(advFrame)
        if decoded.messageKind == mkAdvertise:
          client.registry.applyAdvertise(peerId,
            decodeAdvertise(decoded.payload))
      conn.hasHandshaked = true
    await sendFrame(conn.socket, mkFetchRequest, encodeFetchRequest(req))
    inc client.fetchRoundTripCount
    let respBytes = await readFrameBytes(conn.socket)
    if respBytes.len == 0:
      ok = false
    else:
      let frame = decodeFrame(respBytes)
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
  for peerId, entry in client.registry.entries.pairs:
    if peerId == client.selfPeerId or client.isConnected(peerId):
      continue
    if entry.endpoint.port == Port(0):
      continue
    targets.add(entry.endpoint)
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
