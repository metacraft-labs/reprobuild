import std/[net, os, osproc, strtabs, strutils, times]

import repro_core
import blake3

import ./client
import ./protocol
import ./stats_store

when defined(posix):
  import std/posix except Time

  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

when defined(windows):
  import std/winlean

  const
    LOCKFILE_EXCLUSIVE_LOCK = 0x00000002'i32
    LOCKFILE_FAIL_IMMEDIATELY = 0x00000001'i32
    ERROR_LOCK_VIOLATION = 33'i32

  proc lockFileExRaw(hFile: Handle; dwFlags: DWORD; dwReserved: DWORD;
                     nNumberOfBytesToLockLow, nNumberOfBytesToLockHigh: DWORD;
                     lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "LockFileEx", sideEffect.}
  proc unlockFileExRaw(hFile: Handle; dwReserved: DWORD;
                       nNumberOfBytesToUnlockLow,
                       nNumberOfBytesToUnlockHigh: DWORD;
                       lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "UnlockFileEx", sideEffect.}

type
  UserDaemonRuntimeError* = object of CatchableError

  UserDaemonConfig* = object
    endpoint*: string
    stateDir*: string
    logPath*: string
    foreground*: bool
    devMode*: bool
    daemonExe*: string
    sourceExe*: string
    stagedGenerationDir*: string
    previousStagedGenerationDir*: string
    restartRunId*: string

  UserDaemonBuildEmit* = proc(kind: UserDaemonBuildEventKind;
                              message: string;
                              terminal: bool;
                              exitCode: int;
                              severity: string;
                              payloadJson: string)
  UserDaemonBuildCancelCheck* = proc(): bool
  UserDaemonBuildExecutor* = proc(request: UserDaemonBuildRequest;
                                  emit: UserDaemonBuildEmit;
                                  cancelCheck: UserDaemonBuildCancelCheck):
                                  int
  UserDaemonBuildPrewarmer* = proc(request: UserDaemonBuildRequest)
  UserDaemonWatchEmit* = proc(kind: UserDaemonBuildEventKind;
                              message: string;
                              terminal: bool;
                              exitCode: int;
                              severity: string;
                              payloadJson: string;
                              watchedPaths: seq[string];
                              lastResult: string)
  UserDaemonWatchCancelCheck* = proc(): bool
  UserDaemonWatchExecutor* = proc(request: UserDaemonWatchRequest;
                                  emit: UserDaemonWatchEmit;
                                  cancelCheck: UserDaemonWatchCancelCheck):
                                  int

  UserDaemonLock = object
    held: bool
    lockPath: string
    token: string
    when defined(posix):
      fd: cint
    when defined(windows):
      handle: Handle

  DevRestartState = object
    enabled: bool
    sourceImagePath: string
    runningImagePath: string
    sourceHash: string
    runningHash: string
    protocolGeneration: string
    restartRunId: string
    stagedGenerationDir: string
    previousStagedGenerationDir: string
    candidateHash: string
    candidateSinceMs: int64
    lastCheckMs: int64
    restartPending: bool

const UserDaemonLockFileName = ".repro-daemon.lock"

var userDaemonBuildExecutor: UserDaemonBuildExecutor
var userDaemonBuildPrewarmer: UserDaemonBuildPrewarmer
var userDaemonWatchExecutor: UserDaemonWatchExecutor

proc setUserDaemonBuildExecutor*(executor: UserDaemonBuildExecutor) =
  userDaemonBuildExecutor = executor

proc setUserDaemonBuildPrewarmer*(prewarmer: UserDaemonBuildPrewarmer) =
  userDaemonBuildPrewarmer = prewarmer

proc setUserDaemonWatchExecutor*(executor: UserDaemonWatchExecutor) =
  userDaemonWatchExecutor = executor

