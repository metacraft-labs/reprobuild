## Shared-Development-Services L7 (§4.5) — THE REGISTRY OF RUNNING
## INSTANCES: `repro up` converges in any order on one instance with one
## holder per consuming project, `repro down` drops one reference without
## stopping what another project is using, and a restarted daemon rebuilds
## the registry from the on-disk lease records without orphaning or
## double-starting.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Specifically:
##
## * every interface snapshot comes from a real `package` block in
##   `l6_attach_fixtures.nim`, expanded by the real DSL macro and lifted
##   by the real `toProjectInterface`;
## * every instance key comes from the real `serviceInstanceKey` over the
##   fixture's own declared identity and scope;
## * every holder goes through the real `deadlineFrom` and every persisted
##   record through the real `mergeHolderDeadlines` into a real
##   `StateStore` on a real filesystem under a throwaway root;
## * every instance is a REAL detached child process, started by the real
##   `materialiseServiceInstanceProcess` the daemon calls and stopped by
##   the real `stopServiceInstanceProcess`;
## * the process-liveness probe is the real
##   `repro_daemon_core/writer_identity.writerLiveness`, reached through
##   the real `serviceInstanceLivenessProbe` the daemon installs.
##
## TWO CONSTRUCTED VALUES ARE USED, BOTH NAMED HERE BECAUSE THE POLICY
## ABOVE SAYS SO, AND NEITHER IS A DOUBLE OF ANYTHING:
##
## * the undecodable-record cases (the rebuild's and the sweep's) write a
##   `ResourceStateRecord` whose `attrsTypeId` is a version this build
##   does not read. That is the record a FUTURE build writes; there is no
##   other way to have one, and the record goes into a real `StateStore`
##   through the real `writeStateRecord`.
## * the recycled-pid case takes the real identity of a real live child
##   and replaces its START STAMP with the previous tick. That is exactly
##   the record a process that held the same pid a moment earlier leaves
##   behind, and it is the only way to produce one deterministically —
##   the kernel does not let a test choose which pid it is handed. The
##   bootId, the pid and the child are all real, and the substituted
##   value is one field, which is the same technique (and the same
##   justification) `keyFor`'s `stableId` substitution already carries.
##
## THE ONE INJECTED FUNCTION IS NOT A SEAM FOR A DOUBLE.
## `ServiceInstanceRegistry.probe` exists because `writerLiveness` lives
## in `repro_daemon_core`, which DEPENDS ON `repro_resources` — so
## `service_registry.nim` cannot import it without a library cycle. This
## file installs the real one, which is the only one that exists.
##
## WHAT IS NOT EXERCISED HERE, AND WHERE IT IS. The daemon's SOCKET and
## the `repro up` / `repro down` CLI are driven end to end by
## `tests/integration/t_l7_repro_up_converges_on_one_shared_instance.nim`
## — a real `repro-daemon`, a real control-API socket, three real project
## directories and the real CLI. This file is the registry's own gate: it
## runs the same policy functions the daemon's handler bodies call, with
## the same real store and the same real processes, and it can enumerate
## ALL SIX orders of three consumers in seconds where the CLI path cannot.
## Both are required; neither substitutes for the other.
##
## Governing text — `Shared-Development-Services.md` §4.5 in full, and in
## particular its three numbered rules about a restarted daemon.

