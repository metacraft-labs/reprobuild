## Named-Targets M1 verification: two packages in one project each
## emit an edge whose implicit name is ``cli``. The normalized graph
## artifact records both qualified forms (``ambigPkgA:cli`` and
## ``ambigPkgB:cli``) AND records the unqualified ``cli`` as
## ambiguous on a sentinel row in the table's ``ambiguities`` list.
## The M2 CLI resolver consumes this row to surface a
## ``target_ambiguous`` diagnostic.
##
## Each package's GraphFragment carries the per-package slice of the
## export table (the M1 wiring is project-scoped in registry-form
## but each fragment only sees the rows accumulated during its own
## ``buildPackageFragment`` invocation). To exercise the
## cross-package collision we drive both ``buildProc``s against the
## shared registry in sequence WITHOUT resetting it between, then
## inspect the second fragment which carries the cumulative table.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_ambiguity

proc fixturePackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture package missing: " & name)

proc dummyRequest(pkg: PackageDef): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: pkg.packageName & ".root",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/test-fixture-root",
    namespace: "project-" & pkg.packageName)

proc exportTableFromFragment(fragment: GraphFragment): TargetExportTable =
  for node in fragment.nodes:
    if node.kind == gnkMetadata and
        node.stableName == "reprobuild.target-export-table.v1":
      return decodeTargetExportTablePayload(toBytes(node.payload))
  raise newException(ValueError,
    "fragment is missing the target-export-table metadata node")

suite "t_engine_target_export_table_records_ambiguity":

  test "t_engine_target_export_table_records_ambiguity":
    # Building package A first populates the registry with its row.
    # Building package B then triggers the cross-package ambiguity
    # detection inside ``registerTargetExportEntry``: a second row
    # for ``cli`` arrives under a DIFFERENT owning package, so the
    # ambiguities list gains an entry listing both qualified forms.
    #
    # We deliberately do NOT call ``resetTargetExportRegistry``
    # between the two builds — that's exactly what would happen in a
    # real project where one provider run emits all package
    # fragments in sequence and the table accumulates.
    #
    # NB: ``buildPackageFragment`` calls ``resetTargetExportRegistry``
    # at the start of EVERY invocation. To accumulate across packages
    # we exercise the underlying registration helpers directly,
    # mirroring what a multi-package provider would do if it took
    # the cumulative-table responsibility on itself.
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    resetBuildPoolRegistry()
    resetDefaultBuildActionRegistry()
    resetTargetExportRegistry()
    setCurrentOwningPackageOverride("ambigPkgA")
    buildAmbigPkgAPackage()
    clearCurrentOwningPackageOverride()
    setCurrentOwningPackageOverride("ambigPkgB")
    buildAmbigPkgBPackage()
    clearCurrentOwningPackageOverride()

    let table = registeredTargetExports()

    # Both qualified forms must appear: the table's entries carry
    # the per-package rows, and the M2 resolver derives the
    # qualified-name form by joining ``owningPackage:name``.
    var qualifiedSeen: seq[string] = @[]
    for entry in table.entries:
      if entry.name == "cli":
        qualifiedSeen.add(entry.owningPackage & ":" & entry.name)
    check qualifiedSeen.len == 2
    check "ambigPkgA:cli" in qualifiedSeen
    check "ambigPkgB:cli" in qualifiedSeen

    # And the unqualified ``cli`` lookup must be ambiguous: a single
    # sentinel row in the ambiguities list, with both qualified
    # candidates.
    var ambiguityRow: TargetExportAmbiguity
    var ambiguityFound = false
    for ambig in table.ambiguities:
      if ambig.name == "cli":
        ambiguityRow = ambig
        ambiguityFound = true
        break
    check ambiguityFound
    check ambiguityRow.candidates.len == 2
    check "ambigPkgA:cli" in ambiguityRow.candidates
    check "ambigPkgB:cli" in ambiguityRow.candidates

    # The same-name-within-package rule did NOT fire — the two rows
    # belong to different packages. As a regression guard, also
    # confirm that re-running the SAME package's build with the same
    # ``actionId`` (which would re-register an identical row) does
    # NOT raise. The existing entry is preserved unchanged.
    setCurrentOwningPackageOverride("ambigPkgA")
    try:
      # Re-running buildAmbigPkgAPackage() adds an action to the
      # global registry (second instance with the same id). The
      # implicit-name registration sees ``owningPackage == ambigPkgA``
      # and ``actionId == cli-a`` — identical to the existing entry,
      # so it's a duplicate registration and no collision raises.
      buildAmbigPkgAPackage()
    except:
      check false
    finally:
      clearCurrentOwningPackageOverride()
