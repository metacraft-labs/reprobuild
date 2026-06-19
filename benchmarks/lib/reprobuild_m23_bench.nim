import std/[json, os, osproc, streams, strutils, tempfiles, times]

import repro_build_engine
import repro_core
import repro_hash
import repro_runquota

when defined(macosx):
  import repro_monitor_depfile

type
  ThresholdDirection = enum
    tdLessOrEqual
    tdGreaterOrEqual

  BenchMetric = object
    suite: string
    name: string
    unit: string
    value: float
    direction: string
    thresholdDirection: ThresholdDirection
    thresholdValue: float
    status: string
    note: string
    realComponents: seq[string]

  MonitorBenchResult = object
    metrics: seq[BenchMetric]
    advisory: JsonNode

proc elapsedMillis(start: float): float =
  (epochTime() - start) * 1000.0

proc ensureParent(path: string) =
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)

proc writeFixture(path, content: string) =
  ensureParent(path)
  writeFile(path, content)

proc fixtureMain(args: seq[string]) =
  if args.len < 2:
    quit 64
  case args[1]
  of "write":
    if args.len != 5:
      quit 64
    sleep(parseInt(args[2]))
    writeFixture(args[4], "write:" & args[3] & "\n")
  of "cache":
    if args.len != 5:
      quit 64
    sleep(parseInt(args[2]))
    writeFixture(args[4], "cache:" & readFile(args[3]))
  of "probe":
    if args.len != 5:
      quit 64
    let inputPath = args[2]
    let outDir = args[3]
    let outputPath = args[4]
    discard readFile(inputPath)
    discard fileExists(outDir / "missing-probe.txt")
    for kind, path in walkDir(outDir):
      discard kind
      discard path
    writeFixture(outputPath, "probe\n")
  else:
    quit 64

proc thresholdStatus(value: float; direction: ThresholdDirection;
                     threshold: float): string =
  case direction
  of tdLessOrEqual:
    if value <= threshold: "pass" else: "fail"
  of tdGreaterOrEqual:
    if value >= threshold: "pass" else: "fail"

proc addMetric(metrics: var seq[BenchMetric]; suite, name, unit: string;
               value: float; direction: ThresholdDirection;
               thresholdValue: float; note: string;
               realComponents: openArray[string]) =
  metrics.add BenchMetric(
    suite: suite,
    name: name,
    unit: unit,
    value: value,
    direction: if direction == tdLessOrEqual: "lower-is-better"
      else: "higher-is-better",
    thresholdDirection: direction,
    thresholdValue: thresholdValue,
    status: thresholdStatus(value, direction, thresholdValue),
    note: note,
    realComponents: @realComponents)

proc thresholdJson(metric: BenchMetric): JsonNode =
  let op = if metric.thresholdDirection == tdLessOrEqual: "<=" else: ">="
  %*{
    "operator": op,
    "value": metric.thresholdValue,
    "status": metric.status
  }

proc metricJson(metric: BenchMetric): JsonNode =
  %*{
    "suite": metric.suite,
    "name": metric.name,
    "unit": metric.unit,
    "value": metric.value,
    "direction": metric.direction,
    "threshold": thresholdJson(metric),
    "status": metric.status,
    "note": metric.note,
    "realComponents": metric.realComponents
  }

proc q(value: string): string =
  quoteShell(value)

proc commandLine(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add(" ")
    result.add(q(arg))

proc runProcess(args: openArray[string]; cwd = getCurrentDir()):
    tuple[code: int; output: string; millis: float] =
  let start = epochTime()
  let childArgs = if args.len > 1: @args[1 .. ^1] else: @[]
  let process = startProcess(args[0],
    args = childArgs,
    workingDir = cwd,
    options = {poUsePath, poStdErrToStdOut})
  if process.outputStream != nil:
    result.output = process.outputStream.readAll()
  result.code = process.waitForExit()
  result.millis = elapsedMillis(start)
  process.close()

proc requireProcess(args: openArray[string]; cwd = getCurrentDir()): float =
  let res = runProcess(args, cwd)
  if res.code != 0:
    raise newException(OSError,
      "command failed: " & commandLine(args) & "\n" & res.output)
  res.millis

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc startRunQuota(repoRoot: string): tuple[process: owned(Process);
                                           socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    raise newException(OSError, "missing runquotad; run scripts/run-m23-benchmark.sh")
  let socketPath = "/tmp/repro-m23-rq-" & $getCurrentProcessId() & ".sock"
  if pathExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "8000",
    "--memory-bytes", $((16'u64 * 1024'u64 * 1024'u64 * 1024'u64))
  ], options = {poUsePath, poStdErrToStdOut})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("m23.production.benchmark." & name)

proc successful(run: BuildRunResult; statuses: set[ActionStatus]): int =
  for item in run.results:
    if item.status in statuses:
      inc result

