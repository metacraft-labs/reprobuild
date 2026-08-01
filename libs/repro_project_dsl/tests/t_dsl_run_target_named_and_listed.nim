## Named-Runnable-Edges N0 verification — `run "name", ...` registers a
## run-target export entry (a `tekRunEdge` row) resolvable by name, while
## a bare/anonymous run-edge keeps its implicit name unchanged.
##
## Spec cite: Named-Runnable-Edges.md §3.1 / §4a; the N0 milestone
## Verification `t_dsl_run_target_named_and_listed`.

import std/[unittest]

import repro_project_dsl
import repro_resources

suite "t_dsl_run_target_named_and_listed":

  test "run \"name\", build = handle registers a tekRunEdge export row":
    resetTargetExportRegistry()
    run("topology-lease-smoke", build = "gate-action-id")
    let table = registeredTargetExports()
    var found: TargetExportEntry
    var hits = 0
    for entry in table.entries:
      if entry.name == "topology-lease-smoke":
        inc hits
        found = entry
    check hits == 1
    check found.kind == tekRunEdge
    check found.actionId == "gate-action-id"

  test "run-target carries args + is resolvable by its given name":
    resetTargetExportRegistry()
    run("t-run-with-args", build = "bin-id",
        args = @["--slice", "bounded"])
    let table = registeredTargetExports()
    var found = false
    for entry in table.entries:
      if entry.name == "t-run-with-args":
        found = true
        check entry.runArgs == @["--slice", "bounded"]
        check entry.kind == tekRunEdge
    check found

  test "a bare implicit-name edge keeps its implicit name (tekImplicit)":
    ## Anonymous / implicitly-named run-edges MUST keep working unchanged:
    ## the implicit-target export path still produces a `tekImplicit` row,
    ## untouched by the new `run "name"` surface.
    resetTargetExportRegistry()
    registerImplicitTargetExports(
      actionId = "t_topology_lease-action",
      owningPackage = "infra",
      names = @["t_topology_lease"],
      sourceFile = "recipe.nim",
      sourceLine = 10)
    let table = registeredTargetExports()
    var found: TargetExportEntry
    var hits = 0
    for entry in table.entries:
      if entry.name == "t_topology_lease":
        inc hits
        found = entry
    check hits == 1
    check found.kind == tekImplicit
    check found.actionId == "t_topology_lease-action"

  test "named run-target and a bare edge coexist in the same table":
    resetTargetExportRegistry()
    registerImplicitTargetExports(
      actionId = "bare-edge-action",
      owningPackage = "infra",
      names = @["t_bare_edge"],
      sourceFile = "recipe.nim",
      sourceLine = 5)
    run("named-run", build = "named-run-action")
    let table = registeredTargetExports()
    var sawBare, sawNamed = false
    for entry in table.entries:
      if entry.name == "t_bare_edge":
        sawBare = true
        check entry.kind == tekImplicit
      elif entry.name == "named-run":
        sawNamed = true
        check entry.kind == tekRunEdge
    check sawBare
    check sawNamed
