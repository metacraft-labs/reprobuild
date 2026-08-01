## L3 (Ephemeral-State-Leases.md §4): the crash-safe reaper.
##
## These cases drive the reaper over an IN-PROCESS stub provider (the
## `rtInProcess` transport) with a DESTROY WITNESS LOG — a global seq the
## stub's `apply(rakDestroy)` appends to, so a test asserts EXACTLY which
## addresses were destroyed and IN WHICH ORDER (reverse topo). The stub is
## the same shape as the L1/L2 stubs (a `Table` fake world keyed by the
## provider's identity), so `observe` reports a state present iff the stub
## world still holds it — letting us prove the already-absent no-op and
## idempotency non-vacuously.
##
## SESSION-TRANSPORT NOTE (honest): the reaper's `rtSession` transport
## dispatches destroy over the RP provider session via the SAME
## `observeViaSession` / `applyViaSession` procs the RP5b integration test
## (`tests/integration/t_rp5b_resource_driver_via_protocol.nim`) proves
## end-to-end against a real launched provider child. The reaper simply
## routes its `observe`/`apply(rakDestroy)` through those procs when
## `transport.kind == rtSession`. A dedicated live-session reap (launching a
## provider binary just to destroy) is HEAVY (an RP1 provider build per
## test) and is deferred to the L5 topology integration, which exercises the
## session-destroy path on a real provider. Here the core selection
## predicate, reverse-topo, crash-safety, idempotency, and the `repro reap`
## seam are proven hermetically over the in-process transport.

import std/[tables, options, times, os, strutils, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox

# ---------------------------------------------------------------------------
# Stub provider with a DESTROY WITNESS LOG.
# ---------------------------------------------------------------------------

type
  StubAttrs = object
    value: string

var stubWorld {.threadvar.}: Table[string, string]   ## resourceId -> realized value
var destroyLog {.threadvar.}: seq[string]             ## addresses destroyed, in order
var observeLog {.threadvar.}: seq[string]             ## addresses observed, in order

proc stubIdentity(inst: ResourceInstance): string =
  "stub:" & inst.address

proc stubDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc stubObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  observeLog.add(inst.address)
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
  case action
  of rakDestroy:
    destroyLog.add(inst.address)          # <-- the destroy witness
    stubWorld.del(id)
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: id, present: false)
  else:
    stubWorld[id] = a.value
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: id, postWriteDigest: stubDigest(inst), present: true)

proc registerStub() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "l3.stub",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: stubApply)))
  registerExtension[StubAttrs]("l3.stub")

proc stubState(name, value: string): ResourceRef =
  resource("l3.stub", name, StubAttrs(value: value))

proc stubConsumer(name, value: string; consumes: seq[LeasedDep]): ResourceRef =
  resource("l3.stub", name, StubAttrs(value: value), consumes = consumes)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-l3-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

# Materialize a leased state (+ its consumer) into the store so we have a
# real, reconstructable record to reap.
proc materialize(store: StateStore; stateName, consumerId: string;
                 policy: LeasePolicy; now: Time) =
  resetDesiredResources()
  discard stubState(stateName, "up")
  discard stubConsumer(consumerId & "-c", "probe",
    consumes = @[leased(stateName, consumerId, policy)])
  discard reconcileResources(collectedResources(), store = some(store), now = now)

