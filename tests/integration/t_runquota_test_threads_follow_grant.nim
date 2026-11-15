## Negotiated widths reach a test binary that takes its width as a flag.
##
## An action that declares a CPU range (``cpuMinMilli`` .. ``cpuPreferredMilli``)
## and a width flag (``widthFlag = "--test-threads"``) is offered to a real
## ``runquotad`` as a range. RunQuota grants the widest width that is free,
## and the action's command runs with that grant in its flag and in
## ``RUNQUOTA_RUN_WIDTH``.
##
## WHAT IS GUARDED, with the mutation that breaks it:
##
## * test_threads_follow_grant: on a daemon with a 3-slot budget, a test
##   action asking for 1..16 slots is granted 3 and its binary runs with
##   ``--test-threads 3``. Mutation: launch the declared argv
##   (``applyGrantedWidth`` returning the command unchanged) and the binary
##   receives the unfilled placeholder instead of a width, and no
##   ``RUNQUOTA_RUN_WIDTH``.
## * A ``--test-threads 64`` already on the command line, more than the
##   grant, is lowered to the grant. ``--test-threads 2``, less than the
##   grant, is kept as written.
##
## NO MOCKS, ONE FIXTURE: the "test binary" is this file's own executable in
## ``fixture-action`` mode. It records the argv and ``RUNQUOTA_RUN_WIDTH``
## it was started with, which is exactly what a real test binary would
## receive. The daemon is the real ``runquotad`` (``RUNQUOTAD_BIN``), started
## by this file on an endpoint it owns, under the private endpoint policy
## (``RUNQUOTA_ENDPOINT_SCOPE=private``) because the endpoint is the test
## user's own.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_build_engine
import repro_runquota

import repro_test_support

proc pathPresent(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc startDaemon(repoRoot: string; cpuMilli: int):
    tuple[process: owned(Process), socket: string] =
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = runquotaSocketEndpoint(
    "repro-widths-rq-" & $getCurrentProcessId())
  # The daemon and this process's client both use the private policy: the
  # endpoint belongs to the user running the test, whatever system account a
  # host's own RunQuota service runs as.
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", $cpuMilli,
    "--memory-bytes", "34359738368"
  ], options = {poUsePath, poStdErrToStdOut})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 400:
    if pathPresent(socketPath):
      return (process: daemon, socket: socketPath)
    if not daemon.running:
      break
    sleep(25)
  let output = daemon.outputStream.readAll()
  daemon.close()
  raise newException(OSError, "runquotad socket did not appear: " & output)

proc fixtureMain(args: seq[string]) =
  ## `fixture-action record <path> [args...]`: the argv after `<path>` and
  ## RUNQUOTA_RUN_WIDTH, one per line.
  if args.len < 3 or args[1] != "record": quit 64
  createDir(args[2].splitPath.head)
  writeFile(args[2], "width=" & getEnv("RUNQUOTA_RUN_WIDTH") & "\n" &
    args[3 .. ^1].join("\n") & "\n")

when defined(macosx) or defined(linux):
  var cachedMonitorTools: MonitorTools
  var cachedMonitorToolsReady = false
  proc monitorTools(repoRoot: string): MonitorTools =
    if not cachedMonitorToolsReady:
      cachedMonitorTools = prepareMonitorTools(repoRoot,
        repoRoot / "build" / "test-monitor-widths", "widths-monitor")
      putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
      cachedMonitorToolsReady = true
    cachedMonitorTools

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

suite "negotiated widths reach the test binary":

  when isNixSupported:
    test "test_threads_follow_grant: a test action granted 3 slots runs " &
        "its test binary with --test-threads 3":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-widths", "")
      defer: removeDir(tempRoot)
      var daemon = startDaemon(repoRoot, 3000)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()

      let app = getAppFilename()
      let workRoot = tempRoot / "work"
      createDir(workRoot)
      proc testAction(id: string; extra: openArray[string]): BuildAction =
        var argv = @[app, "fixture-action", "record", workRoot / (id & ".txt")]
        argv.add extra
        action(id, argv, cwd = workRoot, outputs = [id & ".txt"],
          cpuMinMilli = 1000'u32, cpuPreferredMilli = 16000'u32,
          widthFlag = "--test-threads", commandStatsId = id,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let actions = @[
        testAction("plain", ["--nocapture"]),
        testAction("asked-more", ["--test-threads", "64"]),
        testAction("asked-less", ["--test-threads", "2", "--", "filter"])]
      # One at a time: each is then granted the whole 3-slot budget.
      var graphActions = actions
      graphActions[1].deps = @["plain"]
      graphActions[2].deps = @["asked-more"]
      let buildResult = runBuild(graph(graphActions, []), BuildEngineConfig(
        cacheRoot: tempRoot / ".repro-cache",
        runQuotaCliPath: app,
        monitorCliPath: monitorTools(repoRoot).monitorCliPath,
        monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
        maxParallelism: 8'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        inlineRunQuota: true))
      for item in buildResult.results:
        checkpoint item.id & ": " & $item.status & " " & item.stderr
        check item.status == asSucceeded
      check not buildResult.runQuotaBypassed

      proc recorded(id: string): seq[string] =
        readFile(workRoot / (id & ".txt")).strip().splitLines()
      # Granted 3 of the 1..16 asked for (the whole budget), passed on.
      check recorded("plain") == @["width=3", "--nocapture",
        "--test-threads", "3"]
      # More than the grant is lowered to it.
      check recorded("asked-more") == @["width=3", "--test-threads", "3"]
      # Less than the grant is kept; nothing goes after the `--`.
      check recorded("asked-less") == @["width=3", "--test-threads", "2",
        "--", "filter"]
