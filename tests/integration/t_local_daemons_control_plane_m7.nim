import std/[json, os, osproc, strutils, tempfiles, times, unittest]

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
                  extra: openArray[string] = [];
                  envExtra: openArray[(string, string)] = []): CmdSpec =
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
  ] & @extra, daemonEnv(tempRoot, envExtra))

proc retiredStatsStorePath(projectRoot: string): string =
  ## RETIRED, AND NAMED HERE ONLY TO ASSERT ITS ABSENCE.
  ## ``Retired-Names.md`` §"Analytics store paths and schema ids" retires
  ## ``.repro/stats/observations.jsonl`` and ``summary.json``; raw
  ## per-execution rows are RunQuota's now.
  projectRoot / ".repro" / "stats" / "observations.jsonl"

proc daemonCaptureLine(tempRoot: string): string =
  ## THE WITNESS THAT REPLACED THE JSONL FILE (M18).
  ##
  ## M7's property was that daemon-hosted capture RAN AND IS OBSERVABLE,
  ## and the JSONL store was merely the shape it was observable in. The
  ## store swap moved raw rows to RunQuota and left the project-local
  ## DERIVED store without a linked backend, so what the daemon has to
  ## show for a capture run is a counted discard it logs by session. That
  ## line is the observable, and it is read from the DAEMON's log because
  ## the counter lives in the daemon: a ``repro stats status`` process
  ## asking itself would report its own zero and witness nothing.
  if not fileExists(daemonLogPath(tempRoot)):
    return ""
  for line in readFile(daemonLogPath(tempRoot)).splitLines:
    if line.contains("stats discarded session=") or
        line.contains("stats flushed session="):
      return line
  ""

proc waitForDaemonCapture(tempRoot: string; timeoutSeconds = 20.0): string =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    result = daemonCaptureLine(tempRoot)
    if result.len > 0:
      return
    sleep(50)
  if fileExists(daemonLogPath(tempRoot)):
    checkpoint(readFile(daemonLogPath(tempRoot)))
  raise newException(IOError, "timed out waiting for daemon-hosted capture")

suite "Local daemons/control-plane M7 stats capture":
  when isNixSupported:
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
        "--stats-groups=timing",
        "--no-runquota"
      ], daemonEnv(tempRoot)), repoRoot())
      check directCapture.contains(
        "--write-stats requires daemon-hosted build; direct-mode persistent " &
          "capture is not implemented")

      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work"),
        repoRoot())
      check not fileExists(retiredStatsStorePath(projectRoot))
      # NON-VACUITY FOR THE ABSENCE ABOVE: without ``--stats-groups`` no
      # capture was requested, so nothing has run yet either. The absence
      # that MEANS something is asserted after the capture build below.
      check daemonCaptureLine(tempRoot).len == 0

      let statusBefore = requireSuccess(shellCommand([
        publicReproBin(), "stats", "status", "--project-root=" & projectRoot
      ], daemonEnv(tempRoot)), repoRoot())
      # M18 RETARGET. "stats capture: disabled by default" described ONE
      # store; there are two now with different owners, and the surface
      # must say which of them is off. Raw capture is RunQuota's and is
      # not reprobuild's to enable; the project-local DERIVED capture is
      # what ``--stats-groups`` turns on, and it is off here.
      check statusBefore.contains("raw capture: RunQuota-owned")
      check statusBefore.contains("active derived capture: none")
      check statusBefore.contains("flushed: 0")

      discard requireSuccess(buildCommand(projectRoot, tempRoot, "work",
        ["--stats-groups=timing,cache,runquota,deps,sessions"]), repoRoot())
      let captureLine = waitForDaemonCapture(tempRoot)

      # THE M7 PROPERTY, IN ITS REPLACEMENT SHAPE: daemon-hosted capture
      # ran, it had real work to do, and the daemon says so per session
      # rather than leaving an operator to infer it from an empty store.
      check captureLine.contains("stats discarded session=")
      check captureLine.contains("reason=derived-backend-not-linked")
      check captureLine.contains(
        projectRoot / ".repro" / "stats" / "derived")

      # AND THE RETIRED STORE STAYED RETIRED ON THE ONE PATH THAT USED TO
      # WRITE IT. This is the daemon-hosted ``--stats-groups`` invocation
      # the M7 writer lived on, so the absence here is reached rather
      # than merely convenient.
      check not fileExists(retiredStatsStorePath(projectRoot))
      check not fileExists(projectRoot / ".repro" / "stats" / "summary.json")

      let statusAfter = requireSuccess(shellCommand([
        publicReproBin(), "stats", "status", "--project-root=" & projectRoot
      ], daemonEnv(tempRoot)), repoRoot())
      check statusAfter.contains(
        "derived store: " & projectRoot / ".repro" / "stats" / "derived")
      check statusAfter.contains("derived backend: not linked")
      check not statusAfter.contains("observations.jsonl")
      check not statusAfter.contains("summary.json")

      # THIS BUILD RAN ``--no-runquota``, SO THERE IS NO SHARED HISTORY --
      # and the point of the M18 read path is that an absent window is
      # NAMED rather than rendered as zeros. Asserting figures here would
      # be asserting them against a fixture that produced none.
      #
      # RUNQUOTA_SOCKET IS PINNED AT A DEAD PATH so the state under test
      # is the one this fixture creates and not whatever daemon happens to
      # be running on the developer's machine.
      let overview = requireSuccess(shellCommand([
        publicReproBin(), "stats", "overview", "--project-root=" & projectRoot
      ], daemonEnv(tempRoot,
        [("RUNQUOTA_SOCKET", tempRoot / "no-runquotad-here.sock")])),
        repoRoot())
      check overview.contains("Stats source: ")
      check overview.contains("No statistics: ")
      check not overview.contains("Stats window: executions=")
      # AND THE RETIRED RENDERER IS GONE, not merely quiet: these lines
      # were the M7 overview's own vocabulary, computed from the JSONL
      # file this milestone retired.
      check not overview.contains("Capture groups:")
      check not overview.contains("Observation kinds:")

      let invalid = requireFailure(shellCommand([
        publicReproBin(), "build", projectRoot,
        "--daemon=require",
        "--tool-provisioning=path",
        "--stats-groups=invalid"
      ], daemonEnv(tempRoot)), repoRoot())
      check invalid.contains("unsupported --stats-groups=invalid")

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
        ["--stats-groups=timing,cache,runquota,deps,sessions"],
        [("REPRO_DAEMON_TEST_STATS_FLUSH_DELAY_MS", "8000")]), repoRoot())
      # OS-1, AND IT IS STILL THE SAME PROPERTY: the build returned before
      # the delayed flush could have finished, so capture is off the hot
      # path. Only the WITNESS changed -- the retired JSONL file became
      # the daemon's counted-discard line, which is what a flush produces
      # now.
      check daemonCaptureLine(tempRoot).len == 0
      check not fileExists(retiredStatsStorePath(projectRoot))
      let captureLine = waitForDaemonCapture(tempRoot, timeoutSeconds = 20.0)
      check captureLine.contains("reason=derived-backend-not-linked")
      # THE FLUSH HAD SOMETHING TO FLUSH. Without this the assertion above
      # would be satisfied by a build that captured nothing at all.
      let observed = captureLine.split("observations=")[1].split(' ')[0]
      check parseInt(observed) > 0
      check not fileExists(projectRoot / ".repro" / "stats" / "summary.json")
