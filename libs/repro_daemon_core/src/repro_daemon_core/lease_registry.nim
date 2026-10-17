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
##     record for the address, apply the L2 renewal primitive
##     (``applyHolderRenewal``: a dated policy sets ``holders[consumerId] =
##     deadlineFrom(policy, now)``, ``keep`` records the consumer in
##     ``keepHolders``), recompute the reference-counted MAX
##     ``effectiveDeadline`` (keep dominates -> ``none``), and persist
##     atomically (L1 ``writeStateRecord``). Absent
##     record => a best-effort no-op (``hadRecord == false``); the client
##     must not treat that as fatal (the no-daemon path already wrote the
##     record via the reconcile's in-process store, and a daemon that simply
##     has not yet seen a materialization must not wedge a reconcile).
##   * ``runLeaseReapTick`` — the wall-clock timer tick: run the L3
##     ``reapExpiredAtReconcileStart`` against the scoped store. The daemon
##     event loop calls this on a bounded cadence; it is a plain store sweep,
##     so it SURVIVES a daemon restart by construction (the store is on disk).
##   * ``runAndRecordLeaseReapTick`` — the tick the daemon event loop calls:
##     one sweep, its STANDING VERDICT (``LeaseReapTickHealth``) persisted
##     beside the store it swept, and counts plus pre-rendered finding lines
##     returned for the caller to log. Sweep and record are ONE call so that a
##     logging failure at the call site cannot be recorded as a sweep failure.
##   * ``readLeaseReapTickHealth`` + ``probeLeaseStore`` — the reader's half,
##     used by ``repro health``'s ``lease-reaper`` row. Logging a finding is
##     not reporting it; see the block comment above the constants.

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
  ## Apply ONE consumer's renewal to ``rec`` in place — the daemon side of
  ## reconcile's ``mergeHolderDeadlines``, and deliberately the SAME
  ## primitive (``repro_resources``' ``applyHolderRenewal``), so a renew that
  ## reaches the daemon and the in-process store write of the same consume
  ## cannot disagree about the record they produce:
  ##
  ##   * a dated policy sets ``holders[consumerId]`` to
  ##     ``deadlineFrom(policy, now)`` and takes the consumer out of
  ##     ``keepHolders``;
  ##   * ``keep`` records the consumer BY NAME in ``keepHolders`` (and drops
  ##     any dated entry for it), so the record can say who pins the state —
  ##     the name a ``repro up --replace`` refusal must give, and the one a
  ##     daemon rebuilding its registry from the store after a restart needs;
  ##   * ``effectiveDeadline`` is the MAX over the dated holders, or ``none``
  ##     while ANY keep holder is recorded — this renew's or an earlier one's
  ##     (§2.3: keep dominates every dated holder).
  applyHolderRenewal(rec, consumerId, policy, now)

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
    except ForeignStateRecordError as err:
      # A NEWER repro owns this record. Renewing would mean rewriting it in
      # OUR format — downgrading it and dropping whatever the newer version
      # added — so refuse and say why; the newer repro's own renew path (or
      # daemon) is the one that may touch it.
      result.ok = false
      result.reason = "refusing to renew: the record for " & request.address &
        " was written by a newer repro (state-record version " &
        $err.version & "); renew it with that version"
      return
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

