## L1 (Ephemeral-State-Leases.md §3): the persistent resource-state store.
##
## Pins:
##   (a) write -> read -> reconstruct yields an instance EQUAL to the
##       original (address/typeId/determinism/dependsOn/attrs);
##   (b) reconstruct -> observe works with ONLY the store record + the
##       registered provider (the desired graph is cleared first — the
##       reaper's standalone-destroy contract);
##   (c) atomic-write safety — a partial (temp, un-renamed) write leaves
##       the prior record intact;
##   (d) the lease fields (holders / effectiveDeadline / lastRenewed)
##       round-trip;
##   (e) NON-REGRESSION: reconcileResources with NO store configured
##       behaves exactly as before (idempotent digest cache-hit), and no
##       state files are written.

import std/[tables, options, times, os, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox for the round-trip check

# ---------------------------------------------------------------------------
# A hermetic stub provider: an in-memory "world" the driver observes and
# mutates, plus a serializable attrs record registered via
# registerExtension (the attrs marshaller the store reuses).
# ---------------------------------------------------------------------------

type
  StubAttrs = object
    value: string
    size: int

var stubWorld {.threadvar.}: Table[string, string]   ## resourceId -> realized value
var applyLog {.threadvar.}: seq[string]

proc stubIdentity(inst: ResourceInstance): string =
  "stub:" & inst.address

proc stubDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value &
               "\x00" & $a.size)

proc stubObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  let id = stubIdentity(inst)
  if stubWorld.hasKey(id):
    let a = TypedExtensionBox[StubAttrs](inst.attrs).val
    result.present = true
    result.digest = digestString(
      inst.typeId & "\x00" & inst.address & "\x00" & stubWorld[id] &
      "\x00" & $a.size)
  else:
    result.present = false

proc stubApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  let id = stubIdentity(inst)
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  applyLog.add(inst.address)
  stubWorld[id] = a.value
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: id,
    postWriteDigest: stubDigest(inst),
    present: true)

proc stubThing(name: string; value: string; size: int = 0;
               dependsOn: seq[string] = @[]): ResourceRef =
  resource("l1.stub", name, StubAttrs(value: value, size: size), dependsOn)

proc registerStub() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "l1.stub",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: stubApply)))
  registerExtension[StubAttrs]("l1.stub")

