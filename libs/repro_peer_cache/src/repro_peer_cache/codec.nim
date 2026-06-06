## Peer-cache wire codec — Peer-Cache M0.
##
## Frame shape (from `Peer-Cache.md` §"Wire shape"):
##
##   uint16 version       // current = 1
##   uint16 messageKind   // MessageKind enum tag
##   uint32 payloadLen
##   bytes  payload[payloadLen]
##
## Per-message payloads are fixed-shape records (length-prefixed for
## variable-length sequences) following the same little-endian
## SSZ-style pattern `runquota_codec` uses. The choice over the
## macro-driven `ssz-serialization` library: messages are small and
## fixed, so a hand-rolled encoder ships less code and stays
## debuggable byte-for-byte under cross-platform fuzzing.

import std/strutils

import ./types

const PeerCacheProtocolVersion* = 1'u16

type
  PeerCacheCodecError* = object of CatchableError
    ## Raised on any malformed peer-cache frame or payload.

  Frame* = object
    version*: uint16
    messageKind*: MessageKind
    payloadLen*: uint32
    payload*: seq[byte]

# ---------------------------------------------------------------------------
# Low-level little-endian primitives.
# ---------------------------------------------------------------------------

proc writeU8(buf: var seq[byte]; value: uint8) =
  buf.add(value)

