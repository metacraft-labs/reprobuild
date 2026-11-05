## Windows named pipes for the agent protocol's transport
## (`ReproOS-Agent-Integration-Protocol.md` §"The Windows transport").
##
## The rules this module implements, and which property of the Unix
## transport each one stands in for:
##
## * **Creation (T1, T4, T5).** Every instance is created with
##   `PIPE_REJECT_REMOTE_CLIENTS` and an explicit protected DACL that
##   grants the host user alone (`D:P(A;;GA;;;<SID>)`, the analogue of the
##   `0700` directory). The first instance also carries
##   `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a name that already exists fails
##   creation instead of being served beside a squatter. A listener always
##   holds one unconnected instance, so the name never lapses.
## * **Peer identity (T1, T2).** `clientSid` impersonates the client of a
##   pipe from which data has been read, opens the thread token as self,
##   reads its `TokenUser` SID and reverts before doing anything else. The
##   identity is the one the kernel bound to the connection; the client's
##   pid (`GetNamedPipeClientProcessId`) is not used for it because a client
##   can spoof that pid (J. Forshaw, "Windows Exploitation Tricks: Spoofing
##   Named Pipe Client PID", Project Zero, 2019,
##   https://projectzero.google/2019/09/windows-exploitation-tricks-spoofing.html).
## * **Clients** open with `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION`:
##   the host may identify them and can never act as them.
##
## The I/O is overlapped and completes through the `asyncdispatch` IOCP
## dispatcher, so the single-threaded host serves pipes exactly as it
## serves sockets on POSIX. The patterns follow `std/asyncfile`'s Windows
## branch (`newCustom`, `CompletionData`, `ERROR_IO_PENDING`).
##
## API references:
## https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createnamedpipew
## https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-connectnamedpipe
## https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-impersonatenamedpipeclient
## https://learn.microsoft.com/en-us/windows/win32/secauthz/impersonation-levels

when not defined(windows):
  {.error: "repro_agent_protocol/named_pipe is the Windows transport".}

import std/[asyncdispatch, os, strutils, sysrand, widestrs]
import std/winlean

const
  PIPE_TYPE_BYTE = 0'i32
  PIPE_READMODE_BYTE = 0'i32
  PIPE_WAIT = 0'i32
  PIPE_REJECT_REMOTE_CLIENTS = 0x8'i32
  PIPE_UNLIMITED_INSTANCES = 255'i32
  PipeBufferBytes = 64 * 1024'i32
  ERROR_BROKEN_PIPE = 109'i32
  ERROR_PIPE_BUSY = 231'i32
  ERROR_NO_DATA = 232'i32
  ERROR_PIPE_NOT_CONNECTED = 233'i32
  ERROR_PIPE_CONNECTED = 535'i32
  ERROR_OPERATION_ABORTED = 995'i32
  SECURITY_SQOS_PRESENT = 0x00100000'i32
  SECURITY_IDENTIFICATION = 0x00010000'i32 ## SecurityIdentification shl 16
  TOKEN_QUERY = 0x0008'i32
  TokenUserClass = 1'i32
  SDDL_REVISION_1 = 1'i32
  ConnectRetryMs = 10
  ConnectWaitMs* = 5_000
    ## How long a client waits for a free instance (`ERROR_PIPE_BUSY`).

type
  ClientImpersonation* = enum
    ## The impersonation level a client grants the server
    ## (`SECURITY_SQOS_PRESENT` flags of `CreateFileW`).
    ciAnonymous      ## SECURITY_ANONYMOUS: the server cannot identify it
    ciIdentification ## SECURITY_IDENTIFICATION: the protocol's level

  PipeStream* = ref object
    ## One connected end of a pipe, server or client.
    fd: AsyncFD
    closed: bool

  PipeListener* = ref object
    ## The server side of one pipe name: always one unconnected instance.
    name, sddl: string
    pending: AsyncFD
    closed: bool

  PipeSecurityError* = object of OSError
    ## The client could not be identified.

proc ConnectNamedPipe(h: Handle; ol: POVERLAPPED): WINBOOL {.
  stdcall, dynlib: "kernel32", importc.}
