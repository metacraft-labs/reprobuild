import std/[algorithm, os, osproc, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_monitor_depfile
import repro_runquota

proc q(value: string): string =
  quoteShell(value)

proc runShell(command: string; cwd = getCurrentDir()): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  check res.code == 0
  if res.code != 0:
    checkpoint(res.output)
  res.output

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc ensureRunQuotaDaemon(repoRoot, tempRoot: string): tuple[process: owned(Process),
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m12-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "32000",
    "--memory-bytes", "34359738368",
    "--pool", "link=2"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc fixtureMain(args: seq[string]) =
  if args.len < 2:
    quit 64
  case args[1]
  of "copy":
    if args.len != 5:
      quit 64
    fixtureWrite(args[4], args[2] & ":" & readFile(args[3]))
  of "wide":
    if args.len != 4:
      quit 64
    sleep(20)
    fixtureWrite(args[3], "wide " & args[2] & "\n")
  of "pool":
    if args.len != 5:
      quit 64
    let logPath = args[3]
    let outputPath = args[4]
    let start = epochTime()
    fixtureWrite(logPath & "." & args[2] & ".start", $start)
    sleep(180)
    let stop = epochTime()
    fixtureWrite(logPath & "." & args[2] & ".end", $stop)
    fixtureWrite(outputPath, "pool " & args[2] & "\n")
  of "fail":
    if args.len != 3:
      quit 64
    fixtureWrite(args[2], "failing action ran\n")
    quit 7
  of "cache-should-not-run":
    if args.len != 4:
      quit 64
    fixtureWrite(args[2], "cache branch command ran\n")
    fixtureWrite(args[3], "bad uncached output\n")
  of "depfile":
    if args.len != 6:
      quit 64
    fixtureWrite(args[4], "depfile output\n")
    fixtureWrite(args[5], args[4] & ": " & args[2] & " " & args[3] & "\n")
  of "monitor":
    if args.len != 5:
      quit 64
    fixtureWrite(args[3], "monitor output\n")
    writeCanonical(args[4], [
      MonitorRecord(kind: mrFileRead, observationKind: moFileRead, seq: 4,
        osPid: 100, threadId: 1, path: args[2]),
      MonitorRecord(kind: mrFileWrite, observationKind: moFileWrite, seq: 5,
        osPid: 100, threadId: 1, path: args[3]),
      MonitorRecord(kind: mrPathProbe, observationKind: moPathProbe, seq: 6,
        osPid: 100, threadId: 1, probeResult: prAbsent,
        path: args[2] & ".missing")
    ])
  else:
    quit 64

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("m12.integration." & name)

proc prepopulateCache(cacheRoot, workRoot, markerPath, outputPath: string) =
  let inputPath = workRoot / "cache" / "input.txt"
  fixtureWrite(inputPath, "cache input\n")
  fixtureWrite(outputPath, "restored cached output\n")
  let cas = openLocalCas(cacheRoot / "cas")
  var cache = openActionCache(cacheRoot / "action-cache")
  discard cache.recordActionResult(cas, weak("cache-hit"), ffpHybrid,
    [inputPath], ["cache/out.txt"], workRoot)
  removeFile(outputPath)
  if fileExists(markerPath):
    removeFile(markerPath)

proc maxPoolConcurrency(tempRoot, prefix: string; count: int): int =
  var events: seq[tuple[t: float, delta: int]] = @[]
  for i in 0 ..< count:
    let startPath = tempRoot / (prefix & "." & $i & ".start")
    let endPath = tempRoot / (prefix & "." & $i & ".end")
    if not fileExists(startPath):
      checkpoint("missing pool start log: " & startPath)
      return count + 1
    if not fileExists(endPath):
      checkpoint("missing pool end log: " & endPath)
      return count + 1
    events.add((t: parseFloat(readFile(startPath)), delta: 1))
    events.add((t: parseFloat(readFile(endPath)), delta: -1))
  events.sort(proc(a, b: tuple[t: float, delta: int]): int =
    result = cmp(a.t, b.t)
    if result == 0:
      result = cmp(a.delta, b.delta))
  var current = 0
  for event in events:
    current += event.delta
    result = max(result, current)

proc hasMetric(buildResult: BuildRunResult; name: string): bool =
  for metric in buildResult.stats.metrics:
    if metric.name == name:
      return true
  false

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

suite "integration_build_engine_api_ready_queue":
  test "normalized API rejects dependency cycles before scheduling":
    let tempRoot = createTempDir("repro-m12-cycle", "")
    defer: removeDir(tempRoot)
    let buildGraph = graph([
      action("cycle-a", ["unused"], deps = ["cycle-b"], outputs = ["a.out"]),
      action("cycle-b", ["unused"], deps = ["cycle-a"], outputs = ["b.out"])
    ])
    expect BuildEngineError:
      discard runBuild(buildGraph, defaultBuildEngineConfig(tempRoot))

  test "runBuild emits progress callbacks for process action lifecycle":
    let tempRoot = createTempDir("repro-progress-api", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let outputPath = workRoot / "out" / "progress.txt"
    fixtureWrite(inputPath, "progress input\n")

    var events: seq[BuildProgressEvent] = @[]
    var config = BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true)
    config.statsEnabled = true
    config.progressCallback = proc(event: BuildProgressEvent) =
      events.add(event)

    let buildResult = runBuild(graph([
      action("copy-progress", [app, "fixture-action", "copy", "progress",
        inputPath, outputPath], cwd = workRoot, inputs = [inputPath],
        outputs = ["out/progress.txt"], commandStatsId = "progress-copy")
    ]), config)

    check buildResult.results.len == 1
    check buildResult.results[0].status == asSucceeded
    check readFile(outputPath).contains("progress:progress input")
    var sawSchedulerTotalStat = false
    var sawProcessWaitStat = false
    for metric in buildResult.stats.metrics:
      if metric.name == "repro scheduler total":
        sawSchedulerTotalStat = true
        check metric.count == 1
        check metric.totalUs > 0.0
      if metric.name == "repro process wait":
        sawProcessWaitStat = true
        check metric.count == 1
        check metric.totalUs >= 0.0
    check sawSchedulerTotalStat
    check sawProcessWaitStat

    var sawStarted = false
    var sawCompleted = false
    for event in events:
      if event.kind == bpkActionStarted and event.actionId == "copy-progress":
        sawStarted = true
        check event.status == asRunning
        check event.launched
        check event.total == 1
        check event.running == 1
      if event.kind == bpkActionCompleted and event.actionId == "copy-progress":
        sawCompleted = true
        check event.status == asSucceeded
        check event.completed == 1
        check event.total == 1
        check event.running == 0
    check sawStarted
    check sawCompleted

  test "runBuild fast no-op cache hit skips process launch and RunQuota probe":
    let tempRoot = createTempDir("repro-fast-noop-api", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let outputPath = workRoot / "out" / "fast-noop.txt"
    fixtureWrite(inputPath, "fast noop input\n")

    let oldSocket = getEnv("RUNQUOTA_SOCKET", "")
    putEnv("RUNQUOTA_SOCKET", tempRoot / "missing-runquota.sock")
    defer:
      putEnv("RUNQUOTA_SOCKET", oldSocket)

    var config = BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      fallbackToRunQuotaBypass: true,
      suppressTrace: true,
      skipCacheHitEvidence: true)
    config.statsEnabled = true

    let buildAction = action("copy-fast-noop", [app, "fixture-action", "copy",
      "fast-noop", inputPath, outputPath], cwd = workRoot,
      inputs = [inputPath], outputs = ["out/fast-noop.txt"],
      cacheable = true, weakFingerprint = weak("fast-noop"))

    let first = runBuild(graph([buildAction]), config)
    check first.results.len == 1
    check first.results[0].status == asSucceeded
    check first.results[0].launched
    check first.hasMetric("repro runquota probe")
    check readFile(outputPath).contains("fast-noop:fast noop input")

    let second = runBuild(graph([buildAction]), config)
    check second.results.len == 1
    check second.results[0].status == asCacheHit
    check second.results[0].cacheDecision == cdHit
    check not second.results[0].launched
    check second.hasMetric("repro fast noop scan")
    check not second.hasMetric("repro runquota probe")
    check second.trace.len == 0

  test "runBuild infers declared output to input dependencies before scheduling":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m46-api-inferred-deps", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot, tempRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let generatedPath = workRoot / "gen" / "generated.txt"
    let finalPath = workRoot / "dist" / "final.txt"
    fixtureWrite(inputPath, "api inferred deps\n")

    let buildResult = runBuild(graph([
      action("produce", [app, "fixture-action", "copy", "producer",
        inputPath, generatedPath], cwd = workRoot, inputs = [inputPath],
        outputs = ["gen/generated.txt"], commandStatsId = "m46-api-produce"),
      action("consume", [app, "fixture-action", "copy", "consumer",
        generatedPath, finalPath], cwd = workRoot,
        inputs = ["gen/generated.txt"], outputs = ["dist/final.txt"],
        commandStatsId = "m46-api-consume")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 2'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024))

    proc byId(id: string): ActionResult =
      for item in buildResult.results:
        if item.id == id:
          return item
      raise newException(ValueError, "missing result " & id)

    proc launchedIndex(id: string): int =
      for i, event in buildResult.trace:
        if event.actionId == id and event.event == "launched":
          return i
      -1

    check byId("produce").status == asSucceeded
    check byId("consume").status == asSucceeded
    check readFile(finalPath).contains("producer:api inferred deps")
    check launchedIndex("produce") >= 0
    check launchedIndex("consume") > launchedIndex("produce")

  test "runBuild applies dynamic graph fragments before launching dependent actions":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m6-api-dyndep", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot, tempRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let fragmentPath = workRoot / "deps" / "graph.rbdyn"
    let providerOutput = workRoot / "provider" / "out.txt"
    let consumerOutput = workRoot / "consumer" / "out.txt"
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "dep\tconsumer\tprovider\n")

    let buildResult = runBuild(graph([
      action("consumer", [app, "fixture-action", "copy", "consumer",
        providerOutput, consumerOutput], cwd = workRoot,
        outputs = ["consumer/out.txt"], dynamicDepsFile = "deps/graph.rbdyn",
        commandStatsId = "m6-dyndep-consumer"),
      action("provider", [app, "fixture-action", "wide", "provider",
        providerOutput], cwd = workRoot, outputs = ["provider/out.txt"],
        commandStatsId = "m6-dyndep-provider")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 2'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024))

    proc byId(id: string): ActionResult =
      for item in buildResult.results:
        if item.id == id:
          return item
      raise newException(ValueError, "missing result " & id)

    proc traceIndex(id, event: string): int =
      for i, item in buildResult.trace:
        if item.actionId == id and item.event == event:
          return i
      -1

    check byId("provider").status == asSucceeded
    check byId("consumer").status == asSucceeded
    check readFile(consumerOutput).contains("wide provider")
    check traceIndex("consumer", "dynamic-deps") >= 0
    check traceIndex("provider", "launched") >= 0
    check traceIndex("consumer", "launched") > traceIndex("provider", "asSucceeded")

  test "runBuild fails closed for malformed dynamic graph fragments":
    let tempRoot = createTempDir("repro-m6-api-dyndep-bad", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let outputPath = workRoot / "out.txt"
    fixtureWrite(workRoot / "deps" / "bad.rbdyn", "not-a-dynamic-fragment\n")

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", [app, "fixture-action", "wide", "bad", outputPath],
          cwd = workRoot, outputs = ["out.txt"],
          dynamicDepsFile = "deps/bad.rbdyn",
          commandStatsId = "m6-dyndep-bad")
      ]), BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024))
    check not fileExists(outputPath)

  test "cache hit skips CAS verification only when outputs are present":
    let tempRoot = createTempDir("repro-cache-hit-present-output", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let outputPath = workRoot / "out" / "cached.txt"
    let markerPath = workRoot / "out" / "marker.txt"
    fixtureWrite(inputPath, "cache input\n")

    let cacheAction = action("cache-present-output",
      [app, "fixture-action", "copy", "seed", inputPath, outputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/cached.txt"],
      cacheable = true, weakFingerprint = weak("cache-present-output"),
      commandStatsId = "cache-present-output")
    let restoreOnlyAction = action("cache-present-output",
      [app, "fixture-action", "cache-should-not-run", markerPath, outputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/cached.txt"],
      cacheable = true, weakFingerprint = weak("cache-present-output"),
      commandStatsId = "cache-present-output")

    proc runOne(buildAction: BuildAction): ActionResult =
      let buildResult = runBuild(graph([buildAction]), BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        rebuildMissingOutputsOnCacheHit: true,
        bypassRunQuota: true))
      check buildResult.results.len == 1
      buildResult.results[0]

    let cold = runOne(cacheAction)
    check cold.status == asSucceeded
    check readFile(outputPath) == "seed:cache input\n"
    var actionCache = openActionCache(cacheRoot / "action-cache")
    let cas = openLocalCas(cacheRoot / "cas")
    let seededLookup = actionCache.lookupActionResult(cas,
      weak("cache-present-output"), ffpHybrid)
    check seededLookup.status == aclHit
    check actionCache.lookupActionResult(cas, weak("cache-present-output"),
      ffpChecksum).status == aclMissNoRecord
    let casObject = cas.blobPath(seededLookup.record.outputs[0].blob.digest)

    removeFile(outputPath)
    let warmMissing = runOne(restoreOnlyAction)
    check warmMissing.status == asCacheHit
    check warmMissing.cacheDecision == cdHit
    check not warmMissing.launched
    check not fileExists(markerPath)
    check readFile(outputPath) == "seed:cache input\n"

    let presentContent = "local present output\n"
    writeFile(outputPath, presentContent)
    let presentMtime = fromUnix(1_700_000_100)
    setLastModificationTime(outputPath, presentMtime)
    removeIfExists(casObject)

    let warmPresent = runOne(restoreOnlyAction)
    check warmPresent.status == asCacheHit
    check warmPresent.cacheDecision == cdHit
    check not warmPresent.launched
    check not fileExists(markerPath)
    check readFile(outputPath) == presentContent
    check getFileInfo(outputPath).lastWriteTime == presentMtime

    writeFile(casObject, "corrupted")
    removeFile(outputPath)
    let corruptMissing = runOne(restoreOnlyAction)
    check corruptMissing.status == asSucceeded
    check corruptMissing.cacheDecision == cdRejected
    check corruptMissing.launched
    check fileExists(markerPath)
    check readFile(outputPath) == "bad uncached output\n"

  test "runBuild honors explicit checksum action-cache policy":
    let tempRoot = createTempDir("repro-cache-explicit-checksum", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let outputPath = workRoot / "out" / "cached.txt"
    let markerPath = workRoot / "out" / "marker.txt"
    fixtureWrite(inputPath, "checksum input\n")
    fixtureWrite(outputPath, "checksum cached output\n")

    let cas = openLocalCas(cacheRoot / "cas")
    var actionCache = openActionCache(cacheRoot / "action-cache")
    discard actionCache.recordActionResult(cas, weak("explicit-checksum"),
      ffpChecksum, [inputPath], ["out/cached.txt"], workRoot)
    removeFile(outputPath)

    let buildResult = runBuild(graph([
      action("explicit-checksum",
        [app, "fixture-action", "cache-should-not-run", markerPath, outputPath],
        cwd = workRoot, inputs = [inputPath], outputs = ["out/cached.txt"],
        cacheable = true, weakFingerprint = weak("explicit-checksum"),
        actionCachePolicy = ffpChecksum,
        commandStatsId = "explicit-checksum")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true))

    check buildResult.results.len == 1
    check buildResult.results[0].status == asCacheHit
    check buildResult.results[0].cacheDecision == cdHit
    check not buildResult.results[0].launched
    check not fileExists(markerPath)
    check readFile(outputPath) == "checksum cached output\n"
    check actionCache.lookupActionResult(cas, weak("explicit-checksum"),
      ffpHybrid).status == aclMissNoRecord

  test "normalized API schedules ready queue with RunQuota, cache, pools, failure, and evidence":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m12-build-engine", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot, tempRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)

    let srcA = workRoot / "src-a.txt"
    let srcB = workRoot / "src-b.txt"
    let depInputA = workRoot / "dep-a.h"
    let depInputB = workRoot / "dep-b.h"
    let monitorInput = workRoot / "monitor-input.txt"
    fixtureWrite(srcA, "alpha\n")
    fixtureWrite(srcB, "bravo\n")
    fixtureWrite(depInputA, "dep a\n")
    fixtureWrite(depInputB, "dep b\n")
    fixtureWrite(monitorInput, "monitor input\n")

    let cacheMarker = workRoot / "cache" / "marker.txt"
    let cacheOutput = workRoot / "cache" / "out.txt"
    prepopulateCache(cacheRoot, workRoot, cacheMarker, cacheOutput)

    var actions: seq[BuildAction] = @[]
    actions.add action("diamond-left", [app, "fixture-action", "copy", "left", srcA,
      workRoot / "diamond" / "left.txt"], cwd = workRoot, inputs = [srcA],
      outputs = ["diamond/left.txt"], commandStatsId = "diamond-left")
    actions.add action("diamond-right", [app, "fixture-action", "copy", "right", srcB,
      workRoot / "diamond" / "right.txt"], cwd = workRoot, inputs = [srcB],
      outputs = ["diamond/right.txt"], commandStatsId = "diamond-right")
    actions.add action("diamond-join", [app, "fixture-action", "copy", "join",
      workRoot / "diamond" / "left.txt", workRoot / "diamond" / "joined.txt"],
      cwd = workRoot, deps = ["diamond-left", "diamond-right"],
      inputs = [workRoot / "diamond" / "left.txt", workRoot / "diamond" / "right.txt"],
      outputs = ["diamond/joined.txt"], commandStatsId = "diamond-join")

    for i in 0 ..< 64:
      actions.add action("wide-" & $i, [app, "fixture-action", "wide", $i,
        workRoot / "wide" / ($i & ".txt")], cwd = workRoot,
        outputs = ["wide/" & $i & ".txt"], commandStatsId = "wide-" & $i)

    for i in 0 ..< 8:
      actions.add action("link-" & $i, [app, "fixture-action", "pool", $i,
        tempRoot / "link-log", workRoot / "link" / ($i & ".txt")], cwd = workRoot,
        outputs = ["link/" & $i & ".txt"], pool = "link", poolUnits = 1'u32,
        commandStatsId = "link-" & $i)

    actions.add action("cache-hit", [app, "fixture-action", "cache-should-not-run",
      cacheMarker, cacheOutput], cwd = workRoot, inputs = [workRoot / "cache" / "input.txt"],
      outputs = ["cache/out.txt"], cacheable = true, weakFingerprint = weak("cache-hit"),
      commandStatsId = "cache-hit")
    actions.add action("cache-dependent", [app, "fixture-action", "copy", "cache-dep",
      cacheOutput, workRoot / "cache" / "dependent.txt"], cwd = workRoot,
      deps = ["cache-hit"], inputs = [cacheOutput], outputs = ["cache/dependent.txt"],
      commandStatsId = "cache-dependent")

    actions.add action("will-fail", [app, "fixture-action", "fail",
      workRoot / "failure" / "ran.txt"], cwd = workRoot,
      outputs = ["failure/failed.txt"], commandStatsId = "will-fail")
    actions.add action("blocked-child", [app, "fixture-action", "copy", "blocked",
      workRoot / "failure" / "failed.txt", workRoot / "failure" / "blocked.txt"],
      cwd = workRoot, deps = ["will-fail"], outputs = ["failure/blocked.txt"],
      commandStatsId = "blocked-child")

    let depfilePath = workRoot / "deps" / "action.d"
    actions.add action("depfile-action", [app, "fixture-action", "depfile",
      depInputA, depInputB, workRoot / "deps" / "out.txt", depfilePath],
      cwd = workRoot, inputs = [depInputA], outputs = ["deps/out.txt"],
      depfile = depfilePath, commandStatsId = "depfile-action")

    let monitorDepfilePath = workRoot / "monitor" / "action.rmdf"
    actions.add action("monitor-action", [app, "fixture-action", "monitor",
      monitorInput, workRoot / "monitor" / "out.txt", monitorDepfilePath],
      cwd = workRoot, inputs = [monitorInput], outputs = ["monitor/out.txt"],
      monitorDepfile = monitorDepfilePath, commandStatsId = "monitor-action")

    let buildGraph = graph(actions, [pool("link", 2'u32)])
    let buildResult = runBuild(buildGraph, BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 16'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024))

    proc byId(id: string): ActionResult =
      for item in buildResult.results:
        if item.id == id:
          return item
      raise newException(ValueError, "missing result " & id)

    proc checkpointAction(id: string) =
      let item = byId(id)
      if item.status notin {asSucceeded, asCacheHit, asUpToDate, asBlocked}:
        checkpoint(id & " status=" & $item.status &
          " exit=" & $item.exitCode &
          " stdout=" & item.stdout &
          " stderr=" & item.stderr)

    for item in buildResult.results:
      if item.status == asFailed and item.id != "will-fail":
        checkpointAction(item.id)

    if byId("diamond-left").status != asSucceeded:
      checkpoint(byId("diamond-left").stdout)
    check byId("diamond-left").status == asSucceeded
    check byId("diamond-right").status == asSucceeded
    check byId("diamond-join").status == asSucceeded
    check fileExists(workRoot / "diamond" / "joined.txt")

    var wideSucceeded = 0
    for i in 0 ..< 64:
      if byId("wide-" & $i).status == asSucceeded:
        inc wideSucceeded
    check wideSucceeded == 64

    for i in 0 ..< 8:
      check byId("link-" & $i).status == asSucceeded
    check maxPoolConcurrency(tempRoot, "link-log", 8) <= 2

    check byId("cache-hit").status == asCacheHit
    check byId("cache-hit").cacheDecision == cdHit
    check not byId("cache-hit").launched
    check readFile(cacheOutput) == "restored cached output\n"
    check not fileExists(cacheMarker)
    check byId("cache-dependent").status == asSucceeded
    check readFile(workRoot / "cache" / "dependent.txt").contains("restored cached output")

    check byId("will-fail").status == asFailed
    check byId("will-fail").launched
    check byId("blocked-child").status == asBlocked
    check byId("blocked-child").blockedBy == "will-fail"
    check not fileExists(workRoot / "failure" / "blocked.txt")

    let depResult = byId("depfile-action")
    check depResult.status == asSucceeded
    check depResult.evidence.depfileInputs.find(depInputA) >= 0
    check depResult.evidence.depfileInputs.find(depInputB) >= 0

    let monitorResult = byId("monitor-action")
    check monitorResult.status == asSucceeded
    check monitorResult.evidence.monitorReads.find(monitorInput) >= 0
    check monitorResult.evidence.monitorWrites.find(workRoot / "monitor" / "out.txt") >= 0
    check monitorResult.evidence.monitorProbes.find(monitorInput & ".missing") >= 0

    check buildResult.trace.len >= actions.len
    check buildResult.trace[0].seq == 1'u64
    let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin" / "runquota"
    let status = requireSuccess(q(runquotaBin) & " status", repoRoot)
    check status.contains("total_granted:")
    check status.contains("total_finished:")
    for item in buildResult.results:
      if item.launched:
        check item.runQuotaBackend.len > 0
