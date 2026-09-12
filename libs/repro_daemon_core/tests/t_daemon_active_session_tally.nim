## The daemon's active-session count is MAINTAINED, and it must equal what a
## from-disk recount would say.
##
## WHY IT IS MAINTAINED AT ALL. `statusFor` needs one integer: how many
## sessions are active. It used to compute it by walking `sessions/` and
## parsing every record ever written. Records are never pruned, so that walk
## grows without bound with use: measured on a developer machine with 2,108
## records (9.2 MB, oldest seven weeks old) it cost 37.6 ms of a 76 ms
## `repro build` no-op -- about half that invocation's fixed cost and the
## largest single term in it. A `status` request is issued on EVERY build, by
## the daemon-staleness check in `startUserDaemon`, so every build paid it.
##
## WHAT THIS FILE DEFENDS IS THE EQUALITY, NOT THE SPEED. A timing assertion
## here would be worthless -- the cost is proportional to how many records
## the host happens to have accumulated, so it is near zero on a fresh
## machine and tens of milliseconds on a used one, and that is exactly why
## the regression went unnoticed. The property that makes the optimisation
## legitimate is that the maintained number and the recounted number agree
## after any sequence of session writes. Every case below asserts that
## equality; none asserts a duration.
##
## MOCK POLICY: no mocks, and none may be added. Records are written through
## `writeSessionRecord` -- the daemon's single write funnel for creation and
## for every state transition -- into a real temporary state directory, and
## the reference count is a real directory walk. A fake filesystem would
## remove the only thing under test, which is whether the in-memory tally
## tracks what is actually on disk.
##
## THE RESTART CASE IS THE ONE THAT MATTERS MOST. A tally that counted only
## the sessions its own process observed would read LOW after a dev
## self-restart, and a status consumer that believes there are no active
## sessions where there are is worse than a slow one: `restartCandidateReady`
## uses this number to decide whether it may restart out from under live
## work. `resetTallyAsIfRestarted` reproduces that by clearing the in-memory
## state and re-asking, which is what a fresh daemon process does.

import std/[os, strutils, tempfiles, unittest]

import repro_daemon_core

proc tempConfig(root: string): UserDaemonConfig =
  result = defaultUserDaemonConfig(devMode = false)
  result.stateDir = root
  result.endpoint = root / "daemon.sock"

proc session(id, state: string): UserDaemonSession =
  result.sessionId = id
  result.projectRoot = "/tmp/project"
  result.mode = "build"
  result.state = state
  result.startedAtUnix = 1_700_000_000
  result.endedAtUnix = 0
  result.exitCode = 0

proc resetTallyAsIfRestarted(config: UserDaemonConfig) =
  ## Force the next query to prime from disk, the way a fresh daemon process
  ## does. Achieved by pointing the cache at a different directory and back,
  ## which is the same mechanism a differently-configured `stateDir` uses.
  var other = config
  other.stateDir = config.stateDir / "elsewhere"
  createDir(other.stateDir)
  discard activeSessionTallyFor(other)

suite "daemon active-session tally equals a from-disk recount":
  test "an empty state directory counts zero, both ways":
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    check activeSessionTallyFor(config) == 0
    check countActiveSessionRecordsFromDisk(config) == 0

  test "after N opens and M terminations the tally is N-M":
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    const N = 12
    const M = 5
    for i in 0 ..< N:
      writeSessionRecord(config, session("s" & $i, "running"))
    check activeSessionTallyFor(config) == N
    check countActiveSessionRecordsFromDisk(config) == N
    # Terminate M of them THROUGH THE SAME FUNNEL a state transition uses:
    # the record is rewritten with a terminal state, never deleted.
    for i in 0 ..< M:
      writeSessionRecord(config, session("s" & $i, "completed"))
    checkpoint("tally=" & $activeSessionTallyFor(config) &
      " fromDisk=" & $countActiveSessionRecordsFromDisk(config))
    check activeSessionTallyFor(config) == N - M
    check countActiveSessionRecordsFromDisk(config) == N - M

  test "re-terminating an already-terminal session does not double-decrement":
    # The decrement is driven by a state TRANSITION, not by the write. A
    # writer that repeats a terminal write -- which the daemon does, e.g. a
    # cancel racing a completion -- must not drive the tally negative.
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    writeSessionRecord(config, session("only", "running"))
    check activeSessionTallyFor(config) == 1
    for _ in 0 ..< 4:
      writeSessionRecord(config, session("only", "completed"))
    check activeSessionTallyFor(config) == 0
    check countActiveSessionRecordsFromDisk(config) == 0

  test "a session that goes back to an active state counts again":
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    writeSessionRecord(config, session("w", "watching"))
    check activeSessionTallyFor(config) == 1
    writeSessionRecord(config, session("w", "completed"))
    check activeSessionTallyFor(config) == 0
    writeSessionRecord(config, session("w", "idle"))
    check activeSessionTallyFor(config) == 1
    check countActiveSessionRecordsFromDisk(config) == 1

  test "every active state is counted and every other state is not":
    # Denominator: if the predicate silently stopped recognising a state,
    # the counts would still agree with each other while both being wrong.
    # This pins the vocabulary itself against a from-disk recount.
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    let active = ["accepted", "running", "cancelling", "watching", "idle"]
    let terminal = ["completed", "failed", "cancelled", "unsupported"]
    for i, st in active:
      writeSessionRecord(config, session("a" & $i, st))
    for i, st in terminal:
      writeSessionRecord(config, session("t" & $i, st))
    checkpoint("active=" & $active.len & " terminal=" & $terminal.len &
      " tally=" & $activeSessionTallyFor(config))
    check activeSessionTallyFor(config) == active.len
    check countActiveSessionRecordsFromDisk(config) == active.len

  test "a restarted daemon re-primes from disk and does not read low":
    # THE CASE THE OPTIMISATION COULD GET WRONG. A tally that started at zero
    # in each process would report no active sessions here, and
    # `restartCandidateReady` would then restart out from under live work.
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    for i in 0 ..< 7:
      writeSessionRecord(config, session("live" & $i, "running"))
    for i in 0 ..< 3:
      writeSessionRecord(config, session("done" & $i, "completed"))
    check activeSessionTallyFor(config) == 7

    resetTallyAsIfRestarted(config)
    checkpoint("after simulated restart: tally=" &
      $activeSessionTallyFor(config))
    check activeSessionTallyFor(config) == 7
    check countActiveSessionRecordsFromDisk(config) == 7

    # ... and it keeps tracking correctly after re-priming, rather than
    # being right once and then drifting.
    writeSessionRecord(config, session("live0", "completed"))
    check activeSessionTallyFor(config) == 6
    check countActiveSessionRecordsFromDisk(config) == 6

  test "records written before the tally was ever asked are still counted":
    # Priming is lazy, so the first question may arrive after writes that
    # happened through a different code path (or a previous process). Those
    # must be picked up by the prime rather than missed.
    let root = createTempDir("repro-tally-", "")
    defer: removeDir(root)
    let config = tempConfig(root)
    createDir(root / "sessions")
    # Written directly, as a previous daemon process would have left them.
    for i in 0 ..< 4:
      writeFile(root / "sessions" / ("pre" & $i & ".session"),
        "sessionId=pre" & $i & "\nmode=build\nstate=running\n" &
        "startedAtUnix=1700000000\nendedAtUnix=0\nexitCode=0\n")
    resetTallyAsIfRestarted(config)
    check activeSessionTallyFor(config) == 4
    check countActiveSessionRecordsFromDisk(config) == 4
