## Two places where the host-wide apply lock protects an add-on host from
## the deploy agent's own tick (ReproOS Add-On Mode §7.7, §5.2;
## System-Profile-And-Infra-Apply.md validation criteria).
##
## 1. An apply never runs on top of an interrupted switch. `runInfraApply`
##    (every deploy-agent tick and operator apply) takes the host lock, then
##    asks the add-on layer's guard. If a pending marker is on the host and
##    its owner is no longer running, the switch is recovered first, and the
##    apply refuses when recovery does not resolve it. At 9c51db884 there was
##    no guard: the tick applied straight over the half switch.
## 2. `repro store gc` takes the host lock. A tick realising a closure holds
##    no store root on it until it commits, so a collection during the tick
##    could delete what the tick is about to bind. At 9c51db884 gc took no
##    lock and ran during a tick.
##
## Real processes and the real lock. The pending marker is a real marker in
## a temporary state directory, and the guard is the one production installs,
## pointed at that directory. The unrecoverable marker is a corrupt one,
## which recovery refuses before it touches anything on the host. That keeps
## this test from driving systemctl or /etc on the machine running it.
## `REPRO_HOST_APPLY_LOCK` points every process at a lock private to this
## test, which is honoured because the test does not run as root. The store
## collector is not given a store: the assertion is that it refuses on the
## lock before it opens one.

import std/[os, strutils, tempfiles, unittest]
import std/posix

import repro_core/host_apply_lock
import repro_elevation
import repro_infra
import repro_addon/cli
import repro_addon/reassert
import repro_addon/static_tree

proc options(stateDir: string): ApplyOptions =
  result.stateDir = stateDir
  result.hostIdentity = "host-lock-guard-test"
  result.reproExe = "/usr/bin/false"
  result.elevationMode = emNoElevate
  result.noPreview = true

suite "an apply recovers an interrupted switch first, or refuses":
  test "a marker nobody can recover: the apply refuses and writes nothing":
    let tmp = createTempDir("addon-guard-refuse-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    let addonState = tmp / "addon-state"
    installPendingSwitchGuard(addonState)
    defer: installPendingSwitchGuard()
    createDir(parentDir(pendingMarkerPath(addonState)))
    writeFile(pendingMarkerPath(addonState), "not a pending marker\n")
    var refused = false
    try:
      discard runInfraApply("", options(tmp / "tick-state"))
    except EPendingSwitch as e:
      refused = "unreadable" in e.msg
    check refused
    check not dirExists(tmp / "tick-state")
    check hasPendingMarker(addonState)

  test "a marker its live switch owns does not stop that switch's apply":
    let tmp = createTempDir("addon-guard-live-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    let addonState = tmp / "addon-state"
    installPendingSwitchGuard(addonState)
    defer: installPendingSwitchGuard()
    # This process is the switch: it wrote the marker and runs the apply.
    writePendingMarker(addonState, PendingMarker(fromGeneration: "g0",
      step: ssFlip, status: "in-progress"))
    discard runInfraApply("", options(tmp / "switch-state"))
    check hasPendingMarker(addonState)

suite "store gc and the host apply lock":
  test "gc refuses while a tick holds the lock, before touching the store":
    let tmp = createTempDir("addon-gc-lock-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    putEnv(HostApplyLockWaitEnvVar, "0")
    defer: delEnv(HostApplyLockWaitEnvVar)
    var held, release: array[2, cint]
    doAssert pipe(held) == 0 and pipe(release) == 0
    let tick = fork()
    doAssert tick >= 0
    if tick == 0:
      var lock = acquireHostApplyLock("a tick realising a closure")
      var c = 'h'
      discard posix.write(held[1], addr c, 1)
      discard posix.read(release[0], addr c, 1)
      lock.release()
      exitnow(0)
    var c: char
    doAssert posix.read(held[0], addr c, 1) == 1
    let errPath = tmp / "gc.stderr"
    let gc = fork()
    doAssert gc >= 0
    if gc == 0:
      let fd = posix.open(errPath.cstring, O_WRONLY or O_CREAT or O_TRUNC,
        Mode(0o600))
      discard dup2(fd, 2)
      exitnow(cint(runAddonStoreCli(@["gc"])))
    var st: cint
    doAssert waitpid(gc, st, 0) == gc
    check WIFEXITED(st) and WEXITSTATUS(st) == 1
    let err = readFile(errPath)
    check "another apply is changing this host" in err
    check ("pid " & $tick) in err
    c = 'r'
    doAssert posix.write(release[1], addr c, 1) == 1
    doAssert waitpid(tick, st, 0) == tick
