## The generic reconciler: given a desired `seq[ResourceInstance]`, the
## recorded bindings from the previous generation, and options, drive
## each resource through its registered driver in dependency order.
##
## The seven-step algorithm of `Resources-And-State.md` is unchanged;
## only the per-type leaf operations move behind `driver.*`, dispatched
## by a `typeId` registry lookup rather than a closed `case kind`.
##
## The per-resource decision is a MINIMAL generic re-statement of the
## home lib's `decideAction` (which is coupled to the `Resource` union
## via `state.desired.kind` and `digestOfResource`, so not importable
## for `ResourceInstance`). It reuses the home lib's `ResourceActionKind`
## enum so both lanes emit the same action vocabulary.

import std/[tables, options, sets, algorithm, times]

from repro_home_generations/pointer import Digest256
from repro_home_resources/types import ObservedState, ResourceActionKind,
  rakNoOp, rakCreate, rakUpdate, rakReplace, rakDestroy, rakAdopt,
  rakDriftBlocked
import repro_resources/instance
import repro_resources/state_store

type
  ReconcileOptions* = object
    reconcileDrift*: bool
      ## When true, an operator-mutated (drifted) resource is converged
      ## with an update rather than emitting `rakDriftBlocked`.

  ResourceAction* = object
    ## The generic-lane planned action for one resource.
    address*: string
    typeId*: string
    kind*: ResourceActionKind
    summary*: string

  ReconcileResult* = object
    actions*: seq[ResourceAction]         ## in applied (topological) order
    bindings*: seq[ResourceBinding]       ## recorded bindings after apply

proc orderingEdges(inst: ResourceInstance): seq[string] =
  ## The full set of ordering edges for `inst`: bare structural
  ## `dependsOn` PLUS every leased-consumption `consumes[].address` (L2 —
  ## consuming a leased state implies depending on that state existing).
  ## De-duplicated so a leased dep that is also listed bare counts once.
  var seen = initHashSet[string]()
  result = @[]
  for dep in inst.dependsOn:
    if not seen.containsOrIncl(dep):
      result.add(dep)
  for ld in inst.consumes:
    if not seen.containsOrIncl(ld.address):
      result.add(ld.address)

proc topoOrder*(desired: seq[ResourceInstance]): seq[ResourceInstance] =
  ## Deterministic topological order by `dependsOn` AND leased `consumes`
  ## edges (both are resource addresses). Raises on an unknown dependency
  ## or a cycle. A bare `dependsOn`-only graph orders exactly as pre-L2.
  var byAddr = initTable[string, ResourceInstance]()
  for inst in desired:
    if byAddr.hasKey(inst.address):
      raise newException(ValueError,
        "duplicate resource address '" & inst.address & "'")
    byAddr[inst.address] = inst

  var ordered: seq[ResourceInstance] = @[]
  var visited = initHashSet[string]()
  var onStack = initHashSet[string]()

  proc visit(addrKey: string) =
    if addrKey in visited: return
    if addrKey in onStack:
      raise newException(ValueError,
        "dependency cycle involving resource '" & addrKey & "'")
    onStack.incl(addrKey)
    let inst = byAddr[addrKey]
    # Sort deps for a stable, reproducible order independent of the
    # authored `dependsOn` / `consumes` sequence order.
    var deps = orderingEdges(inst)
    deps.sort()
    for dep in deps:
      if not byAddr.hasKey(dep):
        raise newException(KeyError,
          "resource '" & addrKey & "' depends on unknown address '" &
          dep & "'")
      visit(dep)
    onStack.excl(addrKey)
    visited.incl(addrKey)
    ordered.add(inst)

  # Visit in a stable order (authored order) so independent subgraphs
  # keep their declaration order.
  for inst in desired:
    visit(inst.address)
  ordered

proc decide*(desiredDigest: Digest256; observed: ObservedState;
            recorded: Option[ResourceBinding];
            options: ReconcileOptions): ResourceActionKind =
  ## Minimal generic decision, mirroring the home lib's `decideAction`
  ## branch structure for the desired-present case.
  if not observed.present:
    return rakCreate
  if observed.digest == desiredDigest:
    return rakNoOp                       # cache-hit: live state == desired
  # Observed differs from desired. If we recorded writing exactly what
  # is now observed, it is a safe update; if we never wrote it, the
  # diff is the initial-convergence delta (also an update); otherwise
  # it is operator drift.
  if recorded.isSome and recorded.get.present and
     recorded.get.postWriteDigest == observed.digest:
    return rakUpdate
  if recorded.isNone:
    return rakUpdate
  if options.reconcileDrift:
    return rakUpdate
  return rakDriftBlocked

