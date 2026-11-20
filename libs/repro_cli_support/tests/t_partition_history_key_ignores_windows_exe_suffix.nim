## A test binary's shard-history key is the same on Windows as elsewhere.
##
## ``repro test --shard`` keys each whole-binary test edge's recorded
## duration (``test-durations.json``) by the test binary's file name. The
## ``NimUnittestBinary`` typed output that name comes from is the file the
## compile edge writes: ``<stem>.exe`` on Windows since the fix for
## reprobuild-pm issue 2026-11-17-windows-test-execute-edge-launches-the-
## test-binary-without-its-exe-suffix, the bare ``<stem>`` on Linux and
## macOS. Taking the file name as it stands would key a Windows run under
## ``<stem>.exe`` and lose every duration the other hosts recorded.
##
## The first case pins the key rule itself. The second drives the real
## planner over a real history file on disk and checks that an edge whose
## binary is spelled with ``.exe`` finds the duration recorded under the
## bare stem. Nothing is mocked: the history is a file in a scratch
## directory, and the learned-estimate store is simply absent, which the
## planner treats as a cold store.

import std/[json, os, times, unittest]

import repro_cli_support/partition
from repro_test_support import testCaseScratchSlug

let TmpDir = "build/test-tmp/partition-history-key-exe" /
  testCaseScratchSlug()

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

suite "shard history key of a test binary":

  test "the key drops only a trailing .exe":
    check testHistoryKeyForBinary("build/test-bin/t_probe") == "t_probe"
    check testHistoryKeyForBinary("build/test-bin/t_probe.exe") == "t_probe"
    check testHistoryKeyForBinary("t_probe.exe") == "t_probe"
    # Any other dot is part of the name, as the plain file name kept it.
    check testHistoryKeyForBinary("build/test-bin/t_probe.v2") == "t_probe.v2"
    check testHistoryKeyForBinary("build/test-bin/t_probe.v2.exe") ==
      "t_probe.v2"
    # A file called just ``.exe`` has no stem to fall back to.
    check testHistoryKeyForBinary("build/test-bin/.exe") == ".exe"
    check testHistoryKeyForBinary("") == ""
    when defined(windows):
      check testHistoryKeyForBinary("build\\test-bin\\t_probe.exe") ==
        "t_probe"

  test "the planner finds a bare-stem duration for an .exe binary":
    resetTmp()
    let historyDir = TmpDir / "history"
    createDir(historyDir)
    writeFile(historyDir / "test-durations.json",
      $(%*{"t_probe": 7}))  # milliseconds, as the history records them

    proc planFor(binaryPath: string): ShardPlan =
      planTestShards(ShardPlanRequest(
        shardCount: 1,
        policy: sipIndependent,
        historyDir: historyDir,
        estimateDbPath: "",
        fallbackBuildCostNs: 1_000_000'i64,
        fallbackTestCostNs: 2_000_000'i64,
        buildActions: @[ShardBuildAction(id: nodeId(101),
          commandStatsId: "cmd-probe", deps: @[])],
        testEdges: @[ShardTestEdge(id: nodeId(201), selector: "probe",
          historyKey: testHistoryKeyForBinary(binaryPath),
          buildDeps: @[nodeId(101)])],
        refinementPasses: DefaultRefinementPasses))

    for binaryPath in ["build/test-bin/t_probe",
                       "build/test-bin/t_probe.exe"]:
      checkpoint("binary: " & binaryPath)
      let plan = planFor(binaryPath)
      check plan.unknownTestCount == 0
      # The recorded 7 ms reached the edge, not the 2 ms fallback.
      check plan.partition.perShardCost[0].inNanoseconds >= 7_000_000'i64
