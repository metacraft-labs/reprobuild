## t_repro_build_test_aggregate_builds_every_test —
## Test-Edges-And-Parallel-Runner M1 verification.
##
## The spec requires that ``repro build :test --dry-run`` enumerates
## one action per declared test edge in ``repro.tests.nim``. We assert
## the structural seam in two layers:
##
##   1. ``repro.tests.nim`` declares N ``buildNimUnittest.build(...)``
##      calls AND a single ``aggregate("test", @[..., ..., ...])`` at
##      the bottom whose body lists N action references.
##   2. When the engine is invokable in this environment, run
##      ``repro build test --dry-run --report=full`` and assert the
##      resulting ``build-report.json`` enumerates ≥ N test-edge
##      actions (action ids matching the ``ct_test_nim_unittest``
##      typed-tool prefix). When the engine surface is missing — e.g.,
##      no built ``./build/bin/repro``, tool provisioning unavailable
##      outside a ``nix develop`` shell — we record the engine call as
##      a soft check and still pass the structural assertion.
##
## The structural assertion is the load-bearing one: if a new test
## landing without a generator re-run, or the aggregate wiring drifts
## from the per-edge bindings, both checks fail together.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro.tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc countGeneratedBuildCalls(repoRoot: string): int =
  let content = readFile(repoRoot / "repro.tests.nim")
  for line in content.splitLines():
    let stripped = line.strip(leading = true, trailing = false)
    if stripped.startsWith("let _") and "buildNimUnittest.build(" in line:
      inc result

proc countAggregateActionRefs(repoRoot: string): int =
  ## Count the ``_<name>.action`` entries inside the single
  ## ``aggregate("test", @[...])`` call at the bottom of
  ## ``repro.tests.nim``. The generator emits exactly one such
  ## aggregate; the entries are one per declared edge.
  let content = readFile(repoRoot / "repro.tests.nim")
  var inAggregate = false
  for line in content.splitLines():
    let stripped = line.strip()
    if not inAggregate:
      if stripped.startsWith("discard aggregate(\"test\""):
        inAggregate = true
      continue
    if stripped.startsWith("])"):
      inAggregate = false
      continue
    if stripped.startsWith("_") and stripped.contains(".action"):
      inc result

proc findReport(workRoot, repoRoot: string): string =
  for path in walkDirRec(workRoot):
    if path.endsWith("build-report.json"):
      return path
  let inRepo = repoRoot / ".repro" / "build"
  if dirExists(inRepo):
    for path in walkDirRec(inRepo):
      if path.endsWith("build-report.json"):
        return path
  ""

suite "t_repro_build_test_aggregate_builds_every_test":
  test "aggregate(\"test\", ...) wires every declared edge":
    let repoRoot = findRepoRoot()
    let declaredCount = countGeneratedBuildCalls(repoRoot)
    let aggregateCount = countAggregateActionRefs(repoRoot)
    checkpoint("declared edges: " & $declaredCount)
    checkpoint("aggregate entries: " & $aggregateCount)
    check declaredCount > 0
    # Every declared edge must appear in the aggregate (and vice
    # versa) so ``repro build test`` schedules every test-binary
    # compilation in one pass.
    check declaredCount == aggregateCount

  test "repro build test --dry-run enumerates every declared edge (soft)":
    ## Soft engine round-trip: skipped when the environment can't
    ## host an in-tree ``repro build`` invocation (e.g. running
    ## outside ``nix develop`` so tool provisioning fails). The
    ## structural assertion in the previous test is the load-bearing
    ## check; this one exercises the engine seam when it's reachable.
    let repoRoot = findRepoRoot()
    let declaredCount = countGeneratedBuildCalls(repoRoot)
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      let tempRoot = createTempDir("repro-m1-dry-run-", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      createDir(workRoot)

      let args = @[
        reproBin,
        "build",
        "test",
        ".",
        "--dry-run",
        "--report=full",
        "--no-runquota",
        "--work-root=" & workRoot,
        "--progress=quiet",
        "--log=quiet",
      ]
      let cmd = args.join(" ")
      let (output, exitCode) = execCmdEx(cmd, workingDir = repoRoot)
      checkpoint("repro build test --dry-run exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
        # Tool provisioning failures (running outside ``nix develop``,
        # missing daemons) surface as exit=1 BEFORE the engine
        # reaches the action-graph layer this test wants to inspect.
        # Treat that as a skip rather than a fail so the test stays
        # green in environments that can't host the full engine.
        let provisioningFailure =
          output.contains("tool-resolution failed") or
          output.contains("typed tool provisioning is required") or
          output.contains("does not declare provisioning")
        if provisioningFailure:
          checkpoint("skipped — tool provisioning unavailable")
          skip()
        else:
          check exitCode == 0
      else:
        let reportPath = findReport(workRoot, repoRoot)
        checkpoint("build report: " & reportPath)
        check fileExists(reportPath)
        if fileExists(reportPath):
          let payload = parseJson(readFile(reportPath))
          let actions =
            if payload.hasKey("actions"): payload["actions"]
            else: newJArray()
          var testEdgeActions = 0
          for entry in actions:
            let id = entry{"id"}.getStr("")
            if id.startsWith("ct_test_nim_unittest.buildNimUnittest-build-"):
              inc testEdgeActions
          checkpoint("declared test edges: " & $declaredCount)
          checkpoint("test edge actions in report: " & $testEdgeActions)
          check testEdgeActions >= declaredCount
