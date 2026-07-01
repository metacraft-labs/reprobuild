## t_just_test_via_ct_test_runner —
## Test-Edges-And-Parallel-Runner M4 verification (the
## ``just_test_via_ct_test_runner`` entry in the milestone
## deliverables).
##
## End-to-end run of the full reprobuild suite through ``just test``, with the
## ct-test-runner binary available via ``CT_TEST_RUNNER`` or ``PATH`` so the
## run-tests script prefers it over the M3 internal fallback.
##
## Gated on ``REPRO_M1_LONG_TEST=1`` like the M3 long-test verifier — a
## full-suite run takes several minutes wall time and is only
## appropriate as a manual benchmark or CI long-test gate.

import std/[os, osproc, strutils, times, unittest]

const RepoRootMarker = "repro.nim"
const LongTestEnv = "REPRO_M1_LONG_TEST"

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

proc ctTestRunnerPath(): string =
  let fromEnv = getEnv("CT_TEST_RUNNER")
  if fromEnv.len > 0:
    return fromEnv
  findExe(addFileExt("ct-test-runner", ExeExt))

proc runEndToEnd() =
  let repoRoot = findRepoRoot()
  let just = findExe("just")
  check just.len > 0
  if just.len == 0:
    return

  let runner = ctTestRunnerPath()
  check runner.len > 0 and fileExists(runner)
  if runner.len == 0 or not fileExists(runner):
    checkpoint("ct-test-runner not available via CT_TEST_RUNNER/PATH")
    return

  let t0 = epochTime()
  let (output, exitCode) = execCmdEx(
    "just test",
    workingDir = repoRoot)
  let wallMs = int((epochTime() - t0) * 1000)
  checkpoint("`just test` exit=" & $exitCode &
    " wall=" & $wallMs & "ms (informational, not asserted)")
  if exitCode != 0:
    let tail = block:
      let lines = output.splitLines()
      if lines.len <= 80:
        output
      else:
        "...\n" & lines[lines.high - 79 .. lines.high].join("\n")
    checkpoint(tail)
  check exitCode == 0

  let summaryPath = repoRoot / "test-logs" / "parallel-run.json"
  check fileExists(summaryPath)

  # Soft-check: the test log should mention ct-test-runner, confirming
  # the script used the external runner rather than the M3 fallback.
  let logPath = repoRoot / "test-logs" / "test.log"
  if fileExists(logPath):
    let log = readFile(logPath)
    check log.contains("ct-test-runner") or log.contains("ct_test_runner")

suite "t_just_test_via_ct_test_runner":
  test "`just test` runs the full suite through ct-test-runner":
    if getEnv(LongTestEnv) != "1":
      checkpoint("skipped — set " & LongTestEnv &
        "=1 to run the long-form end-to-end verifier")
      skip()
    else:
      runEndToEnd()
