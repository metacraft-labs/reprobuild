## M2 verification: ``--list-json`` produces valid JSON with a
## non-empty ``tests`` array, each entry having ``name``, ``suite``,
## ``file``, ``line``.
##
## Strategy: build the fixture ``fixture_protocol_three_tests`` once
## (three tests across two suites), invoke it with ``--list-json``,
## parse the output as JSON, and assert against the expected shape.

import std/[json, os, osproc, streams, strtabs, strutils]
import std/unittest
from repro_test_support import ctShimFixturePath, requireBinary,
  testCaseScratchSlug

# Graph-Owned-Test-Artifacts M3: the fixture is BUILT BY THE GRAPH.
#
# This proc used to run ``nim c``. Both cases here, and every case of
# ``t_test_binary_run_one_writes_result_file``, built the same fixture — and
# because per-case execution runs those as concurrent processes, each case had
# to be given its own output path and its own nimcache so that one case's
# ``nim c`` would not relink a binary another case was in the middle of
# executing. That was a workaround for a race that only existed because the
# artifact was built six times.
#
# It is now built ONCE by edge ``reprobuild.test_fixtures.ct_shim_fixture_
# protocol_three_tests`` and declared as a typed input on both tests' execute
# edges (``testFixtureArtifacts`` in ``repro.nim``). All six cases read one
# read-only file, so there is no race left to work around, and a change to the
# fixture source invalidates the tests instead of being silently recompiled
# underneath them.
#
# COMPILATION IS NOT THE SUBJECT HERE, which is why this migration is safe:
# what is asserted is the ``--list-json`` protocol document the BINARY emits.
# Contrast ``t_smoke_ct_test_unittest_parallel``, which IMPORTS the shim so
# that its own binary is the artifact under test — nothing to lift, and the M2
# migration correctly left it alone.
proc buildFixture(): string =
  requireBinary(ctShimFixturePath("fixture_protocol_three_tests"),
    "reprobuild.test_fixtures.ct_shim_fixture_protocol_three_tests")

# Scratch space for the per-case result file the protocol writes. The FIXTURE
# is shared; anything the case WRITES still has to be per-case.
let fixtureScratch = "build" / "test-tmp" / "ct-test-unittest-parallel" /
  testCaseScratchSlug()

proc runProtocolCommand(binary, argument: string): tuple[output: string;
    stderrOutput: string; exitCode: int] =
  ## Keep the protocol document and diagnostics on distinct channels.  The old
  ## ``execCmdEx`` assertion merged them and therefore accepted a catalog that
  ## was wholly on stderr — exactly the shape real catalog consumers reject.
  var childEnv = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    childEnv[key] = value
  # Reproduce nested execution under the per-case runner's protocol env.  List
  # mode must remain stdout-only even when an outer result path is inherited.
  childEnv["NIMTEST_RESULT_FILE"] = fixtureScratch / "outer-result.json"

  let process = startProcess(binary, args = [argument], env = childEnv,
    options = {})
  defer: process.close()
  let input = process.inputStream
  if input != nil:
    input.close()
  result.output = process.outputStream.readAll()
  result.stderrOutput = process.errorStream.readAll()
  result.exitCode = process.waitForExit()

suite "t_every_test_binary_speaks_list_json_protocol":
  test "list_json_returns_valid_catalog":
    let binary = buildFixture()
    let captured = runProtocolCommand(binary, "--list-json")
    check captured.exitCode == 0
    check captured.stderrOutput == ""
    var doc: JsonNode = nil
    try:
      doc = parseJson(captured.output)
    except JsonParsingError:
      checkpoint "stdout was:"
      checkpoint captured.output
      checkpoint "stderr was:"
      checkpoint captured.stderrOutput
      fail()
    if doc != nil:
      check doc.kind == JObject
      check doc.hasKey("tests")
      let tests = doc["tests"]
      check tests.kind == JArray
      check tests.len == 3
      var foundAdd, foundSub, foundSkip = false
      for t in tests:
        check t.hasKey("name")
        check t.hasKey("suite")
        check t.hasKey("file")
        check t.hasKey("line")
        check t["file"].getStr().endsWith("fixture_protocol_three_tests.nim")
        check t["line"].getInt() > 0
        case t["name"].getStr()
        of "arithmetic::addition":
          foundAdd = true
          check t["suite"].getStr() == "arithmetic"
        of "arithmetic::subtraction_fails":
          foundSub = true
          check t["suite"].getStr() == "arithmetic"
        of "markers::skipped":
          foundSkip = true
          check t["suite"].getStr() == "markers"
      check foundAdd
      check foundSub
      check foundSkip

  test "list_plain_returns_one_name_per_line":
    let binary = buildFixture()
    let captured = runProtocolCommand(binary, "--list")
    check captured.exitCode == 0
    check captured.stderrOutput == ""
    let lines = captured.output.strip().splitLines()
    check lines.len == 3
    check "arithmetic::addition" in lines
    check "arithmetic::subtraction_fails" in lines
    check "markers::skipped" in lines
