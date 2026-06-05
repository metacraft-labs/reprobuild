## t_test_edge_migration_covers_all_test_files — Test-Edges-And-Parallel-Runner
## M1 verification.
##
## Asserts that the count of declared ``buildNimUnittest.build(`` calls
## in ``repro.tests.nim`` equals the count of test files on disk under
## the three discovery roots used by ``scripts/generate_test_edges.nim``:
##
##   * ``tests/**/t_*.nim``
##   * ``libs/**/tests/{t_,test_}*.nim``
##   * ``tools/**/tests/test_*.nim``
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
        fileExists(dir / "repro.tests.nim"):
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

proc countGeneratedBuildCalls(repoRoot: string): int =
  let content = readFile(repoRoot / "repro.tests.nim")
  result = 0
  for line in content.splitLines():
    let stripped = line.strip(leading = true, trailing = false)
    # The generator emits exactly one ``let _<name> =
    # buildNimUnittest.build(`` line per edge. Filtering by the
    # ``let _`` prefix excludes the documentation comments in the
    # generated file header that mention ``buildNimUnittest.build``
    # in prose.
    if stripped.startsWith("let _") and "buildNimUnittest.build(" in line:
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
