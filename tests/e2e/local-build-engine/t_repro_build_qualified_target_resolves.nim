## Named-Targets M5 verification: the qualified ``<package>:<name>``
## form resolves to the specific package's edge in a multi-fragment
## project, while the bare unqualified name fires the M2 ambiguity
## diagnostic. This is the M5 deliverable that promotes the
## qualified-name form to a first-class selector everywhere the M2
## resolver is consulted.
##
## Test pattern: M5 reuses the M2 ``m2_fixtures_ambiguity`` fixture
## (two packages each emitting one typed-tool call whose implicit
## name is ``cli``) and exercises the resolver in-process via
## ``lowerProviderSnapshot`` against a synthetic two-fragment
## ``ProviderGraphSnapshot``. Same rationale as the M2 sibling test:
## each ``repro.nim`` evaluates one package per provider run, so a
## multi-fragment scenario is built directly from ``buildPackageFragment``
## rather than standing up the cross-process provider runtime. The
## resolver / aggregator covered here is precisely the code path
## that ``repro build pkgA:cli`` exercises on the CLI; the dispatch
## arm's typed catches translate the same exceptions to exit-2 +
## stderr text via the shared ``renderAmbiguousTargetDiagnostic``
## helper that the M2 e2e suites already exercise end-to-end.

import std/[strutils, unittest]

import repro_build_engine
import repro_provider_runtime
import repro_project_dsl
import repro_cli_support
import repro_tool_profiles

import m2_fixtures_ambiguity

proc fixturePackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "fixture package missing: " & name)

proc dummyRequest(pkg: PackageDef): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider-" & pkg.packageName,
    entryPointId: pkg.packageName & ".root",
    entryPointBodyHash: pkg.packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/test-fixture-root",
    namespace: "project-" & pkg.packageName)

proc storedOf(fragment: GraphFragment;
              providerArtifactId: string): StoredGraphFragment =
  StoredGraphFragment(
    providerArtifactId: providerArtifactId,
    entryPointId: fragment.entryPointId,
    entryPointBodyHash: fragment.entryPointBodyHash,
    arguments: fragment.arguments,
    namespace: fragment.namespace,
    nodes: fragment.nodes,
    edges: fragment.edges,
    effectClaims: fragment.effectClaims,
    childEntryPoints: fragment.childEntryPoints,
    evaluationInputs: fragment.evaluationInputs)

