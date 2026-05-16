import std/[algorithm, options, os, osproc, sequtils, strutils, tempfiles]

import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_project_dsl

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

  InterfaceToolUse* = object
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
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

  ProviderCompileArtifact* = object
    inputSources*: seq[string]
    outputBinaryPath*: string
    compilerCommand*: seq[string]
    compileEdge*: ProviderCompileEdge
    interfaceFingerprint*: ContentDigest
    providerFingerprint*: ContentDigest
    outputBinaryFingerprint*: ContentDigest
    executionResult*: ProviderCompileExecutionResult

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

proc writeToolUse(outp: var seq[byte]; useDef: InterfaceToolUse) =
  outp.writeString(useDef.rawConstraint)
  outp.writeString(useDef.packageSelector)
  outp.writeString(useDef.executableName)
  outp.writeStringSeq(useDef.policyPath)
  outp.writeLocation(useDef.location)

proc readToolUse(bytes: openArray[byte]; pos: var int): InterfaceToolUse =
  result.rawConstraint = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.policyPath = readStringSeq(bytes, pos)
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

proc decodeInterfacePayload*(bytes: openArray[byte]): ProjectInterface =
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
    result.toolUses[i] = readToolUse(bytes, pos)
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
  if version != EnvelopeVersion:
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
    decodeInterfacePayload(bytes.toOpenArray(pos, pos + interfacePayloadLen - 1))
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
  createDir(parentDir(path))
  writeFile(path, toByteString(encodeProjectInterfaceArtifact(artifact)))

proc readInterfaceArtifact*(path: string): ProjectInterfaceArtifact =
  decodeProjectInterfaceArtifact(fromByteString(readFile(path)))

proc writeProviderCompileArtifact*(path: string;
    artifact: ProviderCompileArtifact) =
  createDir(parentDir(path))
  writeFile(path, toByteString(encodeProviderCompileArtifact(artifact)))

proc readProviderCompileArtifact*(path: string): ProviderCompileArtifact =
  decodeProviderCompileArtifact(fromByteString(readFile(path)))

proc toInterfaceParam(param: CliParamDef): InterfaceParam =
  InterfaceParam(
    name: param.name,
    nimType: param.nimType,
    kind: if param.kind == cpkPositional: ipkPositional else: ipkFlag,
    position: param.position,
    alias: param.alias,
    required: param.required,
    location: SourceLocation(file: param.sourceFile, line: param.sourceLine))

proc toInterfaceToolUse(useDef: PackageUseDef): InterfaceToolUse =
  InterfaceToolUse(
    rawConstraint: useDef.rawConstraint,
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    policyPath: useDef.policyPath,
    location: SourceLocation(file: useDef.sourceFile, line: useDef.sourceLine))

proc toProjectInterface*(pkg: PackageDef): ProjectInterface =
  result.projectName = pkg.packageName
  result.packageName = pkg.packageName
  result.publicSignatureDependencies = pkg.publicSignatureDependencies
  result.location = SourceLocation(file: pkg.sourceFile, line: pkg.sourceLine)
  for useDef in pkg.toolUses:
    result.toolUses.add(toInterfaceToolUse(useDef))
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

proc artifactFromRegisteredDsl*(): ProjectInterfaceArtifact =
  let packages = registeredPackages()
  if packages.len != 1:
    raise newException(ValueError, "expected exactly one registered package, got " &
      $packages.len)
  artifactFor(toProjectInterface(packages[0]))

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
  createDir(parentDir(path))
  writeFile(path, code)

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc runCommand(command: openArray[string];
    cwd = ""): ProviderCompileExecutionResult =
  let quoted = command.mapIt(shellQuote(it)).join(" ")
  let res = execCmdEx(quoted, workingDir = cwd)
  result = ProviderCompileExecutionResult(
    exitCode: res.exitCode,
    output: res.output)
  if res.exitCode != 0:
    raise newException(OSError, "command failed (" & $res.exitCode & "): " &
      quoted & "\n" & res.output)

proc reproLibPathFlags(workDir: string): seq[string] =
  let libsRoot = workDir / "libs"
  if dirExists(libsRoot):
    for path in walkDir(libsRoot):
      if path.kind == pcDir:
        let src = path.path / "src"
        if dirExists(src):
          result.add("--path:" & src)
  result.sort(system.cmp[string])

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         libraryNames: openArray[string]): string =
  proc hasLibrary(prefix, libraryName: string): bool =
    let exact = prefix / "lib" / libraryName
    if fileExists(exact):
      return true
    let dot = libraryName.find('.')
    let stem =
      if dot > 0:
        libraryName[0 ..< dot]
      else:
        libraryName
    if not dirExists(prefix / "lib"):
      return false
    for kind, path in walkDir(prefix / "lib"):
      if kind == pcFile:
        let tail = splitPath(path).tail
        if tail == libraryName or tail.startsWith(stem & "."):
          return true

  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(prefix / header):
      continue
    for libraryName in libraryNames:
      if hasLibrary(prefix, libraryName):
        return prefix
  ""

