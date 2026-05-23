import std/[os, sequtils, strutils]

import blake3
import cbor
import repro_core
import repro_provider_runtime
import ssz_serialization

import ./types

const
  DevEnvMagic = [byte(ord('R')), byte(ord('B')), byte(ord('D')), byte(ord('E'))]
  EnvelopeHeaderLen = 4 + 2 + 2 + 4 + 4
  EnvelopeTrailerLen = 32
  EnvelopeVersion = 1'u16
  EnvelopeTypeDevEnv = 1'u16

  MaxTextBytes = 16 * 1024
  MaxMetadataBytes = 1024 * 1024
  MaxListItems = 4096
  MaxShellOps = 4096
  MaxToolProfiles = 1024
  MaxTasks = 1024
  MaxServices = 1024
  MaxDigests = 4096
  MaxDiagnostics = 4096
  MaxEvaluationInputs = 4096
  MaxSourceFingerprints = 4096

type
  DevEnvArtifactCodecError* = object of CatchableError

  SszText = List[byte, MaxTextBytes]
  SszBytes = List[byte, MaxMetadataBytes]
  SszStringList = List[SszText, MaxListItems]

  DevEnvShellOpSsz = object
    kind: uint8
    name: SszText
    value: SszText
    separator: SszText
    activityRequirements: SszStringList

  DevEnvToolProfileRefSsz = object
    logicalName: SszText
    packageIdentity: SszText
    executionProfileId: Digest32
    realizedPrefix: SszText
    activityRequirements: SszStringList

  DevEnvTaskSummarySsz = object
    name: SszText
    description: SszText
    activityRequirements: SszStringList
    commandRef: Digest32
    command: SszText

  DevEnvServiceSummarySsz = object
    name: SszText
    activityRequirements: SszStringList
    supervisorPlanRef: Digest32
    hasSupervisorPlanRef: bool
    metadata: SszBytes

  DevEnvDiagnosticSsz = object
    severity: uint8
    message: SszText
    sourceFile: SszText
    sourceLine: uint32

  GraphEvaluationInputSsz = object
    kind: uint8
    identity: SszText
    digest: SszText
    directoryMembers: SszStringList
    memberEntryPointId: SszText
    memberEntryPointBodyHash: SszText
    memberArgumentRoot: SszText
    memberNamespace: SszText

  DevEnvSourceFingerprintSsz = object
    kind: SszText
    identity: SszText
    digest: SszText

  DevEnvArtifactSsz* = object
    schemaVersion*: uint32
    artifactId*: Digest32
    providerArtifactId*: Digest32
    providerArtifactIdText*: SszText
    providerEntryPointId*: Digest32
    providerEntryPointName*: SszText
    providerEntryPointBodyHash*: Digest32
    providerEntryPointBodyHashText*: SszText
    projectRootDigest*: Digest32
    projectRoot*: SszText
    lockSliceId*: Digest32
    lockSliceName*: SszText
    activitySelectionDigest*: Digest32
    selectedActivities*: SszStringList
    declaredActivities*: SszStringList
    developModeOverrideDigest*: Digest32
    shellOps*: List[DevEnvShellOpSsz, MaxShellOps]
    toolProfiles*: List[DevEnvToolProfileRefSsz, MaxToolProfiles]
    tasks*: List[DevEnvTaskSummarySsz, MaxTasks]
    services*: List[DevEnvServiceSummarySsz, MaxServices]
    resourcePrerequisites*: List[Digest32, MaxDigests]
    diagnostics*: List[DevEnvDiagnosticSsz, MaxDiagnostics]
    evaluationInputs*: List[GraphEvaluationInputSsz, MaxEvaluationInputs]
    sourceFingerprints*: List[DevEnvSourceFingerprintSsz, MaxSourceFingerprints]
    evaluationEvidenceRef*: Digest32
    providerMetadata*: SszBytes

  EnvelopePayloadBounds = object
    start: int
    stop: int
    version: uint16
    features: uint32

  FieldBounds = object
    start: int
    stop: int
    headerStart: int
    headerStop: int

