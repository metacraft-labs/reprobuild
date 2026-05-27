import std/[algorithm, json, options, os, osproc, sets, streams, strtabs,
    strutils, tables, times]

when defined(windows):
  import std/winlean

import repro_core
import repro_depfile
import repro_hash
import repro_local_store
import repro_monitor_depfile
import repro_runquota

type
  BuildEngineError* = object of CatchableError

  ActionStatus* = enum
    asPending
    asRunning
    asSucceeded
    asCacheHit
    asUpToDate
    asFailed
    asBlocked

  CacheDecision* = enum
    cdNotCacheable
    cdMiss
    cdHit
    cdHybridCutoff
    cdRejected

  BuildProgressKind* = enum
    bpkActionStarted
    bpkActionCompleted

  BuildActionKind* = enum
    bakProcess
    bakCopyFile
    bakEnsureDir
    bakWriteText
    bakStamp
    bakPreserveTree

  BuildAction* = object
    kind*: BuildActionKind
    id*: string
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    pool*: string
    poolUnits*: uint32
    cpuMilli*: uint32
    memoryBytes*: uint64
    commandStatsId*: string
    cacheable*: bool
    weakFingerprint*: ContentDigest
    actionCachePolicy*: FileFingerprintPolicy
    depfile*: string
    dynamicDepsFile*: string
    monitorDepfile*: string
    dependencyPolicy*: DependencyGatheringPolicy
    builtinText*: string
    builtinEntries*: seq[string]

  BuildPool* = object
    name*: string
    capacity*: uint32

  BuildGraph* = object
    actions*: seq[BuildAction]
    pools*: seq[BuildPool]

  BuildEngineConfig* = object
    # Project-local scratch root: holds `runquota-results/*.json`,
    # `monitor-depfiles/*.rdep`, `dependency-evidence/*.rbar`, and per-build
    # transient state. Cleaned by `repro clean`. Per-project by design.
    cacheRoot*: string
    # User-level shared action cache + CAS root. When empty, defaults to
    # `cacheRoot` for backwards compatibility (callers that haven't been
    # updated yet keep the old single-root behavior). When populated, the
    # engine opens `<actionCacheRoot>/cas` and
    # `<actionCacheRoot>/action-cache` instead of paths under `cacheRoot`.
    # Phase 1 of Provider-Compile-Tiering.md §"Cache Scope".
    actionCacheRoot*: string
    runQuotaCliPath*: string
    monitorCliPath*: string
    maxParallelism*: uint32
    stdoutLimit*: int
    stderrLimit*: int
    rebuildMissingOutputsOnCacheHit*: bool
    # When true, successful actions record input/output metadata for local
    # invalidation but do not synchronously hash and copy output payloads into
    # the local CAS. This is only appropriate for modes that rebuild missing
    # outputs instead of restoring them from cache.
    deferLocalOutputBlobs*: bool
    # When true, the engine spawns each `bakProcess` action directly via
    # `osproc.startProcess` instead of going through the RunQuota helper, and
    # synthesizes a result JSON in the same on-disk schema the helper would
    # produce. This bypasses ALL resource quotas, named-pool leases, and
    # backend selection.
    bypassRunQuota*: bool
    # When true, the engine probes RunQuota lazily just before the first process
    # launch and uses the bypass path only if the daemon is unavailable. No-op
    # builds therefore do not pay a daemon round trip.
    fallbackToRunQuotaBypass*: bool
    # When true, the engine keeps one RunQuota client session for the build and
    # launches child processes directly under leases instead of spawning a
    # `repro __repro-runquota-helper` process for every action.
    inlineRunQuota*: bool
    progressCallback*: BuildProgressCallback
    statsEnabled*: bool
    suppressTrace*: bool
    skipCacheHitEvidence*: bool

  PathSetEvidence* = object
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    depfileInputs*: seq[string]
    monitorReads*: seq[string]
    monitorWrites*: seq[string]
    monitorProbes*: seq[string]
    diagnostics*: seq[string]

  EvidenceCollection = object
    evidence: PathSetEvidence
    publishable: bool

  ActionResult* = object
    id*: string
    status*: ActionStatus
    exitCode*: int
    launched*: bool
    cacheDecision*: CacheDecision
    dependencyPolicyKind*: DependencyGatheringKind
    monitorDepfilePath*: string
    blockedBy*: string
    stdout*: string
    stderr*: string
    leaseId*: uint64
    runQuotaBackend*: string
    runQuotaSocket*: string
    evidence*: PathSetEvidence

  SchedulerTraceEvent* = object
    seq*: uint64
    actionId*: string
    event*: string
    detail*: string

  BuildStatsMetric* = object
    name*: string
    count*: int
    totalUs*: float

  BuildStats* = object
    metrics*: seq[BuildStatsMetric]

  BuildRunResult* = object
    results*: seq[ActionResult]
    trace*: seq[SchedulerTraceEvent]
    stats*: BuildStats
    traceEnabled: bool

  BuildProgressEvent* = object
    kind*: BuildProgressKind
    actionId*: string
    command*: string
    status*: ActionStatus
    cacheDecision*: CacheDecision
    launched*: bool
    total*: int
    completed*: int
    running*: int
    ready*: int

  BuildProgressCallback* = proc(event: BuildProgressEvent)

  RunningProcessKind = enum
    rpkHelperProcess
    rpkBypassProcess
    rpkInlineRunQuotaPending
    rpkInlineRunQuota
    rpkInlineRunQuotaFailed

  RunningAction = object
    id: string
    pool: string
    poolUnits: uint32
    action: BuildAction
    processKind: RunningProcessKind
    process: Process
    runQuotaProcess: ReproRunQuotaRunningProcess
    queuedRunQuotaProcess: ReproRunQuotaQueuedProcess
    inlineFailure: ActionResult
    resultPath: string
    when defined(windows):
      # Synchronize-only HANDLE duplicate of the child process, opened on
      # first wait-loop entry via OpenProcess(SYNCHRONIZE, pid). Used as a
      # WaitForMultipleObjects argument so process-exit detection is
      # event-driven (~microseconds) instead of the previous
      # peekExitCode+Sleep(1) spin loop (≥15 ms Windows timer quantum).
      # Closed when the action is reaped. Mirrors Ninja's IOCP-based wait
      # in references/ninja/src/subprocess-win32.cc.
      processWaitHandle: Handle

  DynamicGraphFragment = object
    deps: Table[string, seq[string]]
    outputs: Table[string, seq[string]]

const
  RecognizedPolicyKinds = {
    dgRecognizedFormat,
    dgRecognizedFormatValidatedByMonitor
  }
  ConverterPolicyKinds = {
    dgPostBuildConverter,
    dgPostBuildConverterValidatedByMonitor
  }
  MonitorPolicyKinds = {
    dgAutomaticMonitor,
    dgRecognizedFormatValidatedByMonitor,
    dgPostBuildConverterValidatedByMonitor
  }

proc defaultBuildEngineConfig*(cacheRoot: string;
                               actionCacheRoot: string = ""): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    actionCacheRoot: actionCacheRoot,
    runQuotaCliPath: "",
    monitorCliPath: "",
    maxParallelism: 8'u32,
    stdoutLimit: 1_048_576,
    stderrLimit: 1_048_576,
    rebuildMissingOutputsOnCacheHit: false,
    deferLocalOutputBlobs: false,
    bypassRunQuota: false,
    fallbackToRunQuotaBypass: false,
    inlineRunQuota: false,
    progressCallback: nil,
    statsEnabled: false,
    suppressTrace: false)

proc addMetric*(stats: var BuildStats; name: string; elapsedUs: float) =
  for metric in stats.metrics.mitems:
    if metric.name == name:
      inc metric.count
      metric.totalUs += elapsedUs
      return
  stats.metrics.add(BuildStatsMetric(name: name, count: 1, totalUs: elapsedUs))

proc mergeStats*(stats: var BuildStats; other: BuildStats) =
  for metric in other.metrics:
    if metric.count <= 0:
      continue
    var merged = false
    for existing in stats.metrics.mitems:
      if existing.name == metric.name:
        existing.count += metric.count
        existing.totalUs += metric.totalUs
        merged = true
        break
    if not merged:
      stats.metrics.add(metric)

proc textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFingerprintFromText*(text: string): ContentDigest =
  blake3DomainDigest(text.textBytes(), hdActionFingerprint)

proc action*(id: string; argv: openArray[string]; cwd = "";
             deps: openArray[string] = []; inputs: openArray[string] = [];
             outputs: openArray[string] = []; pool = ""; poolUnits = 1'u32;
             cpuMilli = 1000'u32; memoryBytes = 0'u64;
             commandStatsId = ""; cacheable = false;
             weakFingerprint = weakFingerprintFromText(id);
             actionCachePolicy = ffpTimestamp;
             depfile = ""; monitorDepfile = "";
             dynamicDepsFile = "";
             dependencyPolicy = declaredOnlyPolicy();
             env: openArray[string] = []): BuildAction =
  BuildAction(
    kind: bakProcess,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    argv: @argv,
    cwd: cwd,
    env: @env,
    pool: pool,
    poolUnits: poolUnits,
    cpuMilli: cpuMilli,
    memoryBytes: memoryBytes,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    weakFingerprint: weakFingerprint,
    actionCachePolicy: actionCachePolicy,
    depfile: depfile,
    dynamicDepsFile: dynamicDepsFile,
    monitorDepfile: monitorDepfile,
    dependencyPolicy: dependencyPolicy)

proc builtinAction*(kind: BuildActionKind; id: string; cwd = "";
                    deps: openArray[string] = [];
                    inputs: openArray[string] = [];
                    outputs: openArray[string] = [];
                    commandStatsId = ""; cacheable = true;
                    weakFingerprint = weakFingerprintFromText(id);
                    actionCachePolicy = ffpTimestamp;
                    text = ""; entries: openArray[string] = []): BuildAction =
  if kind == bakProcess:
    raise newException(BuildEngineError, "builtinAction requires a built-in action kind")
  BuildAction(
    kind: kind,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    cwd: cwd,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    weakFingerprint: weakFingerprint,
    actionCachePolicy: actionCachePolicy,
    dependencyPolicy: declaredOnlyPolicy(),
    builtinText: text,
    builtinEntries: @entries)

proc pool*(name: string; capacity: uint32): BuildPool =
  BuildPool(name: name, capacity: capacity)