proc safePathSegment(value, fallback: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&':
      result.add("&amp;")
    of '<':
      result.add("&lt;")
    of '>':
      result.add("&gt;")
    of '"':
      result.add("&quot;")
    of '\'':
      result.add("&apos;")
    else:
      result.add(ch)

proc fileDigestHex(path: string): string =
  if path.len == 0 or not fileExists(path):
    return ""
  let hasher = initHasher()
  defer: hasher.close()
  var file = open(path, fmRead)
  defer: file.close()
  var buffer = newString(64 * 1024)
  while true:
    let readCount = file.readBuffer(addr buffer[0], buffer.len)
    if readCount <= 0:
      break
    hasher.update(buffer[0].addr, readCount)
  "blake3-256:" & hasher.finalize().toHex()

proc nowUnixMs(): int64 =
  let current = getTime()
  current.toUnix * 1000 + int64(current.nanosecond div 1_000_000)

proc newRestartRunId(prefix = "dev-restart"): string =
  let current = getTime()
  prefix & "-" & $getCurrentProcessId() & "-" & $current.toUnix & "-" &
    $current.nanosecond

proc defaultUserDaemonConfig*(daemonExe = ""; foreground = false;
                              devMode = false): UserDaemonConfig =
  UserDaemonConfig(endpoint: defaultUserDaemonEndpoint(),
    stateDir: userDaemonStateDir(),
    logPath: defaultUserDaemonLogPath(),
    foreground: foreground,
    devMode: devMode,
    daemonExe: daemonExe)

proc absoluteNormalized(path: string): string =
  if path.len == 0:
    return ""
  if path.isAbsolute:
    os.normalizedPath(path)
  else:
    os.normalizedPath(getCurrentDir() / path)

proc reconnectLimitationsText(): string =
  "watch sessions can be reattached by run id/session id; completed build " &
    "session diagnostics and stats persist; attached build event streams are " &
    "not replayed after a dev self-restart"

proc initDevRestartState(config: UserDaemonConfig): DevRestartState =
  result.enabled = config.devMode
  result.sourceImagePath =
    if config.sourceExe.len > 0: absoluteNormalized(config.sourceExe)
    else: absoluteNormalized(getAppFilename())
  result.runningImagePath = absoluteNormalized(getAppFilename())
  result.sourceHash = fileDigestHex(result.sourceImagePath)
  result.runningHash = fileDigestHex(result.runningImagePath)
  result.protocolGeneration = $UserDaemonProtocolMajor & "." &
    $UserDaemonProtocolMinor
  result.restartRunId =
    if config.restartRunId.len > 0: config.restartRunId
    else: newRestartRunId("dev-start")
  result.stagedGenerationDir = config.stagedGenerationDir
  result.previousStagedGenerationDir = config.previousStagedGenerationDir

proc devBinRoot(config: UserDaemonConfig): string =
  config.stateDir / "dev-bin"

proc stageDevDaemonBinary*(sourceExe: string; config: UserDaemonConfig;
                           restartRunId = ""):
    tuple[imagePath: string; generationDir: string; runId: string;
          sourceHash: string] =
  result.sourceHash = fileDigestHex(sourceExe)
  if result.sourceHash.len == 0:
    raise newException(UserDaemonRuntimeError,
      "cannot stage missing repro-daemon source executable: " & sourceExe)
  result.runId =
    if restartRunId.len > 0: restartRunId else: newRestartRunId()
  let hashSegment = safePathSegment(result.sourceHash.replace(":", "-"),
    "unknown")
  result.generationDir = devBinRoot(config) /
    safePathSegment(result.runId & "-" & hashSegment[0 .. min(23,
      hashSegment.high)], "generation")
  createDir(result.generationDir)
  result.imagePath = result.generationDir / addFileExt("repro-daemon", ExeExt)
  copyFile(sourceExe, result.imagePath)
  try:
    setFilePermissions(result.imagePath, {fpUserRead, fpUserWrite,
      fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  except CatchableError:
    discard

proc logLine(path, message: string)

proc cleanupPreviousStagedGeneration(config: UserDaemonConfig) =
  if not config.devMode or config.previousStagedGenerationDir.len == 0:
    return
  let root = absoluteNormalized(devBinRoot(config))
  let previous = absoluteNormalized(config.previousStagedGenerationDir)
  if previous.len == 0 or previous == root or not previous.startsWith(root):
    return
  try:
    if dirExists(previous):
      removeDir(previous)
      logLine(config.logPath, "cleaned previous dev staged generation=" &
        previous)
  except CatchableError as err:
    logLine(config.logPath, "previous dev staged generation cleanup failed=" &
      previous & " error=" & err.msg)

proc logLine(path, message: string) =
  try:
    createDir(parentDir(path))
    var file = open(path, fmAppend)
    defer: file.close()
    file.writeLine($now() & " " & message)
  except CatchableError:
    discard

proc lockMetadata(config: UserDaemonConfig; token: string): string =
  "role=" & UserDaemonRole & "\n" &
    "endpoint=" & config.endpoint & "\n" &
    "stateDir=" & config.stateDir & "\n" &
    "logPath=" & config.logPath & "\n" &
    "pid=" & $getCurrentProcessId() & "\n" &
    "token=" & token & "\n" &
    "protocol=" & $UserDaemonProtocolMajor & "." &
      $UserDaemonProtocolMinor & "\n"

proc acquireUserDaemonLock(config: UserDaemonConfig): UserDaemonLock =
  when defined(posix):
    createDir(config.stateDir)
    let lockPath = config.stateDir / UserDaemonLockFileName
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to open user-daemon lockfile " & lockPath & ", errno=" &
        $errno)
    let rc = cFlock(fd, LockExclusive or LockNonBlocking)
    if rc != 0:
      let lockErr = errno
      discard posix.close(fd)
      if lockErr == EWOULDBLOCK or lockErr == EAGAIN:
        var detail = ""
        try:
          detail = readFile(lockPath).strip()
        except CatchableError:
          discard
        var msg = "user daemon lock is held by a live repro-daemon"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(UserDaemonRuntimeError, msg)
      raise newException(UserDaemonRuntimeError,
        "failed to acquire user-daemon lockfile " & lockPath & ", errno=" &
        $lockErr)
    let nowTime = getTime()
    let token = $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    UserDaemonLock(held: true, lockPath: lockPath, token: token, fd: fd)
  elif defined(windows):
    # LockFileEx on a 1-byte range serves the same role as POSIX flock:
    # the lock is automatically released when the handle closes (e.g.
    # the daemon crashes), so a dead daemon never poisons the lockfile.
    # We open the file read+write+share-read so a sibling can observe
    # the metadata while we hold the exclusive lock.
    createDir(config.stateDir)
    let lockPath = config.stateDir / UserDaemonLockFileName
    let wpath = newWideCString(lockPath)
    # SHARE_READ | SHARE_WRITE so the matching `writeFile(lockPath, ...)`
    # below — and any concurrent contender's CreateFileW — succeeds and
    # the mutual-exclusion check is delegated to ``LockFileEx``. The
    # lock itself enforces single-writer semantics: a second daemon
    # opens the same file but fails the LOCKFILE_FAIL_IMMEDIATELY lock
    # with ERROR_LOCK_VIOLATION (the case below).
    let h = createFileW(wpath,
      (GENERIC_READ or GENERIC_WRITE).DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE).DWORD, nil,
      OPEN_ALWAYS.DWORD, 0.DWORD, 0)
    if h == INVALID_HANDLE_VALUE:
      raise newException(UserDaemonRuntimeError,
        "failed to open user-daemon lockfile " & lockPath & ", Windows " &
        "error=" & $osLastError())
    var overlapped: OVERLAPPED
    let ok = lockFileExRaw(h,
      (LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY).DWORD,
      0.DWORD, 1.DWORD, 0.DWORD, addr overlapped)
    if ok == 0:
      let lockErr = int32(osLastError())
      discard closeHandle(h)
      if lockErr == ERROR_LOCK_VIOLATION:
        var detail = ""
        try:
          detail = readFile(lockPath).strip()
        except CatchableError:
          discard
        var msg = "user daemon lock is held by a live repro-daemon"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(UserDaemonRuntimeError, msg)
      raise newException(UserDaemonRuntimeError,
        "failed to acquire user-daemon lockfile " & lockPath &
        ", Windows error=" & $lockErr)
    let nowTime = getTime()
    let token = $getCurrentProcessId() & "-" & $nowTime.toUnix & "-" &
      $nowTime.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    UserDaemonLock(held: true, lockPath: lockPath, token: token, handle: h)
  else:
    UserDaemonLock(held: false)

proc releaseUserDaemonLock(lock: var UserDaemonLock) =
  if not lock.held:
    return
  when defined(posix):
    try:
      if fileExists(lock.lockPath) and
          readFile(lock.lockPath).contains("token=" & lock.token & "\n"):
        removeFile(lock.lockPath)
    except CatchableError:
      discard
    if lock.fd >= 0:
      discard posix.close(lock.fd)
      lock.fd = -1
  elif defined(windows):
    if lock.handle != 0 and lock.handle != INVALID_HANDLE_VALUE:
      var overlapped: OVERLAPPED
      discard unlockFileExRaw(lock.handle, 0.DWORD, 1.DWORD, 0.DWORD,
        addr overlapped)
      discard closeHandle(lock.handle)
      lock.handle = 0
    try:
      if fileExists(lock.lockPath) and
          readFile(lock.lockPath).contains("token=" & lock.token & "\n"):
        removeFile(lock.lockPath)
    except CatchableError:
      discard
  lock.held = false

proc statusPath(config: UserDaemonConfig): string =
  config.stateDir / "status" /
    (safePathSegment(config.endpoint.extractFilename, "repro-daemon") &
      ".status")

proc sessionRecordsDir(config: UserDaemonConfig): string =
  config.stateDir / "sessions"

proc sessionRecordPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) / (safePathSegment(sessionId, "session") & ".session")

proc sessionEventLogPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) /
    (safePathSegment(sessionId, "session") & ".events")

proc sessionStopRequestPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) /
    (safePathSegment(sessionId, "session") & ".stop")

proc flattenRecordValue(value: string): string =
  value.replace("\n", "\\n").replace("\r", "\\r")

proc expandRecordValue(value: string): string =
  value.replace("\\n", "\n").replace("\\r", "\r")

proc flattenRecordSeq(values: openArray[string]): string =
  var escaped: seq[string] = @[]
  for value in values:
    escaped.add(flattenRecordValue(value).replace("\t", "\\t"))
  escaped.join("\t")

proc expandRecordSeq(value: string): seq[string] =
  if value.len == 0:
    return
  for item in value.split('\t'):
    result.add(expandRecordValue(item.replace("\\t", "\t")))

proc writeSessionRecord(config: UserDaemonConfig; session: UserDaemonSession) =
  createDir(sessionRecordsDir(config))
  writeFile(sessionRecordPath(config, session.sessionId),
    "sessionId=" & flattenRecordValue(session.sessionId) & "\n" &
    "projectRoot=" & flattenRecordValue(session.projectRoot) & "\n" &
    "mode=" & flattenRecordValue(session.mode) & "\n" &
    "state=" & flattenRecordValue(session.state) & "\n" &
    "startedAtUnix=" & $session.startedAtUnix & "\n" &
    "endedAtUnix=" & $session.endedAtUnix & "\n" &
    "exitCode=" & $session.exitCode & "\n" &
    "message=" & flattenRecordValue(session.message) & "\n" &
    "selectedRoots=" & flattenRecordSeq(session.selectedRoots) & "\n" &
    "debounceMs=" & $session.debounceMs & "\n" &
    "watchedPaths=" & flattenRecordSeq(session.watchedPaths) & "\n" &
    "tierState=" & flattenRecordValue(session.tierState) & "\n" &
    "lastResult=" & flattenRecordValue(session.lastResult) & "\n")

proc readSessionRecord(path: string): UserDaemonSession =
  for line in readFile(path).splitLines:
    let split = line.find('=')
    if split < 0:
      continue
    let key = line[0 ..< split]
    let value = expandRecordValue(line[split + 1 .. ^1])
    case key
    of "sessionId":
      result.sessionId = value
    of "projectRoot":
      result.projectRoot = value
    of "mode":
      result.mode = value
    of "state":
      result.state = value
    of "startedAtUnix":
      try: result.startedAtUnix = parseBiggestInt(value)
      except ValueError: discard
    of "endedAtUnix":
      try: result.endedAtUnix = parseBiggestInt(value)
      except ValueError: discard
    of "exitCode":
      try: result.exitCode = int(parseBiggestInt(value))
      except ValueError: discard
    of "message":
      result.message = value
    of "selectedRoots":
      result.selectedRoots = expandRecordSeq(value)
    of "debounceMs":
      try: result.debounceMs = int(parseBiggestInt(value))
      except ValueError: discard
    of "watchedPaths":
      result.watchedPaths = expandRecordSeq(value)
    of "tierState":
      result.tierState = value
    of "lastResult":
      result.lastResult = value
    else:
      discard

