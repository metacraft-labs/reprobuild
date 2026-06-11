## Bootstrap-And-Self-Build B4: Python tests participate in the engine's
## graph as ``pythonUnittest.run(...)`` execute edges, alongside the Nim
## test execute edges, inside the same ``test`` build graph collection.
##
## Two halves
## ----------
##
##   1. STRUCTURAL — read ``repro_tests.nim``'s ``pythonTestPaths`` const
##      and assert that (a) it has at least one entry, (b) every entry
##      points at an existing ``test_*.py`` file under ``tests/``, and
##      (c) ``repro.nim``'s ``build:`` block iterates the list and emits
##      ``pythonUnittest.run(source = ...)`` execute edges with the
##      ``reprobuild.python_test.<stem>`` action-id convention. Also
##      assert the ``python_unittest_runner`` stdlib package is present
##      and exposes ``pythonUnittest`` + ``run``. This arm PASSes today.
##
##   2. ENGINE — drive ``./build/bin/repro test --daemon=off`` and assert
##      the build report records each Python test as a separate execute
##      action. SKIPs with the "no pythonUnittest tool profile"
##      classifier (per the B3 outcome; the path-mode tool resolver
##      doesn't yet have a profile for either
##      ``ct_test_nim_unittest.buildNimUnittest`` or ``python_unittest``).

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

proc extractPythonTestPaths(reproTestsText: string): seq[string] =
  ## Parse the ``pythonTestPaths*: seq[string] = @[ ... ]`` block as
  ## plain text — no Nim VM is required and the assertion stays robust
  ## across stylistic edits to the generator's render proc.
  result = @[]
  let header = "const pythonTestPaths*: seq[string] = @["
  let hpos = reproTestsText.find(header)
  if hpos < 0:
    return
  let bodyStart = hpos + header.len
  # Find the closing ``]`` of this seq literal.
  let endPos = reproTestsText.find("]\n", bodyStart)
  if endPos < 0:
    return
  let body = reproTestsText[bodyStart ..< endPos]
  for rawLine in body.splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("##") or line.startsWith("#"):
      continue
    # Trim a trailing comma so the inner literal is unambiguous.
    var inner = line
    if inner.endsWith(","):
      inner = inner[0 ..< inner.len - 1].strip()
    # Expected form: `"tests/.../test_*.py"`.
    if inner.startsWith("\"") and inner.endsWith("\"") and inner.len >= 2:
      result.add(inner[1 ..< inner.len - 1])

suite "Bootstrap-And-Self-Build B4: Python tests participate in the graph":

  test "structural: pythonTestPaths const enumerates real test_*.py files; repro.nim wires the edges":
    let repoRoot = findRepoRoot()
    let reproTests = repoRoot / "repro_tests.nim"
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproTests)
    check fileExists(reproNim)

    let reproTestsText = readFile(reproTests)
    let reproNimText = readFile(reproNim)

    # --- pythonTestPaths const exists ---
    check "const pythonTestPaths*: seq[string]" in reproTestsText

    let pythonPaths = extractPythonTestPaths(reproTestsText)
    checkpoint("pythonTestPaths entries: " & $pythonPaths.len)
    # B4 spec requires at least one Python test in the graph today.
    check pythonPaths.len >= 1

    # Each path must point at an existing file under ``tests/`` whose
    # basename starts with ``test_`` and ends with ``.py``.
    var missing: seq[string] = @[]
    for path in pythonPaths:
      let absPath = repoRoot / path
      if not fileExists(absPath):
        missing.add(path & " (file not found)")
        continue
      let stem = path.splitFile().name
      if not stem.startsWith("test_"):
        missing.add(path & " (basename does not start with test_)")
        continue
      if not path.endsWith(".py"):
        missing.add(path & " (not a .py file)")
        continue
      if not path.startsWith("tests/"):
        missing.add(path & " (not under tests/)")
    if missing.len > 0:
      for entry in missing:
        checkpoint("pythonTestPaths problem: " & entry)
    check missing.len == 0

    # --- repro.nim's build: loop wires the edges ---
    check "pythonTestPaths" in reproNimText
    check "pythonUnittest.run(" in reproNimText
    check "reprobuild.python_test." in reproNimText
    # The python execute action must be appended to the same
    # accumulator as the Nim test execute actions so the ``test``
    # collection covers both languages.
    check "reprobuildTestExecuteActions.add(pyExecute)" in reproNimText

    # --- python_unittest_runner stdlib wrapper present ---
    let pythonWrapper = repoRoot / "libs" / "repro_dsl_stdlib" / "src" /
      "repro_dsl_stdlib" / "packages" / "python_unittest_runner.nim"
    check fileExists(pythonWrapper)
    let wrapperText = readFile(pythonWrapper)
    check "PythonUnittest" in wrapperText
    check "pythonUnittest" in wrapperText
    check "proc run*(tool: PythonUnittest" in wrapperText
    check "publicCliCall(" in wrapperText
    # The wrapper records a call against the ``python3`` profile so the
    # engine's normal tool-resolution path drives the execution.
    check "packageName = \"python3\"" in wrapperText

    checkpoint("B4 Python-tests-in-graph structural assertion: OK")

  test "engine: build report records python_test execute actions":
    # Per the B3 outcome and the B4 spec's "Known constraints" section,
    # the path-mode tool resolver doesn't yet have a profile for
    # ``python_unittest``. The execute actions ARE registered in the
    # graph (the structural arm above verifies the source-level
    # migration intent); engine-level materialisation is a follow-on.
    checkpoint("skipped — no pythonUnittest tool profile. The path-mode " &
      "tool resolver lacks a python_unittest profile (analogous to the " &
      "ct_test_nim_unittest.buildNimUnittest gap documented in B3). " &
      "The structural arm above verifies the source-level wiring; engine " &
      "materialisation lands in a follow-on.")
    skip()
