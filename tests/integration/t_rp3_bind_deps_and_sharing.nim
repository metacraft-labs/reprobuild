## RP3 (Project-Provider-Runtime-Protocol.milestones.org) — BindDependencies +
## cross-consumer provider-session sharing + observed-input propagation
## (Provider-Runtime-Protocol-v1.md §3-4).
##
## Builds THREE real provider binaries — one dependency library and two
## distinct consumers — and proves, non-vacuously, the three RP3 gates:
##
##   1. SHARING (v1 §4): two distinct consumers that bind the SAME dependency
##      (same ProviderArtifactId ⇒ same ProviderSessionKey) converge on ONE
##      launched dependency provider (``launchCount == 1`` across both binds)
##      and both consumers' dependency handles reference the SAME live session
##      object. A DIFFERENT dependency version launches a distinct session
##      (non-vacuous: sharing is keyed, not unconditional).
##
##   2. BINDDEPENDENCIES HONORED (v1 §4): a consumer given a bound dependency
##      handle invokes THROUGH it (``useBoundDependency``) and its fragment
##      carries the dependency's realization; a consumer with NO binding for a
##      name it needs fails cleanly (the provider raises — it does NOT fall
##      back to ambient sibling discovery).
##
##   3. OBSERVED-INPUT PROPAGATION (v1 §3): the dependency invoke's
##      ``evaluationInputs`` (the dependency's own observed source read) cross
##      the boundary and appear on the CONSUMER edge, so a change to the
##      dependency's realization would invalidate the consumer. Non-vacuous: a
##      consumer that binds nothing does NOT gain the dependency's inputs.
##
## The providers are compiled by the RP1 edge (``compileProviderBinary``) with
## ``workDir = getCurrentDir()`` (the reprobuild repo root), mirroring
## ``t_rp2_provider_session_invoke.nim``.

import std/[os, strutils, tables, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash

import repro_project_dsl

# A dependency provider whose root fragment reads its own source file (so it
# carries a distinctive ``gevFileRead`` evaluation input the consumer edge
# should inherit). ``$1`` distinguishes two dependency versions.
const dependencyBodyTemplate = """
import repro_project_dsl

package rp3dep$1:
  build:
    discard
"""

# A consumer provider whose root ``build:`` body reaches its dependency ONLY
# through the engine-supplied binding (``useBoundDependency "dep"``). $1
# distinguishes two consumers; $2 toggles whether the body binds the
# dependency (the "no-binding fails cleanly" case uses "" here but still calls
# useBoundDependency, so it raises when unbound).
const consumerBodyTemplate = """
import repro_project_dsl

package rp3consumer$1:
  build:
    useBoundDependency("dep")
"""

# A consumer that needs NO dependency (binds nothing) — the non-vacuity
# control for observed-input propagation.
const plainConsumerBody = """
import repro_project_dsl

package rp3plain:
  build:
    discard
"""

const ProviderGraphRequestTypeId = "reprobuild.provider-graph-request.v1"
const ProviderGraphResponseTypeId = "reprobuild.provider-graph-response.v1"

proc rpBytesToStr(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc rpStrToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc rpMarshalRequest(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderRequest(
    TypedExtensionBox[ProviderGraphRequest](box).val))

proc rpUnmarshalRequest(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphRequest](
    typeId: ProviderGraphRequestTypeId,
    val: decodeProviderRequest(rpStrToBytes(jsonStr)))

proc rpMarshalResponse(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderResponse(
    TypedExtensionBox[ProviderGraphResponse](box).val))

proc rpUnmarshalResponse(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphResponse](
    typeId: ProviderGraphResponseTypeId,
    val: decodeProviderResponse(rpStrToBytes(jsonStr)))

proc registerRp3Codecs() =
  extensionRegistry[ProviderGraphRequestTypeId] = ExtensionMarshaler(
    marshal: rpMarshalRequest, unmarshal: rpUnmarshalRequest)
  extensionRegistry[ProviderGraphResponseTypeId] = ExtensionMarshaler(
    marshal: rpMarshalResponse, unmarshal: rpUnmarshalResponse)

registerRp3Codecs()

proc marshalRequest(request: ProviderGraphRequest): BoxedValue =
  BoxedValue(typeId: ProviderGraphRequestTypeId,
    jsonStr: extensionRegistry[ProviderGraphRequestTypeId].marshal(
      TypedExtensionBox[ProviderGraphRequest](
        typeId: ProviderGraphRequestTypeId, val: request)))

proc unmarshalResponse(box: BoxedValue): ProviderGraphResponse =
  check box.typeId == ProviderGraphResponseTypeId
  TypedExtensionBox[ProviderGraphResponse](
    extensionRegistry[ProviderGraphResponseTypeId].unmarshal(box.jsonStr)).val

type BuiltProvider = tuple[binary, artifactId, projectRoot, packageName: string]

proc buildProvider(tempRoot, tag, body, packageName: string): BuiltProvider =
  let projectRoot = tempRoot / tag
  let outDir = tempRoot / (tag & "-out")
  createDir(extendedPath(projectRoot))
  createDir(extendedPath(outDir))
  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), body)
  let interfacePath = outDir / (tag & "-interface.rbsz")
  let stubPath = outDir / (tag & "-interface.nim")
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / (tag & "-provider")
  let compilePath = outDir / (tag & "-provider-compile.rbsz")
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes),
   projectRoot: projectRoot,
   packageName: packageName)

