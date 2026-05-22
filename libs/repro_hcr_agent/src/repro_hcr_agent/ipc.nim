import std/[json, net, os, strutils]
from repro_core/paths import extendedPath

import repro_hcr_agent/protocol

const ReproHcrAgentSocketEnv* = "REPRO_HCR_AGENT_SOCKET"

type
  HcrAgentUnixListener* = object
    path*: string
    socket*: Socket

  HcrAgentSocketConnection* = object
    socket*: Socket

proc close*(listener: var HcrAgentUnixListener) =
  if not listener.socket.isNil:
    listener.socket.close()
    listener.socket = nil
  if listener.path.len > 0:
    try:
      removeFile(extendedPath(listener.path))
    except OSError:
      discard

proc close*(connection: var HcrAgentSocketConnection) =
  if not connection.socket.isNil:
    connection.socket.close()
    connection.socket = nil

proc parseContentLength(line: string): int =
  const prefix = "content-length:"
  if not line.toLowerAscii().startsWith(prefix):
    raise newException(ValueError,
      "missing Content-Length header in HCR agent IPC frame")
  parseInt(line[prefix.len .. ^1].strip())

proc recvExact(socket: Socket; byteCount: int): string =
  if byteCount < 0:
    raise newException(ValueError, "negative HCR agent IPC frame length")
  result = newStringOfCap(byteCount)
  while result.len < byteCount:
    let chunk = socket.recv(byteCount - result.len)
    if chunk.len == 0:
      raise newException(IOError,
        "unexpected EOF while reading HCR agent IPC body")
    result.add chunk

proc recvLine(socket: Socket): string =
  while true:
    let chunk = socket.recv(1)
    if chunk.len == 0:
      raise newException(IOError,
        "unexpected EOF while reading HCR agent IPC header")
    let ch = chunk[0]
    if ch == '\n':
      if result.len > 0 and result[^1] == '\r':
        result.setLen(result.len - 1)
      return
    result.add ch

proc listenHcrAgentUnixSocket*(path: string;
                               removeExisting = true): HcrAgentUnixListener =
  when defined(posix):
    if removeExisting:
      try:
        removeFile(extendedPath(path))
      except OSError:
        discard
    result = HcrAgentUnixListener(
      path: path,
      socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE))
    result.socket.bindUnix(path)
    result.socket.listen()
  else:
    raise newException(OSError,
      "HCR agent Unix socket IPC is only supported on POSIX hosts")

proc acceptHcrAgentConnection*(listener: HcrAgentUnixListener):
    HcrAgentSocketConnection =
  var client: owned(Socket)
  listener.socket.accept(client)
  HcrAgentSocketConnection(socket: client)

proc connectHcrAgentUnixSocket*(path: string): HcrAgentSocketConnection =
  when defined(posix):
    result = HcrAgentSocketConnection(
      socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE))
    result.socket.connectUnix(path)
  else:
    raise newException(OSError,
      "HCR agent Unix socket IPC is only supported on POSIX hosts")

proc hcrAgentSocketEnv*(path: string): tuple[name: string, value: string] =
  (ReproHcrAgentSocketEnv, path)

proc requireHcrAgentSocketPathFromEnv*(): string =
  result = getEnv(ReproHcrAgentSocketEnv, "")
  if result.len == 0:
    raise newException(ValueError,
      ReproHcrAgentSocketEnv & " is required for HCR agent IPC startup")

proc connectHcrAgentFromEnv*(): HcrAgentSocketConnection =
  connectHcrAgentUnixSocket(requireHcrAgentSocketPathFromEnv())

proc readAgentFrame*(connection: HcrAgentSocketConnection): string =
  let firstHeader = connection.socket.recvLine()
  let contentLength = firstHeader.parseContentLength()
  var headers = @[firstHeader]
  while true:
    let line = connection.socket.recvLine()
    if line.len == 0:
      break
    headers.add line

  let body = connection.socket.recvExact(contentLength)
  headers.join("\r\n") & "\r\n\r\n" & body

proc readAgentMessageWithFrame*(connection: HcrAgentSocketConnection):
    tuple[frame: string, message: HcrAgentMessage] =
  let frame = connection.readAgentFrame()
  let separator = "\r\n\r\n"
  let splitAt = frame.find(separator)
  if splitAt < 0:
    raise newException(ValueError, "missing HCR agent IPC frame separator")
  (frame, parseAgentMessage(parseJson(frame[splitAt + separator.len .. ^1])))

proc readAgentMessage*(connection: HcrAgentSocketConnection): HcrAgentMessage =
  connection.readAgentMessageWithFrame().message

proc writeAgentMessage*(connection: HcrAgentSocketConnection;
                        message: HcrAgentMessage): string =
  result = frameAgentMessage(message)
  connection.socket.send(result)
