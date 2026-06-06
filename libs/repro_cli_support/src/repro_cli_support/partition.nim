## CI-Sharding M1 — `repro test` partition planner (library only).
##
## This module bridges three substrates into the generic
## `runquota_partition` optimiser:
##
##   1. Reprobuild's normalised build graph (passed in by the caller —
##      M1 stays library-only, so this module does not invoke the engine
##      itself; see strategy notes in CI-Sharding.milestones.org M1).
##   2. RunQuota's learned-estimate store (per-action wall-time costs,
##      keyed by command stats id).  M1 reads the store via the
##      ``sqlite3`` shell — the same approach runquota_persistence uses
##      for writes — so no new C dependency is introduced.  A batched
##      ``runquota_client`` API is the documented follow-up.
##   3. Codetracer's history reporter (per-test wall times).  The full
##      reporter protocol is M3+ territory; for M1 we stub it as a
##      JSON sidecar named ``test-durations.json`` under ``historyDir``
##      keyed by ``"<suite>::<test>"``.
##
## The public entry point is ``planTestShards`` which returns a
## ``ShardPlan`` envelope: the ``PartitionPlan`` from M0 plus a
## ``degraded`` flag and miss counters for the cold-cache case.
##
## Cold-cache rule
## ===============
##
## When BOTH cost sources have no usable data — every build action and
## every test edge falls back to the configured fallback constants —
## the planner emits a count-balanced plan (round-robin across shards,
## equivalent to ``--partition-strategy slice``) and sets
## ``degraded = true`` so callers can surface a warning.  Any partial
## hit on either source disables degraded mode.
##
## JSON schema
## ===========
##
## The serialised plan carries ``"schemaId": "reprobuild.partition-plan.v1"``.
## ``readPartitionPlanJson`` raises ``PartitionPlanReadError`` with a
## clear message on schema mismatch.

import std/[json, os, osproc, sequtils, strutils, tables, times]

import runquota_partition

const
  PartitionPlanSchemaId* = "reprobuild.partition-plan.v1"
    ## Versioned JSON schema id for emitted plans.

  DefaultEstimateDurationTable* = "learned_estimate_durations"
    ## Name of the SQLite table the planner reads build-action durations
    ## from.  M1 maintains this as a small companion table next to the
    ## runquota_persistence ``learned_estimates`` table so this milestone
    ## does not have to extend the upstream schema.  Columns:
    ##
    ##   scope TEXT NOT NULL
    ##   command_stats_id TEXT NOT NULL
    ##   wall_time_ns INTEGER NOT NULL
    ##   sample_count INTEGER NOT NULL DEFAULT 1
    ##   updated_unix_millis INTEGER NOT NULL DEFAULT 0
    ##   PRIMARY KEY (scope, command_stats_id)

  TestDurationsFileName* = "test-durations.json"
    ## Sidecar file the planner reads codetracer per-test wall times
    ## from.  Lives directly under the workspace's history dir.  Shape:
    ## ``{ "<suite>::<test>": <duration_ms_int>, ... }``.

type
  ShardBuildAction* = object
    ## A single node in the build-graph closure of the planned test
    ## edges.  ``id`` is opaque (whatever the caller wants — typically
    ## a hash of the action's command line); ``commandStatsId`` is the
    ## key into RunQuota's learned-estimate store.  ``deps`` references
    ## other ``ShardBuildAction.id`` values.
    id*: NodeId
    commandStatsId*: string
    deps*: seq[NodeId]

  ShardTestEdge* = object
    ## A test-edge root passed to the partitioner.  ``id`` is the root
    ## identity; ``historyKey`` is the ``"<suite>::<test>"`` lookup key
    ## in the codetracer history sidecar.  ``buildDeps`` are the build
    ## actions the test edge depends on (NodeIds in the build graph).
    id*: NodeId
    selector*: string
    historyKey*: string
    buildDeps*: seq[NodeId]

  ShardPlanRequest* = object
    ## Input bundle for ``planTestShards``.  See the field comments for
    ## per-field semantics.
    shardCount*: int
    targetSelectors*: seq[string]
      ## Caller-supplied selectors used to scope reporting.  Empty
      ## means "all of ``testEdges``".  When non-empty, only edges whose
      ## ``selector`` is in the set are partitioned.
    policy*: SharedInputPolicy
    historyDir*: string
      ## Path to the codetracer history backend root, or "" if absent.
    estimateDbPath*: string
      ## Path to the SQLite DB the planner reads build-action costs
      ## from.  "" disables the lookup (every action falls back).
    estimateScope*: string
      ## ``scope`` column to filter the SQLite read by.  "" matches all
      ## rows.
    fallbackBuildCostNs*: int64
    fallbackTestCostNs*: int64
    buildActions*: seq[ShardBuildAction]
    testEdges*: seq[ShardTestEdge]
    refinementPasses*: int
      ## Forwarded to ``runquota_partition.PartitionRequest``.  0 keeps
      ## the LPT result unchanged; ``DefaultRefinementPasses`` is the
      ## recommended default for callers that do not care.

  ShardPlan* = object
    ## Output envelope: the partition plan plus M1's degraded-cache
    ## signal.
    partition*: PartitionPlan
    degraded*: bool
    unknownBuildCount*: int
    unknownTestCount*: int

  PartitionPlanReadError* = object of CatchableError
    ## Raised by ``readPartitionPlanJson`` on schema-version mismatch
    ## or a malformed payload.

