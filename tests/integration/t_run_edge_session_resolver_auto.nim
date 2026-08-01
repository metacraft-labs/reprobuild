## Named-Runnable-Edges N3b step 1 (Named-Runnable-Edges.md §3.2) — the
## ``repro run`` path AUTO-BUILDS the out-of-tree session resolver from the
## resource-graph metadata's provider-artifact refs, WITHOUT a test injecting
## it, and materializes an out-of-tree ``stateGroup`` member over that session.
##
## N3a proved ``reconcileConsumedStateGroups`` reconciles an out-of-tree member
## over a session — but only when a TEST hand-built the ``ProviderArtifactRef``,
## opened the session, and injected the resolver. In production
## ``runReproRunCommand`` must construct that resolver itself. N3b carries the
## per-typeId provider-artifact ref in the ``reprobuild.resource-graph.v1``
## metadata (``registerResourceProviderArtifact`` -> harvest -> decode) and
## ``buildRunEdgeSessionResolver`` (the CLI-side twin of the daemon reaper's
## ``buildLeaseReapTransport``) turns those refs into the resolver.
##
## This test exercises the AUTO path end-to-end:
##   1. build a mock out-of-tree provider (its driver is NOT linked here);
##   2. ENCODE + DECODE the resource-graph metadata carrying the provider-
##      artifact ref (the exact codec ``buildPackageFragment`` /
##      ``aggregateResourceGraph`` use), proving the ref survives the wire;
##   3. call ``buildRunEdgeSessionResolver`` on the DECODED refs (the same
##      builder ``runReproRunCommand`` calls) — NOT a hand-built resolver;
##   4. drive ``reconcileConsumedStateGroups`` with THAT resolver and prove the
##      member materializes in the provider child (apply counter -> 1) + the
##      store records the lease.
##
## The metadata round-trip + the builder ARE the production path; the test
## drives them directly rather than spinning a full ``repro run`` CLI so the
## gate stays hermetic (no recipe eval / no daemon).
##
## Greppable gate name: t_run_edge_session_resolver_auto.

import std/[os, options, tables, times, strutils, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources
import repro_cli_support            # buildRunEdgeSessionResolver + reconcileConsumedStateGroups

const NoDaemon = "/nonexistent/repro-n3b-no-daemon.sock"

type
  StateAttrs = object
    worldPath*: string
    value*: string

# The provider is byte-identical in shape to N3a's mock: ``n3b.state``'s fake
# world is a per-resource FILE holding "<applyCounter>\n<value>". A real apply
# bumps the counter; observe reads it back.
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
  "n3b:" & inst.address & ":" & a.worldPath

proc stDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  digestString("n3b\x00" & inst.address & "\x00" & a.value)

proc stObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString("n3b\x00" & inst.address & "\x00" & realized)
  else:
    result.present = false

proc stApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  if action == rakDestroy:
    if fileExists(a.worldPath): removeFile(a.worldPath)
    return ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: stIdentity(inst), present: false)
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

resourceType "n3b.state":
  attrs: StateAttrs
  wrapper: n3bState
  determinism: rdVolatile
  driver: stateDriver
  attr worldPath: string
  attr value: string

package n3bprov:
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
  let interfacePath = outDir / "n3b-interface.rbsz"
  let stubPath = outDir / "n3b-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "n3b-provider"
  let compilePath = outDir / "n3b-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

# The engine holds ONLY the attrs marshaller for the out-of-tree type.
registerExtension[StateAttrs]("n3b.state")

proc memberInstance(worldPath, value: string): ResourceInstance =
  ResourceInstance(
    typeId: "n3b.state", address: "topo-net",
    attrs: TypedExtensionBox[StateAttrs](typeId: "n3b.state",
      val: StateAttrs(worldPath: worldPath, value: value)),
    determinism: rdVolatile)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-n3b-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

