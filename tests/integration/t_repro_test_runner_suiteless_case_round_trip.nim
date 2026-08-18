## t_repro_test_runner_suiteless_case_round_trip —
## the ``--run`` argument must be the catalog's ``name``, verbatim.
##
## The protocol contract is that a binary's ``--list-json`` catalog names
## its cases and that ``--run <name>`` executes exactly one of them. The
## runner used to *reconstruct* that argument from the catalog's
## ``suite`` + ``name`` fields instead of carrying ``name`` through. For
## a suite-ful case the reconstruction happens to be an identity, so the
## defect was invisible across the whole suite. It is not an identity for
## a **suite-less** case: ``std/unittest``'s ``protocolFullName`` emits
## ``"::" & testName`` when the suite name is empty, and the old
## strip-and-rejoin turned ``::solo_case`` back into the bare
## ``solo_case``. The binary then found no such case, wrote
## ``"exception": "test not found: solo_case"``, exited 1, and the runner
## reported FAIL for a test that never ran.
##
## No suite-less case exists in this repository today, so this is a trap
## for whoever adds the first one rather than a live failure. That is
## exactly why it needs a test: the defect is silent until it isn't.
##
## What this test guarantees
## -------------------------
##  * A suite-less case is discovered, executed and reported as a PASS —
##    which is only possible if ``--run`` received ``::solo_case``.
##  * A suite-ful case in the same binary is unaffected, pinning that the
##    ordinary path did not regress.
##  * The negative control is asserted directly against the fixture: the
##    reconstructed bare name ``solo_case`` really is rejected with
##    "test not found". Without this, the positive assertion could pass
##    against a hypothetically lenient matcher and prove nothing.
##
## Mocking: none. The fixture is a real ``import std/unittest`` binary
## compiled by the real toolchain, and the component under test is the
## real, compiled ``repro_test_runner`` driven as a subprocess against
## real files. The suite-less catalog shape and the strict ``--run``
## matcher are the stdlib's own behaviour, not a stand-in for it.

import std/[json, os, osproc, strutils, tempfiles, unittest]

template testWithReturn(name: string; body: untyped) =
  test name:
    proc runTestBody() =
      body
    runTestBody()

const RepoRootMarker = "repro.nim"

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

const FixtureSource = """
import std/unittest

# Registered outside any suite: ``std/unittest`` catalogs this as
# ``suite: ""`` / ``name: "::solo_case"``.
test "solo_case":
  check 1 == 1

suite "with_suite":
  test "nested_case":
    check 1 == 1
"""

proc compileFixture(workRoot, source, binary: string): bool =
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(workRoot / "nimcache") & " " &
    "--out:" & quoteShell(binary) & " " & quoteShell(source)
  execCmd(cmd) == 0

suite "repro_test_runner suite-less case round-trip":
  testWithReturn "a suite-less case is run via its verbatim catalog name":
    let repoRoot = findRepoRoot()
    let runner = repoRoot / "build" / "bin" /
      addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if not fileExists(runner):
      return

    let tempRoot = createTempDir("repro-m2-suiteless-", "")
    defer: removeDir(tempRoot)
    let binDir = tempRoot / "bin"
    createDir(binDir)

    const Stem = "t_suiteless_fixture"
    let src = tempRoot / (Stem & ".nim")
    writeFile(src, FixtureSource)
    let fixtureBin = binDir / addFileExt(Stem, ExeExt)
    let compiled = compileFixture(tempRoot, src, fixtureBin)
    check compiled
    if not compiled:
      return

    # Pin the catalog shape this test exists to defend: the suite-less
    # case really is named ``::solo_case`` with an empty ``suite``.
    let listed = execCmdEx(quoteShell(fixtureBin) & " --list-json")
    check listed.exitCode == 0
    let catalog = parseJson(listed.output)
    var catalogNames: seq[string] = @[]
    for entry in catalog["tests"]:
      catalogNames.add(entry{"name"}.getStr())
      if entry{"name"}.getStr() == "::solo_case":
        check entry{"suite"}.getStr() == ""
    check "::solo_case" in catalogNames
    check "with_suite::nested_case" in catalogNames

    # Negative control: the reconstructed bare name is rejected. This is
    # precisely what the old runner sent.
    let rejected = execCmdEx(quoteShell(fixtureBin) & " --run solo_case")
    check rejected.exitCode != 0

    let summary = tempRoot / "summary.json"
    let resultsDir = tempRoot / "results"
    let cmd = quoteShell(runner) &
      " --no-build --threads=1 --quiet" &
      " --bin-dir=" & quoteShell(binDir) &
      " --summary-json=" & quoteShell(summary) &
      " --results-dir=" & quoteShell(resultsDir)
    let (output, exitCode) = execCmdEx(cmd)
    checkpoint("runner exit=" & $exitCode)
    if exitCode != 0:
      checkpoint(output)
    check exitCode == 0

    let doc = parseJson(readFile(summary))
    check doc{"summary"}{"total"}.getInt(-1) == 2
    check doc{"summary"}{"passed"}.getInt(-1) == 2
    check doc{"summary"}{"failed"}.getInt(-1) == 0

    # Both cases must be protocol-aware entries; a whole-binary fallback
    # would collapse them into one entry and leave the property untested.
    var reported: seq[string] = @[]
    for entry in doc["tests"]:
      check entry{"protocol_aware"}.getBool() == true
      check entry{"status"}.getStr() == "PASS"
      reported.add(entry{"qualified_name"}.getStr())
    check "solo_case" in reported
    check "with_suite::nested_case" in reported
