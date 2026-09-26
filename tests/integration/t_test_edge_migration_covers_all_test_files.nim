## t_test_edge_migration_covers_all_test_files — Test-Edges-And-Parallel-Runner
## M1 verification.
##
## Asserts that every test file on disk that ``scripts/generate_test_edges.nim``
## would discover (its ``DeclaredSourceRoots`` walked with its
## ``walkAcceptsSource`` rule) is COVERED by the generated ``repro_tests.nim``
## table.
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

# The generator's discovery rule, so the two cannot disagree about which
# files are test sources.
import "../../scripts/generate_test_edges"

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
  ## Every test source the generator's walk would enrol: the roots in
  ## ``DeclaredSourceRoots`` filtered by ``walkAcceptsSource`` — the
  ## generator's own root list, skip prefixes and shape rule, imported
  ## rather than restated.
  ##
  ## This used to be a hand-kept copy of four per-root predicates
  ## (``tests/**/t_*``, ``libs/**/tests/*``, ``tools/**/tests/test_*``,
  ## ``recipes/packages/source/**/test_*``). The generator has since moved
  ## to one shape rule over five roots (``apps/`` added, ``test_`` accepted
  ## under ``tests/``, any ``recipes/`` depth), so the copy reported the
  ## sources only the new rule reaches — ``apps/repro-harvest-apt/tests/``,
  ## ``recipes/sandbox-tools/``, ``tests/integration/test_hax_*`` — as
  ## "declared but not on disk". What this test measures is whether
  ## ``repro_tests.nim`` was regenerated after the tree moved, not what the
  ## shape of a test source is; the shape has exactly one definition, and
  ## ``--check-shape-parity`` already holds the inventory script to it.
  result = initHashSet[string]()
  for root in DeclaredSourceRoots:
    let abs = repoRoot / root
    if not dirExists(abs):
      continue
    for path in walkDirRec(abs, relative = true):
      let rel = root & "/" & path.replace('\\', '/')
      if walkAcceptsSource(rel):
        result.incl(rel)

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
