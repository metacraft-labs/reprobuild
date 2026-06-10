## t_repro_test_runner_aggregate_exit_code —
## Test-Edges-And-Parallel-Runner M3 verification.
##
## Two sub-cases against a fixture of ``NumFixtures`` protocol-aware
## test binaries where exactly one fails:
##
##   1. Default mode: the runner runs all of them, exits 1, summary
##      reports (NumFixtures-1) passed + 1 failed.
##   2. ``REPRO_TEST_FAIL_FAST=1``: the runner stops scheduling after
##      the failing case, exits 1, summary reports
##      ``total < NumFixtures`` (with in-flight tests still allowed to
##      finish).
##
## The fixtures use ``ct_test_unittest_parallel`` so the runner sees
## them as protocol-aware. One fixture's test body calls ``fail()``
## explicitly; the rest pass.
##
## Race decoupling for the fail-fast assertion
## -------------------------------------------
##
## The fail-fast assertion ``total < NumFixtures`` is robust to the
## scheduling race between queue drain and fail-fast propagation only
## when ``NumFixtures`` is well above the worker count AND the failing
## fixture sits at queue position 0 AND the passing fixtures contain a
## non-trivial body sleep. The runner sorts binaries by path, so naming
## the failing fixture ``t_fix_00`` guarantees it is the first item
## pulled. We cap the worker count at ``WorkerCount`` (2) via
## ``--threads`` so the deterministic sequence is:
##
##   * worker 1 pulls ``t_fix_00`` (failing), runs instantly, marks
##     fail-fast triggered;
##   * worker 2 pulls ``t_fix_01`` (passing), starts the body sleep;
##   * worker 1 calls ``nextCase`` → sees fail-fast → exits;
##   * worker 2 finishes its sleep, records PASS, calls ``nextCase`` →
##     sees fail-fast → exits.
##
## Total cases ran = 2, ``NumFixtures`` = 20, so the
## ``2 < 20`` invariant holds without depending on absolute timing.

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

proc writeFixtureSource(path: string; idx: int; shouldFail: bool) =
  ## Emit a tiny protocol-aware test binary. When ``shouldFail`` is
  ## true, the test body fails immediately; otherwise it sleeps briefly
  ## and passes. The sleep on the passing path makes fail-fast
  ## observable: with sub-millisecond tests, workers race to drain the
  ## queue before the runner can mark fail-fast triggered, and the
  ## ``total < NumFixtures`` invariant becomes flaky. The failing
  ## fixture stays instant so the fail-fast signal is delivered before
  ## sibling workers finish their sleep and grab the remaining items.
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
import std/os
import ct_test_unittest_parallel

suite "fixture_aggregate_$IDX":
  test "case":
    sleep(100)
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
    # Pad the basename so a basic lex sort matches the integer order,
    # i.e. ``t_fix_00`` is the first item the worker pool pulls from
    # the queue. Placing the failing fixture at index 0 keeps the
    # fail-fast race deterministic (see module docstring).
    let stem = "t_fix_" & align($i, 2, '0')
    let src = srcDir / (stem & ".nim")
    writeFixtureSource(src, i, i == failingIdx)
    let outBin = binDir / addFileExt(stem, ExeExt)
    if not compileFixture(workRoot, src, outBin, shimSrc):
      return false
  true

proc runRunner(runner, binDir, summary, resultsDir: string;
               failFast: bool;
               threads: int):
    tuple[exitCode: int; output: string] =
  var cmd = quoteShell(runner) &
    " --no-build --threads=" & $threads & " --quiet" &
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

  const NumFixtures = 20
  const FailingIdx = 0
  const WorkerCount = 2
  let ok = setupFixtures(repoRoot, tempRoot, binDir,
                         NumFixtures, FailingIdx)
  check ok
  if not ok:
    return

  let summary = tempRoot / "summary.json"
  let (exitCode, output) = runRunner(runner, binDir, summary,
                                     tempRoot / "results",
                                     failFast = false,
                                     threads = WorkerCount)
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

  const NumFixtures = 20
  const FailingIdx = 0
  const WorkerCount = 2
  let ok = setupFixtures(repoRoot, tempRoot, binDir,
                         NumFixtures, FailingIdx)
  check ok
  if not ok:
    return

  let summary = tempRoot / "summary.json"
  let (exitCode, output) = runRunner(runner, binDir, summary,
                                     tempRoot / "results",
                                     failFast = true,
                                     threads = WorkerCount)
  checkpoint("fail-fast run exit=" & $exitCode)
  if exitCode != 1:
    checkpoint(output)
  check exitCode == 1

  let doc = parseJson(readFile(summary))
  let total = doc{"summary"}{"total"}.getInt(-1)
  let failed = doc{"summary"}{"failed"}.getInt(-1)
  checkpoint("fail-fast run totals: total=" & $total &
    " failed=" & $failed)
  # The failing fixture sits at queue position 0 and the worker pool
  # is capped at ``WorkerCount`` (2). The first worker pulls the
  # failing case, runs it instantly, and flips fail-fast on its next
  # ``nextCase`` call. Every other worker is either still executing
  # a passing fixture (body sleep) or will observe fail-fast on its
  # next pull. Even with worst-case scheduling, total cases ran
  # is bounded by ``WorkerCount`` (in-flight) + 1 (the failing one)
  # = 3, which is far below ``NumFixtures`` (20). The
  # ``total < NumFixtures`` invariant therefore decouples from
  # absolute timing.
  check failed >= 1
  check total < NumFixtures

suite "t_repro_test_runner_aggregate_exit_code":
  test "default mode: 1 failing of 20 -> exit 1, all 20 run":
    runDefaultCase()

  test "fail-fast mode: 1 failing of 20 -> exit 1, fewer than 20 run":
    runFailFastCase()
