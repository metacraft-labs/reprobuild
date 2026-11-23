## Whether this process can change system state: root on Linux and macOS,
## an elevated token on Windows (`GetTokenInformation(TokenElevation)`,
## https://learn.microsoft.com/windows/win32/api/winnt/ne-winnt-token_information_class).
##
## It lives in repro_core so that every library deciding "am I privileged?"
## -- the host-wide apply lock's default, the elevation broker, the system
## apply and rollback pipelines -- asks the same question the same way on
## every platform. Before this module the host lock's default answered
## "unprivileged" on Windows, so an elevated apply that relied on the
## default took no host lock there.

when defined(windows):
  type
    PrivHandle = pointer
    PrivDword = uint32
    PrivBool = int32

  const
    TokenElevationClass = 20'u32
    TokenQueryAccess: PrivDword = 0x0008

  proc privGetCurrentProcess(): PrivHandle
    {.importc: "GetCurrentProcess", stdcall, dynlib: "kernel32".}
  proc privOpenProcessToken(processHandle: PrivHandle; desiredAccess: PrivDword;
                            tokenHandle: ptr PrivHandle): PrivBool
    {.importc: "OpenProcessToken", stdcall, dynlib: "advapi32".}
  proc privGetTokenInformation(tokenHandle: PrivHandle; infoClass: uint32;
                               info: pointer; infoLength: PrivDword;
                               returnLength: ptr PrivDword): PrivBool
    {.importc: "GetTokenInformation", stdcall, dynlib: "advapi32".}
  proc privCloseHandle(h: PrivHandle): PrivBool
    {.importc: "CloseHandle", stdcall, dynlib: "kernel32".}
else:
  proc privGeteuid(): uint32 {.importc: "geteuid", header: "<unistd.h>".}

type EPrivilegeQuery* = object of OSError
  ## The token could not be queried (Windows); never answered as "no".

proc processIsPrivileged*(): bool =
  ## True when this process holds root (POSIX) or an elevated token
  ## (Windows). Raises `EPrivilegeQuery` when Windows will not say.
  when defined(windows):
    var token: PrivHandle
    if privOpenProcessToken(privGetCurrentProcess(), TokenQueryAccess,
        addr token) == 0:
      raise newException(EPrivilegeQuery,
        "OpenProcessToken failed while checking token elevation")
    defer: discard privCloseHandle(token)
    var elevated: PrivDword = 0
    var returned: PrivDword = 0
    if privGetTokenInformation(token, TokenElevationClass, addr elevated,
        PrivDword(sizeof(elevated)), addr returned) == 0:
      raise newException(EPrivilegeQuery,
        "GetTokenInformation(TokenElevation) failed")
    elevated != 0
  else:
    privGeteuid() == 0'u32
