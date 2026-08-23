## ``every_launch_path_is_monitored`` — the coverage gate for io-monitor
## hosting.
##
## WHY THIS TEST EXISTS
## --------------------
## A build action's dependency evidence is only as good as the guarantee
## that the monitor was actually wrapped around it. A launch path that
## misses the monitor is **silently unmonitored**: the child runs, the
## action succeeds, the cache entry publishes, and the recorded
## dependency set is wrong. Nothing in the build output says so.
##
## The engine reaches the OS through several different spawn sites, and
## the set of them is not obvious from any single grep — the tokens
## ``bypassRunQuota`` / ``inlineRunQuota`` / ``fallbackToRunQuotaBypass``
## occur 63x in ``repro_cli_support.nim``, 42x in
## ``repro_build_engine.nim`` and in three further files, and not one of
## those occurrences is a spawn: they are CLI flags, config fields and
## forwarded parameters. This file pins the actual enumeration and
## exercises it against real processes.
##
##
## THE ENUMERATION
## ---------------
## Derived by reading ``libs/repro_build_engine/src/repro_build_engine.nim``
## and following every branch that can turn a ready action into a running
## child. Line numbers are as of the revision this file was written
## against; the first test case re-derives the row set from the source
## TEXT so the list cannot silently fall out of date when lines move.
##
## The three-way launch decision is taken at ``:6170-6176``.
##
##   L1  BYPASS RUNQUOTA — monitored
##       when ``launchBypassesRunQuota()`` (:5282): ``config.bypassRunQuota``,
##       ``REPROBUILD_NO_RUNQUOTA``, or ``fallbackToRunQuotaBypass`` with an
##       unreachable daemon. No lease.
##       spawn: ``startBypassRunQuotaProcess`` (:3957) -> ``startDirect``
##       (:3973), in the engine process.
##       backend label ``runquota-bypass``.
##
##   L2  RUNQUOTA HELPER PROCESS — monitored
##       when neither bypass nor inline applies.
##       spawn: ``startRunQuotaProcess`` (:3975) -> ``startProcess(helper,
##       helperCliArgs(...))`` (:3987). The argv reaches the OS two
##       processes deep: engine -> ``repro __repro-runquota-helper`` ->
##       the command.
##       backend label ``runquota-helper``.
##
##   L3  INLINE RUNQUOTA, GRANTED IMMEDIATELY — monitored
##       when ``config.inlineRunQuota`` and a session opens
##       (``tryEnsureInlineRunQuotaSession``, :5293).
##       spawn: ``offerWithRunQuotaBatch`` (:6276). NOTE: the daemon
##       grants the LEASE; it does not spawn the child. The spawn happens
##       in the engine process, inside ``startGrantedWithRunQuota``.
##       backend label ``runquota-inline``.
##
##   L3b INLINE RUNQUOTA, GRANTED AFTER QUEUEING — monitored
##       a candidate the daemon returns as ``rqokQueued`` (:6285) has NO
##       process yet. It is spawned LATER, from a different call site, in
##       the scheduler's wait loop:
##       ``pollInlineRunQuotaGrants`` -> ``startGrantedWithRunQuota``
##       (:5461), traced as ``launched``/``runquota-grant``.
##       This row is the one an enumeration written from the launch
##       decision alone would miss: it shares L3's backend label and its
##       command spec, but it is a genuinely separate spawn site reached
##       only under pool pressure.
##
##   L4  PRIVILEGED-OPERATION BROKER (elevation) — NOT monitored, by design
##       when ``action.requiresElevation`` (:5923), evaluated BEFORE the
##       monitor plan is computed, so the argv handed to
##       ``config.brokerSpawn(req)`` (:5941) is the RAW ``action.argv``.
##       The branch comment at :5910-5917 states the edge "is a one-shot
##       side-effecting spawn (no monitor depfile)". Fails closed when
##       ``brokerSpawn`` is nil.
##
##   L5  BUILT-IN ACTION — nothing to monitor
##       ``plan.action.kind != bakProcess`` (:6077) -> ``executeBuiltinAction``
##       (:6079), which explicitly refuses ``bakProcess`` (:4706).
##       ``monitoredAction`` returns early for built-ins at :2730.
##       Three built-in kinds do nevertheless run children, all outside
##       the monitor and outside RunQuota, and all deliberately:
##       ``bakWorkspaceVcs`` (git via the executor hook, :4494),
##       ``bakForeignProvision`` (the nix daemon, :4651), and post-build
##       dependency converters (``runConverter``, :2624), which run AFTER
##       the monitored action has finished.
##
## L1, L2, L3 and L3b are the monitored launch paths and this test
## exercises all four. L4 and L5 are recorded here so that "four
## monitored paths" is a decision on the record rather than an omission.
##
##
## THE TWO SEAMS
## -------------
## Four launch paths do not need four monitor wirings, because they share
## both halves of the wiring:
##
##   * ARGV — the monitor wrapper is prepended in exactly ONE proc,
##     ``monitoredAction`` (:2710), called from exactly ONE site (:6063).
##   * ARGV+ENV CONTRACT — all four paths obtain their ``ReproCommandSpec``
##     from exactly ONE proc, ``preparedRunQuotaCommand`` (:3929), whose
##     own doc-comment says it exists to "Build one argv/env contract for
##     direct, helper, and inline launches". L3b reuses the spec L3's
##     batch offer already built.
##
## So a host that has to be threaded through "every launch path" has two
## seams to thread, not sixty-three. The first test case pins both
## call-site counts and every spawn site in the module, so a fifth path
## forces this enumeration to be revisited rather than silently joining
## the set unmonitored.
##
##
## NO MOCKS
## --------
## Every case runs the real ``repro`` binary as the monitor driver, the
## real graph-built monitor shim, a real compiled C fixture performing a
## real ``open``/``read`` of a real file, and — for L2, L3 and L3b — the
## real ``repro __repro-runquota-helper`` and a real ``runquotad`` daemon
## over a real unix socket. Nothing is stubbed. The oracle is the
## dependency evidence the engine actually produced, not a call
## assertion.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support

