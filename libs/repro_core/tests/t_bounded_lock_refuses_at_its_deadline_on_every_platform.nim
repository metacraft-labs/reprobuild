## A deadline-bounded lock acquisition refuses at its deadline on every
## platform, and reports contention exactly once.
##
## `file_lock.acquireExclusiveLockWithin` backs the host-wide apply lock
## (`repro_core/host_apply_lock`), which Windows takes too: the elevated
## broker session holds it, and it lives at `%ProgramData%\repro-apply.lock`.
## The first Windows branch of that procedure ignored the deadline and the
## busy hook and blocked until the holder let go, so the zero-wait
## `tryAcquireHostApplyLock` that switch recovery relies on could never
## answer "held" there; it waited instead. Every POSIX test of the lock
## forks, so none of them ran on Windows to notice.
##
## These cases run in one process on purpose. A share-mode-0 `CreateFileW`
## handle (Windows) and an `flock` on a separate open file description
## (POSIX) each exclude a second acquisition even from the process that
## holds the first, so the holder and the contender can be the same test
## without a fork, and the cases mean the same thing on both platforms.
## No mocks: the real lock files under a private temporary directory, and
## `REPRO_HOST_APPLY_LOCK` pointing the host lock at one of them so the test
## never touches the host's real lock.

import std/[os, strutils, tempfiles, times, unittest]

import repro_core/file_lock
import repro_core/host_apply_lock

suite "deadline-bounded lock acquisition":
  test "a held lock refuses a zero deadline at once and reports busy once":
    let tmp = createTempDir("bounded-lock-", "")
    defer: removeDir(tmp)
    let path = tmp / "held.lock"
    var holder = acquireExclusiveFileLock(path)
    defer: releaseExclusiveFileLock(holder)
    var busy = 0
    let hook: LockBusyHook = proc () {.closure, gcsafe.} = inc busy
    let start = epochTime()
    var refused = false
    try:
      var l = acquireExclusiveLockWithin(path, 0, onBusy = hook)
      releaseExclusiveFileLock(l)
    except ELockTimeout as e:
      refused = true
      check e.lockPath == path
      check "refusing to wait longer" in e.msg
    check refused
    check busy == 1
    # A zero deadline is one attempt, not a wait for the holder.
    check epochTime() - start < 5.0

  test "a held lock is retried until the deadline, with one busy report":
    let tmp = createTempDir("bounded-lock-", "")
    defer: removeDir(tmp)
    let path = tmp / "held.lock"
    var holder = acquireExclusiveFileLock(path)
    defer: releaseExclusiveFileLock(holder)
    var busy = 0
    let hook: LockBusyHook = proc () {.closure, gcsafe.} = inc busy
    let start = epochTime()
    expect ELockTimeout:
      var l = acquireExclusiveLockWithin(path, 350, onBusy = hook)
      releaseExclusiveFileLock(l)
    let waited = epochTime() - start
    check waited >= 0.3
    check waited < 10.0
    check busy == 1

  test "a free lock is taken without a busy report, and excludes others":
    let tmp = createTempDir("bounded-lock-", "")
    defer: removeDir(tmp)
    let path = tmp / "free.lock"
    var busy = 0
    let hook: LockBusyHook = proc () {.closure, gcsafe.} = inc busy
    var l = acquireExclusiveLockWithin(path, 0, onBusy = hook)
    check busy == 0
    var other: ReproFileLock
    check not tryAcquireExclusiveFileLock(path, other)
    releaseExclusiveFileLock(l)
    check tryAcquireExclusiveFileLock(path, other)
    releaseExclusiveFileLock(other)

  test "the zero-wait host lock answers held instead of waiting":
    let tmp = createTempDir("bounded-lock-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    var holder = acquireExclusiveFileLock(tmp / "apply.lock")
    let start = epochTime()
    var r = tryAcquireHostApplyLock("contender", privileged = false)
    check "another apply is changing this host" in r.holder
    check not hostApplyLockHeldHere()
    check epochTime() - start < 5.0
    releaseExclusiveFileLock(holder)
    r = tryAcquireHostApplyLock("contender", privileged = false)
    check r.holder.len == 0
    check hostApplyLockHeldHere()
    r.lock.release()
    check not hostApplyLockHeldHere()
