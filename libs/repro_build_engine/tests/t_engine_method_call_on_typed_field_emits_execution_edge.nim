## Typed-Outputs M1 verification: a call like
## ``edge.testBinary.run(filter = "case_x")`` emits an additional edge
## into the same ``buildPackageFragment`` whose inputs include the
## binary path and whose action id is the
## ``NimUnittestBinary.run`` typed-tool call. The new edge participates
## in the Named-Targets M1 target-export table like any other typed-
## tool edge.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule). Fixtures in a separate module so the auto-generated
## ``runPackageProvider`` shim's ``isMainModule`` guard doesn't fire on
## the test binary.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_method_call_dispatch

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

proc exportTableFromFragment(fragment: GraphFragment): TargetExportTable =
  for node in fragment.nodes:
    if node.kind == gnkMetadata and
        node.stableName == "reprobuild.target-export-table.v1":
      return decodeTargetExportTablePayload(toBytes(node.payload))
  raise newException(ValueError,
    "fragment is missing the target-export-table metadata node")

suite "t_engine_method_call_on_typed_field_emits_execution_edge":

  test "t_engine_method_call_on_typed_field_emits_execution_edge":
    let pkg = fixturePackage("tEngineMethodCallTypedFieldPkg")
    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg), buildTEngineMethodCallTypedFieldPkgPackage,
      includeDefault = false)

    let actions = actionsFromFragment(fragment)
    # Two edges: the build edge and the run edge from the UFCS method
    # call dispatch.
    check actions.len == 2

    var buildAction, runAction: BuildActionDef
    for action in actions:
      if action.id == "build-foo":
        buildAction = action
      elif action.id == "run-foo-case_x":
        runAction = action
    check buildAction.id == "build-foo"
    check runAction.id == "run-foo-case_x"

    # The run edge's action call is the ``NimUnittestBinary.run``
    # typed-tool surface (subcommand ``run`` of the synthesised
    # ``test-buildNimUnittest-method`` tool).
    check runAction.call.subcommand == "run"

    # The binary path was routed from ``self.path`` (the typed handle
    # the UFCS receiver carried) into the run edge's input set so the
    # action cache keys on the binary content.
    check "build/test-bin/foo" in runAction.inputs

    # The new edge participates in the target-export table just like
    # any other typed-tool edge — the basename of the input value is
    # the implicit name.
    let table = exportTableFromFragment(fragment)
    var runRow: TargetExportEntry
    var foundRunRow = false
    for entry in table.entries:
      if entry.actionId == "run-foo-case_x":
        runRow = entry
        foundRunRow = true
        break
    check foundRunRow
    check runRow.kind == tekImplicit
    check runRow.name == "foo"
