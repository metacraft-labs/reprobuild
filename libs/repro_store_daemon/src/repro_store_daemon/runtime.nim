import std/[os, osproc, strtabs, strutils, times]

import repro_interface_artifacts
import repro_local_store
import repro_tool_profiles

import ./client
import ./protocol
# `repro store serve`'s command line is declared in repro's description;
# only its spellings are read here, at compile time.
from repro_cli_support/cli_description import reproLongFlags


when defined(posix):
  import std/posix except Time

  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

when defined(windows):
  import std/winlean
  import repro_daemon_core/windows_detached_spawn

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
    when defined(windows):
      handle: Handle

const DevDaemonLockFileName = ".reprostored-dev.lock"

const StoreServeFlags = reproLongFlags(@["store", "serve"])
  ## The long spelling of each flag of `repro store serve`.

proc storeServeArgs*(config: DevDaemonConfig): seq[string] =
  ## The development store daemon's command line, `repro store serve --dev
  ## ...` (the `repro` image run as the daemon), in the words repro's
  ## generated parser reads back to ``config``: each flag the spelling the
  ## description declares, its value (a path) the next word.
  @["store", "serve", StoreServeFlags.dev,
    StoreServeFlags.storeRoot, config.storeRoot,
    StoreServeFlags.endpoint, config.endpoint]

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
  elif defined(windows):
    createDir(config.storeRoot)
    let lockPath = devDaemonLockPath(config.storeRoot)
    let wpath = newWideCString(lockPath)
    # SHARE_READ | SHARE_WRITE so the matching `writeFile(lockPath, ...)`
    # below — and any concurrent contender's CreateFileW — succeeds and
    # mutual exclusion is delegated to ``LockFileEx``.
    let h = createFileW(wpath,
      (GENERIC_READ or GENERIC_WRITE).DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE).DWORD, nil,
      OPEN_ALWAYS.DWORD, 0.DWORD, 0)
    if h == INVALID_HANDLE_VALUE:
      raise newException(StoreDaemonRuntimeError,
        "failed to open daemon lockfile " & lockPath &
          ", Windows error=" & $osLastError())
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
        var msg = "daemon lock held by a live reprostored --dev for " &
          "store root " & config.storeRoot & " (lockfile " & lockPath & ")"
        if detail.len > 0:
          msg.add("; " & detail.replace("\n", ", "))
        raise newException(StoreDaemonRuntimeError, msg)
      raise newException(StoreDaemonRuntimeError,
        "failed to acquire daemon lockfile " & lockPath &
          ", Windows error=" & $lockErr)
    let now = getTime()
    let token = $getCurrentProcessId() & "-" & $now.toUnix & "-" &
      $now.nanosecond
    writeFile(lockPath, lockMetadata(config, token))
    DevDaemonLock(held: true, lockPath: lockPath, token: token, handle: h)
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
    writerMode: "daemon",
    installMethod: "synthetic",
    selectedStorePath: outcome.absolutePath)

proc ensureRequestStoreMatches(config: DevDaemonConfig; storeRoot: string) =
  if storeRoot.len > 0 and
      os.normalizedPath(storeRoot) != os.normalizedPath(config.storeRoot):
    raise newException(StoreDaemonRuntimeError,
      "request store root does not match daemon store root")

proc useDefForNix(req: StoreDaemonExternalRealizeRequest): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint:
      if req.rawConstraint.len > 0: req.rawConstraint else: req.packageSelector,
    packageSelector: req.packageSelector,
    executableName: req.executableName,
    location: SourceLocation(file: "reprostored-ipc", line: 1))
  result.nixProvisioning = @[InterfaceNixProvisioning(
    packageName: req.packageSelector,
    selector: req.nixSelector,
    executablePath: req.declaredExecutablePath,
    expressionFile: req.nixExpressionFile,
    nixpkgsRef: req.nixpkgsRef,
    nixpkgsRev: req.nixpkgsRev,
    nixpkgsNarHash: req.nixpkgsNarHash,
    packageId: req.packageId,
    lockIdentity: req.lockIdentity,
    location: SourceLocation(file: "reprostored-ipc", line: 1))]

