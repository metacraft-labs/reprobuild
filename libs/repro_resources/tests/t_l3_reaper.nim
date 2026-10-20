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
## THE TYPED REAP HANDLER (cases 12-13) is driven with two closures
## declared in the case bodies. They are NOT doubles of a production
## handler: they ARE the production shape — a `ReapHandler` is a closure a
## library supplies, and the two here supply the two answers the contract
## has (destroyed, and declined). The real one over a real process is
## `repro_daemon_core/instance_registry`'s, measured against real detached
## children in
## `libs/repro_resources/tests/t_l7_instance_registry_converges_in_any_order.nim`;
## what these two cases measure is the SEAM — that a handler is consulted
## instead of the generic path, and that a decline keeps the record.
##
## SESSION-TRANSPORT NOTE (honest): the reaper's `rtSession` transport
## dispatches destroy over the RP provider session via the SAME
## `observeViaSession` / `applyViaSession` procs the RP5b integration test
## (`tests/integration/t_rp5b_resource_driver_via_protocol.nim`) proves
## end-to-end against a real launched provider child. The reaper simply
## routes its `observe`/`apply(rakDestroy)` through those procs when
## `transport.kind == rtSession`. A dedicated live-session reap (launching a
## provider binary just to destroy) is HEAVY (an RP1 provider build per
## test) and lives in
## `tests/integration/t_lease_reap_destroys_an_unlinked_type_over_a_session.nim`,
## which drives a real launched provider — that is where the §4.5 "a session
## reap needs no attrs codec in the reaping process" property is proven
## end-to-end. Here the core selection predicate, reverse-topo, crash-safety,
## idempotency, the `repro reap` seam, and (case 18) WHICH transport requires
## the attrs codec are proven hermetically.

import std/[tables, options, times, os, strutils, unittest]

