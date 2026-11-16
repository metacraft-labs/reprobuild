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

# The holder lookup reads three Linux /proc files. Their parsers are pure
# and compiled on every platform, so the formats are tested everywhere.

type LockDevice* = tuple[major, minor: uint64]
  ## A device number split into major and minor, as /proc prints it.

proc deviceOfStDev*(dev: uint64): LockDevice =
  ## Split a ``st_dev`` the way glibc's ``gnu_dev_major``/``gnu_dev_minor``
  ## do (https://man7.org/linux/man-pages/man3/makedev.3.html): the major
  ## is bits 8-19 and 44-63, the minor bits 0-7 and 20-43, each 32 bits.
  (((dev shr 8) and 0xfff'u64) or ((dev shr 32) and 0xffff_f000'u64),
   (dev and 0xff'u64) or ((dev shr 12) and 0xffff_ff00'u64))

proc fdinfoMountId*(fdinfoText: string): int =
  ## The ``mnt_id:`` of a ``/proc/<pid>/fdinfo/<fd>`` text: the ID of the
  ## mount the open file is on (proc_pid_fdinfo(5),
  ## https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html; the
  ## field exists since Linux 3.15). -1 when absent or malformed.
  result = -1
  for line in fdinfoText.splitLines():
    if line.startsWith("mnt_id:"):
      try: return parseInt(line["mnt_id:".len .. ^1].strip())
      except ValueError: return -1

proc mountinfoDevice*(mountinfoText: string; mountId: int;
                      device: var LockDevice): bool =
  ## The ``major:minor`` (decimal, field 3) of the ``/proc/self/mountinfo``
  ## line whose mount ID (field 1) is ``mountId``
  ## (https://man7.org/linux/man-pages/man5/proc_pid_mountinfo.5.html).
  ## It is the ``st_dev`` of the mount's superblock. False when no line
  ## names that mount.
  if mountId < 0: return false
  for line in mountinfoText.splitLines():
    let f = line.splitWhitespace()
    if f.len < 3: continue
    try:
      if parseInt(f[0]) != mountId: continue
      let mm = f[2].split(':')
      if mm.len != 2: return false
      device = (parseBiggestUInt(mm[0]).uint64,
                parseBiggestUInt(mm[1]).uint64)
      return true
    except ValueError: continue
  false

proc procLocksFlockHolders*(locksText: string; devices: openArray[LockDevice];
                            ino: uint64; excludePid: int): seq[int] =
  ## The PIDs a ``/proc/locks`` text names as holding a granted FLOCK on
  ## inode ``ino`` of any of ``devices``, without ``excludePid`` and without
  ## repeats (proc_locks(5),
  ## https://man7.org/linux/man-pages/man5/proc_locks.5.html). A line names
  ## the file as ``<maj>:<min>:<ino>`` with major and minor in hex, printed
  ## to a minimum width that is not a fixed one, so they are compared as
  ## numbers. A blocked waiter's line carries ``->`` after the ordinal and
  ## is not a holder.
  for line in locksText.splitLines():
    let f = line.splitWhitespace()
    # "N: FLOCK ADVISORY WRITE <pid> <maj>:<min>:<ino> <start> <end>"
    if f.len < 6 or f[1] != "FLOCK": continue
    let id = f[5].split(':')
    if id.len != 3: continue
    try:
      let dev: LockDevice = (fromHex[uint64](id[0]), fromHex[uint64](id[1]))
      if dev notin devices or parseBiggestUInt(id[2]).uint64 != ino:
        continue
      let pid = parseInt(f[4])
      if pid != excludePid and pid notin result: result.add(pid)
    except ValueError: discard

