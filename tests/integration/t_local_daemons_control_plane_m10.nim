import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_daemon_core/runtime

when defined(posix):
  import std/posix

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
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

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

proc fieldValue(output, field: string): string =
  for line in output.splitLines:
    let prefix = field & ": "
    if line.startsWith(prefix):
      return line[prefix.len .. ^1]
  ""

proc startDevDaemon(tempRoot, sourceExe: string): string =
  requireSuccess(shellCommand(@[
    publicReproBin(), "daemon", "start", "--dev", "--daemon-exe", sourceExe
  ] & daemonArgs(tempRoot)), repoRoot())

proc waitForRestart(tempRoot, firstRunId: string; timeoutSeconds = 20.0):
    string =
  let deadline = epochTime() + timeoutSeconds
  var last = ""
  while epochTime() < deadline:
    let res = runShell(shellCommand(@[publicReproBin(), "daemon", "status"] &
      daemonArgs(tempRoot)), repoRoot())
    last = res.output
    if res.code == 0 and res.output.contains("repro daemon: running") and
        fieldValue(res.output, "restart-run-id") != firstRunId:
      return res.output
    sleep(50)
  checkpoint(last)
  if fileExists(daemonLogPath(tempRoot)):
    checkpoint(readFile(daemonLogPath(tempRoot)))
  raise newException(IOError, "timed out waiting for dev self-restart")

proc appendMarker(path, marker: string) =
  when defined(macosx):
    discard marker
    let res = runShell(shellCommand(@["/usr/bin/codesign", "--force",
      "--sign", "-", path]))
    if res.code != 0:
      checkpoint(res.output)
    check res.code == 0
  else:
    var file = open(path, fmAppend)
    defer: file.close()
    file.write("\nM10-RESTART-MARKER:" & marker & "\n")

proc copyDaemonFixture(tempRoot: string): string =
  # Executable-Consolidation M2 (commit b62edf0): the daemon image IS
  # the public ``repro`` binary; the standalone ``repro-daemon`` was
  # retired. ``daemon start --dev --daemon-exe=<exe>`` invokes
  # ``<exe> daemon serve …`` (see ``daemonProcessArgs``) so the
  # fixture path's BASENAME does not matter -- only the byte contents
  # do. Keep the ``repro-daemon`` filename for the source-image hash
  # diagnostics so the dev-restart marker append targets the same
  # file the daemon will re-image from.
  let sourceDir = tempRoot / "source-bin"
  createDir(sourceDir)
  result = sourceDir / "repro-daemon"
  copyFile(publicReproBin(), result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

when defined(posix):
  proc processAlive(pidValue: int64): bool =
    if pidValue <= 0:
      return false
    kill(Pid(pidValue), 0) == 0 or errno == EPERM

  proc waitForProcessExit(pidValue: int64; timeoutSeconds = 10.0) =
    let deadline = epochTime() + timeoutSeconds
    while epochTime() < deadline:
      if not processAlive(pidValue):
        return
      sleep(50)
    check false

proc nimString(value: string): string =
  value.escape()

proc writeCopyProject(projectRoot, packageName: string) =
  createDir(projectRoot / "src")
  writeFile(projectRoot / "src" / "input.txt", "m10 input\n")
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\npackage " & packageName & ":\n" &
    "  build:\n" &
    "    discard fs.copyFile(actionId = " & nimString(packageName & "-copy") &
      ", source = " & nimString("src/input.txt") & ", output = " &
      nimString("dist/output.txt") & ")\n")

proc buildCommand(projectRoot, tempRoot, workName: string;
                  extra: openArray[string] = []): string =
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

proc waitForStatsStore(projectRoot: string; timeoutSeconds = 20.0) =
  let storePath = projectRoot / ".repro" / "stats" / "observations.jsonl"
  let summaryPath = projectRoot / ".repro" / "stats" / "summary.json"
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(storePath) and readFile(storePath).contains(
        "reprobuild.daemon.stats-observation.v1") and fileExists(summaryPath):
      return
    sleep(50)
  if fileExists(storePath):
    checkpoint(readFile(storePath))
  if fileExists(summaryPath):
    checkpoint(readFile(summaryPath))
  raise newException(IOError, "timed out waiting for stats store")