proc fail(message: string) {.noreturn.} =
  raise newException(DevEnvArtifactCodecError, message)

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestBytes(bytes: openArray[byte]): Digest32 =
  let digest = blake3.digest(bytes)
  for i in 0 ..< 32:
    result[i] = digest[i]

proc digestText(text: string): Digest32 =
  digestBytes(toBytes(text))

proc digestStringSeq(values: openArray[string]): Digest32 =
  var payload: seq[byte] = @[]
  payload.writeU32Le(uint32(values.len))
  for value in values:
    payload.writeString(value)
  digestBytes(payload)

proc digestGraphInputs(inputs: openArray[GraphEvaluationInput]): Digest32 =
  var payload: seq[byte] = @[]
  payload.writeU32Le(uint32(inputs.len))
  for input in inputs:
    payload.add(byte(ord(input.kind)))
    payload.writeString(input.identity)
    payload.writeString(input.digest)
    payload.writeU32Le(uint32(input.directoryMembers.len))
    for member in input.directoryMembers:
      payload.writeString(member)
    payload.writeString(input.memberEntryPointId)
    payload.writeString(input.memberEntryPointBodyHash)
    payload.writeString(input.memberArgumentRoot)
    payload.writeString(input.memberNamespace)
  digestBytes(payload)

proc hexDigest(text: string): Digest32 =
  let stripped = text.strip().toLowerAscii()
  if stripped.len == 64 and stripped.allIt(it in {'0'..'9', 'a'..'f'}):
    for i in 0 ..< 32:
      result[i] = byte(parseHexInt(stripped[i * 2 .. i * 2 + 1]))
  else:
    result = digestText(text)

proc zeroDigest(): Digest32 =
  discard

proc toSszText(value: string): SszText =
  if value.len > MaxTextBytes:
    fail("dev-env artifact text value exceeds SSZ bound")
  SszText.init(fromByteString(value))

proc fromSszText(value: SszText): string =
  toByteString(value.asSeq())

proc toSszBytes(value: openArray[byte]): SszBytes =
  if value.len > MaxMetadataBytes:
    fail("dev-env artifact byte value exceeds SSZ bound")
  SszBytes.init(@value)

proc toSszStringList(values: openArray[string]): SszStringList =
  var wire: seq[SszText] = @[]
  if values.len > MaxListItems:
    fail("dev-env artifact string list exceeds SSZ bound")
  for value in values:
    wire.add(toSszText(value))
  SszStringList.init(wire)

proc fromSszStringList(values: SszStringList): seq[string] =
  for value in values:
    result.add(fromSszText(value))

proc encodeMetadata(value: DynamicValue): SszBytes =
  toSszBytes(encode(value))

proc decodeMetadata(value: SszBytes): DynamicValue =
  let raw = value.asSeq()
  try:
    if raw.len == 0:
      result = decode(default(seq[byte]))
    else:
      result = decode(raw.toOpenArray(0, raw.len - 1))
  except CborError as err:
    fail("invalid CBOR metadata inside SSZ payload: " & err.msg)

proc toSsz(value: DevEnvShellOp): DevEnvShellOpSsz =
  DevEnvShellOpSsz(
    kind: uint8(ord(value.kind)),
    name: toSszText(value.name),
    value: toSszText(value.value),
    separator: toSszText(value.separator),
    activityRequirements: toSszStringList(value.activityRequirements))

proc fromSsz(value: DevEnvShellOpSsz): DevEnvShellOp =
  if value.kind > uint8(ord(deskSetWorkingDirectory)):
    fail("invalid dev-env shell op kind in SSZ payload")
  DevEnvShellOp(
    kind: DevEnvShellOpKind(value.kind),
    name: fromSszText(value.name),
    value: fromSszText(value.value),
    separator: fromSszText(value.separator),
    activityRequirements: fromSszStringList(value.activityRequirements))

proc toSsz(value: DevEnvToolProfileRef): DevEnvToolProfileRefSsz =
  DevEnvToolProfileRefSsz(
    logicalName: toSszText(value.logicalName),
    packageIdentity: toSszText(value.packageIdentity),
    executionProfileId: value.executionProfileId,
    realizedPrefix: toSszText(value.realizedPrefix),
    activityRequirements: toSszStringList(value.activityRequirements))