proc leaseReapFindings*(report: ReapReport):
    seq[tuple[signature, line: string]] =
  ## Render one tick's ``failed`` records as ready-to-log sentences, each
  ## paired with the key a caller de-duplicates it on.
  ##
  ## This rendering lives HERE rather than in ``runtime.nim`` for the reason
  ## stated at the top of this module: ``lease_registry`` is the ONE module in
  ## ``repro_daemon_core`` that links ``repro_resources``, so the event loop
  ## cannot name ``ReapFailureKind`` to decide a verb. Same translation duty as
  ## the ``ttlSeconds`` <-> ``LeasePolicy`` encoding above — the resource lane's
  ## vocabulary stops at this module.
  ##
  ## THE SIGNATURE IS NOT THE LINE, and returning both is the whole point.
  ## ``runScopedLeaseReapTick`` reports each finding once per daemon run and
  ## keeps its keys for the daemon's entire life, so the key set has to be
  ## bounded by the STORE rather than by whatever text a failure happens to
  ## carry. ``reason`` is ``err.msg`` for an ``rfkUnreapable`` record, and only
  ## ONE of the causes ``reapOnce`` enumerates has a fixed message — a missing
  ## attrs marshaller names just the typeId. The others are a provider session
  ## that will not launch and a real provider's own ``observe``/``apply``
  ## failure: arbitrary text from out-of-tree code, free to carry a pid, a
  ## socket path, an errno or an attempt counter that differs on every tick.
  ## Keyed on the rendered line, such a record would log again every 30 s —
  ## the 142,713-line flood the de-duplication exists to stop — AND grow the
  ## key set without bound for as long as the daemon runs.
  ##
  ## address + typeId + kind IS the finding: one record, and one reason it is
  ## stuck. A changed message about the same stuck record is the same finding,
  ## and its text is already on the line that was logged.
  ##
  ## Records the sweep could not DECODE have no address, so they are keyed on
  ## their PATH: a second bad record is a new finding, not a repeat of the
  ## first. A foreign record also keys on its version (a store upgraded again
  ## is worth saying again). A quarantined record leaves the store, so its
  ## finding cannot recur for that file — the path key matters for the NEXT
  ## corrupt record, which must not be swallowed as already reported.
  result = @[]
  for f in report.foreign:
    result.add((
      signature: "foreign\x00" & f.path & "\x00" & $f.version,
      line: "leaving foreign record path=" & f.path & " version=" &
        $f.version & ": written by a newer repro; not reaped, not touched"))
  for q in report.quarantined:
    result.add((
      signature: "quarantined\x00" & q.path,
      line: "quarantined undecodable record path=" & q.path & " -> " &
        q.quarantinePath & ": " & q.reason))
  for u in report.unreadable:
    result.add((
      signature: "unreadable\x00" & u.path,
      line: "cannot read record path=" & u.path & ": " & u.reason))
  for f in report.failed:
    let verb =
      case f.kind
      of rfkUnreapable: "cannot reap"
      of rfkBlocked: "holding"
    result.add((
      signature: "finding\x00" & f.address & "\x00" & f.typeId & "\x00" &
        $f.kind,
      line: verb & " address=" & f.address & " typeId=" & f.typeId &
        ": " & f.reason))

# ---------------------------------------------------------------------------
# THE TICK'S OWN HEALTH — the record `repro health` reads.
#
# Reporting each finding once per daemon run (above) fixed the flood. It did
# NOT fix the thing that let the flood run for 57 days: a log line in a daemon
# nobody reads is not a report. Nothing asked whether the reaper had ever
# worked — not `repro health`, not the daemon's own status — so a component
# that was dead from its first tick looked exactly like one with nothing to do,
# while every command that depends on it kept succeeding
# (reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md,
# "Why it matters"). Worse, the de-duplication makes a persistent failure
# QUIETER: after the first report there is nothing new in the log at all.
#
# So the tick leaves a standing, readable verdict beside the store it sweeps,
# and `repro health` turns a run of unsuccessful ticks into a finding. The
# record is per-store rather than per-daemon-instance on purpose: the question
# is "is this store's state being reaped", which outlives any one daemon, and a
# restart must not launder a stuck store into a clean one.
# ---------------------------------------------------------------------------

