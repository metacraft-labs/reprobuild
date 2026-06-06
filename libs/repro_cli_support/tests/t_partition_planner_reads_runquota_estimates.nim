## CI-Sharding M1 verification — RunQuota estimate ingestion.
##
## Builds a fixture with three known-cost actions, populates a SQLite
## learned-estimate DB, asks ``planTestShards`` to split them across two
## shards, and asserts the resulting plan distributes weight against
## the brute-force optimum on a three-tests / two-shards instance.
##
## The brute-force optimum partitions the three roots ``{a, b, c}``
## with costs ``{300, 200, 100}`` ms into ``{a}`` and ``{b, c}`` —
## a min-max of 300 ms.  The planner under test must hit that exactly
## (the LPT bound is tight for n=3, N=2 with this distribution).

import std/[json, math, os, osproc, strutils, tables, times, unittest]

import repro_cli_support/partition

const TmpDir = "build/test-tmp/m1-partition-planner-reads-runquota"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc populateEstimateDb(path: string) =
  ## Writes three rows into the planner's learned-estimate sidecar
  ## table.  Each row is keyed by command stats id and carries a
  ## wall-time in nanoseconds.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  if fileExists(path):
    removeFile(path)
  let sqlText = """
    create table if not exists learned_estimate_durations (
      scope text not null,
      command_stats_id text not null,
      wall_time_ns integer not null,
      sample_count integer not null default 1,
      updated_unix_millis integer not null default 0,
      primary key (scope, command_stats_id)
    );
    insert into learned_estimate_durations
      (scope, command_stats_id, wall_time_ns) values
      ('reprobuild', 'cmd-a', 300000000),
      ('reprobuild', 'cmd-b', 200000000),
      ('reprobuild', 'cmd-c', 100000000);
  """
  let output = execProcess("sqlite3", args = [path, sqlText],
      options = {poUsePath, poStdErrToStdOut})
  # sqlite3 prints nothing on success; any output indicates an error.
  doAssert output.len == 0, "sqlite3 fixture setup failed: " & output

proc bruteForceOptimum(weightsNs: openArray[int64];
                       shardCount: int): int64 =
  ## Returns the smallest possible ``max_k W(k)`` over every assignment
  ## of ``weightsNs`` to ``shardCount`` shards.  For the M1 fixture
  ## sizes (3 weights x 2 shards == 8 assignments) the exhaustive
  ## search is the cheapest correct option.
  result = high(int64)
  let n = weightsNs.len
  let total = shardCount.int ^ n
  for code in 0 ..< total:
    var loads = newSeq[int64](shardCount)
    var c = code
    for i in 0 ..< n:
      let shard = c mod shardCount
      c = c div shardCount
      loads[shard] += weightsNs[i]
    var localMax: int64 = 0
    for v in loads:
      if v > localMax: localMax = v
    if localMax < result:
      result = localMax

suite "M1 partition planner — RunQuota estimate ingestion":

  test "planner ingests populated estimates and matches the brute-force optimum":
    resetTmp()
    let dbPath = TmpDir / "learned-estimates.sqlite3"
    populateEstimateDb(dbPath)

    # Three build actions, each whose only "closure" is itself; three
    # test edges that depend on one build action apiece.  Under
    # ``sipIndependent`` the per-edge cost is build-cost + test-cost.
    let buildActions = @[
      ShardBuildAction(id: nodeId(101), commandStatsId: "cmd-a", deps: @[]),
      ShardBuildAction(id: nodeId(102), commandStatsId: "cmd-b", deps: @[]),
      ShardBuildAction(id: nodeId(103), commandStatsId: "cmd-c", deps: @[]),
    ]
    let testEdges = @[
      ShardTestEdge(id: nodeId(201), selector: "fixture::a",
        historyKey: "", buildDeps: @[nodeId(101)]),
      ShardTestEdge(id: nodeId(202), selector: "fixture::b",
        historyKey: "", buildDeps: @[nodeId(102)]),
      ShardTestEdge(id: nodeId(203), selector: "fixture::c",
        historyKey: "", buildDeps: @[nodeId(103)]),
    ]
    let req = ShardPlanRequest(
      shardCount: 2,
      targetSelectors: @[],
      policy: sipIndependent,
      historyDir: "",
      estimateDbPath: dbPath,
      estimateScope: "reprobuild",
      fallbackBuildCostNs: 1_000_000_000'i64,  # 1 s — deliberately huge so
        # an unintended fallback hit corrupts the optimum and fails
        # the assertion.
      fallbackTestCostNs: 0'i64,
      buildActions: buildActions,
      testEdges: testEdges,
      refinementPasses: DefaultRefinementPasses,
    )

    let plan = planTestShards(req)

    check plan.degraded == false
    check plan.unknownBuildCount == 0
    check plan.unknownTestCount == 3
      # test history is intentionally empty; only build estimates are
      # populated in this test.

    check plan.partition.shardCount == 2
    check plan.partition.assignments.len == 3

    let optimumNs = bruteForceOptimum(
      [300_000_000'i64, 200_000_000'i64, 100_000_000'i64], 2)
    check optimumNs == 300_000_000'i64

    var maxShardNs: int64 = 0
    for cost in plan.partition.perShardCost:
      let ns = cost.inNanoseconds
      if ns > maxShardNs:
        maxShardNs = ns
    check maxShardNs == optimumNs

    # Sanity: every assignment lands on a real shard index.
    for a in plan.partition.assignments:
      check a.shardIndex >= 1
      check a.shardIndex <= 2
