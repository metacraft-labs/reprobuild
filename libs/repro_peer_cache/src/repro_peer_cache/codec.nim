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

const
  PeerCacheProtocolVersion* = 1'u16
    ## Wire-protocol version used by the M0 framing helpers
    ## (`encodeFrame`). Peer-Cache-Scale M1 introduces a v2 advertise
    ## payload carried in a frame stamped with
    ## `PeerCacheProtocolVersionV2`; both versions coexist during the
    ## migration window described in
    ## `reprobuild-specs/Peer-Cache-Scale.md` §"Cuckoo-filter
    ## advertisements".
  PeerCacheProtocolVersionV2* = 2'u16
    ## Wire-protocol version stamped on `mkAdvertiseV2` frames. A v2
    ## decoder accepts both v1 and v2 frames; a v1-only decoder rejects
    ## v2 frames as "unsupported version" via the existing
    ## `decodeFrame` version check.

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
  result.writeBool(msg.capTier2)

proc decodeHello*(data: openArray[byte]): Hello =
  var pos = 0
  result.peerId = readPeerId(data, pos)
  result.listenPort = readU16(data, pos)
  result.capabilities = readU32(data, pos)
  # Peer-Cache-Scale M2: `capTier2` bit appended to the v1 payload.
  # A v1-only sender omits this byte; treat the truncated tail as
  # `capTier2 = false` so legacy peers keep handshaking cleanly.
  if pos < data.len:
    result.capTier2 = readBool(data, pos)
  else:
    result.capTier2 = false
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after Hello payload: " & $(data.len - pos))

proc encodeHelloOk*(msg: HelloOk): seq[byte] =
  result = @[]
  result.writePeerId(msg.peerId)
  result.writeU16(msg.protocolVersion)
  result.writeU64(msg.maxBlobBytes)
  result.writeBool(msg.capTier2)

proc decodeHelloOk*(data: openArray[byte]): HelloOk =
  var pos = 0
  result.peerId = readPeerId(data, pos)
  result.protocolVersion = readU16(data, pos)
  result.maxBlobBytes = readU64(data, pos)
  # Peer-Cache-Scale M2: optional `capTier2` tail (see decodeHello).
  if pos < data.len:
    result.capTier2 = readBool(data, pos)
  else:
    result.capTier2 = false
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

proc encodeAdvertiseV2*(msg: AdvertiseV2): seq[byte] =
  ## Peer-Cache-Scale M1 v2 advertise payload. The serialised cuckoo
  ## filter is carried verbatim with an explicit length prefix; the
  ## `filterCapacity` and `filterCount` fields are echoed from the
  ## sender's filter state so receivers can sanity-check before
  ## deserialising.
  ##
  ## Peer-Cache-BearSSL M1: the optional trailing `signature` field is
  ## length-prefixed. A `tmCidr` sender writes a zero-length signature
  ## (1 byte: `0x00 0x00 0x00 0x00`); a `tmTls` sender writes the 64-byte
  ## ECDSA-P256 raw signature produced by `auth.signMessage`. A decoder
  ## reading a frame that lacks the trailing length prefix entirely
  ## (early v2 callers from M1/M2 written before this milestone)
  ## interprets the missing bytes as an empty signature.
  result = @[]
  result.writeU64(msg.sequence)
  result.writeU8(uint8(ord(msg.mode)))
  result.writeU32(msg.filterCapacity)
  result.writeU32(msg.filterCount)
  result.writeU32(uint32(msg.filterBytes.len))
  for b in msg.filterBytes:
    result.add(b)
  result.writeU32(uint32(msg.signature.len))
  for b in msg.signature:
    result.add(b)

