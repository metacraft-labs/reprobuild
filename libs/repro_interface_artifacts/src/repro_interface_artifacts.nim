import std/[algorithm, options, os, osproc, sequtils, sets, streams, strutils,
            tables, times]

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

  InterfaceLibrary* = object
    name*: string
    kind*: LibraryKind
    location*: SourceLocation

  InterfaceNixProvisioning* = object
    packageName*: string
    selector*: string
    executablePath*: string
    expressionFile*: string
    nixpkgsRef*: string
    nixpkgsRev*: string
    nixpkgsNarHash*: string
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
    cpu*: string
    os*: string
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
    defaultToolProvisioning*: string
    publicExecutables*: seq[InterfaceExecutable]
    publicLibraries*: seq[InterfaceLibrary]
    toolUses*: seq[InterfaceToolUse]
    publicSignatureDependencies*: seq[string]
    location*: SourceLocation
    standardBuildEligible*: bool
      ## True iff the package's DSL body declared no ``build:`` block —
      ## the engine's Tier 2b fast path dispatches such projects to the
      ## pre-built ``repro-standard-provider`` binary, which derives the
      ## graph from language conventions instead of compiling a project-
      ## specific provider. See
      ## ``reprobuild-specs/Standard-Provider-Implementation.milestones.org``
      ## §M2 and ``Provider-Compile-Tiering.md`` §"2b".

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
    reproLibFingerprint: string
    sources: seq[string]

  InterfaceExtractionCacheRecord = object
    context: InterfaceExtractionContext
    sourceStamps: seq[FileStamp]
    reproLibStamps: seq[FileStamp]
    inputFingerprint: ContentDigest

  ProviderFreshnessCacheRecord = object
    modulePath: string
    outputBinaryPath: string
    sourceStamps: seq[FileStamp]
    outputBinaryStamp: FileStamp
    interfaceFingerprint: ContentDigest
    providerFingerprint: ContentDigest
    outputBinaryFingerprint: ContentDigest

  InterfaceArtifactWarmStats* = object
    metadataColdReads*: int
    metadataWarmHits*: int
    metadataWarmMisses*: int
    metadataRevalidatedSources*: int
    metadataRevalidatedReproLibs*: int
    artifactColdReads*: int
    artifactWarmHits*: int
    artifactWarmMisses*: int

  WarmInterfaceExtractionCacheRecord = object
    evidence: FileStamp
    record: InterfaceExtractionCacheRecord

  WarmProjectInterfaceArtifact = object
    evidence: FileStamp
    artifact: ProjectInterfaceArtifact

const
  EnvelopeMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
  EnvelopeVersion = 10'u16
    ## v10 (current): adds ``InterfaceTarballProvisioning.cpu`` /
    ##                ``InterfaceTarballProvisioning.os`` per-platform
    ##                target fields. Encoded as two strings appended
    ##                AFTER ``lockIdentity`` and BEFORE ``location`` in
    ##                ``writeTarballProvisioning``. v9 payloads decode
    ##                with empty cpu/os strings ( = "any" semantics).
    ## v9: adds ``ProjectInterface.publicLibraries`` — the M12
    ##               DSL ``library`` member enumerates here. Encoded as a
    ##               ``u32`` count + per-entry ``InterfaceLibrary`` rows
    ##               appended to the interface payload BEFORE the
    ##               ``toolUses`` block. v8 readers reject v9 envelopes
    ##               (the version > EnvelopeVersion check below). v9
    ##               readers accept v8 by treating ``publicLibraries`` as
    ##               an empty seq — see ``decodeInterfacePayload``.
    ## v8: adds ``ProjectInterface.standardBuildEligible``, a single byte
    ##     at the tail of the interface payload (outside the fingerprint).
    ##     v7 readers reject v8; v8 readers accept v7 by defaulting the
    ##     flag to false.
  InterfaceExtractionCacheRecordMagic =
    "reprobuild.interfaceExtractionCache.v2"
  ProviderFreshnessCacheRecordMagic =
    "reprobuild.providerFreshnessCache.v1"

var cachedNimCompilerPath = ""
var processWarmInterfaceMetadata =
  initTable[string, WarmInterfaceExtractionCacheRecord]()
var processWarmInterfaceArtifacts =
  initTable[string, WarmProjectInterfaceArtifact]()
var processWarmInterfaceStats: InterfaceArtifactWarmStats

proc consumeInterfaceArtifactWarmStats*(): InterfaceArtifactWarmStats =
  result = processWarmInterfaceStats
  processWarmInterfaceStats = InterfaceArtifactWarmStats()

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
      dependencyPolicy: automaticMonitorGatheringPolicy(),
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

proc writeLibrary(outp: var seq[byte]; lib: InterfaceLibrary) =
  outp.writeString(lib.name)
  outp.writeByte(byte(ord(lib.kind)))
  outp.writeLocation(lib.location)

proc readLibrary(bytes: openArray[byte]; pos: var int): InterfaceLibrary =
  result.name = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(lkHeaderOnly)):
    raiseEnvelopeError(eeMalformed, "invalid interface library kind")
  result.kind = LibraryKind(kind)
  result.location = readLocation(bytes, pos)

proc writeNixProvisioning(outp: var seq[byte];
                          provisioning: InterfaceNixProvisioning) =
  outp.writeString(provisioning.packageName)
  outp.writeString(provisioning.selector)
  outp.writeString(provisioning.executablePath)
  outp.writeString(provisioning.expressionFile)
  outp.writeString(provisioning.nixpkgsRef)
  outp.writeString(provisioning.nixpkgsRev)
  outp.writeString(provisioning.nixpkgsNarHash)
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
  if version >= 7'u16:
    result.nixpkgsRef = readString(bytes, pos)
    result.nixpkgsRev = readString(bytes, pos)
    result.nixpkgsNarHash = readString(bytes, pos)
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
  outp.writeString(provisioning.cpu)
  outp.writeString(provisioning.os)
  outp.writeLocation(provisioning.location)

proc readTarballProvisioning(bytes: openArray[byte]; pos: var int;
                             version: uint16): InterfaceTarballProvisioning =
  result.packageName = readString(bytes, pos)
  result.url = readString(bytes, pos)
  result.mirrors = readStringSeq(bytes, pos)
  result.sha256 = readString(bytes, pos)
  result.archiveType = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  result.stripComponents = int(readU32Le(bytes, pos))
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  if version >= 10'u16:
    # v10: per-platform target fields. v9 payloads have no cpu/os —
    # the empty defaults are semantically "any", matching the
    # any-host behaviour the single-platform v9 schema implied.
    result.cpu = readString(bytes, pos)
    result.os = readString(bytes, pos)
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
      result.tarballProvisioning[i] = readTarballProvisioning(bytes, pos,
        version)
  if version >= 5'u16:
    let scoopCount = int(readU32Le(bytes, pos))
    result.scoopProvisioning = newSeq[InterfaceScoopProvisioning](scoopCount)
    for i in 0 ..< scoopCount:
      result.scoopProvisioning[i] = readScoopProvisioning(bytes, pos)
  result.location = readLocation(bytes, pos)

proc encodeInterfacePayload*(value: ProjectInterface): seq[byte] =
  ## Encodes the fingerprinted portion of the project-interface payload.
  ## ``standardBuildEligible`` is deliberately NOT serialised here so it
  ## does NOT contribute to ``interfaceFingerprint``: the flag is a
  ## function of the DSL source's structural shape (presence of a
  ## ``build:`` block), and the source-file digest is already part of
  ## the interface-extraction cache key. Keeping the flag out of the
  ## interface fingerprint also means existing v<8 artifacts on disk
  ## continue to round-trip cleanly under the v8 codec — their stored
  ## fingerprints match what ``interfaceFingerprint`` recomputes.
  result.writeString(value.projectName)
  result.writeString(value.packageName)
  result.writeString(value.defaultToolProvisioning)
  result.writeStringSeq(value.publicSignatureDependencies)
  result.writeLocation(value.location)
  result.writeU32Le(uint32(value.publicExecutables.len))
  for exe in value.publicExecutables:
    result.writeExecutable(exe)
  # v9: publicLibraries are encoded AFTER publicExecutables and BEFORE
  # toolUses so the field order matches the source-of-truth in the
  # ``ProjectInterface`` object literal above. v8 envelopes encode no
  # libraries block at all; ``decodeInterfacePayload`` gates this read
  # on ``version >= 9'u16`` so v8 on-disk artifacts load cleanly under
  # the v9 reader.
  result.writeU32Le(uint32(value.publicLibraries.len))
  for lib in value.publicLibraries:
    result.writeLibrary(lib)
  result.writeU32Le(uint32(value.toolUses.len))
  for useDef in value.toolUses:
    result.writeToolUse(useDef)

