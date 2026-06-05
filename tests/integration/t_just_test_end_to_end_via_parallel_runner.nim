## t_just_test_end_to_end_via_parallel_runner —
## Test-Edges-And-Parallel-Runner M3 verification (the ``just_test``
## entry in the milestone deliverables).
##
## End-to-end run of the full reprobuild suite through ``just test``
## passes via the new parallel runner. Wall time is recorded for
## informational purposes but NOT asserted (the speedup target is a
## soft goal; this test verifies functional correctness only).
##
## Gated on ``REPRO_M1_LONG_TEST=1`` like the M1 hot-cache verifier —
## a full-suite run takes several minutes wall time and is only
## appropriate as a manual benchmark or CI long-test gate.

import std/[os, osproc, strutils, times, unittest]

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

proc runEndToEnd() =
  let repoRoot = findRepoRoot()
  let just = findExe("just")
  check just.len > 0
  if just.len == 0:
    return

  let t0 = epochTime()
  let (output, exitCode) = execCmdEx(
    "just test",
    workingDir = repoRoot)
  let wallMs = int((epochTime() - t0) * 1000)
  checkpoint("`just test` exit=" & $exitCode &
    " wall=" & $wallMs & "ms (informational, not asserted)")
  if exitCode != 0:
    # Surface the tail of the output; full log is in
    # ``test-logs/test.log``.
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

suite "t_just_test_end_to_end_via_parallel_runner":
  test "`just test` runs the full suite through the M3 parallel runner":
    if getEnv(LongTestEnv) != "1":
      checkpoint("skipped — set " & LongTestEnv &
        "=1 to run the long-form end-to-end verifier")
      skip()
    else:
      runEndToEnd()
