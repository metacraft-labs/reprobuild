import std/[algorithm, json, os, sets, strutils, tables, times]

const
  StatsObservationSchemaId* = "reprobuild.daemon.stats-observation.v1"
  StatsSummarySchemaId* = "reprobuild.daemon.stats-summary.v1"
  StatsRetentionRawRuns* = 50
  StatsRetentionWindowDays* = 90

type
  StatsCaptureGroup* = enum
    scgTiming = "timing"
    scgCache = "cache"
    scgRunQuota = "runquota"
    scgDeps = "deps"
    scgSessions = "sessions"

  StatsCaptureConfig* = object
    enabled*: bool
    groups*: set[StatsCaptureGroup]
    raw*: string

  StatsFlushResult* = object
    storePath*: string
    summaryPath*: string
    queuedBefore*: int
    flushed*: int
    totalObservations*: int
    lastError*: string

var currentCapture: StatsCaptureConfig
var currentRunId = ""
var currentSessionId = ""
var currentProjectRoot = ""
var currentCommand = ""
var currentTarget = ""
var currentTestFlushDelayMs = 0
var observationQueue: seq[JsonNode] = @[]
var processFlushedCount = 0
var processLastFlushError = ""

proc nowUnixMs(): int64 =
  let current = getTime()
  current.toUnix * 1000 + int64(current.nanosecond div 1_000_000)

proc groupName*(group: StatsCaptureGroup): string =
  case group
  of scgTiming:
    "timing"
  of scgCache:
    "cache"
  of scgRunQuota:
    "runquota"
  of scgDeps:
    "deps"
  of scgSessions:
    "sessions"

proc stableStatsCaptureGroups*(): seq[string] =
  @["timing", "cache", "runquota", "deps", "sessions", "all"]

proc parseStatsCaptureGroups*(raw: string): StatsCaptureConfig =
  let trimmed = raw.strip()
  if trimmed.len == 0:
    raise newException(ValueError,
      "unsupported --stats-capture= (expected one or more of " &
        stableStatsCaptureGroups().join(",") & ")")
  result.enabled = true
  result.raw = trimmed
  for itemRaw in trimmed.split(','):
    let item = itemRaw.strip().toLowerAscii()
    if item.len == 0:
      raise newException(ValueError,
        "unsupported --stats-capture entry in " & raw)
    case item
    of "all":
      result.groups = {scgTiming, scgCache, scgRunQuota, scgDeps, scgSessions}
    of "timing":
      result.groups.incl(scgTiming)
    of "cache":
      result.groups.incl(scgCache)
    of "runquota":
      result.groups.incl(scgRunQuota)
    of "deps":
      result.groups.incl(scgDeps)
    of "sessions":
      result.groups.incl(scgSessions)
    else:
      raise newException(ValueError,
        "unsupported --stats-capture=" & item &
          " (expected one or more of " &
          stableStatsCaptureGroups().join(",") & ")")

proc captureGroupsText*(config: StatsCaptureConfig): string =
  if not config.enabled:
    return "disabled"
  var names: seq[string] = @[]
  for group in [scgTiming, scgCache, scgRunQuota, scgDeps, scgSessions]:
    if group in config.groups:
      names.add(group.groupName)
  names.join(",")

