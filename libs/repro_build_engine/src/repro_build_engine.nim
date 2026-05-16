import std/[algorithm, json, os, osproc, sets, streams, strutils, tables]

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

  BuildAction* = object
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
    depfile*: string
    monitorDepfile*: string

  BuildPool* = object
    name*: string
    capacity*: uint32

  BuildGraph* = object
    actions*: seq[BuildAction]
    pools*: seq[BuildPool]

  BuildEngineConfig* = object
    cacheRoot*: string
    runQuotaCliPath*: string
    maxParallelism*: uint32
    stdoutLimit*: int
    stderrLimit*: int

  PathSetEvidence* = object
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    depfileInputs*: seq[string]
    monitorReads*: seq[string]
    monitorWrites*: seq[string]
    monitorProbes*: seq[string]
    diagnostics*: seq[string]

  ActionResult* = object
    id*: string
    status*: ActionStatus
    exitCode*: int
    launched*: bool
    cacheDecision*: CacheDecision
    blockedBy*: string
    stdout*: string
    stderr*: string
    leaseId*: uint64
    runQuotaBackend*: string
    evidence*: PathSetEvidence

  SchedulerTraceEvent* = object
    seq*: uint64
    actionId*: string
    event*: string
    detail*: string

  BuildRunResult* = object
    results*: seq[ActionResult]
    trace*: seq[SchedulerTraceEvent]

  RunningAction = object
    id: string
    pool: string
    poolUnits: uint32
    process: Process
    resultPath: string

proc defaultBuildEngineConfig*(cacheRoot: string): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    runQuotaCliPath: "",
    maxParallelism: 8'u32,
    stdoutLimit: 1_048_576,
    stderrLimit: 1_048_576)

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
             depfile = ""; monitorDepfile = "";
             env: openArray[string] = []): BuildAction =
  BuildAction(
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
    depfile: depfile,
    monitorDepfile: monitorDepfile)

proc pool*(name: string; capacity: uint32): BuildPool =
  BuildPool(name: name, capacity: capacity)

proc graph*(actions: openArray[BuildAction];
            pools: openArray[BuildPool] = []): BuildGraph =
  BuildGraph(actions: @actions, pools: @pools)

proc trace(result: var BuildRunResult; actionId, event, detail: string) =
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
    if action.argv.len == 0 and action.outputs.len == 0:
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

proc allOutputsExist(action: BuildAction): bool =
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path = if output.isAbsolute or action.cwd.len == 0: output else: action.cwd / output
    if not fileExists(path):
      return false
  true

proc normalizeDepfileText(text: string): string =
  text.replace("\\\n", " ").replace("\\\r\n", " ")

proc parseDepfileInputs(path: string): seq[string] =
  if path.len == 0 or not fileExists(path):
    return
  let normalized = normalizeDepfileText(readFile(path))
  let colon = normalized.find(':')
  if colon < 0:
    return
  let rest = normalized[colon + 1 .. ^1]
  for token in rest.splitWhitespace:
    if token.len > 0:
      result.add(token)

proc addUnique(values: var seq[string]; value: string) =
  if value.len == 0:
    return
  if values.find(value) < 0:
    values.add(value)

proc collectEvidence(action: BuildAction): PathSetEvidence =
  result.declaredInputs = action.inputs
  result.declaredOutputs = action.outputs
  for input in parseDepfileInputs(action.depfile):
    result.depfileInputs.addUnique(input)
  if action.monitorDepfile.len > 0:
    try:
      let dep = readMonitorDepFile(action.monitorDepfile)
      for record in dep.records:
        case record.kind
        of mrFileRead, mrFileOpen:
          result.monitorReads.addUnique(record.path)
        of mrFileWrite:
          result.monitorWrites.addUnique(record.path)
        of mrPathProbe, mrDirectoryEnumerate:
          result.monitorProbes.addUnique(record.path)
        else:
          discard
      if dep.completeness != mcComplete:
        result.diagnostics.add("monitor depfile is incomplete")
    except MonitorDepFileReaderError as err:
      result.diagnostics.add("monitor depfile read failed: " & err.msg)

