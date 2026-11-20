## The network guard's lock (ReproOS Add-On Mode §4.5 step 4, §5.3; §13
## decisions 102, 107, 124; threat model T62).
##
## Every change of a pending marker's guard fields is made while holding an
## exclusive ``flock(2)`` on ``/run/repro-addon-guard.lock``: the apply that
## owns the switch, the timer's ``revert-network`` and every recovery
## serialise on it, so a timer that fires as the owner disarms is ordered
## one way or the other, never both. It sits beside the host apply lock in
## ``/run``, which only root can write, and it is separate from that lock:
## the actor that switches or reverts holds the host apply lock throughout,
## while the guard lock is held only across one read and the write it
## decides.
##
## Whichever guard actor finds it absent creates it (decision 124): root,
## mode 0600, opened ``O_RDWR`` so that no unprivileged process can open it,
## let alone hold it. ``/run`` is empty after a reboot, so boot recovery is
## usually the one that creates it. The open never follows a symbolic link
## and refuses anything at the path that is not a regular file owned by
## this process's user with mode 0600: a file planted there (by root, the
## only one who can) does not redirect the lock to somewhere else. A late
## actor that recreates it after uninstall removed it leaves a harmless
## empty file that the next reboot clears.

import std/[os, posix]

type
  GuardLockError* = object of CatchableError

  GuardLock* = object
    fd: cint
    held: bool

const
  DefaultGuardLockPath* = "/run/repro-addon-guard.lock"

var guardLockPath* = DefaultGuardLockPath
  ## Where the lock lives. Only a unit test, which runs unprivileged and
  ## must not touch ``/run``, points it elsewhere.

var OpenNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc c_flock(fd: cint; op: cint): cint {.importc: "flock",
  header: "<sys/file.h>".}
const
  LockEx = 2.cint      # LOCK_EX
  LockNb = 4.cint      # LOCK_NB
  LockUn = 8.cint      # LOCK_UN

proc openGuardLockFd(path: string): cint =
  ## Open (creating it when absent) the lock file, refusing anything that
  ## is not a regular file of this user with mode 0600.
  let fd = posix.open(path.cstring, O_RDWR or O_CREAT or OpenNoFollow or
                      O_CLOEXEC, Mode(0o600))
  if fd < 0:
    raise newException(GuardLockError, "the guard lock " & path &
      " cannot be opened read-write (" & osErrorMsg(osLastError()) &
      "; a symbolic link is refused)")
  var st: Stat
  if fstat(fd, st) != 0:
    discard posix.close(fd)
    raise newException(GuardLockError, "the guard lock " & path &
      ": fstat failed")
  if not S_ISREG(st.st_mode) or st.st_uid != geteuid():
    discard posix.close(fd)
    raise newException(GuardLockError, "the guard lock " & path &
      " is not a regular file owned by uid " & $geteuid() &
      "; refusing to lock through it")
  if (int(st.st_mode) and 0o7777) != 0o600:
    # Created by this open under a umask, or left with other bits: the
    # mode is the lock's own, so it is set rather than refused.
    if fchmod(fd, Mode(0o600)) != 0:
      discard posix.close(fd)
      raise newException(GuardLockError, "the guard lock " & path &
        " cannot be made mode 0600")
  fd

proc acquireGuardLock*(path = guardLockPath): GuardLock =
  ## Take the guard lock, waiting for as long as another holder keeps it:
  ## the wait is not bounded (spec §4.5 step 4, ``revert-network`` step 2).
  let fd = openGuardLockFd(path)
  while c_flock(fd, LockEx) != 0:
    if errno != EINTR:
      discard posix.close(fd)
      raise newException(GuardLockError, "flock on " & path & " failed: " &
        osErrorMsg(osLastError()))
  GuardLock(fd: fd, held: true)

proc tryAcquireGuardLock*(path = guardLockPath): tuple[lock: GuardLock;
                                                         ok: bool] =
  ## Take the guard lock only if it is free now.
  let fd = openGuardLockFd(path)
  if c_flock(fd, LockEx or LockNb) != 0:
    discard posix.close(fd)
    return (GuardLock(), false)
  (GuardLock(fd: fd, held: true), true)

proc release*(l: var GuardLock) =
  if l.held:
    discard c_flock(l.fd, LockUn)
    discard posix.close(l.fd)
    l.held = false

template withGuardLock*(body: untyped) =
  ## Run ``body`` holding the guard lock.
  var guardLockHeld = acquireGuardLock()
  try:
    body
  finally:
    guardLockHeld.release()

proc removeGuardLock*(path = guardLockPath): bool =
  ## Uninstall's last guard act (spec §6.4 step 5; §13 decision 124): the
  ## lock file goes, its absence tolerated. True when one was removed.
  try:
    if symlinkExists(path) or fileExists(path):
      removeFile(path)
      return true
  except OSError:
    discard
  false