proc graph*(actions: openArray[BuildAction];
            pools: openArray[BuildPool] = []): BuildGraph =
  BuildGraph(actions: @actions, pools: @pools)

proc trace(result: var BuildRunResult; actionId, event, detail: string) =
  if not result.traceEnabled:
    return
  result.trace.add SchedulerTraceEvent(
    seq: uint64(result.trace.len + 1),
    actionId: actionId,
    event: event,
    detail: detail)

proc raiseEngine(message: string) {.noreturn.} =
  raise newException(BuildEngineError, message)

proc validateGraph(g: BuildGraph) =
  var ids = initHashSet[string]()
  var byId = initTable[string, BuildAction]()
  var outputs = initHashSet[string]()
  for action in g.actions:
    if action.id.len == 0:
      raiseEngine("action id is required")
    if ids.contains(action.id):
      raiseEngine("duplicate action id: " & action.id)
    ids.incl(action.id)
    byId[action.id] = action
    if action.kind == bakProcess and action.argv.len == 0 and action.outputs.len == 0:
      raiseEngine("action has neither command nor outputs: " & action.id)
    for output in action.outputs:
      if outputs.contains(output):
        raiseEngine("duplicate declared output: " & output)
      outputs.incl(output)
  for action in g.actions:
    for dep in action.deps:
      if not ids.contains(dep):
        raiseEngine("unknown dependency " & dep & " for " & action.id)

  var state = initTable[string, int]()
  var stack: seq[string] = @[]

  proc cycleText(id: string): string =
    let start = stack.find(id)
    if start >= 0:
      var cycle = stack[start .. ^1]
      cycle.add(id)
      return cycle.join(" -> ")
    id

  proc visit(id: string) =
    case state.getOrDefault(id, 0)
    of 1:
      raiseEngine("dependency cycle: " & cycleText(id))
    of 2:
      return
    else:
      state[id] = 1
      stack.add(id)
      for dep in byId[id].deps:
        visit(dep)
      discard stack.pop()
      state[id] = 2

  for action in g.actions:
    visit(action.id)

  for p in g.pools:
    if p.name.len == 0:
      raiseEngine("pool name is required")
    if p.capacity == 0'u32:
      raiseEngine("pool capacity must be positive: " & p.name)

proc pathExists(path: string): bool =
  symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)) or
    dirExists(extendedPath(path))

proc outputPathReady(action: BuildAction; path: string): bool =
  if action.kind in {bakCopyFile, bakWriteText, bakStamp} and
      symlinkExists(extendedPath(path)):
    return false
  path.pathExists()

proc allOutputsExist(action: BuildAction): bool =
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path = if output.isAbsolute or action.cwd.len == 0: output else: action.cwd / output
    if not action.outputPathReady(path):
      return false
  true

proc addUnique(values: var seq[string]; value: string) =
  if value.len == 0:
    return
  if values.find(value) < 0:
    values.add(value)

proc normalizedDeclaredActionPath(action: BuildAction; path: string): string =
  result = path.replace('\\', '/').strip()
  while result.startsWith("./"):
    result = result.substr(2)
  while result.endsWith("/") and result.len > 1:
    result.setLen(result.len - 1)
  if result.len == 0:
    return

  if path.isAbsolute:
    result = os.normalizedPath(path).replace('\\', '/')
  elif action.cwd.len > 0:
    result = os.normalizedPath(action.cwd / path).replace('\\', '/')

proc inferDeclaredActionDeps(g: BuildGraph): BuildGraph =
  result = g
  var outputProducer = initTable[string, string]()
  for action in g.actions:
    for output in action.outputs:
      let normalized = normalizedDeclaredActionPath(action, output)
      if normalized.len > 0 and not outputProducer.hasKey(normalized):
        outputProducer[normalized] = action.id

  for i in 0 ..< result.actions.len:
    for input in result.actions[i].inputs:
      let normalized = normalizedDeclaredActionPath(result.actions[i], input)
      if normalized.len == 0 or not outputProducer.hasKey(normalized):
        continue
      let producerId = outputProducer[normalized]
      if producerId != result.actions[i].id:
        result.actions[i].deps.addUnique(producerId)

proc materialPath(root, path: string): string =
  if path.isAbsolute or root.len == 0:
    path
  else:
    root / path

proc readDynamicGraphFragment(path: string): DynamicGraphFragment =
  if path.len == 0 or not fileExists(extendedPath(path)):
    raiseEngine("dynamic dependency fragment missing: " & path)
  let lines = readFile(extendedPath(path)).splitLines()
  if lines.len == 0 or lines[0] != "repro-dynamic-graph-v1":
    raiseEngine(path & ": missing repro-dynamic-graph-v1 header")
  for lineNo in 1 ..< lines.len:
    let line = lines[lineNo]
    if line.len == 0:
      continue
    let fields = line.split('\t')
    if fields.len != 3:
      raiseEngine(path & ":" & $(lineNo + 1) &
        ": dynamic graph record must have 3 tab-separated fields")
    case fields[0]
    of "dep":
      result.deps.mgetOrPut(fields[1], @[]).addUnique(fields[2])
    of "output":
      result.outputs.mgetOrPut(fields[1], @[]).addUnique(fields[2])
    else:
      raiseEngine(path & ":" & $(lineNo + 1) &
        ": unsupported dynamic graph record kind: " & fields[0])

proc expectedPath(action: BuildAction; file: ExpectedDependencyFile): string =
  materialPath(action.cwd, file.path)

proc legacyDepfileReports(action: BuildAction):
    seq[RecognizedDependencyReportSpec] =
  if action.depfile.len > 0:
    result.add RecognizedDependencyReportSpec(
      formatName: DependencyFormatName(MakeDepfileFormatName),
      outputs: @[ExpectedDependencyFile(
        logicalName: "depfile",
        path: action.depfile,
        required: true)],
      completeness: decComplete)

proc reportSpecsForPolicy(action: BuildAction):
    seq[RecognizedDependencyReportSpec] =
  if action.dependencyPolicy.kind in RecognizedPolicyKinds:
    return action.dependencyPolicy.recognizedReports
  if action.dependencyPolicy.kind == dgDeclaredOnly:
    return action.legacyDepfileReports()
  @[]

proc converterSpecsForPolicy(action: BuildAction):
    seq[PostBuildDependencyConverterSpec] =
  if action.dependencyPolicy.kind in ConverterPolicyKinds:
    return action.dependencyPolicy.postBuildConverters
  @[]

proc monitorEvidenceRequired(action: BuildAction): bool =
  action.dependencyPolicy.kind in MonitorPolicyKinds or
    (action.dependencyPolicy.kind == dgDeclaredOnly and
      action.monitorDepfile.len > 0)

proc needsExecutionForPolicy(action: BuildAction): bool =
  action.dependencyPolicy.kind in MonitorPolicyKinds or
    action.kind == bakPreserveTree

proc addPathSet(evidence: var PathSetEvidence; pathSet: DependencyPathSet;
                recognized: bool) =
  if recognized:
    for input in pathSet.inputs:
      evidence.depfileInputs.addUnique(input)
  else:
    for input in pathSet.inputs:
      evidence.monitorReads.addUnique(input)
    for output in pathSet.outputs:
      evidence.monitorWrites.addUnique(output)
    for probe in pathSet.probes:
      evidence.monitorProbes.addUnique(probe)
  for diagnostic in pathSet.diagnostics:
    evidence.diagnostics.add(diagnostic)

proc collectConvertedEvidence(action: BuildAction;
                              specs: openArray[PostBuildDependencyConverterSpec];
                              evidence: var PathSetEvidence): bool

proc collectEvidence(action: BuildAction; strict: bool): EvidenceCollection =
  result.publishable = true
  result.evidence.declaredInputs = action.inputs
  result.evidence.declaredOutputs = action.outputs
  let reports = action.reportSpecsForPolicy()
  if action.dependencyPolicy.kind in RecognizedPolicyKinds and reports.len == 0:
    result.evidence.diagnostics.add(
      "dependency policy requires a recognized report but none is declared")
    result.publishable = false
  for report in reports:
    for output in report.outputs:
      let path = action.expectedPath(output)
      if output.required and not fileExists(extendedPath(path)):
        result.evidence.diagnostics.add("dependency report missing: " & path)
        result.publishable = false
        continue
      if not fileExists(extendedPath(path)):
        continue
      try:
        result.evidence.addPathSet(
          readRecognizedDependencyReport($report.formatName, path),
          recognized = true)
      except DependencyReportError as err:
        result.evidence.diagnostics.add("dependency report invalid: " & err.msg)
        result.publishable = false
  let converters = action.converterSpecsForPolicy()
  if action.dependencyPolicy.kind in ConverterPolicyKinds and converters.len == 0:
    result.evidence.diagnostics.add(
      "dependency policy requires a post-build converter but none is declared")
    result.publishable = false
  if not action.collectConvertedEvidence(converters, result.evidence):
    result.publishable = false
  if action.monitorEvidenceRequired():
    if action.monitorDepfile.len == 0:
      result.evidence.diagnostics.add(
        "dependency policy requires monitor evidence but no RMDF path is selected")
      result.publishable = false
      if strict and not result.publishable:
        discard
      return
    try:
      let dep = readMonitorDepFile(action.monitorDepfile)
      for record in dep.records:
        let path = materialPath(action.cwd, record.path)
        case record.kind
        of mrFileRead:
          result.evidence.monitorReads.addUnique(path)
        of mrFileOpen:
          case record.observationKind
          of moFileRead, moFileOpen:
            result.evidence.monitorReads.addUnique(path)
          of moFileWrite:
            result.evidence.monitorWrites.addUnique(path)
          else:
            discard
        of mrFileWrite:
          result.evidence.monitorWrites.addUnique(path)
        of mrPathProbe, mrDirectoryEnumerate:
          result.evidence.monitorProbes.addUnique(path)
        else:
          discard
      if dep.completeness != mcComplete:
        result.evidence.diagnostics.add("monitor depfile is incomplete")
        result.publishable = false
    except MonitorDepFileReaderError as err:
      result.evidence.diagnostics.add("monitor depfile read failed: " & err.msg)
      result.publishable = false
  if strict and not result.publishable:
    discard

proc evidenceInputPaths(evidence: PathSetEvidence): seq[string] =
  for input in evidence.declaredInputs:
    result.addUnique(input)
  for input in evidence.depfileInputs:
    result.addUnique(input)
  for input in evidence.monitorReads:
    result.addUnique(input)
  for probe in evidence.monitorProbes:
    result.addUnique(probe)