proc decodeInterfacePayload*(bytes: openArray[byte];
                             version = EnvelopeVersion): ProjectInterface =
  var pos = 0
  result.projectName = readString(bytes, pos)
  result.packageName = readString(bytes, pos)
  if version >= 6'u16:
    result.defaultToolProvisioning = readString(bytes, pos)
  result.publicSignatureDependencies = readStringSeq(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.publicExecutables = newSeq[InterfaceExecutable](count)
  for i in 0 ..< count:
    result.publicExecutables[i] = readExecutable(bytes, pos)
  # v9 added publicLibraries between executables and toolUses. v<9
  # envelopes have no library block — leave the seq empty.
  if version >= 9'u16:
    let libCount = int(readU32Le(bytes, pos))
    result.publicLibraries = newSeq[InterfaceLibrary](libCount)
    for i in 0 ..< libCount:
      result.publicLibraries[i] = readLibrary(bytes, pos)
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
  # v8: ``standardBuildEligible`` lives in the envelope tail, NOT in the
  # fingerprinted payload — see ``encodeInterfacePayload`` for why. v8
  # readers decoding a v7 envelope skip this byte and leave the field
  # as ``false`` (the conservative slow-path default), keeping existing
  # on-disk artifacts loadable without re-extraction.
  payload.writeByte(
    if artifact.projectInterface.standardBuildEligible: 1'u8 else: 0'u8)
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
  # v8 envelopes carry an extra trailing byte for standardBuildEligible
  # past the 34-byte interface fingerprint; older envelopes do not.
  let standardBuildEligibleBytes = if version >= 8'u16: 1 else: 0
  let interfacePayloadLen = payloadLength - 34 - standardBuildEligibleBytes
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
  if version >= 8'u16:
    result.projectInterface.standardBuildEligible =
      readByte(bytes, pos) != 0'u8

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
  outp.writeString(context.reproLibFingerprint)
  outp.writeStringSeq(context.sources)

proc readInterfaceContext(bytes: openArray[byte]; pos: var int):
    InterfaceExtractionContext =
  result.modulePath = readString(bytes, pos)
  result.workDir = readString(bytes, pos)
  result.nimCompiler = readString(bytes, pos)
  result.libPathFlags = readStringSeq(bytes, pos)
  result.reproLibFingerprint = readString(bytes, pos)
  result.sources = readStringSeq(bytes, pos)

proc encodeInterfaceExtractionCacheRecord(
    record: InterfaceExtractionCacheRecord): seq[byte] =
  result.writeString(InterfaceExtractionCacheRecordMagic)
  result.writeInterfaceContext(record.context)
  result.writeFileStamps(record.sourceStamps)
  result.writeFileStamps(record.reproLibStamps)
  result.writeDigest(record.inputFingerprint)

proc decodeInterfaceExtractionCacheRecord(bytes: openArray[byte]):
    InterfaceExtractionCacheRecord =
  var pos = 0
  let magic = readString(bytes, pos)
  if magic != InterfaceExtractionCacheRecordMagic:
    raiseEnvelopeError(eeUnknownType, "not an interface extraction cache record")
  result.context = readInterfaceContext(bytes, pos)
  result.sourceStamps = readFileStamps(bytes, pos)
  result.reproLibStamps = readFileStamps(bytes, pos)
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
    nixpkgsRef: provisioning.nixpkgsRef,
    nixpkgsRev: provisioning.nixpkgsRev,
    nixpkgsNarHash: provisioning.nixpkgsNarHash,
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
    cpu: provisioning.cpu,
    os: provisioning.os,
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
      # When the package declares an ``executable`` whose exportName
      # matches the use selector and renames the binary via ``name:``
      # (e.g. ``package foundry: executable foundry: name: "forge"``),
      # propagate that binary basename as the use's executableName so
      # path-mode tool resolution probes for ``forge[.exe]`` instead of
      # the non-existent ``foundry[.exe]`` derived from the selector.
      # The default executableName (= selector) is preserved when no
      # such executable is declared, keeping existing single-binary
      # packages (cargo, gcc, nim, ...) unchanged.
      for exe in pkg.executables:
        if exe.exportName == useDef.executableName and
            exe.binaryName.len > 0 and
            exe.binaryName != useDef.executableName:
          result.executableName = exe.binaryName
          break

proc toProjectInterface*(pkg: PackageDef;
                         packages: openArray[PackageDef] = []):
    ProjectInterface =
  result.projectName = pkg.packageName
  result.packageName = pkg.packageName
  result.defaultToolProvisioning = pkg.defaultToolProvisioning
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
  for lib in pkg.libraries:
    result.publicLibraries.add(InterfaceLibrary(
      name: lib.name,
      kind: lib.kind,
      location: SourceLocation(file: lib.sourceFile, line: lib.sourceLine)))

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

const
  RegisteredStandardConventionToolchains* = ["nim", "rust", "rustc", "cargo",
    "go",
    "python3", "python", "uv",
    "node", "typescript", "tsx", "swc", "esbuild",
    "gcc", "clang", "make", "ar", "autoconf", "automake",
    "cmake", "ninja", "meson",
    "java", "jdk", "javac", "mvn", "maven",
    "gradle", "kotlin",
    "dotnet", "dotnet-sdk", "csharp",
    "swift", "swiftc", "swiftpm",
    "gfortran", "fortran",
    "zig",
    "d", "dmd", "ldc2", "gdc",
    "ada", "gnat", "gnatmake",
    "pascal", "fpc", "freepascal",
    "crystal", "shards",
    "erlang", "erl", "rebar3",
    "elixir", "mix",
    "ocaml", "ocamlc", "ocamlopt", "ocamlfind", "dune",
    "haskell", "ghc", "cabal", "cabal-install",
    "ruby", "bundler",
    "php", "composer"]
    ## Toolchain names whose presence in ``uses:`` makes a package
    ## ``executable``/``library`` declaration safe to route through the
    ## Tier 2b standard provider. This list MUST stay in sync with the
    ## conventions registered in
    ## ``apps/repro-standard-provider/repro_standard_provider.nim``.
    ## ``"rust"`` and ``"cargo"`` both route to the same Rust convention
    ## plugin (M4) — the Rust convention's ``recognize`` matches either
    ## token in ``uses:``. ``"go"`` (M5) routes to the Go convention plugin
    ## which keys on the ``go.mod`` + ``main.go`` layout. ``"python3"`` /
    ## ``"python"`` / ``"uv"`` (M15) route to the Python convention plugin
    ## which keys on ``pyproject.toml`` + a recognised PEP 517 build
    ## backend (hatchling / flit_core / setuptools). ``"gcc"`` / ``"clang"``
    ## / ``"make"`` / ``"ar"`` (M17) route to the C/C++ Make convention;
    ## ``"autoconf"`` / ``"automake"`` (M17) route to the C/C++ Autotools
    ## convention which keys on ``configure.ac`` + ``Makefile.am`` at the
    ## project root. ``"cmake"`` (M38) routes to the C/C++ CMake (Tier 2b)
    ## convention which keys on ``CMakeLists.txt`` at the project root.
    ## ``"meson"`` (M39) routes to the C/C++ Meson (Tier 2b) convention
    ## which keys on ``meson.build`` at the project root.
    ## ``"java"`` / ``"jdk"`` / ``"javac"`` / ``"mvn"`` / ``"maven"`` (M40)
    ## route to the Java + Maven (Tier 2b) convention which keys on
    ## ``pom.xml`` at the project root; recognition additionally requires
    ## both halves (a JDK token AND a Maven token) in ``uses:``.
    ## ``"gradle"`` / ``"kotlin"`` (M41) route to the Kotlin + Gradle
    ## (Tier 2b) convention which keys on ``build.gradle.kts`` (or
    ## ``build.gradle``) at the project root; recognition additionally
    ## requires both halves (a JDK token AND a Gradle/Kotlin token) in
    ## ``uses:`` AND the absence of ``pom.xml`` at the root (defers to
    ## the M40 Maven convention when both manifests coexist).
    ## ``"dotnet"`` / ``"dotnet-sdk"`` / ``"csharp"`` (M42) route to the
    ## C# + .NET (Tier 2b) convention which keys on a single ``*.csproj``
    ## at the project root + a ``packages.lock.json`` (HARD precondition).
    ## ``"swift"`` / ``"swiftc"`` / ``"swiftpm"`` (M43) route to the
    ## Swift + SwiftPM (Tier 2b) convention which keys on ``Package.swift``
    ## at the project root.
    ## ``"ocaml"`` / ``"ocamlc"`` / ``"ocamlopt"`` / ``"ocamlfind"`` /
    ## ``"dune"`` (M46) route to the OCaml + Dune (Tier 2b) convention
    ## which keys on ``dune-project`` at the project root; recognition
    ## additionally requires BOTH halves (an OCaml token AND ``dune``)
    ## in ``uses:`` — mirrors M40 java-maven's strict "both required"
    ## pattern because Dune isn't a built-in part of the OCaml
    ## distribution (it's a separate ``opam install dune``).
    ## Mismatches break in the engine-side fall-back path:
    ## the engine will dispatch to the provider, the provider will reply
    ## "no convention matched", and the build fails loudly — preferable to
    ## silently routing through the slow path when the user expects the
    ## fast path.

proc usesIncludesRegisteredConvention(sourceFile: string): bool =
  ## Heuristic line scan of ``reprobuild.nim`` for any toolchain in
  ## ``RegisteredStandardConventionToolchains`` appearing inside a
  ## ``uses:`` block. Mirrors the line-scan in
  ## ``libs/repro_standard_provider/src/repro_standard_provider/project_intro.nim``
  ## (no DSL evaluator), kept here rather than imported because
  ## ``repro_interface_artifacts`` is upstream of ``repro_standard_provider``
  ## in the library dep graph. Conservative: returns ``false`` on any
  ## read error or malformed block.
  if sourceFile.len == 0:
    return false
  var content: string
  try:
    content = readFile(extendedPath(sourceFile))
  except CatchableError:
    return false
  var inBlock = false
  for rawLine in content.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    var payload = ""
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        payload = stripped
    if payload.len == 0 and stripped.startsWith("uses:"):
      let p = stripped[5 .. ^1].strip()
      if p.len == 0:
        inBlock = true
      else:
        payload = p
    if payload.len == 0:
      continue
    var clean = payload
    if clean.startsWith("["):
      clean = clean[1 .. ^1]
    if clean.endsWith("]"):
      clean = clean[0 ..< ^1]
    for raw in clean.split({',', ' ', '\t'}):
      let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
      if entry.len == 0:
        continue
      let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
      for toolchain in RegisteredStandardConventionToolchains:
        if firstToken == toolchain:
          return true
  false

proc detectStandardBuildEligible(sourceFile: string;
                                  pkg: PackageDef): bool =
  ## A package is eligible for the Tier 2b ``repro-standard-provider``
  ## fast path when the DSL body declares NO ``build:`` block AND one
  ## of two things is true:
  ##   1. zero ``executable`` / ``library`` members (pure metadata or
  ##      "no-build" package — let the standard provider decide what to
  ##      do; missing match still fails loudly), OR
  ##   2. ``uses:`` includes a toolchain name listed in
  ##      ``RegisteredStandardConventionToolchains`` (i.e. the standard
  ##      provider ships a convention plugin for it).
  ##
  ## Conservatively excluding executable-bearing packages whose ``uses:``
  ## doesn't reference any registered convention keeps tool-wrapper
  ## packages (``executable foo`` with no ``build:``, expecting the slow
  ## path's typed-tool resolution to materialise a launcher) on the
  ## traditional path — bypassing them through the standard provider
  ## would mean every such package hits a "no convention matched" error.
  ##
  ## The ``build:`` check is a heuristic line-scan of the source file,
  ## mirroring ``moduleHasBuildBlock`` in ``repro_cli_support``: a
  ## stripped-equal-to-``build:`` line under either the top-level
  ## package body or a nested ``executable`` block disqualifies. Empty
  ## or unreadable source file → not eligible (conservative default).
  if sourceFile.len == 0:
    return false
  var content: string
  try:
    content = readFile(extendedPath(sourceFile))
  except CatchableError:
    return false
  for line in content.splitLines:
    if line.strip() == "build:":
      return false
  if pkg.executables.len == 0 and pkg.libraries.len == 0:
    return true
  # Library-only packages (no executable members) need the same
  # registered-convention gate as executable-bearing packages: routing a
  # ``library foo`` declaration through the standard provider only makes
  # sense when the convention plugin in question knows how to emit a
  # library link action. The Nim convention's M12 ``emitFragment`` covers
  # ``lkStatic``/``lkShared``/``lkBoth``/``lkHeaderOnly`` — see
  # ``conventions/nim.nim``.
  usesIncludesRegisteredConvention(sourceFile)

proc mergeProjectInterfaces(matches: openArray[PackageDef];
                            packages: openArray[PackageDef]): ProjectInterface =
  ## Combine the ``ProjectInterface`` projections of every package
  ## declared in the same Nim project file into a single envelope.
  ##
  ## Background: the on-disk interface artifact carries ONE
  ## ``ProjectInterface`` per project file (one ``ProjectInterfaceArtifact``
  ## per ``repro.nim``). When multiple ``package`` blocks share a file —
  ## the "one workspace, many packages, single file" Mode 3 shape —
  ## downstream consumers (the engine, ``repro-standard-provider``, the
  ## CMake generator) still expect a single envelope. We project the
  ## multi-package shape into the single-envelope shape by:
  ##
  ##   * keeping the FIRST package's ``projectName`` /
  ##     ``packageName`` / ``defaultToolProvisioning`` /
  ##     ``location`` as the "root" — preserving the
  ##     single-package shape byte-for-byte when ``matches.len == 1``;
  ##   * concatenating ``publicExecutables`` and ``publicLibraries``
  ##     across every package in source order (the DSL itself
  ##     guarantees member-name uniqueness within a package, and
  ##     multi-package files almost always partition members one per
  ##     package, so duplicates are not expected here);
  ##   * deduplicating ``toolUses`` by
  ##     ``(packageSelector, executableName)`` so a constraint listed in
  ##     two ``uses:`` blocks (typical for shared toolchains like
  ##     ``"nim >=2.2 <3.0"``) doesn't surface twice;
  ##   * unioning ``publicSignatureDependencies``.
  ##
  ## The per-target ``packageName`` distinction is preserved at the
  ## DSL level (each ``InterfaceExecutable.binaryName`` /
  ## ``InterfaceLibrary.name`` plus its source location still maps
  ## back to its owning package); the merged envelope just doesn't
  ## carry the per-target package label in the v9 wire format. The
  ## scanner, ``repro show-conventions``, ``repro deps refresh``, and
  ## the multi-package unit tests all consult ``registeredPackages()``
  ## directly so they retain full per-package attribution.
  result.projectName = matches[0].packageName
  result.packageName = matches[0].packageName
  result.defaultToolProvisioning = matches[0].defaultToolProvisioning
  result.location = SourceLocation(
    file: matches[0].sourceFile,
    line: matches[0].sourceLine)
  var seenToolUses: seq[string] = @[]
  var seenSigDeps: seq[string] = @[]
  for pkg in matches:
    let projection = toProjectInterface(pkg, packages)
    for exe in projection.publicExecutables:
      result.publicExecutables.add(exe)
    for lib in projection.publicLibraries:
      result.publicLibraries.add(lib)
    for use in projection.toolUses:
      let key = use.packageSelector & "\x1f" & use.executableName
      if seenToolUses.find(key) >= 0:
        continue
      seenToolUses.add(key)
      result.toolUses.add(use)
    for dep in projection.publicSignatureDependencies:
      if seenSigDeps.find(dep) >= 0:
        continue
      seenSigDeps.add(dep)
      result.publicSignatureDependencies.add(dep)
    # ``defaultToolProvisioning`` resolution: the first non-empty wins.
    # An explicit value on a later package overrides a default-empty
    # earlier one, matching the "first explicit declaration in source
    # order" rule the spec hints at.
    if result.defaultToolProvisioning.len == 0 and
        pkg.defaultToolProvisioning.len > 0:
      result.defaultToolProvisioning = pkg.defaultToolProvisioning

proc artifactFromRegisteredDsl*(rootSourceFile = ""): ProjectInterfaceArtifact =
  let packages = registeredPackages()
  if rootSourceFile.len > 0:
    var matches: seq[PackageDef] = @[]
    for pkg in packages:
      if sameSourceFile(pkg.sourceFile, rootSourceFile):
        matches.add(pkg)
    if matches.len == 1:
      var pi = toProjectInterface(matches[0], packages)
      pi.standardBuildEligible =
        detectStandardBuildEligible(rootSourceFile, matches[0])
      return artifactFor(pi)
    if matches.len > 1:
      # Multi-package single-file (Mode 3 + the upcoming C/C++ work):
      # collapse every package declared in the same Nim file into one
      # interface envelope. The marker collision that previously blocked
      # this at compile-time is fixed in
      # ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim``;
      # the merge logic here is the artifact-layer side of the same
      # change.
      var pi = mergeProjectInterfaces(matches, packages)
      var allEligible = true
      for pkg in matches:
        if not detectStandardBuildEligible(rootSourceFile, pkg):
          allEligible = false
          break
      pi.standardBuildEligible = allEligible
      return artifactFor(pi)
  if packages.len != 1:
    # Same multi-package fallback as the rootSourceFile branch above,
    # for callers that don't pass a root hint. The merge preserves the
    # ``packages.len == 1`` shape exactly (single-element ``matches`` →
    # ``mergeProjectInterfaces`` reproduces the legacy
    # ``toProjectInterface`` output), so this branch only kicks in when
    # two or more packages were registered without an explicit root.
    var pi = mergeProjectInterfaces(packages, packages)
    var allEligible = true
    for pkg in packages:
      if not detectStandardBuildEligible(pkg.sourceFile, pkg):
        allEligible = false
        break
    pi.standardBuildEligible = allEligible
    return artifactFor(pi)
  var pi = toProjectInterface(packages[0], packages)
  pi.standardBuildEligible =
    detectStandardBuildEligible(packages[0].sourceFile, packages[0])
  artifactFor(pi)

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
    if candidate.startsWith("/nix/store/"):
      cachedNimCompilerPath = candidate
      return candidate
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
  # MR9 — `$REPRO_BOOTSTRAP_CC` is the bootstrap-resolved gcc absolute
  # path published by `ensureBootstrapToolchainEnv` (tool_profiles.nim)
  # before the interface-extract step runs. It outranks `$CC` because
  # env.ps1 / inherited shells legitimately set `$CC` to a bare
  # basename like ``gcc`` for use by Makefiles / autotools, and the
  # `isAbsolute(ccEnv)` check below would discard that value and fall
  # through to `BuiltCCompilerPath` (which, on a clean Windows host,
  # rarely matches a usable 64-bit toolchain). Consulting the
  # bootstrap pin first guarantees nim's `--gcc.exe:` flag points at
  # the reprobuild-provisioned winlibs gcc instead of whatever
  # PATH-resolution would pick (e.g. FPC's 32-bit-target gcc 2.95).
  let bootstrapCC = getEnv("REPRO_BOOTSTRAP_CC")
  if bootstrapCC.len > 0 and isAbsolute(bootstrapCC) and
      fileExists(extendedPath(bootstrapCC)):
    return bootstrapCC
  let ccEnv = getEnv("CC")
  if ccEnv.len > 0 and isAbsolute(ccEnv):
    return ccEnv
  if BuiltCCompilerPath.len > 0 and fileExists(extendedPath(BuiltCCompilerPath)):
    return BuiltCCompilerPath
  ""

var cachedHostCCompilerFamily = ""

proc hostCCompilerFamily(cc: string): string =
  ## Detect whether the provisioned C compiler is clang- or gcc-flavoured
  ## so Nim's selected compiler *family* matches the actual binary.
  ##
  ## ``hostCCompilerFlags`` aliases BOTH ``--gcc.exe`` and ``--clang.exe``
  ## to this single compiler but, historically, left the compiler family
  ## at Nim's platform default (clang on macOS, gcc on Linux). When the
  ## provisioned ``cc`` is gcc (e.g. the Nix gcc-wrapper used by path-mode
  ## provisioning) but Nim still thinks it is clang, Nim emits clang-only
  ## flags such as ``-ferror-limit=3`` (from ``clang.options.always``)
  ## and the gcc binary rejects them, breaking interface extraction.
  ## Pinning ``--cc`` to the detected family keeps the always-on flag set
  ## consistent with the binary on every platform.
  if cachedHostCCompilerFamily.len > 0:
    return cachedHostCCompilerFamily
  cachedHostCCompilerFamily = "gcc"
  try:
    let (output, exitCode) = execCmdEx(quoteShell(cc) & " --version")
    if exitCode == 0 and "clang" in output.toLowerAscii:
      cachedHostCCompilerFamily = "clang"
  except CatchableError, OSError:
    discard
  cachedHostCCompilerFamily

proc hostCCompilerFlags(): seq[string] =
  # Windows: bump the linked stack size for any binary the engine
  # compiles on its own behalf (interface-extract runner, per-project
  # provider). Default Windows stack is 1 MB; the recipe-evaluation
  # path executes deeply-recursive macro-expansion code under a
  # singleton thread (no async, no fan-out), and the resulting binary
  # routinely overflows that limit with STATUS_STACK_OVERFLOW
  # (-1073741571 / 0xC00000FD) on recipes that import the whole
  # ``repro_dsl_stdlib`` umbrella. POSIX gets a much larger default
  # stack from the kernel (8 MB on Linux, 8 MB on macOS) so this is a
  # Windows-only adjustment. Emitted regardless of whether
  # ``hostCCompilerPath`` resolved — the flag is honoured by every
  # supported toolchain (winlibs gcc, MSYS2 mingw64, MSVC link.exe via
  # ``--passL:/STACK:`` equivalent).
  when defined(windows):
    result.add("--passL:-Wl,--stack,16777216")

  let cc = hostCCompilerPath()
  if cc.len == 0:
    return
  # Match Nim's compiler family to the provisioned binary so the family's
  # always-on flags (e.g. clang's -ferror-limit) are not handed to the
  # wrong compiler. See hostCCompilerFamily for the failure this avoids.
  result.add("--cc:" & hostCCompilerFamily(cc))
  result.add("--gcc.exe:" & cc)
  result.add("--gcc.linkerexe:" & cc)
  result.add("--clang.exe:" & cc)
  result.add("--clang.linkerexe:" & cc)

proc walkLibSrcPathsInto(libsRoot: string; sink: var seq[string]) =
  ## Walks ``<libsRoot>/<name>/src`` and appends every existing entry to
  ## ``sink``. Follows symlinked dirs so cross-repo libraries vendored
  ## via symlink (codetracer's ``ct_test_nim_unittest`` adapter etc.)
  ## participate. Idempotent — the caller deduplicates the final list.
  if not dirExists(extendedPath(libsRoot)):
    return
  # TODO(win-longpath): walk results escape; needs review
  for path in walkDir(libsRoot):
    if path.kind in {pcDir, pcLinkToDir}:
      let src = path.path / "src"
      if dirExists(extendedPath(src)):
        sink.add(src)

proc reprobuildLibsRootFromEnv(): string =
  ## ``$REPROBUILD_LIBS_DIR`` is the explicit operator override for
  ## "where reprobuild's libs/ live". Set by the engine when invoking
  ## an out-of-tree provider compile; mirrors ``$REPROBUILD_REPO_ROOT``
  ## except it points at the libs dir directly. Empty when not set.
  let direct = getEnv("REPROBUILD_LIBS_DIR")
  if direct.len > 0:
    return direct
  let repoRoot = getEnv("REPROBUILD_REPO_ROOT")
  if repoRoot.len > 0:
    return repoRoot / "libs"
  ""

proc reprobuildLibsRootFromBinaryLocation(): string =
  ## When the running ``repro`` binary lives inside a reprobuild source
  ## checkout (``<reprobuild-root>/build/bin/repro``) we can derive the
  ## reprobuild libs root from the binary's path. This is the sibling-
  ## repo detection equivalent of how dev-shell scripts probe for
  ## ``../reprobuild/libs/`` next to the consumer repo, but anchored
  ## from the binary instead of the consumer's workdir so it stays
  ## correct regardless of where ``repro`` was invoked from.
  let exePath = getAppFilename()
  if exePath.len == 0:
    return ""
  # exePath: <reprobuild-root>/build/bin/repro.exe
  let candidateRoot = exePath.parentDir.parentDir.parentDir
  let candidate = candidateRoot / "libs"
  let marker = candidate / "repro_project_dsl" / "src" / "repro_project_dsl.nim"
  if fileExists(extendedPath(marker)):
    return candidate
  ""

proc siblingReprobuildLibsRoot(workDir: string): string =
  ## When a recorder repo is checked out as a sibling of reprobuild
  ## (``D:/m/dev/codetracer-foo-recorder/`` next to
  ## ``D:/m/dev/reprobuild/``) the develop-mode convention is for the
  ## consumer to find reprobuild's libs at ``../reprobuild/libs/``.
  ## This is the equivalent of the recorder dev-shell scripts' sibling
  ## detection (``scripts/detect-siblings.sh`` etc.) lifted into the
  ## reprobuild engine itself so consumers don't have to redo it.
  let candidate = workDir.parentDir / "reprobuild" / "libs"
  let marker = candidate / "repro_project_dsl" / "src" / "repro_project_dsl.nim"
  if fileExists(extendedPath(marker)):
    return candidate
  ""

proc resolveBootstrapPackagePath*(envName: string;
                                  candidates: openArray[string];
                                  marker: string): string =
  ## MR14 — mirror ``config.nims``'s ``addPackagePath`` resolution shape
  ## so the recipe-compile (extract_runner) ``nim c`` invocation sees the
  ## same sibling source-only dependencies that reprobuild itself sees
  ## when it is compiled. ``config.nims`` is loaded by ``nim`` when the
  ## current directory is the reprobuild repo root; the recipe-compile
  ## step runs from the *consumer* repo's workdir so it never loads
  ## reprobuild's ``config.nims``. Without this helper, an ``import``
  ## that the dev-shell could resolve (e.g. ``import nimcrypto/sha2``
  ## inside ``repro_project_dsl``) fails at extract_runner compile time
  ## with ``Error: cannot open file: nimcrypto/sha2``.
  ##
  ## Resolution order (mirrors ``config.nims:112-121``):
  ## 1. ``$<envName>`` environment variable (if set and contains marker)
  ## 2. each candidate path in declaration order (if it contains marker)
  ## 3. "" (caller skips the ``--path:`` flag entirely)
  let envPath = getEnv(envName)
  if envPath.len > 0 and fileExists(extendedPath(envPath / marker)):
    return envPath
  for candidate in candidates:
    if fileExists(extendedPath(candidate / marker)):
      return candidate
  ""

proc bootstrapSiblingPackagePathFlags(reprobuildRoot: string): seq[string] =
  ## MR14 — produce the ``--path:`` flags for the source-only sibling
  ## dependencies that ``reprobuild/config.nims`` lines 126-192 register
  ## via ``addPackagePath``. The list MUST stay in sync with config.nims
  ## so the recipe-compile reaches the same path set as reprobuild itself.
  ##
  ## The candidate lists below are written relative to
  ## ``reprobuildRoot`` (the absolute path to reprobuild's repo root)
  ## rather than to ``getCurrentDir()`` because the recipe-compile runs
  ## from the consumer's workdir, where ``".." / "nimcrypto"`` would
  ## point at a sibling of the *consumer* repo and not at a sibling of
  ## reprobuild. We resolve every candidate against ``reprobuildRoot``
  ## so the same workspace layout that satisfies ``nim c`` for
  ## reprobuild itself also satisfies the recipe-compile.
  if reprobuildRoot.len == 0:
    return
  let reprobuildParent = reprobuildRoot.parentDir
  proc anchored(candidates: openArray[string]): seq[string] =
    for c in candidates:
      if isAbsolute(c):
        result.add(c)
      elif c.startsWith(".." & DirSep) or c.startsWith("../") or c == ".." or
           c.startsWith(".." & "\\"):
        # Strip a single leading "../" and anchor at reprobuild's parent.
        var rest = c
        if rest == "..":
          rest = ""
        elif rest.startsWith("../"):
          rest = rest[3 .. ^1]
        elif rest.startsWith(".." & DirSep):
          rest = rest[3 .. ^1]
        elif rest.startsWith("..\\"):
          rest = rest[3 .. ^1]
        result.add(if rest.len > 0: reprobuildParent / rest else: reprobuildParent)
      else:
        result.add(reprobuildRoot / c)

  type SiblingSpec = tuple
    envName: string
    candidates: seq[string]
    marker: string
  let specs: seq[SiblingSpec] = @[
    ("FASTSTREAMS_SRC", anchored([
      "libs" / "nim-faststreams" / "src",
      ".." / "codetracer" / "libs" / "nim-faststreams",
      ".." / "nim-faststreams",
    ]), "faststreams" / "inputs.nim"),
    ("NIM_STEW_SRC", anchored([
      "libs" / "nim-stew" / "src",
      ".." / "codetracer" / "libs" / "nim-stew",
      ".." / "nim-stew",
    ]), "stew" / "objects.nim"),
    ("NIM_SERIALIZATION_SRC", anchored([
      "libs" / "nim-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-serialization",
      ".." / "nim-serialization",
    ]), "serialization" / "case_objects.nim"),
    ("NIM_JSON_SERIALIZATION_SRC", anchored([
      "libs" / "nim-json-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-json-serialization",
      ".." / "nim-json-serialization",
    ]), "json_serialization.nim"),
    ("NIM_TOML_SERIALIZATION_SRC", anchored([
      "libs" / "nim-toml-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-toml-serialization",
      ".." / "nim-toml-serialization",
    ]), "toml_serialization.nim"),
    ("SSZ_SERIALIZATION_SRC", anchored([
      "libs" / "nim-ssz-serialization" / "src",
      ".." / "nim-ssz-serialization",
    ]), "ssz_serialization.nim"),
    ("NIMCRYPTO_SRC", anchored([
      ".." / "codetracer" / "libs" / "nimcrypto",
      ".." / "nimcrypto",
    ]), "nimcrypto" / "hash.nim"),
    ("BEARSSL_SRC", anchored([
      ".." / "nim-bearssl",
      "libs" / "nim-bearssl",
    ]), "bearssl.nim"),
    ("RESULTS_SRC", anchored([
      "libs" / "results" / "src",
    ]), "results.nim"),
    ("STINT_SRC", anchored([
      "libs" / "stint" / "src",
    ]), "stint.nim"),
    ("STACKABLE_HOOKS_SRC", anchored([
      ".." / "nim-stackable-hooks" / "src",
      "libs" / "repro_monitor_shim" / "vendor" / "nim-stackable-hooks" / "src",
    ]), "stackable_hooks.nim"),
    ("VM_HARNESS_SRC", anchored([
      ".." / "vm-harness" / "src",
    ]), "vm_harness.nim"),
    ("CT_TEST_SRC", anchored([
      ".." / "ct-test" / "libs" / "ct_test_interface" / "src",
    ]), "ct_test_interface.nim"),
  ]
  for spec in specs:
    let resolved = resolveBootstrapPackagePath(spec.envName, spec.candidates,
                                               spec.marker)
    if resolved.len > 0:
      result.add("--path:" & resolved)

proc reproLibPathFlags(workDir: string): seq[string] =
  ## Build the ``--path:`` flags the engine passes to ``nim c`` when
  ## compiling a project's provider library. Includes:
  ##
  ## 1. ``<workDir>/libs/*/src`` — the consumer repo's own libs.
  ## 2. The reprobuild repo's ``libs/*/src``, located via:
  ##    a. ``$REPROBUILD_LIBS_DIR`` / ``$REPROBUILD_REPO_ROOT`` overrides,
  ##    b. the running ``repro`` binary's location (when it lives inside
  ##       a reprobuild source checkout — the develop-mode default), or
  ##    c. a sibling ``../reprobuild/`` checkout next to the consumer.
  ## 3. (MR14) The source-only sibling dependencies that
  ##    ``reprobuild/config.nims`` registers via ``addPackagePath`` —
  ##    nimcrypto, nim-stew, nim-faststreams, nim-bearssl, etc. The
  ##    recipe-compile (extract_runner) never loads ``config.nims`` so
  ##    those flags have to be reconstructed here, anchored at the
  ##    reprobuild repo root located in step (2).
  ##
  ## Step (2) is the develop-mode sibling-repo detection per
  ## codetracer-specs/Repo-Requirements.md §2.8: the engine ensures
  ## that every recipe that imports ``repro_project_dsl`` / the
  ## reprobuild stdlib packages compiles without the consumer recipe
  ## having to embed the reprobuild repo path. It is also what makes
  ## a one-shot ``repro build`` work in a recorder repo on Windows
  ## without an env.ps1 pre-setup of NIM ``--path``.
  var paths: seq[string] = @[]
  walkLibSrcPathsInto(workDir / "libs", paths)

  # When the consumer's own ``libs/`` IS a reprobuild source tree — the
  # in-tree case where the provider compiles reprobuild's own ``repo.nim``
  # — those working-tree libs are the authoritative copy. Adding a SECOND
  # reprobuild lib root located via ``$REPROBUILD_REPO_ROOT`` /
  # ``$REPROBUILD_LIBS_DIR`` (or the binary location / a sibling checkout)
  # would put a duplicate of every ``repro_*`` module on ``--path``. Nim's
  # module resolution does NOT reliably prefer the first ``--path`` entry
  # when the same logical module exists under two roots, so the external
  # root can SHADOW the working tree — and in a dev shell that external
  # root is a flake-pinned snapshot that can lag the working tree (e.g.
  # pinned to a different branch), silently compiling the recipe against
  # stale stdlib sources. So only consult the external reprobuild root
  # when the consumer does not already provide the reprobuild libs itself.
  let workDirIsReprobuildTree = fileExists(extendedPath(
    workDir / "libs" / "repro_project_dsl" / "src" / "repro_project_dsl.nim"))

  var reprobuildLibsRoot = ""
  if workDirIsReprobuildTree:
    # In-tree: anchor the MR14 sibling source-only flags at the working
    # tree; the working-tree libs are already on ``paths`` above.
    reprobuildLibsRoot = workDir / "libs"
  else:
    reprobuildLibsRoot = reprobuildLibsRootFromEnv()
    if reprobuildLibsRoot.len == 0:
      reprobuildLibsRoot = reprobuildLibsRootFromBinaryLocation()
    if reprobuildLibsRoot.len == 0:
      reprobuildLibsRoot = siblingReprobuildLibsRoot(workDir)
    if reprobuildLibsRoot.len > 0:
      walkLibSrcPathsInto(reprobuildLibsRoot, paths)

  # Deduplicate (a consumer repo that happens to symlink reprobuild
  # libs into its own libs/ would otherwise list each path twice).
  var seen = initHashSet[string]()
  for p in paths:
    if not seen.containsOrIncl(p):
      result.add("--path:" & p)
  result.sort(system.cmp[string])

  # MR14 — append the sibling source-only ``--path:`` flags after the
  # reprobuild-libs flags so the standard libs win on ambiguity but
  # imports like ``nimcrypto/sha2`` (added during the Phase-2 migration
  # to ``repro_project_dsl``) still resolve. ``reprobuildLibsRoot`` is
  # ``<reprobuild-root>/libs`` so ``parentDir`` gives the reprobuild
  # repo root the candidate lists are anchored at.
  if reprobuildLibsRoot.len > 0:
    let siblingFlags = bootstrapSiblingPackagePathFlags(
      reprobuildLibsRoot.parentDir)
    for flag in siblingFlags:
      result.add(flag)

proc normalizedStampPath(path: string): string =
  os.normalizedPath(path).replace('\\', '/')

proc stripNimLineComment(line: string): string =
  let pos = line.find('#')
  if pos >= 0:
    line[0 ..< pos]
  else:
    line

proc splitImportSpecs(text: string): seq[string] =
  var current = ""
  var bracketDepth = 0
  for ch in text:
    case ch
    of '[':
      bracketDepth.inc
      current.add(ch)
    of ']':
      bracketDepth.dec
      current.add(ch)
    of ',':
      if bracketDepth == 0:
        let item = current.strip()
        if item.len > 0:
          result.add(item)
        current.setLen(0)
      else:
        current.add(ch)
    else:
      current.add(ch)
  let item = current.strip()
  if item.len > 0:
    result.add(item)

proc expandImportSpec(spec: string): seq[string] =
  var value = spec.strip()
  if value.len == 0:
    return
  let aliasPos = value.find(" as ")
  if aliasPos >= 0:
    value = value[0 ..< aliasPos].strip()
  if value.startsWith("\"") and value.endsWith("\"") and value.len >= 2:
    value = value[1 .. ^2]
  let openPos = value.find('[')
  let closePos = value.rfind(']')
  if openPos >= 0 and closePos > openPos:
    let prefix = value[0 ..< openPos].strip().strip(chars = {'/'})
    for item in splitImportSpecs(value[openPos + 1 ..< closePos]):
      let suffix = item.strip()
      if suffix.len > 0:
        if prefix.len > 0:
          result.add(prefix & "/" & suffix)
        else:
          result.add(suffix)
  else:
    result.add(value)

proc localNimModulePath(currentFile, projectRoot, spec: string): string =
  if spec.len == 0 or spec.startsWith("std/") or spec == "std" or
      spec.startsWith("pkg/") or spec == "pkg":
    return ""
  var module = spec
  if module.startsWith("./") or module.startsWith("../"):
    module = parentDir(currentFile) / module
  elif module.isAbsolute:
    discard
  else:
    module = projectRoot / module
  if not module.endsWith(".nim") and not module.endsWith(".nims"):
    module.add(".nim")
  module = normalizedStampPath(module)
  let normalizedRoot = normalizedStampPath(projectRoot)
  if module == normalizedRoot or module.startsWith(normalizedRoot & "/"):
    if fileExists(extendedPath(module)):
      return module
  ""

proc nimImportSpecs(line: string): seq[string] =
  let stripped = stripNimLineComment(line).strip()
  if stripped.startsWith("import "):
    return splitImportSpecs(stripped["import ".len .. ^1])
  if stripped.startsWith("include "):
    return splitImportSpecs(stripped["include ".len .. ^1])
  if stripped.startsWith("from "):
    let rest = stripped["from ".len .. ^1]
    let pos = rest.find(" import ")
    if pos > 0:
      return @[rest[0 ..< pos].strip()]

proc discoverNimSources*(rootModulePath: string): seq[string] =
  ## Enumerate the provider compile's input source set.
  ##
  ## Imports reachable from ``rootModulePath`` are included transitively
  ## (only within the project root, never outside; std/ and pkg/ specs are
  ## ignored). In addition every ``.nim`` file directly in the project
  ## root is included even when it is not currently imported, so that
  ## adding a sibling module to the project invalidates the provider
  ## compile cache: a later edit to ``reprobuild.nim`` might import it,
  ## and Nim's own compilation already treats project-root siblings as
  ## eligible imports. Sibling enumeration is intentionally
  ## non-recursive — subdirectory sources only enter the set through an
  ## explicit import edge.
  let projectRoot = normalizedStampPath(parentDir(rootModulePath))
  var pending = @[normalizedStampPath(rootModulePath)]
  var seen = initHashSet[string]()
  while pending.len > 0:
    let path = pending.pop()
    if path in seen:
      continue
    seen.incl(path)
    result.add(path)
    if not fileExists(extendedPath(path)):
      continue
    for line in readFile(extendedPath(path)).splitLines:
      for spec in nimImportSpecs(line):
        for expanded in expandImportSpec(spec):
          let localPath = localNimModulePath(path, projectRoot, expanded)
          if localPath.len > 0 and localPath notin seen:
            pending.add(localPath)
  if dirExists(extendedPath(projectRoot)):
    for kind, child in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if not (child.endsWith(".nim") or child.endsWith(".nims")):
        continue
      let normalized = normalizedStampPath(child)
      if normalized notin seen:
        seen.incl(normalized)
        result.add(normalized)
  result.sort(system.cmp[string])

proc reproLibSources(workDir: string): seq[string] =
  let libsRoot = workDir / "libs"
  if not dirExists(extendedPath(libsRoot)):
    return
  # NOTE: pass the *non*-extended ``libsRoot`` to ``walkDirRec`` here.
  # On Windows ``walkDirRec`` propagates whatever path it was handed,
  # so feeding it ``\\?\D:\...`` produces ``\\?\D:\...`` children. Those
  # children then survive ``normalizedStampPath`` as ``//?/D:/...`` and
  # the subsequent ``extendedPath`` call re-prefixes them, yielding the
  # invalid ``\\?\\\?\D:\...`` Nim then fails to open. The libs tree is
  # well under MAX_PATH so the raw form is safe.
  for path in walkDirRec(libsRoot):
    if path.endsWith(".nim") or path.endsWith(".nims"):
      result.add(normalizedStampPath(path))
  result.sort(system.cmp[string])

proc reproLibSourceFingerprint(workDir: string): string =
  let paths = reproLibSources(workDir)
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.lib-sources.v1")
  for path in paths:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  toHex(blake3DomainDigest(payload, hdActionFingerprint).bytes)

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

proc cacheableWarmEvidence(stamp: FileStamp): bool =
  stamp.kind == fskRegular

proc readInterfaceArtifactWithWarm(path: string): ProjectInterfaceArtifact =
  let evidence = fileStamp(path)
  if processWarmInterfaceArtifacts.hasKey(path):
    let warm = processWarmInterfaceArtifacts[path]
    if cacheableWarmEvidence(evidence) and warm.evidence == evidence:
      inc processWarmInterfaceStats.artifactWarmHits
      return warm.artifact
    inc processWarmInterfaceStats.artifactWarmMisses
  else:
    inc processWarmInterfaceStats.artifactColdReads
  result = readInterfaceArtifact(path)
  if cacheableWarmEvidence(evidence):
    processWarmInterfaceArtifacts[path] = WarmProjectInterfaceArtifact(
      evidence: evidence,
      artifact: result)

proc fileStamps(paths: openArray[string]): seq[FileStamp] =
  for path in paths:
    result.add(fileStamp(path))
  result.sort do (a, b: FileStamp) -> int:
    cmp(a.path, b.path)

proc restampRecordedInputs(stamps: openArray[FileStamp]): seq[FileStamp] =
  for stamp in stamps:
    result.add(fileStamp(stamp.path))
  result.sort do (a, b: FileStamp) -> int:
    cmp(a.path, b.path)

proc immutableStorePath(path: string): bool =
  normalizedStampPath(path).startsWith("/nix/store/")

proc reproLibStampsForCache(workDir: string): seq[FileStamp] =
  if immutableStorePath(workDir):
    return @[]
  fileStamps(reproLibSources(workDir))

proc interfaceExtractionContext(modulePath: string;
                                workDir = getCurrentDir();
                                includeReproLibFingerprint = true):
    InterfaceExtractionContext =
  let sources = discoverNimSources(modulePath).mapIt(normalizedStampPath(it))
  InterfaceExtractionContext(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    nimCompiler: nimCompilerPath(),
    libPathFlags: reproLibPathFlags(workDir),
    reproLibFingerprint:
      if includeReproLibFingerprint: reproLibSourceFingerprint(workDir)
      else: "",
    sources: sources)

proc interfaceExtractionCacheContext(modulePath: string;
                                     workDir = getCurrentDir()):
    InterfaceExtractionContext =
  InterfaceExtractionContext(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    nimCompiler: nimCompilerPath(),
    libPathFlags:
      if immutableStorePath(workDir): @[]
      else: reproLibPathFlags(workDir),
    reproLibFingerprint: "",
    sources: @[])

proc interfaceContextsMatchForCache(a, b: InterfaceExtractionContext): bool =
  a.modulePath == b.modulePath and
    a.workDir == b.workDir and
    a.nimCompiler == b.nimCompiler and
    (a.libPathFlags == b.libPathFlags or immutableStorePath(a.workDir))

proc interfaceExtractionFingerprint(context: InterfaceExtractionContext):
    ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.interfaceExtract.v1")
  payload.writeString(context.modulePath)
  payload.writeString(context.workDir)
  payload.writeString(context.nimCompiler)
  payload.writeStringSeq(context.libPathFlags)
  payload.writeString(context.reproLibFingerprint)
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
    reproLibStamps: reproLibStampsForCache(context.workDir),
    inputFingerprint: fingerprint)
  try:
    let metadataPath = interfaceExtractionMetadataPath(artifactPath)
    writeFile(extendedPath(metadataPath),
      toByteString(encodeInterfaceExtractionCacheRecord(record)))
    let evidence = fileStamp(metadataPath)
    if cacheableWarmEvidence(evidence):
      processWarmInterfaceMetadata[metadataPath] =
        WarmInterfaceExtractionCacheRecord(
          evidence: evidence,
          record: record)
  except CatchableError:
    discard

