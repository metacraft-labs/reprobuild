## The DERIVED half of the two-store split (M18).
##
## Normative specification:
## ``reprobuild-specs/Build-Analytics-And-Optimization.md`` §"Two Stores",
## ``reprobuild-specs/Retired-Names.md`` §"Analytics store paths and schema
## ids".
##
## **THE RAW HALF IS GONE FROM HERE.** ``.repro/stats/observations.jsonl``,
## ``.repro/stats/summary.json`` and the two schema ids
## ``reprobuild.daemon.stats-observation.v1`` /
## ``reprobuild.daemon.stats-summary.v1`` are retired: raw per-execution rows
## are RunQuota's, written as ``ext_repro_action`` on its execution spine and
## read back through ``runquotad``'s query interface. Reprobuild does not
## define a database for them, does not choose their location, and does not
## manage their retention.
##
## **NO MIGRATION, AND THE QUESTION IS ALREADY SETTLED.** ``Retired-Names.md``
## records the JSONL store as "superseded rather than migrated: nothing reads
## it" -- it had exactly one reader, ``repro stats``, which now reads the
## shared store instead. An existing ``.repro/stats/observations.jsonl`` is
## therefore left alone rather than imported: importing it would inject rows
## with no host identity and no hardware profile into a store whose OS-6
## invariant refuses aggregates that lack them.
##
## ``--write-stats`` SURVIVES WITH A NARROWER JOB: it names the project-local
## DERIVED store, ``.repro/stats/derived/``, which holds rollups computed FROM
## RunQuota's rows and never raw samples of its own.

import std/[json, os, sets, strutils, tables, times]

import repro_runquota/stats_query

# RAW RETENTION IS NOT REPROBUILD'S ANY MORE. ``StatsRetentionRawRuns = 50``
# and ``StatsRetentionWindowDays = 90`` were the JSONL store's policy, and
# ``Retired-Names.md`` retires ``[stats] raw-runs = N`` with no replacement:
# raw retention is configured once in RunQuota for every client rather than
# per project. They are deleted rather than left as unused constants, because
# a constant naming a policy nothing enforces reads as a policy.

type
  StatsCaptureGroup* = enum
    scgTiming = "timing"
    scgCache = "cache"
    scgRunQuota = "runquota"
    scgDeps = "deps"
    scgSessions = "sessions"

  StatsCaptureConfig* = object
    ## PERSIST axis, third sink (CLI/README.md §"The accumulating stats store
    ## is the third sink"). ``enabled`` is set by ``--write-stats`` /
    ## ``--stats-groups``; ``groups`` selects which SECTIONS of the store get
    ## written, which is a persist decision rather than a collection one —
    ## most sections project data the run always has. ``storePath`` is the
    ## ``--write-stats=PATH`` override; empty means the conventional path.
    enabled*: bool
    groups*: set[StatsCaptureGroup]
    raw*: string
    storePath*: string

  StatsFlushResult* = object
    storePath*: string
      ## The DERIVED store this flush was for.
    queuedBefore*: int
    flushed*: int
      ## How many rollup inputs reached a backend. Zero until one is
      ## linked, and reported rather than assumed.
    discarded*: int
      ## How many were thrown away for want of that backend. Counted so a
      ## reader is never told "0 flushed" without also being told why.
    derivedBackendLinked*: bool
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
var processDiscardedCount = 0
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

const
  AllStatsCaptureGroups* = {scgTiming, scgCache, scgRunQuota, scgDeps,
    scgSessions}

proc stableStatsCaptureGroups*(): seq[string] =
  @["timing", "cache", "runquota", "deps", "sessions", "all"]

proc parseStatsCaptureGroups*(raw: string; storePath = ""): StatsCaptureConfig =
  ## Parses a ``--stats-groups=`` section list. Naming any section enables the
  ## sink, so ``--stats-groups=timing`` is a complete request on its own.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    raise newException(ValueError,
      "unsupported --stats-groups= (expected one or more of " &
        stableStatsCaptureGroups().join(",") & ")")
  result.enabled = true
  result.raw = trimmed
  result.storePath = storePath
  for itemRaw in trimmed.split(','):
    let item = itemRaw.strip().toLowerAscii()
    if item.len == 0:
      raise newException(ValueError,
        "unsupported --stats-groups entry in " & raw)
    case item
    of "all":
      result.groups = AllStatsCaptureGroups
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
        "unsupported --stats-groups=" & item &
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