const
  LeaseReapUnhealthyTickThreshold* = 10
    ## How many consecutive UNSUCCESSFUL ticks make the reaper a health
    ## finding. At the 30 s default cadence that is five minutes.
    ##
    ## The number is a judgement about two failure modes, not a round figure.
    ## Too low and a transient trips it: a provider session that needs one
    ## relaunch, a host under load, an `observe` that times out once — all of
    ## which the NEXT tick clears, and a doctor that goes red on them is a
    ## doctor people stop running (the same reasoning the `unpublished-heads`
    ## row states for staying a `warn`). Too high and it reproduces the defect
    ## in miniature: the condition this exists to catch was unfixable by
    ## retrying and persisted for 131,882 ticks, so anything that waits hours
    ## to say so has conceded the argument. Ten says "retrying has had a fair
    ## chance and is not working", within one coffee break rather than within
    ## two months.
  LeaseReapHealthFile = "reap-health"
    ## The record's filename inside the lease store root. It is deliberately
    ## NOT a `*.rec` name: `listStateRecords` walks the store directory and
    ## keeps only entries ending in `.rec` (skipping `.tmp-*` partials), so
    ## this file is invisible to every store reader and cannot be mistaken for
    ## a resource record.
  LeaseReapHealthMaxStuck = 16
    ## How many findings one verdict carries. The store is unbounded and every
    ## selected-but-unreapable record produces a finding, so without a cap the
    ## tick rewrites an ever-growing file every 30 s and the doctor renders an
    ## ever-growing string into both its table and its JSON. Sixteen is enough
    ## to show a pattern — the same typeId repeating, or one record blocking a
    ## chain — which is what an operator reads the list for; the exact
    ## population is in the store, and `elidedStuck` says how many were cut.
  LeaseReapHealthMaxStuckBytes = 8 * 1024
    ## A byte budget over the kept findings, because the count alone does not
    ## bound the size: a `reason` ends in provider text of any length. Reached
    ## before the count, it stops the list early and the remainder is elided
    ## the same way.

type
  LeaseReapTickHealth* = object
    ## The standing verdict on one lease store's reaper, as of its last tick.
    ##
    ## WHAT "SUCCESSFUL" MEANS HERE, stated once because every field below and
    ## the whole health row rest on it: a tick is SUCCESSFUL when it completed
    ## and left nothing it had SELECTED unreaped and nothing it could not even
    ## READ (see `recordLeaseReapTickOutcome` for the three undecodable
    ## categories and which of them count). An IDLE tick — the store held
    ## nothing due, so nothing was selected — therefore COUNTS AS SUCCESSFUL,
    ## and that is deliberate rather than incidental: an idle sweep genuinely
    ## demonstrates an unobstructed reaper (it listed the store, applied the
    ## predicate and finished), which is the useful thing to record. Most ticks
    ## on a healthy host are idle, and treating them as a third neither-state
    ## would leave a perfectly working daemon's verdict frozen at whatever its
    ## last destroy happened to be.
    lastTickUnix*: int64
      ## When a tick last RAN against this store.
    lastSuccessUnix*: int64
      ## When a sweep last COMPLETED UNOBSTRUCTED — not when something was
      ## last destroyed. An idle tick advances this; a tick that reaped three
      ## records and got stuck on a fourth does not.
      ##
      ## ``0`` means no tick has ever completed unobstructed. Because an idle
      ## tick counts as a success, that is reachable in exactly one way: the
      ## FIRST recorded tick already failed, and every tick since has. It is
      ## precisely the live daemon's case — 131,882 ticks, every one of them
      ## stuck on the same record, not one clean sweep — which is why the
      ## doctor is worth teaching to say "never" rather than only a count.
    totalTicks*: int64
      ## Ticks recorded against this store, across daemon instances.
    consecutiveUnsuccessful*: int
      ## Ticks since the last successful one. Reset to 0 by a success —
      ## including an idle one — so the verdict is falsifiable in both
      ## directions rather than a counter that only ever climbs.
    stuck*: seq[string]
      ## The most recent tick's findings (`leaseReapFindings` lines), each
      ## naming the record, its typeId and why it could not be reaped. The
      ## LAST tick's, not an accumulation: the question the doctor answers is
      ## what is stuck now.
      ##
      ## BOUNDED — see `LeaseReapHealthMaxStuck` / `LeaseReapHealthMaxStuckBytes`.
      ## A finding's `reason` is partly out-of-tree provider text and the store
      ## can hold thousands of records, so an uncapped list is an unbounded
      ## write on every tick and an unbounded string in the doctor's JSON.
    elidedStuck*: int
      ## Findings the last tick had but did not record, because the caps above
      ## were reached. Carried so the row can say how many it is not showing:
      ## a truncated list that does not admit to being truncated reads as the
      ## whole population, which is the same class of lie as a stuck store
      ## reading as a healthy one.