proc rootRequest(p: BuiltProvider): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: p.artifactId,
    entryPointId: p.packageName & ".root",
    entryPointBodyHash: p.packageName & ".build.v1",
    reason: girColdStart,
    arguments: p.projectRoot,
    namespace: p.packageName,
    lockSliceId: "rp3-lock",
    activity: "default")

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp3"],
    lockSliceId: "rp3-lock",
    canonicalExecutionRoot: getCurrentDir())

proc artifactRef(p: BuiltProvider): ProviderArtifactRef =
  ProviderArtifactRef(
    binaryPath: p.binary,
    providerArtifactId: p.artifactId,
    workingDir: getCurrentDir())

# Open the dependency's shared session and invoke it ONCE, returning the
# handle (so callers can assert session identity) plus the resolved binding
# the engine will wire into a consumer.
proc resolveDependency(pool: ProviderSessionPool; dep: BuiltProvider):
    tuple[handle: ProviderHandle; binding: DependencyBinding; res: EntryPointResult] =
  let handle = pool.openProviderSession(dep.artifactRef(),
    defaultSessionPolicy(), engineHello())
  let res = handle.invokeEntryPoint(dep.packageName & ".root",
    @[marshalRequest(dep.rootRequest())])
  let binding = resolveDependencyBinding(handle, "dep",
    dep.packageName & ".root", res)
  (handle: handle, binding: binding, res: res)

