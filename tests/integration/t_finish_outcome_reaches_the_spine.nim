## The supervisor's own account of WHY an execution ended has to survive the
## trip to RunQuota's execution spine, and `timeout` has to be one of the
## words it can produce.
##
## ## What this pins
##
## `repro_runquota.finishOutcome` is the only place reprobuild names a
## termination. RunQuota imposes no deadlines — it cannot observe one — so a
## deadline is a fact this client holds alone: if `finishOutcome` does not say
## it, the store can never learn it. It used to not say it. `timedOut` was
## computed by the process backend and then collapsed into a plain cancel,
## and because the kill SIGNAL travelled in its own independent wire field,
## the daemon's mapping resolved that finish through its signal test and
## wrote `signalled` — true, and useless to a reader asking why the work
## stopped. `timeout` was a word the schema knew and no client could write.
##
## SINCE `LeaseFinish`, A CONCLUSION AND ITS EVIDENCE TRAVEL AS ONE VALUE, so
## there is no separate signal field for a mapping to be rescued by. Arms (2)
## and (3) below are both kills delivered by a signal, and each has to be
## NAMED correctly by `finishOutcome` or its row is wrong — which is what
## makes this file the gate on that mapping rather than a description of it.
##
## ## NO MOCKS, AND NOTHING IN THIS FILE WRITES A ROW
##
## Every arm runs the real `runquotad` over a real Unix-domain socket, takes
## real leases through `repro_runquota`'s public session API, launches real
## children, and reads the rows back through `readSharedStore` — the same
## client path `repro stats` renders from. The terminations asserted below
## were chosen by the shipped `finishOutcome` and mapped by the shipped
## daemon; this file only decides how each child dies.
##
## ## ENUMERATED, NOT WITNESSED
##
## The three executions land in ONE store and are asserted as a SET keyed by
## stats id. A one-element expectation ("some row says timeout") asserts
## existence and is satisfied by a mapping that returns `timeout` for
## everything; the set is not. Concretely:
##
##   * `exited` — a child that exits 0 on its own.
##   * `signalled` — a child cancelled that honours SIGTERM promptly. This is
##     the arm that fails if `timedOut` is tested too broadly, e.g. if the
##     `cancelled` case were folded into the deadline the way the deadline
##     used to be folded into `cancelled`.
##   * `timeout` — a child that IGNORES SIGTERM, so `cancelAndWait`'s
##     three-second grace expires and the backend reports `timedOut`. This is
##     the arm that fails on the pre-fix mapping, which reported it as
##     `leaseFinishCancelled` and landed on `signalled` — indistinguishable
##     from the arm above it.
##
## The third child is the only producer of `timedOut` reachable from
## reprobuild at all: none of the three leased wait sites in
## `libs/repro_runquota/src/repro_runquota.nim` passes a timeout to
## `waitForCompletion`, so `cancelAndWait`'s grace deadline is the deadline
## this client holds. Driving it through a synthetic `ProcessCompletion`
## instead would assert the mapping and prove nothing about whether any real
## execution can reach it.

import std/[os, osproc, streams, tables, times, unittest]

import repro_runquota
import repro_runquota/stats_query

import repro_test_support

proc repoRoot(): string = getCurrentDir()

proc pathPresent(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

type SpineDaemon = object
  process: Process
  socket: string

proc startSpineDaemon(root: string): SpineDaemon =
  ## A real `runquotad` with capture ON (no flag needed — capture is the
  ## default) and its own observation database, so the rows read back are
  ## this test's and only this test's.
  ##
  ## THE ENDPOINT DIRECTORY IS CREATED 0700 BY THIS TEST: `runquotad`
  ## refuses a rendezvous directory whose mode it did not verify as
  ## created, so inheriting the umask's would be a startup failure rather
  ## than a permission it silently tightened.
  let daemonBin = requireRunQuotaDaemonBin(repoRoot())
  let endpointDir = root / "ep"
  createDir(endpointDir)
  setFilePermissions(endpointDir, {fpUserRead, fpUserWrite, fpUserExec})
  let socketPath = endpointDir / "d.sock"
  let stateDir = root / "state"
  createDir(stateDir)
  let process = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--host-identity-file", stateDir / "host-id",
    "--observation-db", stateDir / "observations.db",
    "--ambient-sample-interval-millis", "0"
  ], options = {poStdErrToStdOut})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 400:
    if pathPresent(socketPath):
      return SpineDaemon(process: process, socket: socketPath)
    sleep(25)
  # THE DAEMON'S OWN WORDS, not a bare "it did not start". A startup
  # refusal that reports only the missing socket sends the next reader
  # looking in the wrong place.
  var diagnostic = ""
  if not process.running:
    try: diagnostic = process.outputStream.readAll() except CatchableError: discard
  process.terminate()
  discard process.waitForExit(5000)
  process.close()
  raise newException(OSError,
    "runquotad socket did not appear at " & socketPath &
      (if diagnostic.len > 0: "; daemon said: " & diagnostic else: ""))

proc stop(daemon: var SpineDaemon) =
  if daemon.process.running:
    daemon.process.terminate()
    discard daemon.process.waitForExit(5000)
  if daemon.process.running:
    daemon.process.kill()
    discard daemon.process.waitForExit(5000)
  daemon.process.close()

