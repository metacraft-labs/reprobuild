## CI-Sharding M1 verification — partition plan JSON round-trip.
##
## Writes a populated ``ShardPlan`` to disk via ``writePartitionPlanJson``
## and reads it back via ``readPartitionPlanJson``.  The round-tripped
## value must equal the original plan and meta byte-for-byte at the
## logical level (nanoseconds, ids, ordering).
##
## A second case manually corrupts the ``schemaId`` field and asserts
## the reader raises ``PartitionPlanReadError`` with a clear message.

import std/[json, os, strutils, times, unittest]

import repro_cli_support/partition

const TmpDir = "build/test-tmp/m1-partition-plan-json-round-trip"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc samePlan(a, b: PartitionPlan): bool =
  if a.shardCount != b.shardCount: return false
  if a.bound.inNanoseconds != b.bound.inNanoseconds: return false
  if a.assignments.len != b.assignments.len: return false
  if a.perShardCost.len != b.perShardCost.len: return false
  for i in 0 ..< a.assignments.len:
    let x = a.assignments[i]
    let y = b.assignments[i]
    if uint64(x.root) != uint64(y.root): return false
    if x.shardIndex != y.shardIndex: return false
    if x.explainedCost.inNanoseconds != y.explainedCost.inNanoseconds:
      return false
  for i in 0 ..< a.perShardCost.len:
    if a.perShardCost[i].inNanoseconds != b.perShardCost[i].inNanoseconds:
      return false
  true

proc sameMeta(a, b: ShardPlanRequest): bool =
  if a.shardCount != b.shardCount: return false
  if a.targetSelectors != b.targetSelectors: return false
  if a.policy != b.policy: return false
  if a.historyDir != b.historyDir: return false
  if a.estimateDbPath != b.estimateDbPath: return false
  if a.estimateScope != b.estimateScope: return false
  if a.fallbackBuildCostNs != b.fallbackBuildCostNs: return false
  if a.fallbackTestCostNs != b.fallbackTestCostNs: return false
  if a.refinementPasses != b.refinementPasses: return false
  if a.buildActions.len != b.buildActions.len: return false
  if a.testEdges.len != b.testEdges.len: return false
  for i in 0 ..< a.buildActions.len:
    let x = a.buildActions[i]
    let y = b.buildActions[i]
    if uint64(x.id) != uint64(y.id): return false
    if x.commandStatsId != y.commandStatsId: return false
    if x.deps.len != y.deps.len: return false
    for k in 0 ..< x.deps.len:
      if uint64(x.deps[k]) != uint64(y.deps[k]): return false
  for i in 0 ..< a.testEdges.len:
    let x = a.testEdges[i]
    let y = b.testEdges[i]
    if uint64(x.id) != uint64(y.id): return false
    if x.selector != y.selector: return false
    if x.historyKey != y.historyKey: return false
    if x.buildDeps.len != y.buildDeps.len: return false
    for k in 0 ..< x.buildDeps.len:
      if uint64(x.buildDeps[k]) != uint64(y.buildDeps[k]): return false
  true

