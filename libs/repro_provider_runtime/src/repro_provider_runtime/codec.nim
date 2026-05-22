import repro_core
import repro_provider_runtime/types

const
  ProviderGraphMagic = [byte(ord('R')), byte(ord('B')), byte(ord('P')), byte(ord('G'))]
  ProviderGraphVersion = 1'u16
  ProviderRequestType = 1'u16
  ProviderResponseType = 2'u16
  ProviderSnapshotType = 3'u16

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc requestKind(value: byte): ProviderRequestKind =
  if value > byte(ord(prkDevEnvIntrospection)):
    raiseEnvelopeError(eeMalformed, "invalid provider request kind")
  ProviderRequestKind(value)

proc responseKind(value: byte): ProviderResponseKind =
  if value > byte(ord(pskDevEnvResult)):
    raiseEnvelopeError(eeMalformed, "invalid provider response kind")
  ProviderResponseKind(value)

proc entryPointKind(value: byte): GraphEntryPointKind =
  if value > byte(ord(gpkDevEnvIntrospection)):
    raiseEnvelopeError(eeMalformed, "invalid graph entry point kind")
  GraphEntryPointKind(value)

proc invocationReason(value: byte): GraphInvocationReason =
  if value > byte(ord(girExplicitUserRequest)):
    raiseEnvelopeError(eeMalformed, "invalid graph invocation reason")
  GraphInvocationReason(value)

proc evaluationInputKind(value: byte): GraphEvaluationInputKind =
  if value > byte(ord(gevActivitySelection)):
    raiseEnvelopeError(eeMalformed, "invalid graph evaluation input kind")
  GraphEvaluationInputKind(value)

proc shellOpKind(value: byte): DevEnvShellOpKind =
  if value > byte(ord(deskSetWorkingDirectory)):
    raiseEnvelopeError(eeMalformed, "invalid dev-env shell op kind")
  DevEnvShellOpKind(value)

proc diagnosticSeverity(value: byte): DevEnvDiagnosticSeverity =
  if value > byte(ord(dedsError)):
    raiseEnvelopeError(eeMalformed, "invalid dev-env diagnostic severity")
  DevEnvDiagnosticSeverity(value)

proc nodeKind(value: byte): GraphNodeKind =
  if value > byte(ord(gnkMetadata)):
    raiseEnvelopeError(eeMalformed, "invalid graph node kind")
  GraphNodeKind(value)

proc edgeKind(value: byte): GraphEdgeKind =
  if value > byte(ord(gekInvalidates)):
    raiseEnvelopeError(eeMalformed, "invalid graph edge kind")
  GraphEdgeKind(value)

proc effectKind(value: byte): OwnedEffectKind =
  if value > byte(ord(oekResource)):
    raiseEnvelopeError(eeMalformed, "invalid owned effect kind")
  OwnedEffectKind(value)

proc cleanupPolicy(value: byte): CleanupPolicy =
  if value > byte(ord(cplNeverDeleteAutomatically)):
    raiseEnvelopeError(eeMalformed, "invalid cleanup policy")
  CleanupPolicy(value)

proc writeDescriptor(outp: var seq[byte]; value: GraphEntryPointDescriptor) =
  outp.writeString(value.id)
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.stableName)
  outp.writeString(value.bodyHash)
  outp.writeString(value.argumentSchemaId)
  outp.writeString(value.outputSchemaId)

proc readDescriptor(bytes: openArray[byte]; pos: var int):
    GraphEntryPointDescriptor =
  GraphEntryPointDescriptor(
    id: readString(bytes, pos),
    kind: entryPointKind(readByte(bytes, pos)),
    stableName: readString(bytes, pos),
    bodyHash: readString(bytes, pos),
    argumentSchemaId: readString(bytes, pos),
    outputSchemaId: readString(bytes, pos))

proc writeManifest(outp: var seq[byte]; value: ProviderManifest) =
  outp.writeString(value.providerArtifactId)
  outp.writeU32Le(value.protocolVersion)
  outp.writeU32Le(uint32(value.entryPoints.len))
  for descriptor in value.entryPoints:
    outp.writeDescriptor(descriptor)