proc leasedRequest(statsId: string): ReproResourceRequest =
  ReproResourceRequest(
    label: statsId,
    commandStatsId: statsId,
    cpuMilli: 1000'u32,
    memoryBytes: 128'u64 * 1024'u64 * 1024'u64)

proc shellCommand(script: string): ReproCommandSpec =
  ReproCommandSpec(
    argv: @["/bin/sh", "-c", script],
    cwd: getCurrentDir(),
    env: @[],
    stdoutLimit: 64 * 1024,
    stderrLimit: 64 * 1024)

proc terminationsByStatsKey(): Table[string, string] =
  ## The spine, read through the SHIPPED client path. Polls for a MINIMUM
  ## number of rows: the observation writer drains on a tick, so a query
  ## issued immediately after a finish can legitimately see nothing yet, and
  ## polling upward cannot turn a present row into an absent one.
  let deadline = epochTime() + 30.0
  while true:
    result = initTable[string, string]()
    let view = readSharedStore()
    for entry in view.executions:
      result[entry.statsKey] = entry.termination
    if result.len >= 3 or epochTime() >= deadline:
      return
    sleep(200)

suite "a finish outcome reaches the spine as the word it deserves":
  when defined(posix):
    test "exited, signalled and timeout are three distinguishable rows":
      # A SHORT ROOT, DELIBERATELY. `sun_path` is 104 bytes on macOS, and
      # the suite's scratch TMPDIR is already deep enough that a
      # `createTempDir` name under it puts the endpoint over the limit —
      # which surfaces as a daemon that never binds rather than as a path
      # error.
      let root = getTempDir() / ("rq-fo-" & $getCurrentProcessId())
      removeDir(root)
      createDir(root)
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      var daemon = startSpineDaemon(root)
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(root)

      var session = openRunQuotaSession("finish-outcome-spine", "0.1.0")

      # (1) THE ORDINARY EXIT. Present so the two kill arms below are read
      #     against a store that demonstrably records the boring case too:
      #     a mapping that answered `timeout` unconditionally would satisfy
      #     the timeout arm on its own.
      block:
        var running = session.startWithRunQuota(
          leasedRequest("spine_exited"), shellCommand("exit 0"))
        let execution = running.finishCompleted()
        check execution.exited
        check execution.exitCode == 0
        check execution.leaseFinishedSent

      # (2) A CANCEL THE CHILD HONOURS. `cancelAndWait` SIGTERMs the group;
      #     this child does not trap it, so it dies well inside the grace
      #     period and the completion carries `cancelled` WITHOUT `timedOut`.
      #
      #     THIS ARM IS WHY `finishOutcome` NAMES THIS A CRASH. The child
      #     dies OF the SIGTERM, so the completion carries `signaled` too;
      #     the old code called the finish `leaseFinishCancelled` and put
      #     the signal in a separate wire field, which the daemon's mapping
      #     read first and recorded as `signalled`. `cancelled()` has no
      #     field to carry a signal in now, so a mapping that still said
      #     `cancelled` here would land this row on `refused`, and this
      #     assertion is what catches it.
      block:
        var running = session.startWithRunQuota(
          leasedRequest("spine_cancelled"), shellCommand("sleep 30"))
        # Let the child install itself before the signal, so the cancel is
        # delivered to a running process rather than racing its exec.
        sleep(300)
        let execution = running.cancelAndWait()
        check execution.signaled
        check execution.leaseFinishedSent

      # (3) A CANCEL THE CHILD IGNORES. `trap "" TERM` makes SIGTERM a no-op,
      #     so `cancelAndWait`'s three-second deadline expires, the backend
      #     escalates to SIGKILL and reports `timedOut`. Before the fix this
      #     produced a plain cancel and the daemon's signal test wrote
      #     `signalled` — the same word as arm (2), from a different cause.
      block:
        var running = session.startWithRunQuota(
          leasedRequest("spine_timed_out"),
          shellCommand("trap '' TERM; sleep 30"))
        sleep(300)
        let execution = running.cancelAndWait()
        check execution.leaseFinishedSent
        # NOT `execution.signaled`. `buildCompletion` populates neither
        # `exited` nor `signaled` on its deadline branch — the kill is in
        # the raw wait status and nothing decodes it there. That is the
        # discarded fact `finishSignal` recovers, and asserting the
        # undecoded field here would pin the discard instead.
        check not execution.exited

      session.close()

      let terminations = terminationsByStatsKey()

      # ALL THREE ROWS ARE PRESENT. Without this the assertions below could
      # be satisfied by rows the daemon never wrote — an absent key reads as
      # an absent expectation, not as a failure, in a lookup-per-assertion
      # shape.
      check terminations.len == 3
      check terminations.hasKey("spine_exited")
      check terminations.hasKey("spine_cancelled")
      check terminations.hasKey("spine_timed_out")

      # THE SET, NOT A WITNESS.
      check terminations["spine_exited"] == "exited"
      check terminations["spine_cancelled"] == "signalled"
      check terminations["spine_timed_out"] == "timeout"

      # AND THE THREE ARE DISTINCT, stated separately so a future edit that
      # collapsed two of them has to break an assertion whose name says what
      # was lost rather than only an equality that reads as a typo.
      var distinct_terminations: seq[string] = @[]
      for _, value in terminations:
        if value notin distinct_terminations:
          distinct_terminations.add(value)
      check distinct_terminations.len == 3

      # THE STORE HELD EVERY ONE OF THEM. A finish the daemon refused would
      # leave a gap here rather than a wrong word, and the two failures want
      # different fixes.
      let view = readSharedStore()
      check figuresArePresentable(view.state)
      check view.loss.known
      check view.loss.contradictoryExecutions == 0
      check view.sampleCount == 3
