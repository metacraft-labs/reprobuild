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
# Qualified-only: `std/tables` exports its own `contains`, which would shadow
# the substring one the finding assertions use.
from std/strutils import contains

import repro_resources
import repro_project_dsl            # TypedExtensionBox / StateGroupDef / RunEdgeLease
import repro_cli_support            # reconcileConsumedStateGroups (the N2 bridge)

# A deliberately unreachable daemon endpoint so ``renewLeaseBestEffort`` takes
# its no-daemon branch DETERMINISTICALLY — this dev box may have a real user
# daemon listening on the default socket, and these hermetic cases must prove
# the no-daemon correctness property (store is the source of truth) regardless.
const NoDaemon = "/nonexistent/repro-n2-no-daemon.sock"

# Every member in this file's graph is IN-TREE: the mock driver is registered in
# this process, so there is no provider binary to launch and no artifact ref to
# record. `reconcileConsumedStateGroups` takes `providerArtifacts` with no
# default precisely so a caller has to say which case it is in, rather than
# letting the production call site lose the argument silently — so saying "none,
# and here is why" is the point, not boilerplate.
let noArtifacts: seq[tuple[typeId: string;
                           artifact: ResourceProviderArtifactRef]] = @[]

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
    if a.value == "fail":
      raise newException(IOError, "mock materialization failed: " & inst.address)
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
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
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
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t1)
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
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    let delayedDeadline = readStateRecord(store, "net").effectiveDeadline
    check delayedDeadline.isSome

    # An immediate consumer of the SAME group runs next. Its now-deadline must
    # NOT shorten the delayed holder's later deadline: the reference-counted MAX
    # (keep/later-dominates) keeps the group alive until the delayed hold lapses.
    let immediateConsumer = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relImmediate, ttlSeconds: 0)]
    discard reconcileConsumedStateGroups(immediateConsumer, "immediate-holder",
      resources, groups, store, noArtifacts, endpoint = NoDaemon,
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
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
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

  test "required groups reject missing, empty, and incomplete membership":
    let store = scratchStore("missing")
    defer: removeDir(store.root)
    let (resources, _) = topologyGraph()
    let consumes = @[RunEdgeLease(address: "topology", policyKind: relDelayed,
      ttlSeconds: 1800)]
    for groups in [
        newSeq[StateGroupDef](),
        @[StateGroupDef(name: "topology", members: @[])],
        @[StateGroupDef(name: "topology", members: @["net", "missing"])]]:
      let outcome = reconcileConsumedStateGroups(consumes, "required-run",
        resources, groups, store, noArtifacts, endpoint = NoDaemon)
      check outcome.missingGroups == @["topology"]
      check outcome.reconciled.len == 0
      check outcome.renewedGroups.len == 0
      check applyLog.len == 0
    let direct = @[mockState("topology", "up")]
    check buildStateGroupDesired(consumes[0], "required-run", direct, @[]).len == 2
    check buildStateGroupDesired(consumes[0], "required-run", direct,
      @[StateGroupDef(name: "topology", members: @[])]).len == 0

  test "required out-of-tree state rejects a missing provider session":
    let store = scratchStore("provider-missing")
    defer: removeDir(store.root)
    var member = mockState("external", "up")
    member.typeId = "n2.unlinked-required-state"
    check not isResourceProviderRegistered(member.typeId)
    let groups = @[StateGroupDef(name: "external-group", members: @["external"])]
    let consumes = @[RunEdgeLease(address: "external-group",
      policyKind: relDelayed, ttlSeconds: 1800)]
    expect ValueError:
      discard reconcileConsumedStateGroups(consumes, "required-run",
        @[member], groups, store, noArtifacts, endpoint = NoDaemon)
    check applyLog.len == 0
    check not hasStateRecord(store, "external")

  test "failed required reconciliation preserves leased state for normal cleanup":
    let store = scratchStore("partial-failure")
    defer: removeDir(store.root)
    let resources = @[mockState("net", "up"), mockState("a", "fail")]
    let groups = @[StateGroupDef(name: "topology", members: @["net", "a"])]
    let consumes = @[RunEdgeLease(address: "topology", policyKind: relDelayed,
      ttlSeconds: 1800)]
    let t0 = fromUnix(1_700_000_000)
    expect IOError:
      discard reconcileConsumedStateGroups(consumes, "required-run",
        resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    check applyLog == @["net"]
    check hasStateRecord(store, "net")
    check not hasStateRecord(store, "a")
    check destroyLog.len == 0
    discard reapExpiredAtReconcileStart(store, now = t0 + initDuration(minutes = 1))
    check destroyLog.len == 0
    discard reapExpiredAtReconcileStart(store, now = t0 + initDuration(minutes = 31))
    check destroyLog == @["net"]
    check not hasStateRecord(store, "net")

  test "§4.3 fallback (a): the bridge reaps lapsed records at reconcile start":
    ## Ephemeral-State-Leases.md §4.3 promises that "every `repro` reconcile
    ## opportunistically reaps expired records at start (cheap, bounded)". This
    ## bridge IS that reconcile — the only production path that reconciles
    ## leased state against the store — and nothing called the hook, so the
    ## promise was unkept: `reapExpiredAtReconcileStart` was reached from
    ## production only through the §4.2 daemon tick
    ## (reprobuild-pm/issues/
    ## 2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md,
    ## item 3). On a host with no daemon — which is the case this fallback
    ## exists for — a lapsed record was reaped by nothing at all.
    ##
    ## NO DAEMON HERE (`NoDaemon` is an unreachable socket), so the sweep under
    ## test is the bridge's own and cannot be confused with a tick.
    let store = scratchStore("start-reap")
    defer: removeDir(store.root)
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)

    # A record from an EARLIER, unrelated run whose lease has lapsed: it is not
    # a member of the group this run consumes, so nothing else in this run
    # would touch it.
    discard reconcileResources(
      @[mockState("stale", "up"),
        ResourceInstance(
          typeId: "n2.mock", address: "stale-consumer",
          attrs: TypedExtensionBox[MockAttrs](typeId: "n2.mock",
            val: MockAttrs(value: "probe")),
          determinism: rdVolatile,
          consumes: @[leased("stale", "old-run",
            delayed(initDuration(minutes = 5)))])],
      store = some(store), now = t0)
    check hasStateRecord(store, "stale")
    check mockWorld.hasKey("mock:stale")
    applyLog = @[]
    destroyLog = @[]

    # A consuming run, well past that lease's deadline.
    let later = t0 + initDuration(minutes = 30)
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let outcome = reconcileConsumedStateGroups(consumes,
      "topology-lease-smoke", resources, groups, store, noArtifacts,
      endpoint = NoDaemon, now = later)

    # The lapsed record was destroyed BEFORE this run materialized anything,
    # and the bridge says so.
    check outcome.startReapError == ""
    check outcome.startReaped == @["stale"]
    check not hasStateRecord(store, "stale")
    check destroyLog == @["stale"]
    check not mockWorld.hasKey("mock:stale")

    # ...and this run's own work happened as before.
    check outcome.missingGroups.len == 0
    check outcome.renewedGroups == @["topology"]
    check applyLog == @["net", "a", "b"]

  test "§4.3 fallback (a) never reaps state whose lease is still LIVE":
    ## `force = false`: the start-of-reconcile sweep destroys only what the
    ## selection predicate says is due, so a state whose lease has NOT lapsed
    ## survives it — including the group this run is about to consume, when that
    ## group is still within its ttl. Reuse WITHIN the lease is the feature
    ## (§6: a re-run inside the ttl reuses the live cluster and renews), and a
    ## sweep that destroyed an unexpired state would make every consuming run
    ## rebuild from scratch.
    ##
    ## This is about LIVENESS, not about exempting the consumed addresses. A
    ## group whose lease HAS lapsed is torn down and re-materialized even though
    ## this run consumes it — that is the ttl being enforced, and it is the next
    ## case.
    let store = scratchStore("start-reap-safe")
    defer: removeDir(store.root)
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]

    # First run materializes the group under a 30m lease.
    discard reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    applyLog = @[]
    destroyLog = @[]

    # A second run INSIDE the lease: the start sweep finds the members still
    # leased and leaves them, so the reconcile REUSES them (no re-apply).
    let within = t0 + initDuration(minutes = 10)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = within)
    check second.startReapError == ""
    check second.startReaped.len == 0
    check destroyLog.len == 0
    check applyLog.len == 0                       # reused, not rebuilt
    for m in @["net", "a", "b"]:
      check hasStateRecord(store, m)

    # The synthetic run-edge consumer record carries no dated deadline, so it
    # is never-reap and the sweep must skip it rather than destroy it.
    check hasStateRecord(store, "topology-lease-smoke::consumes::topology")

  test "§4.3 fallback (a): a LAPSED group is torn down and re-materialized":
    ## THE INTENDED SEMANTICS, stated here because it reads like overreach and
    ## is not. A run at `t0 + 31min` against a 30-minute lease finds its own
    ## consumed group expired, the start sweep destroys it, and the reconcile
    ## that follows builds it again.
    ##
    ## That is the ttl doing its job, not the sweep reaching too far.
    ## `Ephemeral-State-Leases.md` §1/§6 define `delayed(ttl)` as "torn down
    ## once ttl passes with no use", and `reapExpiredAtReconcileStart`'s own
    ## contract is that a consuming run "first clears any records whose lease
    ## already lapsed". Exempting the addresses this run consumes would make the
    ## ttl unenforceable for exactly the states it governs: a run every 31
    ## minutes would keep a cluster alive forever, each run reusing a state whose
    ## lease had expired before it started. The only reason today's product
    ## appears to reuse such a state is that nothing ever reaped it.
    ##
    ## The destroy is WITNESSED by the mock driver's `destroyLog`, and the
    ## re-materialize by `applyLog`, so neither is inferred from the record
    ## alone.
    let store = scratchStore("start-reap-lapsed")
    defer: removeDir(store.root)
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]

    let first = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = t0)
    check first.startReaped.len == 0               # nothing to reap on run one
    check applyLog == @["net", "a", "b"]
    let firstDeadline = readStateRecord(store, "net").effectiveDeadline
    check firstDeadline == some(t0 + initDuration(minutes = 30))
    applyLog = @[]
    destroyLog = @[]

    # One minute PAST the lease.
    let lapsed = t0 + initDuration(minutes = 31)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, noArtifacts, endpoint = NoDaemon, now = lapsed)
    check second.startReapError == ""
    check second.startReapFindings.len == 0

    # The sweep destroyed all three members. Reverse-topo order is the L3
    # suite's subject; here the set is what matters.
    for m in @["net", "a", "b"]:
      check m in second.startReaped
      check m in destroyLog
    check second.startReaped.len == 3

    # ...and the run then RE-MATERIALIZED them, so it still succeeds and the
    # command it guards can start: a torn-down group is rebuilt, not missing.
    check second.missingGroups.len == 0
    check second.renewedGroups == @["topology"]
    check applyLog == @["net", "a", "b"]
    for m in @["net", "a", "b"]:
      check hasStateRecord(store, m)
      check mockWorld.hasKey("mock:" & m)

    # The records are this run's, under a fresh lease measured from `lapsed`.
    check readStateRecord(store, "net").effectiveDeadline ==
      some(lapsed + initDuration(minutes = 30))

  test "§4.4: the start sweep's findings reach the caller, not just the store":
    ## `reapOnce` QUARANTINES a corrupt record as a side effect of scanning, so
    ## a sweep whose report is discarded moves a record aside and LOSES the
    ## finding §4.4 requires: the bytes are preserved but nothing says the
    ## resource that record described may now be leaked with nothing naming its
    ## address. `reapOnce`'s own docstring forbids exactly that, and the §4.3
    ## (a) sweep this bridge runs is a sweep nobody else reports for — there is
    ## no daemon log behind it.
    ##
    ## So the bridge carries the rendered findings out on `startReapFindings`,
    ## and `runReproRunCommand` prints them. This case pins the carrying; the
    ## PRINTING is pinned end-to-end by
    ## `tests/e2e/local-build-engine/t_e2e_repro_run_named_run_edge.nim`
    ## ("a consumed out-of-tree group records its provider artifact end to
    ## end"), which drives the real `repro run`.
    ##
    ## NON-VACUITY: the only prior assertion on this field was
    ## `startReapFindings.len == 0`, which stays true if the population is
    ## deleted outright. This asserts a finding ARRIVES and names the record.
    let store = scratchStore("start-reap-findings")
    defer: removeDir(store.root)
    let (resources, groups) = topologyGraph()
    let t0 = fromUnix(1_700_000_000)
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]

    # A genuinely undecodable record, written as raw bytes the way a torn write
    # or a truncated `.rec` leaves one. Nothing is stubbed to fail.
    writeFile(store.root / "corrupt-member.rec", "\x00\x01\x02 not a record")

    let outcome = reconcileConsumedStateGroups(consumes,
      "topology-lease-smoke", resources, groups, store, noArtifacts,
      endpoint = NoDaemon, now = t0)

    # The sweep quarantined it — the record left the store root...
    check not fileExists(store.root / "corrupt-member.rec")
    check dirExists(store.root / "quarantine")
    # ...and SAID SO through the bridge, naming the file. Without this the move
    # would be silent and the operator would never learn the resource it
    # described may be leaked.
    check outcome.startReapFindings.len == 1
    let finding = outcome.startReapFindings[0]
    check finding.contains("quarantined")
    check finding.contains("corrupt-member.rec")
    # The sweep itself did not fail: a corrupt record is a per-record finding,
    # not a sweep failure (§4.4), so the run proceeds normally.
    check outcome.startReapError == ""
    check outcome.missingGroups.len == 0
    check outcome.renewedGroups == @["topology"]
    check applyLog == @["net", "a", "b"]

    # A HEALTHY sweep reports nothing, so a finding is a signal rather than
    # noise every run emits.
    let clean = scratchStore("start-reap-findings-clean")
    defer: removeDir(clean.root)
    applyLog = @[]
    let quiet = reconcileConsumedStateGroups(consumes,
      "topology-lease-smoke", resources, groups, clean, noArtifacts,
      endpoint = NoDaemon, now = t0)
    check quiet.startReapFindings.len == 0
    check quiet.startReapError == ""
