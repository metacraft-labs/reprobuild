import std/[os, osproc, strutils, tempfiles, times, unittest]

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

proc publicReproDaemonBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro-daemon", ExeExt)

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
  let sourceDir = tempRoot / "source-bin"
  createDir(sourceDir)
  result = sourceDir / "repro-daemon"
  copyFile(publicReproDaemonBin(), result)
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
    "--report=none",
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
        ["--stats-capture=timing,cache,runquota,deps,sessions"]), repoRoot())
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