suite "Local daemons/control-plane M10 development self-restart":
  test "launchd ownership environment is absent unless runner supplied it":
    const OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
    let hadOwnerToken = existsEnv(OwnerTokenEnv)
    let priorOwnerToken = getEnv(OwnerTokenEnv)
    defer:
      if hadOwnerToken:
        putEnv(OwnerTokenEnv, priorOwnerToken)
      else:
        delEnv(OwnerTokenEnv)
    delEnv(OwnerTokenEnv)

    let config = UserDaemonConfig(
      endpoint: "/tmp/repro-owner-plist.sock",
      stateDir: "/tmp/repro-owner-plist-state",
      logPath: "/tmp/repro-owner-plist-state/daemon.log")
    let plist = renderLaunchdUserAgentPlist("/tmp/repro", config)
    # The dict itself is expected: reprobuild's own runtime configuration
    # (PATH, REPROBUILD_*, *_SRC, *_PREFIX) is propagated so a launchd-started
    # daemon keeps the settings an installed `repro` wrapper injects. What must
    # stay absent without a runner-supplied token is the ownership marker.
    check not plist.contains("<key>" & OwnerTokenEnv & "</key>")

  test "launchd ownership environment is exact and XML escaped":
    const OwnerTokenEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
    let hadOwnerToken = existsEnv(OwnerTokenEnv)
    let priorOwnerToken = getEnv(OwnerTokenEnv)
    defer:
      if hadOwnerToken:
        putEnv(OwnerTokenEnv, priorOwnerToken)
      else:
        delEnv(OwnerTokenEnv)
    putEnv(OwnerTokenEnv, "<owner&\"'token>")

    let config = UserDaemonConfig(
      endpoint: "/tmp/repro-owner-plist.sock",
      stateDir: "/tmp/repro-owner-plist-state",
      logPath: "/tmp/repro-owner-plist-state/daemon.log")
    let plist = renderLaunchdUserAgentPlist("/tmp/repro", config)
    check plist.count("<key>EnvironmentVariables</key>") == 1
    check plist.count("<key>" & OwnerTokenEnv & "</key>") == 1
    check plist.contains(
      "<string>&lt;owner&amp;&quot;&apos;token&gt;</string>")
    check not plist.contains("<owner&\"'token>")

  test "launchd plist propagates reprobuild runtime configuration only":
    # Regression: a launchd user agent starts from launchd's default
    # environment, so the daemon lost every `--set-default` variable an
    # installed `repro` wrapper injects. Losing REPROBUILD_SOURCE_ROOT meant the
    # daemon could not find `tools/reprobuild-nix-daemon` (shipped only in the
    # source root), and every `tool-provisioning=nix` build failed with
    # "Failed to connect or spawn reprobuild-nix-daemon".
    const SourceRootEnv = "REPROBUILD_SOURCE_ROOT"
    const PrefixEnv = "CLINGO_PREFIX"
    const UnrelatedEnv = "T_M10_UNRELATED_USER_SECRET"
    let priors = [
      (SourceRootEnv, existsEnv(SourceRootEnv), getEnv(SourceRootEnv)),
      (PrefixEnv, existsEnv(PrefixEnv), getEnv(PrefixEnv)),
      (UnrelatedEnv, existsEnv(UnrelatedEnv), getEnv(UnrelatedEnv))]
    defer:
      for (key, had, value) in priors:
        if had: putEnv(key, value) else: delEnv(key)
    putEnv(SourceRootEnv, "/nix/store/fake-source&root")
    putEnv(PrefixEnv, "/nix/store/fake-clingo")
    putEnv(UnrelatedEnv, "super-secret-token")

    let config = UserDaemonConfig(
      endpoint: "/tmp/repro-env-plist.sock",
      stateDir: "/tmp/repro-env-plist-state",
      logPath: "/tmp/repro-env-plist-state/daemon.log")
    let plist = renderLaunchdUserAgentPlist("/tmp/repro", config)

    check plist.count("<key>EnvironmentVariables</key>") == 1
    # Reprobuild's own configuration crosses over, XML-escaped.
    check plist.contains("<key>" & SourceRootEnv & "</key>")
    check plist.contains("<string>/nix/store/fake-source&amp;root</string>")
    check plist.contains("<key>" & PrefixEnv & "</key>")
    check plist.contains("<key>PATH</key>")
    # Unrelated caller environment must NOT be serialised to disk.
    check not plist.contains(UnrelatedEnv)
    check not plist.contains("super-secret-token")

  test "integration_daemon_dev_restart_posix":
    when defined(posix):
      let tempRoot = createTempDir("repro-daemon-m10-posix", "")
      let sourceExe = copyDaemonFixture(tempRoot)
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let started = startDevDaemon(tempRoot, sourceExe)
      check started.contains("dev-mode: true")
      check fieldValue(started, "source-image-path") == sourceExe
      check fieldValue(started, "running-image-path") != sourceExe
      check fieldValue(started, "source-hash").len > 0
      check fieldValue(started, "source-hash") ==
        fieldValue(started, "running-hash")
      check dirExists(fieldValue(started, "staged-generation-dir"))
      check not fileExists(fieldValue(started, "staged-generation-dir") /
        addFileExt("repro-full", ExeExt))
      check fieldValue(started, "protocol-generation") == "1.1"
      check fieldValue(started, "reconnect-limitations").contains(
        "watch sessions can be reattached")

      let firstPid = parseBiggestInt(fieldValue(started, "pid"))
      let firstRunId = fieldValue(started, "restart-run-id")
      let firstGeneration = fieldValue(started, "generation")
      appendMarker(sourceExe, "posix")

      let restarted = waitForRestart(tempRoot, firstRunId)
      check fieldValue(restarted, "restart-run-id") != firstRunId
      check fieldValue(restarted, "generation") != firstGeneration
      check parseBiggestInt(fieldValue(restarted, "pid")) != firstPid
      check fieldValue(restarted, "source-hash") ==
        fieldValue(restarted, "running-hash")
      check fieldValue(restarted, "source-hash") !=
        fieldValue(started, "source-hash")
      discard requireSuccess(shellCommand(@[
        publicReproBin(), "daemon", "sessions"
      ] & daemonArgs(tempRoot)), repoRoot())
      waitForProcessExit(firstPid)
    else:
      echo "[platform N/A] POSIX dev self-restart gate"

  test "integration_daemon_dev_restart_does_not_corrupt_state":
    when defined(posix):
      let tempRoot = createTempDir("repro-daemon-m10-state", "")
      let sourceExe = copyDaemonFixture(tempRoot)
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let started = startDevDaemon(tempRoot, sourceExe)
      let firstRunId = fieldValue(started, "restart-run-id")
      let projectRoot = tempRoot / "project"
      writeCopyProject(projectRoot, "daemonM10State")

      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-groups=timing,cache,runquota,deps,sessions"]), repoRoot())
      waitForStatsStore(projectRoot)
      let sessionsBefore = requireSuccess(shellCommand(@[
        publicReproBin(), "daemon", "sessions"
      ] & daemonArgs(tempRoot)), repoRoot())
      check sessionsBefore.contains("succeeded")

      appendMarker(sourceExe, "state")
      discard waitForRestart(tempRoot, firstRunId)

      let sessionsAfter = requireSuccess(shellCommand(@[
        publicReproBin(), "daemon", "sessions"
      ] & daemonArgs(tempRoot)), repoRoot())
      check sessionsAfter.contains("succeeded")
      check fileExists(projectRoot / ".repro" / "stats" / "summary.json")
      check dirExists(tempRoot / "action-cache")

      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work-after"),
        repoRoot())
    else:
      echo "[platform N/A] POSIX dev self-restart state gate"

  test "integration_daemon_dev_restart_windows_staged_copy":
    when defined(windows):
      echo "[planned] Windows staged-copy dev restart requires native Windows " &
        "IPC/process-image-locking verification"
    else:
      echo "[platform N/A] Windows staged-copy dev restart gate"