proc leaseReapTickIsUnhealthy*(health: LeaseReapTickHealth): bool =
  ## The one place the threshold is applied, so the daemon, the doctor and
  ## the tests cannot drift apart on what "persistently failing" means.
  health.consecutiveUnsuccessful >= LeaseReapUnhealthyTickThreshold

proc leaseReapHealthPath*(scope: DaemonLeaseScope = dlsUser;
                          overrideRoot = ""): string =
  ## Where the verdict for the store `scope`/`overrideRoot` selects lives.
  ## Derived from `leaseStoreRootForScope`, so the writer (the daemon tick)
  ## and the reader (`repro health`) cannot disagree about the location.
  leaseStoreRootForScope(scope, overrideRoot) / LeaseReapHealthFile

proc escapeHealthValue(value: string): string =
  ## `key=value` lines cannot carry a raw newline, and a `reason` is partly
  ## out-of-tree provider text — free to contain one. Escape rather than
  ## truncate: the reason is the whole content of the finding.
  result = newStringOfCap(value.len)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(ch)

proc unescapeHealthValue(value: string): string =
  result = newStringOfCap(value.len)
  var i = 0
  while i < value.len:
    if value[i] == '\\' and i + 1 < value.len:
      case value[i + 1]
      of '\\': result.add('\\'); i += 2
      of 'n': result.add('\n'); i += 2
      of 'r': result.add('\r'); i += 2
      else: result.add(value[i]); inc i
    else:
      result.add(value[i]); inc i

proc writeLeaseReapHealth(path: string; health: LeaseReapTickHealth) =
  ## Persist atomically: a temp file in the same directory, renamed over the
  ## destination (`writeStateRecord`'s pattern — a rename within one directory
  ## is atomic on POSIX and NTFS). A doctor must never read a half-written
  ## verdict, and a crash mid-write must leave the previous one.
  ##
  ## `key=value` text, like the daemon's own status file, and deliberately not
  ## JSON: `AGENTS.md` §Boundaries rules JSON out as an on-disk source of
  ## truth. This is also a file an operator may well `cat` while diagnosing,
  ## which is an argument for the same shape the status file already uses.
  let dir = parentDir(path)
  let tmp = dir / (".tmp-" & LeaseReapHealthFile)
  var body = "lastTickUnix=" & $health.lastTickUnix & "\n" &
    "lastSuccessUnix=" & $health.lastSuccessUnix & "\n" &
    "totalTicks=" & $health.totalTicks & "\n" &
    "consecutiveUnsuccessful=" & $health.consecutiveUnsuccessful & "\n" &
    "elidedStuck=" & $health.elidedStuck & "\n"
  for i, line in health.stuck:
    body.add("stuck." & $i & "=" & escapeHealthValue(line) & "\n")
  writeFile(tmp, body)
  moveFile(tmp, path)

