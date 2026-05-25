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

proc placementLiteral(node: NimNode; fallback: CliArgPlacement):
    CliArgPlacement =
  let text = identText(node).normalize
  case text
  of "after", "aftersubcommand", "capaftersubcommand":
    capAfterSubcommand
  of "before", "beforesubcommand", "global", "capbeforesubcommand":
    capBeforeSubcommand
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

proc parseIsTypedHead(node: NimNode;
                      context: string): tuple[matched: bool, name: string,
                                               nimType: string] =
  if node.kind == nnkInfix and node.len == 3 and node[0].eqIdent("is"):
    result.matched = true
    result.name = identText(node[1])
    result.nimType = node[2].repr
  elif node.kind == nnkInfix:
    error(context & " uses an unsupported infix form: " & node.repr, node)

proc parseParam(node: NimNode): CliParamDef =
  let kindName = calleeName(node).normalize
  let loc = lineFile(node)
  if kindName == "pos":
    if node.len < 2:
      error("pos requires a parameter name", node)
    let head = parseIsTypedHead(node[1], "pos parameter")
    result.kind = cpkPositional
    result.name = if head.matched: head.name else: identText(node[1])
    if head.matched:
      result.nimType = head.nimType
    else:
      if node.len < 3:
        error("pos requires a type", node)
      result.nimType = node[2].repr
    result.position = 0
    result.required = true
    let optionStart =
      if head.matched or kindName == "boolflag": 2 else: 3
    for i in optionStart ..< node.len:
      let value = namedValue(node[i], "position")
      if not value.isNil:
        result.position = intLiteral(value, result.position)
      let roleValue = namedValue(node[i], "role")
      if not roleValue.isNil:
        result.role = roleLiteral(roleValue, result.role)
      let repeatedValue = namedValue(node[i], "repeated")
      if not repeatedValue.isNil:
        result.repeated = boolLiteral(repeatedValue, result.repeated)
  elif kindName == "flag" or kindName == "boolflag":
    if node.len < 2:
      error(kindName & " requires a parameter name", node)
    let head = parseIsTypedHead(node[1], kindName & " parameter")
    result.kind = cpkFlag
    result.name = if head.matched: head.name else: identText(node[1])
    if kindName == "boolflag":
      result.nimType = if head.matched: head.nimType else: "bool"
      if result.nimType.normalize != "bool":
        error("boolFlag requires bool type", node[1])
    elif head.matched:
      result.nimType = head.nimType
    else:
      if node.len < 3:
        error("flag requires a type", node)
      result.nimType = node[2].repr
    result.position = 0
    result.required = false
    let optionStart = if head.matched: 2 else: 3
    for i in optionStart ..< node.len:
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
      let placementValue = namedValue(node[i], "placement")
      if not placementValue.isNil:
        result.placement = placementLiteral(placementValue, result.placement)
      let repeatedValue = namedValue(node[i], "repeated")
      if not repeatedValue.isNil:
        result.repeated = boolLiteral(repeatedValue, result.repeated)
  else:
    error("unsupported CLI parameter DSL form: " & node.repr, node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line

proc parseCommandDependencyPolicy(node: NimNode;
                                  fallback = defaultDependencyPolicy()):
    BuildActionDependencyPolicy =
  if calleeName(node).normalize != "dependencypolicy" or node.len < 2:
    error("dependencyPolicy expects a policy name", node)
  let text = identText(node[1]).normalize
  case text
  of "default":
    result = defaultDependencyPolicy()
  of "declaredonly":
    result = declaredOnlyDependencyPolicy()
  of "automaticmonitor", "monitor":
    when defined(macosx) or defined(linux) or defined(windows):
      result = automaticMonitorPolicy()
    else:
      result = declaredOnlyDependencyPolicy()
  of "makedepfile":
    result = makeDepfilePolicy()
  else:
    result = fallback
  for i in 2 ..< node.len:
    let depfileValue = namedValue(node[i], "depfile")
    if not depfileValue.isNil:
      result.depfile = stringLiteral(depfileValue)

proc parseCommand(packageName, executableName: string; node: NimNode;
                  defaultPolicy: BuildActionDependencyPolicy;
                  commonParams: openArray[CliParamDef] = []): CliCommandDef =
  let loc = lineFile(node)
  let head = calleeName(node).normalize
  case head
  of "call":
    result.name = ""
  of "subcmd":
    result.name = stringLiteral(node[1])
  else:
    error("CLI command expects call: or subcmd \"name\":", node)
  result.providerEntrypointId =
    if result.name.len == 0:
      packageName & "." & executableName & ".call"
    else:
      packageName & "." & executableName & "." & result.name
  result.dependencyPolicy = defaultPolicy
  result.params = @commonParams
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  let body = node[node.len - 1]
  for stmt in body:
    let name = calleeName(stmt).normalize
    if name == "dependencypolicy":
      result.dependencyPolicy = parseCommandDependencyPolicy(stmt,
        result.dependencyPolicy)
    elif name == "pos" or name == "flag" or name == "boolflag":
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
      var defaultPolicy = defaultDependencyPolicy()
      var commonParams: seq[CliParamDef] = @[]
      for cliStmt in cliBody:
        let name = calleeName(cliStmt).normalize
        if name == "dependencypolicy":
          defaultPolicy = parseCommandDependencyPolicy(cliStmt, defaultPolicy)
        elif name == "flag" or name == "boolflag":
          var param = parseParam(cliStmt)
          param.placement = capBeforeSubcommand
          commonParams.add(param)
        elif name == "pos":
          error("top-level CLI parameters before subcommands must be flags",
            cliStmt)
      for cliStmt in cliBody:
        let name = calleeName(cliStmt).normalize
        if name == "call" or name == "subcmd":
          result.commands.add(parseCommand(packageName, result.exportName,
            cliStmt, defaultPolicy, commonParams))
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

proc compileTimeDefineValue(name: string): bool =
  case name.normalize
  of "linux":
    result = defined(linux)
  of "macosx", "macos", "darwin":
    result = defined(macosx)
  of "windows", "win32":
    result = defined(windows)
  of "posix":
    result = defined(posix)
  else:
    result = false

proc compileTimeConditionValue(node: NimNode): bool =
  case node.kind
  of nnkIdent:
    case identText(node).normalize
    of "true":
      true
    of "false":
      false
    else:
      false
  of nnkCall, nnkCommand:
    let name = calleeName(node).normalize
    if name == "defined" and node.len >= 2:
      compileTimeDefineValue(identText(node[1]))
    else:
      false
  of nnkPrefix:
    if node.len == 2 and identText(node[0]).normalize == "not":
      not compileTimeConditionValue(node[1])
    else:
      false
  of nnkInfix:
    if node.len == 3:
      case identText(node[0]).normalize
      of "and":
        compileTimeConditionValue(node[1]) and compileTimeConditionValue(node[2])
      of "or":
        compileTimeConditionValue(node[1]) or compileTimeConditionValue(node[2])
      else:
        false
    else:
      false
  of nnkPar:
    if node.len == 1:
      compileTimeConditionValue(node[0])
    else:
      false
  else:
    false

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
  of nnkWhenStmt:
    for branch in node:
      case branch.kind
      of nnkElifBranch:
        if branch.len >= 2 and compileTimeConditionValue(branch[0]):
          collectUses(branch[1], policyPath, output)
          break
      of nnkElse:
        if branch.len >= 1:
          collectUses(branch[0], policyPath, output)
          break
      else:
        discard
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

proc parseNixPackageProvisioning(node: NimNode): NixPackageProvisioningDef =
  let loc = lineFile(node)
  if calleeName(node).normalize != "nixpackage" or node.len < 2:
    error("provisioning expects nixPackage \"selector\", executablePath = \"bin/name\"",
      node)
  result.selector = stringLiteral(node[1])
  result.packageId = result.selector
  result.lockIdentity = result.selector
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for i in 2 ..< node.len:
    let executablePathValue = namedValue(node[i], "executablePath")
    if not executablePathValue.isNil:
      result.executablePath = stringLiteral(executablePathValue)
    let expressionFileValue = namedValue(node[i], "expressionFile")
    if not expressionFileValue.isNil:
      result.expressionFile = stringLiteral(expressionFileValue)
    let packageIdValue = namedValue(node[i], "packageId")
    if not packageIdValue.isNil:
      result.packageId = stringLiteral(packageIdValue)
    let lockIdentityValue = namedValue(node[i], "lockIdentity")
    if not lockIdentityValue.isNil:
      result.lockIdentity = stringLiteral(lockIdentityValue)
  if result.selector.len == 0:
    error("nixPackage selector must not be empty", node)
  if result.executablePath.len == 0:
    error("nixPackage requires executablePath = \"bin/name\"", node)
  if result.executablePath.isAbsolute or result.executablePath.startsWith(".."):
    error("nixPackage executablePath must be relative to the realized output",
      node)
  if result.expressionFile.len > 0 and not result.expressionFile.isAbsolute:
    result.expressionFile = loc.file.splitPath.head / result.expressionFile

proc unsafeRelativePath(value: string): bool =
  let normalized = value.replace('\\', '/')
  if normalized.len == 0 or normalized.startsWith("/"):
    return true
  for part in normalized.split('/'):
    if part == "..":
      return true

proc parseTarballProvisioning(node: NimNode): TarballProvisioningDef =
  let loc = lineFile(node)
  if calleeName(node).normalize != "tarball":
    error("provisioning expects tarball url = \"...\", sha256 = \"...\", executablePath = \"bin/name\"",
      node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  result.archiveType = "tar.gz"
  result.stripComponents = 0
  for i in 1 ..< node.len:
    let urlValue = namedValue(node[i], "url")
    if not urlValue.isNil:
      result.url = stringLiteral(urlValue)
    let mirrorValue = namedValue(node[i], "mirror")
    if not mirrorValue.isNil:
      result.mirrors.add(stringLiteral(mirrorValue))
    let sha256Value = namedValue(node[i], "sha256")
    if not sha256Value.isNil:
      result.sha256 = stringLiteral(sha256Value)
    let archiveTypeValue = namedValue(node[i], "archiveType")
    if not archiveTypeValue.isNil:
      result.archiveType = stringLiteral(archiveTypeValue)
    let executablePathValue = namedValue(node[i], "executablePath")
    if not executablePathValue.isNil:
      result.executablePath = stringLiteral(executablePathValue)
    let stripComponentsValue = namedValue(node[i], "stripComponents")
    if not stripComponentsValue.isNil:
      result.stripComponents = intLiteral(stripComponentsValue, 0)
    let packageIdValue = namedValue(node[i], "packageId")
    if not packageIdValue.isNil:
      result.packageId = stringLiteral(packageIdValue)
    let lockIdentityValue = namedValue(node[i], "lockIdentity")
    if not lockIdentityValue.isNil:
      result.lockIdentity = stringLiteral(lockIdentityValue)
  if result.url.len == 0:
    error("tarball requires url = \"...\"", node)
  if result.sha256.len == 0:
    error("tarball requires sha256 = \"...\"", node)
  if result.executablePath.len == 0:
    error("tarball requires executablePath = \"bin/name\"", node)
  if result.executablePath.unsafeRelativePath:
    error("tarball executablePath must be relative to the realized prefix", node)
  if result.stripComponents < 0:
    error("tarball stripComponents must not be negative", node)
  if result.packageId.len == 0:
    result.packageId = result.url
  if result.lockIdentity.len == 0:
    result.lockIdentity = "sha256:" & result.sha256

proc parseScoopProvisioning(node: NimNode): ScoopProvisioningDef =
  let loc = lineFile(node)
  if calleeName(node).normalize != "scoopapp":
    error("provisioning expects scoopApp bucket = \"main\", app = \"ripgrep\", " &
      "version = \"14.1.0\", executablePath = \"<exe>\"", node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  result.requiresExecutionProfileChecksum = true
  for i in 1 ..< node.len:
    let bucketValue = namedValue(node[i], "bucket")
    if not bucketValue.isNil:
      result.bucket = stringLiteral(bucketValue)
    let appValue = namedValue(node[i], "app")
    if not appValue.isNil:
      result.app = stringLiteral(appValue)
    let versionValue = namedValue(node[i], "version")
    if not versionValue.isNil:
      result.version = stringLiteral(versionValue)
    let preferredVersionValue = namedValue(node[i], "preferredVersion")
    if not preferredVersionValue.isNil:
      result.preferredVersion = stringLiteral(preferredVersionValue)
    let manifestChecksumValue = namedValue(node[i], "manifestChecksum")
    if not manifestChecksumValue.isNil:
      result.manifestChecksum = stringLiteral(manifestChecksumValue)
    let manifestUrlValue = namedValue(node[i], "manifestUrl")
    if not manifestUrlValue.isNil:
      result.manifestUrl = stringLiteral(manifestUrlValue)
    let executablePathValue = namedValue(node[i], "executablePath")
    if not executablePathValue.isNil:
      result.executablePath = stringLiteral(executablePathValue)
    let requiresExecProfileValue = namedValue(node[i],
      "requiresExecutionProfileChecksum")
    if not requiresExecProfileValue.isNil:
      result.requiresExecutionProfileChecksum = boolLiteral(
        requiresExecProfileValue, true)
    let packageIdValue = namedValue(node[i], "packageId")
    if not packageIdValue.isNil:
      result.packageId = stringLiteral(packageIdValue)
    let lockIdentityValue = namedValue(node[i], "lockIdentity")
    if not lockIdentityValue.isNil:
      result.lockIdentity = stringLiteral(lockIdentityValue)
  if result.bucket.len == 0:
    error("scoopApp requires bucket = \"<name>\"", node)
  if result.app.len == 0:
    error("scoopApp requires app = \"<name>\"", node)
  if result.version.len > 0 and result.preferredVersion.len > 0:
    error("scoopApp accepts version OR preferredVersion, not both", node)
  if result.version.len == 0 and result.preferredVersion.len == 0:
    error("scoopApp requires version = \"<exact>\" or preferredVersion = " &
      "\"<range>\"", node)
  if result.executablePath.len == 0:
    error("scoopApp requires executablePath = \"<relative-path>\"", node)
  if result.executablePath.unsafeRelativePath:
    error("scoopApp executablePath must be a relative path inside the " &
      "Scoop app prefix", node)
  if result.packageId.len == 0:
    result.packageId =
      if result.version.len > 0:
        result.bucket & "/" & result.app & "@" & result.version
      else:
        result.bucket & "/" & result.app & "@" & result.preferredVersion
  if result.lockIdentity.len == 0:
    result.lockIdentity =
      if result.manifestChecksum.len > 0:
        "scoop:" & result.bucket & "/" & result.app & ":" &
          result.manifestChecksum
      elif result.version.len > 0:
        "scoop:" & result.bucket & "/" & result.app & "@" & result.version
      else:
        "scoop:" & result.bucket & "/" & result.app & "@" &
          result.preferredVersion

proc collectProvisioning(node: NimNode;
                         nixOutput: var seq[NixPackageProvisioningDef];
                         tarballOutput: var seq[TarballProvisioningDef];
                         scoopOutput: var seq[ScoopProvisioningDef]) =
  case node.kind
  of nnkStmtList:
    for child in node:
      collectProvisioning(child, nixOutput, tarballOutput, scoopOutput)
  of nnkCall, nnkCommand:
    if calleeName(node).normalize == "nixpackage":
      nixOutput.add(parseNixPackageProvisioning(node))
    elif calleeName(node).normalize == "tarball":
      tarballOutput.add(parseTarballProvisioning(node))
    elif calleeName(node).normalize == "scoopapp":
      scoopOutput.add(parseScoopProvisioning(node))
    else:
      error("unsupported provisioning form: " & node.repr, node)
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
    elif calleeName(stmt).normalize == "provisioning":
      if stmt.len < 2:
        error("provisioning expects a body", stmt)
      collectProvisioning(stmt[stmt.len - 1], result.nixProvisioning,
        result.tarballProvisioning, result.scoopProvisioning)
    elif calleeName(stmt).normalize == "usesimportpath":
      if stmt.len != 2:
        error("usesImportPath expects exactly one string literal", stmt)
      result.usesImportPaths.add(stringLiteral(stmt[1]))
    elif calleeName(stmt).normalize == "devenv":
      if stmt.len < 2:
        error("devEnv expects a body", stmt)
      result.hasDevEnv = true
      result.devEnvBodyHash = stableHashHex(result.packageName & ".dev-env\n" &
        stmt[stmt.len - 1].repr)

proc escForCode(text: string): string =
  text.escape()

proc dependencyPolicyCode(policy: BuildActionDependencyPolicy): string =
  case policy.kind
  of bdpDefault:
    "defaultDependencyPolicy()"
  of bdpDeclaredOnly:
    "declaredOnlyDependencyPolicy()"
  of bdpAutomaticMonitor:
    "automaticMonitorPolicy()"
  of bdpMakeDepfile:
    "makeDepfilePolicy(" & escForCode(policy.depfile) & ")"

proc packageLiteral(pkg: PackageDef): string =
  result = "PackageDef(packageName: " & escForCode(pkg.packageName) &
    ", nixProvisioning: @["
  for provisioningIndex, provisioning in pkg.nixProvisioning:
    if provisioningIndex > 0:
      result.add(", ")
    result.add("NixPackageProvisioningDef(selector: " & escForCode(
        provisioning.selector) &
      ", executablePath: " & escForCode(provisioning.executablePath) &
      ", expressionFile: " & escForCode(provisioning.expressionFile) &
      ", packageId: " & escForCode(provisioning.packageId) &
      ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], tarballProvisioning: @[")
  for provisioningIndex, provisioning in pkg.tarballProvisioning:
    if provisioningIndex > 0:
      result.add(", ")
    result.add("TarballProvisioningDef(url: " & escForCode(provisioning.url) &
      ", mirrors: @[")
    for mirrorIndex, mirror in provisioning.mirrors:
      if mirrorIndex > 0:
        result.add(", ")
      result.add(escForCode(mirror))
    result.add("], sha256: " & escForCode(provisioning.sha256) &
      ", archiveType: " & escForCode(provisioning.archiveType) &
      ", executablePath: " & escForCode(provisioning.executablePath) &
      ", stripComponents: " & $provisioning.stripComponents &
      ", packageId: " & escForCode(provisioning.packageId) &
      ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], scoopProvisioning: @[")
  for provisioningIndex, provisioning in pkg.scoopProvisioning:
    if provisioningIndex > 0:
      result.add(", ")
    result.add("ScoopProvisioningDef(bucket: " & escForCode(provisioning.bucket) &
      ", app: " & escForCode(provisioning.app) &
      ", version: " & escForCode(provisioning.version) &
      ", preferredVersion: " & escForCode(provisioning.preferredVersion) &
      ", manifestChecksum: " & escForCode(provisioning.manifestChecksum) &
      ", manifestUrl: " & escForCode(provisioning.manifestUrl) &
      ", executablePath: " & escForCode(provisioning.executablePath) &
      ", requiresExecutionProfileChecksum: " &
        $provisioning.requiresExecutionProfileChecksum &
      ", packageId: " & escForCode(provisioning.packageId) &
      ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], usesImportPaths: @[")
  for pathIndex, path in pkg.usesImportPaths:
    if pathIndex > 0:
      result.add(", ")
    result.add(escForCode(path))
  result.add("], publicSignatureDependencies: @[], sourceFile: " & escForCode(
      pkg.sourceFile) &
    ", sourceLine: " & $pkg.sourceLine &
    ", hasDevEnv: " & $pkg.hasDevEnv &
    ", devEnvBodyHash: " & escForCode(pkg.devEnvBodyHash) &
    ", toolUses: @[")
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
        ", dependencyPolicy: " & dependencyPolicyCode(cmd.dependencyPolicy) &
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
          ", placement: " & $param.placement &
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
    escForCode(param.alias) & ", " & $param.format & ", " &
    $param.placement & ", " & $param.repeated
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
  let normalized = selectorModuleName(text)
  if normalized.len == 0:
    return "Package"
  var capitalizeNext = true
  for ch in normalized:
    if ch == '_':
      capitalizeNext = true
    elif capitalizeNext:
      result.add(ch.toUpperAscii())
      capitalizeNext = false
    else:
      result.add(ch)
  result.add("Package")

proc packageValueIdent(text: string): string =
  selectorModuleName(text)

proc commandCallableName(cmdName: string): string =
  if cmdName.len == 0:
    "`()`"
  else:
    commandProcName(cmdName)

proc shouldEmitArgCondition(param: CliParamDef): string =
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

proc toolActionFormal(param: CliParamDef): string =
  result = param.name & ": " & param.nimType
  if not param.required:
    result.add(" = " & nimDefault(param.nimType))

proc toolActionArgExpr(param: CliParamDef): string =
  argBuilder(param)

proc toolActionWrapperCode(pkg: PackageDef): string =
  let typeName = titleIdent(pkg.packageName)
  let valueName = packageValueIdent(pkg.packageName)
  result = "{.experimental: \"callOperator\".}\n"
  result.add("type\n  " & typeName & "* = object\n")
  result.add("const " & valueName & "* = " & typeName & "()\n")
  result.add("proc reprobuildPackageMarker*() = discard\n")
  if pkg.executables.len != 1:
    return
  let exe = pkg.executables[0]
  for cmd in exe.commands:
    var formals = @["pkg: " & typeName]
    for param in cmd.params:
      formals.add(toolActionFormal(param))
    formals.add("actionId = \"\"")
    formals.add("deps: openArray[string] = []")
    formals.add("after: openArray[BuildActionDef] = []")
    formals.add("extraInputs: openArray[string] = []")
    formals.add("extraOutputs: openArray[string] = []")
    formals.add("depfile = \"\"")
    formals.add("cacheable = true")
    formals.add("actionCachePolicy = defaultActionCachePolicy()")
    formals.add("commandStatsId = \"\"")
    result.add("proc " & commandCallableName(cmd.name) & "*( " &
      formals.join("; ") & "): BuildActionDef {.discardable.} =\n")
    result.add("  discard pkg\n")
    result.add("  var cliArgs: seq[PublicCliArg] = @[]\n")
    for param in cmd.params:
      result.add("  if " & shouldEmitArgCondition(param) & ":\n")
      result.add("    cliArgs.add(" & toolActionArgExpr(param) & ")\n")
    result.add("  let call = publicCliCall(" & escForCode(pkg.packageName) &
      ", " & escForCode(exe.binaryName) & ", " & escForCode(cmd.name) &
      ", " & escForCode(cmd.providerEntrypointId) & ", cliArgs)\n")
    result.add("  let selectedActionId = if actionId.len > 0: actionId " &
      "else: defaultToolActionId(call)\n")
    result.add("  recordToolInvocation(selectedActionId, call, " &
      "deps = combineActionDeps(deps, after), extraInputs = extraInputs, " &
      "extraOutputs = extraOutputs, depfile = depfile, cacheable = cacheable, " &
      "commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy, " &
      "dependencyPolicy = " &
      dependencyPolicyCode(cmd.dependencyPolicy) & ")\n")

proc wrapperCode(pkg: PackageDef; recordActions = false): string =
  if recordActions:
    return toolActionWrapperCode(pkg)
  let typeName = titleIdent(pkg.packageName)
  let exeTypeName = typeName & "Executable"
  let valueName = packageValueIdent(pkg.packageName)
  var prefix = ""
  block:
    var hasCallCommand = false
    for exe in pkg.executables:
      for cmd in exe.commands:
        if cmd.name.len == 0:
          hasCallCommand = true
    if hasCallCommand:
      prefix = "{.experimental: \"callOperator\".}\n"
  result = prefix & "type\n  " & typeName & "* = object\n" &
    "  " & exeTypeName & "* = object\n" &
    "    value*: SelectedExecutable\n" &
    "const " & valueName & "* = " & typeName & "()\n" &
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
      result.add("proc " & commandCallableName(cmd.name) & "*( " &
        params.join("; ") &
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
      result.add("proc " & commandCallableName(cmd.name) & "*( " &
        params.join("; ") &
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
      if cmd.name.len > 0:
        result.add("proc " & commandCallableName(cmd.name) & "*(" & directParams &
          "): PublicCliCall =\n")
        result.add("  publicCliCall(" & escForCode(pkg.packageName) & ", " &
          escForCode(exe.binaryName) & ", " & escForCode(cmd.name) & ", " &
          escForCode(cmd.providerEntrypointId) & ", @[" & argCalls.join(", ") &
          "])\n")

proc usesImportCode(pkg: PackageDef): string =
  proc isBundledStdlibSelector(selector: string): bool =
    selector in [
      "bash",
      "bpftrace",
      "bpftool",
      "cachix",
      "capnp",
      "cargo",
      "cargo-nextest",
      "clang",
      "ctags",
      "curl",
      "dpkg",
      "electron",
      "emcc",
      "flake8",
      "gcc",
      "gh",
      "git",
      "just",
      "llvm-config",
      "mdbook",
      "nim",
      "nimble",
      "nix",
      "node",
      "npx",
      "openssl",
      "pcre-config",
      "pkg-config",
      "playwright",
      "python3",
      "rg",
      "ruby",
      "rust-analyzer",
      "rustc",
      "rustfmt",
      "rustup",
      "sh",
      "shellcheck",
      "sqlite3",
      "stylus",
      "tmux",
      "tree-sitter",
      "tup",
      "vim",
      "wasm-opt",
      "wasm-pack",
      "webpack-cli",
      "wget",
      "xdotool",
      "xvfb-run",
      "yarn",
      "zstd"
    ]
  var modules: seq[string] = @[]
  for useDef in pkg.toolUses:
    if isBundledStdlibSelector(useDef.packageSelector):
      let modulePath = "repro_dsl_stdlib/packages/" &
        selectorModuleName(useDef.packageSelector)
      if modules.find(modulePath) < 0:
        modules.add(modulePath)
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

proc parseInterfaceParam(node: NimNode;
                         defaultPlacement = capAfterSubcommand): CliParamDef =
  let kindName = calleeName(node).normalize
  if node.len < 2:
    error("CLI parameter requires a name", node)
  let head = parseIsTypedHead(node[1], "CLI parameter")
  result.name = if head.matched: head.name else: identText(node[1])
  result.placement = defaultPlacement
  var optionStart = 2
  case kindName
  of "pos":
    result.kind = cpkPositional
    if head.matched:
      result.nimType = head.nimType
    else:
      if node.len < 3:
        error("pos requires a type", node)
      result.nimType = node[2].repr
      optionStart = 3
    result.required = true
  of "flag":
    result.kind = cpkFlag
    if head.matched:
      result.nimType = head.nimType
    else:
      if node.len < 3:
        error("flag requires a type", node)
      result.nimType = node[2].repr
      optionStart = 3
    result.required = false
  of "boolflag":
    result.kind = cpkFlag
    result.nimType = if head.matched: head.nimType else: "bool"
    if result.nimType.normalize != "bool":
      error("boolFlag requires bool type", node[1])
    result.required = false
  else:
    error("CLI command bodies accept pos/flag/boolFlag statements", node)

  let loc = lineFile(node)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for i in optionStart ..< node.len:
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
    let placementValue = namedValue(node[i], "placement")
    if not placementValue.isNil:
      result.placement = placementLiteral(placementValue, result.placement)
    let repeatedValue = namedValue(node[i], "repeated")
    if not repeatedValue.isNil:
      result.repeated = boolLiteral(repeatedValue, result.repeated)

proc dependencyPolicyLiteral(node: NimNode;
                             fallback: BuildActionDependencyPolicy):
    BuildActionDependencyPolicy =
  let text = identText(node).normalize
  case text
  of "default":
    defaultDependencyPolicy()
  of "declaredonly":
    declaredOnlyDependencyPolicy()
  of "automaticmonitor", "monitor":
    when defined(macosx) or defined(linux) or defined(windows):
      automaticMonitorPolicy()
    else:
      declaredOnlyDependencyPolicy()
  of "makedepfile":
    makeDepfilePolicy()
  else:
    fallback

proc parseInterfaceDependencyPolicy(node: NimNode;
                                    fallback = defaultDependencyPolicy()):
    BuildActionDependencyPolicy =
  if calleeName(node).normalize != "dependencypolicy" or node.len < 2:
    error("dependencyPolicy expects a policy name", node)
  result = dependencyPolicyLiteral(node[1], fallback)
  for i in 2 ..< node.len:
    let depfileValue = namedValue(node[i], "depfile")
    if not depfileValue.isNil:
      result.depfile = stringLiteral(depfileValue)

proc collectParamGroup(node: NimNode): tuple[name: string,
                                            statements: seq[NimNode]] =
  if node.kind != nnkTemplateDef:
    error("CLI parameter group must be a template definition", node)
  result.name = identText(node[0]).normalize
  if node[3].kind != nnkFormalParams or node[3].len != 1:
    error("CLI parameter group templates must not accept parameters", node[3])
  let body = node[^1]
  if body.kind != nnkStmtList:
    error("CLI parameter group template must contain a statement body", body)
  for stmt in body:
    result.statements.add(stmt)

proc expandInterfaceParamStmt(stmt: NimNode;
                              paramGroups: Table[string, seq[NimNode]];
                              stack: var seq[string]): seq[NimNode] =
  let groupName = calleeName(stmt).normalize
  if groupName.len > 0 and paramGroups.hasKey(groupName) and stmt.len == 1:
    if stack.find(groupName) >= 0:
      error("recursive CLI parameter group: " & groupName, stmt)
    stack.add(groupName)
    for groupedStmt in paramGroups[groupName]:
      for expandedStmt in expandInterfaceParamStmt(groupedStmt, paramGroups,
          stack):
        result.add(expandedStmt)
    discard stack.pop()
  else:
    result.add(stmt)

proc parseInterfaceCommand(toolId: string; node: NimNode;
                           paramGroups: Table[string, seq[NimNode]];
                           commonParams: openArray[CliParamDef];
                           defaultPolicy: BuildActionDependencyPolicy):
    CliCommandDef =
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
  result.dependencyPolicy = defaultPolicy
  result.params = @commonParams
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  let body = node[node.len - 1]
  for stmt in body:
    if calleeName(stmt).normalize == "dependencypolicy":
      result.dependencyPolicy = parseInterfaceDependencyPolicy(stmt,
        result.dependencyPolicy)
      continue
    var stack: seq[string] = @[]
    for expandedStmt in expandInterfaceParamStmt(stmt, paramGroups, stack):
      let name = calleeName(expandedStmt).normalize
      if name in ["pos", "flag", "boolflag"]:
        result.params.add(parseInterfaceParam(expandedStmt))
      else:
        error("CLI command bodies accept pos/flag/boolFlag statements",
          expandedStmt)

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
    $param.placement & ", " & $param.repeated & ")"

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
    formals.add("after: openArray[BuildActionDef] = []")
    formals.add("extraInputs: openArray[string] = []")
    formals.add("extraOutputs: openArray[string] = []")
    formals.add("depfile = \"\"")
    formals.add("cacheable = true")
    formals.add("actionCachePolicy = defaultActionCachePolicy()")
    formals.add("commandStatsId = \"\"")
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
      "deps = combineActionDeps(deps, after), extraInputs = extraInputs, " &
      "extraOutputs = extraOutputs, depfile = depfile, cacheable = cacheable, " &
      "commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy, " &
      "dependencyPolicy = " &
      dependencyPolicyCode(command.dependencyPolicy) & ")\n")

macro defineCliInterface*(toolSymbol: untyped;
                          toolId: static string;
                          body: untyped): untyped =
  if toolSymbol.kind notin {nnkIdent, nnkSym}:
    error("defineCliInterface expects a Nim identifier for the tool symbol",
      toolSymbol)
  var paramGroups: Table[string, seq[NimNode]]
  for stmt in body:
    if stmt.kind == nnkTemplateDef:
      let group = collectParamGroup(stmt)
      paramGroups[group.name] = group.statements
  var commonParams: seq[CliParamDef] = @[]
  var defaultPolicy = defaultDependencyPolicy()
  proc addCommonParams(stmt: NimNode) =
    var stack: seq[string] = @[]
    for expandedStmt in expandInterfaceParamStmt(stmt, paramGroups, stack):
      let head = calleeName(expandedStmt).normalize
      if head in ["flag", "boolflag"]:
        commonParams.add(parseInterfaceParam(expandedStmt,
          capBeforeSubcommand))
      elif head == "pos":
        error("top-level CLI parameters before subcommands must be flags",
          expandedStmt)
      else:
        error("top-level CLI interface statements accept flags, templates, " &
          "dependencyPolicy, call:, or subcmd sections", expandedStmt)
  for stmt in body:
    let head = calleeName(stmt).normalize
    if head in ["flag", "boolflag", "pos"]:
      addCommonParams(stmt)
    elif head.len > 0 and paramGroups.hasKey(head) and stmt.len == 1:
      addCommonParams(stmt)
    elif head == "dependencypolicy":
      defaultPolicy = parseInterfaceDependencyPolicy(stmt, defaultPolicy)
  var commands: seq[CliCommandDef] = @[]
  for stmt in body:
    let head = calleeName(stmt).normalize
    case head
    of "call", "subcmd":
      commands.add(parseInterfaceCommand(toolId, stmt, paramGroups,
        commonParams, defaultPolicy))
    of "flag", "boolflag", "pos", "dependencypolicy":
      discard
    of "":
      if stmt.kind == nnkTemplateDef:
        discard
      else:
        error("CLI interface accepts call: or subcmd \"name\": sections", stmt)
    of "policy":
      discard
    else:
      if paramGroups.hasKey(head) and stmt.len == 1:
        discard
      else:
        error("CLI interface accepts call: or subcmd \"name\": sections", stmt)
  result = parseStmt(defineCliInterfaceCode(identText(toolSymbol), toolId,
    commands))

