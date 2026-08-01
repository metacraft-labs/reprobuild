## Ephemeral-State-Leases L4 (§4): the daemon-hosted lease registry + the
## wall-clock reaper tick.
##
## This is the ONE module in ``repro_daemon_core`` that links
## ``repro_resources`` (the L1 state store, the L2 lease policy, and the L3
## reaper). ``protocol.nim`` stays a leaf (only ``repro_core``); the wire
## ``ttlSeconds`` encoding it carries is translated to/from a
## ``repro_resources`` ``LeasePolicy`` HERE, so the frame codec never
## depends on the resource lane.
##
## What it provides:
##
##   * ``leaseStoreRootForScope`` — the §4.1 scope routing: ``dlsUser`` ->
##     ``$HOME/.cache/repro/state`` (the L3 ``defaultUserStateStoreRoot``),
##     ``dlsSystem`` -> the system state dir (``/var/lib/repro/state`` or
##     ``$REPRO_SYSTEM_STATE_DIR``). A test throwaway root overrides both.
##   * ``applyLeaseRenew`` — the ``udkLeaseRenew`` handler body: load the
##     record for the address, set ``holders[consumerId] =
##     deadlineFrom(policy, now)`` (the L2 renewal primitive), recompute the
##     reference-counted MAX ``effectiveDeadline`` (keep dominates ->
##     ``none``), and persist atomically (L1 ``writeStateRecord``). Absent
##     record => a best-effort no-op (``hadRecord == false``); the client
##     must not treat that as fatal (the no-daemon path already wrote the
##     record via the reconcile's in-process store, and a daemon that simply
##     has not yet seen a materialization must not wedge a reconcile).
##   * ``runLeaseReapTick`` — the wall-clock timer tick: run the L3
##     ``reapExpiredAtReconcileStart`` against the scoped store. The daemon
##     event loop calls this on a bounded cadence; it is a plain store sweep,
##     so it SURVIVES a daemon restart by construction (the store is on disk).

import std/[os, options, times, tables, strutils]

import repro_resources                    # state store + lease + reaper (L1-L3)
import repro_provider_runtime             # ProviderSessionPool / openProviderSession
                                          # (the RP session machinery the reaper's
                                          # rtSession transport dispatches over)

import ./protocol
import ./client                            # renewLeaseBestEffort (the consume-site
                                          # renew forward — no-daemon-safe)

const
  DefaultLeaseReapIntervalMs* = 30_000
    ## §4.2 "reap on a wall-clock tick" default cadence: sweep the scoped
    ## store for lapsed leases every 30 s even with no client traffic.
    ## Overridable via ``REPRO_DAEMON_LEASE_REAP_INTERVAL_MS`` (a test drives
    ## it far lower). ``<= 0`` disables the tick.

proc leaseReapIntervalMs*(): int =
  ## The reap-tick cadence, honouring the env override. ``0`` disables the
  ## tick entirely (a test that drives the reaper by hand sets this).
  let raw = getEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "")
  if raw.len == 0:
    return DefaultLeaseReapIntervalMs
  try:
    max(0, parseInt(raw))
  except ValueError:
    DefaultLeaseReapIntervalMs

# ---------------------------------------------------------------------------
# L5 deferral (i): the daemon's SESSION reap transport.
#
# The L3 reaper already accepts a caller-injected ``ReapTransport``; its
# ``rtSession`` variant dispatches ``observe``/``apply(rakDestroy)`` over the
# RP provider-session protocol (``observeViaSession``/``applyViaSession``)
# against a launched OUT-OF-TREE provider — so the daemon can tear down
# vm-harness's Incus resources WITHOUT linking their drivers.
#
# What was missing (the L4 deferral): the daemon called ``runLeaseReapTick``
# with the DEFAULT ``inProcessTransport()`` — it never opened a provider
# session. Here we add:
#
#   * a per-typeId registry of provider ARTIFACTS (binary path + the RP1
#     content-addressed artifact id + working dir) the daemon may reap over —
#     a plain module global (like the driver registry), so a daemon that must
#     reap an out-of-tree type registers its provider artifact at startup;
#   * a POOLED resolver: one long-lived ``ProviderSessionPool`` shared across
#     reap ticks, so a session per ``ProviderArtifactId`` is launched once and
#     REUSED across ticks (the §4.2 "opens/pools a provider session per
#     typeId just as the engine does" contract) rather than respawned each
#     sweep;
#   * ``buildLeaseReapTransport`` — returns an ``rtSession`` transport when
#     any provider artifact is registered, else the in-process default (the
#     in-closure providers path stays the default for the hermetic L4 tests +
#     in-tree providers).
# ---------------------------------------------------------------------------

