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

  UserDaemonLock = object
    held: bool
    lockPath: string
    token: string
    when defined(posix):
      fd: cint

const UserDaemonLockFileName = ".repro-daemon.lock"

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

proc removeEndpointFiles(config: UserDaemonConfig) =
  try: removeFile(config.endpoint) except OSError: discard
  try:
    removeFile(config.stateDir / "status" /
      (config.endpoint.extractFilename & ".status"))
  except OSError:
    discard

proc generationFor(startedAt: Time): string =
  $getCurrentProcessId() & "-" & $startedAt.toUnix & "-" & $startedAt.nanosecond

proc statusFor(config: UserDaemonConfig; startedAt: Time;
               generation: string): UserDaemonStatus =
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
    activeSessionCount: 0,
    devMode: config.devMode)

proc writeStatusFile(config: UserDaemonConfig; status: UserDaemonStatus) =
  let path = config.stateDir / "status" /
    (config.endpoint.extractFilename & ".status")
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

proc handleClient(socket: Socket; config: UserDaemonConfig; startedAt: Time;
                  generation: string; shuttingDown: var bool) =
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
      statusBody(statusFor(config, startedAt, generation)))
  of udkShutdown:
    shuttingDown = true
    socket.writeFrame(udkShutdownAck)
    logLine(config.logPath, "shutdown requested")
  else:
    socket.writeFrame(udkError, errorBody(
      "unsupported user-daemon message in M1 lifecycle server: " &
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
    writeStatusFile(config, statusFor(config, startedAt, generation))
    logLine(config.logPath, "started role=" & UserDaemonRole &
      " endpoint=" & config.endpoint & " generation=" & generation)

    var shuttingDown = false
    while not shuttingDown:
      var client: owned(Socket)
      listener.accept(client)
      try:
        handleClient(client, config, startedAt, generation, shuttingDown)
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
  let exe =
    if config.daemonExe.len > 0: config.daemonExe
    else: siblingUserDaemonPath(publicCliPath)
  when defined(posix):
    createDir(parentDir(config.endpoint))
    createDir(config.stateDir)
    createDir(parentDir(config.logPath))
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