proc collectLeaseHolders*(desired: seq[ResourceInstance]):
    Table[string, seq[LeasedDep]] =
  ## Group every leased-consumption edge by the STATE address it targets:
  ## `stateAddress -> seq[LeasedDep]` (each carrying its consumerId +
  ## policy). This is the per-state holder set being RENEWED this run.
  result = initTable[string, seq[LeasedDep]]()
  for inst in desired:
    for ld in inst.consumes:
      result.mgetOrPut(ld.address, @[]).add(ld)

proc foldEffectiveDeadline(rec: ResourceStateRecord): Option[Time] =
  ## The reaper's gate, derived from the holder sets (§2.3):
  ##
  ##   * any recorded keep holder -> `none` (keep dominates every dated holder);
  ##   * an UNKNOWN keep-holder set (`keepHoldersKnown == false`, a pre-v4
  ##     record still `none`) -> `none`: an anonymous keep pin may exist, and
  ##     re-arming a deadline under a pin we cannot see would let the reaper
  ##     destroy pinned state;
  ##   * otherwise MAX over the dated deadlines, so an `immediate` (now)
  ##     holder never SHORTENS a `delayed`/later one; `none` if there is no
  ##     dated holder at all.
  if rec.keepHolders.len > 0 or not rec.keepHoldersKnown:
    return none(Time)
  result = none(Time)
  for _, dl in rec.holders:
    if result.isNone or dl > result.get:
      result = some(dl)

proc applyHolderRenewal*(rec: var ResourceStateRecord; consumerId: string;
                         policy: LeasePolicy; now: Time) =
  ## Apply ONE consumer's renewal to `rec`'s lease fields in place. This is
  ## THE renewal primitive: reconcile's `mergeHolderDeadlines` folds it over
  ## a run's renewals, and the daemon's `udkLeaseRenew` handler
  ## (`repro_daemon_core/lease_registry.renewHolder`) applies it to one —
  ## so both sides of §4.3 (in-process store write, daemon registry) agree
  ## on what a renewal means.
  ##
  ##   * a DATED policy (`immediate`/`delayed`) sets `holders[consumerId] =
  ##     deadlineFrom(policy, now)` and removes the consumer from
  ##     `keepHolders` — a keep holder that renews under a dated policy gives
  ##     up its pin;
  ##   * `keep` removes the consumer from the dated map (it must not
  ##     masquerade as an expiring holder) and records it BY NAME in
  ##     `keepHolders`, which keeps the pin across runs until that same
  ##     consumer renews under a dated policy or the record is removed;
  ##   * `lastRenewed = now`, and `effectiveDeadline` is re-derived
  ##     (`foldEffectiveDeadline`).
  ##
  ## An unknown keep-holder set (`keepHoldersKnown == false`, a pre-v4 record
  ## still `none` — the decoder already marks a pre-v4 record that carries a
  ## dated deadline as known) stays unknown: this renewal's holders are
  ## recorded by name, but naming one holder does not prove there is no
  ## other, so it stays never-reap until the record is removed. The upgrade
  ## below covers an in-memory record constructed without the field (Nim's
  ## `false` default) beside a dated deadline: a dated deadline is never
  ## written under a keep pin, so there is no pin to lose.
  if not rec.keepHoldersKnown and rec.effectiveDeadline.isSome:
    rec.keepHoldersKnown = true
  let dl = deadlineFrom(policy, now)
  if dl.isSome:
    rec.holders[consumerId] = dl.get
    let at = rec.keepHolders.find(consumerId)
    if at >= 0:
      rec.keepHolders.delete(at)
  else:
    rec.holders.del(consumerId)
    if consumerId notin rec.keepHolders:
      rec.keepHolders.add(consumerId)
      rec.keepHolders.sort()           # canonical: ascending, no duplicates
  rec.lastRenewed = now
  rec.effectiveDeadline = foldEffectiveDeadline(rec)

