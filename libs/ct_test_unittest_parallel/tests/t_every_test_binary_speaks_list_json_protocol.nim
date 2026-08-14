## M2 verification: ``--list-json`` produces valid JSON with a
## non-empty ``tests`` array, each entry having ``name``, ``suite``,
## ``file``, ``line``.
##
## Strategy: build the fixture ``fixture_protocol_three_tests`` once
## (three tests across two suites), invoke it with ``--list-json``,
## parse the output as JSON, and assert against the expected shape.

import std/[json, os, osproc, streams, strtabs, strutils]
import std/unittest
from repro_test_support import testCaseScratchSlug

const fixtureSource = currentSourcePath().parentDir() /
  "fixtures" / "fixture_protocol_three_tests.nim"

# Both cases in this suite — and every case of
# ``t_test_binary_run_one_writes_result_file`` — build this same
# fixture. Under per-case execution those are concurrent processes, so
# a single shared output path and nimcache means one ``nim c`` relinks
# the binary another case is in the middle of running. Give each case
# its own. Building under ``build/test-tmp`` rather than
# ``build/test-bin`` also keeps a deliberately-failing fixture out of
# the directory the runner scans.
let fixtureScratch = "build" / "test-tmp" / "ct-test-unittest-parallel" /
  testCaseScratchSlug()

proc nimcacheDir(): string =
  result = getEnv("CT_TEST_PARALLEL_NIMCACHE")
  if result.len == 0:
    result = fixtureScratch / "nimcache"

proc buildFixture(): string =
  let outputPath = fixtureScratch /
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