proc defaultRunQuotaHelperPath(): string =
  let configured = getEnv("REPRO_RUNQUOTA_HELPER")
  if configured.len > 0:
    return configured
  raiseEngine("BuildEngineConfig.runQuotaCliPath or REPRO_RUNQUOTA_HELPER is required")

proc startRunQuotaProcess(action: BuildAction; config: BuildEngineConfig;
                          resultPath: string): Process =
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

proc finishRunQuotaProcess(id: string; process: Process; resultPath: string): ActionResult =
  result = ActionResult(id: id, launched: true, runQuotaBackend: "runquota-helper")
  let helperExit = process.waitForExit()
  var helperOutput = ""
  if process.outputStream != nil:
    helperOutput = process.outputStream.readAll()
  if not fileExists(resultPath):
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper did not write result"
    if helperOutput.len > 0:
      result.stderr.add(": " & helperOutput)
    return
  try:
    let node = parseFile(resultPath)
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
    result.status =
      if helperExit == 0 and runnerError.len == 0 and result.exitCode == 0:
        asSucceeded
      else:
        asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper result parse failed: " & err.msg

proc resultIndex(ids: Table[string, int]; id: string): int =
  if not ids.hasKey(id):
    raiseEngine("internal missing result id: " & id)
  ids[id]