proc loadSessionRecords(config: UserDaemonConfig): seq[UserDaemonSession] =
  if not dirExists(sessionRecordsDir(config)):
    return
  for kind, path in walkDir(sessionRecordsDir(config)):
    if kind != pcFile or not path.endsWith(".session"):
      continue
    try:
      let session = readSessionRecord(path)
      if session.sessionId.len > 0:
        result.add(session)
    except CatchableError:
      discard

proc countActiveSessionRecords(config: UserDaemonConfig): int =
  for session in loadSessionRecords(config):
    if session.state in ["accepted", "running", "cancelling", "watching",
        "idle"]:
      inc result

proc removeStatusFile(config: UserDaemonConfig) =
  try:
    removeFile(statusPath(config))
  except OSError:
    discard

proc removeEndpointFiles(config: UserDaemonConfig) =
  try: removeFile(config.endpoint) except OSError: discard
  removeStatusFile(config)

proc cleanupStaleUserDaemonDiscovery*(config: UserDaemonConfig): bool =
  ## Remove stale discovery files only when the endpoint does not accept a raw
  ## connection. A protocol-incompatible but live daemon must keep its state.
  when defined(posix):
    let endpointPresent = userDaemonEndpointExists(config.endpoint)
    let accepts = userDaemonEndpointAcceptsConnections(config.endpoint)
    if endpointPresent and not accepts:
      try:
        removeFile(config.endpoint)
        result = true
      except OSError:
        discard
    if not accepts:
      if fileExists(statusPath(config)):
        removeStatusFile(config)
        result = true
  else:
    if fileExists(statusPath(config)):
      removeStatusFile(config)
      result = true

proc generationFor(startedAt: Time): string =
  $getCurrentProcessId() & "-" & $startedAt.toUnix & "-" & $startedAt.nanosecond

proc statusFor(config: UserDaemonConfig; startedAt: Time;
               generation: string; activeSessionCount = 0;
               devRestart: DevRestartState = DevRestartState()):
    UserDaemonStatus =
  UserDaemonStatus(
    running: true,
    role: UserDaemonRole,
    endpoint: config.endpoint,
    stateDir: config.stateDir,
    logPath: config.logPath,
    pid: int64(getCurrentProcessId()),
    uptimeSeconds: getTime().toUnix - startedAt.toUnix,
    protocolMajor: UserDaemonProtocolMajor,
    protocolMinor: UserDaemonProtocolMinor,
    binary: binaryIdentity("repro-daemon", getAppFilename(), versionString()),
    featureFlags: UserDaemonFeatureFlags,
    generation: generation,
    activeSessionCount: activeSessionCount,
    devMode: config.devMode,
    sourceImagePath: devRestart.sourceImagePath,
    runningImagePath:
      if devRestart.runningImagePath.len > 0:
        devRestart.runningImagePath
      else:
        getAppFilename(),
    sourceHash: devRestart.sourceHash,
    runningHash: devRestart.runningHash,
    protocolGeneration:
      if devRestart.protocolGeneration.len > 0:
        devRestart.protocolGeneration
      else:
        $UserDaemonProtocolMajor & "." & $UserDaemonProtocolMinor,
    restartRunId: devRestart.restartRunId,
    stagedGenerationDir: devRestart.stagedGenerationDir,
    previousStagedGenerationDir: devRestart.previousStagedGenerationDir,
    reconnectLimitations:
      if config.devMode: reconnectLimitationsText() else: "")

proc writeStatusFile(config: UserDaemonConfig; status: UserDaemonStatus) =
  let path = statusPath(config)
  createDir(parentDir(path))
  writeFile(path,
    "role=" & status.role & "\n" &
    "endpoint=" & status.endpoint & "\n" &
    "stateDir=" & status.stateDir & "\n" &
    "logPath=" & status.logPath & "\n" &
    "pid=" & $status.pid & "\n" &
    "protocol=" & $status.protocolMajor & "." & $status.protocolMinor &
      "\n" &
    "binary=" & status.binary.path & "\n" &
    "generation=" & status.generation & "\n" &
    "sourceImagePath=" & status.sourceImagePath & "\n" &
    "runningImagePath=" & status.runningImagePath & "\n" &
    "sourceHash=" & status.sourceHash & "\n" &
    "runningHash=" & status.runningHash & "\n" &
    "protocolGeneration=" & status.protocolGeneration & "\n" &
    "restartRunId=" & status.restartRunId & "\n" &
    "stagedGenerationDir=" & status.stagedGenerationDir & "\n" &
    "previousStagedGenerationDir=" &
      status.previousStagedGenerationDir & "\n" &
    "featureFlags=" & status.featureFlags & "\n")

proc handleHello(socket: IpcConn; config: UserDaemonConfig; generation: string;
                 frameBody: openArray[byte]): bool =
  let hello = parseHello(frameBody)
  if hello.major != UserDaemonProtocolMajor:
    socket.writeFrame(udkError, errorBody(
      "user daemon protocol mismatch: client major " & $hello.major &
      ", daemon major " & $UserDaemonProtocolMajor))
    return false
  let daemon = binaryIdentity("repro-daemon", getAppFilename(), versionString())
  socket.writeFrame(udkHelloAck, helloAckBody(daemon, UserDaemonFeatureFlags,
    generation))
  logLine(config.logPath, "handshake client=" & hello.client.name &
    " mode=" & hello.commandMode & " client-protocol=" & $hello.major &
    "." & $hello.minor)
  true

proc nextBuildEvent(runId, sessionId, projectRoot: string;
                    eventId: uint64;
                    kind: UserDaemonBuildEventKind;
                    message: string;
                    terminal = false;
                    exitCode = 0;
                    severity = "info";
                    payloadJson = ""): UserDaemonBuildEvent =
  UserDaemonBuildEvent(
    schemaId: BuildEventSchemaId,
    schemaVersion: BuildEventSchemaVersion,
    eventId: eventId,
    occurredAtUnixMs: nowUnixMs(),
    runId: runId,
    sessionId: sessionId,
    projectRoot: projectRoot,
    command: "build",
    kind: kind,
    severity: severity,
    message: message,
    terminal: terminal,
    exitCode: exitCode,
    payloadJson: payloadJson)

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc stringToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc appendWatchEventRecord(config: UserDaemonConfig; sessionId: string;
                            event: UserDaemonBuildEvent) =
  createDir(sessionRecordsDir(config))
  let body = buildEventBody(event)
  var record: seq[byte] = @[]
  record.writeU32Le(uint32(body.len))
  record.add(body)
  var file = open(sessionEventLogPath(config, sessionId), fmAppend)
  defer: file.close()
  file.write(record.bytesToString())

proc readU32LeFromString(raw: string; pos: var int): uint32 =
  if pos + 4 > raw.len:
    raise newException(ValueError, "truncated watch event length")
  result =
    uint32(ord(raw[pos])) or
    (uint32(ord(raw[pos + 1])) shl 8) or
    (uint32(ord(raw[pos + 2])) shl 16) or
    (uint32(ord(raw[pos + 3])) shl 24)
  pos += 4

proc readWatchEventsFrom(config: UserDaemonConfig; sessionId: string;
                         offset: var int64): seq[UserDaemonBuildEvent] =
  let path = sessionEventLogPath(config, sessionId)
  if not fileExists(path):
    return
  let raw = readFile(path)
  var pos = int(offset)
  while pos + 4 <= raw.len:
    let start = pos
    let length = int(readU32LeFromString(raw, pos))
    if length < 0 or pos + length > raw.len:
      pos = start
      break
    let body = raw[pos ..< pos + length].stringToBytes()
    result.add(parseBuildEventBody(body))
    pos += length
  offset = int64(pos)

proc latestSessionRecord(config: UserDaemonConfig;
                         sessionId: string): UserDaemonSession =
  let path = sessionRecordPath(config, sessionId)
  if fileExists(path):
    return readSessionRecord(path)
  UserDaemonSession(sessionId: sessionId, state: "missing", exitCode: 1,
    message: "watch session not found")

proc removeSession(sessions: var seq[UserDaemonSession]; sessionId: string) =
  var kept: seq[UserDaemonSession] = @[]
  for session in sessions:
    if session.sessionId != sessionId:
      kept.add(session)
  sessions = kept

proc sessionStateAccepted(sessionId, projectRoot: string; started: Time):
    UserDaemonSession =
  UserDaemonSession(sessionId: sessionId,
    projectRoot: projectRoot, mode: "build", state: "accepted",
    startedAtUnix: started.toUnix,
    exitCode: -1,
    message: "build request accepted by repro-daemon")

