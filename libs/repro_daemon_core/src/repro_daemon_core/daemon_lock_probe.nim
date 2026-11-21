## What a client can observe about a user daemon's state-directory lock
## WITHOUT being the daemon: is `<state dir>/.repro-daemon.lock` there, does
## any process hold the OS lock on it, and is a given pid still running.
##
## `requestUserDaemonShutdown` (client.nim) uses these to say what it saw
## after a shutdown ACK. The lock is an OS lock (`flock` / `LockFileEx`), so it
## is released when the daemon's handle closes however the daemon ends; the
## FILE can outlive it (a removal that failed, a Windows delete that is
## pending behind another process's handle). "The file is still there" and
## "the lock is still held" are therefore different observations, and only
## the second says a daemon is still alive.

import std/os

when defined(posix):
  import std/posix

  const
    ProbeLockExclusive = 2.cint
    ProbeLockNonBlocking = 4.cint

  proc probeFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

when defined(windows):
  import std/winlean

  const
    ProbeLockfileExclusiveLock = 0x00000002'i32
    ProbeLockfileFailImmediately = 0x00000001'i32
    ProbeErrorFileNotFound = 2'i32
    ProbeErrorPathNotFound = 3'i32
    ProbeErrorLockViolation = 33'i32
    ProbeErrorInvalidParameter = 87'i32
    ProbeFileShareDelete = 0x00000004'i32
    ProbeProcessQueryLimitedInformation = 0x1000'i32
    ProbeStillActive = 259'i32

  proc probeLockFileEx(hFile: Handle; dwFlags: DWORD; dwReserved: DWORD;
                       nNumberOfBytesToLockLow,
                       nNumberOfBytesToLockHigh: DWORD;
                       lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "LockFileEx", sideEffect.}
  proc probeUnlockFileEx(hFile: Handle; dwReserved: DWORD;
                         nNumberOfBytesToUnlockLow,
                         nNumberOfBytesToUnlockHigh: DWORD;
                         lpOverlapped: ptr OVERLAPPED): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "UnlockFileEx", sideEffect.}
  proc probeOpenProcess(desiredAccess: DWORD; inheritHandle: WINBOOL;
                        processId: DWORD): Handle {.
    stdcall, dynlib: "kernel32", importc: "OpenProcess", sideEffect.}
  proc probeGetExitCodeProcess(process: Handle; exitCode: ptr DWORD): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetExitCodeProcess", sideEffect.}

const UserDaemonLockFileName* = ".repro-daemon.lock"
  ## The daemon's lockfile, directly under its state directory.

type
  UserDaemonLockState* = enum
    udlAbsent      ## no lockfile
    udlFree        ## the lockfile exists and no process holds the lock
    udlHeld        ## some process holds the lock
    udlUnexamined  ## the lockfile exists but could not be opened or probed

  UserDaemonLockProbe* = object
    state*: UserDaemonLockState
    detail*: string  ## for ``udlUnexamined``: the OS error, in words

proc probeUserDaemonLock*(lockPath: string): UserDaemonLockProbe =
  ## Take the lock without blocking and give it straight back.
  ##
  ## While this holds the lock (two system calls) a daemon starting on the
  ## same state directory is refused it, exactly as by a live daemon. Call it
  ## only where that is acceptable; `requestUserDaemonShutdown` does so once,
  ## after the lockfile has outlived a closed endpoint by its whole wait.
  when defined(posix):
    # Read-write, as the daemon opens it: some filesystems refuse an
    # exclusive lock through a read-only descriptor.
    var fd = posix.open(lockPath.cstring, O_RDWR or posix.O_CLOEXEC)
    if fd < 0 and (errno == EACCES or errno == EROFS):
      fd = posix.open(lockPath.cstring, O_RDONLY or posix.O_CLOEXEC)
    if fd < 0:
      let err = errno
      if err == ENOENT or err == ENOTDIR:
        return UserDaemonLockProbe(state: udlAbsent)
      return UserDaemonLockProbe(state: udlUnexamined,
        detail: "open failed: " & $strerror(err))
    defer: discard posix.close(fd)
    if probeFlock(fd, ProbeLockExclusive or ProbeLockNonBlocking) == 0:
      # Closing the descriptor releases it.
      return UserDaemonLockProbe(state: udlFree)
    let err = errno
    if err == EWOULDBLOCK or err == EAGAIN:
      return UserDaemonLockProbe(state: udlHeld)
    UserDaemonLockProbe(state: udlUnexamined,
      detail: "flock failed: " & $strerror(err))
  elif defined(windows):
    # Share everything, delete included: this probe must never be the handle
    # that keeps someone else's removal of the file from completing.
    let h = createFileW(newWideCString(lockPath), GENERIC_READ.DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE or ProbeFileShareDelete).DWORD,
      nil, OPEN_EXISTING.DWORD, 0.DWORD, 0)
    if h == INVALID_HANDLE_VALUE:
      let err = int32(osLastError())
      if err == ProbeErrorFileNotFound or err == ProbeErrorPathNotFound:
        return UserDaemonLockProbe(state: udlAbsent)
      # ERROR_ACCESS_DENIED (5) is also what a file whose delete is pending
      # answers; it cannot be told apart from a real denial here.
      return UserDaemonLockProbe(state: udlUnexamined,
        detail: "open failed: Windows error " & $err)
    defer: discard closeHandle(h)
    var overlapped: OVERLAPPED
    if probeLockFileEx(h,
        (ProbeLockfileExclusiveLock or ProbeLockfileFailImmediately).DWORD,
        0.DWORD, 1.DWORD, 0.DWORD, addr overlapped) != 0:
      var release: OVERLAPPED
      discard probeUnlockFileEx(h, 0.DWORD, 1.DWORD, 0.DWORD, addr release)
      return UserDaemonLockProbe(state: udlFree)
    let err = int32(osLastError())
    if err == ProbeErrorLockViolation:
      return UserDaemonLockProbe(state: udlHeld)
    UserDaemonLockProbe(state: udlUnexamined,
      detail: "LockFileEx failed: Windows error " & $err)
  else:
    if fileExists(lockPath):
      UserDaemonLockProbe(state: udlUnexamined,
        detail: "this platform has no daemon lock")
    else:
      UserDaemonLockProbe(state: udlAbsent)

proc userDaemonProcessGone*(pid: int64): bool =
  ## True only when it is ESTABLISHED that no process has this pid. An
  ## unknown pid, a pid we may not inspect, a failed query and (on POSIX) a
  ## process that has exited but whose parent has not yet reaped it all
  ## answer false: the caller is deciding whether to call a stop successful.
  if pid <= 0 or pid > int64(high(int32)):
    return false
  when defined(posix):
    if posix.kill(Pid(pid), 0) == 0:
      return false
    errno == ESRCH
  elif defined(windows):
    let h = probeOpenProcess(ProbeProcessQueryLimitedInformation.DWORD, 0,
      DWORD(pid))
    if h == 0:
      # Not found is ERROR_INVALID_PARAMETER; access denied means it exists.
      return int32(osLastError()) == ProbeErrorInvalidParameter
    defer: discard closeHandle(h)
    var code: DWORD = 0
    if probeGetExitCodeProcess(h, addr code) == 0:
      return false
    int32(code) != ProbeStillActive
  else:
    false
