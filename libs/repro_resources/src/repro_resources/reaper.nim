## L3 (Ephemeral-State-Leases.md §4): the crash-safe reaper.
##
## The reaper destroys IDLE leased state. It works ENTIRELY from the L1
## on-disk state store — never from an in-memory desired graph — so it is
## correct after a crash, across a fresh process, and without a running
## daemon (§4.3). Its inputs are a `StateStore` and a `now`; its effect is:
## reconstruct each reapable `ResourceInstance` from the persisted attrs
## (L1 `reconstructInstance` on the in-process arm, `reconstructInstanceOpaque`
## on the session arm — see `reconstructFor`), `observe` it,
## `apply(rakDestroy)`, and `removeStateRecord` on success.
##
## The SELECTION PREDICATE (the L2 reap-safety property, verified here):
##
##   * `effectiveDeadline == none`  -> NEVER reap. `none` means "a `keep`
##     holder pins it" (named in `keepHolders`), "no dated holder", or — for
##     a pre-v4 record (`keepHoldersKnown == false`) — "maybe an anonymous
##     keep pin": there is NO reap deadline. This is deliberately an
##     `Option`, not an epoch-0/PAST sentinel — a PAST sentinel would make
##     the natural `deadline < now` gate destroy a pinned state. A `none`
##     record is unconditionally skipped.
##   * `effectiveDeadline == some(t)` with `t <= now` AND no LIVE holder ->
##     reap. A holder is LIVE if it is a recorded `keep` holder (no expiry)
##     or its own deadline is still in the future
##     (`holders[c] > now`); a live holder keeps the state even if the
##     folded `effectiveDeadline` looks passed (defense in depth — normally
##     `effectiveDeadline == max(holders)`, so a live holder already lifts
##     it, but the reaper re-checks per-holder liveness from the store so a
##     stale/racy folded deadline can never over-reap).
##   * An ORPHANED lease (the consumer process was killed, its holder
##     deadline has since passed) is therefore reaped like any other
##     expired dated state: nothing in memory pins it, its holder is not
##     live, its `effectiveDeadline` is `some(past)`.
##
## `force = true` (the `--rebuild-host-bound` / `--hard-rebuild` path,
## §5 interaction) ignores the deadline + holder liveness entirely and
## selects EVERY present record (or a named subset) for destruction, so a
## re-materialize starts from a clean world regardless of an unexpired
## lease.
##
## DESTROY TRANSPORT (§4.2) is a STRATEGY the caller injects: the primary
## is the RP provider-SESSION protocol (`applyViaSession` /
## `observeViaSession` against a launched out-of-tree provider — reached
## WITHOUT linking its driver), with the in-process
## `lookupResourceProvider(typeId).driver.*` as the fallback for a provider
## already in this process's closure. The persisted `typeId` + attrs are
## transport-agnostic; the reaper picks the op path per record.
##
## "WITHOUT LINKING ITS DRIVER" EXTENDS TO THE ATTRS CODEC. A session reap
## re-marshals the persisted attrs box straight back out to the provider
## process, so it never reads the typed value and must not require the codec
## that produces one; `reconstructFor` gives it the opaque reconstruction. An
## in-process reap hands the box to a LINKED driver that does read it, so it
## keeps the strict one.
##
## The reaper used to reconstruct strictly on BOTH arms. That was a latent
## requirement contradicting §4.2's own promise — a daemon holding a provider
## artifact but not the provider's attrs codec, which is the configuration
## §4.2 describes, could not reap over the session it had. Removing it is what
## makes that configuration work.
##
## IT IS NOT, HOWEVER, THE CAUSE OF THE MEASURED OUTAGE, and the distinction
## matters because the outage is what is cited around here. The live per-user
## daemon's 131,882 consecutive failing ticks over 57 days
## (reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md)
## came through the IN-PROCESS arm: the transport fell back to
## `inProcessTransport()` because no provider artifact was known, and at the
## time NOTHING in the shipped tree could make one known
## (reprobuild-pm/issues/2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md).
## Its `vm_harness.nic` record had neither a linked driver nor a linked codec
## there, so it was unreapable by that process by ANY route, and strict
## reconstruction remains correct for it. What this split fixes is the second,
## independent defect that would have produced the identical symptom in a
## daemon that did have the artifact.
##
## WHERE THE ARTIFACT COMES FROM NOW (that second issue, closed): the record
## itself carries it (`ResourceStateRecord.providerArtifact`, v5), written by
## the reconcile that materialized the resource over a session, and a consuming
## `repro run` additionally registers it with the running daemon. A sweep merges
## the two — see `reapTransportFactory` — so the §4.2 session transport is
## selected by the daemon tick, by `repro reap`, and by the reconcile-start
## sweep, from the store alone and across a daemon restart.
##
## REVERSE TOPO (§4.2): a group is destroyed in the REVERSE of its
## dependency order (nics -> containers -> networks) computed from the
## persisted `dependsOn` edges of the records being reaped — a dependent is
## torn down before the state it depends on.

import std/[tables, options, sets, algorithm, times, sequtils, os,
  strutils]

from repro_home_resources/types import ObservedState, ResourceActionKind,
  rakDestroy
import repro_resources/instance
import repro_resources/state_store
import repro_resources/marshal          # isAttrsMarshallerRegistered — the
                                        # strict/opaque decision + its diagnosis
import repro_provider_runtime           # ProviderHandle
import repro_resources/protocol         # observeViaSession / applyViaSession

