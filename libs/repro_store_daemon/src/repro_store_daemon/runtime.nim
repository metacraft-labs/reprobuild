import std/[net, os, osproc, strtabs, strutils, times]

import repro_local_store

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
  StoreDaemonRuntimeError* = object of CatchableError

  DevDaemonConfig* = object
    endpoint*: string
    storeRoot*: string

  DevDaemonLock = object
    held: bool
    lockPath: string
    token: string
    when defined(posix):
      fd: cint

const DevDaemonLockFileName = ".reprostored-dev.lock"

proc parseStoreRootFlag(args: seq[string]; defaultRoot = ""):
    tuple[root: string; rest: seq[string]] =
  var i = 0
  while i < args.len:
    let raw = args[i]
    if raw.startsWith("--store-root="):
      result.root = raw[len("--store-root=") .. ^1]
    elif raw == "--store-root":
      if i + 1 >= args.len:
        raise newException(ValueError, "--store-root requires a path")
      result.root = args[i + 1]
      inc i
    else:
      result.rest.add(raw)
    inc i
  if result.root.len == 0:
    result.root = defaultRoot

proc parseEndpointFlag(args: seq[string]; defaultEndpoint = ""):
    tuple[endpoint: string; rest: seq[string]] =
  var i = 0
  while i < args.len:
    let raw = args[i]
    if raw.startsWith("--endpoint="):
      result.endpoint = raw[len("--endpoint=") .. ^1]
    elif raw == "--endpoint":
      if i + 1 >= args.len:
        raise newException(ValueError, "--endpoint requires a path")
      result.endpoint = args[i + 1]
      inc i
    else:
      result.rest.add(raw)
    inc i
  if result.endpoint.len == 0:
    result.endpoint = defaultEndpoint

proc parseDevConfig*(args: seq[string]): tuple[config: DevDaemonConfig;
    rest: seq[string]] =
  let p1 = parseStoreRootFlag(args, defaultDevStoreRoot())
  let p2 = parseEndpointFlag(p1.rest, defaultDevEndpoint())
  result.config = DevDaemonConfig(endpoint: p2.endpoint,
    storeRoot: devStoreRoot(p1.root))
  result.rest = p2.rest

proc devDaemonLockPath*(storeRoot: string): string =
  storeRoot / DevDaemonLockFileName

proc lockMetadata(config: DevDaemonConfig; token: string): string =
  "profile=" & StoreDaemonProfileDev & "\n" &
    "endpoint=" & config.endpoint & "\n" &
    "storeRoot=" & config.storeRoot & "\n" &
    "pid=" & $getCurrentProcessId() & "\n" &
    "token=" & token & "\n" &
    "protocolVersion=" & $StoreDaemonProtocolVersion & "\n"

proc acquireDevDaemonLock(config: DevDaemonConfig): DevDaemonLock =
  when defined(posix):
    createDir(config.storeRoot)
    let lockPath = devDaemonLockPath(config.storeRoot)
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      raise newException(StoreDaemonRuntimeError,
        "failed to open daemon lockfile " & lockPath & ", errno=" & $errno)
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
        var msg = "daemon lock held by a live reprostored --dev for " &
          "store root " & config.storeRoot & " (lockfile " & lockPath & ")"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(StoreDaemonRuntimeError, msg)
      raise newException(StoreDaemonRuntimeError,
        "failed to acquire daemon lockfile " & lockPath & ", errno=" &
        $lockErr)
    let now = getTime()
    let token = $getCurrentProcessId() & "-" & $now.toUnix & "-" &
      $now.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    DevDaemonLock(held: true, lockPath: lockPath, token: token, fd: fd)
  else:
    DevDaemonLock(held: false)

proc releaseDevDaemonLock(lock: var DevDaemonLock) =
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

proc writeStatusFile(config: DevDaemonConfig) =
  let path = statusFileForEndpoint(config.endpoint)
  createDir(parentDir(path))
  writeFile(path,
    "profile=" & StoreDaemonProfileDev & "\n" &
    "endpoint=" & config.endpoint & "\n" &
    "storeRoot=" & config.storeRoot & "\n" &
    "pid=" & $getCurrentProcessId() & "\n" &
    "protocolVersion=" & $StoreDaemonProtocolVersion & "\n")

proc removeEndpointFiles(config: DevDaemonConfig) =
  try: removeFile(config.endpoint) except OSError: discard
  try: removeFile(statusFileForEndpoint(config.endpoint)) except OSError: discard