proc watchSessionStateAccepted(sessionId, projectRoot: string; started: Time;
                               request: UserDaemonWatchRequest):
    UserDaemonSession =
  UserDaemonSession(sessionId: sessionId,
    projectRoot: projectRoot, mode: "watch", state: "accepted",
    startedAtUnix: started.toUnix,
    exitCode: -1,
    message: "watch request accepted by repro-daemon",
    selectedRoots: request.selectedRoots,
    debounceMs: request.debounceMs,
    tierState: "single-tier",
    lastResult: "pending")

proc updateSessionState(config: UserDaemonConfig; session: var UserDaemonSession;
                        state: string; exitCode = -1; message = "") =
  session.state = state
  session.exitCode = exitCode
  if message.len > 0:
    session.message = message
  if state notin ["accepted", "running", "cancelling", "watching", "idle"]:
    session.endedAtUnix = getTime().toUnix
  writeSessionRecord(config, session)

proc buildResponseDelayMs(): int =
  let raw = getEnv("REPRO_DAEMON_M3_BUILD_RESPONSE_DELAY_MS", "")
  if raw.len == 0:
    return 0
  try:
    max(0, parseInt(raw))
  except ValueError:
    0

proc waitForBuildUnsupportedOrDisconnect(socket: IpcConn; delayMs: int): bool =
  ## Returns true when the attached client disconnected before the placeholder
  ## M3 unsupported response was sent.
  let deadline = epochTime() + float(delayMs) / 1000.0
  while epochTime() < deadline:
    if socket.clientDisconnected():
      return true
    sleep(25)
  socket.clientDisconnected()

proc flushStatsAfterTerminal(config: UserDaemonConfig; sessionId: string) =
  let flush = flushStatsObservations()
  if flush.flushed > 0:
    logLine(config.logPath, "stats flushed session=" & sessionId &
      " observations=" & $flush.flushed & " store=" & flush.storePath)
  elif flush.lastError.len > 0:
    logLine(config.logPath, "stats flush failed session=" & sessionId &
      " error=" & flush.lastError)

proc runBuildRequestWorker(socket: IpcConn; config: UserDaemonConfig;
                           request: UserDaemonBuildRequest;
                           session: var UserDaemonSession) =
  var eventId = 1'u64
  var terminalSent = false
  let sessionId = session.sessionId
  let projectRoot = session.projectRoot
  proc emit(kind: UserDaemonBuildEventKind; message: string; terminal: bool;
            exitCode: int; severity: string; payloadJson: string) =
    inc eventId
    socket.writeFrame(udkBuildEvent, buildEventBody(nextBuildEvent(
      request.runId, sessionId, projectRoot, eventId, kind,
      message, terminal = terminal, exitCode = exitCode,
      severity = severity, payloadJson = payloadJson)))
    terminalSent = terminalSent or terminal

  proc cancelCheck(): bool =
    request.attached and request.cancelOnDisconnect and socket.clientDisconnected()

  try:
    updateSessionState(config, session, "running",
      message = "daemon-hosted build running")
    if userDaemonBuildExecutor == nil:
      let message =
        "daemon-hosted build executor is not registered in repro-daemon"
      updateSessionState(config, session, "unsupported", 64, message)
      emit(bekUnsupported, message, true, 64, "warning",
        "{\"fallbackAllowed\":true,\"deferredMilestone\":\"M4\"}")
      return
    let exitCode = userDaemonBuildExecutor(request, emit, cancelCheck)
    let message =
      if exitCode == 0: "daemon-hosted build succeeded"
      else: "daemon-hosted build failed"
    updateSessionState(config, session,
      if exitCode == 0: "succeeded" else: "failed", exitCode, message)
    emit(bekFinished, message, true, exitCode,
      if exitCode == 0: "info" else: "error",
      "{\"executor\":\"direct-build-entrypoint\"}")
    try: socket.closeIpcConn() except CatchableError: discard
    flushStatsAfterTerminal(config, session.sessionId)
    logLine(config.logPath, "build request finished session=" &
      session.sessionId & " exitCode=" & $exitCode)
  except CatchableError as err:
    let cancelled = cancelCheck()
    let kind = if cancelled: bekCancelled else: bekFinished
    let state = if cancelled: "cancelled" else: "failed"
    let code = if cancelled: 130 else: 1
    let message =
      if cancelled: "daemon-hosted build cancelled after client disconnect"
      else: "daemon-hosted build failed: " & err.msg
    updateSessionState(config, session, state, code, message)
    if not terminalSent:
      try:
        emit(kind, message, true, code,
          if cancelled: "warning" else: "error",
          "{\"executor\":\"direct-build-entrypoint\"}")
      except CatchableError:
        discard
    logLine(config.logPath, "build request " & state & " session=" &
      session.sessionId & " message=" & message)

proc handleBuildRequest(socket: IpcConn; config: UserDaemonConfig;
                        request: UserDaemonBuildRequest;
                        sessions: var seq[UserDaemonSession]) =
  let started = getTime()
  let sessionId =
    if request.runId.len > 0:
      request.runId
    else:
      $getCurrentProcessId() & "-" & $started.toUnix & "-" &
        $started.nanosecond
  let projectRoot =
    if request.projectRoot.len > 0:
      request.projectRoot
    else:
      request.workingDir
  var session = sessionStateAccepted(sessionId, projectRoot, started)
  sessions.add(session)
  writeSessionRecord(config, session)
  logLine(config.logPath, "build request accepted session=" & sessionId &
    " projectRoot=" & projectRoot & " attached=" & $request.attached &
    " cancelOnDisconnect=" & $request.cancelOnDisconnect)
  try:
    socket.writeFrame(udkBuildEvent, buildEventBody(nextBuildEvent(
      request.runId, sessionId, projectRoot, 1'u64, bekAccepted,
      "build request accepted by repro-daemon")))
    let delayMs = buildResponseDelayMs()
    if delayMs > 0 and request.attached and request.cancelOnDisconnect:
      if waitForBuildUnsupportedOrDisconnect(socket, delayMs):
        logLine(config.logPath, "build request cancelled session=" &
          sessionId & " reason=client-disconnect")
        updateSessionState(config, session, "cancelled", 130,
          "daemon-hosted build cancelled before scheduling")
        return
    if userDaemonBuildPrewarmer != nil:
      try:
        userDaemonBuildPrewarmer(request)
      except CatchableError as err:
        logLine(config.logPath, "build prewarm skipped session=" &
          sessionId & " error=" & err.msg)
    when defined(posix):
      let pid = fork()
      if pid < 0:
        raise newException(UserDaemonRuntimeError,
          "failed to fork daemon build worker")
      if pid == 0:
        try:
          signal(SIGCHLD, SIG_DFL)
          runBuildRequestWorker(socket, config, request, session)
        except CatchableError as err:
          logLine(config.logPath, "build worker fatal session=" & sessionId &
            " error=" & err.msg)
        try: socket.closeIpcConn() except CatchableError: discard
        quit(0)
      logLine(config.logPath, "build worker started session=" & sessionId &
        " pid=" & $pid)
    else:
      runBuildRequestWorker(socket, config, request, session)
  finally:
    sessions.removeSession(sessionId)

proc watchStopRequested(config: UserDaemonConfig; sessionId: string): bool =
  fileExists(sessionStopRequestPath(config, sessionId))

proc writeWatchStopRequest(config: UserDaemonConfig; sessionId, reason: string) =
  createDir(sessionRecordsDir(config))
  writeFile(sessionStopRequestPath(config, sessionId), reason & "\n")

proc nextWatchEvent(runId, sessionId, projectRoot: string;
                    eventId: uint64;
                    kind: UserDaemonBuildEventKind;
                    message: string;
                    terminal = false;
                    exitCode = 0;
                    severity = "info";
                    payloadJson = ""): UserDaemonBuildEvent =
  result = nextBuildEvent(runId, sessionId, projectRoot, eventId, kind,
    message, terminal = terminal, exitCode = exitCode, severity = severity,
    payloadJson = payloadJson)
  result.command = "watch"

