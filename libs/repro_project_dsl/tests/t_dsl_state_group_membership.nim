## Named-Runnable-Edges N0 verification — `stateGroup "topology":` with N
## member resources resolves the group name to exactly those N addresses.
##
## Spec cite: Named-Runnable-Edges.md §3.3 / §4b; the N0 milestone
## Verification `t_dsl_state_group_membership`.

import std/[options, tables, unittest]

import repro_project_dsl
import repro_resources

# A hermetic stub provider so the `resource(...)` calls inside a
# `stateGroup` block have a registered typeId to lower against (an
# unknown typeId is a hard error in `resource(...)`).

type
  StubAttrs = object
    value: string

proc stubIdentity(inst: ResourceInstance): string =
  "sg:" & inst.address

proc stubDigest(inst: ResourceInstance): Digest256 =
  digestString(inst.typeId & "\x00" & inst.address)

proc stubObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  ObservedState(present: false)

proc stubApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
                  resourceId: stubIdentity(inst),
                  postWriteDigest: stubDigest(inst), present: true)

proc registerStub() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "sg.stub",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: stubApply)))
  registerExtension[StubAttrs]("sg.stub")

proc stubThing(name: string): ResourceRef =
  resource("sg.stub", name, StubAttrs(value: name))

suite "t_dsl_state_group_membership":

  setup:
    resetDesiredResources()
    resetStateGroupRegistry()
    registerStub()

  test "stateGroup resolves its name to exactly its N member addresses":
    stateGroup "topology":
      discard stubThing("topo-net")
      discard stubThing("topo-a")
      discard stubThing("topo-b")
    check stateGroupMembers("topology") == @["topo-net", "topo-a", "topo-b"]
    # The group record is registered exactly once.
    var groupHits = 0
    for g in registeredStateGroups():
      if g.name == "topology":
        inc groupHits
    check groupHits == 1

  test "nested resources are still collected into the desired graph":
    ## `stateGroup` is a grouping OVER the existing resource DSL — the
    ## members still land in the collected desired-resource graph.
    stateGroup "topology":
      discard stubThing("topo-net")
      discard stubThing("topo-a")
    let addrs = block:
      var acc: seq[string] = @[]
      for inst in collectedResources():
        acc.add(inst.address)
      acc
    check addrs == @["topo-net", "topo-a"]

  test "an unknown group name resolves to no members":
    stateGroup "topology":
      discard stubThing("topo-net")
    check stateGroupMembers("does-not-exist").len == 0

  test "two groups keep disjoint membership":
    stateGroup "net-only":
      discard stubThing("n1")
    stateGroup "compute":
      discard stubThing("c1")
      discard stubThing("c2")
    check stateGroupMembers("net-only") == @["n1"]
    check stateGroupMembers("compute") == @["c1", "c2"]