proc runBuild*(g: BuildGraph; config: BuildEngineConfig): BuildRunResult =
  var runResult: BuildRunResult
  validateGraph(g)

  let maxParallel = if config.maxParallelism == 0'u32: 1'u32 else: config.maxParallelism
  let cacheRoot = if config.cacheRoot.len == 0:
      getCurrentDir() / ".repro" / "build-engine-cache"
    else:
      config.cacheRoot
  let cas = openLocalCas(cacheRoot / "cas")
  var cache = openActionCache(cacheRoot / "action-cache")

  var idToIndex = initTable[string, int]()
  var dependents = initTable[string, seq[string]]()
  var remaining = initTable[string, int]()
  var statuses = initTable[string, ActionStatus]()
  var poolCapacity = initTable[string, uint32]()
  var poolRunning = initTable[string, uint32]()
  var ready: seq[string] = @[]
  var actionsById = initTable[string, BuildAction]()

  poolCapacity[""] = maxParallel
  for p in g.pools:
    poolCapacity[p.name] = p.capacity
  for action in g.actions:
    let cap = poolCapacity.getOrDefault(action.pool, maxParallel)
    let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
    if units > cap:
      raiseEngine("action " & action.id & " requests " & $units &
        " units from pool " & action.pool & " with capacity " & $cap)
  for i, action in g.actions:
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
      cacheDecision: if action.cacheable: cdMiss else: cdNotCacheable))

  proc readyCmp(a, b: string): int =
    cmp(idToIndex[a], idToIndex[b])

  proc completeSuccess(id: string; status: ActionStatus; cacheDecision: CacheDecision;
                       launched: bool; detail = "") =
    let idx = idToIndex.resultIndex(id)
    runResult.results[idx].status = status
    runResult.results[idx].cacheDecision = cacheDecision
    runResult.results[idx].launched = launched
    statuses[id] = status
    runResult.trace(id, $status, detail)
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        remaining[dep] = remaining[dep] - 1
        if remaining[dep] == 0:
          ready.add(dep)
    ready.sort(readyCmp)

  proc blockClosure(id, blocker: string) =
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        statuses[dep] = asBlocked
        let idx = idToIndex.resultIndex(dep)
        runResult.results[idx].status = asBlocked
        runResult.results[idx].blockedBy = blocker
        runResult.trace(dep, "blocked", blocker)
        blockClosure(dep, blocker)

  var completed = 0
  var running: seq[RunningAction] = @[]
  let runQuotaResultRoot = cacheRoot / "runquota-results"
  createDir(runQuotaResultRoot)
  var launchSeq = 0
  try:
    while completed < g.actions.len:
      ready.sort(readyCmp)
      var launchedAny = false
      var i = 0
      while i < ready.len and uint32(running.len) < maxParallel:
        let id = ready[i]
        let action = actionsById[id]
        let poolName = action.pool
        let cap = poolCapacity.getOrDefault(poolName, maxParallel)
        let used = poolRunning.getOrDefault(poolName, 0'u32)
        let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
        if used + units > cap:
          inc i
          continue

        ready.delete(i)
        runResult.trace(id, "ready", "pool=" & poolName)

        if action.cacheable:
          let lookup = cache.lookupActionResult(cas, action.weakFingerprint, ffpChecksum)
          case lookup.status
          of aclHit:
            cas.restoreOutputs(lookup.record, action.cwd)
            runResult.results[idToIndex.resultIndex(id)].evidence = collectEvidence(action)
            completeSuccess(id, asCacheHit, cdHit, false, "restored")
            inc completed
            launchedAny = true
            continue
          of aclHybridCutoff:
            cas.restoreOutputs(lookup.record, action.cwd)
            runResult.results[idToIndex.resultIndex(id)].evidence = collectEvidence(action)
            completeSuccess(id, asCacheHit, cdHybridCutoff, false, "restored")
            inc completed
            launchedAny = true
            continue
          of aclRejectedCorruptOutput:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdRejected
          else:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss

        if action.allOutputsExist():
          runResult.results[idToIndex.resultIndex(id)].evidence = collectEvidence(action)
          completeSuccess(id, asUpToDate, runResult.results[idToIndex.resultIndex(id)].cacheDecision,
            false, "outputs-present")
          inc completed
          launchedAny = true
          continue

        statuses[id] = asRunning
        runResult.results[idToIndex.resultIndex(id)].status = asRunning
        poolRunning[poolName] = used + units
        inc launchSeq
        let resultPath = runQuotaResultRoot / ($launchSeq & ".json")
        let process = startRunQuotaProcess(action, config, resultPath)
        running.add(RunningAction(
          id: id,
          pool: poolName,
          poolUnits: units,
          process: process,
          resultPath: resultPath))
        runResult.trace(id, "launched", "pool=" & poolName)
        launchedAny = true

      if running.len == 0:
        if ready.len > 0 and not launchedAny:
          raiseEngine("ready queue is blocked by pool capacity")
        var pending: seq[string] = @[]
        for action in g.actions:
          if statuses[action.id] == asPending:
            pending.add(action.id)
        raiseEngine("build graph made no progress; pending actions: " & pending.join(", "))

      var runIndex = -1
      while runIndex < 0:
        for j in 0 ..< running.len:
          if running[j].process.peekExitCode() != -1:
            runIndex = j
            break
        if runIndex < 0:
          sleep(10)
      let finished = finishRunQuotaProcess(
        running[runIndex].id,
        running[runIndex].process,
        running[runIndex].resultPath)
      if runIndex < 0:
        raiseEngine("internal missing running action: " & finished.id)
      running[runIndex].process.close()
      let finishedUsed = poolRunning.getOrDefault(running[runIndex].pool, 0'u32)
      poolRunning[running[runIndex].pool] =
        if finishedUsed > running[runIndex].poolUnits:
          finishedUsed - running[runIndex].poolUnits
        else:
          0'u32
      running.delete(runIndex)

      let idx = idToIndex.resultIndex(finished.id)
      runResult.results[idx] = finished
      runResult.results[idx].cacheDecision =
        if actionsById[finished.id].cacheable and runResult.results[idx].cacheDecision == cdNotCacheable:
          cdMiss
        else:
          runResult.results[idx].cacheDecision
      statuses[finished.id] = finished.status
      if finished.status == asSucceeded:
        let action = actionsById[finished.id]
        runResult.results[idx].evidence = collectEvidence(action)
        if action.cacheable:
          discard cache.recordActionResult(cas, action.weakFingerprint, ffpChecksum,
            action.inputs, action.outputs, action.cwd)
        completeSuccess(finished.id, asSucceeded, runResult.results[idx].cacheDecision,
          true, "exit=0")
      else:
        runResult.trace(finished.id, "failed", "exit=" & $finished.exitCode)
        blockClosure(finished.id, finished.id)
      inc completed

      completed = 0
      for action in g.actions:
        if statuses[action.id] in {asSucceeded, asCacheHit, asUpToDate, asFailed, asBlocked}:
          inc completed
  finally:
    for item in running.mitems:
      if item.process.running():
        item.process.terminate()
      item.process.close()
  result = runResult