type
  ReapTransportKind* = enum
    ## How a reap destroys one record's real-world state.
    rtInProcess   ## in-process `lookupResourceProvider(typeId).driver.*`
    rtSession     ## over an RP provider session (`observe/applyViaSession`)

  ReapTransport* = object
    ## The destroy strategy the reaper uses per record. `rtInProcess`
    ## needs nothing (the driver is linked); `rtSession` needs a resolver
    ## that hands back the launched provider session for a `typeId` (the
    ## same shape the RP5b engine-side reconcile uses).
    case kind*: ReapTransportKind
    of rtInProcess:
      discard
    of rtSession:
      resolve*: proc (typeId: string): ProviderHandle {.closure.}
      inProcess*: proc (typeId: string): bool {.closure.}
        ## Optional HYBRID gate, the reap-side twin of
        ## `reconcileResourcesViaSession`'s `ResourceInProcessPredicate`:
        ## return true for a `typeId` this sweep must destroy through its
        ## LINKED driver instead of over the session.
        ##
        ## WHY A SESSION TRANSPORT NEEDS AN IN-PROCESS ARM AT ALL. A transport
        ## is chosen once per SWEEP, and a sweep runs over a whole store — one
        ## store holds records of every type the host has leased, in-tree and
        ## out-of-tree together. Without this gate, the moment anything gives
        ## the reaper ONE provider artifact, every in-tree record in the same
        ## store starts failing: `resolve` has no artifact for its type and
        ## raises, and a record that was reapable a tick ago becomes an
        ## `rfkUnreapable` finding. So the production feeders for the session
        ## transport (Ephemeral-State-Leases.md §4.2) could not be added
        ## without it — see `artifactSessionTransport`, which is where the
        ## predicate is built and where the per-record rule is stated once.
        ##
        ## `nil` sends every op over the session (the RP5b / L5 behaviour,
        ## unchanged), so a caller that pins a resolver by hand is unaffected.

  ReapEvent* = object
    ## One reaped record, in the order it was destroyed — the witness a
    ## test asserts against (reverse-topo order, idempotency).
    address*: string
    typeId*: string
    wasPresent*: bool   ## true if `observe` saw it live (a real destroy);
                        ## false = already-absent clean no-op (record still removed)

  ReapFailureKind* = enum
    ## Why a SELECTED record was not reaped by this sweep.
    rfkUnreapable   ## attempted; the per-record op RAISED (see `reason`)
    rfkBlocked      ## NOT attempted: a record that DEPENDS on it is unreapable,
                    ## so destroying it would break the reverse-topo invariant

  ReapFailure* = object
    ## One record the sweep SELECTED but could not reap. Deliberately NOT
    ## folded into `skipped`: `skipped` means "inspected and correctly kept"
    ## (never-reap / still leased), which is a healthy outcome, while this is
    ## a record the reaper was asked to destroy and could not. Collapsing the
    ## two would make a permanently stuck store read as a healthy one.
    address*: string
    typeId*: string
    kind*: ReapFailureKind
    reason*: string
      ## `rfkUnreapable`: the raised message. `rfkBlocked`: which unreapable
      ## dependent is holding this record back.

  ReapReport* = object
    ## The outcome of a sweep.
    reaped*: seq[ReapEvent]        ## destroyed (or already-absent) records removed, in order
    skipped*: seq[string]          ## addresses inspected but kept (still leased / never-reap)
    failed*: seq[ReapFailure]      ## selected but NOT reaped — see `ReapFailure`
    # Records the sweep could not even READ (`scanStateRecords`). They have no
    # decodable address, so `onlyAddresses` cannot filter them and they are
    # always reported.
    foreign*: seq[ForeignStateRecord]
      ## written by a NEWER repro: left untouched, never reaped
    quarantined*: seq[QuarantinedStateRecord]
      ## corrupt: moved into the store's `quarantine/` dir by this sweep
    unreadable*: seq[UnreadableStateRecord]
      ## could neither be decoded nor quarantined; still in place

proc inProcessTransport*(): ReapTransport =
  ReapTransport(kind: rtInProcess)

proc sessionTransport*(resolve: proc (typeId: string): ProviderHandle {.closure.};
                       inProcess: proc (typeId: string): bool {.closure.} = nil):
    ReapTransport =
  ReapTransport(kind: rtSession, resolve: resolve, inProcess: inProcess)

proc routesInProcess(transport: ReapTransport; typeId: string): bool =
  ## Does `typeId` go through the LINKED driver on this transport?
  ##
  ## The ONE place the question is answered, because three call sites ask it
  ## and they must agree: `observeVia`, `destroyVia` and — critically —
  ## `reconstructFor`, which picks the STRICT or the OPAQUE attrs
  ## reconstruction. A record reconstructed opaquely and then handed to a
  ## linked driver would have its attrs box cast to the wrong type, and one
  ## reconstructed strictly for a session reap would demand a codec the
  ## session arm exists not to need (Ephemeral-State-Leases.md §4.5, "Which
  ## transport needs the attrs codec"). Those are opposite failures, and three
  ## independent copies of this condition is how a later edit produces one of
  ## them.
  transport.kind == rtSession and transport.inProcess != nil and
    transport.inProcess(typeId)

proc reapEngineHello*(): EngineHello =
  ## The engine handshake a REAP session is opened with — the daemon's tick, the
  ## `repro reap` CLI and the reconcile-start opportunistic sweep all use this
  ## one, so a provider sees the same engine identity whichever of them reached
  ## it (Ephemeral-State-Leases.md §4.2).
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["ephemeral-state-lease-reaper"],
    lockSliceId: "lease-reaper",
    canonicalExecutionRoot: getCurrentDir())

# ---------------------------------------------------------------------------
# Which provider artifact serves which typeId (Ephemeral-State-Leases.md §4.2).
#
# A reap over the session transport needs the provider BINARY for the record's
# type. Two sources supply it, and they compose:
#
#   * the record itself (`ResourceStateRecord.providerArtifact`, v5) — DURABLE:
#     it is on disk, so it survives a daemon restart and needs no re-evaluation
#     of the recipe that produced it, which is what §4.3's "the L1 on-disk store
#     is the source of truth" asks for. It can also be STALE: a build output
#     path outlives neither a rebuild nor a store garbage collection.
#   * an artifact registered with the running daemon
#     (`registerLeaseReapProvider`, fed by a consuming `repro run`) — FRESH: it
#     came from a process that is launching that provider right now. So it wins
#     where both are present.
#
# `mergeProviderArtifacts` is that precedence, `providerArtifactsOfRecords` is
# the durable half, and `artifactSessionTransport` turns the merged answer into
# the transport. Keeping the three here rather than in the daemon means the CLI
# fallbacks (§4.3 (a) and (b)) resolve a provider by exactly the same rule the
# daemon tick does.
# ---------------------------------------------------------------------------

type
  ProviderArtifactBinding* = tuple[typeId: string;
                                   artifact: ResourceProviderArtifactRef]
    ## One `typeId` -> provider-artifact mapping, the shape every producer and
    ## consumer of the set below passes around (the resource-graph metadata,
    ## the daemon registry, a record scan).

  ReapTransportFromRecords* = proc (artifacts: seq[ProviderArtifactBinding]):
      ReapTransport {.closure.}
    ## Builds the transport for one sweep from the artifacts that sweep's OWN
    ## records carry. `reapOnce` calls it after its single `scanStateRecords`,
    ## so the records are decoded once — see `reapOnce` for why a second scan
    ## would be worse than merely slower.