proc statusFor(config: DevDaemonConfig; startedAt: Time;
               pending: int): StoreDaemonStatus =
  var store = openStore(config.storeRoot)
  defer: store.close()
  StoreDaemonStatus(
    running: true,
    protocolVersion: StoreDaemonProtocolVersion,
    daemonProfile: StoreDaemonProfileDev,
    endpoint: config.endpoint,
    storeRoot: config.storeRoot,
    pid: int64(getCurrentProcessId()),
    uptimeSeconds: getTime().toUnix - startedAt.toUnix,
    realizedPrefixCount: store.listPrefixes().len,
    rootCount: store.listRoots().len,
    pendingRealizationCount: pending)

proc realizeSyntheticDaemon(config: DevDaemonConfig;
                            req: SyntheticRealizeRequest):
    StoreDaemonRealizeResult =
  if req.storeRoot.len > 0 and
      os.normalizedPath(req.storeRoot) != os.normalizedPath(config.storeRoot):
    raise newException(StoreDaemonRuntimeError,
      "request store root does not match daemon store root")

  var store = openStore(config.storeRoot)
  defer: store.close()
  let prefixId = parsePrefixIdHex(req.realizationIdHex)
  let hint = StoreReceiptHint(
    adapter: "synthetic",
    packageName: req.packageName,
    version: req.version,
    declaredExecutablePath: "bin/tool",
    lockIdentity: "synthetic:" & req.realizationIdHex,
    materializationMechanism: "directory")
  let outcome = store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      if req.delayMs > 0:
        sleep(req.delayMs)
      createDir(stagingDir / "bin")
      writeFile(stagingDir / "bin" / "tool", req.payload)
      mechanism = "directory",
    writerMode = "daemon")
  let scoped = scopedRootId(req.holderId, req.rootId)
  store.registerRoot(scoped, rkSession, currentUid())
  store.attachPrefixToRoot(scoped, prefixId)
  StoreDaemonRealizeResult(
    status:
      if outcome.outcome == roAlreadyPresent: "already-realized"
      else: "realized",
    realizedPrefixPath: outcome.absolutePath,
    realizationHashHex: req.realizationIdHex,
    rootId: scoped,
    writerMode: "daemon")

proc releaseRootDaemon(config: DevDaemonConfig; holderId, rootId: string) =
  var store = openStore(config.storeRoot)
  defer: store.close()
  store.deleteRoot(scopedRootId(holderId, rootId))

proc handleClient(socket: Socket; config: DevDaemonConfig; startedAt: Time;
                  shuttingDown: var bool; pending: var int) =
  let hello = socket.readFrame()
  if hello.kind != sdkHello:
    socket.writeFrame(sdkError, errorBody("expected Hello"))
    return
  let parsed = parseHello(hello.body)
  if parsed.version != StoreDaemonProtocolVersion:
    socket.writeFrame(sdkError,
      errorBody("unsupported protocol version: " & $parsed.version))
    return
  socket.writeFrame(sdkHelloAck,
    helloAckBody(StoreDaemonProfileDev, config.storeRoot,
      int64(getCurrentProcessId())))

  let frame = socket.readFrame()
  case frame.kind
  of sdkStatus:
    socket.writeFrame(sdkStatusResponse,
      statusBody(statusFor(config, startedAt, pending)))
  of sdkSyntheticRealize:
    inc pending
    try:
      let res = realizeSyntheticDaemon(config, parseSyntheticBody(frame.body))
      socket.writeFrame(sdkRealizeResponse, realizeResponseBody(res))
    finally:
      dec pending
  of sdkReleaseRoot:
    let req = parseReleaseRootBody(frame.body)
    releaseRootDaemon(config, req.holderId, req.rootId)
    socket.writeFrame(sdkReleaseRootAck)
  of sdkShutdown:
    shuttingDown = true
    socket.writeFrame(sdkShutdownAck)
  else:
    socket.writeFrame(sdkError,
      errorBody("unsupported store-daemon message: " & $frame.kind))

proc runDevDaemonForeground*(config: DevDaemonConfig): int =
  when defined(posix):
    var daemonLock = acquireDevDaemonLock(config)
    defer:
      releaseDevDaemonLock(daemonLock)

    try:
      let existing = queryDevStatus(config.endpoint)
      if existing.running:
        if os.normalizedPath(existing.storeRoot) ==
            os.normalizedPath(config.storeRoot):
          stderr.writeLine("reprostored --dev: already running for " &
            config.storeRoot)
          return 0
        stderr.writeLine("reprostored --dev: endpoint already hosts store " &
          existing.storeRoot)
        return 2
    except CatchableError:
      discard

    block recoverAtStartup:
      var store = openStore(config.storeRoot)
      defer: store.close()
      discard store.recover()

    removeEndpointFiles(config)
    var listener = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    defer:
      listener.close()
      removeEndpointFiles(config)
    listener.bindUnix(config.endpoint)
    listener.listen()
    writeStatusFile(config)

    let startedAt = getTime()
    var shuttingDown = false
    var pending = 0
    while not shuttingDown:
      var client: owned(Socket)
      listener.accept(client)
      try:
        handleClient(client, config, startedAt, shuttingDown, pending)
      except CatchableError as err:
        try:
          client.writeFrame(sdkError, errorBody(err.msg))
        except CatchableError:
          discard
      client.close()
    0
  else:
    stderr.writeLine("reprostored --dev: development IPC is not implemented " &
      "on this platform")
    2

