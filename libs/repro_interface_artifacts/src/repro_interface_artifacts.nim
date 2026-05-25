import std/[algorithm, options, os, osproc, sequtils, streams, strutils, times]

import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_project_dsl

const BuiltNimCompilerPath = staticExec("command -v nim").strip()
const BuiltCCompilerPath =
  staticExec("command -v cc || command -v gcc || true").strip()

var interfaceTempNonce = uint64(getCurrentProcessId())

type
  InterfaceEnvelopeKind* = enum
    iekProjectInterface
    iekProviderCompile

  InterfaceParamKind* = enum
    ipkPositional
    ipkFlag

  SourceLocation* = object
    file*: string
    line*: int

  InterfaceParam* = object
    name*: string
    nimType*: string
    kind*: InterfaceParamKind
    position*: int
    alias*: string
    required*: bool
    location*: SourceLocation

  InterfaceCommand* = object
    name*: string
    params*: seq[InterfaceParam]
    providerEntrypointId*: string
    location*: SourceLocation

  InterfaceExecutable* = object
    exportName*: string
    binaryName*: string
    commands*: seq[InterfaceCommand]
    location*: SourceLocation

  InterfaceNixProvisioning* = object
    packageName*: string
    selector*: string
    executablePath*: string
    expressionFile*: string
    packageId*: string
    lockIdentity*: string
    location*: SourceLocation

  InterfaceTarballProvisioning* = object
    packageName*: string
    url*: string
    mirrors*: seq[string]
    sha256*: string
    archiveType*: string
    executablePath*: string
    stripComponents*: int
    packageId*: string
    lockIdentity*: string
    location*: SourceLocation

  InterfaceScoopProvisioning* = object
    packageName*: string
    bucket*: string
    app*: string
    version*: string
    preferredVersion*: string
    manifestChecksum*: string
    manifestUrl*: string
    executablePath*: string
    requiresExecutionProfileChecksum*: bool
    packageId*: string
    lockIdentity*: string
    location*: SourceLocation

  InterfaceToolUse* = object
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
    nixProvisioning*: seq[InterfaceNixProvisioning]
    tarballProvisioning*: seq[InterfaceTarballProvisioning]
    scoopProvisioning*: seq[InterfaceScoopProvisioning]
    location*: SourceLocation

  ProjectInterface* = object
    projectName*: string
    packageName*: string
    publicExecutables*: seq[InterfaceExecutable]
    toolUses*: seq[InterfaceToolUse]
    publicSignatureDependencies*: seq[string]
    location*: SourceLocation

  ProjectInterfaceArtifact* = object
    projectInterface*: ProjectInterface
    interfaceFingerprint*: ContentDigest

  ProviderCompileExecutionResult* = object
    exitCode*: int
    output*: string

  ProviderCompileEdge* = object
    actionSpec*: ActionSpec
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    actionFingerprint*: ContentDigest

  ProviderCompilePlan* = object
    inputSources*: seq[string]
    outputBinaryPath*: string
    compilerCommand*: seq[string]
    compileEdge*: ProviderCompileEdge
    interfaceFingerprint*: ContentDigest
    providerFingerprint*: ContentDigest

  ProviderCompileArtifact* = object
    inputSources*: seq[string]
    outputBinaryPath*: string
    compilerCommand*: seq[string]
    compileEdge*: ProviderCompileEdge
    interfaceFingerprint*: ContentDigest
    providerFingerprint*: ContentDigest
    outputBinaryFingerprint*: ContentDigest
    executionResult*: ProviderCompileExecutionResult

  FileStampKind = enum
    fskMissing
    fskRegular
    fskDirectory
    fskOther

  FileStamp = object
    path: string
    kind: FileStampKind
    sizeBytes: uint64
    mtimeNs: uint64

  InterfaceExtractionContext = object
    modulePath: string
    workDir: string
    nimCompiler: string
    libPathFlags: seq[string]
    sources: seq[string]

  InterfaceExtractionCacheRecord = object
    context: InterfaceExtractionContext
    sourceStamps: seq[FileStamp]
    inputFingerprint: ContentDigest

  ProviderFreshnessCacheRecord = object
    modulePath: string
    outputBinaryPath: string
    sourceStamps: seq[FileStamp]
    outputBinaryStamp: FileStamp
    interfaceFingerprint: ContentDigest
    providerFingerprint: ContentDigest
    outputBinaryFingerprint: ContentDigest

const
  EnvelopeMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
  EnvelopeVersion = 5'u16
  InterfaceExtractionCacheRecordMagic =
    "reprobuild.interfaceExtractionCache.v1"
  ProviderFreshnessCacheRecordMagic =
    "reprobuild.providerFreshnessCache.v1"

var cachedNimCompilerPath = ""

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

proc writeExecutionResult(outp: var seq[byte];
                          execution: ProviderCompileExecutionResult) =
  outp.writeU32Le(uint32(max(execution.exitCode, 0)))
  outp.writeString(execution.output)

