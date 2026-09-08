## t_ct_test_surface_case_addressability — every Reprobuild case this
## repository tracks is addressable through CodeTracer's published
## ``ct test`` catalog surface, under a stable identity, with counts a
## machine can read — and the exceptions are enumerated rather than averaged.
##
## What this test is for
## ---------------------
## Reprobuild has always been able to address its own cases individually: a
## test binary built by the codetracer-nim fork answers ``--list-json`` with a
## row per case, and Reprobuild's own runner reads it. That is per-case
## addressability, and it is not what this test is about.
##
## This test is about the *canonical* surface — ``ct-test test discover``,
## driven by CodeTracer's provider registry — because "addressable" and
## "addressable through the surface CodeTracer publishes" are different
## claims, and only the second one says anything about whether this
## repository could stop maintaining a runner of its own. Nothing here runs
## ``repro_test_runner``, reads its summary, or links any of its code; the
## last test in this file makes that a checked property rather than a promise
## (see "The negative control" below).
##
## What it asserts
## ---------------
##  * The canonical surface is *locatable* by the documented lookup —
##    ``$CT_TEST``, then ``ct-test`` on ``PATH``, then ``ct`` — and the lookup
##    has no tail that could resolve to a Reprobuild-local program.
##  * One ``discover --workspace`` invocation over this repository returns a
##    schema-1 catalog document with **no error diagnostics**, and counts that
##    are machine-readable and non-degenerate.
##  * Every Nim suite source the tracked inventory records is EITHER present
##    in that catalog, OR named in the checked-in ledger
##    ``benchmarks/reports/ct-test-surface-addressability.json`` with a reason.
##    The comparison is **exact in both directions**: a source that stops
##    being discovered fails the test, and a ledger entry that starts being
##    discovered fails it too. A ledger that could only grow would let the
##    gap widen silently, and a gap that widens silently is the one nobody
##    notices until a release depends on it.
##  * For every discovered source, the number of cases the surface reports
##    equals the case count the tracked inventory records — with the same
##    two-way exactness on the disagreement list.
##  * Case identities are **stable across independent invocations and across
##    discovery scopes**: for a named subset, the ids from the workspace-wide
##    catalog are byte-identical to the ids from a per-file discovery, and
##    each one is exactly what ``ctTestItemIdFor`` predicts from the case's
##    file, suite and name.
##
## The negative control
## --------------------
## The claim this file makes must not be satisfiable by the Reprobuild-only
## runner, or it is not a claim about the canonical surface at all. So the
## last case points
## ``$CT_TEST`` at ``build/bin/repro_test_runner`` and requires the very first
## step — obtaining a catalog document — to FAIL. If that ever passes, this
## file has stopped testing the canonical surface and is testing the local
## runner under a different name, and every number above is worthless.
##
## Environment
## -----------
## The surface is expected on ``PATH``: ``flake.nix`` puts ``ct-test`` in the
## dev shell's packages. When it is absent this test **fails with the lookup
## order named**; it does not skip. A skip here would report "the canonical
## boundary is fine" on a host that never reached it, which is precisely the
## healthy-looking summary that this repository has twice had to retract.
##
## Reviewers: ``$CT_TEST`` is the supported way to measure a specific build.
## The dev shell's ``ct-test`` is built from the ``codetracer-src`` flake
## input, which the workspace ``.envrc`` auto-overrides to a ``../codetracer``
## sibling when one exists — so on a workspace host it is whatever that
## sibling happens to be, which is not necessarily the pinned revision. The
## checked-in artifact records which binary produced its numbers.
##
## What the ground truth is, and what it cannot see
## ------------------------------------------------
## The ground truth is ``benchmarks/reports/reprobuild-suite-m0-inventory-
## sources.json``, and specifically its ``staticCaseCount`` field. That field
## comes from ``reprobuild_suite_inventory.py``'s own Nim token scanner — a
## different program, in a different language, in a different repository from
## CodeTracer's provider. The two sides of the comparison therefore share no
## PRODUCER, which is what makes an agreement on 1,393 of 1,394 sources mean
## something.
##
## They do share a DEFINITION, and the honest reading of these numbers depends
## on saying so. Both sides count a case as a literal ``test "…"`` call in the
## source; neither executes anything, and the checked-in inventory artifact
## carries no ``--list-json``-derived field at all. A case declared through a
## repository-local template is invisible to both, and so cannot appear in
## either the numerator or the denominator. There are nine such cases today,
## declared through the ``testWithReturn`` template in the four
## ``tests/integration/t_repro_test_runner_*`` sources that define it; the
## surface reports zero cases for those files, the inventory records zero, the
## two agree, and the cases are nonetheless not addressable through ``ct
## test``. They are a real part of the gap between "94.19% of sources" and
## "every logical Reprobuild case", and no assertion below can find them.
##
## Mocking: none. The surface is the real ``ct test`` binary, driven as a
## subprocess against this repository's real sources. There is no stand-in for
## either side, because a stand-in would be the thing under test.

