## t_runner_progress_visibility — the execution phase must be observable
## WHILE it runs, not only once it finishes.
##
## THE DEFECT THIS PINS
## --------------------
## A full suite run takes hours. Until this test existed the only thing the
## runner emitted during that time was a per-case line with no denominator:
## ``[PASS] t_foo bar (5ms)``. From a log like that a reader cannot tell a run
## that is 20% done from one that is 90% done, cannot see how many cases have
## already failed, and — while a single long case holds a worker, and this
## suite has one worth about 81 minutes — cannot tell a slow run from a wedged
## one at all. The machine-readable summary is written once, at the end, so a
## run killed by the outer ``timeout`` produced NOTHING: no summary, and no
## log a triager could act on.
##
## Three properties are asserted here, each of which was false before:
##
##   1. COUNTER — every per-case line carries ``[done/total pct%]``, the
##      counter is monotonic, starts at 1 and ends at the total.
##   2. HEARTBEAT — a periodic line restates position, elapsed time, how many
##      cases are in flight and how many have failed, even while no case
##      completes. It survives ``--quiet``, because a quiet run needs progress
##      MORE than a loud one, not less.
##   3. FAILURES ARE LIVE — a failing case and its reason reach the log at the
##      moment it fails, ahead of the end-of-run summary.
##
## Plus one contract check: all of this goes to stderr. Stdout is the runner's
## machine-readable side (``--list-json`` and anything a caller pipes), and
## human progress written there would corrupt it.
##
## NO MOCKS. The runner is the real binary, the fixtures are real compiled
## test programs speaking the real Tier-1 protocol, and the assertions read
## the runner's real stdout/stderr as separate files.

import std/[os, osproc, strutils, tempfiles, unittest]

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

proc writeSlowFixture(path: string) =
  ## Two cases, one of them slow enough that the heartbeat has to speak while
  ## nothing is completing — the exact stretch the old log went silent for.
  writeFile(path, """
import std/[os, times]
import ct_test_unittest_parallel

suite "progress_fixture_slow":
  test "slow_case":
    let t0 = epochTime()
    sleep(2500)
    check epochTime() - t0 >= 2.0

  test "quick_case":
    check "progress".len == 8
""")

proc writeFailingFixture(path: string) =
  writeFile(path, """
import ct_test_unittest_parallel

suite "progress_fixture_failing":
  test "deliberate_failure":
    let observed = 1
    check observed == 2
""")

proc compileFixture(repoRoot, workRoot, source, binary: string): bool =
  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrc) & " " &
    "--nimcache:" & quoteShell(workRoot / "nimcache" /
      splitFile(source).name) & " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  execCmd(cmd) == 0

type RunFindings = object
  stdoutText: string
  stderrText: string
  exitCode: int

proc runRunner(runner, binDir, workRoot: string; quiet: bool): RunFindings =
  ## Streams are captured SEPARATELY on purpose: the point of the stdout
  ## assertion is that progress never lands there, which a merged capture
  ## could not tell apart.
  let outPath = workRoot / (if quiet: "quiet.out" else: "loud.out")
  let errPath = workRoot / (if quiet: "quiet.err" else: "loud.err")
  var cmd = quoteShell(runner) & " --no-build --threads=2" &
    " --test-timeout=120" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(workRoot /
      (if quiet: "quiet.json" else: "loud.json")) &
    " --results-dir=" & quoteShell(workRoot /
      (if quiet: "quiet-results" else: "loud-results"))
  if quiet:
    cmd.add(" --quiet")
  cmd.add(" > " & quoteShell(outPath) & " 2> " & quoteShell(errPath))
  # One second, so the heartbeat is observable inside a test rather than a
  # minute later. The production default is sixty; the knob exists for an
  # operator watching a live run and is reused here rather than stubbed.
  putEnv("REPRO_TEST_RUNNER_HEARTBEAT_SEC", "1")
  result.exitCode = execCmd("sh -c " & quoteShell(cmd))
  delEnv("REPRO_TEST_RUNNER_HEARTBEAT_SEC")
  result.stdoutText = readFile(outPath)
  result.stderrText = readFile(errPath)

proc caseCounters(stderrText: string): seq[(int, int)] =
  ## Extract ``[done/total …]`` from the per-case lines (the ones carrying a
  ## status label), ignoring the heartbeat lines.
  for line in stderrText.splitLines():
    if not line.startsWith("["):
      continue
    let close = line.find(']')
    if close < 0:
      continue
    let inner = line[1 ..< close]
    let parts = inner.split(' ')[0].split('/')
    if parts.len != 2:
      continue
    try:
      result.add((parseInt(parts[0]), parseInt(parts[1].split(' ')[0])))
    except ValueError:
      discard

