## Deferred Item D6: ``repro_test_runner`` honours a per-test
## ``--test-timeout=N`` deadline so a single hung test fails with a
## clear TIMEOUT signature while the rest of the suite continues.
##
## Background
## ----------
## CI run 27386716759 stalled at 2h42m on a self-hosted runner because
## the M3 runner's worker thread blocked indefinitely in
## ``drainAndWait``'s ``readLine`` waiting on
## ``t_local_daemons_control_plane_m11`` to close its inherited pipe
## FDs. The test exec had returned, but it left ``repro-daemon`` /
## ``fake_protocol_daemon_helper`` / ``repro`` children alive holding
## the merged stdout/stderr pipe open. The B5 follow-up wrapped the
## whole runner phase with a shell ``timeout 90m`` band-aid; D6
## replaces this with a per-test SIGTERM/SIGKILL inside the runner so
## one bad test no longer kills the entire phase.
##
## Two arms:
##
##   1. STRUCTURAL — assert the runner source carries the D6
##      ``--test-timeout`` CLI flag parsing AND a deadline-aware
##      ``drainAndWait``-equivalent. Anchors textual markers so a
##      refactor that drops the timeout path surfaces immediately at
##      the source-level review surface.
##
##   2. BEHAVIOURAL — write a small Nim source that does
##      ``sleep(60_000)`` (60 seconds), compile it under a private
##      temp ``--bin-dir``, then invoke the runner with
##      ``--test-timeout=3``. Assert: runner exits cleanly (not hung),
##      the sleeper's result entry has ``status=FAIL`` and stdout
##      contains "TIMEOUT", and total wall time is < 30 seconds.

import std/[json, os, osproc, strutils, times, unittest]

const RepoMarker = "repro.nim"

const FixtureSource = """
import std/os
echo "d6 sleeper: starting 60s sleep"
sleep(60_000)
echo "d6 sleeper: woke up cleanly (timeout did not fire)"
quit(0)
"""

type
  BehaviouralFindings = object
    wallSec: float
    runnerExit: int
    runnerOut: string
    summaryEntries: int
    entryStem: string
    entryStatus: string
    entryStdout: string

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runBehavioural(runnerBin: string): BehaviouralFindings =
  ## Compile the 60-second sleeper into a private temp dir, invoke the
  ## runner with ``--test-timeout=3``, return what we observe. Wrapped
  ## in a standalone proc so the ``defer`` cleanup and the early
  ## ``return`` shape compose naturally — ``unittest.test`` blocks
  ## expand to a template that forbids bare ``return``.
  let tmpDir = getTempDir() / "reprobuild_d6_runner_timeout"
  if dirExists(tmpDir):
    removeDir(tmpDir)
  createDir(tmpDir)
  defer:
    try:
      removeDir(tmpDir)
    except CatchableError:
      discard

  let fixtureSrc = tmpDir / "t_d6_sleeper_fixture.nim"
  let fixtureBin = tmpDir / "t_d6_sleeper_fixture"
  let resultsDir = tmpDir / "results"
  let summaryPath = tmpDir / "summary.json"

  writeFile(fixtureSrc, FixtureSource)

  let compileCmd = "nim c -d:release --hints:off --warnings:off " &
    "--out:" & quoteShell(fixtureBin) & " " & quoteShell(fixtureSrc)
  let (compileOut, compileExit) = execCmdEx(compileCmd)
  if compileExit != 0:
    raise newException(IOError,
      "fixture compile failed (exit " & $compileExit & "):\n" &
      compileOut)
  if not fileExists(fixtureBin):
    raise newException(IOError,
      "fixture binary missing after compile: " & fixtureBin)

  let runnerCmd = @[
    quoteShell(runnerBin),
    "--no-build",
    "--threads=1",
    "--test-timeout=3",
    "--bin-dir=" & quoteShell(tmpDir),
    "--summary-json=" & quoteShell(summaryPath),
    "--results-dir=" & quoteShell(resultsDir),
  ].join(" ")

  let t0 = epochTime()
  let (runnerOut, runnerExit) = execCmdEx(runnerCmd)
  result.wallSec = epochTime() - t0
  result.runnerExit = runnerExit
  result.runnerOut = runnerOut

  if not fileExists(summaryPath):
    raise newException(IOError,
      "runner produced no summary at " & summaryPath &
      " (exit " & $runnerExit & "):\n" & runnerOut)

  let summary = parseFile(summaryPath)
  let tests = summary{"tests"}
  if tests.isNil or tests.kind != JArray:
    raise newException(IOError,
      "summary lacks a ``tests`` array: " & summary.pretty())
  result.summaryEntries = tests.len
  if tests.len >= 1:
    let entry = tests[0]
    result.entryStem = entry{"binary_stem"}.getStr()
    result.entryStatus = entry{"status"}.getStr()
    result.entryStdout = entry{"stdout"}.getStr()

