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
##   (i) the same tick reaps a shared service INSTANCE whose last lease has
##       lapsed -- Shared-Development-Services §4.5's "an instance is reaped
##       when its last lease lapses", end to end through the DAEMON rather
##       than through a direct `reapOnce`. This is the case that measures
##       the WIRING: that the daemon installs the real instance-reap handler
##       around its tick, that the handler reaches the daemon's own
##       registry, and that the stop is a real signal to a real process.
##       Nothing is stubbed in it -- the instance is a real detached child
##       and its absence is read from `/proc`.

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
    ## per-user daemon's tick raised on its FIRST record — a `vm_harness.nic`
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

  test "(i) the tick reaps a shared service INSTANCE whose last lease lapsed":
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
    let process = materialiseServiceInstanceProcess(
      @["sh", "-c", "while :; do sleep 1; done"], root)
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
