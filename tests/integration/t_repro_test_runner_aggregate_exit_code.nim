## t_repro_test_runner_aggregate_exit_code —
## Test-Edges-And-Parallel-Runner M3 verification.
##
## Two sub-cases against a fixture of 10 protocol-aware test binaries
## where exactly one fails:
##
##   1. Default mode: the runner runs all 10, exits 1, summary
##      reports 9 passed + 1 failed.
##   2. ``REPRO_TEST_FAIL_FAST=1``: the runner stops scheduling after
##      the failing case, exits 1, summary reports total < 10 (with
##      in-flight tests still allowed to finish).
##
## The fixtures use ``ct_test_unittest_parallel`` so the runner sees
## them as protocol-aware. One fixture's test body calls ``fail()``
## explicitly; the rest pass.

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

proc writeFixtureSource(path: string; idx: int; shouldFail: bool) =
  ## Emit a tiny protocol-aware test binary. When ``shouldFail`` is
  ## true, the test body fails; otherwise it passes. Each fixture has
  ## one test case so the case count == fixture count.
  let body =
    if shouldFail:
      """
import ct_test_unittest_parallel

suite "fixture_aggregate_$IDX":
  test "case":
    check 1 == 2
""".replace("$IDX", $idx)
    else:
      """
import ct_test_unittest_parallel

suite "fixture_aggregate_$IDX":
  test "case":
    check true
""".replace("$IDX", $idx)
  writeFile(path, body)

proc compileFixture(workRoot, source, binary, shimSrc: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrc) & " " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  execCmd(cmd) == 0

proc setupFixtures(repoRoot, workRoot, binDir: string;
                   numFixtures, failingIdx: int): bool =
  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  let srcDir = workRoot / "src"
  createDir(srcDir)
  for i in 0 ..< numFixtures:
    # Pad the basename so a basic lex sort puts the failing fixture
    # roughly in the middle of the run.
    let stem = "t_fix_" & align($i, 2, '0')
    let src = srcDir / (stem & ".nim")
    writeFixtureSource(src, i, i == failingIdx)
    let outBin = binDir / addFileExt(stem, ExeExt)
    if not compileFixture(workRoot, src, outBin, shimSrc):
      return false
  true

proc runRunner(runner, binDir, summary, resultsDir: string;
               failFast: bool): tuple[exitCode: int; output: string] =
  var cmd = quoteShell(runner) & " --no-build --threads=4 --quiet" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(resultsDir)
  if failFast:
    putEnv("REPRO_TEST_FAIL_FAST", "1")
  else:
    delEnv("REPRO_TEST_FAIL_FAST")
  let (output, exitCode) = execCmdEx(cmd)
  delEnv("REPRO_TEST_FAIL_FAST")
  (exitCode, output)

proc runDefaultCase() =
  let repoRoot = findRepoRoot()
  let runner = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  check fileExists(runner)
  if not fileExists(runner):
    return

  let tempRoot = createTempDir("repro-m3-aggrc-", "")
  defer: removeDir(tempRoot)
  let binDir = tempRoot / "bin"
  createDir(binDir)

  const NumFixtures = 10
  const FailingIdx = 4
  let ok = setupFixtures(repoRoot, tempRoot, binDir,
                         NumFixtures, FailingIdx)
  check ok
  if not ok:
    return

  let summary = tempRoot / "summary.json"
  let (exitCode, output) = runRunner(runner, binDir, summary,
                                     tempRoot / "results",
                                     failFast = false)
  checkpoint("default run exit=" & $exitCode)
  if exitCode != 1:
    checkpoint(output)
  check exitCode == 1

  let doc = parseJson(readFile(summary))
  let total = doc{"summary"}{"total"}.getInt(-1)
  let passed = doc{"summary"}{"passed"}.getInt(-1)
  let failed = doc{"summary"}{"failed"}.getInt(-1)
  checkpoint("default run totals: total=" & $total &
    " passed=" & $passed & " failed=" & $failed)
  check total == NumFixtures
  check failed == 1
  check passed == NumFixtures - 1

proc runFailFastCase() =
  let repoRoot = findRepoRoot()
  let runner = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  check fileExists(runner)
  if not fileExists(runner):
    return

  let tempRoot = createTempDir("repro-m3-aggrc-ff-", "")
  defer: removeDir(tempRoot)
  let binDir = tempRoot / "bin"
  createDir(binDir)

  const NumFixtures = 10
  const FailingIdx = 4
  let ok = setupFixtures(repoRoot, tempRoot, binDir,
                         NumFixtures, FailingIdx)
  check ok
  if not ok:
    return

  let summary = tempRoot / "summary.json"
  let (exitCode, output) = runRunner(runner, binDir, summary,
                                     tempRoot / "results",
                                     failFast = true)
  checkpoint("fail-fast run exit=" & $exitCode)
  if exitCode != 1:
    checkpoint(output)
  check exitCode == 1

  let doc = parseJson(readFile(summary))
  let total = doc{"summary"}{"total"}.getInt(-1)
  let failed = doc{"summary"}{"failed"}.getInt(-1)
  checkpoint("fail-fast run totals: total=" & $total &
    " failed=" & $failed)
  # At least the failing one ran; at most all 10 were scheduled but
  # in-flight workers are allowed to finish. We assert that NEW
  # tests stopped being scheduled — i.e. ``total`` is strictly less
  # than ``NumFixtures`` (otherwise fail-fast had no effect). Each
  # fixture is fast so the in-flight cap is bounded by the worker
  # count (4).
  check failed >= 1
  check total < NumFixtures

suite "t_repro_test_runner_aggregate_exit_code":
  test "default mode: 1 failing of 10 -> exit 1, all 10 run":
    runDefaultCase()

  test "fail-fast mode: 1 failing of 10 -> exit 1, fewer than 10 run":
    runFailFastCase()
