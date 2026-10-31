## A batched RunQuota launch that fails part-way does not lose what it owns.
##
## WHY. ``offerWithRunQuotaBatch`` submits a chunk of candidates in one
## round trip and then starts the granted ones one by one. Until 2026-10-16 a
## failure part-way through -- a launch the parent itself could not perform,
## a missing decision, a denial that hit the static-capacity deadline --
## propagated straight out of the call. Every child it had already started,
## every queued lease and every granted lease it had not reached yet went with
## the discarded partial result: nobody killed or reaped the children and
## nobody released the leases. The scheduler then marked the staged actions
## failed, and the build's session close was refused by the daemon with
## ``session still owns leases`` -- which replaced the real launch error as
## the build's only diagnostic (reprobuild-specs issue
## 2026-10-08-batched-launch-loses-partial-lease-and-child-ownership).
##
## The engine's ``finally`` had the second half of that defect: a cleanup
## step or the session close that raised while another exception was already
## unwinding erased the exception that started the unwinding.
##
## THE CONTRACT (RunQuota-Protocol-And-Client-Libraries.md, "Ownership Across
## a Batched Client Launch"): before unwinding, the client cancels queued
## requests, releases granted work it has not started, cancels and waits for
## each child it launched, and releases their leases; the initiating
## diagnostic survives, and a failed close is an ADDITIONAL failure that does
## not erase it.
##
## WHAT THIS RUNS. A real ``runquotad`` on a private endpoint, sized by
## ``--cpu-milli`` so its decisions are known in advance, and real children:
## this binary re-executed in a fixture mode. The partial failure is a
## genuine parent-side launch failure -- a command with an empty argv, which
## the process backend refuses with ``empty argv`` after the lease has been
## granted and marked starting. The lease inventory is read back from the
## daemon over a connection of the test's own (the ``leases`` inspection
## subject), so "empty" is the daemon's statement, not the client's belief.
##
## The engine-level cases drive ``runBuild`` through its inline RunQuota
## session. The second one needs a session close that genuinely fails while an
## exception is unwinding; it gets one by stopping the daemon from inside a
## progress callback that then raises -- the daemon really goes away, so the
## cleanup's lease traffic and the close really fail.
##
## NO MOCKS: every decision is the daemon's, every child is a real process.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix

import runquota_client
import repro_build_engine
import repro_core
import repro_depfile
import repro_runquota

import repro_test_support

# ---------------------------------------------------------------------------
# Fixture modes
# ---------------------------------------------------------------------------

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

const lingerMs = 1500
  ## How long a "linger" child runs before it records that it SURVIVED. The
  ## checks below wait past it, so a child that was orphaned rather than
  ## drained leaves ``<tag>.survived`` behind.

proc fixtureMain(args: seq[string]) =
  # "linger" <marker-dir> <tag>  -- record pid, sleep, record survival
  # "quick"  <marker-dir> <tag>  -- record completion and exit 0
  if args.len < 4:
    quit 64
  let dir = args[2]
  let tag = args[3]
  case args[1]
  of "linger":
    fixtureWrite(dir / (tag & ".started"), $getCurrentProcessId())
    sleep(lingerMs)
    fixtureWrite(dir / (tag & ".survived"), $epochTime())
  of "quick":
    fixtureWrite(dir / (tag & ".done"), $epochTime())
  else:
    quit 64
  # The engine cases declare a recognized depfile; write one when asked.
  if args.len == 6:
    fixtureWrite(args[4], tag & "\n")
    fixtureWrite(args[5], "out/" & tag & ".txt:\n")

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

# ---------------------------------------------------------------------------
# Daemon and inspection
# ---------------------------------------------------------------------------

proc startDaemon(repoRoot, root: string; cpuMilli: int): Process =
  let socket = runquotaSocketEndpoint("repro-batchown-" &
    $getCurrentProcessId() & "-" & root.extractFilename)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
  putEnv("RUNQUOTA_SOCKET", socket)
  result = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--cpu-milli", $cpuMilli, "--memory-bytes", $(8'u64 shl 30),
    "--host-identity-file", root / "host-id", "--no-write-stats",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  for _ in 0 ..< 400:
    if isRunQuotaDaemonReachable():
      return
    sleep(25)
  raise newException(OSError, "runquotad did not become reachable")

proc stopDaemon(daemon: var Process) =
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(5000)
  daemon.close()
  delEnv("RUNQUOTA_SOCKET")

