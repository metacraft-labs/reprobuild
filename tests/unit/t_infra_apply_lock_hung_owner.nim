## `repro infra apply` — cross-process recovery from a HUNG lock owner.
##
## The library-local suite in
## ``libs/repro_infra/tests/t_smoke_repro_infra.nim`` pins the reclaim
## POLICY against synthetic lock records. This gate pins the same
## behaviour against a REAL second process: it starts a child that takes
## the apply lock for a temporary state directory and then either hangs
## (never beats) or keeps working (beats on a slow cycle), and asserts
## what an operator running `repro infra apply` on the same host would
## see.
##
## Why this matters: dead-owner reclaim alone leaves the host wedged.
## The wedges seen in practice had owners that were alive but stuck — a
## long-running apply on a Windows host held the lock for four hours
## having consumed roughly seven seconds of CPU in total. `kill(pid, 0)`
## reports such a process ALIVE, so a liveness-only rule refuses every
## subsequent apply forever and the host silently stops converging.
##
## The safety property this gate exists to protect is the opposite one:
## a lock whose owner is STILL MAKING PROGRESS must never be reclaimed,
## because two concurrent applies would both mutate system state. The
## "beats on a slow cycle" case is the load-bearing test — the owner's
## heartbeat is deliberately allowed to go stale between beats, and the
## acquirer must still refuse because it observes a beat land while it
## is watching.
##
## No mocks: a real child process, real pids, a real kill.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_infra

const
  HolderDirEnv = "REPRO_TEST_APPLY_LOCK_HOLDER_DIR"
  HolderBeatEnv = "REPRO_TEST_APPLY_LOCK_HOLDER_BEAT_MS"

# ---------------------------------------------------------------------------
# Child mode. Re-executing THIS binary with `HolderDirEnv` set turns it
# into the lock holder, so the gate needs no external helper program and
# works identically on every platform. This block must stay ahead of the
# suites below — the child must never run them.
# ---------------------------------------------------------------------------

block childMode:
  let holderDir = getEnv(HolderDirEnv)
  if holderDir.len == 0:
    break childMode
  var policy = defaultApplyLockPolicy()
  policy.reclaimConfirmMs = 0
  if not acquireApplyLock(holderDir, policy):
    quit(97)
  var beatMs = 0
  try: beatMs = parseInt(getEnv(HolderBeatEnv, "0"))
  except ValueError: beatMs = 0
  while true:
    if beatMs > 0:
      sleep(beatMs)
      refreshApplyLock(holderDir)
    else:
      # A hung apply: alive, holding the lock, making no progress.
      sleep(25)

proc startHolder(stateDir: string; beatMs: int): Process =
  ## Start the lock holder as a child process. The environment is set on
  ## this process only for the duration of the spawn so the child
  ## inherits it and later children do not.
  putEnv(HolderDirEnv, stateDir)
  putEnv(HolderBeatEnv, $beatMs)
  try:
    result = startProcess(getAppFilename(), args = [], options = {})
  finally:
    delEnv(HolderDirEnv)
    delEnv(HolderBeatEnv)

proc waitForOwner(stateDir: string; pid: int; timeoutMs = 10_000): bool =
  var waited = 0
  while waited < timeoutMs:
    if applyLockOwner(stateDir) == pid:
      return true
    sleep(25)
    waited += 25
  false

proc waitUntilHeartbeatOlderThan(stateDir: string; seconds: int64;
                                 timeoutMs = 10_000): bool =
  ## Block until the holder's recorded heartbeat is more than `seconds`
  ## old, so the caller's acquire attempt starts from a provably stale
  ## reading rather than a lucky one.
  var waited = 0
  while waited < timeoutMs:
    let rec = readApplyLockRecord(stateDir)
    if rec.present and rec.heartbeatAt > 0 and
       getTime().toUnix() - rec.heartbeatAt > seconds:
      return true
    sleep(25)
    waited += 25
  false

proc stopHolder(p: Process) =
  ## SIGKILL-equivalent: the holder never gets to release the lock, which
  ## is exactly the dead-owner shape we want left behind. `waitForExit`
  ## reaps the child so its pid stops reading as alive.
  try: kill(p)
  except OSError: discard
  discard waitForExit(p)
  close(p)

