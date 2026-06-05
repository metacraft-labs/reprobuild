## Test-Edges-And-Parallel-Runner M0 verification: a ``test`` block
## with no explicit ``build:`` body produces an action whose argv
## contains ``--threads:on --hints:off --warnings:off`` — the three
## per-test compile defaults the M0 spec mandates.
##
## The check inspects the synthesised call's ``PublicCliArg`` entries
## directly: each boolFlag in the bundled ``nim`` typed-tool wrapper
## carries an ``alias`` field (``"--threads:on"`` etc.) that becomes
## the rendered argv token when the value is ``true``. Asserting on
## the encoded values keeps the test independent of the argv-rendering
## helper (which lives in ``repro_cli_support`` and would re-introduce
## a profile / resolved-executable dependency the M0 surface does not
## need).

import std/[strutils, unittest]

import repro_core
import repro_project_dsl

import m0_fixtures_default_flags

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

proc lookupArg(action: BuildActionDef; name: string): PublicCliArg =
  for arg in action.call.arguments:
    if arg.name == name:
      return arg
  raise newException(ValueError, "argument missing: " & name)

suite "t_dsl_test_block_default_compile_flags":

  test "t_dsl_test_block_default_compile_flags":
    let pkg = fixturePackage("tDslTestBlockDefaultFlagsPkg")
    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg),
      buildTDslTestBlockDefaultFlagsPkgPackage,
      includeDefault = false)
    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    check action.kind == bakTest

    # The three M0-mandated defaults — each is a boolFlag on the
    # ``nim`` typed-tool wrapper whose alias becomes the rendered argv
    # token when the value is ``true``. The encoded-value form is
    # ``"true"`` for a ``true`` bool boolFlag (see ``cliArg`` overload
    # for bool in ``runtime_core``).
    let threads = lookupArg(action, "threadsOn")
    check threads.alias == "--threads:on"
    check threads.encodedValue == "true"
    check threads.nimType.toLowerAscii() == "bool"

    let hints = lookupArg(action, "hintsOff")
    check hints.alias == "--hints:off"
    check hints.encodedValue == "true"
    check hints.nimType.toLowerAscii() == "bool"

    let warnings = lookupArg(action, "warningsOff")
    check warnings.alias == "--warnings:off"
    check warnings.encodedValue == "true"
    check warnings.nimType.toLowerAscii() == "bool"