proc derivedStatsStorePath*(projectRoot: string): string =
  ## Where ``--write-stats`` points now: the project-local DERIVED store of
  ## §"Two Stores", holding rollups, sketches and findings computed FROM
  ## RunQuota's rows. It holds no raw samples of its own.
  projectRoot / ".repro" / "stats" / "derived"

proc activeStatsStorePath*(projectRoot: string): string =
  ## ``--write-stats=PATH`` names the derived store exactly; bare
  ## ``--write-stats`` uses the conventional derived path.
  if currentCapture.storePath.len > 0:
    return currentCapture.storePath
  derivedStatsStorePath(projectRoot)

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

proc discardedStatsObservationCount*(): int =
  processDiscardedCount

proc enqueueStatsObservation*(group: StatsCaptureGroup; kind: string;
                              fields: JsonNode = newJObject()) =
  ## Queue one project-local observation for the DERIVED store.
  ##
  ## NO SCHEMA ID. ``reprobuild.daemon.stats-observation.v1`` is retired:
  ## it named a project-private raw schema, and raw rows are RunQuota's
  ## now. What is queued here is input to a project-local rollup, and it
  ## never leaves this process as a raw row.
  if not statsGroupEnabled(group):
    return
  observationQueue.add(%*{
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

proc defaultStatsSnapshotDir*(projectRoot: string): string =
  projectRoot / ".repro" / "stats" / "snapshots"

proc flushStatsObservations*(): StatsFlushResult =
  ## Drains the derived-store queue.
  ##
  ## **NOTHING IS WRITTEN, AND THE DISCARD IS COUNTED RATHER THAN SILENT.**
  ## The derived store is specified as SQLite (§"Two Stores"), a backend
  ## reprobuild does not link, so there is nowhere for these rollup inputs
  ## to go. The queue is drained anyway -- leaving it to grow would be a
  ## leak -- and ``discarded`` carries the count, so
  ## ``repro stats status`` can say how much was thrown away instead of
  ## reporting a store that quietly holds nothing.
  ##
  ## WHAT IS *NOT* LOST HERE: the raw per-execution rows. Those never
  ## entered this queue. They travel to ``runquotad`` as
  ## ``ext_repro_action`` rows on RunQuota's execution spine, written by
  ## the build engine at the point each fact is known, and they are what
  ## ``repro stats`` reads.
  result.queuedBefore = observationQueue.len
  result.flushed = 0
  result.derivedBackendLinked = false
  if currentProjectRoot.len == 0:
    result.storePath = ""
  else:
    result.storePath = activeStatsStorePath(currentProjectRoot)
  if not currentCapture.enabled or observationQueue.len == 0:
    observationQueue.setLen(0)
    return
  maybeTestFlushDelay()
  result.discarded = observationQueue.len
  processDiscardedCount += observationQueue.len
  observationQueue.setLen(0)
  processLastFlushError = ""

proc statsStatusText*(projectRoot: string; view: SharedStoreView): string =
  ## What ``repro stats status`` says about BOTH stores, and it never says
  ## a number about the raw one without saying where the number came from
  ## and whether the sample behind it is whole.
  let storePath = derivedStatsStorePath(projectRoot)
  result.add("raw capture: RunQuota-owned; every action a RunQuota session " &
    "admitted writes an ext_repro_action row\n")
  result.add("active derived capture: " &
    (if currentCapture.enabled: currentCapture.captureGroupsText else: "none") &
    "\n")
  result.add("raw store: " & view.windowText & "\n")
  # THE THREE EMPTY WINDOWS ARE NOT ONE. A reader who sees "samples: 0"
  # must be able to tell "no daemon" from "nothing built" from "the query
  # failed", so the state is printed above and the consequence spelled
  # out here.
  if not figuresArePresentable(view.state):
    result.add("raw statistics: NOT AVAILABLE (" & view.reason & ")\n")
  else:
    result.add("raw statistics: " &
      (if view.state == sssIncomplete: "INCOMPLETE" else: "complete") & "\n")
    result.add("executions: " & $view.sampleCount & "\n")
    result.add("action rows: " & $view.actionRows.len & "\n")
    var names: seq[string] = @[]
    for profile in view.profiles:
      names.add(profile.hostId & "/" & profile.profileId & " (" &
        profile.cpuModel & ", " & $profile.logicalCores & " cores)")
    result.add("host profiles: " &
      (if names.len == 0: "none" else: names.join("; ")) & "\n")
  if view.loss.known:
    result.add("counted losses: dropped=" & $view.loss.dropped &
      " write-failures=" & $view.loss.writeFailures &
      " rejected=" & $view.loss.rejected &
      " extension-rows-refused=" & $view.loss.extensionRowsRefused &
      " deferred-batches-refused=" & $view.loss.deferredBatchesRefused & "\n")
  else:
    result.add("counted losses: unknown (the daemon did not report them)\n")
  result.add("derived store: " & storePath & "\n")
  result.add("derived backend: not linked; queued rollup inputs are " &
    "discarded and counted\n")
  result.add("queued: " & $queuedStatsObservationCount() & "\n")
  result.add("flushed: " & $flushedStatsObservationCount() & "\n")
  result.add("discarded: " & $discardedStatsObservationCount() & "\n")
  if processLastFlushError.len > 0:
    result.add("last flush error: " & processLastFlushError & "\n")

proc statsOverviewText*(projectRoot: string; view: SharedStoreView): string =
  ## The one-screen summary, rendered from the shared store.
  ##
  ## EVERY FIGURE BELOW IS PRINTED ONLY INSIDE THE BRANCH THAT ESTABLISHED
  ## THE WINDOW IS PRESENTABLE. A version of this proc that computed the
  ## counters first and printed the state afterwards would print zeros for
  ## an unreachable daemon, which is the failure OS-2 names.
  discard projectRoot
  result.add("Stats source: " & view.windowText & "\n")
  if not figuresArePresentable(view.state):
    result.add("No statistics: " & view.reason & "\n")
    return
  if view.state == sssIncomplete:
    result.add("Sample: INCOMPLETE -- " & $view.loss.totalLost &
      " observations counted lost by runquotad\n")
  var actions = initHashSet[string]()
  var outcomes = initCountTable[string]()
  var kinds = initCountTable[string]()
  var pools = initCountTable[string]()
  var statsKeys = initHashSet[string]()
  var totalDurationMs = 0'i64
  for row in view.actionRows:
    let actionId = row.value("action_id")
    if actionId.len > 0:
      actions.incl(actionId)
    let outcome = row.value("cache_outcome")
    if outcome.len > 0:
      outcomes.inc(outcome)
    let kind = row.value("action_kind")
    if kind.len > 0:
      kinds.inc(kind)
    if row.hasValue("pool"):
      pools.inc(row.value("pool"))
  for execution in view.executions:
    if execution.statsKey.len > 0:
      statsKeys.incl(execution.statsKey)
    totalDurationMs += execution.durationMillis
  proc tableText(table: CountTable[string]): string =
    var pairs: seq[string] = @[]
    for key, value in table:
      pairs.add(key & "=" & $value)
    if pairs.len == 0: "none" else: pairs.join(",")
  result.add("Stats window: executions=" & $view.sampleCount &
    " actionRows=" & $view.actionRows.len &
    " first=" & $view.firstObservationUnixMillis &
    " last=" & $view.lastObservationUnixMillis & "ms\n")
  var profileNames: seq[string] = @[]
  for profile in view.profiles:
    profileNames.add(profile.hostId & "/" & profile.profileId)
  result.add("Host profiles: " &
    (if profileNames.len == 0: "none" else: profileNames.join(",")) & "\n")
  result.add("Actions: " & $actions.len & " launched=" & $view.actionRows.len &
    "\n")
  result.add("Action kinds: " & tableText(kinds) & "\n")
  result.add("Cache: " & tableText(outcomes) & "\n")
  result.add("Pools: " & tableText(pools) & "\n")
  result.add("RunQuota: statsKeys=" & $statsKeys.len & "\n")
  result.add("Timing total: " & $totalDurationMs & "ms\n")