import std/[algorithm, json, options, os, sets, strutils, tables, unittest]

import ct_test_surface

const
  RepoRootMarker = "repro.nim"
  LedgerPath = "benchmarks/reports/ct-test-surface-addressability.json"
  InventoryPath = "benchmarks/reports/reprobuild-suite-m0-inventory-sources.json"
  IdentityStabilitySubset = [
    ## A named subset spanning the shapes that make identity reconstruction
    ## non-trivial: a one-case smoke test, a multi-case library test, a unit
    ## test, an integration test, a source whose suite titles contain the
    ## ``::`` separator itself, and an e2e test under a nested directory.
    "libs/ct_test_interface/tests/t_smoke_ct_test_interface.nim",
    "libs/repro_build_engine/tests/t_engine_action_create_dyndep.nim",
    "libs/repro_core/tests/t_rust_dep_scanner.nim",
    "tests/unit/t_m9r83_install_mirror_action_shapes.nim",
    "tests/integration/t_repro_test_runner_aggregate_exit_code.nim",
    "tests/e2e/cmake-develop/t_e2e_repro_develop_cmake.nim"
  ]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent
  raise newException(IOError,
    "could not find the reprobuild checkout root above " & currentSourcePath())

proc requireSurface(): CtTestSurface =
  let located = locateCtTestSurface()
  if located.isNone:
    raise newException(IOError,
      "the canonical `ct test` surface was not found. Looked for " &
      lookupOrderDescription() & ". This is a refusal and not a skip: " &
      "without the surface this test cannot say anything about the boundary " &
      "it exists to measure, and reporting that as a pass would be the " &
      "opposite of the guarantee. `ct-test` is in the dev shell's packages " &
      "(flake.nix); run this from the dev shell, or set $" &
      CtTestSurfaceEnvVar & " to a binary that implements `test discover`.")
  located.get

template requireDocument(outcome: CtTestDiscoverOutcome) =
  ## ``require outcome.document != nil`` reads correctly and is a trap.
  ##
  ## When that comparison fails, ``unittest`` stringifies both operands to
  ## build the failure message, and ``$`` on a nil ``JsonNode`` dereferences
  ## it: a surface that answered without a document killed the binary with
  ## SIGSEGV instead of reporting a failure, taking every later case with it.
  ## Reducing the comparison to a plain ``bool`` before ``require`` sees it is
  ## what keeps the refusal legible. Observed, not theorised — pointing
  ## ``$CT_TEST`` at ``build/bin/repro_test_runner`` reproduces it.
  let documentWasReturned = not outcome.document.isNil
  require documentWasReturned

proc caseFilesFromCatalog(outcome: CtTestDiscoverOutcome):
    Table[string, seq[CtTestCatalogItem]] =
  ## Group every ``case`` item by the file it was found in. ``suite`` items
  ## are excluded here on purpose: a suite is a container, not a case, and
  ## counting it would inflate exactly the number this test compares.
  result = initTable[string, seq[CtTestCatalogItem]]()
  for item in catalogItems(outcome):
    if item.kind != "case": continue
    result.mgetOrPut(item.file, @[]).add(item)

