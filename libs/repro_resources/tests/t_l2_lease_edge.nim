## L2 (Ephemeral-State-Leases.md §2.2/§2.3): per-consume-edge lease policy
## + renewal + reference-counted max-deadline.
##
## Pins (a hermetic STUB provider with a MATERIALIZATION WITNESS — a global
## counter the driver's `apply(create)` bumps, so a test asserts EXACTLY how
## many times the state was materialized):
##
##   (a) REUSE + RENEW: two store-backed reconciles of a `delayed(ttl)`
##       consumer over the same state materialize the state ONCE (witness
##       == 1 — the 2nd run reuses the present, digest-matching record) and
##       the 2nd run RENEWS (the holder deadline + lastRenewed + effective
##       deadline all advance);
##   (b) IMMEDIATE + DELAYED max-deadline: two consumers of one state, one
##       `immediate` + one `delayed(30m)`, leave effectiveDeadline == the
##       30m-from-now deadline, NOT now — the immediate holder does not
##       shorten it;
##   (c) KEEP never reaps: a `keep` consumer (even alongside a `delayed`
##       holder) leaves the record with NO reap deadline (`none`, NOT an
##       epoch-0/PAST sentinel that a `deadline < now` reap gate would
##       wrongly destroy), keep dominating;
##   (d) additivity: a bare-`dependsOn`, no-store reconcile is unchanged —
##       the pre-existing `t_resource_provider_lane.nim` is the companion
##       non-regression gate (run separately + reported).

import std/[tables, options, times, os, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox

# ---------------------------------------------------------------------------
# Stub provider with a MATERIALIZATION WITNESS. `stubMaterializations` is
# bumped once per `apply` that actually creates/updates real-world state, so
# the tests can prove single-materialization cross-run reuse.
# ---------------------------------------------------------------------------

type
  StubAttrs = object
    value: string

var stubWorld {.threadvar.}: Table[string, string]   ## resourceId -> realized value
var stubMaterializations {.threadvar.}: int          ## the witness counter (all addresses)
var stubMatByAddr {.threadvar.}: Table[string, int]  ## per-address materialization witness

proc stubIdentity(inst: ResourceInstance): string =
  "stub:" & inst.address

proc stubDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc stubObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  let id = stubIdentity(inst)
  if stubWorld.hasKey(id):
    result.present = true
    result.digest = digestString(
      inst.typeId & "\x00" & inst.address & "\x00" & stubWorld[id])
  else:
    result.present = false

proc stubApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  let id = stubIdentity(inst)
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  inc stubMaterializations              # <-- the materialization witness
  stubMatByAddr[inst.address] = stubMatByAddr.getOrDefault(inst.address) + 1
  stubWorld[id] = a.value
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: id,
    postWriteDigest: stubDigest(inst),
    present: true)

proc registerStub() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "l2.stub",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: stubApply)))
  registerExtension[StubAttrs]("l2.stub")

# The leased STATE resource (what consumers hold a lease on).
proc stubState(name: string; value: string): ResourceRef =
  resource("l2.stub", name, StubAttrs(value: value))

# A CONSUMER resource that consumes the state under a lease policy.
proc stubConsumer(name: string; value: string;
                  consumes: seq[LeasedDep]): ResourceRef =
  resource("l2.stub", name, StubAttrs(value: value), consumes = consumes)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-l2-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

# "Never reap" is `none(Time)` on the record — NOT an epoch-0/PAST
# sentinel. A reaper reaps only a `some(t)` with `t <= now`, so a `none`
# effective deadline is unconditionally safe from the reap gate.
proc reapableAt(rec: ResourceStateRecord; now: Time): bool =
  ## The reap predicate L3 will use: reap iff there is a dated deadline
  ## that has passed. A `none` (keep / no dated holder) is NEVER reapable.
  rec.effectiveDeadline.isSome and rec.effectiveDeadline.get <= now

