## Cross-process file exclusion shared by publication and cache owners.
## One owned, noninheritable OS handle; acquisition errors never grant access.
import std/[os, strutils, times]
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
  var ProviderLockOpenDirectory {.importc: "O_DIRECTORY",
                                  header: "<fcntl.h>".}: cint
  var ProviderLockNoFollow {.importc: "O_NOFOLLOW",
                             header: "<fcntl.h>".}: cint

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


# ---------------------------------------------------------------------------
# Deadline-bounded acquisition that names the holder (where the OS can).
# ---------------------------------------------------------------------------

type
  ELockTimeout* = object of IOError
    ## The lock was still held by another process at the deadline.
    lockPath*: string
    holderPids*: seq[int]   ## from /proc/locks; empty when not knowable

  LockBusyHook* = proc () {.closure, gcsafe.}
    ## Called once, the first time an acquisition finds the lock held.

when not defined(windows):
  proc flockHolderPids*(fd: cint): seq[int] =
    ## The PIDs /proc/locks names as holding a granted FLOCK on the file
    ## open at ``fd``, excluding this process. A line matches only on the
    ## device (major and minor, compared as numbers: the kernel's minimum
    ## field width is not a fixed one) AND the inode. Empty where
    ## /proc/locks is unavailable (non-Linux) or names nobody.
    var st: Stat
    if fstat(fd, st) != 0: return
    let ino = uint64(st.st_ino)
    let dev = uint64(st.st_dev)
    let major = ((dev shr 8) and 0xfff'u64) or ((dev shr 32) and not 0xfff'u64)
    let minor = (dev and 0xff'u64) or ((dev shr 12) and not 0xff'u64)
    let me = getCurrentProcessId()
    var text = ""
    try: text = readFile("/proc/locks")
    except IOError, OSError: return
    for line in text.splitLines():
      let f = line.splitWhitespace()
      # "N: FLOCK ADVISORY WRITE <pid> <maj>:<min>:<ino> <start> <end>";
      # a blocked waiter's line carries "->" after the ordinal and is
      # skipped by the field-1 test.
      if f.len < 6 or f[1] != "FLOCK": continue
      let id = f[5].split(':')
      if id.len != 3: continue
      try:
        if fromHex[uint64](id[0]) != major or fromHex[uint64](id[1]) != minor or
            parseBiggestUInt(id[2]) != ino:
          continue
        let pid = parseInt(f[4])
        if pid != me and pid notin result: result.add(pid)
      except ValueError: discard

  proc describeHolders(pids: seq[int]): string =
    if pids.len == 0: "a process /proc/locks does not name"
    else: "pid " & pids.join(", pid ")

proc acquireExclusiveLockWithin*(lockPath: string; deadlineMs: int;
                                 directory = false;
                                 onBusy: LockBusyHook = nil;
                                 mode = 0o600): ReproFileLock =
  ## Take an exclusive ``flock`` on ``lockPath`` (a lock file created with
  ## ``mode``, never through a symbolic link, or with ``directory`` the
  ## directory itself, so no file is added to it), retrying non-blocking
  ## until ``deadlineMs`` has passed.
  ## A lock still held then raises ``ELockTimeout`` naming the holder's
  ## PID, rather than waiting on a holder that may never let go.
  ## ``onBusy`` runs once, at the first refusal.
  ##
  ## Windows keeps the same contract with the exclusion it has: a
  ## share-mode-0 handle (``tryAcquireExclusiveFileLock``), where a
  ## sharing violation is the "held" answer. Windows has no ``/proc/locks``,
  ## so ``ELockTimeout.holderPids`` is empty there. ``mode`` is a POSIX
  ## permission and has no Windows meaning; the file inherits its
  ## directory's ACL. ``directory`` locks are refused by name: only the
  ## apt realisation (Linux-only) takes them, and ``CreateFileW`` opens a
  ## directory only with ``FILE_FLAG_BACKUP_SEMANTICS``, which the lock
  ## handle does not use, so it would fail anyway, less legibly.
  when defined(windows):
    discard mode
    if directory:
      raise newException(IOError, "locking the directory " & lockPath &
        " itself is not supported on Windows")
    let start = epochTime()
    var told = false
    while true:
      var lock: ReproFileLock
      if tryAcquireExclusiveFileLock(lockPath, lock):
        return lock
      if not told:
        told = true
        if onBusy != nil: onBusy()
      if int((epochTime() - start) * 1000) >= deadlineMs:
        var e = newException(ELockTimeout, lockPath & " is still locked " &
          "by another process (Windows does not name it) after " &
          $deadlineMs & " ms; refusing to wait longer")
        e.lockPath = lockPath
        raise e
      sleep(100)
  else:
    if not directory:
      createDir(extendedPath(parentDir(lockPath)))
    let flags = if directory: O_RDONLY or O_CLOEXEC or ProviderLockNoFollow or
                  ProviderLockOpenDirectory
                else: O_RDWR or O_CREAT or O_CLOEXEC or ProviderLockNoFollow
    let fd = posix.open(lockPath.cstring, flags, Mode(mode))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") to lock it failed, errno=" & $errno)
    let start = epochTime()
    var told = false
    while true:
      if providerLockFlock(fd, ProviderLockExclusive or
          ProviderLockNonBlocking) == 0:
        return ReproFileLock(held: true, fd: fd)
      let err = errno
      if err == EINTR: continue
      if err != EWOULDBLOCK and err != EAGAIN:
        discard posix.close(fd)
        raise newException(IOError,
          "flock(" & lockPath & ") failed, errno=" & $err)
      if not told:
        told = true
        if onBusy != nil: onBusy()
      if int((epochTime() - start) * 1000) >= deadlineMs:
        let holders = flockHolderPids(fd)
        discard posix.close(fd)
        var e = newException(ELockTimeout, lockPath & " is still locked " &
          "by " & describeHolders(holders) & " after " & $deadlineMs &
          " ms; refusing to wait longer")
        e.lockPath = lockPath
        e.holderPids = holders
        raise e
      sleep(100)
