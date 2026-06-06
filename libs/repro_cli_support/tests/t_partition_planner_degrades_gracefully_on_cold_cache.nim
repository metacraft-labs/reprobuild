## CI-Sharding M1 verification — cold-cache degradation.
##
## Same fixture as t_partition_planner_reads_runquota_estimates but
## with no learned-estimate DB at all (and an empty history dir).  The
## planner must emit a count-balanced plan tagged ``degraded: true``
## with ``unknownBuildCount > 0``.

import std/[os, times, unittest]

import repro_cli_support/partition

const TmpDir = "build/test-tmp/m1-partition-planner-cold-cache"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

suite "M1 partition planner — cold cache":

  test "empty learned-estimate store yields a degraded count-balanced plan":
    resetTmp()
    let dbPath = TmpDir / "no-estimates.sqlite3"  # intentionally absent
    let historyDir = TmpDir / "no-history"
    createDir(historyDir)
    # No test-durations.json is written, so the test sidecar lookup
    # also misses for every edge.

    let buildActions = @[
      ShardBuildAction(id: nodeId(101), commandStatsId: "cmd-a", deps: @[]),
      ShardBuildAction(id: nodeId(102), commandStatsId: "cmd-b", deps: @[]),
      ShardBuildAction(id: nodeId(103), commandStatsId: "cmd-c", deps: @[]),
    ]
    let testEdges = @[
      ShardTestEdge(id: nodeId(201), selector: "fixture::a",
        historyKey: "fixture::a", buildDeps: @[nodeId(101)]),
      ShardTestEdge(id: nodeId(202), selector: "fixture::b",
        historyKey: "fixture::b", buildDeps: @[nodeId(102)]),
      ShardTestEdge(id: nodeId(203), selector: "fixture::c",
        historyKey: "fixture::c", buildDeps: @[nodeId(103)]),
    ]
    let req = ShardPlanRequest(
      shardCount: 2,
      targetSelectors: @[],
      policy: sipIndependent,
      historyDir: historyDir,
      estimateDbPath: dbPath,
      estimateScope: "reprobuild",
      fallbackBuildCostNs: 1_000_000'i64,  # 1 ms — uniform fallback
      fallbackTestCostNs: 2_000_000'i64,
      buildActions: buildActions,
      testEdges: testEdges,
      refinementPasses: DefaultRefinementPasses,
    )

    let plan = planTestShards(req)

    check plan.degraded == true
    check plan.unknownBuildCount > 0
    check plan.unknownTestCount > 0

    check plan.partition.shardCount == 2
    check plan.partition.assignments.len == 3

    # Count-balanced (round-robin slice): 3 edges across 2 shards
    # gives shard sizes {2, 1}.  ``--partition-strategy slice``
    # assigns roots in original order, so ``201`` goes to shard 1,
    # ``202`` to shard 2, ``203`` to shard 1.
    check plan.partition.assignments[0].shardIndex == 1
    check plan.partition.assignments[1].shardIndex == 2
    check plan.partition.assignments[2].shardIndex == 1

    # Per-shard cost is uniform * count — proves the slice path was
    # taken rather than the LPT path (LPT with weight==fallback would
    # also produce a 2/1 split, but with potentially different root
    # ordering on the heavier shard).
    let fb = req.fallbackTestCostNs
    check plan.partition.perShardCost[0].inNanoseconds == fb * 2
    check plan.partition.perShardCost[1].inNanoseconds == fb * 1