suite "L2: per-consume-edge lease policy + renewal + max-deadline":

  setup:
    stubWorld = initTable[string, string]()
    stubMaterializations = 0
    stubMatByAddr = initTable[string, int]()
    resetDesiredResources()
    registerStub()

  test "(a) reuse + renew: delayed consumer over two runs materializes once":
    let store = scratchStore("reuse")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)

    # --- Run 1: state + a delayed(30m) consumer. State is materialized. ---
    discard stubState("cluster", "up-1")
    discard stubConsumer("smoke", "probe",
      consumes = @[leased("cluster", "smoke", delayed(ttl))])
    let r1 = reconcileResources(collectedResources(),
                                store = some(store), now = t0)
    check stubMaterializations == 2        # state + consumer, each created once
    check hasStateRecord(store, "cluster")

    let rec1 = readStateRecord(store, "cluster")
    check rec1.holders.hasKey("smoke")
    check rec1.holders["smoke"] == t0 + ttl
    check rec1.effectiveDeadline == some(t0 + ttl)
    check rec1.lastRenewed == t0

    # --- Run 2, later: a FRESH process — the live world is dropped, so the
    # ONLY evidence the state is up is the store record. A digest-matching,
    # present record must drive REUSE (no observe / no apply): the reuse must
    # come from the STORE, not from an observable live world. Without the L2
    # reuse path, observe would report the state absent and re-materialize it
    # (witness would bump); with reuse, the witness stays put. ---
    stubWorld = initTable[string, string]()      # simulate a fresh process
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    discard stubConsumer("smoke", "probe",
      consumes = @[leased("cluster", "smoke", delayed(ttl))])
    let t1 = t0 + initDuration(minutes = 5)
    let matBefore = stubMaterializations         # == 2 (state + consumer, run 1)
    let r2 = reconcileResources(collectedResources(),
                                store = some(store), now = t1)

    # The STATE was NOT re-materialized (reuse from the store record); its
    # reconcile action is a no-op even though the live world was empty.
    let clusterAct = block:
      var k: ResourceActionKind
      for a in r2.actions:
        if a.address == "cluster": k = a.kind
      k
    check clusterAct == rakNoOp
    # The consumer "smoke" (not itself a leased state) re-materializes in the
    # fresh world; the STATE does not. So exactly ONE new materialization,
    # and the state's lifetime witness stays at 1.
    check stubMaterializations == matBefore + 1

    let rec2 = readStateRecord(store, "cluster")
    check rec2.holders["smoke"] == t1 + ttl       # deadline ADVANCED
    check rec2.effectiveDeadline == some(t1 + ttl)
    check rec2.lastRenewed == t1                  # renewal moved forward
    check rec2.effectiveDeadline.get > rec1.effectiveDeadline.get

    # The definitive single-materialization witness: across BOTH runs the
    # leased STATE address was materialized exactly ONCE.
    check stubMatByAddr["cluster"] == 1

  test "(b) immediate + delayed: max-deadline (immediate does not shorten)":
    let store = scratchStore("maxdl")
    let t0 = fromUnix(1_700_100_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    discard stubConsumer("fast", "f",
      consumes = @[leased("cluster", "fast", immediate())])
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)

    let rec = readStateRecord(store, "cluster")
    check rec.holders["fast"] == t0               # immediate -> now
    check rec.holders["slow"] == t0 + ttl         # delayed -> now + 30m
    # The effective (reap) deadline is the MAX: the 30m one, NOT now.
    check rec.effectiveDeadline == some(t0 + ttl)
    check rec.effectiveDeadline != some(t0)

  test "(c) keep never sets a reap deadline (keep dominates delayed)":
    let store = scratchStore("keep")
    let t0 = fromUnix(1_700_200_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)

    let rec = readStateRecord(store, "cluster")
    # keep pins with NO deadline -> not in the dated holder map...
    check not rec.holders.hasKey("pinner")
    check rec.holders.hasKey("slow")
    # ...and it dominates: the effective deadline is `none` (never reap),
    # NOT the 30m delayed deadline and NOT an epoch-0/PAST sentinel.
    check rec.effectiveDeadline.isNone

    # REAP-SAFETY: a pinned (keep) state must NEVER be selected for reaping
    # by the reaper's `deadline <= now` gate, at ANY wall clock. An epoch-0
    # sentinel would make this FAIL (fromUnix(0) <= now is always true).
    check not reapableAt(rec, t0)
    check not reapableAt(rec, t0 + ttl + initDuration(hours = 1))
    check not reapableAt(rec, fromUnix(1_900_000_000))     # far future

    # Positive control: a DELAYED-only state (no keep holder) IS reapable
    # once its dated deadline passes — proving `reapableAt` is not vacuously
    # false and the never-reap result above is meaningful.
    resetDesiredResources()
    discard stubState("delayedOnly", "d-1")
    discard stubConsumer("dc", "d",
      consumes = @[leased("delayedOnly", "dc", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)
    let datedRec = readStateRecord(store, "delayedOnly")
    check datedRec.effectiveDeadline == some(t0 + ttl)
    check not reapableAt(datedRec, t0)                     # before deadline
    check reapableAt(datedRec, t0 + ttl)                   # AT deadline -> reap
    check reapableAt(datedRec, t0 + ttl + initDuration(minutes = 1))

  test "(d) deadlineFrom mapping is exactly immediate/delayed/keep":
    let now = fromUnix(1_700_300_000)
    check deadlineFrom(immediate(), now) == some(now)
    check deadlineFrom(delayed(initDuration(minutes = 10)), now) ==
      some(now + initDuration(minutes = 10))
    check deadlineFrom(keep(), now).isNone

  test "(e) bare dependsOn (no lease) reconcile is unchanged + writes no lease":
    # Non-regression in this file too: a plain dependsOn graph, no consumes,
    # reconciles exactly as pre-L2 (create then idempotent no-op), and even
    # with a store attached carries NO lease fields (not a leased state).
    let store = scratchStore("bare")
    let a = stubState("A", "va")
    discard resource("l2.stub", "B", StubAttrs(value: "vb"),
                     dependsOn = @[a.address])
    let desired = collectedResources()

    let first = reconcileResources(desired, store = some(store))
    check first.actions.len == 2
    for act in first.actions:
      check act.kind == rakCreate
    check stubMaterializations == 2

    # Records exist (L1) but carry NO holders / no reap deadline.
    let recA = readStateRecord(store, "A")
    check recA.holders.len == 0
    check recA.effectiveDeadline.isNone

    # Second reconcile over the same graph is idempotent (digest cache-hit),
    # no new materialization.
    resetDesiredResources()
    let a2 = stubState("A", "va")
    discard resource("l2.stub", "B", StubAttrs(value: "vb"),
                     dependsOn = @[a2.address])
    let matBefore = stubMaterializations
    let second = reconcileResources(collectedResources(),
                                    recorded = first.bindings,
                                    store = some(store))
    for act in second.actions:
      check act.kind == rakNoOp
    check stubMaterializations == matBefore   # nothing re-materialized
