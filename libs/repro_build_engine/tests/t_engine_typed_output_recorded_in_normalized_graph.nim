## Typed-Outputs M1 verification: a ``buildPackageFragment`` invocation
## containing a typed-tool call with a typed output records the field
## name, type identifiers, and bound path in the emitted ``gnkAction``
## payload. Decode round-trip preserves all three.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope. Fixtures live in
## ``m1_fixtures_typed_output_recorded.nim`` (separate module) so the
## auto-generated ``runPackageProvider`` shim's ``isMainModule`` guard
## doesn't fire on the test binary.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_typed_output_recorded

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

suite "t_engine_typed_output_recorded_in_normalized_graph":

  test "t_engine_typed_output_recorded_in_normalized_graph":
    let pkg = fixturePackage("tEngineTypedOutputRecordedPkg")
    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg), buildTEngineTypedOutputRecordedPkgPackage,
      includeDefault = false)

    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    check action.id == "build-foo"

    # The typed-output entry survives the payload codec round-trip
    # (encode + emit as gnkAction payload + decode here). The
    # ``fieldName`` is what the DSL declared, the ``types`` list
    # carries both declared interface identifiers in source order,
    # and the ``path`` is the wrapper-evaluated ``binary`` flag value.
    check action.typedOutputs.len == 1
    let typedOutput = action.typedOutputs[0]
    check typedOutput.fieldName == "testBinary"
    check typedOutput.types == @["NimUnittestBinary", "TestBinary"]
    check typedOutput.path == "build/test-bin/foo"