proc readLeaseReapTickHealth*(scope: DaemonLeaseScope = dlsUser;
                              overrideRoot = ""):
    Option[LeaseReapTickHealth] =
  ## The verdict, or `none` when this store has none that can be read.
  ##
  ## `none` IS NOT "HEALTHY", and a caller must not render it as such on its
  ## own. It means only "this file did not yield a verdict", which covers a
  ## store nothing has ever ticked against (healthy, and the common case) AND
  ## a store whose tick cannot write its verdict (not healthy at all, and the
  ## residual form of the very invisibility the health row exists to remove).
  ## Distinguishing them needs a look at the store itself — `probeLeaseStore`
  ## — and the `lease-reaper` row does exactly that before it reports.
  ##
  ## NEVER RAISES. A caller is the daemon's own tick or the environment
  ## doctor; neither may be taken down by an unreadable or garbled file. A
  ## verdict that cannot be parsed is returned as `none` rather than as a
  ## partial one, because a truncated file read back as
  ## `consecutiveUnsuccessful=0` would positively ASSERT health, which `none`
  ## at least does not do by itself.
  let path = leaseReapHealthPath(scope, overrideRoot)
  var raw = ""
  try:
    if not fileExists(path):
      return none(LeaseReapTickHealth)
    raw = readFile(path)
  except CatchableError:
    return none(LeaseReapTickHealth)
  var health = LeaseReapTickHealth(stuck: @[])
  var sawTick = false
  try:
    for line in raw.splitLines:
      if line.len == 0:
        continue
      let eq = line.find('=')
      if eq <= 0:
        continue
      let key = line[0 ..< eq]
      let value = line[eq + 1 .. ^1]
      if key == "lastTickUnix":
        health.lastTickUnix = parseBiggestInt(value)
        sawTick = true
      elif key == "lastSuccessUnix":
        health.lastSuccessUnix = parseBiggestInt(value)
      elif key == "totalTicks":
        health.totalTicks = parseBiggestInt(value)
      elif key == "consecutiveUnsuccessful":
        health.consecutiveUnsuccessful = parseInt(value)
      elif key == "elidedStuck":
        health.elidedStuck = parseInt(value)
      elif key.startsWith("stuck."):
        health.stuck.add(unescapeHealthValue(value))
  except CatchableError:
    return none(LeaseReapTickHealth)
  # A file with no `lastTickUnix` is not a verdict about anything.
  if not sawTick:
    return none(LeaseReapTickHealth)
  some(health)

type
  LeaseReapStoreStateKind* = enum
    ## What is actually at a lease store root, for a reader that found NO
    ## verdict there and must not guess which of these it is looking at.
    lrsAbsent        ## no store root at all
    lrsEmpty         ## present and readable, holding no resource records
    lrsHoldsRecords  ## present and readable, holding records
    lrsUnreadable    ## present, but it could not be listed

  LeaseReapStoreState* = object
    kind*: LeaseReapStoreStateKind
    records*: int     ## `lrsHoldsRecords`: how many
    reason*: string   ## `lrsUnreadable`: why

proc probeLeaseStore*(scope: DaemonLeaseScope = dlsUser;
                      overrideRoot = ""): LeaseReapStoreState =
  ## Look at the store, for a caller deciding what an ABSENT verdict means.
  ##
  ## "No verdict" has three very different causes and only one of them is
  ## healthy. Reporting them alike is how this row would keep the defect it was
  ## added to remove: a reaper that is stuck AND cannot write its verdict
  ## (unwritable root — the verdict write raises inside
  ## `runAndRecordLeaseReapTick`, which returns it as `healthWriteError` for the
  ## daemon to report once per run) leaves no verdict at all, and a reader that treats
  ## "no verdict" as "nothing leased here" calls that healthy without having
  ## looked. The whole point of the row is to stop answering questions about
  ## the reaper from something other than the reaper's own state.
  ##
  ## NEVER RAISES, for the same reason `readLeaseReapTickHealth` does not: a
  ## diagnostic that dies on an unreadable directory has become the fault it
  ## was meant to report.
  let root = leaseStoreRootForScope(scope, overrideRoot)
  if not dirExists(root):
    return LeaseReapStoreState(kind: lrsAbsent)
  # `listStateRecords` walks with the stdlib's default `checkDir = false`,
  # which yields NOTHING for a directory it cannot open rather than raising —
  # so leaning on it alone would report an unreadable root as an empty one,
  # the exact conflation this probe exists to prevent. Ask for openability
  # explicitly, where a failure is an exception.
  try:
    for _ in walkDir(root, checkDir = true):
      break
  except CatchableError as err:
    return LeaseReapStoreState(kind: lrsUnreadable, reason: err.msg)
  try:
    let records = listStateRecords(openStateStore(root))
    if records.len == 0:
      LeaseReapStoreState(kind: lrsEmpty)
    else:
      LeaseReapStoreState(kind: lrsHoldsRecords, records: records.len)
  except CatchableError as err:
    # Openable but a record would not decode: not "empty", and not something
    # to answer a question about the reaper with.
    LeaseReapStoreState(kind: lrsUnreadable, reason: err.msg)