proc reprostoredUsage*(): string =
  "usage: reprostored --dev [--store-root <path>] [--endpoint <path>]"

proc runReprostoredCommand*(args: seq[string]): int =
  if args.len == 1 and args[0] in ["--help", "-h"]:
    echo reprostoredUsage()
    return 0
  if "--dev" notin args:
    stderr.writeLine("reprostored: only --dev is implemented in this pass")
    return 2
  var filtered: seq[string] = @[]
  for arg in args:
    if arg != "--dev":
      filtered.add(arg)
  try:
    let parsed = parseDevConfig(filtered)
    if parsed.rest.len > 0:
      stderr.writeLine("reprostored: unexpected argument: " & parsed.rest[0])
      return 2
    return runDevDaemonForeground(parsed.config)
  except CatchableError as err:
    stderr.writeLine("reprostored: error: " & err.msg)
    return 1

proc siblingReprostoredPath*(publicCliPath: string): string =
  let candidate = parentDir(publicCliPath) / addFileExt("reprostored", ExeExt)
  if fileExists(candidate):
    candidate
  else:
    addFileExt("reprostored", ExeExt)

proc waitForDevStatus(endpoint, expectedRoot: string; timeoutMs = 15000):
    StoreDaemonStatus =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let status = queryDevStatus(endpoint)
    if status.running:
      if expectedRoot.len == 0 or
          os.normalizedPath(status.storeRoot) ==
            os.normalizedPath(expectedRoot):
        return status
      raise newException(StoreDaemonRuntimeError,
        "running dev store daemon has incompatible root " & status.storeRoot)
    sleep(25)
  raise newException(StoreDaemonRuntimeError,
    "timed out waiting for dev store daemon at " & endpoint)

proc startDevDaemon*(publicCliPath: string; config: DevDaemonConfig):
    StoreDaemonStatus =
  let existing = queryDevStatus(config.endpoint)
  if existing.running:
    if os.normalizedPath(existing.storeRoot) ==
        os.normalizedPath(config.storeRoot):
      return existing
    raise newException(StoreDaemonRuntimeError,
      "dev store daemon already running with store root " & existing.storeRoot)
  let exe = siblingReprostoredPath(publicCliPath)
  when defined(posix):
    let pid = fork()
    if pid < 0:
      raise newException(StoreDaemonRuntimeError,
        "failed to fork dev store daemon")
    if pid == 0:
      discard setsid()
      let devNull = posix.open(cstring("/dev/null"), O_RDWR)
      if devNull >= 0:
        discard dup2(devNull, 0)
        discard dup2(devNull, 1)
        discard dup2(devNull, 2)
      for fd in 3.cint .. 255.cint:
        discard posix.close(fd)
      let argv = allocCStringArray([
        exe, "--dev", "--store-root", config.storeRoot,
        "--endpoint", config.endpoint])
      discard execv(cstring(exe), argv)
      quit(127)
  else:
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env["REPROSTORED_ENDPOINT"] = config.endpoint
    let process = startProcess(exe,
      args = @["--dev", "--store-root", config.storeRoot,
        "--endpoint", config.endpoint],
      env = env,
      options = {poUsePath, poDaemon})
    process.close()
  waitForDevStatus(config.endpoint, config.storeRoot)

proc stopDevDaemon*(endpoint = defaultDevEndpoint()) =
  requestDevShutdown(endpoint)

proc renderStatus*(status: StoreDaemonStatus): string =
  if not status.running:
    return "repro store daemon: not-running\nendpoint: " & status.endpoint
  "repro store daemon: running\n" &
    "profile: " & status.daemonProfile & "\n" &
    "endpoint: " & status.endpoint & "\n" &
    "store-root: " & status.storeRoot & "\n" &
    "protocol-version: " & $status.protocolVersion & "\n" &
    "pid: " & $status.pid & "\n" &
    "uptime-seconds: " & $status.uptimeSeconds & "\n" &
    "realized-prefix-count: " & $status.realizedPrefixCount & "\n" &
    "root-count: " & $status.rootCount & "\n" &
    "pending-realizations: " & $status.pendingRealizationCount
