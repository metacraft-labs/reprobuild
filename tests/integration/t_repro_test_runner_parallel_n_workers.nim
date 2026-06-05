## t_repro_test_runner_parallel_n_workers —
## Test-Edges-And-Parallel-Runner M3 verification.
##
## With ``--threads=4``, the M3 runner must never have more than 4
## child test processes alive at any instant. Verified by spawning the
## runner against a fixture directory of 12 test binaries that import
## the protocol shim; each fixture test records its PID and a pair of
## monotonic-clock timestamps (start, end) into a shared file, and the
## controller (this test) parses the file and asserts the maximum
## overlap of [start, end] intervals never exceeds 4.
##
## The fixture binary is a tiny ``ct_test_unittest_parallel`` test
## program that sleeps for ~120ms inside its body — long enough for
## overlap to be observable, short enough to keep total wall time
## bounded.

import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles,
            unittest]

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

proc writeFixtureSource(path: string; idx: int) =
  ## Emit a tiny test binary that opens ``$REPRO_FIXTURE_LOG``, appends
  ## ``pid,start,end`` lines for each test case, and sleeps so the
  ## controller can observe parallelism.
  let body = """
import std/[locks, os, strutils, times]
import ct_test_unittest_parallel

var ioLock {.global.}: Lock
once: initLock(ioLock)

proc recordWindow(name: string) =
  let logPath = getEnv("REPRO_FIXTURE_LOG")
  if logPath.len == 0:
    return
  let pid = getCurrentProcessId()
  let t0 = epochTime()
  sleep(120)
  let t1 = epochTime()
  acquire(ioLock)
  try:
    let line = $pid & "," & formatFloat(t0, ffDecimal, 6) & "," &
      formatFloat(t1, ffDecimal, 6) & "," & name & "\n"
    let f = open(logPath, fmAppend)
    f.write(line)
    f.close()
  except CatchableError:
    discard
  release(ioLock)

suite "fixture_parallel_n_workers_$IDX":
  test "case_a":
    recordWindow("$IDX::a")
    check true
  test "case_b":
    recordWindow("$IDX::b")
    check true
""".replace("$IDX", $idx)
  writeFile(path, body)

proc countOverlap(intervals: seq[(float, float)]): int =
  ## Maximum number of overlapping intervals. Sweep events:
  ## +1 at start, -1 at end; the max prefix sum is the answer.
  var events: seq[(float, int)] = @[]
  for (s, e) in intervals:
    events.add((s, 1))
    events.add((e, -1))
  events.sort do (a, b: (float, int)) -> int:
    if a[0] < b[0]: -1
    elif a[0] > b[0]: 1
    else: cmp(a[1], b[1])  # end before start at same instant
  var cur = 0
  result = 0
  for (_, delta) in events:
    cur += delta
    if cur > result:
      result = cur

proc compileFixture(repoRoot, workRoot, source, binary: string): bool =
  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  var cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrc) & " " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  let exitCode = execCmd(cmd)
  exitCode == 0

proc runParallelCheck() =
  let repoRoot = findRepoRoot()
  let runner = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  check fileExists(runner)
  if not fileExists(runner):
    return

  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src" /
    "ct_test_unittest_parallel.nim"
  check fileExists(shimSrc)
  if not fileExists(shimSrc):
    return

  let tempRoot = createTempDir("repro-m3-parallel-", "")
  defer: removeDir(tempRoot)
  let binDir = tempRoot / "bin"
  let srcDir = tempRoot / "src"
  createDir(binDir)
  createDir(srcDir)

  const NumFixtures = 12
  var fixtureSources: seq[string] = @[]
  for i in 0 ..< NumFixtures:
    let src = srcDir / ("t_fixture_" & $i & ".nim")
    writeFixtureSource(src, i)
    fixtureSources.add(src)

  # Compile each fixture sequentially; total compile time is bounded.
  for src in fixtureSources:
    let stem = splitFile(src).name
    let outBin = binDir / addFileExt(stem, ExeExt)
    let ok = compileFixture(repoRoot, tempRoot, src, outBin)
    check ok
    if not ok:
      return

  let logPath = tempRoot / "windows.log"
  writeFile(logPath, "")
  putEnv("REPRO_FIXTURE_LOG", logPath)

  let summary = tempRoot / "summary.json"
  let cmd = quoteShell(runner) & " --no-build" &
    " --threads=4 --quiet" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(tempRoot / "results")
  let (output, exitCode) = execCmdEx(cmd)
  checkpoint("runner exit=" & $exitCode)
  if exitCode != 0:
    checkpoint(output)
  check exitCode == 0

  # Parse the per-test window log and compute the max overlap of
  # [start, end] timestamps. Each line: pid,start,end,name.
  var intervals: seq[(float, float)] = @[]
  for line in readFile(logPath).splitLines():
    let parts = line.split(',')
    if parts.len < 3: continue
    try:
      intervals.add((parseFloat(parts[1]), parseFloat(parts[2])))
    except ValueError:
      discard

  checkpoint("recorded windows: " & $intervals.len)
  check intervals.len >= NumFixtures  # at least one per fixture

  let maxParallel = countOverlap(intervals)
  checkpoint("max concurrent test cases: " & $maxParallel)
  check maxParallel <= 4
  # Sanity: with 12 fixtures and 4 workers, we expect more than 1
  # in flight at some point. (Otherwise the test wouldn't exercise
  # the parallelism cap.)
  check maxParallel >= 2

suite "t_repro_test_runner_parallel_n_workers":
  test "runner caps parallelism at --threads N":
    runParallelCheck()
