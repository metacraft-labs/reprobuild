import std/[json, os, osproc, posix, streams, strutils, tempfiles,
  times, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc daemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc daemonStateDir(tempRoot: string): string =
  tempRoot / "state"

proc daemonLogPath(tempRoot: string): string =
  daemonStateDir(tempRoot) / "logs" / "repro-daemon.log"

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", daemonStateDir(tempRoot),
    "--log", daemonLogPath(tempRoot)
  ]

proc daemonEnv(tempRoot: string): seq[(string, string)] =
  @[
    ("REPRO_DAEMON_ENDPOINT", daemonEndpoint(tempRoot)),
    ("REPRO_DAEMON_STATE_DIR", daemonStateDir(tempRoot)),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store")
  ]

proc stopDaemon(tempRoot: string) =
  discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop"] &
    daemonArgs(tempRoot)), repoRoot())
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

proc waitForDaemonRunning(tempRoot: string; timeoutSeconds = 60.0) =
  let deadline = epochTime() + timeoutSeconds
  var lastOutput = ""
  while epochTime() < deadline:
    let res = runShell(shellCommand(@[publicReproBin(), "daemon", "status"] &
      daemonArgs(tempRoot)), repoRoot())
    lastOutput = res.output
    if res.code == 0 and res.output.contains("repro daemon: running"):
      return
    sleep(25)
  checkpoint(lastOutput)
  if fileExists(daemonLogPath(tempRoot)):
    checkpoint(readFile(daemonLogPath(tempRoot)))
  raise newException(IOError, "timed out waiting for foreground daemon")

proc startForegroundDaemon(tempRoot: string): owned(Process) =
  createDir(daemonStateDir(tempRoot))
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard
  # Executable-Consolidation M2 (commit b62edf0): the daemon process
  # is now ``repro daemon serve …`` -- the standalone ``repro-daemon``
  # binary was retired. Spawn via the public ``repro`` image; the
  # daemon role is selected by the ``daemon serve`` subcommand.
  result = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground"] & daemonArgs(tempRoot),
    workingDir = repoRoot(),
    options = {poUsePath, poStdErrToStdOut})
  try:
    waitForDaemonRunning(tempRoot)
  except CatchableError:
    if result.running():
      result.terminate()
      discard result.waitForExit()
    result.close()
    raise

proc closeForegroundDaemon(daemon: var owned(Process); tempRoot: string) =
  stopDaemon(tempRoot)
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

proc nimString(value: string): string =
  value.escape()

proc writeCopyProject(projectRoot, packageName: string; actionCount: int) =
  createDir(projectRoot / "src")
  for i in 0 ..< actionCount:
    writeFile(projectRoot / "src" / ("input-" & $i & ".txt"),
      "input " & $i & "\n")
  var body = "import repro_project_dsl\n\npackage " & packageName & ":\n" &
    "  build:\n"
  for i in 0 ..< actionCount:
    body.add("    discard fs.copyFile(actionId = " &
      nimString(packageName & "-copy-" & $i) & ", source = " &
      nimString("src/input-" & $i & ".txt") & ", output = " &
      nimString("dist/output-" & $i & ".txt") & ")\n")
  writeFile(projectRoot / "reprobuild.nim", body)

proc buildCommand(projectRoot, tempRoot, workName: string;
                  extra: openArray[string] = []): CmdSpec =
  ## The daemon-hosted build the graph-views case drives. It reads no stats,
  ## so it keeps ``--no-runquota``.
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=require",
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--measure=none",
    "--no-runquota"
  ] & @extra, daemonEnv(tempRoot))

# ---------------------------------------------------------------------------
# THE STATS CASES READ RUNQUOTA'S SHARED OBSERVATION STORE (M18).
#
# These two cases used to wait for ``<project>/.repro/stats/observations.jsonl``
# (schema ``reprobuild.daemon.stats-observation.v1``), written by a
# daemon-hosted ``--stats-groups`` build. M18 (404d7284b, "repro stats reads
# the shared observation store") retired that store: Retired-Names.md
# §"Analytics store paths and schema ids" lists it as "Superseded rather than
# migrated: nothing reads it", and Build-Analytics-And-Optimization.md §"Two
# Stores" puts raw per-execution rows in RunQuota's observation store, read
# through ``runquotad``. ``t_stats_reads_shared_store`` asserts that the
# daemon-hosted capture path no longer writes the file, so the old wait could
# only time out.
#
# So each case now starts its OWN ``runquotad`` on a private rendezvous, runs
# a build whose PROCESS actions take leases from it, and reads ``repro stats``
# back from that daemon through ``RUNQUOTA_SOCKET``, the same harness
# ``t_stats_reads_shared_store`` uses. The observation writer drains on a
# tick, so the cases poll the ranking for a MINIMUM number of rows rather
# than for a file.
# ---------------------------------------------------------------------------

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

