## Ephemeral-State-Leases.md §2.3 / §4.2 / §4.3 / §4.4 — lease liveness and
## record updates under CONCURRENCY.
##
## reprobuild-pm issue
## `2026-11-12-lease-liveness-and-record-updates-are-not-concurrency-safe-in-use-state-can-be-reaped-and.md`
## names three defects, each a property of several processes touching one
## state store at once. Every case here drives the production code path from
## more than one process (or more than one open file) and checks the
## real-world outcome, not an internal flag:
##
##   * (1) lost update: concurrent daemon renews of ONE record each read,
##     modify and rename it; without a per-record lock the last rename wins
##     and the other holders — a `keep` holder among them — are dropped.
##   * (2) in-flight liveness: a consume that runs longer than its `ttl` (or
##     under `immediate`) is still in use, and the wall-clock reap must not
##     destroy it mid-run; the deadline starts when the consume ENDS; and a
##     consumer that dies mid-run must not pin the state.
##   * (3) reap vs reuse: a consume that starts while a reap of the same
##     record is destroying it must not "reuse" the state being destroyed;
##     and a reaper whose selection went stale (a renew landed after its
##     scan) must re-check before destroying.
##
## MOCKS, AND WHY. The resource provider is an in-tree mock (`lc.mock`)
## registered in this process — the same stub-with-a-witness pattern as
## `t_run_consumes.nim` and the L3 reaper tests — because the defect is in the
## store/lease layer, not in any provider, and a real provider (Incus) would
## make a timing-sensitive concurrency test depend on a container runtime.
## The mock's "world" is a DIRECTORY of files (one per realized resource), not
## process memory, so a destroy performed by a child process is visible to the
## parent, exactly as a real resource's destruction would be. Everything else
## — the state store, the lease renew handler, the reaper, the run-edge
## consume bridge, file locks, child processes — is the production code
## against the real filesystem. The daemon endpoint is deliberately
## unreachable so the best-effort daemon notify is a deterministic no-op.

import std/[tables, options, times, os, osproc, unittest, strutils, strtabs]

import repro_core/ambient_execution   # uncontrolledStartProcess
import repro_resources
import repro_project_dsl             # TypedExtensionBox / StateGroupDef / RunEdgeLease
import repro_daemon_core             # applyLeaseRenew / DaemonLeaseRenewRequest
import repro_cli_support             # reconcileConsumedStateGroups (the run bridge)

const NoDaemon = "/nonexistent/repro-lease-concurrency-no-daemon.sock"
const ChildRoleEnv = "REPRO_LEASE_CONCURRENCY_CHILD"
const WorldEnv = "REPRO_LEASE_CONCURRENCY_WORLD"
const SlowDestroyMarkEnv = "REPRO_LEASE_CONCURRENCY_SLOW_DESTROY_MARK"

let noArtifacts: seq[tuple[typeId: string;
                           artifact: ResourceProviderArtifactRef]] = @[]

# ---------------------------------------------------------------------------
# File-backed mock provider.
# ---------------------------------------------------------------------------

type
  MockAttrs = object
    value: string

var applyLog {.threadvar.}: seq[string]
var destroyLog {.threadvar.}: seq[string]

proc worldDir(): string = getEnv(WorldEnv)

proc worldFile(inst: ResourceInstance): string =
  worldDir() / inst.address

proc mockIdentity(inst: ResourceInstance): string = "mock:" & inst.address

proc mockDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[MockAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc mockObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  let f = worldFile(inst)
  if fileExists(f):
    result.present = true
    result.digest = digestString(
      inst.typeId & "\x00" & inst.address & "\x00" & readFile(f))
  else:
    result.present = false

proc mockApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  let a = TypedExtensionBox[MockAttrs](inst.attrs).val
  case action
  of rakDestroy:
    let mark = getEnv(SlowDestroyMarkEnv)
    if mark.len > 0:
      # The destroy is in progress: say so, then take long enough that a
      # concurrent consumer certainly runs inside it.
      writeFile(mark, inst.address)
      sleep(3000)
    destroyLog.add(inst.address)
    removeFile(worldFile(inst))
    ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: mockIdentity(inst), present: false)
  else:
    applyLog.add(inst.address)
    createDir(worldDir())
    writeFile(worldFile(inst), a.value)
    ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: mockIdentity(inst), postWriteDigest: mockDigest(inst),
      present: true)

proc registerMock() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "lc.mock",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: mockIdentity, digest: mockDigest,
      observe: mockObserve, apply: mockApply)))
  registerExtension[MockAttrs]("lc.mock")

