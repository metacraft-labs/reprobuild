## M18: ``repro stats`` renders from RunQuota's shared observation store, and
## says what it does not know instead of printing zeros.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M18):
## "``repro stats`` views render from the shared store; every reported
## statistic shows its time window, sample count, and host/profile
## qualification; a store with counted drops renders as INCOMPLETE rather than
## silently thin."
##
## NO MOCKS. Every arm runs the real ``runquotad`` over a real Unix-domain
## socket and the real ``repro`` binary over a real project, and reads
## ``repro stats``'s own JSON back. Nothing in this file writes a row into the
## store or a figure into a view: the numbers asserted on were produced by a
## build that took leases and were rendered by the shipped CLI, which is the
## only reading under which "the views render from the shared store" is a
## statement about the views rather than about this file.
##
## **THE ARM THAT IS EASIEST TO FAKE IS ARM 1, SO IT IS ASSERTED AS A
## DIFFERENCE RATHER THAN AS A PROPERTY.** OS-2 forbids presenting an absent
## or thinned sample as a complete one, and the way that requirement is
## normally lost is not by claiming completeness out loud — it is by
## collapsing "no daemon", "nothing built" and "the query failed" into one
## empty rendering that a reader cannot tell apart from a real quiet window.
## An implementation that hard-coded a single "no data" answer passes any
## check written against one of those states alone. So arm 1 drives the SAME
## command through two of them in one test and requires the two answers to
## DIFFER — in state and in reason — which is the assertion that a collapsed
## implementation cannot satisfy.
##
## **ARM 3 ASSERTS BOTH DIRECTIONS OF THE INCOMPLETE FLAG IN ONE RUN**, for
## the same reason: an implementation that always says INCOMPLETE, and one
## that never does, each satisfy a single-direction check. The arm observes
## the same store COMPLETE, injects a loss the daemon counts, and observes it
## INCOMPLETE — with the figures still present, since "incomplete" must label
## a sample rather than hide it.
##
## **NOT A SAMPLED QUANTITY.** The loss the arm injects is counted by a
## monotonic counter the daemon increments at the point of refusal, and the
## arm polls that counter for a MINIMUM. There is no bound compared against a
## number whose value depends on when the reader happened to look.

import std/[json, os, osproc, posix, streams, strutils, tempfiles, times,
    unittest]

import repro_test_support

import runquota_client
import runquota_core
import runquota_protocol

const
  UndeclaredExtension = "m18_never_declared"
    ## An extension no client ever registered. A row for it is refused by
    ## the daemon and counted, which is a LOSS A WELL-BEHAVED CLIENT
    ## CANNOT PRODUCE — and therefore the only way to reach the INCOMPLETE
    ## branch from outside. Reaching it by editing the counter, or by
    ## asserting the flag on a store that never lost anything, would be the
    ## vacuity this campaign keeps finding.
  ContradictoryStatsKey = "m18_contradictory_execution"
    ## The stats id of the execution the daemon refuses to store. Named so
    ## the arm below can assert the row's ABSENCE by key rather than by a
    ## count that a differently-shaped store could also satisfy.

proc repoRoot(): string = getCurrentDir()

proc publicReproBin(): string =
  ## SPELLED WITH THE LITERAL ``build/bin/repro``: ``generate_test_edges.nim``
  ## detects that substring and stamps ``requiresReproBinary`` on this test's
  ## edge, which declares the engine-built binary as a typed INPUT. Assembled
  ## from components the detector cannot see, an edit under ``libs/repro_*``
  ## would leave this test reporting the OLD binary's behaviour — the same
  ## false green as recompiling the test without rebuilding ``repro``.
  requireBinary(repoRoot() / addFileExt("build/bin/repro", ExeExt),
    "reprobuild.apps.repro")

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type DaemonHandle = object
  process: Process

proc startRunQuotaDaemon(socketPath, identityFile: string): DaemonHandle =
  let process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