proc cacheInputPaths(action: BuildAction; evidence: PathSetEvidence): seq[string] =
  for input in evidence.evidenceInputPaths():
    result.addUnique(materialPath(action.cwd, input))

proc evidenceFromRecord(action: BuildAction; record: ActionResultRecord): PathSetEvidence =
  result.declaredInputs = action.inputs
  result.declaredOutputs = action.outputs
  var declaredInputPaths = initHashSet[string]()
  for input in action.inputs:
    declaredInputPaths.incl(materialPath(action.cwd, input))
  for input in record.inputs:
    if not declaredInputPaths.contains(input.path):
      if action.dependencyPolicy.kind in MonitorPolicyKinds:
        result.monitorReads.addUnique(input.path)
      else:
        result.depfileInputs.addUnique(input.path)

proc processCwd(action: BuildAction; process: ProcessSpec): string =
  let cwd = $process.cwd
  if cwd.len > 0:
    cwd
  else:
    action.cwd

proc envTable(env: openArray[EnvVar]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for item in env:
    result[item.name] = item.value

proc runConverter(action: BuildAction; converterSpec: PostBuildDependencyConverterSpec):
    tuple[ok: bool; diagnostic: string] =
  for input in converterSpec.inputs:
    let path = action.expectedPath(input)
    if input.required and not fileExists(extendedPath(path)):
      return (ok: false, diagnostic: "converter input missing: " & path)
  let process = converterSpec.converterProcess
  if process.executable.value.len == 0:
    return (ok: false, diagnostic: "converter executable is empty")
  let env = if process.env.len > 0: envTable(process.env) else: nil
  let child = startProcess($process.executable,
    args = process.args,
    env = env,
    workingDir = action.processCwd(process),
    options = {poUsePath, poStdErrToStdOut})
  let exitCode = child.waitForExit()
  var output = ""
  if child.outputStream != nil:
    output = child.outputStream.readAll()
  child.close()
  if exitCode != 0:
    var diagnostic = "converter failed with exit " & $exitCode
    if output.len > 0:
      diagnostic.add(": " & output.strip())
    return (ok: false, diagnostic: diagnostic)
  for output in converterSpec.outputs:
    let path = action.expectedPath(output)
    if output.required and not fileExists(extendedPath(path)):
      return (ok: false, diagnostic: "converter output missing: " & path)
  (ok: true, diagnostic: "")

proc runConverters(action: BuildAction;
                   specs: openArray[PostBuildDependencyConverterSpec]):
                   tuple[ok: bool; diagnostics: seq[string]] =
  result.ok = true
  for converterSpec in specs:
    let converterResult = action.runConverter(converterSpec)
    if not converterResult.ok:
      result.ok = false
      result.diagnostics.add("dependency converter: " & converterResult.diagnostic)

proc collectConvertedEvidence(action: BuildAction;
                              specs: openArray[PostBuildDependencyConverterSpec];
                              evidence: var PathSetEvidence): bool =
  result = true
  for converterSpec in specs:
    for output in converterSpec.outputs:
      let path = action.expectedPath(output)
      if output.required and not fileExists(extendedPath(path)):
        evidence.diagnostics.add("converted dependency report missing: " & path)
        result = false
        continue
      if not fileExists(extendedPath(path)):
        continue
      try:
        case converterSpec.outputKind
        of dcoReproPathSet:
          evidence.addPathSet(readReproPathSet(path), recognized = false)
        of dcoRecognizedFormat:
          evidence.addPathSet(
            readRecognizedDependencyReport($converterSpec.outputFormatName, path),
            recognized = true)
      except DependencyReportError as err:
        evidence.diagnostics.add("converted dependency report invalid: " & err.msg)
        result = false

proc defaultRunQuotaHelperPath(): string =
  let configured = getEnv("REPRO_RUNQUOTA_HELPER")
  if configured.len > 0:
    return configured
  raiseEngine("BuildEngineConfig.runQuotaCliPath or REPRO_RUNQUOTA_HELPER is required")

proc monitorCliPath(config: BuildEngineConfig): string =
  if config.monitorCliPath.len > 0:
    return config.monitorCliPath
  let configured = getEnv("REPRO_FS_SNOOP")
  if configured.len > 0:
    return configured
  # Windows: the fs-snoop binary is `repro-fs-snoop.exe` (ExeExt expansion).
  # Without the suffix the fileExists check below misses it. Use addFileExt
  # so the same logic works cross-platform.
  let appSibling = getAppDir() / addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(appSibling)):
    return appSibling
  let repoBuild = getCurrentDir() / "build" / "bin" /
    addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(repoBuild)):
    return repoBuild
  ""

