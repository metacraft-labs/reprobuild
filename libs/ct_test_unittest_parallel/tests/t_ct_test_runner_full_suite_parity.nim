## t_ct_test_runner_full_suite_parity —
## Test-Edges-And-Parallel-Runner M4 verification.
##
## Builds a small protocol-aware fixture binary (5 test cases:
## 4 PASS + 1 SKIP), then runs it through BOTH:
##
## * the M3 internal runner at
##   ``../reprobuild/build/bin/repro_test_runner``, and
## * the new M4 external runner at
##   ``../ct-test/build/bin/ct-test-runner``,
##
## and asserts the pass/fail/skip totals match exactly. This is the
## load-bearing equivalence assertion for the M4 cut-over.
##
## Soft-skips if either runner binary is missing — the parity test is
## meaningful only when both have been built.

import std/[json, os, osproc, strutils, tempfiles, unittest]

const FixtureSrc = currentSourcePath().parentDir() /
  "fixtures" / "fixture_m4_parity_suite.nim"

proc shimSrcDir(): string =
  currentSourcePath().parentDir().parentDir() / "src"

proc workspaceRoot(): string =
  ## Walk up from ct-test/libs/ct_test_unittest_parallel/tests/ until
  ## we find a directory containing both ``ct-test`` and ``reprobuild``
  ## children — that's the metacraft workspace root.
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if dirExists(dir / "ct-test") and dirExists(dir / "reprobuild"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  ""

proc compileFixture(workRoot, outBin: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrcDir()) & " " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(outBin) & " " &
    quoteShell(FixtureSrc)
  execCmd(cmd) == 0

proc copyBinaryAs(src, dst: string) =
  copyFile(src, dst)
  when not defined(windows):
    var info = getFileInfo(dst)
    info.permissions.incl(fpUserExec)
    info.permissions.incl(fpGroupExec)
    info.permissions.incl(fpOthersExec)
    setFilePermissions(dst, info.permissions)

proc runWithRunner(runner, binDir, summary, resultsDir: string):
    tuple[exitCode: int; total, executed, passed, failed,
          skipped: int; output: string] =
  let cmd = quoteShell(runner) & " --no-build --threads=2 --quiet" &
    " --bin-dir=" & quoteShell(binDir) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(resultsDir)
  let (output, exitCode) = execCmdEx(cmd)
  result.exitCode = exitCode
  result.output = output
  if not fileExists(summary):
    return
  try:
    let doc = parseJson(readFile(summary))
    let s = doc{"summary"}
    result.total = s{"total"}.getInt(-1)
    result.executed = s{"executed"}.getInt(s{"total"}.getInt(-1))
    result.passed = s{"passed"}.getInt(-1)
    result.failed = s{"failed"}.getInt(-1)
    result.skipped = s{"skipped"}.getInt(-1)
  except CatchableError:
    discard

proc runParityCase(): bool =
  ## Returns false if prerequisites are missing — caller should skip.
  let ws = workspaceRoot()
  if ws.len == 0:
    checkpoint("skipped — could not locate workspace root")
    return false
  let m3Runner = ws / "reprobuild" / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  let m4Runner = ws / "ct-test" / "build" / "bin" /
    addFileExt("ct-test-runner", ExeExt)
  if not fileExists(m3Runner):
    checkpoint("skipped — M3 runner not built at " & m3Runner)
    return false
  if not fileExists(m4Runner):
    checkpoint("skipped — ct-test-runner not built at " & m4Runner)
    return false

  let tempRoot = createTempDir("ct-test-m4-parity-", "")
  defer: removeDir(tempRoot)

  # Build the fixture once, then mirror it into separate bin
  # directories so each runner has its own scan target (and the
  # M3 runner's exclude-list-against-itself doesn't interfere).
  let fixtureBin = tempRoot / addFileExt("t_m4_parity_fixture", ExeExt)
  let okBuild = compileFixture(tempRoot, fixtureBin)
  check okBuild
  if not okBuild:
    return true   # ran (fixture build attempted); check already failed

  let binDirM3 = tempRoot / "bin-m3"
  let binDirM4 = tempRoot / "bin-m4"
  createDir(binDirM3)
  createDir(binDirM4)
  copyBinaryAs(fixtureBin,
    binDirM3 / addFileExt("t_m4_parity_fixture", ExeExt))
  copyBinaryAs(fixtureBin,
    binDirM4 / addFileExt("t_m4_parity_fixture", ExeExt))

  let m3 = runWithRunner(m3Runner, binDirM3,
                         tempRoot / "summary-m3.json",
                         tempRoot / "results-m3")
  let m4 = runWithRunner(m4Runner, binDirM4,
                         tempRoot / "summary-m4.json",
                         tempRoot / "results-m4")

  checkpoint("M3 totals: passed=" & $m3.passed &
    " failed=" & $m3.failed & " skipped=" & $m3.skipped &
    " exit=" & $m3.exitCode)
  checkpoint("M4 totals: passed=" & $m4.passed &
    " failed=" & $m4.failed & " skipped=" & $m4.skipped &
    " exit=" & $m4.exitCode)
  if m3.exitCode != 0:
    checkpoint("M3 output: " & m3.output)
  if m4.exitCode != 0:
    checkpoint("M4 output: " & m4.output)

  # Both runners must agree on the per-status totals.
  check m3.passed == m4.passed
  check m3.failed == m4.failed
  check m3.skipped == m4.skipped

  # Fixture is 4 PASS + 1 SKIP, no failures.
  check m3.passed == 4
  check m3.failed == 0
  check m3.skipped == 1

  # And both must return exit 0 (no failures).
  check m3.exitCode == 0
  check m4.exitCode == 0
  return true

suite "t_ct_test_runner_full_suite_parity":
  test "M3 internal runner and M4 ct-test-runner agree on pass/fail/skip totals":
    let ran = runParityCase()
    if not ran:
      skip()
