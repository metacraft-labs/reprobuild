## Typed-Extension-Interfaces M2 (opaque attr pass-through) — a consuming
## run-edge materializes-or-reuses + renews a ``stateGroup`` whose member is
## OUT-OF-TREE and whose attrs CODEC IS NOT REGISTERED IN THE RECONCILING
## ("CLI") PROCESS, only in the PROVIDER (serve) side.
##
## This is the REVERSE of ``t_run_consumes_session_store_out_of_tree`` — that
## test registers the member's attrs codec IN-PROCESS
## (``registerExtension[StateAttrs]("n3a.state")`` at module init), which MASKED
## the gap: the CLI is only a ROUTER for an out-of-tree provider's resources and
## must NOT need the member's codec. Here the reconciling process holds NO codec
## for the member type; the CLI-side ``inst.attrs`` is a ``RawExtensionBox``
## (opaque envelope bytes + typeId) produced by ``decodeResourceInstance``'s
## ``unmarshalAttrsOrRaw`` — never unmarshalled in-process. The provider process,
## which links the codec, re-decodes the SAME bytes.
##
## Proven NON-VACUOUSLY:
##   * FAILS-WITHOUT: with the strict old path (``unmarshalAttrs``) the CLI-side
##     ``decodeResourceInstance`` of the member HARD-ERRORS (KeyError) because the
##     codec is absent — asserted directly against the encoded bytes. The M2
##     pass-through (``unmarshalAttrsOrRaw``) instead yields a ``RawExtensionBox``.
##   * ROUND-TRIP: the bytes ``marshalAttrs`` re-emits from the CLI's raw box
##     equal the original marshalled attrs the provider re-decodes — an identity
##     round-trip through the CLI with no codec.
##   * MATERIALIZE + REUSE over the session: first reconcile stands the member up
##     in the PROVIDER CHILD (apply counter -> 1); a second within ttl REUSES
##     (store digest-match ⇒ ``rakNoOp``, no observe/apply over the wire ⇒ counter
##     stays 1) and RENEWS (the store deadline advances) — all while the CLI-side
##     member box stays a ``RawExtensionBox`` (asserted).
##
## Greppable gate name: t_run_consumes_opaque_out_of_tree.

import std/[os, options, tables, times, strutils, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources
import repro_cli_support            # reconcileConsumedStateGroups (the N3a bridge)

const NoDaemon = "/nonexistent/repro-m2-no-daemon.sock"

# The out-of-tree member type is ``m2.state``. Its attrs codec is registered in
# the PROVIDER only (providerBody below), NEVER in this reconciling process.
type
  StateAttrs = object
    worldPath*: string
    value*: string

# ---------------------------------------------------------------------------
# The provider. Identical fake-world shape to the N3a test: a per-resource FILE
# holding "<applyCounter>\n<value>". ``apply`` bumps the counter (the created-at
# witness) so a REUSE that runs no apply is provable.
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
  "m2:" & inst.address & ":" & a.worldPath

proc stDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  digestString("m2\x00" & inst.address & "\x00" & a.value)

proc stObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[StateAttrs](inst.attrs).val
  if fileExists(a.worldPath):
    let lines = readFile(a.worldPath).split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString("m2\x00" & inst.address & "\x00" & realized)
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

resourceType "m2.state":
  attrs: StateAttrs
  wrapper: m2State
  determinism: rdVolatile
  driver: stateDriver
  attr worldPath: string
  attr value: string

package m2prov:
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
  let interfacePath = outDir / "m2-interface.rbsz"
  let stubPath = outDir / "m2-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "m2-provider"
  let compilePath = outDir / "m2-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["m2"],
    lockSliceId: "m2-lock",
    canonicalExecutionRoot: getCurrentDir())

# ---------------------------------------------------------------------------
# Build the CLI-side member ``ResourceInstance`` the way the CLI actually gets
# it: as ENCODED resource-graph bytes it must DECODE without the codec. We
# encode the member with the codec momentarily registered (the producer emits
# the graph with the codec), capture the marshalled attrs bytes, then REMOVE the
# codec so the reconciling process is codec-free — exactly the CLI's posture.
# ---------------------------------------------------------------------------

proc encodeMemberWithTempCodec(worldPath, value: string):
    tuple[bytes: seq[byte]; attrsBytes: string] =
  registerExtension[StateAttrs]("m2.state")
  let inst = ResourceInstance(
    typeId: "m2.state", address: "topo-net",
    attrs: TypedExtensionBox[StateAttrs](typeId: "m2.state",
      val: StateAttrs(worldPath: worldPath, value: value)),
    determinism: rdVolatile)
  let bytes = encodeResourceInstance(inst)
  let attrsBytes = marshalAttrs(inst.attrs)
  # Drop the codec so the reconciling process no longer holds it.
  extensionRegistry.del("m2.state")
  (bytes: bytes, attrsBytes: attrsBytes)