proc DisconnectNamedPipe(h: Handle): WINBOOL {.
  stdcall, dynlib: "kernel32", importc.}
proc GetNamedPipeClientProcessId(h: Handle; pid: ptr uint32): WINBOOL {.
  stdcall, dynlib: "kernel32", importc.}
proc GetCurrentThread(): Handle {.stdcall, dynlib: "kernel32", importc.}
proc LocalFree(p: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}
proc ImpersonateNamedPipeClient(h: Handle): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc RevertToSelf(): WINBOOL {.stdcall, dynlib: "advapi32", importc.}
proc OpenThreadToken(thread: Handle; access: int32; openAsSelf: WINBOOL;
                     token: ptr Handle): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc OpenProcessToken(process: Handle; access: int32; token: ptr Handle):
  WINBOOL {.stdcall, dynlib: "advapi32", importc.}
proc GetTokenInformation(token: Handle; cls: int32; info: pointer;
                         len: int32; retLen: ptr int32): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc ConvertSidToStringSidW(sid: pointer; str: ptr WideCString): WINBOOL {.
  stdcall, dynlib: "advapi32", importc.}
proc ConvertStringSecurityDescriptorToSecurityDescriptorW(
  sddl: WideCString; revision: int32; sd: ptr pointer; size: ptr int32):
  WINBOOL {.stdcall, dynlib: "advapi32", importc.}

# ---------------------------------------------------------------------
# Identities

proc tokenUserSid(token: Handle): string =
  ## The string form (`S-1-5-21-…`) of a token's user SID.
  var needed: int32
  discard GetTokenInformation(token, TokenUserClass, nil, 0, addr needed)
  if needed <= 0:
    raiseOSError(osLastError(), "GetTokenInformation(TokenUser) size")
  var buf = newSeq[byte](needed)
  if GetTokenInformation(token, TokenUserClass, addr buf[0], needed,
                         addr needed) == 0:
    raiseOSError(osLastError(), "GetTokenInformation(TokenUser)")
  # TOKEN_USER { SID_AND_ATTRIBUTES User { PSID Sid; DWORD Attributes } }:
  # the SID pointer is the first field.
  let sid = cast[ptr pointer](addr buf[0])[]
  var text: WideCString
  if ConvertSidToStringSidW(sid, addr text) == 0:
    raiseOSError(osLastError(), "ConvertSidToStringSidW")
  result = $text
  discard LocalFree(cast[pointer](text))

proc currentUserSid*(): string =
  ## The user SID of this process's token: the identity peers must share.
  var token: Handle
  if OpenProcessToken(getCurrentProcess(), TOKEN_QUERY, addr token) == 0:
    raiseOSError(osLastError(), "OpenProcessToken")
  defer: discard closeHandle(token)
  tokenUserSid(token)

proc ownerOnlySddl*(sid: string): string =
  ## The protected DACL that admits `sid` alone (spec: `D:P(A;;GA;;;<SID>)`).
  "D:P(A;;GA;;;" & sid & ")"

# ---------------------------------------------------------------------
# Streams

proc handle*(s: PipeStream): Handle = s.fd.Handle

proc close*(s: PipeStream) =
  ## Close this end. A pending read on it completes as end of stream.
  if s.closed:
    return
  s.closed = true
  unregister(s.fd)
  discard closeHandle(s.fd.Handle)

proc isPeerGone(err: OSErrorCode): bool =
  err.int32 in [ERROR_BROKEN_PIPE, ERROR_PIPE_NOT_CONNECTED, ERROR_NO_DATA,
                ERROR_OPERATION_ABORTED, ERROR_HANDLE_EOF.int32]

