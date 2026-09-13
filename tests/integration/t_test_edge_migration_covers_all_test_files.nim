## t_test_edge_migration_covers_all_test_files — Test-Edges-And-Parallel-Runner
## M1 verification.
##
## Asserts that every test file on disk under the four discovery roots used
## by ``scripts/generate_test_edges.nim`` is COVERED by the generated
## ``repro_tests.nim`` table:
##
##   * ``tests/**/t_*.nim``
##   * ``libs/**/tests/{t_,test_}*.nim``
##   * ``tools/**/tests/test_*.nim``
##   * ``recipes/packages/source/**/test_*.nim``
##
## If a new test file lands without re-running the generator it is not
## covered and this test fails, surfacing the missed regeneration before the
## suite silently drops the new test.
##
## Coverage is a SET relation, not a count
## ---------------------------------------
## This test used to compare two integers: the number of ``TestSpec(``
## entries against the number of files on disk. That reading was correct
## only while the mapping was one binary per source file, and Suite-
## Modernization M4 ended that. A pure-unit BUNDLE
## (``tests/bundles/bundle_*.nim``, generated from the ``PureUnitBundles``
## table in ``scripts/generate_test_edges.nim``) is a single ``TestSpec``
## whose body is nothing but quoted relative imports of several member test
## sources; the members are deliberately NOT emitted as specs of their own,
## because compiling them twice would also count their cases twice.
##
## Under counting, every bundle therefore reads as a deficit of
## ``members - 1``: seven bundles folding 67 members made the two integers
## differ by 60 while not one test file had actually lost coverage. The
## count could only have been restored by un-bundling — undoing the
## consolidation to satisfy the measurement of it.
##
## So the assertion is now the set relation the count was standing in for:
## the union of (non-bundle spec sources) and (members imported by declared
## bundles) must equal the discovered on-disk set exactly. It is strictly
## stronger than the count in both directions — it names the offending
## paths, and it cannot be satisfied by a coincidence of two equal totals
## over different files (one test added and one deleted between runs of the
## generator used to net out to zero).
##
## Bundle recognition mirrors ``bundle_member_paths`` in
## ``scripts/reprobuild_suite_inventory.py`` — the ``tests/bundles/``
## directory AND an import-only body — so the two static readings of the
## suite cannot drift apart. An ordinary test that merely opens with a
## quoted import is never mistaken for an aggregator.

import std/[algorithm, os, sets, strutils, unittest]

const RepoRootMarker = "repro.nim"
const BundleRoot = "tests/bundles/"

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

proc discoverTestFilesOnDisk(repoRoot: string): HashSet[string] =
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

  proc walk(acc: var HashSet[string]; repoRoot, dir: string; mode: PrefixMode;
            requireTestsParent: bool) =
    let abs = repoRoot / dir
    if not dirExists(abs):
      return
    for path in walkDirRec(abs, relative = true):
      let normalized = path.replace('\\', '/')
      let rel = dir & "/" & normalized
      # Mirror the generator's exclusion (scripts/generate_test_edges.nim
      # skips ``tests/fixtures/``): those are fixture PROJECTS — sample
      # test collections consumed BY tests — not reprobuild's own unittest
      # binaries, so they carry no build edge. Without this the on-disk
      # set over-reports by the fixtures' ``t_*.nim`` files.
      if rel.startsWith("tests/fixtures/"):
        continue
      if requireTestsParent:
        let parts = normalized.split('/')
        if parts.len < 3: continue
        if parts[1] != "tests": continue
      if accept(normalized, mode):
        acc.incl(rel)

  result = initHashSet[string]()
  walk(result, repoRoot, "tests", pmTOnly, false)
  walk(result, repoRoot, "libs", pmTOrTest, true)
  walk(result, repoRoot, "tools", pmTestOnly, true)
  # M9.N from-source recipes carry a ``test_<pkg>_source.nim`` per recipe
  # under ``recipes/packages/source/<pkg>/``. The generator discovers
  # them (acceptRecipesTree) and emits a build edge for each, so they
  # belong in the on-disk set too.
  walk(result, repoRoot, "recipes/packages/source", pmTestOnly, false)

proc declaredSpecSources(repoRoot: string): seq[string] =
  ## Project-DSL-Composition M6: the generated table lives in
  ## ``repro_tests.nim`` as a ``seq[TestSpec]``; ``repro.nim`` calls
  ## ``buildNimUnittest.build`` once per entry. Read the ``source:`` field
  ## of each entry — one per declared test build edge. Matching on the
  ## trailing quote excludes the ``source*: string`` field of the
  ## ``TestSpec* = object`` type definition above the table.
  result = @[]
  let content = readFile(repoRoot / "repro_tests.nim")
  for line in content.splitLines():
    let stripped = line.strip()
    if not stripped.startsWith("source: \""):
      continue
    let opening = stripped.find('"')
    let closing = stripped.rfind('"')
    if closing > opening:
      result.add(stripped[opening + 1 ..< closing])

