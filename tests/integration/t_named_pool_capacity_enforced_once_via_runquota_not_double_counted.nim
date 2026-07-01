## RA-13 — named scarce-resource pools are enforced ONCE, by RunQuota,
## and are NOT double-counted by an engine-local authoritative gate.
##
## ## What this pins (Build-Engine-And-Scheduler.md § "One executor, one
## resource authority")
##
## Named pools (``host/linker``, ``host/pty``, …) are RunQuota-owned and
## cross-session. Before RA-13 the engine ALSO kept a local
## ``poolCapacity``/``poolRunning`` gate and capped a named pool's
## concurrency per-invocation — the SAME pool was gated twice (once
## locally, once by RunQuota's grant). RA-13 makes RunQuota the sole
## authority when it is active: the engine declares the action's pool
## membership + units in the lease request and lets RunQuota's grant gate
## capacity; it does NOT also gate locally.
##
## Two falsifiable assertions:
##
## 1. CONSTRUCTION — the lease request the engine sends for a pooled action
##    carries the pool name and unit cost (so RunQuota can enforce it).
##    Falsifies if the engine ever stops declaring the pool to RunQuota.
##
## 2. SOLE-AUTHORITY (the anti-double-gate signal) — run a real ``runquotad``
##    whose ``link`` pool cap is 2, but declare the engine graph's local
##    ``link`` pool capacity as 1, with several ready ``link`` actions and
##    RunQuota ACTIVE. If the engine still consulted its local gate (the
##    double-gate), local cap 1 would bind and at most ONE link action would
##    run at a time. RA-13 skips the local gate when RunQuota is active, so
##    RunQuota's cap of 2 is the only constraint and concurrency reaches 2.
##    We assert ``2 <= maxConcurrency <= 2``: the lower bound falsifies the
##    double-gate; the upper bound confirms RunQuota actually enforces.
##    (Re-adding the local gate on the active path makes maxConcurrency == 1
##    and fails the lower bound.)

import std/[algorithm, os, osproc, strutils, tempfiles, times, unittest]
when defined(posix):
  import std/posix

import repro_build_engine
import repro_runquota

import repro_test_support

proc q(value: string): string =
  quoteShell(value)