import std/[algorithm, options, os, osproc, sequtils, strutils, tables,
    times, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_resources
import repro_resources/service_attach
import repro_resources/service_identity
import repro_resources/service_registry

# The REAL daemon-side half: the liveness probe, the materialiser and the
# stop. Imported rather than reimplemented so this file measures the code
# the daemon runs.
import repro_daemon_core/instance_registry
import repro_daemon_core/writer_identity

import ./l6_attach_fixtures

# ---------------------------------------------------------------------------
# Snapshots and keys, from the real lift. These four helpers are the same
# ones `t_l6_attach_decision_has_three_outcomes.nim` uses and for the same
# reasons; they are duplicated rather than shared because the L6 file
# keeps them private, and copying four short projections is cheaper than
# widening that file's surface for this one.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# §4.3's SAME-GENERATION PRECONDITION, as this suite supplies it.
#
# `convergeServiceInstance` gained a REQUIRED `generation` argument when
# §4.3's stale-lift precondition was implemented, and every call in this
# file passes `sagFresh` through this one named helper.
#
# IT IS NOT A MOCK AND THE SUITE'S MOCK POLICY IS UNCHANGED. There is
# nothing to mock: `ServiceArtifactGenerationCheck` is a plain record of
# an answer already established, `attachDecision` is a pure function of
# it, and no filesystem probe is stubbed out or replaced. What this suite
# measures is the registry's handling of §4.5's converge and §4.3's three
# ROW outcomes; the two PRECONDITION outcomes are measured where they
# belong, in `t_l6_attach_refuses_a_stale_lift.nim`, against a REAL
# recorded provenance stamp and a REAL recipe closure on disk.
#
# `sagFresh` is correct for these cases rather than convenient: each
# constructs its running instance and its requested snapshot from ONE
# lift of one fixture package in this process, so the two sides are
# same-generation by construction. Passing anything else would make
# every case here refuse before reaching the branch it exists to test --
# which is exactly what the mutation "collapse the precondition into an
# unconditional refusal" does, and is why that mutation reddens this
# file too.
# ---------------------------------------------------------------------------

proc freshLiftForThisSuite(): ServiceArtifactGenerationCheck =
  freshLiftGeneration(artifactPath = "<constructed in-process>",
    ownerPackage = "l6_attach_fixtures", ownerProject = "l6_attach_fixtures",
    identity = "same-generation-by-construction")

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc normalisedInterface(name: string): ProjectInterface =
  ## The lifted interface with every PACKAGE-DERIVED HANDLE TYPE replaced
  ## by a constant. The artifice being undone is the one L3/L4/L6's lift
  ## fixtures undo: the scenario is ONE package edited between two
  ## revisions, the fixtures cannot share a name inside one module, and
  ## the handle type is derived from the package name — so without this
  ## every pair would differ on `handleType` and the §4.3 control would
  ## fail for a reason that has nothing to do with the implementation.
  result = toProjectInterface(packageDefNamed(name))
  for act in result.publicActivities.mitems:
    act.handleType = "NormalisedHandle_" & act.name
  for svc in result.publicServices.mitems:
    if svc.handleType.len > 0:
      svc.handleType = "NormalisedHandle_" & svc.activityName

proc snapshotOf(package: string; service = "zitadel"):
    ServiceInterfaceSnapshot =
  serviceInterfaceSnapshot(normalisedInterface(package), service)

proc declaredDefFromLift(package, service: string): DslServiceDef =
  ## The declared identity and scope of a lifted service, in the shape
  ## `serviceInstanceKey` takes. A `service` inside `devEnv: activity …:`
  ## lowers into the generated activity proc, so it is registered when
  ## the activity is ENABLED rather than at module init; the DECLARATION
  ## is nonetheless real and complete on the lifted row, and L6's own
  ## suite checks this projection against a real lowered record.
  let pi = normalisedInterface(package)
  for svc in pi.publicServices:
    if svc.name != service:
      continue
    return DslServiceDef(
      packageName: package, serviceName: svc.name,
      identity: ServiceIdentityDef(
        kind: ServiceIdentityKind(ord(svc.identityMode)),
        stableId: svc.identityStableId),
      scope: ServiceScope(ord(svc.scope)))
  raise newException(ValueError,
    "fixture drift: " & package & " lifts no service " & service)

var caseCounter = 0

proc throwawayRoot(label: string): string =
  ## A throwaway directory, never `.repro/` and never a live tree — the
  ## campaign's working-agreement guardrail for every instance-identity
  ## experiment.
  caseCounter.inc
  result = getTempDir() / ("repro-l7-" & $getCurrentProcessId() & "-" &
    $caseCounter & "-" & label)
  createDir(result)

proc scopeContext(root: string; workspaceId = "l7-workspace"):
    ServiceScopeContext =
  ## `workspaceId` is supplied because the fixtures declare `scope
  ## workspace`: without it `resolveServiceScope` correctly DEGRADES to
  ## `project` and reports it, and the address would be a project-scoped
  ## one — which would make this file measure the degradation rather than
  ## the registry.
  ServiceScopeContext(projectRoot: canonicalRoot(root),
    workspaceRoot: canonicalRoot(root), workspaceId: workspaceId,
    user: "l7tester")

proc keyFor(package: string; root: string; environment = "dev";
            workspaceId = "l7-workspace"; service = "zitadel";
            stableId = ""): ServiceInstanceKey =
  ## `stableId`, when given, REPLACES the fixture's declared identifier
  ## and nothing else.
  ##
  ## It exists because every `zitadel` fixture in `l6_attach_fixtures.nim`
  ## declares the SAME `identity stable "com.example.l6.sso"` -- measured
  ## while writing this file: `l6AttUndeclaredA`'s address and
  ## `l6AttBase`'s are byte-identical, which is correct for L6 (whose
  ## subject is the interface, not the key) and useless for asserting
  ## that two identities are two instances. The substitution goes through
  ## the real `serviceInstanceKey` over a real `ServiceIdentityDef`, so
  ## nothing about the derivation is faked; what is substituted is one
  ## author-chosen string, which is exactly what an author would change.
  var def = declaredDefFromLift(package, service)
  if stableId.len > 0:
    def.identity = ServiceIdentityDef(kind: sikStable, stableId: stableId)
  serviceInstanceKey(def, scopeContext(root, workspaceId), [], environment)

# ---------------------------------------------------------------------------
# Real instances: real detached child processes.
# ---------------------------------------------------------------------------

proc instanceCommand(): seq[string] =
  ## A process that really runs until it is really signalled. `sh` is
  ## used rather than this binary re-executing itself because the
  ## instance has to be something the registry treats as opaque argv,
  ## which is what a declared service is.
  @["sh", "-c", "while :; do sleep 1; done"]

var spawned: seq[ServiceInstanceProcess] = @[]

proc materialise(workingDir: string): ServiceInstanceProcess =
  ## Through the REAL daemon materialiser, and recorded so the teardown
  ## below can reap anything a failing case leaves behind. A leaked
  ## `sleep` loop would outlive the suite.
  # The output log goes beside the throwaway working directory: these
  # cases address no `serviceStateRoot`, and §4.5 only requires that the
  # output land in a file.
  let started = materialiseServiceInstanceProcess(instanceCommand(),
    workingDir, workingDir / ServiceInstanceOutputLogName)
  doAssert not started.exitedEarly,
    "fixture instance died during its start grace window: " &
    describeEarlyServiceInstanceExit(started, "<fixture>")
  result = started.process
  spawned.add(result)

proc reapEverySpawnedInstance() =
  for process in spawned:
    discard stopServiceInstanceProcess(process, graceMs = 1500)
  spawned.setLen(0)

proc livenessOf(process: ServiceInstanceProcess): ServiceInstanceLiveness =
  serviceInstanceLivenessProbe()(process.processIdentity)

proc aliveInProcfs(process: ServiceInstanceProcess): bool =
  ## THE OS's ANSWER, NOT THE REAPER'S. A sweep that reported a reap and
  ## left the process running would pass any assertion made against its
  ## own report, so "the instance is stopped" is read from the process
  ## table instead.
  ##
  ## On Linux that is `/proc/<pid>`, which disappears only once the
  ## process has exited AND been waited on — so this also witnesses the
  ## zombie reap, which a bare "did it exit" check would not.
  when defined(linux):
    dirExists("/proc/" & $process.pid)
  else:
    livenessOf(process) != silDead

proc goneFromProcfs(process: ServiceInstanceProcess;
                    timeoutMs = 5000): bool =
  ## `aliveInProcfs` with a bounded wait, because a SIGTERM the service
  ## honours is not instantaneous. Returns as soon as it is gone, so a
  ## passing case does not pay the timeout.
  var waited = 0
  while waited < timeoutMs:
    if not aliveInProcfs(process):
      return true
    sleep(25)
    waited.inc(25)
  not aliveInProcfs(process)

proc lapsedInstanceRecordWith(address, attrsTypeId, attrsJson: string;
                              lapsedAt: Time): ResourceStateRecord =
  ## An instance record the sweep WILL select: a dated holder whose
  ## deadline is in the past, folded by the REAL `mergeHolderDeadlines`
  ## so the record's `holders` map and `effectiveDeadline` are the ones
  ## the registry's own write funnel would have produced.
  let merged = mergeHolderDeadlines(none(ResourceStateRecord),
    holderRenewals(address,
      @[ServiceInstanceHolder(consumerId: "holder:lapsed",
        deadline: some(lapsedAt))], lapsedAt), lapsedAt)
  ResourceStateRecord(address: address, typeId: ServiceInstanceTypeId,
    determinism: rdVolatile, attrsTypeId: attrsTypeId,
    attrsJson: attrsJson, dependsOn: @[], identity: "x", present: true,
    holders: merged.holders, keepHolders: merged.keepHolders,
    keepHoldersKnown: merged.keepHoldersKnown,
    effectiveDeadline: merged.effective,
    lastRenewed: lapsedAt)

# ---------------------------------------------------------------------------
# Registry helpers.
# ---------------------------------------------------------------------------

proc freshRegistry(storeRoot: string): ServiceInstanceRegistry =
  openServiceInstanceRegistry(storeRoot, serviceInstanceLivenessProbe())

proc holderNames(registry: ServiceInstanceRegistry;
                 key: ServiceInstanceKey): seq[string] =
  result = @[]
  let entry = registry.lookupServiceInstance(key)
  if entry.isNone:
    return
  for holder in entry.get.instance.holders:
    result.add(holder.consumerId)
  result.sort()

proc convergeOne(registry: var ServiceInstanceRegistry;
                 key: ServiceInstanceKey;
                 package, holderId, workingDir: string;
                 policy: LeasePolicy = keep();
                 replace = false; force = false;
                 now = getTime()): ServiceConvergeDecision =
  ## The two steps `applyServiceConverge` performs: decide, and — on
  ## `scoMaterialise` — start the instance and register it. Split in the
  ## library for the reason `recordMaterialisedInstance`'s comment gives
  ## (the process does not exist when the decision is made), so a caller
  ## that wants both does both.
  result = convergeServiceInstance(registry, key, snapshotOf(package),
    holderId, freshLiftForThisSuite(), policy, now,
    replace = replace, force = force)
  if result.outcome == scoMaterialise:
    discard recordMaterialisedInstance(registry, key, snapshotOf(package),
      materialise(workingDir), holderId, policy, now)

proc holderIdFor(label: string): string =
  ## Three DIFFERENT consuming project roots, which is what §4.5's "one
  ## holder per consuming project" counts. The roots are real
  ## directories so `serviceLeaseHolderId`'s canonicalisation is the real
  ## one.
  let root = throwawayRoot("consumer-" & label)
  serviceLeaseHolderId(root)

suite "L7 §4.5 — `repro up` converges on ONE instance in any order":
  teardown:
    # AFTER EVERY CASE, INCLUDING ONE THAT ABORTED -- and the measured
    # scope of that is NARROWER than the obvious reading, which is said
    # here rather than left implicit because an overstated comment in
    # this same file is one of the things this edit is fixing.
    #
    # `unittest`'s `teardown` runs on the way out of each `test` body
    # whether the body completed or raised. The explicit call at the END
    # of each body -- which is how this file was written, 17 times --
    # does not run when the body aborts before reaching it.
    #
    # BUT A BARE `check` DOES NOT ABORT A BODY. `abortOnError` is false
    # by default, so a failed `check` is recorded and execution CONTINUES
    # to the end-of-body reap. Measured on a two-case probe: a body whose
    # first statement is a failing `check` still executes the statement
    # after it, and the teardown still runs. Aborting takes an exception
    # or `require`.
    #
    # AND `spawned` IS A MODULE-LEVEL GLOBAL, so the end-of-body reap of
    # the next case that performs one absorbs whatever an aborted earlier
    # case left in it; the module-scope sweep on the last line catches
    # the remainder before the process exits.
    #
    # SO WHAT THE `teardown` BUYS, EXACTLY: when the aborted case is the
    # LAST one that would have reaped, its `sleep` loop survives into the
    # rest of the run. That is the fixture it was measured in -- a
    # failure injected into the last reaping case with the module-scope
    # sweep removed -- where teardowns removed left 1 leaked process and
    # teardowns present left 0. Narrower than "a failing case leaks", and
    # it is what was measured.
    #
    # The sibling `t_dss11_converge_response_carries_the_instances_points`
    # was fixed this way first; this is the same fix, applied to every
    # suite in this file rather than only to the ones that spawn today,
    # so a case added to a currently process-free suite cannot reopen
    # the leak. The reap is idempotent (it clears `spawned`), so the
    # existing end-of-body calls are left in place -- including the one
    # inside the permutation loop of the first case, which reaps PER
    # ITERATION and which a `teardown` could not replace.
    reapEverySpawnedInstance()

  test "all six orders of three consumers end with one instance and three holders":
    ## THE GATE'S HEADLINE CLAUSE: "`repro up` run in three project
    ## directories of one workspace in **each of several orders**, every
    ## order ending with exactly one instance and three holders".
    ##
    ## All six permutations rather than "several", because six is the
    ## whole space for three consumers and enumerating it costs nothing
    ## here. The holder ids are three real, distinct project roots; the
    ## KEY is one, because identity and scope are the fixture's and
    ## neither is derived from a consumer's path.
    var orders: seq[seq[int]] = @[]
    var indices = @[0, 1, 2]
    indices.sort()
    while true:
      orders.add(indices)
      if not indices.nextPermutation():
        break
    check orders.len == 6
    for order in orders:
      let storeRoot = throwawayRoot("order-" & order.mapIt($it).join(""))
      let keyRoot = throwawayRoot("keyroot")
      let key = keyFor("l6AttBase", keyRoot)
      var registry = freshRegistry(storeRoot)
      var holders: seq[string] = @[]
      for i in 0 .. 2:
        holders.add(holderIdFor($order[i]))
      var materialised = 0
      var attached = 0
      for i in 0 .. 2:
        let decision = convergeOne(registry, key, "l6AttBase",
          holders[order.find(order[i])], keyRoot)
        if decision.outcome == scoMaterialise: materialised.inc
        elif convergeAttached(decision.outcome): attached.inc
        else:
          checkpoint("unexpected outcome " & outcomeWord(decision.outcome) &
            ": " & decision.diagnostic)
          fail()
      # EXACTLY ONE materialisation across the three converges, in every
      # order. This is the clause that separates "converge" from "start":
      # a design that started per consumer would report three.
      check materialised == 1
      check attached == 2
      check registry.registeredServiceInstances().len == 1
      var expected = holders
      expected.sort()
      check registry.holderNames(key) == expected
      check registry.registeredServiceInstances()[0].record.address ==
        serviceInstanceAddress(key)
      reapEverySpawnedInstance()

  test "a second converge from the SAME project renews rather than adding a holder":
    ## The negative control for the holder count: `repro up` twice in one
    ## project is one holder, not two. §4.5 is "one holder per consuming
    ## project", and a registry that appended would make the instance
    ## unreleasable — the project would have to run `repro down` as many
    ## times as it ran `repro up`.
    let storeRoot = throwawayRoot("renew-store")
    let keyRoot = throwawayRoot("renew-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let holder = holderIdFor("solo")
    check convergeOne(registry, key, "l6AttBase", holder,
      keyRoot).outcome == scoMaterialise
    check convergeAttached(convergeOne(registry, key, "l6AttBase", holder,
      keyRoot).outcome)
    check registry.holderNames(key) == @[holder]
    check registry.registeredServiceInstances().len == 1
    reapEverySpawnedInstance()

suite "L7 §4.5 — `repro down` drops ONE reference":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "a release with other holders leaves the instance running; the last one releases it":
    ## The gate's two middle clauses: "`repro down` in one project
    ## leaving the instance running for the other two and dropping only
    ## its own holder; the last `repro down` releasing it".
    let storeRoot = throwawayRoot("release-store")
    let keyRoot = throwawayRoot("release-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let a = holderIdFor("a")
    let b = holderIdFor("b")
    let c = holderIdFor("c")
    for holder in [a, b, c]:
      discard convergeOne(registry, key, "l6AttBase", holder, keyRoot)
    let instanceProcess =
      registry.lookupServiceInstance(key).get.record.process
    check livenessOf(instanceProcess) == silLive

    let first = releaseServiceInstance(registry, key, a)
    check first.outcome == srlDroppedHolder
    check first.diagnostic == ""
    check first.remainingHolders == sorted(@[b, c])
    # The instance is STILL REGISTERED and STILL RUNNING: a release that
    # stopped it here would take it away from two projects using it,
    # which is the behaviour §4.5 exists to replace.
    check registry.registeredServiceInstances().len == 1
    check livenessOf(instanceProcess) == silLive

    let second = releaseServiceInstance(registry, key, b)
    check second.outcome == srlDroppedHolder
    check second.remainingHolders == @[c]
    check livenessOf(instanceProcess) == silLive

    let last = releaseServiceInstance(registry, key, c)
    check last.outcome == srlReleasedLastHolder
    check last.remainingHolders.len == 0
    # The record is deliberately NOT removed by the decision: the caller
    # stops the process first, so a failed stop leaves a registered
    # instance rather than a process nothing names.
    check registry.registeredServiceInstances().len == 1
    let stop = stopServiceInstanceProcess(last.record.process, graceMs = 2000)
    check stop.stopped
    registry.forgetServiceInstance(last.address)
    check registry.registeredServiceInstances().len == 0
    check livenessOf(instanceProcess) == silDead
    # And the record really is gone from the store, so a rebuild finds
    # nothing rather than an instance that is not there.
    check not hasStateRecord(openStateStore(storeRoot),
      serviceInstanceAddress(key))
    reapEverySpawnedInstance()

  test "releasing a holder that never held drops nothing and names the holders":
    let storeRoot = throwawayRoot("notheld-store")
    let keyRoot = throwawayRoot("notheld-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let a = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", a, keyRoot,
      policy = delayed(hours = 1))
    let stranger = holderIdFor("stranger")
    let decision = releaseServiceInstance(registry, key, stranger)
    check decision.outcome == srlNotHeld
    check decision.diagnostic.contains(stranger)
    check decision.diagnostic.contains(a)
    check registry.holderNames(key) == @[a]
    reapEverySpawnedInstance()

  test "releasing at a key with no instance is reported, not silently accepted":
    let storeRoot = throwawayRoot("noinstance-store")
    let keyRoot = throwawayRoot("noinstance-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let decision = releaseServiceInstance(registry, key, holderIdFor("a"))
    check decision.outcome == srlNoInstance
    check decision.diagnostic.contains(serviceInstanceAddress(key))
    check decision.diagnostic.contains("Nothing was stopped")

suite "L7 §4.5 — a restarted daemon rebuilds the registry from the store":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "dated holders are recovered in full, with no orphan and no second start":
    ## The gate's last clause: "a daemon restart recovering the registry
    ## from the on-disk store without orphaning or double-starting".
    ##
    ## DATED holders, because they are the ones the record can carry. The
    ## `keep` default's lossy case is the next suite, and it is a REFUSAL
    ## rather than a recovery — §4.5 rule 1.
    let storeRoot = throwawayRoot("restart-store")
    let keyRoot = throwawayRoot("restart-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var holders: seq[string] = @[]
    var beforePid = 0
    block firstDaemon:
      var registry = freshRegistry(storeRoot)
      for label in ["a", "b", "c"]:
        let holder = holderIdFor(label)
        holders.add(holder)
        discard convergeOne(registry, key, "l6AttBase", holder, keyRoot,
          policy = delayed(hours = 2))
      beforePid = registry.lookupServiceInstance(key).get.record.process.pid
      check registry.holderNames(key) == sorted(holders)
    # THE RESTART. A brand-new registry object over the same store root
    # with the same real probe: nothing is carried over in memory.
    let reopened = openServiceInstanceRegistryReporting(storeRoot,
      serviceInstanceLivenessProbe())
    var registry = reopened.registry
    check reopened.report.recovered == 1
    check reopened.report.droppedDead == 0
    check reopened.report.skipped == 0
    check reopened.report.unnamedKeepHolderRisks == 0
    check registry.registeredServiceInstances().len == 1
    let entry = registry.lookupServiceInstance(key).get
    check entry.holderRecovery == hrTotal
    check registry.holderNames(key) == sorted(holders)
    # NO DOUBLE-START: the recovered instance is the same process, and
    # the rebuild started nothing (one entry, the original pid).
    check entry.record.process.pid == beforePid
    check entry.liveness == silLive
    # NO ORPHAN: the process the record names is the one that is running,
    # and a converge after the restart ATTACHES to it rather than
    # materialising a second one.
    let after = convergeOne(registry, key, "l6AttBase",
      holderIdFor("d"), keyRoot, policy = delayed(hours = 2))
    check convergeAttached(after.outcome)
    check registry.lookupServiceInstance(key).get.record.process.pid ==
      beforePid
    check registry.holderNames(key).len == 4
    reapEverySpawnedInstance()

  test "the rebuild is idempotent":
    let storeRoot = throwawayRoot("idempotent-store")
    let keyRoot = throwawayRoot("idempotent-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    discard convergeOne(registry, key, "l6AttBase", holderIdFor("a"),
      keyRoot, policy = delayed(hours = 1))
    let first = rebuildServiceInstanceRegistry(registry)
    let second = rebuildServiceInstanceRegistry(registry)
    check first.recovered == 1
    check second.recovered == 1
    check first.droppedDead == 0
    check second.droppedDead == 0
    check registry.registeredServiceInstances().len == 1
    reapEverySpawnedInstance()

  test "a record whose process is provably dead is dropped, and the next converge materialises":
    ## "Without orphaning", from the other side. A record kept after its
    ## process died is an entry every later `repro up` would attach to —
    ## handing consumers a handle on nothing.
    let storeRoot = throwawayRoot("dead-store")
    let keyRoot = throwawayRoot("dead-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    discard convergeOne(registry, key, "l6AttBase", holderIdFor("a"),
      keyRoot, policy = delayed(hours = 1))
    let process = registry.lookupServiceInstance(key).get.record.process
    check stopServiceInstanceProcess(process, graceMs = 2000).stopped
    check livenessOf(process) == silDead
    let report = rebuildServiceInstanceRegistry(registry)
    check report.droppedDead == 1
    check report.recovered == 0
    check registry.registeredServiceInstances().len == 0
    check not hasStateRecord(openStateStore(storeRoot),
      serviceInstanceAddress(key))
    var detail = ""
    for event in report.events:
      if event.kind == srrDroppedDeadProcess:
        detail = event.detail
    check detail.contains($process.pid)
    # And the registry is back to "no instance present", so §4.5's
    # "materialises it otherwise" fires.
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), holderIdFor("b"), freshLiftForThisSuite())
    check decision.outcome == scoMaterialise
    check not decision.hadInstance
    reapEverySpawnedInstance()

  test "a record this build cannot decode is REPORTED and left alone":
    ## The silent-drop control for the store: a record written by a
    ## future version must not read as "no instance here", which would
    ## start a second one beside it.
    let storeRoot = throwawayRoot("undecodable-store")
    let keyRoot = throwawayRoot("undecodable-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let address = serviceInstanceAddress(key)
    let store = openStateStore(storeRoot)
    writeStateRecord(store, ResourceStateRecord(
      address: address,
      typeId: ServiceInstanceTypeId,
      attrsTypeId: "reprobuild.service-instance.v99",
      attrsJson: "{}",
      present: true,
      holders: initTable[string, Time]()))
    var registry = freshRegistry(storeRoot)
    let report = rebuildServiceInstanceRegistry(registry)
    check report.skipped == 1
    check report.recovered == 0
    check report.droppedDead == 0
    check registry.registeredServiceInstances().len == 0
    var detail = ""
    for event in report.events:
      if event.kind == srrSkippedUndecodable:
        detail = event.detail
    check detail.contains("reprobuild.service-instance.v99")
    # LEFT ALONE: skipping is not dropping. The record is still on disk,
    # so a build that CAN read it recovers the instance.
    check hasStateRecord(openStateStore(storeRoot), address)

  test "a record whose key disagrees with its address is refused":
    let storeRoot = throwawayRoot("mismatch-store")
    let keyRoot = throwawayRoot("mismatch-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let other = keyFor("l6AttBase", keyRoot, environment = "production")
    check serviceInstanceAddress(key) != serviceInstanceAddress(other)
    let record = ServiceInstanceRecord(key: other,
      address: serviceInstanceAddress(other),
      snapshot: snapshotOf("l6AttBase"))
    expect ValueError:
      discard decodeServiceInstanceAttrs(serviceInstanceAddress(key),
        ServiceInstanceAttrsTypeId, encodeServiceInstanceAttrs(record))

proc downgradeToPreV4(storeRoot: string; key: ServiceInstanceKey) =
  ## Rewrite the instance's record as a PRE-STATE-RECORD-v4 build left it:
  ## the keep holders' names taken out and `keepHoldersKnown` false.
  ##
  ## THIS IS NOT A FABRICATION, AND THE DISTINCTION IS THE WHOLE REASON
  ## THE HELPER EXISTS. It reads the REAL record the real store wrote and
  ## removes exactly the two fields v4 added -- which is byte for byte
  ## what is on disk in any workspace whose last run predates v4. Rule 1's
  ## unrecoverable path can no longer be reached by taking a `keep` lease
  ## and restarting, because `fix(resources): persist keep lease holders in
  ## the state record` made that case RECOVERABLE; this is the shape that
  ## still reaches it, so this is how rule 1 keeps being measured.
  let store = openStateStore(storeRoot)
  var rec = readStateRecord(store, serviceInstanceAddress(key))
  doAssert rec.keepHolders.len > 0,
    "fixture drift: expected a keep-held v4 record to downgrade"
  doAssert rec.keepHoldersKnown,
    "fixture drift: expected the record to claim a complete keep set"
  rec.keepHolders = @[]
  rec.keepHoldersKnown = false
  writeStateRecord(store, rec)

suite "L7 §4.5 rule 1 — an unrecoverable holder set is a REFUSAL":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "the `keep` default is fully counted in memory AND across a restart":
    ## D-SS5 chose `keep` as the default, and §4.5 rule 3 used to record
    ## the consequence: "a `keep` holder's consumer id is written nowhere,
    ## so `effectiveDeadline == none` represents two distinct states".
    ##
    ## STATE-RECORD v4 ENDED THAT, and this case asserts the new
    ## behaviour: `keepHolders` names them on disk and `keepHoldersKnown`
    ## says the list is complete, so the restart recovers the whole set
    ## and rule 1's refusal is never reached -- `--replace` is decided by
    ## L6's `replaceDecision`, which refuses while NAMING all three. The
    ## case below ("rule 1 still refuses...") carries what is left of the
    ## unrecoverable path. Measured against a record written by the REAL
    ## store through the REAL `mergeHolderDeadlines`, as rule 3 requires.
    let storeRoot = throwawayRoot("keep-store")
    let keyRoot = throwawayRoot("keep-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var holders: seq[string] = @[]
    block firstDaemon:
      var registry = freshRegistry(storeRoot)
      for label in ["a", "b", "c"]:
        let holder = holderIdFor(label)
        holders.add(holder)
        discard convergeOne(registry, key, "l6AttBase", holder, keyRoot,
          policy = keep())
      # IN MEMORY the set is complete: §4.5's "authoritative only while
      # the daemon is running".
      check registry.holderNames(key) == sorted(holders)
      check registry.lookupServiceInstance(key).get.holderRecovery == hrTotal
    # ON DISK the names are KEPT. Measured on the record the real store
    # wrote, not on a constructed one.
    let state = readStateRecord(openStateStore(storeRoot),
      serviceInstanceAddress(key))
    # Still not DATED holders -- a keep holder pins with no expiry and is
    # deliberately absent from `holders`, which is unchanged by v4...
    check state.holders.len == 0
    check state.effectiveDeadline.isNone
    # ...and that is now accompanied by their names, and by the record
    # saying the list is COMPLETE rather than merely what it happened to
    # have.
    check sorted(state.keepHolders) == sorted(holders)
    check state.keepHoldersKnown
    let reopened = openServiceInstanceRegistryReporting(storeRoot,
      serviceInstanceLivenessProbe())
    var registry = reopened.registry
    check reopened.report.recovered == 1
    # No risk to report: nothing was lost.
    check reopened.report.unnamedKeepHolderRisks == 0
    let entry = registry.lookupServiceInstance(key).get
    check entry.holderRecovery == hrTotal
    check entry.instance.holders.len == 3
    check sorted(registry.holderNames(key)) == sorted(holders)
    # Every recovered holder is a keep holder: no deadline, always live.
    for holder in entry.instance.holders:
      check holder.deadline.isNone
    # The instance itself is recovered and running.
    check entry.liveness == silLive

    # RULE 1 IS NOT REACHED, because the set is recoverable. `--replace`
    # goes to L6's `replaceDecision`, which refuses and names all three
    # -- a strictly better answer than the old "can name NO holder".
    let refusal = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), holderIdFor("taker"),
      freshLiftForThisSuite(), keep(), getTime(), replace = true)
    check refusal.outcome == scoRefuseOtherHolders
    check refusal.holdersKnown.len == 3
    check sorted(refusal.holdersKnown) == sorted(holders)
    check sorted(refusal.replace.blockingHolders) == sorted(holders)
    check not refusal.diagnostic.contains("can name NO holder")
    for holder in holders:
      check refusal.diagnostic.contains(holder)
    # And the instance is untouched.
    check registry.registeredServiceInstances().len == 1
    check entry.liveness == silLive
    reapEverySpawnedInstance()

  test "rule 1 still refuses an UNRECOVERABLE set, which is now a pre-v4 record":
    ## Rule 1 did not go away with the fix; the only way INTO it did. A
    ## record written before state-record v4 carries no keep-holder names
    ## and does not claim to, so a daemon reading it genuinely cannot
    ## enumerate the holders -- and must say so rather than conclude there
    ## are none. Both rule 1 (refuse) and rule 2 (force, with the
    ## uncertainty named) are asserted on that record.
    let storeRoot = throwawayRoot("prev4-store")
    let keyRoot = throwawayRoot("prev4-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    block firstDaemon:
      var registry = freshRegistry(storeRoot)
      for label in ["a", "b", "c"]:
        discard convergeOne(registry, key, "l6AttBase", holderIdFor(label),
          keyRoot, policy = keep())
    downgradeToPreV4(storeRoot, key)

    let reopened = openServiceInstanceRegistryReporting(storeRoot,
      serviceInstanceLivenessProbe())
    var registry = reopened.registry
    check reopened.report.recovered == 1
    check reopened.report.unnamedKeepHolderRisks == 1
    let entry = registry.lookupServiceInstance(key).get
    check entry.holderRecovery == hrMayHaveUnnamedKeepHolder
    check entry.instance.holders.len == 0
    # The instance itself is recovered and running: the LOSS is the
    # holder set, not the instance.
    check entry.liveness == silLive

    # RULE 1: `--replace` refuses, and names the uncertainty.
    let refusal = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), holderIdFor("taker"),
      freshLiftForThisSuite(), keep(), getTime(), replace = true)
    check refusal.outcome == scoRefuseUnknownHolders
    check refusal.diagnostic.contains("UNRECOVERABLE")
    check refusal.diagnostic.contains("§4.5 rule 1")
    # §4.5: "naming the holders it does know" — and here it knows none,
    # which it says rather than implying there are none.
    check refusal.diagnostic.contains("can name NO holder")
    check refusal.holdersKnown.len == 0
    # `replaceDecision` was NOT consulted, so nothing claims a set this
    # path could not compute.
    check refusal.replace.blockingHolders.len == 0
    check registry.registeredServiceInstances().len == 1
    check entry.liveness == silLive

    # RULE 2: `--force` proceeds, and says holders may exist it cannot
    # name.
    let forced = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), holderIdFor("taker"),
      freshLiftForThisSuite(), keep(), getTime(),
      replace = true, force = true)
    check forced.outcome == scoForcedOverOtherHolders
    check forced.diagnostic.contains(
      "HOLDERS MAY EXIST WHICH THIS DAEMON CANNOT NAME")
    check forced.diagnostic.contains("§4.5 rule 2")
    check forced.diagnostic.contains("not a claim that nobody else holds")
    reapEverySpawnedInstance()

  test "rule 2's forced text on the unrecoverable path differs from the recoverable one":
    ## §4.5: "A `--force` that reads as \"no other holders\" when the
    ## truth is \"no other holders are *recoverable*\" is a worse failure
    ## than the refusal it bypasses." So the two forced diagnostics are
    ## asserted to be DIFFERENT TEXTS, and the recoverable one is
    ## asserted NOT to carry the uncertainty sentence.
    let storeRoot = throwawayRoot("force-texts-store")
    let keyRoot = throwawayRoot("force-texts-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let other = holderIdFor("other")
    discard convergeOne(registry, key, "l6AttBase", other, keyRoot,
      policy = delayed(hours = 1))
    let recoverable = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), holderIdFor("taker"),
      freshLiftForThisSuite(), delayed(hours = 1), getTime(),
      replace = true, force = true)
    check recoverable.outcome == scoForcedOverOtherHolders
    # The RECOVERABLE path's text is L6's `replaceDecision` text: it
    # names the holder it is overriding and makes no claim about
    # unnameable ones.
    check recoverable.diagnostic.contains(other)
    check not recoverable.diagnostic.contains("CANNOT NAME")
    check not recoverable.diagnostic.contains("§4.5 rule 2")
    reapEverySpawnedInstance()

  test "release refuses to decide `last holder` from an unrecoverable set":
    ## Rule 1's REASONING applied to `repro down`, which the
    ## implementation labels as an application rather than quoting as the
    ## clause. The damage is the same: concluding "I was the last" from a
    ## set that could not be enumerated stops an instance another project
    ## is using.
    let storeRoot = throwawayRoot("keep-release-store")
    let keyRoot = throwawayRoot("keep-release-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let holder = holderIdFor("a")
    block firstDaemon:
      var registry = freshRegistry(storeRoot)
      discard convergeOne(registry, key, "l6AttBase", holder, keyRoot,
        policy = keep())
    # A keep holder alone is no longer unrecoverable -- state-record v4
    # names it -- so the set is made unrecoverable the only way that is
    # still real: a record from before v4. See `downgradeToPreV4`.
    downgradeToPreV4(storeRoot, key)
    var registry = freshRegistry(storeRoot)
    let process = registry.lookupServiceInstance(key).get.record.process
    let decision = releaseServiceInstance(registry, key, holder)
    check decision.outcome == srlRefuseUnknownHolders
    check decision.diagnostic.contains("UNRECOVERABLE")
    check decision.diagnostic.contains("name the uncertainty rather than")
    # Nothing was dropped and nothing was stopped.
    check registry.registeredServiceInstances().len == 1
    check livenessOf(process) == silLive
    reapEverySpawnedInstance()

  test "a recoverable set reaches L6's `replaceDecision`, both outcomes":
    ## The control that keeps rule 1 from swallowing the recoverable
    ## path: with dated holders the set IS recoverable after a restart,
    ## so `--replace` is decided by L6's `replaceDecision` — refusing
    ## while another holder is live, and proceeding when the requester is
    ## the only one.
    let storeRoot = throwawayRoot("recoverable-store")
    let keyRoot = throwawayRoot("recoverable-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let mine = holderIdFor("mine")
    let theirs = holderIdFor("theirs")
    block firstDaemon:
      var registry = freshRegistry(storeRoot)
      for holder in [mine, theirs]:
        discard convergeOne(registry, key, "l6AttBase", holder, keyRoot,
          policy = delayed(hours = 3))
    var registry = freshRegistry(storeRoot)
    check registry.lookupServiceInstance(key).get.holderRecovery == hrTotal
    let refusal = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), mine, freshLiftForThisSuite(),
      delayed(hours = 3), getTime(), replace = true)
    check refusal.outcome == scoRefuseOtherHolders
    check refusal.replace.blockingHolders == @[theirs]
    check refusal.diagnostic.contains(theirs)
    check not refusal.diagnostic.contains("UNRECOVERABLE")
    # Drop the other holder, and the same request proceeds.
    check releaseServiceInstance(registry, key, theirs).outcome ==
      srlDroppedHolder
    let proceed = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), mine, freshLiftForThisSuite(),
      delayed(hours = 3), getTime(), replace = true)
    check proceed.outcome == scoReplace
    check proceed.diagnostic == ""
    reapEverySpawnedInstance()

