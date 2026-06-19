## t_test_edge_migration_covers_all_test_files — Test-Edges-And-Parallel-Runner
## M1 verification.
##
## Asserts that the count of declared ``TestSpec(`` entries in the
## generated ``repro_tests.nim`` table equals the count of test files on
## disk under the three discovery roots used by
## ``scripts/generate_test_edges.nim``:
##
##   * ``tests/**/t_*.nim``
##   * ``libs/**/tests/{t_,test_}*.nim``
##   * ``tools/**/tests/test_*.nim``
##   * ``recipes/packages/source/**/test_*.nim``
##
## If a new test file lands without re-running the generator the count
## diverges and this test fails, surfacing the missed regeneration
## before the suite silently drops the new test.

import std/[os, strutils, unittest]

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

proc countTestFilesOnDisk(repoRoot: string): int =
  type PrefixMode = enum
    pmTOnly         # ``tests/`` — only ``t_*.nim``
    pmTOrTest       # ``libs/`` — both ``t_*.nim`` and ``test_*.nim``
    pmTestOnly      # ``tools/`` — only ``test_*.nim`` (M66 convention)

  proc accept(rel: string; mode: PrefixMode): bool =
    if not rel.endsWith(".nim"):
      return false
    let stem = rel.splitFile().name
    case mode
    of pmTOnly:    stem.startsWith("t_")
    of pmTOrTest:  stem.startsWith("t_") or stem.startsWith("test_")
    of pmTestOnly: stem.startsWith("test_")

  proc walk(dir: string; mode: PrefixMode;
            requireTestsParent: bool): int =
    result = 0
    let abs = repoRoot / dir
    if not dirExists(abs):
      return
    for path in walkDirRec(abs, relative = true):
      let normalized = path.replace('\\', '/')
      # Mirror the generator's exclusion (scripts/generate_test_edges.nim
      # skips ``tests/fixtures/``): those are fixture PROJECTS — sample
      # test collections consumed BY tests — not reprobuild's own unittest
      # binaries, so they carry no build edge. Without this the on-disk
      # count over-reports by the fixtures' ``t_*.nim`` files.
      if (dir & "/" & normalized).startsWith("tests/fixtures/"):
        continue
      if requireTestsParent:
        let parts = normalized.split('/')
        if parts.len < 3: continue
        if parts[1] != "tests": continue
      if accept(normalized, mode):
        inc result

  result = 0
  result += walk("tests", pmTOnly, false)
  result += walk("libs", pmTOrTest, true)
  result += walk("tools", pmTestOnly, true)
  # M9.N from-source recipes carry a ``test_<pkg>_source.nim`` per recipe
  # under ``recipes/packages/source/<pkg>/``. The generator discovers
  # them (acceptRecipesTree) and emits a build edge for each, so count
  # them here too or ``declared`` over-reports relative to ``onDisk``.
  result += walk("recipes/packages/source", pmTestOnly, false)

proc countGeneratedBuildCalls(repoRoot: string): int =
  # Project-DSL-Composition M6: the generated table moved from
  # ``repro.tests.nim`` (one ``let _<name> = buildNimUnittest.build(``
  # line per edge) to ``repro_tests.nim`` (a ``seq[TestSpec]`` data
  # table; ``repro.nim`` now calls ``buildNimUnittest.build`` once per
  # entry inside its package ``build:`` block). Count the ``TestSpec(``
  # entries — still exactly one per declared test build edge. Filtering
  # by the ``TestSpec(`` prefix excludes the ``TestSpec* = object`` type
  # definition and the header comments that mention it in prose.
  let content = readFile(repoRoot / "repro_tests.nim")
  result = 0
  for line in content.splitLines():
    let stripped = line.strip(leading = true, trailing = false)
    if stripped.startsWith("TestSpec("):
      inc result

suite "t_test_edge_migration_covers_all_test_files":
  test "every discovered test file has a declared build edge":
    let repoRoot = findRepoRoot()
    let onDisk = countTestFilesOnDisk(repoRoot)
    let declared = countGeneratedBuildCalls(repoRoot)
    checkpoint("test files on disk: " & $onDisk)
    checkpoint("declared buildNimUnittest.build calls: " & $declared)
    check declared == onDisk
    check declared > 0
