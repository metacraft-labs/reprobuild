## Cross-process apply lock (M62 —
## Home-Profile-Generations-And-State.md "Concurrency").
##
## `<state-dir>/locks/apply.lock` mutually excludes concurrent
## `repro home apply` invocations within a user. A second apply that
## starts while a first is in progress must fail closed with
## `EApplyBusy` within the 30-second timeout.
##
## OS-specific code paths:
##
##   Windows: `CreateFileW(lockPath, GENERIC_READ | GENERIC_WRITE,
##            0 /* dwShareMode = 0 → exclusive open */, nil,
##            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)`. A second
##            opener gets ERROR_SHARING_VIOLATION (32) from the same
##            call. The handle is closed on `release` to drop the
##            lock; the file itself is left in place (small price for
##            cross-platform symmetry, matches Git's index.lock-style
##            behavior).
##
##   POSIX:   `open(lockPath, O_CREAT | O_RDWR, 0o600)` followed by
##            `flock(fd, LOCK_EX | LOCK_NB)`. EWOULDBLOCK indicates
##            contention. The fd is closed on `release` (which also
##            drops the flock).
##
## Acquisition strategy: try-acquire in a poll loop (200 ms interval)
## up to `timeoutSeconds` (default 30 s). The loop measures wall-clock
## elapsed time so a single failed try does not extend past the
## timeout.

import std/[os, times]
from repro_core/paths import extendedPath

import ./errors
import ./state_dir

const
  DefaultLockTimeoutSeconds* = 30
  PollIntervalMs* = 200

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
  # Nim's `std/posix` does not expose `flock(2)` uniformly on macOS and
  # Linux, so bind the small sys/file.h surface directly.
  const
    LockExclusive = 2.cint
    LockNonBlocking = 4.cint

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

type
  ApplyLock* = object
    ## RAII-style handle to a held apply lock. `release` (or
    ## `releaseApplyLock`) drops the underlying OS-level lock.
    held*: bool
    lockPath*: string
    when defined(windows):
      handle*: HANDLE
    else:
      fd*: cint

proc tryAcquireOnce(lockPath: string): tuple[ok: bool; lock: ApplyLock] =
  ## Single try-acquire attempt. Returns (true, handle) on success and
  ## (false, _) when the lock is already held by another process.
  ## Any other failure (e.g. permission denied) is surfaced as
  ## an exception.
  let parent = parentDir(lockPath)
  if parent.len > 0:
    createDir(extendedPath(parent))
  when defined(windows):
    let wide = newWideCString(lockPath)
    let h = createFileW(wide,
      GenericRead or GenericWrite,
      0,                                 # no share — exclusive open
      nil,
      OpenAlways,
      FileAttributeNormal,
      nil)
    if cast[int](h) == cast[int](InvalidHandleValue):
      let err = getLastError()
      if err == ErrorSharingViolation:
        return (false, ApplyLock(held: false, lockPath: lockPath,
          handle: InvalidHandleValue))
      raise newException(IOError,
        "CreateFileW(" & lockPath & ") failed, GetLastError=" & $err)
    return (true, ApplyLock(held: true, lockPath: lockPath, handle: h))
  else:
    let fd = posix.open(lockPath.cstring,
      O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    let rc = cFlock(fd, LockExclusive or LockNonBlocking)
    if rc == 0:
      return (true, ApplyLock(held: true, lockPath: lockPath, fd: fd))
    let lockErr = errno
    discard posix.close(fd)
    if lockErr == EWOULDBLOCK or lockErr == EAGAIN:
      return (false, ApplyLock(held: false, lockPath: lockPath, fd: -1))
    raise newException(IOError,
      "flock(" & lockPath & ") failed, errno=" & $lockErr)

proc acquireApplyLockAt*(lockPath: string;
                         timeoutSeconds = DefaultLockTimeoutSeconds): ApplyLock =
  ## Acquire the apply lock at `lockPath`, polling at 200 ms
  ## intervals until `timeoutSeconds` of wall-clock time elapses.
  ## Raises `EApplyBusy` on timeout.
  let deadline = getTime() + initDuration(seconds = timeoutSeconds)
  while true:
    let (ok, lock) = tryAcquireOnce(lockPath)
    if ok:
      return lock
    let now = getTime()
    if now >= deadline:
      raiseApplyBusy(lockPath, timeoutSeconds)
    sleep(PollIntervalMs)

proc acquireApplyLock*(stateDir: string;
                      timeoutSeconds = DefaultLockTimeoutSeconds): ApplyLock =
  ## Convenience: acquire the apply lock at
  ## `<state-dir>/locks/apply.lock`.
  ensureStateDir(stateDir)
  acquireApplyLockAt(applyLockPath(stateDir), timeoutSeconds)

proc releaseApplyLock*(lock: var ApplyLock) =
  ## Drop the OS-level lock. Safe to call on an already-released
  ## handle. The on-disk file is intentionally left in place so a
  ## later `acquireApplyLock` can take ownership without recreating
  ## the path; the lock state lives in the kernel handle, not in the
  ## file's mere existence.
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

# NOTE: we deliberately do NOT bind a `=destroy` hook for `ApplyLock`.
# A user-defined destructor would conflict with the compiler's
# implicit one (Nim 2.x rejects late re-binding). Callers MUST call
# `releaseApplyLock` explicitly; the M62 deliverable contract makes
# that obvious in the API surface, and the apply pipeline (M63) wraps
# the lock in a `try/finally` around the whole apply transaction.