type
  LeaseReapProviderArtifact* = object
    ## How the daemon launches the out-of-tree provider that owns a reapable
    ## resource type, mirroring the engine's ``ProviderArtifactRef``.
    binaryPath*: string
    providerArtifactId*: string
    workingDir*: string

var
  leaseReapProviders: Table[string, LeaseReapProviderArtifact]
    ## typeId -> the provider artifact the daemon reaps that type over.
  leaseReapSessionPool: ProviderSessionPool = nil
    ## The daemon-owned pool, lazily created — one session per artifact id,
    ## reused across reap ticks.

proc registerLeaseReapProvider*(typeId: string;
                                artifact: LeaseReapProviderArtifact) =
  ## Register (or replace) the provider artifact the daemon reaps ``typeId``
  ## over. A daemon that must reap vm-harness's ``vm_harness.container`` etc.
  ## registers the compiled provider binary here at startup; the reap tick
  ## then dispatches that type's destroy over a launched session.
  leaseReapProviders[typeId] = artifact

proc clearLeaseReapProviders*() =
  ## Drop every registered provider artifact + close any pooled sessions
  ## (test isolation; also the daemon's shutdown path).
  leaseReapProviders.clear()
  if leaseReapSessionPool != nil:
    try: leaseReapSessionPool.closeAll() except CatchableError: discard
    leaseReapSessionPool = nil

proc hasLeaseReapProviders*(): bool =
  leaseReapProviders.len > 0

proc leaseReapEngineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["ephemeral-state-lease-reaper"],
    lockSliceId: "lease-reaper",
    canonicalExecutionRoot: getCurrentDir())

proc buildLeaseReapTransport*(): ReapTransport =
  ## The transport the daemon reap tick destroys over: an ``rtSession``
  ## resolver backed by the pooled provider sessions when any provider
  ## artifact is registered, else the in-process default.
  if leaseReapProviders.len == 0:
    return inProcessTransport()
  if leaseReapSessionPool == nil:
    leaseReapSessionPool = newProviderSessionPool()
  let pool = leaseReapSessionPool
  let resolve = proc (typeId: string): ProviderHandle =
    if not leaseReapProviders.hasKey(typeId):
      raise newException(ValueError,
        "no lease-reap provider registered for type " & typeId)
    let a = leaseReapProviders[typeId]
    let artifact = ProviderArtifactRef(
      binaryPath: a.binaryPath,
      providerArtifactId: a.providerArtifactId,
      workingDir: a.workingDir)
    pool.openProviderSession(artifact, defaultSessionPolicy(),
      leaseReapEngineHello())
  sessionTransport(resolve)

proc systemLeaseStoreRoot*(): string =
  ## The system-scoped state-store directory (§4.1). Defaults to
  ## ``/var/lib/repro/state`` (the state dir the system reaper unit owns —
  ## see the nixos-modules systemd wiring); ``$REPRO_SYSTEM_STATE_DIR``
  ## overrides it so a hermetic test can point it under ``$HOME``.
  let explicit = getEnv("REPRO_SYSTEM_STATE_DIR", "")
  if explicit.len > 0:
    return explicit / "state"
  when defined(posix):
    "/var/lib/repro/state"
  else:
    getEnv("PROGRAMDATA", getHomeDir()) / "repro" / "state"

proc leaseStoreRootForScope*(scope: DaemonLeaseScope;
                             overrideRoot = ""): string =
  ## §4.1 scope routing: map a lease scope to its state-store root.
  ## ``overrideRoot`` (non-empty) wins for BOTH scopes — a throwaway test
  ## store, or a daemon started with an explicit ``--state-root``.
  if overrideRoot.len > 0:
    return overrideRoot
  case scope
  of dlsUser:   defaultUserStateStoreRoot()   # $HOME/.cache/repro/state (L3)
  of dlsSystem: systemLeaseStoreRoot()

# ---------------------------------------------------------------------------
# Wire policy <-> repro_resources LeasePolicy (the §4.2 translation seam).
# ---------------------------------------------------------------------------

proc policyFromTtlSeconds*(ttlSeconds: int64): LeasePolicy =
  ## Decode the wire ``ttlSeconds`` (see ``protocol.nim``) into a
  ## ``LeasePolicy``: negative -> ``keep``, ``0`` -> ``immediate``,
  ## positive -> ``delayed(ttl)``.
  if ttlSeconds < 0:
    keep()
  elif ttlSeconds == 0:
    immediate()
  else:
    delayed(initDuration(seconds = int(ttlSeconds)))

