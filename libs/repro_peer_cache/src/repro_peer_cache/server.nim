## Peer-cache TCP server — Peer-Cache M0, hardened as a Boundary receiver in
## Distributed-Execution M7.
##
## `asyncnet` + `asyncdispatch` based server. On accept, the remote address
## is checked against the configured CIDR allowlist (defence in depth only:
## network adjacency is never authorization), the TLS handshake runs under
## `tmTls`, and then every frame passes the receiver gate (`boundary.nim`)
## before it is decoded: size from the header, protocol order, the caller's
## roles on THIS message, and its rate. See `serveConnection` below.
##
## Messages served: identity proof, Hello (bound to the verified identity
## under `tmTls`), advertisements and refresh requests, keep-alives,
## content-plane fetches (`mkFetchRequest`), memoization-plane queries
## (`mkGetSelectorsRequest` / `mkGetActionRecordRequest`), and — on a node
## holding the worker role — `mkReachGoalRequest` through `workerHandler`.

import std/[asyncdispatch, asyncnet, nativesockets, net, options, sets,
            strutils, tables, times]
when defined(posix):
  from std/posix import nil

import blake3

import ./auth
import ./boundary
import ./codec
import ./evidence_record
import ./identity
import ./metrics
import ./multicast
import ./pki
import ./registry
import ./tls
import ./types

export metrics
export boundary
export identity

type
  CidrV4* = object
    ## Simple IPv4 CIDR. `base` is the masked network address; `mask`
    ## is the prefix mask (most-significant bits set).
    base*: uint32
    mask*: uint32

  PeerCacheServer* = ref object
    selfPeerId*: PeerId
    listenAddr*: string
    listenPort*: Port
    registry*: PeerRegistry
    allowlist*: seq[CidrV4]
    maxBlobBytes*: uint64
    localStoreReader*: LocalStoreReader
      ## Peer-Cache M1: optional injected reader for `mkFetchRequest`.
      ## When `nil`, the server falls back to the M0 stub behaviour
      ## (responds with `truncated:true, payload:@[]`).
    responseInterceptor*: ResponseInterceptor
      ## Peer-Cache M1: optional test seam. When non-nil, the proc is
      ## called on the `mkFetchResponse` payload bytes just before
      ## encoding. Production code leaves this `nil`.
    memoSelectorReader*: MemoSelectorReader
      ## Distributed-Execution M0: answers `mkGetSelectorsRequest` from the
      ## local two-phase memo store. `nil` answers every request with an
      ## empty selector list (a memo miss), which is what a peer that only
      ## serves content blobs honestly knows.
    memoEntryReader*: MemoEntryReader
      ## Distributed-Execution M0: answers `mkGetActionRecordRequest`.
      ## `nil` answers `found = false`.
    memoRequestsServed*: int
      ## Instrumentation: memo requests (selector + record) answered.
    listener: AsyncSocket
    running: bool
    activeConnections: seq[AsyncSocket]
      ## Tracked so `stop()` can drain them cleanly. Closed connections
      ## are pruned lazily on next start/stop pass.
    started*: bool
      ## Peer-Cache M2: flips to `true` after `start()` has both opened
      ## the TCP listener and spawned the accept loop. The CLI
      ## verification test asserts this becomes `true` after
      ## `--peer-cache=lan://...` wiring runs.
    multicastSocket: AsyncSocket
      ## Peer-Cache M2: the UDP multicast receiver socket created by
      ## `multicastListen`. Held so `stop()` can close it cleanly.
    multicastRunning: bool
    multicastWarnedPeers: HashSet[PeerId]
      ## Peer-Cache M2: peers whose off-CIDR `mkHello` we've already
      ## warned about in this session. The warning is logged
      ## once-per-peer-id-per-session per the milestone spec; this
      ## set is the dedup index.
    droppedAnnounceCount*: int
      ## Peer-Cache M2: incremented each time the multicast receiver
      ## drops an announcement because its source IP is outside the
      ## CIDR allowlist. Test instrumentation: the M2 CIDR-allowlist
      ## verification test asserts this hits exactly 1 (and the
      ## warning fires once) after a single off-CIDR send.
    warningEmitCount*: int
      ## Peer-Cache M2: incremented each time the multicast receiver
      ## emits a first-time off-CIDR warning. Tracks the "warning is
      ## logged exactly once per peer ID per session" assertion in
      ## the M2 CIDR-allowlist test independent of `stderr` capture.
    diagnosticLog*: proc(line: string) {.gcsafe, closure.}
      ## Where the server's operator diagnostics go (today the first-time
      ## off-CIDR multicast warning). nil = stderr. A node hosted by
      ## `repro-daemon` routes them to the daemon log, because the daemon's
      ## stdout and stderr go to /dev/null.
    capTier2*: bool
      ## Peer-Cache-Scale M2: this server's tier-2 capability. Echoed
      ## back to peers in `mkHelloOk` so clients can record us as a
      ## tier-2 candidate.
    trustMode*: TrustMode
      ## Peer-Cache-BearSSL M3: trust gating. `tmCidr` preserves the
      ## M0-M2 path; `tmTls` wraps every accept with a BearSSL TLS 1.2
      ## mutual-auth handshake (see `tls.nim`).
    ourCert*: CertAndKey
      ## Peer-Cache-BearSSL M3: this server's own X.509 cert + key.
      ## Only used when `trustMode == tmTls`.
    trustAnchorSet*: TrustAnchorSet
      ## Peer-Cache-BearSSL M3: parsed directory of allowed-peer certs.
      ## Only used when `trustMode == tmTls`.
    peerKeyByPeerId*: Table[PeerId, PublicKeyBytes]
      ## Peer-Cache-BearSSL M3: remembers the validated TLS client-cert
      ## pubkey per authenticated peer ID. Used to verify subsequent
      ## `mkAdvertiseV2` signatures.
    signatureRejectedCount*: int
      ## Peer-Cache-Scale M3: number of signed `mkAdvertiseV2` frames
      ## that failed signature verification. Bumped exactly once per
      ## tampered frame on the receive path.
    signatureRejectedPeers: HashSet[PeerId]
      ## Per-session dedup index: each peer ID enters once after its
      ## first rejected frame so the "log once per peer per session"
      ## requirement holds independently of stderr capture.
    tlsHandshakeRejectedCount*: int
      ## Peer-Cache-BearSSL M3: number of TLS handshake attempts this
      ## server rejected (peer cert not in anchors, expired, malformed
      ## ClientHello, TLS-level I/O error, timeout).
    metrics*: PeerCacheMetrics
      ## Peer-Cache-Scale M4: shared observability shell. Increment
      ## sites at fetch / advertise / signature paths are no-ops when
      ## nil. Provided by `newPeerCacheServer` or set after the fact
      ## by the daemon's `--metrics-addr` wiring.
    gate*: ReceiverGate
      ## Distributed-Execution M7: the FLOW-2/FLOW-4 receiver gate every
      ## frame passes (`boundary.nim`). Never nil after construction.
    requireShortLivedLeaves*: bool
      ## Distributed-Execution M7 (CRED-1): refuse legacy long-lived
      ## identities; only host-CA leaves of at most an hour are accepted.
      ## Set by every node the CLI and the daemon start.
    leafProvider*: LeafProvider
      ## Distributed-Execution M7: the current short-lived leaf, presented
      ## on every TLS accept and in `mkIdentityProof`. When nil, `ourCert`
      ## is presented (the Peer-Cache-BearSSL M3/M4 shape).
    workerHandler*: WorkerHandler
      ## Distributed-Execution M7: the worker role's receiver for
      ## `mkReachGoalRequest`, called only after the gate admitted the
      ## frame. Nil on a node without the worker role (the gate then
      ## refuses `ReachGoal` itself: `AuthorizationPolicy.servesWorker`).
    reporter*: DetectionReporter
      ## Where the server's own detections go (a hydration reply that does
      ## not hash to its digest). Nil = counted only.
    clock*: proc(): int64 {.gcsafe, closure.}
      ## Unix milliseconds. Nil = the system clock. A test seam, so a test
      ## can show a connection end when its caller's leaf expires without
      ## waiting an hour (threat model G15).
    discoveredEndpoints*: seq[Endpoint]
      ## Endpoints announced over opt-in multicast on a TLS node. Never
      ## dialled here (an announcement is unauthenticated bytes): the
      ## node's client dials them through the TLS handshake and the
      ## outbound gate (threat model G29). Bounded.
    inboundAuthenticated*: CountTable[(PeerId, LeafRole)]
      ## Instrumentation: inbound connections whose identity proof verified,
      ## per authenticated host and leaf role. A node can show from its own side that a
      ## host never opened a connection to it (FLOW-1, threat model D4: a
      ## worker — its daemon or any build it hosts — never dials a
      ## requester or orchestrator).

  PeerCacheServerError* = object of CatchableError

  HydrationChannel* = ref object
    ## Distributed-Execution M7 (FLOW-1, threat model D4): the worker side
    ## of a `ReachGoal`'s connection. The worker fetches the graph
    ## descriptor, the snapshot manifest and its blobs BACK over the
    ## connection its caller opened — it never dials the caller. The caller
    ## answers only for the digests it published for that goal
    ## (`client.HydrationSet`), and every answer is BLAKE3-verified here.
    send: proc(kind: MessageKind; payload: seq[byte]): Future[void]
      {.gcsafe, closure.}
    pending: Table[BlobDigest, Future[Option[seq[byte]]]]
    closed*: bool
    caller*: CallerIdentity
    mismatches*: int
    server: PeerCacheServer

  WorkerHandler* = proc(caller: CallerIdentity; frame: Frame;
                        hydration: HydrationChannel):
    Future[tuple[kind: MessageKind; payload: seq[byte]]] {.gcsafe, closure.}
    ## Distributed-Execution M7: answers an admitted worker-vocabulary
    ## frame. The caller identity is the one the RECEIVER verified;
    ## `hydration` reaches back to the caller over its own connection.