proc fromSsz(value: DevEnvToolProfileRefSsz): DevEnvToolProfileRef =
  DevEnvToolProfileRef(
    logicalName: fromSszText(value.logicalName),
    packageIdentity: fromSszText(value.packageIdentity),
    executionProfileId: value.executionProfileId,
    realizedPrefix: fromSszText(value.realizedPrefix),
    activityRequirements: fromSszStringList(value.activityRequirements))

proc toSsz(value: DevEnvTaskSummary): DevEnvTaskSummarySsz =
  DevEnvTaskSummarySsz(
    name: toSszText(value.name),
    description: toSszText(value.description),
    activityRequirements: toSszStringList(value.activityRequirements),
    commandRef: value.commandRef,
    command: toSszText(value.command))

proc fromSsz(value: DevEnvTaskSummarySsz): DevEnvTaskSummary =
  DevEnvTaskSummary(
    name: fromSszText(value.name),
    description: fromSszText(value.description),
    activityRequirements: fromSszStringList(value.activityRequirements),
    commandRef: value.commandRef,
    command: fromSszText(value.command))

proc toSsz(value: DevEnvServiceSummary): DevEnvServiceSummarySsz =
  DevEnvServiceSummarySsz(
    name: toSszText(value.name),
    activityRequirements: toSszStringList(value.activityRequirements),
    supervisorPlanRef: value.supervisorPlanRef,
    hasSupervisorPlanRef: value.hasSupervisorPlanRef,
    metadata: encodeMetadata(value.metadata))

proc fromSsz(value: DevEnvServiceSummarySsz): DevEnvServiceSummary =
  DevEnvServiceSummary(
    name: fromSszText(value.name),
    activityRequirements: fromSszStringList(value.activityRequirements),
    supervisorPlanRef: value.supervisorPlanRef,
    hasSupervisorPlanRef: value.hasSupervisorPlanRef,
    metadata: decodeMetadata(value.metadata))

proc toSsz(value: DevEnvDiagnostic): DevEnvDiagnosticSsz =
  DevEnvDiagnosticSsz(
    severity: uint8(ord(value.severity)),
    message: toSszText(value.message),
    sourceFile: toSszText(value.sourceFile),
    sourceLine: uint32(max(value.sourceLine, 0)))

proc fromSsz(value: DevEnvDiagnosticSsz): DevEnvDiagnostic =
  if value.severity > uint8(ord(dedsError)):
    fail("invalid dev-env diagnostic severity in SSZ payload")
  DevEnvDiagnostic(
    severity: DevEnvDiagnosticSeverity(value.severity),
    message: fromSszText(value.message),
    sourceFile: fromSszText(value.sourceFile),
    sourceLine: int(value.sourceLine))

proc toSsz(value: GraphEvaluationInput): GraphEvaluationInputSsz =
  GraphEvaluationInputSsz(
    kind: uint8(ord(value.kind)),
    identity: toSszText(value.identity),
    digest: toSszText(value.digest),
    directoryMembers: toSszStringList(value.directoryMembers),
    memberEntryPointId: toSszText(value.memberEntryPointId),
    memberEntryPointBodyHash: toSszText(value.memberEntryPointBodyHash),
    memberArgumentRoot: toSszText(value.memberArgumentRoot),
    memberNamespace: toSszText(value.memberNamespace))

proc fromSsz(value: GraphEvaluationInputSsz): GraphEvaluationInput =
  if value.kind > uint8(ord(gevActivitySelection)):
    fail("invalid graph evaluation input kind in SSZ payload")
  GraphEvaluationInput(
    kind: GraphEvaluationInputKind(value.kind),
    identity: fromSszText(value.identity),
    digest: fromSszText(value.digest),
    directoryMembers: fromSszStringList(value.directoryMembers),
    memberEntryPointId: fromSszText(value.memberEntryPointId),
    memberEntryPointBodyHash: fromSszText(value.memberEntryPointBodyHash),
    memberArgumentRoot: fromSszText(value.memberArgumentRoot),
    memberNamespace: fromSszText(value.memberNamespace))