proc defaultStatsStorePath*(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "observations.jsonl"

proc defaultStatsSummaryPath*(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "summary.json"

proc enqueueStatsObservation*(group: StatsCaptureGroup; kind: string;
                              fields: JsonNode = newJObject())

proc beginStatsCapture*(runId, sessionId, projectRoot, command, target: string;
                        config: StatsCaptureConfig) =
  currentCapture = config
  currentRunId = runId
  currentSessionId = sessionId
  currentProjectRoot = projectRoot
  currentCommand = command
  currentTarget = target
  try:
    currentTestFlushDelayMs = max(0, parseInt(getEnv(
      "REPRO_DAEMON_TEST_STATS_FLUSH_DELAY_MS", "0")))
  except ValueError:
    currentTestFlushDelayMs = 0
  observationQueue.setLen(0)
  processLastFlushError = ""
  if currentCapture.enabled:
    for group in [scgTiming, scgCache, scgRunQuota, scgDeps, scgSessions]:
      if group in currentCapture.groups:
        enqueueStatsObservation(group, "capture-enabled", %*{
          "captureGroups": currentCapture.captureGroupsText
        })

proc endStatsCapture*() =
  currentCapture = StatsCaptureConfig()
  currentRunId = ""
  currentSessionId = ""
  currentProjectRoot = ""
  currentCommand = ""
  currentTarget = ""
  currentTestFlushDelayMs = 0
  observationQueue.setLen(0)

proc statsCaptureActive*(): bool =
  currentCapture.enabled

proc statsGroupEnabled*(group: StatsCaptureGroup): bool =
  currentCapture.enabled and group in currentCapture.groups

proc queuedStatsObservationCount*(): int =
  observationQueue.len

proc flushedStatsObservationCount*(): int =
  processFlushedCount

proc enqueueStatsObservation*(group: StatsCaptureGroup; kind: string;
                              fields: JsonNode = newJObject()) =
  if not statsGroupEnabled(group):
    return
  observationQueue.add(%*{
    "schemaId": StatsObservationSchemaId,
    "schemaVersion": 1,
    "occurredAtUnixMs": nowUnixMs(),
    "runId": currentRunId,
    "sessionId": currentSessionId,
    "projectRoot": currentProjectRoot,
    "command": currentCommand,
    "target": currentTarget,
    "group": group.groupName,
    "kind": kind,
    "fields": fields
  })

proc maybeTestFlushDelay() =
  if currentTestFlushDelayMs > 0:
    sleep(currentTestFlushDelayMs)

proc readJsonLines(path: string): seq[JsonNode] =
  if not fileExists(path):
    return
  for line in readFile(path).splitLines:
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    try:
      result.add(parseJson(trimmed))
    except JsonParsingError:
      discard

proc readStatsObservations*(projectRoot: string): seq[JsonNode] =
  readJsonLines(defaultStatsStorePath(projectRoot))

proc defaultStatsSnapshotDir*(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "snapshots"

proc writeJsonLines(path: string; nodes: openArray[JsonNode]) =
  createDir(parentDir(path))
  var file = open(path, fmWrite)
  defer: file.close()
  for node in nodes:
    file.writeLine($node)

proc retentionFiltered(nodes: seq[JsonNode]): seq[JsonNode] =
  var runOrder: seq[string] = @[]
  for node in nodes:
    let runId = node{"runId"}.getStr()
    if runId.len > 0 and runOrder.find(runId) < 0:
      runOrder.add(runId)
  var keepRuns = initHashSet[string]()
  let start = max(0, runOrder.len - StatsRetentionRawRuns)
  for i in start ..< runOrder.len:
    keepRuns.incl(runOrder[i])
  let cutoffMs = (getTime().toUnix - StatsRetentionWindowDays * 24 * 60 * 60) *
    1000
  for node in nodes:
    let runId = node{"runId"}.getStr()
    let occurred = node{"occurredAtUnixMs"}.getBiggestInt(0)
    if (runId.len == 0 or runId in keepRuns) and occurred >= cutoffMs:
      result.add(node)

proc buildSummary(projectRoot, storePath: string; nodes: seq[JsonNode];
                  lastFlushed: int): JsonNode =
  var groups = initCountTable[string]()
  var runs = initHashSet[string]()
  var firstMs = int64.high
  var lastMs = 0'i64
  for node in nodes:
    groups.inc(node{"group"}.getStr("unknown"))
    let runId = node{"runId"}.getStr()
    if runId.len > 0:
      runs.incl(runId)
    let occurred = node{"occurredAtUnixMs"}.getBiggestInt(0)
    if occurred > 0:
      firstMs = min(firstMs, occurred)
      lastMs = max(lastMs, occurred)
  var groupNode = newJObject()
  for key, value in groups:
    groupNode[key] = %value
  %*{
    "schemaId": StatsSummarySchemaId,
    "schemaVersion": 1,
    "projectRoot": projectRoot,
    "storePath": storePath,
    "updatedAtUnixMs": nowUnixMs(),
    "lastFlushObservationCount": lastFlushed,
    "totalObservations": nodes.len,
    "runCount": runs.len,
    "firstObservationUnixMs": (if firstMs == int64.high: 0'i64 else: firstMs),
    "lastObservationUnixMs": lastMs,
    "groups": groupNode,
    "retention": {
      "format": "jsonl",
      "rawRuns": StatsRetentionRawRuns,
      "windowDays": StatsRetentionWindowDays,
      "policy": "append batches, retain latest raw runs inside the time window"
    }
  }

proc flushStatsObservations*(): StatsFlushResult =
  result.queuedBefore = observationQueue.len
  result.flushed = 0
  if not currentCapture.enabled or currentProjectRoot.len == 0:
    return
  result.storePath = defaultStatsStorePath(currentProjectRoot)
  result.summaryPath = defaultStatsSummaryPath(currentProjectRoot)
  if observationQueue.len == 0:
    return
  let pending = observationQueue
  observationQueue.setLen(0)
  try:
    maybeTestFlushDelay()
    createDir(parentDir(result.storePath))
    block writePending:
      var file = open(result.storePath, fmAppend)
      defer: file.close()
      for node in pending:
        file.writeLine($node)
    result.flushed = pending.len
    processFlushedCount += pending.len
    let retained = retentionFiltered(readJsonLines(result.storePath))
    writeJsonLines(result.storePath, retained)
    let summary = buildSummary(currentProjectRoot, result.storePath, retained,
      pending.len)
    writeFile(result.summaryPath, pretty(summary))
    result.totalObservations = retained.len
    processLastFlushError = ""
  except CatchableError as err:
    processLastFlushError = err.msg
    result.lastError = err.msg
    for node in pending:
      observationQueue.add(node)

proc statsStatusText*(projectRoot: string): string =
  let storePath = defaultStatsStorePath(projectRoot)
  let summaryPath = defaultStatsSummaryPath(projectRoot)
  let nodes = readJsonLines(storePath)
  let summary =
    if fileExists(summaryPath):
      try: parseFile(summaryPath)
      except CatchableError: buildSummary(projectRoot, storePath, nodes, 0)
    else:
      buildSummary(projectRoot, storePath, nodes, 0)
  result.add("stats capture: disabled by default\n")
  result.add("active capture: " &
    (if currentCapture.enabled: currentCapture.captureGroupsText else: "none") &
    "\n")
  result.add("store: " & storePath & "\n")
  result.add("format: jsonl observations + summary.json\n")
  result.add("queued: " & $queuedStatsObservationCount() & "\n")
  result.add("flushed: " & $summary{"totalObservations"}.getInt(0) & "\n")
  result.add("runs: " & $summary{"runCount"}.getInt(0) & "\n")
  result.add("retention: raw-runs=" & $StatsRetentionRawRuns &
    " window=" & $StatsRetentionWindowDays & "d\n")
  result.add("groups:")
  let groups = summary{"groups"}
  if groups.kind == JObject and groups.len > 0:
    var names: seq[string] = @[]
    for key, value in groups:
      names.add(key & "=" & $value.getInt())
    result.add(" " & names.join(","))
  else:
    result.add(" none")
  result.add("\n")
  if processLastFlushError.len > 0:
    result.add("last flush error: " & processLastFlushError & "\n")

proc statsOverviewText*(projectRoot: string): string =
  let storePath = defaultStatsStorePath(projectRoot)
  let nodes = readJsonLines(storePath)
  var groups = initCountTable[string]()
  var kinds = initCountTable[string]()
  var cache = initCountTable[string]()
  var runquota = initCountTable[string]()
  var statuses = initCountTable[string]()
  var runs = initHashSet[string]()
  var actions = initHashSet[string]()
  var launched = 0
  var timingTotalUs = 0.0
  for node in nodes:
    groups.inc(node{"group"}.getStr("unknown"))
    kinds.inc(node{"kind"}.getStr("unknown"))
    let runId = node{"runId"}.getStr()
    if runId.len > 0:
      runs.incl(runId)
    let fields = node{"fields"}
    let actionId = fields{"actionId"}.getStr()
    if actionId.len > 0:
      actions.incl(actionId)
    if fields{"launched"}.getBool(false):
      inc launched
    let status = fields{"status"}.getStr()
    if status.len > 0:
      statuses.inc(status)
    let cacheDecision = fields{"cacheDecision"}.getStr()
    if cacheDecision.len > 0:
      cache.inc(cacheDecision)
    let backend = fields{"runQuotaBackend"}.getStr()
    if backend.len > 0:
      runquota.inc(backend)
    timingTotalUs += fields{"totalUs"}.getFloat(0.0)
  proc tableText(table: CountTable[string]): string =
    var pairs: seq[string] = @[]
    for key, value in table:
      pairs.add(key & "=" & $value)
    if pairs.len == 0: "none" else: pairs.join(",")
  result.add("Stats window: runs=" & $runs.len &
    " observations=" & $nodes.len & "\n")
  result.add("Capture groups: " & tableText(groups) & "\n")
  result.add("Observation kinds: " & tableText(kinds) & "\n")
  result.add("Actions: " & $actions.len & " launched=" & $launched & "\n")
  result.add("Statuses: " & tableText(statuses) & "\n")
  result.add("Cache: " & tableText(cache) & "\n")
  result.add("RunQuota: " & tableText(runquota) & "\n")
  result.add("Timing total: " & $timingTotalUs & "us\n")
