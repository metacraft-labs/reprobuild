import std/[net, os, strutils]

import repro_core

import ./protocol

type
  UserDaemonClientError* = object of CatchableError

  UserDaemonBuildResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    events*: seq[UserDaemonBuildEvent]

  UserDaemonWatchResult* = object
    supported*: bool
    exitCode*: int
    message*: string
    sessionId*: string
    events*: seq[UserDaemonBuildEvent]

proc endpointExists(endpoint: string): bool =
  try:
    discard getFileInfo(endpoint, followSymlink = false)
    true
  except OSError:
    false

proc userDaemonEndpointExists*(endpoint: string): bool =
  endpointExists(endpoint)

proc userDaemonEndpointAcceptsConnections*(endpoint: string): bool =
  when defined(posix):
    if not endpointExists(endpoint):
      return false
    var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    defer: socket.close()
    try:
      socket.connectUnix(endpoint)
      true
    except CatchableError:
      false
  else:
    false

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
                        requiredFeatures: openArray[string] = []): Socket =
  when defined(posix):
    result = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    result.connectUnix(endpoint)
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
  else:
    raise newException(UserDaemonClientError,
      "repro-daemon IPC is not implemented on this platform")

proc queryUserDaemonStatus*(endpoint = defaultUserDaemonEndpoint()):
    UserDaemonStatus =
  result.endpoint = endpoint
  when defined(posix):
    if not endpointExists(endpoint):
      result.running = false
      return
    var socket: Socket
    try:
      socket = connectUserDaemon(endpoint, commandMode = "status")
    except CatchableError:
      result.running = false
      return
    defer: socket.close()
    socket.writeFrame(udkStatus)
    let frame = socket.readFrame()
    if frame.kind == udkStatusResponse:
      return parseStatusBody(frame.body)
    if frame.kind == udkError:
      raise newException(UserDaemonClientError, parseErrorBody(frame.body))
    raise newException(UserDaemonClientError,
      "unexpected user-daemon status frame: " & $frame.kind)
  else:
    result.running = false

proc requestUserDaemonShutdown*(endpoint = defaultUserDaemonEndpoint()) =
  var socket = connectUserDaemon(endpoint, commandMode = "stop")
  defer: socket.close()
  socket.writeFrame(udkShutdown)
  let frame = socket.readFrame()
  if frame.kind == udkShutdownAck:
    return
  if frame.kind == udkError:
    raise newException(UserDaemonClientError, parseErrorBody(frame.body))
  raise newException(UserDaemonClientError,
    "unexpected user-daemon shutdown frame: " & $frame.kind)

proc requestUserDaemonSessions*(endpoint = defaultUserDaemonEndpoint()):
    seq[UserDaemonSession] =
  var socket = connectUserDaemon(endpoint, commandMode = "sessions")
  defer: socket.close()
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
  var socket = connectUserDaemon(endpoint, commandMode = "build",
    projectRoot = request.projectRoot,
    requiredFeatures = ["build-routing", "build-events"])
  defer: socket.close()
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
  defer: socket.close()
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
  defer: socket.close()
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
  defer: socket.close()
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
  defer: socket.close()
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