suite "Deferred Item D6: --test-timeout kills hung tests cleanly":

  test "structural: runner source carries --test-timeout parsing and a deadline-aware drain":
    let repoRoot = findRepoRoot()
    let runnerSrc = repoRoot / "tools" / "test-runner" /
      "repro_test_runner.nim"
    check fileExists(runnerSrc)

    let runnerText = readFile(runnerSrc)

    # CLI surface: the option must be parsed and surfaced in --help.
    check "--test-timeout" in runnerText
    check "test-timeout" in runnerText
    check "testTimeoutSec" in runnerText

    # A deadline-aware ``drainAndWait``-equivalent must exist and must
    # carry the SIGTERM/SIGKILL escalation the spec calls for.
    check "drainAndWaitWithTimeout" in runnerText
    check "peekExitCode" in runnerText
    check "terminate" in runnerText
    check "kill" in runnerText
    check "TIMEOUT" in runnerText

    checkpoint("D6 structural assertion: OK")

  test "behavioural: --test-timeout=3 SIGKILLs a 60s sleeper and reports FAIL+TIMEOUT":
    let repoRoot = findRepoRoot()
    let runnerBin = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)

    if not fileExists(runnerBin):
      checkpoint("skipped — " & runnerBin &
        " is missing; build the runner first")
      skip()
    else:
      let findings = runBehavioural(runnerBin)
      checkpoint("runner exit=" & $findings.runnerExit & " wall=" &
        formatFloat(findings.wallSec, ffDecimal, 2) & "s")
      if findings.runnerExit != 0:
        checkpoint("runner stdout/stderr:\n" & findings.runnerOut)

      # Wall time must be well below the 60s sleep (so we know the
      # kill actually happened) AND well below the 30s ceiling the
      # spec calls for.
      check findings.wallSec < 30.0
      # The 3s deadline plus the 5s SIGKILL grace plus spawn overhead
      # should resolve in well under 15s on any host. Floor at 1s so
      # a future "the runner short-circuits the spawn" regression
      # would surface here too.
      check findings.wallSec > 1.0

      # The runner's exit code must reflect the FAIL count.
      check findings.runnerExit != 0

      # Summary structure: exactly one entry, the sleeper, marked FAIL.
      check findings.summaryEntries == 1
      checkpoint("summary entry: stem=" & findings.entryStem &
        " status=" & findings.entryStatus)
      check findings.entryStem == "t_d6_sleeper_fixture"
      check findings.entryStatus == "FAIL"

      # The captured stdout in the summary must carry the TIMEOUT
      # signature emitted by ``runWholeBinary`` so the build report
      # surfaces the cause without needing separate log files.
      let preview =
        if findings.entryStdout.len <= 200: findings.entryStdout
        else: findings.entryStdout[0 ..< 200]
      checkpoint("entry stdout (first 200 chars): " & preview)
      check "TIMEOUT" in findings.entryStdout
      check "SIGKILLed" in findings.entryStdout