# ---------------------------------------------------------------------------
# The REPRO daemon (not runquotad). The retired JSONL store was written by
# `repro-daemon`-hosted capture only, so the store-swap arm needs this second
# harness to reach the path the writer actually lived on.
# ---------------------------------------------------------------------------

proc reproDaemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc reproDaemonStateDir(tempRoot: string): string =
  tempRoot / "daemon-state"

proc reproDaemonLogPath(tempRoot: string): string =
  reproDaemonStateDir(tempRoot) / "logs" / "repro-daemon.log"

proc reproDaemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", reproDaemonEndpoint(tempRoot),
    "--state-dir", reproDaemonStateDir(tempRoot),
    "--log", reproDaemonLogPath(tempRoot)
  ]

proc reproDaemonEnv(tempRoot: string): seq[(string, string)] =
  @[
    ("REPRO_DAEMON_ENDPOINT", reproDaemonEndpoint(tempRoot)),
    ("REPRO_DAEMON_STATE_DIR", reproDaemonStateDir(tempRoot)),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store")
  ]

proc waitForReproDaemon(tempRoot: string; timeoutSeconds = 60.0) =
  let deadline = epochTime() + timeoutSeconds
  var lastOutput = ""
  while epochTime() < deadline:
    let res = runShell(shellCommand(@[publicReproBin(), "daemon", "status"] &
      reproDaemonArgs(tempRoot)), repoRoot())
    lastOutput = res.output
    if res.code == 0 and res.output.contains("repro daemon: running"):
      return
    sleep(25)
  checkpoint(lastOutput)
  if fileExists(reproDaemonLogPath(tempRoot)):
    checkpoint(readFile(reproDaemonLogPath(tempRoot)))
  raise newException(IOError, "timed out waiting for the repro daemon")

proc startReproDaemon(tempRoot: string): owned(Process) =
  createDir(reproDaemonStateDir(tempRoot))
  try: removeFile(reproDaemonEndpoint(tempRoot)) except OSError: discard
  result = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground"] & reproDaemonArgs(tempRoot),
    workingDir = repoRoot(),
    options = {poUsePath, poStdErrToStdOut})
  try:
    waitForReproDaemon(tempRoot)
  except CatchableError:
    if result.running():
      result.terminate()
      discard result.waitForExit()
    result.close()
    raise

proc closeReproDaemon(daemon: var owned(Process); tempRoot: string) =
  discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop"] &
    reproDaemonArgs(tempRoot)), repoRoot())
  try: removeFile(reproDaemonEndpoint(tempRoot)) except OSError: discard
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

proc nimString(value: string): string = value.escape()

proc writeCopyProject(projectRoot, packageName: string; actionCount: int) =
  ## PROCESS actions, not built-in ones. A built-in ``fs.copyFile`` runs in
  ## the engine's own process and takes no RunQuota lease, so it produces no
  ## execution row and there would be nothing for the views to render.
  createDir(projectRoot / "src")
  for i in 0 ..< actionCount:
    writeFile(projectRoot / "src" / ("input-" & $i & ".txt"),
      "input " & $i & "\n")
  let script =
    "set -eu\n" &
    "src=$1\n" &
    "out=$2\n" &
    "mkdir -p \"$(dirname \"$out\")\"\n" &
    "cat \"$src\" > \"$out\"\n"
  var body = "import repro_project_dsl\n\n" &
    "package " & packageName & ":\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n"
  for i in 0 ..< actionCount:
    let inputRel = "src/input-" & $i & ".txt"
    let outputRel = "dist/output-" & $i & ".txt"
    body.add("      discard buildAction(" &
      nimString("m18-copy-" & $i) & ",\n" &
      "        " & packageName & ".executable(\"sh\").subcmd_2d_c(\n" &
      "          args = @[" & nimString(script) & ", " & nimString("sh") &
        ", " & nimString(inputRel) & ", " & nimString(outputRel) & "]),\n" &
      "        inputs = @[" & nimString(inputRel) & "],\n" &
      "        outputs = @[" & nimString(outputRel) & "],\n" &
      "        cacheable = true)\n")
  writeFile(projectRoot / "reprobuild.nim", body)

