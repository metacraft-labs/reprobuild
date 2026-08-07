## M2 verification: ``--list-json`` produces valid JSON with a
## non-empty ``tests`` array, each entry having ``name``, ``suite``,
## ``file``, ``line``.
##
## Strategy: build the fixture ``fixture_protocol_three_tests`` once
## (three tests across two suites), invoke it with ``--list-json``,
## parse the output as JSON, and assert against the expected shape.

import std/[json, os, osproc, strutils]
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

suite "t_every_test_binary_speaks_list_json_protocol":
  test "list_json_returns_valid_catalog":
    let binary = buildFixture()
    let (output, exitCode) = execCmdEx(binary.quoteShell() & " --list-json")
    check exitCode == 0
    var doc: JsonNode = nil
    try:
      doc = parseJson(output)
    except JsonParsingError:
      checkpoint "stdout was:"
      checkpoint output
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
    let (output, exitCode) = execCmdEx(binary.quoteShell() & " --list")
    check exitCode == 0
    let lines = output.strip().splitLines()
    check lines.len == 3
    check "arithmetic::addition" in lines
    check "arithmetic::subtraction_fails" in lines
    check "markers::skipped" in lines