type RunQuotaHandle = object
  process: Process
  socketRoot: string
  socketPath: string

proc startRunQuotaDaemon(tag: string): RunQuotaHandle =
  ## A private ``runquotad`` per case. The socket's parent is the rendezvous
  ## directory RunQuota verifies (owner-only), so it is created through
  ## ``runquotaRendezvousDir`` rather than dropped into the temp dir.
  result.socketRoot = getTempDir() / ("rq-m8" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.socketRoot)
  createDir(result.socketRoot)
  result.socketPath = runquotaRendezvousDir(result.socketRoot) / "d.sock"
  let stateDir = result.socketRoot / "state"
  createDir(stateDir)
  result.process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", result.socketPath,
             "--host-identity-file", stateDir / "host-id",
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(result.socketPath): break
    sleep(25)
  if not socketIsBound(result.socketPath):
    raise newException(IOError,
      "runquotad did not bind " & result.socketPath)
  for _ in 0 ..< 3:
    discard result.process.outputStream.readLine()

proc stop(handle: var RunQuotaHandle) =
  if handle.process.isNil:
    return
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()
  handle.process = nil
  removeDir(handle.socketRoot)

proc writeLeasedProject(projectRoot, packageName: string; actionCount: int) =
  ## PROCESS actions, not ``fs.copyFile``. A built-in copy runs inside the
  ## engine and takes no RunQuota lease, so it leaves no execution row in the
  ## shared store and there would be nothing for ``repro stats`` to rank.
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
      nimString("m8-copy-" & $i) & ",\n" &
      "        " & packageName & ".executable(\"sh\").subcmd_2d_c(\n" &
      "          args = @[" & nimString(script) & ", " & nimString("sh") &
        ", " & nimString(inputRel) & ", " & nimString(outputRel) & "]),\n" &
      "        inputs = @[" & nimString(inputRel) & "],\n" &
      "        outputs = @[" & nimString(outputRel) & "],\n" &
      "        cacheable = true)\n")
  writeFile(projectRoot / "reprobuild.nim", body)

proc leasedBuild(projectRoot, tempRoot, workName, socketPath: string): string =
  ## A build that TAKES LEASES from the case's ``runquotad`` (no
  ## ``--no-runquota``): the shared store is filled only by leased
  ## executions.
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

proc statsArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    "--project-root=" & projectRoot,
    "--target=" & projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache"
  ]

proc runStatsJson(projectRoot, tempRoot, socketPath: string;
                  args: openArray[string]): JsonNode =
  parseJson(requireSuccess(shellCommand(@[publicReproBin(), "stats"] & @args &
    statsArgs(projectRoot, tempRoot) & @["--json"],
    @[("RUNQUOTA_SOCKET", socketPath)]), repoRoot()).strip())

proc fixtureActionRows(rank: JsonNode): int =
  ## Rows for THIS fixture's actions. The provider compile and interface
  ## extraction also take leases, so a bare row count could be met without
  ## a single fixture action having been recorded.
  for row in rank{"rows"}:
    if row{"actionId"}.getStr().contains("m8-copy-"):
      inc result

proc waitForFixtureRows(projectRoot, tempRoot, socketPath: string;
                        atLeast: int; minObservations = 0): JsonNode =
  ## The observation writer drains on a tick, so a query issued right after
  ## the build can legitimately see nothing yet. Poll for a MINIMUM: a later
  ## read cannot turn a recorded row back into an absent one.
  let deadline = epochTime() + 60.0
  while true:
    result = runStatsJson(projectRoot, tempRoot, socketPath,
      ["rank", "--scope=actions", "--by=cache-miss-count"])
    if fixtureActionRows(result) >= atLeast and
        result{"window"}{"observationCount"}.getInt(0) >= minObservations:
      return
    if epochTime() >= deadline:
      checkpoint($result)
      return
    sleep(200)

