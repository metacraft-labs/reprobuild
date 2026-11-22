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
## * bypass_shares_the_host: with no lease (``bypassRunQuota``), a sized
##   action still gets a width, an equal share of the cores the running sized
##   actions do not hold among the sized actions that launch together
##   (``bypassWidthMilli``), so two that launch together hold no more than
##   the host's cores between them. Mutation: launch the declared argv under
##   the bypass, as before 2026-11-15, and the binary receives no
##   ``--test-threads`` and no ``RUNQUOTA_RUN_WIDTH`` -- for a Nim compile,
##   no ``--parallelBuild``, so one C compiler per core per concurrent action
##   (~250 ``cc1`` on a 32-core host in full run 53).
## * bypass_lone_action_takes_the_free_cores: a sized action that launches
##   alone under the bypass runs at every core of the host. Mutation: the
##   static share ``hostCores div maxParallelism`` of 2026-11-15, and it runs
##   at half of them here -- in full run 54 the build's last action, the main
##   ``reprobuild`` compile, ran alone at ``--parallelBuild:2`` on 32 cores
##   for over 80 minutes.
##
## NO MOCKS, ONE FIXTURE: the "test binary" is this file's own executable in
## ``fixture-action`` mode. It records the argv and ``RUNQUOTA_RUN_WIDTH``
## it was started with, which is exactly what a real test binary would
## receive. The daemon is the real ``runquotad`` (``RUNQUOTAD_BIN``), started
## by this file on an endpoint it owns, under the private endpoint policy
## (``RUNQUOTA_ENDPOINT_SCOPE=private``) because the endpoint is the test
## user's own.

# The RunQuota helper role of the image this test stands in for: its
# command line read by repro's generated parser.
from repro_cli_support/runquota_helper_cli import runRunQuotaHelperArgs,
  selectsRunQuotaHelper
import std/[os, osproc, streams, strutils, tables, tempfiles, unittest]

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
  # Out of tries with the daemon still up: stop it, so the read below
  # ends instead of waiting on a live writer.
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit()
  # readall-ok: diagnostic from a daemon that left or was stopped; a descendant may hold the pipe
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
  if selectsRunQuotaHelper(params):
    quit runRunQuotaHelperArgs(params)

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

  proc bypassRecords(name: string; parallelism: int;
                     actions: openArray[tuple[id: string; extra: seq[string];
                                              deps: seq[string]]]):
      Table[string, seq[string]] =
    ## Runs ``actions`` under the bypass at ``parallelism`` and returns what
    ## each recorded: ``width=<RUNQUOTA_RUN_WIDTH>`` and its argv.
    let tempRoot = createTempDir(name, "")
    defer: removeDir(tempRoot)
    let workRoot = tempRoot / "work"
    createDir(workRoot)
    let app = getAppFilename()
    var graphActions: seq[BuildAction]
    for spec in actions:
      var argv = @[app, "fixture-action", "record",
        workRoot / (spec.id & ".txt")]
      argv.add spec.extra
      var a = action(spec.id, argv, cwd = workRoot,
        outputs = [spec.id & ".txt"],
        cpuMinMilli = 1000'u32, cpuPreferredMilli = 64000'u32,
        widthFlag = "--test-threads", commandStatsId = spec.id,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      a.deps = spec.deps
      graphActions.add a
    let buildResult = runBuild(graph(graphActions, []), BuildEngineConfig(
      cacheRoot: tempRoot / ".repro-cache",
      maxParallelism: uint32(parallelism),
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true))
    for item in buildResult.results:
      checkpoint item.id & ": " & $item.status & " " & item.stderr
      check item.status == asSucceeded
    for spec in actions:
      result[spec.id] =
        readFile(workRoot / (spec.id & ".txt")).strip().splitLines()

  proc threadsOf(record: seq[string]): int =
    let at = record.find("--test-threads")
    if at < 0 or at + 1 >= record.len: return 0
    parseInt(record[at + 1])

  test "bypass_shares_the_host: without a lease a sized action runs at " &
      "its share of the host's cores":
    # The cores the running sized actions do not hold, shared among those
    # that launch together; at least one slot.
    check bypassWidthMilli(32, 0, 12) == 2000'u32
    check bypassWidthMilli(32, 0, 8) == 4000'u32
    check bypassWidthMilli(4, 0, 12) == 1000'u32
    check bypassWidthMilli(0, 0, 0) == 1000'u32
    # A lone action takes every free core.
    check bypassWidthMilli(32, 0, 1) == 32000'u32
    check bypassWidthMilli(32, 22, 1) == 10000'u32
    check bypassWidthMilli(32, 2, 11) == 2000'u32
    # The floor: a launch onto a host whose cores are all held still runs.
    check bypassWidthMilli(32, 32, 1) == 1000'u32
    check bypassWidthMilli(32, 40, 3) == 1000'u32

    let cores = countProcessors()
    let records = bypassRecords("repro-widths-bypass", 2, [
      (id: "bypass-plain", extra: @["--nocapture"], deps: newSeq[string]()),
      (id: "bypass-asked-less", extra: @["--test-threads", "1"],
       deps: newSeq[string]())])
    let plain = records["bypass-plain"]
    let less = records["bypass-asked-less"]
    checkpoint "cores=" & $cores & " plain=" & $plain & " less=" & $less
    check plain.len == 4
    check plain[0 .. 1] == @["width=" & plain[3], "--nocapture"]
    check plain[2] == "--test-threads"
    # A width the command already asks for, within the share, is kept.
    check less[1 .. 2] == @["--test-threads", "1"]
    check less[0].startsWith("width=")
    # Launched together, the two hold no more than the host's cores (when it
    # has two to share); one launches first and holds at most half of them.
    let plainThreads = threadsOf(plain)
    check plainThreads >= 1
    if cores >= 2:
      check plainThreads + threadsOf(less) <= cores
      check plainThreads >= cores div 2

  test "bypass_lone_action_takes_the_free_cores: a sized action that " &
      "launches alone under the bypass runs at every core":
    let cores = countProcessors()
    # Two in a chain at parallelism 4: each launches alone, the second after
    # the first has been reaped and released its width.
    let records = bypassRecords("repro-widths-lone", 4, [
      (id: "lone-first", extra: @["--nocapture"], deps: newSeq[string]()),
      (id: "lone-tail", extra: @["--nocapture"], deps: @["lone-first"])])
    for id in ["lone-first", "lone-tail"]:
      checkpoint id & ": " & $records[id]
      check records[id] == @["width=" & $cores, "--nocapture",
        "--test-threads", $cores]
