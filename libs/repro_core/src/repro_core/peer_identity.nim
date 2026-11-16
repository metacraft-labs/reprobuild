## Who is at the other end of a local IPC connection, as the KERNEL reports
## it -- never as the peer says.
##
## A path is not an identity: whoever creates a socket or a pipe name first
## answers on it. What a process can trust is what the operating system
## recorded about the peer when the connection was made:
##
## * Linux: ``SO_PEERCRED`` on a connected AF_UNIX socket (unix(7),
##   https://man7.org/linux/man-pages/man7/unix.7.html), the credentials the
##   peer had when it called ``connect(2)`` -- or, seen from the client, when
##   the listener called ``listen(2)``.
## * macOS and the BSDs: ``getpeereid(3)``
##   (https://man.freebsd.org/cgi/man.cgi?query=getpeereid), the same uid,
##   without a pid.
## * Windows: a SID in its string form (``S-1-5-21-…``,
##   ``ConvertSidToStringSidW``): the user SID of a token
##   (``GetTokenInformation(TokenUser)``,
##   https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-gettokeninformation),
##   or the owner SID of a kernel object such as a named pipe, read from a
##   handle to it (``GetSecurityInfo(..., SE_KERNEL_OBJECT,
##   OWNER_SECURITY_INFORMATION)``,
##   https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo).
##   A pipe CLIENT identifies the server by the pipe's owner, never by
##   ``GetNamedPipeServerProcessId``. That call returns a pid the named pipe
##   file system recorded, and the pid does not stay bound to the process
##   holding the server end: the handle can be inherited or duplicated, and
##   pids are reused. So the token found under that pid need not be the
##   server's.
##
## These are the primitives only. What identity a caller EXPECTS, and what it
## does with a mismatch, is that caller's rule
## (``repro_daemon_core/ipc.requireIpcPeer``,
## ``repro_agent_protocol/transport``).

import std/os

when defined(posix):
  import std/posix

  type
    SocketPeerCredentials* = object
      uid*: int ## the peer's effective uid
      pid*: int ## the peer's pid; -1 where the platform does not report it

  when defined(linux):
    type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
      pid: Pid
      uid: Uid
      gid: Gid
    var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint

    proc socketPeerCredentials*(fd: SocketHandle): SocketPeerCredentials =
      ## The kernel's record of the peer of the connected AF_UNIX socket
      ## ``fd``. Raises ``OSError`` when it cannot be obtained.
      var c: Ucred
      var len = SockLen(sizeof(c))
      if getsockopt(fd, SOL_SOCKET, SO_PEERCRED, addr c, addr len) != 0:
        raiseOSError(osLastError(), "SO_PEERCRED")
      if int(len) < sizeof(c):
        raise newException(OSError, "SO_PEERCRED returned " & $len &
          " bytes, not a struct ucred")
      SocketPeerCredentials(uid: int(c.uid), pid: int(c.pid))
  else:
    proc getpeereid(s: SocketHandle; uid: var Uid; gid: var Gid): cint {.
      importc, header: "<unistd.h>".}

    proc socketPeerCredentials*(fd: SocketHandle): SocketPeerCredentials =
      ## The kernel's record of the peer of the connected AF_UNIX socket
      ## ``fd``. ``getpeereid`` reports no pid. Raises ``OSError`` when it
      ## cannot be obtained.
      var uid: Uid
      var gid: Gid
      if getpeereid(fd, uid, gid) != 0:
        raiseOSError(osLastError(), "getpeereid")
      SocketPeerCredentials(uid: int(uid), pid: -1)

when defined(windows):
  import std/[widestrs, winlean]

  const
    TOKEN_QUERY = 0x0008'i32
    TokenUserClass = 1'i32
    SE_KERNEL_OBJECT = 6'i32
      ## ``SE_OBJECT_TYPE`` for a kernel object handle (accctrl.h).
    OWNER_SECURITY_INFORMATION = 0x00000001'i32

  proc OpenProcessToken(process: Handle; access: int32; token: ptr Handle):
    WINBOOL {.stdcall, dynlib: "advapi32", importc.}
  proc GetTokenInformation(token: Handle; cls: int32; info: pointer;
                           len: int32; retLen: ptr int32): WINBOOL {.
    stdcall, dynlib: "advapi32", importc.}
  proc ConvertSidToStringSidW(sid: pointer; str: ptr WideCString): WINBOOL {.
    stdcall, dynlib: "advapi32", importc.}
  proc GetSecurityInfo(handle: Handle; objectType: int32;
                       securityInfo: int32; owner, group, dacl, sacl,
                       descriptor: ptr pointer): int32 {.
    stdcall, dynlib: "advapi32", importc.}
    ## Returns a Win32 error code (``ERROR_SUCCESS`` = 0), not a BOOL.
  proc LocalFree(p: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}

  proc sidText(sid: pointer): string =
    ## The string form of the binary SID at ``sid``. Raises ``OSError``.
    var text: WideCString
    if ConvertSidToStringSidW(sid, addr text) == 0:
      raiseOSError(osLastError(), "ConvertSidToStringSidW")
    result = $text
    discard LocalFree(cast[pointer](text))

  proc tokenUserSid*(token: Handle): string =
    ## The string form (``S-1-5-21-…``) of a token's user SID. Raises
    ## ``OSError`` when it cannot be read.
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
    sidText(cast[ptr pointer](addr buf[0])[])

  proc processUserSid*(process: Handle): string =
    ## The user SID of ``process``'s primary token. The handle needs
    ## ``PROCESS_QUERY_LIMITED_INFORMATION``. Raises ``OSError``.
    var token: Handle
    if OpenProcessToken(process, TOKEN_QUERY, addr token) == 0:
      raiseOSError(osLastError(), "OpenProcessToken")
    defer: discard closeHandle(token)
    tokenUserSid(token)

  proc currentUserSid*(): string =
    ## The user SID of this process's token.
    processUserSid(getCurrentProcess())

  proc kernelObjectOwnerSid*(handle: Handle): string =
    ## The owner SID of the kernel object ``handle`` refers to, for example
    ## the named pipe a client connected to. The handle needs
    ## ``READ_CONTROL``, which ``GENERIC_READ`` includes. Raises ``OSError``
    ## when the security information cannot be read or names no owner.
    ##
    ## A pipe's owner is fixed when its first instance is created. An
    ## account without ``SeRestorePrivilege`` can set it only to its own
    ## user SID or to a group its token marks as an assignable owner, so the
    ## owner identifies the account that created the pipe.
    var owner: pointer
    var descriptor: pointer
    let rc = GetSecurityInfo(handle, SE_KERNEL_OBJECT,
      OWNER_SECURITY_INFORMATION, addr owner, nil, nil, nil, addr descriptor)
    if rc != 0:
      raiseOSError(OSErrorCode(rc), "GetSecurityInfo(OWNER)")
    defer: discard LocalFree(descriptor)
    if owner == nil:
      raise newException(OSError, "GetSecurityInfo(OWNER) returned no owner")
    sidText(owner)