proc decodeAdvertiseV2*(data: openArray[byte]): AdvertiseV2 =
  var pos = 0
  result.sequence = readU64(data, pos)
  let modeRaw = readU8(data, pos)
  if modeRaw > uint8(ord(high(AdvertiseMode))):
    raise newException(PeerCacheCodecError,
      "AdvertiseV2 mode tag out of range: " & $modeRaw)
  result.mode = AdvertiseMode(modeRaw)
  result.filterCapacity = readU32(data, pos)
  result.filterCount = readU32(data, pos)
  let filterLen = int(readU32(data, pos))
  ensureBytes(data.len - pos, filterLen, "AdvertiseV2 filter bytes")
  result.filterBytes = newSeq[byte](filterLen)
  for i in 0 ..< filterLen:
    result.filterBytes[i] = data[pos + i]
  inc pos, filterLen
  # Peer-Cache-Scale M3: the trailing signature is optional. A frame
  # encoded before the M3 codec landed has `pos == data.len` here and
  # we treat the signature as empty for backward compatibility with v1
  # + M2 peers.
  if pos < data.len:
    let sigLen = int(readU32(data, pos))
    ensureBytes(data.len - pos, sigLen, "AdvertiseV2 signature bytes")
    result.signature = newSeq[byte](sigLen)
    for i in 0 ..< sigLen:
      result.signature[i] = data[pos + i]
    inc pos, sigLen
  else:
    result.signature = @[]
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after AdvertiseV2 payload: " & $(data.len - pos))

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
# Peer-Cache-Scale M0: SWIM record codecs.
#
# Each variable-length field is length-prefixed with a `uint32` count
# (matching the M0 advertise payloads). Endpoints carry a length-prefixed
# host string + a `uint16` port. Member entries are fixed-size apart from
# their host string.
# ---------------------------------------------------------------------------

proc writeString(buf: var seq[byte]; value: string) =
  buf.writeU32(uint32(value.len))
  for ch in value:
    buf.add(byte(ord(ch)))

proc readString(data: openArray[byte]; pos: var int): string =
  let length = int(readU32(data, pos))
  ensureBytes(data.len - pos, length, "string bytes")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(data[pos + i])
  inc pos, length

proc writeEndpoint(buf: var seq[byte]; endpoint: Endpoint) =
  buf.writeString(endpoint.host)
  buf.writeU16(uint16(endpoint.port))

proc readEndpoint(data: openArray[byte]; pos: var int): Endpoint =
  let host = readString(data, pos)
  let port = readU16(data, pos)
  initEndpoint(host, Port(port))

proc writeSwimMember(buf: var seq[byte]; member: SwimMember) =
  buf.writePeerId(member.peerId)
  buf.writeEndpoint(member.endpoint)
  buf.writeU8(uint8(ord(member.status)))
  buf.writeU64(member.incarnation)

proc readSwimMember(data: openArray[byte]; pos: var int): SwimMember =
  result.peerId = readPeerId(data, pos)
  result.endpoint = readEndpoint(data, pos)
  let statusRaw = readU8(data, pos)
  if statusRaw > uint8(ord(high(SwimMemberStatus))):
    raise newException(PeerCacheCodecError,
      "SwimMember status tag out of range: " & $statusRaw)
  result.status = SwimMemberStatus(statusRaw)
  result.incarnation = readU64(data, pos)

proc writeGossip(buf: var seq[byte]; gossip: seq[SwimMember]) =
  buf.writeU32(uint32(gossip.len))
  for member in gossip:
    buf.writeSwimMember(member)

proc readGossip(data: openArray[byte]; pos: var int): seq[SwimMember] =
  let count = int(readU32(data, pos))
  result = newSeq[SwimMember](count)
  for i in 0 ..< count:
    result[i] = readSwimMember(data, pos)

proc encodeSwimProbe*(msg: SwimProbe): seq[byte] =
  result = @[]
  result.writePeerId(msg.sourcePeerId)
  result.writeEndpoint(msg.sourceEndpoint)
  result.writePeerId(msg.targetPeerId)
  result.writeU64(msg.sourceIncarnation)
  result.writeGossip(msg.gossip)