proc launched(run: BuildRunResult): int =
  for item in run.results:
    if item.launched:
      inc result

proc requireAll(run: BuildRunResult; statuses: set[ActionStatus]) =
  for item in run.results:
    if item.status notin statuses:
      raise newException(ValueError,
        item.id & " status=" & $item.status & " exit=" & $item.exitCode &
        " stderr=" & item.stderr)

proc noRuntimeDependencyPolicy(): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgNoRuntimeDependencies,
    completeness: decComplete)

proc benchmarkEngineConfig(cacheRoot, app: string;
                           rebuildMissingOutputsOnCacheHit = false):
    BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: app,
    maxParallelism: 8'u32,
    stdoutLimit: 16 * 1024,
    stderrLimit: 16 * 1024,
    rebuildMissingOutputsOnCacheHit: rebuildMissingOutputsOnCacheHit)

proc runBuildWorkload(app, workRoot, cacheRoot: string; count: int):
    tuple[result: BuildRunResult; millis: float] =
  createDir(workRoot)
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< count:
    actions.add action("wide-" & $i, [app, "fixture-action", "write", "2",
      $i, workRoot / "wide" / ($i & ".txt")], cwd = workRoot,
      outputs = ["wide/" & $i & ".txt"], cpuMilli = 100'u32,
      memoryBytes = 4'u64 * 1024'u64 * 1024'u64,
      commandStatsId = "m23-wide-" & $i,
      dependencyPolicy = noRuntimeDependencyPolicy())
  let start = epochTime()
  result.result = runBuild(graph(actions), benchmarkEngineConfig(cacheRoot, app))
  result.millis = elapsedMillis(start)
  requireAll(result.result, {asSucceeded})

proc runNoopWorkload(app, workRoot, cacheRoot: string; count: int):
    tuple[result: BuildRunResult; millis: float] =
  createDir(workRoot)
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< count:
    actions.add action("noop-" & $i, [app, "fixture-action", "write", "0",
      $i, workRoot / "noop" / ($i & ".txt")], cwd = workRoot,
      outputs = ["noop/" & $i & ".txt"], cpuMilli = 100'u32,
      memoryBytes = 4'u64 * 1024'u64 * 1024'u64,
      commandStatsId = "m23-noop-" & $i,
      dependencyPolicy = noRuntimeDependencyPolicy())
  discard runBuild(graph(actions), benchmarkEngineConfig(cacheRoot, app))
  let start = epochTime()
  result.result = runBuild(graph(actions), benchmarkEngineConfig(cacheRoot, app))
  result.millis = elapsedMillis(start)
  requireAll(result.result, {asUpToDate})

proc runCacheRestoreWorkload(app, workRoot, cacheRoot: string; count: int):
    tuple[result: BuildRunResult; millis: float] =
  createDir(workRoot)
  let inputPath = workRoot / "cache" / "input.txt"
  writeFixture(inputPath, "cache input\n")
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< count:
    actions.add action("cache-" & $i, [app, "fixture-action", "cache", "1",
      inputPath, workRoot / "cache" / ($i & ".txt")], cwd = workRoot,
      inputs = [inputPath],
      outputs = ["cache/" & $i & ".txt"],
      cacheable = true,
      weakFingerprint = weak("cache-" & $i),
      cpuMilli = 100'u32,
      memoryBytes = 4'u64 * 1024'u64 * 1024'u64,
      commandStatsId = "m23-cache-" & $i,
      dependencyPolicy = noRuntimeDependencyPolicy())
  discard runBuild(graph(actions), benchmarkEngineConfig(cacheRoot, app))
  for i in 0 ..< count:
    let outputPath = workRoot / "cache" / ($i & ".txt")
    if fileExists(outputPath):
      removeFile(outputPath)
  let start = epochTime()
  result.result = runBuild(graph(actions), benchmarkEngineConfig(cacheRoot,
    app, rebuildMissingOutputsOnCacheHit = false))
  result.millis = elapsedMillis(start)
  requireAll(result.result, {asCacheHit})

