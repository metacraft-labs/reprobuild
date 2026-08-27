## In-Process-Monitor-Hosting P3 — A LAUNCH PATH THAT CANNOT HOST THE
## MONITOR REFUSES THE ACTION; IT NEVER RUNS IT UNMONITORED.
##
## THE HAZARD THIS CLOSES, stated the way it was measured rather than the
## way it was feared. The engine has four monitored launch paths. Deciding
## that an action is "hosted" does TWO independent things:
##
##   1. ``monitoredAction`` leaves the argv exactly as the recipe wrote it,
##      because the engine is about to be io-mon's host itself and there is
##      no ``repro internal io monitor`` wrapper process any more;
##   2. the launch site starts that host.
##
## Only the L1 bypass site ever did (2). An inline RunQuota launch is staged
## into ``stagedInlineLaunches`` and ``continue``s BEFORE the branch that
## consults ``plan.hostInProcess``, and the batch flush / grant poller spawn
## the child themselves as part of binding it to a granted lease. So a
## hosted plan reaching the inline path got (1) and not (2): the recipe's
## argv, naked, with nobody monitoring it. HM-4 measured exactly that by
## relaxing the hosting decision — the inline actions came back with an
## EMPTY read set and "RMDF file does not exist", the actions SUCCEEDED, and
## nothing anywhere said a word. An action that publishes a cache entry
## against a dependency set that is silently wrong is the cardinal sin this
## whole subsystem exists to prevent.
##
## It was harmless only because a boolean was false. The hosting decision
## carried a bare ``bypassRunQuota`` conjunct, and the hazard was recorded —
## in three comments — at the two sites that would have to change together.
## A comment is not a guard: the next person to widen that conjunct gets
## silent unmonitoring with every test in the suite still green.
##
## WHAT IS BEING TESTED, AND WHY IT IS REACHABLE AT ALL. P3 replaced the
## boolean with ``MonitorHostingMode``. ``mhmWhereSupported`` is the old
## "true": host where the launch path can, keep the wrapper everywhere else.
## ``mhmRequired`` is the mode that makes this file possible — it marks a
## plan hosted on EVERY launch path deliberately, so an impossible request
## travels as far as the launch site instead of being quietly downgraded
## where no oracle could see it. The launch site then REFUSES it, and the
## refusal is what these cases drive. Without ``mhmRequired`` the guard
## would be unreachable from any configuration and could only ever be
## exercised by editing the engine, which is a mutation and not a test.
##
## THE PRIMARY ASSERTION IS NOT THE DIAGNOSTIC. It is that the action's
## output file DOES NOT EXIST: the process never ran. A refusal that printed
## the right sentence and then ran the action anyway would satisfy a
## message check and still be the failure this file is about. The message is
## checked too, because "failed for some other reason" would otherwise pass.
##
## MUTATION TARGETS, all four applied to a SHA-256-verified snapshot of
## ``repro_build_engine.nim``, each with both binaries deleted and recompiled
## after the mutation AND after the restore, each restore checksum-verified.
## Results as measured, not as expected:
##
##   A — move the guard below the inline staging block, i.e. the exact pre-P3
##       ``continue``-before-the-branch order. RED, rc=1: the staging site's
##       own ``doAssert`` fires with ``monitorHostingRefusal``'s sentence.
##       This is the mutation that makes the assertion below load-bearing.
##   B — delete the guard AND that ``doAssert``: the true pre-P3 state. RED,
##       rc=1, and it reproduces the hazard exactly — the inline action comes
##       back ``asSucceeded exit=0`` with ``monitorReads: 0 entries``, an
##       empty stderr and ``produced.txt`` on disk. The helper case reddens
##       differently and correctly: it comes back monitored (16 reads) with a
##       ``.host.stdout``, i.e. hosted in-engine with its RunQuota lease
##       silently dropped.
##   C — put the ``bypassRunQuota`` conjunct back into the hosting decision:
##       RED, rc=1. No plan is hosted off L1, so neither refusal happens and
##       both actions run (correctly, via the wrapper) instead.
##   D — remove ONLY the ``doAssert``, keeping the guard. **GREEN. Reddens
##       nothing**, and it is recorded here rather than quietly dropped: the
##       assertion is unreachable while the guard stands above it, which is
##       the intended state. Mutation A is what shows it is not decoration.
##
## AND WHAT NONE OF THEM MOVED: ``t_every_launch_path_is_monitored`` stayed
## 11 [OK] / 0 [FAILED] / 0 [SKIPPED], rc=0, under A, B, C and D alike. The
## launch-path gate cannot see this hazard — it requests hosting as
## ``mhmWhereSupported``, so no hosted plan ever reaches an unhostable path
## there — which is precisely why this file exists next to it.
##
## NO MOCKS. A real ``runquotad`` over a real unix socket, the real engine,
## real child processes, and the filesystem as the oracle.