proc toSsz(value: DevEnvSourceFingerprint): DevEnvSourceFingerprintSsz =
  DevEnvSourceFingerprintSsz(
    kind: toSszText(value.kind),
    identity: toSszText(value.identity),
    digest: toSszText(value.digest))

proc fromSsz(value: DevEnvSourceFingerprintSsz): DevEnvSourceFingerprint =
  DevEnvSourceFingerprint(
    kind: fromSszText(value.kind),
    identity: fromSszText(value.identity),
    digest: fromSszText(value.digest))

proc toSsz(artifact: DevEnvArtifact; artifactIdOverride: Digest32): DevEnvArtifactSsz =
  result.schemaVersion = artifact.schemaVersion
  result.artifactId = artifactIdOverride
  result.providerArtifactId = artifact.providerArtifactId
  result.providerArtifactIdText = toSszText(artifact.providerArtifactIdText)
  result.providerEntryPointId = artifact.providerEntryPointId
  result.providerEntryPointName = toSszText(artifact.providerEntryPointName)
  result.providerEntryPointBodyHash = artifact.providerEntryPointBodyHash
  result.providerEntryPointBodyHashText = toSszText(artifact.providerEntryPointBodyHashText)
  result.projectRootDigest = artifact.projectRootDigest
  result.projectRoot = toSszText(artifact.projectRoot)
  result.lockSliceId = artifact.lockSliceId
  result.lockSliceName = toSszText(artifact.lockSliceName)
  result.activitySelectionDigest = artifact.activitySelectionDigest
  result.selectedActivities = toSszStringList(artifact.selectedActivities)
  result.declaredActivities = toSszStringList(artifact.declaredActivities)
  result.developModeOverrideDigest = artifact.developModeOverrideDigest
  result.shellOps = List[DevEnvShellOpSsz, MaxShellOps].init(
    artifact.shellOps.mapIt(toSsz(it)))
  result.toolProfiles = List[DevEnvToolProfileRefSsz, MaxToolProfiles].init(
    artifact.toolProfiles.mapIt(toSsz(it)))
  result.tasks = List[DevEnvTaskSummarySsz, MaxTasks].init(
    artifact.tasks.mapIt(toSsz(it)))
  result.services = List[DevEnvServiceSummarySsz, MaxServices].init(
    artifact.services.mapIt(toSsz(it)))
  result.resourcePrerequisites = List[Digest32, MaxDigests].init(
    artifact.resourcePrerequisites)
  result.diagnostics = List[DevEnvDiagnosticSsz, MaxDiagnostics].init(
    artifact.diagnostics.mapIt(toSsz(it)))
  result.evaluationInputs = List[GraphEvaluationInputSsz, MaxEvaluationInputs].init(
    artifact.evaluationInputs.mapIt(toSsz(it)))
  result.sourceFingerprints = List[DevEnvSourceFingerprintSsz,
    MaxSourceFingerprints].init(artifact.sourceFingerprints.mapIt(toSsz(it)))
  result.evaluationEvidenceRef = artifact.evaluationEvidenceRef
  result.providerMetadata = encodeMetadata(artifact.providerMetadata)

