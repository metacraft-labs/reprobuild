import std/[macros, strutils]

when defined(reproProviderMode):
  import std/os
  import repro_provider_runtime

type
  BuildActionPayloadError* = object of CatchableError

  CliParamKind* = enum
    cpkPositional
    cpkFlag

  CliParamDef* = object
    name*: string
    nimType*: string
    kind*: CliParamKind
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
    publicSignatureDependencies*: seq[string]
    sourceFile*: string
    sourceLine*: int

  PublicCliArg* = object
    name*: string
    nimType*: string
    encodedValue*: string

  PublicCliCall* = object
    packageName*: string
    executableName*: string
    subcommand*: string
    providerEntrypointId*: string
    arguments*: seq[PublicCliArg]

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

var registry: seq[PackageDef] = @[]
var buildActionRegistry: seq[BuildActionDef] = @[]

const
  BuildActionPayloadMagic = [byte(ord('R')), byte(ord('B')), byte(ord('A')),
    byte(ord('P'))]
  BuildActionPayloadVersion = 1'u16

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

proc cliArg*(name: string; value: string): PublicCliArg =
  PublicCliArg(name: name, nimType: "string", encodedValue: value)

proc cliArg*(name: string; value: int): PublicCliArg =
  PublicCliArg(name: name, nimType: "int", encodedValue: $value)

proc cliArg*(name: string; value: bool): PublicCliArg =
  PublicCliArg(name: name, nimType: "bool", encodedValue: $value)

proc cliArgSeq*(name: string; value: seq[string]): PublicCliArg =
  PublicCliArg(name: name, nimType: "seq[string]", encodedValue: value.join("\x1f"))

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

proc buildAction*(id: string; call: PublicCliCall;
                  deps: openArray[string] = [];
                  inputs: openArray[string] = [];
                  outputs: openArray[string] = [];
                  depfile = "";
                  cacheable = true;
                  commandStatsId = ""): BuildActionDef =
  result = BuildActionDef(
    id: id,
    call: call,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    depfile: depfile,
    cacheable: cacheable,
    commandStatsId: if commandStatsId.len > 0: commandStatsId else: id)
  buildActionRegistry.add(result)

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
  outp.writeString(arg.encodedValue)

proc readCliArg(bytes: openArray[byte]; pos: var int): PublicCliArg =
  PublicCliArg(
    name: readString(bytes, pos),
    nimType: readString(bytes, pos),
    encodedValue: readString(bytes, pos))

proc writeCliCall(outp: var seq[byte]; call: PublicCliCall) =
  outp.writeString(call.packageName)
  outp.writeString(call.executableName)
  outp.writeString(call.subcommand)
  outp.writeString(call.providerEntrypointId)
  outp.writeU32Le(uint32(call.arguments.len))
  for arg in call.arguments:
    outp.writeCliArg(arg)

proc readCliCall(bytes: openArray[byte]; pos: var int): PublicCliCall =
  result.packageName = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.subcommand = readString(bytes, pos)
  result.providerEntrypointId = readString(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.arguments = newSeq[PublicCliArg](count)
  for i in 0 ..< count:
    result.arguments[i] = readCliArg(bytes, pos)

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
  if version != BuildActionPayloadVersion:
    raisePayload("unsupported build action payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("build action payload length mismatch")

  result.id = readString(bytes, pos)
  result.call = readCliCall(bytes, pos)
  result.deps = readStringSeq(bytes, pos)
  result.inputs = readStringSeq(bytes, pos)
  result.outputs = readStringSeq(bytes, pos)
  result.depfile = readString(bytes, pos)
  result.cacheable = readByte(bytes, pos) == 1'u8
  result.commandStatsId = readString(bytes, pos)
  if pos != bytes.len:
    raisePayload("trailing build action payload bytes")

proc actionPayload*(action: BuildActionDef): string =
  fromBytes(encodeBuildActionPayload(action))

proc callIdentity*(call: PublicCliCall): string =
  var parts = @[call.packageName, call.executableName, call.subcommand,
                call.providerEntrypointId]
  for arg in call.arguments:
    parts.add(arg.name & ":" & arg.nimType & "=" & arg.encodedValue)
  parts.join("|")

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

proc escForCode(text: string): string =
  text.escape()

proc packageLiteral(pkg: PackageDef): string =
  result = "PackageDef(packageName: " & escForCode(pkg.packageName) &
    ", publicSignatureDependencies: @[], sourceFile: " & escForCode(
        pkg.sourceFile) &
    ", sourceLine: " & $pkg.sourceLine & ", toolUses: @["
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
  if param.nimType.normalize == "seq[string]":
    "cliArgSeq(\"" & param.name & "\", " & param.name & ")"
  else:
    "cliArg(\"" & param.name & "\", " & param.name & ")"

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
      var signature = cmd.name
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
      result.add("proc " & cmd.name & "*( " & params.join("; ") &
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
      result.add("proc " & cmd.name & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      result.add("  discard pkg\n")
      result.add("  publicCliCall(" & escForCode(pkg.packageName) & ", " &
        escForCode(exe.binaryName) & ", " & escForCode(cmd.name) & ", " &
        escForCode(cmd.providerEntrypointId) & ", @[" & argCalls.join(", ") &
        "])\n")

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

  proc buildPackageFragment(pkg: PackageDef; request: ProviderGraphRequest;
                            buildProc: proc ()): GraphFragment =
    resetBuildActionRegistry()
    buildProc()
    let actions = registeredBuildActions()
    result = GraphFragment(
      entryPointId: request.entryPointId,
      entryPointBodyHash: request.entryPointBodyHash,
      arguments: request.arguments,
      namespace: request.namespace)
    if fileExists(pkg.sourceFile):
      result.evaluationInputs.add(fileReadInput(pkg.sourceFile))
    for action in actions:
      let nodeId = actionNode(request.namespace, action.id)
      result.nodes.add(GraphNode(
        id: nodeId,
        kind: gnkAction,
        stableName: action.id,
        payload: actionPayload(action)))
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
    if calleeName(stmt).normalize == "executable":
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
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" & wrapperCode(pkg))
  result = newStmtList()
  result.add(generated)
  result.add(buildCode(pkg, body))