proc trackedNimSources(repoRoot: string): seq[tuple[source: string; cases: int]] =
  let inventory = parseJson(readFile(repoRoot / InventoryPath))
  result = @[]
  for entry in inventory{"tests"}:
    if entry{"language"}.getStr() != "nim": continue
    result.add((source: entry{"source"}.getStr(),
                cases: entry{"staticCaseCount"}.getInt()))

suite "Reprobuild cases are addressable through the canonical ct test surface":

  test "the canonical surface is locatable and answers with a schema-1 catalog":
    let
      repoRoot = findRepoRoot()
      surface = requireSurface()
    checkpoint("surface binary: " & surface.binary &
               " (origin " & $surface.origin & ")")
    checkpoint("resolved against PATH=" &
               (if surface.searchPath.len > 0: surface.searchPath
                else: "<not searched: $" & CtTestSurfaceEnvVar & " decided>"))
    let outcome = discoverWorkspace(surface, repoRoot)
    checkpoint("command: " & outcome.command.join(" "))
    checkpoint("exit " & $outcome.exitCode & "; parseError=" & outcome.parseError)
    check outcome.exitCode == 0
    check outcome.parseError.len == 0
    requireDocument(outcome)
    check outcome.document{"schemaVersion"}.getInt() == 1

    let counts = counts(outcome)
    checkpoint("catalogs=" & $counts.catalogs & " items=" & $counts.items &
               " cases=" & $counts.caseItems & " suites=" & $counts.suiteItems &
               " other=" & $counts.otherItems &
               " errors=" & $counts.errorDiagnostics &
               " warnings=" & $counts.warningDiagnostics)
    # Non-degenerate, and self-consistent. The partition assertion is what
    # stops a future item kind from being absorbed into `caseItems`.
    check counts.catalogs >= 1
    check counts.caseItems > 1000
    check counts.caseItems + counts.suiteItems + counts.otherItems ==
      counts.items
    # An error diagnostic means the surface itself could not do its job, and
    # every count below it is then a count of what it managed anyway.
    check counts.errorDiagnostics == 0

  test "every tracked Nim source is addressable, or is named in the ledger":
    let
      repoRoot = findRepoRoot()
      surface = requireSurface()
      outcome = discoverWorkspace(surface, repoRoot)
    requireDocument(outcome)
    let
      byFile = caseFilesFromCatalog(outcome)
      discovered = block:
        var s = initHashSet[string]()
        for item in catalogItems(outcome): s.incl(item.file)
        s
      ledger = parseJson(readFile(repoRoot / LedgerPath))
    var ledgered = initHashSet[string]()
    for entry in ledger{"unaddressableSources"}:
      ledgered.incl(entry{"source"}.getStr())

    var
      addressable = 0
      unexpectedlyAbsent: seq[string] = @[]
      unexpectedlyPresent: seq[string] = @[]
    for tracked in trackedNimSources(repoRoot):
      if tracked.source in discovered:
        inc addressable
        if tracked.source in ledgered:
          unexpectedlyPresent.add(tracked.source)
      elif tracked.source notin ledgered:
        unexpectedlyAbsent.add(tracked.source)

    checkpoint("addressable through the surface: " & $addressable &
               "; ledgered as not addressable: " & $ledgered.len)
    if unexpectedlyAbsent.len > 0:
      checkpoint("NOT addressable and NOT in the ledger (" &
                 $unexpectedlyAbsent.len & "): " &
                 unexpectedlyAbsent.sorted.join(", "))
    if unexpectedlyPresent.len > 0:
      checkpoint("in the ledger but NOW addressable — delete these rows (" &
                 $unexpectedlyPresent.len & "): " &
                 unexpectedlyPresent.sorted.join(", "))
    check unexpectedlyAbsent.len == 0
    # The other direction, which is the one a growing ledger would hide: a
    # row that has started working must be removed, or the ledger stops
    # describing the gap and starts excusing it.
    check unexpectedlyPresent.len == 0
    check addressable > 0
    check byFile.len > 0

  test "per-source case counts agree with the tracked inventory":
    let
      repoRoot = findRepoRoot()
      surface = requireSurface()
      outcome = discoverWorkspace(surface, repoRoot)
    requireDocument(outcome)
    let
      byFile = caseFilesFromCatalog(outcome)
      ledger = parseJson(readFile(repoRoot / LedgerPath))
    var expectedDisagreement = initTable[string, int]()
    for entry in ledger{"caseCountDisagreements"}:
      expectedDisagreement[entry{"source"}.getStr()] =
        entry{"ctTestCaseCount"}.getInt()
    var ledgered = initHashSet[string]()
    for entry in ledger{"unaddressableSources"}:
      ledgered.incl(entry{"source"}.getStr())

    var
      compared = 0
      agreed = 0
      surprises: seq[string] = @[]
      staleAllowances: seq[string] = @[]
    for tracked in trackedNimSources(repoRoot):
      # Skip exactly the sources the ledger says the surface cannot see, and
      # nothing else.
      #
      # The obvious-looking condition here is `notin byFile and cases != 0`,
      # and it is wrong in a way that matters: `byFile` holds only CASE items,
      # so a source the surface still finds — its `suite` item is in the
      # catalog — but for which it has stopped emitting any case at all would
      # be skipped by it. That source also passes the "addressable, or
      # ledgered" case above, because it is still in the catalog. The total
      # loss of every case in a file would therefore have been invisible to
      # this gate, while `scripts/ct_test_surface_addressability.py` — which
      # skips on the discovered-FILE set — would have caught it on the next
      # regeneration. A gate weaker than its own generator is not a gate.
      #
      # Skipping on the ledger is the same skip as the generator's, because
      # the case above already asserts, in both directions, that the ledger
      # IS the set of tracked sources the surface does not discover.
      if tracked.source in ledgered: continue
      inc compared
      let observed =
        if tracked.source in byFile: byFile[tracked.source].len else: 0
      if observed == tracked.cases:
        inc agreed
        if tracked.source in expectedDisagreement:
          staleAllowances.add(tracked.source)
      elif tracked.source notin expectedDisagreement:
        surprises.add(tracked.source & ": inventory=" & $tracked.cases &
                      " surface=" & $observed)
      elif expectedDisagreement[tracked.source] != observed:
        surprises.add(tracked.source & ": ledger allows " &
                      $expectedDisagreement[tracked.source] &
                      " but the surface reported " & $observed)

    checkpoint("compared " & $compared & " sources; agreed " & $agreed)
    if surprises.len > 0:
      checkpoint("count disagreements not covered by the ledger: " &
                 surprises.sorted.join("; "))
    if staleAllowances.len > 0:
      checkpoint("ledger rows that now agree — delete them: " &
                 staleAllowances.sorted.join(", "))
    check surprises.len == 0
    check staleAllowances.len == 0
    check compared > 0

  test "case identities are stable across scopes and match the mapping":
    # Stability is the half of "stable identities" that a single invocation
    # cannot demonstrate. Two independent invocations at two different
    # discovery scopes must name each case identically, and the name must be
    # the one the documented mapping predicts from file/suite/case — not
    # merely some name that happens to be repeatable.
    let
      repoRoot = findRepoRoot()
      surface = requireSurface()
      workspaceOutcome = discoverWorkspace(surface, repoRoot)
    requireDocument(workspaceOutcome)
    let workspaceByFile = caseFilesFromCatalog(workspaceOutcome)

    var checkedCases = 0
    for source in IdentityStabilitySubset:
      checkpoint("subset source: " & source)
      require fileExists(repoRoot / source)
      require workspaceByFile.hasKey(source)

      let fileOutcome = discoverFile(surface, repoRoot, repoRoot / source)
      checkpoint("command: " & fileOutcome.command.join(" "))
      check fileOutcome.exitCode == 0
      requireDocument(fileOutcome)
      let fileByFile = caseFilesFromCatalog(fileOutcome)
      require fileByFile.hasKey(source)

      var workspaceIds, fileIds: seq[string] = @[]
      for item in workspaceByFile[source]: workspaceIds.add(item.id)
      for item in fileByFile[source]: fileIds.add(item.id)
      workspaceIds.sort()
      fileIds.sort()
      check workspaceIds == fileIds
      check workspaceIds.len > 0

      # And each id is the mapping's prediction, reconstructed from the
      # item's own file, suite and case name rather than copied from the id.
      #
      # The suite is taken by removing the case name and the separator from
      # the END of the selector, not by splitting on `::`. Suite titles in
      # this repository do contain `::`, so a split would attribute part of
      # the suite to the case and the reconstruction would agree with the id
      # for the wrong reason.
      for item in workspaceByFile[source]:
        require item.name.len > 0
        let tail = "::" & item.name
        require item.selector.endsWith(tail)
        let suiteName = item.selector[0 ..< item.selector.len - tail.len]
        check item.id == ctTestItemIdFor(item.file, suiteName, item.name)
        inc checkedCases

    checkpoint("identity-checked cases: " & $checkedCases)
    check checkedCases >= IdentityStabilitySubset.len

  test "case identities are unique across the whole catalog, bar the ledger":
    # "Stable identities" is worth nothing if two cases share one. The
    # identity is a slug — lowercased, whitespace collapsed to hyphens — so
    # collisions are possible in principle, and this measures how many there
    # are in practice rather than assuming none. Every colliding identity
    # must be named in the ledger, and every ledger entry must still collide.
    let
      repoRoot = findRepoRoot()
      surface = requireSurface()
      outcome = discoverWorkspace(surface, repoRoot)
    requireDocument(outcome)

    var occurrences = initCountTable[string]()
    var caseItems = 0
    for item in catalogItems(outcome):
      if item.kind != "case": continue
      inc caseItems
      occurrences.inc(item.id)

    var observedCollisions: seq[string] = @[]
    for id, n in occurrences:
      if n > 1: observedCollisions.add(id)
    observedCollisions.sort()

    let ledger = parseJson(readFile(repoRoot / LedgerPath))
    var ledgeredCollisions: seq[string] = @[]
    for entry in ledger{"identityCollisions"}:
      ledgeredCollisions.add(entry{"id"}.getStr())
    ledgeredCollisions.sort()

    checkpoint("case items: " & $caseItems & "; distinct identities: " &
               $occurrences.len & "; colliding identities: " &
               $observedCollisions.len)
    if observedCollisions != ledgeredCollisions:
      checkpoint("observed: " & observedCollisions.join(", "))
      checkpoint("ledgered: " & ledgeredCollisions.join(", "))
    check observedCollisions == ledgeredCollisions
    check caseItems > 1000

  test "the Reprobuild-only runner does not satisfy this surface":
    # The control that makes every assertion above mean what it says.
    #
    # `build/bin/repro_test_runner` is built unconditionally by
    # scripts/run_tests.sh before the suite executes, so inside a suite run it
    # is always here. Its absence is asserted rather than tolerated — the same
    # shape `t_repro_test_runner_catalog_selection` uses for the same binary —
    # because a control that quietly does not run is worse than no control:
    # every number in this file would keep being reported as if it had.
    let
      repoRoot = findRepoRoot()
      runner = repoRoot / "build" / "bin" /
        addFileExt("repro_test_runner", ExeExt)
    check fileExists(runner)
    if not fileExists(runner):
      checkpoint("control could not run: " & runner & " is not built. " &
                 "Build it (scripts/run_tests.sh does, before the suite) and " &
                 "run this again.")
      return

    putEnv(CtTestSurfaceEnvVar, runner)
    defer: delEnv(CtTestSurfaceEnvVar)
    let located = locateCtTestSurface()
    require located.isSome
    check located.get.binary == absolutePath(runner)

    let outcome = discoverWorkspace(located.get, repoRoot)
    checkpoint("control command: " & outcome.command.join(" "))
    checkpoint("control exit " & $outcome.exitCode &
               "; parseError=" & outcome.parseError)
    # It must not produce a catalog. If it does, the assertions above are not
    # about the canonical surface at all.
    let producedACatalog =
      outcome.exitCode == 0 and outcome.document != nil and
      outcome.document{"schemaVersion"}.getInt(-1) == 1 and
      counts(outcome).caseItems > 0
    check not producedACatalog