proc readManifest(bytes: openArray[byte]; pos: var int): ProviderManifest =
  result.providerArtifactId = readString(bytes, pos)
  result.protocolVersion = readU32Le(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.entryPoints = newSeq[GraphEntryPointDescriptor](count)
  for i in 0 ..< count:
    result.entryPoints[i] = readDescriptor(bytes, pos)

proc writeNode(outp: var seq[byte]; value: GraphNode) =
  outp.writeString(value.id)
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.stableName)
  outp.writeString(value.payload)

proc readNode(bytes: openArray[byte]; pos: var int): GraphNode =
  GraphNode(
    id: readString(bytes, pos),
    kind: nodeKind(readByte(bytes, pos)),
    stableName: readString(bytes, pos),
    payload: readString(bytes, pos))

proc writeEdge(outp: var seq[byte]; value: GraphEdge) =
  outp.writeString(value.id)
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.fromNode)
  outp.writeString(value.toNode)

proc readEdge(bytes: openArray[byte]; pos: var int): GraphEdge =
  GraphEdge(
    id: readString(bytes, pos),
    kind: edgeKind(readByte(bytes, pos)),
    fromNode: readString(bytes, pos),
    toNode: readString(bytes, pos))

proc writeEffect(outp: var seq[byte]; value: OwnedEffectClaim) =
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.stableName)
  outp.writeString(value.identity)
  outp.writeByte(byte(ord(value.cleanupPolicy)))
  outp.writeString(value.payload)

proc readEffect(bytes: openArray[byte]; pos: var int): OwnedEffectClaim =
  OwnedEffectClaim(
    kind: effectKind(readByte(bytes, pos)),
    stableName: readString(bytes, pos),
    identity: readString(bytes, pos),
    cleanupPolicy: cleanupPolicy(readByte(bytes, pos)),
    payload: readString(bytes, pos))

proc writeChildSpec(outp: var seq[byte]; value: GraphEntryPointInvocationSpec) =
  outp.writeString(value.entryPointId)
  outp.writeString(value.entryPointBodyHash)
  outp.writeString(value.arguments)
  outp.writeString(value.namespace)
  outp.writeString(value.stableName)

proc readChildSpec(bytes: openArray[byte]; pos: var int):
    GraphEntryPointInvocationSpec =
  GraphEntryPointInvocationSpec(
    entryPointId: readString(bytes, pos),
    entryPointBodyHash: readString(bytes, pos),
    arguments: readString(bytes, pos),
    namespace: readString(bytes, pos),
    stableName: readString(bytes, pos))

proc writeInput(outp: var seq[byte]; value: GraphEvaluationInput) =
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.identity)
  outp.writeString(value.digest)
  outp.writeStringSeq(value.directoryMembers)
  outp.writeString(value.memberEntryPointId)
  outp.writeString(value.memberEntryPointBodyHash)
  outp.writeString(value.memberArgumentRoot)
  outp.writeString(value.memberNamespace)

proc readInput(bytes: openArray[byte]; pos: var int): GraphEvaluationInput =
  GraphEvaluationInput(
    kind: evaluationInputKind(readByte(bytes, pos)),
    identity: readString(bytes, pos),
    digest: readString(bytes, pos),
    directoryMembers: readStringSeq(bytes, pos),
    memberEntryPointId: readString(bytes, pos),
    memberEntryPointBodyHash: readString(bytes, pos),
    memberArgumentRoot: readString(bytes, pos),
    memberNamespace: readString(bytes, pos))

