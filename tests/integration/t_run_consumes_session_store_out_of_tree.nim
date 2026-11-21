## Named-Runnable-Edges N3a (Named-Runnable-Edges.md §3.2) — a consuming
## run-edge materializes-or-reuses + renews a ``stateGroup`` whose members are
## OUT-OF-TREE, over a PROVIDER SESSION, WITH the L1 state store.
##
## This is the N3 half N2 deferred: the N2 bridge (``reconcileConsumedStateGroups``)
## drove the IN-PROCESS ``reconcileResources``, which hard-errors on a member
## ``typeId`` whose driver the ``repro`` CLI does not link. Real topology
## ``stateGroup`` members are gosti Incus resources whose drivers are NOT
## linked; this test proves the bridge now routes such a group to the
## session-backed ``reconcileResourcesViaSession(store)`` while the always-linked
## synthetic run-edge-consumer runs in-process, in ONE pass, so the consumer's
## ``consumes`` edges drive the session-materialized member's store-backed
## reuse + renew.
##
## Proven NON-VACUOUSLY, mirroring the RP5b test:
##   * the member type's driver is NOT registered in the engine (test) process —
##     an in-process reconcile would hard-error, so ONLY the session path can
##     converge it (asserted);
##   * the member's ``apply`` mutates a FAKE WORLD in the PROVIDER child process
##     and bumps a persisted APPLY COUNTER — the created-at witness. First
##     reconcile materializes (counter 1); a second WITHIN ttl REUSES (store
##     digest-match ⇒ ``rakNoOp``, no observe/apply over the wire ⇒ counter
##     stays 1) and RENEWS (the store deadline advances);
##   * the bridge is given the run-edge's harvested ``providerArtifacts`` and
##     the record it writes CARRIES that ref (Ephemeral-State-Leases.md §4.2) —
##     the durable half of the reap route, end to end through the CLI seam
##     ``repro run`` uses. Without it the record of an out-of-tree member names
##     no way back to the provider that can destroy it, and the only process
##     that knew the route is the one that exits
##     (reprobuild-pm/issues/
##     2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md).
##
## Greppable gate name: t_run_consumes_session_store_out_of_tree.

import std/[os, options, tables, times, strutils, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources
import repro_cli_support            # reconcileConsumedStateGroups (the N3a bridge)

const NoDaemon = "/nonexistent/repro-n3a-no-daemon.sock"

# The engine side holds ONLY the attrs marshaller (RP5a boundary) — never the
# driver. The out-of-tree member type is ``n3a.state``.
type
  StateAttrs = object
    worldPath*: string
    value*: string

# ---------------------------------------------------------------------------
# The provider. ``n3a.state``'s fake world is a per-resource FILE holding
# "<applyCounter>\n<value>": ``apply`` increments the counter each time it runs
# and stamps the value; ``observe`` reads it back. Because the counter only
# advances on a real ``apply``, the engine can prove a REUSE ran no apply.
# ---------------------------------------------------------------------------

const providerBody = """
import std/[options, os, strutils]
import repro_project_dsl
import repro_resources

type
  StateAttrs = object
    worldPath*: string
    value*: string

proc stIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  "n3a:" & inst.address & ":" & a.worldPath

proc stDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  digestString("n3a\x00" & inst.address & "\x00" & a.value)

proc stObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString("n3a\x00" & inst.address & "\x00" & realized)
  else:
    result.present = false

proc stApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  if action == rakDestroy:
    if fileExists(a.worldPath): removeFile(a.worldPath)
    return ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: stIdentity(inst), present: false)
  # Bump the persisted APPLY COUNTER (the created-at witness) each real apply.
  var counter = 0
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    if lines.len >= 1:
      try: counter = parseInt(lines[0]) except ValueError: counter = 0
  inc counter
  writeFile(a.worldPath, $counter & "\n" & a.value)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: stIdentity(inst),
    postWriteDigest: stDigest(inst), present: true)

let stateDriver = ResourceProviderDriver(
  identity: stIdentity, digest: stDigest,
  observe: stObserve, apply: stApply)

resourceType "n3a.state":
  attrs: StateAttrs
  wrapper: n3aState
  determinism: rdVolatile
  driver: stateDriver
  attr worldPath: string
  attr value: string

package n3aprov:
  build:
    discard
"""

proc buildProvider(tempRoot: string): tuple[binary, artifactId: string] =
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  createDir(extendedPath(projectRoot))
  createDir(extendedPath(outDir))
  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  let interfacePath = outDir / "n3a-interface.rbsz"
  let stubPath = outDir / "n3a-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "n3a-provider"
  let compilePath = outDir / "n3a-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["n3a"],
    lockSliceId: "n3a-lock",
    canonicalExecutionRoot: getCurrentDir())

# The engine holds ONLY the attrs marshaller for the out-of-tree type.
registerExtension[StateAttrs]("n3a.state")

proc memberInstance(worldPath, value: string): ResourceInstance =
  ResourceInstance(
    typeId: "n3a.state", address: "topo-net",
    attrs: TypedExtensionBox[StateAttrs](typeId: "n3a.state",
      val: StateAttrs(worldPath: worldPath, value: value)),
    determinism: rdVolatile)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-n3a-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

