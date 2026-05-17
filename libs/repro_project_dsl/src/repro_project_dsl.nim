import std/[macros, os, strutils, tables]

when defined(reproProviderMode):
  import repro_provider_runtime

type
  BuildActionPayloadError* = object of CatchableError

  Tool*[name: static string] = object

  CliParamKind* = enum
    cpkPositional
    cpkFlag

  CliArgRole* = enum
    carOrdinary
    carInput
    carOutput

  CliArgFormat* = enum
    cafSeparate
    cafConcat
    cafEquals

  CliParamDef* = object
    name*: string
    nimType*: string
    kind*: CliParamKind
    role*: CliArgRole
    format*: CliArgFormat
    repeated*: bool
    position*: int
    alias*: string
    required*: bool
    sourceFile*: string
    sourceLine*: int

  CliCommandDef* = object
    name*: string
    params*: seq[CliParamDef]
    providerEntrypointId*: string
    sourceFile*: string
    sourceLine*: int

  ExecutableDef* = object
    exportName*: string
    binaryName*: string
    commands*: seq[CliCommandDef]
    sourceFile*: string
    sourceLine*: int

  PackageUseDef* = object
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
    sourceFile*: string
    sourceLine*: int

  PackageDef* = object
    packageName*: string
    executables*: seq[ExecutableDef]
    toolUses*: seq[PackageUseDef]
    usesImportPaths*: seq[string]
    publicSignatureDependencies*: seq[string]
    sourceFile*: string
    sourceLine*: int

  PublicCliArg* = object
    name*: string
    nimType*: string
    kind*: CliParamKind
    role*: CliArgRole
    format*: CliArgFormat
    repeated*: bool
    position*: int
    alias*: string
    encodedValue*: string

  PublicCliCall* = object
    packageName*: string
    executableName*: string
    subcommand*: string
    providerEntrypointId*: string
    arguments*: seq[PublicCliArg]

  BuildActionDependencyPolicyKind* = enum
    bdpDefault
    bdpDeclaredOnly
    bdpAutomaticMonitor
    bdpMakeDepfile

  BuildActionDependencyPolicy* = object
    kind*: BuildActionDependencyPolicyKind
    depfile*: string

  SelectedExecutable* = object
    packageName*: string
    executableName*: string

  BuildActionDef* = object
    id*: string
    call*: PublicCliCall
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    depfile*: string
    cacheable*: bool
    commandStatsId*: string
    dependencyPolicy*: BuildActionDependencyPolicy

var registry: seq[PackageDef] = @[]
var buildActionRegistry: seq[BuildActionDef] = @[]
var defaultBuildActionRegistry = ""

when defined(reproProviderMode):
  var providerEvaluationInputRegistry: seq[GraphEvaluationInput] = @[]
  var currentProviderProjectRoot = ""

const
  BuildActionPayloadMagic = [byte(ord('R')), byte(ord('B')), byte(ord('A')),
    byte(ord('P'))]
  BuildActionPayloadVersion = 5'u16

proc resetPackageRegistry*() =
  registry.setLen(0)

proc registerPackageDef*(pkg: PackageDef) =
  registry.add(pkg)

proc registeredPackages*(): seq[PackageDef] =
  registry

proc resetBuildActionRegistry*() =
  buildActionRegistry.setLen(0)

proc registeredBuildActions*(): seq[BuildActionDef] =
  buildActionRegistry

proc resetDefaultBuildActionRegistry*() =
  defaultBuildActionRegistry = ""

proc defaultBuildAction*(id: string) =
  defaultBuildActionRegistry = id

proc registeredDefaultBuildAction*(): string =
  defaultBuildActionRegistry

when defined(reproProviderMode):
  proc resetProviderEvaluationInputRegistry() =
    providerEvaluationInputRegistry.setLen(0)

  proc materialProviderPath(path: string): string =
    if path.len == 0 or path.isAbsolute:
      path
    else:
      os.normalizedPath(currentProviderProjectRoot / path)

  proc providerDirectoryInput*(path: string) =
    providerEvaluationInputRegistry.add(
      directoryEnumerationInput(materialProviderPath(path), "", ""))

  proc registeredProviderEvaluationInputs(): seq[GraphEvaluationInput] =
    providerEvaluationInputRegistry

else:
  proc providerDirectoryInput*(path: string) =
    discard path

proc cliArg*(name: string; value: string; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             repeated = false): PublicCliArg =
  PublicCliArg(name: name, nimType: "string", kind: kind, position: position,
    alias: alias, format: format, repeated: repeated, encodedValue: value)

proc cliArg*(name: string; value: int; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             repeated = false): PublicCliArg =
  PublicCliArg(name: name, nimType: "int", kind: kind, position: position,
    alias: alias, format: format, repeated: repeated, encodedValue: $value)

proc cliArg*(name: string; value: bool; kind = cpkFlag; position = 0;
             alias = ""; format = cafSeparate;
             repeated = false): PublicCliArg =
  PublicCliArg(name: name, nimType: "bool", kind: kind, position: position,
    alias: alias, format: format, repeated: repeated, encodedValue: $value)

proc cliArgSeq*(name: string; value: seq[string]; kind = cpkFlag; position = 0;
                alias = ""; format = cafSeparate;
                repeated = false): PublicCliArg =
  PublicCliArg(name: name, nimType: "seq[string]", kind: kind, position: position,
    alias: alias, format: format, repeated: repeated,
    encodedValue: value.join("\x1f"))

proc inputArg*(name: string; value: string; kind = cpkFlag; position = 0;
               alias = ""; format = cafSeparate;
               repeated = false): PublicCliArg =
  result = cliArg(name, value, kind, position, alias, format, repeated)
  result.role = carInput