proc scratchStore(sub: string): StateStore =
  let root = getHomeDir() / ".cache" /
    ("repro-m2-" & $getCurrentProcessId() & "-" & sub)
  removeDir(root)
  openStateStore(root)

suite "M2: opaque attr pass-through (out-of-tree, codec provider-only)":

  test "t_run_consumes_opaque_out_of_tree":
    let tempRoot = getTempDir() / "m2-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    let worldPath = tempRoot / "topo-net.world"
    check not fileExists(extendedPath(worldPath))

    let (memberBytes, origAttrsBytes) =
      encodeMemberWithTempCodec(extendedPath(worldPath), "up")

    # NON-VACUITY 1: the member type's codec is NOT registered in THIS process
    # now — neither the attrs marshaller nor the driver.
    check not extensionRegistry.contains("m2.state")
    check not isResourceProviderRegistered("m2.state")
    check isResourceProviderRegistered("reprobuild.run-edge-consumer.v1")

    # FAILS-WITHOUT proof: the strict old decode path (``unmarshalAttrs``) is
    # what ``decodeResourceInstance`` used pre-M2. Prove it would hard-error on
    # THIS member's attrs — i.e. the CLI could not even decode the graph.
    # (We drive the strict path directly with the same attrsTypeId + bytes.)
    expect KeyError:
      discard unmarshalAttrs("m2.state", origAttrsBytes)

    # M2 pass-through: ``decodeResourceInstance`` (which the CLI's
    # ``decodeResourceGraphPayload`` calls) now yields a RawExtensionBox instead
    # of erroring, carrying the opaque bytes + typeId.
    let member = decodeResourceInstance(memberBytes)
    check member.typeId == "m2.state"
    check member.address == "topo-net"
    check member.attrs of RawExtensionBox
    check RawExtensionBox(member.attrs).raw == origAttrsBytes

    # ROUND-TRIP: re-marshalling the raw box reproduces the original bytes
    # VERBATIM — the identity round-trip the session + store rely on.
    check marshalAttrs(member.attrs) == origAttrsBytes

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

    let store = scratchStore("opaque")
    # The CLI drives the reconcile with the RAW-BOX member — no codec in-process.
    let resources = @[member]
    let groups = @[StateGroupDef(name: "topology", members: @["topo-net"])]
    let consumes = @[RunEdgeLease(address: "topology",
      consumerId: "topology", policyKind: relDelayed, ttlSeconds: 30 * 60)]
    let t0 = fromUnix(1_700_000_000)

    # ── FIRST reconcile: materialize over the SESSION, with the store ────────
    let first = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, endpoint = NoDaemon, now = t0,
      sessionResolver = resolver)
    check first.missingGroups.len == 0
    check first.renewedGroups == @["topology"]
    # Materialized IN THE PROVIDER CHILD (which re-decoded the opaque bytes).
    check fileExists(extendedPath(worldPath))
    let afterFirst = readFile(extendedPath(worldPath)).split('\n')
    check afterFirst[0] == "1"
    check afterFirst[1] == "up"
    check hasStateRecord(store, "topo-net")
    let firstRec = readStateRecord(store, "topo-net")
    check firstRec.present
    check firstRec.effectiveDeadline.isSome
    check firstRec.effectiveDeadline.get == t0 + initDuration(minutes = 30)
    # The store stored the attrs OPAQUELY — byte-identical to the original.
    check firstRec.attrsTypeId == "m2.state"
    check firstRec.attrsJson == origAttrsBytes

    # The CLI-side member box was NEVER unmarshalled in-process: still raw.
    check member.attrs of RawExtensionBox
    check not extensionRegistry.contains("m2.state")

    # ── SECOND reconcile WITHIN ttl: REUSE (no re-apply) + RENEW ─────────────
    let t1 = t0 + initDuration(minutes = 10)
    let second = reconcileConsumedStateGroups(consumes, "topology-lease-smoke",
      resources, groups, store, endpoint = NoDaemon, now = t1,
      sessionResolver = resolver)
    check second.renewedGroups == @["topology"]
    let afterSecond = readFile(extendedPath(worldPath)).split('\n')
    check afterSecond[0] == "1"                    # still 1: NOT re-applied
    check afterSecond[1] == "up"
    let secondRec = readStateRecord(store, "topo-net")
    check secondRec.effectiveDeadline.isSome
    check secondRec.effectiveDeadline.get == t1 + initDuration(minutes = 30)
    check secondRec.effectiveDeadline.get > firstRec.effectiveDeadline.get
    check second.daemonSent.len == 0

    check second.reconciled.len == 1
    var netAction = ResourceActionKind.rakNoOp
    for a in second.reconciled[0].actions:
      if a.address == "topo-net": netAction = a.kind
    check netAction == rakNoOp

    # Still opaque at the very end — codec never entered this process.
    check member.attrs of RawExtensionBox
    check not extensionRegistry.contains("m2.state")
