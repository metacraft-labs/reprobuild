import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

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
  let endpoint = daemonEndpoint(tempRoot)
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    let res = runShell("ps -axo command | " &
      "grep " & q("repro-daemon --foreground --endpoint " & endpoint) &
      " | grep -v grep", repoRoot())
    if res.code != 0:
      break
    sleep(100)
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
  checkpoint("daemon status did not become running")
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

proc waitForTimestampBoundary() =
  sleep(1100)

proc nimString(value: string): string =
  value.escape()

proc writeWatchProject(projectRoot, projectName, initial: string) =
  createDir(projectRoot / "src")
  writeFile(projectRoot / "src" / "input.txt", initial)
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package " & projectName & ":\n" &
    "  build:\n" &
    "    let copied = fs.copyFile(\n" &
    "      actionId = " & nimString(projectName & "-copy-source") & ",\n" &
    "      source = " & nimString("src/input.txt") & ",\n" &
    "      output = " & nimString("dist/copied.txt") & ")\n" &
    "    defaultBuildAction(copied)\n")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()

proc sessionIdFromDetached(output: string): string =
  let value = valueAfter(output, "repro watch: detached session=")
  check value.len > 0
  value

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
  raise newException(IOError, "timed out waiting for expected file content")

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

proc watchCommand(projectRoot, tempRoot, workName: string;
                  extra: openArray[string] = []): string =
  shellCommand(@[
    publicReproBin(), "watch", projectRoot,
    "--daemon=require",
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / workName,
    "--debounce-ms=50"
  ] & @extra, daemonEnv(tempRoot))

proc buildCommand(projectRoot, tempRoot: string; extra: openArray[string] = []):
    string =
  shellCommand(@[
    publicReproBin(), "build", projectRoot,
    "--tool-provisioning=path",
    "--work-root=" & tempRoot / "build-work",
    "--action-cache-root=" & tempRoot / "action-cache",
    "--progress=quiet",
    "--log=summary"
  ] & @extra, daemonEnv(tempRoot))