proc writeFragmentPayload(outp: var seq[byte]; value: GraphFragment;
                          includeDigest: bool) =
  outp.writeString(value.entryPointId)
  outp.writeString(value.entryPointBodyHash)
  outp.writeString(value.arguments)
  outp.writeString(value.namespace)
  outp.writeU32Le(uint32(value.nodes.len))
  for node in value.nodes:
    outp.writeNode(node)
  outp.writeU32Le(uint32(value.edges.len))
  for edge in value.edges:
    outp.writeEdge(edge)
  outp.writeU32Le(uint32(value.effectClaims.len))
  for effect in value.effectClaims:
    outp.writeEffect(effect)
  outp.writeU32Le(uint32(value.childEntryPoints.len))
  for child in value.childEntryPoints:
    outp.writeChildSpec(child)
  outp.writeU32Le(uint32(value.evaluationInputs.len))
  for input in value.evaluationInputs:
    outp.writeInput(input)
  if includeDigest:
    outp.writeString(value.fragmentDigest)

proc readFragment(bytes: openArray[byte]; pos: var int): GraphFragment =
  result.entryPointId = readString(bytes, pos)
  result.entryPointBodyHash = readString(bytes, pos)
  result.arguments = readString(bytes, pos)
  result.namespace = readString(bytes, pos)
  var count = int(readU32Le(bytes, pos))
  result.nodes = newSeq[GraphNode](count)
  for i in 0 ..< count:
    result.nodes[i] = readNode(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.edges = newSeq[GraphEdge](count)
  for i in 0 ..< count:
    result.edges[i] = readEdge(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.effectClaims = newSeq[OwnedEffectClaim](count)
  for i in 0 ..< count:
    result.effectClaims[i] = readEffect(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.childEntryPoints = newSeq[GraphEntryPointInvocationSpec](count)
  for i in 0 ..< count:
    result.childEntryPoints[i] = readChildSpec(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.evaluationInputs = newSeq[GraphEvaluationInput](count)
  for i in 0 ..< count:
    result.evaluationInputs[i] = readInput(bytes, pos)
  result.fragmentDigest = readString(bytes, pos)

proc writeDevEnvShellOp(outp: var seq[byte]; value: DevEnvShellOp) =
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.name)
  outp.writeString(value.value)
  outp.writeString(value.separator)
  outp.writeStringSeq(value.activityRequirements)

proc readDevEnvShellOp(bytes: openArray[byte]; pos: var int): DevEnvShellOp =
  DevEnvShellOp(
    kind: shellOpKind(readByte(bytes, pos)),
    name: readString(bytes, pos),
    value: readString(bytes, pos),
    separator: readString(bytes, pos),
    activityRequirements: readStringSeq(bytes, pos))

proc writeDevEnvTool(outp: var seq[byte]; value: DevEnvToolRequirement) =
  outp.writeString(value.logicalName)
  outp.writeString(value.packageSelector)
  outp.writeString(value.executableName)
  outp.writeStringSeq(value.policyPath)
  outp.writeStringSeq(value.activityRequirements)

proc readDevEnvTool(bytes: openArray[byte]; pos: var int): DevEnvToolRequirement =
  DevEnvToolRequirement(
    logicalName: readString(bytes, pos),
    packageSelector: readString(bytes, pos),
    executableName: readString(bytes, pos),
    policyPath: readStringSeq(bytes, pos),
    activityRequirements: readStringSeq(bytes, pos))

proc writeDevEnvTask(outp: var seq[byte]; value: DevEnvTaskMetadata) =
  outp.writeString(value.name)
  outp.writeString(value.description)
  outp.writeString(value.command)
  outp.writeStringSeq(value.activityRequirements)

proc readDevEnvTask(bytes: openArray[byte]; pos: var int): DevEnvTaskMetadata =
  DevEnvTaskMetadata(
    name: readString(bytes, pos),
    description: readString(bytes, pos),
    command: readString(bytes, pos),
    activityRequirements: readStringSeq(bytes, pos))

proc writeDevEnvService(outp: var seq[byte]; value: DevEnvServiceMetadata) =
  outp.writeString(value.name)
  outp.writeStringSeq(value.activityRequirements)
  outp.writeString(value.metadata)

proc readDevEnvService(bytes: openArray[byte]; pos: var int): DevEnvServiceMetadata =
  DevEnvServiceMetadata(
    name: readString(bytes, pos),
    activityRequirements: readStringSeq(bytes, pos),
    metadata: readString(bytes, pos))

proc writeDevEnvDiagnostic(outp: var seq[byte]; value: DevEnvDiagnostic) =
  outp.writeByte(byte(ord(value.severity)))
  outp.writeString(value.message)
  outp.writeString(value.sourceFile)
  outp.writeU32Le(uint32(max(value.sourceLine, 0)))

proc readDevEnvDiagnostic(bytes: openArray[byte]; pos: var int): DevEnvDiagnostic =
  DevEnvDiagnostic(
    severity: diagnosticSeverity(readByte(bytes, pos)),
    message: readString(bytes, pos),
    sourceFile: readString(bytes, pos),
    sourceLine: int(readU32Le(bytes, pos)))

proc writeDevEnvFingerprint(outp: var seq[byte]; value: DevEnvSourceFingerprint) =
  outp.writeString(value.kind)
  outp.writeString(value.identity)
  outp.writeString(value.digest)

proc readDevEnvFingerprint(bytes: openArray[byte]; pos: var int):
    DevEnvSourceFingerprint =
  DevEnvSourceFingerprint(
    kind: readString(bytes, pos),
    identity: readString(bytes, pos),
    digest: readString(bytes, pos))

proc writeDevEnvResult(outp: var seq[byte]; value: DevEnvResult) =
  outp.writeU32Le(value.schemaVersion)
  outp.writeString(value.providerArtifactId)
  outp.writeString(value.providerEntryPointId)
  outp.writeString(value.providerEntryPointBodyHash)
  outp.writeString(value.projectRoot)
  outp.writeString(value.lockSliceId)
  outp.writeStringSeq(value.selectedActivities)
  outp.writeStringSeq(value.declaredActivities)
  outp.writeU32Le(uint32(value.shellOps.len))
  for item in value.shellOps:
    outp.writeDevEnvShellOp(item)
  outp.writeU32Le(uint32(value.toolRequirements.len))
  for item in value.toolRequirements:
    outp.writeDevEnvTool(item)
  outp.writeU32Le(uint32(value.tasks.len))
  for item in value.tasks:
    outp.writeDevEnvTask(item)
  outp.writeU32Le(uint32(value.services.len))
  for item in value.services:
    outp.writeDevEnvService(item)
  outp.writeU32Le(uint32(value.diagnostics.len))
  for item in value.diagnostics:
    outp.writeDevEnvDiagnostic(item)
  outp.writeU32Le(uint32(value.evaluationInputs.len))
  for item in value.evaluationInputs:
    outp.writeInput(item)
  outp.writeU32Le(uint32(value.sourceFingerprints.len))
  for item in value.sourceFingerprints:
    outp.writeDevEnvFingerprint(item)

proc readDevEnvResult(bytes: openArray[byte]; pos: var int): DevEnvResult =
  result.schemaVersion = readU32Le(bytes, pos)
  result.providerArtifactId = readString(bytes, pos)
  result.providerEntryPointId = readString(bytes, pos)
  result.providerEntryPointBodyHash = readString(bytes, pos)
  result.projectRoot = readString(bytes, pos)
  result.lockSliceId = readString(bytes, pos)
  result.selectedActivities = readStringSeq(bytes, pos)
  result.declaredActivities = readStringSeq(bytes, pos)
  var count = int(readU32Le(bytes, pos))
  result.shellOps = newSeq[DevEnvShellOp](count)
  for i in 0 ..< count:
    result.shellOps[i] = readDevEnvShellOp(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.toolRequirements = newSeq[DevEnvToolRequirement](count)
  for i in 0 ..< count:
    result.toolRequirements[i] = readDevEnvTool(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.tasks = newSeq[DevEnvTaskMetadata](count)
  for i in 0 ..< count:
    result.tasks[i] = readDevEnvTask(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.services = newSeq[DevEnvServiceMetadata](count)
  for i in 0 ..< count:
    result.services[i] = readDevEnvService(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.diagnostics = newSeq[DevEnvDiagnostic](count)
  for i in 0 ..< count:
    result.diagnostics[i] = readDevEnvDiagnostic(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.evaluationInputs = newSeq[GraphEvaluationInput](count)
  for i in 0 ..< count:
    result.evaluationInputs[i] = readInput(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.sourceFingerprints = newSeq[DevEnvSourceFingerprint](count)
  for i in 0 ..< count:
    result.sourceFingerprints[i] = readDevEnvFingerprint(bytes, pos)

proc writeStoredFragment(outp: var seq[byte]; value: StoredGraphFragment) =
  outp.writeString(value.invocationKey)
  outp.writeString(value.providerArtifactId)
  outp.writeString(value.entryPointId)
  outp.writeString(value.entryPointBodyHash)
  outp.writeString(value.arguments)
  outp.writeString(value.argumentDigest)
  outp.writeString(value.lockSliceId)
  outp.writeString(value.activity)
  outp.writeString(value.namespace)
  outp.writeString(value.fragmentDigest)
  outp.writeU32Le(uint32(value.nodes.len))
  for node in value.nodes:
    outp.writeNode(node)
  outp.writeU32Le(uint32(value.edges.len))
  for edge in value.edges:
    outp.writeEdge(edge)
  outp.writeU32Le(uint32(value.effectClaims.len))
  for effect in value.effectClaims:
    outp.writeEffect(effect)
  outp.writeU32Le(uint32(value.childEntryPoints.len))
  for child in value.childEntryPoints:
    outp.writeChildSpec(child)
  outp.writeU32Le(uint32(value.evaluationInputs.len))
  for input in value.evaluationInputs:
    outp.writeInput(input)

proc readStoredFragment(bytes: openArray[byte]; pos: var int):
    StoredGraphFragment =
  result.invocationKey = readString(bytes, pos)
  result.providerArtifactId = readString(bytes, pos)
  result.entryPointId = readString(bytes, pos)
  result.entryPointBodyHash = readString(bytes, pos)
  result.arguments = readString(bytes, pos)
  result.argumentDigest = readString(bytes, pos)
  result.lockSliceId = readString(bytes, pos)
  result.activity = readString(bytes, pos)
  result.namespace = readString(bytes, pos)
  result.fragmentDigest = readString(bytes, pos)
  var count = int(readU32Le(bytes, pos))
  result.nodes = newSeq[GraphNode](count)
  for i in 0 ..< count:
    result.nodes[i] = readNode(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.edges = newSeq[GraphEdge](count)
  for i in 0 ..< count:
    result.edges[i] = readEdge(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.effectClaims = newSeq[OwnedEffectClaim](count)
  for i in 0 ..< count:
    result.effectClaims[i] = readEffect(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.childEntryPoints = newSeq[GraphEntryPointInvocationSpec](count)
  for i in 0 ..< count:
    result.childEntryPoints[i] = readChildSpec(bytes, pos)
  count = int(readU32Le(bytes, pos))
  result.evaluationInputs = newSeq[GraphEvaluationInput](count)
  for i in 0 ..< count:
    result.evaluationInputs[i] = readInput(bytes, pos)

proc writeHeader(outp: var seq[byte]; typeId: uint16; payloadLength: int) =
  outp.add(ProviderGraphMagic)
  outp.writeU16Le(ProviderGraphVersion)
  outp.writeU16Le(typeId)
  outp.writeU32Le(uint32(payloadLength))

proc payloadBounds(bytes: openArray[byte]; expectedType: uint16):
    tuple[first: int; last: int] =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated provider graph envelope")
  for i in 0 ..< 4:
    if bytes[i] != ProviderGraphMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown provider graph envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ProviderGraphVersion:
    raiseEnvelopeError(eeUnsupportedVersion,
      "unsupported provider graph envelope version " & $version)
  let typeId = readU16Le(bytes, pos)
  if typeId != expectedType:
    raiseEnvelopeError(eeUnknownType, "unexpected provider graph envelope type")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "provider graph envelope length mismatch")
  (first: pos, last: pos + payloadLength - 1)

proc payloadBytes(bytes: openArray[byte]; expectedType: uint16): seq[byte] =
  let bounds = payloadBounds(bytes, expectedType)
  if bounds.last < bounds.first:
    return @[]
  result = newSeq[byte](bounds.last - bounds.first + 1)
  for i in 0 ..< result.len:
    result[i] = bytes[bounds.first + i]

proc encodeProviderRequest*(value: ProviderGraphRequest): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeByte(byte(ord(value.kind)))
  payload.writeString(value.providerArtifactId)
  payload.writeString(value.entryPointId)
  payload.writeString(value.entryPointBodyHash)
  payload.writeByte(byte(ord(value.reason)))
  payload.writeString(value.arguments)
  payload.writeString(value.namespace)
  payload.writeString(value.lockSliceId)
  payload.writeString(value.activity)
  result.writeHeader(ProviderRequestType, payload.len)
  result.add(payload)

proc decodeProviderRequest*(bytes: openArray[byte]): ProviderGraphRequest =
  let payload = payloadBytes(bytes, ProviderRequestType)
  var pos = 0
  result.kind = requestKind(readByte(payload, pos))
  result.providerArtifactId = readString(payload, pos)
  result.entryPointId = readString(payload, pos)
  result.entryPointBodyHash = readString(payload, pos)
  result.reason = invocationReason(readByte(payload, pos))
  result.arguments = readString(payload, pos)
  result.namespace = readString(payload, pos)
  result.lockSliceId = readString(payload, pos)
  result.activity = readString(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing provider request payload bytes")

proc encodeProviderResponse*(value: ProviderGraphResponse): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeByte(byte(ord(value.kind)))
  payload.writeManifest(value.manifest)
  payload.writeFragmentPayload(value.fragment, includeDigest = true)
  if value.kind == pskDevEnvResult:
    payload.writeDevEnvResult(value.devEnv)
  payload.writeStringSeq(value.diagnostics)
  result.writeHeader(ProviderResponseType, payload.len)
  result.add(payload)

proc decodeProviderResponse*(bytes: openArray[byte]): ProviderGraphResponse =
  let payload = payloadBytes(bytes, ProviderResponseType)
  var pos = 0
  result.kind = responseKind(readByte(payload, pos))
  result.manifest = readManifest(payload, pos)
  result.fragment = readFragment(payload, pos)
  if result.kind == pskDevEnvResult:
    result.devEnv = readDevEnvResult(payload, pos)
  result.diagnostics = readStringSeq(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing provider response payload bytes")

proc encodeProviderSnapshot*(value: ProviderGraphSnapshot): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(value.providerArtifactId)
  payload.writeManifest(value.manifest)
  payload.writeU32Le(uint32(value.fragments.len))
  for fragment in value.fragments:
    payload.writeStoredFragment(fragment)
  result.writeHeader(ProviderSnapshotType, payload.len)
  result.add(payload)

proc decodeProviderSnapshot*(bytes: openArray[byte]): ProviderGraphSnapshot =
  let payload = payloadBytes(bytes, ProviderSnapshotType)
  var pos = 0
  result.providerArtifactId = readString(payload, pos)
  result.manifest = readManifest(payload, pos)
  let count = int(readU32Le(payload, pos))
  result.fragments = newSeq[StoredGraphFragment](count)
  for i in 0 ..< count:
    result.fragments[i] = readStoredFragment(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing provider snapshot payload bytes")

proc encodeFragmentForDigest*(value: GraphFragment): seq[byte] =
  result = @[]
  result.writeString(value.entryPointId)
  result.writeString(value.arguments)
  result.writeString(value.namespace)
  result.writeU32Le(uint32(value.nodes.len))
  for node in value.nodes:
    result.writeNode(node)
  result.writeU32Le(uint32(value.edges.len))
  for edge in value.edges:
    result.writeEdge(edge)
  result.writeU32Le(uint32(value.effectClaims.len))
  for effect in value.effectClaims:
    result.writeEffect(effect)
  result.writeU32Le(uint32(value.childEntryPoints.len))
  for child in value.childEntryPoints:
    result.writeString(child.entryPointId)
    result.writeString(child.arguments)
    result.writeString(child.namespace)
    result.writeString(child.stableName)
