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
##       non-regression gate (run separately + reported);
##   (f)-(i) KEEP HOLDERS ARE NAMED: a `keep` consumer is persisted by id in
##       `keepHolders` (never in the dated map), beside any dated holders; a
##       later run in which only a dated consumer renews leaves the keep
##       holder named and the state pinned; the keep holder renewing under a
##       dated policy moves out of `keepHolders` (and back on a later keep);
##   (j)-(l) A RUN THAT DOES NOT CONSUME the state carries its lease forward
##       unchanged: a keep holder stays named and pinning, a dated holder
##       keeps its deadline (so the state stays reapable) — neither is
##       rewritten empty just because the state is in the graph unconsumed
##       — in the in-process reconcile and in the session reconcile (l).

import std/[tables, options, times, os, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox
from repro_provider_runtime import ProviderHandle   # the session resolver's type (l)

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

  # -------------------------------------------------------------------------
  # Keep holders are NAMED on disk (reprobuild-pm issue
  # 2026-10-09-a-keep-holders-identity-is-never-persisted-in-a-lease-record).
  #
  # Before the fix a `keep` holder was deleted from the dated `holders` map
  # and recorded nowhere else, so `effectiveDeadline == none` meant either
  # "a keep holder pins this" or "no dated holder exists" and no reader could
  # tell which, or name the pin. Every case below goes through a REAL
  # `StateStore` on a throwaway directory and reads the record back from
  # disk, so what is asserted is what a later run (or a restarted daemon)
  # can reconstruct — not an in-memory value that never reached the record.
  # -------------------------------------------------------------------------

  test "(f) a keep consumer is named in keepHolders, not in the dated map":
    let store = scratchStore("keep-named")
    let t0 = fromUnix(1_700_400_000)

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)

    let rec = readStateRecord(store, "cluster")
    check rec.keepHolders == @["pinner"]
    check not rec.holders.hasKey("pinner")
    check rec.holders.len == 0
    check rec.keepHoldersKnown                    # a current-format record
    # `none` is now unambiguous: it is pinned BY "pinner".
    check rec.effectiveDeadline.isNone
    check rec.lastRenewed == t0

  test "(g) mixed keep + delayed consumers: both holders are named":
    let store = scratchStore("keep-mixed")
    let t0 = fromUnix(1_700_500_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    # Two keep holders declared out of order, to pin the canonical
    # (ascending, de-duplicated) order of the persisted keep-holder list.
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard stubConsumer("anchor", "a",
      consumes = @[leased("cluster", "anchor", keep())])
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)

    let rec = readStateRecord(store, "cluster")
    check rec.keepHolders == @["anchor", "pinner"]
    check rec.holders.len == 1
    check rec.holders["slow"] == t0 + ttl
    # A consumer id is in at most one of the two holder sets.
    for id in rec.keepHolders:
      check not rec.holders.hasKey(id)
    check rec.effectiveDeadline.isNone            # keep dominates

  test "(h) a later run renewing ONLY a dated consumer keeps the keep pin":
    # The behaviour this fix changes on purpose. Before it, run 2 below wrote
    # `effectiveDeadline = some(t1 + ttl)`: the keep holder from run 1 had
    # left no trace in the record, so the merge could not know the state was
    # still pinned and silently re-armed a reap deadline under it.
    let store = scratchStore("keep-persists")
    let t0 = fromUnix(1_700_600_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)
    check readStateRecord(store, "cluster").effectiveDeadline.isNone

    # Run 2, a fresh process: only the dated consumer runs.
    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    let t1 = t0 + initDuration(minutes = 5)
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t1)

    let rec = readStateRecord(store, "cluster")
    check rec.keepHolders == @["pinner"]          # still named
    check rec.holders["slow"] == t1 + ttl         # the dated holder renewed
    check rec.effectiveDeadline.isNone            # still pinned
    check not reapableAt(rec, t1 + ttl + initDuration(days = 365))

  test "(i) a keep holder renewing under a dated policy leaves keepHolders":
    let store = scratchStore("keep-moves")
    let t0 = fromUnix(1_700_700_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)
    check readStateRecord(store, "cluster").keepHolders == @["pinner"]

    # Run 2: the SAME consumer now holds a dated lease. It moves out of
    # keepHolders into the dated map, and the pin goes with it.
    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", delayed(ttl))])
    let t1 = t0 + initDuration(minutes = 5)
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t1)

    let rec2 = readStateRecord(store, "cluster")
    check rec2.keepHolders.len == 0
    check rec2.holders["pinner"] == t1 + ttl
    check rec2.effectiveDeadline == some(t1 + ttl)
    check reapableAt(rec2, t1 + ttl)              # reapable again

    # Run 3: back to keep — it moves back, and the dated entry goes.
    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    let t2 = t1 + initDuration(minutes = 5)
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t2)

    let rec3 = readStateRecord(store, "cluster")
    check rec3.keepHolders == @["pinner"]
    check not rec3.holders.hasKey("pinner")
    check rec3.effectiveDeadline.isNone

  test "(j) an UNCONSUMED run keeps the keep holder named and the pin":
    let store = scratchStore("unconsumed-keep")
    let t0 = fromUnix(1_700_800_000)

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)
    check readStateRecord(store, "cluster").keepHolders == @["pinner"]

    # Run 2, a fresh process: the state is still in the graph, but nothing
    # consumes it — so it is reconciled as a plain resource (here it is
    # re-materialized, since the fresh world no longer has it) and its record
    # is re-written. The lease on it is untouched by that: only "pinner"
    # renewing under a dated policy, or an explicit teardown, ends the pin.
    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    let t1 = t0 + initDuration(minutes = 5)
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t1)

    let rec = readStateRecord(store, "cluster")
    check rec.keepHolders == @["pinner"]
    check rec.keepHoldersKnown
    check rec.effectiveDeadline.isNone
    check rec.lastRenewed == t0                   # no renewal happened in run 2
    check not reapableAt(rec, fromUnix(1_900_000_000))

  test "(k) an UNCONSUMED run keeps a dated deadline (the state stays reapable)":
    let store = scratchStore("unconsumed-dated")
    let t0 = fromUnix(1_700_900_000)
    let ttl = initDuration(minutes = 30)

    discard stubState("cluster", "up-1")
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t0)

    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    let t1 = t0 + initDuration(minutes = 5)
    discard reconcileResources(collectedResources(),
                               store = some(store), now = t1)

    # Before the carry-forward, run 2 wrote the record with NO holders and a
    # `none` deadline: a lapsed lease silently became a never-reap state.
    let rec = readStateRecord(store, "cluster")
    check rec.holders.len == 1
    check rec.holders["slow"] == t0 + ttl
    check rec.effectiveDeadline == some(t0 + ttl)
    check rec.lastRenewed == t0
    check not reapableAt(rec, t0 + ttl - initDuration(minutes = 1))
    check reapableAt(rec, t0 + ttl)

  test "(l) the SESSION reconcile carries an unconsumed lease forward too":
    # `reconcileResourcesViaSession` has its own copy of the persist step, so
    # it gets its own case. Its leaf ops go through the `inProcess` hybrid
    # gate to the stub driver — the store writes under test are the session
    # path's, and no provider binary is needed to reach them. `resolve` is
    # never called; it fails loudly if it is.
    let store = scratchStore("unconsumed-session")
    let t0 = fromUnix(1_701_000_000)
    let ttl = initDuration(minutes = 30)
    let noSession: ResourceSessionResolver = proc (typeId: string): ProviderHandle =
      raise newException(AssertionDefect, "unexpected session for " & typeId)
    let linked: ResourceInProcessPredicate = proc (typeId: string): bool = true

    discard stubState("cluster", "up-1")
    discard stubConsumer("pinner", "p",
      consumes = @[leased("cluster", "pinner", keep())])
    discard stubConsumer("slow", "s",
      consumes = @[leased("cluster", "slow", delayed(ttl))])
    discard reconcileResourcesViaSession(collectedResources(), noSession,
      store = some(store), now = t0, inProcess = linked)
    check readStateRecord(store, "cluster").keepHolders == @["pinner"]

    stubWorld = initTable[string, string]()
    resetDesiredResources()
    discard stubState("cluster", "up-1")
    discard reconcileResourcesViaSession(collectedResources(), noSession,
      store = some(store), now = t0 + initDuration(minutes = 5),
      inProcess = linked)

    let rec = readStateRecord(store, "cluster")
    check rec.keepHolders == @["pinner"]
    check rec.holders["slow"] == t0 + ttl
    check rec.effectiveDeadline.isNone
    check rec.lastRenewed == t0