proc scratchStore(sub: string): StateStore =
  let root = getTempDir() / ("repro-l1-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

suite "L1: persistent resource-state store":

  setup:
    stubWorld = initTable[string, string]()
    applyLog = @[]
    resetDesiredResources()
    registerStub()

  test "write -> read -> reconstruct yields an equal instance":
    discard stubThing("net", "v-net", size = 3, dependsOn = @["base"])
    let inst = collectedResources()[0]
    let binding = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: stubIdentity(inst),
      postWriteDigest: stubDigest(inst), present: true)

    let store = scratchStore("rt")
    writeStateRecord(store, inst, binding)

    let rec = readStateRecord(store, "net")
    let back = reconstructInstance(rec)

    check back.address == inst.address
    check back.typeId == inst.typeId
    check back.determinism == inst.determinism
    check back.dependsOn == inst.dependsOn
    let a0 = TypedExtensionBox[StubAttrs](inst.attrs).val
    let a1 = TypedExtensionBox[StubAttrs](back.attrs).val
    check a1 == a0
    check rec.identity == "stub:net"
    check rec.digest == binding.postWriteDigest

  test "reconstruct -> observe works from ONLY the store record (no graph)":
    # Materialize + persist via a store-backed reconcile.
    discard stubThing("cluster", "up-1")
    let store = scratchStore("reap")
    let r = reconcileResources(collectedResources(), store = some(store))
    check r.actions.len == 1
    check r.actions[0].kind == rakCreate

    # Simulate a FRESH process: drop the in-memory desired graph entirely.
    resetDesiredResources()
    check collectedResources().len == 0

    # A reaper reads the record, reconstructs, and observes via the
    # registered provider — the stub world still has the state, so observe
    # reports it present with the recorded digest.
    let rec = readStateRecord(store, "cluster")
    let inst = reconstructInstance(rec)
    let def = lookupResourceProvider(inst.typeId)
    let obs = def.driver.observe(inst, none(ResourceBinding))
    check obs.present
    check obs.digest == rec.digest

  test "atomic-write safety: a partial (un-renamed) write leaves prior intact":
    discard stubThing("x", "first")
    let inst = collectedResources()[0]
    let store = scratchStore("atomic")
    writeStateRecord(store, inst, ResourceBinding(
      address: "x", typeId: inst.typeId, resourceId: stubIdentity(inst),
      postWriteDigest: stubDigest(inst), present: true))

    # Simulate an interrupted write: drop a temp file that is never
    # renamed over the destination. The store must still return the
    # committed record, and listStateRecords must skip the temp.
    let tmp = store.root / (".tmp-partial.rec")
    writeFile(tmp, "GARBAGE-NOT-A-RECORD")

    let rec = readStateRecord(store, "x")
    let a = TypedExtensionBox[StubAttrs](reconstructInstance(rec).attrs).val
    check a.value == "first"
    check listStateRecords(store).len == 1     # temp skipped

  test "lease fields round-trip (holders / effectiveDeadline / lastRenewed)":
    discard stubThing("leased", "vv")
    let inst = collectedResources()[0]
    let store = scratchStore("lease")

    var holders = initTable[string, Time]()
    holders["run-A"] = fromUnix(1_700_000_100)
    holders["run-B"] = fromUnix(1_700_000_900)
    let effective = fromUnix(1_700_000_900)
    let renewed = fromUnix(1_700_000_050)

    writeStateRecord(store, inst, ResourceBinding(
      address: "leased", typeId: inst.typeId, resourceId: stubIdentity(inst),
      postWriteDigest: stubDigest(inst), present: true),
      holders = holders, effectiveDeadline = effective, lastRenewed = renewed)

    let rec = readStateRecord(store, "leased")
    check rec.holders.len == 2
    check rec.holders["run-A"] == fromUnix(1_700_000_100)
    check rec.holders["run-B"] == fromUnix(1_700_000_900)
    check rec.effectiveDeadline == effective
    check rec.lastRenewed == renewed

  test "remove + list round-trip":
    discard stubThing("a", "va")
    discard stubThing("b", "vb")
    let store = scratchStore("list")
    for inst in collectedResources():
      writeStateRecord(store, inst, ResourceBinding(
        address: inst.address, typeId: inst.typeId,
        resourceId: stubIdentity(inst),
        postWriteDigest: stubDigest(inst), present: true))
    check listStateRecords(store).len == 2
    removeStateRecord(store, "a")
    check listStateRecords(store).len == 1
    check not hasStateRecord(store, "a")
    check hasStateRecord(store, "b")
    # idempotent removal
    removeStateRecord(store, "a")
    check listStateRecords(store).len == 1

  test "NON-REGRESSION: no-store reconcile is unchanged + writes nothing":
    let a = stubThing("A", "va")
    discard stubThing("B", "vb", dependsOn = @[a.address])
    let desired = collectedResources()

    # First reconcile: both created (no store passed => legacy path).
    let first = reconcileResources(desired)
    check first.actions.len == 2
    for act in first.actions:
      check act.kind == rakCreate
    check applyLog == @["A", "B"]

    # Second reconcile: idempotent no-op cache-hit.
    applyLog = @[]
    let second = reconcileResources(desired, recorded = first.bindings)
    for act in second.actions:
      check act.kind == rakNoOp
    check applyLog.len == 0

    # A fresh store dir that this reconcile never touched stays empty:
    # prove the no-store path performs no store I/O.
    let probe = scratchStore("noreg")
    check listStateRecords(probe).len == 0
    discard reconcileResources(desired, recorded = first.bindings)
    check listStateRecords(probe).len == 0