proc nixPrefix(namePattern, header: string;
               libraryNames: openArray[string]): string =
  if not dirExists("/nix/store"):
    return ""
  let needle = namePattern.replace("*", "")
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    let tail = splitPath(path).tail
    if needle.len > 0 and tail.find(needle) < 0:
      continue
    if not fileExists(path / header):
      continue
    if dirExists(path / "lib"):
      return path
    for libraryName in libraryNames:
      if firstExistingPrefix([path], header, [libraryName]).len > 0:
        return path

proc externalHashFlags(): seq[string] =
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

proc extractInterfaceFromModule*(modulePath, artifactPath, stubPath: string;
                                 workDir = getCurrentDir()): ProjectInterfaceArtifact =
  let moduleDir = parentDir(modulePath)
  let moduleName = splitFile(modulePath).name
  let tempParent = workDir / "build" / "m7-temp"
  createDir(tempParent)
  let tempRoot = createTempDir("repro-interface-extract", "", tempParent)
  defer: removeDir(tempRoot)
  let runnerPath = tempRoot / "extract_runner.nim"
  writeFile(runnerPath,
    "import std/os\n" &
    "import repro_interface_artifacts\n" &
    "import repro_project_dsl\n" &
    "import " & moduleName & "\n\n" &
    "when isMainModule:\n" &
    "  let artifact = artifactFromRegisteredDsl()\n" &
    "  writeInterfaceArtifact(paramStr(1), artifact)\n" &
    "  writeNimInterfaceStub(paramStr(2), artifact)\n")
  let runnerBin = tempRoot / "extract_runner"
  var command = @[
    "nim", "c", "-r",
    "--define:reproInterfaceMode",
    "--path:" & moduleDir,
    "--nimcache:" & (tempRoot / "nimcache"),
    "--out:" & runnerBin,
    runnerPath,
    artifactPath,
    stubPath
  ]
  command.insert(reproLibPathFlags(workDir), 4)
  discard runCommand(command, cwd = workDir)
  readInterfaceArtifact(artifactPath)

proc discoverNimSources*(rootModulePath: string): seq[string] =
  let root = parentDir(rootModulePath)
  for path in walkDirRec(root):
    if path.endsWith(".nim"):
      result.add(path)
  result.sort(system.cmp[string])

proc providerFingerprintFor*(inputSources: openArray[string];
                             interfaceFingerprint: ContentDigest): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeDigest(interfaceFingerprint)
  for path in inputSources:
    payload.writeString(path)
    let content = toBytes(readFile(path))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

proc compileProviderBinary*(modulePath, outputBinaryPath: string;
                            interfaceFingerprint: ContentDigest;
                            artifactPath = "";
                            workDir = getCurrentDir()): ProviderCompileArtifact =
  let sources = discoverNimSources(modulePath)
  let providerFingerprint = providerFingerprintFor(sources, interfaceFingerprint)
  createDir(parentDir(outputBinaryPath))
  let nimcache = parentDir(outputBinaryPath) / "nimcache-provider"
  var command = @[
    "nim", "c",
    "--define:reproProviderMode",
    "--path:" & parentDir(modulePath),
    "--nimcache:" & nimcache,
    "--out:" & outputBinaryPath,
    modulePath
  ]
  command.insert(externalHashFlags(), 2)
  command.insert(reproLibPathFlags(workDir), 2)
  let edge = providerCompileEdge(sources, outputBinaryPath, command,
    interfaceFingerprint, providerFingerprint, workDir = workDir)
  let execution = runCommand(command, cwd = workDir)
  result = ProviderCompileArtifact(
    inputSources: sources,
    outputBinaryPath: outputBinaryPath,
    compilerCommand: command,
    compileEdge: edge,
    interfaceFingerprint: interfaceFingerprint,
    providerFingerprint: providerFingerprint,
    outputBinaryFingerprint: casDigest(toBytes(readFile(outputBinaryPath))),
    executionResult: execution)
  if artifactPath.len > 0:
    writeProviderCompileArtifact(artifactPath, result)
