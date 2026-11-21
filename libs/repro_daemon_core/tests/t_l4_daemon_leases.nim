## Ephemeral-State-Leases L4 (§4): the daemon-hosted lease registry + the
## wall-clock reaper tick.
##
## Hermetic: a THROWAWAY daemon instance (its own socket + state dir + a
## ``--state-root`` lease store, all under ``$HOME``) driven over the real
## ``RBUD`` IPC stack, with an in-process STUB resource provider (the L3
## shape) so a reap destroys a real, reconstructable record end-to-end. No
## built ``repro``/``repro-daemon`` binary, no Incus, no live daemon.
##
## The stub world + destroy log are PLAIN globals (not threadvars) guarded by
## a ``Lock``: the daemon runs its event loop — and therefore its reap tick —
## on a spawned thread, so the reap's ``apply(rakDestroy)`` must mutate the
## SAME world the test thread observes. (The provider registry is already a
## plain module global, visible cross-thread.)
##
## Cases:
##   (a) a renew over the socket advances a record's holder deadline +
##       effectiveDeadline (the ``udkLeaseRenew`` handler).
##   (b) the wall-clock timer tick reaps an expired stub state END-TO-END
##       (record present -> after a tick past its deadline -> destroyed +
##       record removed), with a very short reap interval.
##   (c) a daemon RESTART (stop the first instance, start a second against
##       the SAME on-disk store) resumes reaping — an expired record left by
##       the first instance is reaped by the second.
##   (d) scope routing selects the right store root for user vs system.
##   (e) a record the tick CANNOT reap (no attrs marshaller registered in the
##       daemon process) does not abort the tick: the reapable record beside it
##       is still reaped, and the condition is logged ONCE for the daemon's
##       life instead of on every tick.
##   (f) that "once" holds even when the failure's MESSAGE changes on every
##       tick — a provider refusing the destroy differently each time — so the
##       de-duplication is keyed on the record, not on the sentence.
##   (g) a ``keep`` renew NAMES its holder in the record (``keepHolders``),
##       a later dated renew by another consumer does not unpin it, and the
##       keep holder renewing under a dated policy moves out again. Driven
##       through ``applyLeaseRenew`` (the handler body) on a real store; the
##       socket hop in front of it is (a)'s subject, not this one's.
##   (h) records the sweep could not DECODE — quarantined (corrupt), foreign
##       (a newer repro's) and unreadable — render as findings keyed on their
##       PATH, so a second bad record is a new finding; and a renew refuses to
##       rewrite a foreign record.
##   (i) a tick that keeps failing leaves a readable VERDICT beside the store
##       (``LeaseReapTickHealth``): the consecutive-failure count crosses the
##       threshold ``repro health`` gates on, and "has never succeeded" is a
##       value the verdict can state. Reporting once per run is what makes this
##       necessary — after the first report the log says nothing at all.
##   (j) the same counter RESETS on a successful tick, and an IDLE tick (empty
##       store, nothing due) is itself a SUCCESS that advances
##       ``lastSuccessUnix`` — so the verdict is falsifiable in both directions
##       and a healthy daemon's row keeps reporting a LIVE time rather than
##       freezing at its last destroy.
##   (k) the recorded verdict is a function of the SWEEP, not of the logging:
##       ``runAndRecordLeaseReapTick`` decides and writes it, and its signature
##       admits no log path at all, so a log write that fails cannot persist a
##       clean sweep as an unsuccessful one. Driven as a direct call — no
##       daemon, no log file.
##   (l) the three UNDECODABLE categories are weighed differently by the
##       verdict: an UNREADABLE record (neither decoded nor quarantined, still
##       in place) makes the tick unsuccessful, while a FOREIGN one (left
##       untouched on purpose) and a QUARANTINED one (moved aside by this
##       sweep) do not. ``failed`` is empty in all three, so a verdict keyed on
##       ``failed`` alone would call a permanently obstructed store clean.
##   (m) the same tick reaps a shared service INSTANCE whose last lease has
##       lapsed -- Shared-Development-Services §4.5's "an instance is reaped
##       when its last lease lapses", end to end through the DAEMON rather
##       than through a direct `reapOnce`. This is the case that measures
##       the WIRING: that the daemon installs the real instance-reap handler
##       around its tick, that the handler reaches the daemon's own
##       registry, and that the stop is a real signal to a real process.
##       Nothing is stubbed in it -- the instance is a real detached child
##       and its absence is read from `/proc`.
##   (n)-(r) the §4.2 DESTROY TRANSPORT's registration half
##       (Ephemeral-State-Leases §4.2): the `udkLeaseReapProviders` frame's
##       body codec and its bound on a hostile entry (n); a real frame over
##       the real IPC stack reaching a real daemon's reap registry, and the
##       refusals — no typeId, no binaryPath, a relative path, an empty
##       pool key — each named in the ack and in the daemon's log (o); what
##       the registry does to the transport selection once filled, read on
##       the only thread that touches it (o2); a registration against NO
##       daemon as a healthy no-op, since the artifact is persisted in the
##       record anyway (p); `clearLeaseReapProviders`, which the daemon's
##       shutdown defer calls (q); and the feature gate that makes a new
##       CLI refuse an old daemon truthfully instead of provoking an error
##       frame (r).

import std/[os, options, times, tables, locks, random, strutils, unittest]

import repro_core
import repro_daemon_core
import repro_daemon_core/instance_registry   # the real probe + materialiser
import repro_resources
import repro_resources/service_identity
import repro_resources/service_registry
import repro_project_dsl          # TypedExtensionBox / ServiceIdentityDef

# ---------------------------------------------------------------------------
# Stub provider — PLAIN globals + a lock (cross-thread visible), destroy log.
# ---------------------------------------------------------------------------

type
  StubAttrs = object
    value: string

var stubLock: Lock
var stubWorld: Table[string, string]     ## resourceId -> realized value
var destroyLog: seq[string]              ## addresses destroyed, in order

proc stubIdentity(inst: ResourceInstance): string =
  "stub:" & inst.address

proc stubDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[StubAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc stubObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stubLock:
      let id = stubIdentity(inst)
      if stubWorld.hasKey(id):
        result.present = true
        result.digest = digestString(
          inst.typeId & "\x00" & inst.address & "\x00" & stubWorld[id])
      else:
        result.present = false

proc stubApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock stubLock:
      let id = stubIdentity(inst)
      let a = TypedExtensionBox[StubAttrs](inst.attrs).val
      case action
      of rakDestroy:
        destroyLog.add(inst.address)
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
    typeId: "l4.stub",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: stubApply)))
  registerExtension[StubAttrs]("l4.stub")

proc stubState(name, value: string): ResourceRef =
  resource("l4.stub", name, StubAttrs(value: value))

# ---------------------------------------------------------------------------
# A provider whose DESTROY refuses with a DIFFERENT sentence every attempt.
#
# `reapOnce` names four causes a per-record reap can raise on, and the one the
# live daemon hit — a missing attrs marshaller — is the only one whose message
# is ours and therefore fixed. The other three end in text written by
# out-of-tree provider code: a session that would not launch, an `observe` that
# failed, an `apply` that refused. Such a message is free to carry a pid, a
# socket path, an errno or an attempt counter, and then no two ticks say the
# same thing. This provider is that case, minimally: it reconstructs (its attrs
# marshaller IS registered) and observes present, so the reap reaches the
# destroy, and the destroy raises with the attempt number in it.
# ---------------------------------------------------------------------------

var flakyAttempts: int                   ## refused destroys, guarded by stubLock

