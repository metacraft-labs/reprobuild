type
  ForeachLift = object
    id: string
    bodyHash: string
    stableName: string
    procName: string
    iteratorName: string
    path: string
    iterable: NimNode
    body: NimNode

proc generatedIdentPart(text: string): string =
  for ch in text:
    if ch.isAlphaNumeric():
      result.add(ch)
    else:
      result.add("_")
  if result.len == 0:
    result = "generated"

proc foreachParts(stmt: NimNode): tuple[matched: bool; iteratorName: string;
                                        iterable: NimNode; path: string;
                                        body: NimNode] =
  if calleeName(stmt).normalize != "foreach" or stmt.len != 3:
    return
  let binding = stmt[1]
  if binding.kind != nnkInfix or binding.len != 3 or
      not binding[0].eqIdent("in"):
    error("foreach expects the form: foreach item in dirListing(\"path\"):",
      stmt)
  result.iteratorName = identText(binding[1])
  result.iterable = binding[2]
  if calleeName(result.iterable).normalize != "dirlisting" or
      result.iterable.len < 2:
    error("provider foreach currently requires dirListing(\"path\")", stmt)
  result.path = stringLiteral(result.iterable[1])
  result.body = stmt[2]
  result.matched = true

proc collectBuildStatements(pkgBody: NimNode): NimNode =
  result = newStmtList()
  for stmt in pkgBody:
    if calleeName(stmt).normalize == "build":
      for buildStmt in stmt[1]:
        result.add(buildStmt)
    elif calleeName(stmt).normalize == "executable":
      let exeBody = stmt[2]
      for exeStmt in exeBody:
        if calleeName(exeStmt).normalize == "build":
          for buildStmt in exeStmt[1]:
            result.add(buildStmt)

proc collectDevEnvStatements(pkgBody: NimNode): NimNode =
  result = newStmtList()
  for stmt in pkgBody:
    if calleeName(stmt).normalize == "devenv":
      let body = stmt[stmt.len - 1]
      for devEnvStmt in body:
        result.add(devEnvStmt)

proc liftForeachStatements(pkg: PackageDef; buildBody: NimNode):
    tuple[rootBody: NimNode; liftedProcs: NimNode; lifts: seq[ForeachLift]] =
  result.rootBody = newStmtList()
  result.liftedProcs = newStmtList()
  var index = 0
  for stmt in buildBody:
    let parts = foreachParts(stmt)
    if not parts.matched:
      result.rootBody.add(stmt)
      continue

    let suffix = generatedIdentPart(pkg.packageName) & "_" & $index & "_" &
      generatedIdentPart(parts.iteratorName)
    let procName = "foreach_" & suffix
    let entryPointId = pkg.packageName & ".foreach." & $index & "." &
      parts.iteratorName
    let bodyHash = stableHashHex(entryPointId & "\n" & parts.body.repr)
    let iterIdent = ident(parts.iteratorName)
    let procIdent = ident(procName)
    let iterable = copyNimTree(parts.iterable)
    let bodyCopy = copyNimTree(parts.body)
    let lifted = quote do:
      proc `procIdent`*(`iterIdent`: string) =
        `bodyCopy`
    result.liftedProcs.add(lifted)

    let pathLit = newLit(parts.path)
    let entryLit = newLit(entryPointId)
    let hashLit = newLit(bodyHash)
    let providerBody = quote do:
      providerDirectoryInput(`pathLit`, `entryLit`, `hashLit`)
    let loopBody = copyNimTree(parts.body)
    let loopStmt = newTree(nnkForStmt, ident(parts.iteratorName), iterable,
      loopBody)
    result.rootBody.add(quote do:
      when defined(reproProviderMode):
        `providerBody`
      else:
        `loopStmt`)

    result.lifts.add(ForeachLift(
      id: entryPointId,
      bodyHash: bodyHash,
      stableName: "foreach:" & parts.iteratorName & ":" & parts.path,
      procName: procName,
      iteratorName: parts.iteratorName,
      path: parts.path,
      iterable: copyNimTree(parts.iterable),
      body: copyNimTree(parts.body)))
    inc index

