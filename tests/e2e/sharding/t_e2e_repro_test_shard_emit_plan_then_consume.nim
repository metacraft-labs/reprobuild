## CI-Sharding M2 verification — two-step CI flow.
##
## ``--emit-partition-plan=PATH`` writes the planner output, exits 0,
## and does NOT build or run anything.  A subsequent invocation with
## ``--plan-from=PATH`` honours the plan exactly — the assignments
## the worker sees are identical to those the planner produced.

import std/[json, os, sets, strutils, tables, tempfiles, unittest]

import sharding_test_support

const ShardCount = 4

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

suite "CI-Sharding M2 — emit-plan-then-consume":

  test "t_e2e_repro_test_shard_emit_plan_then_consume":
    let workspace = createTempDir("repro-m2-emit-plan-", "")
    defer: removeDir(workspace)

    let estimateDb = workspace / "learned-estimates.sqlite3"
    populateEstimateDb(estimateDb, "reprobuild", [
      ("cmd-1", 600_000_000'i64),
      ("cmd-2", 500_000_000'i64),
      ("cmd-3", 300_000_000'i64),
      ("cmd-4", 200_000_000'i64),
      ("cmd-5", 100_000_000'i64),
      ("cmd-6",  50_000_000'i64),
    ])
    let historyDir = workspace / "history"
    writeTestDurationsJson(historyDir, [
      ("fixture::test1", 100),
      ("fixture::test2", 200),
      ("fixture::test3", 150),
      ("fixture::test4", 250),
      ("fixture::test5", 300),
      ("fixture::test6", 400),
    ])

    let fixturePath = workspace / "fixture.json"
    let spec = makeFixtureSpec(workspace, estimateDb, historyDir)
    writeFixture(fixturePath, spec)

    # Step 1 — planner job: emit plan, exit 0, NOTHING runs.
    let planPath = workspace / "plan.json"
    let plannerArgs = @["test",
      "--shard", "1/" & $ShardCount,
      "--fixture-from=" & fixturePath,
      "--emit-partition-plan=" & planPath]
    let plannerRes = runRepro(plannerArgs, workspace)
    if plannerRes.code != 0:
      checkpoint(plannerRes.output)
    check plannerRes.code == 0
    check fileExists(planPath)
    # No shard report was written — emit-and-exit does NOT run the
    # build / test phases.
    check not fileExists(workspace / "test-logs" / "shard-1-of-4.json")

    let planDoc = parseJson(readFile(planPath))
    check planDoc["schemaId"].getStr() == "reprobuild.partition-plan.v1"

    # Map root id -> shardIndex from the emitted plan.
    var emittedAssignment = initTable[int, int]()
    for a in planDoc["plan"]["assignments"].elems:
      emittedAssignment[a["root"].getInt()] = a["shardIndex"].getInt()

    # Step 2 — workers: ``--plan-from=plan.json`` for every shard.
    # Each shard's ``assigned_selectors`` must match the plan exactly.
    var byShardSelectors: Table[int, HashSet[string]]
    for k in 1 .. ShardCount:
      let reportPath = workspace / ("worker-shard-" & $k & ".json")
      let res = runRepro(@["test",
        "--shard", $k & "/" & $ShardCount,
        "--fixture-from=" & fixturePath,
        "--plan-from=" & planPath,
        "--report=" & reportPath],
        workspace)
      if res.code != 0:
        checkpoint(res.output)
      check res.code == 0
      let report = readShardReport(reportPath)
      var observed = initHashSet[string]()
      for n in report["assigned_selectors"].elems:
        observed.incl(n.getStr())
      byShardSelectors[k] = observed

    # Cross-check: every (rootId -> shardIndex) in the emitted plan
    # MUST show up in the worker's assigned selectors for that shard.
    # Convert root ids to selectors via the fixture spec.
    var idToSelector = initTable[int, string]()
    for e in spec.edges:
      idToSelector[e.id] = e.selector
    for rootId, shardIdx in emittedAssignment:
      let sel = idToSelector[rootId]
      check sel in byShardSelectors[shardIdx]