proc runWatchRequestWorker(socket: IpcConn; config: UserDaemonConfig;
                           request: UserDaemonWatchRequest;
                           session: var UserDaemonSession;
                           streamToSocket: bool) =
  var eventId = 1'u64
  var terminalSent = false
  let sessionId = session.sessionId
  let projectRoot = session.projectRoot
  let sessionRef = new(UserDaemonSession)
  sessionRef[] = session
  proc emitEvent(kind: UserDaemonBuildEventKind; message: string;
                 terminal: bool; exitCode: int; severity: string;
                 payloadJson: string; watchedPaths: seq[string];
                 lastResult: string) =
    inc eventId
    if watchedPaths.len > 0:
      sessionRef[].watchedPaths = watchedPaths
    if lastResult.len > 0:
      sessionRef[].lastResult = lastResult
    if terminal:
      terminalSent = true
    elif sessionRef[].state == "running":
      sessionRef[].state = "watching"
    if message.len > 0:
      sessionRef[].message = message
    writeSessionRecord(config, sessionRef[])
    let event = nextWatchEvent(request.runId, sessionId, projectRoot, eventId,
      kind, message, terminal = terminal, exitCode = exitCode,
      severity = severity, payloadJson = payloadJson)
    appendWatchEventRecord(config, sessionId, event)
    if streamToSocket:
      socket.writeFrame(udkWatchEvent, buildEventBody(event))

  proc cancelCheck(): bool =
    if watchStopRequested(config, sessionId):
      return true
    streamToSocket and request.cancelOnDisconnect and
      socket.clientDisconnected()

  try:
    updateSessionState(config, sessionRef[], "running",
      message = "daemon-hosted watch running")
    if userDaemonWatchExecutor == nil:
      let message =
        "daemon-hosted watch executor is not registered in repro-daemon"
      updateSessionState(config, sessionRef[], "unsupported", 64, message)
      emitEvent(bekUnsupported, message, true, 64, "warning",
        "{\"fallbackAllowed\":true,\"deferredMilestone\":\"M5\"}", @[],
        "unsupported")
      return
    let exitCode = userDaemonWatchExecutor(request, emitEvent, cancelCheck)
    let stopped = watchStopRequested(config, sessionId) or
      (streamToSocket and request.cancelOnDisconnect and socket.clientDisconnected())
    let state =
      if stopped: "stopped"
      elif exitCode == 0: "succeeded"
      else: "failed"
    let message =
      if stopped: "daemon-hosted watch stopped"
      elif exitCode == 0: "daemon-hosted watch finished"
      else: "daemon-hosted watch failed"
    updateSessionState(config, sessionRef[], state, exitCode, message)
    emitEvent(if stopped: bekCancelled else: bekFinished, message, true,
      exitCode, if exitCode == 0: "info" else: "error",
      "{\"executor\":\"direct-watch-entrypoint\"}", sessionRef[].watchedPaths,
      "exitCode=" & $exitCode)
    try: socket.closeIpcConn() except CatchableError: discard
    flushStatsAfterTerminal(config, sessionRef[].sessionId)
    logLine(config.logPath, "watch request finished session=" &
      sessionRef[].sessionId & " exitCode=" & $exitCode)
  except CatchableError as err:
    let cancelled = cancelCheck()
    let kind = if cancelled: bekCancelled else: bekFinished
    let state = if cancelled: "stopped" else: "failed"
    let code = if cancelled: 130 else: 1
    let message =
      if cancelled: "daemon-hosted watch stopped"
      else: "daemon-hosted watch failed: " & err.msg
    updateSessionState(config, sessionRef[], state, code, message)
    if not terminalSent:
      try:
        emitEvent(kind, message, true, code,
          if cancelled: "warning" else: "error",
          "{\"executor\":\"direct-watch-entrypoint\"}",
          sessionRef[].watchedPaths,
          "exitCode=" & $code)
      except CatchableError:
        discard
    logLine(config.logPath, "watch request " & state & " session=" &
      sessionRef[].sessionId & " message=" & message)

proc streamWatchSession(socket: IpcConn; config: UserDaemonConfig;
                        sessionId: string; stopOnDisconnect: bool) =
  var offset = 0'i64
  var sawAny = false
  while true:
    for event in readWatchEventsFrom(config, sessionId, offset):
      sawAny = true
      socket.writeFrame(udkWatchEvent, buildEventBody(event))
      if event.terminal:
        return
    let session = latestSessionRecord(config, sessionId)
    if session.sessionId.len == 0 or session.state == "missing":
      socket.writeFrame(udkError, errorBody("watch session not found: " &
        sessionId))
      return
    if session.state notin ["accepted", "running", "watching", "idle",
        "cancelling"] and sawAny:
      return
    if stopOnDisconnect and socket.clientDisconnected():
      writeWatchStopRequest(config, sessionId, "attached client disconnected")
      return
    sleep(50)

proc handleWatchStart(socket: IpcConn; config: UserDaemonConfig;
                      request: UserDaemonWatchRequest;
                      sessions: var seq[UserDaemonSession]) =
  let started = getTime()
  let sessionId =
    if request.runId.len > 0:
      request.runId
    else:
      "watch-" & $getCurrentProcessId() & "-" & $started.toUnix & "-" &
        $started.nanosecond
  let projectRoot =
    if request.projectRoot.len > 0:
      request.projectRoot
    else:
      request.workingDir
  var session = watchSessionStateAccepted(sessionId, projectRoot, started,
    request)
  sessions.add(session)
  writeSessionRecord(config, session)
  try: removeFile(sessionStopRequestPath(config, sessionId)) except OSError: discard
  logLine(config.logPath, "watch request accepted session=" & sessionId &
    " projectRoot=" & projectRoot & " attached=" & $request.attached &
    " detached=" & $request.detached)
  let accepted = nextWatchEvent(request.runId, sessionId, projectRoot, 1'u64,
    bekAccepted, "watch request accepted by repro-daemon",
    payloadJson = "{\"detached\":" & $request.detached & "}")
  appendWatchEventRecord(config, sessionId, accepted)
  socket.writeFrame(udkWatchEvent, buildEventBody(accepted))
  when defined(posix):
    let pid = fork()
    if pid < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to fork daemon watch worker")
    if pid == 0:
      try:
        signal(SIGCHLD, SIG_DFL)
        runWatchRequestWorker(socket, config, request, session,
          streamToSocket = request.attached and not request.detached)
      except CatchableError as err:
        logLine(config.logPath, "watch worker fatal session=" & sessionId &
          " error=" & err.msg)
      try: socket.closeIpcConn() except CatchableError: discard
      quit(0)
    logLine(config.logPath, "watch worker started session=" & sessionId &
      " pid=" & $pid)
    if request.detached:
      discard
  else:
    runWatchRequestWorker(socket, config, request, session,
      streamToSocket = request.attached and not request.detached)
  sessions.removeSession(sessionId)

proc handleWatchAttach(socket: IpcConn; config: UserDaemonConfig;
                       request: UserDaemonWatchSessionRequest) =
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch attach requires a session id"))
    return
  when defined(posix):
    let pid = fork()
    if pid < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to fork daemon watch attach worker")
    if pid == 0:
      try:
        signal(SIGCHLD, SIG_DFL)
        streamWatchSession(socket, config, request.sessionId,
          request.cancelOnDisconnect)
      except CatchableError as err:
        logLine(config.logPath, "watch attach fatal session=" &
          request.sessionId & " error=" & err.msg)
      try: socket.closeIpcConn() except CatchableError: discard
      quit(0)
  else:
    streamWatchSession(socket, config, request.sessionId,
      request.cancelOnDisconnect)

proc handleWatchStop(socket: IpcConn; config: UserDaemonConfig;
                     request: UserDaemonWatchSessionRequest) =
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch stop requires a session id"))
    return
  let session = latestSessionRecord(config, request.sessionId)
  if session.sessionId.len == 0 or session.state == "missing":
    socket.writeFrame(udkError, errorBody("watch session not found: " &
      request.sessionId))
    return
  writeWatchStopRequest(config, request.sessionId, "stop requested")
  let event = nextWatchEvent(request.sessionId, request.sessionId,
    session.projectRoot, 1'u64, bekCancelled,
    "watch stop requested", terminal = false,
    payloadJson = "{\"stopRequested\":true}")
  appendWatchEventRecord(config, request.sessionId, event)
  socket.writeFrame(udkWatchEvent, buildEventBody(event))

proc handleWatchDetach(socket: IpcConn; config: UserDaemonConfig;
                       request: UserDaemonWatchSessionRequest) =
  if request.sessionId.len == 0:
    socket.writeFrame(udkError, errorBody("watch detach requires a session id"))
    return
  let session = latestSessionRecord(config, request.sessionId)
  if session.sessionId.len == 0 or session.state == "missing":
    socket.writeFrame(udkError, errorBody("watch session not found: " &
      request.sessionId))
    return
  let event = nextWatchEvent(request.sessionId, request.sessionId,
    session.projectRoot, 1'u64, bekDiagnostic,
    "watch client detached; session remains running", terminal = false,
    payloadJson = "{\"detached\":true}")
  appendWatchEventRecord(config, request.sessionId, event)
  socket.writeFrame(udkWatchEvent, buildEventBody(event))

