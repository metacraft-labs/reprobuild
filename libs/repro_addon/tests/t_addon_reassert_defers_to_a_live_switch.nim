## Switch recovery defers to a live switch; it never waits for it (ReproOS
## Add-On Mode §7.2 step 7, §7.5).
##
## `repro-addon-reassert.service` is a oneshot that the switch itself
## (re)starts at step 7, while it holds the host-wide apply lock and while
## its own pending marker is on disk. At 97645920d, recovery took that lock
## with the 600-second deadline, so every switch that restarted the unit
## stalled for ten minutes and the run then reported "degraded". Recovery
## now tries the lock once. A held lock means a switch is live and that
## switch owns its marker, so the outcome is "deferred" and successful.
##
## Real processes: the "switch" is a forked child holding the real host
## lock, and the marker is a real pending marker in a temporary state
## directory. The only test-specific input is `REPRO_HOST_APPLY_LOCK`,
## which points both at a lock file private to this test (honoured
## because the test does not run as root).

import std/[os, tempfiles, times, unittest]
import std/posix

import repro_core/host_apply_lock
import repro_addon/reassert
import repro_addon/static_tree

suite "switch recovery and the host apply lock":
  test "a recovery started during a live switch returns at once, deferred":
    let tmp = createTempDir("addon-reassert-defer-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    # Long enough that a waiting recovery is unmistakable, short enough
    # that the failing run does not stall the suite.
    putEnv(HostApplyLockWaitEnvVar, "20")
    defer: delEnv(HostApplyLockWaitEnvVar)
    let stateDir = tmp / "state"
    writePendingMarker(stateDir, PendingMarker(fromGeneration: "g0",
      step: ssFlip, status: "in-progress"))
    var held, release: array[2, cint]
    doAssert pipe(held) == 0 and pipe(release) == 0
    let switchPid = fork()
    doAssert switchPid >= 0
    if switchPid == 0:
      var lock = acquireHostApplyLock("the switch")
      var c = 'h'
      discard posix.write(held[1], addr c, 1)
      discard posix.read(release[0], addr c, 1)
      lock.release()
      exitnow(0)
    var c: char
    doAssert posix.read(held[0], addr c, 1) == 1
    let start = epochTime()
    let rec = recoverPendingSwitch(stateDir, atBoot = false)
    let elapsed = epochTime() - start
    check elapsed < 5.0
    check rec.resolved
    check rec.deferred
    # The marker is the live switch's; recovery did not touch it.
    check hasPendingMarker(stateDir)
    let report = runAddonReassert(stateDir, atBoot = false)
    check report.status == "deferred"
    c = 'r'
    doAssert posix.write(release[1], addr c, 1) == 1
    var status: cint
    doAssert waitpid(switchPid, status, 0) == switchPid
