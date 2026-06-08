## Project-DSL-Composition M6 smoke test.
##
## Validates the shape of the migrated test-edge table:
##
##   1. ``repro_tests.nim`` parses as a normal Nim module (no
##      ``build:`` block fragment) and exports ``reprobuildTestSpecs*``
##      with the expected ``TestSpec`` field layout.
##   2. The const carries a healthy non-zero count of entries.
##      Pre-M6 the file held 452 declared edges; the regenerated table
##      should be in the same ballpark.
##   3. Every entry's ``source`` ends in ``.nim`` and every ``binary``
##      lives under ``build/test-bin/`` — the data-shape contract the
##      consumer (``repro.nim``'s ``build:`` loop) depends on.
##   4. The ``defines`` field is populated for the reproProviderMode
##      subset (the Test-Edges M2 metadata that drives
##      ``--define:reproProviderMode`` per-edge).
##
## This is a sanity check on the data shape, not a full DSL execution
## check. The DSL execution check (``./build/bin/repro build test``
## enumerates the edges) is the M6 verification test
## ``t_repro_build_test_lists_all_edges`` which requires the repro
## binary to be built — that one runs in CI after this passes.

import std/[os, strutils, unittest]

import repro_tests

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

suite "Project-DSL-Composition M6 smoke":

  test "reprobuildTestSpecs is non-empty":
    # The actual count tracks the source tree; the lower bound here is
    # what the generator emitted pre-M6 minus a small drift margin.
    check reprobuildTestSpecs.len > 400

  test "every TestSpec.source ends in .nim":
    for spec in reprobuildTestSpecs:
      check spec.source.endsWith(".nim")

  test "every TestSpec.binary lives under build/test-bin/":
    for spec in reprobuildTestSpecs:
      check spec.binary.startsWith("build/test-bin/")

  test "reproProviderMode is carried in defines for the affected subset":
    var providerModeCount = 0
    for spec in reprobuildTestSpecs:
      if "reproProviderMode" in spec.defines:
        inc providerModeCount
    # ``isProviderModePath`` in scripts/generate_test_edges.nim picks
    # out a few dozen tests; the exact count drifts with the source
    # tree but should be non-zero and well below the suite total.
    check providerModeCount > 10
    check providerModeCount < reprobuildTestSpecs.len

  test "no duplicate binary paths (basename-collision invariant)":
    var seen: seq[string] = @[]
    for spec in reprobuildTestSpecs:
      check spec.binary notin seen
      seen.add(spec.binary)

  test "repro_tests.nim does not contain a build: block fragment":
    # Pre-M6 the file's body was ``build:\n  let _t_... = ...``. After
    # the M6 migration the file should be a plain Nim module with the
    # data table. Catch accidental regressions where someone reverts
    # the generator to the include shape. We look at line-starts so
    # ``build/test-bin/`` paths (which contain ``build:``-adjacent
    # substrings in unrelated contexts) don't false-positive.
    let repoRoot = findRepoRoot()
    let content = readFile(repoRoot / "repro_tests.nim")
    var sawBuildBlockOpener = false
    var sawBuildNimUnittestCall = false
    for line in content.splitLines():
      let stripped = line.strip()
      if stripped == "build:":
        sawBuildBlockOpener = true
      if stripped.startsWith("let ") and "buildNimUnittest.build(" in stripped:
        sawBuildNimUnittestCall = true
    check not sawBuildBlockOpener
    check not sawBuildNimUnittestCall
    check "reprobuildTestSpecs*" in content
    check "TestSpec*" in content

  test "repro.nim no longer includes repro.tests.nim":
    # The pre-M6 ``include "repro.tests.nim"`` line is what the
    # composition campaign exists to eliminate. Catch a reversion.
    let repoRoot = findRepoRoot()
    let content = readFile(repoRoot / "repro.nim")
    check "include \"repro.tests.nim\"" notin content
    check "include \"repro_tests.nim\"" notin content
    check "import repro_tests" in content
