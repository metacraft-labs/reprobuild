import std/[json, os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_daemon_core
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

proc nimString(value: string): string =
  value.escape()

proc writeCopyProject(projectRoot, packageName, text: string) =
  createDir(projectRoot / "src")
  writeFile(projectRoot / "src" / "input.txt", text)
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\npackage " & packageName & ":\n" &
    "  build:\n" &
    "    let copied = fs.copyFile(actionId = " &
      nimString(packageName & "-copy") & ", source = " &
      nimString("src/input.txt") & ", output = " &
      nimString("dist/copied.txt") & ")\n" &
    "    defaultBuildAction(copied)\n")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()

proc daemonDiagnostics(tempRoot: string): string =
  result = "daemon diagnostics for " & tempRoot & "\n"
  let sessions = runShell(shellCommand(@[publicReproBin(), "daemon",
    "sessions"] & daemonArgs(tempRoot)), repoRoot())
  result.add("sessions exit=" & $sessions.code & "\n" & sessions.output & "\n")
  if fileExists(daemonLogPath(tempRoot)):
    result.add("daemon log:\n" & readFile(daemonLogPath(tempRoot)) & "\n")

proc waitForFileContent(path, expected: string; tempRoot = "";
                        timeoutSeconds = 120.0) =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(path) and readFile(path) == expected:
      return
    sleep(25)
  checkpoint("expected " & path & " to contain " & expected)
  if fileExists(path):
    checkpoint("actual: " & readFile(path))
  if tempRoot.len > 0:
    checkpoint(daemonDiagnostics(tempRoot))
  raise newException(IOError, "timed out waiting for " & path)

proc buildCommand(projectRoot, tempRoot, workName: string;
                  extra: openArray[string] = [];
                  envExtra: openArray[(string, string)] = []): CmdSpec =
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=summary",
    "--no-runquota"
  ] & @extra, daemonEnv(tempRoot, envExtra))

proc watchCommand(projectRoot, tempRoot, workName: string;
                  extra: openArray[string] = [];
                  envExtra: openArray[(string, string)] = []): CmdSpec =
  shellCommand(@[
    publicReproBin(), "watch", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--debounce-ms=50"
  ] & @extra, daemonEnv(tempRoot, envExtra))

proc waitForSessionsContains(tempRoot, needle: string; timeoutSeconds = 20.0):
    string =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    let res = runShell(shellCommand(@[publicReproBin(), "daemon", "sessions"] &
      daemonArgs(tempRoot)), repoRoot())
    if res.code == 0 and res.output.contains(needle):
      return res.output
    sleep(25)
  let final = runShell(shellCommand(@[publicReproBin(), "daemon", "sessions"] &
    daemonArgs(tempRoot)), repoRoot()).output
  checkpoint(final)
  check false
  final

proc normalizedActionSummary(reportPath: string): JsonNode =
  let report = parseFile(reportPath)
  result = newJArray()
  for action in report{"actions"}.getElems():
    result.add(%*{
      "id": action{"id"}.getStr(),
      "status": action{"status"}.getStr(),
      "exitCode": action{"exitCode"}.getInt(),
      "launched": action{"launched"}.getBool(),
      "cacheDecision": action{"cacheDecision"}.getStr(),
      "runQuotaBackend": action{"runQuotaBackend"}.getStr()
    })

proc normalizedBuildOutput(output, tempRoot: string): seq[string] =
  for line in output.splitLines:
    if line.len == 0:
      continue
    if line.startsWith("buildReport:"):
      result.add("buildReport:<report>")
    elif line.startsWith("interface:") or
        line.startsWith("toolIdentity:") or
        line.startsWith("inspection:") or
        line.startsWith("providerBinary:") or
        line.startsWith("providerCompileArtifact:") or
        line.startsWith("providerArtifact:") or
        line.startsWith("providerGraphSnapshot:") or
        line.startsWith("providerInvocations:") or
        line.startsWith("loweredGraphCache:") or
        line.startsWith("progress:") or
        line.contains("runquotad is not reachable"):
      discard
    elif line.startsWith("scheduler:") or
        line.startsWith("project:") or
        line.startsWith("cachePortability:") or
        line.startsWith("runQuotaSocket:") or
        line.startsWith("repro build:"):
      result.add(line.replace(tempRoot, "<tmp>"))

proc fakeProtocolHelperSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "fake-protocol-daemon-helper" / "fake_protocol_daemon_helper.nim"

proc fakeProtocolHelperBin(): string =
  repoRoot() / "build" / "test-bin" /
    addFileExt("fake_protocol_daemon_helper", ExeExt)

