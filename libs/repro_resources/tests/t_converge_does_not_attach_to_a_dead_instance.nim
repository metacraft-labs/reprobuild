## Shared-Development-Services L7 (spec §4.5) — CONVERGE PROBES THE
## RECORDED PROCESS BEFORE IT ATTACHES TO IT.
##
## WHY THIS FILE EXISTS. `convergeServiceInstance` used to take the
## registry entry and go straight to `attachDecision`. §4.3's three
## outcomes are decided on the interface FINGERPRINT, which is the right
## question only once it is known that there is a process to attach to --
## and nothing on that path asked. Liveness was re-evaluated on the stop
## path, on the reap handler's `wasRunning` read and during a registry
## REBUILD, so a shared instance whose process died stayed attachable for
## the rest of the daemon's lifetime and the next consumer waited out the
## service's whole declared readiness timeout (600 s for the shared SSO
## service) instead of being told the cause. Recorded as
## `reprobuild-pm/issues/2026-10-13-attach-succeeds-against-a-shared-
## instance-whose-process-is-a-zombie.md`.
##
## THE DEAD PROCESS IN EVERY CASE BELOW IS A ZOMBIE, ON PURPOSE. The
## daemon spawns an instance detached and closes the handle without
## waiting, so a dead instance is an UNREAPED child: it keeps its pid, its
## `/proc/<pid>/stat` and its original start time, and `kill(pid, 0)`
## succeeds on it. That is what made a `kill -0` probe the obvious and
## wrong fix. Each dead-instance case therefore asserts the zombie state
## FIRST -- `/proc/<pid>/stat` field 3 is `Z` and `kill(pid, 0) == 0` --
## as a positive control: if the fixture produced a REAPED corpse instead,
## any probe at all would pass, and the case would not be measuring the
## shape the issue observed.
##
## The process is made a zombie by SIGKILLing a running instance, rather
## than by materialising a command that exits on its own. That keeps the
## first converge a genuine materialise of a running process, whatever
## the spawn path does about a child that dies before it is registered
## (a separate issue, fixed separately), so this file measures only the
## converge arm.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE AND NONE MAY BE ADDED.
## Specifically:
##
## * the interface snapshot comes from a real `package` block in
##   `dss11_converge_fixtures.nim`, expanded by the real DSL macro and
##   lifted by the real `toProjectInterface`;
## * the instance key comes from the real `serviceInstanceKey`;
## * the registry is a real `openServiceInstanceRegistry` over a real
##   `StateStore` on a real filesystem under a throwaway root;
## * every instance is a REAL detached child process, started by the
##   real `materialiseServiceInstanceProcess` (reached through the real
##   `applyServiceConverge`, the daemon's `udkServiceConverge` handler
##   body), killed by a real signal, and stopped by the real
##   `stopServiceInstanceProcess`;
## * the liveness probe is the real `serviceInstanceLivenessProbe` the
##   daemon installs -- `writerLiveness` and then `waitpid(WNOHANG)`.
##
## THE ONE INJECTED FUNCTION IS NOT A SEAM FOR A DOUBLE.
## `ServiceInstanceRegistry.probe` exists because `writerLiveness` lives
## in `repro_daemon_core`, which DEPENDS ON `repro_resources`, so
## `service_registry.nim` cannot import it without a library cycle. This
## file installs the real one, which is the only one that exists. The
## same note appears in
## `t_l7_instance_registry_converges_in_any_order.nim`.
##
## Governing text — `Shared-Development-Services.md` §4.5: "`up`
## resolves the key, attaches if an instance is present and materialises
## it otherwise." A record whose process has exited is not an instance
## that is present.

import std/[options, os, posix, strutils, tables, times, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_resources
import repro_resources/service_attach
import repro_resources/service_identity
import repro_resources/service_registry
import repro_resources/state_store

# The REAL daemon-side half: the converge handler body, the liveness
# probe, the materialiser and the stop.
import repro_daemon_core
import repro_daemon_core/instance_registry
import repro_daemon_core/writer_identity

import ./dss11_converge_fixtures

const
  Package = "dss11CvOne"
  ServiceName = "zitadel"
  ZombieWaitMs = 5000

# ---------------------------------------------------------------------------
# Snapshot and key, from the real lift. The same projections
# `t_dss11_converge_response_carries_the_instances_points.nim` uses,
# duplicated for the reason that file gives for duplicating L7's: the
# sibling keeps them private.
# ---------------------------------------------------------------------------

proc packageDefNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError,
    "fixture drift: no package named " & name & " is registered")

