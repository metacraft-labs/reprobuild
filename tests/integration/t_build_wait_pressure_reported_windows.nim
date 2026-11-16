## A real build reports its build-wait pressure to a real `runquotad` ON
## WINDOWS: the engine's inline launch path, a private `runquotad` on a scratch
## named pipe, and the figures read back over `QueryPressure`.
##
## THE WINDOWS ARM of `tests/integration/t_build_wait_pressure_reported.nim`.
## That file is gated `when defined(macosx) or defined(linux):` and starts its
## daemon under the POSIX `private` endpoint scope (a Unix-domain socket in a
## test-owned directory). Windows has no such scope -- the daemon refuses it --
## and the transport is a named pipe under the default `host` scope, isolated
## by a pipe name no concurrent run collides with (`runquotaSocketEndpoint`).
## The client-side computation (`repro_runquota/build_pressure`) and the
## protocol are the same code on every platform; this file proves the engine's
## inline launch path reports over the Windows transport.
##
## Three independent actions of 1.5 s each, one CPU each, on a daemon with a
## one-CPU budget, with `RUNQUOTA_MEASUREMENT=pressure-reports=on`: the engine
## offers all three, one is granted and two queue, so they run one after
## another. While the first two run, at least one other waits, so the build is
## held up (*some*) from the offer until the last grant, about 1.5 + 1.5 = 3 s
## (the two waits overlap: *some* is their union, not their sum), and *full*
## stays near zero because the running action is not held up (the daemon has no
## expected duration for it: capture is off, so the reports are queue-only).
##
## WHAT IS GUARDED, with the mutation that breaks it:
##
## * The engine reports, and the daemon's figures for the build's session group
##   match the schedule: *some* within wide bounds, *full* small, two queue
##   waits, every report queue-only. Mutation: drop the `noteReady` calls at
##   the offer, and nothing is tracked or reported.
## * With the switch off (the default) the same build reports nothing.
##   Mutation: ignore the switch.
##
## The bounds are wide because the schedule is real processes on a shared host;
## the exact arithmetic is checked over a scripted schedule in
## `tests/unit/t_build_wait_pressure_schedule`.
##
## NO MOCKS, ONE FIXTURE: each action is this file's own executable in
## `fixture-sleep` mode. The daemon is the real `runquotad`
## (`requireRunQuotaDaemonBin`), on a named pipe this test owns.