import std/[os, osproc, sets, streams, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support

when defined(linux) or defined(macosx):
  proc statExists(path: string): bool =
    ## ``fileExists`` is false for a unix socket (it is not a regular file),
    ## so daemon readiness has to be probed with a stat.
    try:
      discard getFileInfo(path, followSymlink = false)
      true
    except OSError:
      false

  var cachedMonitorTools: MonitorTools
  var cachedMonitorToolsReady = false
  proc monitorTools(repoRoot: string): MonitorTools =
    if not cachedMonitorToolsReady:
      cachedMonitorTools = prepareMonitorTools(repoRoot,
        repoRoot / "build" / "test-monitor-p3", "p3-monitor")
      putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
      cachedMonitorToolsReady = true
    cachedMonitorTools

  type DaemonHandle = object
    process: Process
    socket: string
    started: bool

  proc startRunQuotaDaemon(repoRoot, endpointRoot: string): DaemonHandle =
    ## THE SOCKET GETS A RENDEZVOUS DIRECTORY OF ITS OWN, provisioned by
    ## ``runquotaRendezvousDir`` — which is RunQuota's own rule rather than
    ## a copy of it. A socket dropped straight into ``getTempDir()`` lands
    ## in root-owned 1777 ``/tmp``, which RunQuota refuses, and the daemon
    ## exits before it listens. That produced a whole gate reporting a
    ## clean run over cases that never executed.
    let daemonBin = requireRunQuotaDaemonBin(repoRoot)
    let socketPath = runquotaRendezvousDir(endpointRoot) / "runquota.sock"
    removeFile(socketPath)
    let daemon = startProcess(daemonBin, args = [
      "--socket", socketPath,
      "--cpu-milli", "4000",
      "--memory-bytes", "17179869184"
    ], options = {poUsePath, poStdErrToStdOut})
    var died = false
    for _ in 0 ..< 400:
      if statExists(socketPath):
        putEnv("RUNQUOTA_SOCKET", socketPath)
        return DaemonHandle(process: daemon, socket: socketPath, started: true)
      # A REFUSAL EXITS; it does not hang. Noticing that here turns a
      # ten-second silent timeout into an immediate, quotable diagnosis.
      if not daemon.running:
        died = true
        break
      sleep(25)
    if not died:
      daemon.terminate()
    discard daemon.waitForExit()
    var output = ""
    try:
      output = daemon.outputStream.readAll().strip()
    except CatchableError:
      discard
    daemon.close()
    raise newException(OSError,
      "runquotad did not bind " & socketPath &
      (if died: " (it exited first)" else: " (timed out)") &
      (if output.len > 0: "; it said: " & output else: "; it said nothing"))

  proc stop(handle: var DaemonHandle) =
    if not handle.started: return
    handle.process.terminate()
    discard handle.process.waitForExit()
    handle.process.close()
    removeFile(handle.socket)
    delEnv("RUNQUOTA_SOCKET")
    handle.started = false

  proc requiredHostingConfig(repoRoot, cacheRoot: string;
                             path: MonitorLaunchPath): BuildEngineConfig =
    ## ``mhmRequired`` on every case here: the point is to ask for hosting
    ## on a path that cannot give it and see what the engine does about it.
    ## The L1 case uses the same mode so the positive control is a control —
    ## it rules out "``mhmRequired`` simply fails everything".
    result = BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: monitorTools(repoRoot).monitorCliPath,
      monitorCliPath: monitorTools(repoRoot).monitorCliPath,
      monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      monitorHosting: mhmRequired)
    case path
    of mlpBypassRunQuota:
      result.bypassRunQuota = true
    of mlpInlineRunQuota:
      result.inlineRunQuota = true
    of mlpRunQuotaHelper:
      discard          # neither bypass nor inline: the helper-process path

  const ProducedName = "produced.txt"
  const MarkerName = "marker.txt"

  proc monitoredShellAction(id, workRoot: string): BuildAction =
    ## Reads a marker and writes an output, both inside the case's own work
    ## tree. The OUTPUT is the oracle for "did this action run at all"; the
    ## MARKER is the oracle for "was it monitored" on the L1 control.
    ##
    ## BOTH PATHS ARE ABSOLUTE IN THE ARGV, and that is not cosmetic: with
    ## ``cat marker.txt`` the monitored child opens a path relative to its
    ## cwd, the recorded read does not resolve to the marker, and the L1
    ## control's monitoring assertion fails while the action is monitored
    ## perfectly well. Measured, not guessed — the first version of this
    ## file used the relative form and recorded fifteen shared objects and
    ## no marker.
    action(id, ["/bin/sh", "-c",
                "cat " & quoteShell(expandFilename(workRoot) / MarkerName) &
                " > " & quoteShell(expandFilename(workRoot) / ProducedName)],
      cwd = workRoot,
      inputs = [MarkerName],
      outputs = [ProducedName],
      commandStatsId = id,
      cpuMilli = 100'u32,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      dependencyPolicy = automaticMonitorGatheringPolicy())

  proc prepareWork(caseDir: string): string =
    result = caseDir / "work"
    createDir(result)
    writeFile(result / MarkerName, "p3 marker payload\n")

  proc inProcessHostCaptureFiles(cacheRoot: string): int =
    ## The in-process host redirects the monitored child's descriptors 1 and
    ## 2 into ``<cacheRoot>/actions/<stem>.host.stdout`` / ``.host.stderr``.
    ## Nothing else in the engine writes a ``.host.stdout``, so their
    ## presence is a RUNTIME witness that the engine hosted this action
    ## rather than putting a ``repro internal io monitor`` child in between —
    ## which no field of ``ActionResult`` reports, because the whole point of
    ## the two forms is that they are indistinguishable downstream.
    let dir = cacheRoot / "actions"
    if not dirExists(dir): return 0
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".host.stdout"):
        inc result

  ## Which cases ran to the END of their assertions. Recorded on the last
  ## line of each body, never on entry: a body that returned early or whose
  ## exception something swallowed would otherwise count itself, run none of
  ## the checks, and report ``[OK]``.
  var executed = initHashSet[string]()

  let repoRoot = getCurrentDir()
  let tempRoot = createTempDir("repro-p3-refusal", "")
  var daemon: DaemonHandle
  var runQuotaError = ""
  try:
    daemon = startRunQuotaDaemon(repoRoot, tempRoot)
  except CatchableError as err:
    runQuotaError = err.msg

  ## MUST BE A TEMPLATE, NOT A PROC. ``unittest.check`` writes to
  ## ``testStatusIMPL``, which the ``test`` template declares as a local;
  ## inside a proc the assignment binds elsewhere and a failed ``check``
  ## prints "Check failed" while the case still reports ``[OK]``. That has
  ## been observed for real in this suite.
  template checkRefused(res: ActionResult; workRoot, phrase, label: string) =
    if res.status != asFailed:
      echo "[", label, "] the action was NOT refused: status=", res.status,
        " exit=", res.exitCode,
        "\n  monitorReads: ", res.evidence.monitorReads.len, " entries",
        "\n  stderr: ", res.stderr,
        "\n  A hosted plan reached a launch site that starts no host. If it",
        " succeeded, it succeeded UNMONITORED."
    check res.status == asFailed

    # PRIMARY ASSERTION. The refusal has to happen INSTEAD of the launch,
    # not alongside it. This is the one that separates "refused" from
    # "printed a sentence and ran it anyway", and it is the one that
    # reddens when the guard is removed.
    if fileExists(workRoot / ProducedName):
      echo "[", label, "] ", ProducedName, " exists: the action RAN.",
        " Whatever the engine reported, the child was launched — and on",
        " this launch path a hosted plan is launched with no wrapper and",
        " no host, i.e. unmonitored."
    check not fileExists(workRoot / ProducedName)
    check res.stdout.len == 0

    # And it failed for THIS reason rather than for some other one.
    check "in-process monitor hosting was requested" in res.stderr
    check phrase in res.stderr
    check "unmonitored" in res.stderr

  suite "P3 unhostable launch paths refuse a hosted plan":
    test "the inline RunQuota path refuses instead of running unmonitored":
      if runQuotaError.len > 0:
        # A FAILURE, NOT A SKIP. ``requireRunQuotaDaemonBin`` already raises
        # when the binary is absent and ``just test`` builds it, so every
        # way of reaching this branch is a broken fixture — and a broken
        # fixture that reports ``[SKIPPED]`` reports a green run over the
        # case that carries this file's whole point.
        echo "[L3] the RunQuota fixture did not come up: ", runQuotaError,
          "\n  Fix the fixture; do not skip the case."
        check runQuotaError.len == 0
      else:
        let caseDir = tempRoot / "inline"
        let workRoot = prepareWork(caseDir)
        let cacheRoot = caseDir / ".repro-cache"
        let run = runBuild(graph([monitoredShellAction("p3-inline", workRoot)]),
          requiredHostingConfig(repoRoot, cacheRoot, mlpInlineRunQuota))
        check run.results.len == 1
        checkRefused(run.results[0], workRoot,
          "inline RunQuota launch path", "L3")
        # Nothing was hosted either — the refusal is not "hosted it after
        # all under a different name".
        check inProcessHostCaptureFiles(cacheRoot) == 0
        executed.incl "inline"

    test "the RunQuota helper path refuses instead of dropping its lease":
      ## The helper path cannot host for a DIFFERENT reason — the action is
      ## started two processes deep, by ``repro __repro-runquota-helper`` —
      ## and its failure mode is different too: a hosted plan here would be
      ## monitored, but launched by the engine with no RunQuota lease at
      ## all. Refusing is the same answer for both.
      if runQuotaError.len > 0:
        echo "[L2] the RunQuota fixture did not come up: ", runQuotaError,
          "\n  Fix the fixture; do not skip the case."
        check runQuotaError.len == 0
      else:
        let caseDir = tempRoot / "helper"
        let workRoot = prepareWork(caseDir)
        let cacheRoot = caseDir / ".repro-cache"
        let run = runBuild(graph([monitoredShellAction("p3-helper", workRoot)]),
          requiredHostingConfig(repoRoot, cacheRoot, mlpRunQuotaHelper))
        check run.results.len == 1
        checkRefused(run.results[0], workRoot,
          "RunQuota helper launch path", "L2")
        check inProcessHostCaptureFiles(cacheRoot) == 0
        executed.incl "helper"

    test "the bypass path really hosts under the same required mode":
      ## THE CONTROL, and it is not a formality. Every assertion above is
      ## satisfied by an engine that refuses everything, which would close
      ## the hazard by breaking hosting altogether. This case asks for
      ## hosting in the same mode on the one path that CAN host and requires
      ## it to succeed, be hosted in-process, and be monitored.
      let caseDir = tempRoot / "bypass"
      let workRoot = prepareWork(caseDir)
      let cacheRoot = caseDir / ".repro-cache"
      let run = runBuild(graph([monitoredShellAction("p3-bypass", workRoot)]),
        requiredHostingConfig(repoRoot, cacheRoot, mlpBypassRunQuota))
      check run.results.len == 1
      let res = run.results[0]
      if res.status != asSucceeded:
        echo "[L1] the control action failed exit=", res.exitCode,
          "\n  diagnostics: ", res.evidence.diagnostics.join("; "),
          "\n  stderr: ", res.stderr
      check res.status == asSucceeded
      check fileExists(workRoot / ProducedName)
      # It really was HOSTED, not merely monitored by a wrapper child.
      check inProcessHostCaptureFiles(cacheRoot) > 0
      # And it really was MONITORED: the child's read of the marker reached
      # the engine's evidence.
      check res.monitorDepfilePath.len > 0
      check fileExists(res.monitorDepfilePath)
      var sawMarker = false
      for p in res.evidence.monitorReads:
        if p == expandFilename(workRoot / MarkerName):
          sawMarker = true
      if not sawMarker:
        echo "[L1] monitorReads (", res.evidence.monitorReads.len,
          " entries) did not contain ", expandFilename(workRoot / MarkerName),
          "\n  entries: ", res.evidence.monitorReads.join("\n            "),
          "\n  depfileInputs: ", res.evidence.depfileInputs.join(" "),
          "\n  diagnostics: ", res.evidence.diagnostics.join("; ")
      check sawMarker
      executed.incl "bypass"

    test "every launch path either hosts or has a refusal to give":
      ## The table and the diagnostic are one statement in two places, so
      ## they are held to each other rather than each being trusted: a path
      ## that cannot host MUST have a sentence to fail with, and a path that
      ## can host must not have one. A new ``MonitorLaunchPath`` member does
      ## not compile until ``launchPathHostsMonitorInProcess`` classifies it;
      ## this is what stops it from being classified as unhostable and then
      ## refusing with an empty message.
      var hostable = 0
      for path in MonitorLaunchPath:
        if launchPathHostsMonitorInProcess(path):
          inc hostable
          check monitorHostingRefusal(path).len == 0
        else:
          check monitorHostingRefusal(path).len > 0
          check "unmonitored" in monitorHostingRefusal(path)
        # The default mode never asks for hosting anywhere, and
        # ``mhmRequired`` always does — that second half is what carries an
        # impossible request to the launch site instead of downgrading it.
        check not monitorHostingRequested(mhmNever, path)
        check monitorHostingRequested(mhmRequired, path)
        check monitorHostingRequested(mhmWhereSupported, path) ==
          launchPathHostsMonitorInProcess(path)
      # NOT VACUOUS in either direction: an empty enum, or a table that said
      # "nothing hosts", would satisfy every check in the loop.
      check hostable == 1
      check launchPathHostsMonitorInProcess(mlpBypassRunQuota)

    test "every case in this file actually executed":
      ## The three cases above are the whole file. Two of them need a
      ## daemon, and a fixture failure that turned into a skip is exactly
      ## how a coverage gate reports a clean run it did not do.
      if runQuotaError.len > 0:
        echo "the RunQuota fixture did not come up: ", runQuotaError
      check runQuotaError.len == 0
      for name in ["inline", "helper", "bypass"]:
        if name notin executed:
          echo "case '", name, "' did not run to the end of its assertions"
        check name in executed

    test "teardown":
      daemon.stop()
      removeDir(tempRoot)
      # ``check true`` could not fail, so a teardown that silently left the
      # daemon running or the scratch tree on disk would still report [OK].
      # Assert the post-state the teardown exists to produce.
      check not dirExists(tempRoot)
      check not daemon.started