suite "Local daemons/control-plane M5 daemon-hosted watch sessions":
  test "integration_daemon_hosts_two_watch_sessions":
    let tempRoot = createTempDir("repro-daemon-m5-two-watch", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectA = tempRoot / "project-a"
    let projectB = tempRoot / "project-b"
    writeWatchProject(projectA, "daemonM5WatchA", "a0\n")
    writeWatchProject(projectB, "daemonM5WatchB", "b0\n")

    let outA = requireSuccess(watchCommand(projectA, tempRoot, "work-a",
      ["--detach"]), repoRoot())
    let sessionA = sessionIdFromDetached(outA)
    waitForFileContent(projectA / "dist" / "copied.txt", "a0\n", tempRoot)
    discard waitForSessionsContains(tempRoot, sessionA & "\twatch\twatching")

    let outB = requireSuccess(watchCommand(projectB, tempRoot, "work-b",
      ["--detach"]), repoRoot())
    let sessionB = sessionIdFromDetached(outB)
    check sessionA != sessionB

    waitForFileContent(projectB / "dist" / "copied.txt", "b0\n", tempRoot)
    let active = waitForSessionsContains(tempRoot, "watching")
    check active.contains(sessionA)
    check active.contains(sessionB)
    check active.contains("selectedRoots=")
    check active.contains("tierState=single-tier")

    waitForTimestampBoundary()
    writeFile(projectA / "src" / "input.txt", "a1\n")
    waitForFileContent(projectA / "dist" / "copied.txt", "a1\n", tempRoot)
    check readFile(projectB / "dist" / "copied.txt") == "b0\n"

    waitForTimestampBoundary()
    writeFile(projectB / "src" / "input.txt", "b1\n")
    waitForFileContent(projectB / "dist" / "copied.txt", "b1\n", tempRoot)
    discard requireSuccess(shellCommand(@[
      publicReproBin(), "watch",
      "--daemon=require",
      "--stop=" & sessionA
    ], daemonEnv(tempRoot)), repoRoot())
    discard requireSuccess(shellCommand(@[
      publicReproBin(), "watch",
      "--daemon=require",
      "--stop=" & sessionB
    ], daemonEnv(tempRoot)), repoRoot())
    let finishedA = waitForSessionsContains(tempRoot,
      sessionA & "\twatch\tstopped", timeoutSeconds = 30.0)
    let finishedB = waitForSessionsContains(tempRoot,
      sessionB & "\twatch\tstopped", timeoutSeconds = 30.0)
    check finishedA.contains(sessionA)
    check finishedB.contains(sessionB)

  test "integration_daemon_watch_detach_and_reattach":
    let tempRoot = createTempDir("repro-daemon-m5-reattach", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)

    let projectRoot = tempRoot / "project"
    writeWatchProject(projectRoot, "daemonM5Reattach", "r0\n")
    let detached = requireSuccess(watchCommand(projectRoot, tempRoot, "work",
      ["--detach"]), repoRoot())
    let sessionId = sessionIdFromDetached(detached)
    waitForFileContent(projectRoot / "dist" / "copied.txt", "r0\n", tempRoot)
    discard waitForSessionsContains(tempRoot, sessionId & "\twatch\twatching")

    waitForTimestampBoundary()
    let attached = startProcess("env",
      args = @[
        "REPRO_DAEMON_ENDPOINT=" & daemonEndpoint(tempRoot),
        "REPRO_DAEMON_STATE_DIR=" & daemonStateDir(tempRoot),
        "REPROBUILD_STORE_ROOT=" & tempRoot / "store",
        "PATH=" & getEnv("PATH"),
        publicReproBin(), "watch",
        "--daemon=require",
        "--attach=" & sessionId
      ],
      workingDir = repoRoot(),
      options = {poUsePath, poStdErrToStdOut})
    defer:
      if attached.running():
        attached.terminate()
        discard attached.waitForExit()
      attached.close()

    writeFile(projectRoot / "src" / "input.txt", "r1\n")
    waitForFileContent(projectRoot / "dist" / "copied.txt", "r1\n", tempRoot)
    discard requireSuccess(shellCommand(@[
      publicReproBin(), "watch",
      "--daemon=require",
      "--stop=" & sessionId
    ], daemonEnv(tempRoot)), repoRoot())

    let exitCode = attached.waitForExit()
    let output = attached.outputStream.readAll()
    checkpoint(output)
    check exitCode == 0
    check output.contains("cycle 1 start initial")
    check output.contains("event seen path=")
    check output.contains("daemon-hosted watch stopped")
    let stopped = waitForSessionsContains(tempRoot, "stopped")
    check stopped.contains(sessionId)

  test "integration_daemon_watch_macos_kqueue":
    when defined(macosx):
      let tempRoot = createTempDir("repro-daemon-m5-kqueue", "")
      var daemon: owned(Process)
      defer:
        closeForegroundDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startForegroundDaemon(tempRoot)

      let projectRoot = tempRoot / "project"
      writeWatchProject(projectRoot, "daemonM5Kqueue", "k0\n")
      let watcher = startProcess("env",
        args = @[
          "REPRO_DAEMON_ENDPOINT=" & daemonEndpoint(tempRoot),
          "REPRO_DAEMON_STATE_DIR=" & daemonStateDir(tempRoot),
          "REPROBUILD_STORE_ROOT=" & tempRoot / "store",
          publicReproBin(), "watch", projectRoot,
          "--daemon=require",
          "--tool-provisioning=path",
          "--work-root=" & tempRoot / "work",
          "--debounce-ms=50",
          "--max-cycles=2"
        ],
        workingDir = repoRoot(),
        options = {poUsePath, poStdErrToStdOut})
      defer:
        if watcher.running():
          watcher.terminate()
          discard watcher.waitForExit()
        watcher.close()

      waitForFileContent(projectRoot / "dist" / "copied.txt", "k0\n",
        tempRoot)
      waitForTimestampBoundary()
      writeFile(projectRoot / "src" / "input.txt", "k1\n")
      waitForFileContent(projectRoot / "dist" / "copied.txt", "k1\n",
        tempRoot)
      let exitCode = watcher.waitForExit()
      let output = watcher.outputStream.readAll()
      check exitCode == 0
      check output.contains("event seen path=")
      check output.contains("detail=write") or output.contains("detail=extend") or
        output.contains("detail=attrib") or output.contains("detail=rename")
    else:
      echo "[platform N/A] macOS kqueue daemon-hosted watch test"

  test "direct one-shot build and direct watch remain available":
    let tempRoot = createTempDir("repro-daemon-m5-direct", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let projectRoot = tempRoot / "project"
    writeWatchProject(projectRoot, "daemonM5Direct", "d0\n")
    let buildOut = requireSuccess(buildCommand(projectRoot, tempRoot,
      ["--daemon=off", "--no-runquota"]), repoRoot())
    check buildOut.contains("project: daemonM5Direct")
    waitForFileContent(projectRoot / "dist" / "copied.txt", "d0\n")

    let watchOut = requireSuccess(shellCommand(@[
      publicReproBin(), "watch", projectRoot,
      "--daemon=off",
      "--tool-provisioning=path",
      "--work-root=" & tempRoot / "direct-watch",
      "--max-cycles=1"
    ], daemonEnv(tempRoot)), repoRoot())
    check watchOut.contains("repro watch: cycle 1 start initial")
    check watchOut.contains("repro watch: max cycles reached")
