import std/[json, os, osproc, strutils, tempfiles, times, unittest]

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / "repro"

proc publicReproDaemonBin(): string =
  repoRoot() / "build" / "bin" / "repro-daemon"

proc daemonEndpoint(tempRoot: string): string =
  "/tmp" / (tempRoot.extractFilename & ".sock")

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

proc buildCommand(projectRoot, tempRoot, workName, benchmarkPath: string;
                  daemonMode = "require"; extra: openArray[string] = []):
    string =
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--daemon=" & daemonMode,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=quiet",
    "--report=none",
    "--no-runquota",
    "--benchmark=" & benchmarkPath
  ] & @extra, daemonEnv(tempRoot))

proc executedActions(path: string): int =
  parseFile(path){"phases"}{"executedActions"}.getInt()

proc phaseUs(path, name: string): float =
  parseFile(path){"phases"}{name}.getFloat()

proc metricPresent(path, name: string): bool =
  for item in parseFile(path){"metrics"}.getElems():
    if item{"name"}.getStr() == name:
      return true

proc waitForTimestampBoundary() =
  sleep(1100)

proc actionHotIndexPath(tempRoot: string): string =
  tempRoot / "action-cache" / "action-cache" / "action-results.hot.index"

suite "Local daemons/control-plane M6 warm no-op path":
  test "benchmark_daemon_noop_build_warm_path":
    let tempRoot = createTempDir("repro-daemon-m6-benchmark", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectRoot = tempRoot / "large-project"
    writeCopyProject(projectRoot, "daemonM6Large", 80)

    let coldBenchmark = tempRoot / "cold-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      coldBenchmark), repoRoot())
    check executedActions(coldBenchmark) == 80

    let warmBenchmark = tempRoot / "warm-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      warmBenchmark), repoRoot())
    check executedActions(warmBenchmark) == 0
    check phaseUs(warmBenchmark, "daemonConnectionUs") > 0.0
    check phaseUs(warmBenchmark, "graphReadinessUs") >= 0.0
    check phaseUs(warmBenchmark, "invalidationChecksUs") > 0.0
    check phaseUs(warmBenchmark, "cacheChecksUs") > 0.0
    check metricPresent(warmBenchmark, "repro lowered graph cache read")
    check metricPresent(warmBenchmark, "repro fast noop scan")
    check fileExists(actionHotIndexPath(tempRoot))

  test "integration_direct_and_daemon_share_incremental_records":
    let tempRoot = createTempDir("repro-daemon-m6-shared", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectRoot = tempRoot / "project"
    writeCopyProject(projectRoot, "daemonM6Shared", 1)

    let directBenchmark = tempRoot / "direct-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      directBenchmark, daemonMode = "off"), repoRoot())
    check executedActions(directBenchmark) == 1
    check fileExists(actionHotIndexPath(tempRoot))
    check readFile(projectRoot / "dist" / "output-0.txt") == "input 0\n"

    let daemonNoopBenchmark = tempRoot / "daemon-noop-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      daemonNoopBenchmark), repoRoot())
    check executedActions(daemonNoopBenchmark) == 0

    waitForTimestampBoundary()
    writeFile(projectRoot / "src" / "input-0.txt", "changed\n")
    let daemonChangedBenchmark = tempRoot / "daemon-changed-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      daemonChangedBenchmark), repoRoot())
    check executedActions(daemonChangedBenchmark) == 1
    check readFile(projectRoot / "dist" / "output-0.txt") == "changed\n"

    let directNoopBenchmark = tempRoot / "direct-noop-benchmark.json"
    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      directNoopBenchmark, daemonMode = "off"), repoRoot())
    check executedActions(directNoopBenchmark) == 0
