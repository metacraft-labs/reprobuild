## L3 (Ephemeral-State-Leases.md §4): the crash-safe reaper.
##
## The reaper destroys IDLE leased state. It works ENTIRELY from the L1
## on-disk state store — never from an in-memory desired graph — so it is
## correct after a crash, across a fresh process, and without a running
## daemon (§4.3). Its inputs are a `StateStore` and a `now`; its effect is:
## reconstruct each reapable `ResourceInstance` from the persisted attrs
## (L1 `reconstructInstance`), `observe` it, `apply(rakDestroy)`, and
## `removeStateRecord` on success.
##
## The SELECTION PREDICATE (the L2 reap-safety property, verified here):
##
##   * `effectiveDeadline == none`  -> NEVER reap. `none` means "no dated
##     holder / a `keep` holder pins it": there is NO reap deadline. This
##     is deliberately an `Option`, not an epoch-0/PAST sentinel — a PAST
##     sentinel would make the natural `deadline < now` gate destroy a
##     pinned state. A `none` record is unconditionally skipped.
##   * `effectiveDeadline == some(t)` with `t <= now` AND no LIVE holder ->
##     reap. A holder is LIVE if its own deadline is still in the future
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

  ReapEvent* = object
    ## One reaped record, in the order it was destroyed — the witness a
    ## test asserts against (reverse-topo order, idempotency).
    address*: string
    typeId*: string
    wasPresent*: bool   ## true if `observe` saw it live (a real destroy);
                        ## false = already-absent clean no-op (record still removed)

  ReapReport* = object
    ## The outcome of a sweep.
    reaped*: seq[ReapEvent]        ## destroyed (or already-absent) records removed, in order
    skipped*: seq[string]          ## addresses inspected but kept (still leased / never-reap)

proc inProcessTransport*(): ReapTransport =
  ReapTransport(kind: rtInProcess)

proc sessionTransport*(resolve: proc (typeId: string): ProviderHandle {.closure.}):
    ReapTransport =
  ReapTransport(kind: rtSession, resolve: resolve)

# ---------------------------------------------------------------------------
# Selection predicate.
# ---------------------------------------------------------------------------

proc hasLiveHolder*(rec: ResourceStateRecord; now: Time): bool =
  ## A holder is LIVE if its own recorded deadline is still in the future.
  ## A live holder keeps the state regardless of the folded
  ## `effectiveDeadline`.
  for _, deadline in rec.holders:
    if deadline > now:
      return true
  false

proc isReapable*(rec: ResourceStateRecord; now: Time; force = false): bool =
  ## The L3 reap gate.
  ##
  ##   * `force`                     -> reap iff the record is still present
  ##     (ignore deadline + holder liveness — the `--hard-rebuild` path).
  ##   * `effectiveDeadline.isNone`  -> NEVER reap (keep / no dated holder).
  ##   * a live holder (`holders[c] > now`) -> NEVER reap (still in use).
  ##   * otherwise reap iff `effectiveDeadline.get <= now`.
  if force:
    return rec.present
  if rec.effectiveDeadline.isNone:
    return false                       # never-reap: keep dominates
  if hasLiveHolder(rec, now):
    return false                       # a live holder keeps it
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
  case transport.kind
  of rtInProcess:
    let drv = lookupResourceProvider(inst.typeId).driver
    drv.observe(inst, prior)
  of rtSession:
    let handle = transport.resolve(inst.typeId)
    observeViaSession(handle, inst, prior)

proc destroyVia(transport: ReapTransport; inst: ResourceInstance;
                observed: ObservedState): ResourceBinding =
  case transport.kind
  of rtInProcess:
    let drv = lookupResourceProvider(inst.typeId).driver
    drv.apply(inst, rakDestroy, observed)
  of rtSession:
    let handle = transport.resolve(inst.typeId)
    applyViaSession(handle, inst, rakDestroy, observed)

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
  let inst = reconstructInstance(rec)
  let observed = observeVia(transport, inst, none(ResourceBinding))
  var wasPresent = false
  if observed.present:
    wasPresent = true
    discard destroyVia(transport, inst, observed)
  removeStateRecord(store, rec.address)
  ReapEvent(address: rec.address, typeId: rec.typeId, wasPresent: wasPresent)

