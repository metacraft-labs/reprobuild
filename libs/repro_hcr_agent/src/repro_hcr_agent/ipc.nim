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

proc hcrAgentWindowsPipeName*(pid: int): string =
  ## HX-W-5's process-derived Windows endpoint, analogous to the POSIX
  ## `/tmp/repro-hcr-<pid>.sock` path.
  "\\\\.\\pipe\\repro-hcr-" & $pid

when defined(windows):
  type
    HcrWindowsHandle = pointer
    HcrWindowsDword = uint32
    HcrWindowsBool = int32
    HcrWindowsLpcwstr = ptr UncheckedArray[uint16]

    HcrAgentPipeConnection* = object
      handle: HcrWindowsHandle

  const
    HcrGenericRead = 0x80000000'u32
    HcrGenericWrite = 0x40000000'u32
    HcrOpenExisting = 3'u32
    HcrErrorFileNotFound = 2'u32
    HcrErrorPipeBusy = 231'u32
    HcrSecuritySqosPresent = 0x00100000'u32
    HcrSecurityIdentification = 0x00010000'u32

  proc CreateFileW(path: HcrWindowsLpcwstr; desiredAccess,
                   shareMode: HcrWindowsDword; securityAttributes: pointer;
                   creationDisposition, flagsAndAttributes: HcrWindowsDword;
                   templateFile: HcrWindowsHandle): HcrWindowsHandle
    {.importc, stdcall, dynlib: "kernel32".}

  proc WaitNamedPipeW(path: HcrWindowsLpcwstr;
                      timeout: HcrWindowsDword): HcrWindowsBool
    {.importc, stdcall, dynlib: "kernel32".}

  proc ReadFile(handle: HcrWindowsHandle; buffer: pointer;
                bytesToRead: HcrWindowsDword; bytesRead: ptr HcrWindowsDword;
                overlapped: pointer): HcrWindowsBool
    {.importc, stdcall, dynlib: "kernel32".}

  proc WriteFile(handle: HcrWindowsHandle; buffer: pointer;
                 bytesToWrite: HcrWindowsDword;
                 bytesWritten: ptr HcrWindowsDword;
                 overlapped: pointer): HcrWindowsBool
    {.importc, stdcall, dynlib: "kernel32".}

  proc FlushFileBuffers(handle: HcrWindowsHandle): HcrWindowsBool
    {.importc, stdcall, dynlib: "kernel32".}

  proc CloseHandle(handle: HcrWindowsHandle): HcrWindowsBool
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetLastError(): HcrWindowsDword
    {.importc, stdcall, dynlib: "kernel32".}

  proc invalidWindowsHandle(): HcrWindowsHandle =
    cast[HcrWindowsHandle](cast[int](0xFFFFFFFFFFFFFFFF'u64))

  proc pipeNameWide(path: string): seq[uint16] =
    ## Pipe names produced above are ASCII by construction.
    result = newSeqOfCap[uint16](path.len + 1)
    for ch in path:
      result.add uint16(byte(ch))
    result.add 0'u16

  proc close*(connection: var HcrAgentPipeConnection) =
    if connection.handle != nil and
        connection.handle != invalidWindowsHandle():
      discard CloseHandle(connection.handle)
      connection.handle = nil

  proc connectHcrAgentWindowsPipe*(pid: int; timeoutMs = 5_000):
      HcrAgentPipeConnection =
    if pid <= 0:
      raise newException(ValueError, "HCR agent pipe needs a positive pid")
    if timeoutMs < 0:
      raise newException(ValueError, "HCR agent pipe timeout cannot be negative")
    let path = hcrAgentWindowsPipeName(pid)
    var wide = pipeNameWide(path)
    var waited = 0
    while true:
      let handle = CreateFileW(
        cast[HcrWindowsLpcwstr](addr wide[0]),
        HcrGenericRead or HcrGenericWrite,
        0, nil, HcrOpenExisting,
        HcrSecuritySqosPresent or HcrSecurityIdentification, nil)
      if handle != invalidWindowsHandle():
        return HcrAgentPipeConnection(handle: handle)
      let failure = GetLastError()
      if failure != HcrErrorFileNotFound and failure != HcrErrorPipeBusy:
        raise newException(OSError,
          "could not open HCR agent pipe " & path & " (status " &
            $failure & ")")
      if waited >= timeoutMs:
        raise newException(OSError,
          "timed out waiting for HCR agent pipe " & path & " (last status " &
            $failure & ")")
      let slice = min(50, timeoutMs - waited)
      if failure == HcrErrorPipeBusy:
        discard WaitNamedPipeW(cast[HcrWindowsLpcwstr](addr wide[0]),
          HcrWindowsDword(slice))
      else:
        sleep(slice)
      waited += slice

  proc pipeReadExact(connection: HcrAgentPipeConnection;
                     byteCount: int): string =
    if byteCount < 0:
      raise newException(ValueError, "negative HCR agent IPC frame length")
    result = newString(byteCount)
    var received = 0
    while received < byteCount:
      var got: HcrWindowsDword
      if ReadFile(connection.handle, addr result[received],
          HcrWindowsDword(byteCount - received), addr got, nil) == 0:
        raise newException(IOError,
          "ReadFile on HCR agent pipe failed (status " & $GetLastError() & ")")
      if got == 0:
        raise newException(IOError,
          "unexpected EOF while reading HCR agent IPC body")
      received += int(got)

  proc pipeReadLine(connection: HcrAgentPipeConnection): string =
    while true:
      let chunk = connection.pipeReadExact(1)
      if chunk[0] == '\n':
        if result.len > 0 and result[^1] == '\r':
          result.setLen(result.len - 1)
        return
      result.add chunk[0]

  proc readAgentFrame*(connection: HcrAgentPipeConnection): string =
    let firstHeader = connection.pipeReadLine()
    let contentLength = firstHeader.parseContentLength()
    var headers = @[firstHeader]
    while true:
      let line = connection.pipeReadLine()
      if line.len == 0:
        break
      headers.add line
    let body = connection.pipeReadExact(contentLength)
    headers.join("\r\n") & "\r\n\r\n" & body

  proc readAgentMessageWithFrame*(connection: HcrAgentPipeConnection):
      tuple[frame: string, message: HcrAgentMessage] =
    let frame = connection.readAgentFrame()
    let separator = "\r\n\r\n"
    let splitAt = frame.find(separator)
    if splitAt < 0:
      raise newException(ValueError, "missing HCR agent IPC frame separator")
    (frame, parseAgentMessage(parseJson(frame[splitAt + separator.len .. ^1])))

  proc readAgentMessage*(connection: HcrAgentPipeConnection):
      HcrAgentMessage =
    connection.readAgentMessageWithFrame().message

  proc writeAgentMessage*(connection: HcrAgentPipeConnection;
                          message: HcrAgentMessage): string =
    result = frameAgentMessage(message)
    var sent = 0
    while sent < result.len:
      var wrote: HcrWindowsDword
      if WriteFile(connection.handle, unsafeAddr result[sent],
          HcrWindowsDword(result.len - sent), addr wrote, nil) == 0:
        raise newException(IOError,
          "WriteFile on HCR agent pipe failed (status " & $GetLastError() & ")")
      if wrote == 0:
        raise newException(IOError, "HCR agent pipe wrote zero bytes")
      sent += int(wrote)
    discard FlushFileBuffers(connection.handle)