proc isLaunchableArtifact*(artifact: ResourceProviderArtifactRef): bool =
  ## Can this ref be used to open a provider session AT ALL? Two independent
  ## requirements, both about how the ref is CONSUMED rather than about taste.
  ##
  ## 1. `binaryPath` MUST BE ABSOLUTE (and non-empty). It reaches
  ##    `startProcess` through `openProviderSession`, which passes
  ##    `poUsePath` — so a RELATIVE path is resolved through the ambient `PATH`
  ##    of whatever process is sweeping. That is wrong on its own terms
  ##    whoever wrote the record: the field is meant to name one specific build
  ##    output by its own path, and `PATH` resolution makes the binary that
  ##    runs a function of the sweeper's environment instead. For the
  ##    system-scoped store the daemon and the writer need not even be the same
  ##    user.
  ##
  ## 2. `providerArtifactId` MUST BE NON-EMPTY, because it is the POOL KEY.
  ##    `providerSessionKey` is built from it, `openProviderSession` REUSES an
  ##    existing session on a key match, and the reaper's idleness bookkeeping
  ##    is keyed on it too. Two refs naming DIFFERENT absolute binaries with an
  ##    empty id therefore collapse to one key: the first child launched serves
  ##    both types, the second binary is never launched at all, and the second
  ##    type's §4.5 finding carries the FIRST provider's error message — a
  ##    wrong answer that reads like a real one. Nothing in the reap lane
  ##    constrains the field, so the aliasing is silent; refusing an empty id
  ##    is what keeps one pool entry meaning one binary.
  ##
  ## A ref failing either test is treated as NO ROUTE: the record is routed
  ## in-process and reported by the §4.5 finding, which is a true statement
  ## about a record nobody can safely act on, rather than launching whatever
  ## `PATH` resolves or reusing an unrelated child.
  ##
  ## VALIDATED HERE AND NOT IN THE CODEC, deliberately. The codec is the wrong
  ## layer to decide what a launcher will accept — and a negative test
  ## legitimately records an unlaunchable path to prove a missing provider is
  ## refused (`tests/e2e/local-build-engine/t_e2e_repro_run_named_run_edge.nim`
  ## registers `binaryPath: "missing-required-provider"`). The field is an
  ## argument to a process launch, so it is checked where the launch is chosen.
  artifact.binaryPath.len > 0 and isAbsolute(artifact.binaryPath) and
    artifact.providerArtifactId.len > 0

proc providerArtifactsOfRecords*(records: seq[ResourceStateRecord]):
    seq[ProviderArtifactBinding] =
  ## The per-`typeId` provider artifacts `records` carry, de-duplicated and
  ## sorted by `typeId`.
  ##
  ## REACHABILITY DECIDES, NOT RECORD ORDER, and that is the point of this
  ## proc rather than a one-line fold. Resolution is per TYPE within a sweep
  ## (the per-RECORD choice is only the in-process-vs-session arm), so when two
  ## records of one type name DIFFERENT artifacts, whichever wins is used for
  ## both. Taking the first by filename would let a record from last week's
  ## build — whose store path has since been garbage-collected — mask a sibling
  ## carrying a route that still works, making a perfectly reapable record
  ## permanently unreapable for as long as the stale neighbour sits there.
  ##
  ## So a candidate whose `binaryPath` EXISTS on disk is preferred. The
  ## fallback, when no candidate exists, is the first launchable one in record
  ## order — not nothing: a concrete path in the §4.5 finding is what tells the
  ## operator which build went missing, where silence would say only that the
  ## type is unreachable.
  ##
  ## `fileExists` here is a HINT, not a guarantee, and the code does not pretend
  ## otherwise: the file can vanish between this check and the launch. Losing
  ## that race produces the same per-record finding the stale path produces, so
  ## the check can only improve the outcome, never break it.
  ##
  ## Determinism is still preserved — ties break by record order, which
  ## `scanStateRecords` already fixed (sorted by filename) — so a sweep's
  ## transport does not depend on directory iteration order. A record whose ref
  ## is absent or unlaunchable (`isLaunchableArtifact`) contributes nothing and
  ## is reaped in-process or reported; it never blanks a sibling's ref.
  var byType = initTable[string, ResourceProviderArtifactRef]()
  var resolved = initHashSet[string]()      ## types whose winner exists on disk
  for rec in records:
    if rec.providerArtifact.isNone:
      continue
    let a = rec.providerArtifact.get
    if not isLaunchableArtifact(a):
      continue
    let onDisk = fileExists(a.binaryPath)
    if not byType.hasKey(rec.typeId):
      byType[rec.typeId] = a
      if onDisk:
        resolved.incl(rec.typeId)
    elif onDisk and rec.typeId notin resolved:
      # A later record carries a route that is actually there; the one already
      # chosen is not. Upgrade, and stop looking for this type.
      byType[rec.typeId] = a
      resolved.incl(rec.typeId)
  result = @[]
  for typeId, artifact in byType:
    result.add((typeId: typeId, artifact: artifact))
  result.sort(proc (a, b: ProviderArtifactBinding): int = cmp(a.typeId, b.typeId))

proc mergeProviderArtifacts*(primary: openArray[ProviderArtifactBinding];
                             fallback: openArray[ProviderArtifactBinding]):
    seq[ProviderArtifactBinding] =
  ## `primary` wins per `typeId`; `fallback` supplies the types it does not
  ## name. Sorted by `typeId` so the merged set is deterministic.
  ##
  ## An UNLAUNCHABLE ref on either side is dropped rather than carried
  ## (`isLaunchableArtifact`): it would mask a usable fallback with something
  ## that cannot be launched, or send the sweep to whatever the ambient `PATH`
  ## resolves a relative name to.
  var byType = initTable[string, ResourceProviderArtifactRef]()
  for b in fallback:
    if isLaunchableArtifact(b.artifact):
      byType[b.typeId] = b.artifact
  for b in primary:
    if isLaunchableArtifact(b.artifact):
      byType[b.typeId] = b.artifact
  result = @[]
  for typeId, artifact in byType:
    result.add((typeId: typeId, artifact: artifact))
  result.sort(proc (a, b: ProviderArtifactBinding): int = cmp(a.typeId, b.typeId))

