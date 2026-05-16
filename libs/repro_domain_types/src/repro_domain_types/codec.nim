import cbor
import repro_core
import repro_hash
import repro_domain_types/types

const
  EnvelopeMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
  EnvelopeVersion = 1'u16

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeBool(outp: var seq[byte]; value: bool) =
  outp.writeByte(if value: 1'u8 else: 0'u8)

proc readBool(bytes: openArray[byte]; pos: var int): bool =
  case readByte(bytes, pos)
  of 0: false
  of 1: true
  else:
    raiseEnvelopeError(eeMalformed, "invalid bool value")

proc writePath(outp: var seq[byte]; path: NormalizedPath) =
  outp.writeByte(byte(ord(path.kind)))
  outp.writeString(path.value)

proc readPath(bytes: openArray[byte]; pos: var int): NormalizedPath =
  let kindByte = readByte(bytes, pos)
  let value = readString(bytes, pos)
  case kindByte
  of byte(ord(npRelative)):
    NormalizedPath(kind: npRelative, value: value)
  of byte(ord(npAbsolute)):
    NormalizedPath(kind: npAbsolute, value: value)
  else:
    raiseEnvelopeError(eeMalformed, "invalid normalized path kind")

proc writeStableId(outp: var seq[byte]; id: StableId) =
  outp.add(array[16, byte](id))

proc readStableId(bytes: openArray[byte]; pos: var int): StableId =
  if pos + 16 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated stable id")
  var raw: array[16, byte]
  for i in 0 ..< 16:
    raw[i] = bytes[pos + i]
  pos += 16
  stableId(raw)

proc writeDynamic(outp: var seq[byte]; value: DynamicValue) =
  let encoded = encode(value)
  outp.writeU32Le(uint32(encoded.len))
  outp.add(encoded)

proc readDynamic(bytes: openArray[byte]; pos: var int): DynamicValue =
  let length = int(readU32Le(bytes, pos))
  if pos + length > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated dynamic metadata")
  result = decode(bytes.toOpenArray(pos, pos + length - 1))
  pos += length

proc writeEnv(outp: var seq[byte]; env: openArray[EnvVar]) =
  outp.writeU32Le(uint32(env.len))
  for item in env:
    outp.writeString(item.name)
    outp.writeString(item.value)

proc readEnv(bytes: openArray[byte]; pos: var int): seq[EnvVar] =
  let length = int(readU32Le(bytes, pos))
  result = newSeq[EnvVar](length)
  for i in 0 ..< length:
    result[i] = EnvVar(name: readString(bytes, pos), value: readString(bytes, pos))

proc writeProcess(outp: var seq[byte]; process: ProcessSpec) =
  outp.writeByte(byte(ord(process.kind)))
  outp.writePath(process.executable)
  outp.writeU32Le(uint32(process.args.len))
  for arg in process.args:
    outp.writeString(arg)
  outp.writeEnv(process.env)
  outp.writePath(process.cwd)
  outp.writeByte(byte(ord(process.stdinPolicy)))
  outp.writeByte(byte(ord(process.stdoutPolicy)))
  outp.writeByte(byte(ord(process.stderrPolicy)))

proc readStdio(bytes: openArray[byte]; pos: var int): StdioPolicy =
  let value = readByte(bytes, pos)
  if value > byte(ord(spCapture)):
    raiseEnvelopeError(eeMalformed, "invalid stdio policy")
  StdioPolicy(value)

proc readProcess(bytes: openArray[byte]; pos: var int): ProcessSpec =
  let kindByte = readByte(bytes, pos)
  if kindByte > byte(ord(ckShell)):
    raiseEnvelopeError(eeMalformed, "invalid command kind")
  result.kind = CommandKind(kindByte)
  result.executable = readPath(bytes, pos)
  let argc = int(readU32Le(bytes, pos))
  result.args = newSeq[string](argc)
  for i in 0 ..< argc:
    result.args[i] = readString(bytes, pos)
  result.env = readEnv(bytes, pos)
  result.cwd = readPath(bytes, pos)
  result.stdinPolicy = readStdio(bytes, pos)
  result.stdoutPolicy = readStdio(bytes, pos)
  result.stderrPolicy = readStdio(bytes, pos)

proc writeExpectedFile(outp: var seq[byte]; file: ExpectedDependencyFile) =
  outp.writeString(file.logicalName)
  outp.writeString(file.path)
  outp.writeBool(file.required)

proc readExpectedFile(bytes: openArray[byte]; pos: var int): ExpectedDependencyFile =
  ExpectedDependencyFile(
    logicalName: readString(bytes, pos),
    path: readString(bytes, pos),
    required: readBool(bytes, pos))

proc writeDependencyPolicy(outp: var seq[byte]; policy: DependencyGatheringPolicy) =
  outp.writeByte(byte(ord(policy.kind)))
  outp.writeByte(byte(ord(policy.completeness)))
  outp.writeU32Le(uint32(policy.recognizedReports.len))
  for report in policy.recognizedReports:
    outp.writeString($report.formatName)
    outp.writeU32Le(uint32(report.outputs.len))
    for output in report.outputs:
      outp.writeExpectedFile(output)
  outp.writeU32Le(uint32(policy.postBuildConverters.len))
  for converterSpec in policy.postBuildConverters:
    outp.writeString(converterSpec.converterPath)
    outp.writeU32Le(uint32(converterSpec.args.len))
    for arg in converterSpec.args:
      outp.writeString(arg)
    outp.writeU32Le(uint32(converterSpec.outputs.len))
    for output in converterSpec.outputs:
      outp.writeExpectedFile(output)