proc fromSsz(wire: DevEnvArtifactSsz): DevEnvArtifact =
  result.schemaVersion = wire.schemaVersion
  result.artifactId = wire.artifactId
  result.providerArtifactId = wire.providerArtifactId
  result.providerArtifactIdText = fromSszText(wire.providerArtifactIdText)
  result.providerEntryPointId = wire.providerEntryPointId
  result.providerEntryPointName = fromSszText(wire.providerEntryPointName)
  result.providerEntryPointBodyHash = wire.providerEntryPointBodyHash
  result.providerEntryPointBodyHashText = fromSszText(wire.providerEntryPointBodyHashText)
  result.projectRootDigest = wire.projectRootDigest
  result.projectRoot = fromSszText(wire.projectRoot)
  result.lockSliceId = wire.lockSliceId
  result.lockSliceName = fromSszText(wire.lockSliceName)
  result.activitySelectionDigest = wire.activitySelectionDigest
  result.selectedActivities = fromSszStringList(wire.selectedActivities)
  result.declaredActivities = fromSszStringList(wire.declaredActivities)
  result.developModeOverrideDigest = wire.developModeOverrideDigest
  result.shellOps = wire.shellOps.asSeq().mapIt(fromSsz(it))
  result.toolProfiles = wire.toolProfiles.asSeq().mapIt(fromSsz(it))
  result.tasks = wire.tasks.asSeq().mapIt(fromSsz(it))
  result.services = wire.services.asSeq().mapIt(fromSsz(it))
  result.resourcePrerequisites = wire.resourcePrerequisites.asSeq()
  result.diagnostics = wire.diagnostics.asSeq().mapIt(fromSsz(it))
  result.evaluationInputs = wire.evaluationInputs.asSeq().mapIt(fromSsz(it))
  result.sourceFingerprints = wire.sourceFingerprints.asSeq().mapIt(fromSsz(it))
  result.evaluationEvidenceRef = wire.evaluationEvidenceRef
  result.providerMetadata = decodeMetadata(wire.providerMetadata)

proc encodeSszPayload(artifact: DevEnvArtifact; artifactIdOverride: Digest32): seq[byte] =
  try:
    SSZ.encode(toSsz(artifact, artifactIdOverride))
  except SszError as err:
    fail("could not SSZ-encode dev-env artifact: " & err.msg)
  except IOError as err:
    fail("could not write SSZ dev-env artifact payload: " & err.msg)

proc decodeSszPayload(payload: openArray[byte]): DevEnvArtifactSsz =
  try:
    SSZ.decode(payload, DevEnvArtifactSsz)
  except SszError as err:
    fail("invalid SSZ dev-env artifact payload: " & err.msg)
  except IOError as err:
    fail("could not read SSZ dev-env artifact payload: " & err.msg)

proc computeArtifactId(artifact: DevEnvArtifact): Digest32 =
  digestBytes(encodeSszPayload(artifact, zeroDigest()))

proc parseEnvelope(bytes: openArray[byte]): EnvelopePayloadBounds =
  if bytes.len < EnvelopeHeaderLen + EnvelopeTrailerLen:
    fail("dev-env artifact envelope too short")
  for i in 0 ..< 4:
    if bytes[i] != DevEnvMagic[i]:
      fail("unknown dev-env artifact magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != EnvelopeVersion:
    fail("unsupported dev-env artifact envelope version " & $version)
  let typeId = readU16Le(bytes, pos)
  if typeId != EnvelopeTypeDevEnv:
    fail("unexpected dev-env artifact envelope type")
  let features = readU32Le(bytes, pos)
  if (features and not DevEnvArtifactRequiredFeatures) != 0'u32:
    fail("unsupported dev-env artifact required feature bits")
  let payloadLen = int(readU32Le(bytes, pos))
  let payloadStart = pos
  let payloadStop = payloadStart + payloadLen
  if payloadStop + EnvelopeTrailerLen != bytes.len:
    fail("dev-env artifact envelope length mismatch")
  let expected = blake3.digest(bytes.toOpenArray(0, payloadStop - 1))
  for i in 0 ..< 32:
    if bytes[payloadStop + i] != expected[i]:
      fail("dev-env artifact checksum mismatch")
  EnvelopePayloadBounds(start: payloadStart, stop: payloadStop,
    version: version, features: features)

proc payloadSlice(bytes: openArray[byte]; parsed: EnvelopePayloadBounds): seq[byte] =
  result = newSeq[byte](parsed.stop - parsed.start)
  for i in 0 ..< result.len:
    result[i] = bytes[parsed.start + i]

proc encodeDevEnvArtifact*(artifact: DevEnvArtifact): seq[byte] =
  var canonical = artifact
  if canonical.schemaVersion == 0'u32:
    canonical.schemaVersion = DevEnvArtifactSchemaVersion
  canonical.artifactId = computeArtifactId(canonical)
  let payload = encodeSszPayload(canonical, canonical.artifactId)
  result = newSeqOfCap[byte](EnvelopeHeaderLen + payload.len + EnvelopeTrailerLen)
  result.add(DevEnvMagic)
  result.writeU16Le(EnvelopeVersion)
  result.writeU16Le(EnvelopeTypeDevEnv)
  result.writeU32Le(DevEnvArtifactRequiredFeatures)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)
  let checksum = blake3.digest(result)
  result.add(checksum)