proc mergeHolderDeadlines*(existing: Option[ResourceStateRecord];
                          renewals: seq[LeasedDep]; now: Time):
    tuple[holders: Table[string, Time]; keepHolders: seq[string];
          keepHoldersKnown: bool; effective: Option[Time]] =
  ## Apply this run's `renewals` to the lease state of the `existing` record
  ## (`none` when the state has no record yet) and return the merged lease
  ## fields to persist — the dated holders, the keep holders, whether the
  ## keep-holder set is complete, and the re-derived effective deadline.
  ## Each renewal is `applyHolderRenewal`; see it for the rules (§2.3).
  ##
  ## The WHOLE existing holder state goes in, not just the dated map: a keep
  ## holder from an earlier run is part of it, and a merge that could not see
  ## it would re-arm a reap deadline under a pinned state the moment any
  ## dated consumer renewed.
  var rec =
    if existing.isSome: existing.get
    else: ResourceStateRecord(holders: initTable[string, Time](),
                              keepHoldersKnown: true)   # nothing to not know
  for ld in renewals:
    applyHolderRenewal(rec, ld.consumerId, ld.policy, now)
  (holders: rec.holders, keepHolders: rec.keepHolders,
   keepHoldersKnown: rec.keepHoldersKnown, effective: rec.effectiveDeadline)

proc writeUnconsumedStateRecord*(store: StateStore; inst: ResourceInstance;
                                 binding: ResourceBinding) =
  ## Persist the record of a resource NO consumer leases this run (a plain
  ## resource, or a leased state that is in the graph but unconsumed), with
  ## its lease fields CARRIED FORWARD unchanged from the existing record.
  ##
  ## A lease ends only by its own holder's renewal or by explicit teardown
  ## (Ephemeral-State-Leases §2.3): a keep holder stays recorded until that
  ## consumer renews under a dated policy, and a dated holder keeps its
  ## deadline until the reaper acts on it. A run that merely does not consume
  ## the state is neither, so it must not touch the lease. Writing the lease
  ## fields empty here (what this write used to do) silently dropped a keep
  ## holder's name, and turned a dated state into a never-reap one — its
  ## deadline gone, `effectiveDeadline` `none`.
  ##
  ## Everything else (identity, digest, attrs, …) is this run's. With no
  ## existing record, the lease fields are the empty defaults: nothing has
  ## leased it. An existing record that cannot be decoded is overwritten
  ## with those defaults, as this write always did: a non-leased reconcile
  ## has never failed on a damaged record, and there is no lease in it to
  ## carry forward that anyone could read.
  var rec = buildStateRecord(inst, binding)
  if hasStateRecord(store, inst.address):
    var prior = none(ResourceStateRecord)
    try:
      prior = some(readStateRecord(store, inst.address))
    except IOError, StateStoreCodecError:
      discard
    if prior.isSome:
      let p = prior.get
      rec.holders = p.holders
      rec.keepHolders = p.keepHolders
      rec.keepHoldersKnown = p.keepHoldersKnown
      rec.effectiveDeadline = p.effectiveDeadline
      rec.lastRenewed = p.lastRenewed
  writeStateRecord(store, rec)

