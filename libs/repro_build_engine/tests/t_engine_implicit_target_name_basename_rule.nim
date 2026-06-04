## Named-Targets M1 verification: the basename + extension-stripping
## rule applied at edge emission time. Three fixture ``nim.c`` calls
## with ``output = "bin/codetracer"``, ``output = "bin/codetracer.exe"``,
## and ``output = "/abs/path/codetracer-cli"`` produce edges whose
## ``targetNames`` first entry is ``"codetracer"``, ``"codetracer"``,
## and ``"codetracer-cli"`` respectively.
##
## Each call lives in its own fixture package so the per-package
## same-name collision rule (exercised separately in
## ``t_engine_target_export_table_records_ambiguity``) doesn't fire
## on the two ``codetracer`` rows.
##
## Asserted against the engine's normalized graph artifact (the
## ``GraphFragment`` produced by ``buildPackageFragment``) — *not* via
## the CLI — so the test stays hermetic and doesn't need a tool
## profile, a runquota daemon, or a writeable project root.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope. Fixtures live in
## ``m1_fixtures_basename.nim`` (separate module) so the auto-
## generated ``runPackageProvider`` shim's ``isMainModule`` guard
## doesn't fire on the test binary.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_basename

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

suite "t_engine_implicit_target_name_basename_rule":

  test "t_engine_implicit_target_name_basename_rule":
    let plainPkg = fixturePackage("tEnginePlainBasenamePkg")
    let plainFragment = buildPackageFragment(
      plainPkg, dummyRequest(plainPkg), buildTEnginePlainBasenamePkgPackage,
      includeDefault = false)
    let plainActions = actionsFromFragment(plainFragment)
    check plainActions.len == 1
    check plainActions[0].id == "plain"
    check plainActions[0].targetNames == @["codetracer"]

    let exePkg = fixturePackage("tEngineExeSuffixPkg")
    let exeFragment = buildPackageFragment(
      exePkg, dummyRequest(exePkg), buildTEngineExeSuffixPkgPackage,
      includeDefault = false)
    let exeActions = actionsFromFragment(exeFragment)
    check exeActions.len == 1
    check exeActions[0].id == "exe-suffix"
    check exeActions[0].targetNames == @["codetracer"]

    let absPkg = fixturePackage("tEngineAbsolutePathPkg")
    let absFragment = buildPackageFragment(
      absPkg, dummyRequest(absPkg), buildTEngineAbsolutePathPkgPackage,
      includeDefault = false)
    let absActions = actionsFromFragment(absFragment)
    check absActions.len == 1
    check absActions[0].id == "absolute"
    check absActions[0].targetNames == @["codetracer-cli"]
