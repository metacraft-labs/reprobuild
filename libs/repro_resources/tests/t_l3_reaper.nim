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
    ## transport for all 131,882 ticks — `buildLeaseReapTransport` falls back
    ## to it when no provider artifact is registered, and nothing in the
    ## shipped tree registers one — where its record had no linked driver
    ## either and the strict path is still right. This case pins the second,
    ## independent defect that would have produced the identical symptom in a
    ## daemon that did have the artifact.
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