proc foreachDefsLiteral(lifts: openArray[ForeachLift]): NimNode =
  var items: seq[string] = @[]
  for lift in lifts:
    items.add("ProviderForeachDef(id: " & escForCode(lift.id) &
      ", bodyHash: " & escForCode(lift.bodyHash) &
      ", stableName: " & escForCode(lift.stableName) & ")")
  parseExpr("@[" & items.join(", ") & "]")

proc foreachDispatchCode(pkg: PackageDef; dispatchName: string;
                         lifts: openArray[ForeachLift]): NimNode =
  var code = "proc " & dispatchName &
    "(request: ProviderGraphRequest): GraphFragment =\n"
  code.add("  case request.entryPointId\n")
  for lift in lifts:
    code.add("  of " & escForCode(lift.id) & ":\n")
    code.add("    return buildPackageFragment(" & packageLiteral(pkg) &
      ", request, proc () = " & lift.procName &
      "(request.arguments), includeDefault = false)\n")
  code.add("  else:\n")
  code.add("    raise newException(ValueError, \"unknown foreach provider entry point: \" & request.entryPointId)\n")
  parseStmt(code)

proc buildCode(pkg: PackageDef; body: NimNode): NimNode =
  let buildBody = collectBuildStatements(body)
  let devEnvBody = collectDevEnvStatements(body)
  if buildBody.len == 0 and devEnvBody.len == 0:
    return newStmtList()
  let lifted = liftForeachStatements(pkg, buildBody)
  let procName = ident("build" & titleIdent(pkg.packageName))
  let devEnvProcName = ident("devEnv" & titleIdent(pkg.packageName))
  let pkgLiteral = parseExpr(packageLiteral(pkg))
  let devEnvProc =
    if devEnvBody.len > 0:
      quote do:
        when defined(reproProviderMode):
          proc `devEnvProcName`*() =
            `devEnvBody`
    else:
      newStmtList()
  if lifted.lifts.len == 0:
    let rootBody = lifted.rootBody
    result = quote do:
      when not defined(reproInterfaceMode):
        `devEnvProc`
        proc `procName`*() =
          `rootBody`
        when defined(reproProviderMode) and isMainModule:
          when compiles(`devEnvProcName`()):
            quit runPackageProvider(`pkgLiteral`, `procName`,
              devEnvProc = `devEnvProcName`)
          else:
            quit runPackageProvider(`pkgLiteral`, `procName`)
  else:
    let rootBody = lifted.rootBody
    let liftedProcs = lifted.liftedProcs
    let dispatchName = ident("dispatch" & titleIdent(pkg.packageName) &
      "Foreach")
    let dispatchProc = foreachDispatchCode(pkg, $dispatchName, lifted.lifts)
    let defsLiteral = foreachDefsLiteral(lifted.lifts)
    result = quote do:
      when not defined(reproInterfaceMode):
        `devEnvProc`
        `liftedProcs`
        proc `procName`*() =
          `rootBody`
        when defined(reproProviderMode):
          `dispatchProc`
          when isMainModule:
            when compiles(`devEnvProcName`()):
              quit runPackageProvider(`pkgLiteral`, `procName`, `defsLiteral`,
                `dispatchName`, devEnvProc = `devEnvProcName`)
            else:
              quit runPackageProvider(`pkgLiteral`, `procName`, `defsLiteral`,
                `dispatchName`)

macro package*(name: untyped; body: untyped): untyped =
  let pkg = parsePackageDef(name, body)
  let recordActions = collectBuildStatements(body).len == 0 and
    pkg.executables.len > 0
  let generated = parseStmt(
    usesImportCode(pkg) &
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" &
    wrapperCode(pkg, recordActions))
  result = newStmtList()
  result.add(generated)
  result.add(buildCode(pkg, body))
