import std/[net, os, strutils, times]

import repro_core

when defined(posix):
  import std/posix

const
  UserDaemonProtocolMajor* = 1'u16
  UserDaemonProtocolMinor* = 0'u16
  UserDaemonRole* = "repro-daemon/user"
  UserDaemonFeatureFlags* = "lifecycle,status,logs,shutdown,sessions"
  FrameMagic = "RBUD"

type
  UserDaemonMessageKind* = enum
    udkHello = 1
    udkHelloAck = 2
    udkStatus = 3
    udkStatusResponse = 4
    udkShutdown = 5
    udkShutdownAck = 6
    udkSessions = 7
    udkSessionsResponse = 8
    udkError = 255

  BinaryIdentity* = object
    name*: string
    path*: string
    version*: string
    sizeBytes*: int64
    mtimeUnix*: int64

  UserDaemonStatus* = object
    running*: bool
    role*: string
    endpoint*: string
    stateDir*: string
    logPath*: string
    pid*: int64
    uptimeSeconds*: int64
    protocolMajor*: uint16
    protocolMinor*: uint16
    binary*: BinaryIdentity
    featureFlags*: string
    generation*: string
    activeSessionCount*: int
    devMode*: bool

  UserDaemonSession* = object
    sessionId*: string
    projectRoot*: string
    mode*: string
    state*: string
    startedAtUnix*: int64

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

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc currentUid*(): int64 =
  when defined(posix):
    int64(getuid())
  else:
    0'i64

proc userDaemonRuntimeDir*(): string =
  let explicit = getEnv("REPRO_DAEMON_RUNTIME_DIR")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: local / "repro" / "daemon" / "runtime"
    else: getEnv("USERPROFILE") / "AppData" / "Local" / "repro" /
      "daemon" / "runtime"
  else:
    let xdg = getEnv("XDG_RUNTIME_DIR")
    if xdg.len > 0: xdg / "repro"
    else: getTempDir() / ("repro-" & $currentUid())

proc userDaemonStateDir*(): string =
  let explicit = getEnv("REPRO_DAEMON_STATE_DIR")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0: local / "repro" / "daemon"
    else: getEnv("USERPROFILE") / "AppData" / "Local" / "repro" / "daemon"
  elif defined(macosx):
    getEnv("HOME") / "Library" / "Application Support" / "repro" / "daemon"
  else:
    let xdg = getEnv("XDG_STATE_HOME")
    let base = if xdg.len > 0: xdg else: getEnv("HOME") / ".local" / "state"
    base / "repro" / "daemon"

proc defaultUserDaemonEndpoint*(): string =
  let explicit = getEnv("REPRO_DAEMON_ENDPOINT")
  if explicit.len > 0:
    return explicit
  when defined(windows):
    "\\\\.\\pipe\\repro-daemon-current-user"
  else:
    userDaemonRuntimeDir() / ("repro-daemon-" & $currentUid() & ".sock")

proc defaultUserDaemonLogPath*(): string =
  userDaemonStateDir() / "logs" / "repro-daemon.log"

proc statusFileForEndpoint*(endpoint: string): string =
  userDaemonStateDir() / "status" /
    (safePathSegment(endpoint.extractFilename, "repro-daemon") & ".status")

proc binaryIdentity*(name, path, version: string): BinaryIdentity =
  result = BinaryIdentity(name: name, path: path, version: version)
  if path.len > 0 and fileExists(path):
    try:
      let info = getFileInfo(path)
      result.sizeBytes = int64(info.size)
      result.mtimeUnix = info.lastWriteTime.toUnix
    except CatchableError:
      discard

proc writeBinaryIdentity(buf: var seq[byte]; identity: BinaryIdentity) =
  buf.writeString(identity.name)
  buf.writeString(identity.path)
  buf.writeString(identity.version)
  buf.writeI64(identity.sizeBytes)
  buf.writeI64(identity.mtimeUnix)

proc readBinaryIdentity(buf: openArray[byte]; pos: var int): BinaryIdentity =
  result.name = buf.readString(pos)
  result.path = buf.readString(pos)
  result.version = buf.readString(pos)
  result.sizeBytes = buf.readI64(pos)
  result.mtimeUnix = buf.readI64(pos)

proc writeSession(buf: var seq[byte]; session: UserDaemonSession) =
  buf.writeString(session.sessionId)
  buf.writeString(session.projectRoot)
  buf.writeString(session.mode)
  buf.writeString(session.state)
  buf.writeI64(session.startedAtUnix)

proc readSession(buf: openArray[byte]; pos: var int): UserDaemonSession =
  result.sessionId = buf.readString(pos)
  result.projectRoot = buf.readString(pos)
  result.mode = buf.readString(pos)
  result.state = buf.readString(pos)
  result.startedAtUnix = buf.readI64(pos)

