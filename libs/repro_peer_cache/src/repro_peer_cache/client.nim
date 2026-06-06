## Peer-cache TCP client — Peer-Cache M0.
##
## `asyncnet` + `asyncdispatch` based client. `start` dials each seed
## peer, completes the `mkHello` / `mkHelloOk` handshake, registers
## the remote peer ID + endpoint with the local registry, and reads
## the initial `mkAdvertise` snapshot. Connections are kept open
## (one per peer) so subsequent fetch requests and advertisements
## reuse them; `stop` sends `mkGoodbye` to each peer and closes.

import std/[asyncdispatch, asyncnet, nativesockets, options, tables]

import blake3

import ./codec
import ./multicast
import ./registry
import ./server  # for inAllowlist + CidrV4
import ./types

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
    connections: Table[PeerId, AsyncSocket]
    running: bool

  PeerCacheClientError* = object of CatchableError

proc newPeerCacheClient*(selfPeerId: PeerId;
                        listenPort: uint16;
                        registry: PeerRegistry;
                        seedPeers: openArray[Endpoint];
                        cidrAllowlist: openArray[CidrV4];
                        localStoreWriter: LocalStoreWriter = nil;
                        fetchTimeoutMs: int = DefaultFetchTimeoutMs;
                        advertiseIntervalMs: int = 5_000):
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
    running: false)

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
  ## remote peer ID.
  let hello = Hello(
    peerId: client.selfPeerId,
    listenPort: client.listenPort,
    capabilities: 0'u32)
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

  # Send our initial advertise snapshot.
  let snapshot = client.registry.snapshotFor(helloOk.peerId)
  await sendFrame(sock, mkAdvertise, encodeAdvertise(snapshot))

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
        client.registry.applyAdvertiseV2(peerId,
          decodeAdvertiseV2(frame.payload))
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
        let resp = decodeFetchResponse(frame.payload)
        if resp.truncated:
          client.completePending(resp.digest, none(seq[byte]))
        else:
          let observed = blake3.digest(resp.payload)
          let expected = bytes(resp.digest)
          if observed != expected:
            # BLAKE3 mismatch — drop the response, mark the peer
            # suspect, and fall through (the caller's `requestFetch`
            # loop tries the next candidate). Per spec, mismatch is
            # always the *peer's* fault: the digest was supplied by
            # the receiver, the payload was supplied by the peer.
            client.registry.markSuspect(peerId)
            client.completePending(resp.digest, none(seq[byte]))
          else:
            client.completePending(resp.digest,
              some(resp.payload))
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

proc dialPeer(client: PeerCacheClient;
              endpoint: Endpoint): Future[void] {.async.} =
  var sock = newAsyncSocket()
  try:
    await sock.connect(endpoint.host, endpoint.port)
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
  let candidates = client.registry.findPeersWithBlob(digest)
  for candidate in candidates:
    if not client.connections.hasKey(candidate):
      continue
    let sock = client.connections[candidate]
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

proc stop*(client: PeerCacheClient) {.async.} =
  ## Sends Goodbye to each connected peer and closes the connections.
  ## Also stops any in-flight multicast broadcast loop.
  client.running = false
  client.multicastRunning = false
  if not client.multicastSocket.isNil:
    try: client.multicastSocket.close() except CatchableError: discard
    client.multicastSocket = nil
  for peerId, sock in client.connections.pairs:
    try:
      await sendFrame(sock, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError:
      discard
    try: sock.close() except CatchableError: discard
  client.connections.clear()

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
    capabilities: 0'u32)
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
