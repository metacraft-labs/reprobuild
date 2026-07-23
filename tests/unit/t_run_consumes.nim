## Named-Runnable-Edges N2 (Named-Runnable-Edges.md §3.2) — the leased-consumes
## bridge, hermetic.
##
## These cases drive the CLI bridge proc ``reconcileConsumedStateGroups``
## directly over an IN-TREE MOCK resource provider (no Incus), mirroring the L3
## reaper tests' stub-with-a-witness-log pattern. The mock's ``apply`` appends
## to a MATERIALIZE WITNESS LOG so a test proves EXACTLY when a group's members
## are (re)materialized vs REUSED — the created-at witness the milestone calls
## for. There is no daemon, so ``renewLeaseBestEffort`` takes its no-daemon
## branch (``sent == false``) and the on-disk L1 store is the source of truth,
## exactly as the spec's no-daemon correctness property requires.
##
## Verifies the three N2 milestone gates:
##   * t_run_consumes_materialize_then_reuse
##   * t_run_consumes_refcount_immediate_vs_delayed
##   * t_run_consumes_no_daemon_reap

import std/[tables, options, times, os, unittest]

import repro_resources
import repro_project_dsl            # TypedExtensionBox / StateGroupDef / RunEdgeLease
import repro_cli_support            # reconcileConsumedStateGroups (the N2 bridge)

# A deliberately unreachable daemon endpoint so ``renewLeaseBestEffort`` takes
# its no-daemon branch DETERMINISTICALLY — this dev box may have a real user
# daemon listening on the default socket, and these hermetic cases must prove
# the no-daemon correctness property (store is the source of truth) regardless.
const NoDaemon = "/nonexistent/repro-n2-no-daemon.sock"

# ---------------------------------------------------------------------------
# Mock provider with a MATERIALIZE WITNESS LOG (the L3 stub shape).
# ---------------------------------------------------------------------------

type
  MockAttrs = object
    value: string

var mockWorld {.threadvar.}: Table[string, string]   ## resourceId -> realized value
var applyLog {.threadvar.}: seq[string]               ## addresses (re)materialized, in order
var destroyLog {.threadvar.}: seq[string]             ## addresses destroyed, in order

proc mockIdentity(inst: ResourceInstance): string =
  "mock:" & inst.address

proc mockDigest(inst: ResourceInstance): Digest256 =
  let a = TypedExtensionBox[MockAttrs](inst.attrs).val
  digestString(inst.typeId & "\x00" & inst.address & "\x00" & a.value)

proc mockObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  let id = mockIdentity(inst)
  if mockWorld.hasKey(id):
    result.present = true
    result.digest = digestString(
      inst.typeId & "\x00" & inst.address & "\x00" & mockWorld[id])
  else:
    result.present = false

proc mockApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
  let id = mockIdentity(inst)
  let a = TypedExtensionBox[MockAttrs](inst.attrs).val
  case action
  of rakDestroy:
    destroyLog.add(inst.address)
    mockWorld.del(id)
    result = ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: id, present: false)
  else:
    applyLog.add(inst.address)            # <-- the materialize witness
    mockWorld[id] = a.value
    result = ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: id, postWriteDigest: mockDigest(inst), present: true)

proc registerMock() =
  registerResourceProvider(ResourceProviderDef(
    typeId: "n2.mock",
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: mockIdentity, digest: mockDigest,
      observe: mockObserve, apply: mockApply)))
  registerExtension[MockAttrs]("n2.mock")

proc mockState(name, value: string): ResourceInstance =
  ResourceInstance(
    typeId: "n2.mock", address: name,
    attrs: TypedExtensionBox[MockAttrs](typeId: "n2.mock",
      val: MockAttrs(value: value)),
    determinism: rdVolatile)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-n2-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

# The topology-shaped bounded slice: 1 network + 2 containers, as a stateGroup.
proc topologyGraph(): tuple[resources: seq[ResourceInstance];
                            groups: seq[StateGroupDef]] =
  result.resources = @[
    mockState("net", "up"),
    mockState("a", "up"),
    mockState("b", "up")]
  result.groups = @[StateGroupDef(name: "topology",
    members: @["net", "a", "b"])]

