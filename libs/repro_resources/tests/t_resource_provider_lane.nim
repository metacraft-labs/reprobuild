## Slice 2 (Composable-Resource-Types.md): the generic external-provider
## resource lane.
##
## Pins:
##   (a) a MOCK resource type is authored purely via
##       `registerResourceProvider` + `registerExtension` (no edit to
##       reprobuild's closed enums);
##   (b) `resource(...)` collects a small graph and the reconciler
##       applies A before B where B `dependsOn` A;
##   (c) a second reconcile is all no-op (idempotent / digest cache-hit);
##   (d) an unknown typeId is a HARD error, not a silent skip;
##   (e) the attrs box round-trips by `typeId` through the marshaller.

import std/[tables, options, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox for the round-trip check

# ---------------------------------------------------------------------------
# The mock provider: an in-memory "world" the driver observes and mutates.
# A thread-local so the reconciler (which may run on any thread) sees it.
# ---------------------------------------------------------------------------

type
  MockThingAttrs = object
    value: string

var mockWorld {.threadvar.}: Table[string, string]   ## resourceId -> realized value
var applyLog {.threadvar.}: seq[string]               ## addresses in apply order

proc mockIdentity(inst: ResourceInstance): string =
  "mock:" & inst.address

proc mockDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[MockThingAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc mockObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  let id = mockIdentity(inst)
  if mockWorld.hasKey(id):
    result.present = true
    result.digest = digestString(
      inst.typeId & "\x00" & inst.address & "\x00" & mockWorld[id])
  else:
    result.present = false

proc mockApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  let id = mockIdentity(inst)
  let a = TypedExtensionBox[MockThingAttrs](inst.attrs).val
  applyLog.add(inst.address)
  mockWorld[id] = a.value
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: id,
    postWriteDigest: mockDigest(inst),
    present: true)

# The typed wrapper a defining repo would export (lowers to `resource`).
proc mockThing(name: string; value: string;
               dependsOn: seq[string] = @[]): ResourceRef =
  resource("mock.thing", name, MockThingAttrs(value: value), dependsOn)

proc registerMock() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "mock.thing",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: mockIdentity,
      digest: mockDigest,
      observe: mockObserve,
      apply: mockApply)))
  registerExtension[MockThingAttrs]("mock.thing")

suite "slice 2: generic external-provider resource lane":

  setup:
    mockWorld = initTable[string, string]()
    applyLog = @[]
    resetDesiredResources()
    registerMock()

  test "provider authored purely via registration":
    check isResourceProviderRegistered("mock.thing")
    let def = lookupResourceProvider("mock.thing")
    check def.determinism == rdVolatile
    check def.driver.apply != nil

  test "resource(...) collects a graph; reconcile respects dependsOn":
    let a = mockThing("A", "va")
    discard mockThing("B", "vb", dependsOn = @[a.address])
    let desired = collectedResources()
    check desired.len == 2
    # Per-instance determinism carried from the provider default.
    check desired[0].determinism == rdVolatile

    let r = reconcileResources(desired)
    # Both created.
    check r.actions.len == 2
    for act in r.actions:
      check act.kind == rakCreate
    # A applied before B (B depends on A).
    check applyLog == @["A", "B"]
    check r.bindings.len == 2

  test "second reconcile is all no-op (idempotent digest cache-hit)":
    let a = mockThing("A", "va")
    discard mockThing("B", "vb", dependsOn = @[a.address])
    let desired = collectedResources()

    let first = reconcileResources(desired)
    check first.bindings.len == 2

    applyLog = @[]
    let second = reconcileResources(desired, recorded = first.bindings)
    for act in second.actions:
      check act.kind == rakNoOp
    # Nothing was applied the second time.
    check applyLog.len == 0

  test "a changed attribute drives an update, not a no-op":
    discard mockThing("A", "va")
    let first = reconcileResources(collectedResources())

    resetDesiredResources()
    discard mockThing("A", "va-CHANGED")
    let second = reconcileResources(collectedResources(),
                                    recorded = first.bindings)
    check second.actions.len == 1
    check second.actions[0].kind == rakUpdate

  test "unknown typeId lookup is a hard error":
    expect KeyError:
      discard lookupResourceProvider("no.such.type")
    # And instantiating an unknown type also hard-errors (via lookup).
    expect KeyError:
      discard resource("no.such.type", "x", MockThingAttrs(value: "v"))

  test "attrs box marshals + unmarshals by typeId to an equal value":
    discard mockThing("A", "roundtrip-me")
    let inst = collectedResources()[0]
    let wire = marshalAttrs(inst.attrs)
    let back = unmarshalAttrs(inst.typeId, wire)
    let orig = TypedExtensionBox[MockThingAttrs](inst.attrs).val
    let got = TypedExtensionBox[MockThingAttrs](back).val
    check got == orig
    check back.typeId == "mock.thing"

  test "unknown typeId marshalling is a hard error":
    expect KeyError:
      discard unmarshalAttrs("no.such.type", "{}")