# ---------------------------------------------------------------------------
# The sweep — the seam the CLI (`repro reap`), the reconcile hook, and the
# L4 daemon timer all call.
# ---------------------------------------------------------------------------

proc reapOnce*(store: StateStore; now: Time = getTime();
               transport: ReapTransport = inProcessTransport();
               force = false; onlyAddresses: seq[string] = @[]): ReapReport =
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
  result.reaped = @[]
  result.skipped = @[]

  var all = listStateRecords(store)
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

  for rec in reverseTopoOrder(selected):
    result.reaped.add(reapRecord(store, transport, rec))

# ---------------------------------------------------------------------------
# Reconcile-start opportunistic hook (§4.3 fallback (a)).
# ---------------------------------------------------------------------------

proc reapExpiredAtReconcileStart*(store: StateStore; now: Time = getTime();
                                  transport: ReapTransport = inProcessTransport()):
    ReapReport =
  ## The opportunistic reap hook a `reconcileResources` run calls at START,
  ## BEFORE materializing, so a run that consumes a leased state first clears
  ## any records whose lease already lapsed (cheap + bounded — one store
  ## scan, `force = false`). This is fallback (a) of §4.3: the store enforces
  ## the lease even with NO daemon running. `force` is never set here (a
  ## reconcile must not reap a still-leased state out from under itself); the
  ## `--hard-rebuild` force path is a distinct, explicit call.
  reapOnce(store, now, transport, force = false)

# ---------------------------------------------------------------------------
# The `repro reap` CLI seam (§4.3 fallback (b)) — a proc the CLI subcommand
# AND the L4 daemon timer both call. Full top-level `repro reap` dispatch
# wiring in `repro_cli_support` is the L4 integration point; this proc is the
# self-contained entry it (and the daemon) invoke.
# ---------------------------------------------------------------------------

proc defaultUserStateStoreRoot*(): string =
  ## The per-user state-store directory (§4.1): `$HOME/.cache/repro/state`.
  ## The L4 system daemon supplies a system-scoped root instead.
  getHomeDir() / ".cache" / "repro" / "state"

proc runReapCli*(args: seq[string];
                 storeRootOverride = "";
                 now: Time = getTime();
                 transport: ReapTransport = inProcessTransport();
                 echoLine: proc (line: string) {.closure.} = nil): int =
  ## The `repro reap [--once] [--force] [--state-root=PATH] [address...]`
  ## entry. Returns a process exit code. `--once` is accepted (and is the
  ## only mode here — a single sweep; the daemon-hosted repeated schedule is
  ## L4). `--force` selects every present record regardless of lease
  ## (`--hard-rebuild`). Bare address args restrict the sweep to a group.
  ##
  ## Pure w.r.t. output: `echoLine` (default: `echo`) receives each report
  ## line, so a test can capture output without a process.
  var force = false
  var storeRoot = storeRootOverride
  var targets: seq[string] = @[]
  for raw in args:
    if raw == "--once":
      discard                    # single sweep is the only mode here (L4 = repeat)
    elif raw == "--force" or raw == "--hard-rebuild" or raw == "--rebuild-host-bound":
      force = true
    elif raw.startsWith("--state-root="):
      storeRoot = raw[len("--state-root=") .. ^1]
    elif raw.startsWith("--"):
      return 2                   # unknown flag
    else:
      targets.add(raw)

  let root = if storeRoot.len > 0: storeRoot else: defaultUserStateStoreRoot()
  let emit = if echoLine != nil: echoLine else: (proc (line: string) = echo line)

  if not dirExists(root):
    emit("repro reap: no state store at " & root & " (nothing to reap)")
    return 0

  let store = openStateStore(root)
  let report = reapOnce(store, now, transport, force = force,
                        onlyAddresses = targets)
  emit("repro reap: state-root=" & root &
       (if force: " (force)" else: ""))
  emit("reaped: " & $report.reaped.len)
  for ev in report.reaped:
    emit("  - " & ev.address & " (" & ev.typeId & ")" &
         (if ev.wasPresent: "" else: " [already-absent]"))
  emit("kept: " & $report.skipped.len)
  0