proc recv*(s: PipeStream; size: int): Future[string] =
  ## Up to `size` bytes; "" when the peer is gone or this end was closed.
  var fut = newFuture[string]("named_pipe.recv")
  if s.closed or size <= 0:
    fut.complete("")
    return fut
  let buf = cast[cstring](alloc0(size))
  var ol = newCustom()
  ol.data = CompletionData(fd: s.fd, cb:
    proc (fd: AsyncFD; bytes: DWORD; err: OSErrorCode) =
      if not fut.finished:
        if err == OSErrorCode(-1):
          var data = newString(bytes)
          if bytes > 0:
            copyMem(addr data[0], buf, bytes)
          fut.complete(data)
        elif isPeerGone(err):
          fut.complete("")
        else:
          fut.fail(newOSError(err))
      dealloc(buf))
  if readFile(s.fd.Handle, buf, size.int32, nil, cast[POVERLAPPED](ol)) == 0:
    let err = osLastError()
    if err.int32 != ERROR_IO_PENDING:
      # No completion packet will be queued for a call that failed at once.
      GC_unref(ol)
      dealloc(buf)
      if isPeerGone(err): fut.complete("")
      else: fut.fail(newOSError(err))
  # A call that succeeded at once still queues its completion packet, and
  # the callback above completes the future.
  fut

proc recvExact*(s: PipeStream; size: int): Future[string] {.async.} =
  ## Exactly `size` bytes, or fewer when the peer went away first.
  result = ""
  while result.len < size:
    let part = await s.recv(size - result.len)
    if part.len == 0:
      break
    result.add part

proc writeSome(s: PipeStream; data: string; start: int): Future[int] =
  var fut = newFuture[int]("named_pipe.write")
  let n = data.len - start
  let buf = cast[cstring](alloc0(n))
  copyMem(buf, unsafeAddr data[start], n)
  var ol = newCustom()
  ol.data = CompletionData(fd: s.fd, cb:
    proc (fd: AsyncFD; bytes: DWORD; err: OSErrorCode) =
      if not fut.finished:
        if err == OSErrorCode(-1): fut.complete(int(bytes))
        else: fut.fail(newOSError(err))
      dealloc(buf))
  if writeFile(s.fd.Handle, buf, n.int32, nil, cast[POVERLAPPED](ol)) == 0:
    let err = osLastError()
    if err.int32 != ERROR_IO_PENDING:
      GC_unref(ol)
      dealloc(buf)
      fut.fail(newOSError(err))
  fut

proc send*(s: PipeStream; data: string) {.async.} =
  ## Write all of `data`; raises OSError when the peer is gone.
  if s.closed:
    raise newException(OSError, "the pipe is closed")
  var done = 0
  while done < data.len:
    let n = await s.writeSome(data, done)
    if n <= 0:
      raise newException(OSError, "the pipe accepted no bytes")
    done += n

# ---------------------------------------------------------------------
# Server side

proc createInstance(name, sddl: string; first: bool): AsyncFD =
  var sd: pointer
  if ConvertStringSecurityDescriptorToSecurityDescriptorW(
      newWideCString(sddl), SDDL_REVISION_1, addr sd, nil) == 0:
    raiseOSError(osLastError(), "security descriptor " & sddl)
  defer: discard LocalFree(sd)
  var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
                               lpSecurityDescriptor: sd, bInheritHandle: 0)
  var openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED
  if first:
    openMode = openMode or FILE_FLAG_FIRST_PIPE_INSTANCE
  let h = createNamedPipe(newWideCString(name), openMode,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
      PIPE_REJECT_REMOTE_CLIENTS,
    PIPE_UNLIMITED_INSTANCES, PipeBufferBytes, PipeBufferBytes, 0, addr sa)
  if h == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError(), "CreateNamedPipeW " & name)
  result = AsyncFD(h)
  register(result)

proc listenPipe*(name, sddl: string): PipeListener =
  ## Create the FIRST instance of `name`; raises OSError when any instance
  ## of that name already exists (a squatter, or a second host).
  PipeListener(name: name, sddl: sddl,
               pending: createInstance(name, sddl, first = true))

proc connectInstance(fd: AsyncFD): Future[void] =
  var fut = newFuture[void]("named_pipe.connect")
  var ol = newCustom()
  ol.data = CompletionData(fd: fd, cb:
    proc (fd: AsyncFD; bytes: DWORD; err: OSErrorCode) =
      if not fut.finished:
        if err == OSErrorCode(-1): fut.complete()
        else: fut.fail(newOSError(err)))
  if ConnectNamedPipe(fd.Handle, cast[POVERLAPPED](ol)) == 0:
    let err = osLastError()
    if err.int32 == ERROR_PIPE_CONNECTED:
      # The client connected between creation and this call: success, and
      # no completion packet follows.
      GC_unref(ol)
      fut.complete()
    elif err.int32 != ERROR_IO_PENDING:
      GC_unref(ol)
      fut.fail(newOSError(err))
  fut

