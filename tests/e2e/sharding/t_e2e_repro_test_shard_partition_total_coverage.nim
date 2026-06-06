## CI-Sharding M2 verification — total-coverage property.
##
## Runs ``repro test --shard k/N`` for every k in 1..N against a 6-edge
## fixture and asserts:
##
##   1. The union of executed tests across all shards equals the full
##      test set.
##   2. No test runs on more than one shard.
##   3. Every shard exits 0 (the fixture's test commands are all
##      ``/bin/true``).

import std/[json, os, sets, strutils, tables, tempfiles, unittest]

import sharding_test_support

const ShardCount = 4

proc makeFixtureSpec(workspace: string): FixtureSpec =
  ## Six test edges, each backed by exactly one build action.  Both
  ## the action ``buildCmd`` and the edge ``runCmd`` invoke an in-tree
  ## ``/bin/sh`` stub that exits 0 — the test asserts shard coverage,
  ## not actual build/run behaviour.
  let trueScript = workspace / "noop.sh"
  writeTrueScript(trueScript)
  result.fallbackBuildCostNs = 1_000_000_000'i64
  result.fallbackTestCostNs = 1_000_000_000'i64
  result.historyDir = ""
  result.estimateDbPath = ""
  result.estimateScope = ""
  result.policy = "independent"
  for i in 1 .. 6:
    result.actions.add(FixtureActionSpec(
      id: 100 + i,
      commandStatsId: "cmd-" & $i,
      deps: @[],
      buildCmd: @[trueScript]))
    result.edges.add(FixtureEdgeSpec(
      id: 200 + i,
      selector: "fixture::test" & $i,
      historyKey: "fixture::test" & $i,
      buildDeps: @[100 + i],
      testName: "fixture-test-" & $i,
      testCmd: @[trueScript]))

suite "CI-Sharding M2 — partition total coverage":

  test "t_e2e_repro_test_shard_partition_total_coverage":
    let workspace = createTempDir("repro-m2-coverage-", "")
    defer: removeDir(workspace)

    let fixturePath = workspace / "fixture.json"
    let spec = makeFixtureSpec(workspace)
    writeFixture(fixturePath, spec)

    var unionOfTests = initHashSet[string]()
    var perShardTests: Table[int, HashSet[string]]
    var fullSet = initHashSet[string]()
    for e in spec.edges:
      fullSet.incl(e.selector)

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
      check report["shard"].getInt() == k
      check report["shardCount"].getInt() == ShardCount

      var shardTests = initHashSet[string]()
      for n in report["assigned_selectors"].elems:
        let sel = n.getStr()
        shardTests.incl(sel)
        # No test should appear on more than one shard.
        check (sel notin unionOfTests)
        unionOfTests.incl(sel)
      perShardTests[k] = shardTests

    # Union across all shards must equal the full test set.
    check unionOfTests == fullSet

    # Sanity: every shard ran at least one or could legitimately have
    # zero tests.  With 6 tests across 4 shards, each shard gets at
    # least 1 under the round-robin slice path used by the cold-cache
    # fallback (the fixture deliberately has no cost data, so the
    # planner emits a slice plan).
    var assignedCount = 0
    for k in 1 .. ShardCount:
      assignedCount += perShardTests[k].len
    check assignedCount == spec.edges.len