proc readInterfaceExtractionCacheRecord(path: string):
    Option[InterfaceExtractionCacheRecord] =
  let evidence = fileStamp(path)
  if evidence.kind == fskMissing:
    return none(InterfaceExtractionCacheRecord)
  if processWarmInterfaceMetadata.hasKey(path):
    let warm = processWarmInterfaceMetadata[path]
    if cacheableWarmEvidence(evidence) and warm.evidence == evidence:
      inc processWarmInterfaceStats.metadataWarmHits
      return some(warm.record)
    inc processWarmInterfaceStats.metadataWarmMisses
  else:
    inc processWarmInterfaceStats.metadataColdReads
  try:
    let record =
      decodeInterfaceExtractionCacheRecord(fromByteString(readFile(extendedPath(path))))
    if cacheableWarmEvidence(evidence):
      processWarmInterfaceMetadata[path] =
        WarmInterfaceExtractionCacheRecord(
          evidence: evidence,
          record: record)
    return some(record)
  except CatchableError:
    return none(InterfaceExtractionCacheRecord)

proc cachedInterfaceArtifactByMetadata(artifactPath, stubPath: string;
                                       context: InterfaceExtractionContext;
                                       requireStub = true):
    Option[ProjectInterfaceArtifact] =
  if not fileExists(extendedPath(artifactPath)):
    return none(ProjectInterfaceArtifact)
  if requireStub and not fileExists(extendedPath(stubPath)):
    return none(ProjectInterfaceArtifact)
  let record = readInterfaceExtractionCacheRecord(
    interfaceExtractionMetadataPath(artifactPath))
  if record.isNone:
    return none(ProjectInterfaceArtifact)
  let cached = record.get()
  if not interfaceContextsMatchForCache(cached.context, context):
    return none(ProjectInterfaceArtifact)
  processWarmInterfaceStats.metadataRevalidatedSources +=
    cached.sourceStamps.len
  if cached.sourceStamps != restampRecordedInputs(cached.sourceStamps):
    return none(ProjectInterfaceArtifact)
  processWarmInterfaceStats.metadataRevalidatedReproLibs +=
    cached.reproLibStamps.len
  if cached.reproLibStamps != restampRecordedInputs(cached.reproLibStamps):
    return none(ProjectInterfaceArtifact)
  try:
    let artifact = readInterfaceArtifactWithWarm(artifactPath)
    if artifact.interfaceFingerprint != cached.inputFingerprint:
      return none(ProjectInterfaceArtifact)
    return some(artifact)
  except CatchableError:
    return none(ProjectInterfaceArtifact)