proc artifactSessionTransport*(artifacts: openArray[ProviderArtifactBinding];
                               open: proc (artifact: ResourceProviderArtifactRef):
                                   ProviderHandle {.closure.}):
    ReapTransport =
  ## THE §4.2 ROUTING RULE, in one place: given the provider artifacts this
  ## sweep knows about, which transport destroys which record.
  ##
  ##   * a type WITH an artifact -> over a provider session, launched by `open`
  ##     (pooled by the caller, so one session per artifact id is reused);
  ##   * a type WITHOUT one -> in-process, where either its driver is linked
  ##     (the §4.2 fallback "for providers already in the daemon's closure") or
  ##     the existing diagnosable refusal fires and §4.5 reports it;
  ##   * NO artifacts at all -> the plain in-process transport, byte-identical
  ##     to the pre-feeder behaviour, so a host that has never materialized an
  ##     out-of-tree resource pays nothing and launches nothing.
  ##
  ## The choice is PER RECORD, not per sweep: see `ReapTransport.inProcess` for
  ## what a per-sweep choice would do to the in-tree records sharing the store.
  ##
  ## The daemon tick, `repro reap` and the reconcile-start sweep all come
  ## through here, so none of them can resolve a provider by a different rule
  ## than the others.
  if artifacts.len == 0:
    return inProcessTransport()
  var byType = initTable[string, ResourceProviderArtifactRef]()
  for b in artifacts:
    byType[b.typeId] = b.artifact
  let resolve = proc (typeId: string): ProviderHandle =
    # Defence in depth: the `inProcess` gate below already keeps an
    # artifact-less type away from here, so reaching this raise means the two
    # disagreed. Say which type, so the finding names it rather than reporting
    # a nil handle three frames later.
    if not byType.hasKey(typeId):
      raise newException(ValueError,
        "no provider artifact registered for resource type " & typeId)
    open(byType[typeId])
  let inProcess = proc (typeId: string): bool = not byType.hasKey(typeId)
  sessionTransport(resolve, inProcess)

proc reapTransportFactory*(primary: openArray[ProviderArtifactBinding];
                           open: proc (artifact: ResourceProviderArtifactRef):
                               ProviderHandle {.closure.}):
    ReapTransportFromRecords =
  ## The `transportFromRecords` every production sweep passes to `reapOnce`:
  ## merge the caller's own artifacts (`primary` — the daemon's in-memory
  ## registry, or the run-edge's harvested refs) over the ones the swept records
  ## carry, and build the transport from the result. `primary` wins, because it
  ## came from a live process and a recorded path can be stale.
  ##
  ## Both the daemon tick and the CLI pass exactly this, differing only in
  ## `primary` and in which pool `open` draws from.
  let primarySeq = @primary
  result = proc (fromRecords: seq[ProviderArtifactBinding]): ReapTransport =
    artifactSessionTransport(mergeProviderArtifacts(primarySeq, fromRecords),
      open)

# ---------------------------------------------------------------------------
# Selection predicate.
# ---------------------------------------------------------------------------

proc hasLiveHolder*(rec: ResourceStateRecord; now: Time): bool =
  ## A holder is LIVE if it is a recorded `keep` holder — it pins with no
  ## expiry, so it is live at every `now` — or its own recorded deadline is
  ## still in the future. A live holder keeps the state regardless of the
  ## folded `effectiveDeadline`. (The merge never writes a keep holder next
  ## to a dated effective deadline; checking it here is the same defense in
  ## depth as the dated check: the gate re-reads the holders it can see
  ## rather than trusting the fold alone.)
  if rec.keepHolders.len > 0:
    return true
  for _, deadline in rec.holders:
    if deadline > now:
      return true
  false

proc isReapable*(rec: ResourceStateRecord; now: Time; force = false): bool =
  ## The L3 reap gate.
  ##
  ##   * `force`                     -> reap iff the record is still present
  ##     (ignore deadline + holder liveness — the `--hard-rebuild` path).
  ##   * `effectiveDeadline.isNone`  -> NEVER reap (a keep holder, possibly
  ##     an anonymous pre-v4 one, or no dated holder).
  ##   * a live holder (a recorded keep holder, or `holders[c] > now`) ->
  ##     NEVER reap (still pinned / in use).
  ##   * otherwise reap iff `effectiveDeadline.get <= now`.
  if force:
    return rec.present
  if rec.effectiveDeadline.isNone:
    return false                       # never-reap: keep dominates
  if hasLiveHolder(rec, now):
    return false                       # a keep or unexpired holder keeps it
  rec.effectiveDeadline.get <= now

proc selectReapable*(records: seq[ResourceStateRecord]; now: Time;
                     force = false): seq[ResourceStateRecord] =
  ## Every record the gate selects, unordered (the caller orders for destroy).
  result = @[]
  for rec in records:
    if isReapable(rec, now, force):
      result.add(rec)

# ---------------------------------------------------------------------------
# Reverse topological order for destroy (nics -> containers -> networks).
# ---------------------------------------------------------------------------

proc reverseTopoOrder*(records: seq[ResourceStateRecord]):
    seq[ResourceStateRecord] =
  ## Order `records` so a DEPENDENT is destroyed BEFORE the state it depends
  ## on: forward topological order by the persisted `dependsOn` edges, then
  ## REVERSED. Edges to addresses OUTSIDE this reap set are ignored (a group
  ## may be reaped without its never-reap network). A cycle is impossible in
  ## a well-formed graph; if one is present we fall back to input order for
  ## that node rather than raising (a reap must never wedge on a corrupt
  ## edge — crash-safety over strictness).
  var byAddr = initTable[string, ResourceStateRecord]()
  for rec in records:
    byAddr[rec.address] = rec

  var forward: seq[ResourceStateRecord] = @[]
  var visited = initHashSet[string]()
  var onStack = initHashSet[string]()

  proc visit(addrKey: string) =
    if addrKey in visited: return
    if addrKey in onStack: return       # cycle guard: don't recurse again
    onStack.incl(addrKey)
    let rec = byAddr[addrKey]
    var deps = rec.dependsOn
    deps.sort()
    for dep in deps:
      if byAddr.hasKey(dep):            # only order WITHIN the reap set
        visit(dep)
    onStack.excl(addrKey)
    visited.incl(addrKey)
    forward.add(rec)

  # Stable outer order (records as given, sorted by address for determinism).
  var addrs: seq[string] = @[]
  for rec in records: addrs.add(rec.address)
  addrs.sort()
  for a in addrs:
    visit(a)

  # forward = deps-first (network, container, nic). Destroy is the reverse.
  result = @[]
  for i in countdown(forward.len - 1, 0):
    result.add(forward[i])

# ---------------------------------------------------------------------------
# Per-record destroy over the selected transport.
# ---------------------------------------------------------------------------

proc observeVia(transport: ReapTransport; inst: ResourceInstance;
                prior: Option[ResourceBinding]): ObservedState =
  if transport.kind == rtInProcess or routesInProcess(transport, inst.typeId):
    let drv = lookupResourceProvider(inst.typeId).driver
    drv.observe(inst, prior)
  else:
    let handle = transport.resolve(inst.typeId)
    observeViaSession(handle, inst, prior)

proc destroyVia(transport: ReapTransport; inst: ResourceInstance;
                observed: ObservedState): ResourceBinding =
  if transport.kind == rtInProcess or routesInProcess(transport, inst.typeId):
    let drv = lookupResourceProvider(inst.typeId).driver
    drv.apply(inst, rakDestroy, observed)
  else:
    let handle = transport.resolve(inst.typeId)
    applyViaSession(handle, inst, rakDestroy, observed)