suite "repro infra apply: a hung lock owner does not wedge the host":

  setup:
    let sd = createTempDir("repro-hungowner-", "")
    ensureSystemStateDir(sd)

  teardown:
    removeDir(sd)

  test "a live owner that has stopped making progress is reclaimed":
    let holder = startHolder(sd, beatMs = 0)
    defer: stopHolder(holder)
    let holderPid = processID(holder)
    check waitForOwner(sd, holderPid)
    check processAlive(holderPid)
    # The owner is ALIVE, so dead-owner reclaim cannot help here.
    check not acquireApplyLock(sd, ApplyLockPolicy(
      heartbeatStaleSeconds: 3600, maxAgeSeconds: 0, reclaimConfirmMs: 0))
    # Once its heartbeat is older than the configured window it is hung.
    check waitUntilHeartbeatOlderThan(sd, 1)
    let acq = tryAcquireApplyLock(sd, ApplyLockPolicy(
      heartbeatStaleSeconds: 1, maxAgeSeconds: 0, reclaimConfirmMs: 400))
    check acq.acquired
    check acq.reclaim == alrStaleHeartbeat
    check acq.previousOwner == holderPid
    check applyLockOwner(sd) == getCurrentProcessId()
    # We took the lock; we did NOT kill the owner. The operator is told
    # which pid to check on via the recorded `reclaimed-from`.
    check readApplyLockRecord(sd).reclaimedFrom == holderPid
    check processAlive(holderPid)

  test "an owner that beats while we watch keeps the lock":
    # The holder beats on a cycle LONGER than the stale window, so its
    # heartbeat goes stale between beats. A naive "stale ⇒ reclaim" rule
    # would steal the lock from a perfectly healthy apply. The second
    # observation is what prevents that.
    let holder = startHolder(sd, beatMs = 1500)
    defer: stopHolder(holder)
    let holderPid = processID(holder)
    check waitForOwner(sd, holderPid)
    check waitUntilHeartbeatOlderThan(sd, 1)
    let before = readApplyLockRecord(sd)
    let acq = tryAcquireApplyLock(sd, ApplyLockPolicy(
      heartbeatStaleSeconds: 1, maxAgeSeconds: 0, reclaimConfirmMs: 3000))
    check not acq.acquired
    check applyLockOwner(sd) == holderPid
    # It really did beat during the window — the refusal was earned.
    check readApplyLockRecord(sd).beats > before.beats

  test "a long phase is not reclaimed while its units of work keep landing":
    # THE safety property. The holder simulates a long phase made of
    # units of work: it beats once per unit, on a cycle comparable to
    # the staleness window, and keeps going for many times that window.
    # Every acquire attempt across the whole phase must be refused —
    # "long" must never be mistaken for "stuck".
    let holder = startHolder(sd, beatMs = 700)
    defer: stopHolder(holder)
    let holderPid = processID(holder)
    check waitForOwner(sd, holderPid)
    let policy = ApplyLockPolicy(
      heartbeatStaleSeconds: 1, maxAgeSeconds: 0, reclaimConfirmMs: 1500)
    let started = getTime()
    var attempts = 0
    while getTime() - started < initDuration(seconds = 6):
      check not acquireApplyLock(sd, policy)
      inc attempts
    # The phase ran for six times the staleness window and was probed
    # repeatedly throughout.
    check attempts >= 3
    check applyLockOwner(sd) == holderPid
    check readApplyLockRecord(sd).beats > 0

  test "the escape hatch takes the lock from a healthy, beating owner":
    let holder = startHolder(sd, beatMs = 100)
    defer: stopHolder(holder)
    let holderPid = processID(holder)
    check waitForOwner(sd, holderPid)
    # Nothing automatic gets past a beating owner.
    check not acquireApplyLock(sd, ApplyLockPolicy(
      heartbeatStaleSeconds: 1, maxAgeSeconds: 0, reclaimConfirmMs: 1500))
    var forced = defaultApplyLockPolicy()
    forced.forceUnlock = true
    let acq = tryAcquireApplyLock(sd, forced)
    check acq.acquired
    check acq.reclaim == alrForced
    check acq.previousOwner == holderPid

  test "a lock left behind by a killed owner is still reclaimed as dead":
    # The Phase-1 behaviour must keep working: no heartbeat reasoning is
    # needed once the owner is genuinely gone.
    let holder = startHolder(sd, beatMs = 0)
    let holderPid = processID(holder)
    check waitForOwner(sd, holderPid)
    stopHolder(holder)
    check not processAlive(holderPid)
    check fileExists(applyLockPath(sd))
    let acq = tryAcquireApplyLock(sd, ApplyLockPolicy(
      heartbeatStaleSeconds: 3600, maxAgeSeconds: 0, reclaimConfirmMs: 0))
    check acq.acquired
    check acq.reclaim == alrDeadOwner
    check acq.previousOwner == holderPid
    check applyLockOwner(sd) == getCurrentProcessId()