proc cachedInterfaceArtifactByFingerprint(artifactPath, stubPath: string;
                                          fingerprint: ContentDigest;
                                          requireStub = true):
    Option[ProjectInterfaceArtifact] =
  let cachePath = interfaceExtractionCachePath(artifactPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(cachePath))):
    return none(ProjectInterfaceArtifact)
  if requireStub and not fileExists(extendedPath(stubPath)):
    return none(ProjectInterfaceArtifact)
  if readFile(extendedPath(cachePath)).strip() != toHex(fingerprint.bytes):
    return none(ProjectInterfaceArtifact)
  try:
    return some(readInterfaceArtifactWithWarm(artifactPath))
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

proc addExternalPackagePath(flags: var seq[string]; workDir, envName: string;
                            candidates: openArray[string]; marker: string) =
  ## Replay one of ``config.nims``'s ``addPackagePath`` resolutions as an
  ## explicit ``--path`` flag. ``config.nims`` resolves each third-party /
  ## sibling-repo package by checking ``getEnv(envName)`` first and then a
  ## list of candidate directories, gating each on a marker file so a stale or
  ## wrong directory is never added. We mirror that exact logic here.
  ##
  ## This is required because the interface-extraction runner and the per-
  ## project provider binary are compiled from a scratch tree that lives
  ## OUTSIDE reprobuild (under ``<project>/.repro/...`` for dev-env, under the
  ## build out-dir otherwise). Nim only evaluates reprobuild's ``config.nims``
  ## when the compiled main module sits inside reprobuild's directory tree (the
  ## project-config parent walk); for an arbitrary project it does not, so the
  ## ``--path`` switches ``config.nims`` would have added (e.g. ``NIMCRYPTO_SRC``
  ## for ``nimcrypto/sha2``, pulled in transitively by ``repro_project_dsl``)
  ## are missing and the compile fails with ``cannot open file: nimcrypto/sha2``.
  ## ``externalHashFlags`` replays ``config.nims``'s C-library flags for the same
  ## reason; this helper extends that to the Nim package source paths.
  ##
  ## Candidate paths are resolved relative to ``workDir`` (the
  ## ``reprobuildLibraryWorkDir``) so they match ``config.nims``'s
  ## reprobuild-root-relative candidates regardless of the compile's cwd.
  let resolve = proc(path: string): string =
    if path.len == 0 or path.isAbsolute: path else: workDir / path
  let envPath = getEnv(envName)
  if envPath.len > 0 and fileExists(extendedPath(envPath / marker)):
    flags.add("--path:" & envPath)
    return
  for candidate in candidates:
    let resolved = resolve(candidate)
    if fileExists(extendedPath(resolved / marker)):
      flags.add("--path:" & resolved)
      return