proc graphArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache"
  ]

proc runGraphJson(projectRoot, tempRoot: string;
                  args: openArray[string]): JsonNode =
  parseJson(requireSuccess(shellCommand(@[publicReproBin(), "graph"] &
    graphArgs(projectRoot, tempRoot) & @args & @["--json"], daemonEnv(tempRoot)),
    repoRoot()).strip())

proc waitForTimestampBoundary() =
  sleep(1100)

suite "Local daemons/control-plane M8 graph and stats analysis":
  when isNixSupported:
    test "integration_stats_rank_core_scopes":
      let tempRoot = createTempDir("repro-daemon-m8-rank", "")
      var runquota = startRunQuotaDaemon("r")
      defer:
        runquota.stop()
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeLeasedProject(projectRoot, "daemonM8Rank", 3)
      discard leasedBuild(projectRoot, tempRoot, "work", runquota.socketPath)

      let actions = waitForFixtureRows(projectRoot, tempRoot,
        runquota.socketPath, 3)
      check actions{"schemaId"}.getStr() == "reprobuild.stats.rank.v1"
      check actions{"scope"}.getStr() == "actions"
      check actions{"rows"}.len > 0
      # NON-VACUITY: all three fixture actions were recorded, as executions
      # read back from the shared store.
      check fixtureActionRows(actions) >= 3
      check actions{"availability"}{"available"}.getBool(false)

      let inputCount = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["rank", "--scope=actions", "--by=input-count"])
      check inputCount{"metric"}.getStr() == "input-count"
      check inputCount{"rows"}.len > 0

      let peakMemory = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["rank", "--scope=actions", "--by=peak-memory"])
      check not peakMemory{"availability"}{"available"}.getBool()
      check peakMemory{"availability"}{"reason"}.getStr().contains("not captured")

      let inputs = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["rank", "--scope=inputs", "--by=blast-radius"])
      check inputs{"scope"}.getStr() == "inputs"
      check inputs{"graph"}{"loweredGraphCachePath"}.getStr().len > 0
      check inputs{"rows"}.len > 0

      let inputUnavailable = runStatsJson(projectRoot, tempRoot,
        runquota.socketPath, ["rank", "--scope=inputs", "--by=change-frequency"])
      check not inputUnavailable{"availability"}{"available"}.getBool()

      # TARGETS ARE NOT A DIMENSION OF THE SHARED STORE. Under M7 this ranked
      # rows from the project-local JSONL, which was written by the command
      # that knew the target. RunQuota's execution spine (and
      # ``ext_repro_action`` v1) carries host, profile, stats key, owner and
      # outcome, but no reprobuild target, so since M18 (404d7284b) the
      # view reports itself unavailable and names the scopes that can answer
      # (``targetRankJson`` in repro_cli_support). An empty ranking marked
      # available would claim "no target was slow". The same behaviour is
      # gated in ``t_stats_reads_shared_store``.
      let targets = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["rank", "--scope=targets", "--by=build-time"])
      check targets{"scope"}.getStr() == "targets"
      check not targets{"availability"}{"available"}.getBool(true)
      check targets{"rows"}.len == 0
      check targets{"availability"}{"reason"}.getStr().contains(
        "no reprobuild target dimension")

      let tools = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["rank", "--scope=tools", "--by=cache-hit-ratio"])
      check tools{"scope"}.getStr() == "tools"
      check tools{"rows"}.len > 0

    test "integration_stats_snapshot_compare":
      let tempRoot = createTempDir("repro-daemon-m8-snapshot", "")
      var runquota = startRunQuotaDaemon("s")
      defer:
        runquota.stop()
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeLeasedProject(projectRoot, "daemonM8Snapshot", 2)
      discard leasedBuild(projectRoot, tempRoot, "work", runquota.socketPath)
      let firstRank = waitForFixtureRows(projectRoot, tempRoot,
        runquota.socketPath, 2)
      check fixtureActionRows(firstRank) >= 2

      let baseline = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["snapshot", "--label=before"])
      check baseline{"schemaId"}.getStr() == "reprobuild.stats.snapshot.v1"
      check fileExists(projectRoot / ".repro" / "stats" / "snapshots" / "before.json")
      let baselineCount = baseline{"window"}{"observationCount"}.getInt()
      check baselineCount >= 2

      waitForTimestampBoundary()
      writeFile(projectRoot / "src" / "input-0.txt", "changed\n")
      discard leasedBuild(projectRoot, tempRoot, "work", runquota.socketPath)
      # The changed input re-executes ``m8-copy-0``, which adds an execution
      # row; wait for the window to include it before taking the candidate.
      discard waitForFixtureRows(projectRoot, tempRoot, runquota.socketPath, 2,
        minObservations = baselineCount + 1)
      let candidate = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["snapshot", "--label=after"])
      check candidate{"window"}{"observationCount"}.getInt() >
        baseline{"window"}{"observationCount"}.getInt()

      let compare = runStatsJson(projectRoot, tempRoot, runquota.socketPath,
        ["compare", "--baseline=before", "--candidate=after"])
      check compare{"schemaId"}.getStr() == "reprobuild.stats.compare.v1"
      check compare{"deltas"}{"observationCount"}.getInt() > 0
      check compare{"rollupDeltas"}{"actionsByCacheMissCount"}.len > 0
      check compare{"rollupDeltas"}{"actionsByCacheMissCount"}[0]{"actionId"}.getStr().len > 0
      # THE TARGET ROLLUP WAS REPLACED BY THE TOOL ROLLUP IN M18 (404d7284b):
      # targets are not a dimension of the shared store (see the rank case),
      # so ``snapshotJson`` no longer records ``targetsByBuildTime`` and
      # rolls up by RunQuota stats key instead. Asserted as present-and-
      # populated for the replacement and absent for the retired key, so a
      # snapshot that kept the old key filled with nothing would fail.
      check compare{"rollupDeltas"}{"toolsByCacheHitRatio"}.len > 0
      check not compare{"rollupDeltas"}.hasKey("targetsByBuildTime")

    test "integration_graph_analysis_views":
      let tempRoot = createTempDir("repro-daemon-m8-graph", "")
      var daemon: owned(Process)
      defer:
        closeForegroundDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startForegroundDaemon(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "daemonM8Graph", 2)
      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-groups=timing,cache,runquota,deps,sessions"]), repoRoot())
      # No wait on `.repro/stats/observations.jsonl` here any more. That raw
      # store was retired by M18 (404d7284b; `Retired-Names.md` §"Analytics
      # store paths and schema ids") and a daemon-hosted build no longer
      # writes it — `t_stats_reads_shared_store` asserts exactly that — so
      # the wait could only time out. Nothing below reads the stats store:
      # every view is answered from the lowered graph the (synchronous)
      # build above left behind.

      let baseGraph = runGraphJson(projectRoot, tempRoot, [])
      let actionId = baseGraph{"actions"}[0]{"id"}.getStr()
      let inputPath = baseGraph{"actions"}[0]{"inputs"}[0].getStr()

      writeFile(projectRoot / "dist" / "output-0.txt", "sentinel\n")
      let neighborhood = runGraphJson(projectRoot, tempRoot,
        ["--view=neighborhood", "--focus=" & actionId])
      check neighborhood{"schemaId"}.getStr() == "reprobuild.graph.analysis-view.v1"
      check neighborhood{"view"}.getStr() == "neighborhood"

      let inputs = runGraphJson(projectRoot, tempRoot,
        ["--view=inputs", "--focus=" & actionId])
      check inputs{"inputs"}.len > 0

      let dependents = runGraphJson(projectRoot, tempRoot,
        ["--view=dependents", "--path=" & inputPath])
      check dependents{"directDependentCount"}.getInt() > 0

      let blast = runGraphJson(projectRoot, tempRoot,
        ["--view=blast-radius", "--path=" & inputPath])
      check blast{"blastRadiusCount"}.getInt() >=
        dependents{"directDependentCount"}.getInt()

      let critical = runGraphJson(projectRoot, tempRoot,
        ["--view=critical-path", "--run=last"])
      check critical{"view"}.getStr() == "critical-path"
      check not critical{"availability"}{"available"}.getBool()

      let partition = runGraphJson(projectRoot, tempRoot,
        ["--view=partition-candidates", "--kind=dylib"])
      check not partition{"availability"}{"available"}.getBool()
      check partition{"availability"}{"reason"}.getStr().contains("deferred")

      check readFile(projectRoot / "dist" / "output-0.txt") == "sentinel\n"