proc pathPresent(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  check res.exitCode == 0
  if res.exitCode != 0:
    checkpoint(res.output)
  res.output

proc startLinkPoolDaemon(repoRoot: string; linkCap: int):
    tuple[process: owned(Process), socket: string] =
  ## Real ``runquotad`` whose ``link`` pool admits ``linkCap`` units.
  let runquotaRoot = repoRoot.parentDir / "runquota"
  var daemonBin = getEnv("RUNQUOTAD_BIN")
  if daemonBin.len == 0:
    daemonBin = findExe("runquotad")
  let siblingBin = runquotaRoot / "build" / "bin" /
    addFileExt("runquotad", ExeExt)
  if daemonBin.len == 0:
    daemonBin = siblingBin
  if not fileExists(daemonBin) and daemonBin == siblingBin:
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin &
      "; set RUNQUOTAD_BIN or use direnv exec so runquotad is on PATH")
  let socketPath = "/tmp/repro-ra13-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "32000",
    "--memory-bytes", "34359738368",
    "--pool", "link=" & $linkCap
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathPresent(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc resolveRunQuotaClient(repoRoot: string): string =
  result = findExe("runquota")
  if result.len > 0:
    return
  result = repoRoot.parentDir / "runquota" / "build" / "bin" /
    addFileExt("runquota", ExeExt)
  if not fileExists(result):
    raise newException(OSError,
      "runquota binary missing at " & result &
      "; use direnv exec so runquota is on PATH")

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc fixtureMain(args: seq[string]) =
  # "pool" <index> <log-prefix> <output> — record start/end timestamps so the
  # harness can compute observed peak concurrency, with a sleep wide enough to
  # overlap when the gate allows it.
  if args.len < 2: quit 64
  case args[1]
  of "pool":
    if args.len != 5: quit 64
    let logPath = args[3]
    let outputPath = args[4]
    fixtureWrite(logPath & "." & args[2] & ".start", $epochTime())
    sleep(220)
    fixtureWrite(logPath & "." & args[2] & ".end", $epochTime())
    fixtureWrite(outputPath, "pool " & args[2] & "\n")
  else: quit 64

proc maxPoolConcurrency(tempRoot, prefix: string; count: int): int =
  var events: seq[tuple[t: float, delta: int]] = @[]
  for i in 0 ..< count:
    let startPath = tempRoot / (prefix & "." & $i & ".start")
    let endPath = tempRoot / (prefix & "." & $i & ".end")
    if not fileExists(startPath) or not fileExists(endPath):
      checkpoint("missing pool log for index " & $i)
      return count + 1
    events.add((t: parseFloat(readFile(startPath)), delta: 1))
    events.add((t: parseFloat(readFile(endPath)), delta: -1))
  events.sort(proc(a, b: tuple[t: float, delta: int]): int =
    result = cmp(a.t, b.t)
    if result == 0: result = cmp(a.delta, b.delta))
  var current = 0
  for event in events:
    current += event.delta
    result = max(result, current)

when defined(macosx) or defined(linux):
  var cachedMonitorTools: MonitorTools
  var cachedMonitorToolsReady = false
  proc monitorTools(repoRoot: string): MonitorTools =
    if not cachedMonitorToolsReady:
      cachedMonitorTools = prepareMonitorTools(repoRoot,
        repoRoot / "build" / "test-monitor-ra13", "ra13-monitor")
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

suite "RA-13 named pool enforced once via RunQuota (no double-gate)":

  test "engine lease request for a pooled action declares the pool + units":
    # CONSTRUCTION assertion. The engine forwards the action's pool membership
    # and unit cost into the RunQuota lease request; the helper argv that
    # spawns the leased child carries --pool/--pool-units. This is what lets
    # RunQuota be the sole authority for the pool.
    let pooled = action("link-0", ["/bin/true"], pool = "link", poolUnits = 1'u32)
    check pooled.pool == "link"
    check pooled.poolUnits == 1'u32
    let request = ReproResourceRequest(
      label: pooled.id,
      namedPool: pooled.pool,
      namedPoolUnits: pooled.poolUnits)
    let resolved = request.toRunQuotaRequest()
    check resolved.resources.namedPools.len == 1
    check resolved.resources.namedPools[0].name == "link"
    check resolved.resources.namedPools[0].units == 1'u32
    let command = ReproCommandSpec(argv: pooled.argv, cwd: getCurrentDir())
    let argv = helperCliArgs(request, command, "/tmp/ra13-result.json")
    var sawPool = false
    var sawUnits = false
    for i in 0 ..< argv.len - 1:
      if argv[i] == "--pool" and argv[i + 1] == "link": sawPool = true
      if argv[i] == "--pool-units" and argv[i + 1] == "1": sawUnits = true
    check sawPool
    check sawUnits

  when isNixSupported:
    test "named pool gated by RunQuota only — local cap is not double-counted":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-ra13-named-pool", "")
      defer: removeDir(tempRoot)

      # RunQuota link pool admits 2 units; the engine graph's LOCAL link cap is
      # deliberately 1. With RunQuota active the local cap must be ignored.
      var daemon = startLinkPoolDaemon(repoRoot, linkCap = 2)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathPresent(daemon.socket):
          removeFile(daemon.socket)

      let app = getAppFilename()
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      createDir(workRoot)

      var actions: seq[BuildAction] = @[]
      for i in 0 ..< 6:
        actions.add action("link-" & $i, [app, "fixture-action", "pool", $i,
          tempRoot / "link-log", workRoot / "link" / ($i & ".txt")],
          cwd = workRoot, outputs = ["link/" & $i & ".txt"],
          pool = "link", poolUnits = 1'u32, commandStatsId = "link-" & $i)

      # Local declared link capacity = 1 (smaller than RunQuota's 2): if the
      # engine still gated locally this would cap concurrency to 1.
      let buildGraph = graph(actions, [pool("link", 1'u32)])
      let buildResult = runBuild(buildGraph, BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        monitorCliPath: monitorTools(repoRoot).monitorCliPath,
        monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
        maxParallelism: 8'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        inlineRunQuota: true))

      proc byId(id: string): ActionResult =
        for item in buildResult.results:
          if item.id == id: return item
        raise newException(ValueError, "missing result " & id)

      for i in 0 ..< 6:
        check byId("link-" & $i).status == asSucceeded

      let observed = maxPoolConcurrency(tempRoot, "link-log", 6)
      # Lower bound falsifies the double-gate (local cap 1 would force 1);
      # upper bound confirms RunQuota's cap of 2 is actually enforced.
      check observed >= 2
      check observed <= 2

      # RunQuota actually granted/finished these leases (it WAS the authority).
      let runquotaBin = resolveRunQuotaClient(repoRoot)
      let status = requireSuccess(q(runquotaBin) & " status", repoRoot)
      check status.contains("total_granted:")
      check status.contains("total_finished:")

      # The build was NOT a bypass run — RunQuota was the authority.
      check not buildResult.runQuotaBypassed
      for item in buildResult.results:
        if item.launched:
          check item.runQuotaBackend.len > 0
          check item.runQuotaBackend != "runquota-bypass"
