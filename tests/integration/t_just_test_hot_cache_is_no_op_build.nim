## t_just_test_hot_cache_is_no_op_build —
## Test-Edges-And-Parallel-Runner M1 verification.
##
## After a clean ``just test``, a second ``just test`` must do zero
## ``nim c`` work for the build phase — the action cache hits
## everywhere; the only wall time is the actual test execution.
##
## Assertion strategy: invoke ``repro build test --dry-run`` twice
## (the second call must hit the cache for every action). The first
## run is preceded by a real ``repro build test`` so the action cache
## is warm; the second dry-run asserts every cached action reports
## ``cacheDecision`` other than ``cdMiss`` and ``wouldLaunch=false``.
##
## This test is expensive: building the full suite warm can take
## several minutes. Gate it on ``REPRO_M1_LONG_TEST=1`` so it does
## not fire in regular CI. To run manually::
##
##   REPRO_M1_LONG_TEST=1 nim c -r tests/integration/t_just_test_hot_cache_is_no_op_build.nim

import std/[json, os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"
const LongTestEnv = "REPRO_M1_LONG_TEST"

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

proc runHotCacheCheck() =
  let repoRoot = findRepoRoot()
  let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  check fileExists(reproBin)
  if not fileExists(reproBin):
    return

  let tempRoot = createTempDir("repro-m1-hot-cache-", "")
  defer: removeDir(tempRoot)
  let workRoot = tempRoot / "work"
  createDir(workRoot)

  proc runBuild(extraFlags: openArray[string]): tuple[output: string;
      exitCode: int] =
    var args = @[
      reproBin, "build", "test", ".",
      "--report=full",
      "--no-runquota",
      "--work-root=" & workRoot,
      "--progress=quiet",
      "--log=quiet",
    ]
    for f in extraFlags:
      args.add(f)
    let cmd = args.join(" ")
    execCmdEx(cmd, workingDir = repoRoot)

  # First run: prime the cache. We run with ``--dry-run`` removed so
  # actions actually execute and populate the action cache.
  let cold = runBuild([])
  checkpoint("cold build exit=" & $cold.exitCode)
  if cold.exitCode != 0:
    checkpoint(cold.output)
  check cold.exitCode == 0

  # Second run: same target with ``--dry-run`` — every test edge
  # should report a cache hit and ``wouldLaunch=false``.
  let hot = runBuild(["--dry-run"])
  checkpoint("hot dry-run exit=" & $hot.exitCode)
  if hot.exitCode != 0:
    checkpoint(hot.output)
  check hot.exitCode == 0

  let reportPath = findReport(workRoot, repoRoot)
  check fileExists(reportPath)
  if not fileExists(reportPath):
    return

  let payload = parseJson(readFile(reportPath))
  let actions =
    if payload.hasKey("actions"): payload["actions"] else: newJArray()
  var testEdgeActions = 0
  var wouldLaunch = 0
  var cacheMisses = 0
  for entry in actions:
    let id = entry{"id"}.getStr("")
    if not id.startsWith("ct_test_nim_unittest.buildNimUnittest-build-"):
      continue
    inc testEdgeActions
    if entry{"wouldLaunch"}.getBool(false):
      inc wouldLaunch
    let decision = entry{"cacheDecision"}.getStr("")
    if decision == "cdMiss" or decision == "miss":
      inc cacheMisses
  checkpoint("test edge actions: " & $testEdgeActions)
  checkpoint("would-launch on hot run: " & $wouldLaunch)
  checkpoint("cache misses on hot run: " & $cacheMisses)
  check testEdgeActions > 0
  check wouldLaunch == 0
  check cacheMisses == 0

suite "t_just_test_hot_cache_is_no_op_build":
  test "second build of :test aggregate is fully cache-hit (gated by REPRO_M1_LONG_TEST)":
    if getEnv(LongTestEnv) != "1":
      checkpoint("skipped — set " & LongTestEnv &
        "=1 to run the long-form hot-cache verifier")
      skip()
    else:
      runHotCacheCheck()