proc sanitizeActionId(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "action"

proc actionIdFileSuffix(value: string): string =
  let hash = toHex(weakFingerprintFromText(value).bytes)
  hash[0 .. 15]

proc dependencyEvidencePath*(cacheRoot, actionId: string): string =
  cacheRoot / "dependency-evidence" /
    (sanitizeActionId(actionId) & "-" & actionIdFileSuffix(actionId) & ".rbar")

proc monitoredAction(action: BuildAction; config: BuildEngineConfig;
                     cacheRoot: string): tuple[action: BuildAction;
                                               diagnostic: string] =
  result.action = action
  if action.dependencyPolicy.kind notin MonitorPolicyKinds:
    return
  # Windows: automatic monitor dependency gathering now works on Windows via
  # the IAT-patching shim + CreateRemoteThread injection (see
  # libs/repro_monitor_shim/src/repro_monitor_shim/windows_interpose.nim and
  # libs/repro_monitor_depfile/src/repro_monitor_depfile/windows_injector.nim).
  # The same `repro-fs-snoop` driver is used as on macOS — only the underlying
  # injection mechanism differs.
  #
  # Windows escape hatch: REPRO_MONITOR_BYPASS=1 disables the injection for
  # the current build run. The Windows IAT-patching shim is stable for short
  # commands but currently deadlocks the Nim compiler on very large native
  # codetracer builds (ct.exe — thousands of generated .c files; nim spends
  # most of its time invoking gcc under the shim and the synchronization
  # cost compounds). With bypass on, the engine runs the action directly,
  # uses only declared/inputs evidence, and the build still completes
  # correctly for caching purposes — the cost is that monitor-derived
  # evidence is empty.
  when not (defined(macosx) or defined(linux) or defined(windows)):
    result.diagnostic =
      "automatic monitor dependency gathering is unsupported on this platform"
  else:
    when defined(windows):
      if getEnv("REPRO_MONITOR_BYPASS") == "1":
        # Windows: downgrade the action to declared-only when the bypass is
        # active. Without this, the engine's evidence validator later
        # complains that monitor evidence is required but no depfile is set,
        # and the action is marked asFailed even though it ran successfully.
        # Declared inputs + outputs are enough for caching correctness; we
        # just lose the auto-discovered read/write set.
        result.action.dependencyPolicy = declaredOnlyPolicy()
        return
    let monitorCli = monitorCliPath(config)
    if monitorCli.len == 0:
      result.diagnostic =
        "automatic monitor dependency gathering requires repro-fs-snoop"
      return
    let depfile = cacheRoot / "monitor-depfiles" /
      (sanitizeActionId(action.id) & ".rdep")
    result.action.monitorDepfile = depfile
    result.action.argv = @[monitorCli, "--depfile", depfile, "--"] & action.argv

proc envTableFromArgvStyle(env: openArray[string]): StringTableRef =
  ## Convert the ``"NAME=VALUE"`` argv-style env (carried on BuildAction.env)
  ## into the StringTableRef shape that ``osproc.startProcess`` expects.
  ## Returns ``nil`` when no overrides are provided so the child inherits the
  ## parent process environment.
  if env.len == 0:
    return nil
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

when defined(windows):
  proc ensureRunningProcessHandle(item: var RunningAction): Handle =
    ## Lazily open a SYNCHRONIZE-only HANDLE for the running child process,
    ## suitable for WaitForMultipleObjects. Cached on the RunningAction so
    ## each process is opened once and reused across wait iterations.
    if item.processWaitHandle != 0:
      return item.processWaitHandle
    let pid = processID(item.process)
    if pid <= 0:
      return 0
    let handle = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
    item.processWaitHandle = handle
    handle

  proc closeRunningProcessHandle(item: var RunningAction) =
    if item.processWaitHandle != 0:
      discard closeHandle(item.processWaitHandle)
      item.processWaitHandle = 0

  proc waitAnyProcessExitWindows(running: var seq[RunningAction];
                                 timeoutMs: int): int =
    ## Returns the index in `running` of the first process whose handle is
    ## signaled within `timeoutMs`, or -1 on timeout. Mirrors Ninja's
    ## event-driven wait (references/ninja/src/subprocess-win32.cc:260):
    ## one syscall, the OS wakes us when ANY child exits, no polling.
    ## Inline-runquota / queued / inline-failed running entries are not
    ## handle-based and are skipped here — the caller still checks them
    ## via pollCompletion / inlineFailure after this returns (the timeout
    ## gives the caller a cadence for those checks).
    var handles: WOHandleArray
    var indices: array[MAXIMUM_WAIT_OBJECTS, int]
    var count = 0
    for i in 0 ..< running.len:
      if count >= MAXIMUM_WAIT_OBJECTS:
        break
      case running[i].processKind
      of rpkHelperProcess, rpkBypassProcess:
        let h = ensureRunningProcessHandle(running[i])
        if h != 0:
          handles[count] = h
          indices[count] = i
          inc count
      else:
        discard
    if count == 0:
      return -1
    let ret = waitForMultipleObjects(DWORD(count), addr handles,
                                     WINBOOL(0), DWORD(timeoutMs))
    const WAIT_OBJECT_0_DWORD = DWORD(0)
    const WAIT_TIMEOUT_DWORD = DWORD(0x102)
    const WAIT_FAILED_DWORD = cast[DWORD](0xFFFFFFFF'u32)
    if ret == WAIT_TIMEOUT_DWORD or ret == WAIT_FAILED_DWORD:
      return -1
    let signaled = int(ret - WAIT_OBJECT_0_DWORD)
    if signaled < 0 or signaled >= count:
      return -1
    indices[signaled]

proc startBypassRunQuotaProcess(action: BuildAction): Process =
  ## Path-mode escape hatch: spawn the action's argv directly via osproc,
  ## bypassing the RunQuota helper. Only used when
  ## ``BuildEngineConfig.bypassRunQuota`` is true (currently set only on
  ## Windows under ``--tool-provisioning=path``). All resource accounting,
  ## named-pool leases, and quota enforcement are skipped — the engine still
  ## honours its own ``poolRunning`` capacity tracking so action graphs that
  ## declare pools stay sequenced, but no daemon-side enforcement happens.
  if action.argv.len == 0:
    raiseEngine("bypassRunQuota: action has empty argv: " & action.id)
  let env = envTableFromArgvStyle(action.env)
  let cwd = if action.cwd.len > 0: action.cwd else: getCurrentDir()
  # Use inherited stdio instead of pipe-based capture. Path-mode bypass is a
  # RunQuota escape hatch, and waiting for direct children before draining their
  # pipe can deadlock on verbose compiler probes that fill the kernel buffer.
  # The caller (`repro build`) still sees the output through its own stdio.
  result = startProcess(action.argv[0],
    args = action.argv[1 .. ^1],
    env = env,
    workingDir = cwd,
    options = {poUsePath, poParentStreams})

proc startRunQuotaProcess(action: BuildAction; config: BuildEngineConfig;
                          resultPath: string; bypassRunQuota: bool): Process =
  if bypassRunQuota:
    return startBypassRunQuotaProcess(action)
  let rq = ReproResourceRequest(
    label: action.id,
    commandStatsId: action.commandStatsId,
    cpuMilli: action.cpuMilli,
    memoryBytes: action.memoryBytes,
    namedPool: action.pool,
    namedPoolUnits: action.poolUnits)
  let command = ReproCommandSpec(
    argv: action.argv,
    cwd: action.cwd,
    env: action.env,
    stdoutLimit: config.stdoutLimit,
    stderrLimit: config.stderrLimit)
  let helper = if config.runQuotaCliPath.len > 0: config.runQuotaCliPath
    else: defaultRunQuotaHelperPath()
  startProcess(helper, args = helperCliArgs(rq, command, resultPath),
    options = {poUsePath, poStdErrToStdOut})

proc runQuotaRequest(action: BuildAction): ReproResourceRequest =
  ReproResourceRequest(
    label: action.id,
    commandStatsId: action.commandStatsId,
    cpuMilli: action.cpuMilli,
    memoryBytes: action.memoryBytes,
    namedPool: action.pool,
    namedPoolUnits: action.poolUnits)

proc runQuotaCommand(action: BuildAction; config: BuildEngineConfig):
    ReproCommandSpec =
  ReproCommandSpec(
    argv: action.argv,
    cwd: action.cwd,
    env: action.env,
    stdoutLimit: config.stdoutLimit,
    stderrLimit: config.stderrLimit)

proc writeBypassResultJson(resultPath: string; exitCode: int;
                           combinedOutput: string) =
  ## Synthesize the same result-JSON schema the RunQuota helper writes, so the
  ## downstream parser in ``finishRunQuotaProcess`` can consume it unchanged.
  ## Keep field names and types byte-for-byte aligned with
  ## ``repro_runquota.executionJson``.
  let payload = %*{
    "runner_error": "",
    "lease_id": 0,
    "exit_code": exitCode,
    "exited": true,
    "signaled": false,
    "signal": 0,
    "stdout": combinedOutput,
    "stderr": "",
    "backend_name": "runquota-bypass",
    "runquota_socket": "",
    "lease_finished_sent": false,
    "lease_released": false
  }
  createDir(extendedPath(parentDir(resultPath)))
  writeFile(extendedPath(resultPath), $payload)

proc finishBypassRunQuotaProcess(id: string; process: Process;
                                 resultPath: string) =
  ## Path-mode escape hatch: drain the directly-spawned process and synthesize
  ## the result JSON the standard parser expects. Returns nothing — the caller
  ## proceeds to the same ``parseFile(resultPath)`` codepath the RunQuota
  ## helper would have written.
  #
  var combinedOutput = ""
  let exitCode = process.waitForExit()
  writeBypassResultJson(resultPath, exitCode, combinedOutput)

proc finishRunQuotaProcess(id: string; process: Process; resultPath: string;
                           bypassRunQuota: bool): ActionResult =
  let backendLabel =
    if bypassRunQuota: "runquota-bypass" else: "runquota-helper"
  result = ActionResult(id: id, launched: true, runQuotaBackend: backendLabel)
  if bypassRunQuota:
    finishBypassRunQuotaProcess(id, process, resultPath)
  let helperExit =
    if bypassRunQuota: 0
    else: process.waitForExit()
  var helperOutput = ""
  if not bypassRunQuota and process.outputStream != nil:
    helperOutput = process.outputStream.readAll()
  if not fileExists(extendedPath(resultPath)):
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper did not write result"
    if helperOutput.len > 0:
      result.stderr.add(": " & helperOutput)
    return
  try:
    # extendedPath() is required: the result file's path can exceed Windows
    # MAX_PATH (260 chars) once nested under <bench-root>/CMakeFiles/
    # CMakeScratch/TryCompile-<hash>/CMakeFiles/reprobuild/worktrees/<…>/
    # build/reprobuild/build-engine-cache/runquota-results/1.json. Without
    # the \\?\ prefix, parseFile() raises "cannot read from file" even when
    # the prior fileExists() check (which DOES use extendedPath) saw it.
    let node = parseFile(extendedPath(resultPath))
    result.leaseId = node{"lease_id"}.getBiggestInt(0).uint64
    result.exitCode = node{"exit_code"}.getInt(1)
    result.stdout = node{"stdout"}.getStr("")
    result.stderr = node{"stderr"}.getStr("")
    let runnerError = node{"runner_error"}.getStr("")
    if runnerError.len > 0:
      if result.stderr.len > 0:
        result.stderr.add("\n")
      result.stderr.add(runnerError)
    if helperOutput.len > 0:
      if result.stderr.len > 0:
        result.stderr.add("\n")
      result.stderr.add(helperOutput)
    result.runQuotaBackend = node{"backend_name"}.getStr("runquota-helper")
    result.runQuotaSocket = node{"runquota_socket"}.getStr("")
    result.status =
      if helperExit == 0 and runnerError.len == 0 and result.exitCode == 0:
        asSucceeded
      else:
        asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper result parse failed: " & err.msg

proc finishInlineRunQuotaProcess(id: string;
                                 process: var ReproRunQuotaRunningProcess):
    ActionResult =
  result = ActionResult(id: id, launched: true)
  try:
    let execution = process.finishCompleted()
    result.leaseId = execution.leaseId
    result.exitCode = execution.exitCode
    result.stdout = execution.stdout
    result.stderr = execution.stderr
    result.runQuotaBackend = execution.backendName
    result.runQuotaSocket = getEnv("RUNQUOTA_SOCKET", "")
    result.status =
      if execution.exitCode == 0:
        asSucceeded
      else:
        asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = "runquota inline process failed: " & err.msg
    result.runQuotaBackend = "runquota-inline"
    result.runQuotaSocket = getEnv("RUNQUOTA_SOCKET", "")

proc inlineRunQuotaFailureResult(id, message: string): ActionResult =
  ActionResult(
    id: id,
    status: asFailed,
    exitCode: 1,
    launched: true,
    stderr: message,
    runQuotaBackend: "runquota-inline",
    runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))

proc builtinPath(action: BuildAction; path: string): string =
  materialPath(action.cwd, path)

proc builtinRoots(text: string): tuple[sourceRoot: string; outputRoot: string] =
  let lines = text.splitLines()
  if lines.len < 2:
    raiseEngine("preserveTree action requires sourceRoot and outputRoot")
  (sourceRoot: lines[0], outputRoot: lines[1])

proc preserveTreeManifestPath(action: BuildAction): string =
  for output in action.outputs:
    let normalized = output.replace('\\', '/')
    if normalized.startsWith(".repro/preserve-tree/") and
        normalized.endsWith(".manifest"):
      return action.builtinPath(output)
  action.builtinPath(".repro" / "preserve-tree" /
    (sanitizeActionId(action.id) & ".manifest"))

proc readManifestEntries(path: string): seq[string] =
  if not fileExists(extendedPath(path)):
    return @[]
  for line in readFile(extendedPath(path)).splitLines:
    let entry = line.strip().replace('\\', '/')
    if entry.len > 0:
      result.add(entry)

proc writeManifestEntries(path: string; entries: openArray[string]) =
  createDir(extendedPath(path.splitPath.head))
  var text = ""
  for entry in entries:
    text.add(entry)
    text.add("\n")
  writeFile(extendedPath(path), text)

proc prepareBuiltinFileOutput(path: string) =
  ## Built-in file writes must replace output symlinks instead of writing
  ## through them into their targets.
  let expanded = extendedPath(path)
  if symlinkExists(expanded):
    removeFile(expanded)

proc removeExistingPath(path: string) =
  let expanded = extendedPath(path)
  if symlinkExists(expanded) or fileExists(expanded):
    removeFile(expanded)
  elif dirExists(expanded):
    removeDir(expanded)

proc pathWithinRoot(path, root: string): tuple[inside: bool; relative: string] =
  let relative = relativePath(os.normalizedPath(path), os.normalizedPath(root))
  if relative == ".":
    return (inside: true, relative: "")
  if relative.isAbsolute or relative == ".." or relative.startsWith("../") or
      relative.startsWith("..\\"):
    return (inside: false, relative: "")
  (inside: true, relative: relative)

proc copiedSymlinkTarget(sourceRoot, outputRoot, sourceLink, destinationLink,
    target: string): string =
  let resolvedTarget =
    if target.isAbsolute: os.normalizedPath(target)
    else: os.normalizedPath(sourceLink.splitPath.head / target)
  let withinSource = pathWithinRoot(resolvedTarget, sourceRoot)
  let mappedTarget =
    if withinSource.inside: outputRoot / withinSource.relative
    else: resolvedTarget
  relativePath(mappedTarget, destinationLink.splitPath.head)

type
  PreserveTreeEntryKind = enum
    ptekFile
    ptekSymlink

  PreserveTreeEntry = object
    kind: PreserveTreeEntryKind
    relative: string
    target: string

proc parsePreserveTreeEntry(entry: string): PreserveTreeEntry =
  let normalized = entry.replace('\\', '/')
  let fields = normalized.split('\t')
  if fields.len > 0 and fields[0] == "file":
    if fields.len != 2 or fields[1].len == 0:
      raiseEngine("invalid preserveTree file entry: " & entry)
    return PreserveTreeEntry(kind: ptekFile, relative: fields[1])
  if fields.len > 0 and fields[0] == "symlink":
    if fields.len != 3 or fields[1].len == 0:
      raiseEngine("invalid preserveTree symlink entry: " & entry)
    return PreserveTreeEntry(
      kind: ptekSymlink,
      relative: fields[1],
      target: fields[2])
  PreserveTreeEntry(kind: ptekFile, relative: normalized)

proc executeBuiltinAction(action: BuildAction): ActionResult =
  result = ActionResult(
    id: action.id,
    launched: true,
    runQuotaBackend: "builtin",
    dependencyPolicyKind: action.dependencyPolicy.kind)
  try:
    case action.kind
    of bakCopyFile:
      if action.inputs.len != 1 or action.outputs.len != 1:
        raiseEngine("copyFile action requires exactly one input and one output: " &
          action.id)
      let source = action.builtinPath(action.inputs[0])
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      copyFile(extendedPath(source), extendedPath(destination))
    of bakEnsureDir:
      if action.outputs.len != 1:
        raiseEngine("ensureDir action requires exactly one output: " & action.id)
      createDir(extendedPath(action.builtinPath(action.outputs[0])))
    of bakWriteText:
      if action.outputs.len != 1:
        raiseEngine("writeText action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      writeFile(extendedPath(destination), action.builtinText)
    of bakStamp:
      if action.outputs.len != 1:
        raiseEngine("stamp action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      var text = action.builtinText
      if text.len > 0 and not text.endsWith("\n"):
        text.add("\n")
      for entry in action.builtinEntries:
        text.add(entry)
        text.add("\n")
      writeFile(extendedPath(destination), text)
    of bakPreserveTree:
      let roots = builtinRoots(action.builtinText)
      let sourceRoot = action.builtinPath(roots.sourceRoot)
      let outputRoot = action.builtinPath(roots.outputRoot)
      createDir(extendedPath(outputRoot))
      var expected = initHashSet[string]()
      var currentEntries: seq[string] = @[]
      for rawEntry in action.builtinEntries:
        let entry = parsePreserveTreeEntry(rawEntry)
        let relative = entry.relative
        if relative.len == 0:
          continue
        expected.incl(relative)
        currentEntries.add(relative)
        let source = sourceRoot / relative
        let destination = outputRoot / relative
        createDir(extendedPath(destination.splitPath.head))
        case entry.kind
        of ptekFile:
          if not fileExists(extendedPath(source)):
            raiseEngine("preserveTree source file disappeared before execution: " &
              source)
          prepareBuiltinFileOutput(destination)
          copyFile(extendedPath(source), extendedPath(destination))
        of ptekSymlink:
          if not symlinkExists(extendedPath(source)):
            raiseEngine("preserveTree source symlink disappeared before execution: " &
              source)
          let currentTarget = copiedSymlinkTarget(sourceRoot, outputRoot, source,
            destination, entry.target)
          removeExistingPath(destination)
          createSymlink(currentTarget, extendedPath(destination))
      let manifestPath = preserveTreeManifestPath(action)
      for previous in readManifestEntries(manifestPath):
        if not expected.contains(previous):
          let stale = outputRoot / previous
          if symlinkExists(extendedPath(stale)) or fileExists(extendedPath(stale)):
            removeFile(extendedPath(stale))
      currentEntries.sort(system.cmp[string])
      writeManifestEntries(manifestPath, currentEntries)
    of bakProcess:
      raiseEngine("process action cannot be executed as a built-in: " & action.id)
    result.status = asSucceeded
    result.exitCode = 0
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = err.msg

proc resultIndex(ids: Table[string, int]; id: string): int =
  if not ids.hasKey(id):
    raiseEngine("internal missing result id: " & id)
  ids[id]

proc runBuild*(g: BuildGraph; config: BuildEngineConfig): BuildRunResult =
  var stats: BuildStats
  proc statStart(): float =
    if config.statsEnabled:
      epochTime()
    else:
      0.0
  proc finishStat(name: string; started: float) =
    if config.statsEnabled:
      stats.addMetric(name, (epochTime() - started) * 1_000_000.0)

  let totalStart = statStart()
  let inferStart = statStart()
  let buildGraph = inferDeclaredActionDeps(g)
  finishStat("repro graph infer deps", inferStart)
  var runResult: BuildRunResult
  runResult.traceEnabled = not config.suppressTrace
  let validateStart = statStart()
  validateGraph(buildGraph)
  finishStat("repro graph validate", validateStart)

  let maxParallel = if config.maxParallelism == 0'u32: 1'u32 else: config.maxParallelism
  let initStart = statStart()
  let cacheRoot = if config.cacheRoot.len == 0:
      getCurrentDir() / ".repro" / "build-engine-cache"
    else:
      config.cacheRoot
  # The CAS and action-cache live under the shared user-level
  # `actionCacheRoot` when set (Provider-Compile-Tiering.md §"Cache Scope"
  # Phase 1). When empty (legacy / unmigrated callers, tests), they fall
  # back to `cacheRoot` so the single-root layout still works.
  let sharedRoot = if config.actionCacheRoot.len > 0:
      config.actionCacheRoot
    else:
      cacheRoot
  let casOpenStart = statStart()
  let cas = openLocalCas(sharedRoot / "cas")
  finishStat("repro cas open", casOpenStart)
  let actionCacheOpenStart = statStart()
  var cache = openActionCache(sharedRoot / "action-cache")
  finishStat("repro action cache open", actionCacheOpenStart)
  defer:
    cache.flushHotIndex()

  proc cacheHitEvidence(action: BuildAction;
                        record: ActionResultRecord): PathSetEvidence =
    if config.skipCacheHitEvidence:
      PathSetEvidence()
    else:
      evidenceFromRecord(action, record)

  proc tryFastNoopCacheHits(): Option[BuildRunResult] =
    if not config.rebuildMissingOutputsOnCacheHit:
      return none(BuildRunResult)
    if config.progressCallback != nil:
      return none(BuildRunResult)
    var fastResult: BuildRunResult
    fastResult.traceEnabled = not config.suppressTrace
    var metadataCache = initFileMetadataCache()
    if config.skipCacheHitEvidence:
      var hotProbes: seq[HotMetadataProbe] = @[]
      for action in buildGraph.actions:
        if (not action.cacheable) or action.dynamicDepsFile.len > 0:
          return none(BuildRunResult)
        let outputStatStart = statStart()
        let outputsPresent = action.allOutputsExist()
        finishStat("repro output stat", outputStatStart)
        if not outputsPresent:
          return none(BuildRunResult)
        hotProbes.add(HotMetadataProbe(
          weakFingerprint: action.weakFingerprint,
          policy: action.actionCachePolicy))
      let lookupStart = statStart()
      let navigatorStart = statStart()
      let scan = cache.scanHotIndexMetadataInputsUnchanged(hotProbes,
        addr metadataCache)
      finishStat("repro hot index navigator scan", navigatorStart)
      finishStat("repro cache lookup", lookupStart)
      case scan.status
      of hmssHit:
        let resultMaterializeStart = statStart()
        for action in buildGraph.actions:
          fastResult.results.add(ActionResult(
            id: action.id,
            status: asUpToDate,
            cacheDecision: cdHit,
            dependencyPolicyKind: action.dependencyPolicy.kind))
        finishStat("repro cache hit result materialize", resultMaterializeStart)
        fastResult.stats = stats
        return some(fastResult)
      of hmssMissingRecord, hmssInputChanged:
        return none(BuildRunResult)
      of hmssUnavailable, hmssCorrupt:
        discard

    var hotRecords: seq[ActionResultRecord] = @[]
    for action in buildGraph.actions:
      if (not action.cacheable) or action.dynamicDepsFile.len > 0:
        return none(BuildRunResult)
      let outputStatStart = statStart()
      let outputsPresent = action.allOutputsExist()
      finishStat("repro output stat", outputStatStart)
      if not outputsPresent:
        return none(BuildRunResult)
      let hotRecordLookupStart = statStart()
      let hotRecord = cache.lookupHotMetadataRecord(action.weakFingerprint,
        action.actionCachePolicy)
      finishStat("repro hot record lookup", hotRecordLookupStart)
      if hotRecord.isNone:
        return none(BuildRunResult)
      if not config.skipCacheHitEvidence:
        hotRecords.add(hotRecord.get())
    let lookupStart = statStart()
    let inputScanStart = statStart()
    let inputsUnchanged =
      if buildGraph.actions.len == cache.hotMetadataRecordCount():
        cache.hotMetadataInputsUnchanged(addr metadataCache)
      else:
        if config.skipCacheHitEvidence:
          var selectedHotRecords: seq[ActionResultRecord] = @[]
          for action in buildGraph.actions:
            selectedHotRecords.add(cache.lookupHotMetadataRecord(
              action.weakFingerprint, action.actionCachePolicy).get())
          hotMetadataRecordInputsUnchanged(selectedHotRecords, addr metadataCache)
        else:
          hotMetadataRecordInputsUnchanged(hotRecords, addr metadataCache)
    finishStat("repro hot input scan", inputScanStart)
    finishStat("repro cache lookup", lookupStart)
    if not inputsUnchanged:
      return none(BuildRunResult)
    let resultMaterializeStart = statStart()
    for i, action in buildGraph.actions:
      let record =
        if config.skipCacheHitEvidence: ActionResultRecord()
        else: hotRecords[i]
      fastResult.results.add(ActionResult(
        id: action.id,
        status: asUpToDate,
        cacheDecision: cdHit,
        dependencyPolicyKind: action.dependencyPolicy.kind,
        evidence: cacheHitEvidence(action, record)))
    finishStat("repro cache hit result materialize", resultMaterializeStart)
    fastResult.stats = stats
    some(fastResult)

  let fastNoopStart = statStart()
  let fastNoop = tryFastNoopCacheHits()
  finishStat("repro fast noop scan", fastNoopStart)
  if fastNoop.isSome:
    runResult = fastNoop.get()
    finishStat("repro scheduler total", totalStart)
    runResult.stats = stats
    return runResult

  var idToIndex = initTable[string, int]()
  var dependents = initTable[string, seq[string]]()
  var remaining = initTable[string, int]()
  var statuses = initTable[string, ActionStatus]()
  var poolCapacity = initTable[string, uint32]()
  var poolRunning = initTable[string, uint32]()
  var ready: seq[string] = @[]
  var actionsById = initTable[string, BuildAction]()
  var launchedSucceeded = initHashSet[string]()
  var dynamicDepsLoaded = initHashSet[string]()
  var fileMetadataCache = initFileMetadataCache()
  var inlineRunQuotaSession: ReproRunQuotaSession
  var inlineRunQuotaSessionOpen = false

  proc invalidateCachedPath(path: string) =
    fileMetadataCache.invalidate(path)

  proc invalidateCachedOutputs(action: BuildAction) =
    for output in action.outputs:
      invalidateCachedPath(materialPath(action.cwd, output))

  proc invalidateCachedWrites(action: BuildAction; evidence: PathSetEvidence) =
    for output in evidence.monitorWrites:
      invalidateCachedPath(materialPath(action.cwd, output))

  poolCapacity[""] = maxParallel
  for p in buildGraph.pools:
    poolCapacity[p.name] = p.capacity
  for action in buildGraph.actions:
    let cap = poolCapacity.getOrDefault(action.pool, maxParallel)
    let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
    if units > cap:
      raiseEngine("action " & action.id & " requests " & $units &
        " units from pool " & action.pool & " with capacity " & $cap)
  for i, action in buildGraph.actions:
    idToIndex[action.id] = i
    actionsById[action.id] = action
    remaining[action.id] = action.deps.len
    statuses[action.id] = asPending
    if action.deps.len == 0:
      ready.add(action.id)
    for dep in action.deps:
      dependents.mgetOrPut(dep, @[]).add(action.id)
    runResult.results.add(ActionResult(
      id: action.id,
      status: asPending,
      dependencyPolicyKind: action.dependencyPolicy.kind,
      cacheDecision: if action.cacheable: cdMiss else: cdNotCacheable))
  finishStat("repro scheduler initialize", initStart)

  proc readyCmp(a, b: string): int =
    cmp(idToIndex[a], idToIndex[b])

  var running: seq[RunningAction] = @[]
  var runQuotaDaemonReachable: Option[bool]

  proc launchBypassesRunQuota(): bool =
    if config.bypassRunQuota:
      return true
    if not config.fallbackToRunQuotaBypass:
      return false
    if runQuotaDaemonReachable.isNone:
      let probeStart = statStart()
      runQuotaDaemonReachable = some(isRunQuotaDaemonReachable())
      finishStat("repro runquota probe", probeStart)
    not runQuotaDaemonReachable.get()

  proc tryEnsureInlineRunQuotaSession(): bool =
    if inlineRunQuotaSessionOpen:
      return true
    let sessionStart = statStart()
    try:
      inlineRunQuotaSession = openRunQuotaSession()
      inlineRunQuotaSessionOpen = true
      runQuotaDaemonReachable = some(true)
      result = true
    except CatchableError as err:
      runQuotaDaemonReachable = some(false)
      if config.fallbackToRunQuotaBypass:
        result = false
      else:
        raise err
    finally:
      finishStat("repro runquota session open", sessionStart)

  proc terminalCount(): int =
    for action in buildGraph.actions:
      if statuses[action.id] in {asSucceeded, asCacheHit, asUpToDate, asFailed, asBlocked}:
        inc result

  proc emitProgress(kind: BuildProgressKind; id: string) =
    if config.progressCallback == nil:
      return
    let idx = idToIndex.resultIndex(id)
    let action = actionsById[id]
    var command = ""
    if action.argv.len > 0:
      for arg in action.argv:
        if command.len > 0:
          command.add(" ")
        command.add(quoteShell(arg))
    else:
      command = $action.kind & " " & action.id
    config.progressCallback(BuildProgressEvent(
      kind: kind,
      actionId: id,
      command: command,
      status: runResult.results[idx].status,
      cacheDecision: runResult.results[idx].cacheDecision,
      launched: runResult.results[idx].launched,
      total: buildGraph.actions.len,
      completed: terminalCount(),
      running: running.len,
      ready: ready.len))

  proc hasPendingInlineRunQuota(): bool =
    for item in running:
      if item.processKind == rpkInlineRunQuotaPending:
        return true
    false

  proc anyInlineRunQuotaProcess(): bool =
    ## True when any running entry uses the inline RunQuota path (active
    ## or pending). The Windows event-driven wait can't include these
    ## (they don't expose a SYNCHRONIZE handle to us), so a non-zero
    ## answer caps the WaitForMultipleObjects timeout so we still poll
    ## `pollCompletion` periodically. Zero answer lets us wait longer.
    for item in running:
      if item.processKind in {rpkInlineRunQuota, rpkInlineRunQuotaPending,
                              rpkInlineRunQuotaFailed}:
        return true
    false

  proc failRunningAction(index: int; message: string) =
    running[index].inlineFailure = inlineRunQuotaFailureResult(
      running[index].id, message)
    running[index].processKind = rpkInlineRunQuotaFailed

  proc pollInlineRunQuotaGrants(): int =
    result = -1
    if not inlineRunQuotaSessionOpen or not hasPendingInlineRunQuota():
      return
    try:
      for grant in pollRunQuotaGrants(inlineRunQuotaSession):
        for j in 0 ..< running.len:
          if running[j].processKind != rpkInlineRunQuotaPending:
            continue
          if running[j].queuedRunQuotaProcess.candidateId != grant.candidateId:
            continue
          if not grant.active or grant.queued:
            failRunningAction(j, "runquota denied queued lease: " &
              grant.diagnostic)
            return j
          try:
            var queued = running[j].queuedRunQuotaProcess
            running[j].runQuotaProcess = startGrantedWithRunQuota(
              inlineRunQuotaSession, queued, grant)
            running[j].queuedRunQuotaProcess = queued
            running[j].processKind = rpkInlineRunQuota
            runResult.trace(running[j].id, "launched", "runquota-grant")
          except CatchableError as err:
            failRunningAction(j, "runquota inline process failed: " & err.msg)
            return j
          break
    except CatchableError as err:
      for j in 0 ..< running.len:
        if running[j].processKind == rpkInlineRunQuotaPending:
          failRunningAction(j, "runquota inline grant polling failed: " &
            err.msg)
          return j

  proc completeSuccess(id: string; status: ActionStatus; cacheDecision: CacheDecision;
                       launched: bool; detail = "") =
    let idx = idToIndex.resultIndex(id)
    runResult.results[idx].status = status
    runResult.results[idx].cacheDecision = cacheDecision
    runResult.results[idx].launched = launched
    statuses[id] = status
    if launched and status == asSucceeded:
      launchedSucceeded.incl(id)
    runResult.trace(id, $status, detail)
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        remaining[dep] = remaining[dep] - 1
        if remaining[dep] == 0:
          ready.add(dep)
    ready.sort(readyCmp)
    emitProgress(bpkActionCompleted, id)

  proc blockClosure(id, blocker: string) =
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        statuses[dep] = asBlocked
        let idx = idToIndex.resultIndex(dep)
        runResult.results[idx].status = asBlocked
        runResult.results[idx].blockedBy = blocker
        runResult.trace(dep, "blocked", blocker)
        emitProgress(bpkActionCompleted, dep)
        blockClosure(dep, blocker)

  proc applyDynamicDeps(id: string): bool =
    if dynamicDepsLoaded.contains(id):
      return true
    var action = actionsById[id]
    if action.dynamicDepsFile.len == 0:
      dynamicDepsLoaded.incl(id)
      return true
    let fragmentPath = materialPath(action.cwd, action.dynamicDepsFile)
    let dyndepStart = statStart()
    let fragment = readDynamicGraphFragment(fragmentPath)
    finishStat("repro dynamic deps load", dyndepStart)
    var addedWaiting = 0
    for output in fragment.outputs.getOrDefault(id):
      action.outputs.addUnique(output)
    for dep in fragment.deps.getOrDefault(id):
      if not actionsById.hasKey(dep):
        raiseEngine("dynamic dependency " & dep & " for " & id &
          " does not name an action in the selected graph")
      if dep == id:
        raiseEngine("dynamic dependency cycle: " & id & " depends on itself")
      if action.deps.find(dep) >= 0:
        continue
      action.deps.add(dep)
      dependents.mgetOrPut(dep, @[]).addUnique(id)
      case statuses[dep]
      of asSucceeded, asCacheHit, asUpToDate:
        discard
      of asFailed, asBlocked:
        statuses[id] = asBlocked
        let idx = idToIndex.resultIndex(id)
        runResult.results[idx].status = asBlocked
        runResult.results[idx].blockedBy = dep
        runResult.trace(id, "blocked", dep)
        emitProgress(bpkActionCompleted, id)
        blockClosure(id, dep)
        actionsById[id] = action
        dynamicDepsLoaded.incl(id)
        return false
      else:
        inc addedWaiting
    actionsById[id] = action
    dynamicDepsLoaded.incl(id)
    if addedWaiting > 0:
      remaining[id] = remaining.getOrDefault(id, 0) + addedWaiting
      runResult.trace(id, "dynamic-deps", "waiting=" & $addedWaiting)
      return false
    runResult.trace(id, "dynamic-deps", "loaded")
    true

  var completed = 0
  let runQuotaResultRoot = cacheRoot / "runquota-results"
  createDir(extendedPath(runQuotaResultRoot))
  var launchSeq = 0

  type StagedInlineLaunch = object
    id: string
    pool: string
    poolUnits: uint32
    runningIdx: int
    action: BuildAction
    resultPath: string

  try:
    while completed < buildGraph.actions.len:
      ready.sort(readyCmp)
      var launchedAny = false
      var stagedInlineLaunches: seq[StagedInlineLaunch] = @[]
      var i = 0
      while i < ready.len and
          uint32(running.len + stagedInlineLaunches.len) < maxParallel:
        let id = ready[i]
        var action = actionsById[id]
        let poolName = action.pool
        let cap = poolCapacity.getOrDefault(poolName, maxParallel)
        let used = poolRunning.getOrDefault(poolName, 0'u32)
        let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
        if used + units > cap:
          inc i
          continue

        ready.delete(i)
        if not applyDynamicDeps(id):
          launchedAny = true
          completed = terminalCount()
          continue
        action = actionsById[id]
        runResult.trace(id, "ready", "pool=" & poolName)
        runResult.trace(id, "dependency-policy", $action.dependencyPolicy.kind)

        var cacheMissInputChanged = false
        var dependencyLaunched = false
        var outputsPresentBeforeLookup = false
        var outputsPresentKnown = false
        for dep in action.deps:
          if launchedSucceeded.contains(dep):
            dependencyLaunched = true
            break
        if dependencyLaunched:
          runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
          runResult.trace(id, "cache-skipped", "dependency-launched")
        elif action.cacheable:
          if config.rebuildMissingOutputsOnCacheHit:
            let outputStatStart = statStart()
            outputsPresentBeforeLookup = action.allOutputsExist()
            outputsPresentKnown = true
            finishStat("repro output stat", outputStatStart)
          let lookupStart = statStart()
          let lookup = cache.lookupActionResult(cas, action.weakFingerprint,
            action.actionCachePolicy,
            verifyOutputBlobs = not outputsPresentBeforeLookup,
            allowMetadataOnlyHit = config.rebuildMissingOutputsOnCacheHit and
              outputsPresentBeforeLookup,
            metadataCache = addr fileMetadataCache)
          finishStat("repro cache lookup", lookupStart)
          case lookup.status
          of aclHit:
            var outputsPresent = true
            if config.rebuildMissingOutputsOnCacheHit:
              outputsPresent = outputsPresentBeforeLookup
            if config.rebuildMissingOutputsOnCacheHit and outputsPresent:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asUpToDate, cdHit, false, "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              let restoreStart = statStart()
              cas.restoreOutputs(lookup.record, action.cwd)
              fileMetadataCache.clear()
              finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asCacheHit, cdHit, false, "restored")
              inc completed
              launchedAny = true
              continue
          of aclHybridCutoff:
            var outputsPresent = true
            if config.rebuildMissingOutputsOnCacheHit:
              outputsPresent = outputsPresentBeforeLookup
            if config.rebuildMissingOutputsOnCacheHit and outputsPresent:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asUpToDate, cdHybridCutoff, false,
                "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              let restoreStart = statStart()
              cas.restoreOutputs(lookup.record, action.cwd)
              fileMetadataCache.clear()
              finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asCacheHit, cdHybridCutoff, false, "restored")
              inc completed
              launchedAny = true
              continue
          of aclRejectedCorruptOutput:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdRejected
          of aclMissInputChanged:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            cacheMissInputChanged = true
          else:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss

        var outputsPresent: bool
        if outputsPresentKnown:
          outputsPresent = outputsPresentBeforeLookup
        else:
          let outputStatStart = statStart()
          outputsPresent = action.allOutputsExist()
          finishStat("repro output stat", outputStatStart)
        if outputsPresent and not cacheMissInputChanged and
            not dependencyLaunched and
            not action.needsExecutionForPolicy():
          let evidenceStart = statStart()
          let evidence = collectEvidence(action, strict = true)
          finishStat("repro evidence collect", evidenceStart)
          runResult.results[idToIndex.resultIndex(id)].evidence = evidence.evidence
          if not evidence.publishable:
            statuses[id] = asFailed
            runResult.results[idToIndex.resultIndex(id)].status = asFailed
            runResult.results[idToIndex.resultIndex(id)].stderr =
              evidence.evidence.diagnostics.join("\n")
            runResult.trace(id, "failed", "dependency evidence invalid")
            blockClosure(id, id)
            emitProgress(bpkActionCompleted, id)
            completed = terminalCount()
            launchedAny = true
            continue
          completeSuccess(id, asUpToDate, runResult.results[idToIndex.resultIndex(id)].cacheDecision,
            false, "outputs-present")
          inc completed
          launchedAny = true
          continue

        let monitorPlanStart = statStart()
        let plan = monitoredAction(action, config, cacheRoot)
        finishStat("repro monitor plan", monitorPlanStart)
        if plan.diagnostic.len > 0:
          statuses[id] = asFailed
          let idx = idToIndex.resultIndex(id)
          runResult.results[idx].status = asFailed
          runResult.results[idx].stderr = plan.diagnostic
          runResult.trace(id, "failed", plan.diagnostic)
          blockClosure(id, id)
          emitProgress(bpkActionCompleted, id)
          completed = terminalCount()
          launchedAny = true
          continue

        if plan.action.kind != bakProcess:
          let builtinStart = statStart()
          let finished = executeBuiltinAction(plan.action)
          finishStat("repro builtin execute", builtinStart)
          let idx = idToIndex.resultIndex(id)
          let previousCacheDecision = runResult.results[idx].cacheDecision
          runResult.results[idx] = finished
          runResult.results[idx].dependencyPolicyKind =
            plan.action.dependencyPolicy.kind
          runResult.results[idx].cacheDecision =
            if actionsById[finished.id].cacheable and
                previousCacheDecision == cdNotCacheable:
              cdMiss
            else:
              previousCacheDecision
          statuses[id] = finished.status
          if finished.status == asSucceeded:
            invalidateCachedOutputs(plan.action)
            let evidenceStart = statStart()
            let evidence = collectEvidence(plan.action, strict = true)
            finishStat("repro evidence collect", evidenceStart)
            runResult.results[idx].evidence = evidence.evidence
            if not evidence.publishable:
              runResult.results[idx].status = asFailed
              runResult.results[idx].stderr =
                evidence.evidence.diagnostics.join("\n")
              statuses[id] = asFailed
              runResult.trace(finished.id, "failed", "dependency evidence invalid")
              blockClosure(finished.id, finished.id)
              emitProgress(bpkActionCompleted, finished.id)
              completed = terminalCount()
              launchedAny = true
              continue
            invalidateCachedWrites(plan.action, evidence.evidence)
            if plan.action.cacheable:
              let recordStart = statStart()
              let record = cache.recordActionResult(cas, plan.action.weakFingerprint,
                plan.action.actionCachePolicy, plan.action.cacheInputPaths(evidence.evidence),
                plan.action.outputs, plan.action.cwd,
                storeOutputBlobs = not config.deferLocalOutputBlobs,
                metadataCache = addr fileMetadataCache)
              finishStat("repro cache record", recordStart)
              writeActionResultRecordFile(
                dependencyEvidencePath(cacheRoot, plan.action.id), record)
            completeSuccess(finished.id, asSucceeded,
              runResult.results[idx].cacheDecision, true, "builtin")
          else:
            runResult.trace(finished.id, "failed", finished.stderr)
            blockClosure(finished.id, finished.id)
            emitProgress(bpkActionCompleted, finished.id)
          inc completed
          launchedAny = true
          continue

        statuses[id] = asRunning
        let runningIdx = idToIndex.resultIndex(id)
        runResult.results[runningIdx].status = asRunning
        runResult.results[runningIdx].launched = true
        runResult.results[runningIdx].monitorDepfilePath = plan.action.monitorDepfile
        poolRunning[poolName] = used + units
        inc launchSeq
        let resultPath = runQuotaResultRoot / ($launchSeq & ".json")
        var bypassRunQuota = false
        var inlineRunQuota = false
        if config.inlineRunQuota and not config.bypassRunQuota:
          inlineRunQuota = tryEnsureInlineRunQuotaSession()
          bypassRunQuota = not inlineRunQuota
        else:
          bypassRunQuota = launchBypassesRunQuota()
        if inlineRunQuota:
          # Pipelined path: defer the actual offer round-trip and stage
          # this launch. After the launch wave we'll dispatch every
          # staged action in a single OfferCandidates batch — the daemon
          # already supports batched candidate decisions, so this turns
          # an O(N) chain of synchronous round-trips at parallel=N into
          # a single round-trip per wave.
          stagedInlineLaunches.add(StagedInlineLaunch(
            id: id,
            pool: poolName,
            poolUnits: units,
            runningIdx: runningIdx,
            action: plan.action,
            resultPath: resultPath))
          launchedAny = true
          continue
        let launchStart = statStart()
        var process: Process
        var processKind =
          if bypassRunQuota: rpkBypassProcess
          else: rpkHelperProcess
        let startEvent = "launched"
        let startDetail = "pool=" & poolName
        var launchFailure = ""
        try:
          process = startRunQuotaProcess(plan.action, config, resultPath,
            bypassRunQuota)
        except CatchableError as err:
          launchFailure = err.msg
        finishStat("repro runquota launch", launchStart)
        if launchFailure.len > 0:
          let previousCacheDecision = runResult.results[runningIdx].cacheDecision
          runResult.results[runningIdx] = ActionResult(
            id: id,
            status: asFailed,
            exitCode: 1,
            launched: true,
            cacheDecision: previousCacheDecision,
            dependencyPolicyKind: plan.action.dependencyPolicy.kind,
            monitorDepfilePath: plan.action.monitorDepfile,
            stderr: "process launch failed: " & launchFailure,
            runQuotaBackend:
              if bypassRunQuota: "runquota-bypass"
              else: "runquota-helper",
            runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))
          statuses[id] = asFailed
          let failedUsed = poolRunning.getOrDefault(poolName, 0'u32)
          poolRunning[poolName] =
            if failedUsed > units: failedUsed - units else: 0'u32
          runResult.trace(id, "failed", "launch")
          blockClosure(id, id)
          emitProgress(bpkActionCompleted, id)
          completed = terminalCount()
          launchedAny = true
          continue
        running.add(RunningAction(
          id: id,
          pool: poolName,
          poolUnits: units,
          action: plan.action,
          processKind: processKind,
          process: process,
          resultPath: resultPath
        ))
        runResult.trace(id, startEvent, startDetail)
        emitProgress(bpkActionStarted, id)
        launchedAny = true

      # Flush any staged inline-runquota launches as one batched offer.
      # The previous per-action offerWithRunQuota loop performed an
      # offerCandidates round-trip serialised on each ready action — at
      # parallel=32 that's 32 synchronous round-trips before any work
      # actually starts. The batched call collapses them into one (or a
      # handful, when stagedInlineLaunches exceeds maxCandidatesPerBatch).
      if stagedInlineLaunches.len > 0:
        let batchStart = statStart()
        var requests = newSeq[ReproResourceRequest](stagedInlineLaunches.len)
        var commands = newSeq[ReproCommandSpec](stagedInlineLaunches.len)
        for k, staged in stagedInlineLaunches:
          requests[k] = staged.action.runQuotaRequest()
          commands[k] = staged.action.runQuotaCommand(config)
        var offers: seq[ReproRunQuotaOffer]
        var batchFailure = ""
        try:
          offers = offerWithRunQuotaBatch(inlineRunQuotaSession, requests, commands)
        except CatchableError as err:
          batchFailure = err.msg
        finishStat("repro runquota launch", batchStart)
        if batchFailure.len > 0:
          # The whole batch failed (e.g. session died mid-way). Mark
          # each staged launch failed and undo its pool reservation so
          # we don't lose capacity for the rest of the build.
          for staged in stagedInlineLaunches:
            let previousCacheDecision =
              runResult.results[staged.runningIdx].cacheDecision
            runResult.results[staged.runningIdx] = ActionResult(
              id: staged.id,
              status: asFailed,
              exitCode: 1,
              launched: true,
              cacheDecision: previousCacheDecision,
              dependencyPolicyKind: staged.action.dependencyPolicy.kind,
              monitorDepfilePath: staged.action.monitorDepfile,
              stderr: "process launch failed: " & batchFailure,
              runQuotaBackend: "runquota-inline",
              runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))
            statuses[staged.id] = asFailed
            let failedUsed = poolRunning.getOrDefault(staged.pool, 0'u32)
            poolRunning[staged.pool] =
              if failedUsed > staged.poolUnits: failedUsed - staged.poolUnits
              else: 0'u32
            runResult.trace(staged.id, "failed", "launch")
            blockClosure(staged.id, staged.id)
            emitProgress(bpkActionCompleted, staged.id)
          completed = terminalCount()
          launchedAny = true
        else:
          for k, staged in stagedInlineLaunches:
            let offer = offers[k]
            var startEvent = "launched"
            var startDetail = "pool=" & staged.pool
            var processKind: RunningProcessKind
            var runQuotaProcess: ReproRunQuotaRunningProcess
            var queuedRunQuotaProcess: ReproRunQuotaQueuedProcess
            case offer.kind
            of rqokStarted:
              runQuotaProcess = offer.running
              processKind = rpkInlineRunQuota
            of rqokQueued:
              queuedRunQuotaProcess = offer.queued
              processKind = rpkInlineRunQuotaPending
              startEvent = "queued"
              startDetail = "pool=" & staged.pool & " runquota=pending"
            running.add(RunningAction(
              id: staged.id,
              pool: staged.pool,
              poolUnits: staged.poolUnits,
              action: staged.action,
              processKind: processKind,
              runQuotaProcess: runQuotaProcess,
              queuedRunQuotaProcess: queuedRunQuotaProcess,
              resultPath: staged.resultPath
            ))
            runResult.trace(staged.id, startEvent, startDetail)
            emitProgress(bpkActionStarted, staged.id)
            launchedAny = true

      if completed >= buildGraph.actions.len:
        break

      if running.len == 0:
        if ready.len > 0 and not launchedAny:
          raiseEngine("ready queue is blocked by pool capacity")
        var pending: seq[string] = @[]
        for action in buildGraph.actions:
          if statuses[action.id] == asPending:
            pending.add(action.id)
        raiseEngine("build graph made no progress; pending actions: " & pending.join(", "))

      var runIndex = -1
      let waitStart = statStart()
      var nextGrantPoll = 0.0
      while runIndex < 0:
        if hasPendingInlineRunQuota() and epochTime() >= nextGrantPoll:
          runIndex = pollInlineRunQuotaGrants()
          nextGrantPoll = epochTime() + 0.025
          if runIndex >= 0:
            break
        # Cheap inline-only checks first: queued/failed inline-runquota
        # entries are not handle-based and the OS won't wake us for them.
        # Inline-RunQuota processes do their own pipe / handle wait in
        # `pollCompletion`, which is non-blocking here.
        for j in 0 ..< running.len:
          case running[j].processKind
          of rpkInlineRunQuotaPending:
            discard
          of rpkInlineRunQuota:
            if running[j].runQuotaProcess.pollCompletion():
              runIndex = j
              break
          of rpkInlineRunQuotaFailed:
            runIndex = j
            break
          of rpkHelperProcess, rpkBypassProcess:
            when defined(windows):
              # Handled by the event-driven block below; skip here.
              discard
            else:
              if running[j].process.peekExitCode() != -1:
                runIndex = j
                break
        if runIndex >= 0:
          break
        # Event-driven wait: ask the OS to wake us when ANY child process
        # exits. On Windows this is WaitForMultipleObjects on cached
        # SYNCHRONIZE-only handles (mirrors Ninja's IOCP-driven design in
        # references/ninja/src/subprocess-win32.cc) and avoids the
        # ≥15 ms timer-quantum latency the old peekExitCode + sleep(1)
        # spin loop had. We cap the timeout so the loop still revisits
        # inline-runquota grants and pending-queued state periodically.
        let timeoutMs =
          if hasPendingInlineRunQuota(): 25
          elif anyInlineRunQuotaProcess(): 50
          else: 250
        when defined(windows):
          let signaled = waitAnyProcessExitWindows(running, timeoutMs)
          if signaled >= 0:
            runIndex = signaled
        else:
          # POSIX `sleep(1)` is genuine 1 ms (not 15 ms like Windows), so
          # the spin pattern is acceptable here. A SIGCHLD-based waiter
          # would be more efficient but is a larger change.
          sleep(1)
      finishStat("repro process wait", waitStart)
      var runningItem = running[runIndex]
      let finishStart = statStart()
      let finished =
        case runningItem.processKind
        of rpkInlineRunQuotaPending:
          inlineRunQuotaFailureResult(
            runningItem.id,
            "runquota inline process failed: queued action selected before grant")
        of rpkInlineRunQuota:
          finishInlineRunQuotaProcess(
            runningItem.id,
            runningItem.runQuotaProcess)
        of rpkInlineRunQuotaFailed:
          runningItem.inlineFailure
        of rpkBypassProcess:
          finishRunQuotaProcess(
            runningItem.id,
            runningItem.process,
            runningItem.resultPath,
            true)
        of rpkHelperProcess:
          finishRunQuotaProcess(
            runningItem.id,
            runningItem.process,
            runningItem.resultPath,
            false)
      finishStat("repro runquota finish", finishStart)
      if runIndex < 0:
        raiseEngine("internal missing running action: " & finished.id)
      if runningItem.processKind in {rpkHelperProcess, rpkBypassProcess}:
        runningItem.process.close()
      let finishedUsed = poolRunning.getOrDefault(runningItem.pool, 0'u32)
      poolRunning[runningItem.pool] =
        if finishedUsed > runningItem.poolUnits:
          finishedUsed - runningItem.poolUnits
        else:
          0'u32
      when defined(windows):
        closeRunningProcessHandle(running[runIndex])
      running.delete(runIndex)

      let idx = idToIndex.resultIndex(finished.id)
      let previousCacheDecision = runResult.results[idx].cacheDecision
      runResult.results[idx] = finished
      runResult.results[idx].dependencyPolicyKind =
        runningItem.action.dependencyPolicy.kind
      runResult.results[idx].monitorDepfilePath = runningItem.action.monitorDepfile
      runResult.results[idx].cacheDecision =
        if actionsById[finished.id].cacheable and previousCacheDecision == cdNotCacheable:
          cdMiss
        else:
          previousCacheDecision
      statuses[finished.id] = finished.status
      if finished.status == asSucceeded:
        let action = runningItem.action
        invalidateCachedOutputs(action)
        let converterStart = statStart()
        let converterResult = action.runConverters(action.converterSpecsForPolicy())
        finishStat("repro dependency convert", converterStart)
        if not converterResult.ok:
          runResult.results[idx].status = asFailed
          var diagnostics: seq[string] = @[]
          if runResult.results[idx].stderr.len > 0:
            diagnostics.add(runResult.results[idx].stderr)
          diagnostics.add(converterResult.diagnostics)
          runResult.results[idx].stderr = diagnostics.join("\n").strip()
          statuses[finished.id] = asFailed
          runResult.trace(finished.id, "failed", "dependency converter failed")
          blockClosure(finished.id, finished.id)
          emitProgress(bpkActionCompleted, finished.id)
          completed = terminalCount()
          continue
        let evidenceStart = statStart()
        let evidence = collectEvidence(action, strict = true)
        finishStat("repro evidence collect", evidenceStart)
        runResult.results[idx].evidence = evidence.evidence
        if not evidence.publishable:
          runResult.results[idx].status = asFailed
          runResult.results[idx].stderr =
            [runResult.results[idx].stderr, evidence.evidence.diagnostics.join("\n")].join("\n").strip()
          statuses[finished.id] = asFailed
          runResult.trace(finished.id, "failed", "dependency evidence invalid")
          blockClosure(finished.id, finished.id)
          emitProgress(bpkActionCompleted, finished.id)
          completed = terminalCount()
          continue
        invalidateCachedWrites(action, evidence.evidence)
        if action.cacheable:
          let recordStart = statStart()
          let record = cache.recordActionResult(cas, action.weakFingerprint,
            action.actionCachePolicy, action.cacheInputPaths(evidence.evidence),
            action.outputs, action.cwd,
            storeOutputBlobs = not config.deferLocalOutputBlobs,
            metadataCache = addr fileMetadataCache)
          finishStat("repro cache record", recordStart)
          writeActionResultRecordFile(
            dependencyEvidencePath(cacheRoot, action.id), record)
        completeSuccess(finished.id, asSucceeded, runResult.results[idx].cacheDecision,
          true, "exit=0")
      else:
        runResult.trace(finished.id, "failed", "exit=" & $finished.exitCode)
        blockClosure(finished.id, finished.id)
        emitProgress(bpkActionCompleted, finished.id)
      inc completed

      completed = 0
      for action in buildGraph.actions:
        if statuses[action.id] in {asSucceeded, asCacheHit, asUpToDate, asFailed, asBlocked}:
          inc completed
  finally:
    for item in running.mitems:
      case item.processKind
      of rpkInlineRunQuotaPending:
        if item.queuedRunQuotaProcess.active:
          item.queuedRunQuotaProcess.cancelQueued()
      of rpkInlineRunQuota:
        if item.runQuotaProcess.active and not item.runQuotaProcess.completed:
          discard item.runQuotaProcess.cancelAndWait()
      of rpkInlineRunQuotaFailed:
        discard
      of rpkHelperProcess, rpkBypassProcess:
        if item.process.running():
          item.process.terminate()
        item.process.close()
    if inlineRunQuotaSessionOpen:
      inlineRunQuotaSession.close()
  finishStat("repro scheduler total", totalStart)
  runResult.stats = stats
  result = runResult