const
  MaxCapturedRefusalBytes = 64 * 1024
    ## How much of a refused frame's payload is read for the audit record
    ## when the frame is over its size budget (EVID-1; threat model G19).
  MaxDiscoveredEndpoints = 256
  DefaultHydrationTimeoutMs* = 60_000

proc nowMs*(server: PeerCacheServer): int64 =
  if server.clock.isNil: int64(epochTime() * 1000.0)
  else: server.clock()

proc pendingCount*(ch: HydrationChannel): int =
  if ch.isNil: 0 else: ch.pending.len

proc fetch*(ch: HydrationChannel; digest: BlobDigest;
            timeoutMs = DefaultHydrationTimeoutMs): Future[Option[seq[byte]]]
            {.async.} =
  ## Asks the caller for `digest` over its own connection; `none` when the
  ## caller does not answer, refuses, or answers bytes that do not hash to
  ## `digest`.
  if ch.isNil or ch.closed:
    return none(seq[byte])
  var fut: Future[Option[seq[byte]]]
  if ch.pending.hasKey(digest):
    fut = ch.pending[digest]
  else:
    fut = newFuture[Option[seq[byte]]]("peer_cache.hydration")
    ch.pending[digest] = fut
    try:
      await ch.send(mkFetchRequest, encodeFetchRequest(FetchRequest(
        digest: digest)))
    except CatchableError:
      ch.pending.del(digest)
      return none(seq[byte])
  if not await withTimeout(fut, timeoutMs):
    if ch.pending.hasKey(digest) and ch.pending[digest] == fut:
      ch.pending.del(digest)
    return none(seq[byte])
  return fut.read()

proc complete(ch: HydrationChannel; resp: FetchResponse) =
  if not ch.pending.hasKey(resp.digest):
    return
  let fut = ch.pending[resp.digest]
  ch.pending.del(resp.digest)
  var value = none(seq[byte])
  if not resp.truncated:
    let observed = blake3.digest(resp.payload)
    if observed == bytes(resp.digest):
      value = some(resp.payload)
    else:
      inc ch.mismatches
      if not ch.server.isNil and not ch.server.reporter.isNil:
        try:
          ch.server.reporter(newEvidenceRecord(ecDetection,
            "peer-cache-content", "blob-digest-mismatch",
            [("peer", $ch.caller.hostId), ("digest", $resp.digest),
             ("observedDigest", $blobDigestFromBytes(observed)),
             ("size", $resp.payload.len), ("reason", "hydration reply")],
            payload = resp.payload))
        except CatchableError:
          discard
  if not fut.finished:
    fut.complete(value)

