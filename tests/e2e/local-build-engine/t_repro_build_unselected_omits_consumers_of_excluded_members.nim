## An omitted-target ``repro build`` must not schedule run-edges of the
## ``test``, ``bench`` or ``lint`` collections, and it must not emit an
## action whose dependency closure reaches one of them either: that
## action cannot run without the excluded member, so emitting it leaves
## a dangling dependency that the engine refuses with
## ``unknown dependency <member> for <consumer>``.
##
## The fixture (``unselected_exclusion_fixture``) is a real package
## fragment produced by ``buildPackageFragment``: ``sdkProtocol`` is a
## direct ``test`` member, ``sdkNative`` depends on it and is a member of
## an opt-in ``authoring`` collection, ``sdkReport`` depends on
## ``sdkNative`` (a transitive consumer), and ``product`` is an ordinary
## action with no tie to any of them. Every action is a
## ``reprobuild.builtin.exec`` call, so lowering needs no tool profiles
## and the full engine-facing action list is observable. A second
## fixture package puts a consumer, declared before the member it
## depends on, on a dependency cycle through that member.
##
## A third fixture routes the same rule through the ``default``
## collection, which is what a bare ``repro build`` resolves to: a
## ``default`` member depends on a ``test`` member, a second one on a
## member of a collection the ``test`` collection nests, and the build
## through ``default`` must omit both whether or not ``default`` is named
## explicitly.

import std/[algorithm, sets, unittest]

import repro_build_engine
import repro_provider_runtime
import repro_project_dsl
import repro_cli_support
import repro_tool_profiles

import unselected_exclusion_fixture

proc fixtureSnapshot(packageName = "unselectedExclusionFixture";
    build: proc () = buildUnselectedExclusionFixturePackage):
    ProviderGraphSnapshot =
  var pkg: PackageDef
  for candidate in registeredPackages():
    if candidate.packageName == packageName:
      pkg = candidate
  check pkg.packageName == packageName
  let request = ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider-" & packageName,
    entryPointId: packageName & ".root",
    entryPointBodyHash: packageName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: "/tmp/test-fixture-root",
    namespace: "project-" & packageName)
  let fragment = buildPackageFragment(pkg, request, build,
    includeDefault = false)
  result.fragments.add(StoredGraphFragment(
    providerArtifactId: request.providerArtifactId,
    entryPointId: fragment.entryPointId,
    entryPointBodyHash: fragment.entryPointBodyHash,
    arguments: fragment.arguments,
    namespace: fragment.namespace,
    nodes: fragment.nodes,
    edges: fragment.edges,
    effectClaims: fragment.effectClaims,
    childEntryPoints: fragment.childEntryPoints,
    evaluationInputs: fragment.evaluationInputs))

proc lowered(selectors: openArray[string];
             snapshot = fixtureSnapshot()): seq[BuildAction] =
  lowerProviderSnapshot(snapshot, PathOnlyBuildIdentity(),
    "/tmp/test-fixture-root", selectors).actions

proc sortedIds(actions: openArray[BuildAction]): seq[string] =
  for action in actions:
    result.add(action.id)
  result.sort()

proc danglingDeps(actions: openArray[BuildAction]): seq[string] =
  ## The same closure check the engine's graph validation applies.
  var ids = initHashSet[string]()
  for action in actions:
    ids.incl(action.id)
  for action in actions:
    for dep in action.deps:
      if not ids.contains(dep):
        result.add(dep & " for " & action.id)

suite "t_repro_build_unselected_omits_consumers_of_excluded_members":

  test "omitted target drops the test member and every consumer of it":
    let actions = lowered([""])
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["fixture.product"]

  test "selecting the opt-in collection keeps its full dependency closure":
    let actions = lowered(["authoring"])
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) ==
      @["fixture.sdk_native", "fixture.sdk_protocol"]

  test "selecting the transitive consumer keeps its full dependency closure":
    let actions = lowered(["fixture.sdk_report"])
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) ==
      @["fixture.sdk_native", "fixture.sdk_protocol", "fixture.sdk_report"]

  test "selecting the test collection builds only its member":
    let actions = lowered(["test"])
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["fixture.sdk_protocol"]

  test "the exclusion reaches every action on a cycle through a member":
    let actions = lowered([""], fixtureSnapshot(
      "unselectedExclusionCycleFixture",
      buildUnselectedExclusionCycleFixturePackage))
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["cycle.kept"]

  test "the default collection omits members that reach an excluded member":
    let snapshot = fixtureSnapshot("unselectedExclusionDefaultFixture",
      buildUnselectedExclusionDefaultFixturePackage)
    let actions = lowered(["default"], snapshot)
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["dflt.helper"]

  test "a nested collection of test is excluded from the omitted target":
    let snapshot = fixtureSnapshot("unselectedExclusionDefaultFixture",
      buildUnselectedExclusionDefaultFixturePackage)
    let actions = lowered([""], snapshot)
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["dflt.helper", "dflt.product"]

  test "selecting an excluded consumer beside default keeps its closure":
    let snapshot = fixtureSnapshot("unselectedExclusionDefaultFixture",
      buildUnselectedExclusionDefaultFixturePackage)
    let actions = lowered(["default", "opt-in"], snapshot)
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["dflt.consumer", "dflt.helper",
      "dflt.nested_consumer", "dflt.test_direct", "dflt.test_nested"]

  test "selecting the nested collection by name builds its member":
    let snapshot = fixtureSnapshot("unselectedExclusionDefaultFixture",
      buildUnselectedExclusionDefaultFixturePackage)
    let actions = lowered(["test"], snapshot)
    check danglingDeps(actions) == newSeq[string]()
    check sortedIds(actions) == @["dflt.test_direct", "dflt.test_nested"]