proc reconstructFor(transport: ReapTransport;
                    rec: ResourceStateRecord): ResourceInstance =
  ## Rebuild the record's instance under the attrs contract THIS transport
  ## actually imposes. The two arms want opposite things and conflating them
  ## is the defect this seam fixes:
  ##
  ##   * `rtInProcess` dispatches to a LINKED `ResourceProviderDriver`, which
  ##     dereferences the typed value (`TypedExtensionBox[T](inst.attrs).val`).
  ##     A box it cannot read is unusable, so the strict path is correct here:
  ##     a missing codec must be a diagnosable `KeyError` at the seam, not an
  ##     opaque box handed to a driver that will cast it to the wrong type.
  ##   * `rtSession` MARSHALS the box straight back out to a provider process
  ##     that does link the codec (`observeViaSession` / `applyViaSession`).
  ##     This process never reads the value, so requiring it to be able to was
  ##     a requirement with no consumer. `reconstructInstanceOpaque` boxes the
  ##     persisted bytes verbatim, and `marshalAttrs` sends those same bytes
  ##     on.
  ##
  ## What the session arm's change does and does not fix: it lets a daemon that
  ## HAS a provider artifact for a type but not that provider's attrs codec
  ## reap over the session — the configuration §4.2 describes. It does not give
  ## any process a route to a type it cannot reach at all; see the module
  ## header for why the measured outage was the latter and not this.
  ##
  ## The decision follows the TRANSPORT THIS RECORD WILL ACTUALLY USE, not the
  ## transport's kind: on a hybrid session transport a type the `inProcess` gate
  ## claims is destroyed by a linked driver, and so wants the strict
  ## reconstruction. `routesInProcess` is the single predicate all three
  ## dispatchers share, so the reconstruction and the op can never disagree.
  if transport.kind == rtInProcess or routesInProcess(transport, rec.typeId):
    reconstructInstance(rec)
  else:
    reconstructInstanceOpaque(rec)

proc reapRecord*(store: StateStore; transport: ReapTransport;
                 rec: ResourceStateRecord): ReapEvent =
  ## Destroy ONE record's real-world state and remove its store record.
  ##
  ## Crash-safe + idempotent: reconstruct the instance from the persisted
  ## attrs (no graph), `observe` — if the world already reports it ABSENT
  ## (a prior crashed run destroyed it, or it never fully materialized), the
  ## destroy is skipped and the record is STILL removed (a clean no-op). If
  ## present, `apply(rakDestroy)` tears it down. Either way the record is
  ## removed only after the op, so a crash mid-destroy leaves the record for
  ## the next sweep to resume.
  ##
  ## The reconstruction is transport-dependent — see `reconstructFor`. An
  ## in-process reap needs this process to hold the attrs codec; a session
  ## reap does not, because the payload is forwarded to the provider.
  let inst = reconstructFor(transport, rec)
  let observed = observeVia(transport, inst, none(ResourceBinding))
  var wasPresent = false
  if observed.present:
    wasPresent = true
    discard destroyVia(transport, inst, observed)
  removeStateRecord(store, rec.address)
  ReapEvent(address: rec.address, typeId: rec.typeId, wasPresent: wasPresent)

