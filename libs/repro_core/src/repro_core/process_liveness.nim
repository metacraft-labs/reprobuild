## Whether a process id names a running process.
##
## Shared by every owner-liveness rule that reclaims something a dead
## process left behind: the ``repro infra apply`` lock and the static-tree
## markers (``repro_infra/apply_lock``), and the git pack temporaries an
## interrupted repack leaves in a shared clone pool
## (``repro_workspace_vcs/shared_clones``).

when defined(windows):
  import std/winlean
else:
  import std/posix

when defined(windows):
  const
    StillActive: DWORD = 259
    ProcessQueryLimitedInformation: DWORD = 0x1000
    # Win32 code returned by OpenProcess for a pid that does not exist.
    # Declared here because std/winlean does not export it.
    ErrorInvalidParameter: int32 = 87

  proc openProcessK32(desiredAccess: DWORD; inheritHandle: WINBOOL;
                      processId: DWORD): Handle
    {.importc: "OpenProcess", stdcall, dynlib: "kernel32".}

  proc getExitCodeProcessK32(process: Handle; exitCode: ptr DWORD): WINBOOL
    {.importc: "GetExitCodeProcess", stdcall, dynlib: "kernel32".}

proc processAlive*(pid: int): bool =
  ## True when a process with `pid` currently exists.
  ##
  ## Deliberately conservative: anything we cannot positively establish as
  ## dead is reported ALIVE, so an unexpected probe failure preserves what
  ## the process owns (a lock, a temporary file) rather than reclaiming it
  ## from under a running owner. A reused pid errs the same way.
  if pid <= 0:
    return false
  when defined(windows):
    let h = openProcessK32(ProcessQueryLimitedInformation, 0, DWORD(pid))
    if h == 0:
      # Cannot open: the process is gone (ERROR_INVALID_PARAMETER) or we
      # lack rights to it (ERROR_ACCESS_DENIED). Access-denied implies it
      # EXISTS, so only treat "not found" as dead.
      return getLastError() != ErrorInvalidParameter
    defer: discard closeHandle(h)
    var code: DWORD = 0
    if getExitCodeProcessK32(h, addr code) == 0:
      return true
    code == StillActive
  else:
    # kill(pid, 0) performs the permission + existence checks without
    # sending a signal: ESRCH means gone, EPERM means it exists but is
    # owned by another user.
    if posix.kill(Pid(pid), cint(0)) == 0:
      return true
    errno != ESRCH