proc outputArg*(name: string; value: string; kind = cpkFlag; position = 0;
                alias = ""; format = cafSeparate;
                repeated = false): PublicCliArg =
  result = cliArg(name, value, kind, position, alias, format, repeated)
  result.role = carOutput

proc inputArgSeq*(name: string; value: seq[string]; kind = cpkFlag; position = 0;
                  alias = ""; format = cafSeparate;
                  repeated = false): PublicCliArg =
  result = cliArgSeq(name, value, kind, position, alias, format, repeated)
  result.role = carInput

proc outputArgSeq*(name: string; value: seq[string]; kind = cpkFlag;
                   position = 0; alias = ""; format = cafSeparate;
                   repeated = false): PublicCliArg =
  result = cliArgSeq(name, value, kind, position, alias, format, repeated)
  result.role = carOutput

proc publicCliCall*(packageName, executableName, subcommand,
                    providerEntrypointId: string;
                    arguments: openArray[PublicCliArg]): PublicCliCall =
  PublicCliCall(
    packageName: packageName,
    executableName: executableName,
    subcommand: subcommand,
    providerEntrypointId: providerEntrypointId,
    arguments: @arguments)

proc selectedExecutable*(packageName, executableName: string): SelectedExecutable =
  SelectedExecutable(packageName: packageName, executableName: executableName)

proc defaultDependencyPolicy*(): BuildActionDependencyPolicy =
  BuildActionDependencyPolicy(kind: bdpDefault)

proc declaredOnlyDependencyPolicy*(): BuildActionDependencyPolicy =
  BuildActionDependencyPolicy(kind: bdpDeclaredOnly)

proc automaticMonitorPolicy*(): BuildActionDependencyPolicy =
  BuildActionDependencyPolicy(kind: bdpAutomaticMonitor)

proc makeDepfilePolicy*(depfile = ""): BuildActionDependencyPolicy =
  BuildActionDependencyPolicy(kind: bdpMakeDepfile, depfile: depfile)

proc buildAction*(id: string; call: PublicCliCall;
                  deps: openArray[string] = [];
                  inputs: openArray[string] = [];
                  outputs: openArray[string] = [];
                  depfile = "";
                  cacheable = true;
                  commandStatsId = "";
                  dependencyPolicy = defaultDependencyPolicy()): BuildActionDef =
  result = BuildActionDef(
    id: id,
    call: call,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    depfile: depfile,
    cacheable: cacheable,
    commandStatsId: if commandStatsId.len > 0: commandStatsId else: id,
    dependencyPolicy: dependencyPolicy)
  buildActionRegistry.add(result)

proc addUniquePath(paths: var seq[string]; path: string) =
  let stripped = path.strip()
  if stripped.len > 0 and paths.find(stripped) < 0:
    paths.add(stripped)

proc addRoleValues(paths: var seq[string]; arg: PublicCliArg) =
  if arg.nimType.normalize == "bool":
    return
  if arg.nimType.normalize == "seq[string]":
    if arg.encodedValue.len > 0:
      for item in arg.encodedValue.split("\x1f"):
        paths.addUniquePath(item)
  else:
    paths.addUniquePath(arg.encodedValue)

proc declaredInputPaths*(call: PublicCliCall): seq[string] =
  for arg in call.arguments:
    if arg.role == carInput:
      result.addRoleValues(arg)

proc declaredOutputPaths*(call: PublicCliCall): seq[string] =
  for arg in call.arguments:
    if arg.role == carOutput:
      result.addRoleValues(arg)

proc recordCommandAction*(id: string; call: PublicCliCall;
                          deps: openArray[string] = [];
                          extraInputs: openArray[string] = [];
                          extraOutputs: openArray[string] = [];
                          depfile = "";
                          cacheable = true;
                          commandStatsId = "";
                          dependencyPolicy = defaultDependencyPolicy()):
    BuildActionDef =
  var inputs = declaredInputPaths(call)
  var outputs = declaredOutputPaths(call)
  for item in extraInputs:
    inputs.addUniquePath(item)
  for item in extraOutputs:
    outputs.addUniquePath(item)
  buildAction(
    id,
    call,
    deps = deps,
    inputs = inputs,
    outputs = outputs,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = dependencyPolicy)

proc recordToolInvocation*(id: string; call: PublicCliCall;
                           deps: openArray[string] = [];
                           extraInputs: openArray[string] = [];
                           extraOutputs: openArray[string] = [];
                           depfile = "";
                           cacheable = true;
                           commandStatsId = "";
                           dependencyPolicy = defaultDependencyPolicy()):
    BuildActionDef =
  recordCommandAction(
    id,
    call,
    deps = deps,
    extraInputs = extraInputs,
    extraOutputs = extraOutputs,
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = dependencyPolicy)

proc normalizedDeclaredProjectPath*(projectRoot, path: string): string =
  result = path.replace('\\', '/').strip()
  while result.startsWith("./"):
    result = result.substr(2)
  while result.endsWith("/") and result.len > 1:
    result.setLen(result.len - 1)
  if result.len == 0:
    return
  if projectRoot.len > 0 and path.isAbsolute:
    let normalizedRoot = normalizedPath(projectRoot).replace('\\', '/')
    let normalizedPathValue = normalizedPath(path).replace('\\', '/')
    if normalizedPathValue == normalizedRoot:
      return "."
    let prefix = normalizedRoot & "/"
    if normalizedPathValue.startsWith(prefix):
      return normalizedPathValue.substr(prefix.len)
    result = normalizedPathValue

