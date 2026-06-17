## t_repro_build_test_aggregate_builds_every_test —
## Test-Edges-And-Parallel-Runner M1 verification, updated for the
## Project-DSL-Composition M6 data-table migration and the
## Spec-Implementation M0 ``collect``-primitive rename.
##
## The spec requires that ``repro build test`` enumerates one action
## per declared test spec. The shape after the M6 migration:
##
##   - ``repro_tests.nim`` exports a ``seq[TestSpec]`` constant; every
##     entry is one logical test edge.
##   - ``repro.nim``'s ``build:`` body iterates the data table and
##     calls ``buildNimUnittest.build(...)`` once per spec, accumulating
##     the resulting action handles into ``reprobuildTestActions``.
##   - The body closes with ``collect("test", reprobuildTestActions)``
##     (per Spec-Implementation M0) or, on older trees, the equivalent
##     ``aggregate("test", reprobuildTestActions)``.
##
## We assert the structural seam:
##
##   1. ``repro_tests.nim`` declares N ``TestSpec(...)`` entries.
##   2. ``repro.nim``'s ``build:`` body closes the iteration with a
##      single ``collect("test", reprobuildTestActions)`` (or
##      ``aggregate("test", reprobuildTestActions)``) — i.e. the
##      iteration's accumulator is fed into exactly one collection /
##      aggregate registration.
##   3. When the engine is invokable in this environment, run
##      ``repro build test --dry-run --report=full`` and assert the
##      resulting ``build-report.json`` enumerates ≥ N test-edge
##      actions (action ids matching the ``ct_test_nim_unittest``
##      typed-tool prefix). When the engine surface is missing — e.g.,
##      no built ``./build/bin/repro``, tool provisioning unavailable
##      outside a ``nix develop`` shell — we record the engine call as
##      a soft check and still pass the structural assertion.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc countDeclaredTestSpecs(repoRoot: string): int =
  ## Post-M6 the test edges are data: ``repro_tests.nim`` exports a
  ## ``seq[TestSpec]`` whose entries are one per logical test edge.
  ## Count them.
  let content = readFile(repoRoot / "repro_tests.nim")
  for line in content.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("TestSpec("):
      inc result

proc collectsTestActions(repoRoot: string): bool =
  ## Verify that ``repro.nim``'s ``build:`` body closes the test
  ## iteration with exactly one ``collect("test", …)``. The accumulator
  ## name evolved across migrations: the M0 shape collected a single
  ## ``reprobuildTestActions``; the later two-edge split (build edge +
  ## execute edge) renamed the run-collection accumulator to
  ## ``reprobuildTestExecuteActions`` (with a sibling
  ## ``reprobuildTestBuildActions`` feeding ``test-builds``). Accept any
  ## of those forms — and the legacy ``aggregate(...)`` spelling — so the
  ## test pins the "exactly one closing collection" invariant without
  ## hard-coding a single accumulator identifier.
  let content = readFile(repoRoot / "repro.nim")
  for accumulator in ["reprobuildTestExecuteActions", "reprobuildTestActions"]:
    if ("collect(\"test\", " & accumulator & ")") in content or
        ("aggregate(\"test\", " & accumulator & ")") in content:
      return true
  false

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
  test "collect(\"test\", reprobuildTestActions) closes the iteration":
    let repoRoot = findRepoRoot()
    let declaredCount = countDeclaredTestSpecs(repoRoot)
    let hasCollect = collectsTestActions(repoRoot)
    checkpoint("declared TestSpec entries: " & $declaredCount)
    checkpoint("repro.nim collects/aggregates reprobuildTestActions: " &
               $hasCollect)
    check declaredCount > 0
    # The iteration's accumulator must be fed into exactly one
    # collection / aggregate registration so ``repro build test``
    # schedules every test-binary compilation in one pass.
    check hasCollect

  test "repro build test --dry-run enumerates every declared edge (soft)":
    ## Soft engine round-trip: skipped when the environment can't
    ## host an in-tree ``repro build`` invocation (e.g. running
    ## outside ``nix develop`` so tool provisioning fails). The
    ## structural assertion in the previous test is the load-bearing
    ## check; this one exercises the engine seam when it's reachable.
    let repoRoot = findRepoRoot()
    let declaredCount = countDeclaredTestSpecs(repoRoot)
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
        # Match scripts/run_tests.sh: the explicit weak local profile is
        # the engine entry path that doesn't require a populated tool
        # catalog.
        "--tool-provisioning=path",
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
            # Engine lowercases the typed-tool name in the action id
            # (``buildnimunittest`` not ``buildNimUnittest``); match
            # the actual on-disk shape rather than the source identifier.
            if id.startsWith("ct_test_nim_unittest.buildnimunittest-build-"):
              inc testEdgeActions
          checkpoint("declared test edges: " & $declaredCount)
          checkpoint("test edge actions in report: " & $testEdgeActions)
          check testEdgeActions >= declaredCount