suite "N3b: auto-built out-of-tree session resolver (hermetic)":

  test "t_run_edge_session_resolver_auto":
    let tempRoot = getTempDir() / "n3b-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    # NON-VACUITY: the member type is NOT linked here, so only a session can
    # converge it. The synthetic run-edge-consumer IS linked (module init).
    check not isResourceProviderRegistered("n3b.state")
    check isResourceProviderRegistered("reprobuild.run-edge-consumer.v1")

    let worldPath = tempRoot / "topo-net.world"
    check not fileExists(extendedPath(worldPath))

    # ── The N3b metadata carrier: register the provider-artifact ref, harvest
    #    it into the ``resource-graph.v1`` payload, and round-trip through the
    #    exact codec ``buildPackageFragment`` + ``aggregateResourceGraph`` use.
    #    This is what carries the provider BINARY ref to ``repro run`` time.
    clearResourceProviderArtifacts()
    registerResourceProviderArtifact("n3b.state",
      ResourceProviderArtifactRef(
        binaryPath: provider.binary,
        providerArtifactId: provider.artifactId,
        workingDir: getCurrentDir()))
    let resources = @[memberInstance(extendedPath(worldPath), "up")]
    let groups = @[StateGroupDef(name: "topology", members: @["topo-net"])]

    let payload = encodeResourceGraphPayload(resources, groups,
      registeredResourceProviderArtifacts())
    let decoded = decodeResourceGraphPayload(payload)
    # The provider-artifact ref survived the metadata wire (v2 section).
    check decoded.providerArtifacts.len == 1
    check decoded.providerArtifacts[0].typeId == "n3b.state"
    check decoded.providerArtifacts[0].artifact.binaryPath == provider.binary
    check decoded.providerArtifacts[0].artifact.providerArtifactId ==
      provider.artifactId

    # ── The AUTO-BUILT resolver: ``runReproRunCommand`` calls exactly this on
    #    the DECODED refs. NO hand-built ProviderArtifactRef / injected handle.
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    let resolver = buildRunEdgeSessionResolver(decoded.providerArtifacts, pool)
    check resolver != nil          # non-nil because an out-of-tree ref exists

    let store = scratchStore("auto")
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let t0 = fromUnix(1_700_000_000)

    # ── Reconcile over the AUTO-BUILT session, with the store ───────────────
    let first = reconcileConsumedStateGroups(consumes, "topology-lease-auto",
      decoded.resources, decoded.groups, store, endpoint = NoDaemon, now = t0,
      sessionResolver = resolver)
    check first.missingGroups.len == 0
    check first.renewedGroups == @["topology"]
    # Materialized IN THE PROVIDER CHILD via the auto-built session.
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

    # ── REUSE within ttl over the same pooled session (no re-apply) ─────────
    let t1 = t0 + initDuration(minutes = 10)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-auto",
      decoded.resources, decoded.groups, store, endpoint = NoDaemon, now = t1,
      sessionResolver = resolver)
    check second.renewedGroups == @["topology"]
    let afterSecond = readFile(extendedPath(worldPath)).split('\n')
    check afterSecond[0] == "1"                    # still 1: NOT re-applied
    let secondRec = readStateRecord(store, "topo-net")
    check secondRec.effectiveDeadline.isSome
    check secondRec.effectiveDeadline.get == t1 + initDuration(minutes = 30)
    check secondRec.effectiveDeadline.get > firstRec.effectiveDeadline.get

  test "all-in-tree keeps the in-process fast path (nil resolver)":
    # No provider-artifact ref registered ⇒ the metadata stays v1 (byte-
    # identical to N2) and the builder returns nil so the in-process reconcile
    # path is chosen. This guards the additive/non-empty-only invariant AND the
    # nil-resolver fall-through.
    clearResourceProviderArtifacts()
    let resources = @[memberInstance("/tmp/unused", "x")]
    let groups = @[StateGroupDef(name: "topology", members: @["topo-net"])]

    # v1 layout (no provider section) is byte-identical whether we ask the
    # encoder for the empty artifact list explicitly or omit it.
    let v1a = encodeResourceGraphPayload(resources, groups)
    let v1b = encodeResourceGraphPayload(resources, groups,
      registeredResourceProviderArtifacts())
    check v1a == v1b

    let decoded = decodeResourceGraphPayload(v1a)
    check decoded.providerArtifacts.len == 0
    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    check buildRunEdgeSessionResolver(decoded.providerArtifacts, pool) == nil
