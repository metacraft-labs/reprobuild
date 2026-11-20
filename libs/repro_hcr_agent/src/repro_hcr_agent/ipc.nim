import std/[json, net, os, strutils]
from repro_core/paths import extendedPath
when defined(posix):
  import std/posix
  from repro_core/paths import unixSocketPathMaxLen, unixSocketPathFits
  from repro_core/peer_identity import socketPeerCredentials
  import repro_core/owned_directory

import repro_hcr_agent/protocol

const ReproHcrAgentSocketEnv* = "REPRO_HCR_AGENT_SOCKET"

type
  HcrAgentUnixListener* = object
    path*: string
    socket*: Socket

  HcrAgentSocketConnection* = object
    socket*: Socket

  HcrAgentPeerError* = object of IOError
    ## The process at the other end of the patch channel is not this user's,
    ## or who it is cannot be established. The channel carries executable
    ## code, so the connection is closed before any frame crosses it.
    ## reprobuild-pm ``spec/HCR/HCR-Overview.md`` §5.2 "Who may use the
    ## channel".

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

when defined(posix):
  proc requireHcrAgentSocketPathFits(path, action: string) =
    ## Refuse a socket path ``std/net`` cannot bind or dial, BEFORE it is
    ## handed to ``bindUnix`` / ``connectUnix``. Those refuse a path of
    ## ``Sockaddr_un_path_length`` bytes or more (108 on Linux, 92 on macOS)
    ## with a bare ``socket path too long`` that names neither the path nor
    ## the limit; this says both. ``repro watch`` checks the resolved
    ## ``--hcr-agent-socket`` earlier and names the flag; this is the
    ## library-level defence for every other caller.
    if not unixSocketPathFits(path):
      raise newException(ValueError,
        "cannot " & action & " HCR agent socket " & path & ": the path is " &
          $path.len & " bytes, longer than the " & $unixSocketPathMaxLen() &
          "-byte Unix-socket path limit on this platform")

when defined(posix):
  proc requireSameUserPeer(socket: Socket; peerRole: string) =
    ## Admit the connected AF_UNIX ``socket`` only when the kernel says the
    ## process at its other end runs as this process's effective uid
    ## (``SO_PEERCRED`` on Linux, ``getpeereid`` on macOS and the BSDs). A
    ## path is not an identity: whoever binds or reaches the name first
    ## answers on it. Closes ``socket`` and raises ``HcrAgentPeerError``
    ## otherwise, before anything is read from or written to it.
    let me = int(geteuid())
    var peerUid = -1
    var reason = ""
    try:
      peerUid = socketPeerCredentials(SocketHandle(socket.getFd())).uid
    except OSError as err:
      reason = err.msg
    if reason.len == 0 and peerUid == me:
      return
    socket.close()
    if reason.len > 0:
      raise newException(HcrAgentPeerError,
        "refusing the HCR " & peerRole & ": cannot read its peer " &
          "credentials (" & reason & "), and the patch channel carries " &
          "executable code")
    raise newException(HcrAgentPeerError,
      "refusing the HCR " & peerRole & ": it runs as uid " & $peerUid &
        ", not as this user (uid " & $me & "), and the patch channel " &
        "carries executable code")

proc listenHcrAgentUnixSocket*(path: string;
                               removeExisting = true): HcrAgentUnixListener =
  when defined(posix):
    requireHcrAgentSocketPathFits(path, "listen on")
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
  ## Accept one connection, admitted only when the connecting process runs
  ## as this user (``requireSameUserPeer``); another account's connection
  ## raises ``HcrAgentPeerError``.
  var client: owned(Socket)
  listener.socket.accept(client)
  when defined(posix):
    requireSameUserPeer(client, "agent connecting to " & listener.path)
  HcrAgentSocketConnection(socket: client)

proc connectHcrAgentUnixSocket*(path: string): HcrAgentSocketConnection =
  when defined(posix):
    requireHcrAgentSocketPathFits(path, "connect to")
    result = HcrAgentSocketConnection(
      socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE))
    result.socket.connectUnix(path)
    requireSameUserPeer(result.socket, "coordinator listening on " & path)
  else:
    raise newException(OSError,
      "HCR agent Unix socket IPC is only supported on POSIX hosts")

when defined(posix):
  const HcrAgentSocketDirRole = OwnedDirectoryRole(
    noun: "HCR agent socket directory",
    exposure: "another account could listen in place of the coordinator " &
      "and send this user's process executable code",
    remedy: "remove it or fix its mode and start the session again; if " &
      "another account owns it, pass an absolute --hcr-agent-socket in a " &
      "directory only you can write")

  proc hcrAgentPrivateSocketDir*(tempRoot = "/tmp"): string =
    ## The per-user directory a DERIVED agent socket lives in:
    ## ``<tempRoot>/repro-hcr-<euid>``. ``/tmp`` rather than ``getTempDir()``
    ## because the derived path exists to be short. A socket is never put
    ## directly in a shared temporary directory, where anyone can create the
    ## predictable name first. reprobuild-pm ``spec/HCR/CLI-Integration.md``
    ## §"Agent Socket Path".
    tempRoot / ("repro-hcr-" & $int(geteuid()))

  proc hcrAgentDerivedSocketPath*(resolved: string;
                                  tempRoot = "/tmp"): string =
    ## The short socket that replaces a relative ``--hcr-agent-socket`` whose
    ## resolved path is too long: ``<private dir>/<64-bit FNV-1a of the
    ## resolved path, 16 hex>.sock``. 64 bits so that two of this user's
    ## projects do not share one by accident: the coordinator removes an
    ## existing socket before it binds.
    var h = 14695981039346656037'u64
    for ch in resolved:
      h = (h xor uint64(ord(ch))) * 1099511628211'u64
    hcrAgentPrivateSocketDir(tempRoot) / (toHex(h, 16).toLowerAscii & ".sock")

  proc admitHcrAgentPrivateSocketDir*(tempRoot = "/tmp") =
    ## Create the per-user directory ``0700`` when missing, and admit it only
    ## when ``lstat`` says it is a real directory owned by this user with no
    ## group or other permission. An existing directory is never repaired.
    ## Raises ``OwnedDirectoryError`` for a refusal.
    ensureOwnedDirectory(hcrAgentPrivateSocketDir(tempRoot),
      privateDir = true, HcrAgentSocketDirRole)

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
  ## HX-W-5's process-derived Windows endpoint. On Windows the agent serves
  ## this pipe and the coordinator connects; on Linux and macOS the roles are
  ## reversed (the coordinator listens on ``REPRO_HCR_AGENT_SOCKET``).
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