suite "RP3 bind-deps + cross-consumer session sharing":

  test "two consumers binding the SAME dependency share ONE launched session; a different version does not":
    let tempRoot = getTempDir() / "rp3-share-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    let dep = buildProvider(tempRoot, "dep", dependencyBodyTemplate % "", "rp3dep")
    let consumerA = buildProvider(tempRoot, "ca",
      consumerBodyTemplate % "a", "rp3consumera")
    let consumerB = buildProvider(tempRoot, "cb",
      consumerBodyTemplate % "b", "rp3consumerb")

    let pool = newProviderSessionPool()
    defer: pool.closeAll()

    # Consumer A resolves + binds the dependency: the shared dependency session
    # is launched here (launchCount 1: dep) + the consumer session (2: ca).
    let depForA = pool.resolveDependency(dep)
    let consumerAHandle = pool.openProviderSession(consumerA.artifactRef(),
      defaultSessionPolicy(), engineHello())
    consumerAHandle.bindDependencies(@[depForA.binding])

    check pool.launchCount == 2  # dep + consumerA

    # Consumer B resolves the SAME dependency: openProviderSession returns the
    # pooled dependency session (no relaunch) — this is the "build once, share"
    # convergence. consumerB's own session is a new launch (3).
    let depForB = pool.resolveDependency(dep)
    check depForB.handle.session == depForA.handle.session   # SAME live session
    check depForB.handle.sessionKey == depForA.handle.sessionKey
    check depForB.handle.providerArtifactId == depForA.handle.providerArtifactId
    check pool.launchCount == 2  # dependency was NOT relaunched for B

    let consumerBHandle = pool.openProviderSession(consumerB.artifactRef(),
      defaultSessionPolicy(), engineHello())
    consumerBHandle.bindDependencies(@[depForB.binding])
    check pool.launchCount == 3  # + consumerB

    # NON-VACUITY: a DIFFERENT dependency version has a distinct
    # ProviderArtifactId ⇒ distinct ProviderSessionKey ⇒ a distinct launched
    # session (sharing is keyed, not unconditional).
    let depV2 = buildProvider(tempRoot, "depv2",
      dependencyBodyTemplate % "v2", "rp3depv2")
    check depV2.artifactId != dep.artifactId
    let depForV2 = pool.resolveDependency(depV2)
    check depForV2.handle.session != depForA.handle.session
    check depForV2.handle.sessionKey != depForA.handle.sessionKey
    check pool.launchCount == 4  # v2 is a fresh launch

  test "BindDependencies is honored: a bound consumer invokes through the handle; an unbound consumer fails cleanly":
    let tempRoot = getTempDir() / "rp3-bind-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    let dep = buildProvider(tempRoot, "dep", dependencyBodyTemplate % "", "rp3dep")
    let consumer = buildProvider(tempRoot, "ca",
      consumerBodyTemplate % "a", "rp3consumera")

    let pool = newProviderSessionPool()
    defer: pool.closeAll()

    let depResolved = pool.resolveDependency(dep)
    check depResolved.res.ok

    # BOUND: the engine wires the dependency handle in; the consumer's build
    # body calls useBoundDependency("dep") and the invoke succeeds, recording
    # the dependency's realization as a provider-dependency-result input.
    let consumerHandle = pool.openProviderSession(consumer.artifactRef(),
      defaultSessionPolicy(), engineHello())
    consumerHandle.bindDependencies(@[depResolved.binding])
    let boundRes = consumerHandle.invokeEntryPoint("rp3consumera.root",
      @[marshalRequest(consumer.rootRequest())])
    check boundRes.ok
    check boundRes.hasValue
    check boundRes.diagnostics.len == 0
    let boundFragment = unmarshalResponse(boundRes.value).fragment
    var sawDepResult = false
    for input in boundFragment.evaluationInputs:
      if input.kind == gevProviderDependencyResult and
          input.identity.endsWith(":dep"):
        sawDepResult = true
    check sawDepResult  # the dependency's realization crossed into the consumer

    # UNBOUND: a fresh consumer session with NO BindDependencies for "dep".
    # The build body's useBoundDependency("dep") must RAISE (no ambient sibling
    # discovery) — surfaced as a failed EntryPointResult with a diagnostic.
    var otherPolicy = defaultSessionPolicy()
    otherPolicy.trustTenantBoundary = "rp3-unbound"
    let unboundHandle = pool.openProviderSession(consumer.artifactRef(),
      otherPolicy, engineHello())
    let unboundRes = unboundHandle.invokeEntryPoint("rp3consumera.root",
      @[marshalRequest(consumer.rootRequest())])
    check not unboundRes.ok
    check unboundRes.diagnostics.len > 0
    var mentionedNoBinding = false
    for diag in unboundRes.diagnostics:
      if "no dependency bound" in diag.message:
        mentionedNoBinding = true
    check mentionedNoBinding

  test "the dependency's observed inputs propagate to the consumer edge":
    let tempRoot = getTempDir() / "rp3-inputs-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    let dep = buildProvider(tempRoot, "dep", dependencyBodyTemplate % "", "rp3dep")
    let consumer = buildProvider(tempRoot, "ca",
      consumerBodyTemplate % "a", "rp3consumera")
    let plain = buildProvider(tempRoot, "plain", plainConsumerBody, "rp3plain")

    let pool = newProviderSessionPool()
    defer: pool.closeAll()

    let depResolved = pool.resolveDependency(dep)
    # The dependency reads its own source file: it must carry at least one
    # observed input (else the propagation assertion would be vacuous).
    check depResolved.res.evaluationInputs.len > 0
    var depFileInput: GraphEvaluationInput
    var sawDepFile = false
    for input in depResolved.res.evaluationInputs:
      if input.kind == gevFileRead:
        depFileInput = input
        sawDepFile = true
    check sawDepFile

    # BOUND consumer: after invoke, the consumer's EntryPointResult
    # evaluationInputs must include the dependency's observed input (folded on
    # by the engine's invokeEntryPoint) so the consumer edge invalidates when
    # the dependency's realization changes.
    let consumerHandle = pool.openProviderSession(consumer.artifactRef(),
      defaultSessionPolicy(), engineHello())
    consumerHandle.bindDependencies(@[depResolved.binding])
    let boundRes = consumerHandle.invokeEntryPoint("rp3consumera.root",
      @[marshalRequest(consumer.rootRequest())])
    check boundRes.ok
    var consumerSawDepInput = false
    for input in boundRes.evaluationInputs:
      if input.kind == depFileInput.kind and
          input.identity == depFileInput.identity and
          input.digest == depFileInput.digest:
        consumerSawDepInput = true
    check consumerSawDepInput  # dependency's observed input crossed the boundary

    # The engine-side accessor exposes the same union for consumer-edge wiring.
    var accessorSawDepInput = false
    for input in consumerHandle.boundDependencyInputs():
      if input.identity == depFileInput.identity and
          input.digest == depFileInput.digest:
        accessorSawDepInput = true
    check accessorSawDepInput

    # NON-VACUITY: a consumer that binds NOTHING does NOT gain the dependency's
    # observed input — the propagation is real, not an artifact of every
    # provider seeing every file.
    let plainHandle = pool.openProviderSession(plain.artifactRef(),
      defaultSessionPolicy(), engineHello())
    let plainRes = plainHandle.invokeEntryPoint("rp3plain.root",
      @[marshalRequest(plain.rootRequest())])
    check plainRes.ok
    var plainSawDepInput = false
    for input in plainRes.evaluationInputs:
      if input.identity == depFileInput.identity:
        plainSawDepInput = true
    check not plainSawDepInput
