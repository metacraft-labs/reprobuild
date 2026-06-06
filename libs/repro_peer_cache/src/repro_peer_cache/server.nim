## Peer-cache TCP server — Peer-Cache M0.
##
## `asyncnet` + `asyncdispatch` based server. On accept, reads framed
## peer-cache messages from the connection. Handles:
##
##   `mkHello`     — reply with `mkHelloOk` + initial `mkAdvertise`
##                   snapshot built from the registry's self-advertised
##                   set,
##   `mkAdvertise` — applied to the registry,
##   `mkPing`      — replied with `mkPong`,
##   `mkGoodbye`   — closes the connection,
##   `mkFetchRequest` — M0 stub: responds with an empty
##                       `mkFetchResponse{ truncated: true }`. M1 wires
##                       this to the local store.
##
## At accept time, the remote network address is checked against the
## configured CIDR allowlist; non-matching peers are dropped without
## sending any frames.

import std/[asyncdispatch, asyncnet, nativesockets, net, sets,
            strutils]

import ./codec
import ./multicast
import ./registry
import ./types

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

  PeerCacheServerError* = object of CatchableError

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
                         responseInterceptor: ResponseInterceptor = nil):
                         PeerCacheServer =
  result = PeerCacheServer(
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
    warningEmitCount: 0)

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

# ---------------------------------------------------------------------------
# Connection handler.
# ---------------------------------------------------------------------------

proc handleConnection(server: PeerCacheServer; client: AsyncSocket;
                      remoteAddress: string) {.async.} =
  var registeredPeerId: PeerId
  var hasRegisteredPeer = false
  try:
    while server.running:
      let frameBytes = await readFrameBytes(client)
      if frameBytes.len == 0:
        break
      let frame = decodeFrame(frameBytes)
      case frame.messageKind
      of mkHello:
        let hello = decodeHello(frame.payload)
        # Register the peer with the network address `accept` saw
        # plus the listen port from the Hello. The announced
        # endpoint becomes the peer's known fetch address.
        let endpoint = initEndpoint(remoteAddress, Port(hello.listenPort))
        server.registry.addPeer(hello.peerId, endpoint)
        registeredPeerId = hello.peerId
        hasRegisteredPeer = true
        # Reply with HelloOk.
        let helloOk = HelloOk(
          peerId: server.selfPeerId,
          protocolVersion: PeerCacheProtocolVersion,
          maxBlobBytes: server.maxBlobBytes)
        await sendFrame(client, mkHelloOk, encodeHelloOk(helloOk))
        # Send the initial advertise snapshot.
        let snapshot = server.registry.snapshotFor(hello.peerId)
        await sendFrame(client, mkAdvertise, encodeAdvertise(snapshot))
      of mkAdvertise:
        if not hasRegisteredPeer:
          # Advertise before Hello — protocol violation.
          raise newException(PeerCacheServerError,
            "Advertise received before Hello on peer-cache connection")
        let ad = decodeAdvertise(frame.payload)
        server.registry.applyAdvertise(registeredPeerId, ad)
      of mkAdvertiseV2:
        # Peer-Cache-Scale M1: v2 cuckoo-filter advertisement.
        if not hasRegisteredPeer:
          raise newException(PeerCacheServerError,
            "AdvertiseV2 received before Hello on peer-cache connection")
        let ad = decodeAdvertiseV2(frame.payload)
        server.registry.applyAdvertiseV2(registeredPeerId, ad)
      of mkPing:
        await sendFrame(client, mkPong, encodePong(Pong()))
      of mkPong:
        if hasRegisteredPeer:
          server.registry.updateLastSeen(registeredPeerId)
      of mkGoodbye:
        break
      of mkFetchRequest:
        # M1: consult the injected `LocalStoreReader`. Reply truncated
        # when there is no reader (M0 fallback), the blob is absent, or
        # the blob exceeds `maxBlobBytes`. On hit, run the optional
        # `responseInterceptor` (test seam for the corrupted-payload
        # verification path) before encoding the response payload.
        let req = decodeFetchRequest(frame.payload)
        var resp: FetchResponse
        if server.localStoreReader.isNil:
          resp = FetchResponse(
            digest: req.digest, truncated: true, payload: @[])
        else:
          let lookup = server.localStoreReader(req.digest)
          if lookup.isNone:
            resp = FetchResponse(
              digest: req.digest, truncated: true, payload: @[])
          else:
            let bytes = lookup.get()
            if uint64(bytes.len) > server.maxBlobBytes:
              resp = FetchResponse(
                digest: req.digest, truncated: true, payload: @[])
            else:
              var payload = bytes
              if not server.responseInterceptor.isNil:
                payload = server.responseInterceptor(payload)
              resp = FetchResponse(
                digest: req.digest, truncated: false, payload: payload)
        await sendFrame(client, mkFetchResponse, encodeFetchResponse(resp))
      of mkFetchResponse:
        # Server-side receipt of a fetch response is unusual (the
        # server is the one serving fetches), but the protocol is
        # bidirectional — drop silently in M0.
        discard
      of mkHelloOk:
        # Server doesn't expect HelloOk from a client.
        discard
      of mkWant:
        # M1: a `wkSnapshotRequest` asks for a fresh advertise
        # snapshot — used by the receiver after detecting a
        # sequence-number gap (see registry.needsSnapshot). We reply
        # with the current `mkAdvertise` snapshot from the registry.
        # `wkBlobs` (point fetch list) remains a no-op until M2 wires
        # batched fetches; senders that want a single blob today use
        # `mkFetchRequest` instead.
        if not hasRegisteredPeer:
          raise newException(PeerCacheServerError,
            "Want received before Hello on peer-cache connection")
        let want = decodeWant(frame.payload)
        case want.kind
        of wkSnapshotRequest:
          let snapshot = server.registry.snapshotFor(registeredPeerId)
          await sendFrame(
            client, mkAdvertise, encodeAdvertise(snapshot))
        of wkBlobs:
          discard
      of mkSwimProbe, mkSwimAck, mkSwimProbeReq, mkSwimProbeAckIndirect,
         mkSwimSuspect, mkSwimConfirm, mkSwimRefute:
        # Peer-Cache-Scale M0: SWIM frames are handled by the SWIM
        # engine's own transport, not by the M0 TCP server. Drop them
        # silently if they arrive on a TCP connection — production
        # code routes SWIM traffic out-of-band.
        discard
  except CatchableError:
    # Connection-level errors close the socket; the registry retains
    # the peer entry so a reconnection re-uses it.
    discard
  finally:
    try: client.close() except CatchableError: discard

