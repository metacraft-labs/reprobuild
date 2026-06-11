## Bootstrap-And-Self-Build B4: the ``test`` collection in
## ``repro.nim`` enrolls EXECUTE edges from both Nim tests AND Python
## tests in one unified accumulator, so ``repro test`` covers the
## entire suite in a single engine pass.
##
## Structural verification only — no engine round-trip. The structural
## arm asserts the source-level migration intent: the test-spec loop
## and the python-test loop both push into
## ``reprobuildTestExecuteActions``, which is then registered as the
## ``test`` collection.

import std/[os, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc orderInText(text: string; markers: openArray[string]):
    seq[tuple[marker: string, pos: int]] =
  result = @[]
  for m in markers:
    result.add((marker: m, pos: text.find(m)))

suite "Bootstrap-And-Self-Build B4: repro test covers Nim + Python in one collection":

  test "structural: test collection enrolls Nim + Python execute edges in a unified accumulator":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproNim)

    let text = readFile(reproNim)

    # --- single accumulator, two producer loops ---

    # Both producer loops must push into the SAME accumulator so the
    # ``test`` collection's closure spans both languages.
    check "reprobuildTestExecuteActions" in text
    check "reprobuildTestExecuteActions.add(executeEdge)" in text
    check "reprobuildTestExecuteActions.add(pyExecute)" in text

    # --- Nim test loop ---
    check "for spec in reprobuildTestSpecs:" in text
    check "buildNimUnittest.build(" in text
    check "edge.testBinary.run(" in text

    # --- Python test loop ---
    check "for source in pythonTestPaths:" in text
    check "pythonUnittest.run(" in text
    check "reprobuild.python_test." in text

    # --- collection registration ---
    check "collect(\"test\", reprobuildTestExecuteActions" in text

    # --- ordering: Nim loop must declare the accumulator; Python loop
    # must come AFTER the Nim loop and BEFORE the collect() call so
    # both lanes contribute. ---
    let order = orderInText(text, [
      "for spec in reprobuildTestSpecs:",
      "reprobuildTestExecuteActions.add(executeEdge)",
      "for source in pythonTestPaths:",
      "reprobuildTestExecuteActions.add(pyExecute)",
      "collect(\"test\", reprobuildTestExecuteActions"
    ])
    for entry in order:
      check entry.pos >= 0
    for i in 1 ..< order.len:
      if order[i - 1].pos >= 0 and order[i].pos >= 0:
        check order[i].pos > order[i - 1].pos

    # --- python_unittest_runner imported at the top ---
    check "import repro_dsl_stdlib/packages/python_unittest_runner" in text

    checkpoint("B4 repro-test-alias structural assertion: OK")
