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

import std/[asyncdispatch, asyncnet, nativesockets, net, strutils]

import ./codec
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
    listener: AsyncSocket
    running: bool
    activeConnections: seq[AsyncSocket]
      ## Tracked so `stop()` can drain them cleanly. Closed connections
      ## are pruned lazily on next start/stop pass.

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
                         maxBlobBytes: uint64 = DefaultMaxBlobBytes):
                         PeerCacheServer =
  result = PeerCacheServer(
    selfPeerId: selfPeerId,
    listenAddr: listenAddr,
    listenPort: listenPort,
    registry: registry,
    allowlist: @cidrAllowlist,
    maxBlobBytes: maxBlobBytes,
    listener: nil,
    running: false,
    activeConnections: @[])

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
      of mkPing:
        await sendFrame(client, mkPong, encodePong(Pong()))
      of mkPong:
        if hasRegisteredPeer:
          server.registry.updateLastSeen(registeredPeerId)
      of mkGoodbye:
        break
      of mkFetchRequest:
        # M0 stub: respond truncated. M1 wires this to the local store.
        let req = decodeFetchRequest(frame.payload)
        let resp = FetchResponse(
          digest: req.digest,
          truncated: true,
          payload: @[])
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
        # M0 acknowledges but does not act on Want.
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
  asyncCheck acceptLoop(server)

proc stop*(server: PeerCacheServer) =
  ## Closes the listener and drops active connections. Idempotent.
  if not server.running:
    return
  server.running = false
  if not server.listener.isNil:
    try: server.listener.close() except CatchableError: discard
    server.listener = nil
  for conn in server.activeConnections:
    try: conn.close() except CatchableError: discard
  server.activeConnections.setLen(0)

proc actualPort*(server: PeerCacheServer): Port =
  server.listenPort
