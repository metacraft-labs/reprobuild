## The authenticated IPC channel (M81 deliverable 4).
##
## Per Elevation-And-Privileged-Operations.md "The IPC Channel And
## Authentication":
##
##   Windows — a named pipe `\\.\pipe\repro-elev-<channel-id>` created
##   by the parent before the broker launch. The channel id is random
##   and is NOT the nonce: every pipe name on the machine can be
##   listed, so the name is public and nothing secret may be in it.
##   The parent creates the pipe's FIRST and ONLY instance
##   (`FILE_FLAG_FIRST_PIPE_INSTANCE`, `nMaxInstances = 1`) with a
##   protected DACL that admits Administrators and SYSTEM alone. A
##   process that created the name first makes the parent's creation
##   fail; a process that tries to add a second instance is refused.
##   So the broker, connecting by name, reaches the parent's instance.
##   The parent then requires the connecting client's token to be
##   ELEVATED. It does not compare SIDs: under Administrator
##   Protection, or an over-the-shoulder elevation by a standard user,
##   the broker's user SID is not the parent's.
##   The nonce rides on the broker's command line and in `Hello`; it
##   binds the session, and is not secret from the launching user's
##   own processes.
##
##   POSIX — a Unix domain socket + `SO_PEERCRED` / `LOCAL_PEERCRED`.
##   Per the M68 Phase A/B precedent, the POSIX transport is a
##   skeleton: it raises `ENotImplementedPlatform` so the platform-
##   pure parts (partition, RBEB codec, typed operation set,
##   closed-set validation) still build and unit-test everywhere,
##   and the Windows path is fully real.
##
## The channel speaks the `RBEB` framing from `protocol.nim`: each
## `send` writes one complete framed message, each `recv` reads a
## fixed header then exactly the declared body + trailer. The
## transport never interprets the body — it owns only delimitation
## and authentication.

import std/[strutils, sysrand]

import ./errors
import ./protocol

# ---------------------------------------------------------------------------
# Channel name derivation — shared so the parent (pipe creator) and
# the broker (connector) agree without a second argument.
# ---------------------------------------------------------------------------

const ElevationPipePrefix* = "\\\\.\\pipe\\repro-elev-"

proc isChannelId*(channelId: string): bool =
  ## A channel id is 32 lower-case hex digits, as `generateChannelId`
  ## makes them. The broker refuses any other `--channel` value, so it
  ## can only ever open a `repro-elev-` pipe.
  if channelId.len != 32:
    return false
  for c in channelId:
    if c notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc generateChannelId*(): string =
  ## A fresh random channel id. It names the pipe, so it is public as
  ## soon as the pipe exists; its job is to keep two applies apart and
  ## to make the name unguessable BEFORE the parent creates it.
  var bytes: array[16, byte]
  if not urandom(bytes):
    raiseBrokerLaunch("the OS random source is unavailable")
  result = newStringOfCap(32)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc pipeNameForChannel*(channelId: string): string =
  ## The Windows named-pipe path for a channel id. It carries no
  ## secret: the nonce is never part of it.
  if not isChannelId(channelId):
    raiseProtocol("not an elevation channel id: '" & channelId & "'")
  ElevationPipePrefix & channelId

const ElevationPipeSddl* = "D:P(A;;GA;;;BA)(A;;GA;;;SY)(A;;RC;;;OW)"
  ## The pipe's protected DACL: Administrators and SYSTEM, nobody else.
  ## The `OWNER RIGHTS` entry (`OW`, read-control only) takes away the
  ## implicit WRITE_DAC the pipe's owner -- the launching user -- would
  ## otherwise keep, so a non-elevated process of that user cannot
  ## rewrite the DACL to let itself in.
  ## An elevated broker holds an enabled Administrators group under
  ## every elevation Windows offers (Admin Approval Mode, Administrator
  ## Protection's system-managed account, over-the-shoulder credentials
  ## of another administrator). The launching user's non-elevated
  ## processes hold Administrators deny-only, or not at all, so they
  ## cannot open the pipe as a client. The elevated-client check in
  ## `acceptAuthenticatedClient` checks the same property again on the
  ## token bound to the connection.