proc snapshotOf(package: string): ServiceInterfaceSnapshot =
  serviceInterfaceSnapshot(toProjectInterface(packageDefNamed(package)),
    ServiceName)

proc declaredDefFromLift(package: string): DslServiceDef =
  let pi = toProjectInterface(packageDefNamed(package))
  for svc in pi.publicServices:
    if svc.name != ServiceName:
      continue
    return DslServiceDef(
      packageName: package, serviceName: svc.name,
      identity: ServiceIdentityDef(
        kind: ServiceIdentityKind(ord(svc.identityMode)),
        stableId: svc.identityStableId),
      scope: ServiceScope(ord(svc.scope)))
  raise newException(ValueError,
    "fixture drift: " & package & " lifts no service " & ServiceName)

var caseCounter = 0

proc throwawayRoot(label: string): string =
  ## A throwaway directory, never `.repro/` and never a live tree.
  caseCounter.inc
  result = getTempDir() / ("repro-cvdead-" & $getCurrentProcessId() &
    "-" & $caseCounter & "-" & label)
  createDir(result)

proc keyFor(root: string): ServiceInstanceKey =
  ## `workspaceId` is supplied because the fixture declares `scope
  ## workspace`; without it the scope degrades to `project`.
  serviceInstanceKey(declaredDefFromLift(Package),
    ServiceScopeContext(projectRoot: canonicalRoot(root),
      workspaceRoot: canonicalRoot(root), workspaceId: "cvdead-workspace",
      user: "cvdeadtester"),
    [], "dev")

# ---------------------------------------------------------------------------
# Real instances, and the zombie they are turned into.
# ---------------------------------------------------------------------------

proc instanceCommand(): seq[string] =
  @["sh", "-c", "while :; do sleep 1; done"]

var spawned: seq[ServiceInstanceProcess] = @[]

proc reapEverySpawnedInstance() =
  ## The real stop, which probes first and so also REAPS a zombie this
  ## file left behind: a case that fails before the converge under test
  ## would otherwise leave the corpse in the process table.
  for process in spawned:
    discard stopServiceInstanceProcess(process, graceMs = 1500)
  spawned.setLen(0)

proc freshRegistry(storeRoot: string): ServiceInstanceRegistry =
  openServiceInstanceRegistry(storeRoot, serviceInstanceLivenessProbe())

proc convergeRequestFor(key: ServiceInstanceKey; holderId,
                        workingDir: string;
                        command = instanceCommand();
                        replace = false): DaemonServiceConvergeRequest =
  ## The request the CLI sends, with the generation ESTABLISHED as fresh:
  ## an absent one refuses with `RefuseUnknownProvenance` before liveness
  ## is relevant, and both snapshots here come from one in-process lift,
  ## so there is no artifact for either to be stale against.
  DaemonServiceConvergeRequest(
    scope: dlsUser,
    keyJson: encodeServiceInstanceKey(key),
    snapshotJson: encodeServiceInterfaceSnapshot(snapshotOf(Package)),
    holderId: holderId,
    ttlSeconds: -1,          ## negative == `keep`, per the field's doc
    command: command,
    workingDir: workingDir,
    replace: replace,
    force: false,
    generationJson: encodeServiceArtifactGenerationCheck(
      freshLiftGeneration("<constructed in-process>",
        "dss11_resolver_fixtures", "dss11_resolver_fixtures",
        "same-generation-by-construction")))

proc trackRegistered(registry: ServiceInstanceRegistry) =
  for address, entry in registry.entries:
    spawned.add(entry.record.process)

proc materialiseRunning(registry: var ServiceInstanceRegistry;
                        key: ServiceInstanceKey;
                        holderId, workingDir: string): int =
  ## Put a RUNNING instance in the registry through the real handler body
  ## and answer its pid.
  let response = applyServiceConverge(registry,
    convergeRequestFor(key, holderId, workingDir))
  doAssert response.ok,
    "fixture could not materialise the instance: " & response.diagnostic
  doAssert response.outcome == outcomeWord(scoMaterialise),
    "fixture expected a materialise and got " & response.outcome &
    ": " & response.diagnostic
  registry.trackRegistered()
  int(response.pid)