import repro_resources
import repro_project_dsl          # TypedExtensionBox
import repro_provider_runtime     # ProviderHandle — case (12)'s session resolver

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

  test "(3b) a NAMED keep holder is a live holder, even beside a passed deadline":
    # Defense in depth, the same reasoning as the dated live-holder check: the
    # merge never writes a keep holder next to a dated effective deadline, but
    # the reaper re-checks the holders it can see rather than trusting the
    # folded deadline alone. A record naming a keep holder is pinned.
    let t0 = fromUnix(1_700_000_000)
    var rec = ResourceStateRecord(
      address: "cluster", typeId: "l3.stub", present: true,
      holders: initTable[string, Time](),
      keepHolders: @["pinner"], keepHoldersKnown: true,
      effectiveDeadline: some(t0), lastRenewed: t0)
    let later = t0 + initDuration(days = 1)
    check hasLiveHolder(rec, later)
    check not isReapable(rec, later)
    # `force` still selects it: an explicit teardown is the one way a keep
    # pin ends (§2.3), and that is what `force` is.
    check isReapable(rec, later, force = true)
    # Control: without the keep holder the same record IS reapable.
    rec.keepHolders = @[]
    check isReapable(rec, later)

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

  test "(8) force reap ignores an UNEXPIRED lease (--force)":
    let store = scratchStore("force")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)

    # BEFORE the deadline: a normal sweep keeps it (case 2). A force sweep
    # over the NAMED group reaps it anyway — the `repro reap --force cluster`
    # re-materialize-from-clean path — ignoring the unexpired lease.
    #
    # This case used to be named after `--hard-rebuild`, which `runReapCli`
    # accepted as a bare alias of `--force`. That spelling now belongs to
    # `repro build` (Edge-Determinism-And-Soft-Rebuild.md §4.3), where it
    # means something entirely different; see case (10) for the refusal.
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

  test "(10) `repro reap` REFUSES the two `repro build` rebuild verbs":
    ## The negative control for the verb-collision resolution.
    ## `runReapCli` used to accept `--hard-rebuild` and
    ## `--rebuild-host-bound` as bare aliases of `--force`, i.e. as a
    ## request to destroy a still-leased state. Those two spellings are now
    ## `repro build`'s, where they select which determinism classes to
    ## invalidate in the ACTION CACHE and destroy nothing.
    ##
    ## Both arms are required. Asserting only the refusal would pass against
    ## a parser that refused every flag, so the second arm proves `--force`
    ## still does the destructive thing the refused spellings used to do --
    ## the capability was RELOCATED, not removed.
    let store = scratchStore("verbs")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 30)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)
    let inLease = t0 + initDuration(minutes = 1)

    for spelling in ["--hard-rebuild", "--rebuild-host-bound"]:
      var lines: seq[string] = @[]
      let capture = proc (line: string) = lines.add(line)
      let rc = runReapCli(@[spelling, "--state-root=" & store.root],
                          now = inLease, echoLine = capture)
      # Refused, with a non-zero exit...
      check rc == 2
      # ...and the state is STILL THERE. A refusal that destroyed anything
      # would be worse than the alias it replaced.
      check hasStateRecord(store, "cluster")
      check destroyLog.len == 0
      # ...and the operator is told where the verb went, rather than getting
      # a bare exit 2 that reads as a typo.
      var explained = false
      for l in lines:
        if l.contains("repro build") and l.contains("--force"):
          explained = true
      check explained

    # The other arm: `--force` is unaffected and still reaps the unexpired
    # lease it always reaped. Scoped to the named group, exactly as case (8)
    # scopes it, so the consumer record is not swept in as collateral.
    let rc = runReapCli(@["--force", "cluster", "--state-root=" & store.root],
                        now = inLease)
    check rc == 0
    check not hasStateRecord(store, "cluster")
    check destroyLog == @["cluster"]

  test "(11) one unreapable record does not abort the sweep; its dependencies are held":
    ## The defect this case pins: a sweep that RAISES on one record reaps
    ## NOTHING. The daemon's wall-clock tick hit it on its very first record —
    ## a `vm_harness.nic` whose attrs marshaller the daemon does not link — on
    ## every one of 141,895 consecutive attempts over 60 days, and reaped
    ## nothing, ever (reprobuild-specs/issues/
    ## 2026-09-29-lease-reap-tick-has-never-once-succeeded.md).
    ##
    ## The store here is REAL and so is the failure: `orphan` is a genuine
    ## record written to disk whose `attrsTypeId` has no `registerExtension`
    ## marshaller in this process, so `reconstructInstance` raises the same
    ## `KeyError` the live daemon logs. Nothing is stubbed to fail.
    ##
    ## Three reapable records, and the reverse-topo order puts the broken one
    ## FIRST (see below), reproducing the abort exactly:
    ##
    ##   cluster  -- reapable, independent      -> MUST be reaped
    ##   orphan   -- no marshaller, dependsOn base -> unreapable, record kept
    ##   base     -- reapable, but `orphan` depends on it -> HELD, not destroyed
    ##
    ## `base` is held rather than reaped on purpose. `orphan` still exists, in
    ## the store and possibly in the world, so destroying what it depends on
    ## would tear a dependency out from under a live dependent — the exact
    ## thing the reverse-topo order exists to prevent — and would leave
    ## `orphan.dependsOn` dangling at a removed address.
    let store = scratchStore("unreapable")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)

    # Two real, reconstructable stub states, each leased by its own consumer.
    materialize(store, "cluster", "smoke", delayed(ttl), t0)
    materialize(store, "base", "basic", delayed(ttl), t0)

    # ...and one record whose attrs typeId has NO registered marshaller. Hand
    # written because `buildStateRecord` marshals through the registry, which
    # is precisely the step that cannot happen for such a type. The payload is
    # opaque bytes: `unmarshalAttrs` refuses on the typeId before reading it.
    writeStateRecord(store, ResourceStateRecord(
      address: "orphan",
      typeId: "l3.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @["base"],
      identity: "stub:orphan",
      present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: some(t0),
      lastRenewed: t0))

    # Order check, so this case cannot pass vacuously by reaping `cluster`
    # before ever reaching the broken record: `reverseTopoOrder` emits
    # [orphan, cluster, base], so the sweep meets `orphan` FIRST.
    let selected = selectReapable(listStateRecords(store), later)
    var order: seq[string] = @[]
    for rec in reverseTopoOrder(selected): order.add(rec.address)
    check order == @["orphan", "cluster", "base"]

    let report = reapOnce(store, now = later)

    # The reapable, unrelated record IS reaped — the sweep ran to the end.
    check "cluster" in destroyLog
    check not hasStateRecord(store, "cluster")
    # The broken record is left on disk for a later sweep (in a process that
    # DOES link the marshaller) to resume. Nothing was destroyed for it.
    check hasStateRecord(store, "orphan")
    check "orphan" notin destroyLog
    # ...and so is its dependency, untouched.
    check hasStateRecord(store, "base")
    check "base" notin destroyLog
    # Exactly one record was reaped, and the other two are NOT reported as
    # healthy `kept` records: `skipped` means "inspected and correctly kept"
    # (here, the two never-reap consumer records only). A record the reaper
    # was asked to destroy and could not must not read as a healthy one.
    #
    # Deliberately asserted through the baseline API and the CLI text below
    # rather than by naming the new report field, so reverting only the
    # production change reddens this case at RUN time on the behaviour, not at
    # compile time on a missing symbol.
    check report.reaped.len == 1
    check report.reaped[0].address == "cluster"
    check report.skipped.len == 2
    for a in @["orphan", "base"]:
      check a notin report.skipped

    # The `repro reap` CLI seam reports the unreapable records rather than
    # printing "kept" and exiting 0 — the invisibility that let the daemon
    # fail for 60 days must not be reproduced at the CLI.
    let store2 = scratchStore("unreapable-cli")
    materialize(store2, "cluster", "smoke", delayed(ttl), t0)
    writeStateRecord(store2, ResourceStateRecord(
      address: "orphan", typeId: "l3.unregistered",
      determinism: rdVolatile, attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00", dependsOn: @[],
      identity: "stub:orphan", present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: some(t0), lastRenewed: t0))
    var lines: seq[string] = @[]
    let capture = proc (line: string) = lines.add(line)
    let rc = runReapCli(@["--once", "--state-root=" & store2.root],
                        now = later, echoLine = capture)
    # Non-zero: the verb was asked to destroy this state and did not.
    check rc == 1
    var named = false
    var reportedReaped = false
    for l in lines:
      if l.contains("orphan") and l.contains("marshaller"): named = true
      if l == "reaped: 1": reportedReaped = true
    check named            # the operator is told WHICH record and WHY
    check reportedReaped   # ...and that the rest of the sweep still ran
    check not hasStateRecord(store2, "cluster")
    check hasStateRecord(store2, "orphan")

  # -------------------------------------------------------------------------
  # Undecodable and foreign records (reprobuild-pm issues/
  # 2026-10-01-one-undecodable-state-record-aborts-every-lease-reap-sweep-
  # forever.md). Before the fix ONE such `.rec` made `listStateRecords` raise,
  # so `reapOnce` reaped nothing — on every tick, for the life of the store.
  # Every file below is a REAL file in a real store; nothing is stubbed to
  # fail. The owner's decision: genuine corruption is QUARANTINED (moved aside
  # under a findable name, bytes kept); a record written by a NEWER repro is
  # FOREIGN (left untouched, never reaped, reported).
  # -------------------------------------------------------------------------

  test "(12) a garbage record is quarantined and the valid records beside it are reaped":
    let store = scratchStore("garbage")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    materialize(store, "beta", "cb", delayed(ttl), t0)
    let garbage = store.root / "garbage.rec"
    writeFile(garbage, "\x00")

    let report = reapOnce(store, now = later)

    # The sweep ran to the end: both valid expired records are destroyed.
    check destroyLog.len == 2
    check "alpha" in destroyLog and "beta" in destroyLog
    check not hasStateRecord(store, "alpha")
    check not hasStateRecord(store, "beta")
    check report.reaped.len == 2
    # The garbage is gone from where listing looks...
    check not fileExists(garbage)
    # ...and kept, bytes intact, under a name that leads back to it.
    check report.quarantined.len == 1
    check report.quarantined[0].path == garbage
    let q = report.quarantined[0].quarantinePath
    check q.startsWith(store.root / "quarantine" / "garbage.rec.")
    check fileExists(q)
    check readFile(q) == "\x00"
    check report.quarantined[0].reason.len > 0
    check report.foreign.len == 0
    check report.unreadable.len == 0

    # The store is fully decodable again: a second sweep has nothing to say.
    let second = reapOnce(store, now = later)
    check second.quarantined.len == 0
    check second.foreign.len == 0
    check second.unreadable.len == 0
    check second.reaped.len == 0
    check fileExists(q)                       # the evidence is not re-moved

  test "(13) a checksum-mismatched or truncated SSZ record is quarantined":
    let store = scratchStore("corrupt")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    # Real record bytes, damaged two ways: one flipped payload byte (the
    # BLAKE3 trailer no longer matches) and one lost final byte (a torn
    # write). Both keep the valid magic + current version, so they reach the
    # SSZ envelope decoder rather than failing on the magic.
    let good = readFile(store.root / "alpha.rec")
    check good.len > 40
    var flipped = good
    flipped[20] = char(ord(flipped[20]) xor 0xFF)
    writeFile(store.root / "flipped.rec", flipped)
    writeFile(store.root / "truncated.rec", good[0 ..< good.len - 1])

    let report = reapOnce(store, now = later)

    check destroyLog == @["alpha"]
    check report.quarantined.len == 2
    var paths: seq[string] = @[]
    for q in report.quarantined:
      paths.add(q.path)
      check fileExists(q.quarantinePath)
    check store.root / "flipped.rec" in paths
    check store.root / "truncated.rec" in paths
    check not fileExists(store.root / "flipped.rec")
    check not fileExists(store.root / "truncated.rec")
    for q in report.quarantined:
      if q.path.endsWith("flipped.rec"):
        check readFile(q.quarantinePath) == flipped
        check q.reason.contains("checksum")
      else:
        check readFile(q.quarantinePath) == good[0 ..< good.len - 1]

  test "(14) a NEWER-version record is foreign: untouched, never reaped, reported":
    let store = scratchStore("foreign")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    materialize(store, "future", "cf", delayed(ttl), t0)
    # The `future` record, as a newer repro would have written it: same
    # magic, envelope version one past what this reader knows. Its deadline
    # is past, so a reader that mistook it for its own would reap it.
    let path = store.root / "future.rec"
    var bytes = readFile(path)
    let newer = StateRecordSszVersion + 1
    bytes[4] = char(newer and 0xFF)
    bytes[5] = char(newer shr 8)
    writeFile(path, bytes)

    let report = reapOnce(store, now = later)

    check destroyLog == @["alpha"]                 # the sibling still reaped
    check "future" notin destroyLog                # never reaped
    check fileExists(path)
    check readFile(path) == bytes                  # byte-for-byte untouched
    check report.quarantined.len == 0              # NOT treated as corrupt
    check not dirExists(store.root / "quarantine")
    check report.foreign.len == 1
    check report.foreign[0].path == path
    check report.foreign[0].version == newer

    # A point read refuses with a DISTINCT error, so a caller such as the
    # daemon's renew path can refuse rather than overwrite a newer record.
    var raisedVersion = 0'u16
    try:
      discard readStateRecord(store, "future")
    except ForeignStateRecordError as err:
      raisedVersion = err.version
    check raisedVersion == newer

    # Steady state: the next sweep reports it again (it is still there) and
    # still does not touch it.
    let second = reapOnce(store, now = later)
    check second.foreign.len == 1
    check readFile(path) == bytes

  test "(15) `repro reap` reports quarantined and foreign records":
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)

    # Quarantine: exit 1 — the store held damaged state an operator must look
    # at, and the line says where the evidence went.
    let store = scratchStore("cli-quarantine")
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    writeFile(store.root / "garbage.rec", "\x00")
    var lines: seq[string] = @[]
    let capture = proc (line: string) = lines.add(line)
    var rc = runReapCli(@["--once", "--state-root=" & store.root],
                        now = later, echoLine = capture)
    check rc == 1
    check "reaped: 1" in lines
    check "quarantined: 1" in lines
    var namesBoth = false
    for l in lines:
      if l.contains("garbage.rec") and l.contains(store.root / "quarantine"):
        namesBoth = true
    check namesBoth

    # Foreign alone: exit 0 — a newer repro's record is healthy, just not
    # ours; reported so nobody wonders why it is never reaped.
    let store2 = scratchStore("cli-foreign")
    materialize(store2, "future", "cf", delayed(ttl), t0)
    let path = store2.root / "future.rec"
    var bytes = readFile(path)
    bytes[4] = char((StateRecordSszVersion + 1) and 0xFF)
    writeFile(path, bytes)
    lines = @[]
    rc = runReapCli(@["--once", "--state-root=" & store2.root],
                    now = later, echoLine = capture)
    check rc == 0
    check "foreign: 1" in lines
    var namesForeign = false
    for l in lines:
      if l.contains("future.rec") and l.contains("version " &
          $(StateRecordSszVersion + 1)):
        namesForeign = true
    check namesForeign
    check readFile(path) == bytes

  test "(16) an out-of-range field in a legacy record is quarantined, not a sweep-ending Defect":
    # The legacy (pre-SSZ) framing has no checksum, so a corrupt byte reaches
    # the field decoders. Narrowing an out-of-range value with a plain
    # conversion raises a `RangeDefect`, which is NOT a `CatchableError`: it
    # sailed past the per-record guard and ended the sweep exactly as the
    # issue describes. Both shapes are built byte-by-byte in the documented
    # legacy layout, so they decode up to the bad field and fail there.
    proc u32(x: uint32): string =
      for i in 0 .. 3: result.add(char((x shr (8 * i)) and 0xFF))
    proc u64(x: uint64): string =
      for i in 0 .. 7: result.add(char((x shr (8 * i)) and 0xFF))
    proc str(s: string): string = u32(uint32(s.len)) & s
    proc legacy(determinism: uint32; lastRenewed: uint64): string =
      result = "RSST" & u32(2) & str("old") & str("l3.stub") &
        u32(determinism) & str("") & str("") & u32(0) & str("stub:old")
      for i in 0 ..< 32: result.add('\x00')          # digest
      result.add('\x01')                             # present
      result.add(u32(0))                             # no holders
      result.add('\x00')                             # no effective deadline
      result.add(u64(lastRenewed))

    let store = scratchStore("legacy-range")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    # Positive control: the hand-built layout IS a decodable legacy record.
    writeFile(store.root / "control.rec", legacy(0, 1_700_000_000'u64))
    writeFile(store.root / "determinism.rec", legacy(99, 1_700_000_000'u64))
    writeFile(store.root / "timestamp.rec",
              legacy(0, 0xFFFF_FFFF_FFFF_FFFF'u64))

    let report = reapOnce(store, now = later)

    check destroyLog == @["alpha"]
    check fileExists(store.root / "control.rec")      # decoded, kept (no deadline)
    check "old" in report.skipped
    check report.quarantined.len == 2
    var reasons: seq[string] = @[]
    for q in report.quarantined:
      reasons.add(extractFilename(q.path) & ": " & q.reason)
      check fileExists(q.quarantinePath)
    check reasons.len == 2
    for r in reasons:
      check r.contains("out of range")
    check not fileExists(store.root / "determinism.rec")
    check not fileExists(store.root / "timestamp.rec")

  test "(17) a temp orphaned by a crashed write is swept; a live write's temp is not":
    # Temp names are unique per write, so nothing ever overwrites the temp of
    # a write that died before its rename: without this sweep each such crash
    # would leak one file in the store for good.
    let store = scratchStore("stale-temp")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    materialize(store, "alpha", "ca", delayed(ttl), t0)
    let orphan = store.root / ".tmp-alpha.rec.1-2-3"
    let live = store.root / ".tmp-alpha.rec.4-5-6"
    writeFile(orphan, "half a record")
    writeFile(live, "half a record")
    setLastModificationTime(orphan, getTime() - initDuration(hours = 2))

    let report = reapOnce(store, now = t0 + ttl + initDuration(minutes = 1))

    check destroyLog == @["alpha"]
    check not fileExists(orphan)
    check fileExists(live)                 # never touched: a write may hold it
    check report.quarantined.len == 0      # a temp is never judged as a record
    check report.unreadable.len == 0

  test "(18) the attrs codec is required IN-PROCESS and not over a SESSION":
    ## The transport asymmetry §4.5 settles, pinned in both directions against
    ## ONE record in ONE process, so neither arm can drift into the other's
    ## contract without a red case.
    ##
    ## The defect: the reaper reconstructed through the STRICT attrs codec
    ## BEFORE it chose a transport. §4.2 gives the daemon a provider-session
    ## destroy precisely so it can tear down an out-of-tree provider's
    ## resources "WITHOUT linking it into the daemon", so a process holding a
    ## provider artifact but not that provider's attrs codec — the
    ## configuration §4.2 describes — could not reap over the session it had.
    ##
    ## NOT the cause of the outage in reprobuild-pm/issues/
    ## 2026-09-29-lease-reap-tick-has-never-once-succeeded.md, and this case
    ## does not claim to reproduce it. That daemon swept on the IN-PROCESS
    ## transport for all 131,882 ticks — the transport falls back to it when no
    ## provider artifact is known, and at the time nothing in the shipped tree
    ## could make one known — where its record had no linked driver either and
    ## the strict path is still right. This case pins the second, independent
    ## defect that would have produced the identical symptom in a daemon that
    ## did have the artifact. (Cases 21-23 cover the artifacts a record now
    ## carries, which is what made the session arm reachable.)
    ##
    ## The two arms want OPPOSITE things and that is the whole point:
    ##
    ##   * in-process  -> the linked driver dereferences the typed value, so a
    ##     codec it cannot decode is unusable and must be a hard, diagnosable
    ##     failure AT the seam. Loosening this arm would hand a `RawExtensionBox`
    ##     to a driver that casts it to the wrong type.
    ##   * session     -> the box is marshalled straight back out to a provider
    ##     that DOES link the codec. Requiring one here is a requirement with no
    ##     consumer.
    let store = scratchStore("transport-codec")
    let t0 = fromUnix(1_700_000_000)
    let later = t0 + initDuration(hours = 1)

    # One record whose attrs typeId has no registered marshaller in this
    # process — hand written, because `buildStateRecord` marshals THROUGH the
    # registry and so cannot produce one for such a type. This is exactly the
    # daemon's situation: a record written by a process that had the codec,
    # being swept by one that does not.
    proc seedOrphan() =
      writeStateRecord(store, ResourceStateRecord(
        address: "nic0",
        typeId: "l3.unregistered",
        determinism: rdVolatile,
        attrsTypeId: "l3.unregistered",
        attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[],
        identity: "incus:nic0",
        present: true,
        holders: initTable[string, Time](),
        effectiveDeadline: some(t0),
        lastRenewed: t0))

    # --- IN-PROCESS: still a hard failure, and still non-destructive. ---
    seedOrphan()
    let inProc = reapOnce(store, now = later, inProcessTransport())
    check inProc.reaped.len == 0
    check inProc.failed.len == 1
    check inProc.failed[0].address == "nic0"
    check inProc.failed[0].kind == rfkUnreapable
    check inProc.failed[0].reason.contains("marshaller")
    # The record survives for a sweep that can do better, and nothing in the
    # world was touched on the way to finding out.
    check hasStateRecord(store, "nic0")
    check destroyLog.len == 0
    # The recorded reason names what the operator of THIS process can do.
    # `unmarshalAttrs`'s own advice — import the producer's lifted interface —
    # is unactionable for the daemon, which is a fixed binary with no recipe to
    # add an import to; repeating it there is how a failure stays unfixed while
    # nominally carrying a remedy.
    check inProc.failed[0].reason.contains("provider session")
    check inProc.failed[0].reason.contains("repro reap --once")

    # --- SESSION: the codec is not consulted; the transport IS reached. ---
    # The resolver raises a sentinel instead of launching a provider: this case
    # is about WHERE the reap gets to, and a real launched provider is case
    # `t_lease_reap_destroys_an_unlinked_type_over_a_session`'s subject. Before
    # the fix the resolver was never called at all and the reason named the
    # marshaller.
    var resolverCalls = 0
    var resolvedTypeIds: seq[string] = @[]
    let resolve = proc (typeId: string): ProviderHandle =
      inc resolverCalls
      resolvedTypeIds.add(typeId)
      raise newException(ValueError, "L3-SENTINEL session not launched here")

    let viaSession = reapOnce(store, now = later, sessionTransport(resolve))
    check resolverCalls == 1                       # the transport was REACHED
    check resolvedTypeIds == @["l3.unregistered"]  # ...for the right type
    check viaSession.failed.len == 1
    check viaSession.failed[0].reason.contains("L3-SENTINEL")
    # ...and the strict-codec refusal is GONE from this arm, which is the
    # falsifiable half: before the fix this reason was the marshaller message.
    check not viaSession.failed[0].reason.contains("marshaller")
    # A session arm that failed to launch is still non-destructive and still
    # leaves the record.
    check hasStateRecord(store, "nic0")
    check destroyLog.len == 0

  test "(19) a typed reap handler is used INSTEAD of the generic path":
    ## The hook the shared-service instance registry reaches the sweep
    ## through (`Shared-Development-Services.md` §4.5: "an instance is
    ## reaped when its last lease lapses"). A `typeId` with a handler is
    ## never reconstructed, so it needs no attrs marshaller and no
    ## provider driver — which is the whole point, since the record below
    ## has neither and case (11) shows what the generic path does with
    ## one.
    let store = scratchStore("handler")
    let t0 = fromUnix(1_700_000_000)
    var holders = initTable[string, Time]()
    holders["smoke"] = t0
    writeStateRecord(store, ResourceStateRecord(
      address: "handled",
      typeId: "l3.handled",
      determinism: rdVolatile,
      attrsTypeId: "l3.no-such-attrs",
      attrsJson: "{}",
      dependsOn: @[], identity: "x", present: true,
      holders: holders, effectiveDeadline: some(t0), lastRenewed: t0))
    check reapHandlerFor("l3.handled").isNil

    var handled: seq[string] = @[]
    registerReapHandler("l3.handled",
      proc (rec: ResourceStateRecord): ReapHandlerOutcome =
        handled.add(rec.address)
        ReapHandlerOutcome(destroyed: true, wasPresent: true,
          detail: "handled by the typed hook"))
    check "l3.handled" in registeredReapHandlerIds()
    let report = reapOnce(store, now = t0 + initDuration(minutes = 1))
    check handled == @["handled"]
    check report.reaped.len == 1
    check report.reaped[0].typeId == "l3.handled"
    check report.reaped[0].wasPresent
    check report.failed.len == 0
    check not hasStateRecord(store, "handled")
    # The generic driver was never asked, which is what "instead of"
    # means: `reconstructInstance` would have raised about the missing
    # marshaller before `observe` was ever reached.
    check observeLog.len == 0

    unregisterReapHandler("l3.handled")
    check reapHandlerFor("l3.handled").isNil
    # A nil handler is a refusal, not a way to clear the slot: reading it
    # back as "no handler" would silently restore the generic path for a
    # type that registered precisely to avoid it.
    expect ValueError:
      registerReapHandler("l3.handled", nil)

  test "(20) a handler that DECLINES keeps the record and names itself":
    ## `destroyed = false` is not a quiet success. The record stays, the
    ## reason lands in `failed` as `rfkUnreapable` exactly as a raise
    ## would, and the sweep carries on with the rest — the shape a
    ## process that persists a record it cannot destroy needs. A handler
    ## that returned "destroyed" on a failed destroy would hand the sweep
    ## a licence to remove the record of state that still exists.
    let store = scratchStore("handler-decline")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    materialize(store, "cluster", "smoke", delayed(ttl), t0)
    let later = t0 + ttl + initDuration(minutes = 1)
    var holders = initTable[string, Time]()
    holders["smoke"] = t0
    writeStateRecord(store, ResourceStateRecord(
      address: "zz-declined",
      typeId: "l3.declining",
      determinism: rdVolatile,
      attrsTypeId: "l3.no-such-attrs",
      attrsJson: "{}",
      dependsOn: @[], identity: "x", present: true,
      holders: holders, effectiveDeadline: some(t0), lastRenewed: t0))
    # Reverse-topo puts `zz-declined` FIRST, so a sweep that gave up on a
    # declining handler would never reach `cluster` and this case could
    # not pass vacuously.
    let selected = selectReapable(listStateRecords(store), later)
    var order: seq[string] = @[]
    for rec in reverseTopoOrder(selected): order.add(rec.address)
    check order[0] == "zz-declined"

    registerReapHandler("l3.declining",
      proc (rec: ResourceStateRecord): ReapHandlerOutcome =
        ReapHandlerOutcome(destroyed: false, wasPresent: true,
          detail: "this process cannot destroy `" & rec.address & "`"))
    let report = reapOnce(store, now = later)
    unregisterReapHandler("l3.declining")

    check report.failed.len == 1
    check report.failed[0].address == "zz-declined"
    check report.failed[0].kind == rfkUnreapable
    check report.failed[0].reason.contains("cannot destroy")
    check hasStateRecord(store, "zz-declined")
    check "zz-declined" notin report.skipped
    # And the rest of the sweep still happened.
    check "cluster" in destroyLog
    check not hasStateRecord(store, "cluster")

  test "(21) a hybrid session transport reaps IN-TREE records in-process":
    ## Ephemeral-State-Leases.md §4.2 — the routing is PER RECORD, and that is
    ## what makes the production feeders safe to add at all.
    ##
    ## A transport is chosen once per SWEEP, but a sweep runs over a whole
    ## store, and one store holds every type the host has leased. Before the
    ## hybrid gate, the moment anything handed the reaper ONE provider artifact
    ## the transport became `rtSession` for the ENTIRE sweep, and every in-tree
    ## record in that store started failing: `resolve` has no artifact for
    ## `l3.stub`, so it raised and a record that was reaped a tick ago became an
    ## `rfkUnreapable` finding. Wiring a feeder without this would have traded
    ## the issue's defect for a worse one.
    ##
    ## NON-VACUITY: the resolver RAISES if it is ever asked for the in-tree
    ## type, so "reaped in-process" cannot be confused with "reaped over a
    ## session that happened to work", and the in-tree record's destroy is
    ## witnessed by `destroyLog`, which only the linked stub driver appends to.
    let store = scratchStore("hybrid-routing")
    let t0 = fromUnix(1_700_000_000)
    let ttl = initDuration(minutes = 10)
    let later = t0 + ttl + initDuration(minutes = 1)

    # IN-TREE: a real stub-provider record, driver and codec both linked here.
    materialize(store, "intree", "smoke", delayed(ttl), t0)

    # OUT-OF-TREE: a record of a type this process links nothing for, carrying
    # its own provider artifact — the v5 route the session arm follows.
    writeStateRecord(store, ResourceStateRecord(
      address: "outoftree",
      typeId: "l3.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:outoftree",
      present: true,
      holders: initTable[string, Time](),
      keepHolders: @[],
      keepHoldersKnown: true,
      effectiveDeadline: some(t0),
      lastRenewed: t0,
      providerArtifact: some(ResourceProviderArtifactRef(
        binaryPath: "/nonexistent/l3-provider",
        providerArtifactId: "l3artifact",
        workingDir: getCurrentDir()))))

    # The artifacts the sweep derives from its own records: exactly one, for
    # the out-of-tree type. The in-tree type is absent, which is what sends it
    # in-process.
    let derived = providerArtifactsOfRecords(listStateRecords(store))
    check derived.len == 1
    check derived[0].typeId == "l3.unregistered"
    check derived[0].artifact.binaryPath == "/nonexistent/l3-provider"

    # The WITNESS: every artifact the transport actually asked to launch. The
    # in-tree record must never produce an entry here, and the assertion below
    # is only worth making because this closure fills it.
    var launched: seq[string] = @[]
    let report = reapOnce(store, now = later,
      transportFromRecords = reapTransportFactory(@[],
        proc (artifact: ResourceProviderArtifactRef): ProviderHandle =
          launched.add(artifact.binaryPath)
          raise newException(ValueError, "L3-SENTINEL would launch " &
            artifact.binaryPath)))

    # The IN-TREE record was destroyed by the LINKED driver — `destroyLog` is
    # appended to only by `stubApply`, so this is a witness and not an
    # inference.
    check "intree" in destroyLog
    check not hasStateRecord(store, "intree")
    check report.reaped.len == 1
    check report.reaped[0].address == "intree"

    # The OUT-OF-TREE record went to the session arm, which here refuses to
    # launch — so it is a finding naming the sentinel, NOT the missing-codec
    # refusal the in-process arm would have produced. That distinction is the
    # proof it was routed over the session.
    check report.failed.len == 1
    check report.failed[0].address == "outoftree"
    check report.failed[0].reason.contains("L3-SENTINEL")
    check report.failed[0].reason.contains("/nonexistent/l3-provider")
    check not report.failed[0].reason.contains("marshaller")
    check hasStateRecord(store, "outoftree")
    # The launcher was asked EXACTLY ONCE, for the out-of-tree provider. The
    # in-tree record never reached it: had the hybrid gate sent `l3.stub` to the
    # session, this would hold two entries and `destroyLog` would be empty.
    check launched == @["/nonexistent/l3-provider"]

  test "(22) a registered artifact outranks the one a record carries":
    ## Ephemeral-State-Leases.md §4.2 resolution order. A recorded binary path
    ## is a build output: a rebuild or a store garbage collection can leave it
    ## naming nothing, and the record cannot notice. An artifact supplied by a
    ## live process — the daemon's registry, fed by a consuming `repro run` —
    ## came from something launching that provider right now, so it wins.
    let recorded = ResourceProviderArtifactRef(
      binaryPath: "/stale/provider", providerArtifactId: "old",
      workingDir: "/stale")
    let fresh = ResourceProviderArtifactRef(
      binaryPath: "/fresh/provider", providerArtifactId: "new",
      workingDir: "/fresh")
    let other = ResourceProviderArtifactRef(
      binaryPath: "/other/provider", providerArtifactId: "other",
      workingDir: "/other")

    let merged = mergeProviderArtifacts(
      @[(typeId: "t.a", artifact: fresh)],
      @[(typeId: "t.a", artifact: recorded), (typeId: "t.b", artifact: other)])
    # Sorted by typeId, `primary` winning on the collision and `fallback`
    # supplying the type it does not name.
    check merged.len == 2
    check merged[0].typeId == "t.a"
    check merged[0].artifact.binaryPath == "/fresh/provider"
    check merged[1].typeId == "t.b"
    check merged[1].artifact.binaryPath == "/other/provider"

    # An artifact with no binary path cannot launch anything, so it never
    # enters the merged set — it would otherwise mask a usable fallback with
    # something guaranteed to fail.
    let blanked = mergeProviderArtifacts(
      @[(typeId: "t.a", artifact: ResourceProviderArtifactRef())],
      @[(typeId: "t.a", artifact: recorded)])
    check blanked.len == 1
    check blanked[0].artifact.binaryPath == "/stale/provider"

    # With NO artifacts on either side the transport is the plain in-process
    # one, so a host that has never materialized an out-of-tree resource pays
    # nothing and launches nothing.
    let plain = artifactSessionTransport(@[],
      proc (artifact: ResourceProviderArtifactRef): ProviderHandle =
        raise newException(ValueError, "must not be called"))
    check plain.kind == rtInProcess

  test "(23) a record's provider artifact survives a later write, on all three paths":
    ## Ephemeral-State-Leases.md §4.2 — the ref is carried forward on the same
    ## terms as the lease fields.
    ##
    ## A run that reconciles the resource without supplying an artifact has not
    ## discovered that the provider binary is gone; it merely did not need it.
    ## Blanking the ref there would withdraw the only route a later reap has to
    ## an out-of-tree record — silently, on the ordinary path, turning a
    ## reapable record into a permanently stuck one.
    ##
    ## `carriedProviderArtifact` HAS THREE CALL SITES and this case covers each
    ## with an assertion that reddens when THAT site's call is removed:
    ##
    ##   * `reconcile.nim` `writeUnconsumedStateRecord` — the not-consumed-this-
    ##     run write, shared by the in-process and session reconciles;
    ##   * `reconcile.nim` `reconcileResources` — the LEASED in-process write;
    ##   * `protocol.nim` `reconcileResourcesViaSession` — the LEASED session
    ##     write.
    ##
    ## TWO WAYS THIS CASE WAS PREVIOUSLY VACUOUS, both fixed here and both worth
    ## naming because they are easy to reintroduce:
    ##
    ##   1. A no-op reconcile WRITES NOTHING. With no `recorded` binding passed,
    ##      a digest-matching resource decides `rakNoOp`, `effective` stays
    ##      `none`, and the persist step is skipped entirely — so the record
    ##      still held the seeded ref no matter what the carry-forward did. Each
    ##      block below therefore passes `recorded` so the write really happens,
    ##      and asserts the record was REWRITTEN (`lastRenewed` / a changed
    ##      field) before asserting the ref survived it.
    ##   2. Supplying an artifact short-circuits the carry. When this run has
    ##      its own ref, `carriedProviderArtifact` returns it without consulting
    ##      the existing record — so a case that passes one proves nothing about
    ##      carrying. The session block below passes NO artifact for exactly
    ##      that reason. (It is also why
    ##      `t_run_consumes_session_store_out_of_tree` does not cover this: its
    ##      second pass supplies `harvested` again.)
    let t0 = fromUnix(1_700_000_000)
    let artifact = ResourceProviderArtifactRef(
      binaryPath: "/carried/provider", providerArtifactId: "carried",
      workingDir: getCurrentDir())

    proc seedCarried(store: StateStore): ResourceBinding =
      ## A materialized `carried` record holding the ref a session reconcile
      ## would have written, plus the binding a later run must pass as
      ## `recorded` for its no-op to carry forward (and so to WRITE).
      ##
      ## The stub world is cleared first: the three blocks share this process,
      ## and a world left materialized by the previous one makes this reconcile
      ## a digest-matching no-op that writes NO record at all — which is the
      ## same trap that made the old version of this case vacuous.
      stubWorld = initTable[string, string]()
      resetDesiredResources()
      discard stubState("carried", "up")
      let first = reconcileResources(collectedResources(),
        store = some(store), now = t0)
      var seeded = readStateRecord(store, "carried")
      check seeded.providerArtifact.isNone      # nothing invented it
      seeded.providerArtifact = some(artifact)
      seeded.lastRenewed = t0
      # POISON `identity` so each block's `after.identity == resourceId` is a
      # real WRITE WITNESS and not a tautology. Site 1 needs this most: it goes
      # through `writeUnconsumedStateRecord`, which carries `lastRenewed`
      # forward, so without a field the write must overwrite, all three of its
      # guard assertions are equally true of an untouched record — and this is
      # the block whose vacuity was the original defect. `identity` is the right
      # field: `buildStateRecord` always sets it from the binding, and it is NOT
      # in the carried-forward list, so a record that still says SENTINEL was
      # never rewritten.
      seeded.identity = "SENTINEL-not-rewritten"
      writeStateRecord(store, seeded)
      for b in first.bindings:
        if b.address == "carried":
          return b
      raise newException(ValueError, "no binding for 'carried'")

    # ── SITE 1: `writeUnconsumedStateRecord` (not consumed this run) ───────
    block:
      let store = scratchStore("carry-unconsumed")
      let binding = seedCarried(store)
      resetDesiredResources()
      discard stubState("carried", "up")
      discard reconcileResources(collectedResources(), recorded = @[binding],
        store = some(store), now = t0 + initDuration(minutes = 1))
      let after = readStateRecord(store, "carried")
      # The record really WAS rewritten — without this the assertion below
      # would hold on an untouched record and prove nothing.
      check after.identity == binding.resourceId
      check after.present
      check hasStateRecord(store, "carried")
      check after.providerArtifact.isSome
      check after.providerArtifact.get.binaryPath == "/carried/provider"
      check after.providerArtifact.get.providerArtifactId == "carried"

    # ── SITE 2: `reconcileResources`, LEASED in-process write ─────────────
    block:
      let store = scratchStore("carry-leased")
      let binding = seedCarried(store)
      resetDesiredResources()
      discard stubState("carried", "up")
      discard stubConsumer("carried-c", "probe",
        consumes = @[leased("carried", "smoke",
          delayed(initDuration(minutes = 10)))])
      let now = t0 + initDuration(minutes = 2)
      discard reconcileResources(collectedResources(), recorded = @[binding],
        store = some(store), now = now)
      let after = readStateRecord(store, "carried")
      # WITNESS that this write happened: the lease was renewed, which only the
      # leased arm does, and `lastRenewed` moved off the seeded `t0`.
      check after.lastRenewed == now
      check after.effectiveDeadline == some(now + initDuration(minutes = 10))
      check after.providerArtifact.isSome
      check after.providerArtifact.get.binaryPath == "/carried/provider"

    # ── SITE 3: `reconcileResourcesViaSession`, LEASED session write ───────
    block:
      let store = scratchStore("carry-session")
      let binding = seedCarried(store)
      resetDesiredResources()
      discard stubState("carried", "up")
      discard stubConsumer("carried-c", "probe",
        consumes = @[leased("carried", "smoke",
          delayed(initDuration(minutes = 10)))])
      let now = t0 + initDuration(minutes = 3)
      # The SESSION reconcile's persist step, driven hermetically: every leaf op
      # is routed to the LINKED stub driver by the hybrid gate, so no provider
      # binary is needed, while the write still goes through
      # `reconcileResourcesViaSession`'s own branch rather than
      # `reconcileResources`'. The resolver raises if it is ever reached, so
      # "the ops ran in-process" is witnessed rather than assumed.
      discard reconcileResourcesViaSession(collectedResources(),
        proc (typeId: string): ProviderHandle =
          raise newException(ValueError, "L3-SENTINEL: no session here"),
        recorded = @[binding], store = some(store), now = now,
        inProcess = proc (typeId: string): bool = true,
        providerArtifacts = @[])      # NO ref this run: the carry is the point
      let after = readStateRecord(store, "carried")
      check after.lastRenewed == now
      check after.effectiveDeadline == some(now + initDuration(minutes = 10))
      check after.providerArtifact.isSome
      check after.providerArtifact.get.binaryPath == "/carried/provider"
      check after.providerArtifact.get.providerArtifactId == "carried"

  test "(24) a stale sibling record does not mask a reachable artifact":
    ## Resolution is per TYPE within a sweep: when two records of one typeId
    ## name DIFFERENT artifacts, whichever wins is used for BOTH. So picking the
    ## first by filename let a record from an old build — whose store path has
    ## since been garbage-collected — mask a sibling carrying a route that still
    ## works, and the reachable record became permanently unreapable for as long
    ## as the stale neighbour sat beside it. Every tick would report it, and the
    ## reported reason would name a path that is simply not there.
    ##
    ## NON-VACUITY: the stale path sorts FIRST by record filename (`aaa-` before
    ## `zzz-`), so first-record-wins would pick it. The reachable artifact is a
    ## file this test creates, so `fileExists` is answering about a real file,
    ## and the witness records which path the transport actually asked to
    ## launch.
    let store = scratchStore("stale-sibling")
    let t0 = fromUnix(1_700_000_000)
    let later = t0 + initDuration(minutes = 11)

    # A real file to stand in for a provider binary that is still installed.
    # Never executed — the launcher closure refuses before any spawn — so its
    # contents do not matter, only that it EXISTS.
    let liveProvider = store.root / "live-provider"
    writeFile(liveProvider, "#!/bin/sh\nexit 0\n")
    let stalePath = store.root / "collected-away-provider"
    check not fileExists(stalePath)

    proc outOfTreeRecord(address, binaryPath: string): ResourceStateRecord =
      ResourceStateRecord(
        address: address,
        typeId: "l3.unregistered",
        determinism: rdVolatile,
        attrsTypeId: "l3.unregistered",
        attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[],
        identity: "stub:" & address,
        present: true,
        holders: initTable[string, Time](),
        keepHolders: @[],
        keepHoldersKnown: true,
        effectiveDeadline: some(t0),
        lastRenewed: t0,
        providerArtifact: some(ResourceProviderArtifactRef(
          binaryPath: binaryPath,
          providerArtifactId: "id-" & address,
          workingDir: getCurrentDir())))

    # The STALE one sorts first; the reachable one second.
    writeStateRecord(store, outOfTreeRecord("aaa-stale", stalePath))
    writeStateRecord(store, outOfTreeRecord("zzz-live", liveProvider))

    # The derived set prefers the artifact that EXISTS, for both records.
    let derived = providerArtifactsOfRecords(listStateRecords(store))
    check derived.len == 1
    check derived[0].typeId == "l3.unregistered"
    check derived[0].artifact.binaryPath == liveProvider

    var launched: seq[string] = @[]
    let report = reapOnce(store, now = later,
      transportFromRecords = reapTransportFactory(@[],
        proc (artifact: ResourceProviderArtifactRef): ProviderHandle =
          launched.add(artifact.binaryPath)
          raise newException(ValueError, "L3-SENTINEL would launch " &
            artifact.binaryPath)))

    # Both records were routed to the LIVE provider, never to the collected
    # path. (The sentinel refuses the launch, so both come back as findings —
    # which path the sweep chose is the property under test.)
    check launched.len == 2
    for path in launched:
      check path == liveProvider
    check report.failed.len == 2
    for f in report.failed:
      check f.reason.contains(liveProvider)
      check not f.reason.contains("collected-away-provider")

    # When NO candidate exists, the first launchable one is still used, so the
    # finding names a concrete path an operator can go and look for rather than
    # saying only that the type is unreachable.
    let store2 = scratchStore("stale-only")
    let gone = store2.root / "also-gone"
    writeStateRecord(store2, outOfTreeRecord("aaa-stale", stalePath))
    writeStateRecord(store2, outOfTreeRecord("zzz-also-stale", gone))
    let derived2 = providerArtifactsOfRecords(listStateRecords(store2))
    check derived2.len == 1
    check derived2[0].artifact.binaryPath == stalePath   # first, deterministic

  test "(25) a RELATIVE recorded binaryPath is no route at all":
    ## `openProviderSession` launches with `poUsePath`, so a non-absolute
    ## `binaryPath` is resolved through the ambient `PATH` of whatever process
    ## is sweeping. The field is meant to name one specific build output by its
    ## own path; `PATH` resolution instead makes the binary that runs a function
    ## of the sweeper's environment, and for the system-scoped store the writer
    ## and the daemon need not even be the same user.
    ##
    ## So such a ref is treated as NO ROUTE: the record is routed in-process —
    ## where, having no linked driver or codec either, it becomes the §4.5
    ## finding — rather than launching whatever `PATH` happens to resolve.
    ##
    ## NON-VACUITY: the launcher closure records every artifact it is asked
    ## for, so "nothing was launched" is a witness rather than an absence of
    ## evidence.
    let store = scratchStore("relative-path")
    let t0 = fromUnix(1_700_000_000)
    let later = t0 + initDuration(minutes = 11)

    writeStateRecord(store, ResourceStateRecord(
      address: "relative",
      typeId: "l3.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:relative",
      present: true,
      holders: initTable[string, Time](),
      keepHolders: @[],
      keepHoldersKnown: true,
      effectiveDeadline: some(t0),
      lastRenewed: t0,
      providerArtifact: some(ResourceProviderArtifactRef(
        binaryPath: "sh",                  # resolvable on PATH, and refused
        providerArtifactId: "relative-id",
        workingDir: getCurrentDir()))))

    check not isLaunchableArtifact(ResourceProviderArtifactRef(
      binaryPath: "sh", providerArtifactId: "x"))
    check not isLaunchableArtifact(ResourceProviderArtifactRef(
      binaryPath: "", providerArtifactId: "x"))
    check isLaunchableArtifact(ResourceProviderArtifactRef(
      binaryPath: "/usr/bin/sh", providerArtifactId: "x"))
    # ...and an EMPTY providerArtifactId is unlaunchable however good the path
    # is, because that field is the provider-session POOL KEY: two refs naming
    # different absolute binaries with an empty id would collapse to one key,
    # the first child launched would serve both types, and the second type's
    # finding would carry the first provider's error. See case (26).
    check not isLaunchableArtifact(ResourceProviderArtifactRef(
      binaryPath: "/usr/bin/sh", providerArtifactId: ""))

    # The record contributes NO artifact, so the sweep's transport for this
    # store is the plain in-process one.
    check providerArtifactsOfRecords(listStateRecords(store)).len == 0

    var launched: seq[string] = @[]
    let report = reapOnce(store, now = later,
      transportFromRecords = reapTransportFactory(@[],
        proc (artifact: ResourceProviderArtifactRef): ProviderHandle =
          launched.add(artifact.binaryPath)
          raise newException(ValueError, "L3-SENTINEL must not be reached")))

    check launched.len == 0                 # nothing was launched, witnessed
    check report.reaped.len == 0
    check report.failed.len == 1
    check report.failed[0].address == "relative"
    check report.failed[0].kind == rfkUnreapable
    # It came back through the IN-PROCESS arm: the marshaller refusal and its
    # §4.5 remedy, not a session-launch error.
    check report.failed[0].reason.contains("marshaller")
    check not report.failed[0].reason.contains("L3-SENTINEL")

    # THE REMEDY MUST DESCRIBE THIS STATE, not the no-artifact one. The record
    # DOES name an artifact, so "the record names no provider artifact" would
    # be a false statement, and "re-materialize it, which records the artifact"
    # would be useless advice — the same relative path would be recorded again.
    # So the reason names the recorded path, the requirement it fails, and who
    # has to change.
    let reason = report.failed[0].reason
    check reason.contains("cannot be launched")
    check reason.contains("binaryPath 'sh'")
    check reason.contains("not an absolute path")
    # The remedy says what to re-record it WITH, and who has to do it. (The
    # wording moved from "the provider's ABSOLUTE path" to the general
    # "launchable provider artifact" when a second unlaunchability criterion —
    # the empty pool key of case (26) — joined the first; the sentence above
    # is what names which of the two this record fails.)
    check reason.contains("launchable provider artifact")
    check reason.contains("the producer")
    check not reason.contains("names no provider artifact")
    check not reason.contains("which records the artifact in the record")
    # The by-hand route is still offered, carrying this store's root.
    check reason.contains("repro reap --once --state-root=" & store.root)

    # ...and the OTHER state still gets the other remedy, so this is a genuine
    # split rather than one message replacing the other. Same store, a record
    # with NO ref at all.
    writeStateRecord(store, ResourceStateRecord(
      address: "no-ref",
      typeId: "l3.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:no-ref",
      present: true,
      holders: initTable[string, Time](),
      keepHolders: @[],
      keepHoldersKnown: true,
      effectiveDeadline: some(t0),
      lastRenewed: t0,
      providerArtifact: none(ResourceProviderArtifactRef)))
    let both = reapOnce(store, now = later)
    check both.failed.len == 2
    for f in both.failed:
      if f.address == "no-ref":
        check f.reason.contains("names no provider artifact")
        check f.reason.contains("which records the artifact in the record")
        check not f.reason.contains("cannot be launched")
      else:
        check f.reason.contains("cannot be launched")

    # THE THIRD STATE: a record whose ref is perfectly LAUNCHABLE, swept on a
    # PINNED in-process transport — which is what `reapOnce(store, now)` is.
    # Nothing is wrong with this record, so it must get neither of the other
    # two remedies: "names no provider artifact" would be false, and telling
    # its producer to re-record a good artifact would send the operator to fix
    # something that is already right. The remedy is to stop pinning.
    writeStateRecord(store, ResourceStateRecord(
      address: "good-ref",
      typeId: "l3.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l3.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:good-ref",
      present: true,
      holders: initTable[string, Time](),
      keepHolders: @[],
      keepHoldersKnown: true,
      effectiveDeadline: some(t0),
      lastRenewed: t0,
      providerArtifact: some(ResourceProviderArtifactRef(
        binaryPath: getCurrentDir() / "build" / "bin" / "repro",
        providerArtifactId: "good-id",
        workingDir: getCurrentDir()))))
    let pinned = reapOnce(store, now = later, inProcessTransport())
    var sawGood = false
    for f in pinned.failed:
      if f.address != "good-ref":
        continue
      sawGood = true
      check f.reason.contains("did not use the provider artifact")
      check f.reason.contains("in-process transport")
      check f.reason.contains("pinned")
      check not f.reason.contains("names no provider artifact")
      check not f.reason.contains("cannot be launched")
      check not f.reason.contains("the producer that wrote this record")
    check sawGood

    # And the records survive for a sweep that can do better.
    check hasStateRecord(store, "relative")
    check hasStateRecord(store, "no-ref")

    # `mergeProviderArtifacts` drops it on BOTH sides, so a relative path in
    # the daemon's registry cannot sneak in either.
    let rel = ResourceProviderArtifactRef(binaryPath: "sh",
      providerArtifactId: "relative-id")
    check mergeProviderArtifacts(@[(typeId: "t.a", artifact: rel)], @[]).len == 0
    check mergeProviderArtifacts(@[], @[(typeId: "t.a", artifact: rel)]).len == 0

  test "(26) an empty providerArtifactId is no route: it would alias the pool":
    ## `providerArtifactId` is the PROVIDER-SESSION POOL KEY.
    ## `providerSessionKey` is built from it, `openProviderSession` REUSES an
    ## existing session on a key match, `closeProviderSession` matches on it,
    ## and the daemon's idleness bookkeeping is keyed on it. Nothing in the reap
    ## lane constrains the field, so two records of DIFFERENT types naming
    ## DIFFERENT absolute binaries with an empty id would collapse to ONE pool
    ## key: the first child launched would serve both, the second binary would
    ## never run, and the second type's §4.5 finding would carry the FIRST
    ## provider's error message — a wrong answer that reads like a real one.
    ##
    ## So an empty id is unlaunchable, exactly like a relative path, and both
    ## records are routed in-process and reported instead.
    ##
    ## NON-VACUITY: the launcher closure records every artifact it is asked to
    ## launch, so "neither binary was launched" is a witness; and the two
    ## records name DIFFERENT existing files, so the aliasing this prevents
    ## would have been observable as one path serving both.
    let store = scratchStore("empty-artifact-id")
    let t0 = fromUnix(1_700_000_000)
    let later = t0 + initDuration(minutes = 11)

    # Two real files, so `fileExists` is answering about real binaries and the
    # refusal cannot be mistaken for "the path is missing".
    let binA = store.root / "provider-a"
    let binB = store.root / "provider-b"
    writeFile(binA, "#!/bin/sh\nexit 0\n")
    writeFile(binB, "#!/bin/sh\nexit 0\n")

    proc aliasedRecord(address, typeId, binaryPath: string):
        ResourceStateRecord =
      ResourceStateRecord(
        address: address, typeId: typeId, determinism: rdVolatile,
        attrsTypeId: typeId, attrsJson: "\x01\x00\x00\x00\x00\x00",
        dependsOn: @[], identity: "stub:" & address, present: true,
        holders: initTable[string, Time](), keepHolders: @[],
        keepHoldersKnown: true,
        effectiveDeadline: some(t0), lastRenewed: t0,
        providerArtifact: some(ResourceProviderArtifactRef(
          binaryPath: binaryPath,
          providerArtifactId: "",        # the hazard
          workingDir: getCurrentDir())))

    writeStateRecord(store, aliasedRecord("alias-a", "l3.aliasA", binA))
    writeStateRecord(store, aliasedRecord("alias-b", "l3.aliasB", binB))

    # Neither ref is a route, so the sweep derives NO artifacts and the
    # transport for this store is the plain in-process one.
    check providerArtifactsOfRecords(listStateRecords(store)).len == 0

    var launched: seq[string] = @[]
    let report = reapOnce(store, now = later,
      transportFromRecords = reapTransportFactory(@[],
        proc (artifact: ResourceProviderArtifactRef): ProviderHandle =
          launched.add(artifact.binaryPath)
          raise newException(ValueError, "L3-SENTINEL must not be reached")))

    check launched.len == 0               # witnessed: nothing was launched
    check report.reaped.len == 0
    check report.failed.len == 2
    for f in report.failed:
      check f.kind == rfkUnreapable
      # In-process arm, and the remedy names the pool-key requirement rather
      # than the path (which is absolute and really exists here).
      check f.reason.contains("marshaller")
      check f.reason.contains("providerArtifactId is empty")
      check f.reason.contains("POOL KEY")
      check not f.reason.contains("is not an absolute path")
      check not f.reason.contains("names no provider artifact")
    check hasStateRecord(store, "alias-a")
    check hasStateRecord(store, "alias-b")

    # `mergeProviderArtifacts` drops such a ref on both sides too, so an
    # empty id cannot enter through the daemon's registry either.
    let noId = ResourceProviderArtifactRef(
      binaryPath: binA, providerArtifactId: "")
    check mergeProviderArtifacts(@[(typeId: "t.a", artifact: noId)], @[]).len == 0
    check mergeProviderArtifacts(@[], @[(typeId: "t.a", artifact: noId)]).len == 0
