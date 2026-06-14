## B3 P2 risk #1: system-scope apply lock.
##
## Adapted from
## ``libs/repro_home_generations/src/repro_home_generations/locks.nim``.
## Same OS-level primitive (Windows ``CreateFileW`` with ``dwShareMode = 0``
## / POSIX ``flock(2)`` with ``LOCK_EX | LOCK_NB``) but keyed against the
## system-scope state directory.
##
## Lock path: ``<state>/locks/apply.lock``. The default timeout is
## 30 seconds, matching the home-scope contract and B3's deliverable
## risk-#1 callout.
##
## The lock is wrapped around ``applyTransitions`` + ``recordGeneration``
## + ``confirmStagedGeneration`` in ``pipeline.nim``. The CLI also
## exposes it from ``switch`` / ``rollback`` so a concurrent
## ``reproos-rebuild apply`` cannot interleave with a switch-in-progress.
##
## NOTE: this module DOES NOT re-export the home-scope ``EApplyBusy``
## exception; the system-scope pipeline raises its own ``ESystemApplyBusy``
## (see ``errors.nim``).

import std/[os, times]
from repro_core/paths import extendedPath

import ./errors

const
  DefaultLockTimeoutSeconds* = 30
  PollIntervalMs* = 200
  LocksDirName* = "locks"
  ApplyLockName* = "apply.lock"

when defined(windows):
  type
    HANDLE = pointer
    DWORD = uint32
    LPCWSTR = WideCString
    LPSECURITY_ATTRIBUTES = pointer
    BOOL = int32

  const
    InvalidHandleValue: HANDLE = cast[HANDLE](-1'i64)
    GenericRead: DWORD = 0x80000000'u32
    GenericWrite: DWORD = 0x40000000'u32
    OpenAlways: DWORD = 4
    FileAttributeNormal: DWORD = 0x80
    ErrorSharingViolation: DWORD = 32

  proc createFileW(lpFileName: LPCWSTR; dwDesiredAccess: DWORD;
                   dwShareMode: DWORD;
                   lpSecurityAttributes: LPSECURITY_ATTRIBUTES;
                   dwCreationDisposition: DWORD;
                   dwFlagsAndAttributes: DWORD;
                   hTemplateFile: HANDLE): HANDLE
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}

  proc closeHandle(h: HANDLE): BOOL
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc getLastError(): DWORD
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}

else:
  import std/posix
  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

type
  SystemApplyLock* = object
    ## RAII-style handle for the system-scope apply lock. Call
    ## ``releaseApplyLock`` to drop the OS-level handle. The file at
    ## ``lockPath`` is left on disk so subsequent acquirers do not race
    ## on its creation.
    held*: bool
    lockPath*: string
    when defined(windows):
      handle*: HANDLE
    else:
      fd*: cint

proc locksDir*(stateDir: string): string =
  stateDir / LocksDirName

proc applyLockPath*(stateDir: string): string =
  locksDir(stateDir) / ApplyLockName

proc ensureLocksDir(stateDir: string) =
  let p = locksDir(stateDir)
  if not dirExists(extendedPath(p)):
    createDir(extendedPath(p))

proc tryAcquireOnce(lockPath: string): tuple[ok: bool; lock: SystemApplyLock] =
  let parent = parentDir(lockPath)
  if parent.len > 0:
    if not dirExists(extendedPath(parent)):
      createDir(extendedPath(parent))
  when defined(windows):
    let wide = newWideCString(lockPath)
    let h = createFileW(wide,
      GenericRead or GenericWrite,
      0,
      nil,
      OpenAlways,
      FileAttributeNormal,
      nil)
    if cast[int](h) == cast[int](InvalidHandleValue):
      let err = getLastError()
      if err == ErrorSharingViolation:
        return (false, SystemApplyLock(held: false, lockPath: lockPath,
          handle: InvalidHandleValue))
      raise newException(IOError,
        "CreateFileW(" & lockPath & ") failed, GetLastError=" & $err)
    return (true, SystemApplyLock(held: true, lockPath: lockPath, handle: h))
  else:
    let fd = posix.open(lockPath.cstring,
      O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    let rc = cFlock(fd, LockExclusive or LockNonBlocking)
    if rc == 0:
      return (true, SystemApplyLock(held: true, lockPath: lockPath, fd: fd))
    let lockErr = errno
    discard posix.close(fd)
    if lockErr == EWOULDBLOCK or lockErr == EAGAIN:
      return (false, SystemApplyLock(held: false, lockPath: lockPath, fd: -1))
    raise newException(IOError,
      "flock(" & lockPath & ") failed, errno=" & $lockErr)

proc acquireApplyLockAt*(lockPath: string;
                         timeoutSeconds = DefaultLockTimeoutSeconds): SystemApplyLock =
  ## Acquire the system apply lock at ``lockPath`` (polling at
  ## ``PollIntervalMs``-millisecond intervals up to
  ## ``timeoutSeconds`` of wall-clock time). Raises
  ## ``ESystemApplyBusy`` on timeout.
  let deadline = getTime() + initDuration(seconds = timeoutSeconds)
  while true:
    let (ok, lock) = tryAcquireOnce(lockPath)
    if ok:
      return lock
    let now = getTime()
    if now >= deadline:
      raiseSystemApplyBusy(lockPath, timeoutSeconds)
    sleep(PollIntervalMs)

proc acquireApplyLock*(stateDir: string;
                      timeoutSeconds = DefaultLockTimeoutSeconds): SystemApplyLock =
  ## Convenience: acquire ``<state>/locks/apply.lock``.
  if not dirExists(extendedPath(stateDir)):
    createDir(extendedPath(stateDir))
  ensureLocksDir(stateDir)
  acquireApplyLockAt(applyLockPath(stateDir), timeoutSeconds)

proc releaseApplyLock*(lock: var SystemApplyLock) =
  ## Drop the OS-level lock. Idempotent.
  if not lock.held:
    return
  when defined(windows):
    if cast[int](lock.handle) != cast[int](InvalidHandleValue):
      discard closeHandle(lock.handle)
      lock.handle = InvalidHandleValue
  else:
    if lock.fd >= 0:
      discard posix.close(lock.fd)
      lock.fd = -1
  lock.held = false
