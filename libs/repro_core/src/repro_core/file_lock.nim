## Cross-process file exclusion shared by publication and cache owners.
## One owned, noninheritable OS handle; acquisition errors never grant access.
import std/os
from ./paths import extendedPath

when defined(windows):
  type
    ProviderLockHandle = pointer
    ProviderLockDword = uint32
    ProviderLockWideString = WideCString

  const
    ProviderLockInvalidHandle = cast[ProviderLockHandle](-1'i64)
    ProviderLockGenericRead = 0x80000000'u32
    ProviderLockGenericWrite = 0x40000000'u32
    ProviderLockOpenAlways = 4'u32
    ProviderLockFileAttributeNormal = 0x80'u32
    ProviderLockSharingViolation = 32'u32

  proc providerLockCreateFileW(
      path: ProviderLockWideString;
      desiredAccess, shareMode: ProviderLockDword;
      securityAttributes: pointer;
      creationDisposition, flagsAndAttributes: ProviderLockDword;
      templateFile: ProviderLockHandle): ProviderLockHandle
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}

  proc providerLockCloseHandle(handle: ProviderLockHandle): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc providerLockGetLastError(): ProviderLockDword
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}

else:
  import std/posix

  const
    ProviderLockExclusive = 2.cint
    ProviderLockNonBlocking = 4.cint

  proc providerLockFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

type ReproFileLock* = object
  held: bool
  when defined(windows):
    handle: ProviderLockHandle
  else:
    fd: cint

proc acquireExclusiveFileLock*(lockPath: string): ReproFileLock =
  createDir(extendedPath(parentDir(lockPath)))
  when defined(windows):
    let wide = newWideCString(lockPath)
    while true:
      let handle = providerLockCreateFileW(
        wide,
        ProviderLockGenericRead or ProviderLockGenericWrite,
        0,
        nil,
        ProviderLockOpenAlways,
        ProviderLockFileAttributeNormal,
        nil)
      if cast[int](handle) != cast[int](ProviderLockInvalidHandle):
        return ReproFileLock(held: true, handle: handle)
      let error = providerLockGetLastError()
      if error != ProviderLockSharingViolation:
        raise newException(IOError,
          "CreateFileW(" & lockPath & ") failed, GetLastError=" & $error)
      sleep(50)
  else:
    # Close-on-exec: a lock fd inherited by a child keeps the flock held for
    # as long as that child lives, so a long-lived process spawned while the
    # lock is held (a daemon started inside a build) would hold it forever.
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    while providerLockFlock(fd, ProviderLockExclusive) != 0:
      if errno == EINTR:
        continue
      let lockError = errno
      discard posix.close(fd)
      raise newException(IOError,
        "flock(" & lockPath & ") failed, errno=" & $lockError)
    return ReproFileLock(held: true, fd: fd)

proc tryAcquireExclusiveFileLock*(lockPath: string;
                                lock: var ReproFileLock): bool =
  ## Non-blocking `acquireExclusiveFileLock`: true and `lock` held when the
  ## lock was free, false (nothing held) when another holder has it.
  createDir(extendedPath(parentDir(lockPath)))
  when defined(windows):
    let handle = providerLockCreateFileW(
      newWideCString(lockPath),
      ProviderLockGenericRead or ProviderLockGenericWrite,
      0,
      nil,
      ProviderLockOpenAlways,
      ProviderLockFileAttributeNormal,
      nil)
    if cast[int](handle) != cast[int](ProviderLockInvalidHandle):
      lock = ReproFileLock(held: true, handle: handle)
      return true
    let error = providerLockGetLastError()
    if error != ProviderLockSharingViolation:
      raise newException(IOError,
        "CreateFileW(" & lockPath & ") failed, GetLastError=" & $error)
    false
  else:
    # Close-on-exec: a lock fd inherited by a child keeps the flock held for
    # as long as that child lives, so a long-lived process spawned while the
    # lock is held (a daemon started inside a build) would hold it forever.
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    while providerLockFlock(fd, ProviderLockExclusive or
        ProviderLockNonBlocking) != 0:
      if errno == EINTR:
        continue
      let lockError = errno
      discard posix.close(fd)
      if lockError == EWOULDBLOCK or lockError == EAGAIN:
        return false
      raise newException(IOError,
        "flock(" & lockPath & ") failed, errno=" & $lockError)
    lock = ReproFileLock(held: true, fd: fd)
    true

proc releaseExclusiveFileLock*(lock: var ReproFileLock) =
  if not lock.held:
    return
  when defined(windows):
    if cast[int](lock.handle) != cast[int](ProviderLockInvalidHandle):
      discard providerLockCloseHandle(lock.handle)
      lock.handle = ProviderLockInvalidHandle
  else:
    if lock.fd >= 0:
      discard posix.close(lock.fd)
      lock.fd = -1
  lock.held = false