proc ttlSecondsFromPolicy*(policy: LeasePolicy): int64 =
  ## Encode a ``LeasePolicy`` for the wire ``ttlSeconds`` field — the
  ## inverse of ``policyFromTtlSeconds``, used by the client seam.
  case policy.kind
  of lkKeep:      LeaseRenewKeepSentinel
  of lkImmediate: 0'i64
  of lkDelayed:   policy.ttl.inSeconds

# ---------------------------------------------------------------------------
# The renew handler (§4.2 renew) — reuses the L2 renewal primitive
# (``deadlineFrom``) + the reference-counted MAX / keep-dominates fold.
# ---------------------------------------------------------------------------

proc renewHolder*(rec: var ResourceStateRecord; consumerId: string;
                  policy: LeasePolicy; now: Time) =
  ## Apply ONE consumer's renewal to ``rec`` in place — the daemon-side
  ## analog of reconcile's ``mergeHolderDeadlines`` for a single holder:
  ##
  ##   * ``deadlineFrom(policy, now)`` is the L2 primitive that maps the
  ##     policy to this holder's deadline;
  ##   * a ``keep``/``none`` policy DROPS the consumer from the dated map
  ##     (it pins with no expiry) so it can never masquerade as an expiring
  ##     holder;
  ##   * ``effectiveDeadline`` is recomputed as the MAX over all remaining
  ##     dated holders — but a ``keep`` holder makes it ``none`` (never
  ##     reap), dominating every dated holder (§2.3).
  let dl = deadlineFrom(policy, now)
  if dl.isSome:
    rec.holders[consumerId] = dl.get
  else:
    rec.holders.del(consumerId)
  rec.lastRenewed = now

  # keep-dominates: if THIS renewal pinned the state, effective is none.
  # Otherwise fold the MAX over the remaining dated holders. (We treat a
  # renew whose policy is keep as "this holder pins" — matching the L2
  # reconcile rule; a prior dated holder does not re-expire a keep-pinned
  # state within the same record because the pin is recorded as the absence
  # of a dated entry AND the effective deadline going none here.)
  if policy.kind == lkKeep:
    rec.effectiveDeadline = none(Time)
    return
  var effective = none(Time)
  for _, d in rec.holders:
    if effective.isNone or d > effective.get:
      effective = some(d)
  rec.effectiveDeadline = effective

proc applyLeaseRenew*(request: DaemonLeaseRenewRequest;
                      overrideRoot = "";
                      now: Time = getTime()): DaemonLeaseRenewResponse =
  ## The ``udkLeaseRenew`` handler body. Loads the record for
  ## ``request.address`` from the scoped store, renews ``request.consumerId``
  ## under the decoded policy, and persists it atomically. A missing record
  ## is a best-effort no-op (``ok == true``, ``hadRecord == false``): the
  ## renew targets the daemon's canonical registry, but the reconcile's
  ## own in-process L1 store write is the source of truth for correctness,
  ## so a daemon that has not yet seen this materialization must not fail the
  ## caller.
  let root = leaseStoreRootForScope(request.scope, overrideRoot)
  result.effectiveDeadlineUnix = LeaseRenewKeepSentinel
  if not dirExists(root):
    result.ok = true
    result.hadRecord = false
    result.reason = "no state store at " & root
    return
  let store = openStateStore(root)
  if not hasStateRecord(store, request.address):
    result.ok = true
    result.hadRecord = false
    result.reason = "no record for address " & request.address
    return
  var rec =
    try:
      readStateRecord(store, request.address)
    except CatchableError as err:
      result.ok = false
      result.reason = "failed to read record: " & err.msg
      return
  renewHolder(rec, request.consumerId,
              policyFromTtlSeconds(request.ttlSeconds), now)
  writeStateRecord(store, rec)
  result.ok = true
  result.hadRecord = true
  result.reason = "renewed"
  result.effectiveDeadlineUnix =
    if rec.effectiveDeadline.isSome: rec.effectiveDeadline.get.toUnix
    else: LeaseRenewKeepSentinel

# ---------------------------------------------------------------------------
# The wall-clock reaper tick (§4.2) — a bounded store sweep the daemon event
# loop calls on a cadence. Survives daemon restart: it reads the on-disk
# store, so an expired record left by a prior daemon instance is reaped by
# the next one on its first tick.
# ---------------------------------------------------------------------------