proc recordLeaseReapTickOutcome(successful: bool; findings: seq[string];
                                scope: DaemonLeaseScope;
                                overrideRoot: string; now: Time) =
  ## Fold ONE tick into the store's standing verdict.
  ##
  ## WHAT COUNTS AS SUCCESSFUL, which is the whole definition this record rests
  ## on: a tick is SUCCESSFUL when it completed and left nothing it had
  ## SELECTED unreaped and nothing it could not even READ. It is UNSUCCESSFUL
  ## when the sweep RAISED, when it finished holding at least one record it had
  ## selected and could not reap (`ReapReport.failed`), or when it left a
  ## record it could neither decode nor quarantine (`ReapReport.unreadable`).
  ## A FOREIGN record (a newer repro's, deliberately untouched) and a
  ## QUARANTINED one (moved out of the way by this sweep) are the reaper
  ## working as specified and do NOT count against it.
  ##
  ## Two consequences, both deliberate and both easy to get backwards:
  ##
  ##   * An IDLE tick — nothing was due, so nothing was selected — is
  ##     SUCCESSFUL, and advances `lastSuccessUnix`. It listed the store,
  ##     applied the predicate and finished with no obstruction, which is
  ##     exactly what the counter is asking about. `lastSuccessUnix` therefore
  ##     means "a sweep last completed unobstructed", NOT "something was last
  ##     destroyed". Most ticks on a healthy host are idle; a third
  ##     neither-state for them would freeze a working daemon's verdict at
  ##     whatever its last destroy happened to be, and the operator would be
  ##     reading a stale timestamp as a live one.
  ##   * A tick that reaped three records and got stuck on a fourth is
  ##     UNSUCCESSFUL. Partial progress is how a stuck store hides.
  ##
  ## So `lastSuccessUnix == 0` ("never") is reachable in exactly one way: the
  ## FIRST tick recorded against this store already failed, and so has every
  ## tick since. That is the live daemon's case and nothing else.
  ##
  ## ONE TICKER PER STORE is assumed, and it is what the daemon lock already
  ## gives: a scope's store is swept by the daemon that holds
  ## ``.repro-daemon.lock`` for it. The read-modify-write below is therefore
  ## not guarded against a concurrent writer — two tickers on one store could
  ## lose a count. The individual WRITE is still atomic (temp + rename), so the
  ## worst case is an undercount, never a corrupt or half-written verdict. A
  ## hand sweep (``repro reap``) deliberately does not write here at all: it is
  ## not a tick, and letting it reset the counter would let the operator's
  ## diagnostic erase the finding that sent them to it.
  let root = leaseStoreRootForScope(scope, overrideRoot)
  # No store, nothing to reap, nothing to report. Writing here would also
  # CREATE the store root as a side effect of a tick against a host that has
  # never leased anything, which the tick itself is careful not to do.
  if not dirExists(root):
    return
  var health = readLeaseReapTickHealth(scope, overrideRoot).get(
    LeaseReapTickHealth(stuck: @[]))
  health.lastTickUnix = now.toUnix
  inc health.totalTicks
  # Bounded, and honest about being bounded (see the two caps' docstrings).
  health.stuck = @[]
  health.elidedStuck = 0
  var budget = LeaseReapHealthMaxStuckBytes
  for finding in findings:
    if health.stuck.len >= LeaseReapHealthMaxStuck or finding.len > budget:
      inc health.elidedStuck
      continue
    budget -= finding.len
    health.stuck.add(finding)
  if successful:
    health.lastSuccessUnix = now.toUnix
    health.consecutiveUnsuccessful = 0
  else:
    inc health.consecutiveUnsuccessful
  writeLeaseReapHealth(leaseReapHealthPath(scope, overrideRoot), health)