proc useDefForTarball(req: StoreDaemonExternalRealizeRequest): InterfaceToolUse =
  # The rebuilt record has no declaring file, so a relative manifest could
  # only resolve against the daemon's own working directory, which is not
  # the client's realize. The client sends it absolute; refuse anything else
  # rather than open whatever that path names here.
  if req.closureManifest.len > 0 and not req.closureManifest.isAbsolute:
    raise newException(StoreDaemonRuntimeError,
      "tarball realize request carries a relative closureManifest (" &
      req.closureManifest & "); the client must send it resolved to an " &
      "absolute path")
  result = InterfaceToolUse(
    rawConstraint:
      if req.rawConstraint.len > 0: req.rawConstraint else: req.packageSelector,
    packageSelector: req.packageSelector,
    executableName: req.executableName,
    location: SourceLocation(file: "reprostored-ipc", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: req.packageSelector,
    url: req.tarballUrl,
    mirrors: req.tarballMirrors,
    sha256: req.tarballSha256,
    archiveType: req.archiveType,
    executablePath: req.declaredExecutablePath,
    executableAlias: req.executableAlias,
    prunePaths: req.prunePaths,
    nonRedistributable: req.nonRedistributable,
    launcher: req.launcher,
    closureManifest: req.closureManifest,
    closureEntries: parseClosureManifestText(req.closureEntries.join("\n"),
      "closure entries of " & req.packageSelector),
    stripComponents: req.stripComponents,
    packageId: req.packageId,
    lockIdentity: req.lockIdentity,
    detail: req.archiveDetail,
    location: SourceLocation(file: "reprostored-ipc", line: 1))]

proc daemonPrefixPathForProfile(config: DevDaemonConfig;
                                profile: PathOnlyToolProfile): string =
  let prefixRoot = config.storeRoot / "prefixes"
  if profile.selectedStorePath.startsWith(prefixRoot):
    return profile.selectedStorePath
  for path in profile.realizedStorePaths:
    if path.startsWith(prefixRoot):
      return path
  ""

proc writeHolderProfileArtifact(config: DevDaemonConfig; holderId, rootId,
                                adapter: string;
                                profile: PathOnlyToolProfile): string =
  let scoped = scopedRootId(holderId, rootId)
  result = config.storeRoot / "profile-roots" / scoped /
    (adapter & "-tool-identities.rbtp")
  let identity = PathOnlyBuildIdentity(
    projectName: "reprostored-dev-" & adapter,
    profiles: @[profile],
    actionIdentities: @[])
  writePathOnlyBuildIdentity(result, identity)

proc attachProfileRoot(config: DevDaemonConfig; holderId, rootId: string;
                       profile: PathOnlyToolProfile): tuple[scoped: string;
    prefixPath: string; realizationHashHex: string] =
  result.prefixPath = daemonPrefixPathForProfile(config, profile)
  if result.prefixPath.len == 0:
    raise newException(StoreDaemonRuntimeError,
      "daemon-side " & profile.installMethod &
      " realization did not publish a unified store prefix")
  let receipt = readReceiptFile(result.prefixPath / ReceiptFileName)
  result.realizationHashHex = prefixIdHex(receipt.realizationHash)
  result.scoped = scopedRootId(holderId, rootId)
  var store = openStore(config.storeRoot)
  defer: store.close()
  store.registerRoot(result.scoped, rkProfile, currentUid())
  store.attachPrefixToRoot(result.scoped, receipt.realizationHash)

proc realizeNixDaemon(config: DevDaemonConfig;
                      req: StoreDaemonExternalRealizeRequest):
    StoreDaemonRealizeResult =
  ensureRequestStoreMatches(config, req.storeRoot)
  let profile = resolveNixTool(useDefForNix(req), config.storeRoot,
    writerMode = "daemon", requesterDir = req.nixRequesterDir)
  let attached = attachProfileRoot(config, req.holderId, req.rootId, profile)
  let artifact = writeHolderProfileArtifact(config, req.holderId, req.rootId,
    "nix", profile)
  StoreDaemonRealizeResult(
    status: "realized",
    realizedPrefixPath: attached.prefixPath,
    realizationHashHex: attached.realizationHashHex,
    rootId: attached.scoped,
    writerMode: "daemon",
    installMethod: "nix",
    selectedStorePath: profile.selectedStorePath,
    profileArtifactPath: artifact)

proc realizeTarballDaemon(config: DevDaemonConfig;
                          req: StoreDaemonExternalRealizeRequest):
    StoreDaemonRealizeResult =
  ensureRequestStoreMatches(config, req.storeRoot)
  let profile = resolveTarballTool(useDefForTarball(req), config.storeRoot,
    writerMode = "daemon")
  let attached = attachProfileRoot(config, req.holderId, req.rootId, profile)
  let artifact = writeHolderProfileArtifact(config, req.holderId, req.rootId,
    "tarball", profile)
  StoreDaemonRealizeResult(
    status: "realized",
    realizedPrefixPath: attached.prefixPath,
    realizationHashHex: attached.realizationHashHex,
    rootId: attached.scoped,
    writerMode: "daemon",
    installMethod: "tarball",
    selectedStorePath: profile.selectedStorePath,
    profileArtifactPath: artifact)

proc releaseRootDaemon(config: DevDaemonConfig; holderId, rootId: string) =
  var store = openStore(config.storeRoot)
  defer: store.close()
  store.deleteRoot(scopedRootId(holderId, rootId))