# ---------------------------------------------------------------------------
# Cost lookups
# ---------------------------------------------------------------------------

proc sqlQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc loadEstimateDurations(dbPath, scope: string): Table[string, int64] =
  ## Returns a ``commandStatsId -> wall_time_ns`` map by querying the
  ## SQLite DB at ``dbPath``.  Missing file, missing table, or
  ## ``sqlite3`` binary not found all yield an empty table — the caller
  ## then falls back to ``fallbackBuildCostNs`` and increments the miss
  ## counter accordingly.
  ##
  ## ``sqlite3`` is invoked via ``execProcess`` rather than
  ## ``execCmdEx`` so the SQL string is passed as a single ``argv``
  ## element and is never re-interpreted by a shell — embedded single
  ## quotes therefore survive unmodified, which matters for the SQL
  ## literal used in the scope filter.
  result = initTable[string, int64]()
  if dbPath.len == 0 or not fileExists(dbPath):
    return
  var sqlText = "select command_stats_id, wall_time_ns from " &
    DefaultEstimateDurationTable
  if scope.len > 0:
    sqlText.add(" where scope = " & sqlQuote(scope))
  sqlText.add(";")
  let output = try:
    execProcess("sqlite3", args = [dbPath, sqlText],
        options = {poUsePath, poStdErrToStdOut})
  except OSError:
    return
  for line in output.splitLines():
    if line.len == 0:
      continue
    # ``sqlite3`` emits diagnostics on stderr; ``poStdErrToStdOut``
    # merges them in.  Lines that don't look like ``<id>|<int>`` are
    # silently ignored — the cold-cache path will then kick in.
    let row = line.split('|')
    if row.len < 2:
      continue
    try:
      result[row[0]] = parseBiggestInt(row[1]).int64
    except ValueError:
      discard

proc loadTestDurations(historyDir: string): Table[string, int64] =
  ## Returns a ``"<suite>::<test>" -> wall_time_ns`` map by reading
  ## ``historyDir/test-durations.json``.  Missing dir, missing file, or
  ## malformed JSON all yield an empty table.
  result = initTable[string, int64]()
  if historyDir.len == 0:
    return
  let path = historyDir / TestDurationsFileName
  if not fileExists(path):
    return
  let raw = try:
    readFile(path)
  except IOError:
    return
  let parsed = try:
    parseJson(raw)
  except JsonParsingError, ValueError:
    return
  if parsed.kind != JObject:
    return
  for key, value in parsed.fields:
    let ms = case value.kind
      of JInt: value.getInt().int64
      of JFloat: int64(value.getFloat())
      else: -1'i64
    if ms < 0:
      continue
    result[key] = ms * 1_000_000  # ms -> ns

# ---------------------------------------------------------------------------
# Planner
# ---------------------------------------------------------------------------

proc filterSelectedEdges(edges: seq[ShardTestEdge];
                         selectors: seq[string]): seq[ShardTestEdge] =
  if selectors.len == 0:
    return edges
  var allowed = initTable[string, bool]()
  for sel in selectors:
    allowed[sel] = true
  for edge in edges:
    if allowed.getOrDefault(edge.selector, false):
      result.add(edge)

