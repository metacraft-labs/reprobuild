## t_ct_test_runner_partition_file_mode —
## Test-Edges-And-Parallel-Runner M4 verification.
##
## Asserts ``ct-test-runner run --partition file:<path> <binary>`` runs
## exactly the test cases listed in the partition file, with the other
## cases marked as skipped-by-partition in the JSON summary.
##
## Strategy: build the same 5-case fixture used by the parity test
## (``fixture_m4_parity_suite``), write a partition file listing
## three of the five fully-qualified names, run ct-test-runner against
## that fixture binary, and inspect ``test-logs/parallel-run.json``.
##
## Also covers two error-mode cases:
##
## * ``--partition slice:1/4`` exits 2 with a diagnostic (slice/hash
##   sharding belongs to the upstream ct-test-runner).
## * Names in the partition file that don't appear in the catalog emit
##   a one-time warning (per codetracer-specs §15.1).

import std/[json, os, osproc, strutils, tempfiles, unittest]

const FixtureSrc = currentSourcePath().parentDir() /
  "fixtures" / "fixture_m4_parity_suite.nim"

proc shimSrcDir(): string =
  currentSourcePath().parentDir().parentDir() / "src"

proc workspaceRoot(): string =
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

proc m4RunnerPath(): string =
  let ws = workspaceRoot()
  if ws.len == 0:
    return ""
  ws / "ct-test" / "build" / "bin" /
    addFileExt("ct-test-runner", ExeExt)

proc runPartitionFileCase(): bool =
  let runner = m4RunnerPath()
  if runner.len == 0 or not fileExists(runner):
    checkpoint("skipped — ct-test-runner not built at " & runner)
    return false

  let tempRoot = createTempDir("ct-test-m4-part-", "")
  defer: removeDir(tempRoot)
  let fixtureBin = tempRoot / addFileExt("t_m4_part_fixture", ExeExt)
  let okBuild = compileFixture(tempRoot, fixtureBin)
  check okBuild
  if not okBuild:
    return true

  # Pick 3 of the 5 cases. The other 2 must NOT appear in the
  # executed-tests array of the summary.
  let partitionFile = tempRoot / "partition.txt"
  writeFile(partitionFile, """
# M4 partition-file selection — 3 of 5 fixture tests.
alpha::pass_a
beta::pass_d
beta::pass_e
""")

  let summary = tempRoot / "summary.json"
  let cmd = quoteShell(runner) & " run --quiet --threads=2" &
    " --partition=file:" & quoteShell(partitionFile) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(tempRoot / "results") &
    " " & quoteShell(fixtureBin)
  let (output, exitCode) = execCmdEx(cmd)
  checkpoint("ct-test-runner exit=" & $exitCode)
  if exitCode != 0:
    checkpoint(output)
  check exitCode == 0
  check fileExists(summary)

  let doc = parseJson(readFile(summary))
  let s = doc{"summary"}
  let total = s{"total"}.getInt(-1)
  let executed = s{"executed"}.getInt(-1)
  let passed = s{"passed"}.getInt(-1)
  let failed = s{"failed"}.getInt(-1)
  let skipped = s{"skipped"}.getInt(-1)
  let skippedByPartition = s{"skipped_by_partition"}.getInt(-1)

  checkpoint("totals: total=" & $total & " executed=" & $executed &
    " passed=" & $passed & " failed=" & $failed &
    " skipped=" & $skipped & " skipped_by_partition=" &
    $skippedByPartition)

  check total == 5
  check executed == 3
  check skippedByPartition == 2
  check passed == 3
  check failed == 0
  # The skipped fixture test (alpha::skip_c) is excluded by the
  # partition, so the run sees zero skips by skip().
  check skipped == 0

  # Spot-check the executed-tests array contains exactly the three
  # listed names — and NOT alpha::pass_b or alpha::skip_c.
  let tests = doc{"tests"}
  check tests.kind == JArray
  check tests.len == 3
  var executedNames: seq[string] = @[]
  for t in tests:
    executedNames.add(t{"qualified_name"}.getStr(""))
  check "alpha::pass_a" in executedNames
  check "beta::pass_d" in executedNames
  check "beta::pass_e" in executedNames
  check "alpha::pass_b" notin executedNames
  check "alpha::skip_c" notin executedNames
  return true

proc runPartitionSliceDiagnosticCase(): bool =
  let runner = m4RunnerPath()
  if runner.len == 0 or not fileExists(runner):
    checkpoint("skipped — ct-test-runner not built")
    return false
  let cmd = quoteShell(runner) & " run --partition=slice:1/4" &
    " --bin-dir=/tmp/nonexistent-m4-slice"
  let (output, exitCode) = execCmdEx(cmd)
  check exitCode == 2
  check output.contains("slice")
  check output.contains("Nim-Parallel-Test-Framework")
  return true

proc runPartitionMissingNamesCase(): bool =
  let runner = m4RunnerPath()
  if runner.len == 0 or not fileExists(runner):
    checkpoint("skipped — ct-test-runner not built")
    return false

  let tempRoot = createTempDir("ct-test-m4-part-miss-", "")
  defer: removeDir(tempRoot)
  let fixtureBin = tempRoot / addFileExt("t_m4_part_miss_fixture",
    ExeExt)
  let okBuild = compileFixture(tempRoot, fixtureBin)
  check okBuild
  if not okBuild:
    return true

  let partitionFile = tempRoot / "partition.txt"
  writeFile(partitionFile, """
alpha::pass_a
alpha::not_a_real_test
""")

  let summary = tempRoot / "summary.json"
  let cmd = quoteShell(runner) & " run --quiet --threads=1" &
    " --partition=file:" & quoteShell(partitionFile) &
    " --summary-json=" & quoteShell(summary) &
    " --results-dir=" & quoteShell(tempRoot / "results") &
    " " & quoteShell(fixtureBin)
  let (output, exitCode) = execCmdEx(cmd)
  check exitCode == 0
  check output.contains("not found in any binary")
  check output.contains("alpha::not_a_real_test")
  return true

suite "t_ct_test_runner_partition_file_mode":
  test "partition file: runs only the listed three of five tests":
    if not runPartitionFileCase():
      skip()

  test "partition slice: not implemented, exits 2 with diagnostic":
    if not runPartitionSliceDiagnosticCase():
      skip()

  test "partition file names that don't match any test produce warning":
    if not runPartitionMissingNamesCase():
      skip()
