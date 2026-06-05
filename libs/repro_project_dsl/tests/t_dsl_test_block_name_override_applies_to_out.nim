## Test-Edges-And-Parallel-Runner M0 verification: a ``test`` block
## with ``name "alt"`` produces an edge whose implicit name is ``alt``
## and whose ``output`` argument ends in ``/alt`` — both derived from
## the same override. The override is applied to the synthesised
## ``output`` string at the call site, so the M1 implicit-name
## basename rule consumes it uniformly with non-overridden defaults
## (no special-case branch in the name resolver).

import std/[strutils, unittest]

import repro_core
import repro_project_dsl

import m0_fixtures_name_override

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

proc actionsFromFragment(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    result.add(decodeBuildActionPayload(toBytes(node.payload)))

proc encodedArg(action: BuildActionDef; name: string): string =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg.encodedValue
  raise newException(ValueError, "argument missing: " & name)

suite "t_dsl_test_block_name_override_applies_to_out":

  test "t_dsl_test_block_name_override_applies_to_out":
    let pkg = fixturePackage("tDslTestBlockNameOverridePkg")
    check pkg.tests.len == 1
    check pkg.tests[0].ident == "localBuildEngineSmoke"
    check pkg.tests[0].kebabName == "local-build-engine-smoke"
    check pkg.tests[0].nameOverride == "alt"

    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg),
      buildTDslTestBlockNameOverridePkgPackage,
      includeDefault = false)
    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    # The implicit name comes from Named-Targets M1's basename rule
    # applied to the ``output`` arg's value; with ``name "alt"`` set,
    # the synthesised output path is ``build/test-bin/alt`` and the
    # implicit name reduces to ``alt`` (no extension to strip).
    check action.targetNames == @["alt"]
    let outputValue = encodedArg(action, "output")
    check outputValue.endsWith("/alt")
    check outputValue == "build/test-bin/alt"
    check action.kind == bakTest