proc reapFailureReason(transport: ReapTransport; store: StateStore;
                       rec: ResourceStateRecord; raised: string): string =
  ## The `reason` a failed per-record reap is RECORDED under: the raised
  ## message, plus — for the one cause whose own advice does not apply to the
  ## process that hits it — what the operator of THAT process can do.
  ##
  ## `unmarshalAttrs`'s message tells the reader to "import the producer's
  ## lifted interface". That is the right instruction for a consumer recipe
  ## and the wrong one for the repro daemon: the daemon is a fixed binary, it
  ## has no recipe to add an import to, and nothing an operator types will put
  ## an out-of-tree provider's interface into its closure. Repeating it there
  ## is how a failure stays unfixed while nominally carrying a remedy — the
  ## live daemon logged exactly that sentence 131,882 times
  ## (reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md).
  ##
  ## So when an IN-PROCESS reap failed and the codec is genuinely absent, the
  ## reason names the two things that could work instead: destroy over a
  ## provider session (the §4.2 transport, which needs no codec in the reaping
  ## process), or run the sweep from a process that links the type. The raised
  ## text is kept verbatim ahead of it — it identifies the typeId, and a
  ## diagnosis that edits away the original message makes the next reader's
  ## grep fail.
  ##
  ## THE FIRST SUGGESTION IS NOW REACHABLE, and the text says how. It used to
  ## end "registering a provider artifact needs a code path that does it, and
  ## the shipped tree has none" — true when it was written and false now: a
  ## reconcile that materializes a resource over a provider session records the
  ## artifact IN THE RECORD (`ResourceStateRecord.providerArtifact`, v5), and a
  ## consuming `repro run` also registers it with the running daemon, so a
  ## record written by current code carries its own route. A record reaching
  ## this diagnosis therefore either predates v5, or was materialized
  ## in-process by a build that linked the type and is now being swept by one
  ## that does not — and re-materializing it over the session path is what
  ## gives it a route.
  ##
  ## A RECORD CAN STILL HAVE NO ROUTE AT ALL, which is why the text stays
  ## worded as options rather than instructions: a pre-v5 record names no
  ## artifact, and a build that links the type may not exist either. Such a
  ## record is permanently unreapable HERE, which is a true fact about this
  ## process and not a reaper defect — and it is exactly what the
  ## `lease-reaper` health finding exists to surface rather than hide.
  ##
  ## TWO STATES, TWO REMEDIES, and conflating them hands the operator advice
  ## that cannot work. A record with NO ref needs a run that records one. A
  ## record whose ref is PRESENT but not launchable — a relative `binaryPath`,
  ## which `isLaunchableArtifact` drops so the sweep never resolves `PATH`
  ## against it — would be told "the record names no provider artifact" (false)
  ## and "re-materialize it, which records the artifact" (useless: the same
  ## relative path would be recorded again). The second state names the
  ## recorded path and the requirement it fails, because that is the only thing
  ## the operator can act on.
  result = raised
  # The gate is "did THIS RECORD go in-process", not "is the transport
  # in-process", and the difference is now reachable: a hybrid session
  # transport routes a type it has no artifact for through the linked driver,
  # and those are precisely the records that hit the missing-codec failure.
  # Asking `transport.kind` would have silently dropped the diagnosis for every
  # one of them — the whole population this remedy was written for — on exactly
  # the transport the production feeders select.
  if (transport.kind == rtInProcess or
      routesInProcess(transport, rec.typeId)) and
      not isAttrsMarshallerRegistered(rec.attrsTypeId):
    # Deliberately NOT phrased with the words the finding's own verb uses:
    # `leaseReapFindings` renders an `rfkUnreapable` line as "cannot reap
    # address=…", and a reason that repeated that phrase would make a
    # substring count of it read 2 for one report. t_l4_daemon_leases case (e)
    # counts exactly that, and caught this.
    # The suggested command CARRIES THE STORE ROOT. Without it the sweep it
    # names addresses the per-user default, which for any other root is a
    # different store — so a copy-pasted remedy would report "no record for
    # that address" and read as "the problem went away".
    let byHand = "run the sweep from a process that links the type: " &
      "`repro reap --once --state-root=" & store.root & " " &
      rec.address & "` from such a build. " &
      "The record is LEFT IN THE STORE for whichever comes first."
    let sessionNote = "the Ephemeral-State-Leases §4.2 transport, which " &
      "needs no attrs codec in the reaping process"
    result.add(" — this process has no way to destroy '" & rec.address &
      "' in-process, and ")
    # THREE STATES, and each gets only the advice that is true of it. The
    # "names no provider artifact" sentence is reachable ONLY when that is
    # literally so: it used to be the `else`, which caught a record with a
    # perfectly good ref whenever the caller had PINNED the in-process
    # transport (`reapOnce(store, now)` with no transport does exactly that),
    # and told its operator to re-materialize a record that already carries
    # the route it needs.
    if rec.providerArtifact.isNone:
      result.add("the record names no provider artifact to destroy it over a " &
        "session with (" & sessionNote & "). Either re-materialize '" &
        rec.address & "' through a run that reconciles its type over a " &
        "provider session, which records the artifact in the record, or " &
        byHand)
    elif not isLaunchableArtifact(rec.providerArtifact.get):
      # The ref is THERE and was dropped for being unusable. Saying "no
      # artifact" here would be false, and "re-materialize to record one"
      # would record the same unusable value again. Name the field that fails
      # and the requirement it fails, because that is what the PRODUCER has to
      # change.
      let a = rec.providerArtifact.get
      result.add("the provider artifact it names cannot be launched: ")
      if a.binaryPath.len == 0 or not isAbsolute(a.binaryPath):
        result.add("binaryPath '" & a.binaryPath &
          "' is not an absolute path, and a reap session is launched with " &
          "the path as given (a relative name would resolve through this " &
          "process's own PATH rather than naming the provider build)")
      else:
        result.add("providerArtifactId is empty, and it is the " &
          "provider-session POOL KEY — an empty one would alias this " &
          "provider with any other empty-id artifact into a single session")
      result.add(", so it is not used as a route (" & sessionNote &
        "). Either re-record '" & rec.address &
        "' with a launchable provider artifact — the producer that wrote " &
        "this record is what has to change — or " & byHand)
    else:
      # A LAUNCHABLE ref that this sweep did not use: the caller pinned the
      # in-process transport, so the route in the record was never consulted.
      # Nothing is wrong with the record, and nothing about it needs changing —
      # the remedy is to sweep in a way that uses it.
      result.add("this sweep did not use the provider artifact the record " &
        "names (binaryPath '" & rec.providerArtifact.get.binaryPath &
        "'), because it ran on the in-process transport: the caller pinned " &
        "one rather than letting the sweep resolve a route per record (" &
        sessionNote & "). Re-run the sweep without pinning a transport — " &
        "`repro reap --once --state-root=" & store.root & " " &
        rec.address & "` resolves the record's own artifact — or " & byHand)

# ---------------------------------------------------------------------------
# The sweep — the seam the CLI (`repro reap`), the reconcile hook, and the
# L4 daemon timer all call.
# ---------------------------------------------------------------------------