proc readDependencyPolicy(bytes: openArray[byte]; pos: var int): DependencyGatheringPolicy =
  let kind = readByte(bytes, pos)
  let completeness = readByte(bytes, pos)
  if kind > byte(ord(dgNoRuntimeDependencies)):
    raiseEnvelopeError(eeMalformed, "invalid dependency gathering kind")
  if completeness > byte(ord(decDiagnosticOnly)):
    raiseEnvelopeError(eeMalformed, "invalid evidence completeness")
  result.kind = DependencyGatheringKind(kind)
  result.completeness = DependencyEvidenceCompleteness(completeness)
  let reportCount = int(readU32Le(bytes, pos))
  result.recognizedReports = newSeq[RecognizedDependencyReportSpec](reportCount)
  for i in 0 ..< reportCount:
    let name = DependencyFormatName(readString(bytes, pos))
    let outputCount = int(readU32Le(bytes, pos))
    var outputs = newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      outputs[j] = readExpectedFile(bytes, pos)
    result.recognizedReports[i] =
      RecognizedDependencyReportSpec(formatName: name, outputs: outputs)
  let converterCount = int(readU32Le(bytes, pos))
  result.postBuildConverters = newSeq[PostBuildDependencyConverterSpec](converterCount)
  for i in 0 ..< converterCount:
    result.postBuildConverters[i].converterPath = readString(bytes, pos)
    let argCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].args = newSeq[string](argCount)
    for j in 0 ..< argCount:
      result.postBuildConverters[i].args[j] = readString(bytes, pos)
    let outputCount = int(readU32Le(bytes, pos))
    result.postBuildConverters[i].outputs = newSeq[ExpectedDependencyFile](outputCount)
    for j in 0 ..< outputCount:
      result.postBuildConverters[i].outputs[j] = readExpectedFile(bytes, pos)

proc writeContentDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.writeByte(byte(ord(digest.algorithm)))
  outp.writeByte(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readContentDigest(bytes: openArray[byte]; pos: var int): ContentDigest =
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

proc encodePayload(value: DomainValue): seq[byte] =
  case value.kind
  of dekRepositoryMetadata:
    result.writeStableId(value.repositoryMetadata.repositoryId)
    result.writeString(value.repositoryMetadata.displayName)
    result.writeU32Le(value.repositoryMetadata.formatVersion)
    result.writeDynamic(value.repositoryMetadata.metadata)
  of dekActionSpec:
    result.writeStableId(value.actionSpec.actionId)
    result.writeProcess(value.actionSpec.process)
    result.writeDependencyPolicy(value.actionSpec.dependencyPolicy)
    result.writeDynamic(value.actionSpec.metadata)
  of dekContentDigestEnvelope:
    result.writeContentDigest(value.contentDigest.digest)
    result.writeU64Le(value.contentDigest.size)

proc decodePayload(kind: DomainEnvelopeKind; payload: openArray[byte]): DomainValue =
  var pos = 0
  case kind
  of dekRepositoryMetadata:
    result = repositoryValue(RepositoryMetadata(
      repositoryId: readStableId(payload, pos),
      displayName: readString(payload, pos),
      formatVersion: readU32Le(payload, pos),
      metadata: readDynamic(payload, pos)))
  of dekActionSpec:
    result = actionValue(ActionSpec(
      actionId: readStableId(payload, pos),
      process: readProcess(payload, pos),
      dependencyPolicy: readDependencyPolicy(payload, pos),
      metadata: readDynamic(payload, pos)))
  of dekContentDigestEnvelope:
    result = contentDigestValue(ContentDigestEnvelope(
      digest: readContentDigest(payload, pos),
      size: readU64Le(payload, pos)))
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing fixed-schema payload bytes")

proc encodeEnvelope*(value: DomainValue): seq[byte] =
  let payload = encodePayload(value)
  result = @[]
  result.add(EnvelopeMagic)
  result.writeU16Le(EnvelopeVersion)
  result.writeU16Le(uint16(ord(value.kind) + 1))
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeEnvelope*(bytes: openArray[byte]): DomainValue =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated envelope")
  for i in 0 ..< 4:
    if bytes[i] != EnvelopeMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown fixed-schema envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != EnvelopeVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported envelope version " & $version)
  let typeId = readU16Le(bytes, pos)
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "envelope payload length mismatch")
  let kind =
    case typeId
    of uint16(ord(dekRepositoryMetadata) + 1): dekRepositoryMetadata
    of uint16(ord(dekActionSpec) + 1): dekActionSpec
    of uint16(ord(dekContentDigestEnvelope) + 1): dekContentDigestEnvelope
    else:
      raiseEnvelopeError(eeUnknownType, "unknown envelope type " & $typeId)
  decodePayload(kind, bytes.toOpenArray(pos, pos + payloadLength - 1))

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writeEnvelope*(path: string; value: DomainValue) =
  writeFile(path, toByteString(encodeEnvelope(value)))

proc readEnvelope*(path: string): DomainValue =
  decodeEnvelope(fromByteString(readFile(path)))

proc fixedSchemaMagic*(): array[4, byte] =
  EnvelopeMagic

proc envelopeVersion*(): uint16 =
  EnvelopeVersion