proc runBuild(projectRoot, tempRoot, workName, socketPath: string): string =
  requireSuccess(shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=off",
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--measure=none"
  ], @[("RUNQUOTA_SOCKET", socketPath)]), repoRoot())

proc statsJson(projectRoot, socketPath: string;
               args: openArray[string]): JsonNode =
  parseJson(requireSuccess(shellCommand(@[publicReproBin(), "stats"] & @args &
    @["--project-root=" & projectRoot, "--json"],
    @[("RUNQUOTA_SOCKET", socketPath)]), repoRoot()).strip())

proc statsText(projectRoot, socketPath: string;
               args: openArray[string]): string =
  requireSuccess(shellCommand(@[publicReproBin(), "stats"] & @args &
    @["--project-root=" & projectRoot],
    @[("RUNQUOTA_SOCKET", socketPath)]), repoRoot())

proc actionRank(projectRoot, socketPath: string): JsonNode =
  statsJson(projectRoot, socketPath,
    ["rank", "--scope=actions", "--by=cache-miss-count"])

proc lossTotal(socketPath: string): int64 =
  ## Read the daemon's own loss counters back over RQSP. This is the
  ## place the write path documents as where OS-2's "every dropped
  ## observation MUST be counted" is satisfied for its one-way messages.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let root = parseJson(client.inspectionJson("observations")){"observations"}
  root{"dropped"}.getBiggestInt(0) +
    root{"write_failures"}.getBiggestInt(0) +
    root{"rejected"}.getBiggestInt(0) +
    root{"extension_rows_refused"}.getBiggestInt(0) +
    root{"deferred_batches_refused"}.getBiggestInt(0) +
    root{"executions_contradictory"}.getBiggestInt(0)

proc contradictoryCount(socketPath: string): int64 =
  ## The ONE counter the contradiction arm below is about, read on its own
  ## so that arm can say WHICH loss moved rather than only that the total
  ## did — a total that also moves for five other reasons would let an
  ## implementation reading any one of them pass.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let root = parseJson(client.inspectionJson("observations")){"observations"}
  root{"executions_contradictory"}.getBiggestInt(0)

proc injectCountedLoss(socketPath: string) =
  ## Offer the daemon a row for an extension nobody declared. The daemon
  ## refuses it and counts the refusal; the client is never told, because
  ## the message is one-way by design.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  var session = client.registerSession("m18-loss-injector", "0.1.0")
  session.recordExtensionRow(0'u64, UndeclaredExtension, 1,
    ["some_column"], [wireText("value")])
  session.closeSession()

proc waitForLossAtLeast(socketPath: string; atLeast: int64): int64 =
  ## Polls a MONOTONIC COUNTER for a minimum. Never for a maximum, and
  ## never against a bound whose left-hand side is sampled: the counter
  ## only ever moves up, so a later read cannot turn a counted loss back
  ## into an uncounted one.
  let deadline = epochTime() + 15.0
  while epochTime() < deadline:
    result = lossTotal(socketPath)
    if result >= atLeast:
      return
    sleep(100)

