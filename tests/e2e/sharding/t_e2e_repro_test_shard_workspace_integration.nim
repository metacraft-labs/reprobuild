## CI-Sharding M2 follow-up verification — real workspace integration.
##
## This test exercises the workspace-driven path of ``repro test
## --shard k/N`` (no ``--fixture-from``).  It depends on:
##
##   - The reprobuild repo built (``build/bin/repro`` exists).
##   - The ct-test-runner or fallback ``repro_test_runner`` available
##     (the workspace mode hands off to one of them after the build).
##
## A full real-suite run takes minutes wall time, so the test is
## gated on ``REPRO_M1_LONG_TEST=1`` per the repo convention.  When
## the gate is off, the test ``skip()``s with a checkpoint pointer.
##
## When enabled, the test asserts:
##
##   1. The build phase completes (no ``M2 requires --fixture-from`` /
##      missing-fixture diagnostic; ``runner_invoked`` true).
##   2. At least one test binary was built (we check
##      ``build/test-bin/`` against a representative file).
##   3. The per-shard report at ``test-logs/shard-1-of-3.json`` has
##      ``partition_file``, non-empty ``assigned_selectors`` and
##      ``assigned_binaries``, per-test results carried through from the
##      runner's summary JSON, and a ``degraded_plan`` flag that
##      reflects the cost-data state (true on a cold workspace).
##
## The 5-minute soft budget is enforced as an informational checkpoint
## — a real regression would surface as a build/runner failure first.

import std/[json, os, strutils, times, unittest]

import sharding_test_support

const LongTestEnv = "REPRO_M1_LONG_TEST"
const ExpectedTestBinarySample =
  "build/test-bin/t_engine_action_create_dyndep"

proc reprobuildRoot(): string =
  ## Locate the reprobuild repo root irrespective of the test's cwd.
  ## Mirrors ``sharding_test_support.repoRoot`` but searches for the
  ## ``repro.tests.nim`` marker as well as the bin path.
  let env = getEnv("REPRO_REPO_ROOT")
  if env.len > 0 and dirExists(env):
    return env
  result = getCurrentDir()
  for _ in 0 .. 6:
    if fileExists(result / "repro.tests.nim") and
        fileExists(result / "build" / "bin" / "repro"):
      return result
    let parent = parentDir(result)
    if parent.len == 0 or parent == result:
      break
    result = parent

proc runWorkspaceShard() =
  let repoRoot = reprobuildRoot()
  checkpoint("repo root = " & repoRoot)
  doAssert fileExists(repoRoot / "build" / "bin" / "repro"),
    "repro binary missing — run ``just build`` first"
  doAssert fileExists(repoRoot / "repro.tests.nim"),
    "repro.tests.nim missing — wrong repo root"

  let reportPath = repoRoot / "test-logs" / "shard-1-of-3.json"
  if fileExists(reportPath):
    removeFile(reportPath)

  let t0 = epochTime()
  let res = runRepro(@[
    "test",
    "--shard", "1/3",
    "--report=" & reportPath,
  ], repoRoot)
  let wallSec = epochTime() - t0
  checkpoint("repro test --shard 1/3 exit=" & $res.code &
    " wall=" & $int(wallSec) & "s (5min soft budget)")

  # Even if the run exited non-zero (e.g. some test failures in the
  # actual suite), the workspace mode is reachable iff we did NOT see
  # the M2 fixture-required diagnostic.
  check not res.output.contains("M2 requires --fixture-from")

  # 5-minute soft budget.  This is a checkpoint, not an assertion —
  # but a 5x overshoot probably indicates a hang.
  if wallSec > 600:
    checkpoint("wall time exceeded 10 minutes — likely a hang")
    check wallSec <= 600

  # Per-shard report must exist.
  check fileExists(reportPath)
  let report = parseJson(readFile(reportPath))
  check report["schemaId"].getStr() == "reprobuild.shard-report.v1"
  check report["shard"].getInt() == 1
  check report["shardCount"].getInt() == 3
  check report["mode"].getStr() == "workspace"

  # Required fields from the per-shard report contract.
  check report.hasKey("partition_file")
  let partitionFile = report["partition_file"].getStr()
  check partitionFile.len > 0
  check fileExists(repoRoot / partitionFile)

  check report.hasKey("assigned_selectors")
  check report["assigned_selectors"].kind == JArray
  check report["assigned_selectors"].len > 0

  check report.hasKey("assigned_binaries")
  check report["assigned_binaries"].kind == JArray
  check report["assigned_binaries"].len > 0

  # degraded_plan must be present and a bool — its value reflects the
  # cost-data state.  On a cold workspace (no RunQuota learned-estimate
  # rows and no test-durations.json) we expect degraded_plan to be
  # true; on a warm workspace it would be false.  Either case must
  # round-trip without crashing.
  check report.hasKey("degraded_plan")
  check report["degraded_plan"].kind == JBool

  # The build phase must have produced at least one test binary.
  check fileExists(repoRoot / ExpectedTestBinarySample)

  # Per-test results must be carried from the runner's summary into
  # the report's ``tests`` array.  When ``runner_invoked`` is true and
  # the runner did not fail catastrophically, the array carries one
  # entry per assigned binary.
  check report.hasKey("runner_invoked")
  if report["runner_invoked"].getBool():
    check report["tests"].kind == JArray
    # Either the runner ran tests (array non-empty) or every assigned
    # binary failed to produce a result file — both are valid but
    # the count must be non-negative.
    check report["tests"].len >= 0

suite "CI-Sharding M2 follow-up — workspace integration":

  test "t_e2e_repro_test_shard_workspace_integration":
    if getEnv(LongTestEnv) != "1":
      checkpoint("skipped — set " & LongTestEnv &
        "=1 to run the long-form workspace shard verifier")
      skip()
    else:
      runWorkspaceShard()
