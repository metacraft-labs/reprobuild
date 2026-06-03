import std/[json, os, osproc, strutils, tempfiles, times, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc publicReproDaemonBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro-daemon", ExeExt)

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
  result = startProcess(publicReproDaemonBin(),
    args = @["--foreground"] & daemonArgs(tempRoot),
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
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=require",
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--report=none",
    "--no-runquota"
  ] & @extra, daemonEnv(tempRoot))

proc statsArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    "--project-root=" & projectRoot,
    "--target=" & projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache"
  ]

proc graphArgs(projectRoot, tempRoot: string): seq[string] =
  @[
    projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache"
  ]

proc statsStorePath(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "observations.jsonl"

proc waitForStatsStore(projectRoot: string; timeoutSeconds = 20.0) =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(statsStorePath(projectRoot)) and
        readFile(statsStorePath(projectRoot)).contains(
          "reprobuild.daemon.stats-observation.v1"):
      return
    sleep(50)
  if fileExists(statsStorePath(projectRoot)):
    checkpoint(readFile(statsStorePath(projectRoot)))
  raise newException(IOError, "timed out waiting for stats store")

proc runStatsJson(projectRoot, tempRoot: string;
                  args: openArray[string]): JsonNode =
  parseJson(requireSuccess(shellCommand(@[publicReproBin(), "stats"] & @args &
    statsArgs(projectRoot, tempRoot) & @["--json"], daemonEnv(tempRoot)),
    repoRoot()).strip())

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
      var daemon: owned(Process)
      defer:
        closeForegroundDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startForegroundDaemon(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "daemonM8Rank", 3)
      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
      waitForStatsStore(projectRoot)

      let actions = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=actions", "--by=cache-miss-count"])
      check actions{"schemaId"}.getStr() == "reprobuild.stats.rank.v1"
      check actions{"scope"}.getStr() == "actions"
      check actions{"rows"}.len > 0

      let inputCount = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=actions", "--by=input-count"])
      check inputCount{"metric"}.getStr() == "input-count"
      check inputCount{"rows"}.len > 0

      let peakMemory = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=actions", "--by=peak-memory"])
      check not peakMemory{"availability"}{"available"}.getBool()
      check peakMemory{"availability"}{"reason"}.getStr().contains("not captured")

      let inputs = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=inputs", "--by=blast-radius"])
      check inputs{"scope"}.getStr() == "inputs"
      check inputs{"graph"}{"loweredGraphCachePath"}.getStr().len > 0
      check inputs{"rows"}.len > 0

      let inputUnavailable = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=inputs", "--by=change-frequency"])
      check not inputUnavailable{"availability"}{"available"}.getBool()

      let targets = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=targets", "--by=build-time"])
      check targets{"scope"}.getStr() == "targets"
      check targets{"rows"}.len > 0

      let tools = runStatsJson(projectRoot, tempRoot,
        ["rank", "--scope=tools", "--by=cache-hit-ratio"])
      check tools{"scope"}.getStr() == "tools"
      check tools{"rows"}.len > 0

    test "integration_stats_snapshot_compare":
      let tempRoot = createTempDir("repro-daemon-m8-snapshot", "")
      var daemon: owned(Process)
      defer:
        closeForegroundDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startForegroundDaemon(tempRoot)

      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "daemonM8Snapshot", 2)
      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
      waitForStatsStore(projectRoot)

      let baseline = runStatsJson(projectRoot, tempRoot,
        ["snapshot", "--label=before"])
      check baseline{"schemaId"}.getStr() == "reprobuild.stats.snapshot.v1"
      check fileExists(projectRoot / ".repro" / "stats" / "snapshots" / "before.json")

      waitForTimestampBoundary()
      writeFile(projectRoot / "src" / "input-0.txt", "changed\n")
      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
      waitForStatsStore(projectRoot)
      let candidate = runStatsJson(projectRoot, tempRoot,
        ["snapshot", "--label=after"])
      check candidate{"window"}{"observationCount"}.getInt() >=
        baseline{"window"}{"observationCount"}.getInt()

      let compare = runStatsJson(projectRoot, tempRoot,
        ["compare", "--baseline=before", "--candidate=after"])
      check compare{"schemaId"}.getStr() == "reprobuild.stats.compare.v1"
      check compare{"deltas"}{"observationCount"}.getInt() >= 0
      check compare{"rollupDeltas"}{"actionsByCacheMissCount"}.len > 0
      check compare{"rollupDeltas"}{"actionsByCacheMissCount"}[0]{"actionId"}.getStr().len > 0
      check compare{"rollupDeltas"}{"targetsByBuildTime"}.len > 0

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
        ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
      waitForStatsStore(projectRoot)

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