suite "L7 — the attach decision is L6's; only its PROVENANCE is new":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "an implementation-only change attaches with NO diagnostic":
    ## §4.3's control, now decided over a registry lookup rather than a
    ## constructed record: "a change to the implementation only (args,
    ## config bytes) must attach with NO warning emitted".
    let storeRoot = throwawayRoot("silent-store")
    let keyRoot = throwawayRoot("silent-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    discard convergeOne(registry, key, "l6AttBase", holderIdFor("a"),
      keyRoot, policy = delayed(hours = 1))
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttOtherImpl"), holderIdFor("b"),
      freshLiftForThisSuite(), delayed(hours = 1))
    check decision.outcome == scoAttachSilently
    check decision.diagnostic == ""
    check decision.attach.outcome == saoAttachSilently
    check decision.hadInstance
    reapEverySpawnedInstance()

  test "an interface difference within one major attaches and warns, naming the member":
    let storeRoot = throwawayRoot("warn-store")
    let keyRoot = throwawayRoot("warn-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let first = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", first, keyRoot,
      policy = delayed(hours = 1))
    let second = holderIdFor("b")
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttAddedKey"), second, freshLiftForThisSuite(),
      delayed(hours = 1))
    check decision.outcome == scoAttachWithWarning
    check decision.diagnostic.len > 0
    check decision.attach.differences.len > 0
    # Attached means HELD: the warning does not cost the consumer its
    # reference.
    check registry.holderNames(key) == sorted(@[first, second])
    reapEverySpawnedInstance()

  test "a differing major REFUSES and takes no holder":
    ## The refusal's consequence, which only a registry can measure: a
    ## consumer that was refused must not be recorded as a holder, or
    ## `repro down` elsewhere would release an instance it never used and
    ## `--replace` would refuse on its account.
    let storeRoot = throwawayRoot("refuse-store")
    let keyRoot = throwawayRoot("refuse-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let first = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", first, keyRoot,
      policy = delayed(hours = 1))
    let refused = holderIdFor("b")
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttOtherMajor"), refused, freshLiftForThisSuite(),
      delayed(hours = 1))
    check decision.outcome == scoRefuseMajor
    check convergeRefused(decision.outcome)
    check decision.attach.outcome == saoRefuseMajor
    check registry.holderNames(key) == @[first]
    check not registry.holderNames(key).contains(refused)
    reapEverySpawnedInstance()