suite "t_repro_build_qualified_target_resolves":

  test "t_repro_build_qualified_target_resolves":
    let pkgA = fixturePackage("m2AmbigPkgA")
    let pkgB = fixturePackage("m2AmbigPkgB")
    let fragmentA = buildPackageFragment(pkgA, dummyRequest(pkgA),
      buildM2AmbigPkgAPackage, includeDefault = false)
    let fragmentB = buildPackageFragment(pkgB, dummyRequest(pkgB),
      buildM2AmbigPkgBPackage, includeDefault = false)

    var snapshot: ProviderGraphSnapshot
    snapshot.fragments.add(storedOf(fragmentA, "test-provider-A"))
    snapshot.fragments.add(storedOf(fragmentB, "test-provider-B"))

    # M5 step 1: classifyBuildSelector recognises ``<package>:<name>``
    # as the qualified form. The selector kind is the structural
    # discriminator M2 introduced; M5 verifies it is honoured by the
    # downstream resolver below.
    let qualifiedA = classifyBuildSelector("m2AmbigPkgA:cli")
    check qualifiedA.kind == bskQualified
    check qualifiedA.package == "m2AmbigPkgA"
    check qualifiedA.name == "cli"

    let qualifiedB = classifyBuildSelector("m2AmbigPkgB:cli")
    check qualifiedB.kind == bskQualified
    check qualifiedB.package == "m2AmbigPkgB"
    check qualifiedB.name == "cli"

    let bareName = classifyBuildSelector("cli")
    check bareName.kind == bskName
    check bareName.name == "cli"

    # M5 step 2: aggregateTargetExportTable + the shared resolver
    # translate each form correctly without surfacing the
    # cross-package ambiguity that the bare name produces.
    let exportTable = aggregateTargetExportTable(snapshot)

    let resolvedA = resolveTargetExportSelector(exportTable,
      @[], @[], "m2AmbigPkgA:cli")
    check resolvedA.kind == trkResolved
    check resolvedA.actionId == "build-cli-a"
    check resolvedA.owningPackage == "m2AmbigPkgA"

    let resolvedB = resolveTargetExportSelector(exportTable,
      @[], @[], "m2AmbigPkgB:cli")
    check resolvedB.kind == trkResolved
    check resolvedB.actionId == "build-cli-b"
    check resolvedB.owningPackage == "m2AmbigPkgB"

    # M5 step 3: the bare name still surfaces ambiguity with both
    # candidates listed in qualified form. This is the M2 contract
    # M5 preserves — qualified-name support adds resolution paths
    # without weakening the ambiguity diagnostic.
    let resolvedAmbig = resolveTargetExportSelector(exportTable,
      @[], @[], "cli")
    check resolvedAmbig.kind == trkAmbiguous
    check resolvedAmbig.candidates.len == 2
    check "m2AmbigPkgA:cli" in resolvedAmbig.candidates
    check "m2AmbigPkgB:cli" in resolvedAmbig.candidates

    # M5 step 4: end-to-end via lowerProviderSnapshot — the qualified
    # form translates to the specific package's edge without raising
    # ``BuildTargetAmbiguousError``. The full lowering would require a
    # populated ``PathOnlyBuildIdentity`` (tool-profile resolution);
    # the resolver itself runs before that, so we catch the deeper
    # ``ValueError`` from ``lowerGraphAction`` and inspect the action
    # id it cites — same trick the M2 ambiguity test uses.
    let identity = PathOnlyBuildIdentity()
    var qualifiedAResolved = false
    var qualifiedBResolved = false

    try:
      discard lowerProviderSnapshot(snapshot, identity,
        "/tmp/test-fixture-root", "m2AmbigPkgA:cli")
    except BuildTargetAmbiguousError as e:
      check false  # qualified form must NOT raise ambiguity
      discard e
    except BuildTargetUnknownError as e:
      check false
      discard e
    except ValueError as err:
      # ``build-cli-a`` is package A's action id; reaching this point
      # with that id in the diagnostic message proves the qualified
      # selector translated to A's edge before the tool-resolution
      # step. ``build-cli-b`` must NOT appear.
      qualifiedAResolved = err.msg.contains("build-cli-a") and
        not err.msg.contains("build-cli-b")
    check qualifiedAResolved

    try:
      discard lowerProviderSnapshot(snapshot, identity,
        "/tmp/test-fixture-root", "m2AmbigPkgB:cli")
    except BuildTargetAmbiguousError as e:
      check false
      discard e
    except BuildTargetUnknownError as e:
      check false
      discard e
    except ValueError as err:
      qualifiedBResolved = err.msg.contains("build-cli-b") and
        not err.msg.contains("build-cli-a")
    check qualifiedBResolved

    # M5 step 5: bare ``cli`` still raises ``BuildTargetAmbiguousError``
    # through the full lowering pass. The diagnostic carries both
    # qualified candidates so the user can re-run with either form
    # (which step 4 proves resolves cleanly).
    var sawAmbiguous = false
    var ambigErr: ref BuildTargetAmbiguousError = nil
    try:
      discard lowerProviderSnapshot(snapshot, identity,
        "/tmp/test-fixture-root", "cli")
    except BuildTargetAmbiguousError as err:
      sawAmbiguous = true
      ambigErr = err
    check sawAmbiguous
    if ambigErr != nil:
      check ambigErr.selectorName == "cli"
      check ambigErr.candidates.len == 2
      check "m2AmbigPkgA:cli" in ambigErr.candidates
      check "m2AmbigPkgB:cli" in ambigErr.candidates

    # M5 step 6: the shared diagnostic renderer emits both candidates
    # in the byte-identical text shape M2's CLI dispatch arm prints
    # to stderr (so the helper that --hcr-target qualified-form
    # collision avoidance and JSON consumers depend on stays
    # observed by an automated test).
    if ambigErr != nil:
      let rendered = renderAmbiguousTargetDiagnostic(ambigErr[])
      check "m2AmbigPkgA:cli" in rendered
      check "m2AmbigPkgB:cli" in rendered
      check "re-run with the qualified" in rendered