proc devEnvArtifactSszPayload*(bytes: openArray[byte]): seq[byte] =
  payloadSlice(bytes, parseEnvelope(bytes))

proc canonicalDevEnvArtifactSszPayload*(artifact: DevEnvArtifact): seq[byte] =
  var canonical = artifact
  if canonical.schemaVersion == 0'u32:
    canonical.schemaVersion = DevEnvArtifactSchemaVersion
  canonical.artifactId = computeArtifactId(canonical)
  encodeSszPayload(canonical, canonical.artifactId)

proc decodeDevEnvArtifactSszPayload*(payload: openArray[byte]): DevEnvArtifact =
  let wire = decodeSszPayload(payload)
  result = fromSsz(wire)
  if result.schemaVersion != DevEnvArtifactSchemaVersion:
    fail("unsupported dev-env artifact schema version " & $result.schemaVersion)
  if result.artifactId != computeArtifactId(result):
    fail("dev-env artifact identity mismatch")

proc decodeDevEnvArtifact*(bytes: openArray[byte]): DevEnvArtifact =
  decodeDevEnvArtifactSszPayload(devEnvArtifactSszPayload(bytes))

proc readDevEnvArtifact*(path: string): DevEnvArtifact =
  decodeDevEnvArtifact(fromByteString(readFile(extendedPath(path))))

proc writeDevEnvArtifact*(path: string; artifact: DevEnvArtifact) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeDevEnvArtifact(artifact)))

proc sszFieldBounds(payload: openArray[byte]; fieldName: static string): FieldBounds =
  const header = fixedPortionSize(DevEnvArtifactSsz)
  if payload.len < header:
    fail("dev-env artifact SSZ payload too short")
  const bounds = getFieldBoundingOffsets(DevEnvArtifactSsz, fieldName)
  var startPos = bounds.fieldOffset
  let start = int(readU32Le(payload, startPos))
  when bounds.nextFieldOffset == -1:
    let stop = payload.len
  else:
    var stopPos = bounds.nextFieldOffset
    let stop = int(readU32Le(payload, stopPos))
  if start < header or stop < start or stop > payload.len:
    fail("dev-env artifact SSZ field offset outside payload")
  FieldBounds(start: start, stop: stop, headerStart: bounds.fieldOffset,
    headerStop: bounds.nextFieldOffset)

proc decodeShellOpsField(payload: openArray[byte]; bounds: FieldBounds;
                         stats: var DevEnvNavigatorStats): seq[DevEnvShellOp] =
  var wire: List[DevEnvShellOpSsz, MaxShellOps]
  try:
    readSszBytes(payload.toOpenArray(bounds.start, bounds.stop - 1), wire)
  except SszError as err:
    fail("invalid SSZ shell-op field: " & err.msg)
  for op in wire:
    result.add(fromSsz(op))
    inc stats.shellOpRecordsDecoded

proc shellOpsFromNavigator*(bytes: openArray[byte];
                            stats: var DevEnvNavigatorStats): seq[DevEnvShellOp] =
  stats = DevEnvNavigatorStats()
  stats.envelopeBytesChecked = EnvelopeHeaderLen + EnvelopeTrailerLen
  let parsed = parseEnvelope(bytes)
  stats.payloadBytesHashed = parsed.stop - parsed.start
  let payload = payloadSlice(bytes, parsed)
  let shellBounds = sszFieldBounds(payload, "shellOps")
  let tasksBounds = sszFieldBounds(payload, "tasks")
  let servicesBounds = sszFieldBounds(payload, "services")
  stats.payloadHeaderBytesRead = fixedPortionSize(DevEnvArtifactSsz)
  stats.shellOpsSectionStart = shellBounds.start
  stats.shellOpsSectionEnd = shellBounds.stop
  stats.tasksSectionStart = tasksBounds.start
  stats.servicesSectionStart = servicesBounds.start
  result = decodeShellOpsField(payload, shellBounds, stats)
  stats.maxDecodedPayloadOffset = shellBounds.stop