proc handleClient(socket: IpcConn; config: UserDaemonConfig; startedAt: Time;
                  generation: string; shuttingDown: var bool;
                  sessions: var seq[UserDaemonSession];
                  devRestart: DevRestartState) =
  let helloFrame = socket.readFrame()
  if helloFrame.kind != udkHello:
    socket.writeFrame(udkError, errorBody(
      "first user-daemon message must be hello, got " & $helloFrame.kind))
    return
  if not handleHello(socket, config, generation, helloFrame.body):
    return

  let frame = socket.readFrame()
  case frame.kind
  of udkStatus:
    socket.writeFrame(udkStatusResponse,
      statusBody(statusFor(config, startedAt, generation,
        countActiveSessionRecords(config), devRestart)))
  of udkShutdown:
    for session in loadSessionRecords(config):
      if session.mode == "watch" and session.state in ["accepted", "running",
          "watching", "idle", "cancelling"]:
        writeWatchStopRequest(config, session.sessionId,
          "daemon shutdown requested")
    shuttingDown = true
    socket.writeFrame(udkShutdownAck)
    logLine(config.logPath, "shutdown requested")
  of udkSessions:
    socket.writeFrame(udkSessionsResponse,
      sessionsBody(loadSessionRecords(config)))
  of udkWatchListRequest:
    var watchSessions: seq[UserDaemonSession] = @[]
    for session in loadSessionRecords(config):
      if session.mode == "watch":
        watchSessions.add(session)
    socket.writeFrame(udkSessionsResponse, sessionsBody(watchSessions))
  of udkBuildRequest:
    if devRestart.restartPending:
      socket.writeFrame(udkError, errorBody(
        "repro-daemon development restart is in progress; retry by run id " &
        "after reconnect where supported"))
      return
    handleBuildRequest(socket, config, parseBuildRequestBody(frame.body),
      sessions)
  of udkWatchStartRequest:
    if devRestart.restartPending:
      socket.writeFrame(udkError, errorBody(
        "repro-daemon development restart is in progress; retry by run id " &
        "after reconnect where supported"))
      return
    handleWatchStart(socket, config, parseWatchRequestBody(frame.body),
      sessions)
  of udkWatchAttachRequest:
    handleWatchAttach(socket, config, parseWatchSessionRequestBody(frame.body))
  of udkWatchStopRequest:
    handleWatchStop(socket, config, parseWatchSessionRequestBody(frame.body))
  of udkWatchDetachRequest:
    handleWatchDetach(socket, config, parseWatchSessionRequestBody(frame.body))
  else:
    socket.writeFrame(udkError, errorBody(
      "unsupported user-daemon message in lifecycle server: " &
      $frame.kind))

proc devRestartPollIntervalMs(): int64 =
  try:
    max(50, parseInt(getEnv("REPRO_DAEMON_DEV_RESTART_POLL_MS", "250")))
  except ValueError:
    250

proc devRestartStableMs(): int64 =
  try:
    max(50, parseInt(getEnv("REPRO_DAEMON_DEV_RESTART_STABLE_MS", "750")))
  except ValueError:
    750

proc restartCandidateReady(config: UserDaemonConfig;
                           state: var DevRestartState): bool =
  if not state.enabled or state.sourceImagePath.len == 0 or
      not fileExists(state.sourceImagePath):
    return false
  let nowMs = nowUnixMs()
  if nowMs - state.lastCheckMs < devRestartPollIntervalMs():
    return false
  state.lastCheckMs = nowMs
  let currentHash = fileDigestHex(state.sourceImagePath)
  if currentHash.len == 0 or currentHash == state.runningHash:
    state.candidateHash = ""
    state.candidateSinceMs = 0
    return false
  if currentHash != state.candidateHash:
    state.candidateHash = currentHash
    state.candidateSinceMs = nowMs
    logLine(config.logPath, "dev restart candidate source=" &
      state.sourceImagePath & " hash=" & currentHash)
    return false
  if nowMs - state.candidateSinceMs < devRestartStableMs():
    return false
  let active = countActiveSessionRecords(config)
  if active > 0:
    logLine(config.logPath, "dev restart deferred active-sessions=" & $active)
    return false
  true

proc daemonProcessArgs(config: UserDaemonConfig): seq[string]
proc launchWithFork(exe: string; config: UserDaemonConfig)

proc performDevSelfRestart(config: UserDaemonConfig;
                           listener: var IpcListener;
                           daemonLock: var UserDaemonLock;
                           state: var DevRestartState): bool =
  state.restartPending = true
  discard flushStatsObservations()
  let runId = newRestartRunId()
  let staged = stageDevDaemonBinary(state.sourceImagePath, config, runId)
  var nextConfig = config
  nextConfig.daemonExe = staged.imagePath
  nextConfig.sourceExe = state.sourceImagePath
  nextConfig.stagedGenerationDir = staged.generationDir
  nextConfig.previousStagedGenerationDir = state.stagedGenerationDir
  nextConfig.restartRunId = runId
  logLine(config.logPath, "dev restart launching source=" &
    state.sourceImagePath & " running=" & staged.imagePath & " runId=" &
    runId)
  closeIpcListener(listener)
  removeEndpointFiles(config)
  releaseUserDaemonLock(daemonLock)
  # Use the same launchWithFork the initial launch uses (fork + setsid +
  # dup2 stdio onto /dev/null and the log file + close inherited fds +
  # execv). osproc.startProcess with poDaemon on POSIX leaves the child
  # with stdio pipes that the parent immediately closes via
  # process.close(); the new daemon then dies of SIGPIPE on the first
  # write to stderr — the listener never binds, the test polls
  # 'daemon status' for 20 s, and the restart appears to time out.
  when defined(posix):
    launchWithFork(staged.imagePath, nextConfig)
  else:
    let process = startProcess(staged.imagePath,
      args = daemonProcessArgs(nextConfig),
      options = {poUsePath, poDaemon})
    process.close()
  logLine(config.logPath, "dev restart old process exiting runId=" & runId)
  true

proc runUserDaemonForeground*(config: UserDaemonConfig): int =
  # Named-pipe endpoints live under the kernel ``\\.\pipe\`` namespace
  # which is NOT a filesystem directory; ``createDir`` on its
  # parent would raise. Filesystem endpoints (AF_UNIX socket paths)
  # still need their parent directory provisioned.
  if endpointKindOf(config.endpoint) == ekUnixSocket:
    createDir(parentDir(config.endpoint))
  createDir(config.stateDir)
  createDir(parentDir(config.logPath))
  var daemonLock = acquireUserDaemonLock(config)
  defer:
    releaseUserDaemonLock(daemonLock)

  let restartChild =
    config.devMode and config.previousStagedGenerationDir.len > 0
  if not restartChild:
    try:
      let existing = queryUserDaemonStatus(config.endpoint)
      if existing.running:
        stderr.writeLine("repro-daemon: already running at " &
          config.endpoint)
        return 0
    except CatchableError:
      discard

  if not restartChild:
    discard cleanupStaleUserDaemonDiscovery(config)
  removeEndpointFiles(config)
  var listener = bindIpcListener(config.endpoint)
  var selfRestarting = false
  defer:
    closeIpcListener(listener)
    if not selfRestarting:
      removeEndpointFiles(config)
      logLine(config.logPath, "stopped")

  let startedAt = getTime()
  let generation = generationFor(startedAt)
  var devRestart = initDevRestartState(config)
  cleanupPreviousStagedGeneration(config)
  var sessions: seq[UserDaemonSession] = @[]
  writeStatusFile(config, statusFor(config, startedAt, generation,
    sessions.len, devRestart))
  logLine(config.logPath, "started role=" & UserDaemonRole &
    " endpoint=" & config.endpoint & " generation=" & generation &
    " devMode=" & $config.devMode & " source=" &
    devRestart.sourceImagePath & " running=" & devRestart.runningImagePath &
    " restartRunId=" & devRestart.restartRunId)

  var shuttingDown = false
  while not shuttingDown:
    if restartCandidateReady(config, devRestart):
      writeStatusFile(config, statusFor(config, startedAt, generation,
        countActiveSessionRecords(config), devRestart))
      if performDevSelfRestart(config, listener, daemonLock, devRestart):
        selfRestarting = true
        return 0
    if not listener.waitForClient(int(devRestartPollIntervalMs())):
      continue
    var client = listener.acceptIpc()
    try:
      handleClient(client, config, startedAt, generation, shuttingDown,
        sessions, devRestart)
    except CatchableError as err:
      logLine(config.logPath, "client error: " & err.msg)
      try:
        client.writeFrame(udkError, errorBody(err.msg))
      except CatchableError:
        discard
    client.closeIpcConn()
  0

