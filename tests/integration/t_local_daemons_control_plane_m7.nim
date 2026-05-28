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

proc requireFailure(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code == 0:
    checkpoint(res.output)
  check res.code != 0
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

proc daemonEnv(tempRoot: string;
               extra: openArray[(string, string)] = []): seq[(string, string)] =
  result = @[
    ("REPRO_DAEMON_ENDPOINT", daemonEndpoint(tempRoot)),
    ("REPRO_DAEMON_STATE_DIR", daemonStateDir(tempRoot)),
    ("REPROBUILD_STORE_ROOT", tempRoot / "store")
  ]
  for item in extra:
    result.add(item)

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
                  extra: openArray[string] = [];
                  envExtra: openArray[(string, string)] = []): string =
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
  ] & @extra, daemonEnv(tempRoot, envExtra))

proc statsStorePath(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "observations.jsonl"

proc waitForStatsStore(projectRoot: string; timeoutSeconds = 20.0) =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(statsStorePath(projectRoot)) and
        readFile(statsStorePath(projectRoot)).contains(
          "reprobuild.daemon.stats-observation.v1") and
        fileExists(projectRoot / ".repro" / "stats" / "summary.json"):
      return
    sleep(50)
  if fileExists(statsStorePath(projectRoot)):
    checkpoint(readFile(statsStorePath(projectRoot)))
  if fileExists(projectRoot / ".repro" / "stats" / "summary.json"):
    checkpoint(readFile(projectRoot / ".repro" / "stats" / "summary.json"))
  raise newException(IOError, "timed out waiting for stats store")

suite "Local daemons/control-plane M7 stats capture":
  test "integration_daemon_stats_capture_opt_in":
    let tempRoot = createTempDir("repro-daemon-m7-stats", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectRoot = tempRoot / "project"
    writeCopyProject(projectRoot, "daemonM7Stats", 2)

    let directCapture = requireFailure(shellCommand([
      publicReproBin(), "build", projectRoot,
      "--daemon=off",
      "--tool-provisioning=path",
      "--work-root=" & tempRoot / "direct-work",
      "--stats-capture=timing",
      "--no-runquota"
    ], daemonEnv(tempRoot)), repoRoot())
    check directCapture.contains(
      "--stats-capture requires daemon-hosted build; direct-mode persistent " &
        "capture is not implemented")

    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work"),
      repoRoot())
    check not fileExists(statsStorePath(projectRoot))

    let statusBefore = requireSuccess(shellCommand([
      publicReproBin(), "stats", "status", "--project-root=" & projectRoot
    ], daemonEnv(tempRoot)), repoRoot())
    check statusBefore.contains("stats capture: disabled by default")
    check statusBefore.contains("flushed: 0")

    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
    waitForStatsStore(projectRoot)

    let statusAfter = requireSuccess(shellCommand([
      publicReproBin(), "stats", "status", "--project-root=" & projectRoot
    ], daemonEnv(tempRoot)), repoRoot())
    check statusAfter.contains("format: jsonl observations + summary.json")
    check statusAfter.contains("retention: raw-runs=50 window=90d")
    check statusAfter.contains("timing=")
    check statusAfter.contains("cache=")
    check statusAfter.contains("runquota=")
    check statusAfter.contains("deps=")
    check statusAfter.contains("sessions=")

    let overview = requireSuccess(shellCommand([
      publicReproBin(), "stats", "overview", "--project-root=" & projectRoot
    ], daemonEnv(tempRoot)), repoRoot())
    check overview.contains("Stats window: runs=1")
    check overview.contains("Actions: 2")
    check overview.contains("Cache:")
    check overview.contains("RunQuota:")

    let invalid = requireFailure(shellCommand([
      publicReproBin(), "build", projectRoot,
      "--daemon=require",
      "--tool-provisioning=path",
      "--stats-capture=invalid"
    ], daemonEnv(tempRoot)), repoRoot())
    check invalid.contains("unsupported --stats-capture=invalid")

  test "integration_stats_flush_not_in_build_hot_path":
    let tempRoot = createTempDir("repro-daemon-m7-hot-path", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectRoot = tempRoot / "project"
    writeCopyProject(projectRoot, "daemonM7HotPath", 1)

    discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
      ["--stats-capture=timing,cache,runquota,deps,sessions"],
      [("REPRO_DAEMON_TEST_STATS_FLUSH_DELAY_MS", "8000")]), repoRoot())
    check not fileExists(statsStorePath(projectRoot))
    waitForStatsStore(projectRoot, timeoutSeconds = 20.0)
    let summary = parseFile(projectRoot / ".repro" / "stats" / "summary.json")
    check summary{"totalObservations"}.getInt() > 0
