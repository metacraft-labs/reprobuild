## Named-Runnable-Edges N0 verification — a run-edge with
## `consumes = @[leased("topology", delayed(minutes = 30))]` lowers +
## serializes + re-parses to an EQUAL graph; the `LeasedDep` policy
## survives the target-export-table codec round-trip.
##
## Also pins the additive/non-regression guarantee: a table that uses
## none of the N0 surfaces serializes + decodes to an EQUAL table, so
## pre-N0 recipes are unaffected by the v3 codec bump.
##
## Spec cite: Named-Runnable-Edges.md §3.2 / §4; the N0 milestone
## Verification `t_dsl_run_consumes_roundtrip`.

import std/[times, unittest]

import repro_project_dsl
import repro_resources

suite "t_dsl_run_consumes_roundtrip":

  test "delayed(minutes = 30) sugar type-checks and lowers to a LeasedDep":
    ## The spec's DSL sketch (§4): `leased("topology", delayed(minutes =
    ## 30))` must type-check via the `lease.nim` sugar constructors.
    let dep = leased("topology", delayed(minutes = 30))
    check dep.address == "topology"
    check dep.consumerId == "topology"      # defaults to the address
    check dep.policy.kind == lkDelayed
    check dep.policy.ttl == initDuration(minutes = 30)

  test "run-edge consumes round-trips through the target-export codec":
    resetTargetExportRegistry()
    run("topology-lease-smoke", build = "gate-action-id",
        consumes = @[leased("topology", delayed(minutes = 30))],
        args = @["--slice", "bounded"])
    let original = registeredTargetExports()

    # Lower + serialize + re-parse.
    let payload = encodeTargetExportTablePayload(original)
    let decoded = decodeTargetExportTablePayload(payload)

    # The whole table reconstructs equal (entries + ambiguities).
    check decoded == original

    # And the lease specifically survives: find the run-edge row and
    # reconstruct the LeasedDep from the decoded RunEdgeLease.
    var found = false
    for entry in decoded.entries:
      if entry.name == "topology-lease-smoke":
        found = true
        check entry.kind == tekRunEdge
        check entry.runArgs == @["--slice", "bounded"]
        check entry.consumes.len == 1
        let back = toLeasedDep(entry.consumes[0])
        check back.address == "topology"
        check back.policy.kind == lkDelayed
        check back.policy.ttl == initDuration(minutes = 30)
    check found

  test "immediate + keep policies also survive the round-trip":
    resetTargetExportRegistry()
    run("run-immediate", build = "bin-a",
        consumes = @[leased("grp-a", immediate())])
    run("run-keep", build = "bin-b",
        consumes = @[leased("grp-b", keep())])
    let original = registeredTargetExports()
    let decoded = decodeTargetExportTablePayload(
      encodeTargetExportTablePayload(original))
    check decoded == original
    for entry in decoded.entries:
      if entry.name == "run-immediate":
        check toLeasedDep(entry.consumes[0]).policy.kind == lkImmediate
      elif entry.name == "run-keep":
        check toLeasedDep(entry.consumes[0]).policy.kind == lkKeep

  test "NON-REGRESSION: a table with no N0 surfaces round-trips equal":
    ## A table built purely from the pre-N0 surfaces (implicit + explicit
    ## rows, no run-edge / consumes) must serialize + decode to an EQUAL
    ## table — the additive v3 codec does not perturb legacy graphs.
    resetTargetExportRegistry()
    registerImplicitTargetExports(
      actionId = "impl-action",
      owningPackage = "pkg",
      names = @["libfoo"],
      sourceFile = "recipe.nim",
      sourceLine = 3)
    registerExplicitTargetExport(
      BuildTargetDef(name: "foo", actions: @["explicit-action"],
                     sourceFile: "recipe.nim", sourceLine: 7),
      owningPackage = "pkg")
    let original = registeredTargetExports()
    for entry in original.entries:
      check entry.runArgs.len == 0
      check entry.consumes.len == 0
    let decoded = decodeTargetExportTablePayload(
      encodeTargetExportTablePayload(original))
    check decoded == original
