import std/[os, strutils, times]

import repro_core

import ./protocol

type
  UserDaemonClientError* = object of CatchableError

  UserDaemonBuildResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    events*: seq[UserDaemonBuildEvent]
    connectionUs*: float

  UserDaemonWatchResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    sessionId*: string
    events*: seq[UserDaemonBuildEvent]

proc userDaemonEndpointExists*(endpoint: string): bool =
  endpointExistsLocal(endpoint)

proc userDaemonEndpointAcceptsConnections*(endpoint: string): bool =
  endpointAcceptsConnections(endpoint)

proc featureSet(flags: string): seq[string] =
  for raw in flags.split(','):
    let item = raw.strip()
    if item.len > 0:
      result.add(item)

proc requireDaemonFeatures(features, required: openArray[string]) =
  for needed in required:
    if features.find(needed) < 0:
      raise newException(UserDaemonClientError,
        "user daemon does not advertise required feature: " & needed)

proc connectUserDaemon*(endpoint = defaultUserDaemonEndpoint();
                        clientName = "repro";
                        commandMode = "daemon";
                        projectRoot = "";
                        protocolMajor = UserDaemonProtocolMajor;
                        protocolMinor = UserDaemonProtocolMinor;
                        requiredFeatures: openArray[string] = []): IpcConn =
  try:
    result = connectIpc(endpoint)
  except IpcEndpointError as exc:
    raise newException(UserDaemonClientError, exc.msg)
  let client = binaryIdentity(clientName, getAppFilename(), versionString())
  result.writeFrame(udkHello, helloBody(client, UserDaemonFeatureFlags,
    commandMode, projectRoot, protocolMajor, protocolMinor))
  let ack = result.readFrame()
  if ack.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(ack.body))
  if ack.kind != udkHelloAck:
    raise newException(UserDaemonClientError,
      "user daemon returned unexpected hello frame: " & $ack.kind)
  let parsed = parseHelloAck(ack.body)
  if parsed.major != UserDaemonProtocolMajor:
    raise newException(UserDaemonClientError,
      "user daemon protocol mismatch: client major " &
      $UserDaemonProtocolMajor & ", daemon major " & $parsed.major)
  requireDaemonFeatures(parsed.featureFlags.featureSet(), requiredFeatures)

proc queryUserDaemonStatus*(endpoint = defaultUserDaemonEndpoint()):
    UserDaemonStatus =
  result.endpoint = endpoint
  if not endpointExistsLocal(endpoint):
    result.running = false
    return
  var conn: IpcConn
  try:
    conn = connectUserDaemon(endpoint, commandMode = "status")
  except CatchableError:
    result.running = false
    return
  defer: conn.closeIpcConn()
  conn.writeFrame(udkStatus)
  let frame = conn.readFrame()
  if frame.kind == udkStatusResponse:
    return parseStatusBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon status frame: " & $frame.kind)

proc requestUserDaemonShutdown*(endpoint = defaultUserDaemonEndpoint()) =
  ## Issue the shutdown request and wait for the daemon to RELEASE
  ## its endpoint — not just to ACK. The daemon's listener loop sends
  ## ``sdkShutdownAck`` from inside ``handleClient`` before its outer
  ## ``defer`` chain runs (close listener, remove endpoint files,
  ## release lock, remove lockfile). On Windows the lockfile + status
  ## file removal lags the ACK by a few hundred microseconds; a
  ## caller that immediately tries ``removeDir(tempRoot)`` then hits
  ## "The process cannot access the file because it is being used by
  ## another process." Wait until ``endpointAcceptsConnections``
  ## flips to false before returning, which guarantees both the
  ## listener AND the cleanup defers have run.
  # Grab the daemon's state-dir BEFORE issuing the shutdown so we can
  # poll for its lockfile to disappear once the endpoint flips quiet —
  # querying after shutdown loses the race (the daemon might already
  # be tearing down the listener when the status request lands).
  let stateDir =
    try: queryUserDaemonStatus(endpoint).stateDir
    except CatchableError: ""
  block:
    var socket = connectUserDaemon(endpoint, commandMode = "stop")
    defer: socket.closeIpcConn()
    socket.writeFrame(udkShutdown)
    let frame = socket.readFrame()
    if frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    if frame.kind != udkShutdownAck:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon shutdown frame: " & $frame.kind)

  # Poll for endpoint quiescence. The daemon's listener-defer runs
  # FIRST (LIFO order) — that closes the IPC listener and flips
  # ``endpointAcceptsConnections`` to false. The lockfile release
  # runs in the SECOND defer immediately after.
  #
  # Between the two defers the daemon also writes the final
  # ``stopped`` line to its log + reads/removes the lockfile metadata,
  # so the gap to a clean ``removeDir(stateDir)`` is a few hundred
  # milliseconds on a healthy host. On a heavily-loaded Windows host
  # the daemon process's scheduling latency between the two defers
  # has been observed at >200 ms, hitting integration tests' defer
  # chain with ``ERROR_SHARING_VIOLATION`` on the lockfile. After the
  # endpoint flips quiet, poll for ``.repro-daemon.lock`` (which lives
  # next to ``status/`` under the state-dir reported by the daemon's
  # status response) to disappear — that file's removal IS the final
  # action of ``releaseUserDaemonLock`` and is the canonical signal
  # the cleanup chain has fully drained.
  proc lockfileGone(stateDir: string): bool =
    not fileExists(stateDir / ".repro-daemon.lock")
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    if not endpointAcceptsConnections(endpoint):
      if stateDir.len == 0:
        # We never got a state-dir from the pre-shutdown status
        # query. Fall back to a fixed wait long enough for the
        # daemon's lockfile defer to land on a busy Windows host.
        sleep(1500)
        return
      let lockDeadline = epochTime() + 5.0
      while epochTime() < lockDeadline:
        if lockfileGone(stateDir):
          # Lockfile is gone — and on Windows ``fileExists`` only
          # returns false once the kernel has finalised the delete
          # (no pending-delete state), so the lockfile handle is
          # truly closed and ``removeDir(stateDir)`` can proceed.
          return
        sleep(25)
      # The lockfile is still on disk 5 s after the endpoint went
      # quiet — something is wedging the daemon's release defer.
      # Surface it as the same time-out error as the outer loop.
      break
    sleep(10)
  # Time-out: the daemon is still listening 5 s after ACK. That's a
  # real bug — surface it instead of silently returning.
  raise newException(UserDaemonClientError,
    "user-daemon at " & endpoint & " accepted shutdown ACK but " &
    "did not release its endpoint within 5 s")