proc readExecutionResult(bytes: openArray[byte]; pos: var int):
    ProviderCompileExecutionResult =
  ProviderCompileExecutionResult(
    exitCode: int(readU32Le(bytes, pos)),
    output: readString(bytes, pos))

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.writeByte(byte(ord(digest.algorithm)))
  outp.writeByte(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(bytes: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(bytes, pos)
  let domain = readByte(bytes, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid hash domain")
  if pos + 32 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated content digest")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = bytes[pos + i]
  pos += 32

proc digestHexValue(digest: ContentDigest): DynamicValue =
  cborText(toHex(digest.bytes))

proc stableIdFromDigest(digest: ContentDigest): StableId =
  var raw: array[16, byte]
  for i in 0 ..< raw.len:
    raw[i] = digest.bytes[i]
  stableId(raw)

proc actionFingerprintFor*(declaredInputs, declaredOutputs,
                           compilerCommand: openArray[string];
                           interfaceFingerprint,
                           providerFingerprint: ContentDigest): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.providerCompile.v1")
  payload.writeStringSeq(declaredInputs)
  payload.writeStringSeq(declaredOutputs)
  payload.writeStringSeq(compilerCommand)
  payload.writeDigest(interfaceFingerprint)
  payload.writeDigest(providerFingerprint)
  blake3DomainDigest(payload, hdActionFingerprint)

proc providerCompileMetadata(
    declaredInputs, declaredOutputs, compilerCommand: openArray[string];
    interfaceFingerprint, providerFingerprint,
    actionFingerprint: ContentDigest): DynamicValue =
  var inputValues: seq[DynamicValue] = @[]
  for value in declaredInputs:
    inputValues.add(cborText(value))
  var outputValues: seq[DynamicValue] = @[]
  for value in declaredOutputs:
    outputValues.add(cborText(value))
  var commandValues: seq[DynamicValue] = @[]
  for value in compilerCommand:
    commandValues.add(cborText(value))
  cborMap([
    entry("kind", cborText("providerCompile")),
    entry("schema", cborUInt(1)),
    entry("declaredInputs", cborArray(inputValues)),
    entry("declaredOutputs", cborArray(outputValues)),
    entry("command", cborArray(commandValues)),
    entry("interfaceFingerprint", digestHexValue(interfaceFingerprint)),
    entry("providerFingerprint", digestHexValue(providerFingerprint)),
    entry("actionFingerprint", digestHexValue(actionFingerprint))
  ])

proc providerCompileEdge*(inputSources: openArray[string];
                          outputBinaryPath: string;
                          compilerCommand: openArray[string];
                          interfaceFingerprint,
                          providerFingerprint: ContentDigest;
                          workDir = getCurrentDir();
                          knownActionFingerprint = none(ContentDigest)):
    ProviderCompileEdge =
  let declaredInputs = @inputSources
  let declaredOutputs = @[outputBinaryPath]
  let fingerprint =
    if knownActionFingerprint.isSome:
      knownActionFingerprint.get()
    else:
      actionFingerprintFor(declaredInputs, declaredOutputs, compilerCommand,
        interfaceFingerprint, providerFingerprint)
  var processArgs: seq[string] = @[]
  for i in 1 ..< compilerCommand.len:
    processArgs.add(compilerCommand[i])
  let process =
    if compilerCommand.len == 0:
      directProcess(corepaths.normalizedPath("nim"), [],
          corepaths.normalizedPath(workDir))
    else:
      directProcess(
        corepaths.normalizedPath(compilerCommand[0]),
        processArgs,
        corepaths.normalizedPath(workDir))
  ProviderCompileEdge(
    actionSpec: ActionSpec(
      actionId: stableIdFromDigest(fingerprint),
      process: process,
      dependencyPolicy: declaredOnlyPolicy(),
      metadata: providerCompileMetadata(declaredInputs, declaredOutputs,
        compilerCommand, interfaceFingerprint, providerFingerprint,
        fingerprint)),
    declaredInputs: declaredInputs,
    declaredOutputs: declaredOutputs,
    actionFingerprint: fingerprint)

proc writeLocation(outp: var seq[byte]; loc: SourceLocation) =
  outp.writeString(loc.file)
  outp.writeU32Le(uint32(max(loc.line, 0)))

proc readLocation(bytes: openArray[byte]; pos: var int): SourceLocation =
  SourceLocation(file: readString(bytes, pos), line: int(readU32Le(bytes, pos)))

proc writeParam(outp: var seq[byte]; param: InterfaceParam) =
  outp.writeString(param.name)
  outp.writeString(param.nimType)
  outp.writeByte(byte(ord(param.kind)))
  outp.writeU32Le(uint32(param.position))
  outp.writeString(param.alias)
  outp.writeByte(if param.required: 1'u8 else: 0'u8)
  outp.writeLocation(param.location)

proc readParam(bytes: openArray[byte]; pos: var int): InterfaceParam =
  result.name = readString(bytes, pos)
  result.nimType = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(ipkFlag)):
    raiseEnvelopeError(eeMalformed, "invalid interface parameter kind")
  result.kind = InterfaceParamKind(kind)
  result.position = int(readU32Le(bytes, pos))
  result.alias = readString(bytes, pos)
  result.required = readByte(bytes, pos) == 1'u8
  result.location = readLocation(bytes, pos)

proc writeCommand(outp: var seq[byte]; cmd: InterfaceCommand) =
  outp.writeString(cmd.name)
  outp.writeString(cmd.providerEntrypointId)
  outp.writeLocation(cmd.location)
  outp.writeU32Le(uint32(cmd.params.len))
  for param in cmd.params:
    outp.writeParam(param)

proc readCommand(bytes: openArray[byte]; pos: var int): InterfaceCommand =
  result.name = readString(bytes, pos)
  result.providerEntrypointId = readString(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.params = newSeq[InterfaceParam](count)
  for i in 0 ..< count:
    result.params[i] = readParam(bytes, pos)

proc writeExecutable(outp: var seq[byte]; exe: InterfaceExecutable) =
  outp.writeString(exe.exportName)
  outp.writeString(exe.binaryName)
  outp.writeLocation(exe.location)
  outp.writeU32Le(uint32(exe.commands.len))
  for cmd in exe.commands:
    outp.writeCommand(cmd)

proc readExecutable(bytes: openArray[byte]; pos: var int): InterfaceExecutable =
  result.exportName = readString(bytes, pos)
  result.binaryName = readString(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.commands = newSeq[InterfaceCommand](count)
  for i in 0 ..< count:
    result.commands[i] = readCommand(bytes, pos)

proc writeNixProvisioning(outp: var seq[byte];
                          provisioning: InterfaceNixProvisioning) =
  outp.writeString(provisioning.packageName)
  outp.writeString(provisioning.selector)
  outp.writeString(provisioning.executablePath)
  outp.writeString(provisioning.expressionFile)
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeLocation(provisioning.location)

proc readNixProvisioning(bytes: openArray[byte]; pos: var int;
                         version: uint16): InterfaceNixProvisioning =
  result.packageName = readString(bytes, pos)
  result.selector = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  if version >= 3'u16:
    result.expressionFile = readString(bytes, pos)
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeTarballProvisioning(outp: var seq[byte];
                              provisioning: InterfaceTarballProvisioning) =
  outp.writeString(provisioning.packageName)
  outp.writeString(provisioning.url)
  outp.writeStringSeq(provisioning.mirrors)
  outp.writeString(provisioning.sha256)
  outp.writeString(provisioning.archiveType)
  outp.writeString(provisioning.executablePath)
  outp.writeU32Le(uint32(max(provisioning.stripComponents, 0)))
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeLocation(provisioning.location)

proc readTarballProvisioning(bytes: openArray[byte]; pos: var int):
    InterfaceTarballProvisioning =
  result.packageName = readString(bytes, pos)
  result.url = readString(bytes, pos)
  result.mirrors = readStringSeq(bytes, pos)
  result.sha256 = readString(bytes, pos)
  result.archiveType = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  result.stripComponents = int(readU32Le(bytes, pos))
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeScoopProvisioning(outp: var seq[byte];
                            provisioning: InterfaceScoopProvisioning) =
  outp.writeString(provisioning.packageName)
  outp.writeString(provisioning.bucket)
  outp.writeString(provisioning.app)
  outp.writeString(provisioning.version)
  outp.writeString(provisioning.preferredVersion)
  outp.writeString(provisioning.manifestChecksum)
  outp.writeString(provisioning.manifestUrl)
  outp.writeString(provisioning.executablePath)
  outp.writeByte(byte(ord(provisioning.requiresExecutionProfileChecksum)))
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeLocation(provisioning.location)

proc readScoopProvisioning(bytes: openArray[byte]; pos: var int):
    InterfaceScoopProvisioning =
  result.packageName = readString(bytes, pos)
  result.bucket = readString(bytes, pos)
  result.app = readString(bytes, pos)
  result.version = readString(bytes, pos)
  result.preferredVersion = readString(bytes, pos)
  result.manifestChecksum = readString(bytes, pos)
  result.manifestUrl = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  result.requiresExecutionProfileChecksum = readByte(bytes, pos) != 0
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeToolUse(outp: var seq[byte]; useDef: InterfaceToolUse) =
  outp.writeString(useDef.rawConstraint)
  outp.writeString(useDef.packageSelector)
  outp.writeString(useDef.executableName)
  outp.writeStringSeq(useDef.policyPath)
  outp.writeU32Le(uint32(useDef.nixProvisioning.len))
  for provisioning in useDef.nixProvisioning:
    outp.writeNixProvisioning(provisioning)
  outp.writeU32Le(uint32(useDef.tarballProvisioning.len))
  for provisioning in useDef.tarballProvisioning:
    outp.writeTarballProvisioning(provisioning)
  outp.writeU32Le(uint32(useDef.scoopProvisioning.len))
  for provisioning in useDef.scoopProvisioning:
    outp.writeScoopProvisioning(provisioning)
  outp.writeLocation(useDef.location)

proc readToolUse(bytes: openArray[byte]; pos: var int;
                 version: uint16): InterfaceToolUse =
  result.rawConstraint = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.policyPath = readStringSeq(bytes, pos)
  if version >= 2'u16:
    let provisioningCount = int(readU32Le(bytes, pos))
    result.nixProvisioning = newSeq[InterfaceNixProvisioning](
      provisioningCount)
    for i in 0 ..< provisioningCount:
      result.nixProvisioning[i] = readNixProvisioning(bytes, pos, version)
  if version >= 4'u16:
    let tarballCount = int(readU32Le(bytes, pos))
    result.tarballProvisioning = newSeq[InterfaceTarballProvisioning](
      tarballCount)
    for i in 0 ..< tarballCount:
      result.tarballProvisioning[i] = readTarballProvisioning(bytes, pos)
  if version >= 5'u16:
    let scoopCount = int(readU32Le(bytes, pos))
    result.scoopProvisioning = newSeq[InterfaceScoopProvisioning](scoopCount)
    for i in 0 ..< scoopCount:
      result.scoopProvisioning[i] = readScoopProvisioning(bytes, pos)
  result.location = readLocation(bytes, pos)

proc encodeInterfacePayload*(value: ProjectInterface): seq[byte] =
  result.writeString(value.projectName)
  result.writeString(value.packageName)
  result.writeStringSeq(value.publicSignatureDependencies)
  result.writeLocation(value.location)
  result.writeU32Le(uint32(value.publicExecutables.len))
  for exe in value.publicExecutables:
    result.writeExecutable(exe)
  result.writeU32Le(uint32(value.toolUses.len))
  for useDef in value.toolUses:
    result.writeToolUse(useDef)

proc decodeInterfacePayload*(bytes: openArray[byte];
                             version = EnvelopeVersion): ProjectInterface =
  var pos = 0
  result.projectName = readString(bytes, pos)
  result.packageName = readString(bytes, pos)
  result.publicSignatureDependencies = readStringSeq(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.publicExecutables = newSeq[InterfaceExecutable](count)
  for i in 0 ..< count:
    result.publicExecutables[i] = readExecutable(bytes, pos)
  let useCount = int(readU32Le(bytes, pos))
  result.toolUses = newSeq[InterfaceToolUse](useCount)
  for i in 0 ..< useCount:
    result.toolUses[i] = readToolUse(bytes, pos, version)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing interface payload bytes")

proc interfaceFingerprint*(value: ProjectInterface): ContentDigest =
  blake3DomainDigest(encodeInterfacePayload(value), hdMetadataEnvelope)

proc artifactFor*(value: ProjectInterface): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(
    projectInterface: value,
    interfaceFingerprint: interfaceFingerprint(value))

proc writeEnvelopeHeader(outp: var seq[byte]; kind: InterfaceEnvelopeKind;
                         payloadLength: int) =
  outp.add(EnvelopeMagic)
  outp.writeU16Le(EnvelopeVersion)
  outp.writeU16Le(uint16(ord(kind) + 101))
  outp.writeU32Le(uint32(payloadLength))

proc encodeProjectInterfaceArtifact*(artifact: ProjectInterfaceArtifact): seq[byte] =
  var payload = encodeInterfacePayload(artifact.projectInterface)
  payload.writeDigest(artifact.interfaceFingerprint)
  result.writeEnvelopeHeader(iekProjectInterface, payload.len)
  result.add(payload)

proc decodeProjectInterfaceArtifact*(bytes: openArray[
    byte]): ProjectInterfaceArtifact =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated interface artifact envelope")
  for i in 0 ..< 4:
    if bytes[i] != EnvelopeMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown interface artifact envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version < 1'u16 or version > EnvelopeVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported interface envelope version")
  let typeId = readU16Le(bytes, pos)
  if typeId != uint16(ord(iekProjectInterface) + 101):
    raiseEnvelopeError(eeUnknownType, "not a project interface artifact")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "interface envelope payload length mismatch")
  let interfacePayloadLen = payloadLength - 34
  if interfacePayloadLen < 0:
    raiseEnvelopeError(eeMalformed, "truncated interface fingerprint")
  result.projectInterface =
    decodeInterfacePayload(bytes.toOpenArray(pos, pos + interfacePayloadLen - 1),
      version)
  pos += interfacePayloadLen
  result.interfaceFingerprint = readDigest(bytes, pos)
  if result.interfaceFingerprint != interfaceFingerprint(
      result.projectInterface):
    raiseEnvelopeError(eeMalformed, "interface fingerprint mismatch")

proc encodeProviderCompileArtifact*(artifact: ProviderCompileArtifact): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeStringSeq(artifact.inputSources)
  payload.writeString(artifact.outputBinaryPath)
  payload.writeStringSeq(artifact.compilerCommand)
  payload.writeString($artifact.compileEdge.actionSpec.process.cwd)
  payload.writeStringSeq(artifact.compileEdge.declaredInputs)
  payload.writeStringSeq(artifact.compileEdge.declaredOutputs)
  payload.writeDigest(artifact.compileEdge.actionFingerprint)
  payload.writeExecutionResult(artifact.executionResult)
  payload.writeDigest(artifact.interfaceFingerprint)
  payload.writeDigest(artifact.providerFingerprint)
  payload.writeDigest(artifact.outputBinaryFingerprint)
  result.writeEnvelopeHeader(iekProviderCompile, payload.len)
  result.add(payload)

proc decodeProviderCompileArtifact*(bytes: openArray[
    byte]): ProviderCompileArtifact =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated provider compile envelope")
  for i in 0 ..< 4:
    if bytes[i] != EnvelopeMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown provider compile envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != EnvelopeVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported provider compile envelope version")
  let typeId = readU16Le(bytes, pos)
  if typeId != uint16(ord(iekProviderCompile) + 101):
    raiseEnvelopeError(eeUnknownType, "not a provider compile artifact")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "provider compile payload length mismatch")
  result.inputSources = readStringSeq(bytes, pos)
  result.outputBinaryPath = readString(bytes, pos)
  result.compilerCommand = readStringSeq(bytes, pos)
  let processCwd = readString(bytes, pos)
  let declaredInputs = readStringSeq(bytes, pos)
  let declaredOutputs = readStringSeq(bytes, pos)
  let actionFingerprint = readDigest(bytes, pos)
  result.executionResult = readExecutionResult(bytes, pos)
  result.interfaceFingerprint = readDigest(bytes, pos)
  result.providerFingerprint = readDigest(bytes, pos)
  result.outputBinaryFingerprint = readDigest(bytes, pos)
  result.compileEdge = providerCompileEdge(
    result.inputSources,
    result.outputBinaryPath,
    result.compilerCommand,
    result.interfaceFingerprint,
    result.providerFingerprint,
    workDir = processCwd,
    knownActionFingerprint = some(actionFingerprint))
  result.compileEdge.declaredInputs = declaredInputs
  result.compileEdge.declaredOutputs = declaredOutputs
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing provider compile payload bytes")

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writeInterfaceArtifact*(path: string; artifact: ProjectInterfaceArtifact) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProjectInterfaceArtifact(artifact)))

proc readInterfaceArtifact*(path: string): ProjectInterfaceArtifact =
  decodeProjectInterfaceArtifact(fromByteString(readFile(extendedPath(path))))

proc writeProviderCompileArtifact*(path: string;
    artifact: ProviderCompileArtifact) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderCompileArtifact(artifact)))