proc mockState(name, value: string): ResourceInstance =
  ResourceInstance(
    typeId: "lc.mock", address: name,
    attrs: TypedExtensionBox[MockAttrs](typeId: "lc.mock",
      val: MockAttrs(value: value)),
    determinism: rdVolatile)

proc clusterGraph(): tuple[resources: seq[ResourceInstance];
                           groups: seq[StateGroupDef]] =
  result.resources = @[mockState("net", "up"), mockState("box", "up")]
  result.groups = @[StateGroupDef(name: "cluster", members: @["net", "box"])]

proc delayedLease(seconds: int64): seq[RunEdgeLease] =
  @[RunEdgeLease(address: "cluster", consumerId: "cluster",
                 policyKind: relDelayed, ttlSeconds: seconds)]

proc immediateLease(): seq[RunEdgeLease] =
  @[RunEdgeLease(address: "cluster", consumerId: "cluster",
                 policyKind: relImmediate)]

proc scratch(sub: string): string =
  result = getHomeDir() / ".cache" /
    ("repro-lease-conc-" & $getCurrentProcessId() & "-" & sub)
  removeDir(result)
  createDir(result)

# ---------------------------------------------------------------------------
# Child roles (this binary re-executed). A child exits 0 on success.
# ---------------------------------------------------------------------------