proc reconcileResources*(desired: seq[ResourceInstance];
                         recorded: seq[ResourceBinding] = @[];
                         options: ReconcileOptions = ReconcileOptions();
                         store: Option[StateStore] = none(StateStore);
                         now: Time = getTime()):
                         ReconcileResult =
  ## Drive the desired graph to convergence. Topologically orders by
  ## `dependsOn`, then per resource: look up the driver by `typeId`
  ## (hard error on unknown), `observe` -> `decide` -> `apply`,
  ## recording the returned binding. Pure w.r.t. process state — all
  ## real-world effect is confined to the driver callbacks, so it is
  ## unit-testable with an in-memory driver.
  ##
  ## L1 (Ephemeral-State-Leases §3) additive persistence: when `store`
  ## is `some`, a `ResourceStateRecord` is written for every resource
  ## whose binding is present after this reconcile (created/updated, or a
  ## no-op carrying a prior present binding) — the cross-run reuse index
  ## + the reaper's source of truth. When `store` is `none` (the default)
  ## the loop is BYTE-IDENTICAL to the pre-L1 behaviour: no store I/O, no
  ## record writes.
  ##
  ## L2 (Ephemeral-State-Leases §2.2/§2.3) — store-backed lease handling.
  ## When `store` is `some`, for a resource that is a leased STATE (i.e.
  ## some consumer's `consumes` targets its address this run):
  ##
  ##   * REUSE-OR-MATERIALIZE: if the store already has a PRESENT record
  ##     for the state whose `digest` matches the desired digest, the state
  ##     is up + current — REUSE it (emit `rakNoOp`, do NOT `observe`/
  ##     `apply`; this is the cross-run reuse the feature exists for). If
  ##     the record is absent/stale, materialize normally.
  ##   * RENEW: set `holders[consumerId] = deadlineFrom(policy, now)` for
  ##     each dated consumer this run, record each `keep` consumer by name in
  ##     `keepHolders` (it pins with no deadline), set `lastRenewed = now`,
  ##     and recompute `effectiveDeadline = max(holders)` (none while any
  ##     keep holder — this run's or an earlier run's — is recorded). The
  ##     updated lease fields are persisted with the record.
  ##
  ## A non-leased resource (no `consumes` targeting it) follows the L1 path,
  ## carrying any lease its existing record holds forward unchanged
  ## (`writeUnconsumedStateRecord`); when `store` is `none` the whole loop is
  ## byte-identical to pre-L1. `now` is injectable for hermetic tests.
  result.actions = @[]
  result.bindings = @[]

  var recordedByAddr = initTable[string, ResourceBinding]()
  for b in recorded:
    recordedByAddr[b.address] = b

  let leaseHolders =
    if store.isSome: collectLeaseHolders(desired)
    else: initTable[string, seq[LeasedDep]]()

  for inst in topoOrder(desired):
    let def = lookupResourceProvider(inst.typeId)   # hard error on unknown
    let drv = def.driver
    let prior =
      if recordedByAddr.hasKey(inst.address): some(recordedByAddr[inst.address])
      else: none(ResourceBinding)

    let desiredDigest = drv.digest(inst)
    let renewals =
      if leaseHolders.hasKey(inst.address): leaseHolders[inst.address]
      else: @[]
    let isLeasedState = renewals.len > 0

    # L2 cross-run reuse: a leased state with a PRESENT, digest-matching
    # store record is already up + current — reuse it WITHOUT observing or
    # re-applying the provider (the store record is the reuse index).
    var reuseRec = none(ResourceStateRecord)
    if isLeasedState and store.isSome and hasStateRecord(store.get, inst.address):
      let rec = readStateRecord(store.get, inst.address)
      if rec.present and rec.digest == desiredDigest:
        reuseRec = some(rec)

    var effective = none(ResourceBinding)
    var action: ResourceActionKind

    if reuseRec.isSome:
      # Reuse path: no observe, no apply. Reconstruct the effective binding
      # from the persisted record so downstream reconciles + the result see
      # the recorded identity/digest.
      action = rakNoOp
      let rec = reuseRec.get
      let binding = ResourceBinding(
        address: rec.address, typeId: rec.typeId,
        resourceId: rec.identity, postWriteDigest: rec.digest,
        present: rec.present)
      result.bindings.add(binding)
      recordedByAddr[inst.address] = binding
      effective = some(binding)
    else:
      let observed = drv.observe(inst, prior)
      action = decide(desiredDigest, observed, prior, options)
      case action
      of rakCreate, rakUpdate, rakReplace, rakDestroy:
        let binding = drv.apply(inst, action, observed)
        result.bindings.add(binding)
        recordedByAddr[inst.address] = binding
        effective = some(binding)
      of rakNoOp, rakAdopt, rakDriftBlocked:
        # No apply. Carry the prior binding forward if we had one so a
        # subsequent reconcile still sees the recorded post-write digest.
        if prior.isSome:
          result.bindings.add(prior.get)
          effective = prior

    result.actions.add(ResourceAction(
      address: inst.address,
      typeId: inst.typeId,
      kind: action,
      summary: $action & " " & inst.address & " (" & inst.typeId & ")"))

    # L1/L2: persist a reconstructable record for a materialized resource,
    # only when a store is configured (opt-in — the no-store path is
    # untouched). For a leased state, also RENEW the lease (§2.3): merge
    # this run's holder deadlines into the record's holders and recompute
    # the reference-counted MAX effective deadline.
    if store.isSome and effective.isSome and effective.get.present:
      if isLeasedState:
        let existing =
          if hasStateRecord(store.get, inst.address):
            some(readStateRecord(store.get, inst.address))
          else:
            none(ResourceStateRecord)
        let merged = mergeHolderDeadlines(existing, renewals, now)
        # `merged.effective` is `none` when this state has NO reap deadline
        # (a recorded `keep` holder, or no dated holder) — persisted as an
        # OPTIONAL deadline (`none` = never reap), NOT an epoch-0/PAST
        # sentinel that the reaper's `deadline < now` gate would wrongly
        # reap. The keep holders are written BY NAME, so the record says
        # which of the two `none`s it is and who pins it.
        writeStateRecord(store.get, inst, effective.get,
          holders = merged.holders,
          effectiveDeadline = merged.effective,
          lastRenewed = now,
          keepHolders = merged.keepHolders,
          keepHoldersKnown = merged.keepHoldersKnown)
      else:
        # Not consumed this run: carry any existing lease forward untouched.
        writeUnconsumedStateRecord(store.get, inst, effective.get)
