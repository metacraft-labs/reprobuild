import std/[macros, strutils]

type
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

var registry: seq[PackageDef] = @[]

proc resetPackageRegistry*() =
  registry.setLen(0)

proc registerPackageDef*(pkg: PackageDef) =
  registry.add(pkg)

proc registeredPackages*(): seq[PackageDef] =
  registry

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
  result = "type\n  " & typeName & "* = object\n" &
    "const " & pkg.packageName & "* = " & typeName & "()\n"
  for exe in pkg.executables:
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
  result = quote do:
    when not defined(reproInterfaceMode):
      proc `procName`*() =
        `buildBody`

macro package*(name: untyped; body: untyped): untyped =
  let pkg = parsePackageDef(name, body)
  let generated = parseStmt(
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" & wrapperCode(pkg))
  result = newStmtList()
  result.add(generated)
  result.add(buildCode(pkg, body))