proc childRenew(root, prefix: string; count: int; keep: bool) =
  ## `count` daemon renews of the record `cluster.box` from this process.
  for j in 0 ..< count:
    let resp = applyLeaseRenew(DaemonLeaseRenewRequest(scope: dlsUser,
        address: "box",
        consumerId: (if keep: prefix else: prefix & "-" & $j),
        ttlSeconds: (if keep: LeaseRenewKeepSentinel else: 3600'i64)),
      overrideRoot = root)
    if not resp.ok or not resp.hadRecord:
      quit("renew failed: " & resp.reason, 3)

proc childConsume(root, prefix: string; count: int) =
  ## `count` complete consumes of the group through the run-edge bridge, each
  ## under its own run-edge name, from this process.
  registerMock()
  let (resources, groups) = clusterGraph()
  for j in 0 ..< count:
    var bridge = reconcileConsumedStateGroups(delayedLease(3600),
      prefix & "-" & $j, resources, groups, openStateStore(root), noArtifacts,
      endpoint = NoDaemon)
    let problems = finishConsumedStateGroups(bridge, endpoint = NoDaemon)
    if problems.len > 0:
      quit("finish failed: " & problems.join("; "), 3)

proc childSlowReap(root: string; nowUnix: int64) =
  registerMock()
  let report = reapOnce(openStateStore(root), fromUnix(nowUnix))
  echo "child reaped ", report.reaped.len, " failed ", report.failed.len

proc childConsumeAndHang(root, ready: string; t0Unix: int64) =
  registerMock()
  let (resources, groups) = clusterGraph()
  let bridge = reconcileConsumedStateGroups(delayedLease(60), "cluster-run",
    resources, groups, openStateStore(root), noArtifacts,
    endpoint = NoDaemon, now = fromUnix(t0Unix))
  doAssert bridge.holds.len == 1 and bridge.holds[0].isHeld
  writeFile(ready, "consuming")
  sleep(600_000)   # the "test" runs; the parent kills us mid-run

if existsEnv(ChildRoleEnv):
  let args = commandLineParams()
  case getEnv(ChildRoleEnv)
  of "renew":
    childRenew(args[0], args[1], parseInt(args[2]), args[3] == "keep")
  of "consume":
    childConsume(args[0], args[1], parseInt(args[2]))
  of "slow-reap":
    childSlowReap(args[0], parseBiggestInt(args[1]))
  of "consume-and-hang":
    childConsumeAndHang(args[0], args[1], parseBiggestInt(args[2]))
  else:
    quit("unknown child role", 2)
  quit(0)

proc spawnChild(role: string; args: openArray[string];
                extraEnv: openArray[(string, string)] = []): Process =
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env[ChildRoleEnv] = role
  for (k, v) in extraEnv: env[k] = v
  uncontrolledStartProcess(getAppFilename(), args = args, env = env,
    options = {poParentStreams})

proc waitFor(path: string; timeoutMs = 60_000) =
  var waited = 0
  while not fileExists(path):
    if waited >= timeoutMs:
      raise newException(IOError, "timed out waiting for " & path)
    sleep(20)
    waited += 20

# ---------------------------------------------------------------------------
# Cases.
# ---------------------------------------------------------------------------

suite "lease liveness and record updates are concurrency-safe":

  setup:
    applyLog = @[]
    destroyLog = @[]
    registerMock()

  test "(1) concurrent daemon renews of one record lose no holder, keep included":
    let base = scratch("renew")
    putEnv(WorldEnv, base / "world")
    let root = base / "state"
    let (resources, groups) = clusterGraph()
    # Materialize the state once, so there is a record to renew.
    discard reconcileConsumedStateGroups(delayedLease(3600), "seed", resources,
      groups, openStateStore(root), noArtifacts, endpoint = NoDaemon)
    const Writers = 6
    const PerWriter = 25
    var children: seq[Process] = @[]
    for i in 0 ..< Writers:
      children.add(spawnChild("renew", [root, "w" & $i, $PerWriter, "dated"]))
    # The keep holder of a state-owning shared service (D-SS5), renewing
    # alongside the dated consumers.
    children.add(spawnChild("renew", [root, "keeper", $PerWriter, "keep"]))
    # Two `repro run` consumers renewing through the bridge's in-process
    # store write, concurrently with the daemon renews.
    const Consumers = 2
    const PerConsumer = 8
    for i in 0 ..< Consumers:
      children.add(spawnChild("consume", [root, "run" & $i, $PerConsumer]))
    for p in children:
      check p.waitForExit() == 0
      p.close()
    let rec = readStateRecord(openStateStore(root), "box")
    var missing: seq[string] = @[]
    for i in 0 ..< Writers:
      for j in 0 ..< PerWriter:
        let id = "w" & $i & "-" & $j
        if not rec.holders.hasKey(id): missing.add(id)
    for i in 0 ..< Consumers:
      for j in 0 ..< PerConsumer:
        let id = "run" & $i & "-" & $j
        if not rec.holders.hasKey(id): missing.add(id)
    checkpoint("dated holders lost: " & $missing.len & " of " &
      $(Writers * PerWriter + Consumers * PerConsumer) & " " &
      missing.join(","))
    check missing.len == 0
    check "keeper" in rec.keepHolders
    check rec.effectiveDeadline.isNone          # keep dominates: never reap

  test "(2a) an in-flight consume is not reaped when its ttl lapses mid-run":
    let base = scratch("inflight")
    putEnv(WorldEnv, base / "world")
    let store = openStateStore(base / "state")
    let (resources, groups) = clusterGraph()
    let t0 = fromUnix(1_700_000_000)
    var bridge = reconcileConsumedStateGroups(delayedLease(60), "cluster-run",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    # The run-edge is still executing (a test longer than its ttl); the
    # daemon's wall-clock tick fires two hours later.
    let tEnd = t0 + initDuration(hours = 2)
    let midRun = reapOnce(store, tEnd)
    check midRun.reaped.len == 0
    check midRun.failed.len == 0                 # in use is live, not stuck
    check destroyLog.len == 0
    check fileExists(base / "world" / "box")
    # A `--force` reap does not destroy a state in use either: it is told.
    # (It does reap the run-edge's own bookkeeping record, which is no state
    # anyone consumes.)
    let forced = reapOnce(store, tEnd, force = true)
    for ev in forced.reaped:
      check ev.address notin ["net", "box"]
    check destroyLog.len == 0
    check fileExists(base / "world" / "box")
    var inUse = 0
    for f in forced.failed:
      if f.kind == rfkInUse: inc inUse
    check inUse == 2
    # The consume ends at tEnd: the deadline counts from there.
    check finishConsumedStateGroups(bridge, endpoint = NoDaemon,
      now = tEnd).len == 0
    check not bridge.holds[0].isHeld
    let rec = readStateRecord(store, "box")
    check rec.holders["cluster-run"] == tEnd + initDuration(seconds = 60)
    check reapOnce(store, tEnd + initDuration(seconds = 30)).reaped.len == 0
    check destroyLog.len == 0
    let after = reapOnce(store, tEnd + initDuration(seconds = 61))
    check after.reaped.len == 2
    check not fileExists(base / "world" / "box")

  test "(2b) an immediate consumer is not reaped before its consume ends":
    let base = scratch("immediate")
    putEnv(WorldEnv, base / "world")
    let store = openStateStore(base / "state")
    let (resources, groups) = clusterGraph()
    let t0 = fromUnix(1_700_000_000)
    var bridge = reconcileConsumedStateGroups(immediateLease(), "cluster-run",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    let midRun = reapOnce(store, t0 + initDuration(seconds = 1))
    check midRun.reaped.len == 0
    check destroyLog.len == 0
    # Once the consume ends, `immediate` is reapable at once.
    let tEnd = t0 + initDuration(minutes = 5)
    check finishConsumedStateGroups(bridge, endpoint = NoDaemon,
      now = tEnd).len == 0
    check reapOnce(store, tEnd).reaped.len == 2

  test "(2c) a consumer killed mid-run does not pin the state":
    let base = scratch("crash")
    putEnv(WorldEnv, base / "world")
    let root = base / "state"
    let t0 = fromUnix(1_700_000_000)
    let ready = base / "consuming"
    let child = spawnChild("consume-and-hang", [root, ready, $t0.toUnix])
    waitFor(ready)
    let store = openStateStore(root)
    # In flight: kept, however late the tick.
    check reapOnce(store, t0 + initDuration(hours = 2)).reaped.len == 0
    check fileExists(base / "world" / "box")
    child.kill()
    discard child.waitForExit()
    child.close()
    # Dead: its hold went with it, and the deadline stamped at the start of
    # its consume (t0 + 60s) has long lapsed.
    let after = reapOnce(store, t0 + initDuration(hours = 2))
    check after.reaped.len == 2
    check not fileExists(base / "world" / "box")

  test "(3a) a consume that starts during a reap of its state does not reuse it":
    let base = scratch("reapreuse")
    putEnv(WorldEnv, base / "world")
    let root = base / "state"
    let (resources, groups) = clusterGraph()
    let t0 = fromUnix(1_700_000_000)
    # A lapsed lease: materialized at t0 under delayed(60s), consume ended.
    var old = reconcileConsumedStateGroups(delayedLease(60), "old-run",
      resources, groups, openStateStore(root), noArtifacts,
      endpoint = NoDaemon, now = t0)
    check finishConsumedStateGroups(old, endpoint = NoDaemon, now = t0).len == 0
    let mark = base / "destroying"
    let reaper = spawnChild("slow-reap", [root, $(t0.toUnix + 3600)],
      [(SlowDestroyMarkEnv, mark)])
    waitFor(mark)
    # A new run consumes the group while the reaper is destroying it.
    applyLog = @[]
    var fresh = reconcileConsumedStateGroups(delayedLease(3600), "new-run",
      resources, groups, openStateStore(root), noArtifacts,
      endpoint = NoDaemon, now = t0 + initDuration(seconds = 3601))
    check reaper.waitForExit() == 0
    reaper.close()
    check fresh.missingGroups.len == 0
    # It waited for the reap and stood the group up again, rather than
    # "reusing" what was being destroyed.
    check "box" in applyLog
    check "net" in applyLog
    discard finishConsumedStateGroups(fresh, endpoint = NoDaemon,
      now = t0 + initDuration(seconds = 3602))
    # The state this run was handed must exist, and its record must name it.
    let store = openStateStore(root)
    for member in ["net", "box"]:
      checkpoint("member " & member)
      check fileExists(base / "world" / member)
      check hasStateRecord(store, member)

  test "(3b) a reaper whose selection went stale re-checks before destroying":
    let base = scratch("stale")
    putEnv(WorldEnv, base / "world")
    let root = base / "state"
    let store = openStateStore(root)
    let (resources, groups) = clusterGraph()
    let t0 = fromUnix(1_700_000_000)
    var bridge = reconcileConsumedStateGroups(delayedLease(60), "old-run",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    discard finishConsumedStateGroups(bridge, endpoint = NoDaemon, now = t0)
    let late = t0 + initDuration(hours = 1)
    # What a sweep's scan saw: lapsed.
    let scanned = readStateRecord(store, "box")
    check isReapable(scanned, late)
    # A renew lands after the scan (a daemon renew from another consumer).
    let resp = applyLeaseRenew(DaemonLeaseRenewRequest(scope: dlsUser,
        address: "box", consumerId: "late-renewer", ttlSeconds: 1_000_000_000),
      overrideRoot = root)
    check resp.ok and resp.hadRecord
    # The reaper acts on its stale copy: it must re-read, and keep the state.
    let attempt = reapRecord(store, inProcessTransport(), scanned, late)
    check attempt.kind == raKept
    check destroyLog.len == 0
    check fileExists(base / "world" / "box")
    check hasStateRecord(store, "box")