proc readProviderCompileArtifact*(path: string): ProviderCompileArtifact =
  decodeProviderCompileArtifact(fromByteString(readFile(extendedPath(path))))

proc writeFileStamp(outp: var seq[byte]; stamp: FileStamp) =
  outp.writeString(stamp.path)
  outp.writeByte(byte(ord(stamp.kind)))
  outp.writeU64Le(stamp.sizeBytes)
  outp.writeU64Le(stamp.mtimeNs)

proc readFileStamp(bytes: openArray[byte]; pos: var int): FileStamp =
  result.path = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(fskOther)):
    raiseEnvelopeError(eeMalformed, "invalid file stamp kind")
  result.kind = FileStampKind(kind)
  result.sizeBytes = readU64Le(bytes, pos)
  result.mtimeNs = readU64Le(bytes, pos)

proc writeFileStamps(outp: var seq[byte]; stamps: openArray[FileStamp]) =
  outp.writeU32Le(uint32(stamps.len))
  for stamp in stamps:
    outp.writeFileStamp(stamp)

proc readFileStamps(bytes: openArray[byte]; pos: var int): seq[FileStamp] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[FileStamp](count)
  for i in 0 ..< count:
    result[i] = readFileStamp(bytes, pos)

proc writeInterfaceContext(outp: var seq[byte];
                           context: InterfaceExtractionContext) =
  outp.writeString(context.modulePath)
  outp.writeString(context.workDir)
  outp.writeString(context.nimCompiler)
  outp.writeStringSeq(context.libPathFlags)
  outp.writeStringSeq(context.sources)

proc readInterfaceContext(bytes: openArray[byte]; pos: var int):
    InterfaceExtractionContext =
  result.modulePath = readString(bytes, pos)
  result.workDir = readString(bytes, pos)
  result.nimCompiler = readString(bytes, pos)
  result.libPathFlags = readStringSeq(bytes, pos)
  result.sources = readStringSeq(bytes, pos)

proc encodeInterfaceExtractionCacheRecord(
    record: InterfaceExtractionCacheRecord): seq[byte] =
  result.writeString(InterfaceExtractionCacheRecordMagic)
  result.writeInterfaceContext(record.context)
  result.writeFileStamps(record.sourceStamps)
  result.writeDigest(record.inputFingerprint)

proc decodeInterfaceExtractionCacheRecord(bytes: openArray[byte]):
    InterfaceExtractionCacheRecord =
  var pos = 0
  let magic = readString(bytes, pos)
  if magic != InterfaceExtractionCacheRecordMagic:
    raiseEnvelopeError(eeUnknownType, "not an interface extraction cache record")
  result.context = readInterfaceContext(bytes, pos)
  result.sourceStamps = readFileStamps(bytes, pos)
  result.inputFingerprint = readDigest(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed,
      "trailing interface extraction cache bytes")

proc encodeProviderFreshnessCacheRecord(
    record: ProviderFreshnessCacheRecord): seq[byte] =
  result.writeString(ProviderFreshnessCacheRecordMagic)
  result.writeString(record.modulePath)
  result.writeString(record.outputBinaryPath)
  result.writeFileStamps(record.sourceStamps)
  result.writeFileStamp(record.outputBinaryStamp)
  result.writeDigest(record.interfaceFingerprint)
  result.writeDigest(record.providerFingerprint)
  result.writeDigest(record.outputBinaryFingerprint)