suite "L3: crash-safe reaper":

  setup:
    stubWorld = initTable[string, string]()
    destroyLog = @[]
    observeLog = @[]
    resetDesiredResources()
    registerStub()

  test "(1) an EXPIRED state is reaped: destroy called, record removed":
    let store = scratchStore("expired")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)
    check hasStateRecord(store, "cluster")

    # Sweep AFTER the deadline.
    let later = t0 + ttl + initDuration(minutes = 1)
    let report = reapOnce(store, now = later)

    check destroyLog == @["cluster"]                 # destroy was called
    check not hasStateRecord(store, "cluster")       # record removed
    check report.reaped.len == 1
    check report.reaped[0].address == "cluster"
    check report.reaped[0].wasPresent                # a real (present) destroy

  test "(2) a still-leased state (deadline in the FUTURE) is NOT reaped":
    let store = scratchStore("leased")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    # Sweep BEFORE the deadline: the holder is live, the deadline is future.
    let report = reapOnce(store, now = t0 + initDuration(minutes = 5))
    check destroyLog.len == 0
    check hasStateRecord(store, "cluster")
    check report.reaped.len == 0
    # The leased state is KEPT (and so is the consumer record, which carries
    # no dated deadline — never-reap).
    check "cluster" in report.skipped

  test "(3) a KEEP state (effectiveDeadline == none) is NEVER reaped (reap-safety)":
    let store = scratchStore("keep")
    let t0 = fromUnix(1_700_000_000)
    materialize(store, "cluster", "pinner", keep(), t0)
    let rec = readStateRecord(store, "cluster")
    check rec.effectiveDeadline.isNone              # the never-reap record

    # Reap at t0, far past t0, and the far future: NONE of them select it.
    for probe in @[t0, t0 + initDuration(days = 3650),
                   fromUnix(1_900_000_000)]:
      let report = reapOnce(store, now = probe)
      check destroyLog.len == 0
      check hasStateRecord(store, "cluster")
      check "cluster" in report.skipped

    # The predicate itself: a none-deadline record is never reapable.
    check not isReapable(rec, fromUnix(1_900_000_000))

  test "(4) an ORPHANED lease (holder killed, deadline passed) IS reaped":
    # Simulate an orphan: a delayed lease was renewed at t0, then the
    # consumer process died. Nothing renews it; the store record still
    # carries the (now-passed) dated holder + effectiveDeadline. A fresh
    # process (empty in-memory graph) reaps purely from the store.
    let store = scratchStore("orphan")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    # Fresh process: drop the in-memory desired graph entirely. The reaper
    # must rely ONLY on the store.
    resetDesiredResources()
    let report = reapOnce(store, now = t0 + ttl + initDuration(hours = 1))
    check destroyLog == @["cluster"]
    check not hasStateRecord(store, "cluster")
    check report.reaped[0].wasPresent

  test "(5) reap of an already-ABSENT state is a clean no-op + record removed":
    let store = scratchStore("absent")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    # Simulate a prior crashed run that already destroyed the world but did
    # NOT get to remove the record: clear the stub world, keep the record.
    stubWorld = initTable[string, string]()
    check hasStateRecord(store, "cluster")

    let report = reapOnce(store, now = t0 + ttl + initDuration(minutes = 1))
    # observe reported ABSENT, so no destroy was issued...
    check destroyLog.len == 0
    # ...but the stale record is STILL removed (idempotent resume).
    check not hasStateRecord(store, "cluster")
    check report.reaped.len == 1
    check not report.reaped[0].wasPresent            # already-absent no-op

  test "(6) reverse-topo: nic -> container -> network reaps nic BEFORE container BEFORE network":
    # The reap set is three LEASED STATES: nic dependsOn container dependsOn
    # network (the persisted `dependsOn` edges the reaper reads from the
    # store). Each is leased under `delayed(ttl)` by its own consumer so all
    # three carry a dated deadline and are selected. Destroy MUST run in the
    # REVERSE of the dependency order: nic, then container, then network — a
    # dependent torn down before the state it depends on.
    let store = scratchStore("topo")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)

    resetDesiredResources()
    let net = stubState("network", "n")
    let cont = resource("l3.stub", "container", StubAttrs(value: "c"),
                        dependsOn = @[net.address])
    discard resource("l3.stub", "nic", StubAttrs(value: "i"),
                     dependsOn = @[cont.address])
    # One holder-consumer per state so each gets a dated deadline. Consumers
    # themselves carry no dated deadline (never-reap), so they are skipped.
    discard stubConsumer("h-net", "hn",
      consumes = @[leased("network", "hn", delayed(ttl))])
    discard stubConsumer("h-cont", "hc",
      consumes = @[leased("container", "hc", delayed(ttl))])
    discard stubConsumer("h-nic", "hi",
      consumes = @[leased("nic", "hi", delayed(ttl))])
    discard reconcileResources(collectedResources(), store = some(store), now = t0)

    for a in @["network", "container", "nic"]:
      check hasStateRecord(store, a)

    let report = reapOnce(store, now = t0 + ttl + initDuration(minutes = 1))
    # nic before container before network — the destroy witness proves order.
    check destroyLog == @["nic", "container", "network"]
    for a in @["nic", "container", "network"]:
      check not hasStateRecord(store, a)
    check report.reaped.len == 3
    # The three consumer records (never-reap) survive.
    for c in @["h-net", "h-cont", "h-nic"]:
      check hasStateRecord(store, c)

  test "(7) idempotency: running reap twice is safe (2nd run no-ops)":
    let store = scratchStore("idem")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    let later = t0 + ttl + initDuration(minutes = 1)
    let first = reapOnce(store, now = later)
    check first.reaped.len == 1
    check destroyLog == @["cluster"]

    # Second sweep: the record is gone, nothing to do.
    let second = reapOnce(store, now = later)
    check second.reaped.len == 0
    check destroyLog == @["cluster"]                 # no SECOND destroy

  test "(8) force reap ignores an UNEXPIRED lease (--hard-rebuild)":
    let store = scratchStore("force")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    # BEFORE the deadline: a normal sweep keeps it (case 2). A force sweep
    # over the NAMED group reaps it anyway — the `--hard-rebuild cluster`
    # re-materialize-from-clean path — ignoring the unexpired lease.
    let keepReport = reapOnce(store, now = t0 + initDuration(minutes = 1))
    check keepReport.reaped.len == 0
    check hasStateRecord(store, "cluster")

    let forceReport = reapOnce(store, now = t0 + initDuration(minutes = 1),
                               force = true, onlyAddresses = @["cluster"])
    check destroyLog == @["cluster"]
    check not hasStateRecord(store, "cluster")
    check forceReport.reaped.len == 1
    # The consumer record (not named + no dated deadline) is untouched.
    check hasStateRecord(store, "smoke-c")

  test "(9) the `repro reap` CLI seam sweeps the store + reports":
    let store = scratchStore("cli")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    var lines: seq[string] = @[]
    let capture = proc (line: string) = lines.add(line)
    let rc = runReapCli(@["--once", "--state-root=" & store.root],
                        now = t0 + ttl + initDuration(minutes = 1),
                        echoLine = capture)
    check rc == 0
    check destroyLog == @["cluster"]
    check not hasStateRecord(store, "cluster")
    # The report mentions the reaped address.
    var mentioned = false
    for l in lines:
      if l.contains("cluster"): mentioned = true
    check mentioned