proc siblingUserDaemonPath*(publicCliPath: string): string =
  ## Locate the ``repro-daemon`` companion binary for the given ``repro``
  ## executable. Prefers a sibling next to ``publicCliPath`` (the layout used
  ## by installed and ``just build`` outputs), then falls back to ``findExe``
  ## so a daemon staged into ``PATH`` (for example, in a dev shell with
  ## ``build/bin`` on ``PATH``) still wins. Returns the bare unqualified
  ## binary name when neither lookup succeeds; callers must treat that as
  ## "daemon binary not found" and fail fast rather than handing the bare
  ## name to ``launchctl`` / ``execv``.
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-daemon", ExeExt)
  if fileExists(candidate):
    return os.normalizedPath(candidate)
  let viaPath = findExe("repro-daemon")
  if viaPath.len > 0:
    return os.normalizedPath(absolutePath(viaPath))
  addFileExt("repro-daemon", ExeExt)

proc daemonProcessArgs(config: UserDaemonConfig): seq[string] =
  result = @["--foreground", "--endpoint", config.endpoint,
    "--state-dir", config.stateDir, "--log", config.logPath]
  if config.devMode:
    result.add("--dev")
  if config.sourceExe.len > 0:
    result.add("--source-exe")
    result.add(config.sourceExe)
  if config.stagedGenerationDir.len > 0:
    result.add("--staged-generation")
    result.add(config.stagedGenerationDir)
  if config.previousStagedGenerationDir.len > 0:
    result.add("--previous-staged-generation")
    result.add(config.previousStagedGenerationDir)
  if config.restartRunId.len > 0:
    result.add("--restart-run-id")
    result.add(config.restartRunId)

proc launchdLabel(config: UserDaemonConfig): string =
  "org.reprobuild.repro-daemon." &
    safePathSegment(config.endpoint.extractFilename, "user")

proc launchdPlistPath(config: UserDaemonConfig): string =
  config.stateDir / "launchd" / (launchdLabel(config) & ".plist")

proc renderLaunchdUserAgentPlist*(exe: string; config: UserDaemonConfig):
    string =
  var args = @[exe] & daemonProcessArgs(config)
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " &
    "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
    "<plist version=\"1.0\">\n<dict>\n" &
    "  <key>Label</key>\n  <string>" & xmlEscape(launchdLabel(config)) &
      "</string>\n" &
    "  <key>ProgramArguments</key>\n  <array>\n"
  for arg in args:
    result.add("    <string>" & xmlEscape(arg) & "</string>\n")
  result.add("  </array>\n" &
    "  <key>RunAtLoad</key>\n  <true/>\n" &
    "  <key>KeepAlive</key>\n  <false/>\n" &
    "  <key>StandardOutPath</key>\n  <string>" &
      xmlEscape(config.logPath) & "</string>\n" &
    "  <key>StandardErrorPath</key>\n  <string>" &
      xmlEscape(config.logPath) & "</string>\n" &
    "</dict>\n</plist>\n")

proc quoteCommand(args: openArray[string]): string =
  var parts: seq[string] = @[]
  for arg in args:
    parts.add(quoteShell(arg))
  parts.join(" ")

proc launchWithLaunchd(exe: string; config: UserDaemonConfig): bool =
  when defined(macosx):
    try:
      createDir(parentDir(launchdPlistPath(config)))
      writeFile(launchdPlistPath(config), renderLaunchdUserAgentPlist(exe,
        config))
      let serviceTarget = "gui/" & $currentUid()
      let bootstrap = execCmdEx(quoteCommand(["launchctl", "bootstrap",
        serviceTarget, launchdPlistPath(config)]))
      if bootstrap.exitCode == 0:
        logLine(config.logPath, "launch requested backend=launchd label=" &
          launchdLabel(config))
        return true
      let kickstart = execCmdEx(quoteCommand(["launchctl", "kickstart", "-k",
        serviceTarget & "/" & launchdLabel(config)]))
      if kickstart.exitCode == 0:
        logLine(config.logPath, "launch requested backend=launchd-kickstart label=" &
          launchdLabel(config))
        return true
      logLine(config.logPath, "launchd unavailable, falling back: " &
        bootstrap.output.strip() & " " & kickstart.output.strip())
    except CatchableError as err:
      logLine(config.logPath, "launchd launch failed, falling back: " &
        err.msg)
    false
  else:
    false

proc systemdUnitName(config: UserDaemonConfig): string =
  "repro-daemon-" & safePathSegment(config.endpoint.extractFilename,
    "user") & ".service"

proc launchWithSystemdUser(exe: string; config: UserDaemonConfig): bool =
  when defined(linux):
    try:
      # ExitType=cgroup is what lets the dev self-restart survive on
      # Linux: the old daemon performs the fork+exec of the staged
      # binary and then exits 0. With the default ExitType=main,
      # systemd treats the unit as inactive the moment that main
      # process exits, --collect removes it, and KillMode=control-group
      # SIGKILLs every other PID in the cgroup — including the
      # freshly-forked replacement. ExitType=cgroup keeps the unit
      # active as long as any process in the cgroup is alive, so the
      # replacement keeps running and can bind the endpoint.
      var args = @["systemd-run", "--user", "--unit=" & systemdUnitName(config),
        "--collect", "--quiet", "-p", "ExitType=cgroup",
        exe] & daemonProcessArgs(config)
      let res = execCmdEx(quoteCommand(args))
      if res.exitCode == 0:
        logLine(config.logPath, "launch requested backend=systemd-user unit=" &
          systemdUnitName(config))
        return true
      logLine(config.logPath, "systemd --user unavailable, falling back: " &
        res.output.strip())
    except CatchableError as err:
      logLine(config.logPath, "systemd --user launch failed, falling back: " &
        err.msg)
    false
  else:
    false

proc launchWithFork(exe: string; config: UserDaemonConfig) =
  when defined(posix):
    let argv = @[exe] & daemonProcessArgs(config)
    let cargv = allocCStringArray(argv)
    let exeCString = cstring(exe)
    let logPathCString = cstring(config.logPath)
    let pid = fork()
    if pid < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to fork repro-daemon")
    if pid == 0:
      discard setsid()
      let devNull = posix.open(cstring("/dev/null"), O_RDONLY)
      if devNull >= 0:
        discard dup2(devNull, 0)
      let logFd = posix.open(logPathCString,
        O_WRONLY or O_CREAT or O_APPEND, Mode(0o600))
      if logFd >= 0:
        discard dup2(logFd, 1)
        discard dup2(logFd, 2)
      for fd in 3.cint .. 255.cint:
        discard posix.close(fd)
      discard execv(exeCString, cargv)
      quit(127)
    logLine(config.logPath, "launch requested backend=posix-fork pid=" &
      $pid)

proc cleanupPlatformBackgroundRegistration*(config: UserDaemonConfig) =
  when defined(macosx):
    if fileExists(launchdPlistPath(config)):
      discard execCmdEx(quoteCommand(["launchctl", "bootout",
        "gui/" & $currentUid() & "/" & launchdLabel(config)]))
  elif defined(linux):
    discard execCmdEx(quoteCommand(["systemctl", "--user", "stop",
      systemdUnitName(config)]))

proc waitForUserDaemonStatus*(endpoint: string; timeoutMs = 60000):
    UserDaemonStatus =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let status = queryUserDaemonStatus(endpoint)
    if status.running:
      return status
    sleep(25)
  raise newException(UserDaemonRuntimeError,
    "timed out waiting for repro-daemon at " & endpoint)

