import std/[net, os, strutils, times]

import repro_core

when defined(posix):
  import std/posix

const
  UserDaemonProtocolMajor* = 1'u16
  UserDaemonProtocolMinor* = 0'u16
  UserDaemonRole* = "repro-daemon/user"
  UserDaemonFeatureFlags* =
    "lifecycle,status,logs,shutdown,sessions,build-routing,build-events"
  BuildEventSchemaId* = "reprobuild.daemon.build-event.v1"
  BuildEventSchemaVersion* = 1'u16
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
    udkBuildRequest = 9
    udkBuildEvent = 10
    udkBuildCancel = 11
    udkError = 255

  UserDaemonBuildEventKind* = enum
    bekAccepted = "accepted"
    bekDiagnostic = "diagnostic"
    bekUnsupported = "unsupported"
    bekCancelled = "cancelled"
    bekFinished = "finished"

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
    endedAtUnix*: int64
    exitCode*: int
    message*: string

  UserDaemonBuildRequest* = object
    runId*: string
    target*: string
    workingDir*: string
    projectRoot*: string
    toolProvisioning*: string
    workRoot*: string
    publicCliPath*: string
    rawArgs*: seq[string]
    environment*: seq[string]
    attached*: bool
    cancelOnDisconnect*: bool

  UserDaemonBuildEvent* = object
    schemaId*: string
    schemaVersion*: uint16
    eventId*: uint64
    occurredAtUnixMs*: int64
    runId*: string
    sessionId*: string
    projectRoot*: string
    command*: string
    kind*: UserDaemonBuildEventKind
    severity*: string
    message*: string
    terminal*: bool
    exitCode*: int
    payloadJson*: string

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
  let raw = buf.readU64Le(pos)
  if raw <= uint64(int64.high):
    int64(raw)
  elif raw == 0x8000000000000000'u64:
    int64.low
  else:
    -int64((not raw) + 1'u64)

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
  buf.writeI64(session.endedAtUnix)
  buf.writeI64(int64(session.exitCode))
  buf.writeString(session.message)

proc readSession(buf: openArray[byte]; pos: var int): UserDaemonSession =
  result.sessionId = buf.readString(pos)
  result.projectRoot = buf.readString(pos)
  result.mode = buf.readString(pos)
  result.state = buf.readString(pos)
  result.startedAtUnix = buf.readI64(pos)
  result.endedAtUnix = buf.readI64(pos)
  result.exitCode = int(buf.readI64(pos))
  result.message = buf.readString(pos)

proc writeStringSeq(buf: var seq[byte]; values: openArray[string]) =
  buf.writeU32Le(uint32(values.len))
  for value in values:
    buf.writeString(value)

proc readStringSeq(buf: openArray[byte]; pos: var int): seq[string] =
  let count = int(buf.readU32Le(pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = buf.readString(pos)

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

proc buildRequestBody*(request: UserDaemonBuildRequest): seq[byte] =
  result.writeString(request.runId)
  result.writeString(request.target)
  result.writeString(request.workingDir)
  result.writeString(request.projectRoot)
  result.writeString(request.toolProvisioning)
  result.writeString(request.workRoot)
  result.writeString(request.publicCliPath)
  result.writeStringSeq(request.rawArgs)
  result.writeStringSeq(request.environment)
  result.writeBool(request.attached)
  result.writeBool(request.cancelOnDisconnect)

proc parseBuildRequestBody*(body: openArray[byte]): UserDaemonBuildRequest =
  var pos = 0
  result.runId = body.readString(pos)
  result.target = body.readString(pos)
  result.workingDir = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.toolProvisioning = body.readString(pos)
  result.workRoot = body.readString(pos)
  result.publicCliPath = body.readString(pos)
  result.rawArgs = body.readStringSeq(pos)
  result.environment = body.readStringSeq(pos)
  result.attached = body.readBool(pos)
  result.cancelOnDisconnect = body.readBool(pos)

proc parseBuildEventKind(value: string): UserDaemonBuildEventKind =
  case value
  of "accepted":
    bekAccepted
  of "diagnostic":
    bekDiagnostic
  of "unsupported":
    bekUnsupported
  of "cancelled":
    bekCancelled
  of "finished":
    bekFinished
  else:
    raise newException(ValueError,
      "unknown user-daemon build event kind: " & value)

proc buildEventBody*(event: UserDaemonBuildEvent): seq[byte] =
  result.writeString(event.schemaId)
  result.writeU16Le(event.schemaVersion)
  result.writeU64Le(event.eventId)
  result.writeI64(event.occurredAtUnixMs)
  result.writeString(event.runId)
  result.writeString(event.sessionId)
  result.writeString(event.projectRoot)
  result.writeString(event.command)
  result.writeString($event.kind)
  result.writeString(event.severity)
  result.writeString(event.message)
  result.writeBool(event.terminal)
  result.writeI64(int64(event.exitCode))
  result.writeString(event.payloadJson)

proc parseBuildEventBody*(body: openArray[byte]): UserDaemonBuildEvent =
  var pos = 0
  result.schemaId = body.readString(pos)
  result.schemaVersion = body.readU16Le(pos)
  result.eventId = body.readU64Le(pos)
  result.occurredAtUnixMs = body.readI64(pos)
  result.runId = body.readString(pos)
  result.sessionId = body.readString(pos)
  result.projectRoot = body.readString(pos)
  result.command = body.readString(pos)
  result.kind = parseBuildEventKind(body.readString(pos))
  result.severity = body.readString(pos)
  result.message = body.readString(pos)
  result.terminal = body.readBool(pos)
  result.exitCode = int(body.readI64(pos))
  result.payloadJson = body.readString(pos)

proc errorBody*(message: string): seq[byte] =
  result.writeString(message)

proc parseErrorBody*(body: openArray[byte]): string =
  var pos = 0
  body.readString(pos)