proc daemonLeases(): seq[JsonNode] =
  ## Every lease the daemon holds, in any state (queued included), read over
  ## a connection of the test's own. Raises rather than returning empty: an
  ## inventory that could silently read as "nothing held" would make the
  ## emptiness checks below vacuous.
  var client = runquota_client.connectDefault()
  try:
    let doc = parseJson(client.inspectionJson("leases"))
    for lease in doc["leases"]:
      result.add(lease)
  finally:
    client.close()

proc describe(leases: seq[JsonNode]): string =
  for lease in leases:
    result.add("\n  lease " & $lease{"id"}.getBiggestInt() & " " &
      lease{"label"}.getStr() & " state=" & lease{"state"}.getStr() &
      " child=" & $lease{"child_process_id"}.getBiggestInt())

proc processAlive(pid: int): bool =
  ## A drained child has been REAPED, so even a zombie counts as alive here.
  when defined(posix):
    kill(Pid(pid), 0) == 0
  else:
    false

# ---------------------------------------------------------------------------
# Library-level cases
# ---------------------------------------------------------------------------

proc request(label: string; cpuMilli: uint32): ReproResourceRequest =
  ReproResourceRequest(label: label, commandStatsId: label,
    cpuMilli: cpuMilli, memoryBytes: 64'u64 shl 20)

proc fixtureCommand(mode, dir, tag: string): ReproCommandSpec =
  ReproCommandSpec(argv: @[getAppFilename(), "fixture-action", mode, dir, tag],
    cwd: dir, stdoutLimit: 64 * 1024, stderrLimit: 64 * 1024)

proc emptyArgvCommand(dir: string): ReproCommandSpec =
  ## A command the parent cannot launch: the process backend refuses it with
  ## ``empty argv`` after the lease was granted and marked starting.
  ReproCommandSpec(argv: @[], cwd: dir)

type BatchFailure = object
  raised: bool
  isRunQuotaError: bool
  isDeadlock: bool
  message: string

proc offerExpectingFailure(session: ReproRunQuotaSession;
                           requests: openArray[ReproResourceRequest];
                           commands: openArray[ReproCommandSpec]):
    BatchFailure =
  try:
    discard session.offerWithRunQuotaBatch(requests, commands)
  except CatchableError as err:
    result.raised = true
    result.isRunQuotaError = err of ReproRunQuotaError
    result.isDeadlock = err of ReproRunQuotaDeadlockError
    result.message = err.msg

proc closeOutcome(session: ReproRunQuotaSession): string =
  ## "" when the daemon accepted the close, its refusal otherwise.
  try:
    session.close()
  except CatchableError as err:
    result = err.msg
    if result.len == 0: result = "close raised " & $err.name

proc waitPastLinger(failedAt: float) =
  let remaining = int((failedAt + (lingerMs + 1000) / 1000 - epochTime()) * 1000)
  if remaining > 0:
    sleep(remaining)

proc checkDrained(dir, tag: string): bool =
  ## The child behind ``tag`` was cancelled and reaped, not orphaned: it never
  ## lived to write ``<tag>.survived``, and if it got as far as recording its
  ## pid that pid is gone.
  if fileExists(dir / (tag & ".survived")):
    checkpoint(tag & " survived the failed batch: it was orphaned, not drained")
    return false
  let started = dir / (tag & ".started")
  if fileExists(started):
    let pid = parseInt(readFile(started).strip())
    if processAlive(pid):
      checkpoint(tag & " pid " & $pid & " is still alive")
      return false
  true

suite "a partially failed batched launch keeps ownership of what it accepted":
  let repoRoot = getCurrentDir()

  test "a launch failure after an earlier child started drains it and releases the rest":
    let root = createTempDir("repro-batchown-a", "")
    defer: removeDir(root)
    var daemon = startDaemon(repoRoot, root, cpuMilli = 3000)
    defer: stopDaemon(daemon)
    let session = openRunQuotaSession("batch ownership a")
    # All three fit at once (3 x 1000m of 3000m): every decision is a grant,
    # so the first child starts, the second launch fails in the parent, and
    # the third is granted but never reached.
    let failure = session.offerExpectingFailure(
      [request("first", 1000), request("broken", 1000), request("later", 1000)],
      [fixtureCommand("linger", root, "first"), emptyArgvCommand(root),
       fixtureCommand("linger", root, "later")])
    let failedAt = epochTime()
    checkpoint("batch failure: " & failure.message)
    check failure.raised
    check failure.isRunQuotaError
    check not failure.isDeadlock
    # The initiating diagnostic survives the rollback.
    check "empty argv" in failure.message
    # Nothing is left with the daemon BEFORE the session closes.
    let leftover = daemonLeases()
    checkpoint("leases after the failed batch:" & describe(leftover))
    check leftover.len == 0
    waitPastLinger(failedAt)
    check checkDrained(root, "first")
    # The later granted candidate was released, never started.
    check not fileExists(root / "later.started")
    let closed = session.closeOutcome()
    checkpoint("close: " & closed)
    check "session still owns leases" notin closed
    check closed.len == 0

  test "a queued decision before the failure is cancelled":
    let root = createTempDir("repro-batchown-b", "")
    defer: removeDir(root)
    var daemon = startDaemon(repoRoot, root, cpuMilli = 2000)
    defer: stopDaemon(daemon)
    let session = openRunQuotaSession("batch ownership b")
    # 2000m budget: "first" (1000m) is granted; "waits" (2000m) fits the
    # machine but not what is left, so it QUEUES; "broken" (500m) still fits
    # beside "first" and is granted -- and its launch fails.
    let failure = session.offerExpectingFailure(
      [request("first", 1000), request("waits", 2000), request("broken", 500)],
      [fixtureCommand("linger", root, "first"),
       fixtureCommand("quick", root, "waits"), emptyArgvCommand(root)])
    let failedAt = epochTime()
    checkpoint("batch failure: " & failure.message)
    check failure.raised
    # Proves "broken" was granted and reached, i.e. the queued decision for
    # "waits" was processed before the failure.
    check "empty argv" in failure.message
    let leftover = daemonLeases()
    checkpoint("leases after the failed batch:" & describe(leftover))
    check leftover.len == 0
    waitPastLinger(failedAt)
    check checkDrained(root, "first")
    check not fileExists(root / "waits.done")
    let closed = session.closeOutcome()
    checkpoint("close: " & closed)
    check closed.len == 0

  test "after a failed batch the same session runs a fresh batch to completion":
    let root = createTempDir("repro-batchown-c", "")
    defer: removeDir(root)
    # Sized so that capacity the failed batch failed to return would QUEUE
    # the fresh batch: 3000m, and the failed batch takes all of it.
    var daemon = startDaemon(repoRoot, root, cpuMilli = 3000)
    defer: stopDaemon(daemon)
    let session = openRunQuotaSession("batch ownership c")
    let failure = session.offerExpectingFailure(
      [request("first", 1000), request("broken", 1000), request("later", 1000)],
      [fixtureCommand("linger", root, "first"), emptyArgvCommand(root),
       fixtureCommand("linger", root, "later")])
    check failure.raised
    var offers: seq[ReproRunQuotaOffer]
    var freshFailure = ""
    try:
      offers = session.offerWithRunQuotaBatch(
        [request("again-1", 1000), request("again-2", 1000)],
        [fixtureCommand("quick", root, "again-1"),
         fixtureCommand("quick", root, "again-2")])
    except CatchableError as err:
      freshFailure = err.msg
    checkpoint("fresh batch failure: " & freshFailure)
    check freshFailure.len == 0
    check offers.len == 2
    if offers.len == 2:
      for offer in offers:
        check offer.kind == rqokStarted
      # Positive control for the inventory reads above: while these two are
      # held the daemon reports exactly them.
      let held = daemonLeases()
      checkpoint("leases while the fresh batch runs:" & describe(held))
      check held.len == 2
      for offer in offers.mitems:
        if offer.kind == rqokStarted:
          let execution = offer.running.finishCompleted()
          check execution.exited
          check execution.exitCode == 0
          check execution.leaseReleased
      check fileExists(root / "again-1.done")
      check fileExists(root / "again-2.done")
    check daemonLeases().len == 0
    check session.closeOutcome().len == 0

# ---------------------------------------------------------------------------
# Engine-level cases
# ---------------------------------------------------------------------------

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[RecognizedDependencyReportSpec(
      formatName: DependencyFormatName(MakeDepfileFormatName),
      outputs: @[ExpectedDependencyFile(logicalName: "deps",
        path: depfile, required: true)],
      completeness: decComplete)])

