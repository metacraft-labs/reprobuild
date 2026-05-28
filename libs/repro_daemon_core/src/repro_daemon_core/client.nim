import std/[net, os, strutils]

import repro_core

import ./protocol

type
  UserDaemonClientError* = object of CatchableError

proc endpointExists(endpoint: string): bool =
  try:
    discard getFileInfo(endpoint, followSymlink = false)
    true
  except OSError:
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