proc startUserDaemon*(publicCliPath: string; config: UserDaemonConfig):
    UserDaemonStatus =
  let existing = queryUserDaemonStatus(config.endpoint)
  if existing.running:
    return existing
  when defined(posix):
    if userDaemonEndpointExists(config.endpoint) and
        userDaemonEndpointAcceptsConnections(config.endpoint):
      raise newException(UserDaemonRuntimeError,
        "repro-daemon endpoint accepts connections but did not complete a " &
          "compatible status handshake at " & config.endpoint &
          "; stop the incompatible daemon or set REPRO_DAEMON=off for direct mode")
  discard cleanupStaleUserDaemonDiscovery(config)
  let sourceExe =
    if config.daemonExe.len > 0: config.daemonExe
    else: siblingUserDaemonPath(publicCliPath)
  # Fail fast when the daemon binary cannot be located. Without this guard the
  # bare unqualified name returned by ``siblingUserDaemonPath`` propagates into
  # ``launchctl bootstrap`` (which silently registers a non-executable plist
  # entry and forces a 30 s status-wait timeout) and then into ``execv`` in the
  # posix-fork fallback (another 60 s wait). Both paths eventually surface as a
  # generic timeout that hides the real cause from CLI fallbacks. Raising here
  # lets ``runBuildCommand`` / ``runWatchCommand`` switch to direct mode in
  # milliseconds with a clear diagnostic naming the path we tried.
  if not isAbsolute(sourceExe) or not fileExists(sourceExe):
    raise newException(UserDaemonRuntimeError,
      "repro-daemon binary not found (looked for sibling next to " &
        publicCliPath & " and on PATH as 'repro-daemon'); set " &
        "REPRO_DAEMON=off or install/build repro-daemon next to repro")
  var launchConfig = config
  var exe = sourceExe
  if config.devMode:
    let staged = stageDevDaemonBinary(sourceExe, config,
      if config.restartRunId.len > 0: config.restartRunId else: newRestartRunId(
        "dev-start"))
    exe = staged.imagePath
    launchConfig.sourceExe = absoluteNormalized(sourceExe)
    launchConfig.stagedGenerationDir = staged.generationDir
    launchConfig.restartRunId = staged.runId
    logLine(config.logPath, "dev start staged source=" & sourceExe &
      " running=" & exe & " runId=" & staged.runId)
  when defined(posix):
    createDir(parentDir(launchConfig.endpoint))
    createDir(launchConfig.stateDir)
    createDir(parentDir(launchConfig.logPath))
    var launchedWithPlatformManager = false
    when defined(macosx):
      launchedWithPlatformManager = launchWithLaunchd(exe, launchConfig)
      if not launchedWithPlatformManager:
        launchWithFork(exe, launchConfig)
    elif defined(linux):
      launchedWithPlatformManager = launchWithSystemdUser(exe, launchConfig)
      if not launchedWithPlatformManager:
        launchWithFork(exe, launchConfig)
    else:
      launchWithFork(exe, launchConfig)
    if launchedWithPlatformManager:
      try:
        return waitForUserDaemonStatus(launchConfig.endpoint, 30000)
      except UserDaemonRuntimeError as err:
        logLine(launchConfig.logPath,
          "platform launcher did not produce a ready repro-daemon: " &
            err.msg & "; falling back to posix-fork")
        cleanupPlatformBackgroundRegistration(launchConfig)
        discard cleanupStaleUserDaemonDiscovery(launchConfig)
        launchWithFork(exe, launchConfig)
  else:
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env["REPRO_DAEMON_ENDPOINT"] = launchConfig.endpoint
    env["REPRO_DAEMON_STATE_DIR"] = launchConfig.stateDir
    let process = startProcess(exe,
      args = daemonProcessArgs(launchConfig),
      env = env,
      options = {poUsePath, poDaemon})
    process.close()
  waitForUserDaemonStatus(launchConfig.endpoint)

proc stopUserDaemon*(endpoint = defaultUserDaemonEndpoint()) =
  requestUserDaemonShutdown(endpoint)

proc renderUserDaemonStatus*(status: UserDaemonStatus): string =
  if not status.running:
    return "repro daemon: not-running\nendpoint: " & status.endpoint
  "repro daemon: running\n" &
    "role: " & status.role & "\n" &
    "endpoint: " & status.endpoint & "\n" &
    "state-dir: " & status.stateDir & "\n" &
    "log: " & status.logPath & "\n" &
    "protocol: " & $status.protocolMajor & "." & $status.protocolMinor & "\n" &
    "binary-name: " & status.binary.name & "\n" &
    "binary-path: " & status.binary.path & "\n" &
    "binary-version: " & status.binary.version & "\n" &
    "features: " & status.featureFlags & "\n" &
    "generation: " & status.generation & "\n" &
    "pid: " & $status.pid & "\n" &
    "uptime-seconds: " & $status.uptimeSeconds & "\n" &
    "active-sessions: " & $status.activeSessionCount & "\n" &
    "dev-mode: " & $status.devMode & "\n" &
    "source-image-path: " & status.sourceImagePath & "\n" &
    "running-image-path: " & status.runningImagePath & "\n" &
    "source-hash: " & status.sourceHash & "\n" &
    "running-hash: " & status.runningHash & "\n" &
    "protocol-generation: " & status.protocolGeneration & "\n" &
    "restart-run-id: " & status.restartRunId & "\n" &
    "staged-generation-dir: " & status.stagedGenerationDir & "\n" &
    "previous-staged-generation-dir: " &
      status.previousStagedGenerationDir & "\n" &
    "reconnect-limitations: " & status.reconnectLimitations

proc renderUserDaemonLogs*(config: UserDaemonConfig): string =
  if not fileExists(config.logPath):
    return "repro daemon logs: no log file at " & config.logPath
  readFile(config.logPath)

proc renderUserDaemonSessions*(sessions: openArray[UserDaemonSession]):
    string =
  if sessions.len == 0:
    return "repro daemon sessions: none"
  result = "repro daemon sessions: " & $sessions.len
  for session in sessions:
    result.add("\n" & session.sessionId & "\t" & session.mode & "\t" &
      session.state & "\t" & $session.exitCode & "\t" &
      session.projectRoot)
    if session.mode == "watch":
      result.add("\tselectedRoots=" & session.selectedRoots.join(",") &
        "\tdebounceMs=" & $session.debounceMs &
        "\t watchedPaths=" & $session.watchedPaths.len &
        "\ttierState=" & session.tierState &
        "\tlastResult=" & session.lastResult)
    if session.message.len > 0:
      result.add("\t" & session.message)

proc parseUserDaemonConfigFlags*(args: seq[string];
                                 base = defaultUserDaemonConfig()):
    tuple[config: UserDaemonConfig; rest: seq[string]] =
  result.config = base
  var explicitLog = false
  var i = 0
  while i < args.len:
    let raw = args[i]
    proc valueFor(flag: string): string =
      let prefix = flag & "="
      if raw.startsWith(prefix):
        return raw[prefix.len .. ^1]
      if raw == flag:
        if i + 1 >= args.len:
          raise newException(ValueError, flag & " requires a value")
        inc i
        return args[i]
      raise newException(ValueError, "internal user-daemon flag parse error")

    if raw == "--foreground":
      result.config.foreground = true
    elif raw == "--dev":
      result.config.devMode = true
    elif raw == "--daemon-exe" or raw.startsWith("--daemon-exe="):
      result.config.daemonExe = valueFor("--daemon-exe")
    elif raw == "--source-exe" or raw.startsWith("--source-exe="):
      result.config.sourceExe = valueFor("--source-exe")
    elif raw == "--staged-generation" or
        raw.startsWith("--staged-generation="):
      result.config.stagedGenerationDir = valueFor("--staged-generation")
    elif raw == "--previous-staged-generation" or
        raw.startsWith("--previous-staged-generation="):
      result.config.previousStagedGenerationDir =
        valueFor("--previous-staged-generation")
    elif raw == "--restart-run-id" or raw.startsWith("--restart-run-id="):
      result.config.restartRunId = valueFor("--restart-run-id")
    elif raw == "--endpoint" or raw.startsWith("--endpoint="):
      result.config.endpoint = valueFor("--endpoint")
    elif raw == "--state-dir" or raw.startsWith("--state-dir="):
      result.config.stateDir = valueFor("--state-dir")
    elif raw == "--log" or raw.startsWith("--log="):
      result.config.logPath = valueFor("--log")
      explicitLog = true
    else:
      result.rest.add(raw)
    inc i
  if not explicitLog:
    result.config.logPath = result.config.stateDir / "logs" /
      "repro-daemon.log"

proc userDaemonUsage*(): string =
  "usage: repro-daemon [--foreground] [--dev] [--endpoint PATH] " &
    "[--state-dir PATH] [--log PATH]"

proc runUserDaemonCommand*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["--help", "-h"]:
    echo userDaemonUsage()
    return 0
  try:
    let parsed = parseUserDaemonConfigFlags(args)
    if parsed.rest.len > 0:
      stderr.writeLine("repro-daemon: unexpected argument: " &
        parsed.rest[0])
      return 2
    return runUserDaemonForeground(parsed.config)
  except CatchableError as err:
    stderr.writeLine("repro-daemon: error: " & err.msg)
    return 1