when defined(windows):
  type
    HANDLE = pointer
    DWORD = uint32
    BOOL = int32
    LPVOID = pointer
    LPCWSTR = ptr UncheckedArray[uint16]
    LPDWORD = ptr DWORD
    PHANDLE = ptr HANDLE

  const
    PIPE_ACCESS_DUPLEX: DWORD = 0x00000003
    PIPE_TYPE_BYTE: DWORD = 0x00000000
    PIPE_READMODE_BYTE: DWORD = 0x00000000
    PIPE_WAIT: DWORD = 0x00000000
    PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008
    FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000
    SDDL_REVISION_1: DWORD = 1
    GENERIC_READ: DWORD = 0x80000000'u32
    GENERIC_WRITE: DWORD = 0x40000000'u32
    OPEN_EXISTING: DWORD = 3
    ERROR_PIPE_CONNECTED: DWORD = 535
    ERROR_PIPE_BUSY: DWORD = 231
    SECURITY_SQOS_PRESENT: DWORD = 0x00100000
    SECURITY_IDENTIFICATION: DWORD = 0x00010000
    TokenElevation = 20'u32
    TOKEN_QUERY: DWORD = 0x0008

  type
    OVERLAPPED = object
    SECURITY_ATTRIBUTES = object
      nLength: DWORD
      lpSecurityDescriptor: pointer
      bInheritHandle: BOOL

  proc invalidHandle(): HANDLE =
    ## `INVALID_HANDLE_VALUE` — the all-ones pointer the Win32 file /
    ## pipe APIs return on failure. Built via a properly-typed
    ## literal so the cast is legal in a `proc` body.
    cast[HANDLE](cast[int](0xFFFFFFFFFFFFFFFF'u64))

  proc CreateNamedPipeW(lpName: LPCWSTR; dwOpenMode: DWORD;
                        dwPipeMode: DWORD; nMaxInstances: DWORD;
                        nOutBufferSize: DWORD; nInBufferSize: DWORD;
                        nDefaultTimeOut: DWORD;
                        lpSecurityAttributes: pointer): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc ConnectNamedPipe(hNamedPipe: HANDLE;
                        lpOverlapped: ptr OVERLAPPED): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc DisconnectNamedPipe(hNamedPipe: HANDLE): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc CreateFileW(lpFileName: LPCWSTR; dwDesiredAccess: DWORD;
                   dwShareMode: DWORD; lpSecurityAttributes: pointer;
                   dwCreationDisposition: DWORD;
                   dwFlagsAndAttributes: DWORD;
                   hTemplateFile: HANDLE): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc WaitNamedPipeW(lpNamedPipeName: LPCWSTR; nTimeOut: DWORD): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc ReadFile(hFile: HANDLE; lpBuffer: LPVOID; nNumberOfBytesToRead: DWORD;
                lpNumberOfBytesRead: LPDWORD;
                lpOverlapped: ptr OVERLAPPED): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc WriteFile(hFile: HANDLE; lpBuffer: LPVOID;
                 nNumberOfBytesToWrite: DWORD;
                 lpNumberOfBytesWritten: LPDWORD;
                 lpOverlapped: ptr OVERLAPPED): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc FlushFileBuffers(hFile: HANDLE): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc CloseHandle(h: HANDLE): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetLastError(): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  # Peer-identity surface.
  proc GetTokenInformation(tokenHandle: HANDLE; tokenInformationClass: uint32;
                           tokenInformation: pointer;
                           tokenInformationLength: DWORD;
                           returnLength: LPDWORD): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc ImpersonateNamedPipeClient(hNamedPipe: HANDLE): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc RevertToSelf(): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc OpenThreadToken(threadHandle: HANDLE; desiredAccess: DWORD;
                       openAsSelf: BOOL; tokenHandle: PHANDLE): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc GetCurrentThread(): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc ConvertStringSecurityDescriptorToSecurityDescriptorW(
    sddl: LPCWSTR; revision: DWORD; sd: ptr pointer; size: ptr DWORD): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc LocalFree(p: pointer): pointer
    {.importc, stdcall, dynlib: "kernel32".}

  # ---- wide-string helpers -------------------------------------------------

  proc toWideZ(s: string): seq[uint16] =
    result = @[]
    for ch in s:
      result.add(uint16(byte(ch)))    # pipe names / nonces are ASCII
    result.add(0'u16)

  # ---- peer elevation -----------------------------------------------------

  proc tokenIsElevated(token: HANDLE): bool =
    var elevation: DWORD = 0           # TOKEN_ELEVATION { DWORD TokenIsElevated }
    var needed: DWORD = 0
    if GetTokenInformation(token, TokenElevation, addr elevation,
        DWORD(sizeof(elevation)), addr needed) == 0:
      raiseChannelAuth("GetTokenInformation(TokenElevation) failed " &
        "(status " & $GetLastError() & ")")
    elevation != 0

  proc connectedPipeClientIsElevated(pipe: HANDLE): bool =
    ## Whether the client connected to `pipe` runs with an elevated
    ## token, read from the token the kernel bound to the connection:
    ## impersonate the client (it opened at identification level),
    ## read the thread token, revert before anything else. The
    ## client's pid is not used; a client can spoof it.
    if ImpersonateNamedPipeClient(pipe) == 0:
      raiseChannelAuth("ImpersonateNamedPipeClient failed (status " &
        $GetLastError() & ")")
    var token: HANDLE
    let opened = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1,
      addr token) != 0
    let openStatus = GetLastError()
    if RevertToSelf() == 0:
      # Still impersonating: nothing more may run on this thread.
      quit("repro: RevertToSelf failed after identifying the elevation " &
        "client; stopping", QuitFailure)
    if not opened:
      raiseChannelAuth("could not open the connecting client's token " &
        "(status " & $openStatus & ")")
    defer: discard CloseHandle(token)
    tokenIsElevated(token)

  # ---- the channel object --------------------------------------------------

  type
    ElevationChannel* = object
      ## One authenticated RBEB transport endpoint. The parent owns
      ## the pipe-server handle; the broker owns the client handle.
      handle: HANDLE
      isServer: bool
      open: bool

  proc rawSendFrame(ch: var ElevationChannel; frame: openArray[byte]) =
    ## Write one complete RBEB frame. The pipe is byte-mode; the
    ## RBEB length header self-delimits the frame, so the receiver
    ## reads exactly the declared bytes back.
    var sent = 0
    while sent < frame.len:
      var wrote: DWORD = 0
      let chunk = DWORD(frame.len - sent)
      if WriteFile(ch.handle, unsafeAddr frame[sent], chunk,
          addr wrote, nil) == 0:
        raiseBrokerLost("WriteFile on the elevation channel failed " &
          "(status " & $GetLastError() & ")")
      if wrote == 0:
        raiseBrokerLost("WriteFile wrote 0 bytes on the elevation channel")
      sent += int(wrote)
    discard FlushFileBuffers(ch.handle)

  proc rawReadExact(ch: var ElevationChannel; count: int): seq[byte] =
    ## Read exactly `count` bytes; a short read (peer closed) is
    ## `EBrokerLost`.
    result = newSeq[byte](count)
    var got = 0
    while got < count:
      var read: DWORD = 0
      let want = DWORD(count - got)
      if ReadFile(ch.handle, addr result[got], want, addr read, nil) == 0:
        raiseBrokerLost("ReadFile on the elevation channel failed " &
          "(status " & $GetLastError() & ")")
      if read == 0:
        raiseBrokerLost("the elevation channel peer closed mid-frame")
      got += int(read)

  proc sendFrame*(ch: var ElevationChannel; frame: openArray[byte]) =
    if not ch.open:
      raiseBrokerLost("send on a closed elevation channel")
    rawSendFrame(ch, frame)

  proc recvFrame*(ch: var ElevationChannel): DecodedFrame =
    ## Read one RBEB frame: the fixed header, then exactly the
    ## declared body + 32-byte checksum trailer.
    if not ch.open:
      raiseBrokerLost("recv on a closed elevation channel")
    const HeaderSize = 4 + 2 + 2 + 4
    let header = rawReadExact(ch, HeaderSize)
    let hdr = parseFrameHeader(header)
    let rest = rawReadExact(ch, hdr.bodyLength + 32)
    var whole = newSeqOfCap[byte](HeaderSize + rest.len)
    for b in header: whole.add(b)
    for b in rest: whole.add(b)
    decodeFrame(whole)

  proc close*(ch: var ElevationChannel) =
    if ch.open:
      if ch.isServer:
        discard FlushFileBuffers(ch.handle)
        discard DisconnectNamedPipe(ch.handle)
      discard CloseHandle(ch.handle)
      ch.open = false

  # ---- parent side: create the pipe, accept the broker -------------------

  proc createListeningChannel*(channelId: string): ElevationChannel =
    ## PARENT: create the named pipe BEFORE launching the broker, as
    ## the FIRST and ONLY instance of its name:
    ##
    ##   * `FILE_FLAG_FIRST_PIPE_INSTANCE` — if any process already
    ##     created this name, creation fails (`ERROR_ACCESS_DENIED`)
    ##     instead of joining the squatter's pipe, where the broker
    ##     could connect to the squatter's instance.
    ##   * `nMaxInstances = 1` — nobody can add a second instance
    ##     beside this one while the parent holds it.
    ##   * `ElevationPipeSddl` — only Administrators and SYSTEM may
    ##     open it as a client.
    ##   * `PIPE_REJECT_REMOTE_CLIENTS` — local clients only.
    let name = pipeNameForChannel(channelId)
    var wide = toWideZ(name)
    var sddlW = toWideZ(ElevationPipeSddl)
    var sd: pointer
    if ConvertStringSecurityDescriptorToSecurityDescriptorW(
        cast[LPCWSTR](addr sddlW[0]), SDDL_REVISION_1, addr sd, nil) == 0:
      raiseBrokerLaunch("could not build the pipe's security descriptor " &
        "(status " & $GetLastError() & ")")
    defer: discard LocalFree(sd)
    var sa = SECURITY_ATTRIBUTES(nLength: DWORD(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: sd, bInheritHandle: 0)
    let h = CreateNamedPipeW(cast[LPCWSTR](addr wide[0]),
      PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
        PIPE_REJECT_REMOTE_CLIENTS,
      1, 64 * 1024, 64 * 1024, 0, addr sa)
    if h == invalidHandle():
      let err = GetLastError()
      raiseBrokerLaunch("CreateNamedPipeW failed for " & name &
        " (status " & $err & "); a process that already " &
        "holds this name is refused, never joined")
    result.handle = h
    result.isServer = true
    result.open = true

  proc acceptAuthenticatedClient*(ch: var ElevationChannel) =
    ## PARENT: block until a client connects, then require the
    ## connecting client's token to be ELEVATED. A non-elevated client
    ## is `EChannelAuth` and is disconnected.
    ##
    ## The check is elevation, not SID equality with the parent: under
    ## Administrator Protection the broker runs as a separate,
    ## system-managed identity, and under an over-the-shoulder
    ## elevation by a standard user it runs as the administrator who
    ## typed the credentials. Neither SID is the parent's, and a
    ## same-SID check would refuse the legitimate broker. A process
    ## that is already elevated gains nothing by connecting.
    ##
    ## On a refusal the caller must keep the pipe (do not `close`)
    ## until the broker has exited: closing releases the name, and a
    ## squatter could then create it for the broker to connect to.
    if ConnectNamedPipe(ch.handle, nil) == 0:
      let err = GetLastError()
      if err != ERROR_PIPE_CONNECTED:
        raiseBrokerLost("ConnectNamedPipe failed (status " & $err & ")")
    if not connectedPipeClientIsElevated(ch.handle):
      discard DisconnectNamedPipe(ch.handle)
      raiseChannelAuth("the connecting client is not elevated; " &
        "refusing to serve it as the broker")

  # ---- broker side: the parent must stay alive across the connect -------

  proc OpenProcess(desiredAccess: DWORD; inheritHandle: BOOL;
                   processId: DWORD): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetProcessTimes(process: HANDLE; creation, exit, kernel,
                       user: ptr uint64): BOOL
    {.importc, stdcall, dynlib: "kernel32".}

  proc WaitForSingleObject(handle: HANDLE; ms: DWORD): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetCurrentProcessId(): DWORD
    {.importc, stdcall, dynlib: "kernel32".}

  proc GetCurrentProcess(): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  const
    SYNCHRONIZE: DWORD = 0x00100000
    PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000
    WAIT_TIMEOUT: DWORD = 258

  type
    ParentWatch* = object
      ## A handle the broker holds on the parent that launched it. While
      ## the handle is open the parent's pid cannot be reused.
      handle: HANDLE

  proc processStartTime(h: HANDLE): uint64 =
    var creation, exitT, kernelT, userT: uint64
    if GetProcessTimes(h, addr creation, addr exitT, addr kernelT,
        addr userT) == 0:
      raiseChannelAuth("GetProcessTimes failed (status " &
        $GetLastError() & ")")
    creation

  proc currentProcessIdentity*(): tuple[pid: int, start: uint64] =
    ## PARENT: its own pid and creation time, passed to the broker so
    ## the broker can hold the parent and know it is the same process.
    (int(GetCurrentProcessId()), processStartTime(GetCurrentProcess()))

  proc watchParent*(pid: int; start: uint64): ParentWatch =
    ## BROKER, before connecting: open the parent and check it is the
    ## process that launched this broker (pid AND creation time).
    let h = OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION,
      0, DWORD(pid))
    if h == nil:
      raiseChannelAuth("cannot open the launching parent (pid " & $pid &
        ", status " & $GetLastError() & "); refusing to connect")
    result.handle = h
    if processStartTime(h) != start:
      discard CloseHandle(h)
      raiseChannelAuth("pid " & $pid & " is not the launching parent " &
        "(its creation time differs); refusing to connect")

  proc requireParentAlive*(w: ParentWatch) =
    ## BROKER, after connecting: the parent must still be running. The
    ## parent holds its pipe's only instance until the broker exits, so
    ## a parent that was alive from before the connect until after it
    ## means the name was never released, and the instance the broker
    ## reached is the parent's. A parent that died (was killed) may
    ## have released the name to a squatter: refuse.
    if WaitForSingleObject(w.handle, 0) != WAIT_TIMEOUT:
      raiseChannelAuth("the launching parent exited before the broker " &
        "connected; the pipe may not be the parent's")

  proc close*(w: var ParentWatch) =
    if w.handle != nil:
      discard CloseHandle(w.handle)
      w.handle = nil

  # ---- broker side: connect back to the parent ---------------------------

  proc connectToParent*(channelId: string;
                        timeoutMs: int = 20_000): ElevationChannel =
    ## BROKER: connect back to the parent's pipe. Retries while the
    ## pipe is momentarily busy (its one instance in use), up to the
    ## timeout. The pipe has one instance, created first by the
    ## parent, so opening the name reaches the parent's instance.
    let name = pipeNameForChannel(channelId)
    var wide = toWideZ(name)
    var waited = 0
    while true:
      let h = CreateFileW(cast[LPCWSTR](addr wide[0]),
        GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
        SECURITY_SQOS_PRESENT or SECURITY_IDENTIFICATION, nil)
      if h != invalidHandle():
        var result0: ElevationChannel
        result0.handle = h
        result0.isServer = false
        result0.open = true
        # The pipe is byte-mode on both ends; the RBEB length header
        # self-delimits each frame.
        return result0
      let err = GetLastError()
      if err != ERROR_PIPE_BUSY:
        raiseBrokerLaunch("broker could not open the parent pipe " &
          name & " (status " & $err & ")")
      if waited >= timeoutMs:
        raiseBrokerLaunch("timed out waiting for the parent pipe " & name)
      let slice: DWORD = 250
      discard WaitNamedPipeW(cast[LPCWSTR](addr wide[0]), slice)
      waited += int(slice)

else:
  # POSIX skeleton — M68 Phase A/B precedent. The platform-pure
  # protocol / partition / operations / dispatch modules build and
  # unit-test on POSIX; only the transport is deferred.
  type
    ElevationChannel* = object
      open: bool

  proc createListeningChannel*(channelId: string): ElevationChannel =
    raiseNotImplementedPlatform("Unix-domain-socket elevation channel")

  proc acceptAuthenticatedClient*(ch: var ElevationChannel) =
    raiseNotImplementedPlatform("Unix-domain-socket peer-cred accept")

  type ParentWatch* = object

  proc currentProcessIdentity*(): tuple[pid: int, start: uint64] =
    raiseNotImplementedPlatform("parent identity for the elevation channel")

  proc watchParent*(pid: int; start: uint64): ParentWatch =
    raiseNotImplementedPlatform("parent watch for the elevation channel")

  proc requireParentAlive*(w: ParentWatch) =
    raiseNotImplementedPlatform("parent watch for the elevation channel")

  proc close*(w: var ParentWatch) = discard

  proc connectToParent*(channelId: string;
                        timeoutMs: int = 20_000): ElevationChannel =
    raiseNotImplementedPlatform("Unix-domain-socket connect-back")

  proc sendFrame*(ch: var ElevationChannel; frame: openArray[byte]) =
    raiseNotImplementedPlatform("Unix-domain-socket sendFrame")

  proc recvFrame*(ch: var ElevationChannel): DecodedFrame =
    raiseNotImplementedPlatform("Unix-domain-socket recvFrame")

  proc close*(ch: var ElevationChannel) =
    ch.open = false