proc startFakeProtocolDaemon(tempRoot: string): owned(Process) =
  ## Spawn the portable Nim helper that mimics a live, protocol-
  ## incompatible daemon: it binds the endpoint and responds to every
  ## connection with a single ``udkError`` frame carrying the
  ## canonical "user daemon protocol mismatch" message. The helper
  ## binary is built up-front by ``scripts/run_tests.sh``; a missing
  ## binary here is a harness configuration error.
  let helperBin = fakeProtocolHelperBin()
  if not fileExists(helperBin):
    raise newException(OSError,
      "fake-protocol-daemon helper missing at " & helperBin &
      "; build it via the test harness (scripts/run_tests.sh)")

  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard
  result = startProcess(helperBin,
    args = @[daemonEndpoint(tempRoot)],
    workingDir = repoRoot(),
    options = {poUsePath, poStdErrToStdOut})

  # Wait until the endpoint is reachable. ``connectIpc`` raises on
  # failure (it can't distinguish "not bound yet" from "wrong
  # endpoint" without a probe); a short retry loop matches the
  # original Python fixture's startup timing.
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    try:
      var probe = connectIpc(daemonEndpoint(tempRoot))
      probe.closeIpcConn()
      return
    except CatchableError:
      sleep(25)
  if result.running():
    result.terminate()
    discard result.waitForExit()
  let output =
    if result.outputStream != nil: result.outputStream.readAll() else: ""
  result.close()
  raise newException(IOError,
    "fake protocol daemon did not create endpoint: " & output)