proc reproPackagePathFlags(workDir: string): seq[string] =
  ## Replay the third-party / sibling-repo package ``--path`` switches that
  ## reprobuild's ``config.nims`` adds via ``addPackagePath``. Kept byte-for-byte
  ## in sync with the ``addPackagePath(...)`` block in ``config.nims``; when a
  ## package is added or its candidate list changes there, update it here too.
  ## (reprobuild's OWN ``libs/*/src`` tree is replayed separately by
  ## ``reproLibPathFlags``; this helper covers only the out-of-tree packages.)
  if workDir.len == 0:
    return
  result.addExternalPackagePath(workDir, "FASTSTREAMS_SRC", [
    "libs" / "nim-faststreams" / "src",
    ".." / "codetracer" / "libs" / "nim-faststreams",
    ".." / "nim-faststreams",
  ], "faststreams" / "inputs.nim")
  result.addExternalPackagePath(workDir, "NIM_STEW_SRC", [
    "libs" / "nim-stew" / "src",
    ".." / "codetracer" / "libs" / "nim-stew",
    ".." / "nim-stew",
  ], "stew" / "objects.nim")
  result.addExternalPackagePath(workDir, "NIM_SERIALIZATION_SRC", [
    "libs" / "nim-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-serialization",
    ".." / "nim-serialization",
  ], "serialization" / "case_objects.nim")
  result.addExternalPackagePath(workDir, "NIM_JSON_SERIALIZATION_SRC", [
    "libs" / "nim-json-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-json-serialization",
    ".." / "nim-json-serialization",
  ], "json_serialization.nim")
  result.addExternalPackagePath(workDir, "NIM_TOML_SERIALIZATION_SRC", [
    "libs" / "nim-toml-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-toml-serialization",
    ".." / "nim-toml-serialization",
  ], "toml_serialization.nim")
  result.addExternalPackagePath(workDir, "SSZ_SERIALIZATION_SRC", [
    "libs" / "nim-ssz-serialization" / "src",
    ".." / "nim-ssz-serialization",
  ], "ssz_serialization.nim")
  result.addExternalPackagePath(workDir, "NIMCRYPTO_SRC", [
    ".." / "codetracer" / "libs" / "nimcrypto",
    ".." / "nimcrypto",
  ], "nimcrypto" / "hash.nim")
  result.addExternalPackagePath(workDir, "BEARSSL_SRC", [
    ".." / "nim-bearssl",
    "libs" / "nim-bearssl",
  ], "bearssl.nim")
  result.addExternalPackagePath(workDir, "RESULTS_SRC", [
    "libs" / "results" / "src",
  ], "results.nim")
  result.addExternalPackagePath(workDir, "STINT_SRC", [
    "libs" / "stint" / "src",
  ], "stint.nim")

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

  # repro's own ASP solver (repro_solver) dlopens libclingo at module-init
  # time through a ``{.dynlib.}`` const. When repro runs as a CLI against an
  # arbitrary project, the extract_runner links repro's DSL (which pulls in
  # the solver), so the runner must resolve libclingo at runtime regardless
  # of whether the *host project's* environment provisions it. Replay
  # clingo's lib dir the same way blake3/xxhash are replayed so the runner
  # is self-contained instead of depending on the caller's NIX_LDFLAGS /
  # dyld search path. clingo is dlopened, not linked, so no ``-lclingo`` and
  # no ``-I`` (the bindings are header-free); the ``-L`` search dir plus an
  # ``-rpath`` are both required — on macOS ``-L`` alone does not let the
  # baked dlopen find the library (verified), the rpath is what resolves it.
  let clingoPrefix = block:
    let direct = firstExistingPrefix(
      [getEnv("CLINGO_PREFIX"), "/opt/homebrew/opt/clingo",
        "/usr/local/opt/clingo"],
      "include/clingo.h",
      ["libclingo.dylib", "libclingo.so"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-clingo-*", "include/clingo.h",
        ["libclingo.dylib", "libclingo.so"])
  if clingoPrefix.len > 0:
    result.add("--passL:-L" & clingoPrefix / "lib")
    result.add("--passL:-Wl,-rpath," & clingoPrefix / "lib")

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
  parts.add(reproLibSourceFingerprint(workDir))
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
                                 scratchDir = "";
                                 requireStub = true): ProjectInterfaceArtifact =
  let extractionContext = interfaceExtractionCacheContext(modulePath, workDir)
  let metadataCached = cachedInterfaceArtifactByMetadata(artifactPath,
    stubPath, extractionContext, requireStub)
  if metadataCached.isSome:
    return metadataCached.get()

  let fingerprintContext = interfaceExtractionContext(modulePath, workDir,
    includeReproLibFingerprint = true)
  let inputFingerprint = interfaceExtractionFingerprint(fingerprintContext)
  let cached = cachedInterfaceArtifactByFingerprint(artifactPath, stubPath,
    inputFingerprint, requireStub)
  if cached.isSome:
    writeInterfaceExtractionCacheRecord(artifactPath, fingerprintContext,
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
  command.insert(reproPackagePathFlags(workDir), 2)
  command.insert(libFlags, 4)
  let compileExecution = runCommand(command, cwd = workDir)
  let runnerExe = compiledExecutablePath(runnerBin)
  if not fileExists(extendedPath(runnerExe)):
    # `runCommand` already raises on non-zero exit, so reaching this branch
    # means the compiler reported success (typically `[SuccessX]`) but did
    # not actually write the binary. This has been observed under
    # fork/resource pressure with certain Nim/clang-wrapper combinations.
    # Capture a directory listing to make the missing-output state visible
    # for future triage instead of just claiming the file is absent.
    let runnerExeDir = runnerExe.splitPath.head
    var listing = ""
    try:
      let lsExec = runCommand(@["ls", "-la", runnerExeDir])
      listing = lsExec.output
    except CatchableError as ex:
      listing = "(failed to list " & runnerExeDir & ": " & ex.msg & ")"
    raise newException(IOError,
      "interface extraction runner was not compiled (exit=" &
        $compileExecution.exitCode &
        ", compiler reported success but produced no binary): " &
        runnerExe & "\ncompiler output:\n" & compileExecution.output &
        "\ndirectory listing of " & runnerExeDir & ":\n" & listing)
  ensureExecutable(runnerExe)
  let execution = runCommand(@[runnerExe, artifactPath, stubPath, modulePath],
    cwd = workDir)
  if not fileExists(extendedPath(artifactPath)):
    raise newException(IOError,
      "interface extraction did not write artifact: " & artifactPath &
        "\n" & execution.output)
  result = readInterfaceArtifactWithWarm(artifactPath)
  writeFile(extendedPath(interfaceExtractionCachePath(artifactPath)), toHex(
      inputFingerprint.bytes))
  writeInterfaceExtractionCacheRecord(artifactPath, fingerprintContext,
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
  result.insert(reproPackagePathFlags(workDir), 2)
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