type
  LaunchPathKind = enum
    lpBypassRunQuota          ## L1
    lpRunQuotaHelper          ## L2
    lpInlineRunQuota          ## L3
    lpInlineRunQuotaQueued    ## L3b

  LaunchPath = object
    kind: LaunchPathKind
    name: string
    spawnSite: string
      ## The proc in ``repro_build_engine.nim`` that performs the spawn.
    needsRunQuota: bool

const EnumeratedLaunchPaths: array[4, LaunchPath] = [
  LaunchPath(kind: lpBypassRunQuota, name: "L1 bypass-runquota",
    spawnSite: "startBypassRunQuotaProcess", needsRunQuota: false),
  LaunchPath(kind: lpRunQuotaHelper, name: "L2 runquota-helper",
    spawnSite: "startRunQuotaProcess", needsRunQuota: true),
  LaunchPath(kind: lpInlineRunQuota, name: "L3 inline-runquota",
    spawnSite: "offerWithRunQuotaBatch", needsRunQuota: true),
  LaunchPath(kind: lpInlineRunQuotaQueued,
    name: "L3b inline-runquota-after-queue",
    spawnSite: "startGrantedWithRunQuota", needsRunQuota: true)
]

## A C fixture that reads a marker file and writes an output file, with
## an optional busy period so a second action can be held in the
## daemon's queue while this one holds the lease (L3b). The read is the
## observable: it can only appear in the action's evidence if the
## io-monitor shim was actually injected into this process.
const FixtureSource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) return 80;
  char buffer[256];
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  if (count < 0) return 81;
  close(fd);
  buffer[count] = '\0';
  long hold_ms = atol(argv[3]);
  if (hold_ms > 0) {
    struct timespec ts;
    ts.tv_sec = hold_ms / 1000;
    ts.tv_nsec = (hold_ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
  }
  FILE *out = fopen(argv[2], "w");
  if (out == NULL) return 82;
  fputs(buffer, out);
  fclose(out);
  return 0;
}
"""

const EngineSource = "libs/repro_build_engine/src/repro_build_engine.nim"

proc countOccurrences(haystack, needle: string): int =
  var pos = 0
  while true:
    let hit = haystack.find(needle, pos)
    if hit < 0: break
    inc result
    pos = hit + needle.len

proc statExists(path: string): bool =
  ## ``fileExists`` is false for a unix socket (it is not a regular
  ## file), so daemon readiness has to be probed with a stat.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc compileFixture(sourcePath, outputPath: string) =
  let res = execCmdEx("cc " & quoteShell(sourcePath) & " -o " &
    quoteShell(outputPath))
  if res.exitCode != 0:
    echo res.output
  doAssert res.exitCode == 0, "fixture compile failed"

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false
proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-hm4", "hm4-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

type DaemonHandle = object
  process: Process
  socket: string
  started: bool

proc startRunQuotaDaemon(repoRoot: string; cpuMilli: int): DaemonHandle =
  ## Real runquotad over a real unix socket. ``cpuMilli`` is the whole
  ## host budget: L3b needs it small enough that two concurrent actions
  ## cannot both be granted at once.
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = getTempDir() / ("repro-hm4-rq-" & $getCurrentProcessId() &
    ".sock")
  removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", $cpuMilli,
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  for _ in 0 ..< 400:
    if statExists(socketPath):
      putEnv("RUNQUOTA_SOCKET", socketPath)
      return DaemonHandle(process: daemon, socket: socketPath, started: true)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear: " & socketPath)

proc stop(handle: var DaemonHandle) =
  if not handle.started: return
  handle.process.terminate()
  discard handle.process.waitForExit()
  handle.process.close()
  removeFile(handle.socket)
  delEnv("RUNQUOTA_SOCKET")
  handle.started = false

proc configFor(lp: LaunchPath; repoRoot, cacheRoot: string):
    BuildEngineConfig =
  # The RunQuota "helper CLI" is the ``repro`` image itself: L2 spawns
  # ``repro __repro-runquota-helper …`` (helperCliArgs, repro_runquota.nim
  # :496). The standalone ``runquota`` binary is a status/acquire CLI and
  # does NOT accept that argv.
  result = BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliPath: monitorTools(repoRoot).monitorCliPath,
    monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
    maxParallelism: 2'u32,
    stdoutLimit: 256 * 1024,
    stderrLimit: 256 * 1024)
  case lp.kind
  of lpBypassRunQuota:
    result.bypassRunQuota = true
  of lpRunQuotaHelper:
    discard          # neither bypass nor inline: the helper-process path
  of lpInlineRunQuota, lpInlineRunQuotaQueued:
    result.inlineRunQuota = true

proc monitoredFixtureAction(id, fixtureBin, marker, outPath, workRoot: string;
                            holdMs: int; cpuMilli: uint32): BuildAction =
  action(id, [fixtureBin, marker, outPath, $holdMs],
    cwd = workRoot,
    inputs = [marker.extractFilename],
    outputs = [outPath.extractFilename],
    commandStatsId = id,
    cpuMilli = cpuMilli,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    dependencyPolicy = automaticMonitorGatheringPolicy())

proc mentionsPath(paths: seq[string]; wanted: string): bool =
  for p in paths:
    if p == wanted: return true
  false

proc hasTrace(run: BuildRunResult; event, detail: string): bool =
  for item in run.trace:
    if item.event == event and item.detail == detail:
      return true
  false

proc resultById(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id: return item
  raise newException(ValueError, "no result for " & id)

proc helperResultFilesWritten(cacheRoot: string): int =
  ## Only the L2 helper-process path writes a lease result JSON into
  ## ``<cacheRoot>/runquota-results/`` — ``startRunQuotaProcess`` passes
  ## ``--result <path>`` on the helper argv and reads it back in
  ## ``finishRunQuotaProcess``. Bypass and inline launches never do, so
  ## the presence or absence of these files distinguishes L2 from L1/L3
  ## at runtime rather than by trusting the config.
  let dir = cacheRoot / "runquota-results"
  if not dirExists(dir): return 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".json"):
      inc result

## ---------------------------------------------------------------------
## Path-identity oracle: prove the case really took the launch path it
## is named for, instead of quietly degrading to another one and passing
## for the wrong reason. ``runQuotaBackend`` alone cannot do this — on a
## granted lease it carries the runquota PROCESS backend name
## (``posix-fork-exec-poll``), not the engine's path label.
## ---------------------------------------------------------------------
template checkTookLaunchPath(lp: LaunchPath; run: BuildRunResult;
                             res: ActionResult; cacheRoot: string) =
  case lp.kind
  of lpBypassRunQuota:
    check run.runQuotaBypassed
    check res.runQuotaBackend == "runquota-bypass"
    check res.leaseId == 0'u64
    check helperResultFilesWritten(cacheRoot) == 0
  of lpRunQuotaHelper:
    check not run.runQuotaBypassed
    check res.leaseId != 0'u64
    check helperResultFilesWritten(cacheRoot) > 0
  of lpInlineRunQuota, lpInlineRunQuotaQueued:
    check not run.runQuotaBypassed
    check res.leaseId != 0'u64
    check helperResultFilesWritten(cacheRoot) == 0

## ---------------------------------------------------------------------
## The shared oracle: this action's dependency evidence proves the child
## was monitored.
##
## This MUST be a template, not a proc. ``unittest.check`` writes to
## ``testStatusIMPL``, which the ``test`` template declares as a local —
## inside a proc the assignment binds elsewhere and a failed ``check``
## prints its diagnostic while the case still reports ``[OK]``. That was
## observed on this very file during development: the L2 case printed
## three failed checks and passed. A silently-passing coverage test is
## the exact failure this file exists to prevent, one level up.
## ---------------------------------------------------------------------
template checkMonitoredEvidence(res: ActionResult; markerPath, label: string) =
  if res.status != asSucceeded:
    echo "[", label, "] action failed exit=", res.exitCode,
      " backend=", res.runQuotaBackend,
      "\n  diagnostics: ", res.evidence.diagnostics.join("; "),
      "\n  stdout: ", res.stdout, "\n  stderr: ", res.stderr
  check res.status == asSucceeded

  # The monitor was wired: a depfile was selected and written.
  check res.monitorDepfilePath.len > 0
  check fileExists(res.monitorDepfilePath)

  # PRIMARY ASSERTION. The child's real open()/read() of the marker
  # reached the engine's evidence. This is the property "this launch
  # path is monitored"; it is false for an unmonitored path no matter
  # how healthy the rest of the run looks.
  if not mentionsPath(res.evidence.monitorReads, markerPath):
    echo "[", label, "] monitorReads (", res.evidence.monitorReads.len,
      " entries) did not contain ", markerPath,
      "\n  diagnostics: ", res.evidence.diagnostics.join("; ")
  check mentionsPath(res.evidence.monitorReads, markerPath)

  # And the evidence is COMPLETE, not merely non-empty.
  for diagnostic in res.evidence.diagnostics:
    check not diagnostic.contains("monitor depfile read failed")
    check not diagnostic.contains(
      "requires monitor evidence but no RMDF path is selected")

suite "every_launch_path_is_monitored":

  test "the enumeration matches the engine source":
    ## A list nobody tested is not an enumeration. This re-derives the
    ## launch-path set from the engine source text, so a fifth spawn
    ## site — or a second caller of either monitor seam — cannot land
    ## without this file being revisited.
    let src = readFile(getCurrentDir() / EngineSource)

    # SEAM 1 (argv): the monitor wrapper is prepended in exactly one
    # proc, called from exactly one site.
    check countOccurrences(src, "proc monitoredAction(") == 1
    check countOccurrences(src,
      "monitoredAction(action, config, cacheRoot)") == 1

    # SEAM 2 (argv+env contract): one definition + three uses, one per
    # non-deferred launch path. L3b reuses L3's spec.
    check countOccurrences(src, "preparedRunQuotaCommand(") == 4

    # Every spawn site NAMED IN THE TABLE really exists in the engine —
    # so a row cannot describe a path that was deleted or renamed.
    for lp in EnumeratedLaunchPaths:
      if countOccurrences(src, lp.spawnSite) == 0:
        echo "enumerated launch path ", lp.name,
          " names a spawn site that is not in the engine: ", lp.spawnSite
      check countOccurrences(src, lp.spawnSite) > 0

    # Every enumerated spawn site is present, defined once and called
    # once. (The bare proc names also appear in prose comments, so the
    # pins below use the definition and call-site forms rather than a
    # raw name count, which would move whenever a comment is reworded.)
    check countOccurrences(src, "proc startBypassRunQuotaProcess(") == 1
    check countOccurrences(src,
      "startBypassRunQuotaProcess(plan.action, config)") == 1          # L1
    check countOccurrences(src, "proc startRunQuotaProcess(") == 1
    check countOccurrences(src,
      "startRunQuotaProcess(plan.action, config, resultPath)") == 1    # L2
    check countOccurrences(src, "offerWithRunQuotaBatch(") == 1        # L3
    check countOccurrences(src, "startGrantedWithRunQuota(") == 1      # L3b

    # The deliberately-unmonitored paths still have the shape this
    # enumeration recorded for them.
    check countOccurrences(src, "config.brokerSpawn(req)") == 1        # L4
    check countOccurrences(src, "executeBuiltinAction(plan.action)") == 1  # L5

    # And no NEW raw spawn primitive has appeared in the module. The
    # three permitted `startProcess` calls are: the post-build
    # dependency converter (:2624), the RunQuota helper (:3987, = L2),
    # and the foreign-provision nix daemon (:4651). `startDirect` is
    # L1's, and there is exactly one.
    check countOccurrences(src, "startProcess(") == 3
    check countOccurrences(src, "startDirect(") == 1

  test "the io-monitor subcommand argv agrees across all of its mirrors":
    ## The CLI subcommand ``repro internal io monitor`` is the debugging
    ## entry point and must keep working. Its argv is spelled in four
    ## places, and three of them are hand-written literals rather than
    ## uses of the constant — a rename in one place alone is a silently
    ## unmonitored dev session, not a compile error.
    let root = getCurrentDir()
    const Expected = ["internal", "io", "monitor"]

    # 1. The constant the engine is configured with.
    check ioMonitorCliArgs == @Expected

    # 2. The definition in repro_cli_support.
    let cliSupport = readFile(root /
      "libs/repro_cli_support/src/repro_cli_support.nim")
    check countOccurrences(cliSupport,
      "const internalIoMonitorArgs* = @[\"internal\", \"io\", \"monitor\"]") == 1

    # 3. The dispatcher that has to recognise it, both for the self-spawn
    #    (``internal``) and for the operator-facing (``debug``) spelling.
    check countOccurrences(cliSupport,
      "args[0] == \"internal\" and args[1] == \"io\" and") == 1
    check countOccurrences(cliSupport,
      "args[0] == \"debug\" and") >= 1

    # 4. The hand-copied literal in the dev-session supervisor.
    let devSession = readFile(root /
      "libs/repro_cli_support/src/repro_cli_support/dev_session.nim")
    check countOccurrences(devSession,
      "monitorCliArgs: @[\"internal\", \"io\", \"monitor\"]") == 1

  when defined(linux) or defined(macosx):
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-hm4-launch-paths", "")
    let fixtureSource = tempRoot / "fixture.c"
    let fixtureBin = tempRoot / "fixture"
    writeFile(fixtureSource, FixtureSource)
    compileFixture(fixtureSource, fixtureBin)

    # One host budget of 1000 cpu-milli; the L3b actions ask for 800
    # each, so the daemon can grant exactly one at a time and the other
    # comes back `rqokQueued`.
    var daemon: DaemonHandle
    var runQuotaError = ""
    try:
      daemon = startRunQuotaDaemon(repoRoot, cpuMilli = 1000)
    except CatchableError as err:
      runQuotaError = err.msg

    ## The monitored launch paths, parameterised over the enumeration.
    ## Looping over ``EnumeratedLaunchPaths`` rather than hand-copying a
    ## case per row is deliberate: a path added to the enumeration is
    ## exercised automatically, so it is not possible to extend the list
    ## and forget the test.
    for launchPath in EnumeratedLaunchPaths:
      let lp = launchPath
      test "monitored evidence is complete via " & lp.name:
        if lp.needsRunQuota and runQuotaError.len > 0:
          # Named, not quietly omitted.
          echo "[fixture N/A] ", lp.name,
            " needs a real runquota/runquotad: ", runQuotaError
          skip()
        else:
          let caseDir = tempRoot / ("case-" & $ord(lp.kind))
          let workRoot = caseDir / "work"
          createDir(workRoot)
          let cacheRoot = caseDir / ".repro-cache"
          let config = configFor(lp, repoRoot, cacheRoot)

          if lp.kind == lpInlineRunQuotaQueued:
            # Two actions, 800 cpu-milli each against a 1000-milli host:
            # the batch offer grants one and QUEUES the other, so the
            # queued one is spawned from the deferred site (:5461)
            # instead of from the batch flush.
            var actions: seq[BuildAction] = @[]
            for i in 0 .. 1:
              let marker = workRoot / ("marker-" & $i & ".txt")
              writeFile(marker, "hm4 marker payload " & $i & "\n")
              actions.add monitoredFixtureAction("queued-" & $i, fixtureBin,
                marker, workRoot / ("out-" & $i & ".txt"), workRoot,
                holdMs = 400, cpuMilli = 800'u32)
            let run = runBuild(graph(actions), config)
            check run.results.len == 2

            # The deferred site really was exercised: the queued
            # candidate is traced as launched by a grant, which only
            # `pollInlineRunQuotaGrants` emits.
            if not run.hasTrace("launched", "runquota-grant"):
              echo "[", lp.name,
                "] no queued-then-granted launch was observed; the ",
                "deferred spawn site was NOT exercised by this run"
            check run.hasTrace("launched", "runquota-grant")

            for i in 0 .. 1:
              let res = run.resultById("queued-" & $i)
              checkTookLaunchPath(lp, run, res, cacheRoot)
              checkMonitoredEvidence(res,
                expandFilename(workRoot / ("marker-" & $i & ".txt")),
                lp.name & " #" & $i)
          else:
            let marker = workRoot / "marker.txt"
            writeFile(marker, "hm4 marker payload\n")
            let act = monitoredFixtureAction("monitored-" & $ord(lp.kind),
              fixtureBin, marker, workRoot / "out.txt", workRoot,
              holdMs = 0, cpuMilli = 100'u32)
            let run = runBuild(graph([act]), config)
            check run.results.len == 1
            let res = run.results[0]
            checkTookLaunchPath(lp, run, res, cacheRoot)
            checkMonitoredEvidence(res, expandFilename(marker), lp.name)

    test "teardown":
      daemon.stop()
      removeDir(tempRoot)
      check true
