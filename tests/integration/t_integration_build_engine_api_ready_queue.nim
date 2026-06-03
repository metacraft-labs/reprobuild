import std/[algorithm, json, os, osproc, strutils, tempfiles, times, unittest]

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

proc ensureRunQuotaDaemon(repoRoot, tempRoot: string; cpuMilli = "32000"):
    tuple[process: owned(Process), socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m12-rq-" & $getCurrentProcessId() & ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", cpuMilli,
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
  of "emit-dyndep":
    # M25: copy a prepared dyndep fragment from <source-path> to
    # <fragment-output-path>. The source file is staged by the test ahead
    # of time so JSON payloads carrying Windows paths (``\\`` escapes) do
    # not have to round-trip through argv-escape encoding. Argv layout:
    # "emit-dyndep" <fragment-output-path> <source-path>
    if args.len != 4:
      quit 64
    fixtureWrite(args[2], readFile(args[3]))
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
  discard cache.recordActionResult(cas, weak("cache-hit"), ffpTimestamp,
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
        check event.checked == 1
        check event.settled == 0
        check event.plannedExecutions == 1
        check event.completedExecutions == 0
        check event.running == 1
      if event.kind == bpkActionCompleted and event.actionId == "copy-progress":
        sawCompleted = true
        check event.status == asSucceeded
        check event.completed == 1
        check event.total == 1
        check event.checked == 1
        check event.settled == 1
        check event.plannedExecutions == 1
        check event.completedExecutions == 1
        check event.executionPlanKnown
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
    check second.results[0].status in {asCacheHit, asUpToDate}
    check second.results[0].cacheDecision == cdHit
    check not second.results[0].launched
    check second.hasMetric("repro fast noop scan")
    check not second.hasMetric("repro runquota probe")
    check second.trace.len == 0

  test "runBuild materializes relative declared inputs before cache checks":
    let tempRoot = createTempDir("repro-relative-input-cache", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    let inputPath = workRoot / "src" / "input.txt"
    let outputPath = workRoot / "out" / "copied.txt"
    fixtureWrite(inputPath, "one\n")

    var config = defaultBuildEngineConfig(cacheRoot)
    config.rebuildMissingOutputsOnCacheHit = true
    config.suppressTrace = true

    let copyAction = builtinAction(bakCopyFile, "relative-copy",
      cwd = workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/copied.txt"],
      cacheable = true,
      weakFingerprint = weak("relative-copy"))

    let first = runBuild(graph([copyAction]), config)
    check first.results.len == 1
    check first.results[0].status == asSucceeded
    check first.results[0].launched
    check readFile(outputPath) == "one\n"

    fixtureWrite(inputPath, "two changed\n")

    let second = runBuild(graph([copyAction]), config)
    check second.results.len == 1
    check second.results[0].status == asSucceeded
    check second.results[0].cacheDecision == cdMiss
    check second.results[0].launched
    check readFile(outputPath) == "two changed\n"

  test "runBuild fast no-op ignores stale unrelated hot cache inputs":
    let tempRoot = createTempDir("repro-fast-noop-scoped", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let selectedInput = workRoot / "src" / "selected.txt"
    let selectedOutput = workRoot / "out" / "selected.txt"
    let staleInput = workRoot / "src" / "stale.txt"
    let staleOutput = workRoot / "out" / "stale.txt"
    fixtureWrite(selectedInput, "selected input\n")
    fixtureWrite(selectedOutput, "selected cached output\n")
    fixtureWrite(staleInput, "stale input before\n")
    fixtureWrite(staleOutput, "stale cached output\n")

    let selectedAction = action("selected", [app, "fixture-action", "copy",
      "selected", selectedInput, selectedOutput], cwd = workRoot,
      inputs = [selectedInput], outputs = ["out/selected.txt"],
      cacheable = true, weakFingerprint = weak("fast-noop-selected"))
    let staleAction = action("stale", [app, "fixture-action", "copy",
      "stale", staleInput, staleOutput], cwd = workRoot,
      inputs = [staleInput], outputs = ["out/stale.txt"],
      cacheable = true, weakFingerprint = weak("fast-noop-stale"))

    let cas = openLocalCas(cacheRoot / "cas")
    var cache = openActionCache(cacheRoot / "action-cache")
    discard cache.recordActionResult(cas, selectedAction.weakFingerprint,
      selectedAction.actionCachePolicy, selectedAction.inputs,
      selectedAction.outputs, workRoot)
    discard cache.recordActionResult(cas, staleAction.weakFingerprint,
      staleAction.actionCachePolicy, staleAction.inputs, staleAction.outputs,
      workRoot)
    cache.flushHotIndex()
    fixtureWrite(staleInput, "stale input after\n")

    var config = BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      rebuildMissingOutputsOnCacheHit: true,
      suppressTrace: true,
      skipCacheHitEvidence: true)
    config.statsEnabled = true

    let buildResult = runBuild(graph([selectedAction]), config)
    check buildResult.results.len == 1
    check buildResult.results[0].status in {asCacheHit, asUpToDate}
    check not buildResult.results[0].launched
    check buildResult.hasMetric("repro fast noop scan")
    check not buildResult.hasMetric("repro scheduler initialize")

  test "inline RunQuota queued leases do not block scheduler completion":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-inline-rq-queued", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot, tempRoot, cpuMilli = "1000")
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

    let buildResult = runBuild(graph([
      action("inline-a", [app, "fixture-action", "pool", "0",
        tempRoot / "inline-log", workRoot / "inline" / "a.txt"],
        cwd = workRoot, outputs = ["inline/a.txt"], cpuMilli = 1000'u32,
        commandStatsId = "inline-a"),
      action("inline-b", [app, "fixture-action", "pool", "1",
        tempRoot / "inline-log", workRoot / "inline" / "b.txt"],
        cwd = workRoot, outputs = ["inline/b.txt"], cpuMilli = 1000'u32,
        commandStatsId = "inline-b")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 2'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      inlineRunQuota: true))

    proc byId(id: string): ActionResult =
      for item in buildResult.results:
        if item.id == id:
          return item
      raise newException(ValueError, "missing result " & id)

    check byId("inline-a").status == asSucceeded
    check byId("inline-b").status == asSucceeded
    check maxPoolConcurrency(tempRoot, "inline-log", 2) == 1
    var sawQueued = false
    var sawGrantedLaunch = false
    for event in buildResult.trace:
      if event.event == "queued":
        sawQueued = true
      if event.event == "launched" and event.detail == "runquota-grant":
        sawGrantedLaunch = true
    check sawQueued
    check sawGrantedLaunch

  test "inline RunQuota denied leases are action failures":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-inline-rq-denied", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot, tempRoot, cpuMilli = "1000")
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
    let outputPath = workRoot / "denied" / "out.txt"

    let buildResult = runBuild(graph([
      action("inline-denied", [app, "fixture-action", "wide", "denied",
        outputPath], cwd = workRoot, outputs = ["denied/out.txt"],
        cpuMilli = 2000'u32, commandStatsId = "inline-denied")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 1'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      inlineRunQuota: true))

    check buildResult.results.len == 1
    check buildResult.results[0].status == asFailed
    check buildResult.results[0].stderr.contains("denied")
    check buildResult.results[0].runQuotaBackend == "runquota-inline"
    check not fileExists(outputPath)

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

  test "M25: engine materialises action-create dyndep records into the running graph":
    # Standalone dyndep ingest scenario. ``producer`` writes a .rbdyn that
    # carries one ``create-action`` record (``synth-copy``) plus a ``dep``
    # edge wiring the consumer onto the new action. The engine must:
    #   1. parse the create-action JSON,
    #   2. materialise ``synth-copy`` into the graph,
    #   3. schedule ``synth-copy`` so its output exists before the
    #      consumer launches,
    #   4. surface ``synth-copy``'s result in ``buildResult.results``.
    let tempRoot = createTempDir("repro-m25-action-create", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let synthInput = workRoot / "src" / "synth.txt"
    let synthOutput = workRoot / "build" / "synth.copy.txt"
    let consumerOutput = workRoot / "build" / "consumer.txt"
    let fragmentPath = workRoot / "build" / "consumer.rbdyn"
    fixtureWrite(synthInput, "m25 synth payload\n")

    # The dyndep-emitter ``producer`` writes a fragment shaped like:
    #   repro-dynamic-graph-v1
    #   create-action\t{"id":"synth-copy", "argv":[...], "outputs":[...]}
    #   dep\tconsumer\tsynth-copy
    let createJson = $(%*{
      "id": "synth-copy",
      "argv": [app, "fixture-action", "copy", "synth", synthInput,
        synthOutput],
      "cwd": workRoot,
      "inputs": [synthInput],
      "outputs": ["build/synth.copy.txt"],
      "commandStatsId": "m25-synth-copy"
    })
    let fragmentSource = workRoot / "stage" / "consumer.rbdyn.src"
    fixtureWrite(fragmentSource,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n" &
      "dep\tconsumer\tsynth-copy\n")

    let buildResult = runBuild(graph([
      action("producer", [app, "fixture-action", "emit-dyndep",
        fragmentPath, fragmentSource],
        cwd = workRoot, outputs = ["build/consumer.rbdyn"],
        commandStatsId = "m25-producer"),
      action("consumer", [app, "fixture-action", "copy", "consumer",
        synthOutput, consumerOutput],
        cwd = workRoot, deps = ["producer"],
        outputs = ["build/consumer.txt"],
        dynamicDepsFile = "build/consumer.rbdyn",
        commandStatsId = "m25-consumer")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 2'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true))

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

    check byId("producer").status == asSucceeded
    check byId("synth-copy").status == asSucceeded
    check byId("consumer").status == asSucceeded
    check fileExists(synthOutput)
    check fileExists(consumerOutput)
    check readFile(synthOutput).contains("synth:m25 synth payload")
    check readFile(consumerOutput).contains("consumer:synth:m25 synth payload")

    # action-create trace event attributes the materialisation back to
    # the producer of the .rbdyn record.
    let createIdx = traceIndex("synth-copy", "action-create")
    check createIdx >= 0
    check buildResult.trace[createIdx].detail == "producer=consumer"

    # Scheduling order: synth-copy must succeed BEFORE consumer launches.
    check traceIndex("synth-copy", "asSucceeded") >= 0
    check traceIndex("consumer", "launched") >
      traceIndex("synth-copy", "asSucceeded")

  test "M25: engine rejects action-create records that reference unknown deps":
    let tempRoot = createTempDir("repro-m25-action-create-bad-dep", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let consumerOutput = workRoot / "build" / "consumer.txt"
    let fragmentPath = workRoot / "build" / "consumer.rbdyn"
    # The created action declares a dep on ``ghost`` which is absent from
    # the static graph AND not produced by any earlier ``create-action``
    # record in the same fragment. The engine must reject the entire
    # dyndep ingest as a closed-loop validation failure.
    let createJson = $(%*{
      "id": "orphan",
      "argv": [app, "fixture-action", "wide", "orphan",
        workRoot / "build" / "orphan.txt"],
      "cwd": workRoot,
      "outputs": ["build/orphan.txt"],
      "deps": ["ghost"],
      "commandStatsId": "m25-orphan"
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n")

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", [app, "fixture-action", "wide", "consumer",
          consumerOutput], cwd = workRoot, outputs = ["build/consumer.txt"],
          dynamicDepsFile = "build/consumer.rbdyn",
          commandStatsId = "m25-bad-dep-consumer")
      ]), BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        bypassRunQuota: true))
    check not fileExists(consumerOutput)

  test "M25: engine rejects action-create records that duplicate an existing action id":
    let tempRoot = createTempDir("repro-m25-action-create-dup", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let consumerOutput = workRoot / "build" / "consumer.txt"
    let fragmentPath = workRoot / "build" / "consumer.rbdyn"
    # The create-action record uses ``consumer`` as its id — which is
    # already present in the static graph. Duplicate-id ingest must
    # raise BuildEngineError and leave the consumer unscheduled.
    let createJson = $(%*{
      "id": "consumer",
      "argv": [app, "fixture-action", "wide", "dup",
        workRoot / "build" / "dup.txt"],
      "cwd": workRoot,
      "outputs": ["build/dup.txt"],
      "commandStatsId": "m25-dup"
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n")

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", [app, "fixture-action", "wide", "consumer",
          consumerOutput], cwd = workRoot, outputs = ["build/consumer.txt"],
          dynamicDepsFile = "build/consumer.rbdyn",
          commandStatsId = "m25-dup-consumer")
      ]), BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        bypassRunQuota: true))
    check not fileExists(consumerOutput)

  test "M25: malformed action-create JSON payload fails closed":
    let tempRoot = createTempDir("repro-m25-action-create-bad-json", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let consumerOutput = workRoot / "build" / "consumer.txt"
    let fragmentPath = workRoot / "build" / "consumer.rbdyn"
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\tthis is not json\n")

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", [app, "fixture-action", "wide", "consumer",
          consumerOutput], cwd = workRoot, outputs = ["build/consumer.txt"],
          dynamicDepsFile = "build/consumer.rbdyn",
          commandStatsId = "m25-bad-json-consumer")
      ]), BuildEngineConfig(
        cacheRoot: cacheRoot,
        runQuotaCliPath: app,
        maxParallelism: 1'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        bypassRunQuota: true))
    check not fileExists(consumerOutput)

  test "M25: two action-create records with a dep edge between them schedule in order":
    # Validates the "second action references the first" path: one .rbdyn
    # creates two new actions A and B and declares B depends on A. The
    # scheduler must materialise both, run A before B, then run the
    # consumer (which depends on B via a dep edge in the same fragment).
    let tempRoot = createTempDir("repro-m25-two-create", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let stageA = workRoot / "build" / "a.txt"
    let stageB = workRoot / "build" / "b.txt"
    let consumerOutput = workRoot / "build" / "consumer.txt"
    let fragmentPath = workRoot / "build" / "consumer.rbdyn"
    let inputPath = workRoot / "src" / "in.txt"
    fixtureWrite(inputPath, "two-create input\n")

    let createA = $(%*{
      "id": "stage-a",
      "argv": [app, "fixture-action", "copy", "a", inputPath, stageA],
      "cwd": workRoot,
      "outputs": ["build/a.txt"],
      "commandStatsId": "m25-stage-a"
    })
    let createB = $(%*{
      "id": "stage-b",
      "argv": [app, "fixture-action", "copy", "b", stageA, stageB],
      "cwd": workRoot,
      "deps": ["stage-a"],
      "outputs": ["build/b.txt"],
      "commandStatsId": "m25-stage-b"
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createA & "\n" &
      "create-action\t" & createB & "\n" &
      "dep\tconsumer\tstage-b\n")

    let buildResult = runBuild(graph([
      action("consumer", [app, "fixture-action", "copy", "consumer",
        stageB, consumerOutput], cwd = workRoot,
        outputs = ["build/consumer.txt"],
        dynamicDepsFile = "build/consumer.rbdyn",
        commandStatsId = "m25-two-create-consumer")
    ]), BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: app,
      maxParallelism: 2'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true))

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

    check byId("stage-a").status == asSucceeded
    check byId("stage-b").status == asSucceeded
    check byId("consumer").status == asSucceeded
    check readFile(stageA).contains("a:two-create input")
    check readFile(stageB).contains("b:a:two-create input")
    check readFile(consumerOutput).contains("consumer:b:a:two-create input")

    # Ordering: stage-a → stage-b → consumer.
    check traceIndex("stage-b", "launched") >
      traceIndex("stage-a", "asSucceeded")
    check traceIndex("consumer", "launched") >
      traceIndex("stage-b", "asSucceeded")

  test "cache hit skips CAS verification only when outputs are present":
    let tempRoot = createTempDir("repro-cache-hit-present-output", "")
    defer: removeDir(tempRoot)

    let app = getAppFilename()
    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let inputPath = workRoot / "src" / "input.txt"
    let presentOutputPath = workRoot / "out" / "present.txt"
    let presentMarkerPath = workRoot / "out" / "present-marker.txt"
    let missingOutputPath = workRoot / "out" / "missing.txt"
    let missingMarkerPath = workRoot / "out" / "missing-marker.txt"
    fixtureWrite(inputPath, "cache input\n")

    let presentCacheAction = action("cache-present-output",
      [app, "fixture-action", "copy", "seed", inputPath, presentOutputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/present.txt"],
      cacheable = true, weakFingerprint = weak("cache-present-output"),
      commandStatsId = "cache-present-output")
    let presentRestoreOnlyAction = action("cache-present-output",
      [app, "fixture-action", "cache-should-not-run", presentMarkerPath,
        presentOutputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/present.txt"],
      cacheable = true, weakFingerprint = weak("cache-present-output"),
      commandStatsId = "cache-present-output")
    let missingCacheAction = action("cache-missing-output",
      [app, "fixture-action", "copy", "seed", inputPath, missingOutputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/missing.txt"],
      cacheable = true, weakFingerprint = weak("cache-missing-output"),
      commandStatsId = "cache-missing-output")
    let missingRestoreOnlyAction = action("cache-missing-output",
      [app, "fixture-action", "cache-should-not-run", missingMarkerPath,
        missingOutputPath],
      cwd = workRoot, inputs = [inputPath], outputs = ["out/missing.txt"],
      cacheable = true, weakFingerprint = weak("cache-missing-output"),
      commandStatsId = "cache-missing-output")

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

    let cold = runOne(presentCacheAction)
    check cold.status == asSucceeded
    check readFile(presentOutputPath) == "seed:cache input\n"
    var actionCache = openActionCache(cacheRoot / "action-cache")
    let cas = openLocalCas(cacheRoot / "cas")
    let seededLookup = actionCache.lookupActionResult(cas,
      weak("cache-present-output"), ffpTimestamp)
    check seededLookup.status == aclHit
    check actionCache.lookupActionResult(cas, weak("cache-present-output"),
      ffpChecksum).status == aclMissNoRecord
    let casObject = cas.blobPath(seededLookup.record.outputs[0].blob.digest)

    let presentContent = "local present output\n"
    writeFile(presentOutputPath, presentContent)
    let presentMtime = fromUnix(1_700_000_100)
    setLastModificationTime(presentOutputPath, presentMtime)
    removeIfExists(casObject)

    let warmPresent = runOne(presentRestoreOnlyAction)
    check warmPresent.status in {asCacheHit, asUpToDate}
    check warmPresent.cacheDecision == cdHit
    check not warmPresent.launched
    check not fileExists(presentMarkerPath)
    check readFile(presentOutputPath) == presentContent
    check getFileInfo(presentOutputPath).lastWriteTime == presentMtime

    fixtureWrite(inputPath, "changed cache input\n")
    let warmChangedInput = runOne(presentRestoreOnlyAction)
    check warmChangedInput.status == asSucceeded
    check warmChangedInput.cacheDecision == cdMiss
    check warmChangedInput.launched
    check fileExists(presentMarkerPath)
    check readFile(presentOutputPath) == "bad uncached output\n"

    let coldMissing = runOne(missingCacheAction)
    check coldMissing.status == asSucceeded
    check readFile(missingOutputPath) == "seed:changed cache input\n"
    removeFile(missingOutputPath)
    let warmMissing = runOne(missingRestoreOnlyAction)
    check warmMissing.status == asSucceeded
    check warmMissing.cacheDecision == cdMiss
    check warmMissing.launched
    check fileExists(missingMarkerPath)
    check readFile(missingOutputPath) == "bad uncached output\n"

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
    check buildResult.results[0].status in {asCacheHit, asUpToDate}
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

    check byId("cache-hit").status in {asCacheHit, asUpToDate}
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
    let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin" / addFileExt("runquota", ExeExt)
    let status = requireSuccess(q(runquotaBin) & " status", repoRoot)
    check status.contains("total_granted:")
    check status.contains("total_finished:")
    for item in buildResult.results:
      if item.launched:
        check item.runQuotaBackend.len > 0
