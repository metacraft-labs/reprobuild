import std/[net, os, strutils]

import repro_core

when defined(posix):
  import std/posix

const
  StoreDaemonProtocolVersion* = 1'u16
  StoreDaemonProfileDev* = "development-store"
  StoreDaemonCapabilities* = "realize,register_root,query,gc,status"
  FrameMagic = "RBSD"

type
  StoreDaemonMessageKind* = enum
    sdkHello = 1
    sdkHelloAck = 2
    sdkStatus = 3
    sdkStatusResponse = 4
    sdkSyntheticRealize = 5
    sdkRealizeResponse = 6
    sdkReleaseRoot = 7
    sdkReleaseRootAck = 8
    sdkShutdown = 9
    sdkShutdownAck = 10
    sdkError = 255

  StoreDaemonStatus* = object
    running*: bool
    protocolVersion*: uint16
    daemonProfile*: string
    endpoint*: string
    storeRoot*: string
    pid*: int64
    uptimeSeconds*: int64
    realizedPrefixCount*: int
    rootCount*: int
    pendingRealizationCount*: int

  StoreDaemonRealizeResult* = object
    status*: string
    realizedPrefixPath*: string
    realizationHashHex*: string
    rootId*: string
    writerMode*: string

  SyntheticRealizeRequest* = object
    storeRoot*: string
    realizationIdHex*: string
    packageName*: string
    version*: string
    payload*: string
    holderId*: string
    rootId*: string
    delayMs*: int

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc textOf(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc writeBool(buf: var seq[byte]; value: bool) =
  buf.add(if value: 1'u8 else: 0'u8)

proc readBool(buf: openArray[byte]; pos: var int): bool =
  if pos >= buf.len:
    raise newException(ValueError, "truncated boolean")
  result = buf[pos] != 0
  inc pos

proc writeI64(buf: var seq[byte]; value: int64) =
  buf.writeU64Le(uint64(value))

proc readI64(buf: openArray[byte]; pos: var int): int64 =
  int64(buf.readU64Le(pos))

proc writeFrame*(socket: Socket; kind: StoreDaemonMessageKind;
                 body: openArray[byte] = []) =
  var frame: seq[byte] = @[]
  for ch in FrameMagic:
    frame.add(byte(ord(ch)))
  frame.writeU16Le(StoreDaemonProtocolVersion)
  frame.writeU16Le(uint16(ord(kind)))
  frame.writeU32Le(uint32(body.len))
  frame.add(body)
  socket.send(frame.textOf())

proc recvExact(socket: Socket; byteCount: int): seq[byte] =
  result = newSeqOfCap[byte](byteCount)
  while result.len < byteCount:
    let chunk = socket.recv(byteCount - result.len)
    if chunk.len == 0:
      raise newException(IOError, "unexpected EOF reading store-daemon frame")
    for ch in chunk:
      result.add(byte(ord(ch)))

proc readFrame*(socket: Socket): tuple[kind: StoreDaemonMessageKind;
                                      body: seq[byte]] =
  let header = socket.recvExact(12)
  for i in 0 ..< 4:
    if header[i] != byte(ord(FrameMagic[i])):
      raise newException(ValueError, "bad store-daemon frame magic")
  var pos = 4
  let version = header.readU16Le(pos)
  if version != StoreDaemonProtocolVersion:
    raise newException(ValueError,
      "unsupported store-daemon protocol version: " & $version)
  let kindRaw = int(header.readU16Le(pos))
  let bodyLen = int(header.readU32Le(pos))
  result.kind = StoreDaemonMessageKind(kindRaw)
  result.body = socket.recvExact(bodyLen)

proc helloBody*(clientName: string): seq[byte] =
  result.writeU16Le(StoreDaemonProtocolVersion)
  result.writeString(clientName)
  result.writeI64(int64(getCurrentProcessId()))

proc parseHello*(body: openArray[byte]): tuple[version: uint16;
    clientName: string; pid: int64] =
  var pos = 0
  result.version = body.readU16Le(pos)
  result.clientName = body.readString(pos)
  result.pid = body.readI64(pos)

proc helloAckBody*(profile, storeRoot: string; pid: int64): seq[byte] =
  result.writeU16Le(StoreDaemonProtocolVersion)
  result.writeString(profile)
  result.writeString(storeRoot)
  result.writeString(StoreDaemonCapabilities)
  result.writeI64(pid)

proc parseHelloAck*(body: openArray[byte]): tuple[version: uint16;
    profile: string; storeRoot: string; capabilities: string; pid: int64] =
  var pos = 0
  result.version = body.readU16Le(pos)
  result.profile = body.readString(pos)
  result.storeRoot = body.readString(pos)
  result.capabilities = body.readString(pos)
  result.pid = body.readI64(pos)

proc statusBody*(status: StoreDaemonStatus): seq[byte] =
  result.writeBool(status.running)
  result.writeU16Le(status.protocolVersion)
  result.writeString(status.daemonProfile)
  result.writeString(status.endpoint)
  result.writeString(status.storeRoot)
  result.writeI64(status.pid)
  result.writeI64(status.uptimeSeconds)
  result.writeU32Le(uint32(status.realizedPrefixCount))
  result.writeU32Le(uint32(status.rootCount))
  result.writeU32Le(uint32(status.pendingRealizationCount))

proc parseStatusBody*(body: openArray[byte]): StoreDaemonStatus =
  var pos = 0
  result.running = body.readBool(pos)
  result.protocolVersion = body.readU16Le(pos)
  result.daemonProfile = body.readString(pos)
  result.endpoint = body.readString(pos)
  result.storeRoot = body.readString(pos)
  result.pid = body.readI64(pos)
  result.uptimeSeconds = body.readI64(pos)
  result.realizedPrefixCount = int(body.readU32Le(pos))
  result.rootCount = int(body.readU32Le(pos))
  result.pendingRealizationCount = int(body.readU32Le(pos))

proc syntheticBody*(req: SyntheticRealizeRequest): seq[byte] =
  result.writeString(req.storeRoot)
  result.writeString(req.realizationIdHex)
  result.writeString(req.packageName)
  result.writeString(req.version)
  result.writeString(req.payload)
  result.writeString(req.holderId)
  result.writeString(req.rootId)
  result.writeU32Le(uint32(req.delayMs))

proc parseSyntheticBody*(body: openArray[byte]): SyntheticRealizeRequest =
  var pos = 0
  result.storeRoot = body.readString(pos)
  result.realizationIdHex = body.readString(pos)
  result.packageName = body.readString(pos)
  result.version = body.readString(pos)
  result.payload = body.readString(pos)
  result.holderId = body.readString(pos)
  result.rootId = body.readString(pos)
  result.delayMs = int(body.readU32Le(pos))

proc realizeResponseBody*(res: StoreDaemonRealizeResult): seq[byte] =
  result.writeString(res.status)
  result.writeString(res.realizedPrefixPath)
  result.writeString(res.realizationHashHex)
  result.writeString(res.rootId)
  result.writeString(res.writerMode)

proc parseRealizeResponseBody*(body: openArray[byte]):
    StoreDaemonRealizeResult =
  var pos = 0
  result.status = body.readString(pos)
  result.realizedPrefixPath = body.readString(pos)
  result.realizationHashHex = body.readString(pos)
  result.rootId = body.readString(pos)
  result.writerMode = body.readString(pos)

proc releaseRootBody*(holderId, rootId: string): seq[byte] =
  result.writeString(holderId)
  result.writeString(rootId)

proc parseReleaseRootBody*(body: openArray[byte]):
    tuple[holderId: string; rootId: string] =
  var pos = 0
  result.holderId = body.readString(pos)
  result.rootId = body.readString(pos)

proc errorBody*(message: string): seq[byte] =
  result.writeString(message)

proc parseErrorBody*(body: openArray[byte]): string =
  var pos = 0
  body.readString(pos)

proc devRuntimeDir*(): string =
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      local / "repro"
    else:
      getTempDir()
  else:
    let xdg = getEnv("XDG_RUNTIME_DIR")
    if xdg.len > 0:
      xdg
    else:
      getTempDir()

proc currentUid*(): int64 =
  when defined(posix):
    int64(getuid())
  else:
    0'i64

proc defaultDevEndpoint*(): string =
  let override = getEnv("REPROSTORED_ENDPOINT")
  if override.len > 0:
    return override
  when defined(windows):
    "\\\\.\\pipe\\reprostored-dev-current-user"
  else:
    devRuntimeDir() / ("reprostore-" & $currentUid() & ".sock")

proc statusFileForEndpoint*(endpoint: string): string =
  let leaf = endpoint.extractFilename
  devRuntimeDir() / (leaf & ".status")

proc defaultDevStoreRoot*(): string =
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      local / "repro" / "reprostored-dev" / "store"
    else:
      getEnv("USERPROFILE") / "AppData" / "Local" / "repro" /
        "reprostored-dev" / "store"
  elif defined(macosx):
    getEnv("HOME") / "Library" / "Caches" / "repro" / "reprostored-dev" /
      "store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".cache"
    base / "repro" / "reprostored-dev" / "store"

proc devStoreRoot*(explicit = ""): string =
  if explicit.len > 0:
    explicit
  else:
    defaultDevStoreRoot()

proc parsePrefixIdHex*(hex: string): array[32, byte] =
  if hex.len != 64:
    raise newException(ValueError,
      "realization id must be 64 lowercase hex chars")
  for i in 0 ..< 32:
    result[i] = byte(parseHexInt(hex[i * 2 .. i * 2 + 1]))

proc prefixIdHex(bytes: openArray[byte]): string =
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())