proc decodeSwimProbe*(data: openArray[byte]): SwimProbe =
  var pos = 0
  result.sourcePeerId = readPeerId(data, pos)
  result.sourceEndpoint = readEndpoint(data, pos)
  result.targetPeerId = readPeerId(data, pos)
  result.sourceIncarnation = readU64(data, pos)
  result.gossip = readGossip(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimProbe payload: " & $(data.len - pos))

proc encodeSwimAck*(msg: SwimAck): seq[byte] =
  result = @[]
  result.writePeerId(msg.responderPeerId)
  result.writeEndpoint(msg.responderEndpoint)
  result.writeU64(msg.responderIncarnation)
  result.writeGossip(msg.gossip)

proc decodeSwimAck*(data: openArray[byte]): SwimAck =
  var pos = 0
  result.responderPeerId = readPeerId(data, pos)
  result.responderEndpoint = readEndpoint(data, pos)
  result.responderIncarnation = readU64(data, pos)
  result.gossip = readGossip(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimAck payload: " & $(data.len - pos))

proc encodeSwimProbeReq*(msg: SwimProbeReq): seq[byte] =
  result = @[]
  result.writePeerId(msg.initiatorPeerId)
  result.writeEndpoint(msg.initiatorEndpoint)
  result.writePeerId(msg.targetPeerId)
  result.writeEndpoint(msg.targetEndpoint)
  result.writeGossip(msg.gossip)

proc decodeSwimProbeReq*(data: openArray[byte]): SwimProbeReq =
  var pos = 0
  result.initiatorPeerId = readPeerId(data, pos)
  result.initiatorEndpoint = readEndpoint(data, pos)
  result.targetPeerId = readPeerId(data, pos)
  result.targetEndpoint = readEndpoint(data, pos)
  result.gossip = readGossip(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimProbeReq payload: " & $(data.len - pos))

proc encodeSwimProbeAckIndirect*(msg: SwimProbeAckIndirect): seq[byte] =
  result = @[]
  result.writePeerId(msg.initiatorPeerId)
  result.writePeerId(msg.targetPeerId)
  result.writePeerId(msg.intermediaryPeerId)
  result.writeU64(msg.targetIncarnation)
  result.writeGossip(msg.gossip)

proc decodeSwimProbeAckIndirect*(data: openArray[byte]): SwimProbeAckIndirect =
  var pos = 0
  result.initiatorPeerId = readPeerId(data, pos)
  result.targetPeerId = readPeerId(data, pos)
  result.intermediaryPeerId = readPeerId(data, pos)
  result.targetIncarnation = readU64(data, pos)
  result.gossip = readGossip(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimProbeAckIndirect payload: " & $(data.len - pos))

# Single-member dissemination frames — same record shape as one entry in
# the gossip seq. Used when a node wants to broadcast a state change
# eagerly rather than wait for the next probe/ack round to piggyback it.

# Peer-Cache-BearSSL M3: the M3-era `encodeAuthChallenge` /
# `decodeAuthChallenge` / `encodeAuthResponse` / `decodeAuthResponse`
# codecs were deleted in this milestone. `tmTls` carries no in-
# protocol auth frames — TLS handshakes run below the framing layer.

proc encodeSwimSuspect*(msg: SwimMember): seq[byte] =
  result = @[]
  result.writeSwimMember(msg)

proc decodeSwimSuspect*(data: openArray[byte]): SwimMember =
  var pos = 0
  result = readSwimMember(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimSuspect payload: " & $(data.len - pos))

proc encodeSwimConfirm*(msg: SwimMember): seq[byte] =
  result = @[]
  result.writeSwimMember(msg)

proc decodeSwimConfirm*(data: openArray[byte]): SwimMember =
  var pos = 0
  result = readSwimMember(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimConfirm payload: " & $(data.len - pos))

proc encodeSwimRefute*(msg: SwimMember): seq[byte] =
  result = @[]
  result.writeSwimMember(msg)

proc decodeSwimRefute*(data: openArray[byte]): SwimMember =
  var pos = 0
  result = readSwimMember(data, pos)
  if pos != data.len:
    raise newException(PeerCacheCodecError,
      "trailing bytes after SwimRefute payload: " & $(data.len - pos))

# ---------------------------------------------------------------------------
# Frame encode / decode.
# ---------------------------------------------------------------------------

proc encodeFrame*(messageKind: MessageKind; payload: openArray[byte]):
    seq[byte] =
  ## Encodes a complete on-the-wire frame: version + kind + payloadLen +
  ## payload bytes. Defaults to wire-protocol version 1 for legacy
  ## message kinds; `mkAdvertiseV2` is stamped with version 2 so the
  ## migration-window decoder logic can route on `Frame.version`.
  result = @[]
  let version =
    if messageKind == mkAdvertiseV2: PeerCacheProtocolVersionV2
    else: PeerCacheProtocolVersion
  result.writeU16(version)
  result.writeU16(uint16(ord(messageKind)))
  result.writeU32(uint32(payload.len))
  for b in payload:
    result.add(b)

proc decodeFrame*(data: openArray[byte]): Frame =
  ## Decodes a complete on-the-wire frame. Raises `PeerCacheCodecError`
  ## on unsupported wire-protocol version, unknown message-kind tag,
  ## or payload-length mismatch.
  ##
  ## Version routing: v1 is the default for every message kind except
  ## `mkAdvertiseV2`; v2 is the only valid framing for `mkAdvertiseV2`.
  ## A v2 frame carrying any other kind is rejected as a version
  ## mismatch — this preserves the M0 "version != 1" guard for legacy
  ## message kinds while opening the v2 channel exclusively for the
  ## cuckoo-filter advertise payload.
  var pos = 0
  let version = readU16(data, pos)
  let kindRaw = readU16(data, pos)
  if kindRaw > uint16(ord(high(MessageKind))):
    raise newException(PeerCacheCodecError,
      "unknown peer-cache message kind: " & $kindRaw)
  let kind = MessageKind(kindRaw)
  let expectedVersion =
    if kind == mkAdvertiseV2: PeerCacheProtocolVersionV2
    else: PeerCacheProtocolVersion
  if version != expectedVersion:
    raise newException(PeerCacheCodecError,
      "unsupported peer-cache protocol version: observed " & $version &
      ", expected " & $expectedVersion & " for message kind " & $kind)
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
  AdvertiseV2Handler*   = proc (msg: AdvertiseV2)   {.gcsafe, closure.}
  WantHandler*          = proc (msg: Want)          {.gcsafe, closure.}
  FetchRequestHandler*  = proc (msg: FetchRequest)  {.gcsafe, closure.}
  FetchResponseHandler* = proc (msg: FetchResponse) {.gcsafe, closure.}
  PingHandler*          = proc (msg: Ping)          {.gcsafe, closure.}
  PongHandler*          = proc (msg: Pong)          {.gcsafe, closure.}
  GoodbyeHandler*       = proc (msg: Goodbye)       {.gcsafe, closure.}
  SwimProbeHandler*     = proc (msg: SwimProbe)     {.gcsafe, closure.}
  SwimAckHandler*       = proc (msg: SwimAck)       {.gcsafe, closure.}
  SwimProbeReqHandler*  = proc (msg: SwimProbeReq)  {.gcsafe, closure.}
  SwimProbeAckIndirectHandler* =
    proc (msg: SwimProbeAckIndirect) {.gcsafe, closure.}
  SwimSuspectHandler*   = proc (msg: SwimMember)    {.gcsafe, closure.}
  SwimConfirmHandler*   = proc (msg: SwimMember)    {.gcsafe, closure.}
  SwimRefuteHandler*    = proc (msg: SwimMember)    {.gcsafe, closure.}

proc dispatch*(frame: Frame;
               onHello: HelloHandler = nil;
               onHelloOk: HelloOkHandler = nil;
               onAdvertise: AdvertiseHandler = nil;
               onAdvertiseV2: AdvertiseV2Handler = nil;
               onWant: WantHandler = nil;
               onFetchRequest: FetchRequestHandler = nil;
               onFetchResponse: FetchResponseHandler = nil;
               onPing: PingHandler = nil;
               onPong: PongHandler = nil;
               onGoodbye: GoodbyeHandler = nil;
               onSwimProbe: SwimProbeHandler = nil;
               onSwimAck: SwimAckHandler = nil;
               onSwimProbeReq: SwimProbeReqHandler = nil;
               onSwimProbeAckIndirect: SwimProbeAckIndirectHandler = nil;
               onSwimSuspect: SwimSuspectHandler = nil;
               onSwimConfirm: SwimConfirmHandler = nil;
               onSwimRefute: SwimRefuteHandler = nil) =
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
  of mkAdvertiseV2:
    if not onAdvertiseV2.isNil:
      onAdvertiseV2(decodeAdvertiseV2(frame.payload))
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
  of mkSwimProbe:
    if not onSwimProbe.isNil:
      onSwimProbe(decodeSwimProbe(frame.payload))
  of mkSwimAck:
    if not onSwimAck.isNil:
      onSwimAck(decodeSwimAck(frame.payload))
  of mkSwimProbeReq:
    if not onSwimProbeReq.isNil:
      onSwimProbeReq(decodeSwimProbeReq(frame.payload))
  of mkSwimProbeAckIndirect:
    if not onSwimProbeAckIndirect.isNil:
      onSwimProbeAckIndirect(decodeSwimProbeAckIndirect(frame.payload))
  of mkSwimSuspect:
    if not onSwimSuspect.isNil:
      onSwimSuspect(decodeSwimSuspect(frame.payload))
  of mkSwimConfirm:
    if not onSwimConfirm.isNil:
      onSwimConfirm(decodeSwimConfirm(frame.payload))
  of mkSwimRefute:
    if not onSwimRefute.isNil:
      onSwimRefute(decodeSwimRefute(frame.payload))

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