proc handleClient(socket: IpcConn; config: DevDaemonConfig; startedAt: Time;
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
  of sdkNixRealize:
    inc pending
    try:
      let res = realizeNixDaemon(config, parseExternalRealizeBody(frame.body))
      socket.writeFrame(sdkRealizeResponse, realizeResponseBody(res))
    finally:
      dec pending
  of sdkTarballRealize:
    inc pending
    try:
      let res = realizeTarballDaemon(config,
        parseExternalRealizeBody(frame.body))
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
  # The private per-user directory is admitted before anything is bound in
  # it or written to it: the endpoint, when it lies there, and the status
  # file, which lives there whenever XDG_RUNTIME_DIR is unset. reprobuild-pm
  # spec/Store-Daemon-And-Multi-User-Coordination.md, "The per-user endpoint
  # directory is private". A refusal raises, naming the directory.
  admitDevEndpointDir(config.endpoint)
  admitDevRuntimeDir()

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
  except StoreDaemonEndpointRefused:
    # Another account listens at this endpoint. Never unlink or replace its
    # socket (removeEndpointFiles / the bind's rename would): refuse.
    raise
  except CatchableError:
    discard

  block recoverAtStartup:
    let report = recoverStoreRoot(config.storeRoot)
    if report.indexRebuilt:
      stderr.writeLine("reprostored --dev: rebuilt corrupt index.db; " &
        "quarantine=" & report.indexQuarantineDir &
        " reinserted-prefixes=" & $report.reinsertedPrefixes.len &
        " quarantined-prefixes=" & $report.quarantinedPrefixes.len)

  removeEndpointFiles(config)
  var listener =
    when defined(windows):
      # Owner and DACL are this user's SID alone, so a client's owner check
      # (``requireIpcListener``) admits this pipe even when the daemon runs
      # elevated. reprobuild-pm
      # spec/Store-Daemon-And-Multi-User-Coordination.md, "A client
      # authenticates the daemon".
      bindIpcListener(config.endpoint,
        sddl = ownerOnlyPipeSddl(ipcOwnIdentity().sid))
    else:
      bindIpcListener(config.endpoint)
  defer:
    closeIpcListener(listener)
    removeEndpointFiles(config)
  writeStatusFile(config)

  let startedAt = getTime()
  var shuttingDown = false
  var pending = 0
  while not shuttingDown:
    var client = listener.acceptIpc()
    try:
      handleClient(client, config, startedAt, shuttingDown, pending)
    except CatchableError as err:
      try:
        client.writeFrame(sdkError, errorBody(err.msg))
      except CatchableError:
        discard
    client.closeIpcConn()
  0

proc waitForDevStatus(endpoint, expectedRoot: string; timeoutMs = 60000):
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
  # Executable-Consolidation M3: the store daemon IS the `repro` image, run as
  # `repro store serve …`. Self-spawn `repro` rather than locating the
  # standalone `reprostored` binary.
  let exe = publicCliPath
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
      let argv = allocCStringArray(@[exe] & storeServeArgs(config))
      discard execv(cstring(exe), argv)
      quit(127)
  else:
    # NOT `osproc.startProcess`: on Windows it creates the child with
    # `bInheritHandles = TRUE` and no handle list, so this daemon -- which
    # outlives the `repro` that starts it -- would hold every inheritable
    # handle we have, including the pipe our caller reads our output from,
    # and that caller would never see an end of file. `spawnWithOwnStdio`
    # gives it NUL stdio and nothing else, the Windows form of the POSIX arm
    # above, and starts it outside our working directory.
    var env: seq[(string, string)] = @[]
    for key, value in envPairs():
      if cmpIgnoreCase(key, "REPROSTORED_ENDPOINT") != 0:
        env.add((key, value))
    env.add(("REPROSTORED_ENDPOINT", config.endpoint))
    var image = exe
    if not isAbsolute(image):
      let found = findExe(image)
      image = if found.len > 0: found else: absolutePath(image)
    discard spawnWithOwnStdio(image, storeServeArgs(config),
      env, inheritEnvironment = false, logPath = "",
      workingDir = parentDir(image))
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

proc renderRefusedStatus*(endpoint, reason: string): string =
  ## What ``repro store daemon status --dev`` prints for an endpoint the
  ## client refused (``StoreDaemonEndpointRefused``): never "not-running",
  ## because whoever holds it is not this user's daemon and may well be
  ## running. reprobuild-pm ``spec/Store-Daemon-And-Multi-User-Coordination.md``
  ## §"A client authenticates the daemon".
  "repro store daemon: refused (the endpoint is not this user's)\n" &
    "endpoint: " & endpoint & "\n" &
    "reason: " & reason
