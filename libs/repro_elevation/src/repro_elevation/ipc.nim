## The authenticated IPC channel (M81 deliverable 4).
##
## Per Elevation-And-Privileged-Operations.md "The IPC Channel And
## Authentication":
##
##   Windows — a named pipe `\\.\pipe\repro-elev-<nonce>` created by
##   the parent before the broker launch. The broker connects back.
##   The parent verifies the connecting client via the pipe's
##   authenticated peer SID (the broker must be the same human user).
##   The broker verifies the parent passed the matching `<nonce>` so
##   an unrelated local process cannot connect and drive an elevated
##   executor.
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

import ./errors
import ./protocol

# ---------------------------------------------------------------------------
# Channel name derivation — shared so the parent (pipe creator) and
# the broker (connector) agree without a second argument.
# ---------------------------------------------------------------------------

proc pipeNameForNonce*(nonce: string): string =
  ## The Windows named-pipe path for a given nonce. The nonce is a
  ## cryptographically random hex token; it is safe in a pipe name.
  "\\\\.\\pipe\\repro-elev-" & nonce

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
    PIPE_UNLIMITED_INSTANCES: DWORD = 255
    GENERIC_READ: DWORD = 0x80000000'u32
    GENERIC_WRITE: DWORD = 0x40000000'u32
    OPEN_EXISTING: DWORD = 3
    ERROR_PIPE_CONNECTED: DWORD = 535
    ERROR_PIPE_BUSY: DWORD = 231
    SECURITY_SQOS_PRESENT: DWORD = 0x00100000
    SECURITY_IDENTIFICATION: DWORD = 0x00010000
    TokenUser = 1'u32
    TOKEN_QUERY: DWORD = 0x0008

  type
    OVERLAPPED = object
    SidNameUse = int32

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
  proc GetCurrentProcess(): HANDLE
    {.importc, stdcall, dynlib: "kernel32".}

  proc OpenProcessToken(processHandle: HANDLE; desiredAccess: DWORD;
                        tokenHandle: PHANDLE): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

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

  proc ConvertSidToStringSidW(sid: pointer;
                              stringSid: ptr LPCWSTR): BOOL
    {.importc, stdcall, dynlib: "advapi32".}

  proc LocalFree(p: pointer): pointer
    {.importc, stdcall, dynlib: "kernel32".}

  # ---- wide-string helpers -------------------------------------------------

  proc toWideZ(s: string): seq[uint16] =
    result = @[]
    for ch in s:
      result.add(uint16(byte(ch)))    # pipe names / nonces are ASCII
    result.add(0'u16)

  proc fromWideZ(p: LPCWSTR): string =
    var i = 0
    while p[i] != 0'u16:
      result.add(char(p[i] and 0xff))
      inc i

  # ---- peer SID extraction -------------------------------------------------

  proc currentProcessUserSidString(): string =
    ## SID string of the user the CURRENT process runs as.
    var token: HANDLE
    if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, addr token) == 0:
      raiseChannelAuth("OpenProcessToken failed")
    defer: discard CloseHandle(token)
    var needed: DWORD = 0
    discard GetTokenInformation(token, TokenUser, nil, 0, addr needed)
    if needed == 0:
      raiseChannelAuth("GetTokenInformation(TokenUser) sizing failed")
    var buf = newSeq[byte](int(needed))
    if GetTokenInformation(token, TokenUser, addr buf[0], needed,
        addr needed) == 0:
      raiseChannelAuth("GetTokenInformation(TokenUser) failed")
    # TOKEN_USER { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes } }
    # The first pointer-sized field is the PSID.
    let sidPtr = cast[pointer](cast[ptr int](addr buf[0])[])
    var sidStrW: LPCWSTR
    if ConvertSidToStringSidW(sidPtr, addr sidStrW) == 0:
      raiseChannelAuth("ConvertSidToStringSidW failed")
    result = fromWideZ(sidStrW)
    discard LocalFree(sidStrW)

  proc connectedPipeClientSidString(pipe: HANDLE): string =
    ## SID string of the client currently connected to `pipe`,
    ## obtained by impersonating the client and reading the
    ## impersonation token's user. Restores the thread token before
    ## returning.
    if ImpersonateNamedPipeClient(pipe) == 0:
      raiseChannelAuth("ImpersonateNamedPipeClient failed (status " &
        $GetLastError() & ")")
    var failed = false
    var sidStr = ""
    try:
      var token: HANDLE
      if OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, addr token) == 0:
        failed = true
      else:
        defer: discard CloseHandle(token)
        var needed: DWORD = 0
        discard GetTokenInformation(token, TokenUser, nil, 0, addr needed)
        if needed == 0:
          failed = true
        else:
          var buf = newSeq[byte](int(needed))
          if GetTokenInformation(token, TokenUser, addr buf[0], needed,
              addr needed) == 0:
            failed = true
          else:
            let sidPtr = cast[pointer](cast[ptr int](addr buf[0])[])
            var sidStrW: LPCWSTR
            if ConvertSidToStringSidW(sidPtr, addr sidStrW) == 0:
              failed = true
            else:
              sidStr = fromWideZ(sidStrW)
              discard LocalFree(sidStrW)
    finally:
      discard RevertToSelf()
    if failed:
      raiseChannelAuth("could not read the connecting client's SID")
    return sidStr

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

  proc createListeningChannel*(nonce: string): ElevationChannel =
    ## PARENT: create the named pipe BEFORE launching the broker.
    ## `PIPE_REJECT_REMOTE_CLIENTS` confines the pipe to the local
    ## machine. The default security descriptor grants access only
    ## to the creating user + SYSTEM + Administrators, so a different
    ## interactive user cannot open it; the explicit peer-SID check
    ## in `acceptAuthenticatedClient` is the belt-and-braces
    ## confirmation the spec mandates.
    let name = pipeNameForNonce(nonce)
    var wide = toWideZ(name)
    let h = CreateNamedPipeW(cast[LPCWSTR](addr wide[0]),
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
        PIPE_REJECT_REMOTE_CLIENTS,
      PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, nil)
    if h == invalidHandle():
      raiseBrokerLaunch("CreateNamedPipeW failed (status " &
        $GetLastError() & ")")
    result.handle = h
    result.isServer = true
    result.open = true

  proc acceptAuthenticatedClient*(ch: var ElevationChannel) =
    ## PARENT: block until a client connects, then verify the
    ## connecting peer's SID equals the parent's own user SID. A
    ## mismatch is `EChannelAuth` and the connection is dropped — an
    ## unrelated user's process cannot drive the elevated broker.
    ## (The broker runs under an elevated token of the SAME human
    ## user, so its user SID matches the parent's.)
    if ConnectNamedPipe(ch.handle, nil) == 0:
      let err = GetLastError()
      if err != ERROR_PIPE_CONNECTED:
        raiseBrokerLost("ConnectNamedPipe failed (status " & $err & ")")
    let expectedSid = currentProcessUserSidString()
    let peerSid = connectedPipeClientSidString(ch.handle)
    if peerSid != expectedSid:
      discard DisconnectNamedPipe(ch.handle)
      raiseChannelAuth("the connecting client's SID (" & peerSid &
        ") is not the launching user (" & expectedSid &
        "); refusing to serve a foreign peer")

  # ---- broker side: connect back to the parent ---------------------------

  proc connectToParent*(nonce: string;
                        timeoutMs: int = 20_000): ElevationChannel =
    ## BROKER: connect back to the parent's pipe. Retries while the
    ## pipe is momentarily busy (all instances in use), up to the
    ## timeout.
    let name = pipeNameForNonce(nonce)
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

  proc createListeningChannel*(nonce: string): ElevationChannel =
    raiseNotImplementedPlatform("Unix-domain-socket elevation channel")

  proc acceptAuthenticatedClient*(ch: var ElevationChannel) =
    raiseNotImplementedPlatform("Unix-domain-socket peer-cred accept")

  proc connectToParent*(nonce: string;
                        timeoutMs: int = 20_000): ElevationChannel =
    raiseNotImplementedPlatform("Unix-domain-socket connect-back")

  proc sendFrame*(ch: var ElevationChannel; frame: openArray[byte]) =
    raiseNotImplementedPlatform("Unix-domain-socket sendFrame")

  proc recvFrame*(ch: var ElevationChannel): DecodedFrame =
    raiseNotImplementedPlatform("Unix-domain-socket recvFrame")

  proc close*(ch: var ElevationChannel) =
    ch.open = false
