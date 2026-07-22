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

import ./protocol

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
                       transport: ReapTransport = inProcessTransport()):
    ReapReport =
  ## Run ONE reap sweep against the scoped store (the L3
  ## ``reapExpiredAtReconcileStart`` — ``force = false``, so it never reaps a
  ## still-leased state). Returns the report (reaped + kept) so the caller
  ## (and a test) can observe it. A missing store dir is an empty report.
  let root = leaseStoreRootForScope(scope, overrideRoot)
  if not dirExists(root):
    return ReapReport(reaped: @[], skipped: @[])
  let store = openStateStore(root)
  reapExpiredAtReconcileStart(store, now, transport)