when not defined(windows):
  proc flockHolderPids*(fd: cint): seq[int] =
    ## The PIDs /proc/locks names as holding a granted FLOCK on the file
    ## open at ``fd``, excluding this process. A line matches on the inode
    ## AND a device that is either ``fstat``'s or that of the mount the fd
    ## is on (its ``mnt_id`` in ``/proc/self/fdinfo/<fd>``, looked up in
    ## ``/proc/self/mountinfo``).
    ##
    ## The second device is needed on btrfs: ``stat`` reports the
    ## subvolume's anonymous device (a fresh ``0:N`` per subvolume), while
    ## /proc/locks prints the superblock's ``s_dev``, which is the device
    ## mountinfo gives. Matching ``fstat`` alone named nobody there
    ## (reprobuild-pm issue 2026-11-15, lock-holder lookup names nobody on
    ## btrfs). Where the fd's mount cannot be found, ``fstat``'s device is
    ## the only one tried. Empty where /proc/locks is unavailable
    ## (non-Linux) or names nobody.
    var st: Stat
    if fstat(fd, st) != 0: return
    var devices = @[deviceOfStDev(uint64(st.st_dev))]
    try:
      let mountId = fdinfoMountId(readFile("/proc/self/fdinfo/" & $fd))
      var mountDevice: LockDevice
      if mountinfoDevice(readFile("/proc/self/mountinfo"), mountId,
          mountDevice) and mountDevice notin devices:
        devices.add(mountDevice)
    except IOError, OSError: discard
    var text = ""
    try: text = readFile("/proc/locks")
    except IOError, OSError: return
    procLocksFlockHolders(text, devices, uint64(st.st_ino),
      getCurrentProcessId())

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

# ---------------------------------------------------------------------------
# Shared (reader) acquisition.
#
# A SHARED lock coexists with any number of other shared holders and excludes
# every exclusive one, in both directions: while any shared holder exists,
# `tryAcquireExclusiveFileLock` answers false and `acquireExclusiveFileLock`
# waits; while an exclusive holder exists, `acquireSharedFileLock` waits.
#
#   * POSIX: `flock(LOCK_SH)` (https://man7.org/linux/man-pages/man2/flock.2.html).
#     The lock belongs to the open file description, so it is released when
#     the holder closes it OR DIES — a killed process never leaves it held.
#   * Windows: the share-mode exclusion the exclusive half already uses. A
#     shared holder opens the file for GENERIC_READ with FILE_SHARE_READ, so
#     further shared opens succeed while the exclusive open (GENERIC_READ |
#     GENERIC_WRITE, share mode 0) fails with a sharing violation, and vice
#     versa (https://learn.microsoft.com/en-us/windows/win32/fileio/creating-and-opening-files).
#     The handle is closed by the OS when the process dies, so the same
#     crash-release property holds.
#
# Release either kind with `releaseExclusiveFileLock`: releasing is closing
# the handle, whatever kind of lock it carried.
# ---------------------------------------------------------------------------

when defined(windows):
  const ProviderLockFileShareRead = 0x00000001'u32
else:
  const ProviderLockShared = 1.cint

proc acquireSharedFileLock*(lockPath: string;
                            onBusy: LockBusyHook = nil): ReproFileLock =
  ## Take a SHARED lock on `lockPath` (created on demand), waiting for as long
  ## as an exclusive holder has it. `onBusy` runs once, the first time the
  ## lock is found held exclusively — so a caller can say what it is waiting
  ## for instead of hanging silently. Raises on any failure other than
  ## "held"; a failure never grants the lock.
  createDir(extendedPath(parentDir(lockPath)))
  when defined(windows):
    let wide = newWideCString(lockPath)
    var told = false
    while true:
      let handle = providerLockCreateFileW(
        wide,
        ProviderLockGenericRead,
        ProviderLockFileShareRead,
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
      if not told:
        told = true
        if onBusy != nil: onBusy()
      sleep(50)
  else:
    # Close-on-exec for the reason `acquireExclusiveFileLock` gives: a child
    # that inherited the fd would hold the lock for its own lifetime.
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT or O_CLOEXEC,
      Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    # Non-blocking first, only so `onBusy` can be told; then block.
    while providerLockFlock(fd, ProviderLockShared or
        ProviderLockNonBlocking) != 0:
      let err = errno
      if err == EINTR: continue
      if err != EWOULDBLOCK and err != EAGAIN:
        discard posix.close(fd)
        raise newException(IOError,
          "flock(" & lockPath & ", LOCK_SH) failed, errno=" & $err)
      if onBusy != nil: onBusy()
      while providerLockFlock(fd, ProviderLockShared) != 0:
        let waitErr = errno
        if waitErr == EINTR: continue
        discard posix.close(fd)
        raise newException(IOError,
          "flock(" & lockPath & ", LOCK_SH) failed, errno=" & $waitErr)
      break
    return ReproFileLock(held: true, fd: fd)

proc isHeld*(lock: ReproFileLock): bool =
  ## Whether `lock` currently holds its file (it was acquired and not yet
  ## released).
  lock.held