proc countBalancedPlan(req: ShardPlanRequest;
                       edges: seq[ShardTestEdge]): PartitionPlan =
  ## Round-robin slice plan, used when both cost sources are cold.
  ## Roots are emitted in their original order so the slice matches
  ## ``--partition-strategy slice``.
  result.shardCount = max(1, req.shardCount)
  result.assignments = newSeq[PartitionAssignment](edges.len)
  result.perShardCost = newSeq[Duration](result.shardCount)
  for k in 0 ..< result.shardCount:
    result.perShardCost[k] = initDuration(nanoseconds = 0)
  let costNs = max(0'i64, req.fallbackTestCostNs)
  for i, edge in edges:
    let shardIdx = i mod result.shardCount
    result.assignments[i] = PartitionAssignment(
      root: edge.id,
      shardIndex: shardIdx + 1,
      explainedCost: initDuration(nanoseconds = costNs)
    )
    result.perShardCost[shardIdx] = result.perShardCost[shardIdx] +
      initDuration(nanoseconds = costNs)
  # Bound mirrors the trivially uniform sum.
  let sumNs = costNs * edges.len.int64
  let factor =
    if result.shardCount <= 0: 1.0
    else: 4.0 / 3.0 - 1.0 / (3.0 * float(result.shardCount))
  result.bound = initDuration(nanoseconds = int64(float(sumNs) * factor))

proc planTestShards*(req: ShardPlanRequest): ShardPlan =
  ## Builds a ``PartitionRequest`` from the caller's build graph and
  ## test edges, decorates each node and root with the best-available
  ## cost estimate (RunQuota + codetracer history, falling back to the
  ## configured constants), calls ``computePartition``, and returns the
  ## resulting plan wrapped in a ``ShardPlan`` envelope.
  doAssert req.shardCount >= 1,
    "ShardPlanRequest.shardCount must be >= 1"
  let edges = filterSelectedEdges(req.testEdges, req.targetSelectors)

  let buildDurations = loadEstimateDurations(req.estimateDbPath,
      req.estimateScope)
  let testDurations = loadTestDurations(req.historyDir)

  # Build the union of build-action ids that participate in any
  # selected edge's closure.  We only consume costs for actions that
  # actually appear in the planned closure so the miss counters reflect
  # the planned shard work, not the workspace's total action universe.
  var actionById = initTable[NodeId, ShardBuildAction]()
  for action in req.buildActions:
    actionById[action.id] = action

  var seenNodes = initTable[NodeId, bool]()
  var unknownBuildCount = 0
  var knownBuildCount = 0
  var unknownTestCount = 0
  var knownTestCount = 0
  var nodes: seq[PartitionNode] = @[]

  proc visit(id: NodeId) =
    if seenNodes.getOrDefault(id, false):
      return
    seenNodes[id] = true
    if not actionById.hasKey(id):
      return
    let action = actionById[id]
    let cost =
      if action.commandStatsId.len > 0 and
          buildDurations.hasKey(action.commandStatsId):
        inc knownBuildCount
        buildDurations[action.commandStatsId]
      else:
        inc unknownBuildCount
        max(0'i64, req.fallbackBuildCostNs)
    nodes.add(PartitionNode(
      id: action.id,
      weight: initDuration(nanoseconds = cost),
      deps: action.deps
    ))
    for dep in action.deps:
      visit(dep)

  for edge in edges:
    for dep in edge.buildDeps:
      visit(dep)

  # Each test edge enters the partitioner BOTH as a root (so the LPT
  # pass treats the edge as an indivisible unit assignable to one
  # shard) AND as a node whose ``deps`` are the edge's build closure.
  # ``runquota_partition.closureCost`` walks deps from the root id;
  # if no node with that id exists it returns just the root weight.
  # Test edges with non-trivial build closures therefore need a
  # zero-weight bridge node so the closure traversal reaches the
  # build graph.  The node's weight is zero because the edge's own
  # cost is carried by ``PartitionRoot.weight``; under sipIndependent
  # ``closureCost`` would otherwise double-count it.
  var roots: seq[PartitionRoot] = @[]
  for edge in edges:
    let cost =
      if edge.historyKey.len > 0 and testDurations.hasKey(edge.historyKey):
        inc knownTestCount
        testDurations[edge.historyKey]
      else:
        inc unknownTestCount
        max(0'i64, req.fallbackTestCostNs)
    roots.add(PartitionRoot(
      id: edge.id,
      weight: initDuration(nanoseconds = cost)
    ))
    if not seenNodes.getOrDefault(edge.id, false):
      seenNodes[edge.id] = true
      nodes.add(PartitionNode(
        id: edge.id,
        weight: initDuration(nanoseconds = 0),
        deps: edge.buildDeps
      ))

  let totalBuild = knownBuildCount + unknownBuildCount
  let totalTest = knownTestCount + unknownTestCount
  let coldCache = (knownBuildCount == 0 and knownTestCount == 0 and
                   totalBuild + totalTest > 0)

  if coldCache:
    result.partition = countBalancedPlan(req, edges)
    result.degraded = true
    result.unknownBuildCount = unknownBuildCount
    result.unknownTestCount = unknownTestCount
    return

  let partitionRequest = PartitionRequest(
    nodes: nodes,
    roots: roots,
    shardCount: req.shardCount,
    policy: req.policy,
    refinementPasses:
      if req.refinementPasses <= 0: DefaultRefinementPasses
      else: req.refinementPasses
  )
  result.partition = computePartition(partitionRequest)
  result.degraded = false
  result.unknownBuildCount = unknownBuildCount
  result.unknownTestCount = unknownTestCount

# ---------------------------------------------------------------------------
# JSON serialisation
# ---------------------------------------------------------------------------

proc durationNs(d: Duration): int64 = d.inNanoseconds

proc nsToDuration(n: int64): Duration =
  initDuration(nanoseconds = n)

proc policyToString(p: SharedInputPolicy): string =
  case p
  of sipIndependent: "independent"
  of sipShared: "shared"

proc parsePolicy(s: string): SharedInputPolicy =
  case s
  of "independent": sipIndependent
  of "shared": sipShared
  else:
    raise newException(PartitionPlanReadError,
      "unknown SharedInputPolicy value: " & s)

proc actionToJson(a: ShardBuildAction): JsonNode =
  result = %*{
    "id": uint64(a.id),
    "commandStatsId": a.commandStatsId,
    "deps": newJArray()
  }
  for d in a.deps:
    result["deps"].add(%uint64(d))

proc edgeToJson(e: ShardTestEdge): JsonNode =
  result = %*{
    "id": uint64(e.id),
    "selector": e.selector,
    "historyKey": e.historyKey,
    "buildDeps": newJArray()
  }
  for d in e.buildDeps:
    result["buildDeps"].add(%uint64(d))

proc assignmentToJson(a: PartitionAssignment): JsonNode =
  %*{
    "root": uint64(a.root),
    "shardIndex": a.shardIndex,
    "explainedCostNs": durationNs(a.explainedCost)
  }

proc planToJson(plan: PartitionPlan): JsonNode =
  result = %*{
    "shardCount": plan.shardCount,
    "boundNs": durationNs(plan.bound),
    "assignments": newJArray(),
    "perShardCostNs": newJArray()
  }
  for a in plan.assignments:
    result["assignments"].add(assignmentToJson(a))
  for c in plan.perShardCost:
    result["perShardCostNs"].add(%durationNs(c))

proc metaToJson(meta: ShardPlanRequest): JsonNode =
  result = %*{
    "shardCount": meta.shardCount,
    "targetSelectors": meta.targetSelectors,
    "policy": policyToString(meta.policy),
    "historyDir": meta.historyDir,
    "estimateDbPath": meta.estimateDbPath,
    "estimateScope": meta.estimateScope,
    "fallbackBuildCostNs": meta.fallbackBuildCostNs,
    "fallbackTestCostNs": meta.fallbackTestCostNs,
    "refinementPasses": meta.refinementPasses,
    "buildActions": newJArray(),
    "testEdges": newJArray()
  }
  for a in meta.buildActions:
    result["buildActions"].add(actionToJson(a))
  for e in meta.testEdges:
    result["testEdges"].add(edgeToJson(e))

proc shardPlanJson(plan: ShardPlan; meta: ShardPlanRequest): JsonNode =
  %*{
    "schemaId": PartitionPlanSchemaId,
    "meta": metaToJson(meta),
    "plan": planToJson(plan.partition),
    "degraded": plan.degraded,
    "unknownBuildCount": plan.unknownBuildCount,
    "unknownTestCount": plan.unknownTestCount
  }

proc writePartitionPlanJson*(plan: ShardPlan; path: string;
                             meta: ShardPlanRequest) =
  ## Writes the plan (with the originating meta) as JSON.  The schema id
  ## is captured at the top of the document for the M2 ``--plan-from``
  ## consumer's compatibility check.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, shardPlanJson(plan, meta).pretty() & "\n")

proc readSeqU64(node: JsonNode): seq[NodeId] =
  if node.kind != JArray:
    raise newException(PartitionPlanReadError,
      "expected array of node ids, got " & $node.kind)
  for item in node.elems:
    if item.kind != JInt:
      raise newException(PartitionPlanReadError,
        "node id must be an integer")
    result.add(nodeId(uint64(item.getInt())))

proc readSeqString(node: JsonNode): seq[string] =
  if node.kind != JArray:
    raise newException(PartitionPlanReadError,
      "expected array of strings")
  for item in node.elems:
    if item.kind != JString:
      raise newException(PartitionPlanReadError,
        "expected string element")
    result.add(item.getStr())

proc readMeta(node: JsonNode): ShardPlanRequest =
  if node.kind != JObject:
    raise newException(PartitionPlanReadError,
      "meta block must be an object")
  result.shardCount = node["shardCount"].getInt()
  result.targetSelectors = readSeqString(node["targetSelectors"])
  result.policy = parsePolicy(node["policy"].getStr())
  result.historyDir = node["historyDir"].getStr()
  result.estimateDbPath = node["estimateDbPath"].getStr()
  result.estimateScope = node["estimateScope"].getStr()
  result.fallbackBuildCostNs = node["fallbackBuildCostNs"].getBiggestInt().int64
  result.fallbackTestCostNs = node["fallbackTestCostNs"].getBiggestInt().int64
  result.refinementPasses = node["refinementPasses"].getInt()
  for actionNode in node["buildActions"].elems:
    var a = ShardBuildAction(
      id: nodeId(uint64(actionNode["id"].getInt())),
      commandStatsId: actionNode["commandStatsId"].getStr(),
      deps: readSeqU64(actionNode["deps"])
    )
    result.buildActions.add(a)
  for edgeNode in node["testEdges"].elems:
    var e = ShardTestEdge(
      id: nodeId(uint64(edgeNode["id"].getInt())),
      selector: edgeNode["selector"].getStr(),
      historyKey: edgeNode["historyKey"].getStr(),
      buildDeps: readSeqU64(edgeNode["buildDeps"])
    )
    result.testEdges.add(e)

proc readPlan(node: JsonNode): PartitionPlan =
  if node.kind != JObject:
    raise newException(PartitionPlanReadError,
      "plan block must be an object")
  result.shardCount = node["shardCount"].getInt()
  result.bound = nsToDuration(node["boundNs"].getBiggestInt().int64)
  for a in node["assignments"].elems:
    result.assignments.add(PartitionAssignment(
      root: nodeId(uint64(a["root"].getInt())),
      shardIndex: a["shardIndex"].getInt(),
      explainedCost: nsToDuration(a["explainedCostNs"].getBiggestInt().int64)
    ))
  for c in node["perShardCostNs"].elems:
    result.perShardCost.add(nsToDuration(c.getBiggestInt().int64))

proc readPartitionPlanJson*(path: string):
    tuple[plan: ShardPlan, meta: ShardPlanRequest] =
  ## Inverse of ``writePartitionPlanJson``.  Raises
  ## ``PartitionPlanReadError`` on schema-version mismatch or any
  ## structurally invalid field; never silently coerces.
  if not fileExists(path):
    raise newException(PartitionPlanReadError,
      "partition plan file not found: " & path)
  let raw = readFile(path)
  let parsed = try:
    parseJson(raw)
  except JsonParsingError as exc:
    raise newException(PartitionPlanReadError,
      "partition plan JSON could not be parsed: " & exc.msg)
  if parsed.kind != JObject:
    raise newException(PartitionPlanReadError,
      "partition plan root must be a JSON object")
  if not parsed.hasKey("schemaId"):
    raise newException(PartitionPlanReadError,
      "partition plan is missing the schemaId field")
  let schemaId = parsed["schemaId"].getStr()
  if schemaId != PartitionPlanSchemaId:
    raise newException(PartitionPlanReadError,
      "partition plan schema mismatch: expected " &
      PartitionPlanSchemaId & ", got " & schemaId)
  result.meta = readMeta(parsed["meta"])
  result.plan.partition = readPlan(parsed["plan"])
  result.plan.degraded = parsed["degraded"].getBool()
  result.plan.unknownBuildCount = parsed["unknownBuildCount"].getInt()
  result.plan.unknownTestCount = parsed["unknownTestCount"].getInt()

# Re-export the underlying types from runquota_partition so callers
# need only ``import repro_cli_support/partition`` to consume the full
# API surface — including ``PartitionPlan``, ``PartitionAssignment``,
# and ``SharedInputPolicy``.
export runquota_partition