proc reapOnce*(store: StateStore; now: Time = getTime();
               transport: ReapTransport = inProcessTransport();
               force = false; onlyAddresses: seq[string] = @[];
               transportFromRecords: ReapTransportFromRecords = nil):
    ReapReport =
  ## One sweep over the whole store (the L3 core). Reads every record,
  ## selects the reapable set (§4.2 predicate — `none` never reaps, a live
  ## holder keeps, `force` reaps every present record), destroys them in
  ## REVERSE topo order over `transport`, and removes each on success.
  ##
  ## `onlyAddresses` (non-empty) restricts the sweep to those addresses —
  ## the force-reap-a-specific-group path (`--hard-rebuild <target>`); an
  ## empty seq sweeps everything.
  ##
  ## Idempotent: a second call finds the removed records gone and no-ops.
  ## Crash-safe: it relies ONLY on the store, so a partially-reaped group
  ## from a crashed prior run resumes (present records reaped, removed ones
  ## simply absent).
  ##
  ## ONE UNHANDLEABLE RECORD MUST NOT ABORT THE SWEEP. `reapRecord` can raise
  ## for reasons that are properties of ONE record and of this process, not of
  ## the store: on the IN-PROCESS arm only, no attrs marshaller registered for
  ## its `attrsTypeId` (`reconstructInstance`) and no in-process driver for its
  ## `typeId` (`lookupResourceProvider`); on either arm, a provider session
  ## that will not launch, or a real provider whose `observe`/`apply` failed.
  ## (The missing-marshaller cause is in-process-only since `reconstructFor`
  ## gave the session arm the opaque reconstruction — a session reap has no use
  ## for a codec it would only marshal straight back out.)
  ##
  ## Letting any of those unwind the loop means the OTHER records — the ones
  ## this process can perfectly well reap — are never reached, so the sweep
  ## reaps nothing at all and does so again on every subsequent tick, forever.
  ## That is not hypothetical: the daemon's wall-clock tick failed on its first
  ## record (a `vm_harness.nic` with no linked marshaller) on every one of
  ## 141,895 consecutive attempts over 60 days and reaped nothing, ever.
  ##
  ## So each record is attempted independently and a failure is RECORDED in
  ## `failed` rather than raised. The record is left in the store (no
  ## `removeStateRecord` ran), so a later sweep — in a process that does link
  ## the marshaller, or once the provider is reachable — resumes it. This is
  ## the same crash-safety contract `reapRecord` already relies on.
  ##
  ## …WITHOUT breaking reverse-topo. A record that cannot be reaped still
  ## EXISTS, both in the store and (maybe) in the world, so destroying what it
  ## `dependsOn` would tear a dependency out from under a live dependent —
  ## exactly what the reverse-topo order exists to prevent — and
  ## `removeStateRecord` would leave the surviving record's `dependsOn`
  ## dangling at an address that no longer has a record. Every record the
  ## failed one depends on (transitively, within this reap set) is therefore
  ## HELD as `rfkBlocked` and left alone. Because the iteration order is
  ## reverse-topo, a record's dependencies always come AFTER it, so marking
  ## forward in one pass is sufficient.
  ##
  ## …AND ONE UNDECODABLE RECORD MUST NOT ABORT IT EITHER. The listing is
  ## `scanStateRecords`, which never raises per record: a newer repro's record
  ## comes back as `foreign` (never reaped — it is not ours to interpret), a
  ## corrupt one is quarantined, and both are carried into the report.
  ##
  ## `transportFromRecords` (non-nil) CHOOSES the transport from the artifacts
  ## the swept records themselves carry (Ephemeral-State-Leases.md §4.2, the
  ## durable half of the provider-artifact resolution), overriding `transport`.
  ## It is applied to THIS sweep's own `scanStateRecords` result, which is the
  ## reason the hook exists rather than the caller scanning first and passing a
  ## ready transport: `scanStateRecords` QUARANTINES a corrupt record as a side
  ## effect, so a preparatory scan would move a record aside in a pass whose
  ## report nobody reads — the finding §4.4 requires would be lost, and only the
  ## second scan's silence would remain. One scan, one report, transport chosen
  ## from it.
  result.reaped = @[]
  result.skipped = @[]
  result.failed = @[]

  let scan = scanStateRecords(store)
  result.foreign = scan.foreign
  result.quarantined = scan.quarantined
  result.unreadable = scan.unreadable
  let effectiveTransport =
    if transportFromRecords != nil:
      transportFromRecords(providerArtifactsOfRecords(scan.records))
    else:
      transport
  var all = scan.records
  if onlyAddresses.len > 0:
    var wanted = initHashSet[string]()
    for a in onlyAddresses: wanted.incl(a)
    all = all.filterIt(it.address in wanted)

  let selected = selectReapable(all, now, force)
  var selectedAddrs = initHashSet[string]()
  for rec in selected: selectedAddrs.incl(rec.address)
  for rec in all:
    if rec.address notin selectedAddrs:
      result.skipped.add(rec.address)

  let ordered = reverseTopoOrder(selected)
  # Held-back records and, for each, the unreapable dependent responsible —
  # so the report names the blast radius rather than just its size.
  var blockedBy = initTable[string, string]()

  proc holdDependencies(rec: ResourceStateRecord; culprit: string) =
    for dep in rec.dependsOn:
      if dep in selectedAddrs and dep notin blockedBy:
        blockedBy[dep] = culprit

  for rec in ordered:
    if rec.address in blockedBy:
      result.failed.add(ReapFailure(
        address: rec.address, typeId: rec.typeId, kind: rfkBlocked,
        reason: "held: '" & blockedBy[rec.address] &
          "' depends on it and could not be reaped"))
      # Propagate the hold down the dependency chain, crediting the record
      # that actually failed rather than this intermediate one.
      holdDependencies(rec, blockedBy[rec.address])
      continue
    try:
      result.reaped.add(reapRecord(store, effectiveTransport, rec))
    except CatchableError as err:
      result.failed.add(ReapFailure(
        address: rec.address, typeId: rec.typeId, kind: rfkUnreapable,
        reason: reapFailureReason(effectiveTransport, store, rec, err.msg)))
      holdDependencies(rec, rec.address)

# ---------------------------------------------------------------------------
# Reconcile-start opportunistic hook (§4.3 fallback (a)).
# ---------------------------------------------------------------------------

proc reapExpiredAtReconcileStart*(store: StateStore; now: Time = getTime();
                                  transport: ReapTransport = inProcessTransport();
                                  transportFromRecords:
                                    ReapTransportFromRecords = nil):
    ReapReport =
  ## The opportunistic reap hook a `reconcileResources` run calls at START,
  ## BEFORE materializing, so a run that consumes a leased state first clears
  ## any records whose lease already lapsed (cheap + bounded — one store
  ## scan, `force = false`). This is fallback (a) of §4.3: the store enforces
  ## the lease even with NO daemon running. `force` is never set here (a
  ## reconcile must not reap a still-leased state out from under itself); the
  ## `repro reap --force` path is a distinct, explicit call.
  ##
  ## `transportFromRecords` is forwarded so this sweep reaches an out-of-tree
  ## record over the provider session its own record names — the production
  ## caller (`reconcileConsumedStateGroups`) passes `reapTransportFactory` over
  ## the run-edge's harvested artifacts, so fallback (a) has the same reach the
  ## daemon tick does rather than being a weaker sweep that reports what it
  ## cannot touch.
  reapOnce(store, now, transport, force = false,
           transportFromRecords = transportFromRecords)

# ---------------------------------------------------------------------------
# The `repro reap` CLI seam (§4.3 fallback (b)) — a proc the CLI subcommand
# AND the L4 daemon timer both call. The top-level `repro reap` dispatch in
# `repro_cli_support`'s `runThinAppDispatch` now routes here (it did not when
# this banner was written, which is what the stale "is the L4 integration
# point" phrasing referred to); this proc is the
# self-contained entry it (and the daemon) invoke.
# ---------------------------------------------------------------------------

proc defaultUserStateStoreRoot*(): string =
  ## The per-user state-store directory (§4.1): `$HOME/.cache/repro/state`.
  ## The L4 system daemon supplies a system-scoped root instead.
  getHomeDir() / ".cache" / "repro" / "state"