proc flakyApply(inst: ResourceInstance; action: ResourceActionKind;
                observed: ObservedState): ResourceBinding {.gcsafe.} =
  {.cast(gcsafe).}:
    case action
    of rakDestroy:
      var attempt: int
      withLock stubLock:
        inc flakyAttempts
        attempt = flakyAttempts
      raise newException(CatchableError,
        "provider refused destroy (attempt " & $attempt & ")")
    else:
      result = stubApply(inst, action, observed)

proc registerFlaky() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "l4.flaky",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: stubIdentity,
      digest: stubDigest,
      observe: stubObserve,
      apply: flakyApply)))
  registerExtension[StubAttrs]("l4.flaky")

proc flakyState(name, value: string): ResourceRef =
  resource("l4.flaky", name, StubAttrs(value: value))

proc stubConsumer(name, value: string; consumes: seq[LeasedDep]): ResourceRef =
  resource("l4.stub", name, StubAttrs(value: value), consumes = consumes)

proc worldHas(address: string): bool =
  withLock stubLock:
    result = stubWorld.hasKey("stub:" & address)

proc destroyLogSnapshot(): seq[string] =
  withLock stubLock: result = destroyLog

# Materialize a leased state (+ its consumer) into `store` so we have a real,
# reconstructable record to renew/reap.
proc materialize(store: StateStore; stateName, consumerId: string;
                 policy: LeasePolicy; now: Time) =
  resetDesiredResources()
  discard stubState(stateName, "up")
  discard stubConsumer(consumerId & "-c", "probe",
    consumes = @[leased(stateName, consumerId, policy)])
  discard reconcileResources(collectedResources(), store = some(store), now = now)

proc materializeFlaky(store: StateStore; stateName, consumerId: string;
                      policy: LeasePolicy; now: Time) =
  ## `materialize`, but the leased state is the flaky type. Its create path is
  ## the stub's, so this really does write a reconstructable record and really
  ## does put the state in the fake world; only the DESTROY refuses.
  resetDesiredResources()
  discard flakyState(stateName, "up")
  discard stubConsumer(consumerId & "-c", "probe",
    consumes = @[leased(stateName, consumerId, policy)])
  discard reconcileResources(collectedResources(), store = some(store), now = now)

# ---------------------------------------------------------------------------
# Throwaway daemon harness (real runUserDaemonForeground on a thread).
# ---------------------------------------------------------------------------

type
  DaemonArgs = tuple[config: UserDaemonConfig]

var daemonThreadResult: int

proc runThrowawayDaemon(args: DaemonArgs) {.thread.} =
  {.cast(gcsafe).}:
    # The attrs marshaller registry (``extensionRegistry``) is a THREADVAR,
    # so the stub's marshaller must be registered ON THIS THREAD for the
    # reap's ``reconstructInstance`` -> ``unmarshalAttrs`` to succeed. In
    # production the daemon process links + registers its providers at
    # startup on its own thread; here the test daemon does the same. (The
    # provider *driver* registry is a plain global — already visible — so the
    # stub world/log the destroy mutates is shared with the test thread.)
    registerStub()
    registerFlaky()
    daemonThreadResult = runUserDaemonForeground(args.config)

proc scratchRoot(sub: string): string =
  getHomeDir() / ".cache" /
    ("repro-l4-" & $getCurrentProcessId() & "-" & $rand(999_999) & "-" & sub)

proc startThrowawayDaemon(root, stateRoot: string;
                          thread: var Thread[DaemonArgs]): UserDaemonConfig =
  var config = defaultUserDaemonConfig()
  config.endpoint = root / "daemon.sock"
  config.stateDir = root / "state"
  config.logPath = root / "state" / "logs" / "daemon.log"
  config.leaseStoreRoot = stateRoot
  createThread(thread, runThrowawayDaemon, (config: config,))
  discard waitForUserDaemonStatus(config.endpoint, 10_000)
  config

# ---------------------------------------------------------------------------

