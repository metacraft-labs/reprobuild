## M2 verification: ``--run "<name>"`` with ``$NIMTEST_RESULT_FILE``
## set produces a JSON result file with the required fields
## (``status``, ``duration_ms``, ``checkpoints``, ``exception``) and
## exits 0/1/2 matching the result status.
##
## Strategy: build the fixture ``fixture_protocol_three_tests`` once
## (three tests across two suites with deterministic pass / fail /
## skip outcomes), invoke ``--run`` for each, and assert against the
## result-file shape and exit code.

import std/[json, os, osproc, strutils]
import std/unittest

const fixtureSource = currentSourcePath().parentDir() /
  "fixtures" / "fixture_protocol_three_tests.nim"

proc nimcacheDir(): string =
  result = getEnv("CT_TEST_PARALLEL_NIMCACHE")
  if result.len == 0:
    result = "build" / "nimcache" / "ct_test_unittest_parallel" /
      "fixture_protocol_three_tests"

proc buildFixture(): string =
  let outputPath = "build" / "test-bin" /
    "ct_test_unittest_parallel_fixture_three_tests"
  createDir(outputPath.parentDir())
  createDir(nimcacheDir())
  let cmd = "nim c --hints:off --warnings:off --nimcache:" &
    nimcacheDir().quoteShell() & " --out:" & outputPath.quoteShell() &
    " " & fixtureSource.quoteShell()
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo output
    raise newException(IOError, "failed to build fixture: " & cmd)
  outputPath

proc runOne(binary, name, resultFile: string): tuple[exitCode: int,
                                                     doc: JsonNode] =
  removeFile(resultFile)
  putEnv("NIMTEST_RESULT_FILE", resultFile)
  let (_, exitCode) = execCmdEx(binary.quoteShell() & " --run " &
    name.quoteShell())
  delEnv("NIMTEST_RESULT_FILE")
  var doc: JsonNode
  if fileExists(resultFile):
    doc = parseJson(readFile(resultFile))
  (exitCode, doc)

template assertResultShape(doc: JsonNode) =
  check doc.kind == JObject
  check doc.hasKey("status")
  check doc.hasKey("duration_ms")
  check doc.hasKey("checkpoints")
  check doc.hasKey("exception")
  check doc["checkpoints"].kind == JArray

suite "t_test_binary_run_one_writes_result_file":
  test "pass_status_zero_exit":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "arithmetic::addition",
      "/tmp/ct_test_unittest_parallel.pass.json")
    check exitCode == 0
    check doc != nil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "PASS"

  test "fail_status_one_exit_with_checkpoints":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "arithmetic::subtraction_fails",
      "/tmp/ct_test_unittest_parallel.fail.json")
    check exitCode == 1
    check doc != nil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"
      check doc["checkpoints"].len > 0

  test "skip_status_two_exit":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "markers::skipped",
      "/tmp/ct_test_unittest_parallel.skip.json")
    check exitCode == 2
    check doc != nil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "SKIP"

  test "missing_test_writes_result_and_exits_nonzero":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "nonexistent::test",
      "/tmp/ct_test_unittest_parallel.missing.json")
    check exitCode != 0
    check doc != nil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"