proc shellOpsFromNavigatorFile*(path: string;
                                stats: var DevEnvNavigatorStats): seq[DevEnvShellOp] =
  shellOpsFromNavigator(fromByteString(readFile(extendedPath(path))), stats)

proc artifactFromDevEnvResult*(devEnv: DevEnvResult): DevEnvArtifact =
  result.schemaVersion = DevEnvArtifactSchemaVersion
  result.providerArtifactIdText = devEnv.providerArtifactId
  result.providerArtifactId = hexDigest(devEnv.providerArtifactId)
  result.providerEntryPointName = devEnv.providerEntryPointId
  result.providerEntryPointId = digestText(devEnv.providerEntryPointId)
  result.providerEntryPointBodyHashText = devEnv.providerEntryPointBodyHash
  result.providerEntryPointBodyHash = hexDigest(devEnv.providerEntryPointBodyHash)
  result.projectRoot = devEnv.projectRoot
  result.projectRootDigest = digestText(devEnv.projectRoot)
  result.lockSliceName = devEnv.lockSliceId
  result.lockSliceId = digestText(devEnv.lockSliceId)
  result.selectedActivities = devEnv.selectedActivities
  result.declaredActivities = devEnv.declaredActivities
  result.activitySelectionDigest = digestStringSeq(devEnv.selectedActivities)
  let developInputs = devEnv.evaluationInputs.filterIt(
    it.kind == gevDevelopModeOverride)
  result.developModeOverrideDigest =
    if developInputs.len > 0: digestGraphInputs(developInputs)
    else: zeroDigest()
  result.shellOps = devEnv.shellOps
  for tool in devEnv.toolRequirements:
    var identityPayload: seq[byte] = @[]
    identityPayload.writeString(tool.logicalName)
    identityPayload.writeString(tool.packageSelector)
    identityPayload.writeString(tool.executableName)
    identityPayload.writeU32Le(uint32(tool.policyPath.len))
    for part in tool.policyPath:
      identityPayload.writeString(part)
    result.toolProfiles.add(DevEnvToolProfileRef(
      logicalName: tool.logicalName,
      packageIdentity: tool.packageSelector,
      executionProfileId: digestBytes(identityPayload),
      realizedPrefix: tool.policyPath.join(":"),
      activityRequirements: tool.activityRequirements))
  for task in devEnv.tasks:
    result.tasks.add(DevEnvTaskSummary(
      name: task.name,
      description: task.description,
      activityRequirements: task.activityRequirements,
      commandRef: digestText(task.command),
      command: task.command))
  for service in devEnv.services:
    result.services.add(DevEnvServiceSummary(
      name: service.name,
      activityRequirements: service.activityRequirements,
      metadata: cborText(service.metadata)))
  result.diagnostics = devEnv.diagnostics
  result.evaluationInputs = devEnv.evaluationInputs
  result.sourceFingerprints = devEnv.sourceFingerprints
  result.evaluationEvidenceRef = digestGraphInputs(devEnv.evaluationInputs)
  result.providerMetadata = cborMap([
    entry("providerArtifactId", cborText(devEnv.providerArtifactId)),
    entry("providerEntryPointId", cborText(devEnv.providerEntryPointId)),
    entry("providerEntryPointBodyHash", cborText(devEnv.providerEntryPointBodyHash))
  ])
  result.artifactId = computeArtifactId(result)

proc produceDevEnvArtifact*(config: ProviderExecutionConfig;
                            providerArtifactId, projectRoot: string;
                            entryPointId = "";
                            activity = "";
                            lockSliceId = ""): DevEnvArtifact =
  artifactFromDevEnvResult(invokeProviderDevEnvIntrospection(config,
    providerArtifactId, projectRoot, entryPointId = entryPointId,
    activity = activity, lockSliceId = lockSliceId))