proc closeChannel(ch: HydrationChannel) =
  ch.closed = true
  for _, fut in ch.pending.pairs:
    if not fut.finished:
      fut.complete(none(seq[byte]))
  ch.pending.clear()

# ---------------------------------------------------------------------------
# CIDR parsing + matching.
# ---------------------------------------------------------------------------

proc parseCidrV4*(cidr: string): CidrV4 =
  ## Parses an IPv4 CIDR of the form `A.B.C.D/N`. Raises
  ## `PeerCacheServerError` on malformed input.
  let slash = cidr.find('/')
  if slash < 0:
    raise newException(PeerCacheServerError,
      "CIDR missing '/': " & cidr)
  let ipPart = cidr[0 ..< slash]
  let prefixPart = cidr[slash + 1 .. ^1]
  let prefix =
    try: parseInt(prefixPart)
    except ValueError:
      raise newException(PeerCacheServerError,
        "CIDR prefix is not an integer: " & cidr)
  if prefix < 0 or prefix > 32:
    raise newException(PeerCacheServerError,
      "CIDR prefix out of range for IPv4: " & cidr)
  let octets = ipPart.split('.')
  if octets.len != 4:
    raise newException(PeerCacheServerError,
      "CIDR address is not IPv4: " & cidr)
  var ip: uint32 = 0
  for i, octet in octets:
    let value =
      try: parseInt(octet)
      except ValueError:
        raise newException(PeerCacheServerError,
          "CIDR octet is not an integer: " & cidr)
    if value < 0 or value > 255:
      raise newException(PeerCacheServerError,
        "CIDR octet out of range: " & cidr)
    ip = (ip shl 8) or uint32(value)
  let mask: uint32 =
    if prefix == 0: 0'u32
    else: not ((1'u32 shl uint32(32 - prefix)) - 1'u32)
  CidrV4(base: ip and mask, mask: mask)

proc ipv4ToU32(address: string): uint32 =
  let octets = address.split('.')
  if octets.len != 4:
    raise newException(PeerCacheServerError,
      "not an IPv4 address: " & address)
  var ip: uint32 = 0
  for octet in octets:
    let value = parseInt(octet)
    if value < 0 or value > 255:
      raise newException(PeerCacheServerError,
        "IPv4 octet out of range: " & address)
    ip = (ip shl 8) or uint32(value)
  ip

proc inCidr*(address: string; cidr: CidrV4): bool =
  ## Returns true if the IPv4 string `address` lies inside `cidr`.
  ## Non-IPv4 addresses (e.g. an IPv6 string) yield `false` rather
  ## than raising — the M0 loopback workflow is IPv4-only and we
  ## want the allowlist check to fail closed for unknown formats.
  if address.len == 0:
    return false
  if address.contains(':'):
    return false
  let asU32 =
    try: ipv4ToU32(address)
    except CatchableError:
      return false
  (asU32 and cidr.mask) == cidr.base

proc inAllowlist*(address: string; allowlist: openArray[CidrV4]): bool =
  if allowlist.len == 0:
    # Empty allowlist denies everything — explicit configuration is
    # required to accept inbound peers. The loopback helper sets
    # `127.0.0.0/8`; production callers parse from
    # `peer_cache.cidr`.
    return false
  for cidr in allowlist:
    if inCidr(address, cidr):
      return true
  false

# ---------------------------------------------------------------------------
# Constructor + lifecycle.
# ---------------------------------------------------------------------------

const DefaultMaxBlobBytes* = 100_000_000'u64
  ## Spec default for `peer_cache.max_blob_bytes`
  ## (`Peer-Cache.md` §"Configuration surface").

proc newPeerCacheServer*(selfPeerId: PeerId;
                         listenAddr: string;
                         listenPort: Port;
                         registry: PeerRegistry;
                         cidrAllowlist: openArray[CidrV4];
                         maxBlobBytes: uint64 = DefaultMaxBlobBytes;
                         localStoreReader: LocalStoreReader = nil;
                         responseInterceptor: ResponseInterceptor = nil;
                         capTier2: bool = false;
                         trustMode: TrustMode = tmCidr;
                         ourCert: CertAndKey = CertAndKey();
                         trustAnchorSet: TrustAnchorSet = TrustAnchorSet();
                         metrics: PeerCacheMetrics = nil;
                         memoSelectorReader: MemoSelectorReader = nil;
                         memoEntryReader: MemoEntryReader = nil;
                         gate: ReceiverGate = nil):
                         PeerCacheServer =
  result = PeerCacheServer(
    gate: (if gate.isNil: newReceiverGate() else: gate),
    memoSelectorReader: memoSelectorReader,
    memoEntryReader: memoEntryReader,
    selfPeerId: selfPeerId,
    listenAddr: listenAddr,
    listenPort: listenPort,
    registry: registry,
    allowlist: @cidrAllowlist,
    maxBlobBytes: maxBlobBytes,
    localStoreReader: localStoreReader,
    responseInterceptor: responseInterceptor,
    listener: nil,
    running: false,
    activeConnections: @[],
    started: false,
    multicastSocket: nil,
    multicastRunning: false,
    multicastWarnedPeers: initHashSet[PeerId](),
    droppedAnnounceCount: 0,
    warningEmitCount: 0,
    capTier2: capTier2,
    trustMode: trustMode,
    ourCert: ourCert,
    trustAnchorSet: trustAnchorSet,
    peerKeyByPeerId: initTable[PeerId, PublicKeyBytes](),
    signatureRejectedCount: 0,
    signatureRejectedPeers: initHashSet[PeerId](),
    tlsHandshakeRejectedCount: 0,
    metrics: metrics)

# ---------------------------------------------------------------------------
# Frame I/O helpers.
# ---------------------------------------------------------------------------

proc readFrameBytes(sock: AsyncSocket): Future[seq[byte]] {.async.} =
  ## Reads the 8-byte header (version + kind + payloadLen), then the
  ## payload. Returns the concatenated frame bytes ready for
  ## `decodeFrame`. On clean EOF returns an empty seq; the caller
  ## treats that as "remote closed".
  let header = await sock.recv(8)
  if header.len == 0:
    return @[]
  if header.len != 8:
    raise newException(PeerCacheServerError,
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
      raise newException(PeerCacheServerError,
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

# Peer-Cache-BearSSL M3: `performAuthHandshake` (synthetic-mTLS in-
# protocol challenge/response) was deleted in this milestone. The
# `tmTls` branch in `acceptLoop` now wraps the accepted socket via
# `wrapServerSocket` from `tls.nim`. Real TLS owns the auth surface.

# ---------------------------------------------------------------------------
# Distributed-Execution M0: memoization request handling, shared by the
# plain-TCP and TLS connection handlers so the two transports cannot drift.
# ---------------------------------------------------------------------------

proc memoReply*(server: PeerCacheServer; frame: Frame):
    tuple[kind: MessageKind; payload: seq[byte]] =
  ## Builds the reply for a memo request frame. Raises
  ## `PeerCacheServerError` for a frame that is not a memo request; codec
  ## errors propagate (the caller closes the connection, as for any
  ## malformed frame).
  case frame.messageKind
  of mkGetSelectorsRequest:
    let req = decodeGetSelectorsRequest(frame.payload)
    var selectors: seq[MemoSelector] = @[]
    if not server.memoSelectorReader.isNil:
      selectors = server.memoSelectorReader(req.weakFingerprint)
      if selectors.len > MaxSelectorsPerResponse:
        selectors.setLen(MaxSelectorsPerResponse)
    inc server.memoRequestsServed
    (mkGetSelectorsResponse, encodeGetSelectorsResponse(
      GetSelectorsResponse(weakFingerprint: req.weakFingerprint,
                           selectors: selectors)))
  of mkGetActionRecordRequest:
    let req = decodeGetActionRecordRequest(frame.payload)
    var resp = GetActionRecordResponse(
      weakFingerprint: req.weakFingerprint,
      strongFingerprint: req.strongFingerprint,
      found: false, entry: @[])
    if not server.memoEntryReader.isNil:
      let entry = server.memoEntryReader(req.weakFingerprint,
                                         req.strongFingerprint)
      if entry.isSome and uint64(entry.get().len) <= server.maxBlobBytes:
        resp.found = true
        resp.entry = entry.get()
    inc server.memoRequestsServed
    (mkGetActionRecordResponse, encodeGetActionRecordResponse(resp))
  else:
    raise newException(PeerCacheServerError,
      "not a memo request frame: " & $frame.messageKind)

proc readFrameBytesTls(conn: TlsConn): Future[seq[byte]] {.async.} =
  ## Reads one full peer-cache frame (header + payload) from the TLS
  ## tunnel. Returns an empty seq on clean close.
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
        raise newException(PeerCacheServerError,
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

# ---------------------------------------------------------------------------
# Connection handling — Distributed-Execution M7.
#
# ONE loop serves both transports (plain TCP under `tmCidr`, BearSSL TLS under
# `tmTls`), so the Boundary rules cannot drift between them. For every frame:
#
#   1. the 8-byte header is read and `ReceiverGate.admit` decides from it
#      alone — size first, so an oversized frame is refused without its body
#      ever being allocated (`boundary.nim` documents the order);
#   2. a refused frame is audited by the gate, the sender is told
#      (`mkRefused`) and the connection is closed when the stream cannot be
#      resynchronised;
#   3. an admitted frame's payload is read, decoded strictly, audited with
#      its payload (`recordAdmitted`) and only then acted on.
#
# The caller's identity is established by the RECEIVER: from the TLS leaf it
# verified (`mkIdentityProof`, `identity.nim`) — never from the peer id a
# Hello claims. Under `tmTls` a Hello naming any other peer id is refused
# and the connection closed; under `tmCidr` the caller is anonymous and the
# gate's anonymous set applies.
# ---------------------------------------------------------------------------

type
  FrameIo = object
    ## The transport a connection rides, as three closures.
    recvExact: proc(n: int): Future[seq[byte]] {.gcsafe, closure.}
    send: proc(kind: MessageKind; payload: seq[byte]): Future[void]
      {.gcsafe, closure.}
    close: proc() {.gcsafe, closure.}

proc plainRecvExact(sock: AsyncSocket; n: int): Future[seq[byte]] {.async.} =
  if n == 0:
    return @[]
  var got = ""
  while got.len < n:
    let chunk = await sock.recv(n - got.len)
    if chunk.len == 0:
      return @[]
    got.add(chunk)
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(ord(got[i]))

proc tlsRecvExact(conn: TlsConn; n: int;
                  idle = false): Future[seq[byte]] {.async.} =
  ## `idle`: this read waits for the next frame, so no deadline applies
  ## until its first byte (an idle connection is not a closed one).
  if n == 0:
    return @[]
  var got = ""
  while got.len < n:
    let chunk = await tls.recv(conn, n - got.len,
      idleTimeoutMs = (if idle and got.len == 0: 0 else: 60_000))
    if chunk.len == 0:
      return @[]
    got.add(chunk)
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = byte(ord(got[i]))

proc plainIo(sock: AsyncSocket): FrameIo =
  FrameIo(
    recvExact: proc(n: int): Future[seq[byte]] {.gcsafe, closure.} =
      plainRecvExact(sock, n),
    send: proc(kind: MessageKind; payload: seq[byte]): Future[void]
        {.gcsafe, closure.} =
      sendFrame(sock, kind, payload),
    close: proc() {.gcsafe, closure.} =
      try: sock.close() except CatchableError: discard)

proc tlsIo(conn: TlsConn): FrameIo =
  FrameIo(
    recvExact: proc(n: int): Future[seq[byte]] {.gcsafe, closure.} =
      tlsRecvExact(conn, n, idle = n == 8),
    send: proc(kind: MessageKind; payload: seq[byte]): Future[void]
        {.gcsafe, closure.} =
      sendFrameTls(conn, kind, payload),
    close: proc() {.gcsafe, closure.} =
      asyncCheck tls.close(conn))

proc headerFields(header: seq[byte]): tuple[version, tag: uint16;
                                           payloadLen: uint32] =
  result.version = uint16(header[0]) or (uint16(header[1]) shl 8)
  result.tag = uint16(header[2]) or (uint16(header[3]) shl 8)
  for i in 0 ..< 4:
    result.payloadLen = result.payloadLen or
      (uint32(header[4 + i]) shl uint32(i * 8))

proc sendRefusal(io: FrameIo; tag: uint16; decision: GateDecision)
    {.async.} =
  try:
    await io.send(mkRefused, encodeRefused(RefusedNotice(refusedTag: tag,
      refusalClass: uint8(ord(decision.refusal)), reason: decision.reason)))
  except CatchableError:
    discard

proc ownProof(server: PeerCacheServer): seq[byte] =
  if server.leafProvider.isNil:
    return @[]
  try: server.leafProvider().cert.certDer
  except CatchableError: @[]

proc fetchReply(server: PeerCacheServer; req: FetchRequest): FetchResponse =
  ## The content-plane answer (unchanged semantics from Peer-Cache M1).
  if not server.metrics.isNil:
    inc server.metrics.fetchRequestsTotal
  result = FetchResponse(digest: req.digest, truncated: true, payload: @[])
  if server.localStoreReader.isNil:
    if not server.metrics.isNil:
      inc server.metrics.fetchMissesTotal
    return
  let lookup = server.localStoreReader(req.digest)
  if lookup.isNone or uint64(lookup.get().len) > server.maxBlobBytes:
    if not server.metrics.isNil:
      inc server.metrics.fetchMissesTotal
    return
  var payload = lookup.get()
  if not server.responseInterceptor.isNil:
    payload = server.responseInterceptor(payload)
  if not server.metrics.isNil:
    inc server.metrics.fetchHitsLocal
  result = FetchResponse(digest: req.digest, truncated: false, payload: payload)

proc refuseInline(server: PeerCacheServer; io: FrameIo;
                  caller: CallerIdentity; tag: uint16; payload: seq[byte];
                  refusal: RefusalClass; reason: string;
                  close = true) {.async.} =
  ## A refusal decided AFTER the payload was read (identity proof that does
  ## not verify, a Hello claiming another identity, schema errors). Audited
  ## like a gate refusal, with the payload captured.
  let decision = GateDecision(allowed: false, refusal: refusal,
    reason: reason, closeConnection: close)
  server.gate.record(caller, tag, uint32(payload.len), decision, payload,
    nowMs = server.nowMs())
  await sendRefusal(io, tag, decision)

proc readRefusedPayload(io: FrameIo; decision: GateDecision;
                        payloadLen: uint32): Future[seq[byte]] {.async.} =
  ## The payload of a frame the gate refused from its header, for the audit
  ## record (EVID-1: capture the payload, not only the fact; threat model
  ## G19). A frame within its size budget is read whole (it must be
  ## consumed anyway to stay in frame sync); an oversized one only up to
  ## `MaxCapturedRefusalBytes` before the connection is closed.
  let n =
    if decision.refusal == rcSize: min(int(payloadLen), MaxCapturedRefusalBytes)
    else: int(payloadLen)
  if n <= 0:
    return @[]
  try:
    result = await io.recvExact(n)
  except CatchableError:
    result = @[]

proc serveConnection(server: PeerCacheServer; io: FrameIo;
                     remoteAddress: string;
                     authedKey: Option[PublicKeyBytes]) {.async.} =
  var caller = CallerIdentity(address: remoteAddress)
  if server.trustMode == tmTls and authedKey.isSome:
    # Until an identity proof arrives, a TLS peer is its own key (the
    # legacy shape). A node that requires short-lived leaves treats it as
    # unauthenticated instead, so nothing but the proof itself passes.
    if not server.requireShortLivedLeaves:
      let legacy = legacyIdentityFromKey(authedKey.get())
      caller.authenticated = true
      caller.hostId = legacy.hostId
      caller.leafRole = lrLegacy
  let hydration = HydrationChannel(send: io.send, server: server,
    pending: initTable[BlobDigest, Future[Option[seq[byte]]]]())
  var goalInFlight = false
  try:
    while server.running:
      let header = await io.recvExact(8)
      if header.len != 8:
        break
      let (version, tag, payloadLen) = headerFields(header)
      let decision = server.gate.decide(caller, tag, payloadLen,
        server.nowMs(), hydrationPending = hydration.pendingCount > 0)
      if not decision.allowed:
        let captured = await readRefusedPayload(io, decision, payloadLen)
        server.gate.record(caller, tag, payloadLen, decision, captured,
          nowMs = server.nowMs())
        await sendRefusal(io, tag, decision)
        if decision.closeConnection or captured.len != int(payloadLen):
          break
        continue
      let payload = await io.recvExact(int(payloadLen))
      if payload.len != int(payloadLen):
        break
      var frameBytes = header
      frameBytes.add(payload)
      var frame: Frame
      try:
        frame = decodeFrame(frameBytes)
      except CatchableError as err:
        await server.refuseInline(io, caller, tag, payload, rcSchema,
          "malformed frame: " & err.msg)
        break
      discard version
      server.gate.recordAdmitted(caller, tag, payload)
      try:
        case frame.messageKind
        of mkIdentityProof:
          if server.trustMode != tmTls or authedKey.isNone:
            await server.refuseInline(io, caller, tag, payload, rcProtocol,
              "identity proof outside a TLS session")
            break
          var leafDer: seq[byte]
          try:
            leafDer = decodeIdentityProof(frame.payload)
          except CatchableError as err:
            await server.refuseInline(io, caller, tag, payload, rcSchema,
              err.msg)
            break
          let verified = verifyLeaf(leafDer, server.trustAnchorSet,
            server.nowMs() div 1000, expectedPublicKey = authedKey,
            requireShortLived = server.requireShortLivedLeaves)
          if not verified.ok:
            await server.refuseInline(io, caller, tag, payload,
              rcUnauthenticated, verified.reason)
            break
          caller.authenticated = true
          caller.hostId = verified.hostId
          server.inboundAuthenticated.inc((verified.hostId, verified.role))
          caller.leafRole = verified.role
          caller.leafNotAfter = verified.notAfter
          hydration.caller = caller
          let mine = server.ownProof()
          if mine.len > 0:
            await io.send(mkIdentityProof, encodeIdentityProof(mine))
        of mkHello:
          let hello = decodeHello(frame.payload)
          if server.trustMode == tmTls:
            if not caller.authenticated:
              await server.refuseInline(io, caller, tag, payload,
                rcUnauthenticated, "Hello before a verified identity proof")
              break
            if hello.peerId != caller.hostId:
              await server.refuseInline(io, caller, tag, payload,
                rcUnauthenticated, "Hello claims peer " & $hello.peerId &
                " but the authenticated host is " & $caller.hostId)
              break
          let peerId = if caller.authenticated: caller.hostId else: hello.peerId
          server.registry.addPeer(peerId,
            initEndpoint(remoteAddress, Port(hello.listenPort)))
          server.registry.setPeerTier2(peerId, hello.capTier2)
          if authedKey.isSome:
            server.peerKeyByPeerId[peerId] = authedKey.get()
          caller.helloDone = true
          if not caller.authenticated:
            caller.hostId = hello.peerId
          hydration.caller = caller
          await io.send(mkHelloOk, encodeHelloOk(HelloOk(
            peerId: server.selfPeerId,
            protocolVersion: PeerCacheProtocolVersion,
            maxBlobBytes: server.maxBlobBytes,
            capTier2: server.capTier2)))
          await io.send(mkAdvertise,
            encodeAdvertise(server.registry.snapshotFor(peerId)))
          if not server.metrics.isNil:
            inc server.metrics.advertisementsSentTotal
        of mkAdvertise:
          server.registry.applyAdvertise(caller.hostId,
            decodeAdvertise(frame.payload))
          if not server.metrics.isNil:
            inc server.metrics.advertisementsReceivedTotal
        of mkAdvertiseV2:
          let ad = decodeAdvertiseV2(frame.payload)
          # Peer-Cache-BearSSL M3 semantics: under `tmTls` a signed
          # advertisement must verify under the TLS-bound key and an unsigned
          # one is accepted; `tmCidr` has no key to check against.
          var verified = true
          if server.trustMode == tmTls and ad.signature.len > 0:
            verified = false
            if ad.signature.len == 64 and
                server.peerKeyByPeerId.hasKey(caller.hostId):
              var sig: SignatureBytes
              for i in 0 ..< 64:
                sig[i] = ad.signature[i]
              verified = verifySignature(server.peerKeyByPeerId[caller.hostId],
                canonicaliseAdvertiseForSigning(caller.hostId, ad), sig)
          if not verified:
            if caller.hostId notin server.signatureRejectedPeers:
              server.signatureRejectedPeers.incl(caller.hostId)
              inc server.signatureRejectedCount
            if not server.metrics.isNil:
              inc server.metrics.signatureRejectionsTotal
            continue
          server.registry.applyAdvertiseV2(caller.hostId, ad)
          if not server.metrics.isNil:
            inc server.metrics.advertisementsReceivedTotal
        of mkWant:
          let want = decodeWant(frame.payload)
          if want.kind == wkSnapshotRequest:
            await io.send(mkAdvertise,
              encodeAdvertise(server.registry.snapshotFor(caller.hostId)))
            if not server.metrics.isNil:
              inc server.metrics.advertisementsSentTotal
        of mkPing:
          await io.send(mkPong, encodePong(Pong()))
        of mkPong:
          if caller.helloDone:
            server.registry.updateLastSeen(caller.hostId)
        of mkGoodbye:
          break
        of mkFetchRequest:
          let resp = server.fetchReply(decodeFetchRequest(frame.payload))
          await io.send(mkFetchResponse, encodeFetchResponse(resp))
        of mkFetchResponse:
          # Admitted by the gate only as a hydration reply (a fetch this
          # worker made over the caller's connection is outstanding).
          hydration.complete(decodeFetchResponse(frame.payload))
        of mkGetSelectorsRequest, mkGetActionRecordRequest:
          let reply = server.memoReply(frame)
          await io.send(reply.kind, reply.payload)
        of mkReachGoalRequest:
          if server.workerHandler.isNil:
            await server.refuseInline(io, caller, tag, payload,
              rcNotImplemented, "this node does not hold the worker role",
              close = false)
          elif goalInFlight:
            await server.refuseInline(io, caller, tag, payload, rcProtocol,
              "a ReachGoal is already in progress on this connection",
              close = false)
          else:
            # The handler hydrates over THIS connection, so it runs beside
            # the read loop that delivers the caller's hydration replies.
            goalInFlight = true
            let handler = server.workerHandler
            let goalCaller = caller
            let goalFrame = frame
            proc runGoal() {.async.} =
              try:
                let reply = await handler(goalCaller, goalFrame, hydration)
                await io.send(reply.kind, reply.payload)
              except CatchableError:
                discard
              goalInFlight = false
            asyncCheck runGoal()
        of mkHelloOk, mkGetSelectorsResponse,
           mkGetActionRecordResponse, mkRefused, mkReachGoalResponse,
           mkAttach, mkGraphDescriptorFetch, mkExecutePips,
           mkNotifyPipResults, mkShardDispatch,
           mkSwimProbe, mkSwimAck, mkSwimProbeReq, mkSwimProbeAckIndirect,
           mkSwimSuspect, mkSwimConfirm, mkSwimRefute:
          # Unreachable: the gate refuses these at a receiver (zero size
          # budget for replies/SWIM, not-implemented for the reserved ones).
          discard
      except OSError, IOError, TlsHandshakeError:
        # The connection itself failed (peer gone mid-reply): not a
        # property of the frame.
        break
      except CatchableError as err:
        # A payload the codec or a handler could not process is a parser-
        # level rejection (EVID-1): refused as `schema`, audited with the
        # frame, and the connection closed.
        await server.refuseInline(io, caller, tag, payload, rcSchema,
          "malformed " & $frame.messageKind & ": " & err.msg)
        break
  except CatchableError:
    # Connection-level errors close the socket; the registry retains
    # the peer entry so a reconnection re-uses it.
    discard
  finally:
    hydration.closeChannel()
    io.close()

proc acceptLoop(server: PeerCacheServer) {.async.} =
  while server.running:
    var client: AsyncSocket
    var remoteAddress: string
    try:
      (remoteAddress, client) = await server.listener.acceptAddr()
    except CatchableError:
      break
    if client.isNil:
      break
    if not inAllowlist(remoteAddress, server.allowlist):
      # CIDR rejection — close without responding (defence in depth beside
      # the declared-interface bind; adjacency is never authorization).
      try: client.close() except CatchableError: discard
      continue
    server.activeConnections.add(client)
    if server.trustMode == tmTls:
      var connOpt: Option[TlsConn]
      if server.leafProvider.isNil:
        connOpt = await wrapServerSocket(client, server.ourCert,
                                         server.trustAnchorSet)
      else:
        let leaf =
          try: server.leafProvider()
          except CatchableError: LeafCredential()
        if leaf.key.isNil or not leaf.key.available:
          connOpt = none(TlsConn)
        else:
          connOpt = await wrapServerSocket(client, leaf.cert.certDer,
            leaf.key, server.trustAnchorSet)
      if connOpt.isNone:
        inc server.tlsHandshakeRejectedCount
        try: client.close() except CatchableError: discard
        continue
      let conn = connOpt.get()
      asyncCheck serveConnection(server, tlsIo(conn), remoteAddress,
        remotePublicKey(conn))
    else:
      asyncCheck serveConnection(server, plainIo(client), remoteAddress,
        none(PublicKeyBytes))

proc start*(server: PeerCacheServer) =
  ## Opens the listening socket and spawns the accept loop.
  ## Re-reads `server.listenPort` after binding so callers can
  ## use port 0 to ask the OS for an ephemeral port (the test
  ## suite + loopback helper rely on this).
  if server.running:
    return
  if server.trustMode == tmCidr and not server.listenAddr.startsWith("127."):
    # The harness mode (see `TrustMode`) never listens beyond loopback.
    raise newException(ValueError, "a CIDR-trust peer-cache server listens " &
      "only on a loopback address, not '" & server.listenAddr & "'")
  server.listener = newAsyncSocket()
  server.listener.setSockOpt(OptReuseAddr, true)
  server.listener.bindAddr(server.listenPort, server.listenAddr)
  let nativeFd = server.listener.getFd()
  let actualPort = getLocalAddr(nativeFd, Domain.AF_INET)[1]
  server.listenPort = actualPort
  server.listener.listen()
  server.running = true
  server.started = true
  asyncCheck acceptLoop(server)

proc stop*(server: PeerCacheServer) =
  ## Closes the listener and drops active connections. Idempotent.
  if not server.running:
    return
  server.running = false
  server.started = false
  server.multicastRunning = false
  if not server.multicastSocket.isNil:
    try: server.multicastSocket.close() except CatchableError: discard
    server.multicastSocket = nil
  if not server.listener.isNil:
    try: server.listener.close() except CatchableError: discard
    server.listener = nil
  for conn in server.activeConnections:
    try: conn.close() except CatchableError: discard
  server.activeConnections.setLen(0)

proc actualPort*(server: PeerCacheServer): Port =
  server.listenPort

proc abandonAfterFork*(server: PeerCacheServer) =
  ## Distributed-Execution M0: called in a FORKED CHILD of the process that
  ## owns this server (a `repro-daemon` build worker). Releases the child's
  ## copies of the listening and multicast descriptors WITHOUT going through
  ## the async dispatcher: the dispatcher the child inherited is the
  ## parent's (on Linux the epoll instance is literally shared), so
  ## unregistering through it would disturb the parent, which keeps serving.
  ## The server object is unusable afterwards.
  server.running = false
  server.started = false
  server.multicastRunning = false
  when defined(posix):
    if not server.listener.isNil:
      discard posix.close(cint(server.listener.getFd()))
    if not server.multicastSocket.isNil:
      discard posix.close(cint(server.multicastSocket.getFd()))
    for conn in server.activeConnections:
      if not conn.isNil:
        discard posix.close(cint(conn.getFd()))
  server.listener = nil
  server.multicastSocket = nil
  server.activeConnections.setLen(0)

proc sampleMetrics*(server: PeerCacheServer) =
  ## Peer-Cache-Scale M4: mirrors registry size + counter snapshots
  ## into the shared `PeerCacheMetrics`. The HTTP scrape handler reads
  ## the metrics shell, so callers (or a periodic loop) must call this
  ## before scrapes to keep the gauges current.
  if server.metrics.isNil:
    return
  setActivePeers(server.metrics,
                 if server.registry.isNil: 0
                 else: server.registry.peerCount())
  refreshDebugRegistry(server.metrics, server.registry)
  # Mirror M3 signature-rejection counter into the metrics counter so
  # `repro_peer_cache_signature_rejections_total` reflects both the
  # M4-only increment site (above) and any M3-only flow.
  server.metrics.signatureRejectionsTotal =
    max(server.metrics.signatureRejectionsTotal,
        uint64(server.signatureRejectedCount))

# ---------------------------------------------------------------------------
# Peer-Cache M2: UDP multicast receiver.
# ---------------------------------------------------------------------------

proc readGatedFrame(server: PeerCacheServer; sock: AsyncSocket;
                    peer: CallerIdentity; ctx: OutboundContext):
                    Future[Option[Frame]] {.async.} =
  ## One frame from a socket this server dialled, through the outbound gate
  ## (size from the header before the body is read; audited).
  let header = await sock.recv(8)
  if header.len != 8:
    return none(Frame)
  var hdr = newSeq[byte](8)
  for i in 0 ..< 8: hdr[i] = byte(ord(header[i]))
  let (_, tag, payloadLen) = headerFields(hdr)
  let decision = server.gate.decideOutbound(peer, tag, payloadLen, ctx,
    server.nowMs())
  if not decision.allowed:
    server.gate.record(peer, tag, payloadLen, decision, outbound = true,
      nowMs = server.nowMs())
    return none(Frame)
  var frameBytes = hdr
  if payloadLen > 0'u32:
    let body = await sock.recv(int(payloadLen))
    if body.len != int(payloadLen):
      return none(Frame)
    for ch in body: frameBytes.add(byte(ord(ch)))
  let frame = decodeFrame(frameBytes)
  server.gate.recordAdmitted(peer, tag, frame.payload, outbound = true)
  return some(frame)

proc dialAnnouncedPeer(server: PeerCacheServer;
                       hello: Hello;
                       remoteAddress: string) {.async.} =
  ## After an inbound multicast announcement passes the CIDR check:
  ##
  ## * on a TLS node (every node the CLI and the daemon start) the
  ##   announced endpoint is only RECORDED (`discoveredEndpoints`). An
  ##   announcement is unauthenticated bytes; the node's client dials the
  ##   endpoint through the TLS handshake, the identity proof and the
  ##   outbound gate like any other peer (threat model G29 — the plaintext
  ##   dial with an unbounded read used to run here);
  ## * in the CIDR harness mode (loopback only) the Peer-Cache M2 handshake
  ##   runs here, with every frame through the outbound gate.
  ##
  ## Errors are swallowed — a stale announcement (peer went away
  ## between sending and our dial) is not a protocol violation, just
  ## a miss.
  if hello.peerId == server.selfPeerId:
    # Self-announce on loopback — `IP_MULTICAST_LOOP` delivers our
    # own packets back. Drop without warning.
    return
  let endpoint = initEndpoint(remoteAddress, Port(hello.listenPort))
  if server.trustMode == tmTls:
    if endpoint notin server.discoveredEndpoints and
        server.discoveredEndpoints.len < MaxDiscoveredEndpoints:
      server.discoveredEndpoints.add(endpoint)
    return
  if server.registry.hasPeer(hello.peerId):
    # Already discovered via a previous announcement; nothing more
    # to do. The TCP connection from the prior round still feeds the
    # registry advertisements.
    return
  var sock = newAsyncSocket()
  let peer = CallerIdentity(address: remoteAddress)
  try:
    await sock.connect(remoteAddress, Port(hello.listenPort))
    let ourHello = Hello(
      peerId: server.selfPeerId,
      listenPort: uint16(server.listenPort),
      capabilities: 0'u32,
      capTier2: server.capTier2)
    let helloFrame = encodeFrame(mkHello, encodeHello(ourHello))
    var helloStr = newString(helloFrame.len)
    for i, b in helloFrame:
      helloStr[i] = char(b)
    await sock.send(helloStr)
    let okFrame = await server.readGatedFrame(sock, peer,
      OutboundContext(helloPending: true))
    if okFrame.isNone or okFrame.get().messageKind != mkHelloOk:
      try: sock.close() except CatchableError: discard
      return
    let helloOk = decodeHelloOk(okFrame.get().payload)
    server.registry.addPeer(helloOk.peerId, endpoint)
    # Peer-Cache-Scale M2: record the dialed peer's tier-2 capability
    # from both the announced Hello and the returned HelloOk.
    server.registry.setPeerTier2(helloOk.peerId,
                                 hello.capTier2 or helloOk.capTier2)
    # Drain one more frame (the initial advertise snapshot) so the
    # registry's blob set is primed. Best-effort.
    try:
      let adv = await server.readGatedFrame(sock, peer, OutboundContext())
      if adv.isSome and adv.get().messageKind == mkAdvertise:
        server.registry.applyAdvertise(helloOk.peerId,
          decodeAdvertise(adv.get().payload))
    except CatchableError:
      discard
    try: sock.close() except CatchableError: discard
  except CatchableError:
    try: sock.close() except CatchableError: discard

proc multicastReceiveLoop(server: PeerCacheServer;
                          group: MulticastGroup;
                          sock: AsyncSocket) {.async.} =
  ## Inner recv loop: read UDP packets, decode `mkHello`, enforce the
  ## CIDR allowlist at the packet level, and (on accept) dial the
  ## announced TCP endpoint.
  const MaxPacketBytes = 2_048
  while server.multicastRunning:
    var triple: tuple[data: string, address: string, port: Port]
    try:
      triple = await sock.recvFrom(MaxPacketBytes)
    except CatchableError:
      break
    if triple.data.len == 0:
      continue
    # CIDR check at the multicast receiver level (primary security
    # gate per Peer-Cache M2). Off-CIDR announcements are dropped
    # before any TCP dial is attempted.
    if not inAllowlist(triple.address, server.allowlist):
      inc server.droppedAnnounceCount
      var hello: Hello
      var helloOk = true
      try:
        hello = decodeHelloPacket(triple.data)
      except CatchableError:
        helloOk = false
      if helloOk and hello.peerId notin server.multicastWarnedPeers:
        server.multicastWarnedPeers.incl(hello.peerId)
        inc server.warningEmitCount
        let line = "peer-cache: dropping multicast announcement from " &
          triple.address & " (peer " & $hello.peerId &
          ") — outside configured CIDR allowlist"
        try:
          if server.diagnosticLog.isNil:
            stderr.writeLine(line)
          else:
            server.diagnosticLog(line)
        except CatchableError:
          discard
      continue
    var hello: Hello
    try:
      hello = decodeHelloPacket(triple.data)
    except CatchableError:
      # Malformed packet — drop silently.
      continue
    asyncCheck dialAnnouncedPeer(server, hello, triple.address)

proc multicastListen*(server: PeerCacheServer;
                     group: MulticastGroup) =
  ## Peer-Cache M2: start a background loop that joins the configured
  ## UDP multicast group, receives `mkHello` announcements, enforces
  ## the CIDR allowlist at the packet level, and (on accept) opens
  ## the standard M0 TCP handshake to the announced endpoint.
  ##
  ## The CIDR check is the primary security gate at the multicast
  ## layer; the TCP-level CIDR check in `acceptLoop` remains as
  ## defense in depth (announcements that pass packet-level routing
  ## via a routable group but originate from outside the CIDR get
  ## dropped twice — once here, once at TCP accept).
  if server.multicastRunning:
    return
  server.multicastRunning = true
  let sock = newMulticastReceiverSocket(group)
  server.multicastSocket = sock
  asyncCheck multicastReceiveLoop(server, group, sock)