suite "M1 partition plan — JSON round-trip":

  test "round-trips a populated plan losslessly":
    resetTmp()
    let path = TmpDir / "plan.json"

    let meta = ShardPlanRequest(
      shardCount: 3,
      targetSelectors: @["fixture::a", "fixture::c"],
      policy: sipIndependent,
      historyDir: "/tmp/history",
      estimateDbPath: "/tmp/estimates.sqlite3",
      estimateScope: "reprobuild",
      fallbackBuildCostNs: 7_000_000_000'i64,
      fallbackTestCostNs: 500_000_000'i64,
      refinementPasses: 8,
      buildActions: @[
        ShardBuildAction(id: nodeId(11), commandStatsId: "cmd-a",
          deps: @[nodeId(12)]),
        ShardBuildAction(id: nodeId(12), commandStatsId: "cmd-b",
          deps: @[]),
      ],
      testEdges: @[
        ShardTestEdge(id: nodeId(21), selector: "fixture::a",
          historyKey: "fixture::a", buildDeps: @[nodeId(11)]),
        ShardTestEdge(id: nodeId(22), selector: "fixture::b",
          historyKey: "fixture::b", buildDeps: @[nodeId(12)]),
      ],
    )
    let plan = ShardPlan(
      partition: PartitionPlan(
        shardCount: 3,
        assignments: @[
          PartitionAssignment(root: nodeId(21), shardIndex: 1,
            explainedCost: initDuration(nanoseconds = 400_000_000)),
          PartitionAssignment(root: nodeId(22), shardIndex: 2,
            explainedCost: initDuration(nanoseconds = 300_000_000)),
        ],
        perShardCost: @[
          initDuration(nanoseconds = 400_000_000),
          initDuration(nanoseconds = 300_000_000),
          initDuration(nanoseconds = 0),
        ],
        bound: initDuration(nanoseconds = 800_000_000),
      ),
      degraded: false,
      unknownBuildCount: 1,
      unknownTestCount: 0,
    )

    writePartitionPlanJson(plan, path, meta)
    check fileExists(path)

    let (rtPlan, rtMeta) = readPartitionPlanJson(path)

    check samePlan(rtPlan.partition, plan.partition)
    check rtPlan.degraded == plan.degraded
    check rtPlan.unknownBuildCount == plan.unknownBuildCount
    check rtPlan.unknownTestCount == plan.unknownTestCount
    check sameMeta(rtMeta, meta)

  test "round-trips a degraded cold-cache plan":
    resetTmp()
    let path = TmpDir / "degraded.json"
    let meta = ShardPlanRequest(
      shardCount: 2,
      targetSelectors: @[],
      policy: sipShared,
      historyDir: "",
      estimateDbPath: "",
      estimateScope: "",
      fallbackBuildCostNs: 1_000_000'i64,
      fallbackTestCostNs: 2_000_000'i64,
      refinementPasses: 0,
      buildActions: @[],
      testEdges: @[],
    )
    let plan = ShardPlan(
      partition: PartitionPlan(
        shardCount: 2,
        assignments: @[],
        perShardCost: @[
          initDuration(nanoseconds = 0),
          initDuration(nanoseconds = 0),
        ],
        bound: initDuration(nanoseconds = 0),
      ),
      degraded: true,
      unknownBuildCount: 5,
      unknownTestCount: 7,
    )
    writePartitionPlanJson(plan, path, meta)
    let (rt, rtMeta) = readPartitionPlanJson(path)
    check rt.degraded == true
    check rt.unknownBuildCount == 5
    check rt.unknownTestCount == 7
    check rtMeta.policy == sipShared
    check rtMeta.refinementPasses == 0

  test "schema-version mismatch surfaces a clear error":
    resetTmp()
    let goodPath = TmpDir / "good.json"
    let badPath = TmpDir / "bad.json"

    let meta = ShardPlanRequest(
      shardCount: 1,
      targetSelectors: @[],
      policy: sipShared,
      historyDir: "",
      estimateDbPath: "",
      estimateScope: "",
      fallbackBuildCostNs: 0'i64,
      fallbackTestCostNs: 0'i64,
      refinementPasses: 0,
      buildActions: @[],
      testEdges: @[],
    )
    let plan = ShardPlan(
      partition: PartitionPlan(
        shardCount: 1,
        assignments: @[],
        perShardCost: @[initDuration(nanoseconds = 0)],
        bound: initDuration(nanoseconds = 0),
      ),
      degraded: false,
      unknownBuildCount: 0,
      unknownTestCount: 0,
    )
    writePartitionPlanJson(plan, goodPath, meta)

    # Rewrite the schema id to a value the reader must reject.
    let raw = readFile(goodPath)
    let mutated = raw.replace("\"reprobuild.partition-plan.v1\"",
                              "\"reprobuild.partition-plan.v999\"")
    check mutated != raw
    writeFile(badPath, mutated)

    var caught = false
    var message = ""
    try:
      discard readPartitionPlanJson(badPath)
    except PartitionPlanReadError as exc:
      caught = true
      message = exc.msg
    check caught
    check message.contains("schema")
    check message.contains("v1")
    check message.contains("v999")