proc writeFrame*(socket: Socket; kind: UserDaemonMessageKind;
                 body: openArray[byte] = []) =
  var frame: seq[byte] = @[]
  for ch in FrameMagic:
    frame.add(byte(ord(ch)))
  frame.writeU16Le(uint16(ord(kind)))
  frame.writeU32Le(uint32(body.len))
  frame.add(body)
  socket.send(frame.textOf())

proc recvExact(socket: Socket; byteCount: int): seq[byte] =
  result = newSeqOfCap[byte](byteCount)
  while result.len < byteCount:
    let chunk = socket.recv(byteCount - result.len)
    if chunk.len == 0:
      raise newException(IOError, "unexpected EOF reading user-daemon frame")
    for ch in chunk:
      result.add(byte(ord(ch)))

proc readFrame*(socket: Socket): tuple[kind: UserDaemonMessageKind;
                                      body: seq[byte]] =
  let header = socket.recvExact(10)
  for i in 0 ..< 4:
    if header[i] != byte(ord(FrameMagic[i])):
      raise newException(ValueError, "bad user-daemon frame magic")
  var pos = 4
  let kindRaw = int(header.readU16Le(pos))
  let bodyLen = int(header.readU32Le(pos))
  result.kind = UserDaemonMessageKind(kindRaw)
  result.body = socket.recvExact(bodyLen)

proc helloBody*(client: BinaryIdentity; featureFlags, commandMode,
                projectRoot: string; protocolMajor = UserDaemonProtocolMajor;
                protocolMinor = UserDaemonProtocolMinor): seq[byte] =
  result.writeU16Le(protocolMajor)
  result.writeU16Le(protocolMinor)
  result.writeBinaryIdentity(client)
  result.writeString(featureFlags)
  result.writeString(commandMode)
  result.writeString(projectRoot)
  result.writeI64(int64(getCurrentProcessId()))

proc parseHello*(body: openArray[byte]): tuple[major: uint16; minor: uint16;
    client: BinaryIdentity; featureFlags: string; commandMode: string;
    projectRoot: string; pid: int64] =
  var pos = 0
  result.major = body.readU16Le(pos)
  result.minor = body.readU16Le(pos)
  result.client = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.commandMode = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.pid = body.readI64(pos)

proc helloAckBody*(daemon: BinaryIdentity; featureFlags, generation: string):
    seq[byte] =
  result.writeU16Le(UserDaemonProtocolMajor)
  result.writeU16Le(UserDaemonProtocolMinor)
  result.writeBinaryIdentity(daemon)
  result.writeString(featureFlags)
  result.writeString(generation)

proc parseHelloAck*(body: openArray[byte]): tuple[major: uint16;
    minor: uint16; daemon: BinaryIdentity; featureFlags: string;
    generation: string] =
  var pos = 0
  result.major = body.readU16Le(pos)
  result.minor = body.readU16Le(pos)
  result.daemon = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.generation = body.readString(pos)

proc statusBody*(status: UserDaemonStatus): seq[byte] =
  result.writeBool(status.running)
  result.writeString(status.role)
  result.writeString(status.endpoint)
  result.writeString(status.stateDir)
  result.writeString(status.logPath)
  result.writeI64(status.pid)
  result.writeI64(status.uptimeSeconds)
  result.writeU16Le(status.protocolMajor)
  result.writeU16Le(status.protocolMinor)
  result.writeBinaryIdentity(status.binary)
  result.writeString(status.featureFlags)
  result.writeString(status.generation)
  result.writeU32Le(uint32(status.activeSessionCount))
  result.writeBool(status.devMode)

proc parseStatusBody*(body: openArray[byte]): UserDaemonStatus =
  var pos = 0
  result.running = body.readBool(pos)
  result.role = body.readString(pos)
  result.endpoint = body.readString(pos)
  result.stateDir = body.readString(pos)
  result.logPath = body.readString(pos)
  result.pid = body.readI64(pos)
  result.uptimeSeconds = body.readI64(pos)
  result.protocolMajor = body.readU16Le(pos)
  result.protocolMinor = body.readU16Le(pos)
  result.binary = body.readBinaryIdentity(pos)
  result.featureFlags = body.readString(pos)
  result.generation = body.readString(pos)
  result.activeSessionCount = int(body.readU32Le(pos))
  result.devMode = body.readBool(pos)

proc sessionsBody*(sessions: openArray[UserDaemonSession]): seq[byte] =
  result.writeU32Le(uint32(sessions.len))
  for session in sessions:
    result.writeSession(session)

proc parseSessionsBody*(body: openArray[byte]): seq[UserDaemonSession] =
  var pos = 0
  let count = int(body.readU32Le(pos))
  result = newSeq[UserDaemonSession](count)
  for i in 0 ..< count:
    result[i] = body.readSession(pos)

proc errorBody*(message: string): seq[byte] =
  result.writeString(message)

proc parseErrorBody*(body: openArray[byte]): string =
  var pos = 0
  body.readString(pos)