proc decodeProviderFreshnessCacheRecord(bytes: openArray[byte]):
    ProviderFreshnessCacheRecord =
  var pos = 0
  let magic = readString(bytes, pos)
  if magic != ProviderFreshnessCacheRecordMagic:
    raiseEnvelopeError(eeUnknownType, "not a provider freshness cache record")
  result.modulePath = readString(bytes, pos)
  result.outputBinaryPath = readString(bytes, pos)
  result.sourceStamps = readFileStamps(bytes, pos)
  result.outputBinaryStamp = readFileStamp(bytes, pos)
  result.interfaceFingerprint = readDigest(bytes, pos)
  result.providerFingerprint = readDigest(bytes, pos)
  result.outputBinaryFingerprint = readDigest(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing provider freshness cache bytes")

proc toInterfaceParam(param: CliParamDef): InterfaceParam =
  InterfaceParam(
    name: param.name,
    nimType: param.nimType,
    kind: if param.kind == cpkPositional: ipkPositional else: ipkFlag,
    position: param.position,
    alias: param.alias,
    required: param.required,
    location: SourceLocation(file: param.sourceFile, line: param.sourceLine))

proc toInterfaceNixProvisioning(packageName: string;
                                provisioning: NixPackageProvisioningDef):
    InterfaceNixProvisioning =
  InterfaceNixProvisioning(
    packageName: packageName,
    selector: provisioning.selector,
    executablePath: provisioning.executablePath,
    expressionFile: provisioning.expressionFile,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceTarballProvisioning(packageName: string;
                                    provisioning: TarballProvisioningDef):
    InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(
    packageName: packageName,
    url: provisioning.url,
    mirrors: provisioning.mirrors,
    sha256: provisioning.sha256,
    archiveType: provisioning.archiveType,
    executablePath: provisioning.executablePath,
    stripComponents: provisioning.stripComponents,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceScoopProvisioning(packageName: string;
                                  provisioning: ScoopProvisioningDef):
    InterfaceScoopProvisioning =
  InterfaceScoopProvisioning(
    packageName: packageName,
    bucket: provisioning.bucket,
    app: provisioning.app,
    version: provisioning.version,
    preferredVersion: provisioning.preferredVersion,
    manifestChecksum: provisioning.manifestChecksum,
    manifestUrl: provisioning.manifestUrl,
    executablePath: provisioning.executablePath,
    requiresExecutionProfileChecksum:
      provisioning.requiresExecutionProfileChecksum,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceToolUse(useDef: PackageUseDef;
                        packages: openArray[PackageDef]): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: useDef.rawConstraint,
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    policyPath: useDef.policyPath,
    location: SourceLocation(file: useDef.sourceFile, line: useDef.sourceLine))
  for pkg in packages:
    if pkg.packageName == useDef.packageSelector:
      for provisioning in pkg.nixProvisioning:
        result.nixProvisioning.add(toInterfaceNixProvisioning(pkg.packageName,
          provisioning))
      for provisioning in pkg.tarballProvisioning:
        result.tarballProvisioning.add(toInterfaceTarballProvisioning(
          pkg.packageName, provisioning))
      for provisioning in pkg.scoopProvisioning:
        result.scoopProvisioning.add(toInterfaceScoopProvisioning(
          pkg.packageName, provisioning))

proc toProjectInterface*(pkg: PackageDef;
                         packages: openArray[PackageDef] = []):
    ProjectInterface =
  result.projectName = pkg.packageName
  result.packageName = pkg.packageName
  result.publicSignatureDependencies = pkg.publicSignatureDependencies
  result.location = SourceLocation(file: pkg.sourceFile, line: pkg.sourceLine)
  for useDef in pkg.toolUses:
    result.toolUses.add(toInterfaceToolUse(useDef, packages))
  for exe in pkg.executables:
    var normalizedExe = InterfaceExecutable(
      exportName: exe.exportName,
      binaryName: exe.binaryName,
      location: SourceLocation(file: exe.sourceFile, line: exe.sourceLine))
    for cmd in exe.commands:
      var normalizedCmd = InterfaceCommand(
        name: cmd.name,
        providerEntrypointId: cmd.providerEntrypointId,
        location: SourceLocation(file: cmd.sourceFile, line: cmd.sourceLine))
      for param in cmd.params:
        normalizedCmd.params.add(toInterfaceParam(param))
      normalizedExe.commands.add(normalizedCmd)
    result.publicExecutables.add(normalizedExe)

proc sameSourceFile(a, b: string): bool =
  if a.len == 0 or b.len == 0:
    return false
  try:
    if sameFile(a, b):
      return true
  except CatchableError:
    discard
  let rawA = a.replace('\\', '/')
  let rawB = b.replace('\\', '/')
  if rawA == rawB or rawA.endsWith("/" & rawB) or rawB.endsWith("/" & rawA):
    return true
  try:
    os.normalizedPath(expandFilename(a)) ==
      os.normalizedPath(expandFilename(b))
  except CatchableError:
    a == b

proc artifactFromRegisteredDsl*(rootSourceFile = ""): ProjectInterfaceArtifact =
  let packages = registeredPackages()
  if rootSourceFile.len > 0:
    var matches: seq[PackageDef] = @[]
    for pkg in packages:
      if sameSourceFile(pkg.sourceFile, rootSourceFile):
        matches.add(pkg)
    if matches.len == 1:
      return artifactFor(toProjectInterface(matches[0], packages))
    if matches.len > 1:
      raise newException(ValueError,
        "expected one root package in " & rootSourceFile & ", got " &
          $matches.len)
  if packages.len != 1:
    raise newException(ValueError, "expected exactly one registered package, got " &
      $packages.len)
  artifactFor(toProjectInterface(packages[0], packages))

proc nimDefault(nimType: string): string =
  case nimType.normalize
  of "string":
    "\"\""
  of "int":
    "0"
  of "bool":
    "false"
  of "seq[string]":
    "@[]"
  else:
    "default(" & nimType & ")"

proc escForCode(text: string): string =
  text.escape()

proc argBuilder(param: InterfaceParam): string =
  let kindCode =
    if param.kind == ipkPositional:
      "cpkPositional"
    else:
      "cpkFlag"
  let metaArgs = ", " & kindCode & ", " & $param.position & ", " &
    escForCode(param.alias)
  if param.nimType.normalize == "seq[string]":
    "cliArgSeq(\"" & param.name & "\", " & param.name & metaArgs & ")"
  else:
    "cliArg(\"" & param.name & "\", " & param.name & metaArgs & ")"

proc titleIdent(text: string): string =
  if text.len == 0:
    "Package"
  else:
    text[0].toUpperAscii() & text.substr(1) & "Package"

proc validGeneratedIdent(text: string): bool =
  const keywords = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
    "concept", "const", "continue", "converter", "defer", "discard", "distinct",
    "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
    "for", "from", "func", "if", "import", "in", "include", "interface", "is",
    "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
    "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
    "return", "shl", "shr", "static", "template", "try", "tuple", "type",
    "using", "var", "when", "while", "xor", "yield"
  ]
  if text.len == 0 or text.normalize in keywords:
    return false
  if not (text[0].isAlphaAscii() or text[0] == '_'):
    return false
  for ch in text:
    if not (ch.isAlphaNumeric() or ch == '_'):
      return false
  true

proc commandProcName(cmdName: string): string =
  if validGeneratedIdent(cmdName):
    return cmdName
  result = "subcmd"
  for ch in cmdName:
    if ch.isAlphaNumeric():
      result.add("_" & $ch)
    else:
      result.add("_" & toHex(ord(ch), 2).toLowerAscii())

proc writeNimInterfaceStub*(path: string; artifact: ProjectInterfaceArtifact) =
  let pkg = artifact.projectInterface
  var code = "import repro_project_dsl\n\n"
  let typeName = titleIdent(pkg.packageName)
  let exeTypeName = typeName & "Executable"
  code.add("type\n  " & typeName & "* = object\n")
  code.add("  " & exeTypeName & "* = object\n")
  code.add("    value*: SelectedExecutable\n\n")
  code.add("const " & pkg.packageName & "* = " & typeName & "()\n\n")
  code.add("proc executable*(pkg: " & typeName & "; name: string): " &
    exeTypeName & " =\n")
  code.add("  discard pkg\n")
  code.add("  " & exeTypeName & "(value: selectedExecutable(\"" &
    pkg.packageName & "\", name))\n\n")
  var selectedCommands: seq[string] = @[]
  for exe in pkg.publicExecutables:
    for cmd in exe.commands:
      var params: seq[string] = @["exe: " & exeTypeName]
      var argCalls: seq[string] = @[]
      let procName = commandProcName(cmd.name)
      var signature = procName & "|" & cmd.name
      for param in cmd.params:
        var spec = param.name & ": " & param.nimType
        if not param.required:
          spec.add(" = " & nimDefault(param.nimType))
        params.add(spec)
        signature.add("|" & spec)
        argCalls.add(argBuilder(param))
      if selectedCommands.find(signature) >= 0:
        continue
      selectedCommands.add(signature)
      code.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      code.add("  publicCliCall(exe.value.packageName, " &
        "exe.value.executableName, \"" & cmd.name &
        "\", exe.value.packageName & \".\" & exe.value.executableName & " &
        "\"." & cmd.name & "\", @[" & argCalls.join(", ") & "])\n\n")
  if pkg.publicExecutables.len == 1:
    let exe = pkg.publicExecutables[0]
    for cmd in exe.commands:
      var params: seq[string] = @["pkg: " & typeName]
      var argCalls: seq[string] = @[]
      for param in cmd.params:
        var spec = param.name & ": " & param.nimType
        if not param.required:
          spec.add(" = " & nimDefault(param.nimType))
        params.add(spec)
        argCalls.add(argBuilder(param))
      let procName = commandProcName(cmd.name)
      code.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      code.add("  discard pkg\n")
      code.add("  publicCliCall(\"" & pkg.packageName & "\", \"" &
        exe.binaryName &
        "\", \"" & cmd.name & "\", \"" & cmd.providerEntrypointId &
        "\", @[" & argCalls.join(", ") & "])\n\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), code)

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc cmdExeShellEscape(value: string): string =
  ## cmd.exe quoting: wrap in double quotes; escape embedded double quotes.
  "\"" & value.replace("\"", "\\\"") & "\""

proc runCommand(command: openArray[string];
    cwd = ""): ProviderCompileExecutionResult =
  if command.len == 0:
    raise newException(OSError, "runCommand requires a non-empty argv")
  when defined(windows):
    # Capture the child's merged stdout+stderr through a temp-file sink
    # rather than draining an inherited OS pipe. The pipe variant deadlocks
    # on Windows whenever the child (typically `nim c`) spawns a sub-process
    # (gcc) that inherits the pipe write handle: when `nim` exits but gcc
    # is still running, the pipe never EOFs and the parent's `readAll()`
    # blocks forever. Materialising the redirection as a tiny .cmd script
    # (rather than passing it inline through `cmd.exe /c`) sidesteps the
    # cmd.exe outer-quote-stripping rule that otherwise mangles the `>`
    # redirection when the assembled command line starts with a quoted
    # absolute path.
    let sinkDir = getTempDir()
    createDir(extendedPath(sinkDir))
    let nonce = $getCurrentProcessId() & "-" &
      $int64(epochTime() * 1_000_000.0)
    let sinkPath = sinkDir / ("repro-runcommand-" & nonce & ".log")
    let scriptPath = sinkDir / ("repro-runcommand-" & nonce & ".cmd")
    let scriptBody = "@echo off\r\n" &
      command.mapIt(cmdExeShellEscape(it)).join(" ") &
      " > " & cmdExeShellEscape(sinkPath) & " 2>&1\r\n"
    writeFile(extendedPath(scriptPath), scriptBody)
    var process = startProcess("cmd.exe",
      args = @["/c", scriptPath],
      workingDir = cwd, options = {poUsePath})
    let exitCode = process.waitForExit()
    process.close()
    try:
      removeFile(extendedPath(scriptPath))
    except CatchableError:
      discard
    var output = ""
    if fileExists(extendedPath(sinkPath)):
      try:
        output = readFile(extendedPath(sinkPath))
      except CatchableError:
        output = ""
      try:
        removeFile(extendedPath(sinkPath))
      except CatchableError:
        discard
    result = ProviderCompileExecutionResult(
      exitCode: exitCode,
      output: output)
  else:
    let process = startProcess(command[0],
      args = command[1 .. ^1],
      workingDir = cwd,
      options = {poUsePath, poStdErrToStdOut})
    var output = ""
    if process.outputStream != nil:
      output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    result = ProviderCompileExecutionResult(
      exitCode: exitCode,
      output: output)
  if result.exitCode != 0:
    let quoted = command.mapIt(shellQuote(it)).join(" ")
    raise newException(OSError, "command failed (" & $result.exitCode &
      "): " & quoted & "\n" & result.output)

proc nimCompilerPath(): string =
  if cachedNimCompilerPath.len > 0:
    return cachedNimCompilerPath
  let overridePath = getEnv("REPRO_NIM_COMPILER")
  if overridePath.len > 0:
    cachedNimCompilerPath = overridePath
    return overridePath
  proc addUnique(paths: var seq[string]; path: string) =
    if path.len == 0:
      return
    for existing in paths:
      if existing == path:
        return
    paths.add(path)
  proc looksLikeNimCompiler(path: string): bool =
    try:
      let probe = runCommand(@[path, "--version"])
      probe.output.contains("Nim Compiler")
    except CatchableError:
      false
  let exeName = addFileExt("nim", ExeExt)
  var candidates: seq[string] = @[]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0:
      continue
    let candidate = dir / exeName
    if fileExists(extendedPath(candidate)):
      candidates.addUnique(candidate)
  if BuiltNimCompilerPath.len > 0 and fileExists(extendedPath(BuiltNimCompilerPath)):
    candidates.addUnique(BuiltNimCompilerPath)
  candidates.addUnique("nim")
  for candidate in candidates:
    if looksLikeNimCompiler(candidate):
      cachedNimCompilerPath = candidate
      return candidate
  cachedNimCompilerPath =
    if BuiltNimCompilerPath.len > 0 and fileExists(extendedPath(BuiltNimCompilerPath)):
      BuiltNimCompilerPath
    else:
      "nim"
  cachedNimCompilerPath

proc compiledExecutablePath(outputPath: string): string =
  when defined(windows):
    if ExeExt.len == 0 or outputPath.endsWith("." & ExeExt):
      outputPath
    else:
      outputPath & "." & ExeExt
  else:
    outputPath

proc ensureExecutable(path: string) =
  when defined(windows):
    discard path
  else:
    setFilePermissions(extendedPath(path), {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc hostCCompilerPath(): string =
  let ccEnv = getEnv("CC")
  if ccEnv.len > 0 and isAbsolute(ccEnv):
    return ccEnv
  if BuiltCCompilerPath.len > 0 and fileExists(extendedPath(BuiltCCompilerPath)):
    return BuiltCCompilerPath
  ""

proc hostCCompilerFlags(): seq[string] =
  let cc = hostCCompilerPath()
  if cc.len == 0:
    return
  result.add("--gcc.exe:" & cc)
  result.add("--gcc.linkerexe:" & cc)
  result.add("--clang.exe:" & cc)
  result.add("--clang.linkerexe:" & cc)

proc reproLibPathFlags(workDir: string): seq[string] =
  let libsRoot = workDir / "libs"
  if dirExists(extendedPath(libsRoot)):
    # TODO(win-longpath): walk results escape; needs review
    for path in walkDir(libsRoot):
      if path.kind == pcDir:
        let src = path.path / "src"
        if dirExists(extendedPath(src)):
          result.add("--path:" & src)
  result.sort(system.cmp[string])

proc discoverNimSources*(rootModulePath: string): seq[string] =
  let root = parentDir(rootModulePath)
  var dirs = @[root]
  while dirs.len > 0:
    let dir = dirs.pop()
    # TODO(win-longpath): walk results escape; needs review
    for kind, path in walkDir(dir):
      let tail = splitPath(path).tail
      case kind
      of pcDir:
        if tail notin [".git", ".repro", "CMakeFiles", "nimcache-provider"]:
          dirs.add(path)
      of pcFile:
        if path.endsWith(".nim"):
          result.add(path)
      else:
        discard
  result.sort(system.cmp[string])

proc normalizedStampPath(path: string): string =
  os.normalizedPath(path).replace('\\', '/')

proc fileStamp(path: string): FileStamp =
  result.path = normalizedStampPath(path)
  if not fileExists(extendedPath(path)) and not dirExists(extendedPath(path)):
    result.kind = fskMissing
    return
  let info = getFileInfo(extendedPath(path), followSymlink = false)
  result.kind =
    case info.kind
    of pcFile, pcLinkToFile:
      fskRegular
    of pcDir, pcLinkToDir:
      fskDirectory
  result.sizeBytes = uint64(max(info.size, 0))
  let mtime = info.lastWriteTime
  result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
    uint64(mtime.nanosecond)

proc fileStamps(paths: openArray[string]): seq[FileStamp] =
  for path in paths:
    result.add(fileStamp(path))
  result.sort do (a, b: FileStamp) -> int:
    cmp(a.path, b.path)

proc interfaceExtractionContext(modulePath: string;
                                workDir = getCurrentDir()):
    InterfaceExtractionContext =
  let sources = discoverNimSources(modulePath).mapIt(normalizedStampPath(it))
  InterfaceExtractionContext(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    nimCompiler: nimCompilerPath(),
    libPathFlags: reproLibPathFlags(workDir),
    sources: sources)

proc interfaceExtractionFingerprint(context: InterfaceExtractionContext):
    ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.interfaceExtract.v1")
  payload.writeString(context.modulePath)
  payload.writeString(context.workDir)
  payload.writeString(context.nimCompiler)
  payload.writeStringSeq(context.libPathFlags)
  for path in context.sources:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

proc interfaceExtractionFingerprint*(modulePath: string;
                                     workDir = getCurrentDir()): ContentDigest =
  interfaceExtractionFingerprint(interfaceExtractionContext(modulePath, workDir))

proc interfaceExtractionCachePath(artifactPath: string): string =
  artifactPath & ".inputs"

proc interfaceExtractionMetadataPath(artifactPath: string): string =
  artifactPath & ".inputs.meta"

proc writeInterfaceExtractionCacheRecord(artifactPath: string;
    context: InterfaceExtractionContext; fingerprint: ContentDigest) =
  let record = InterfaceExtractionCacheRecord(
    context: context,
    sourceStamps: fileStamps(context.sources),
    inputFingerprint: fingerprint)
  try:
    writeFile(extendedPath(interfaceExtractionMetadataPath(artifactPath)),
      toByteString(encodeInterfaceExtractionCacheRecord(record)))
  except CatchableError:
    discard

proc readInterfaceExtractionCacheRecord(path: string):
    Option[InterfaceExtractionCacheRecord] =
  if not fileExists(extendedPath(path)):
    return none(InterfaceExtractionCacheRecord)
  try:
    return some(decodeInterfaceExtractionCacheRecord(fromByteString(readFile(extendedPath(path)))))
  except CatchableError:
    return none(InterfaceExtractionCacheRecord)

proc cachedInterfaceArtifactByMetadata(artifactPath, stubPath: string;
                                       context: InterfaceExtractionContext):
    Option[ProjectInterfaceArtifact] =
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(stubPath))):
    return none(ProjectInterfaceArtifact)
  let record = readInterfaceExtractionCacheRecord(
    interfaceExtractionMetadataPath(artifactPath))
  if record.isNone:
    return none(ProjectInterfaceArtifact)
  let cached = record.get()
  if cached.context != context:
    return none(ProjectInterfaceArtifact)
  if cached.sourceStamps != fileStamps(context.sources):
    return none(ProjectInterfaceArtifact)
  try:
    let artifact = readInterfaceArtifact(artifactPath)
    if artifact.interfaceFingerprint != cached.inputFingerprint:
      return none(ProjectInterfaceArtifact)
    return some(artifact)
  except CatchableError:
    return none(ProjectInterfaceArtifact)

proc cachedInterfaceArtifactByFingerprint(artifactPath, stubPath: string;
                                          fingerprint: ContentDigest):
    Option[ProjectInterfaceArtifact] =
  let cachePath = interfaceExtractionCachePath(artifactPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(stubPath)) and
      fileExists(extendedPath(cachePath))):
    return none(ProjectInterfaceArtifact)
  if readFile(extendedPath(cachePath)).strip() != toHex(fingerprint.bytes):
    return none(ProjectInterfaceArtifact)
  try:
    return some(readInterfaceArtifact(artifactPath))
  except CatchableError:
    return none(ProjectInterfaceArtifact)

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         libraryNames: openArray[string]): string =
  proc hasLibrary(prefix, libraryName: string): bool =
    let exact = prefix / "lib" / libraryName
    if fileExists(extendedPath(exact)):
      return true
    let dot = libraryName.find('.')
    let stem =
      if dot > 0:
        libraryName[0 ..< dot]
      else:
        libraryName
    if not dirExists(extendedPath(prefix / "lib")):
      return false
    for kind, path in walkDir(extendedPath(prefix / "lib")):
      if kind == pcFile:
        let tail = splitPath(path).tail
        if tail == libraryName or tail.startsWith(stem & "."):
          return true

  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(extendedPath(prefix / header)):
      continue
    for libraryName in libraryNames:
      if hasLibrary(prefix, libraryName):
        return prefix
  ""

proc nixPrefix(namePattern, header: string;
               libraryNames: openArray[string]): string =
  if not dirExists(extendedPath("/nix/store")):
    return ""
  let needle = namePattern.replace("*", "")
  # TODO(win-longpath): walk results escape; needs review
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    let tail = splitPath(path).tail
    if needle.len > 0 and tail.find(needle) < 0:
      continue
    if not fileExists(extendedPath(path / header)):
      continue
    for libraryName in libraryNames:
      if firstExistingPrefix([path], header, [libraryName]).len > 0:
        return path

proc externalHashFlags(workDir = ""): seq[string] =
  # Windows: there is no homebrew/nix prefix that ships libblake3 or libxxhash.
  # The reprobuild repo vendors portable C sources for both under
  # references/mold/third-party/, and config.nims wires the include paths +
  # `{.compile:.}` pragmas accordingly. When repro is run as a CLI against an
  # arbitrary project, the project's nim invocation does NOT pick up
  # reprobuild's config.nims (different working directory), so we have to
  # propagate the same -I flags here. The vendored sources live alongside the
  # reprobuild library tree, so resolve the include dirs relative to workDir
  # (which is the reprobuildLibraryWorkDir) — there is no system-wide install
  # to discover.
  when defined(windows):
    if workDir.len > 0:
      let blake3Inc = workDir / "references" / "mold" / "third-party" /
        "blake3" / "c"
      let xxhashInc = workDir / "references" / "mold" / "third-party" /
        "xxhash"
      if fileExists(extendedPath(blake3Inc / "blake3.h")):
        result.add("--passC:-I" & blake3Inc)
      if fileExists(extendedPath(xxhashInc / "xxhash.h")):
        result.add("--passC:-I" & xxhashInc)
    return

  let blake3Prefix = block:
    let direct = firstExistingPrefix(
      [getEnv("BLAKE3_PREFIX"), "/opt/homebrew/opt/blake3",
        "/usr/local/opt/blake3"],
      "include/blake3.h",
      ["libblake3.dylib", "libblake3.so", "libblake3.a"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-libblake3-*", "include/blake3.h",
        ["libblake3.dylib", "libblake3.so", "libblake3.a"])
  if blake3Prefix.len > 0:
    result.add("--passC:-I" & blake3Prefix / "include")
    result.add("--passL:-L" & blake3Prefix / "lib")
    result.add("--passL:-lblake3")

  let xxhashPrefix = block:
    let direct = firstExistingPrefix(
      [getEnv("XXHASH_PREFIX"), "/opt/homebrew/opt/xxhash",
        "/usr/local/opt/xxhash"],
      "include/xxhash.h",
      ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-xxHash-*", "include/xxhash.h",
        ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
  if xxhashPrefix.len > 0:
    result.add("--passC:-I" & xxhashPrefix / "include")
    result.add("--passL:-L" & xxhashPrefix / "lib")
    result.add("--passL:-lxxhash")

proc fnvHex64(parts: openArray[string]): string =
  ## FNV-1a 64-bit hex digest of the concatenation of `parts` (with a NUL
  ## separator between parts so prefix collisions are impossible). Rendered
  ## inline to avoid pulling in a specific `toHex`.
  var h = 0xcbf29ce484222325'u64
  for i, part in parts:
    if i > 0:
      h = (h xor 0'u64) * 0x100000001b3'u64
    for ch in part:
      h = (h xor uint64(ord(ch))) * 0x100000001b3'u64
  const hexDigits = "0123456789abcdef"
  result = newString(16)
  for i in 0 ..< 16:
    result[15 - i] = hexDigits[int((h shr (uint64(i) * 4)) and 0xF'u64)]

proc providerNimcacheKey(outputBinaryPath: string): string =
  ## Per-output-binary nimcache key (FNV-1a of absolute output path).
  ## Retained for opt-in isolation via `REPRO_PROVIDER_NIMCACHE_MODE=per-binary`.
  fnvHex64([absolutePath(outputBinaryPath)])

proc sharedProviderNimcacheKey(workDir: string;
                               hostFlags, libFlags: openArray[string]): string =
  ## Toolchain-stable nimcache key shared across every provider compile that
  ## targets the same Nim compiler + host C compiler + library set, anchored
  ## at the same `workDir`. Provider compiles invoked from a single CMake
  ## configure (the parent project plus every `try_compile`) land in the
  ## same nimcache so unchanged library modules are reused across them --
  ## the dominant slice of each provider compile.
  var parts = @[nimCompilerPath(), absolutePath(workDir)]
  for f in hostFlags:
    parts.add(f)
  for f in libFlags:
    parts.add(f)
  fnvHex64(parts)

proc providerNimcacheMode(): string =
  let mode = getEnv("REPRO_PROVIDER_NIMCACHE_MODE")
  if mode.len == 0: "shared" else: mode.toLowerAscii()

proc providerDynamicEnabled(): bool =
  ## Returns true when ``REPRO_PROVIDER_DYNAMIC`` selects the Tier 1
  ## shared DSL runtime DLL link mode (see
  ## ``reprobuild-specs/Provider-Compile-Tiering.md``). Off by default
  ## until the DLL's dynamic-mode forward declarations land and the
  ## bench has measured the configure-time drop; switching it on today
  ## adds the link arguments to the provider compile but does not yet
  ## shrink the compile, because the umbrella DSL still pulls every
  ## runtime proc body into the per-project binary.
  let raw = getEnv("REPRO_PROVIDER_DYNAMIC").toLowerAscii()
  raw in ["1", "true", "yes", "on"]

proc providerDynamicLibDir(workDir: string): string =
  ## Filesystem directory that the per-project provider link step
  ## searches for the shared DSL runtime DLL. This matches the build
  ## script's output location
  ## (``build/lib/librepro_project_dsl_runtime.{dll,so,dylib}``).
  workDir / "build" / "lib"

proc buildScratchRoot(workDir, scratchDir: string): string =
  if scratchDir.len > 0:
    scratchDir
  else:
    workDir / "build"

proc extractInterfaceFromModule*(modulePath, artifactPath, stubPath: string;
                                 workDir = getCurrentDir();
                                 scratchDir = ""): ProjectInterfaceArtifact =
  let extractionContext = interfaceExtractionContext(modulePath, workDir)
  let metadataCached = cachedInterfaceArtifactByMetadata(artifactPath,
    stubPath, extractionContext)
  if metadataCached.isSome:
    return metadataCached.get()

  let inputFingerprint = interfaceExtractionFingerprint(extractionContext)
  let cached = cachedInterfaceArtifactByFingerprint(artifactPath, stubPath,
    inputFingerprint)
  if cached.isSome:
    writeInterfaceExtractionCacheRecord(artifactPath, extractionContext,
      inputFingerprint)
    return cached.get()

  let moduleDir = parentDir(modulePath)
  let moduleName = splitFile(modulePath).name
  # Windows: the extract_runner.nim path is passed verbatim to a child
  # `nim c` invocation, and nim opens it via the non-extended Win32 API,
  # so paths longer than MAX_PATH (260 chars) cause `Error: cannot open
  # …extract_runner.nim`. CMake TryCompile workdirs nested inside the
  # generator's per-build worktree blow past that limit, so prefer the
  # system temp dir for the runner scratch tree on Windows.
  let tempParent =
    when defined(windows):
      getTempDir() / "repro-interface-extract"
    else:
      buildScratchRoot(workDir, scratchDir) / "m7-temp"
  createDir(extendedPath(tempParent))
  inc interfaceTempNonce
  let now = getTime()
  let tempRoot = tempParent / ("repro-interface-extract-" &
    $getCurrentProcessId() & "-" & $now.toUnix & "-" & $now.nanosecond &
    "-" & $interfaceTempNonce)
  createDir(extendedPath(tempRoot))
  defer: removeDir(extendedPath(tempRoot))
  let runnerPath = tempRoot / "extract_runner.nim"
  writeFile(extendedPath(runnerPath),
    "import std/os\n" &
    "import repro_interface_artifacts\n" &
    "import repro_project_dsl\n" &
    "import " & moduleName & "\n\n" &
    "let artifact = artifactFromRegisteredDsl(paramStr(3))\n" &
    "writeInterfaceArtifact(paramStr(1), artifact)\n" &
    "writeNimInterfaceStub(paramStr(2), artifact)\n")
  let runnerBin = tempRoot / "extract_runner"
  let hostFlags = hostCCompilerFlags()
  let libFlags = reproLibPathFlags(workDir)
  # Share the extractor nimcache across every interface extraction with the
  # same toolchain + library set. The runner module itself (`extract_runner`)
  # recompiles each time because it imports a project-specific module, but
  # every standard library / repro library module is reused via Nim's
  # `.sha1`-based incremental compilation -- the dominant slice of the
  # compile cost. `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` falls back to
  # the per-tempRoot nimcache that isolates each invocation.
  # Nim's `--nimcache:` directive is also subject to the MAX_PATH ceiling
  # because Nim's own mkdir does not use the \\?\ extended-length prefix.
  # On Windows root the shared nimcache under the same short temp parent
  # we use for the runner, keyed by toolchain+library set so independent
  # extractions still share the bulk of the standard-library compile
  # cost. `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` keeps each
  # extraction's nimcache fully isolated.
  let nimcache =
    if providerNimcacheMode() == "per-binary":
      tempRoot / "nimcache"
    else:
      when defined(windows):
        tempParent / "nimcache-interface" /
          sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
      else:
        buildScratchRoot(workDir, scratchDir) / "nimcache-interface" /
          sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
  var command = @[
    nimCompilerPath(), "c",
    "--define:reproInterfaceMode",
    "--path:" & moduleDir,
    "--nimcache:" & nimcache,
    "--out:" & runnerBin,
    runnerPath
  ]
  command.insert(hostFlags, 2)
  command.insert(externalHashFlags(workDir), 2)
  command.insert(libFlags, 4)
  let compileExecution = runCommand(command, cwd = workDir)
  let runnerExe = compiledExecutablePath(runnerBin)
  if not fileExists(extendedPath(runnerExe)):
    raise newException(IOError,
      "interface extraction runner was not compiled: " & runnerExe &
        "\n" & compileExecution.output)
  ensureExecutable(runnerExe)
  let execution = runCommand(@[runnerExe, artifactPath, stubPath, modulePath],
    cwd = workDir)
  if not fileExists(extendedPath(artifactPath)):
    raise newException(IOError,
      "interface extraction did not write artifact: " & artifactPath &
        "\n" & execution.output)
  result = readInterfaceArtifact(artifactPath)
  writeFile(extendedPath(interfaceExtractionCachePath(artifactPath)), toHex(
      inputFingerprint.bytes))
  writeInterfaceExtractionCacheRecord(artifactPath, extractionContext,
    inputFingerprint)

proc providerFingerprintFor*(inputSources: openArray[string];
                             interfaceFingerprint: ContentDigest): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeDigest(interfaceFingerprint)
  for path in inputSources:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

proc providerFreshnessCachePath(artifactPath: string): string =
  artifactPath & ".inputs"

proc writeProviderFreshnessCacheRecord(artifactPath, modulePath: string;
                                       artifact: ProviderCompileArtifact) =
  let record = ProviderFreshnessCacheRecord(
    modulePath: normalizedStampPath(modulePath),
    outputBinaryPath: normalizedStampPath(artifact.outputBinaryPath),
    sourceStamps: fileStamps(artifact.inputSources),
    outputBinaryStamp: fileStamp(artifact.outputBinaryPath),
    interfaceFingerprint: artifact.interfaceFingerprint,
    providerFingerprint: artifact.providerFingerprint,
    outputBinaryFingerprint: artifact.outputBinaryFingerprint)
  try:
    writeFile(extendedPath(providerFreshnessCachePath(artifactPath)),
      toByteString(encodeProviderFreshnessCacheRecord(record)))
  except CatchableError:
    discard

proc readProviderFreshnessCacheRecord(path: string):
    Option[ProviderFreshnessCacheRecord] =
  if not fileExists(extendedPath(path)):
    return none(ProviderFreshnessCacheRecord)
  try:
    return some(decodeProviderFreshnessCacheRecord(fromByteString(readFile(extendedPath(path)))))
  except CatchableError:
    return none(ProviderFreshnessCacheRecord)

proc providerFreshnessRecordMatches(record: ProviderFreshnessCacheRecord;
                                    modulePath, outputBinaryPath: string;
                                    inputSources: openArray[string];
                                    interfaceFingerprint,
                                    providerFingerprint,
                                    outputBinaryFingerprint: ContentDigest): bool =
  (modulePath.len == 0 or record.modulePath == normalizedStampPath(modulePath)) and
    record.outputBinaryPath == normalizedStampPath(outputBinaryPath) and
    record.interfaceFingerprint == interfaceFingerprint and
    record.providerFingerprint == providerFingerprint and
    record.outputBinaryFingerprint == outputBinaryFingerprint and
    record.sourceStamps == fileStamps(inputSources) and
    record.outputBinaryStamp == fileStamp(outputBinaryPath)

proc cachedProviderFreshnessByMetadata(artifactPath, modulePath,
                                       outputBinaryPath: string;
                                       inputSources: openArray[string];
                                       cached: ProviderCompileArtifact):
    bool =
  let record = readProviderFreshnessCacheRecord(
    providerFreshnessCachePath(artifactPath))
  if record.isNone:
    return false
  providerFreshnessRecordMatches(record.get(), modulePath, outputBinaryPath,
    inputSources, cached.interfaceFingerprint, cached.providerFingerprint,
    cached.outputBinaryFingerprint)

proc normalizedProviderOutputPath*(outputBinaryPath: string): string =
  # On Windows, the Nim compiler emits executables with a .exe suffix even
  # when `--out:` is given without one. Normalize the requested path so the
  # rest of the pipeline (cache lookup, startProcess) sees the real artifact
  # location. ExeExt is "" on POSIX so this is a no-op there.
  when defined(windows):
    if outputBinaryPath.endsWith("." & ExeExt) or ExeExt.len == 0:
      outputBinaryPath
    else:
      outputBinaryPath & "." & ExeExt
  else:
    outputBinaryPath

proc providerCompileCommand*(modulePath, outputBinaryPath: string;
                             workDir = getCurrentDir();
                             scratchDir = ""): seq[string] =
  # The Nim provider nimcache holds generated C/object files with long
  # `@m..@s..nim.c` names. When `outputBinaryPath` lands deep inside a
  # CMake TryCompile scratch tree, a nimcache placed next to it overflows
  # Windows' 260-char MAX_PATH. The nimcache is a pure build intermediate,
  # so anchor it under the short scratch root that the interface extractor also
  # uses.
  #
  # The key is shared across every provider compile that targets the same
  # toolchain + library set (default `REPRO_PROVIDER_NIMCACHE_MODE=shared`).
  # Each CMake configure pays for one cold provider compile; subsequent
  # try_compile providers reuse all unchanged library object files via
  # Nim's `.sha1`-based incremental compilation. Within a single CMake
  # configure the provider compiles are sequential, so the shared cache is
  # safe. `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` restores the legacy
  # per-output isolation.
  let hostFlags = hostCCompilerFlags()
  let libFlags = reproLibPathFlags(workDir)
  let scratchRoot = buildScratchRoot(workDir, scratchDir)
  # Windows: nimcache lives in a short system-temp tree because Nim's
  # mkdir does not use the \\?\ extended-length prefix. CMake TryCompile
  # roots already overflow MAX_PATH by themselves, so the legacy
  # `scratchRoot / "nimcache-provider"` layout cannot be created at all
  # in that context. The same key is reused across every provider
  # compile with matching toolchain + library set, so we still get the
  # cache-sharing benefit within the same `repro` process.
  let nimcacheRoot =
    when defined(windows):
      getTempDir() / "repro-nimcache-provider"
    else:
      scratchRoot / "nimcache-provider"
  let nimcache =
    if providerNimcacheMode() == "per-binary":
      nimcacheRoot / providerNimcacheKey(outputBinaryPath)
    else:
      nimcacheRoot / sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
  result = @[
    nimCompilerPath(), "c",
    "--define:reproProviderMode",
    "--path:" & parentDir(modulePath),
    "--nimcache:" & nimcache,
    "--out:" & outputBinaryPath,
    modulePath
  ]
  result.insert(hostFlags, 2)
  result.insert(externalHashFlags(workDir), 2)
  result.insert(libFlags, 2)
  if providerDynamicEnabled():
    # Tier 1 shared DSL runtime DLL: opt-in via ``REPRO_PROVIDER_DYNAMIC=1``.
    # The define switches the DSL umbrella module into dynamic mode and
    # the link flags point at the DLL location produced by
    # ``scripts/build_apps.sh``.
    #
    # The absolute DLL path is also baked into the per-project provider
    # via ``--define:reproProviderDynamicLibPath=<abs>`` so the
    # ``{.dynlib.}`` consumer can ``dlopen``/``LoadLibrary`` the DLL
    # directly when the per-project binary is launched from a directory
    # where the default DLL search order would not find it — notably
    # the deep CMake ``TryCompile`` scratch dirs that the
    # cmake-reprobuild generator hands the engine. On POSIX the link
    # step still emits an rpath so the binary is also self-locating
    # when copied around.
    let libDir = providerDynamicLibDir(workDir)
    let dllExt =
      when defined(windows): "dll"
      elif defined(macosx):  "dylib"
      else:                  "so"
    let dllAbsPath = absolutePath(libDir / ("librepro_project_dsl_runtime." & dllExt))
    var dynamicFlags = @[
      "--define:reproProviderDynamic",
      "--define:reproProviderDynamicLibPath=" & dllAbsPath,
      "--passL:-L" & libDir,
      "--passL:-lrepro_project_dsl_runtime"
    ]
    when not defined(windows):
      dynamicFlags.add("--passL:-Wl,-rpath," & libDir)
    for flag in dynamicFlags:
      result.insert(flag, 2)

proc providerCompilePlan*(modulePath, outputBinaryPath: string;
                          interfaceFingerprint: ContentDigest;
                          workDir = getCurrentDir();
                          scratchDir = ""): ProviderCompilePlan =
  let normalizedOutputPath = normalizedProviderOutputPath(outputBinaryPath)
  let sources = discoverNimSources(modulePath)
  let providerFingerprint = providerFingerprintFor(sources, interfaceFingerprint)
  let command = providerCompileCommand(modulePath, normalizedOutputPath, workDir,
    scratchDir)
  let edge = providerCompileEdge(sources, normalizedOutputPath, command,
    interfaceFingerprint, providerFingerprint, workDir = workDir)
  ProviderCompilePlan(
    inputSources: sources,
    outputBinaryPath: normalizedOutputPath,
    compilerCommand: command,
    compileEdge: edge,
    interfaceFingerprint: interfaceFingerprint,
    providerFingerprint: providerFingerprint)

proc providerCompileArtifactFresh*(artifactPath, outputBinaryPath: string;
                                   interfaceFingerprint,
                                   providerFingerprint: ContentDigest): bool =
  let normalizedOutputPath = normalizedProviderOutputPath(outputBinaryPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(normalizedOutputPath))):
    return false
  try:
    let cached = readProviderCompileArtifact(artifactPath)
    if cached.providerFingerprint != providerFingerprint:
      return false
    if cached.interfaceFingerprint != interfaceFingerprint:
      return false
    if cached.outputBinaryPath != normalizedOutputPath:
      return false
    if cachedProviderFreshnessByMetadata(artifactPath, "", normalizedOutputPath,
        cached.inputSources, cached):
      return true
    if cached.outputBinaryFingerprint != casDigest(toBytes(readFile(
        extendedPath(normalizedOutputPath)))):
      return false
    return true
  except CatchableError:
    false

proc readFreshProviderCompileArtifact*(artifactPath, modulePath,
                                       outputBinaryPath: string;
                                       interfaceFingerprint: ContentDigest):
    Option[ProviderCompileArtifact] =
  let normalizedOutputPath = normalizedProviderOutputPath(outputBinaryPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(normalizedOutputPath))):
    return none(ProviderCompileArtifact)
  try:
    let cached = readProviderCompileArtifact(artifactPath)
    if cached.interfaceFingerprint != interfaceFingerprint:
      return none(ProviderCompileArtifact)
    if cached.outputBinaryPath != normalizedOutputPath:
      return none(ProviderCompileArtifact)
    let sources = discoverNimSources(modulePath)
    if cachedProviderFreshnessByMetadata(artifactPath, modulePath,
        normalizedOutputPath, sources, cached):
      return some(cached)
    let providerFingerprint = providerFingerprintFor(sources,
      interfaceFingerprint)
    if cached.providerFingerprint != providerFingerprint:
      return none(ProviderCompileArtifact)
    if cached.outputBinaryFingerprint != casDigest(toBytes(readFile(
        extendedPath(normalizedOutputPath)))):
      return none(ProviderCompileArtifact)
    writeProviderFreshnessCacheRecord(artifactPath, modulePath, cached)
    return some(cached)
  except CatchableError:
    return none(ProviderCompileArtifact)

proc compileProviderBinary*(modulePath, outputBinaryPath: string;
                            interfaceFingerprint: ContentDigest;
                            artifactPath = "";
                            workDir = getCurrentDir();
                            scratchDir = ""): ProviderCompileArtifact =
  let plan = providerCompilePlan(modulePath, outputBinaryPath,
    interfaceFingerprint, workDir, scratchDir)
  if artifactPath.len > 0 and providerCompileArtifactFresh(artifactPath,
      plan.outputBinaryPath, interfaceFingerprint, plan.providerFingerprint):
    return readProviderCompileArtifact(artifactPath)
  createDir(extendedPath(parentDir(plan.outputBinaryPath)))
  let execution = runCommand(plan.compilerCommand, cwd = workDir)
  if not fileExists(extendedPath(plan.outputBinaryPath)):
    raise newException(IOError,
      "provider compilation did not write binary: " & plan.outputBinaryPath &
        "\n" & execution.output)
  result = ProviderCompileArtifact(
    inputSources: plan.inputSources,
    outputBinaryPath: plan.outputBinaryPath,
    compilerCommand: plan.compilerCommand,
    compileEdge: plan.compileEdge,
    interfaceFingerprint: interfaceFingerprint,
    providerFingerprint: plan.providerFingerprint,
    outputBinaryFingerprint: casDigest(toBytes(readFile(
        extendedPath(plan.outputBinaryPath)))),
    executionResult: execution)
  if artifactPath.len > 0:
    writeProviderCompileArtifact(artifactPath, result)
    writeProviderFreshnessCacheRecord(artifactPath, modulePath, result)