proc runMonitorWorkload(repoRoot, app, workRoot: string): MonitorBenchResult =
  when not defined(macosx):
    result.advisory = %*{
      "suite": "monitor-overhead",
      "status": "unsupported",
      "reason": "repro-fs-snoop hooks backend is currently macOS-only",
      "platform": hostOS,
      "metricsRecorded": false
    }
  else:
    let fsSnoop = repoRoot / "build" / "bin" / "repro-fs-snoop"
    let shim = repoRoot / "build" / "lib" / "librepro_monitor_shim.dylib"
    if not fileExists(fsSnoop) or not fileExists(shim):
      result.advisory = %*{
        "suite": "monitor-overhead",
        "status": "unsupported",
        "reason": "repro-fs-snoop or librepro_monitor_shim.dylib is missing",
        "metricsRecorded": false,
        "expectedFsSnoop": fsSnoop,
        "expectedShim": shim
      }
      return

    let inputPath = workRoot / "monitor" / "input.txt"
    let outDir = workRoot / "monitor" / "out"
    let baselineOutput = outDir / "baseline.txt"
    let monitoredOutput = outDir / "monitored.txt"
    let depfile = workRoot / "monitor" / "monitor.rdep"
    let eventStream = workRoot / "monitor" / "events.jsonl"
    createDir(outDir)
    writeFile(outDir / "seed.txt", "seed\n")
    writeFixture(inputPath, "monitor input\n")

    let baselineMs = requireProcess([app, "fixture-action", "probe", inputPath,
      outDir, baselineOutput], repoRoot)
    let monitoredMs = requireProcess([
      fsSnoop,
      "--depfile", depfile,
      "--events", "jsonl",
      "--event-stream", eventStream,
      "--",
      app, "fixture-action", "probe", inputPath, outDir, monitoredOutput
    ], repoRoot)

    let dep = readMonitorDepFile(depfile)
    if dep.records.len == 0:
      raise newException(ValueError, "monitor benchmark produced no RMDF records")
    let overheadPct =
      if baselineMs <= 0.001: 0.0 else: ((monitoredMs - baselineMs) /
          baselineMs) * 100.0
    result.metrics.addMetric("monitor-overhead", "fixture baseline wall time",
      "ms", baselineMs, tdLessOrEqual, 10_000.0,
      "direct generated fixture, no monitor",
      ["generated fixture process"])
    result.metrics.addMetric("monitor-overhead", "repro-fs-snoop wall time",
      "ms", monitoredMs, tdLessOrEqual, 60_000.0,
      "actual repro-fs-snoop executable with macOS shim",
      ["repro-fs-snoop", "repro_monitor_shim", "RMDF reader"])
    result.metrics.addMetric("monitor-overhead", "monitor overhead",
      "percent", max(overheadPct, 0.0), tdLessOrEqual, 1_000_000.0,
      "validation threshold only; tightened after stable baseline",
      ["repro-fs-snoop", "repro_monitor_shim", "RMDF reader"])
    result.metrics.addMetric("monitor-overhead", "monitor records captured",
      "count", float(dep.records.len), tdGreaterOrEqual, 1.0,
      "RMDF records decoded from real monitor depfile",
      ["repro-fs-snoop", "repro_monitor_shim", "RMDF reader"])
    result.advisory = %*{
      "suite": "monitor-overhead",
      "status": "measured",
      "backend": $dep.backendFamily,
      "recordCount": dep.records.len,
      "eventLossCount": dep.summary.eventLossCount,
      "depfile": depfile,
      "eventStream": eventStream
    }

proc sysctlValue(name: string): string =
  when defined(macosx):
    let res = execCmdEx("sysctl -n " & q(name))
    if res.exitCode == 0:
      return res.output.strip()
  ""

proc metadata(repoRoot: string; quick: bool; socket: string): JsonNode =
  let revision = execCmdEx("git rev-parse HEAD", workingDir = repoRoot)
  let nimVersion = execCmdEx("nim --version")
  %*{
    "benchmark": "reprobuild-core-mvp-performance",
    "schemaVersion": 1,
    "generatedAt": getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "quick": quick,
    "revision": if revision.exitCode == 0: revision.output.strip(
        ) else: "unknown",
    "toolchain": {
      "nim": if nimVersion.exitCode == 0: nimVersion.output.splitLines()[
          0] else: "unknown"
    },
    "platform": {
      "hostOS": hostOS,
      "hostCPU": hostCPU,
      "kernel": execCmdEx("uname -a").output.strip(),
      "cpuModel": sysctlValue("machdep.cpu.brand_string"),
      "logicalCpuCount": countProcessors(),
      "memoryBytes": sysctlValue("hw.memsize")
    },
    "storageClass": "local-workspace-filesystem",
    "filesystemCacheMode": "warm-or-host-default",
    "resourceCoordinationPolicy": {
      "daemon": "real sibling runquotad",
      "socket": socket,
      "cpuMilli": 8000,
      "memoryBytes": 16'u64 * 1024'u64 * 1024'u64 * 1024'u64
    },
    "fixtureIdentity": "generated-m23-actions",
    "mockPolicy": {
      "generatedWorkloads": true,
      "mockedMeasuredSubsystems": false
    }
  }