proc accept*(l: PipeListener): Future[PipeStream] {.async.} =
  ## The next connected client. The listener replaces the instance it hands
  ## out before returning it, so the name always has a waiting instance.
  if l.closed:
    raise newException(OSError, "the listener is closed")
  let fd = l.pending
  try:
    await connectInstance(fd)
  except OSError:
    # A client that came and went (ERROR_NO_DATA): recycle the instance.
    if not l.closed:
      discard DisconnectNamedPipe(fd.Handle)
    raise
  if l.closed:
    raise newException(OSError, "the listener is closed")
  l.pending = createInstance(l.name, l.sddl, first = false)
  PipeStream(fd: fd)

proc close*(l: PipeListener) =
  if l.closed:
    return
  l.closed = true
  unregister(l.pending)
  discard closeHandle(l.pending.Handle)

proc clientSid*(s: PipeStream): string =
  ## The user SID of the client's authenticated security context, read by
  ## impersonating it. Data must have been read from the pipe first.
  ## Raises `PipeSecurityError` when the client cannot be identified (an
  ## anonymous-level client, or nothing read yet).
  if ImpersonateNamedPipeClient(s.fd.Handle) == 0:
    raise newException(PipeSecurityError,
      "ImpersonateNamedPipeClient: " & osErrorMsg(osLastError()))
  var token: Handle
  let opened = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1,
                               addr token) != 0
  let openErr = osLastError()
  if RevertToSelf() == 0:
    # This thread would go on acting as the client. Nothing after this
    # point could be trusted, so there is no recovering from it.
    raiseAssert "RevertToSelf failed: " & osErrorMsg(osLastError())
  if not opened:
    raise newException(PipeSecurityError,
      "OpenThreadToken: " & osErrorMsg(openErr))
  defer: discard closeHandle(token)
  try:
    result = tokenUserSid(token)
  except OSError as e:
    raise newException(PipeSecurityError, e.msg)

proc clientPid*(s: PipeStream): int =
  ## The pid the pipe file system reports for the client, or -1. ADVISORY
  ## only: a client can spoof it (see the module documentation).
  var pid: uint32
  if GetNamedPipeClientProcessId(s.fd.Handle, addr pid) == 0 or pid == 0: -1
  else: int(pid)

# ---------------------------------------------------------------------
# Client side

proc randomNonce*(): string =
  ## 128 random bits, hex: the per-start part of the host's pipe names.
  for b in urandom(16):
    result.add toHex(b, 2).toLowerAscii

proc openPipeNow*(path: string; level = ciIdentification): PipeStream =
  ## One attempt to connect to the pipe at `path` with the calling
  ## thread's token. Raises OSError when there is no such pipe, no free
  ## instance (`ERROR_PIPE_BUSY`) or the pipe's DACL refuses the caller.
  let sqos = SECURITY_SQOS_PRESENT or
    (if level == ciIdentification: SECURITY_IDENTIFICATION else: 0'i32)
  let h = createFileW(newWideCString(path),
    GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_OVERLAPPED or sqos, 0)
  if h == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError(), "open pipe " & path)
  let fd = AsyncFD(h)
  register(fd)
  PipeStream(fd: fd)

proc openPipe*(path: string;
               level = ciIdentification): Future[PipeStream] {.async.} =
  ## Connect to the pipe at `path`, waiting up to `ConnectWaitMs` for a
  ## free instance.
  var waited = 0
  while true:
    try:
      return openPipeNow(path, level)
    except OSError as e:
      if e.errorCode != ERROR_PIPE_BUSY or waited >= ConnectWaitMs:
        raise
    await sleepAsync(ConnectRetryMs)
    waited += ConnectRetryMs
