## Test-Edges-And-Parallel-Runner M0 verification: a fixture project
## with three ``test`` blocks (no explicit ``build:`` body) emits three
## ordinary build edges; their implicit target names equal the
## ident-kebab form of the block (``local-build-engine-smoke`` for
## ``test localBuildEngineSmoke:``), derived from the ``output``
## parameter of the synthesised ``nim.c`` call per Named-Targets M1.
##
## The synthesised call is
## ``nim_module.nim.c(source = "...",
##                    output = "build/test-bin/<ident-kebab>",
##                    threadsOn = true, hintsOff = true,
##                    warningsOff = true)``;
## the implicit name comes out of the ``output`` flag's basename (after
## extension stripping, which is a no-op here — the test binary has no
## conventional artifact extension).
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope. Fixtures live in
## ``m0_fixtures_implicit_name.nim`` (separate module) so the
## auto-generated ``runPackageProvider`` shim's ``isMainModule`` guard
## doesn't fire on the test binary.

import std/[unittest]

import repro_core
import repro_project_dsl

import m0_fixtures_implicit_name

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

suite "t_dsl_test_block_implicit_name_from_synthesised_out":

  test "t_dsl_test_block_implicit_name_from_synthesised_out":
    let pkg = fixturePackage("tDslTestBlockImplicitNamePkg")
    # The parsed-package view records the three declared test blocks
    # with their ident-kebab forms — independent of the engine wiring,
    # this is the inspection point the DSL surface exposes.
    check pkg.tests.len == 3
    let kebabNames = block:
      var s: seq[string] = @[]
      for t in pkg.tests:
        s.add(t.kebabName)
      s
    check kebabNames == @[
      "local-build-engine-smoke",
      "repro-build-action",
      "hcr-agent-spawn"]

    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg),
      buildTDslTestBlockImplicitNamePkgPackage,
      includeDefault = false)
    let actions = actionsFromFragment(fragment)
    check actions.len == 3
    # Order in the fragment matches declaration order — each test
    # block synthesises exactly one ``nim_module.nim.c`` call into the
    # package's build proc, in source order.
    let names = block:
      var s: seq[string] = @[]
      for a in actions:
        check a.targetNames.len == 1
        s.add(a.targetNames[0])
      s
    check names == @[
      "local-build-engine-smoke",
      "repro-build-action",
      "hcr-agent-spawn"]

    # And every synthesised edge is tagged ``bakTest`` so downstream
    # consumers (``repro test``, the M3 protocol-level runner) can
    # enumerate test edges without scanning the whole graph.
    for a in actions:
      check a.kind == bakTest