proc writeU16(buf: var seq[byte]; value: uint16) =
  buf.add(byte(value and 0xff'u16))
  buf.add(byte((value shr 8) and 0xff'u16))

proc writeU32(buf: var seq[byte]; value: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((value shr uint32(shift)) and 0xff'u32))

proc writeU64(buf: var seq[byte]; value: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((value shr uint64(shift)) and 0xff'u64))

proc writeBool(buf: var seq[byte]; value: bool) =
  buf.writeU8(if value: 1'u8 else: 0'u8)

proc writeDigest(buf: var seq[byte]; digest: BlobDigest) =
  let raw = bytes(digest)
  for b in raw:
    buf.add(b)

proc writePeerId(buf: var seq[byte]; peerId: PeerId) =
  let raw = bytes(peerId)
  for b in raw:
    buf.add(b)

template ensureBytes(remaining: int; needed: int; what: string) =
  if remaining < needed:
    raise newException(PeerCacheCodecError,
      "peer-cache frame too short to read " & what & ": need " &
      $needed & " bytes, have " & $remaining)

proc readU8(data: openArray[byte]; pos: var int): uint8 =
  ensureBytes(data.len - pos, 1, "uint8")
  result = data[pos]
  inc pos

proc readU16(data: openArray[byte]; pos: var int): uint16 =
  ensureBytes(data.len - pos, 2, "uint16")
  result = uint16(data[pos]) or (uint16(data[pos + 1]) shl 8)
  inc pos, 2

proc readU32(data: openArray[byte]; pos: var int): uint32 =
  ensureBytes(data.len - pos, 4, "uint32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(data[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readU64(data: openArray[byte]; pos: var int): uint64 =
  ensureBytes(data.len - pos, 8, "uint64")
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(data[pos + i]) shl uint64(i * 8))
  inc pos, 8

proc readBool(data: openArray[byte]; pos: var int): bool =
  let raw = readU8(data, pos)
  if raw notin {0'u8, 1'u8}:
    raise newException(PeerCacheCodecError,
      "peer-cache bool tag out of range: " & $raw)
  raw != 0'u8

proc readDigest(data: openArray[byte]; pos: var int): BlobDigest =
  ensureBytes(data.len - pos, 32, "BlobDigest")
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = data[pos + i]
  inc pos, 32
  blobDigestFromBytes(raw)

proc readPeerId(data: openArray[byte]; pos: var int): PeerId =
  ensureBytes(data.len - pos, 32, "PeerId")
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = data[pos + i]
  inc pos, 32
  peerIdFromBytes(raw)

# ---------------------------------------------------------------------------
# Per-message payload encoders / decoders.
# ---------------------------------------------------------------------------

proc encodeHello*(msg: Hello): seq[byte] =
  result = @[]
  result.writePeerId(msg.peerId)
  result.writeU16(msg.listenPort)
  result.writeU32(msg.capabilities)

proc decodeHello*(data: openArray[byte]): Hello =
  var pos = 0
  result.peerId = readPeerId(data, pos)
  result.listenPort = readU16(data, pos)
  result.capabilities = readU32(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after Hello payload: " & $(data.len - pos))

proc encodeHelloOk*(msg: HelloOk): seq[byte] =
  result = @[]
  result.writePeerId(msg.peerId)
  result.writeU16(msg.protocolVersion)
  result.writeU64(msg.maxBlobBytes)

proc decodeHelloOk*(data: openArray[byte]): HelloOk =
  var pos = 0
  result.peerId = readPeerId(data, pos)
  result.protocolVersion = readU16(data, pos)
  result.maxBlobBytes = readU64(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after HelloOk payload: " & $(data.len - pos))

proc encodeAdvertise*(msg: Advertise): seq[byte] =
  result = @[]
  result.writeU64(msg.sequence)
  result.writeU8(uint8(ord(msg.mode)))
  result.writeU32(uint32(msg.added.len))
  for d in msg.added:
    result.writeDigest(d)
  result.writeU32(uint32(msg.removed.len))
  for d in msg.removed:
    result.writeDigest(d)

proc decodeAdvertise*(data: openArray[byte]): Advertise =
  var pos = 0
  result.sequence = readU64(data, pos)
  let modeRaw = readU8(data, pos)
  if modeRaw > uint8(ord(high(AdvertiseMode))):
    raise newException(PeerCacheCodecError,
      "Advertise mode tag out of range: " & $modeRaw)
  result.mode = AdvertiseMode(modeRaw)
  let addedLen = int(readU32(data, pos))
  result.added = newSeq[BlobDigest](addedLen)
  for i in 0 ..< addedLen:
    result.added[i] = readDigest(data, pos)
  let removedLen = int(readU32(data, pos))
  result.removed = newSeq[BlobDigest](removedLen)
  for i in 0 ..< removedLen:
    result.removed[i] = readDigest(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after Advertise payload: " & $(data.len - pos))

proc encodeWant*(msg: Want): seq[byte] =
  result = @[]
  result.writeU8(uint8(ord(msg.kind)))
  result.writeU32(uint32(msg.digests.len))
  for d in msg.digests:
    result.writeDigest(d)

proc decodeWant*(data: openArray[byte]): Want =
  var pos = 0
  let kindRaw = readU8(data, pos)
  if kindRaw > uint8(ord(high(WantKind))):
    raise newException(PeerCacheCodecError,
      "Want kind tag out of range: " & $kindRaw)
  result.kind = WantKind(kindRaw)
  let count = int(readU32(data, pos))
  result.digests = newSeq[BlobDigest](count)
  for i in 0 ..< count:
    result.digests[i] = readDigest(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after Want payload: " & $(data.len - pos))

proc encodeFetchRequest*(msg: FetchRequest): seq[byte] =
  result = @[]
  result.writeDigest(msg.digest)

proc decodeFetchRequest*(data: openArray[byte]): FetchRequest =
  var pos = 0
  result.digest = readDigest(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after FetchRequest payload: " & $(data.len - pos))

proc encodeFetchResponse*(msg: FetchResponse): seq[byte] =
  result = @[]
  result.writeDigest(msg.digest)
  result.writeBool(msg.truncated)
  result.writeU32(uint32(msg.payload.len))
  for b in msg.payload:
    result.add(b)

proc decodeFetchResponse*(data: openArray[byte]): FetchResponse =
  var pos = 0
  result.digest = readDigest(data, pos)
  result.truncated = readBool(data, pos)
  let payloadLen = int(readU32(data, pos))
  ensureBytes(data.len - pos, payloadLen, "FetchResponse payload bytes")
  result.payload = newSeq[byte](payloadLen)
  for i in 0 ..< payloadLen:
    result.payload[i] = data[pos + i]
  inc pos, payloadLen
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after FetchResponse payload: " & $(data.len - pos))

proc encodePing*(msg: Ping): seq[byte] =
  result = @[]

proc decodePing*(data: openArray[byte]): Ping =
  if data.len != 0:
    raise newException(PeerCacheCodecError,
      "Ping payload must be empty, got " & $data.len & " bytes")

proc encodePong*(msg: Pong): seq[byte] =
  result = @[]

proc decodePong*(data: openArray[byte]): Pong =
  if data.len != 0:
    raise newException(PeerCacheCodecError,
      "Pong payload must be empty, got " & $data.len & " bytes")

proc encodeGoodbye*(msg: Goodbye): seq[byte] =
  result = @[]

proc decodeGoodbye*(data: openArray[byte]): Goodbye =
  if data.len != 0:
    raise newException(PeerCacheCodecError,
      "Goodbye payload must be empty, got " & $data.len & " bytes")

# ---------------------------------------------------------------------------
# Frame encode / decode.
# ---------------------------------------------------------------------------

proc encodeFrame*(messageKind: MessageKind; payload: openArray[byte]):
    seq[byte] =
  ## Encodes a complete on-the-wire frame: version + kind + payloadLen +
  ## payload bytes. Always emits version = 1.
  result = @[]
  result.writeU16(PeerCacheProtocolVersion)
  result.writeU16(uint16(ord(messageKind)))
  result.writeU32(uint32(payload.len))
  for b in payload:
    result.add(b)

proc decodeFrame*(data: openArray[byte]): Frame =
  ## Decodes a complete on-the-wire frame. Raises `PeerCacheCodecError`
  ## on version mismatch (with the observed version in the message),
  ## unknown message-kind tag, or payload-length mismatch.
  var pos = 0
  let version = readU16(data, pos)
  if version != PeerCacheProtocolVersion:
    raise newException(PeerCacheCodecError,
      "unsupported peer-cache protocol version: observed " & $version &
      ", expected " & $PeerCacheProtocolVersion)
  let kindRaw = readU16(data, pos)
  if kindRaw > uint16(ord(high(MessageKind))):
    raise newException(PeerCacheCodecError,
      "unknown peer-cache message kind: " & $kindRaw)
  let payloadLen = readU32(data, pos)
  ensureBytes(data.len - pos, int(payloadLen), "frame payload")
  var payload = newSeq[byte](int(payloadLen))
  for i in 0 ..< int(payloadLen):
    payload[i] = data[pos + i]
  inc pos, int(payloadLen)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after peer-cache frame: " & $(data.len - pos))
  Frame(
    version: version,
    messageKind: MessageKind(kindRaw),
    payloadLen: payloadLen,
    payload: payload)

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------

type
  HelloHandler*         = proc (msg: Hello)         {.gcsafe, closure.}
  HelloOkHandler*       = proc (msg: HelloOk)       {.gcsafe, closure.}
  AdvertiseHandler*     = proc (msg: Advertise)     {.gcsafe, closure.}
  WantHandler*          = proc (msg: Want)          {.gcsafe, closure.}
  FetchRequestHandler*  = proc (msg: FetchRequest)  {.gcsafe, closure.}
  FetchResponseHandler* = proc (msg: FetchResponse) {.gcsafe, closure.}
  PingHandler*          = proc (msg: Ping)          {.gcsafe, closure.}
  PongHandler*          = proc (msg: Pong)          {.gcsafe, closure.}
  GoodbyeHandler*       = proc (msg: Goodbye)       {.gcsafe, closure.}

proc dispatch*(frame: Frame;
               onHello: HelloHandler = nil;
               onHelloOk: HelloOkHandler = nil;
               onAdvertise: AdvertiseHandler = nil;
               onWant: WantHandler = nil;
               onFetchRequest: FetchRequestHandler = nil;
               onFetchResponse: FetchResponseHandler = nil;
               onPing: PingHandler = nil;
               onPong: PongHandler = nil;
               onGoodbye: GoodbyeHandler = nil) =
  ## Decodes the frame's payload to the concrete record type and invokes
  ## the matching handler. Handlers default to `nil`, in which case the
  ## frame for that kind is silently dropped — useful for the test
  ## suite's per-kind round-trip checks and for client/server code paths
  ## that only react to a subset of the protocol.
  case frame.messageKind
  of mkHello:
    if not onHello.isNil:
      onHello(decodeHello(frame.payload))
  of mkHelloOk:
    if not onHelloOk.isNil:
      onHelloOk(decodeHelloOk(frame.payload))
  of mkAdvertise:
    if not onAdvertise.isNil:
      onAdvertise(decodeAdvertise(frame.payload))
  of mkWant:
    if not onWant.isNil:
      onWant(decodeWant(frame.payload))
  of mkFetchRequest:
    if not onFetchRequest.isNil:
      onFetchRequest(decodeFetchRequest(frame.payload))
  of mkFetchResponse:
    if not onFetchResponse.isNil:
      onFetchResponse(decodeFetchResponse(frame.payload))
  of mkPing:
    if not onPing.isNil:
      onPing(decodePing(frame.payload))
  of mkPong:
    if not onPong.isNil:
      onPong(decodePong(frame.payload))
  of mkGoodbye:
    if not onGoodbye.isNil:
      onGoodbye(decodeGoodbye(frame.payload))

# ---------------------------------------------------------------------------
# Hex helpers — useful for diagnostics + test failure messages.
# ---------------------------------------------------------------------------

proc toHexLower*(bytes: openArray[byte]): string =
  result = newString(bytes.len * 2)
  const HexChars = "0123456789abcdef"
  for i, b in bytes:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc fromHexLower*(hex: string): seq[byte] =
  if (hex.len mod 2) != 0:
    raise newException(PeerCacheCodecError,
      "hex string length must be even, got " & $hex.len)
  result = newSeq[byte](hex.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