suite "L4: daemon-hosted lease registry + wall-clock reaping":

  setup:
    initLock(stubLock)
    withLock stubLock:
      stubWorld = initTable[string, string]()
      destroyLog = @[]
    resetDesiredResources()
    registerStub()
    registerFlaky()
    withLock stubLock:
      flakyAttempts = 0
    randomize()
    # Disable the wall-clock tick by default; cases that want it set the env
    # explicitly. (Prevents an unrelated case's daemon from reaping.)
    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "0")

  test "(a) a renew over the socket advances holder + effectiveDeadline":
    let root = scratchRoot("renew")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)
    let t0 = getTime()
    # Seed a record with an immediate (now) holder so a subsequent delayed
    # renew visibly advances the deadline.
    materialize(store, "cluster", "smoke", immediate(), t0)
    let before = readStateRecord(store, "cluster")
    check before.effectiveDeadline.isSome
    check before.effectiveDeadline.get.toUnix <= t0.toUnix + 1

    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    # Renew the same holder under delayed(1h): the deadline must jump ~1h out.
    let resp = requestUserDaemonLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "cluster", consumerId: "smoke",
      ttlSeconds: 3600), config.endpoint)
    check resp.ok
    check resp.hadRecord
    check resp.effectiveDeadlineUnix >= t0.toUnix + 3500

    let after = readStateRecord(store, "cluster")
    check after.effectiveDeadline.isSome
    check after.effectiveDeadline.get.toUnix >= t0.toUnix + 3500
    check after.holders["smoke"].toUnix >= t0.toUnix + 3500
    check after.lastRenewed.toUnix >= t0.toUnix

    # A renew for an unknown address is a best-effort no-op (not fatal).
    let miss = requestUserDaemonLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "no-such", consumerId: "x", ttlSeconds: 60),
      config.endpoint)
    check miss.ok
    check not miss.hadRecord

  test "(b) the wall-clock timer tick reaps an expired stub state end-to-end":
    let root = scratchRoot("tick")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)
    # Materialize a delayed(1m) state whose deadline is already in the PAST,
    # so the daemon's first wall-clock tick must reap it.
    let past = getTime() - initDuration(hours = 1)
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)), past)
    check hasStateRecord(store, "cluster")
    check worldHas("cluster")

    # A fast reap cadence — the daemon runs the L3 reaper on this tick.
    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "100")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    # Wait for the tick to fire (startup sweep + periodic) and reap.
    let deadline = epochTime() + 8.0
    while epochTime() < deadline and hasStateRecord(store, "cluster"):
      sleep(50)

    check not hasStateRecord(store, "cluster")     # record removed
    check not worldHas("cluster")                  # world torn down
    check "cluster" in destroyLogSnapshot()        # destroy actually ran

  test "(c) a daemon restart resumes reaping (store survives restart)":
    let root = scratchRoot("restart")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)

    # --- first daemon instance: NO reap tick (interval 0). It leaves an
    # already-expired record on disk untouched. ---
    let past = getTime() - initDuration(hours = 1)
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)), past)
    check hasStateRecord(store, "cluster")

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "0")
    var thread1: Thread[DaemonArgs]
    let config1 = startThrowawayDaemon(root, stateRoot, thread1)
    # Give the (disabled) loop a moment; the record must STILL be present.
    sleep(300)
    check hasStateRecord(store, "cluster")
    requestUserDaemonShutdown(config1.endpoint)
    joinThread(thread1)

    # --- second instance against the SAME on-disk store, tick enabled. The
    # expired record left by instance #1 must be reaped from disk alone. ---
    check hasStateRecord(store, "cluster")         # survived the restart
    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "100")
    var thread2: Thread[DaemonArgs]
    let config2 = startThrowawayDaemon(root, stateRoot, thread2)
    defer:
      try: requestUserDaemonShutdown(config2.endpoint) except CatchableError: discard
      joinThread(thread2)
      removeDir(root)

    let deadline = epochTime() + 8.0
    while epochTime() < deadline and hasStateRecord(store, "cluster"):
      sleep(50)
    check not hasStateRecord(store, "cluster")     # reaped by the 2nd instance
    check "cluster" in destroyLogSnapshot()

  test "(d) scope routing selects the right store root for user vs system":
    # An explicit override wins for BOTH scopes (the --state-root / test path).
    check leaseStoreRootForScope(dlsUser, "/tmp/x") == "/tmp/x"
    check leaseStoreRootForScope(dlsSystem, "/tmp/x") == "/tmp/x"
    # User scope -> the L3 per-user root ($HOME/.cache/repro/state).
    check leaseStoreRootForScope(dlsUser) == defaultUserStateStoreRoot()
    # System scope -> the system state dir (env-overridable for hermeticity).
    putEnv("REPRO_SYSTEM_STATE_DIR", "/home/zahary/.cache/repro-l4-sys-probe")
    check leaseStoreRootForScope(dlsSystem) ==
      "/home/zahary/.cache/repro-l4-sys-probe/state"
    delEnv("REPRO_SYSTEM_STATE_DIR")
    # The two scopes are DISTINCT roots (no cross-scope aliasing).
    check leaseStoreRootForScope(dlsUser) != leaseStoreRootForScope(dlsSystem)
    # Policy <-> ttlSeconds wire encoding round-trips (the renew translation).
    check ttlSecondsFromPolicy(keep()) == LeaseRenewKeepSentinel
    check ttlSecondsFromPolicy(immediate()) == 0
    check ttlSecondsFromPolicy(delayed(initDuration(seconds = 42))) == 42
    check policyFromTtlSeconds(LeaseRenewKeepSentinel).kind == lkKeep
    check policyFromTtlSeconds(0).kind == lkImmediate
    check policyFromTtlSeconds(42).kind == lkDelayed

  test "(e) an unmarshallable record neither aborts the tick nor floods the log":
    ## The measured defect (reprobuild-specs/issues/
    ## 2026-09-29-lease-reap-tick-has-never-once-succeeded.md): the live
    ## per-user daemon's tick raised on its FIRST record — a `gosti.nic`
    ## whose attrs marshaller the daemon does not link — reaped nothing, and
    ## logged the identical sentence 141,895 times over 60 days (62 MB of an
    ## unrotated 385 MB log). Two failures in one: the tick never ran, and the
    ## way it said so was indistinguishable from saying nothing.
    ##
    ## Both are asserted here, end-to-end, against a real daemon on a real
    ## store with its real log file. `orphan` is a genuine record written to
    ## disk under a typeId no `registerExtension` covers on the daemon thread,
    ## so the daemon raises the same `KeyError` for the same reason; nothing is
    ## stubbed to fail and nothing is mocked.
    let root = scratchRoot("unreapable")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)

    # One reapable stub state whose deadline is already past...
    let past = getTime() - initDuration(hours = 1)
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)),
                past)
    check hasStateRecord(store, "cluster")
    check worldHas("cluster")

    # ...and one record the daemon cannot reconstruct. Hand written: the whole
    # point is a typeId whose marshaller is absent, and `buildStateRecord`
    # marshals THROUGH that registry. `reverseTopoOrder` sorts `orphan` after
    # `cluster` and then reverses, so the tick meets `orphan` FIRST — which is
    # why, before the fix, `cluster` was never reached.
    writeStateRecord(store, ResourceStateRecord(
      address: "orphan",
      typeId: "l4.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l4.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:orphan",
      present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: some(past),
      lastRenewed: past))

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "100")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    # The reapable record must be reaped despite the broken one beside it.
    let deadline = epochTime() + 8.0
    while epochTime() < deadline and hasStateRecord(store, "cluster"):
      sleep(50)
    check not hasStateRecord(store, "cluster")     # record removed
    check not worldHas("cluster")                  # world torn down
    check "cluster" in destroyLogSnapshot()        # destroy actually ran

    # The broken record stays on disk: a daemon that DOES link the marshaller
    # (or a later `repro reap`) resumes it. It is not silently dropped.
    check hasStateRecord(store, "orphan")

    # Now let many more ticks run at 100 ms. The condition is unchanged and
    # unfixable by retrying, so it must be reported ONCE, not once per tick.
    # The log is read with the daemon still up (the `defer` above owns the
    # single shutdown + join); `logLine` opens/appends/closes per line, so
    # every tick that has fired is already on disk.
    sleep(1200)
    let logText = readFile(config.logPath)
    # At least a dozen ticks ran in that window, so a per-tick report would
    # show here. Exactly ONE LINE names the record — counted per line, not per
    # substring occurrence: the typeId legitimately appears three times inside
    # that single line (the `typeId=` field, the raised message, and the
    # `registerExtension[Attrs]("...")` remedy the message suggests).
    var linesNamingRecord = 0
    for line in logText.splitLines:
      if line.contains("l4.unregistered"):
        inc linesNamingRecord
    check linesNamingRecord == 1
    check logText.count("cannot reap") == 1
    # ...and it says which record and why, not just that something went wrong.
    check logText.contains("address=orphan")
    check logText.contains("marshaller")
    # The old whole-sweep abort is gone: nothing raised out of the sweep.
    check logText.count("lease reap tick error") == 0

  test "(f) a failure whose message changes every tick is still reported once":
    ## Case (e) proves the tick reports a stuck record once. It proves it for
    ## the ONE failure whose message is ours and therefore identical on every
    ## tick. This case is the same property for a failure whose message is a
    ## PROVIDER's: `l4.flaky` refuses the destroy with the attempt number in
    ## the sentence, so no two ticks produce the same text.
    ##
    ## De-duplicating on the rendered sentence passes case (e) and fails here:
    ## every tick's sentence is new, so every tick logs — the same flood, at the
    ## same 142,713-lines-in-61-days rate — and the daemon's set of seen
    ## messages grows for as long as it runs. Nothing about that is visible in
    ## a fixture whose error text never moves, which is why this case exists
    ## beside (e) rather than instead of it.
    let root = scratchRoot("flaky")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)

    let past = getTime() - initDuration(hours = 1)
    materializeFlaky(store, "flaky", "smoke", delayed(initDuration(minutes = 1)),
                     past)
    check hasStateRecord(store, "flaky")
    check worldHas("flaky")            # really materialized; the destroy is what fails

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "100")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    # Many ticks at 100 ms; each re-attempts the destroy and is refused anew.
    sleep(1500)
    var attempts = 0
    withLock stubLock: attempts = flakyAttempts
    # Non-vacuity: the record really was retried a lot, so a per-sentence key
    # would have a lot of distinct sentences to log.
    check attempts >= 5

    let logText = readFile(config.logPath)
    var linesNamingRecord = 0
    for line in logText.splitLines:
      if line.contains("address=flaky"):
        inc linesNamingRecord
    check linesNamingRecord == 1
    # The one line still carries the provider's own words, so the operator is
    # told WHY and not merely that something is stuck.
    check logText.contains("provider refused destroy")
    # The record and its world state are both kept: a refused destroy must not
    # remove the record.
    check hasStateRecord(store, "flaky")
    check worldHas("flaky")
    # And nothing raised out of the sweep.
    check logText.count("lease reap tick error") == 0

  test "(g) a keep renew names its holder; a dated renew does not unpin it":
    let root = scratchRoot("keep-renew")
    let stateRoot = root / "lease-state"
    removeDir(root)
    defer: removeDir(root)
    let store = openStateStore(stateRoot)
    let t0 = fromUnix(1_700_000_000)
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)), t0)
    check readStateRecord(store, "cluster").effectiveDeadline.isSome

    # A keep renew pins the state AND records who pins it.
    let t1 = t0 + initDuration(seconds = 10)
    let pin = applyLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "cluster", consumerId: "pinner",
      ttlSeconds: LeaseRenewKeepSentinel), stateRoot, t1)
    check pin.ok and pin.hadRecord
    check pin.effectiveDeadlineUnix == LeaseRenewKeepSentinel
    let pinned = readStateRecord(store, "cluster")
    check pinned.keepHolders == @["pinner"]
    check not pinned.holders.hasKey("pinner")
    check pinned.holders.hasKey("smoke")
    check pinned.effectiveDeadline.isNone

    # Another consumer renewing under a DATED policy must not unpin it: the
    # keep holder is still recorded, so the record still answers who pins it.
    let t2 = t1 + initDuration(seconds = 10)
    let dated = applyLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "cluster", consumerId: "smoke",
      ttlSeconds: 3600), stateRoot, t2)
    check dated.ok
    check dated.effectiveDeadlineUnix == LeaseRenewKeepSentinel
    let still = readStateRecord(store, "cluster")
    check still.keepHolders == @["pinner"]
    check still.holders["smoke"] == t2 + initDuration(seconds = 3600)
    check still.effectiveDeadline.isNone

    # The keep holder itself renewing under a dated policy releases the pin.
    let t3 = t2 + initDuration(seconds = 10)
    let release = applyLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "cluster", consumerId: "pinner",
      ttlSeconds: 60), stateRoot, t3)
    check release.ok
    let released = readStateRecord(store, "cluster")
    check released.keepHolders.len == 0
    check released.holders["pinner"] == t3 + initDuration(seconds = 60)
    # MAX over the dated holders: smoke's hour outlives pinner's minute.
    check released.effectiveDeadline == some(t2 + initDuration(seconds = 3600))
    check release.effectiveDeadlineUnix == (t2 + initDuration(seconds = 3600)).toUnix

    # The in-place primitive the handler uses names the holder too.
    var rec = released
    renewHolder(rec, "anchor", keep(), t3)
    check rec.keepHolders == @["anchor"]
    check rec.effectiveDeadline.isNone

  test "(h) undecodable records are findings keyed on PATH; renew refuses a foreign record":
    ## reprobuild-pm issues/2026-10-01-one-undecodable-state-record-aborts-
    ## every-lease-reap-sweep-forever.md, item 3: `reportOnce` keys on the
    ## signature, so a signature that did not name the path would swallow the
    ## SECOND corrupt record as a repeat of the first.
    let report = ReapReport(
      quarantined: @[
        QuarantinedStateRecord(path: "/s/a.rec",
          quarantinePath: "/s/quarantine/a.rec.1-2-3", reason: "bad magic"),
        QuarantinedStateRecord(path: "/s/b.rec",
          quarantinePath: "/s/quarantine/b.rec.1-2-4", reason: "bad magic")],
      foreign: @[ForeignStateRecord(path: "/s/f.rec", version: 9)],
      unreadable: @[UnreadableStateRecord(path: "/s/u.rec",
        reason: "permission denied")])
    let findings = leaseReapFindings(report)
    check findings.len == 4
    var signatures: seq[string] = @[]
    for f in findings:
      check f.signature notin signatures      # all distinct
      signatures.add(f.signature)
    for path in ["/s/a.rec", "/s/b.rec", "/s/f.rec", "/s/u.rec"]:
      var keyed, logged = false
      for f in findings:
        if f.signature.contains(path): keyed = true
        if f.line.contains(path): logged = true
      check keyed
      check logged
    for f in findings:
      if f.signature.contains("/s/f.rec"):
        check f.signature.contains("9")
        check f.line.contains("version=9")
      if f.signature.contains("/s/a.rec"):
        check f.line.contains("/s/quarantine/a.rec.1-2-3")
        check f.line.contains("bad magic")

    # Renew of a record a NEWER repro wrote: refused, file byte-for-byte kept.
    let root = scratchRoot("foreign-renew")
    let stateRoot = root / "lease-state"
    removeDir(root)
    defer: removeDir(root)
    let store = openStateStore(stateRoot)
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)),
                getTime())
    let path = stateRoot / "cluster.rec"
    var bytes = readFile(path)
    bytes[4] = char((StateRecordSszVersion + 1) and 0xFF)
    writeFile(path, bytes)
    let resp = applyLeaseRenew(DaemonLeaseRenewRequest(
      scope: dlsUser, address: "cluster", consumerId: "smoke",
      ttlSeconds: 3600), overrideRoot = stateRoot)
    check not resp.ok
    check resp.reason.contains("newer repro")
    check readFile(path) == bytes

  test "(i) a reaper that never succeeds becomes a readable health finding":
    ## §4.5 "a persistently failing reaper is a health finding".
    ##
    ## Cases (e) and (f) prove the tick reports a stuck record ONCE instead of
    ## on every tick. That is the right fix for the 62 MB of repeated log lines
    ## the live daemon produced, and it makes the underlying failure QUIETER
    ## still: after the first report there is nothing new in the log at all. So
    ## it cannot also be the answer to "has the reaper ever worked" — which is
    ## the question nothing could answer for 57 days while `repro health`, the
    ## daemon's status and every dependent command all read healthy
    ## (reprobuild-pm/issues/
    ## 2026-09-29-lease-reap-tick-has-never-once-succeeded.md, "Why it
    ## matters").
    ##
    ## Driven against the real daemon on a real store: the verdict is whatever
    ## the production tick wrote, read back through the production reader.
    let root = scratchRoot("health-stuck")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)
    let past = getTime() - initDuration(hours = 1)

    # A record the daemon cannot reconstruct in-process and has no provider
    # session for: the live defect's shape, and unfixable by retrying.
    writeStateRecord(store, ResourceStateRecord(
      address: "orphan",
      typeId: "l4.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l4.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:orphan",
      present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: some(past),
      lastRenewed: past))

    # No verdict before the daemon runs: an absent record is the healthy
    # "nothing has swept this store" answer, not a failure to report.
    check readLeaseReapTickHealth(dlsUser, stateRoot).isNone

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "50")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    # Wait for the counter to cross the threshold the doctor gates on, rather
    # than for a fixed number of milliseconds.
    let deadline = epochTime() + 15.0
    var health = readLeaseReapTickHealth(dlsUser, stateRoot)
    while epochTime() < deadline and
        (health.isNone or not leaseReapTickIsUnhealthy(health.get)):
      sleep(50)
      health = readLeaseReapTickHealth(dlsUser, stateRoot)

    check health.isSome
    let h = health.get
    check leaseReapTickIsUnhealthy(h)
    check h.consecutiveUnsuccessful >= LeaseReapUnhealthyTickThreshold
    # NEVER succeeded — the issue's own case, and a distinct value from
    # "succeeded a while ago". A reaper that has not worked once is a wiring
    # fault; one that has stopped working is a new obstruction.
    check h.lastSuccessUnix == 0
    check h.totalTicks >= int64(LeaseReapUnhealthyTickThreshold)
    check h.lastTickUnix > 0
    # The verdict names the record and why, so the finding is actionable
    # without reading the log.
    check h.stuck.len == 1
    check h.stuck[0].contains("address=orphan")
    check h.stuck[0].contains("l4.unregistered")
    # Nothing was destroyed and the record is still there to be resumed.
    check hasStateRecord(store, "orphan")

  test "(j) a successful tick resets the counter, and an IDLE tick is a success":
    ## Two properties, and the second is the one that is easy to get backwards.
    ##
    ## (1) The counter is falsifiable in BOTH directions. A monotonically
    ##     climbing counter would make the doctor's row go red once and stay
    ##     red, which is the same uninformative constant as the row that was
    ##     always green.
    ##
    ## (2) An IDLE tick — the store holds nothing due, so nothing is selected —
    ##     counts as a SUCCESS and ADVANCES `lastSuccessUnix`. It is not a
    ##     third neither-state. Asserting only `consecutiveUnsuccessful == 0`
    ##     cannot see the difference, because the counter sits at 0 under
    ##     either reading; the discriminator is whether `lastSuccessUnix` keeps
    ##     MOVING once the store is empty. Under "idle is neither" it would
    ##     freeze at the timestamp of the last destroy, and an operator reading
    ##     the row would be told a stale time as if it were live.
    ##
    ## `lastSuccessUnix` therefore means "a sweep last completed unobstructed",
    ## not "something was last destroyed".
    let root = scratchRoot("health-ok")
    let stateRoot = root / "lease-state"
    removeDir(root)
    let store = openStateStore(stateRoot)
    let past = getTime() - initDuration(hours = 1)

    # A reapable stub record: the tick will destroy it and succeed.
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)),
                past)
    check hasStateRecord(store, "cluster")
    check worldHas("cluster")

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "50")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      removeDir(root)

    let deadline = epochTime() + 10.0
    var health = readLeaseReapTickHealth(dlsUser, stateRoot)
    while epochTime() < deadline and
        (health.isNone or health.get.lastSuccessUnix == 0):
      sleep(50)
      health = readLeaseReapTickHealth(dlsUser, stateRoot)

    check health.isSome
    let h = health.get
    check h.lastSuccessUnix > 0
    check h.consecutiveUnsuccessful == 0
    check not leaseReapTickIsUnhealthy(h)
    check h.stuck.len == 0
    check not hasStateRecord(store, "cluster")   # it really did reap

    # The store is now EMPTY (the one record was reaped), so every subsequent
    # tick is idle. Wait for `lastSuccessUnix` to ADVANCE past the destroying
    # tick's: that is property (2), and it is what distinguishes "idle is a
    # success" from "idle is neither". The wait is on the value rather than on
    # a fixed sleep because the field has one-second granularity.
    let advanceDeadline = epochTime() + 10.0
    var later = readLeaseReapTickHealth(dlsUser, stateRoot)
    while epochTime() < advanceDeadline and
        (later.isNone or later.get.lastSuccessUnix <= h.lastSuccessUnix):
      sleep(50)
      later = readLeaseReapTickHealth(dlsUser, stateRoot)

    check later.isSome
    # THE DISCRIMINATOR: an idle sweep recorded a success of its own.
    check later.get.lastSuccessUnix > h.lastSuccessUnix
    # Non-vacuity: those were idle ticks, not more destroys — the store stayed
    # empty and nothing new was reaped.
    check not hasStateRecord(store, "cluster")
    check later.get.stuck.len == 0
    # ...and the counter stayed down, which is property (1) holding through a
    # run of idle ticks.
    check later.get.consecutiveUnsuccessful == 0
    check not leaseReapTickIsUnhealthy(later.get)
    check later.get.totalTicks > h.totalTicks

  test "(k) the recorded verdict is a function of the SWEEP, not of the logging":
    ## S8: a tick that swept cleanly must never be PERSISTED as an unsuccessful
    ## one because a log write failed. The two failures are unrelated — a full
    ## disk or a revoked log file breaks `logLine`, not the reaper — and
    ## conflating them manufactures the health finding this record exists to
    ## report truthfully, which is strictly worse than a missing log line.
    ##
    ## The property is STRUCTURAL and this case pins the structure:
    ## `runAndRecordLeaseReapTick` decides the verdict and writes it, and its
    ## signature admits NO log path, NO config and NO logger — so there is
    ## nothing it could fail on that belongs to logging, and no ordering a
    ## later edit to the daemon's logging could get wrong. The event loop logs
    ## only AFTER it returns, from the values it returns.
    ##
    ## Driven as a direct call rather than through a daemon, because that is
    ## what makes the point: no daemon, no log file, no event loop — and the
    ## verdict is still recorded correctly in both directions.
    let root = scratchRoot("sweep-not-logging")
    let stateRoot = root / "lease-state"
    removeDir(root)
    defer: removeDir(root)
    let store = openStateStore(stateRoot)
    let past = getTime() - initDuration(hours = 1)

    # --- An IDLE sweep over an empty store: successful, and recorded so. ---
    let idle = runAndRecordLeaseReapTick(dlsUser, stateRoot)
    check not idle.raised
    check idle.reapedCount == 0
    check idle.findings.len == 0
    check idle.healthWriteError.len == 0
    let afterIdle = readLeaseReapTickHealth(dlsUser, stateRoot)
    check afterIdle.isSome
    check afterIdle.get.lastSuccessUnix > 0          # idle IS a success
    check afterIdle.get.consecutiveUnsuccessful == 0
    check afterIdle.get.totalTicks == 1

    # --- A sweep that really reaps: also successful. ---
    materialize(store, "cluster", "smoke", delayed(initDuration(minutes = 1)),
                past)
    check hasStateRecord(store, "cluster")
    let reaping = runAndRecordLeaseReapTick(dlsUser, stateRoot)
    check not reaping.raised
    check reaping.reapedCount == 1
    check reaping.findings.len == 0
    check not hasStateRecord(store, "cluster")
    let afterReap = readLeaseReapTickHealth(dlsUser, stateRoot)
    check afterReap.get.consecutiveUnsuccessful == 0
    check afterReap.get.totalTicks == 2

    # --- A sweep that gets stuck: UNsuccessful, and the finding is carried
    # back for the caller to log rather than logged from inside. ---
    writeStateRecord(store, ResourceStateRecord(
      address: "orphan",
      typeId: "l4.unregistered",
      determinism: rdVolatile,
      attrsTypeId: "l4.unregistered",
      attrsJson: "\x01\x00\x00\x00\x00\x00",
      dependsOn: @[],
      identity: "stub:orphan",
      present: true,
      holders: initTable[string, Time](),
      effectiveDeadline: some(past),
      lastRenewed: past))
    let stuck = runAndRecordLeaseReapTick(dlsUser, stateRoot)
    check not stuck.raised              # the SWEEP completed; a record did not
    check stuck.failedCount == 1
    check stuck.findings.len == 1
    check stuck.findings[0].line.contains("address=orphan")
    # The signature carries the finding OUT; nothing was written to any log,
    # because this proc has no log to write to.
    let afterStuck = readLeaseReapTickHealth(dlsUser, stateRoot)
    check afterStuck.get.consecutiveUnsuccessful == 1
    check afterStuck.get.lastSuccessUnix == afterReap.get.lastSuccessUnix
    check afterStuck.get.stuck.len == 1
    check afterStuck.get.totalTicks == 3

  test "(l) an UNREADABLE record makes the tick unsuccessful; foreign and quarantined do not":
    ## The three undecodable categories `scanStateRecords` reports are NOT
    ## alike, and the verdict has to tell them apart or it reports a
    ## permanently obstructed store as a clean one — the failure this whole
    ## record exists to remove.
    ##
    ##   * FOREIGN (a newer repro's record): deliberately left untouched. The
    ##     reaper is working as specified, so the tick is successful.
    ##   * QUARANTINED (corrupt): this sweep moved it out of the way. It made
    ##     progress and the condition is gone, so the tick is successful.
    ##   * UNREADABLE: "could neither be decoded nor quarantined; still in
    ##     place". Nothing changed, the next tick meets it again, and no amount
    ##     of retrying helps. That is the class the consecutive-unsuccessful
    ##     counter is for, so it must count.
    ##
    ## Driven against a real store through the production tick, with a real
    ## unreadable file (mode 000) rather than a synthetic report: case (h)
    ## already covers the rendering of a synthetic one, and what is at stake
    ## here is the VERDICT, which only the real sweep writes.
    when defined(posix):
      let root = scratchRoot("unreadable-verdict")
      let stateRoot = root / "lease-state"
      removeDir(root)
      defer: removeDir(root)
      discard openStateStore(stateRoot)

      # A quarantinable (plain corrupt) record first: the sweep moves it out,
      # which is progress, so the tick must be SUCCESSFUL.
      writeFile(stateRoot / "corrupt.rec", "not a state record at all")
      let quarantining = runAndRecordLeaseReapTick(dlsUser, stateRoot)
      check not quarantining.raised
      check quarantining.failedCount == 0
      let afterQuarantine = readLeaseReapTickHealth(dlsUser, stateRoot)
      check afterQuarantine.isSome
      # Non-vacuity: the sweep really did report it, and really did move it.
      check afterQuarantine.get.stuck.len == 1
      check afterQuarantine.get.stuck[0].contains("quarantined")
      check not fileExists(stateRoot / "corrupt.rec")
      check afterQuarantine.get.lastSuccessUnix > 0
      check afterQuarantine.get.consecutiveUnsuccessful == 0

      # Now one that can be neither decoded NOR moved, because it cannot even
      # be opened. The sweep leaves it in place and must say the tick failed.
      let bad = stateRoot / "unreadable.rec"
      writeFile(bad, "also not a state record")
      setFilePermissions(bad, {})
      defer: setFilePermissions(bad, {fpUserRead, fpUserWrite})
      let obstructed = runAndRecordLeaseReapTick(dlsUser, stateRoot)
      check not obstructed.raised          # the SWEEP completed...
      check obstructed.failedCount == 0    # ...and selected nothing at all
      check obstructed.findings.len == 1
      check obstructed.findings[0].line.contains("cannot read record")
      let afterUnreadable = readLeaseReapTickHealth(dlsUser, stateRoot)
      check afterUnreadable.isSome
      # THE DISCRIMINATOR: `failed` is empty, so a verdict keyed on `failed`
      # alone would have called this a clean sweep and advanced the success
      # timestamp. It must not.
      check afterUnreadable.get.consecutiveUnsuccessful == 1
      check afterUnreadable.get.lastSuccessUnix ==
        afterQuarantine.get.lastSuccessUnix
      check afterUnreadable.get.stuck.len == 1
      check afterUnreadable.get.stuck[0].contains("cannot read record")
      # It is still there, which is why retrying cannot help.
      check fileExists(bad)

  test "(m) the tick reaps a shared service INSTANCE whose last lease lapsed":
    ## Shared-Development-Services §4.5: "an instance is reaped when its
    ## last lease lapses." Cases (b) and (c) above measure the tick over a
    ## STUB resource; this one measures it over a real shared service
    ## instance, which is a different path through the same sweep: an
    ## instance record carries no attrs marshaller and no provider driver
    ## by design, so it is reaped through the typed `ReapHandler` the
    ## daemon installs around the tick rather than through
    ## `reconstructInstance`.
    ##
    ## WHY THIS CASE EXISTS BESIDE THE REGISTRY'S OWN SUITE.
    ## `libs/repro_resources/tests/t_l7_instance_registry_converges_in_any_order.nim`
    ## drives `reapOnce` with the handler installed BY THE TEST. That
    ## measures the handler. It cannot measure the WIRING -- that
    ## `runScopedLeaseReapTick` installs it, that it is handed a pointer to
    ## the daemon's own registry object, and that it is restored afterwards
    ## -- because in that suite the test is the installer. Here the daemon
    ## is, and the test only writes a record and waits.
    ##
    ## NOTHING IS STUBBED. The key comes from the real
    ## `serviceInstanceKey` over a real `ServiceIdentityDef`; the record is
    ## written by the real `recordMaterialisedInstance` through the real
    ## `mergeHolderDeadlines` into the real `StateStore` the daemon is
    ## pointed at; the instance is a real detached child started by the
    ## real `materialiseServiceInstanceProcess`; the liveness probe is the
    ## real `writerLiveness`; and "the process is gone" is read from
    ## `/proc`, not from the daemon's report.
    let root = scratchRoot("instance-tick")
    let stateRoot = root / "lease-state"
    removeDir(root)
    createDir(stateRoot)

    let key = serviceInstanceKey(
      DslServiceDef(packageName: "l4InstPkg", serviceName: "zitadel",
        identity: ServiceIdentityDef(kind: sikStable,
          stableId: "com.example.l4.instance-tick"),
        scope: sscWorkspace),
      ServiceScopeContext(projectRoot: root, workspaceRoot: root,
        workspaceId: "l4-instance-tick", user: "l4tester"),
      [], "dev")
    let address = serviceInstanceAddress(key)

    var registry = openServiceInstanceRegistry(stateRoot,
      serviceInstanceLivenessProbe())
    let started = materialiseServiceInstanceProcess(
      @["sh", "-c", "while :; do sleep 1; done"], root,
      serviceInstanceOutputLogPath(stateRoot, key))
    doAssert not started.exitedEarly,
      "fixture instance died during its start grace window: " &
      describeEarlyServiceInstanceExit(started, address)
    let process = started.process
    # A lease that lapsed an hour ago: the holder is dated (`delayed`), so
    # the gate SELECTS the record. A `keep` holder would never be selected,
    # which is D-SS5's default and is asserted in the registry's own suite.
    discard recordMaterialisedInstance(registry, key,
      ServiceInterfaceSnapshot(serviceName: "zitadel",
        packageName: "l4InstPkg", projectName: "l4", activityName: "sso",
        handleType: "H", compatibilityMajor: 1, fingerprint: "f",
        projectFingerprint: "pf", members: @[]),
      process, "holder:l4-instance-tick",
      delayed(initDuration(minutes = 1)),
      getTime() - initDuration(hours = 1))

    let store = openStateStore(stateRoot)
    check hasStateRecord(store, address)
    check readStateRecord(store, address).typeId == ServiceInstanceTypeId
    check dirExists("/proc/" & $process.pid)

    putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "100")
    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      # Belt and braces: if the tick did NOT stop the instance, this case
      # must not leak a `sleep` loop into the rest of the suite.
      discard stopServiceInstanceProcess(process, graceMs = 1500)
      removeDir(root)

    let deadline = epochTime() + 15.0
    while epochTime() < deadline and hasStateRecord(store, address):
      sleep(50)

    # The RECORD is gone...
    check not hasStateRecord(store, address)
    # ...and so is the PROCESS, read from the process table. `/proc/<pid>`
    # survives an exit until the child is waited on, so its absence also
    # witnesses that the daemon reaped the zombie rather than merely
    # signalling it.
    let pidDeadline = epochTime() + 10.0
    while epochTime() < pidDeadline and dirExists("/proc/" & $process.pid):
      sleep(50)
    check not dirExists("/proc/" & $process.pid)

    # And the daemon SAID so. Without this, a tick that silently declined
    # every record would be indistinguishable from one that reaped.
    let log = readFile(config.logPath)
    check log.contains("lease reap tick reaped=")
    check not log.contains("lease reap tick error")
    check not log.contains("cannot reap address=" & address)

  test "(n) the reap-provider frame round-trips, and refuses an unusable entry":
    ## Ephemeral-State-Leases §4.2 — the FRESH half of the destroy-transport
    ## artifact resolution, on the wire. Body codec first, because a frame that
    ## does not round-trip makes every behavioural assertion below it a test of
    ## the wrong bytes.
    let request = DaemonLeaseReapProvidersRequest(
      scope: dlsUser,
      providers: @[
        DaemonLeaseReapProvider(typeId: "gosti.nic",
          binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "aa11",
          workingDir: "/work"),
        DaemonLeaseReapProvider(typeId: "gosti.container",
          binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "aa11",
          workingDir: "/work")])
    let back = parseLeaseReapProvidersRequestBody(
      leaseReapProvidersRequestBody(request))
    check back.scope == dlsUser
    check back.providers.len == 2
    check back.providers[0].typeId == "gosti.nic"
    check back.providers[0].binaryPath == "/nix/store/p/bin/prov"
    check back.providers[0].providerArtifactId == "aa11"
    check back.providers[0].workingDir == "/work"
    check back.providers[1].typeId == "gosti.container"

    # The system scope survives the hop too (the daemon logs it; a client
    # routes by endpoint).
    let sys = parseLeaseReapProvidersRequestBody(
      leaseReapProvidersRequestBody(DaemonLeaseReapProvidersRequest(
        scope: dlsSystem, providers: @[])))
    check sys.scope == dlsSystem
    check sys.providers.len == 0

    let response = parseLeaseReapProvidersResponseBody(
      leaseReapProvidersResponseBody(DaemonLeaseReapProvidersResponse(
        ok: false, reason: "nope", registered: 7)))
    check not response.ok
    check response.reason == "nope"
    check response.registered == 7

    # A COUNT the frame cannot honour is refused on the count, before anything
    # is allocated from it: the number comes from the client, so a corrupt or
    # hostile frame must not get to size the daemon's allocation.
    var hostile: seq[byte] = @[]
    hostile.writeU32Le(uint32(ord(dlsUser)))
    hostile.writeU32Le(uint32(MaxLeaseReapProviders + 1))
    expect ValueError:
      discard parseLeaseReapProvidersRequestBody(hostile)

  test "(o) a registration over the socket reaches the daemon's reap registry":
    ## The feeder whose absence made the whole `rtSession` arm unreachable from
    ## the product: `registerLeaseReapProvider` had NO caller in the shipped
    ## tree (reprobuild-pm/issues/
    ## 2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md).
    ## Here a real client frame over the real IPC stack reaches a real daemon's
    ## handler, and the daemon reports what it registered.
    ##
    ## THE REGISTRY IS DELIBERATELY NOT READ FROM THIS THREAD. The daemon runs
    ## on a spawned `Thread`, and `leaseReapProviders` is a plain module global
    ## with no synchronisation — which is sound IN THE DAEMON, where the frame
    ## handler and the reap tick are the same event-loop thread, and unsound
    ## for a reader on another thread. `hasLeaseReapProviders()` /
    ## `registeredLeaseReapArtifacts()` from the test thread would be an
    ## unsynchronised read of a `Table` the daemon thread is mutating: at best a
    ## torn answer, and a case that can pass or fail on timing proves nothing
    ## either way. So every assertion below is on evidence that crossed a REAL
    ## boundary — the ack the daemon sent back over the socket, and the line it
    ## wrote to its own log file.
    let root = scratchRoot("reap-providers")
    let stateRoot = root / "lease-state"
    removeDir(root)
    discard openStateStore(stateRoot)

    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      # The daemon's own shutdown `defer` calls `clearLeaseReapProviders`, so
      # the registry this case filled does not leak into a sibling case. Joined
      # first, so that has happened before anything here looks at it.
      clearLeaseReapProviders()
      removeDir(root)

    let sent = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.outoftree",
          binaryPath: "/nix/store/p/bin/prov",
          providerArtifactId: "bb22", workingDir: "/work")]),
      config.endpoint)
    check sent.sent
    check sent.response.ok
    check sent.response.registered == 1

    # An entry that names no type, or no binary, is refused WHOLE — a daemon
    # that believed it could reap a type it cannot would be the same
    # silently-wrong-and-reporting-success shape this area keeps fixing.
    let bad = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.second",
          binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "cc33"),
        DaemonLeaseReapProvider(typeId: "",
          binaryPath: "/nix/store/p/bin/prov")]),
      config.endpoint)
    check bad.sent
    check not bad.response.ok
    check bad.response.registered == 0
    check bad.response.reason.contains("typeId")

    let noPath = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.third", binaryPath: "")]),
      config.endpoint)
    check noPath.sent
    check not noPath.response.ok
    check noPath.response.reason.contains("binaryPath")

    # A RELATIVE path is refused too, and that is not pedantry: the transport
    # drops a ref `isLaunchableArtifact` rejects, and non-absolute is one of
    # its two rejection criteria. A handler that accepted this would answer
    # `ok: true, registered: 1`, log a successful registration and make
    # `hasLeaseReapProviders()` true, while every tick afterwards dropped the
    # ref and reaped in-process — reporting success and doing nothing, which is
    # the shape the handler's own contract forbids.
    let relative = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.relative",
          binaryPath: "prov", providerArtifactId: "dd44")]),
      config.endpoint)
    check relative.sent
    check not relative.response.ok
    check relative.response.registered == 0
    # The reason names the path and why it is not launchable, so the client's
    # operator can fix the producer rather than guess.
    check relative.response.reason.contains("'prov'")
    check relative.response.reason.contains("not absolute")
    check relative.response.reason.contains("PATH")

    # An EMPTY providerArtifactId is refused on the same terms, and for a
    # reason the operator could not guess: that field is the provider-session
    # POOL KEY, so an empty one would alias this provider with any other
    # empty-id artifact into a single session — the first child launched would
    # serve both types and its errors would be reported as this type's. The
    # transport drops such a ref (`isLaunchableArtifact`), so a handler that
    # accepted it would report a registration that changes no sweep.
    let noId = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.noid",
          binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "")]),
      config.endpoint)
    check noId.sent
    check not noId.response.ok
    check noId.response.registered == 0
    check noId.response.reason.contains("providerArtifactId")
    check noId.response.reason.contains("POOL KEY")
    # ...and the refusal is the TRANSPORT's own test, not a second opinion:
    # the validator delegates to `isLaunchableArtifact` on the very artifact
    # that would have been registered.
    check leaseReapProviderRefusal("l4.noid", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "")).len > 0
    check leaseReapProviderRefusal("l4.noid", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov",
      providerArtifactId: "ee55")).len == 0
    check leaseReapProviderRefusal("", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov",
      providerArtifactId: "ee55")).len > 0

    # The daemon's own log — the other side of the boundary, and where an
    # operator diagnosing a reap that did not happen will look. One accepted
    # registration and two refusals, each named.
    #
    # POLLED, not read once: the handler writes the ack frame BEFORE its log
    # line, so a client that has its answer can be ahead of the daemon's
    # `logLine`. Reading immediately raced the last line. The loop is bounded
    # and the assertions below it are unconditional, so a daemon that never
    # logs fails the case rather than hanging it. (`logLine` opens, appends and
    # closes per line, so anything written is already on disk.)
    let wantedLines = @[
      "lease reap providers registered=1 requested=1 ok=true",
      "registered=0 requested=2 ok=false",
      "registered=0 requested=1 ok=false",
      "not absolute",
      "providerArtifactId"]
    proc logHasAll(path: string): bool =
      let text = try: readFile(path) except CatchableError: ""
      for wanted in wantedLines:
        if not text.contains(wanted):
          return false
      true
    let logDeadline = epochTime() + 8.0
    while epochTime() < logDeadline and not logHasAll(config.logPath):
      sleep(50)
    let logText = readFile(config.logPath)
    for wanted in wantedLines:
      check logText.contains(wanted)

  test "(o2) the in-process registry drives the transport selection":
    ## The other half of (n), asserted WITHOUT a daemon thread so the registry
    ## is read by the only thread that touches it. (o) proves the frame reaches
    ## the daemon; this proves what the registry does once filled — that the
    ## §4.2 transport selection turns a registered artifact into a SESSION
    ## route for that type and leaves every other type in-process.
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()
    check not hasLeaseReapProviders()

    # The plain in-process transport is what an empty registry yields, which is
    # all the product could ever produce before this change.
    check buildLeaseReapTransport().kind == rtInProcess

    registerLeaseReapProvider("l4.outoftree", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov",
      providerArtifactId: "bb22", workingDir: "/work"))
    check hasLeaseReapProviders()
    let registered = registeredLeaseReapArtifacts()
    check registered.len == 1
    check registered[0].typeId == "l4.outoftree"
    check registered[0].artifact.binaryPath == "/nix/store/p/bin/prov"
    check registered[0].artifact.providerArtifactId == "bb22"
    check registered[0].artifact.workingDir == "/work"

    let transport = buildLeaseReapTransport()
    check transport.kind == rtSession
    check transport.inProcess != nil
    check not transport.inProcess("l4.outoftree")   # over the session
    check transport.inProcess("l4.stub")            # in-process, as before

  test "(p) a registration against NO daemon is a healthy no-op":
    ## No-daemon-safe, on the same terms as `renewLeaseBestEffort`: the
    ## registration is a freshness optimization, and the artifact is persisted
    ## in each state record anyway, so a reconcile must not fail — or even
    ## notice — when nothing is listening.
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()
    let dead = scratchRoot("no-daemon") / "absent.sock"
    let outcome = registerLeaseReapProvidersBestEffort(
      DaemonLeaseReapProvidersRequest(scope: dlsUser, providers: @[
        DaemonLeaseReapProvider(typeId: "l4.outoftree",
          binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "bb22")]),
      dead)
    check not outcome.sent
    check not outcome.response.ok
    check outcome.response.reason.len > 0
    # And it did NOT register locally — the registry belongs to the daemon
    # process, so a client that could not reach one has registered nothing.
    check not hasLeaseReapProviders()

  test "(q) clearLeaseReapProviders empties the registry and the pool":
    ## The daemon's shutdown `defer` calls this, which is what makes
    ## `clearLeaseReapProviders`' own docstring true. It used to claim the
    ## shutdown path with no caller — and that mattered once records began
    ## driving the pool, because a stopped daemon would have left one provider
    ## child per artifact it had reaped over, orphaned and holding a pipe, with
    ## nothing left to close them.
    ##
    ## SCOPE, stated so this case is not mistaken for more than it is: no
    ## session is launched here (no provider binary), so this asserts the
    ## registry half and that the pool is empty afterwards. That the pool is
    ## BOUNDED ACROSS TICKS — the `pruneLeaseReapSessionPool` rule — needs live
    ## sessions and therefore a real compiled provider; it is proven in
    ## `tests/integration/t_lease_reap_session_transport_is_reachable_from_production.nim`
    ## ("the reap session pool is bounded across ticks"), where launching one is
    ## already the point of the file.
    clearLeaseReapProviders()
    defer: clearLeaseReapProviders()
    check not hasLeaseReapProviders()
    check leaseReapSessionCount() == 0

    registerLeaseReapProvider("l4.oota", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "id-aaaa"))
    registerLeaseReapProvider("l4.ootb", LeaseReapProviderArtifact(
      binaryPath: "/nix/store/p/bin/prov", providerArtifactId: "id-bbbb"))
    check hasLeaseReapProviders()
    check registeredLeaseReapArtifacts().len == 2

    clearLeaseReapProviders()
    check not hasLeaseReapProviders()
    check registeredLeaseReapArtifacts().len == 0
    check leaseReapSessionCount() == 0

  test "(r) the capability is advertised, and the client gate refuses what is not":
    ## §4.2 registration is BEST-EFFORT, and best-effort has to be able to tell
    ## "no daemon wants this" from "the daemon broke". A daemon that predates
    ## `lease-reap-providers` would answer an unknown frame kind with
    ## `unsupported user-daemon message in lifecycle server` — an error frame,
    ## for a daemon that is working exactly as built and simply lacks the
    ## capability. So the capability is ADVERTISED as a feature flag and
    ## `requestUserDaemonLeaseReapProviders` REQUIRES it, which turns that into
    ## a handshake refusal: truthful, and cheaper (no frame is sent at all,
    ## because `connectUserDaemon` checks the flags before the caller writes
    ## anything).
    ##
    ## WHAT THIS CASE PROVES, exactly, against a REAL daemon: that a current
    ## daemon advertises the flag, so the new requirement does not refuse the
    ## daemons we ship; and that the gate really refuses a feature the daemon
    ## does not advertise, so requiring the flag is load-bearing rather than
    ## decorative. The remaining link — that the client asks for this
    ## particular flag — is the `requiredFeatures` list in
    ## `requestUserDaemonLeaseReapProviders`, asserted by reading.
    ##
    ## An earlier draft stood up a FAKE daemon advertising the pre-change flag
    ## set. It deadlocked: the fake had to block in `readFrame` to witness
    ## whether a frame arrived, and then never returned to its poll loop to see
    ## the stop flag, so `joinThread` hung. A case that can hang the suite is
    ## worse than one that proves slightly less.
    let root = scratchRoot("feature-gate")
    let stateRoot = root / "lease-state"
    removeDir(root)
    discard openStateStore(stateRoot)

    var thread: Thread[DaemonArgs]
    let config = startThrowawayDaemon(root, stateRoot, thread)
    defer:
      try: requestUserDaemonShutdown(config.endpoint) except CatchableError: discard
      joinThread(thread)
      clearLeaseReapProviders()
      removeDir(root)

    # A current daemon advertises it: the handshake succeeds.
    block:
      var conn = connectUserDaemon(config.endpoint,
        commandMode = "lease-reap-providers",
        requiredFeatures = ["lease-registry", "lease-reap-providers"])
      conn.closeIpcConn()

    # ...and the gate is real: an unadvertised feature is refused, by the same
    # code path, against the same daemon.
    expect UserDaemonClientError:
      var conn = connectUserDaemon(config.endpoint,
        commandMode = "lease-reap-providers",
        requiredFeatures = ["lease-registry", "no-such-feature-v9"])
      conn.closeIpcConn()

    # The flag is in the advertised set, which is what the first block above
    # consumed — asserted directly so a rename cannot silently make the gate
    # a permanent refusal.
    check UserDaemonFeatureFlags.contains("lease-reap-providers")
