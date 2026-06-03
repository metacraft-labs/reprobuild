import std/[json, os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc fixtureSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "direct-mode-parity" / "project"

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

proc copyFixtureProject(dest: string) =
  createDir(dest.parentDir)
  copyDir(fixtureSource(), dest)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()

proc waitForOutput(path, expected: string; timeoutSeconds = 10.0) =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(path) and readFile(path) == expected:
      return
    sleep(25)
  checkpoint("missing expected output " & path)
  check false

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

proc normalizedStrings(node: JsonNode; directProject, daemonProject: string):
    JsonNode =
  result = newJArray()
  for item in node.getElems():
    result.add(%item.getStr().replace(directProject, "<project>").
      replace(daemonProject, "<project>"))

proc normalizedActionEvidenceSummary(reportPath, directProject,
                                      daemonProject: string): JsonNode =
  let report = parseFile(reportPath)
  result = newJArray()
  for action in report{"actions"}.getElems():
    let evidence = action{"evidence"}
    result.add(%*{
      "id": action{"id"}.getStr(),
      "declaredInputs": normalizedStrings(evidence{"declaredInputs"},
        directProject, daemonProject),
      "declaredOutputs": normalizedStrings(evidence{"declaredOutputs"},
        directProject, daemonProject),
      "depfileInputs": normalizedStrings(evidence{"depfileInputs"},
        directProject, daemonProject),
      "monitorReads": normalizedStrings(evidence{"monitorReads"},
        directProject, daemonProject),
      "monitorWrites": normalizedStrings(evidence{"monitorWrites"},
        directProject, daemonProject),
      "monitorProbes": normalizedStrings(evidence{"monitorProbes"},
        directProject, daemonProject),
      "diagnostics": normalizedStrings(evidence{"diagnostics"},
        directProject, daemonProject)
    })

proc actionCacheRecordsPath(tempRoot: string): string =
  tempRoot / "action-cache" / "action-cache" / "action-results.records"

proc countFramedActionCacheRecords(path: string): int =
  let raw = readFile(path)
  var pos = 0
  while pos + 8 <= raw.len:
    let length =
      ord(raw[pos]) or
      (ord(raw[pos + 1]) shl 8) or
      (ord(raw[pos + 2]) shl 16) or
      (ord(raw[pos + 3]) shl 24)
    pos += 4
    if length <= 0 or pos + length + 4 > raw.len:
      break
    pos += length + 4
    inc result

proc assertRunQuotaReport(output, socket: string) =
  let reportPath = valueAfter(output, "buildReport:")
  check reportPath.len > 0
  let report = parseFile(reportPath)
  var found = false
  for action in report{"actions"}.getElems():
    if action{"id"}.getStr() == "m4-sleeper-action":
      found = true
      check action{"runQuotaBackend"}.getStr() == "posix-fork-exec-poll"
      check action{"runQuotaSocket"}.getStr() == socket
      check action{"leaseId"}.getBiggestInt() > 0
  check found

proc buildCommand(projectRoot, tempRoot: string; extra: openArray[string] = [];
                  env: openArray[(string, string)] = [];
                  daemonRoot = ""): CmdSpec =
  let daemonEnvRoot =
    if daemonRoot.len > 0: daemonRoot
    else: tempRoot
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "work",
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=summary"
  ] & @extra, daemonEnv(daemonEnvRoot) & @env)

proc nimString(value: string): string =
  value.escape()

proc writeSleeperProject(projectRoot: string; sleepSeconds: int) =
  createDir(projectRoot)
  let outputRel = "build/slept.txt"
  let startedRel = "build/started.txt"
  let script =
    "set -eu\n" &
    "out=$1\n" &
    "started=$2\n" &
    "mkdir -p \"$(dirname \"$started\")\"\n" &
    "printf 'started\\n' > \"$started\"\n" &
    "sleep " & $sleepSeconds & "\n" &
    "mkdir -p \"$(dirname \"$out\")\"\n" &
    "printf 'slept\\n' > \"$out\"\n"
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package daemonM4Sleeper:\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      let action = buildAction(\"m4-sleeper-action\",\n" &
    "        daemonM4Sleeper.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & nimString(script) & ", " & nimString("sh") &
      ", " & nimString(outputRel) & ", " & nimString(startedRel) & "]),\n" &
    "        outputs = @[" & nimString(outputRel) & ", " &
      nimString(startedRel) & "],\n" &
    "        cacheable = false)\n" &
    "      defaultBuildAction(action)\n")