suite "N2: leased-consumes bridge (hermetic)":

  setup:
    mockWorld = initTable[string, string]()
    applyLog = @[]
    destroyLog = @[]
    registerMock()

  test "t_run_consumes_materialize_then_reuse":
    let store = scratchStore("reuse")
    let (resources, groups) = topologyGraph()
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let t0 = fromUnix(1_700_000_000)

    # First run: the group is materialized (all three members applied) and the
    # store records the lease held by the run-edge's stable name.
    let first = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, endpoint = NoDaemon, now = t0)
    check first.missingGroups.len == 0
    check first.renewedGroups == @["topology"]
    check applyLog == @["net", "a", "b"]
    for m in @["net", "a", "b"]:
      check hasStateRecord(store, m)
    let firstDeadline = readStateRecord(store, "net").effectiveDeadline
    check firstDeadline.isSome
    check firstDeadline.get == t0 + initDuration(minutes = 30)

    # Second run WITHIN ttl: the store's present+digest-matching records make
    # the reconciler REUSE the group — no member is re-applied (the witness log
    # stays stable) — and the lease is RENEWED (deadline advances).
    let applyBefore = applyLog
    let t1 = t0 + initDuration(minutes = 10)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, endpoint = NoDaemon, now = t1)
    check second.renewedGroups == @["topology"]
    check applyLog == applyBefore                 # NO re-materialize
    let secondDeadline = readStateRecord(store, "net").effectiveDeadline
    check secondDeadline.isSome
    check secondDeadline.get == t1 + initDuration(minutes = 30)
    check secondDeadline.get > firstDeadline.get  # renew advanced the deadline
    # No daemon in this hermetic run: the renew took its no-daemon branch.
    check second.daemonSent.len == 0

  test "t_run_consumes_refcount_immediate_vs_delayed":
    let store = scratchStore("refcount")
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)

    # A delayed(30m) consumer holds the group first.
    let delayedConsumer = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    discard reconcileConsumedStateGroups(delayedConsumer, "delayed-holder",
      resources, groups, store, endpoint = NoDaemon, now = t0)
    let delayedDeadline = readStateRecord(store, "net").effectiveDeadline
    check delayedDeadline.isSome

    # An immediate consumer of the SAME group runs next. Its now-deadline must
    # NOT shorten the delayed holder's later deadline: the reference-counted MAX
    # (keep/later-dominates) keeps the group alive until the delayed hold lapses.
    let immediateConsumer = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relImmediate, ttlSeconds: 0)]
    discard reconcileConsumedStateGroups(immediateConsumer, "immediate-holder",
      resources, groups, store, endpoint = NoDaemon,
      now = t0 + initDuration(minutes = 1))

    let rec = readStateRecord(store, "net")
    check rec.effectiveDeadline.isSome
    # The effective deadline is the delayed holder's (t0 + 30m), NOT the
    # immediate holder's now-deadline — the immediate run did not yank it.
    check rec.effectiveDeadline.get == t0 + initDuration(minutes = 30)

    # Prove the group SURVIVES the immediate run: a reap sweep right after the
    # immediate consume (well before the delayed deadline) reaps nothing.
    let report = reapExpiredAtReconcileStart(store,
      now = t0 + initDuration(minutes = 2))
    check destroyLog.len == 0
    for m in @["net", "a", "b"]:
      check hasStateRecord(store, m)

  test "t_run_consumes_no_daemon_reap":
    let store = scratchStore("noreap")
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)

    # With NO daemon, a consuming run materializes + (would) run.
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let outcome = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, endpoint = NoDaemon, now = t0)
    check outcome.renewedGroups == @["topology"]
    check outcome.daemonSent.len == 0             # no daemon reached
    for m in @["net", "a", "b"]:
      check hasStateRecord(store, m)

    # AFTER the deadline, the opportunistic reconcile-start reap (equivalently
    # ``repro reap``) tears the group down — correctness independent of any
    # daemon. Reverse-topo order is proven by the L3 suite; here we assert the
    # group is fully destroyed and the store residue is clean.
    let later = t0 + initDuration(minutes = 30) + initDuration(minutes = 1)
    let report = reapExpiredAtReconcileStart(store, now = later)
    for m in @["net", "a", "b"]:
      check not hasStateRecord(store, m)
    check destroyLog.len == 3
    # The synthetic run-edge consumer record (never-reap) is untouched — it
    # carries no dated deadline, so it is skipped, not destroyed.
    check hasStateRecord(store, "topology-lease-smoke::consumes::topology")
