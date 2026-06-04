## Named-Targets M1 verification: a fixture tool with both
## ``outputs target aux`` and an
## ``implicitTargetName(call: CmakeBuildCall): string`` hook returning
## ``"cmake-" & call.target``. Emit a call with ``target = "kernel"``
## and ``aux = "build/kernel.aux.o"`` and confirm the first entry of
## ``targetNames`` is the hook's return (``"cmake-kernel"``) while the
## auxiliary entry from the ``aux`` flag survives as the second
## entry.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_hook

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

suite "t_engine_implicit_target_name_hook_overrides_canonical":

  test "t_engine_implicit_target_name_hook_overrides_canonical":
    let pkg = fixturePackage("tEngineHookConsumer")
    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg), buildTEngineHookConsumerPackage,
      includeDefault = false)
    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    check action.id == "cmake-build-kernel"
    # The hook's return ``"cmake-kernel"`` replaces the canonical
    # (first) ``targetNames`` entry — the basename rule would have
    # produced ``"kernel"`` from the ``target`` flag's value.
    # The auxiliary entry ``"kernel.aux"`` (basename of
    # ``build/kernel.aux.o`` with ``.o`` stripped) remains as the
    # second entry, per the M1 spec's "additional outputs flags
    # survive as subsequent entries" rule.
    check action.targetNames == @["cmake-kernel", "kernel.aux"]
