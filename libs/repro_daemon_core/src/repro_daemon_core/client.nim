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

proc connectUserDaemon*(endpoint = defaultUserDaemonEndpoint();
                        clientName = "repro";
                        commandMode = "daemon";
                        projectRoot = "";
                        protocolMajor = UserDaemonProtocolMajor;
                        protocolMinor = UserDaemonProtocolMinor): Socket =
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
    projectRoot = request.projectRoot)
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