when defined(windows):
  import std/[json, os, osproc, streams, strutils, tempfiles, unittest]

  import repro_build_engine
  import repro_runquota
  import runquota_client
  import runquota_protocol

  import repro_test_support

  proc startDaemon(repoRoot: string; cpuMilli: int; tag: string):
      tuple[process: owned(Process), socket: string] =
    ## A private `runquotad` on a scratch named pipe under the default `host`
    ## scope (Windows refuses the `private` scope the POSIX fixture uses).
    let daemonBin = requireRunQuotaDaemonBin(repoRoot)
    let socketPath = runquotaSocketEndpoint(
      "repro-pressure-win-" & tag & "-" & $getCurrentProcessId())
    let daemon = startProcess(daemonBin, args = [
      "--socket", socketPath,
      "--cpu-milli", $cpuMilli,
      "--memory-bytes", "34359738368"
    ], options = {poUsePath, poStdErrToStdOut})
    putEnv("RUNQUOTA_SOCKET", socketPath)
    for _ in 0 ..< 400:
      # On Windows the pipe has no filesystem entry; readiness is "the name is
      # a pipe and the process is still alive" (`runquotaEndpointReachable`).
      if runquotaEndpointReachable(socketPath) and daemon.running:
        # Give the daemon a moment to bind the pipe before the first connect.
        sleep(100)
        return (process: daemon, socket: socketPath)
      if not daemon.running:
        break
      sleep(25)
    let output = daemon.outputStream.readAll()
    daemon.close()
    raise newException(OSError, "runquotad did not come up: " & output)

  proc buildThreeQueued(repoRoot, tempRoot, group, measurement: string):
      JsonNode =
    ## Run the three-action build against a one-CPU daemon and return the
    ## daemon's pressure answer for `group`.
    var daemon = startDaemon(repoRoot, 1000, group)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
    putEnv("RUNQUOTA_SESSION", group)
    if measurement.len > 0:
      putEnv("RUNQUOTA_MEASUREMENT", measurement)
    else:
      delEnv("RUNQUOTA_MEASUREMENT")
    defer:
      delEnv("RUNQUOTA_SESSION")
      delEnv("RUNQUOTA_MEASUREMENT")
    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    createDir(workRoot)
    var actions: seq[BuildAction]
    for id in ["one", "two", "three"]:
      actions.add(action(id, @[app, "fixture-sleep", "1500",
        workRoot / (id & ".txt")], cwd = workRoot, outputs = [id & ".txt"],
        cpuMilli = 1000'u32, commandStatsId = "pressure-" & id,
        governingLockIdentity = lockIdentityOutsideSolvedGraph()))
    let buildResult = runBuild(graph(actions, []), BuildEngineConfig(
      cacheRoot: tempRoot / ".repro-cache",
      runQuotaCliPath: app,
      # No io-monitor on this host; the actions declare their own outputs and
      # need no monitor evidence (the pressure mechanism is unaffected).
      monitorCliPath: "",
      maxParallelism: 8'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      inlineRunQuota: true))
    for item in buildResult.results:
      checkpoint item.id & ": " & $item.status & " " & item.stderr
      check item.status == asSucceeded
    check not buildResult.runQuotaBypassed
    var client = connectDefault()
    defer: client.close()
    result = parseJson(client.queryPressure())
    # `repro pressure --json` reads the same figures, when a `reprobuild`
    # binary is present (it is not built on the Windows gate); optional.
    let reproBin = repoRoot / "build" / "bin" / "reprobuild.exe"
    if fileExists(reproBin):
      let (output, code) = execCmdEx(quoteShell(reproBin) & " pressure --json")
      checkpoint output
      if code == 0:
        result["repro_pressure"] = parseJson(output)

  proc groupNamed(answer: JsonNode; name: string): JsonNode =
    for group in answer{"groups"}:
      if group{"name"}.getStr == name:
        return group
    newJNull()

  when isMainModule:
    let params = commandLineParams()
    if params.len > 0 and params[0] == "fixture-sleep":
      # `fixture-sleep <millis> <output>`
      sleep(parseInt(params[1]))
      writeFile(params[2], "done\n")
      quit 0
    if params.len > 0 and params[0] == "__repro-runquota-helper":
      quit runRunQuotaHelperCli(params[1 .. ^1])

  suite "build-wait pressure reaches the daemon (windows)":

    test "a build whose actions queue reports some, full and its waits":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-pressure-win", "")
      defer: removeDir(tempRoot)
      let answer = buildThreeQueued(repoRoot, tempRoot, "pressure-on",
        "pressure-reports=on")
      checkpoint $answer
      let group = answer.groupNamed("pressure-on")
      check group.kind == JObject
      if group.kind == JObject:
        let some = group["some"]["total_micros"].getBiggestInt
        let full = group["full"]["total_micros"].getBiggestInt
        # Wide bounds: real processes on a shared Windows host, where each
        # action's start takes longer than on Linux.
        check some >= 2_800_000 and some <= 8_000_000
        check full < 1_000_000
        check group["waits"]["queue"]["count"].getInt == 2
        check group["reports"].getInt >= 1
        check group["queue_only_reports"].getInt >= 1

    test "with the switch off (the default) the build reports nothing":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-pressure-win-off", "")
      defer: removeDir(tempRoot)
      let answer = buildThreeQueued(repoRoot, tempRoot, "pressure-off", "")
      checkpoint $answer
      check answer.groupNamed("pressure-off").kind == JNull
      check answer["host"]["reports"].getInt == 0
else:
  echo "t_build_wait_pressure_reported_windows: Windows only"
