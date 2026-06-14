## Portable IPC primitives shared by `repro_daemon_core` and
## `repro_store_daemon`.
##
## On POSIX this is a thin wrapper around `net.Socket` + `AF_UNIX`.
## On Windows it maps to Named Pipes (`\\.\pipe\...`) per the spec in
## ``reprobuild-specs/Store-Daemon-And-Multi-User-Coordination.md`` and
## the corresponding repro-daemon endpoint convention in
## ``protocol.nim`` (``defaultUserDaemonEndpoint``).
##
## Design goals:
##   * One client at a time (matches the existing POSIX listener loop).
##   * Synchronous send/recv (the existing framing protocol is already
##     blocking; no caller expects nonblocking I/O).
##   * A timed `waitForClient` so the dev-self-restart polling loop in
##     `runtime.nim` keeps working without a dedicated worker thread.
##
## The abstraction is intentionally minimal — only the procs the
## existing daemons actually call are wrapped. Higher-level code stays
## the same; the platform difference is contained here.

import std/[os, strutils]

when defined(posix):
  import std/[net, posix]
  # Nim rejects exporting individual enum values (``cannot export:
  # AF_UNIX; enum field cannot be exported individually``), so we only
  # re-export the typed symbols and the helper procs from std/net and
  # std/posix. Callers that need ``AF_UNIX``, ``SOCK_STREAM``,
  # ``IPPROTO_NONE``, or the ``POLL*`` family ``import std/posix`` (or
  # ``std/net``) themselves.
  export Socket, bindUnix, connectUnix
when defined(windows):
  import std/winlean

type
  IpcEndpointError* = object of CatchableError
    ## Raised for low-level IPC failures the caller can plausibly act
    ## on (path syntax errors, peer disconnects, OS errors). The
    ## existing daemon code surfaces these via the daemon-specific
    ## error types; the IPC layer keeps the type generic so neither
    ## daemon library needs to depend on the other.

const
  WindowsNamedPipePrefix* = r"\\.\pipe\"
    ## Endpoint paths on Windows MUST start with this prefix. The
    ## protocol module's `defaultUserDaemonEndpoint` already returns
    ## the canonical form (``\\.\pipe\repro-daemon-current-user``);
    ## callers who construct ad-hoc endpoints (tests, dev shells) get
    ## a clear error if they forget the prefix.