proc acceptLoop(server: PeerCacheServer) {.async.} =
  while server.running:
    var client: AsyncSocket
    var remoteAddress: string
    var remotePort: Port
    try:
      (remoteAddress, client) = await server.listener.acceptAddr()
      remotePort = Port(0)  # acceptAddr returns address only
    except CatchableError:
      break
    if client.isNil:
      break
    if not inAllowlist(remoteAddress, server.allowlist):
      # CIDR rejection — close without responding. The remote sees
      # a clean TCP RST/FIN before any Hello reply, which is how the
      # M0 verification test asserts the rejection path.
      try: client.close() except CatchableError: discard
      continue
    server.activeConnections.add(client)
    asyncCheck handleConnection(server, client, remoteAddress)

proc start*(server: PeerCacheServer) =
  ## Opens the listening socket and spawns the accept loop.
  ## Re-reads `server.listenPort` after binding so callers can
  ## use port 0 to ask the OS for an ephemeral port (the test
  ## suite + loopback helper rely on this).
  if server.running:
    return
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

# ---------------------------------------------------------------------------
# Peer-Cache M2: UDP multicast receiver.
# ---------------------------------------------------------------------------

proc dialAnnouncedPeer(server: PeerCacheServer;
                       hello: Hello;
                       remoteAddress: string) {.async.} =
  ## After an inbound multicast announcement passes the CIDR check,
  ## open a TCP connection to the announced endpoint and complete the
  ## standard `mkHello` / `mkHelloOk` handshake. The accepted side
  ## (in this server) is a passive listener; here we explicitly act
  ## as the *dialer*, since the originator's announcement told us
  ## where to find them.
  ##
  ## Errors are swallowed — a stale announcement (peer went away
  ## between sending and our dial) is not a protocol violation, just
  ## a miss.
  if hello.peerId == server.selfPeerId:
    # Self-announce on loopback — `IP_MULTICAST_LOOP` delivers our
    # own packets back. Drop without warning.
    return
  if server.registry.hasPeer(hello.peerId):
    # Already discovered via a previous announcement; nothing more
    # to do. The TCP connection from the prior round still feeds the
    # registry advertisements.
    return
  var sock = newAsyncSocket()
  try:
    await sock.connect(remoteAddress, Port(hello.listenPort))
    # Send our own Hello.
    let ourHello = Hello(
      peerId: server.selfPeerId,
      listenPort: uint16(server.listenPort),
      capabilities: 0'u32)
    let helloFrame = encodeFrame(mkHello, encodeHello(ourHello))
    var helloStr = newString(helloFrame.len)
    for i, b in helloFrame:
      helloStr[i] = char(b)
    await sock.send(helloStr)
    # Read HelloOk (8-byte header then payload).
    let header = await sock.recv(8)
    if header.len != 8:
      try: sock.close() except CatchableError: discard
      return
    var hdrBytes = newSeq[byte](8)
    for i in 0 ..< 8:
      hdrBytes[i] = byte(ord(header[i]))
    var payloadLen: uint32 = 0
    for i in 0 ..< 4:
      payloadLen = payloadLen or (uint32(hdrBytes[4 + i]) shl uint32(i * 8))
    var frameBytes = hdrBytes
    if payloadLen > 0'u32:
      let payload = await sock.recv(int(payloadLen))
      if payload.len != int(payloadLen):
        try: sock.close() except CatchableError: discard
        return
      let prefix = frameBytes.len
      frameBytes.setLen(prefix + payload.len)
      for i in 0 ..< payload.len:
        frameBytes[prefix + i] = byte(ord(payload[i]))
    let okFrame = decodeFrame(frameBytes)
    if okFrame.messageKind != mkHelloOk:
      try: sock.close() except CatchableError: discard
      return
    let helloOk = decodeHelloOk(okFrame.payload)
    let endpoint = initEndpoint(remoteAddress, Port(hello.listenPort))
    server.registry.addPeer(helloOk.peerId, endpoint)
    # Drain one more frame (the initial advertise snapshot) so the
    # registry's blob set is primed. Best-effort.
    try:
      let advHeader = await sock.recv(8)
      if advHeader.len == 8:
        var ahBytes = newSeq[byte](8)
        for i in 0 ..< 8:
          ahBytes[i] = byte(ord(advHeader[i]))
        var advLen: uint32 = 0
        for i in 0 ..< 4:
          advLen = advLen or (uint32(ahBytes[4 + i]) shl uint32(i * 8))
        var advBytes = ahBytes
        if advLen > 0'u32:
          let advPayload = await sock.recv(int(advLen))
          for i in 0 ..< advPayload.len:
            advBytes.add(byte(ord(advPayload[i])))
        let advFrame = decodeFrame(advBytes)
        if advFrame.messageKind == mkAdvertise:
          server.registry.applyAdvertise(helloOk.peerId,
            decodeAdvertise(advFrame.payload))
    except CatchableError:
      discard
    # Close the dialer side. Future fetches go through the regular
    # `PeerCacheClient.requestFetch` path which opens its own
    # connection from the seed-list / multicast-derived endpoints —
    # by the time we add the peer to the registry the client side
    # can dial them on the next round. M3 may merge the dialer +
    # long-lived connection holders.
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
        try:
          stderr.writeLine(
            "peer-cache: dropping multicast announcement from " &
            triple.address & " (peer " & $hello.peerId &
            ") — outside configured CIDR allowlist")
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