proc runLeaseReapTick*(scope: DaemonLeaseScope = dlsUser;
                       overrideRoot = "";
                       now: Time = getTime();
                       transport = none(ReapTransport)):
    ReapReport =
  ## Run ONE reap sweep against the scoped store (the L3
  ## ``reapExpiredAtReconcileStart`` — ``force = false``, so it never reaps a
  ## still-leased state). Returns the report (reaped + kept) so the caller
  ## (and a test) can observe it. A missing store dir is an empty report.
  ##
  ## L5 deferral (i): when no explicit ``transport`` is given, the transport
  ## is chosen by ``buildLeaseReapTransport`` — an ``rtSession`` over the
  ## pooled provider sessions when any provider artifact is registered
  ## (reaping OUT-OF-TREE vm-harness resources over a real session), else the
  ## in-process default (in-closure providers / the hermetic L4 stub). A test
  ## may still pin an explicit transport.
  let root = leaseStoreRootForScope(scope, overrideRoot)
  if not dirExists(root):
    return ReapReport(reaped: @[], skipped: @[])
  let store = openStateStore(root)
  let t = if transport.isSome: transport.get else: buildLeaseReapTransport()
  reapExpiredAtReconcileStart(store, now, t)

# ---------------------------------------------------------------------------
# L5 deferral (ii): the concrete consume-site renew hook.
#
# When a ``repro`` reconcile CONSUMES a leased state, L2 already folds the
# holder deadline into the on-disk store IN-PROCESS (the store write is the
# source of truth for correctness — see §4.3). The daemon, however, holds the
# canonical registry that drives the wall-clock reap; a consume must also
# NOTIFY the running daemon so its next tick honours the renewed deadline.
#
# ``renewLeasesForConsumed`` walks the reconciled desired graph, and for every
# ``consumes`` edge forwards a best-effort ``renewLeaseBestEffort`` to the
# daemon (address + consumerId + the policy's ttl). It NEVER regresses the
# no-daemon path: ``renewLeaseBestEffort`` swallows every unreachable/absent-
# daemon error, so a reconcile that already wrote the L1 record proceeds
# unchanged whether or not a daemon is up.
#
# ``reconcileLeasedResources`` is the one-call consume site: reconcile with the
# store (L1/L2) + forward the renews (L4). This is the seam the L5 topology
# gate — and any future top-level ``repro`` reconcile that consumes a leased
# state — calls.
# ---------------------------------------------------------------------------

proc renewLeasesForConsumed*(desired: seq[ResourceInstance];
                             scope: DaemonLeaseScope = dlsUser;
                             endpoint = defaultUserDaemonEndpoint()):
    seq[tuple[address, consumerId: string; sent: bool]] =
  ## Best-effort: for every leased-consume edge in ``desired`` forward a
  ## RENEW to the daemon-hosted registry. Returns, per edge, whether the
  ## renew reached a daemon (``sent``) — purely observational; a false
  ## ``sent`` is a healthy no-daemon run, NOT an error. Never raises.
  result = @[]
  for inst in desired:
    for dep in inst.consumes:
      let req = DaemonLeaseRenewRequest(
        scope: scope,
        address: dep.address,
        consumerId: dep.consumerId,
        ttlSeconds: ttlSecondsFromPolicy(dep.policy))
      let (sent, _) = renewLeaseBestEffort(req, endpoint)
      result.add((address: dep.address, consumerId: dep.consumerId,
                  sent: sent))

proc reconcileLeasedResources*(desired: seq[ResourceInstance];
                               store: StateStore;
                               recorded: seq[ResourceBinding] = @[];
                               options: ReconcileOptions = ReconcileOptions();
                               scope: DaemonLeaseScope = dlsUser;
                               endpoint = defaultUserDaemonEndpoint();
                               now: Time = getTime()):
    ReconcileResult =
  ## The concrete consume site (L5 deferral (ii)). Reconcile the desired graph
  ## against ``store`` (L1 persistence + L2 reuse-or-materialize/renew), then
  ## forward a best-effort daemon RENEW for each consumed leased edge (L4).
  ##
  ## The store write is the correctness source of truth; the daemon renew is a
  ## pure notification so the daemon's wall-clock reaper honours the advanced
  ## deadline without waiting to re-read. No-daemon-safe: the renews are all
  ## best-effort and never raise or alter the reconcile outcome.
  result = reconcileResources(desired, recorded = recorded, options = options,
    store = some(store), now = now)
  discard renewLeasesForConsumed(desired, scope, endpoint)