proc ensureRunQuotaDaemon(repoRoot, tempRoot: string): tuple[
    process: owned(Process); socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  let cliBin = runquotaRoot / "build" / "bin" / addFileExt("runquota", ExeExt)
  if not fileExists(daemonBin) or not fileExists(cliBin):
    discard requireSuccess(shellCommand(@["just", "build"]), runquotaRoot)
  let socketPath = "/tmp/repro-m4-rq-" & $getCurrentProcessId() & ".sock"
  try: removeFile(socketPath) except OSError: discard
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "1000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath, poStdErrToStdOut})

  proc daemonOutput(): string =
    if daemon.outputStream != nil:
      return daemon.outputStream.readAll()

  proc ready(): bool =
    if not daemon.running():
      raise newException(OSError, "runquotad exited during startup: " &
        daemonOutput())
    let status = runShell(shellCommand(@[cliBin, "status", "--json"],
      [("RUNQUOTA_SOCKET", socketPath)]), repoRoot)
    status.code == 0 and status.output.contains("\"active_sessions\"")

  for _ in 0 ..< 800:
    if ready():
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  discard daemon.waitForExit()
  let output = daemonOutput()
  daemon.close()
  raise newException(OSError,
    "runquotad did not become reachable at " & socketPath & ": " & output)

proc waitForSessionsContains(tempRoot, needle: string; timeoutSeconds = 10.0):
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

suite "Local daemons/control-plane M4 daemon-hosted builds":
  test "integration_daemon_build_matches_direct_report":
    let tempRoot = createTempDir("repro-daemon-m4-parity", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let directProject = tempRoot / "direct-project"
    let daemonProject = tempRoot / "daemon-project"
    copyFixtureProject(directProject)
    copyFixtureProject(daemonProject)

    let directRoot = tempRoot / "direct"
    let daemonRoot = tempRoot / "daemon"
    let direct = requireSuccess(buildCommand(directProject, directRoot,
      ["--daemon=off", "--no-runquota"], daemonRoot = tempRoot), repoRoot())
    let daemon = requireSuccess(buildCommand(daemonProject, daemonRoot,
      ["--daemon=require", "--no-runquota"], daemonRoot = tempRoot), repoRoot())

    check direct.contains("project: localDaemonParity")
    check daemon.contains("project: localDaemonParity")
    check not daemon.contains("daemon build unsupported")
    waitForOutput(directProject / "dist" / "copied.txt",
      "direct-mode fixture\n")
    waitForOutput(daemonProject / "dist" / "copied.txt",
      "direct-mode fixture\n")

    let directReport = valueAfter(direct, "buildReport:")
    let daemonReport = valueAfter(daemon, "buildReport:")
    check normalizedActionSummary(directReport) ==
      normalizedActionSummary(daemonReport)
    check normalizedActionEvidenceSummary(directReport, directProject,
      daemonProject) == normalizedActionEvidenceSummary(daemonReport,
      directProject, daemonProject)
    check fileExists(actionCacheRecordsPath(directRoot))
    check fileExists(actionCacheRecordsPath(daemonRoot))
    let directRecordCount = countFramedActionCacheRecords(
      actionCacheRecordsPath(directRoot))
    let daemonRecordCount = countFramedActionCacheRecords(
      actionCacheRecordsPath(daemonRoot))
    check directRecordCount > 0
    check directRecordCount == daemonRecordCount

  test "integration_daemon_build_uses_runquota":
    let tempRoot = createTempDir("repro-daemon-m4-runquota", "")
    let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
    let previousPath = getEnv("PATH", "")
    defer:
      putEnv("RUNQUOTA_SOCKET", previousSocket)
      putEnv("PATH", previousPath)
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let projectRoot = tempRoot / "project"
    writeSleeperProject(projectRoot, 1)
    var runquota = ensureRunQuotaDaemon(repoRoot(), tempRoot)
    putEnv("RUNQUOTA_SOCKET", runquota.socket)
    defer:
      runquota.process.terminate()
      discard runquota.process.waitForExit()
      runquota.process.close()
      try: removeFile(runquota.socket) except OSError: discard

    let output = requireSuccess(buildCommand(projectRoot, tempRoot,
      ["--daemon=require"], env = [("RUNQUOTA_SOCKET", runquota.socket),
        ("PATH", getEnv("PATH"))]), repoRoot())
    check output.contains("runQuotaSocket: " & runquota.socket)
    assertRunQuotaReport(output, runquota.socket)

  test "integration_daemon_sessions_active_recent_and_cancelled":
    when defined(posix):
      let tempRoot = createTempDir("repro-daemon-m4-sessions", "")
      let previousPath = getEnv("PATH", "")
      defer:
        putEnv("PATH", previousPath)
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      writeSleeperProject(projectRoot, 10)

      let client = startProcess("env",
        args = @[
          "REPRO_DAEMON_ENDPOINT=" & daemonEndpoint(tempRoot),
          "REPRO_DAEMON_STATE_DIR=" & daemonStateDir(tempRoot),
          "REPROBUILD_STORE_ROOT=" & tempRoot / "store",
          "PATH=" & getEnv("PATH"),
          publicReproBin(), "build", projectRoot,
          "--daemon=require",
          "--tool-provisioning=path",
          "--work-root=" & tempRoot / "work",
          "--action-cache-root=" & tempRoot / "action-cache",
          "--progress=quiet",
          "--log=summary",
          "--no-runquota"
        ],
        workingDir = repoRoot(),
        options = {poUsePath, poStdErrToStdOut})
      defer:
        if client.running():
          client.terminate()
          discard client.waitForExit()
        client.close()

      let active = waitForSessionsContains(tempRoot, "running")
      check active.contains("build")
      waitForOutput(projectRoot / "build" / "started.txt", "started\n",
        timeoutSeconds = 120.0)
      client.terminate()
      discard client.waitForExit()

      let cancelled = waitForSessionsContains(tempRoot, "cancelled",
        timeoutSeconds = 15.0)
      check cancelled.contains("daemon-hosted build cancelled")
      check not fileExists(projectRoot / "build" / "slept.txt")
    else:
      echo "[platform N/A] POSIX daemon build cancellation test"
