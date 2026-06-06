## Peer-cache TCP client — Peer-Cache M0.
##
## `asyncnet` + `asyncdispatch` based client. `start` dials each seed
## peer, completes the `mkHello` / `mkHelloOk` handshake, registers
## the remote peer ID + endpoint with the local registry, and reads
## the initial `mkAdvertise` snapshot. Connections are kept open
## (one per peer) so subsequent fetch requests and advertisements
## reuse them; `stop` sends `mkGoodbye` to each peer and closes.

import std/[asyncdispatch, asyncnet, nativesockets, tables]

import ./codec
import ./registry
import ./server  # for inAllowlist + CidrV4
import ./types

type
  PeerCacheClient* = ref object
    selfPeerId*: PeerId
    listenPort*: uint16
    registry*: PeerRegistry
    seedPeers*: seq[Endpoint]
    allowlist*: seq[CidrV4]
    connections: Table[PeerId, AsyncSocket]
    running: bool

  PeerCacheClientError* = object of CatchableError

proc newPeerCacheClient*(selfPeerId: PeerId;
                        listenPort: uint16;
                        registry: PeerRegistry;
                        seedPeers: openArray[Endpoint];
                        cidrAllowlist: openArray[CidrV4]): PeerCacheClient =
  result = PeerCacheClient(
    selfPeerId: selfPeerId,
    listenPort: listenPort,
    registry: registry,
    seedPeers: @seedPeers,
    allowlist: @cidrAllowlist,
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

proc readerLoop(client: PeerCacheClient; sock: AsyncSocket;
                peerId: PeerId) {.async.} =
  ## After the handshake, keep reading framed messages — applying
  ## advertise updates, responding to ping, processing fetch
  ## responses (M1). M0 honours advertise + ping + goodbye.
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
      of mkPing:
        await sendFrame(sock, mkPong, encodePong(Pong()))
      of mkPong:
        client.registry.updateLastSeen(peerId)
      of mkGoodbye:
        break
      of mkFetchResponse, mkWant, mkHello, mkHelloOk, mkFetchRequest:
        # M0: surfaces these in M1. Drop silently for now.
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

proc stop*(client: PeerCacheClient) {.async.} =
  ## Sends Goodbye to each connected peer and closes the connections.
  client.running = false
  for peerId, sock in client.connections.pairs:
    try:
      await sendFrame(sock, mkGoodbye, encodeGoodbye(Goodbye()))
    except CatchableError:
      discard
    try: sock.close() except CatchableError: discard
  client.connections.clear()