proc lingerAction(app, workRoot, markers, tag: string): BuildAction =
  let depfile = "deps/" & tag & ".d"
  action(tag, [app, "fixture-action", "linger", markers, tag,
    workRoot / "out" / (tag & ".txt"), workRoot / depfile],
    cwd = workRoot, outputs = ["out/" & tag & ".txt"],
    commandStatsId = tag, dependencyPolicy = depfilePolicy(depfile),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc engineConfig(root, app: string): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: root / ".repro-cache",
    runQuotaCliPath: app,
    maxParallelism: 4'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024,
    inlineRunQuota: true)

suite "the engine keeps the initiating failure of a batched inline launch":
  let repoRoot = getCurrentDir()

  test "the build names the launch failure, not the session close":
    let root = createTempDir("repro-batchown-d1", "")
    defer: removeDir(root)
    var daemon = startDaemon(repoRoot, root, cpuMilli = 8000)
    defer: stopDaemon(daemon)
    let app = getAppFilename()
    let workRoot = root / "work"
    let markers = root / "markers"
    createDir(workRoot)
    createDir(markers)
    # Three independent actions staged in one scheduler tick, so they reach
    # the daemon as ONE batch: a real child, an action whose command the
    # parent cannot launch, another real child.
    let g = graph([
      lingerAction(app, workRoot, markers, "a-first"),
      action("b-broken", newSeq[string](), cwd = workRoot,
        outputs = ["out/b-broken.txt"], commandStatsId = "b-broken",
        governingLockIdentity = lockIdentityOutsideSolvedGraph()),
      lingerAction(app, workRoot, markers, "c-later")])
    var buildFailure = ""
    var run: BuildRunResult
    try:
      run = runBuild(g, engineConfig(root, app))
    except CatchableError as err:
      buildFailure = err.msg
    let finishedAt = epochTime()
    checkpoint("build failure: " & buildFailure)
    check "session still owns leases" notin buildFailure
    check buildFailure.len == 0
    var brokenStderr = ""
    for res in run.results:
      checkpoint(res.id & " " & $res.status & ": " & res.stderr)
      if res.id == "b-broken":
        brokenStderr = res.stderr
        check res.status == asFailed
    check "empty argv" in brokenStderr
    check daemonLeases().len == 0
    waitPastLinger(finishedAt)
    check checkDrained(markers, "a-first")
    check checkDrained(markers, "c-later")

  test "a cleanup and close that fail while unwinding do not erase the cause":
    let root = createTempDir("repro-batchown-d2", "")
    defer: removeDir(root)
    var daemon = startDaemon(repoRoot, root, cpuMilli = 8000)
    defer: stopDaemon(daemon)
    let app = getAppFilename()
    let workRoot = root / "work"
    let markers = root / "markers"
    createDir(workRoot)
    createDir(markers)
    var config = engineConfig(root, app)
    var stopped = false
    # The initiating failure: an observer that raises once the first action
    # has started. Before raising it stops the daemon, so the engine's
    # teardown -- finishing that action's lease, closing the session -- fails
    # for real while this exception is unwinding.
    config.progressCallback = proc(event: BuildProgressEvent) =
      if event.kind == bpkActionStarted and not stopped:
        stopped = true
        # Let the child record its own pid first, so the identity the
        # teardown must disclose is checked against one obtained independently
        # of the engine.
        for _ in 0 ..< 200:
          if fileExists(markers / "only.started"): break
          sleep(25)
        daemon.kill()
        discard daemon.waitForExit(5000)
        raise newException(ValueError, "progress observer refused " &
          event.actionId)
    var raisedName = ""
    var raisedMessage = ""
    try:
      discard runBuild(graph([lingerAction(app, workRoot, markers, "only")]),
        config)
    except CatchableError as err:
      raisedName = $err.name
      raisedMessage = err.msg
    let finishedAt = epochTime()
    checkpoint("raised " & raisedName & ": " & raisedMessage)
    check stopped
    # The cause is still the exception the build raised, with its type...
    check raisedName == "ValueError"
    check "progress observer refused only" in raisedMessage
    # ...and the teardown failures are disclosed beside it, not dropped.
    check "runquota" in raisedMessage.toLowerAscii()
    # The step that could not finish the action's lease names what it left
    # unresolved -- the lease and the child process -- so both can be found
    # and reclaimed (RunQuota-Protocol-And-Client-Libraries.md, "Ownership
    # Across a Batched Client Launch"). The pid is the one the child wrote.
    check fileExists(markers / "only.started")
    let childPid =
      if fileExists(markers / "only.started"):
        readFile(markers / "only.started").strip()
      else: "<unrecorded>"
    const prefix = "stopping action only (lease "
    let at = raisedMessage.find(prefix)
    check at >= 0
    if at >= 0:
      var digits = 0
      while at + prefix.len + digits < raisedMessage.len and
          raisedMessage[at + prefix.len + digits] in Digits:
        inc digits
      check digits > 0
      check raisedMessage.continuesWith(", child pid " & childPid & "): ",
        at + prefix.len + digits)
    # The child was still cancelled and reaped: losing the daemon is not
    # evidence that it completed.
    waitPastLinger(finishedAt)
    check checkDrained(markers, "only")
