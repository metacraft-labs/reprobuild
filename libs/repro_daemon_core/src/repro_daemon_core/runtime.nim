import std/[net, os, osproc, strtabs, strutils, times]

import repro_core

import ./client
import ./protocol

when defined(posix):
  import std/posix except Time

  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

type
  UserDaemonRuntimeError* = object of CatchableError

  UserDaemonConfig* = object
    endpoint*: string
    stateDir*: string
    logPath*: string
    foreground*: bool
    devMode*: bool
    daemonExe*: string

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

  UserDaemonLock = object
    held: bool
    lockPath: string
    token: string
    when defined(posix):
      fd: cint

const UserDaemonLockFileName = ".repro-daemon.lock"

var userDaemonBuildExecutor: UserDaemonBuildExecutor

proc setUserDaemonBuildExecutor*(executor: UserDaemonBuildExecutor) =
  userDaemonBuildExecutor = executor

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

proc defaultUserDaemonConfig*(daemonExe = ""; foreground = false;
                              devMode = false): UserDaemonConfig =
  UserDaemonConfig(endpoint: defaultUserDaemonEndpoint(),
    stateDir: userDaemonStateDir(),
    logPath: defaultUserDaemonLogPath(),
    foreground: foreground,
    devMode: devMode,
    daemonExe: daemonExe)

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
  lock.held = false

proc statusPath(config: UserDaemonConfig): string =
  config.stateDir / "status" /
    (safePathSegment(config.endpoint.extractFilename, "repro-daemon") &
      ".status")

proc sessionRecordsDir(config: UserDaemonConfig): string =
  config.stateDir / "sessions"

proc sessionRecordPath(config: UserDaemonConfig; sessionId: string): string =
  sessionRecordsDir(config) / (safePathSegment(sessionId, "session") & ".session")

proc flattenRecordValue(value: string): string =
  value.replace("\n", "\\n").replace("\r", "\\r")

proc expandRecordValue(value: string): string =
  value.replace("\\n", "\n").replace("\\r", "\r")

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
    "message=" & flattenRecordValue(session.message) & "\n")

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
    if session.state in ["accepted", "running", "cancelling"]:
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
               generation: string; activeSessionCount = 0): UserDaemonStatus =
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
    devMode: config.devMode)

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
    "featureFlags=" & status.featureFlags & "\n")

proc handleHello(socket: Socket; config: UserDaemonConfig; generation: string;
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

proc nowUnixMs(): int64 =
  let current = getTime()
  current.toUnix * 1000 + int64(current.nanosecond div 1_000_000)

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

proc updateSessionState(config: UserDaemonConfig; session: var UserDaemonSession;
                        state: string; exitCode = -1; message = "") =
  session.state = state
  session.exitCode = exitCode
  if message.len > 0:
    session.message = message
  if state notin ["accepted", "running", "cancelling"]:
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

proc clientDisconnected(socket: Socket): bool =
  when defined(posix):
    let fd = socket.getFd()
    var fds = TPollfd(fd: cast[cint](fd), events: POLLIN, revents: 0)
    let rc = poll(addr(fds), Tnfds(1), 0.cint)
    if rc <= 0:
      return false
    if (fds.revents and POLLHUP) != 0 or (fds.revents and POLLERR) != 0 or
        (fds.revents and POLLNVAL) != 0:
      return true
    if (fds.revents and POLLIN) != 0:
      var ch: char
      let n = recv(fd, addr(ch), 1, MSG_PEEK)
      return n == 0
    false
  else:
    false

proc waitForBuildUnsupportedOrDisconnect(socket: Socket; delayMs: int): bool =
  ## Returns true when the attached client disconnected before the placeholder
  ## M3 unsupported response was sent.
  let deadline = epochTime() + float(delayMs) / 1000.0
  while epochTime() < deadline:
    if socket.clientDisconnected():
      return true
    sleep(25)
  socket.clientDisconnected()

proc runBuildRequestWorker(socket: Socket; config: UserDaemonConfig;
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

proc handleBuildRequest(socket: Socket; config: UserDaemonConfig;
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
        try: socket.close() except CatchableError: discard
        quit(0)
      logLine(config.logPath, "build worker started session=" & sessionId &
        " pid=" & $pid)
    else:
      runBuildRequestWorker(socket, config, request, session)
  finally:
    sessions.removeSession(sessionId)

proc handleClient(socket: Socket; config: UserDaemonConfig; startedAt: Time;
                  generation: string; shuttingDown: var bool;
                  sessions: var seq[UserDaemonSession]) =
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
        countActiveSessionRecords(config))))
  of udkShutdown:
    shuttingDown = true
    socket.writeFrame(udkShutdownAck)
    logLine(config.logPath, "shutdown requested")
  of udkSessions:
    socket.writeFrame(udkSessionsResponse,
      sessionsBody(loadSessionRecords(config)))
  of udkBuildRequest:
    handleBuildRequest(socket, config, parseBuildRequestBody(frame.body),
      sessions)
  else:
    socket.writeFrame(udkError, errorBody(
      "unsupported user-daemon message in lifecycle server: " &
      $frame.kind))