proc runReapCli*(args: seq[string];
                 storeRootOverride = "";
                 now: Time = getTime();
                 transport = none(ReapTransport);
                 echoLine: proc (line: string) {.closure.} = nil): int =
  ## The `repro reap [--once] [--force] [--state-root=PATH] [address...]`
  ## entry. Returns a process exit code. `--once` is accepted (and is the
  ## only mode here — a single sweep; the daemon-hosted repeated schedule is
  ## L4). `--force` selects every present record regardless of lease. Bare
  ## address args restrict the sweep to a group.
  ##
  ## Pure w.r.t. output: `echoLine` (default: `echo`) receives each report
  ## line, so a test can capture output without a process.
  ##
  ## TRANSPORT (§4.3 fallback (b)). With no explicit `transport`, the sweep
  ## resolves each record's destroy route from the record itself: a record that
  ## names a provider artifact is destroyed over a session to that provider, and
  ## everything else in-process. That is what makes the by-hand sweep able to
  ## reap an out-of-tree type at all — the operator the §4.5 finding sends here
  ## otherwise needs "a build that links the type", which for an Incus driver
  ## does not exist. A store with no such record launches nothing, so the
  ## in-process behaviour is unchanged where there is no artifact to use.
  ## A caller that passes `some(transport)` pins it and no session is opened.
  ##
  ## ## Why `--hard-rebuild` and `--rebuild-host-bound` are NOT accepted here
  ##
  ## They used to be, as bare aliases of `--force`. They were removed when
  ## `Edge-Determinism-And-Soft-Rebuild.md` §4.2/§4.3 claimed both spellings
  ## for `repro build`, where they mean something ELSE: which determinism
  ## classes to invalidate in the ACTION CACHE. Here they meant "ignore an
  ## unexpired lease and destroy the state anyway" — a destructive operation
  ## on live infrastructure, not a cache invalidation.
  ##
  ## One spelling, two verbs, two meanings, one of them destructive is not a
  ## collision worth documenting around. The resolution is to give the
  ## spellings to `repro build` (where the spec defines them) and leave this
  ## verb with `--force`, which is what it always did and what its own
  ## semantics actually describe. Three facts made removal the cheap
  ## direction rather than the expensive one:
  ##
  ##   1. The spellings belong to `repro build`, which is where the spec
  ##      defines them. This verb has no claim on them.
  ##
  ##      This reason used to read "nothing dispatches `repro reap` yet …  no
  ##      operator can have typed either spelling". That is no longer true:
  ##      there IS a `"reap"` arm in `runThinAppDispatch`, so both spellings
  ##      are now operator-reachable. The change strengthens the refusal
  ##      rather than weakening it, and it is why the refusal is spelled out
  ##      explicitly instead of falling through the generic unknown-flag arm —
  ##      an operator who reaches for a `repro build` spelling here is told
  ##      where the verb went rather than getting a bare exit 2. (The verb is
  ##      absent from the usage text, as the equally-dispatched `health` and
  ##      `gateway` are: `renderUsage` lists none of the three, so that is the
  ##      house convention and not an oversight here.)
  ##   2. Nothing has ever exercised `force` through either flag STRING. The
  ##      library's own test drives it as `reapOnce(force = true)`, and the
  ##      dispatcher simply forwards argv, so removing the aliases changed no
  ##      behaviour anybody depended on — it only changed what a typo gets
  ##      told. (`t_l3_reaper` case (10) now pins the refusal itself, and
  ##      `t_repro_reap_verb_is_dispatched` pins that the verb is reachable.)
  ##   3. Keeping them as aliases would have made
  ##      `repro reap --rebuild-host-bound` and
  ##      `repro build --rebuild-host-bound` do unrelated things, one of
  ##      which deletes a VM.
  ##
  ## Both are refused EXPLICITLY rather than falling through the generic
  ## unknown-flag arm, so an operator who reaches for one is told where the
  ## verb went instead of getting a bare exit 2.
  var force = false
  var storeRoot = storeRootOverride
  var targets: seq[string] = @[]
  # Resolved BEFORE the parse loop, not after it, because the two refusals
  # below report through it and they happen during parsing.
  let emit = if echoLine != nil: echoLine
             else: (proc (line: string) = echo line)
  for raw in args:
    if raw == "--once":
      discard                    # single sweep is the only mode here (L4 = repeat)
    elif raw == "--force":
      force = true
    elif raw == "--hard-rebuild" or raw == "--rebuild-host-bound":
      emit("repro reap: " & raw & " is a `repro build` verb (it selects " &
        "which determinism classes to invalidate in the action cache). To " &
        "reap a still-leased state, use `repro reap --force`.")
      return 2
    elif raw.startsWith("--state-root="):
      storeRoot = raw[len("--state-root=") .. ^1]
    elif raw.startsWith("--"):
      return 2                   # unknown flag
    else:
      targets.add(raw)

  let root = if storeRoot.len > 0: storeRoot else: defaultUserStateStoreRoot()

  if not dirExists(root):
    emit("repro reap: no state store at " & root & " (nothing to reap)")
    return 0

  let store = openStateStore(root)
  # The pool is OWNED by this sweep and closed before we return, including on a
  # failure: `repro reap` is a one-shot command, so leaving a launched provider
  # child behind would leak a process per invocation. It stays empty unless some
  # record actually names an artifact.
  var pool: ProviderSessionPool = nil
  defer:
    if pool != nil:
      try: pool.closeAll() except CatchableError: discard
  let fromRecords =
    if transport.isSome:
      nil                            # pinned by the caller — open nothing
    else:
      reapTransportFactory(@[], proc (artifact: ResourceProviderArtifactRef):
          ProviderHandle =
        if pool == nil:
          pool = newProviderSessionPool()
        pool.openProviderSession(ProviderArtifactRef(
            binaryPath: artifact.binaryPath,
            providerArtifactId: artifact.providerArtifactId,
            workingDir: artifact.workingDir),
          defaultSessionPolicy(), reapEngineHello()))
  let report = reapOnce(store, now,
                        if transport.isSome: transport.get
                        else: inProcessTransport(),
                        force = force, onlyAddresses = targets,
                        transportFromRecords = fromRecords)
  emit("repro reap: state-root=" & root &
       (if force: " (force)" else: ""))
  emit("reaped: " & $report.reaped.len)
  for ev in report.reaped:
    emit("  - " & ev.address & " (" & ev.typeId & ")" &
         (if ev.wasPresent: "" else: " [already-absent]"))
  emit("kept: " & $report.skipped.len)
  # A newer repro's record is healthy, just not ours: said so (an operator
  # would otherwise wonder why it never goes), but it does not fail the verb.
  if report.foreign.len > 0:
    emit("foreign: " & $report.foreign.len)
    for f in report.foreign:
      emit("  - " & f.path & " (written by a newer repro, version " &
           $f.version & "; left untouched)")
  # Corrupt state was found. The sweep moved it aside and carried on, but the
  # resource that record described may now be leaked with nothing holding its
  # address, so an operator has to look: exit non-zero, name the evidence.
  if report.quarantined.len > 0:
    emit("quarantined: " & $report.quarantined.len)
    for q in report.quarantined:
      emit("  - " & q.path & " -> " & q.quarantinePath & ": " & q.reason)
  if report.unreadable.len > 0:
    emit("unreadable: " & $report.unreadable.len)
    for u in report.unreadable:
      emit("  - " & u.path & ": " & u.reason)
  # A selected record the sweep could NOT reap is reported, never swallowed:
  # dropping it here would reproduce, at the CLI, the same invisibility that
  # let the daemon's tick fail for 60 days unnoticed. It is also why the exit
  # code is non-zero — `repro reap` was asked to destroy this state and did
  # not, and an operator (or CI) scripting the verb has to be able to tell.
  if report.failed.len > 0:
    emit("unreapable: " & $report.failed.len)
    for f in report.failed:
      emit("  - " & f.address & " (" & f.typeId & ") " & f.reason)
  if report.failed.len > 0 or report.quarantined.len > 0 or
      report.unreadable.len > 0:
    return 1
  0