suite "N3a: session+store leased-consumes bridge (out-of-tree, hermetic)":

  test "t_run_consumes_session_store_out_of_tree":
    let tempRoot = getTempDir() / "n3a-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    # NON-VACUITY: the member type is NOT linked in the engine (test) process,
    # so the N2 in-process path would hard-error — only the session path can
    # converge it. The synthetic run-edge-consumer type IS linked (registered
    # at module init), so the hybrid gate routes it in-process.
    check not isResourceProviderRegistered("n3a.state")
    check isResourceProviderRegistered("reprobuild.run-edge-consumer.v1")

    let worldPath = tempRoot / "topo-net.world"
    check not fileExists(extendedPath(worldPath))

    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    let artifact = ProviderArtifactRef(
      binaryPath: provider.binary,
      providerArtifactId: provider.artifactId,
      workingDir: getCurrentDir())
    let handle = pool.openProviderSession(artifact, defaultSessionPolicy(),
      engineHello())
    let resolver: ResourceSessionResolver = proc (typeId: string): ProviderHandle =
      handle

    let store = scratchStore("outoftree")
    let resources = @[memberInstance(extendedPath(worldPath), "up")]
    let groups = @[StateGroupDef(name: "topology", members: @["topo-net"])]
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let t0 = fromUnix(1_700_000_000)

    # The harvested per-typeId refs, in the shape the resource-graph metadata
    # hands `repro run` — the same values `buildRunEdgeSessionResolver` builds
    # the resolver from, so passing them to the bridge is what production does.
    let harvested = @[(typeId: "n3a.state",
      artifact: ResourceProviderArtifactRef(
        binaryPath: provider.binary,
        providerArtifactId: provider.artifactId,
        workingDir: getCurrentDir()))]

    # ── FIRST reconcile: materialize over the SESSION, with the store ────────
    let first = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, harvested, endpoint = NoDaemon, now = t0,
      sessionResolver = resolver)
    check first.missingGroups.len == 0
    check first.renewedGroups == @["topology"]
    # The member materialized IN THE PROVIDER CHILD (apply counter -> 1).
    check fileExists(extendedPath(worldPath))
    let afterFirst = readFile(extendedPath(worldPath)).split('\n')
    check afterFirst[0] == "1"
    check afterFirst[1] == "up"
    # The store recorded the member + the lease held by the run-edge name.
    check hasStateRecord(store, "topo-net")
    let firstRec = readStateRecord(store, "topo-net")
    check firstRec.present
    check firstRec.effectiveDeadline.isSome
    check firstRec.effectiveDeadline.get == t0 + initDuration(minutes = 30)
    # THE DURABLE REAP ROUTE (§4.2): the bridge threaded `providerArtifacts`
    # into the session reconcile, which recorded the ref for this member's type.
    # A reaper with no registry and no daemon can now open a session to exactly
    # this provider knowing only the store.
    check firstRec.providerArtifact.isSome
    check firstRec.providerArtifact.get.binaryPath == provider.binary
    check firstRec.providerArtifact.get.providerArtifactId ==
      provider.artifactId
    check firstRec.providerArtifact.get.workingDir == getCurrentDir()
    # ...and the sweep's own resolution agrees: this store yields one artifact,
    # for this type, so the reap transport for it is the session.
    let derived = providerArtifactsOfRecords(listStateRecords(store))
    check derived.len == 1
    check derived[0].typeId == "n3a.state"
    check derived[0].artifact.binaryPath == provider.binary

    # The synthetic consumer record exists (never-reap bookkeeping) and names
    # NO artifact: its driver is always linked and it has no provider binary,
    # so claiming one would make its reap launch an unrelated provider.
    check hasStateRecord(store, "topology-lease-smoke::consumes::topology")
    check readStateRecord(store,
      "topology-lease-smoke::consumes::topology").providerArtifact.isNone

    # ── SECOND reconcile WITHIN ttl: REUSE (no re-apply) + RENEW ─────────────
    let t1 = t0 + initDuration(minutes = 10)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, harvested, endpoint = NoDaemon, now = t1,
      sessionResolver = resolver)
    check second.renewedGroups == @["topology"]
    # REUSE witness: the provider's apply counter is UNCHANGED (no apply ran
    # over the wire — the store digest-match short-circuited it).
    let afterSecond = readFile(extendedPath(worldPath)).split('\n')
    check afterSecond[0] == "1"                    # still 1: NOT re-applied
    check afterSecond[1] == "up"
    # RENEW witness: the store deadline advanced.
    let secondRec = readStateRecord(store, "topo-net")
    check secondRec.effectiveDeadline.isSome
    check secondRec.effectiveDeadline.get == t1 + initDuration(minutes = 30)
    check secondRec.effectiveDeadline.get > firstRec.effectiveDeadline.get
    # The reap route survives the REUSE pass, which rewrites the record without
    # applying anything over the wire.
    check secondRec.providerArtifact.isSome
    check secondRec.providerArtifact.get.binaryPath == provider.binary
    # No daemon reached in this hermetic run.
    check second.daemonSent.len == 0

    # ── The member action on the reuse pass was a no-op (no wire apply) ──────
    check second.reconciled.len == 1
    var netAction = ResourceActionKind.rakNoOp
    for a in second.reconciled[0].actions:
      if a.address == "topo-net": netAction = a.kind
    check netAction == rakNoOp
