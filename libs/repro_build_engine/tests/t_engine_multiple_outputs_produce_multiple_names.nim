## Named-Targets M1 verification: a fixture ``gccCompile.compile``
## call against a tool with ``outputs output depfile`` emits one
## edge whose ``targetNames`` is ``@["foo", "foo"]`` after the
## basename + ``.o`` / ``.d`` extension strip. Both names are
## recorded in the target-export table, both pointing at the same
## edge handle. The same-name-within-package collision rule only
## fires across distinct edges (different ``actionId``), so two rows
## carrying the same name from the same action are allowed and the
## duplicate name still resolves unambiguously to a single edge.
##
## Compiled with ``-d:reproProviderMode`` (see ``scripts/run_tests.sh``
## path rule) so ``buildPackageFragment`` and the binary
## ``BuildActionDef`` payload codec are in scope.

import std/[unittest]

import repro_core
import repro_project_dsl

import m1_fixtures_multiple_outputs

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
        (node.stableName == "reprobuild.target-export-table.v1" or node.stableName == "reprobuild.target-export-table.v2"):
      return decodeTargetExportTablePayload(toBytes(node.payload))
  raise newException(ValueError,
    "fragment is missing the target-export-table metadata node")

suite "t_engine_multiple_outputs_produce_multiple_names":

  test "t_engine_multiple_outputs_produce_multiple_names":
    let pkg = fixturePackage("tEngineMultipleOutputsPkg")
    let fragment = buildPackageFragment(
      pkg, dummyRequest(pkg), buildTEngineMultipleOutputsPkgPackage,
      includeDefault = false)

    let actions = actionsFromFragment(fragment)
    check actions.len == 1
    let action = actions[0]
    check action.id == "compile-foo"
    # ``output = "foo.o"`` reduces to ``"foo"`` and
    # ``depfile = "foo.d"`` reduces to ``"foo"`` — both basenames
    # after extension stripping. The list is in ``outputFlags``
    # declaration order (``output`` first, then ``depfile``).
    check action.targetNames == @["foo", "foo"]

    # The target-export table carries one ``tekImplicit`` row per
    # name slot. Both rows carry the name ``"foo"`` and point at the
    # same edge handle (``compile-foo``). The collision within one
    # edge is allowed; the duplicate name still resolves to a single
    # edge so selection is unambiguous.
    let table = exportTableFromFragment(fragment)
    var fooRows: seq[TargetExportEntry] = @[]
    for entry in table.entries:
      if entry.name == "foo":
        fooRows.add(entry)
    check fooRows.len == 2
    for row in fooRows:
      check row.kind == tekImplicit
      # ``buildPackageFragment`` overrides the wrapper-baked owning
      # package with the calling package's name so the export rows
      # attribute the edge to the consumer (the ``build:`` body's
      # home), not the tool's defining module.
      check row.owningPackage == "tEngineMultipleOutputsPkg"
      check row.actionId == "compile-foo"
