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

import std/[os, strutils, tempfiles, times, unittest]
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

type Recorder = ref object
  calls: seq[string]
  outcome: RecoveryOutcome

proc recorderFor(r: Recorder): SwitchRecovery =
  result = proc (dir: string): RecoveryOutcome {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      r.calls.add(dir)
      r.outcome

proc rawMarker(stateDir: string; ownerPid: int; ownerBoot: string) =
  ## A marker as some other writer left it, NOT stamped by this process
  ## (`writePendingMarker` always stamps the writer).
  createDir(parentDir(pendingMarkerPath(stateDir)))
  writeFile(pendingMarkerPath(stateDir), render(PendingMarker(
    fromGeneration: "g0", step: ssFlip, status: "in-progress",
    ownerPid: ownerPid, ownerBoot: ownerBoot)))

suite "an apply recovers an interrupted switch first, or refuses":
  test "an add-on bootstrapped with --state-dir: its marker is found and the apply refuses":
    # The guard as production installs it, the add-on's state in a
    # non-default directory (bootstrap --state-dir), the apply using it. At
    # 931aae1ed2 the guard looked only at /var/lib/repro/system and applied
    # straight over this marker.
    let tmp = createTempDir("addon-guard-statedir-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    installPendingSwitchGuard()
    let addonState = tmp / "addon-state"
    createDir(parentDir(pendingMarkerPath(addonState)))
    writeFile(pendingMarkerPath(addonState), "not a pending marker\n")
    var refused = false
    try:
      discard runInfraApply("", options(addonState))
    except EPendingSwitch as e:
      refused = "unreadable" in e.msg
    check refused
    check not dirExists(addonState / "generations")
    check hasPendingMarker(addonState)

  test "a marker whose owner PID is alive but is not the caller is recovered first":
    # PID reuse: the switch that wrote the marker died, and some unrelated
    # live process now has its PID. At 931aae1ed2 "the owner is alive" was
    # enough to skip recovery, so every tick applied on the half switch.
    let tmp = createTempDir("addon-guard-pidreuse-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    let addonState = tmp / "addon-state"
    let rec = Recorder(outcome: RecoveryOutcome(resolved: false,
      lines: @["recorded"]))
    installPendingSwitchGuard(recorderFor(rec))
    defer: installPendingSwitchGuard()
    var written, release: array[2, cint]
    doAssert pipe(written) == 0 and pipe(release) == 0
    let other = fork()
    doAssert other >= 0
    if other == 0:
      writePendingMarker(addonState, PendingMarker(fromGeneration: "g0",
        step: ssFlip, status: "in-progress"))
      var c = 'w'
      discard posix.write(written[1], addr c, 1)
      discard posix.read(release[0], addr c, 1)
      exitnow(0)
    var c: char
    doAssert posix.read(written[0], addr c, 1) == 1
    check markerOwnerLive(readPendingMarker(addonState))   # alive, not us
    var refused = false
    try:
      discard runInfraApply("", options(addonState))
    except EPendingSwitch:
      refused = true
    check rec.calls == @[addonState]
    check refused
    c = 'r'
    doAssert posix.write(release[1], addr c, 1) == 1
    var st: cint
    doAssert waitpid(other, st, 0) == other

  test "an ownerless marker: refused while its old switch may run, recovered otherwise, whatever the clock":
    # d7c86107b wrote markers with no owner, and held the state directory's
    # apply lock (with its PID) for the whole switch. At 918919853d the
    # decision was the marker's mtime against /proc/stat btime. On a host
    # without an RTC, before NTP has synced, a live switch's marker can
    # look older than the boot. The decision is now the lock record.
    let tmp = createTempDir("addon-guard-ownerless-", "")
    defer: removeDir(tmp)
    let dir = tmp / "addon-state"
    let rec = Recorder(outcome: RecoveryOutcome(resolved: true))
    rawMarker(dir, 0, "")
    # The marker looks as old as can be: any wall-clock rule would recover.
    setLastModificationTime(pendingMarkerPath(dir), fromUnix(1))
    # The old switch: holds the state lock and is running.
    var held, release: array[2, cint]
    doAssert pipe(held) == 0 and pipe(release) == 0
    let old = fork()
    doAssert old >= 0
    if old == 0:
      doAssert tryAcquireApplyLock(dir).acquired
      var c = 'h'
      discard posix.write(held[1], addr c, 1)
      discard posix.read(release[0], addr c, 1)
      exitnow(0)
    var c: char
    doAssert posix.read(held[0], addr c, 1) == 1
    let live = checkPendingSwitches(dir, recorderFor(rec))
    check not live.ok
    check ("pid " & $old) in live.why
    check rec.calls.len == 0
    c = 'r'
    doAssert posix.write(release[1], addr c, 1) == 1
    var st: cint
    doAssert waitpid(old, st, 0) == old
    # The holder is gone (its lock record stays, as a crash leaves it), and
    # the marker now looks brand new: recovered all the same.
    setLastModificationTime(pendingMarkerPath(dir),
      fromUnix(getTime().toUnix() + 86400))
    check readApplyLockRecord(dir).present
    check checkPendingSwitches(dir, recorderFor(rec)).ok
    check rec.calls == @[dir]

  test "the add-on's state directory is found through bootstrap's pointer":
    # Bootstrapped with --state-dir X, applied by a deploy-agent tick that
    # runs with its own state directory. At 918919853d the guard looked
    # only at the caller's directory, the resolved one and the default, so
    # the tick applied over the half switch in X.
    let tmp = createTempDir("addon-guard-pointer-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    let addonState = tmp / "addon-x"
    let pointer = tmp / "var-lib-repro" / "addon-state-dir"
    writeAddonStateDirPointer(addonState, pointer)
    check readAddonStateDirPointer(pointer) == addonState
    check readAddonStateDirPointer(tmp / "absent") == ""
    let rec = Recorder(outcome: RecoveryOutcome(resolved: false,
      lines: @["recorded"]))
    installPendingSwitchGuard(recorderFor(rec), pointer = pointer)
    defer: installPendingSwitchGuard()
    rawMarker(addonState, 0, "")
    var refused = false
    try:
      discard runInfraApply("", options(tmp / "agent-state"))
    except EPendingSwitch:
      refused = true
    check refused
    check rec.calls == @[addonState]
    check not dirExists(tmp / "agent-state")

  test "with no boot id (macOS, Windows) the caller's own marker is decided by PID":
    let me = getCurrentProcessId()
    let own = PendingMarker(ownerPid: me, ownerBoot: "")
    check markerOwnedByCaller(own, me, "")
    check not markerOwnedByCaller(own, me + 1, "")
    check not markerOwnedByCaller(PendingMarker(ownerPid: 0), 0, "")
    check not markerOwnedByCaller(PendingMarker(ownerPid: me,
      ownerBoot: "b1"), me, "b2")
    # The caller's own switch, no boot id: left to it, never recovered,
    # so the switch's own apply cannot recurse into recovery.
    let tmp = createTempDir("addon-guard-nobootid-", "")
    defer: removeDir(tmp)
    let dir = tmp / "addon-state"
    rawMarker(dir, me, "")
    let rec = Recorder(outcome: RecoveryOutcome(resolved: false))
    check checkPendingSwitches(dir, recorderFor(rec), pid = me,
      bootId = "").ok
    check rec.calls.len == 0

  test "a marker its live switch owns does not stop that switch's apply":
    let tmp = createTempDir("addon-guard-live-", "")
    defer: removeDir(tmp)
    putEnv(HostApplyLockEnvVar, tmp / "apply.lock")
    defer: delEnv(HostApplyLockEnvVar)
    installPendingSwitchGuard()
    let addonState = tmp / "addon-state"
    # This process is the switch: it wrote the marker and runs the apply.
    writePendingMarker(addonState, PendingMarker(fromGeneration: "g0",
      step: ssFlip, status: "in-progress"))
    discard runInfraApply("", options(addonState))
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