proc requestUserDaemonSessions*(endpoint = defaultUserDaemonEndpoint()):
    seq[UserDaemonSession] =
  var socket = connectUserDaemon(endpoint, commandMode = "sessions")
  defer: socket.closeIpcConn()
  socket.writeFrame(udkSessions)
  let frame = socket.readFrame()
  if frame.kind == udkSessionsResponse:
    return parseSessionsBody(frame.body)
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon sessions frame: " & $frame.kind)

proc requestUserDaemonBuild*(request: UserDaemonBuildRequest;
                             endpoint = defaultUserDaemonEndpoint();
                             onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonBuildResult =
  let connectStart = epochTime()
  var socket = connectUserDaemon(endpoint, commandMode = "build",
    projectRoot = request.projectRoot,
    requiredFeatures = ["build-routing", "build-events"])
  result.connectionUs = (epochTime() - connectStart) * 1_000_000.0
  defer: socket.closeIpcConn()
  socket.writeFrame(udkBuildRequest, buildRequestBody(request))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkBuildEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      if onEvent != nil:
        onEvent(event)
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon build frame: " & $frame.kind)

proc requestUserDaemonWatchStart*(request: UserDaemonWatchRequest;
                                  endpoint = defaultUserDaemonEndpoint();
                                  onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch",
    projectRoot = request.projectRoot,
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchStartRequest, watchRequestBody(request))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkWatchEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      if result.sessionId.len == 0:
        result.sessionId = event.sessionId
      if onEvent != nil:
        onEvent(event)
      if request.detached and event.kind == bekAccepted:
        result.exitCode = 0
        result.message = event.message
        result.supported = true
        return
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon watch frame: " & $frame.kind)

proc requestUserDaemonWatchAttach*(sessionId: string;
                                   endpoint = defaultUserDaemonEndpoint();
                                   onEvent: proc(event: UserDaemonBuildEvent) = nil):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-attach",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchAttachRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId,
      cancelOnDisconnect: false)))
  while true:
    let frame = socket.readFrame()
    if frame.kind == udkWatchEvent:
      let event = parseBuildEventBody(frame.body)
      result.events.add(event)
      result.sessionId = event.sessionId
      if onEvent != nil:
        onEvent(event)
      if event.terminal:
        result.exitCode = event.exitCode
        result.message = event.message
        result.supported = event.kind != bekUnsupported
        return
    elif frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    else:
      raise newException(UserDaemonClientError,
        "unexpected user-daemon watch attach frame: " & $frame.kind)

proc requestUserDaemonWatchStop*(sessionId: string;
                                 endpoint = defaultUserDaemonEndpoint()):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-stop",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchStopRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId)))
  let frame = socket.readFrame()
  if frame.kind == udkWatchEvent:
    let event = parseBuildEventBody(frame.body)
    result.events.add(event)
    result.sessionId = event.sessionId
    result.exitCode = event.exitCode
    result.message = event.message
    result.supported = true
    return
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon watch stop frame: " & $frame.kind)

proc requestUserDaemonWatchDetach*(sessionId: string;
                                   endpoint = defaultUserDaemonEndpoint()):
    UserDaemonWatchResult =
  var socket = connectUserDaemon(endpoint, commandMode = "watch-detach",
    requiredFeatures = ["watch-routing", "watch-events", "watch-sessions"])
  defer: socket.closeIpcConn()
  socket.writeFrame(udkWatchDetachRequest, watchSessionRequestBody(
    UserDaemonWatchSessionRequest(sessionId: sessionId)))
  let frame = socket.readFrame()
  if frame.kind == udkWatchEvent:
    let event = parseBuildEventBody(frame.body)
    result.events.add(event)
    result.sessionId = event.sessionId
    result.exitCode = event.exitCode
    result.message = event.message
    result.supported = true
    return
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon watch detach frame: " & $frame.kind)