proc inferDeclaredActionDeps*(actions: openArray[BuildActionDef];
                              projectRoot = ""): seq[BuildActionDef] =
  result = @actions
  var outputProducer = initTable[string, string]()
  for action in actions:
    for output in action.outputs:
      let normalized = normalizedDeclaredProjectPath(projectRoot, output)
      if normalized.len > 0 and not outputProducer.hasKey(normalized):
        outputProducer[normalized] = action.id
  for i in 0 ..< result.len:
    var knownDeps = result[i].deps
    for input in result[i].inputs:
      let normalized = normalizedDeclaredProjectPath(projectRoot, input)
      if normalized.len == 0:
        continue
      if outputProducer.hasKey(normalized):
        let producerId = outputProducer[normalized]
        if producerId != result[i].id and knownDeps.find(producerId) < 0:
          knownDeps.add(producerId)
    result[i].deps = knownDeps

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc raisePayload(message: string) {.noreturn.} =
  raise newException(BuildActionPayloadError, message)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raisePayload("truncated build action payload byte")
  result = bytes[pos]
  inc pos

proc writeU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  for shift in [0, 8, 16, 24]:
    outp.add(byte((value shr shift) and 0xff'u32))

proc readU16Le(bytes: openArray[byte]; pos: var int): uint16 =
  if pos + 2 > bytes.len:
    raisePayload("truncated uint16 in build action payload")
  result = uint16(bytes[pos]) or (uint16(bytes[pos + 1]) shl 8)
  pos += 2

proc readU32Le(bytes: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > bytes.len:
    raisePayload("truncated uint32 in build action payload")
  for i in 0 ..< 4:
    result = result or (uint32(bytes[pos + i]) shl (8 * i))
  pos += 4

proc writeString(outp: var seq[byte]; value: string) =
  outp.writeU32Le(uint32(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

proc readString(bytes: openArray[byte]; pos: var int): string =
  let length = int(readU32Le(bytes, pos))
  if pos + length > bytes.len:
    raisePayload("truncated string in build action payload")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(bytes[pos + i])
  pos += length

proc fromBytes(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeCliArg(outp: var seq[byte]; arg: PublicCliArg) =
  outp.writeString(arg.name)
  outp.writeString(arg.nimType)
  outp.writeByte(byte(ord(arg.kind)))
  outp.writeU32Le(uint32(arg.position))
  outp.writeString(arg.alias)
  outp.writeByte(byte(ord(arg.role)))
  outp.writeByte(byte(ord(arg.format)))
  outp.writeByte(if arg.repeated: 1'u8 else: 0'u8)
  outp.writeString(arg.encodedValue)

proc readCliArg(bytes: openArray[byte]; pos: var int; version: uint16):
    PublicCliArg =
  result.name = readString(bytes, pos)
  result.nimType = readString(bytes, pos)
  if version >= 2'u16:
    let kind = readByte(bytes, pos)
    if kind > byte(ord(cpkFlag)):
      raisePayload("invalid CLI argument kind in build action payload")
    result.kind = CliParamKind(kind)
    result.position = int(readU32Le(bytes, pos))
    result.alias = readString(bytes, pos)
  else:
    result.kind = cpkFlag
  if version >= 4'u16:
    let role = readByte(bytes, pos)
    if role > byte(ord(carOutput)):
      raisePayload("invalid CLI argument role in build action payload")
    result.role = CliArgRole(role)
  else:
    result.role = carOrdinary
  if version >= 5'u16:
    let format = readByte(bytes, pos)
    if format > byte(ord(cafEquals)):
      raisePayload("invalid CLI argument format in build action payload")
    result.format = CliArgFormat(format)
    result.repeated = readByte(bytes, pos) == 1'u8
  else:
    result.format = cafSeparate
    result.repeated = false
  result.encodedValue = readString(bytes, pos)

proc writeCliCall(outp: var seq[byte]; call: PublicCliCall) =
  outp.writeString(call.packageName)
  outp.writeString(call.executableName)
  outp.writeString(call.subcommand)
  outp.writeString(call.providerEntrypointId)
  outp.writeU32Le(uint32(call.arguments.len))
  for arg in call.arguments:
    outp.writeCliArg(arg)

proc readCliCall(bytes: openArray[byte]; pos: var int; version: uint16):
    PublicCliCall =
  result.packageName = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.subcommand = readString(bytes, pos)
  result.providerEntrypointId = readString(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.arguments = newSeq[PublicCliArg](count)
  for i in 0 ..< count:
    result.arguments[i] = readCliArg(bytes, pos, version)

proc writeDependencyPolicy(outp: var seq[byte];
                           policy: BuildActionDependencyPolicy) =
  outp.writeByte(byte(ord(policy.kind)))
  outp.writeString(policy.depfile)

proc readDependencyPolicy(bytes: openArray[byte]; pos: var int):
    BuildActionDependencyPolicy =
  let kind = readByte(bytes, pos)
  if kind > byte(ord(bdpMakeDepfile)):
    raisePayload("invalid dependency policy kind in build action payload")
  result.kind = BuildActionDependencyPolicyKind(kind)
  result.depfile = readString(bytes, pos)

proc encodeBuildActionPayload*(action: BuildActionDef): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(action.id)
  payload.writeCliCall(action.call)
  payload.writeStringSeq(action.deps)
  payload.writeStringSeq(action.inputs)
  payload.writeStringSeq(action.outputs)
  payload.writeString(action.depfile)
  payload.writeByte(if action.cacheable: 1'u8 else: 0'u8)
  payload.writeString(action.commandStatsId)
  payload.writeDependencyPolicy(action.dependencyPolicy)

  result.add(BuildActionPayloadMagic)
  result.writeU16Le(BuildActionPayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeBuildActionPayload*(bytes: openArray[byte]): BuildActionDef =
  if bytes.len < 10:
    raisePayload("truncated build action payload envelope")
  for i in 0 ..< BuildActionPayloadMagic.len:
    if bytes[i] != BuildActionPayloadMagic[i]:
      raisePayload("unknown build action payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version notin {1'u16, 2'u16, 3'u16, 4'u16, BuildActionPayloadVersion}:
    raisePayload("unsupported build action payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("build action payload length mismatch")

  result.id = readString(bytes, pos)
  result.call = readCliCall(bytes, pos, version)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  result.depfile = readString(bytes, pos)
  result.cacheable = readByte(bytes, pos) == 1'u8
  result.commandStatsId = readString(bytes, pos)
  if version >= 3'u16:
    result.dependencyPolicy = readDependencyPolicy(bytes, pos)
  else:
    result.dependencyPolicy = defaultDependencyPolicy()
  if pos != bytes.len:
    raisePayload("trailing build action payload bytes")

proc actionPayload*(action: BuildActionDef): string =
  fromBytes(encodeBuildActionPayload(action))

proc callIdentity*(call: PublicCliCall): string =
  var parts = @[call.packageName, call.executableName, call.subcommand,
                call.providerEntrypointId]
  for arg in call.arguments:
    parts.add(arg.name & ":" & arg.nimType & ":" & $arg.role & ":" &
      $arg.format & ":" & $arg.repeated & "=" & arg.encodedValue)
  parts.join("|")

proc stableHashHex(value: string): string =
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

proc actionIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      result.add(ch.toLowerAscii())
    elif ch in {' ', '/', '\\', ':'}:
      if result.len == 0 or result[^1] != '-':
        result.add('-')
    else:
      result.add(toHex(ord(ch), 2).toLowerAscii())
  while result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "tool"

proc defaultToolActionId*(call: PublicCliCall): string =
  var base = actionIdPart(call.executableName)
  if call.subcommand.len > 0:
    base.add("-" & actionIdPart(call.subcommand))
  base & "-" & stableHashHex(callIdentity(call))

proc identText(node: NimNode): string =
  case node.kind
  of nnkIdent, nnkSym:
    result = $node
  of nnkAccQuoted:
    result = ""
    for child in node:
      result.add(identText(child))
  else:
    result = node.repr

proc stringLiteral(node: NimNode): string =
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    result = node.strVal
  else:
    result = node.repr

proc intLiteral(node: NimNode; fallback: int): int =
  case node.kind
  of nnkIntLit..nnkUInt64Lit:
    int(node.intVal)
  else:
    fallback

proc boolLiteral(node: NimNode; fallback: bool): bool =
  if node.kind == nnkIdent:
    case ($node).normalize
    of "true": true
    of "false": false
    else: fallback
  else:
    fallback

proc roleLiteral(node: NimNode; fallback: CliArgRole): CliArgRole =
  let text = identText(node).normalize
  case text
  of "input", "carinput", "inputpath":
    carInput
  of "output", "caroutput", "outputpath":
    carOutput
  of "ordinary", "carordinary":
    carOrdinary
  else:
    fallback

proc formatLiteral(node: NimNode; fallback: CliArgFormat): CliArgFormat =
  let text = identText(node).normalize
  case text
  of "separate", "cafseparate":
    cafSeparate
  of "concat", "cafconcat":
    cafConcat
  of "equals", "cafequals":
    cafEquals
  else:
    fallback

proc lineFile(node: NimNode): tuple[file: string; line: int] =
  let info = node.lineInfoObj()
  (info.filename, info.line)

proc calleeName(node: NimNode): string =
  if node.kind in {nnkCall, nnkCommand} and node.len > 0:
    identText(node[0])
  else:
    ""

proc namedValue(node: NimNode; name: string): NimNode =
  if node.kind == nnkExprEqExpr and identText(node[0]).normalize ==
      name.normalize:
    node[1]
  else:
    nil

proc parseParam(node: NimNode): CliParamDef =
  let kindName = calleeName(node).normalize
  let loc = lineFile(node)
  if kindName == "pos":
    result.kind = cpkPositional
    result.name = identText(node[1])
    result.nimType = node[2].repr
    result.position = 0
    result.required = true
    for i in 3 ..< node.len:
      let value = namedValue(node[i], "position")
      if not value.isNil:
        result.position = intLiteral(value, result.position)
      let roleValue = namedValue(node[i], "role")
      if not roleValue.isNil:
        result.role = roleLiteral(roleValue, result.role)
      let repeatedValue = namedValue(node[i], "repeated")
      if not repeatedValue.isNil:
        result.repeated = boolLiteral(repeatedValue, result.repeated)
  elif kindName == "flag":
    result.kind = cpkFlag
    result.name = identText(node[1])
    result.nimType = node[2].repr
    result.position = 0
    result.required = false
    for i in 3 ..< node.len:
      let aliasValue = namedValue(node[i], "alias")
      if not aliasValue.isNil:
        result.alias = stringLiteral(aliasValue)
      let requiredValue = namedValue(node[i], "required")
      if not requiredValue.isNil:
        result.required = boolLiteral(requiredValue, result.required)
      let roleValue = namedValue(node[i], "role")
      if not roleValue.isNil:
        result.role = roleLiteral(roleValue, result.role)
      let formatValue = namedValue(node[i], "format")
      if not formatValue.isNil:
        result.format = formatLiteral(formatValue, result.format)
      let repeatedValue = namedValue(node[i], "repeated")
      if not repeatedValue.isNil:
        result.repeated = boolLiteral(repeatedValue, result.repeated)
  else:
    error("unsupported CLI parameter DSL form: " & node.repr, node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line

proc parseCommand(packageName, executableName: string;
    node: NimNode): CliCommandDef =
  let loc = lineFile(node)
  result.name = stringLiteral(node[1])
  result.providerEntrypointId =
    packageName & "." & executableName & "." & result.name
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  let body = node[2]
  for stmt in body:
    let name = calleeName(stmt).normalize
    if name == "pos" or name == "flag":
      result.params.add(parseParam(stmt))

proc parseExecutable(packageName: string; node: NimNode): ExecutableDef =
  let loc = lineFile(node)
  result.exportName = identText(node[1])
  result.binaryName = result.exportName
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  let body = node[2]
  for stmt in body:
    case calleeName(stmt).normalize
    of "name":
      result.binaryName = stringLiteral(stmt[1])
    of "cli":
      let cliBody = stmt[1]
      for cliStmt in cliBody:
        if calleeName(cliStmt).normalize == "subcmd":
          result.commands.add(parseCommand(packageName, result.exportName, cliStmt))
    else:
      discard

proc selectorFromConstraint(value: string): string =
  let parts = value.strip().splitWhitespace()
  if parts.len == 0:
    ""
  else:
    parts[0]

proc selectorModuleName(selector: string): string =
  var previousWasWord = false
  for ch in selector:
    if ch.isAlphaNumeric():
      if ch.isUpperAscii() and previousWasWord and
          result.len > 0 and result[^1] != '_':
        result.add('_')
      result.add(ch.toLowerAscii())
      previousWasWord = true
    else:
      if result.len > 0 and result[^1] != '_':
        result.add('_')
      previousWasWord = false
  while result.len > 0 and result[^1] == '_':
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "package"

proc normalizedImportBase(path: string): string =
  result = path.replace('\\', '/').strip()
  while result.endsWith("/") and result.len > 0:
    result.setLen(result.len - 1)

proc collectUses(node: NimNode; policyPath: seq[string];
                 output: var seq[PackageUseDef]) =
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    let loc = lineFile(node)
    let selector = selectorFromConstraint(node.strVal)
    output.add(PackageUseDef(
      rawConstraint: node.strVal,
      packageSelector: selector,
      executableName: selector,
      policyPath: policyPath,
      sourceFile: loc.file,
      sourceLine: loc.line))
  of nnkStmtList:
    for child in node:
      collectUses(child, policyPath, output)
  of nnkCall, nnkCommand:
    let name = calleeName(node)
    if node.len > 0 and name.len > 0:
      for i in 1 ..< node.len:
        if node[i].kind == nnkStmtList:
          collectUses(node[i], policyPath & @[name], output)
        else:
          collectUses(node[i], policyPath, output)
  else:
    discard

proc parsePackageDef(name: NimNode; body: NimNode): PackageDef =
  let loc = lineFile(name)
  result.packageName = identText(name)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for stmt in body:
    if calleeName(stmt).normalize == "executable":
      result.executables.add(parseExecutable(result.packageName, stmt))
    elif calleeName(stmt).normalize == "uses":
      for i in 1 ..< stmt.len:
        collectUses(stmt[i], @[], result.toolUses)
    elif calleeName(stmt).normalize == "usesimportpath":
      if stmt.len != 2:
        error("usesImportPath expects exactly one string literal", stmt)
      result.usesImportPaths.add(stringLiteral(stmt[1]))

proc escForCode(text: string): string =
  text.escape()

proc packageLiteral(pkg: PackageDef): string =
  result = "PackageDef(packageName: " & escForCode(pkg.packageName) &
    ", usesImportPaths: @["
  for pathIndex, path in pkg.usesImportPaths:
    if pathIndex > 0:
      result.add(", ")
    result.add(escForCode(path))
  result.add("], publicSignatureDependencies: @[], sourceFile: " & escForCode(
      pkg.sourceFile) &
    ", sourceLine: " & $pkg.sourceLine & ", toolUses: @[")
  for useIndex, useDef in pkg.toolUses:
    if useIndex > 0:
      result.add(", ")
    result.add("PackageUseDef(rawConstraint: " & escForCode(
        useDef.rawConstraint) &
      ", packageSelector: " & escForCode(useDef.packageSelector) &
      ", executableName: " & escForCode(useDef.executableName) &
      ", policyPath: @[")
    for policyIndex, policy in useDef.policyPath:
      if policyIndex > 0:
        result.add(", ")
      result.add(escForCode(policy))
    result.add("], sourceFile: " & escForCode(useDef.sourceFile) &
      ", sourceLine: " & $useDef.sourceLine & ")")
  result.add("], executables: @[")
  for exeIndex, exe in pkg.executables:
    if exeIndex > 0:
      result.add(", ")
    result.add("ExecutableDef(exportName: " & escForCode(exe.exportName) &
      ", binaryName: " & escForCode(exe.binaryName) &
      ", sourceFile: " & escForCode(exe.sourceFile) &
      ", sourceLine: " & $exe.sourceLine & ", commands: @[")
    for cmdIndex, cmd in exe.commands:
      if cmdIndex > 0:
        result.add(", ")
      result.add("CliCommandDef(name: " & escForCode(cmd.name) &
        ", providerEntrypointId: " & escForCode(cmd.providerEntrypointId) &
        ", sourceFile: " & escForCode(cmd.sourceFile) &
        ", sourceLine: " & $cmd.sourceLine & ", params: @[")
      for paramIndex, param in cmd.params:
        if paramIndex > 0:
          result.add(", ")
        result.add("CliParamDef(name: " & escForCode(param.name) &
          ", nimType: " & escForCode(param.nimType) &
          ", kind: " & $param.kind &
          ", role: " & $param.role &
          ", format: " & $param.format &
          ", repeated: " & $param.repeated &
          ", position: " & $param.position &
          ", alias: " & escForCode(param.alias) &
          ", required: " & $param.required &
          ", sourceFile: " & escForCode(param.sourceFile) &
          ", sourceLine: " & $param.sourceLine & ")")
      result.add("])")
    result.add("])")
  result.add("])")

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

proc argBuilder(param: CliParamDef): string =
  let kindCode =
    if param.kind == cpkPositional:
      "cpkPositional"
    else:
      "cpkFlag"
  let helper =
    case param.role
    of carInput:
      if param.nimType.normalize == "seq[string]": "inputArgSeq" else: "inputArg"
    of carOutput:
      if param.nimType.normalize == "seq[string]": "outputArgSeq" else: "outputArg"
    of carOrdinary:
      if param.nimType.normalize == "seq[string]": "cliArgSeq" else: "cliArg"
  let metaArgs = ", " & kindCode & ", " & $param.position & ", " &
    escForCode(param.alias) & ", " & $param.format & ", " & $param.repeated
  if param.nimType.normalize == "seq[string]":
    helper & "(\"" & param.name & "\", " & param.name & metaArgs & ")"
  else:
    helper & "(\"" & param.name & "\", " & param.name & metaArgs & ")"

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

proc titleIdent(text: string): string =
  if text.len == 0:
    "Package"
  else:
    text[0].toUpperAscii() & text.substr(1) & "Package"

proc wrapperCode(pkg: PackageDef): string =
  let typeName = titleIdent(pkg.packageName)
  let exeTypeName = typeName & "Executable"
  result = "type\n  " & typeName & "* = object\n" &
    "  " & exeTypeName & "* = object\n" &
    "    value*: SelectedExecutable\n" &
    "const " & pkg.packageName & "* = " & typeName & "()\n" &
    "proc reprobuildPackageMarker*() = discard\n" &
    "proc executable*(pkg: " & typeName & "; name: string): " &
      exeTypeName & " =\n" &
    "  discard pkg\n" &
    "  " & exeTypeName & "(value: selectedExecutable(" &
      escForCode(pkg.packageName) & ", name))\n"
  var selectedCommands: seq[string] = @[]
  for exe in pkg.executables:
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
      result.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      result.add("  publicCliCall(exe.value.packageName, " &
        "exe.value.executableName, " & escForCode(cmd.name) &
        ", exe.value.packageName & \".\" & exe.value.executableName & \".\" & " &
        escForCode(cmd.name) & ", @[" & argCalls.join(", ") & "])\n")
  if pkg.executables.len == 1:
    let exe = pkg.executables[0]
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
      result.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      result.add("  discard pkg\n")
      result.add("  publicCliCall(" & escForCode(pkg.packageName) & ", " &
        escForCode(exe.binaryName) & ", " & escForCode(cmd.name) & ", " &
        escForCode(cmd.providerEntrypointId) & ", @[" & argCalls.join(", ") &
        "])\n")
      let directParams =
        if params.len > 1:
          params[1 .. ^1].join("; ")
        else:
          ""
      result.add("proc " & procName & "*(" & directParams &
        "): PublicCliCall =\n")
      result.add("  publicCliCall(" & escForCode(pkg.packageName) & ", " &
        escForCode(exe.binaryName) & ", " & escForCode(cmd.name) & ", " &
        escForCode(cmd.providerEntrypointId) & ", @[" & argCalls.join(", ") &
        "])\n")

proc usesImportCode(pkg: PackageDef): string =
  var modules: seq[string] = @[]
  for base in pkg.usesImportPaths:
    let normalizedBase = normalizedImportBase(base)
    if normalizedBase.len == 0:
      continue
    for useDef in pkg.toolUses:
      let modulePath = normalizedBase & "/" &
        selectorModuleName(useDef.packageSelector)
      if modules.find(modulePath) < 0:
        modules.add(modulePath)
  for modulePath in modules:
    let moduleName = modulePath.split('/')[^1]
    let moduleAlias = moduleName & "_module"
    result.add("import " & modulePath & " as " & moduleAlias & "\n")
    result.add("when compiles(" & moduleAlias &
      ".reprobuildPackageMarker()):\n")
    result.add("  " & moduleAlias & ".reprobuildPackageMarker()\n")

proc parseInterfaceParam(node: NimNode): CliParamDef =
  let kindName = calleeName(node).normalize
  if node.len < 2:
    error("CLI parameter requires a name", node)
  result.name = identText(node[1])
  case kindName
  of "pos":
    if node.len < 3:
      error("pos requires a type", node)
    result.kind = cpkPositional
    result.nimType = node[2].repr
    result.required = true
  of "flag":
    if node.len < 3:
      error("flag requires a type", node)
    result.kind = cpkFlag
    result.nimType = node[2].repr
    result.required = false
  of "boolflag":
    result.kind = cpkFlag
    result.nimType = "bool"
    result.required = false
  else:
    error("CLI command bodies accept pos/flag/boolFlag statements", node)

  let loc = lineFile(node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for i in 2 ..< node.len:
    if kindName in ["pos", "flag"] and i == 2:
      continue
    let aliasValue = namedValue(node[i], "alias")
    if not aliasValue.isNil:
      result.alias = stringLiteral(aliasValue)
    let requiredValue = namedValue(node[i], "required")
    if not requiredValue.isNil:
      result.required = boolLiteral(requiredValue, result.required)
    let positionValue = namedValue(node[i], "position")
    if not positionValue.isNil:
      result.position = intLiteral(positionValue, result.position)
    let roleValue = namedValue(node[i], "role")
    if not roleValue.isNil:
      result.role = roleLiteral(roleValue, result.role)
    let formatValue = namedValue(node[i], "format")
    if not formatValue.isNil:
      result.format = formatLiteral(formatValue, result.format)
    let repeatedValue = namedValue(node[i], "repeated")
    if not repeatedValue.isNil:
      result.repeated = boolLiteral(repeatedValue, result.repeated)

proc parseInterfaceCommand(toolId: string; node: NimNode): CliCommandDef =
  let loc = lineFile(node)
  let head = calleeName(node).normalize
  case head
  of "call":
    result.name = ""
  of "subcmd":
    if node.len < 3:
      error("subcmd requires a string name and a body", node)
    result.name = stringLiteral(node[1])
  else:
    error("CLI interface accepts call: or subcmd \"name\": sections", node)
  result.providerEntrypointId =
    if result.name.len == 0: toolId & ".call" else: toolId & "." & result.name
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  let body = node[node.len - 1]
  for stmt in body:
    let name = calleeName(stmt).normalize
    if name in ["pos", "flag", "boolflag"]:
      result.params.add(parseInterfaceParam(stmt))
    else:
      error("CLI command bodies accept pos/flag/boolFlag statements", stmt)

proc cliArgHelperName(param: CliParamDef): string =
  case param.role
  of carInput:
    if param.nimType.normalize == "seq[string]": "inputArgSeq" else: "inputArg"
  of carOutput:
    if param.nimType.normalize == "seq[string]": "outputArgSeq" else: "outputArg"
  of carOrdinary:
    if param.nimType.normalize == "seq[string]": "cliArgSeq" else: "cliArg"

proc interfaceParamDefault(param: CliParamDef): string =
  if param.required:
    return ""
  nimDefault(param.nimType)

proc interfaceFormal(param: CliParamDef): string =
  result = param.name & ": " & param.nimType
  let defaultValue = interfaceParamDefault(param)
  if defaultValue.len > 0:
    result.add(" = " & defaultValue)

proc interfaceArgExpr(param: CliParamDef): string =
  let kindCode =
    if param.kind == cpkPositional: "cpkPositional" else: "cpkFlag"
  cliArgHelperName(param) & "(" & escForCode(param.name) & ", " &
    param.name & ", " & kindCode & ", " & $param.position & ", " &
    escForCode(param.alias) & ", " & $param.format & ", " &
    $param.repeated & ")"

proc shouldRecordCondition(param: CliParamDef): string =
  if param.required:
    return "true"
  case param.nimType.normalize
  of "bool":
    param.name
  of "int":
    param.name & " != 0"
  of "seq[string]":
    param.name & ".len > 0"
  else:
    param.name & ".len > 0"

proc interfaceProcName(command: CliCommandDef): string =
  if command.name.len == 0:
    "`()`"
  else:
    commandProcName(command.name)

proc defineCliInterfaceCode(toolSymbol, toolId: string;
                            commands: openArray[CliCommandDef]): string =
  result = "{.experimental: \"callOperator\".}\n"
  result.add("const " & toolSymbol & "* = Tool[" & escForCode(toolId) &
    "]()\n")
  result.add("proc reprobuildPackageMarker*() = discard\n")
  for command in commands:
    var formals = @["tool: Tool[" & escForCode(toolId) & "]"]
    for param in command.params:
      formals.add(interfaceFormal(param))
    formals.add("actionId = \"\"")
    formals.add("deps: openArray[string] = []")
    formals.add("extraInputs: openArray[string] = []")
    formals.add("extraOutputs: openArray[string] = []")
    formals.add("depfile = \"\"")
    formals.add("cacheable = true")
    formals.add("commandStatsId = \"\"")
    formals.add("dependencyPolicy = defaultDependencyPolicy()")
    result.add("proc " & interfaceProcName(command) & "*( " &
      formals.join("; ") & "): BuildActionDef {.discardable.} =\n")
    result.add("  discard tool\n")
    result.add("  var cliArgs: seq[PublicCliArg] = @[]\n")
    for param in command.params:
      result.add("  if " & shouldRecordCondition(param) & ":\n")
      result.add("    cliArgs.add(" & interfaceArgExpr(param) & ")\n")
    result.add("  let call = publicCliCall(" & escForCode(toolId) & ", " &
      escForCode(toolId) & ", " & escForCode(command.name) & ", " &
      escForCode(command.providerEntrypointId) & ", cliArgs)\n")
    result.add("  let selectedActionId = if actionId.len > 0: actionId " &
      "else: defaultToolActionId(call)\n")
    result.add("  recordToolInvocation(selectedActionId, call, " &
      "deps = deps, extraInputs = extraInputs, " &
      "extraOutputs = extraOutputs, depfile = depfile, cacheable = cacheable, " &
      "commandStatsId = commandStatsId, dependencyPolicy = " &
      "dependencyPolicy)\n")

macro defineCliInterface*(toolSymbol: untyped;
                          toolId: static string;
                          body: untyped): untyped =
  if toolSymbol.kind notin {nnkIdent, nnkSym}:
    error("defineCliInterface expects a Nim identifier for the tool symbol",
      toolSymbol)
  var commands: seq[CliCommandDef] = @[]
  for stmt in body:
    let head = calleeName(stmt).normalize
    case head
    of "call", "subcmd":
      commands.add(parseInterfaceCommand(toolId, stmt))
    of "policy":
      discard
    else:
      error("CLI interface accepts call: or subcmd \"name\": sections", stmt)
  result = parseStmt(defineCliInterfaceCode(identText(toolSymbol), toolId,
    commands))

when defined(reproProviderMode):
  proc providerBodyHash(pkg: PackageDef): string =
    pkg.packageName & ".build.v1"

  proc rootEntryPointId(pkg: PackageDef): string =
    pkg.packageName & ".root"

  proc sanitizeNodePart(value: string): string =
    for ch in value:
      if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
          ch in {'-', '_', '.'}:
        result.add(ch)
      else:
        result.add('_')
    if result.len == 0:
      result = "node"

  proc providerManifest(pkg: PackageDef; providerArtifactId: string): ProviderManifest =
    ProviderManifest(
      providerArtifactId: providerArtifactId,
      protocolVersion: ProviderProtocolVersion,
      entryPoints: @[
        GraphEntryPointDescriptor(
          id: rootEntryPointId(pkg),
          kind: gpkProjectRoot,
          stableName: pkg.packageName,
          bodyHash: providerBodyHash(pkg),
          argumentSchemaId: "reprobuild.project-root.v1",
          outputSchemaId: "reprobuild.graph-fragment.v1")
      ])

  proc actionNode(namespace, id: string): string =
    namespace & ":action:" & sanitizeNodePart(id)

  proc outputNode(namespace, actionId, output: string): string =
    namespace & ":output:" & sanitizeNodePart(actionId) & ":" &
      sanitizeNodePart(output)

  proc defaultBuildActionNode(namespace: string): string =
    namespace & ":metadata:default-build-action"

  proc buildPackageFragment(pkg: PackageDef; request: ProviderGraphRequest;
                            buildProc: proc ()): GraphFragment =
    resetBuildActionRegistry()
    resetDefaultBuildActionRegistry()
    resetProviderEvaluationInputRegistry()
    currentProviderProjectRoot = request.arguments
    try:
      buildProc()
    finally:
      currentProviderProjectRoot = ""
    let actions = inferDeclaredActionDeps(
      registeredBuildActions(), request.arguments)
    let defaultAction = registeredDefaultBuildAction()
    result = GraphFragment(
      entryPointId: request.entryPointId,
      entryPointBodyHash: request.entryPointBodyHash,
      arguments: request.arguments,
      namespace: request.namespace)
    if fileExists(pkg.sourceFile):
      result.evaluationInputs.add(fileReadInput(pkg.sourceFile))
    for input in registeredProviderEvaluationInputs():
      result.evaluationInputs.add(input)
    for action in actions:
      let nodeId = actionNode(request.namespace, action.id)
      result.nodes.add(GraphNode(
        id: nodeId,
        kind: gnkAction,
        stableName: action.id,
        payload: actionPayload(action)))
    if defaultAction.len > 0:
      var found = false
      for action in actions:
        if action.id == defaultAction:
          found = true
          break
      if not found:
        raise newException(ValueError,
          "default build action does not match a declared build action: " &
            defaultAction)
      result.nodes.add(GraphNode(
        id: defaultBuildActionNode(request.namespace),
        kind: gnkMetadata,
        stableName: "reprobuild.default-build-action.v1",
        payload: defaultAction))
    for action in actions:
      let nodeId = actionNode(request.namespace, action.id)
      for dep in action.deps:
        result.edges.add(GraphEdge(
          id: request.namespace & ":dep:" & sanitizeNodePart(action.id) & ":" &
            sanitizeNodePart(dep),
          kind: gekDependsOn,
          fromNode: nodeId,
          toNode: actionNode(request.namespace, dep)))
      for output in action.outputs:
        let outNode = outputNode(request.namespace, action.id, output)
        result.nodes.add(GraphNode(
          id: outNode,
          kind: gnkGeneratedOutput,
          stableName: output,
          payload: output))
        result.edges.add(GraphEdge(
          id: request.namespace & ":produces:" & sanitizeNodePart(action.id) &
            ":" & sanitizeNodePart(output),
          kind: gekProduces,
          fromNode: nodeId,
          toNode: outNode))
        result.effectClaims.add(OwnedEffectClaim(
          kind: oekFile,
          stableName: output,
          identity: output,
          cleanupPolicy: cplDeleteWhenUnclaimed,
          payload: action.id))
    result.fragmentDigest = computeGraphFragmentDigest(result)

  proc runPackageProvider*(pkg: PackageDef; buildProc: proc ()): int =
    try:
      let paths = parseProviderProtocolArgs(commandLineParams())
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = providerManifest(pkg, request.providerArtifactId)
      case request.kind
      of prkManifest:
        writeProviderResponseFile(paths.responsePath, manifestResponse(manifest))
      of prkGraphInvocation:
        if request.entryPointId != rootEntryPointId(pkg):
          stderr.writeLine("unknown provider entry point: " & request.entryPointId)
          return 2
        writeProviderResponseFile(paths.responsePath,
          graphResponse(manifest, buildPackageFragment(pkg, request, buildProc)))
      0
    except CatchableError as err:
      stderr.writeLine("repro project provider: error: " & err.msg)
      1

proc buildCode(pkg: PackageDef; body: NimNode): NimNode =
  var buildBody = newStmtList()
  for stmt in body:
    if calleeName(stmt).normalize == "build":
      buildBody.add(stmt[1])
    elif calleeName(stmt).normalize == "executable":
      let exeBody = stmt[2]
      for exeStmt in exeBody:
        if calleeName(exeStmt).normalize == "build":
          buildBody.add(exeStmt[1])
  if buildBody.len == 0:
    return newStmtList()
  let procName = ident("build" & titleIdent(pkg.packageName))
  let pkgLiteral = parseExpr(packageLiteral(pkg))
  result = quote do:
    when not defined(reproInterfaceMode):
      proc `procName`*() =
        `buildBody`
      when defined(reproProviderMode) and isMainModule:
        quit runPackageProvider(`pkgLiteral`, `procName`)

macro package*(name: untyped; body: untyped): untyped =
  let pkg = parsePackageDef(name, body)
  let generated = parseStmt(
    usesImportCode(pkg) &
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" & wrapperCode(pkg))
  result = newStmtList()
  result.add(generated)
  result.add(buildCode(pkg, body))