proc parseArgs(): tuple[outputPath: string; historyPath: string; quick: bool] =
  result.outputPath = getCurrentDir() / "bench-results" /
    "reprobuild-core-mvp-performance.json"
  result.historyPath = getCurrentDir() / "bench-results" / "history" /
    "reprobuild-core-mvp-performance.latest.json"
  for arg in commandLineParams():
    if arg == "--quick":
      result.quick = true
    elif arg.startsWith("--output="):
      result.outputPath = arg["--output=".len .. ^1]
    elif arg == "--output":
      raise newException(ValueError, "--output requires --output=<path>")
    elif arg.startsWith("--history="):
      result.historyPath = arg["--history=".len .. ^1]
    elif arg == "--history":
      raise newException(ValueError, "--history requires --history=<path>")
    else:
      raise newException(ValueError, "unknown benchmark argument: " & arg)

proc main() =
  let args = parseArgs()
  let repoRoot = getCurrentDir()
  let tempRoot = createTempDir("reprobuild-m23-bench", "")
  let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
  defer:
    putEnv("RUNQUOTA_SOCKET", previousSocket)
    removeDir(tempRoot)

  let app = getAppFilename()
  var daemon = startRunQuota(repoRoot)
  defer:
    daemon.process.terminate()
    discard daemon.process.waitForExit()
    daemon.process.close()
    if pathExists(daemon.socket):
      removeFile(daemon.socket)

  let workloadCount = if args.quick: 12 else: 48
  let cacheCount = if args.quick: 8 else: 32
  let workRoot = tempRoot / "work"
  let cacheRoot = tempRoot / ".repro-cache"
  createDir(workRoot)

  var metrics: seq[BenchMetric] = @[]

  let scheduler = runBuildWorkload(app, workRoot / "scheduler", cacheRoot,
    workloadCount)
  metrics.addMetric("build-engine-throughput", "generated action throughput",
    "actions/sec", float(workloadCount) / (scheduler.millis / 1000.0),
    tdGreaterOrEqual, 1.0,
    "real repro_build_engine scheduler with RunQuota helper-launched generated actions",
    ["repro_build_engine", "repro_runquota", "runquotad",
        "generated fixture actions"])
  metrics.addMetric("build-engine-throughput",
    "time to complete generated graph",
    "ms", scheduler.millis, tdLessOrEqual, 60_000.0,
    "validation threshold for M23 gate",
    ["repro_build_engine", "repro_runquota", "runquotad"])
  metrics.addMetric("runquota-process-execution",
    "lease-bound actions launched",
    "count", float(scheduler.result.launched()), tdGreaterOrEqual, float(
        workloadCount),
    "each launched action receives a real RunQuota lease through the helper path",
    ["repro_build_engine", "repro_runquota", "runquotad"])

  let noop = runNoopWorkload(app, workRoot / "noop", cacheRoot, cacheCount)
  metrics.addMetric("cache-consultation-latency", "warm no-op build wall time",
    "ms", noop.millis, tdLessOrEqual, 30_000.0,
    "outputs-present warm run through real build-engine dirty checking",
    ["repro_build_engine", "repro_local_store"])
  metrics.addMetric("cache-consultation-latency", "warm no-op actions",
    "count", float(noop.result.successful({asUpToDate})), tdGreaterOrEqual,
    float(cacheCount),
    "up-to-date actions verified without launching child processes",
    ["repro_build_engine", "repro_local_store"])

  let cache = runCacheRestoreWorkload(app, workRoot / "cache", cacheRoot,
    cacheCount)
  metrics.addMetric("cache-consultation-latency", "cache restore wall time",
    "ms", cache.millis, tdLessOrEqual, 30_000.0,
    "warm local action cache restore with outputs removed before lookup",
    ["repro_build_engine", "repro_local_store"])
  metrics.addMetric("cache-consultation-latency", "cache hit restore actions",
    "count", float(cache.result.successful({asCacheHit})), tdGreaterOrEqual,
    float(cacheCount),
    "all cacheable generated actions restored from the real local cache",
    ["repro_build_engine", "repro_local_store"])

  let monitor = runMonitorWorkload(repoRoot, app, workRoot)
  metrics.add(monitor.metrics)

  var metricNodes = newJArray()
  var failed: seq[string] = @[]
  for metric in metrics:
    metricNodes.add(metric.metricJson())
    if metric.status == "fail":
      failed.add(metric.suite & "/" & metric.name)

  let output = %*{
    "metadata": metadata(repoRoot, args.quick, daemon.socket),
    "status": if failed.len == 0: "pass" else: "fail",
    "thresholdFailures": failed,
    "metrics": metricNodes,
    "monitor": monitor.advisory,
    "artifacts": {
      "result": args.outputPath,
      "historyLatest": args.historyPath
    }
  }
  ensureParent(args.outputPath)
  ensureParent(args.historyPath)
  writeFile(args.outputPath, output.pretty())
  writeFile(args.historyPath, output.pretty())
  echo output.pretty()
  if failed.len > 0:
    quit 1

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])
  main()
