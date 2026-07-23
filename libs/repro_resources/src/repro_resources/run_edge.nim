## Named-Runnable-Edges N0 — the recipe-authoring surface for run-targets
## and leased resource subgraphs (spec §3.3 / §4).
##
## This module lives in `repro_resources` (NOT `repro_project_dsl`)
## because it bridges the two lanes: it converts a `LeasedDep` (the
## resource-lane lease value, `lease.nim`) into the DSL-layer
## `RunEdgeLease` projection carried on a `TargetExportEntry`, and it
## reads the collected desired-resource graph (`collect.nim`) to resolve a
## `stateGroup`'s membership. `repro_resources` already imports
## `repro_project_dsl`; the reverse dependency does not exist, so the
## run-edge surface has to sit on this side of the layering.
##
## Three additions, all reusing landed machinery:
##
##   * `run "name", build = <handle>, consumes = @[...], args = @[...]` —
##     names a run-edge as a run TARGET (a `tekRunEdge` row registered via
##     `registerRunEdgeExport`, reusing Named-Targets M1's collision /
##     ambiguity machinery). An anonymous/implicitly-named run-edge keeps
##     working unchanged — this is opt-in sugar over the export table.
##   * `stateGroup "name":` — registers a NAMED resource subgraph (the
##     leasable unit) over the resources declared inside its block, using
##     the EXISTING resource DSL (`resource(...)`).
##   * `leased(group, policy)` — reused verbatim from `lease.nim`; the
##     run-edge's `consumes` is `seq[LeasedDep]`, identical in type to
##     `ResourceInstance.consumes`.

import std/times                      # Duration / inSeconds / initDuration
import repro_project_dsl              # RunEdgeLease / registerRunEdgeExport / stateGroup registry
import repro_resources/lease          # LeasedDep / LeasePolicy / LeaseKind
import repro_resources/collect        # collectedResources (desired-graph snapshot)

# Named-Runnable-Edges N0: the LeasedDep <-> RunEdgeLease projection below
# casts the policy kind via ``ord``, assuming ``RunEdgeLeaseKind`` (DSL
# layer) and ``LeaseKind`` (resource layer) enumerate the three policies
# in the SAME order. This is the one place the two enums are coupled;
# reordering either without the other would silently mis-map a policy
# through the serialization round-trip. Pin the coupling at compile time
# so such a reorder is a build error, not a runtime corruption.
static:
  doAssert ord(relKeep) == ord(lkKeep),
    "RunEdgeLeaseKind/LeaseKind ordinal drift: keep"
  doAssert ord(relImmediate) == ord(lkImmediate),
    "RunEdgeLeaseKind/LeaseKind ordinal drift: immediate"
  doAssert ord(relDelayed) == ord(lkDelayed),
    "RunEdgeLeaseKind/LeaseKind ordinal drift: delayed"
  doAssert ord(high(RunEdgeLeaseKind)) == ord(high(LeaseKind)),
    "RunEdgeLeaseKind/LeaseKind cardinality drift"

proc toRunEdgeLease*(dep: LeasedDep): RunEdgeLease =
  ## Project a resource-lane `LeasedDep` onto the DSL-layer
  ## `RunEdgeLease` the target-export table carries. The lease *value*
  ## type is not redefined — this is a lossless field copy whose enum
  ## ordinals line up (see `RunEdgeLeaseKind`), so the policy survives the
  ## serialization round-trip and N2 can rebuild the `LeasedDep`.
  RunEdgeLease(
    address: dep.address,
    consumerId: dep.consumerId,
    policyKind: RunEdgeLeaseKind(ord(dep.policy.kind)),
    ttlSeconds: dep.policy.ttl.inSeconds)

proc toLeasedDep*(lease: RunEdgeLease): LeasedDep =
  ## The inverse of `toRunEdgeLease` — reconstruct the `LeasedDep` from a
  ## decoded run-edge row. N2's lease bridge consumes this to reconcile +
  ## renew the named `stateGroup`. `ttlSeconds` is meaningful only for the
  ## delayed policy; the other kinds ignore it (matching `lease.nim`).
  let policy =
    case LeaseKind(ord(lease.policyKind))
    of lkKeep: keep()
    of lkImmediate: immediate()
    of lkDelayed: delayed(initDuration(seconds = lease.ttlSeconds))
  LeasedDep(address: lease.address, consumerId: lease.consumerId,
            policy: policy)

proc run*(name: string; build: string;
          consumes: openArray[LeasedDep] = [];
          args: openArray[string] = [];
          owningPackage = "") =
  ## Name a run-edge as a run TARGET (spec §4a). `build` is the id of the
  ## build edge whose closure produces the runnable artifact (the compiled
  ## gate). `args` is forwarded to the execution by N1; `consumes` is the
  ## leased-state list N2's bridge reconciles + renews around the exec.
  ##
  ## Registers exactly one `tekRunEdge` row via `registerRunEdgeExport`,
  ## reusing the Named-Targets collision/ambiguity path. This does NOT
  ## change how anonymous run-edges behave — they still carry their
  ## implicit name; `run "name", ...` is additive sugar that also makes
  ## the edge resolvable by the given name.
  var leases: seq[RunEdgeLease] = @[]
  for dep in consumes:
    leases.add(toRunEdgeLease(dep))
  registerRunEdgeExport(
    name = name,
    owningPackage = owningPackage,
    actionId = build,
    runArgs = args,
    consumes = leases)

template stateGroup*(groupName, body: untyped) =
  ## Declare a NAMED resource subgraph — the leasable/reapable unit (spec
  ## §3.3). Spelled `stateGroup "topology":` + an indented block of
  ## `resource(...)` calls. Every resource added inside `body` becomes a
  ## member of the group; the group name resolves to exactly those member
  ## addresses (`stateGroupMembers`) for N2's reconcile. The nested
  ## resources use the EXISTING resource DSL unchanged — they are still
  ## collected into the desired-resource graph; `stateGroup` only records
  ## which addresses belong together.
  ##
  ## `groupName` is `untyped` (rather than `string`) so the command-call
  ## block form `stateGroup "topology":` parses — mirroring the
  ## `suite name:` / `test name:` contract; it is used as a string
  ## expression below. It is deliberately NOT named `name` so template
  ## hygiene cannot rewrite the `name:` field label in the
  ## `StateGroupDef(...)` constructor below.
  block:
    let stateGroupName: string = groupName
    let stateGroupFirstIndex = collectedResources().len
    body
    let stateGroupAllResources = collectedResources()
    var stateGroupMemberAddrs: seq[string] = @[]
    for stateGroupIdx in stateGroupFirstIndex ..< stateGroupAllResources.len:
      stateGroupMemberAddrs.add(stateGroupAllResources[stateGroupIdx].address)
    registerStateGroup(StateGroupDef(
      name: stateGroupName,
      members: stateGroupMemberAddrs,
      sourceFile: instantiationInfo().filename,
      sourceLine: instantiationInfo().line))