proc heartbeatLines(stderrText: string): seq[string] =
  for line in stderrText.splitLines():
    if line.startsWith("repro_test_runner: [") and "elapsed=" in line:
      result.add(line)

suite "t_runner_progress_visibility":

  setup:
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src" /
      "ct_test_unittest_parallel.nim"

  test "per-case lines and the heartbeat both report done-of-total":
    check fileExists(runner)
    check fileExists(shimSrc)
    if not (fileExists(runner) and fileExists(shimSrc)):
      return

    let workRoot = createTempDir("repro-progress-loud-", "")
    defer: removeDir(workRoot)
    let binDir = workRoot / "bin"
    let srcDir = workRoot / "src"
    createDir(binDir)
    createDir(srcDir)

    let slowSrc = srcDir / "t_progress_fixture_slow.nim"
    let failSrc = srcDir / "t_progress_fixture_failing.nim"
    writeSlowFixture(slowSrc)
    writeFailingFixture(failSrc)
    for src in [slowSrc, failSrc]:
      let ok = compileFixture(repoRoot, workRoot, src,
        binDir / addFileExt(splitFile(src).name, ExeExt))
      check ok
      if not ok:
        return

    let findings = runRunner(runner, binDir, workRoot, quiet = false)
    checkpoint("stderr:\n" & findings.stderrText)
    # One deliberate failure, so a green exit here would mean the runner
    # stopped noticing failures — which would make every other assertion
    # below meaningless.
    check findings.exitCode != 0

    # 1. COUNTER. Three cases across two binaries.
    let counters = caseCounters(findings.stderrText)
    check counters.len == 3
    if counters.len == 3:
      for (_, total) in counters:
        check total == 3
      check counters[0][0] == 1
      check counters[1][0] == 2
      check counters[2][0] == 3

    # 2. HEARTBEAT. The slow case holds a worker for 2.5s at a 1s interval,
    # so at least one heartbeat must land, and it must carry the numbers a
    # reader needs rather than a bare "still working".
    let beats = heartbeatLines(findings.stderrText)
    check beats.len >= 1
    if beats.len >= 1:
      check "elapsed=" in beats[^1]
      check "running=" in beats[^1]
      check "failed=" in beats[^1]
      # The failure happened before the last heartbeat (it is instantaneous;
      # the slow case is not), so the live failure count must have seen it.
      check "failed=0" notin beats[^1]

    # 3. FAILURES ARE LIVE: the failing case, its reason, and the path to its
    # result document all reach the log at the moment it fails — strictly
    # before the end-of-run summary line.
    let failIdx = findings.stderrText.find("[FAIL] t_progress_fixture_failing")
    let summaryIdx = findings.stderrText.find("repro_test_runner: ran ")
    check failIdx >= 0
    check summaryIdx >= 0
    check failIdx < summaryIdx
    check "Check failed: observed == 2" in findings.stderrText

    # 4. STDOUT CONTRACT: none of it goes to the machine-readable stream.
    check "[FAIL]" notin findings.stdoutText
    check "elapsed=" notin findings.stdoutText

  test "--quiet silences per-case lines but never the heartbeat":
    check fileExists(runner)
    check fileExists(shimSrc)
    if not (fileExists(runner) and fileExists(shimSrc)):
      return

    let workRoot = createTempDir("repro-progress-quiet-", "")
    defer: removeDir(workRoot)
    let binDir = workRoot / "bin"
    let srcDir = workRoot / "src"
    createDir(binDir)
    createDir(srcDir)

    let slowSrc = srcDir / "t_progress_fixture_slow.nim"
    writeSlowFixture(slowSrc)
    let ok = compileFixture(repoRoot, workRoot, slowSrc,
      binDir / addFileExt("t_progress_fixture_slow", ExeExt))
    check ok
    if not ok:
      return

    let findings = runRunner(runner, binDir, workRoot, quiet = true)
    checkpoint("stderr:\n" & findings.stderrText)
    check findings.exitCode == 0

    # Per-case lines are gone, which is what --quiet asks for.
    check caseCounters(findings.stderrText).len == 0

    # The ledger is not. A quiet run that reported no progress at all would
    # be the original defect wearing a flag, so the heartbeat must still
    # count the cases that completed while nothing was being printed.
    let beats = heartbeatLines(findings.stderrText)
    check beats.len >= 1
    if beats.len >= 1:
      check "/2 " in beats[^1]