proc runUserDaemonForeground*(config: UserDaemonConfig): int =
  when defined(posix):
    createDir(parentDir(config.endpoint))
    createDir(config.stateDir)
    createDir(parentDir(config.logPath))
    var daemonLock = acquireUserDaemonLock(config)
    defer:
      releaseUserDaemonLock(daemonLock)

    try:
      let existing = queryUserDaemonStatus(config.endpoint)
      if existing.running:
        stderr.writeLine("repro-daemon: already running at " &
          config.endpoint)
        return 0
    except CatchableError:
      discard

    discard cleanupStaleUserDaemonDiscovery(config)
    removeEndpointFiles(config)
    var listener = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    defer:
      listener.close()
      removeEndpointFiles(config)
      logLine(config.logPath, "stopped")
    listener.bindUnix(config.endpoint)
    listener.listen()

    let startedAt = getTime()
    let generation = generationFor(startedAt)
    var sessions: seq[UserDaemonSession] = @[]
    writeStatusFile(config, statusFor(config, startedAt, generation,
      sessions.len))
    logLine(config.logPath, "started role=" & UserDaemonRole &
      " endpoint=" & config.endpoint & " generation=" & generation)

    var shuttingDown = false
    while not shuttingDown:
      var client: owned(Socket)
      listener.accept(client)
      try:
        handleClient(client, config, startedAt, generation, shuttingDown,
          sessions)
      except CatchableError as err:
        logLine(config.logPath, "client error: " & err.msg)
        try:
          client.writeFrame(udkError, errorBody(err.msg))
        except CatchableError:
          discard
      client.close()
    0
  else:
    stderr.writeLine("repro-daemon: IPC is not implemented on this platform")
    2

proc siblingUserDaemonPath*(publicCliPath: string): string =
  let candidate = parentDir(publicCliPath) /
    addFileExt("repro-daemon", ExeExt)
  if fileExists(candidate):
    os.normalizedPath(candidate)
  else:
    addFileExt("repro-daemon", ExeExt)

proc launchdLabel(config: UserDaemonConfig): string =
  "org.reprobuild.repro-daemon." &
    safePathSegment(config.endpoint.extractFilename, "user")

proc launchdPlistPath(config: UserDaemonConfig): string =
  config.stateDir / "launchd" / (launchdLabel(config) & ".plist")

proc renderLaunchdUserAgentPlist*(exe: string; config: UserDaemonConfig):
    string =
  var args = @[exe, "--foreground", "--endpoint", config.endpoint,
    "--state-dir", config.stateDir, "--log", config.logPath]
  if config.devMode:
    args.add("--dev")
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
      var args = @["systemd-run", "--user", "--unit=" & systemdUnitName(config),
        "--collect", "--quiet", exe, "--foreground", "--endpoint",
        config.endpoint, "--state-dir", config.stateDir, "--log",
        config.logPath]
      if config.devMode:
        args.add("--dev")
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
    let pid = fork()
    if pid < 0:
      raise newException(UserDaemonRuntimeError,
        "failed to fork repro-daemon")
    if pid == 0:
      discard setsid()
      let devNull = posix.open(cstring("/dev/null"), O_RDONLY)
      if devNull >= 0:
        discard dup2(devNull, 0)
      let logFd = posix.open(cstring(config.logPath),
        O_WRONLY or O_CREAT or O_APPEND, Mode(0o600))
      if logFd >= 0:
        discard dup2(logFd, 1)
        discard dup2(logFd, 2)
      for fd in 3.cint .. 255.cint:
        discard posix.close(fd)
      var argv = @[exe, "--foreground", "--endpoint", config.endpoint,
        "--state-dir", config.stateDir, "--log", config.logPath]
      if config.devMode:
        argv.add("--dev")
      let cargv = allocCStringArray(argv)
      discard execv(cstring(exe), cargv)
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
  discard cleanupStaleUserDaemonDiscovery(config)
  let exe =
    if config.daemonExe.len > 0: config.daemonExe
    else: siblingUserDaemonPath(publicCliPath)
  when defined(posix):
    createDir(parentDir(config.endpoint))
    createDir(config.stateDir)
    createDir(parentDir(config.logPath))
    when defined(macosx):
      if not launchWithLaunchd(exe, config):
        launchWithFork(exe, config)
    elif defined(linux):
      if not launchWithSystemdUser(exe, config):
        launchWithFork(exe, config)
    else:
      launchWithFork(exe, config)
  else:
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env["REPRO_DAEMON_ENDPOINT"] = config.endpoint
    env["REPRO_DAEMON_STATE_DIR"] = config.stateDir
    let process = startProcess(exe,
      args = @["--foreground", "--endpoint", config.endpoint,
        "--state-dir", config.stateDir, "--log", config.logPath],
      env = env,
      options = {poUsePath, poDaemon})
    process.close()
  waitForUserDaemonStatus(config.endpoint)

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
    "dev-mode: " & $status.devMode

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