type
  LeaseReapTickOutcome* = object
    ## Everything the daemon event loop needs to LOG about one tick, in
    ## vocabulary that does not name the resource lane.
    ##
    ## This type exists for the module boundary stated at the top of this
    ## file: `lease_registry` is the ONE module in `repro_daemon_core` that
    ## links `repro_resources`, so the event loop cannot name `ReapReport` to
    ## decide what to print. It gets counts and pre-rendered finding lines.
    raised*: bool
      ## The sweep itself failed, as opposed to one record in it: an
      ## unreadable store root, or anything else that stops the sweep before
      ## it can report per-record findings.
      ##
      ## An UNDECODABLE RECORD is no longer such a cause, and it is worth
      ## saying so because it used to be the canonical example: `3700fb02`
      ## guarded the decode loop, so `scanStateRecords` now reports a corrupt
      ## record as quarantined, a newer repro's as foreign and an unopenable
      ## one as unreadable — each a per-record finding, none of them a raise.
    failure*: string
      ## `raised`: the message.
    reapedCount*, keptCount*, failedCount*: int
    findings*: seq[tuple[signature, line: string]]
      ## Per-record findings, each with the key to de-duplicate it on.
    healthWriteError*: string
      ## Non-empty when the verdict could not be PERSISTED. Returned rather
      ## than raised: a diagnostic that cannot be written must not be able to
      ## take down the tick it describes, and the caller wants to report it
      ## once per run like any other finding.

proc runAndRecordLeaseReapTick*(scope: DaemonLeaseScope = dlsUser;
                                overrideRoot = "";
                                now: Time = getTime()):
    LeaseReapTickOutcome =
  ## Run ONE tick and persist its verdict, returning what to log.
  ##
  ## THE VERDICT IS DECIDED AND WRITTEN HERE, FROM THE SWEEP ALONE. That is
  ## the point of folding the two steps into one proc rather than leaving the
  ## caller to run the sweep and then record it: the caller also LOGS, logging
  ## can fail (a full disk, a revoked log file), and a caller that wrapped
  ## both in one `try` would persist a tick that SUCCEEDED as an unsuccessful
  ## one — manufacturing the very health finding this record exists to report
  ## truthfully. Keeping the decision on this side of the boundary means a
  ## later edit to the daemon's logging cannot reintroduce that.
  ##
  ## NEVER RAISES. Both the sweep failure and a failure to persist the verdict
  ## come back as fields.
  var reportFailures: seq[tuple[signature, line: string]] = @[]
  var successful = false
  try:
    let report = runLeaseReapTick(scope, overrideRoot = overrideRoot, now = now)
    result.reapedCount = report.reaped.len
    result.keptCount = report.skipped.len
    result.failedCount = report.failed.len
    reportFailures = leaseReapFindings(report)
    result.findings = reportFailures
    # `unreadable` counts against the tick; `foreign` and `quarantined` do
    # not. The three are not alike: a FOREIGN record is deliberately left
    # alone (a newer repro owns it) and a QUARANTINED one was just moved out
    # of the way by this very sweep — both are the reaper working as
    # specified. An UNREADABLE record "could neither be decoded nor
    # quarantined; still in place": nothing changed, the next tick meets it
    # again, and it is unfixable by retrying. That is exactly the class the
    # consecutive-unsuccessful counter exists to surface, so a sweep that
    # ends with one must not be recorded as a clean sweep.
    successful = report.failed.len == 0 and report.unreadable.len == 0
  except CatchableError as err:
    result.raised = true
    result.failure = err.msg
    successful = false

  var findingLines: seq[string] = @[]
  if result.raised:
    findingLines.add("whole sweep failed: " & result.failure)
  else:
    for finding in reportFailures:
      findingLines.add(finding.line)

  try:
    recordLeaseReapTickOutcome(successful, findingLines, scope, overrideRoot,
      now)
  except CatchableError as err:
    result.healthWriteError = err.msg

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