proc normalizeRelPath(path: string): string =
  ## Collapse ``.`` and ``..`` segments in a forward-slash relative path.
  var parts: seq[string] = @[]
  for segment in path.replace('\\', '/').split('/'):
    if segment.len == 0 or segment == ".":
      continue
    elif segment == "..":
      if parts.len > 0:
        discard parts.pop()
    else:
      parts.add(segment)
  parts.join("/")

proc bundleMembers(repoRoot, source: string): seq[string] =
  ## The member sources a pure-unit bundle folds in, or ``@[]`` when
  ## ``source`` is not one.
  ##
  ## Recognition is deliberately narrow — the ``tests/bundles/`` directory
  ## AND a body consisting of nothing but quoted ``import`` lines — so an
  ## ordinary test that happens to open with a quoted import is never
  ## expanded into members it does not own. Same rule as
  ## ``bundle_member_paths`` in ``scripts/reprobuild_suite_inventory.py``.
  result = @[]
  if not source.startsWith(BundleRoot):
    return
  let abs = repoRoot / source
  if not fileExists(abs):
    return
  var body = 0
  var imports: seq[string] = @[]
  for line in readFile(abs).splitLines():
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    inc body
    if stripped.startsWith("import \"") and stripped.endsWith("\""):
      let opening = stripped.find('"')
      let closing = stripped.rfind('"')
      if closing > opening:
        imports.add(stripped[opening + 1 ..< closing])
  if body == 0 or imports.len != body:
    # Something other than imports lives here; not an aggregator.
    return
  let bundleDir = source.splitFile().dir
  for target in imports:
    result.add(normalizeRelPath(bundleDir & "/" & target & ".nim"))

proc sortedSeq(values: HashSet[string]): seq[string] =
  result = @[]
  for value in values:
    result.add(value)
  result.sort()

proc summarize(label: string; values: HashSet[string]): string =
  ## Render at most a readable prefix of a difference set, with a count, so
  ## a failure names the offending paths instead of only a delta.
  const MaxListed = 25
  let items = sortedSeq(values)
  result = label & " (" & $items.len & "):"
  for i, item in items:
    if i >= MaxListed:
      result.add("\n  … and " & $(items.len - MaxListed) & " more")
      break
    result.add("\n  " & item)

suite "t_test_edge_migration_covers_all_test_files":
  test "every discovered test file has a declared build edge":
    let repoRoot = findRepoRoot()
    let onDisk = discoverTestFilesOnDisk(repoRoot)
    let specSources = declaredSpecSources(repoRoot)

    var covered = initHashSet[string]()
    var bundles = 0
    var bundledMembers = 0
    var emptyBundles: seq[string] = @[]
    var missingMembers = initHashSet[string]()

    for source in specSources:
      let members = bundleMembers(repoRoot, source)
      if source.startsWith(BundleRoot):
        inc bundles
        if members.len == 0:
          # A declared bundle that expands to nothing would silently drop
          # every member it was supposed to carry.
          emptyBundles.add(source)
        for member in members:
          inc bundledMembers
          covered.incl(member)
          if not fileExists(repoRoot / member):
            missingMembers.incl(member)
      else:
        covered.incl(source)

    let uncovered = onDisk - covered
    let stale = covered - onDisk

    checkpoint("test files on disk: " & $onDisk.len)
    checkpoint("declared TestSpec entries: " & $specSources.len)
    checkpoint("of which pure-unit bundles: " & $bundles &
      " (folding " & $bundledMembers & " members)")
    checkpoint("covered test files: " & $covered.len)

    if uncovered.len > 0:
      # The regeneration the suite is missing, spelled out.
      checkpoint("re-run: nim r scripts/generate_test_edges.nim")
      checkpoint(summarize("test files with no build edge", uncovered))
    if stale.len > 0:
      checkpoint(summarize(
        "declared sources not found on disk", stale))
    if emptyBundles.len > 0:
      checkpoint("bundles that expand to no members: " &
        emptyBundles.join(", "))
    if missingMembers.len > 0:
      checkpoint(summarize("bundle members that do not exist",
        missingMembers))

    check uncovered.len == 0
    check stale.len == 0
    check emptyBundles.len == 0
    check missingMembers.len == 0
    check covered.len == onDisk.len
    check covered.len > 0