proc procState(pid: int): char =
  ## Field 3 of `/proc/<pid>/stat`, or '\0' when there is no such entry.
  ## Read after the LAST `)`, because field 2 is `(comm)` and a command
  ## name may itself contain spaces or parentheses.
  ## https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html
  let path = "/proc/" & $pid & "/stat"
  let text =
    try: readFile(path)
    except IOError, OSError: return '\0'
  let close = text.rfind(')')
  if close < 0 or close + 2 >= text.len:
    return '\0'
  text[close + 2]

proc killIntoZombie(pid: int) =
  ## SIGKILL the instance and wait until it is an UNREAPED corpse, then
  ## assert the two facts that make this the issue's shape rather than an
  ## easier one. Reads `/proc` only: the registry's probe would REAP the
  ## child, which is exactly the side effect this must not have.
  doAssert kill(Pid(pid), SIGKILL) == 0'i32,
    "SIGKILL to the fixture instance (pid " & $pid & ") failed"
  var waited = 0
  while procState(pid) != 'Z' and waited < ZombieWaitMs:
    sleep(20)
    waited.inc(20)
  doAssert procState(pid) == 'Z',
    "the killed instance (pid " & $pid & ") did not become a zombie " &
    "within " & $ZombieWaitMs & " ms; state is '" & procState(pid) & "'"

proc deadInstanceFixture(label: string):
    tuple[root: string; registry: ServiceInstanceRegistry;
          key: ServiceInstanceKey; holder: string; deadPid: int] =
  ## A registry holding ONE recorded instance whose process is a zombie.
  let root = throwawayRoot(label)
  var registry = freshRegistry(root / "store")
  let key = keyFor(root)
  let holder = serviceLeaseHolderId(throwawayRoot("consumer-" & label))
  let pid = registry.materialiseRunning(key, holder, root)
  killIntoZombie(pid)
  (root: root, registry: registry, key: key, holder: holder, deadPid: pid)

