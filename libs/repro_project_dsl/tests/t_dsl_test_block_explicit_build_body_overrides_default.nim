## Test-Edges-And-Parallel-Runner M0 verification: a ``test`` block
## whose ``build:`` body explicitly invokes
## ``nim_module.nim.c(source, output = "alt-path/custom")`` emits an
## edge whose implicit name is ``custom`` (the override's ``output``
## basename) — i.e. the user keeps full control by writing the call
## themselves and the M0 default synthesis is suppressed entirely.
##
## The assertion also verifies the bool-flag defaults (``threadsOn``,
## ``hintsOff``, ``warningsOff``) are NOT silently added when the
## user supplies their own ``build:`` body — the override is verbatim,
## not "synthesised body plus user overrides merged".

import std/[unittest]

import repro_core
import repro_project_dsl

import m0_fixtures_explicit_build

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
  ""

proc hasArg(action: BuildActionDef; name: string): bool =
  for arg in action.call.arguments:
    if arg.name == name:
      return true
  false

suite "t_dsl_test_block_explicit_build_body_overrides_default":

  test "t_dsl_test_block_explicit_build_body_overrides_default":
    let pkg = fixturePackage("tDslTestBlockExplicitBuildPkg")
    check pkg.tests.len == 1
    check pkg.tests[0].hasExplicitBuild

    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg),
      buildTDslTestBlockExplicitBuildPkgPackage,
      includeDefault = false)
    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    # Implicit name derived from the user's ``output`` argument via the
    # M1 basename rule — i.e. the same code path the default body
    # would have taken, just with the user's value instead of
    # ``"build/test-bin/<ident-kebab>"``.
    check action.targetNames == @["custom"]
    # The user's ``output`` value flows through verbatim.
    check encodedArg(action, "output") == "alt-path/custom"
    # And the edge is still tagged ``bakTest`` — the kind marker
    # comes from the ``test`` block, not from the (synthesised vs
    # user-supplied) call expression.
    check action.kind == bakTest

    # The M0 default flags must NOT be silently re-added when the user
    # supplies their own ``build:`` body. The override is verbatim;
    # the user's call passed neither ``threadsOn``, ``hintsOff``, nor
    # ``warningsOff``.
    check not action.hasArg("threadsOn")
    check not action.hasArg("hintsOff")
    check not action.hasArg("warningsOff")