suite "L7 — §4.3's SAME-GENERATION PRECONDITION, at the converge":
  ## ADDED when the precondition was implemented. The decision itself is
  ## measured in `t_l6_attach_refuses_a_stale_lift.nim`, against a REAL
  ## provenance stamp on disk; what only a registry can measure is the
  ## CONSEQUENCE of its two refusals -- the outcome word that crosses the
  ## daemon wire, and the holder the consumer must NOT be recorded as.
  ##
  ## The `sagStale` / `sagUnknownProvenance` values here are constructed,
  ## and that is not a mock: a `ServiceArtifactGenerationCheck` is a
  ## record of an answer the CLIENT established from the owner's recipe
  ## and the owner's artifact, neither of which exists in this process.
  ## The establishment is measured where it happens.
  teardown:
    reapEverySpawnedInstance()

  test "a STALE generation refuses, takes no holder, and reads as refused":
    let storeRoot = throwawayRoot("stale-store")
    let keyRoot = throwawayRoot("stale-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let first = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", first, keyRoot,
      policy = delayed(hours = 1))
    let refused = holderIdFor("b")
    # The SAME definition on both sides, so the fingerprints agree and
    # §4.3's table alone would select row 1 -- `scoAttachSilently`, with
    # the holder taken. The generation is the only thing that differs.
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), refused,
      ServiceArtifactGenerationCheck(generation: sagStale,
        artifactPath: keyRoot / "project-interface.rbsz",
        ownerPackage: "l6AttBase", ownerProject: "l6AttBase",
        recordedIdentity: "aa", currentIdentity: "bb",
        movedSources: @["repro.nim (edited)"]),
      delayed(hours = 1))
    check decision.outcome == scoRefuseStaleLift
    check convergeRefused(decision.outcome)
    check decision.attach.outcome == saoRefuseStaleLift
    check decision.diagnostic.contains("THE LIFT IS STALE")
    check decision.diagnostic.contains("repro dev-env")
    # NOT HELD. A refused consumer recorded as a holder would make
    # `repro down` elsewhere release an instance it never used.
    check registry.holderNames(key) == @[first]
    check not registry.holderNames(key).contains(refused)
    # The outcome word survives the wire, so a client reports the
    # refusal rather than an unknown outcome.
    check parseConvergeOutcome(outcomeWord(decision.outcome)) ==
      scoRefuseStaleLift

  test "an UNESTABLISHED generation refuses the same way, and differently":
    let storeRoot = throwawayRoot("unprov-store")
    let keyRoot = throwawayRoot("unprov-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let first = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", first, keyRoot,
      policy = delayed(hours = 1))
    let refused = holderIdFor("b")
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), refused, ServiceArtifactGenerationCheck(),
      delayed(hours = 1))
    check decision.outcome == scoRefuseUnknownProvenance
    check convergeRefused(decision.outcome)
    check decision.attach.outcome == saoRefuseUnknownProvenance
    check not decision.diagnostic.contains("THE LIFT IS STALE")
    check registry.holderNames(key) == @[first]
    check parseConvergeOutcome(outcomeWord(decision.outcome)) ==
      scoRefuseUnknownProvenance

  test "a FRESH generation still attaches and still takes the holder":
    ## The control for the two cases above: the same converge, the same
    ## snapshots, the same registry -- only the generation changes, and
    ## the holder IS taken. A precondition that refused unconditionally
    ## would pass both cases above and fail this one.
    let storeRoot = throwawayRoot("genfresh-store")
    let keyRoot = throwawayRoot("genfresh-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    let first = holderIdFor("a")
    discard convergeOne(registry, key, "l6AttBase", first, keyRoot,
      policy = delayed(hours = 1))
    let second = holderIdFor("b")
    let decision = convergeServiceInstance(registry, key,
      snapshotOf("l6AttBase"), second, freshLiftForThisSuite(),
      delayed(hours = 1))
    check decision.outcome == scoAttachSilently
    check decision.diagnostic == ""
    check registry.holderNames(key) == sorted(@[first, second])

suite "L7 — the registry is keyed by (identity, scope, environment)":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "two environments are two instances, and two identities are two instances":
    ## The mutation this suite is the control for is "key the registry by
    ## project root instead of (identity, scope, environment)". That
    ## mutation reddens the convergence suite above; THIS suite is the
    ## other direction — the key's three components must each SEPARATE
    ## instances, or the registry would merge a development issuer with a
    ## production one (§6.5: "a development issuer and a production
    ## issuer are not interchangeable").
    let storeRoot = throwawayRoot("components-store")
    let keyRoot = throwawayRoot("components-keyroot")
    var registry = freshRegistry(storeRoot)
    let dev = keyFor("l6AttBase", keyRoot, environment = "dev")
    let prod = keyFor("l6AttBase", keyRoot, environment = "production")
    let holder = holderIdFor("a")
    check convergeOne(registry, dev, "l6AttBase", holder, keyRoot,
      policy = delayed(hours = 1)).outcome == scoMaterialise
    # The SAME holder in the SAME project converging the SAME service
    # under a different environment gets its own instance.
    check convergeOne(registry, prod, "l6AttBase", holder, keyRoot,
      policy = delayed(hours = 1)).outcome == scoMaterialise
    check registry.registeredServiceInstances().len == 2
    check registry.lookupServiceInstance(dev).get.record.process.pid !=
      registry.lookupServiceInstance(prod).get.record.process.pid
    # A DIFFERENT stable identity is a third instance, with the SAME
    # package, scope and environment -- so the identity is the only thing
    # that moved.
    let otherIdentity = keyFor("l6AttBase", keyRoot, environment = "dev",
      stableId = "com.example.l7.other-sso")
    check serviceInstanceAddress(otherIdentity) !=
      serviceInstanceAddress(dev)
    check convergeOne(registry, otherIdentity, "l6AttBase", holder,
      keyRoot, policy = delayed(hours = 1)).outcome == scoMaterialise
    check registry.registeredServiceInstances().len == 3
    # Releasing one does not touch the others.
    check releaseServiceInstance(registry, dev, holder).outcome ==
      srlReleasedLastHolder
    registry.forgetServiceInstance(serviceInstanceAddress(dev))
    check registry.registeredServiceInstances().len == 2
    check registry.lookupServiceInstance(prod).isSome
    reapEverySpawnedInstance()

  test "three consumers at three different project roots share one address":
    ## §4.4's property, measured on the registry: "two worktrees resolve
    ## to one directory". Here: three consumers resolve to one ADDRESS,
    ## and no consumer's path occurs in it.
    let storeRoot = throwawayRoot("oneaddress-store")
    let keyRoot = throwawayRoot("oneaddress-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    var roots: seq[string] = @[]
    for label in ["a", "b", "c"]:
      let root = throwawayRoot("worktree-" & label)
      roots.add(canonicalRoot(root))
      discard convergeOne(registry, key, "l6AttBase",
        serviceLeaseHolderId(root), keyRoot, policy = delayed(hours = 1))
    check registry.registeredServiceInstances().len == 1
    let address = registry.registeredServiceInstances()[0].record.address
    for root in roots:
      check not address.contains(root)
    check registry.holderNames(key).len == 3
    reapEverySpawnedInstance()

suite "L7 — the registry refuses what it cannot do, rather than guessing":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "a registry with no liveness probe refuses instead of assuming live":
    var registry = ServiceInstanceRegistry(
      storeRoot: throwawayRoot("noprobe-store"),
      entries: initTable[string, ServiceInstanceEntry]())
    expect ServiceRegistryError:
      discard rebuildServiceInstanceRegistry(registry)

  test "a registry with no store root refuses":
    var registry = ServiceInstanceRegistry(storeRoot: "",
      probe: serviceInstanceLivenessProbe(),
      entries: initTable[string, ServiceInstanceEntry]())
    expect ServiceRegistryError:
      discard rebuildServiceInstanceRegistry(registry)

  test "converge and release refuse an empty holder id":
    let storeRoot = throwawayRoot("noholder-store")
    let keyRoot = throwawayRoot("noholder-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    var registry = freshRegistry(storeRoot)
    expect ServiceRegistryError:
      discard convergeServiceInstance(registry, key,
        snapshotOf("l6AttBase"), "", freshLiftForThisSuite())
    expect ServiceRegistryError:
      discard releaseServiceInstance(registry, key, "")

  test "an unknown outcome word is a named refusal, never a default outcome":
    ## A protocol skew must not read as `scoMaterialise`, which would
    ## start a second instance.
    expect ServiceRegistryError:
      discard parseConvergeOutcome("MaterialiseSomething")
    expect ServiceRegistryError:
      discard parseReleaseOutcome("DroppedEverything")
    for outcome in ServiceConvergeOutcome:
      check parseConvergeOutcome(outcomeWord(outcome)) == outcome
    for outcome in ServiceReleaseOutcome:
      check parseReleaseOutcome(outcomeWord(outcome)) == outcome

suite "L7 — the wire and store codecs round-trip what the decision reads":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "a snapshot survives the codec with every member intact":
    let snapshot = snapshotOf("l6AttBase")
    check snapshot.members.len > 0
    let decoded = decodeServiceInterfaceSnapshot(
      encodeServiceInterfaceSnapshot(snapshot))
    check decoded.fingerprint == snapshot.fingerprint
    check decoded.compatibilityMajor == snapshot.compatibilityMajor
    check decoded.projectName == snapshot.projectName
    check decoded.members.len == snapshot.members.len
    for i in 0 ..< snapshot.members.len:
      check decoded.members[i].kind == snapshot.members[i].kind
      check decoded.members[i].name == snapshot.members[i].name
      check decoded.members[i].signature == snapshot.members[i].signature
    # The round trip must not change the attach decision, which is the
    # only thing the snapshot is for.
    let running = runningServiceInstance(
      keyFor("l6AttBase", throwawayRoot("codec-keyroot")), decoded, [])
    check attachDecision(running, snapshot,
      freshLiftForThisSuite()).outcome == saoAttachSilently

  test "a key survives the codec, and an unknown scope word is refused":
    for environment in ["", "dev", "production/with-slash"]:
      let key = keyFor("l6AttBase", throwawayRoot("keycodec"),
        environment = environment)
      let decoded = decodeServiceInstanceKey(encodeServiceInstanceKey(key))
      check serviceInstanceAddress(decoded) == serviceInstanceAddress(key)
      check decoded.identity == key.identity
      check decoded.scope == key.scope
      check decoded.environment == key.environment
    expect ValueError:
      discard decodeServiceInstanceKey(
        """{"identityKind":"stable","identity":"x","scope":"galaxy",""" &
        """"scopeKey":"k","environment":"","degradation":""}""")
    expect ValueError:
      discard decodeServiceInstanceKey(
        """{"identityKind":"inherited","identity":"x","scope":"user",""" &
        """"scopeKey":"k","environment":"","degradation":""}""")
    expect ValueError:
      discard decodeServiceInstanceKey("not json at all")

  test "an address is recognised as a service instance address or not":
    let key = keyFor("l6AttBase", throwawayRoot("prefix"))
    check isServiceInstanceAddress(serviceInstanceAddress(key))
    check not isServiceInstanceAddress("topology")
    check not isServiceInstanceAddress("")

suite "L7 §4.5 — `an instance is reaped when its last lease lapses`":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()
  ## THE CLAUSE THIS SUITE EXISTS FOR, and the reason it is a suite of its
  ## own rather than a case inside the release suite: §4.5 gives an
  ## instance TWO ways to end. `repro down` by the last holder is one, and
  ## it is driven above. The lease LAPSING with no `repro down` at all is
  ## the other — the orphan case, the one that matters when a consumer is
  ## killed — and it is enforced by the SWEEP, not by a verb.
  ##
  ## The sweep is the same `reapOnce` the lease lane already runs over
  ## this store (`serviceInstanceStoreRoot`: "two roots would mean the
  ## reaper swept a store the registry did not read"), and it reaches an
  ## instance record through `reaper.nim`'s typed handler. Everything
  ## below installs the REAL handler the daemon installs.

  test "a lapsed instance is really STOPPED and its record removed by a sweep":
    let storeRoot = throwawayRoot("reap-lapsed-store")
    let keyRoot = throwawayRoot("reap-lapsed-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let address = serviceInstanceAddress(key)
    var registry = freshRegistry(storeRoot)
    # Converged two hours ago with a one-second lease, through the real
    # `deadlineFrom` into the real store: the lease has lapsed, and
    # nothing renewed it because the consumer is gone.
    let lapsedAt = getTime() - initDuration(hours = 2)
    let decision = convergeOne(registry, key, "l6AttBase",
      holderIdFor("lapsed"), keyRoot,
      policy = delayed(seconds = 1), now = lapsedAt)
    check decision.outcome == scoMaterialise
    let found = registry.lookupServiceInstance(key)
    check found.isSome
    let process = found.get.record.process
    check aliveInProcfs(process)

    let store = openStateStore(storeRoot)
    let record = readStateRecord(store, address)
    check record.typeId == ServiceInstanceTypeId
    check record.effectiveDeadline.isSome
    check isReapable(record, getTime())      # the gate really selects it

    installServiceInstanceReapHandler(addr registry)
    var report: ReapReport
    try:
      report = reapOnce(store, now = getTime())
    finally:
      uninstallServiceInstanceReapHandler()

    check report.reaped.len == 1
    check report.reaped[0].address == address
    check report.reaped[0].typeId == ServiceInstanceTypeId
    check report.reaped[0].wasPresent
    check report.failed.len == 0
    # THE PROCESS IS GONE, read from the process table rather than from
    # the report just asserted. This is the assertion the whole case is
    # for: before the typed handler existed the sweep raised here and the
    # instance ran forever.
    check goneFromProcfs(process)
    # ...and both halves of the registry forgot it: the record, so no
    # rebuild recovers it, and the in-memory entry, so no `repro up`
    # attaches a consumer to a process this sweep has just killed.
    check not hasStateRecord(store, address)
    check registry.lookupServiceInstance(key).isNone
    check registry.registeredServiceInstances().len == 0

  test "one record the sweep cannot reap does not cost the others theirs":
    ## The ISOLATION clause, at L7. Three instance records in ONE store,
    ## all three selected by the gate: two this build can decode and one
    ## it cannot. The two are reaped IN THE SAME TICK and the third comes
    ## back in `failed` as `rfkUnreapable`, named, with its record kept.
    ##
    ## Both halves are load-bearing. Without the isolation, the
    ## undecodable record aborted the sweep and the two live instances
    ## kept running forever; without the failure being REPORTED, the
    ## third record would be a silent leak, which is worse than the abort
    ## it replaced.
    ##
    ## NO `dependsOn` EDGE IS INVOLVED HERE, deliberately: an instance
    ## record is written with `dependsOn: @[]` (`stateRecordFor`), so the
    ## `rfkBlocked` hold that protects a dependency of an unreapable
    ## record cannot fire for instances. `t_l3_reaper` case (11) is where
    ## that half is measured, over records that do have edges.
    let storeRoot = throwawayRoot("reap-isolation-store")
    let keyRoot = throwawayRoot("reap-isolation-keyroot")
    let lapsedAt = getTime() - initDuration(hours = 2)
    var registry = freshRegistry(storeRoot)
    var processes: seq[ServiceInstanceProcess] = @[]
    var addresses: seq[string] = @[]
    for label in ["alpha", "beta"]:
      let key = keyFor("l6AttBase", keyRoot, stableId = "com.example." & label)
      check convergeOne(registry, key, "l6AttBase",
        holderIdFor(label), keyRoot,
        policy = delayed(seconds = 1),
        now = lapsedAt).outcome == scoMaterialise
      processes.add(registry.lookupServiceInstance(key).get.record.process)
      addresses.add(serviceInstanceAddress(key))
    let store = openStateStore(storeRoot)
    # The third: an instance record written by a build that is not this
    # one, with a lapsed dated holder so the gate selects it too.
    let undecodable = "service:workspace:zzz:dev:stable:com.example.future"
    writeStateRecord(store, lapsedInstanceRecordWith(undecodable,
      "reprobuild.service-instance.v99", "{}", lapsedAt))
    check isReapable(readStateRecord(store, undecodable), getTime())
    check listStateRecords(store).len == 3

    installServiceInstanceReapHandler(addr registry)
    var report: ReapReport
    try:
      report = reapOnce(store, now = getTime())
    finally:
      uninstallServiceInstanceReapHandler()

    check report.reaped.len == 2
    var reapedAddresses: seq[string] = @[]
    for event in report.reaped:
      reapedAddresses.add(event.address)
    reapedAddresses.sort()
    var expected = addresses
    expected.sort()
    check reapedAddresses == expected
    for process in processes:
      check goneFromProcfs(process)
    for address in addresses:
      check not hasStateRecord(store, address)

    # The unreapable one, NAMED: its address, its typeId, and why. It is
    # `rfkUnreapable` (attempted and refused) rather than `rfkBlocked`
    # (held because a dependent failed), which is the distinction that
    # keeps a stuck store from reading as a healthy one.
    check report.failed.len == 1
    check report.failed[0].address == undecodable
    check report.failed[0].typeId == ServiceInstanceTypeId
    check report.failed[0].kind == rfkUnreapable
    check report.failed[0].reason.contains(
      "reprobuild.service-instance.v99")
    # ...and it is NOT folded into `skipped`, which means "inspected and
    # correctly kept".
    check undecodable notin report.skipped
    # KEPT, not removed: a build that CAN read it must still find it.
    check hasStateRecord(store, undecodable)

  test "`reapOnce(force = true)` over a `keep`-held instance does not raise":
    ## `force` ignores the deadline and selects every present record, so
    ## it reaches the `keep`-held instance the ordinary sweep never
    ## selects. Before the typed handler that was an unconditional
    ## `KeyError` out of `reapOnce` — i.e. `repro reap --force` could not
    ## be run at all on a store that had ever held a shared instance.
    ##
    ## BOTH HANDLERS ARE EXERCISED, because the two answers are both
    ## correct and they are different answers:
    ##
    ##   * with NO instance-reap handler installed (any process that is
    ##     not the daemon) the record is DECLINED and kept, because
    ##     removing it would leave a running process nothing names;
    ##   * with the daemon's handler installed the instance is really
    ##     stopped and the record removed, which is what `force` means.
    let storeRoot = throwawayRoot("reap-force-store")
    let keyRoot = throwawayRoot("reap-force-keyroot")
    let key = keyFor("l6AttBase", keyRoot)
    let address = serviceInstanceAddress(key)
    var registry = freshRegistry(storeRoot)
    check convergeOne(registry, key, "l6AttBase", holderIdFor("force"),
      keyRoot).outcome == scoMaterialise          # the `keep` default
    let process = registry.lookupServiceInstance(key).get.record.process
    let store = openStateStore(storeRoot)
    let record = readStateRecord(store, address)
    # THE GROUND OF `recordMaterialisedInstance`'s REFUSAL, measured: a
    # `keep` holder's name is not in the record and the fold is `none`,
    # which the gate never selects. That is why an instance registered
    # with NO holder would be unreapable rather than "reaped by the next
    # sweep", and why that refusal says so.
    check record.holders.len == 0
    check record.effectiveDeadline.isNone
    check not isReapable(record, getTime() + initDuration(days = 3650))
    check isReapable(record, getTime(), force = true)

    # Arm 1: no handler installed beyond this library's declining one.
    let declined = reapOnce(store, now = getTime(), force = true)
    check declined.reaped.len == 0
    check declined.failed.len == 1
    check declined.failed[0].address == address
    check declined.failed[0].reason.contains("instance-reap handler")
    check declined.failed[0].reason.contains($process.pid)
    check hasStateRecord(store, address)
    check aliveInProcfs(process)

    # Arm 2: the daemon's handler. `force` now does what it says.
    installServiceInstanceReapHandler(addr registry)
    var forced: ReapReport
    try:
      forced = reapOnce(store, now = getTime(), force = true)
    finally:
      uninstallServiceInstanceReapHandler()
    check forced.failed.len == 0
    check forced.reaped.len == 1
    check forced.reaped[0].address == address
    check goneFromProcfs(process)
    check not hasStateRecord(store, address)
    check registry.registeredServiceInstances().len == 0

  test "a stop that FAILS keeps the record rather than orphaning the process":
    ## The other direction of the handler's contract, and the reason it
    ## returns an outcome instead of just doing the work: a lapsed lease
    ## is NOT a licence to remove a record whose process was not
    ## actually stopped. Removing it is how a running instance becomes
    ## one nothing names and the next `repro up` double-starts.
    ##
    ## BOTH WAYS THE HANDLER CAN FAIL ARE DRIVEN, because they are
    ## different code and only one of them is about `stopped = false`:
    ##
    ##   1. the record cannot be DECODED, so no pid can even be named —
    ##      the same policy `rebuildServiceInstanceRegistry` applies
    ##      (`srrSkippedUndecodable`), since a record this build cannot
    ##      read may be one a later build can;
    ##   2. the record decodes and the STOP fails. Driven through a
    ##      record that names NO PROCESS, which is a real shape rather
    ##      than a contrived one: `applyServiceConverge` refuses to
    ##      register without a process precisely because such an entry
    ##      "would be recovered by every later rebuild as live, liveness
    ##      unknown, and never stop" — so a record written by a path that
    ##      did not establish an identity is exactly what this arm
    ##      describes, and `stopServiceInstanceProcess` answers it with
    ##      `stopped = false` and a sentence.
    let storeRoot = throwawayRoot("reap-keep-record-store")
    let keyRoot = throwawayRoot("reap-keep-record-keyroot")
    let lapsedAt = getTime() - initDuration(hours = 2)
    let store = openStateStore(storeRoot)

    # Arm 1: undecodable.
    let unreadable = "service:workspace:zzz:dev:stable:com.example.unreadable"
    writeStateRecord(store, lapsedInstanceRecordWith(unreadable,
      ServiceInstanceAttrsTypeId, """{"key":{}}""", lapsedAt))

    # Arm 2: decodable, and names no process.
    let key = keyFor("l6AttBase", keyRoot, stableId = "com.example.noproc")
    let processless = serviceInstanceAddress(key)
    writeStateRecord(store, lapsedInstanceRecordWith(processless,
      ServiceInstanceAttrsTypeId,
      encodeServiceInstanceAttrs(ServiceInstanceRecord(key: key,
        address: processless, snapshot: snapshotOf("l6AttBase"),
        process: ServiceInstanceProcess(), startedByHolder: "holder:x",
        startedAtUnix: lapsedAt.toUnix)), lapsedAt))
    # It really does decode, so arm 2 reaches the STOP and is not a
    # second copy of arm 1.
    let decoded = decodeServiceInstanceAttrs(processless,
      ServiceInstanceAttrsTypeId,
      readStateRecord(store, processless).attrsJson)
    check decoded.process.pid == 0
    check isReapable(readStateRecord(store, processless), getTime())

    var registry = freshRegistry(storeRoot)
    installServiceInstanceReapHandler(addr registry)
    var report: ReapReport
    try:
      report = reapOnce(store, now = getTime())
    finally:
      uninstallServiceInstanceReapHandler()

    check report.reaped.len == 0
    check report.failed.len == 2
    var reasons: Table[string, string]
    for decline in report.failed:
      reasons[decline.address] = decline.reason
    check reasons[unreadable].contains("could not be decoded")
    check reasons[processless].contains("could not be stopped")
    check reasons[processless].contains("carries no pid")
    check reasons[processless].contains("record is KEPT")
    # BOTH records survive the sweep.
    check hasStateRecord(store, unreadable)
    check hasStateRecord(store, processless)

suite "L7 — the recorded identity is validated BEFORE `waitpid` is asked":
  teardown:
    # Runs whether the case passed or raised -- see the first suite.
    reapEverySpawnedInstance()

  test "a pid recycled onto another live child is not the recorded instance":
    ## `waitpid(pid, WNOHANG)` answers about a PID; it cannot answer about
    ## an IDENTITY. Asked first, it reported `0` — "my child, still
    ## running" — for a pid that had been recycled onto a DIFFERENT live
    ## child of the same daemon, and `writerLiveness`, the only source
    ## that compares start times, was never consulted. The registry then
    ## kept a dead instance's record on the strength of an unrelated
    ## process, and the next `repro up` attached a consumer to it.
    ##
    ## The recycled record is the real identity of a real live child with
    ## its START STAMP set one tick earlier — see this file's header for
    ## why that is the only deterministic way to produce one.
    let process = materialise(throwawayRoot("recycle-wd"))
    check aliveInProcfs(process)
    let decoded = decodeWriterIdentity(process.processIdentity)
    check decoded.isSome
    let live = decoded.get
    check live.startStamp.len > 0
    # The POSITIVE CONTROL first: the unmodified identity of this very
    # child reads LIVE. Without it, the assertion below would also pass
    # against a probe that answered `silDead` for everything.
    check serviceInstanceLivenessProbe()(process.processIdentity) == silLive

    let earlier = WriterIdentity(bootId: live.bootId, pid: live.pid,
      startStamp: $(parseBiggestInt(live.startStamp) - 1))
    let recycled = encodeWriterIdentity(earlier)
    check recycled != process.processIdentity
    # `writerLiveness` alone has always had this right...
    check writerLiveness(recycled) == wlDead
    # ...and the registry's probe must agree with it rather than with
    # `waitpid`, which still answers "my child, still running" for this
    # pid because the pid IS a live child of this process.
    check serviceInstanceLivenessProbe()(recycled) == silDead
    # The other child is untouched: validating the identity first also
    # means `waitpid` is never asked about a process the record does not
    # name, so its exit status is not consumed out from under whatever
    # started it.
    check aliveInProcfs(process)
    reapEverySpawnedInstance()

# A last sweep, so a failing case cannot leave a `sleep` loop behind.
reapEverySpawnedInstance()