suite "L7 §4.5 — converge does not attach to an instance whose process died":
  teardown:
    # After every case, including a failing one, for the reason the
    # D-SS11 sibling gives: a case that aborts on an early `check` would
    # otherwise leave its `sleep` loop running for the rest of the suite.
    reapEverySpawnedInstance()

  test "THE CONTROL: the zombie would fool a kill -0 probe":
    # The positive control, stated as its own case so its failure reads
    # as a fixture failure rather than as the behaviour under test. If
    # either fact were false the cases below would pass for ANY probe.
    var fx = deadInstanceFixture("control")
    check procState(fx.deadPid) == 'Z'
    check kill(Pid(fx.deadPid), 0) == 0'i32
    # And the registry still names it: nothing between the kill and the
    # next converge has dropped the record.
    check fx.registry.lookupServiceInstance(fx.key).isSome

  test "a request carrying a command materialises a replacement":
    var fx = deadInstanceFixture("withcommand")
    let response = applyServiceConverge(fx.registry,
      convergeRequestFor(fx.key, fx.holder, fx.root))
    fx.registry.trackRegistered()
    checkpoint("outcome=" & response.outcome & " pid=" & $response.pid &
      " deadPid=" & $fx.deadPid & " diagnostic=" & response.diagnostic)
    # THE ASSERTION. Before the fix this was `AttachSilently` naming the
    # dead pid, with `hadInstance` true.
    check response.ok
    check response.outcome == outcomeWord(scoMaterialise)
    check not response.hadInstance
    check response.pid > 0
    check int(response.pid) != fx.deadPid
    # The replacement is a running process, and the registry records it.
    let entry = fx.registry.lookupServiceInstance(fx.key)
    check entry.isSome
    if entry.isSome:
      check entry.get.record.process.pid == int(response.pid)
      check serviceInstanceLivenessProbe()(
        entry.get.record.process.processIdentity) == silLive
    # The probe that answered dead REAPED the corpse, which is the side
    # effect the daemon owes its children: it no longer lingers as `Z`.
    check procState(fx.deadPid) != 'Z'

  test "a command-less request is refused BY NAME, with the dead pid":
    # A resolver asks with no command: it can attach, never materialise.
    # Before the fix it attached to the zombie and then waited out the
    # readiness timeout; now it is told why there is nothing to attach to.
    var fx = deadInstanceFixture("nocommand")
    let response = applyServiceConverge(fx.registry,
      convergeRequestFor(fx.key, fx.holder, fx.root, command = @[]))
    checkpoint("outcome=" & response.outcome & " pid=" & $response.pid &
      " deadPid=" & $fx.deadPid & " diagnostic=" & response.diagnostic)
    check not response.ok
    check not response.hadInstance
    check "no instance is running at" in response.diagnostic
    check ("pid " & $fx.deadPid) in response.diagnostic
    # The dead record is gone from BOTH halves: the in-memory table and
    # the store a daemon restart would rebuild from.
    check fx.registry.lookupServiceInstance(fx.key).isNone
    var addresses: seq[string] = @[]
    for state in listStateRecords(fx.registry.registryStore()):
      addresses.add(state.address)
    check serviceInstanceAddress(fx.key) notin addresses

  test "`--replace` on a dead instance materialises fresh":
    # There is nothing to take over, so the takeover path's stop -- and
    # its refusal when a stop fails -- must not be reached at all.
    var fx = deadInstanceFixture("replace")
    let response = applyServiceConverge(fx.registry,
      convergeRequestFor(fx.key, fx.holder, fx.root, replace = true))
    fx.registry.trackRegistered()
    checkpoint("outcome=" & response.outcome & " pid=" & $response.pid &
      " deadPid=" & $fx.deadPid & " diagnostic=" & response.diagnostic)
    check response.ok
    check response.outcome == outcomeWord(scoMaterialise)
    check not response.hadInstance
    check response.pid > 0
    check int(response.pid) != fx.deadPid
    let entry = fx.registry.lookupServiceInstance(fx.key)
    check entry.isSome
    if entry.isSome:
      check serviceInstanceLivenessProbe()(
        entry.get.record.process.processIdentity) == silLive

  test "the DECISION names the dead pid and keeps `diagnostic` empty":
    # `convergeServiceInstance` directly, below the handler body, so the
    # carried pid is pinned where it is decided. `diagnostic` stays empty
    # because it is asserted empty for every `scoMaterialise`; the report
    # travels in `droppedDeadDetail` instead.
    var fx = deadInstanceFixture("decision")
    let decision = convergeServiceInstance(fx.registry, fx.key,
      snapshotOf(Package), fx.holder,
      freshLiftGeneration("<constructed in-process>",
        "dss11_resolver_fixtures", "dss11_resolver_fixtures",
        "same-generation-by-construction"))
    checkpoint("outcome=" & $decision.outcome &
      " droppedDeadPid=" & $decision.droppedDeadPid &
      " detail=" & decision.droppedDeadDetail)
    check decision.outcome == scoMaterialise
    check not decision.hadInstance
    check decision.diagnostic == ""
    check decision.droppedDeadPid == fx.deadPid
    check ("pid " & $fx.deadPid) in decision.droppedDeadDetail
    check fx.registry.lookupServiceInstance(fx.key).isNone

  test "NO REGRESSION: a LIVE instance is still attached silently":
    # The other half of the pair. Without it an implementation that
    # treated every recorded instance as dead would pass every case
    # above -- and would double-start every shared service.
    let root = throwawayRoot("live")
    var registry = freshRegistry(root / "store")
    let key = keyFor(root)
    let holder = serviceLeaseHolderId(throwawayRoot("consumer-live"))
    let pid = registry.materialiseRunning(key, holder, root)
    let second = serviceLeaseHolderId(throwawayRoot("consumer-live-2"))
    let response = applyServiceConverge(registry,
      convergeRequestFor(key, second, root))
    checkpoint("outcome=" & response.outcome & " pid=" & $response.pid &
      " diagnostic=" & response.diagnostic)
    check response.ok
    check response.outcome == outcomeWord(scoAttachSilently)
    check response.hadInstance
    check int(response.pid) == pid
    check registry.registeredServiceInstances().len == 1
    # And a live attach reports no dropped record.
    let decision = convergeServiceInstance(registry, key,
      snapshotOf(Package), second,
      freshLiftGeneration("<constructed in-process>",
        "dss11_resolver_fixtures", "dss11_resolver_fixtures",
        "same-generation-by-construction"))
    check decision.outcome == scoAttachSilently
    check decision.droppedDeadPid == 0
    check decision.droppedDeadDetail == ""