suite "Local daemons/control-plane M11 default daemon rollout and recovery":
  test "integration_daemon_auto_fallback_and_direct_recovery":
    let tempRoot = createTempDir("repro-daemon-m11-recovery", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let unavailableProject = tempRoot / "unavailable-project"
    writeCopyProject(unavailableProject, "daemonM11Unavailable", "fallback\n")
    let blockedState = tempRoot / "blocked-state"
    writeFile(blockedState, "not a directory\n")
    let unavailable = requireSuccess(buildCommand(unavailableProject,
      tempRoot, "unavailable-work", envExtra = [
        ("REPRO_DAEMON_STATE_DIR", blockedState)
      ]), repoRoot())
    check unavailable.contains("repro build: daemon unavailable; falling back to direct mode:")
    check unavailable.contains("project: daemonM11Unavailable")
    waitForFileContent(unavailableProject / "dist" / "copied.txt",
      "fallback\n", tempRoot)

    let requireFailureOutput = requireFailure(buildCommand(
      tempRoot / "require-project", tempRoot, "require-work",
      ["--daemon=require"], envExtra = [
        ("REPRO_DAEMON_STATE_DIR", blockedState)
      ]), repoRoot())
    check requireFailureOutput.contains(
      "daemon mode required but repro-daemon is unavailable:")

    let envOffProject = tempRoot / "env-off-project"
    writeCopyProject(envOffProject, "daemonM11EnvOff", "env off\n")
    let envOff = requireSuccess(buildCommand(envOffProject, tempRoot,
      "env-off-work", envExtra = [("REPRO_DAEMON", "off")]), repoRoot())
    check envOff.contains("project: daemonM11EnvOff")
    check not envOff.contains("daemon unavailable")

    let flagOffProject = tempRoot / "flag-off-project"
    writeCopyProject(flagOffProject, "daemonM11FlagOff", "flag off\n")
    let flagOff = requireSuccess(buildCommand(flagOffProject, tempRoot,
      "flag-off-work", ["--daemon=off"], envExtra = [
        ("REPRO_DAEMON", "require")
      ]), repoRoot())
    check flagOff.contains("project: daemonM11FlagOff")
    check not flagOff.contains("daemon unavailable")

    let staleProject = tempRoot / "stale-project"
    writeCopyProject(staleProject, "daemonM11Stale", "stale\n")
    writeFile(daemonEndpoint(tempRoot), "stale endpoint\n")
    let stale = requireSuccess(buildCommand(staleProject, tempRoot,
      "stale-work"), repoRoot())
    check stale.contains("project: daemonM11Stale")
    check not stale.contains("daemon unavailable")
    waitForFileContent(staleProject / "dist" / "copied.txt", "stale\n",
      tempRoot)

    stopDaemon(tempRoot)
    let mismatchProject = tempRoot / "mismatch-project"
    writeCopyProject(mismatchProject, "daemonM11Mismatch", "mismatch\n")
    var fake = startFakeProtocolDaemon(tempRoot)
    defer:
      if fake.running():
        fake.terminate()
        discard fake.waitForExit()
      fake.close()
    let mismatch = requireSuccess(buildCommand(mismatchProject, tempRoot,
      "mismatch-work"), repoRoot())
    check mismatch.contains("repro build: daemon unavailable; falling back to direct mode:")
    check mismatch.contains("compatible status handshake") or
      mismatch.contains("protocol mismatch")
    waitForFileContent(mismatchProject / "dist" / "copied.txt",
      "mismatch\n", tempRoot)

    let mismatchRequire = requireFailure(buildCommand(
      tempRoot / "mismatch-require-project", tempRoot, "mismatch-require-work",
      ["--daemon=require"]), repoRoot())
    check mismatchRequire.contains(
      "daemon mode required but repro-daemon is unavailable:")
    check mismatchRequire.contains("compatible status handshake") or
      mismatchRequire.contains("protocol mismatch")

    let watchFallbackProject = tempRoot / "watch-fallback-project"
    writeCopyProject(watchFallbackProject, "daemonM11WatchFallback",
      "watch fallback\n")
    let watchFallback = requireSuccess(watchCommand(watchFallbackProject,
      tempRoot, "watch-fallback-work", ["--max-cycles=1"], envExtra = [
        ("REPRO_DAEMON_STATE_DIR", blockedState)
      ]), repoRoot())
    check watchFallback.contains(
      "repro watch: daemon unavailable; falling back to direct mode:")
    check watchFallback.contains("repro watch: max cycles reached")

  test "integration_daemon_default_output_matches_direct_mode":
    let tempRoot = createTempDir("repro-daemon-m11-output", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let directProject = tempRoot / "direct-project"
    let daemonProject = tempRoot / "daemon-project"
    writeCopyProject(directProject, "daemonM11Output", "same\n")
    writeCopyProject(daemonProject, "daemonM11Output", "same\n")

    let direct = requireSuccess(buildCommand(directProject, tempRoot,
      "direct-work", ["--daemon=off"]), repoRoot())
    let daemonDefault = requireSuccess(buildCommand(daemonProject, tempRoot,
      "daemon-work"), repoRoot())
    check daemonDefault.contains("project: daemonM11Output")
    check not daemonDefault.contains("daemon unavailable")
    check not daemonDefault.contains("daemon build unsupported")

    check normalizedBuildOutput(direct, tempRoot) ==
      normalizedBuildOutput(daemonDefault, tempRoot)
    check normalizedActionSummary(valueAfter(direct, "buildReport:")) ==
      normalizedActionSummary(valueAfter(daemonDefault, "buildReport:"))
    waitForFileContent(directProject / "dist" / "copied.txt", "same\n",
      tempRoot)
    waitForFileContent(daemonProject / "dist" / "copied.txt", "same\n",
      tempRoot)

    let sessions = waitForSessionsContains(tempRoot, "\tbuild\tsucceeded")
    check sessions.contains("daemonM11Output") or sessions.contains(
      daemonProject)

  test "default watch uses daemon-hosted sessions and direct watch stays explicit":
    let tempRoot = createTempDir("repro-daemon-m11-watch", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let daemonProject = tempRoot / "daemon-watch-project"
    writeCopyProject(daemonProject, "daemonM11WatchDefault", "daemon watch\n")
    let detached = requireSuccess(watchCommand(daemonProject, tempRoot,
      "daemon-watch-work", ["--detach"]), repoRoot())
    let sessionId = valueAfter(detached, "repro watch: detached session=")
    check sessionId.len > 0
    discard waitForSessionsContains(tempRoot, sessionId & "\twatch\twatching")
    waitForFileContent(daemonProject / "dist" / "copied.txt",
      "daemon watch\n", tempRoot)
    let stopped = requireSuccess(shellCommand(@[
      publicReproBin(), "watch",
      "--stop=" & sessionId
    ], daemonEnv(tempRoot)), repoRoot())
    check stopped.contains("daemon-hosted watch stopped") or
      stopped.contains("watch stop requested")

    let directProject = tempRoot / "direct-watch-project"
    writeCopyProject(directProject, "daemonM11WatchDirect", "direct watch\n")
    let directWatch = requireSuccess(watchCommand(directProject, tempRoot,
      "direct-watch-work", ["--daemon=off", "--max-cycles=1"]), repoRoot())
    check directWatch.contains("repro watch: cycle 1 start initial")
    check directWatch.contains("repro watch: max cycles reached")
