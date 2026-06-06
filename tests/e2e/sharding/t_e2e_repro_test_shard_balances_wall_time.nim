## CI-Sharding M2 verification — wall-time balance property.
##
## Populates the planner's RunQuota learned-estimate companion DB and a
## codetracer ``test-durations.json`` sidecar, then runs ``repro test
## --shard k/4`` for each shard and asserts that the predicted per-shard
## costs (the planner's output) are within 30% of the mean.  The M2
## spec target is 20%; the M2 milestone block loosens it to 30% for the
## tiny fixture sizes and planner overhead noise — that loosened
## threshold is the contract this test enforces.

import std/[math, json, os, sets, strutils, tables, tempfiles, unittest]

import sharding_test_support

const ShardCount = 4

# Eight test edges with deliberately heterogeneous costs.  The optimal
# split across 4 shards groups the heavy edges with the light edges so
# every shard's cost approximates the mean of ``sum(weights) / N``.
#
# Total weight =
#   build:  300 + 250 + 200 + 150 + 100 +  80 +  50 +  20 = 1150 ms
#   tests:  500 + 400 + 300 + 200 + 150 + 100 +  50 +  10 = 1710 ms
#   joint:  800 + 650 + 500 + 350 + 250 + 180 + 100 +  30 = 2860 ms
# Mean per shard: 715 ms.  Within 30%: 500 .. 930 ms.
const
  BuildCostsMs: array[8, int] = [300, 250, 200, 150, 100, 80, 50, 20]
  TestCostsMs:  array[8, int] = [500, 400, 300, 200, 150, 100, 50, 10]

proc makeFixtureSpec(workspace: string;
                     estimateDb, historyDir: string): FixtureSpec =
  let trueScript = workspace / "noop.sh"
  writeTrueScript(trueScript)
  result.fallbackBuildCostNs = 1_000_000_000'i64
  result.fallbackTestCostNs = 1_000_000_000'i64
  result.historyDir = historyDir
  result.estimateDbPath = estimateDb
  result.estimateScope = "reprobuild"
  result.policy = "independent"
  for i in 0 ..< 8:
    result.actions.add(FixtureActionSpec(
      id: 100 + i,
      commandStatsId: "cmd-" & $(i + 1),
      deps: @[],
      buildCmd: @[trueScript]))
    result.edges.add(FixtureEdgeSpec(
      id: 200 + i,
      selector: "fixture::test" & $(i + 1),
      historyKey: "fixture::test" & $(i + 1),
      buildDeps: @[100 + i],
      testName: "fixture-test-" & $(i + 1),
      testCmd: @[trueScript]))

suite "CI-Sharding M2 — wall-time balance":

  test "t_e2e_repro_test_shard_balances_wall_time":
    let workspace = createTempDir("repro-m2-balance-", "")
    defer: removeDir(workspace)

    let estimateDb = workspace / "learned-estimates.sqlite3"
    var durations: seq[tuple[id: string; ns: int64]]
    for i in 0 ..< 8:
      durations.add((id: "cmd-" & $(i + 1),
                     ns: int64(BuildCostsMs[i]) * 1_000_000'i64))
    populateEstimateDb(estimateDb, "reprobuild", durations)

    let historyDir = workspace / "history"
    var historyEntries: seq[tuple[key: string; ms: int]]
    for i in 0 ..< 8:
      historyEntries.add((key: "fixture::test" & $(i + 1),
                          ms: TestCostsMs[i]))
    writeTestDurationsJson(historyDir, historyEntries)

    let fixturePath = workspace / "fixture.json"
    let spec = makeFixtureSpec(workspace, estimateDb, historyDir)
    writeFixture(fixturePath, spec)

    var predicted: seq[int64] = @[]
    for k in 1 .. ShardCount:
      let reportPath = workspace / ("shard-" & $k & ".json")
      let res = runRepro(@["test",
        "--shard", $k & "/" & $ShardCount,
        "--fixture-from=" & fixturePath,
        "--report=" & reportPath],
        workspace)
      if res.code != 0:
        checkpoint(res.output)
      check res.code == 0

      let report = readShardReport(reportPath)
      # The plan must NOT be degraded — we populated both data sources.
      check report["degraded_plan"].getBool() == false
      check report["unknown_build_count"].getInt() == 0
      check report["unknown_test_count"].getInt() == 0
      predicted.add(report["predicted_shard_cost_ns"].getBiggestInt().int64)

    # 30% threshold against the mean.
    var total: int64 = 0
    for p in predicted:
      total += p
    let mean = float(total) / float(predicted.len)
    var maxCost: int64 = 0
    var minCost: int64 = high(int64)
    for p in predicted:
      if p > maxCost: maxCost = p
      if p < minCost: minCost = p
    let maxFromMean = abs(float(maxCost) - mean) / mean
    let minFromMean = abs(float(minCost) - mean) / mean

    if maxFromMean > 0.30 or minFromMean > 0.30:
      checkpoint("predicted per-shard costs (ns): " & $predicted)
      checkpoint("mean: " & $mean & " maxDelta: " & $maxFromMean &
                 " minDelta: " & $minFromMean)
    check maxFromMean <= 0.30
    check minFromMean <= 0.30