proc injectContradictoryExecution(socketPath: string) =
  ## Finish a real lease with a finish that contradicts its own evidence:
  ## a resource-limit KILL claim (``hardLimitOrOom``) beside ``exit_status
  ## = 0`` and no signal. The daemon refuses to store the row — an
  ## immutable row asserting both that a process was killed for exceeding a
  ## bound and that it exited successfully is unfalsifiable — and counts
  ## the loss under ``executions_contradictory``.
  ##
  ## THE CLIENT IS NEVER TOLD, and that is the point. Refusing
  ## ``LeaseFinished`` is not available to the daemon: it is how the
  ## authority learns the resources are free, so an error in its place
  ## would strand the lease. The finish is therefore ACKNOWLEDGED, this
  ## proc returns normally, and the counter is the only surface on which
  ## the whole missing execution exists.
  ##
  ## A LOSS A WELL-BEHAVED CLIENT CANNOT PRODUCE, like the undeclared
  ## extension row above: ``RunQuotaLease.finish`` cross-validates
  ## ``outcome`` against ``hardLimitOrOom`` nowhere, so this needs no
  ## forged frame — one argument list on the public API reaches it.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  var session = client.registerSession("m18-contradiction-injector", "0.1.0")
  var request = resourceRequest("m18-contradiction", milliCpu(1000),
    bytes(64'u64 * 1024'u64 * 1024'u64))
  request.commandStatsId = ContradictoryStatsKey
  var lease = session.requestLease(request)
  doAssert lease.active
  lease.markStarting()
  lease.markRunning(childProcessId = uint64(getCurrentProcessId()))
  lease.finish(outcome = leaseFinishFailed, exitCode = 0'u32, signal = 0'u32,
    peakMemoryBytes = 1_000'u64, processCount = 1'u32,
    hardLimitOrOom = true)
  lease.release()
  session.closeSession()

proc waitForContradictoryAtLeast(socketPath: string; atLeast: int64): int64 =
  ## Same shape as ``waitForLossAtLeast``: a MONOTONIC counter, polled for a
  ## minimum.
  let deadline = epochTime() + 15.0
  while epochTime() < deadline:
    result = contradictoryCount(socketPath)
    if result >= atLeast:
      return
    sleep(100)

proc waitForActionRows(projectRoot, socketPath: string; atLeast: int): JsonNode =
  ## The observation writer drains on a tick, so a query issued immediately
  ## after the build can legitimately see nothing yet. Polling for a
  ## MINIMUM cannot turn an absent row into a present one.
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    result = actionRank(projectRoot, socketPath)
    if result{"rows"}.len >= atLeast:
      return
    sleep(200)

suite "M18 repro stats reads the shared store":
  when isNixSupported:
    test "unavailable, empty and complete are three distinguishable answers":
      let tempRoot = createTempDir("repro-m18-states", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m18s-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let endpointDir = runquotaRendezvousDir(socketRoot)
      let socketPath = endpointDir / "d.sock"
      let deadSocketPath = endpointDir / "nobody-is-here.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m18States", 2)

      # --- (1) NO DAEMON ------------------------------------------------
      # Asserted BEFORE any daemon exists, so the answer cannot be a
      # cached one.
      let absent = actionRank(projectRoot, deadSocketPath)
      let absentWindow = absent{"window"}
      check absentWindow{"state"}.getStr() == "unavailable"
      check not absentWindow{"available"}.getBool(true)
      check not absent{"availability"}{"available"}.getBool(true)
      # THE REASON NAMES THE ENDPOINT. "no data" would leave a reader with
      # nothing to act on, which is the whole failure mode.
      check absentWindow{"reason"}.getStr().contains(deadSocketPath)
      # AND NO FIGURE IS RENDERED AS ZERO. A ranking of nothing presented
      # as a ranking is the silently-thin presentation OS-2 forbids.
      check absent{"rows"}.len == 0
      let absentText = statsText(projectRoot, deadSocketPath, ["overview"])
      check absentText.contains("unavailable")
      check absentText.contains("No statistics")

      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      # --- (2) DAEMON UP, NOTHING BUILT ---------------------------------
      let empty = actionRank(projectRoot, socketPath)
      let emptyWindow = empty{"window"}
      check emptyWindow{"state"}.getStr() == "empty"
      check not emptyWindow{"available"}.getBool(true)
      check empty{"rows"}.len == 0

      # THE CLAUSE. Same command, same project, two states — and the two
      # answers are different in BOTH the machine-readable state and the
      # human-readable reason. An implementation that collapsed the two
      # into one "no data" rendering fails here and nowhere else.
      check absentWindow{"state"}.getStr() != emptyWindow{"state"}.getStr()
      check absentWindow{"reason"}.getStr() != emptyWindow{"reason"}.getStr()
      check emptyWindow{"reason"}.getStr().len > 0

      # --- (3) A REAL BUILD ---------------------------------------------
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      let ranked = waitForActionRows(projectRoot, socketPath, 2)
      let window = ranked{"window"}
      # NON-VACUITY: the fixture really did produce two distinct actions,
      # so the qualification assertions below are about a populated window
      # rather than trivially true of an empty one.
      check ranked{"rows"}.len >= 2
      check ranked{"rows"}[0]{"actionId"}.getStr() !=
        ranked{"rows"}[1]{"actionId"}.getStr()
      check window{"state"}.getStr() in ["complete", "incomplete"]
      check window{"available"}.getBool(false)
      check ranked{"availability"}{"available"}.getBool(false)

      # --- every reported statistic shows its time window ---------------
      check window{"firstObservationUnixMs"}.getBiggestInt(0) > 0
      check window{"lastObservationUnixMs"}.getBiggestInt(0) >=
        window{"firstObservationUnixMs"}.getBiggestInt(0)
      # --- its sample count ---------------------------------------------
      check window{"sampleCount"}.getInt(0) >= 2
      check window{"observationCount"}.getInt(0) >= 2
      for row in ranked{"rows"}:
        check row{"sampleCount"}.getInt(0) > 0
      # --- and its host/profile qualification (OS-6) --------------------
      check window{"profiles"}.len >= 1
      for profile in window{"profiles"}:
        check profile{"hostId"}.getStr().len > 0
        check profile{"profileId"}.getStr().len > 0
      # --- and WHOSE rows they are --------------------------------------
      # §"Scoping on a shared host": queries are scoped to the calling uid
      # by default and widening must be EXPLICIT. A human surface that
      # widened silently would show a reader on a shared machine other
      # users' builds as though they were this project's, so the scope the
      # rows were selected under is rendered rather than assumed.
      check window{"scope"}.getStr() == "owner"

      # The text surface carries the same three qualifications, because a
      # reader who does not pass --json is the one most likely to read a
      # bare number as authoritative.
      let overview = statsText(projectRoot, socketPath, ["overview"])
      check overview.contains("Stats window: executions=")
      check overview.contains("Host profiles: ")
      check not overview.contains("No statistics")

      # THE STORE-SWAP ASSERTIONS ARE NOT HERE, DELIBERATELY. This build
      # runs ``--daemon=off`` and names no ``--stats-groups``, so the M7
      # JSONL writer was never on the path to begin with -- an assertion
      # that the file is absent would pass on the code that still wrote
      # it, which is precisely the "asserted where it was convenient to
      # reach rather than where the code does the dangerous thing" defect
      # this campaign keeps finding. The live assertion is the last test
      # in this file, which drives the daemon-hosted capture path that
      # actually used to produce those files.
      let status = statsText(projectRoot, socketPath, ["status"])
      check status.contains(projectRoot / ".repro" / "stats" / "derived")
      # The scope reaches the human surface too, where a reader is least
      # likely to go looking for it and most likely to need it.
      check status.contains("scope: owner")

    test "a store with counted drops renders INCOMPLETE, not silently thin":
      let tempRoot = createTempDir("repro-m18-drops", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m18d-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let socketPath = runquotaRendezvousDir(socketRoot) / "d.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m18Drops", 2)
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      let before = waitForActionRows(projectRoot, socketPath, 2)

      # DIRECTION ONE: a store that lost nothing renders COMPLETE. Without
      # this half, an implementation that labels every window INCOMPLETE
      # passes the half below and is useless.
      check before{"window"}{"state"}.getStr() == "complete"
      check before{"window"}{"complete"}.getBool(false)
      check before{"window"}{"loss"}{"known"}.getBool(false)
      check before{"window"}{"loss"}{"total"}.getBiggestInt(-1) == 0
      let renderedRows = before{"rows"}.len
      check renderedRows >= 2

      # Now lose an observation, in the one way the daemon counts and the
      # client is never told about.
      injectCountedLoss(socketPath)
      check waitForLossAtLeast(socketPath, 1) >= 1

      let after = actionRank(projectRoot, socketPath)
      let window = after{"window"}
      # DIRECTION TWO: the same store, one counted loss later.
      check window{"state"}.getStr() == "incomplete"
      check not window{"complete"}.getBool(true)
      check window{"loss"}{"total"}.getBiggestInt(0) >= 1
      check window{"loss"}{"extensionRowsRefused"}.getBiggestInt(0) >= 1
      # THE FIGURES ARE STILL THERE. "Incomplete" must LABEL a sample, not
      # suppress it: a view that hid the rows would have replaced one
      # dishonest answer with another, and a reader who needs the numbers
      # would go back to the ones with no label at all.
      check window{"available"}.getBool(false)
      check after{"rows"}.len == renderedRows
      # And the label reaches the human surface, where it matters most.
      let statusText = statsText(projectRoot, socketPath, ["status"])
      check statusText.contains("INCOMPLETE")
      check statusText.contains("extension-rows-refused=")

    test "a window thinned by a refused CONTRADICTORY execution is INCOMPLETE too":
      # THE SAME OS-2 CLAUSE, REACHED BY THE LOSS THE VIEW DID NOT READ.
      #
      # `runquotad` refuses to store an execution whose own evidence
      # disagrees with itself, acknowledges the finish anyway (refusing it
      # would strand the lease), and counts the whole missing execution
      # under `executions_contradictory`. That counter is a SIXTH loss key,
      # and a client summing only the other five renders a store that has
      # silently lost an entire execution as `complete`. OS-2 forbids
      # exactly that: a thinned sample must never be presentable as whole,
      # because statistics over a silently truncated window read as
      # authoritative.
      #
      # THIS ARM IS DELIBERATELY NOT A LINE IN THE ARM ABOVE. Folded in
      # there, the extension-row refusal would already have driven the
      # window to `incomplete` and the assertion would hold on a client
      # that never read this key at all — the state would be right for the
      # wrong reason. Here the contradictory execution is the ONLY loss in
      # the store, so `incomplete` is reachable only by reading it.
      let tempRoot = createTempDir("repro-m18-contra", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m18c-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let socketPath = rendezvousDir(socketRoot) / "d.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m18Contra", 2)
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      let before = waitForActionRows(projectRoot, socketPath, 2)

      # DIRECTION ONE, AND IT IS NOT DECORATION. An implementation that
      # reports every window `incomplete` — including one that added the
      # sixth counter to the total but read it as a constant, or that
      # tripped `incomplete` off `known` rather than off a count — passes
      # the second half of this arm and is worthless. Every counter is
      # zero here, and the window must say `complete`.
      check before{"window"}{"state"}.getStr() == "complete"
      check before{"window"}{"complete"}.getBool(false)
      check before{"window"}{"loss"}{"known"}.getBool(false)
      check before{"window"}{"loss"}{"total"}.getBiggestInt(-1) == 0
      check before{"window"}{"loss"}{"contradictoryExecutions"}
        .getBiggestInt(-1) == 0
      let renderedRows = before{"rows"}.len
      let renderedSamples = before{"window"}{"sampleCount"}.getInt(0)
      check renderedRows >= 2
      check renderedSamples >= 2

      # NON-VACUITY, ASSERTED BEFORE THE INJECTION. The five older counters
      # are all zero, so anything that changes below changed because of the
      # contradictory execution and nothing else.
      check lossTotal(socketPath) == 0

      injectContradictoryExecution(socketPath)
      check waitForContradictoryAtLeast(socketPath, 1) >= 1

      let after = actionRank(projectRoot, socketPath)
      let window = after{"window"}
      # DIRECTION TWO: the same store, one whole execution poorer.
      check window{"state"}.getStr() == "incomplete"
      check not window{"complete"}.getBool(true)
      check window{"loss"}{"contradictoryExecutions"}.getBiggestInt(0) >= 1
      # AND IT IS COUNTED IN THE TOTAL. A field carried beside the total but
      # left out of it renders "INCOMPLETE: 0 observations counted lost",
      # which tells a reader the sample is thinned and then denies it.
      check window{"loss"}{"total"}.getBiggestInt(0) >= 1
      # THE OTHER FIVE DID NOT MOVE, so the state above cannot be explained
      # by any loss except this one.
      check window{"loss"}{"dropped"}.getBiggestInt(-1) == 0
      check window{"loss"}{"writeFailures"}.getBiggestInt(-1) == 0
      check window{"loss"}{"rejected"}.getBiggestInt(-1) == 0
      check window{"loss"}{"extensionRowsRefused"}.getBiggestInt(-1) == 0
      check window{"loss"}{"deferredBatchesRefused"}.getBiggestInt(-1) == 0

      # THE EXECUTION REALLY IS MISSING, not merely counted. The spine holds
      # exactly what it held before the injection: the refusal cost a whole
      # row, which is why the loss had to be visible somewhere at all.
      check window{"sampleCount"}.getInt(-1) == renderedSamples
      check after{"rows"}.len == renderedRows
      # And the figures are still rendered — "incomplete" labels a sample,
      # it does not suppress one.
      check window{"available"}.getBool(false)

      # The human surface says it too, and names the counter. A reader who
      # does not pass --json is the one most likely to read the numbers as
      # authoritative.
      let statusText = statsText(projectRoot, socketPath, ["status"])
      check statusText.contains("INCOMPLETE")
      check statusText.contains("contradictory-executions=1")

    test "a scope the shared store cannot answer says so instead of ranking nothing":
      # THE HONEST-DEGRADATION CLAUSE. RunQuota's spine has no reprobuild
      # TARGET dimension, so `--scope=targets` has nothing to rank. An
      # empty ranking marked available would report "nothing was slow"
      # where the truth is "this question has no answer here" — the same
      # class of dishonesty as rendering an absent window as zeros, and
      # the one a reader is least likely to notice because the command
      # still exits zero.
      let tempRoot = createTempDir("repro-m18-targets", "")
      let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
      let socketRoot = getTempDir() / ("rq-m18t-" & $getCurrentProcessId())
      removeDir(socketRoot)
      createDir(socketRoot)
      let socketPath = runquotaRendezvousDir(socketRoot) / "d.sock"
      let stateDir = socketRoot / "state"
      createDir(stateDir)
      var daemon = startRunQuotaDaemon(socketPath, stateDir / "host-id")
      defer:
        daemon.stop()
        putEnv("RUNQUOTA_SOCKET", previousSocket)
        removeDir(socketRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m18Targets", 2)
      discard runBuild(projectRoot, tempRoot, "work-1", socketPath)
      # NON-VACUITY: the store is POPULATED. Without this the assertion
      # below would also hold on an empty store, where "unavailable" is
      # the right answer for a quite different reason.
      let populated = waitForActionRows(projectRoot, socketPath, 2)
      check populated{"window"}{"available"}.getBool(false)

      let targets = statsJson(projectRoot, socketPath,
        ["rank", "--scope=targets", "--by=build-time"])
      check not targets{"availability"}{"available"}.getBool(true)
      check targets{"rows"}.len == 0
      # The reason names the missing DIMENSION and an answerable
      # alternative, rather than blaming the store for being empty — which
      # it demonstrably is not.
      check targets{"availability"}{"reason"}.getStr().contains(
        "no reprobuild target dimension")
      check targets{"availability"}{"reason"}.getStr().contains("--scope=tools")
      # And the window it carries is the POPULATED one, so a reader can
      # see that the absence is about the question and not about the data.
      check targets{"window"}{"available"}.getBool(false)
      check targets{"window"}{"sampleCount"}.getInt(0) >= 2

    test "the daemon-hosted capture path no longer writes the retired raw store":
      # THE STORE SWAP, ASSERTED WHERE THE CODE USED TO DO IT.
      #
      # The retired ``.repro/stats/observations.jsonl`` and
      # ``.repro/stats/summary.json`` were written by ONE path: a
      # daemon-hosted build that named ``--stats-groups``. Asserting their
      # absence after any other kind of build is vacuous -- the writer was
      # never reached, so the check passes on the code that still has it.
      # This arm therefore reproduces exactly the invocation
      # ``t_local_daemons_control_plane_m7`` uses to prove the files WERE
      # written, and requires that they are not.
      #
      # NON-VACUITY, ASSERTED RATHER THAN ASSUMED: the build must have
      # produced capture work for the writer to have had something to
      # write. ``discarded`` is that witness -- rollup inputs the derived
      # store had nowhere to put -- and it is counted rather than dropped
      # silently, so "the writer had nothing to do" and "the writer no
      # longer exists" stay distinguishable. Without it, a build that
      # captured nothing at all would satisfy every line below.
      let tempRoot = createTempDir("repro-m18-swap", "")
      var daemon: owned(Process)
      defer:
        closeReproDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startReproDaemon(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "m18Swap", 2)
      discard requireSuccess(shellCommand(@[
        publicReproBin(), "build", projectRoot,
        "--daemon=require",
        "--tool-provisioning=path",
        "--work-root=" & tempRoot / "work",
        "--action-cache-root=" & tempRoot / "action-cache",
        "--progress=quiet",
        "--log=quiet",
        "--measure=none",
        "--no-runquota",
        "--stats-groups=timing,cache,runquota,deps,sessions"
      ], reproDaemonEnv(tempRoot)), repoRoot())

      # The M7 store had an asynchronous flush, so it was polled for. Poll
      # the same way for the counted DISCARD, which is what replaced it.
      #
      # READ FROM THE DAEMON'S LOG, NOT FROM ``repro stats status``. The
      # discard counter is per-process and the discard happens in the
      # DAEMON; a CLI process asking itself would report its own zero and
      # this witness would be satisfied by a daemon that captured nothing
      # at all. That is the same "asserted where it was convenient to
      # reach" defect the arm above avoids, one process boundary over.
      var discardLine = ""
      let deadline = epochTime() + 30.0
      while epochTime() < deadline:
        if fileExists(reproDaemonLogPath(tempRoot)):
          for line in readFile(reproDaemonLogPath(tempRoot)).splitLines:
            if line.contains("stats discarded session="):
              discardLine = line
        if discardLine.len > 0:
          break
        sleep(200)
      # NON-VACUITY: capture really ran and really had something to write.
      # Without this, a build that captured nothing would satisfy every
      # absence check below.
      check discardLine.len > 0
      check discardLine.contains("reason=derived-backend-not-linked")
      check discardLine.contains(projectRoot / ".repro" / "stats" / "derived")

      check not fileExists(projectRoot / ".repro" / "stats" /
        "observations.jsonl")
      check not fileExists(projectRoot / ".repro" / "stats" / "summary.json")
      let status = requireSuccess(shellCommand(@[
        publicReproBin(), "stats", "status",
        "--project-root=" & projectRoot], reproDaemonEnv(tempRoot)), repoRoot())
      check status.contains(projectRoot / ".repro" / "stats" / "derived")
      check not status.contains("observations.jsonl")
      check not status.contains("summary.json")
      # AND THE TWO RETIRED SCHEMA IDS ARE NOT WRITTEN ANYWHERE UNDER THE
      # PROJECT. The two paths above are the ones the specification names,
      # but a writer moved to a neighbouring filename would satisfy them;
      # the ids are what identify the retired shape wherever it lands.
      for path in walkDirRec(projectRoot / ".repro"):
        let body =
          try: readFile(path)
          except CatchableError: ""
        check not body.contains("reprobuild.daemon.stats-observation.v1")
        check not body.contains("reprobuild.daemon.stats-summary.v1")