when defined(windows):
  # winlean exports `createNamedPipe`, `createFileW`, `readFile`,
  # `writeFile`, `closeHandle`, `createEvent`, `waitForSingleObject`
  # and the OVERLAPPED / SECURITY_ATTRIBUTES structs. The remaining
  # procs we need are not in stdlib's winlean for this Nim version,
  # so import them directly.
  proc connectNamedPipeRaw(hNamedPipe: Handle;
                           lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe", sideEffect.}
  proc disconnectNamedPipeRaw(hNamedPipe: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "DisconnectNamedPipe", sideEffect.}
  proc waitNamedPipeWRaw(lpNamedPipeName: WideCString;
                         nTimeOut: int32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "WaitNamedPipeW", sideEffect.}
  proc flushFileBuffersRaw(hFile: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "FlushFileBuffers", sideEffect.}
  proc peekNamedPipeRaw(hNamedPipe: Handle; lpBuffer: pointer;
                        nBufferSize: DWORD; lpBytesRead: ptr DWORD;
                        lpTotalBytesAvail: ptr DWORD;
                        lpBytesLeftThisMessage: ptr DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "PeekNamedPipe", sideEffect.}

  const
    ERROR_PIPE_CONNECTED = 535'i32
    ERROR_IO_PENDING = 997'i32
    ERROR_FILE_NOT_FOUND = 2'i32
    ERROR_BROKEN_PIPE = 109'i32
    ERROR_PIPE_BUSY = 231'i32
    PIPE_TYPE_BYTE = 0x0'i32
    PIPE_READMODE_BYTE = 0x0'i32
    PIPE_WAIT = 0x0'i32
    PIPE_REJECT_REMOTE_CLIENTS = 0x8'i32
    PIPE_UNLIMITED_INSTANCES = 255'i32
    DefaultPipeBufferBytes = 64 * 1024
    DefaultPipeTimeoutMs = 5_000
    WAIT_OBJECT_0_LOCAL = 0'i32
    WAIT_TIMEOUT_LOCAL = 0x102'i32

type
  EndpointKind* = enum
    ekUnixSocket
    ekNamedPipe

when defined(posix):
  type
    IpcConnObj* = object
      ## Connected, one-side-of-a-conversation IPC handle. Wrapped in
      ## ``ref`` so closures inside `runtime.nim`'s build/watch handlers
      ## can capture the connection without tripping Nim's
      ## var-parameter capture restriction. The previous shape used
      ## `Socket` directly (itself a ref) — keeping the ref-around-
      ## record semantics preserves the same memory-safety model.
      socket*: Socket
    IpcConn* = ref IpcConnObj

    IpcListener* = object
      ## Server-side listener; owns the bound AF_UNIX socket on POSIX.
      endpoint*: string
      socket*: Socket
      bound*: bool
when defined(windows):
  type
    IpcConnObj* = object
      handle*: Handle
      ownsHandle*: bool
    IpcConn* = ref IpcConnObj

    IpcListener* = object
      endpoint*: string
      pending*: Handle
      pendingEvent*: Handle
      pendingOverlapped*: OVERLAPPED
      pendingArmed*: bool
      everArmed*: bool
        ## True after the first ``armPending`` call. We pass
        ## ``FILE_FLAG_FIRST_PIPE_INSTANCE`` ONLY on the very first
        ## arm; subsequent rearms (after an acceptIpc transferred
        ## ``pending`` to a connected client) must NOT request first-
        ## instance semantics, otherwise ``CreateNamedPipeW`` fails
        ## with ERROR_ACCESS_DENIED because instances already exist.
        ## The previous logic used ``listener.pending == 0`` as the
        ## first-instance signal, but that field also reads zero
        ## immediately after every accept — so the post-accept rearm
        ## silently failed (the ``try: armPending(...)
        ## except: discard`` in ``acceptIpc`` swallowed it) and a
        ## concurrent second client racing into ``connectIpc`` saw
        ## ERROR_FILE_NOT_FOUND.

proc endpointKindOf*(endpoint: string): EndpointKind =
  if endpoint.startsWith(WindowsNamedPipePrefix):
    ekNamedPipe
  else:
    ekUnixSocket

# ---------------------------------------------------------------------------
# POSIX implementation
# ---------------------------------------------------------------------------

when defined(posix):
  proc bindIpcListener*(endpoint: string): IpcListener =
    result.endpoint = endpoint
    createDir(parentDir(endpoint))
    try: removeFile(endpoint) except OSError: discard
    result.socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    result.socket.bindUnix(endpoint)
    result.socket.listen()
    result.bound = true

  proc closeIpcListener*(listener: var IpcListener) =
    if listener.bound:
      try: listener.socket.close() except CatchableError: discard
      listener.bound = false
    try: removeFile(listener.endpoint) except OSError: discard

  proc waitForClient*(listener: var IpcListener; timeoutMs: int): bool =
    let fd = listener.socket.getFd()
    var fds = TPollfd(fd: cast[cint](fd), events: POLLIN, revents: 0)
    poll(addr(fds), Tnfds(1), cint(timeoutMs)) > 0 and
      (fds.revents and POLLIN) != 0

  proc acceptIpc*(listener: var IpcListener): IpcConn =
    var client: owned(Socket)
    listener.socket.accept(client)
    result = IpcConn(socket: client)

  proc connectIpc*(endpoint: string): IpcConn =
    var sock = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    try:
      sock.connectUnix(endpoint)
    except CatchableError as exc:
      sock.close()
      raise newException(IpcEndpointError,
        "failed to connect to " & endpoint & ": " & exc.msg)
    result = IpcConn(socket: sock)

  proc closeIpcConn*(conn: IpcConn) =
    if conn.socket != nil:
      try: conn.socket.close() except CatchableError: discard
      conn.socket = nil

  proc isOpen*(conn: IpcConn): bool =
    conn.socket != nil

  proc sendByteString*(conn: IpcConn; data: string) =
    if data.len == 0:
      return
    conn.socket.send(data)

  proc recvBytesExact*(conn: IpcConn; byteCount: int): seq[byte] =
    if byteCount <= 0:
      return @[]
    result = newSeqOfCap[byte](byteCount)
    while result.len < byteCount:
      let chunk = conn.socket.recv(byteCount - result.len)
      if chunk.len == 0:
        raise newException(IpcEndpointError,
          "unexpected EOF reading " & $byteCount & " bytes")
      for ch in chunk:
        result.add(byte(ord(ch)))

  proc clientDisconnected*(conn: IpcConn): bool =
    if conn.socket == nil:
      return true
    let fd = conn.socket.getFd()
    var fds = TPollfd(fd: cast[cint](fd), events: POLLIN, revents: 0)
    let rc = poll(addr(fds), Tnfds(1), 0.cint)
    if rc <= 0:
      return false
    if (fds.revents and POLLHUP) != 0 or (fds.revents and POLLERR) != 0 or
        (fds.revents and POLLNVAL) != 0:
      return true
    if (fds.revents and POLLIN) != 0:
      var ch: char
      let n = posix.recv(fd, addr(ch), 1, MSG_PEEK)
      return n == 0
    false

  proc endpointExistsLocal*(endpoint: string): bool =
    try:
      discard getFileInfo(endpoint, followSymlink = false)
      true
    except OSError:
      false

  proc endpointAcceptsConnections*(endpoint: string): bool =
    if not endpointExistsLocal(endpoint):
      return false
    var sock = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    defer: sock.close()
    try:
      sock.connectUnix(endpoint)
      true
    except CatchableError:
      false

# ---------------------------------------------------------------------------
# Windows implementation (Named Pipes)
# ---------------------------------------------------------------------------

when defined(windows):
  proc raiseWin(prefix: string; code: int32 = -1) {.noreturn.} =
    let actualCode = if code < 0: int32(osLastError()) else: code
    raise newException(IpcEndpointError,
      prefix & " (Windows error " & $actualCode & ")")

  proc ensurePipeEndpoint(endpoint: string) =
    if not endpoint.startsWith(WindowsNamedPipePrefix):
      raise newException(IpcEndpointError,
        "Windows endpoints must start with " & WindowsNamedPipePrefix &
          ", got: " & endpoint)

  proc createServerInstance(endpoint: string; firstInstance: bool): Handle =
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil, bInheritHandle: 0)
    var openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
    if firstInstance:
      openMode = openMode or FILE_FLAG_FIRST_PIPE_INSTANCE
    let pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
      PIPE_REJECT_REMOTE_CLIENTS
    let wpath = newWideCString(endpoint)
    let h = createNamedPipe(wpath, openMode.DWORD, pipeMode.DWORD,
      PIPE_UNLIMITED_INSTANCES.DWORD, DefaultPipeBufferBytes.DWORD,
      DefaultPipeBufferBytes.DWORD, DefaultPipeTimeoutMs.DWORD, addr sa)
    if h == INVALID_HANDLE_VALUE:
      raiseWin("CreateNamedPipeW failed for " & endpoint)
    result = h

  proc armPending(listener: var IpcListener) =
    if listener.pendingArmed:
      return
    let firstInstance = not listener.everArmed
    listener.pending = createServerInstance(listener.endpoint, firstInstance)
    listener.everArmed = true
    listener.pendingEvent = createEvent(nil, 1, 0, nil)
    if listener.pendingEvent == 0:
      discard closeHandle(listener.pending)
      listener.pending = 0
      raiseWin("CreateEventW failed while arming named pipe instance")
    zeroMem(addr listener.pendingOverlapped, sizeof(OVERLAPPED))
    listener.pendingOverlapped.hEvent = listener.pendingEvent
    let ok = connectNamedPipeRaw(listener.pending,
      addr listener.pendingOverlapped)
    if ok == 0:
      let err = int32(osLastError())
      if err == ERROR_PIPE_CONNECTED:
        discard setEvent(listener.pendingEvent)
      elif err != ERROR_IO_PENDING:
        discard closeHandle(listener.pendingEvent)
        discard closeHandle(listener.pending)
        listener.pendingEvent = 0
        listener.pending = 0
        raiseWin("ConnectNamedPipe failed during arm", err)
    listener.pendingArmed = true

  proc bindIpcListener*(endpoint: string): IpcListener =
    ensurePipeEndpoint(endpoint)
    result.endpoint = endpoint
    armPending(result)

  proc closeIpcListener*(listener: var IpcListener) =
    if listener.pendingArmed:
      discard disconnectNamedPipeRaw(listener.pending)
      discard closeHandle(listener.pending)
      discard closeHandle(listener.pendingEvent)
      listener.pending = 0
      listener.pendingEvent = 0
      listener.pendingArmed = false

  proc waitForClient*(listener: var IpcListener; timeoutMs: int): bool =
    if not listener.pendingArmed:
      armPending(listener)
    let waitMs = if timeoutMs < 0: -1.int32 else: int32(timeoutMs)
    let rc = waitForSingleObject(listener.pendingEvent, waitMs)
    case rc
    of WAIT_OBJECT_0_LOCAL: true
    of WAIT_TIMEOUT_LOCAL: false
    else:
      raiseWin("WaitForSingleObject failed on named pipe overlapped event",
        rc)

  proc acceptIpc*(listener: var IpcListener): IpcConn =
    if not listener.pendingArmed:
      armPending(listener)
    let rc = waitForSingleObject(listener.pendingEvent, -1.int32)
    if rc != WAIT_OBJECT_0_LOCAL:
      raiseWin("WaitForSingleObject failed during accept", rc)
    result = IpcConn(handle: listener.pending, ownsHandle: true)
    listener.pending = 0
    listener.pendingEvent = 0
    listener.pendingArmed = false
    try:
      armPending(listener)
    except CatchableError:
      discard

  proc connectIpc*(endpoint: string): IpcConn =
    ensurePipeEndpoint(endpoint)
    let wpath = newWideCString(endpoint)
    var attempt = 0
    while true:
      let h = createFileW(wpath,
        (GENERIC_READ or GENERIC_WRITE).DWORD,
        0.DWORD, nil, OPEN_EXISTING.DWORD, 0.DWORD, 0)
      if h != INVALID_HANDLE_VALUE:
        return IpcConn(handle: h, ownsHandle: true)
      let err = int32(osLastError())
      if err == ERROR_PIPE_BUSY:
        # All pipe instances are currently busy serving other clients.
        # ``WaitNamedPipe`` blocks until either an instance becomes
        # available OR the timeout elapses, then we retry the
        # ``CreateFileW``. Total budget: ``DefaultPipeTimeoutMs`` per
        # wait * up to 12 retries (~60 s on a healthy server, matching
        # the auto-spawn deadline used elsewhere in the daemon).
        if waitNamedPipeWRaw(wpath, DefaultPipeTimeoutMs.int32) == 0:
          let waitErr = int32(osLastError())
          if waitErr != ERROR_PIPE_BUSY:
            raiseWin("WaitNamedPipe failed connecting to " & endpoint,
              waitErr)
        inc attempt
        if attempt >= 12:
          raiseWin("CreateFileW kept returning ERROR_PIPE_BUSY for " &
            endpoint & " across 12 WaitNamedPipe retries", err)
        continue
      raiseWin("CreateFileW failed connecting to " & endpoint, err)

  proc closeIpcConn*(conn: IpcConn) =
    if conn.ownsHandle and conn.handle != 0 and
        conn.handle != INVALID_HANDLE_VALUE:
      discard flushFileBuffersRaw(conn.handle)
      discard closeHandle(conn.handle)
    conn.handle = 0
    conn.ownsHandle = false

  proc isOpen*(conn: IpcConn): bool =
    conn.handle != 0 and conn.handle != INVALID_HANDLE_VALUE

  proc sendByteString*(conn: IpcConn; data: string) =
    if data.len == 0:
      return
    var written: DWORD = 0
    var buf = newSeq[byte](data.len)
    for i, ch in data:
      buf[i] = byte(ord(ch))
    let ok = writeFile(conn.handle, addr buf[0], DWORD(data.len),
      addr written, nil)
    if ok == 0 or int(written) != data.len:
      raiseWin("WriteFile failed on named pipe")

  proc recvBytesExact*(conn: IpcConn; byteCount: int): seq[byte] =
    if byteCount <= 0:
      return @[]
    result = newSeq[byte](byteCount)
    var totalRead = 0
    while totalRead < byteCount:
      var nread: DWORD = 0
      let ok = readFile(conn.handle, addr result[totalRead],
        DWORD(byteCount - totalRead), addr nread, nil)
      if ok == 0:
        let err = int32(osLastError())
        if err == ERROR_BROKEN_PIPE:
          raise newException(IpcEndpointError,
            "named pipe closed by peer after " & $totalRead &
              "/" & $byteCount & " bytes")
        raiseWin("ReadFile failed on named pipe", err)
      if nread == 0:
        raise newException(IpcEndpointError,
          "named pipe EOF after " & $totalRead & "/" & $byteCount & " bytes")
      totalRead += int(nread)

  proc clientDisconnected*(conn: IpcConn): bool =
    if conn.handle == 0 or conn.handle == INVALID_HANDLE_VALUE:
      return true
    # PeekNamedPipe returns 0 with ERROR_BROKEN_PIPE when the peer has
    # closed; with bytesAvailable > 0 we know readFile won't block;
    # with bytesAvailable == 0 + success the pipe is open but idle.
    var bytesRead: DWORD = 0
    var totalAvail: DWORD = 0
    var bytesLeft: DWORD = 0
    let ok = peekNamedPipeRaw(conn.handle, nil, 0.DWORD,
      addr bytesRead, addr totalAvail, addr bytesLeft)
    if ok == 0:
      return true
    false

  proc endpointExistsLocal*(endpoint: string): bool =
    if not endpoint.startsWith(WindowsNamedPipePrefix):
      return false
    let wpath = newWideCString(endpoint)
    let ok = waitNamedPipeWRaw(wpath, 1.int32)
    if ok != 0:
      return true
    let err = int32(osLastError())
    err != ERROR_FILE_NOT_FOUND

  proc endpointAcceptsConnections*(endpoint: string): bool =
    if not endpoint.startsWith(WindowsNamedPipePrefix):
      return false
    let wpath = newWideCString(endpoint)
    let h = createFileW(wpath,
      (GENERIC_READ or GENERIC_WRITE).DWORD,
      0.DWORD, nil, OPEN_EXISTING.DWORD, 0.DWORD, 0)
    if h == INVALID_HANDLE_VALUE:
      return false
    discard closeHandle(h)
    true

# ---------------------------------------------------------------------------
# Cross-platform helpers callers reach for
# ---------------------------------------------------------------------------

proc sendBytes*(conn: IpcConn; data: openArray[byte]) =
  if data.len == 0:
    return
  var buf = newString(data.len)
  for i, b in data:
    buf[i] = char(b)
  sendByteString(conn, buf)

proc recvByteString*(conn: IpcConn; byteCount: int): string =
  let buf = recvBytesExact(conn, byteCount)
  result = newString(buf.len)
  for i, b in buf:
    result[i] = char(b)
