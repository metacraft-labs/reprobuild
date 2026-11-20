## M2 verification: ``--run "<name>"`` with ``$NIMTEST_RESULT_FILE``
## set produces a JSON result file with the required fields
## (``status``, ``duration_ms``, ``checkpoints``, ``exception``) and
## exits 0/1/2 matching the result status.
##
## Strategy: build the fixture ``fixture_protocol_three_tests`` once
## (three tests across two suites with deterministic pass / fail /
## skip outcomes), invoke ``--run`` for each, and assert against the
## result-file shape and exit code.

import std/[json, os, osproc, sequtils, strutils]
import std/unittest
from repro_test_support import ctShimFixturePath, requireBinary,
  testCaseScratchSlug

# Graph-Owned-Test-Artifacts M3: the fixture is BUILT BY THE GRAPH — the same
# single artifact ``t_every_test_binary_speaks_list_json_protocol`` reads, from
# edge ``reprobuild.test_fixtures.ct_shim_fixture_protocol_three_tests``, and
# declared as a typed input on both tests' execute edges. See the longer note
# in that file for why the per-case output paths this proc used to need are
# gone with the per-case compile that created the race.
proc buildFixture(): string =
  requireBinary(ctShimFixturePath("fixture_protocol_three_tests"),
    "reprobuild.test_fixtures.ct_shim_fixture_protocol_three_tests")

# The cases that leave the process from inside their body: a failed
# ``require`` (``fail`` -> ``quit(1)``, so ``testEnded`` never runs) and a
# ``quit`` in the body. A separate fixture so the three-case catalog that
# ``t_every_test_binary_speaks_list_json_protocol`` counts stays three.
proc buildAbortFixture(): string =
  requireBinary(ctShimFixturePath("fixture_protocol_abort_paths"),
    "reprobuild.test_fixtures.ct_shim_fixture_protocol_abort_paths")

# Per-case scratch for the result files this suite WRITES. Shared fixture,
# private outputs. The four cases used to name fixed ``/tmp/...`` paths, which
# is an absolute host path in a test body and does not honour ``$TMPDIR``;
# ``testCaseScratchSlug()`` gives each case its own directory under the repo's
# own build tree instead.
let fixtureScratch = "build" / "test-tmp" / "ct-test-unittest-parallel" /
  testCaseScratchSlug()

proc resultFilePath(stem: string): string =
  createDir(fixtureScratch)
  fixtureScratch / (stem & ".json")

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
      resultFilePath("pass"))
    check exitCode == 0
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "PASS"

  test "fail_status_one_exit_with_checkpoints":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "arithmetic::subtraction_fails",
      resultFilePath("fail"))
    check exitCode == 1
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"
      check doc["checkpoints"].len > 0

  test "skip_status_two_exit":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "markers::skipped",
      resultFilePath("skip"))
    check exitCode == 2
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "SKIP"

  test "missing_test_writes_result_and_exits_nonzero":
    let binary = buildFixture()
    let (exitCode, doc) = runOne(binary, "nonexistent::test",
      resultFilePath("missing"))
    check exitCode != 0
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"

  # Positive control for the abort handling below: the passing case of the
  # abort fixture still writes exactly the passing document.
  test "abort_fixture_passing_case_document_unchanged":
    let binary = buildAbortFixture()
    let (exitCode, doc) = runOne(binary, "abort_paths::passes",
      resultFilePath("abort-pass"))
    check exitCode == 0
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "PASS"
      check doc["checkpoints"].len == 0
      check doc["exception"].kind == JNull
      check not doc.hasKey("skipReason")

  # A failed ``require`` quits from inside the body. The document must still
  # say FAIL, carry the checkpoint recorded before the require and the failed
  # condition, and name the require as the reason -- not "test not found",
  # and not nothing.
  test "require_failure_writes_fail_document_with_checkpoints":
    let binary = buildAbortFixture()
    let (exitCode, doc) = runOne(binary, "abort_paths::require_fails",
      resultFilePath("abort-require"))
    check exitCode == 1
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"
      var cps: seq[string]
      for cp in doc["checkpoints"]:
        cps.add(cp.getStr())
      checkpoint "checkpoints: " & $cps
      check "captured build output: abort-paths-marker" in cps
      check cps.anyIt("Check failed: observed == 5" in it)
      check "unreachable after require" notin cps
      check doc["exception"].kind == JString
      let reason = doc["exception"].getStr()
      checkpoint "exception: " & reason
      check reason.startsWith("require failed")
      check "observed == 5" in reason
      check "test not found" notin reason

  # ``quit(0)`` mid-body: the case never finished, so it is a FAIL with a
  # non-zero exit whatever code the body chose.
  test "quit_in_body_writes_fail_document":
    let binary = buildAbortFixture()
    let (exitCode, doc) = runOne(binary, "abort_paths::quits_in_body",
      resultFilePath("abort-quit"))
    check exitCode == 1
    check not doc.isNil
    if doc != nil:
      assertResultShape(doc)
      check doc["status"].getStr() == "FAIL"
      let reason = doc["exception"].getStr()
      checkpoint "exception: " & reason
      check "quit" in reason
      check "test not found" notin reason
