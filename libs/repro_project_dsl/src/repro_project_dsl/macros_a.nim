proc identText(node: NimNode): string =
  case node.kind
  of nnkIdent, nnkSym:
    result = $node
  of nnkAccQuoted:
    result = ""
    for child in node:
      result.add(identText(child))
  of nnkOutTy:
    # The Nim keyword ``out`` is parsed as an ``OutTy`` node when it
    # appears in a position that could begin an ``out T`` parameter
    # type annotation. In CLI parameter declarations (``flag out is
    # string``) and ``outputs`` statements the name ``out`` is a plain
    # identifier, so we project ``OutTy`` back to its literal spelling
    # rather than calling ``repr`` (which produces ``"out string"`` or
    # similar when the OutTy node has children).
    result = "out"
  else:
    result = node.repr

proc stringLiteral(node: NimNode): string =
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    result = node.strVal
  else:
    result = node.repr

proc stringSeqLiteral(node: NimNode): seq[string] =
  let values =
    if node.kind == nnkPrefix and node.len == 2 and node[0].eqIdent("@"):
      node[1]
    else:
      node
  if values.kind notin {nnkBracket, nnkPar}:
    error("expected a string sequence literal", node)
  for item in values:
    result.add(stringLiteral(item))

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
    let ignoredValue = namedValue(node[i], "ignoredInputPrefixes")
    if not ignoredValue.isNil:
      result.ignoredInputPrefixes = stringSeqLiteral(ignoredValue)

proc collectOutputsOperands(node: NimNode; sink: var seq[NimNode]) =
  ## Flatten the operand list of an ``outputs`` statement into a sequence
  ## of identifier (or AccQuoted) nodes.
  ##
  ## Nim's parser interprets the keyword ``out`` in
  ## ``outputs out depfile`` as the start of an ``out T`` parameter type
  ## annotation, producing nodes like:
  ##
  ##   Command(outputs, OutTy)              # ``outputs out``
  ##   Command(outputs, OutTy(depfile))     # ``outputs out depfile``
  ##   Command(outputs, OutTy, depfile)     # ``outputs out, depfile``
  ##   Command(outputs, Command(a, OutTy))  # ``outputs a out``
  ##
  ## Each ``OutTy`` node represents the literal flag name ``"out"``; we
  ## translate it back to an ident here and continue walking its
  ## children so the trailing flag names survive. AccQuoted survives
  ## un-parsed (so users may also write `` outputs `out` ``).
  case node.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    sink.add(node)
  of nnkOutTy:
    # Synthesise an ``out`` ident attributed to the OutTy node so the
    # source-location plumbing below stays meaningful.
    let outIdent = ident("out")
    outIdent.copyLineInfo(node)
    sink.add(outIdent)
    for child in node:
      collectOutputsOperands(child, sink)
  of nnkCommand, nnkCall, nnkPar, nnkBracket:
    for child in node:
      collectOutputsOperands(child, sink)
  else:
    sink.add(node)

proc collectDeclaredFlagNames(body: NimNode; output: var seq[string]) =
  ## Walk a ``cli:`` body (or any sub-body) and accumulate the names of
  ## every ``pos``/``flag``/``boolflag`` declaration encountered.
  ## Used by ``outputs`` validation to distinguish "declared on a sibling
  ## subcmd" (scoping error) from "does not exist" (typo).
  case body.kind
  of nnkCall, nnkCommand:
    let head = calleeName(body).normalize
    if head in ["pos", "flag", "boolflag"] and body.len >= 2:
      let parsed = parseIsTypedHead(body[1], head & " parameter")
      let paramName = if parsed.matched: parsed.name else: identText(body[1])
      output.add(paramName)
    for i in 0 ..< body.len:
      collectDeclaredFlagNames(body[i], output)
  of nnkStmtList:
    for child in body:
      collectDeclaredFlagNames(child, output)
  else:
    discard

proc typeIdentRepr(node: NimNode): string =
  ## Typed-Outputs M0: render one type identifier from the comma-separated
  ## type list of a typed ``outputs`` statement. Accepts a bare ident
  ## (``NimUnittestBinary``), a dotted ident (``cargo.CargoTestBinary``),
  ## or an arbitrary AST whose ``.repr`` is the user-facing source form.
  ## The string is what we hand to the wrapper code generator and what
  ## the field's static type resolves to at typed-tool call sites.
  case node.kind
  of nnkIdent, nnkSym:
    $node
  of nnkAccQuoted:
    var acc = ""
    for child in node:
      acc.add(typeIdentRepr(child))
    acc
  of nnkDotExpr, nnkBracketExpr:
    node.repr
  else:
    node.repr

proc isTypedOutputsHead(stmt: NimNode): bool =
  ## Typed-Outputs M0: the typed form
  ## ``outputs <fieldName> is <Type1>[, <Type2>...], <pathExpression>``
  ## is distinguished from the M0 untyped form
  ## ``outputs <flag> [<flag>...]`` by the presence of an
  ## ``Infix(is, fieldName, FirstType)`` as the first operand. The
  ## untyped form parses as a flat sequence of identifiers (with
  ## ``OutTy`` nodes standing in for the literal ``out`` keyword).
  if stmt.len < 2:
    return false
  let head = stmt[1]
  head.kind == nnkInfix and head.len == 3 and head[0].eqIdent("is")

proc parseTypedOutputsStatement(stmt: NimNode): TypedOutputDef =
  ## Typed-Outputs M0: parse one statement of the typed form
  ##
  ##   ``outputs <fieldName> is <Type1>[, <Type2>...], <pathExpression>``
  ##
  ## The first comma-separated argument is the ``Infix(is, ...)`` node
  ## carrying ``<fieldName>`` and ``<Type1>``. Subsequent operands up to
  ## the second-to-last are additional types; the last operand is the
  ## path expression, preserved verbatim (``.repr``) so M1 can
  ## ``parseExpr`` it back at action-emission time without re-running
  ## the macro.
  let loc = lineFile(stmt)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  if stmt.len < 3:
    error("typed outputs requires at least one type and a path expression, " &
      "e.g. ``outputs fieldName is SomeType, pathExpr``", stmt)
  let head = stmt[1]
  if head.kind != nnkInfix or head.len != 3 or not head[0].eqIdent("is"):
    error("typed outputs expects ``<fieldName> is <Type>`` as the first " &
      "operand", stmt)
  if head[1].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    error("typed outputs: field name must be an identifier", head[1])
  result.fieldName = identText(head[1])
  result.types.add(typeIdentRepr(head[2]))
  # Operands [2 ..< ^1] are additional type identifiers; operand [^1]
  # is the path expression. ``stmt.len`` is always >= 3 at this point
  # (the early check above), so the path operand exists.
  for i in 2 ..< stmt.len - 1:
    result.types.add(typeIdentRepr(stmt[i]))
  let pathOperand = stmt[stmt.len - 1]
  result.pathExpr = pathOperand.repr

proc parseCliScope(packageName, executableName: string; body: NimNode;
                   path: seq[string]; isRoot: bool;
                   parentParams: openArray[CliParamDef];
                   parentOutputFlags: openArray[string];
                   parentTypedOutputs: openArray[TypedOutputDef];
                   parentPolicy: BuildActionDependencyPolicy;
                   wholeBody: NimNode;
                   commands: var seq[CliCommandDef]): CliCommandDef =
  ## Named-Targets M0: walk a ``cli:`` body or a ``subcmd`` body in
  ## source order, tracking the visible-flag set so that ``outputs``
  ## statements can be validated against the lexical-scope rule on the
  ## spot. Nested ``subcmd`` bodies recurse with a snapshot of the
  ## visible set; every encountered command emits one ``CliCommandDef``
  ## into ``commands``, and the function returns the command corresponding
  ## to the current scope (an "anchor" the caller can inspect).
  ##
  ## ``wholeBody`` is the enclosing ``cli:`` body — kept so the
  ## "not in lexical scope" diagnostic can disambiguate sibling-subcmd
  ## flag references from genuinely unknown names.
  let loc = lineFile(body)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  result.path = path
  result.name =
    if path.len == 0: "" else: path[^1]
  result.providerEntrypointId =
    if result.name.len == 0:
      packageName & "." & executableName & ".call"
    else:
      packageName & "." & executableName & "." & path.join(".")
  result.dependencyPolicy = parentPolicy
  result.params = @parentParams
  result.outputFlags = @parentOutputFlags
  result.typedOutputs = @parentTypedOutputs

  for stmt in body:
    let head = calleeName(stmt).normalize
    case head
    of "dependencypolicy":
      result.dependencyPolicy = parseCommandDependencyPolicy(stmt,
        result.dependencyPolicy)
    of "pos":
      if isRoot:
        error("top-level CLI parameters before subcommands must be flags",
          stmt)
      let param = parseParam(stmt)
      result.params.add(param)
    of "flag", "boolflag":
      var param = parseParam(stmt)
      if isRoot:
        param.placement = capBeforeSubcommand
      result.params.add(param)
    of "outputs":
      # Typed-Outputs M0: distinguish the typed form
      # ``outputs <fieldName> is <Type>[, <Type>...], <pathExpression>``
      # from the Named-Targets M0 untyped form
      # ``outputs <flag> [<flag>...]``. The typed form's first operand
      # is an ``Infix(is, ...)`` node — bare flag idents never carry an
      # ``is`` infix, so the dispatch is unambiguous.
      if stmt.len < 2:
        error("outputs requires at least one flag name", stmt)
      if isTypedOutputsHead(stmt):
        let td = parseTypedOutputsStatement(stmt)
        # Disallow duplicate ``fieldName`` declarations along the
        # lexical path so the generated ``BuildEdge`` subtype has a
        # well-defined set of fields. Parent-scope inherited entries
        # are compared by ``fieldName`` to keep the rule symmetric
        # with the untyped ``outputFlags`` accumulation.
        var duplicate = false
        for existing in result.typedOutputs:
          if existing.fieldName == td.fieldName:
            duplicate = true
            break
        if not duplicate:
          result.typedOutputs.add(td)
      else:
        # Validate every named operand against the currently visible set.
        # We need a per-operand check that also detects the
        # sibling-subcmd case (`not in lexical scope` vs `does not exist`).
        var operands: seq[NimNode] = @[]
        for i in 1 ..< stmt.len:
          collectOutputsOperands(stmt[i], operands)
        if operands.len == 0:
          error("outputs requires at least one flag name", stmt)
        for operand in operands:
          if operand.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
            error("outputs expects a flag name identifier, got: " &
              operand.repr, operand)
          let flagName = identText(operand)
          var visible = false
          for param in result.params:
            if param.name == flagName:
              visible = true
              break
          if not visible:
            var declaredSomewhere: seq[string] = @[]
            collectDeclaredFlagNames(wholeBody, declaredSomewhere)
            if declaredSomewhere.find(flagName) >= 0:
              error("outputs: '" & flagName &
                "' is not in lexical scope (declared on a sibling subcmd, " &
                "not on this subcmd or an enclosing one)", stmt)
            else:
              error("outputs: '" & flagName &
                "' does not exist (no flag or positional by that name " &
                "declared in this cli interface)", stmt)
          if result.outputFlags.find(flagName) < 0:
            result.outputFlags.add(flagName)
    of "call", "subcmd":
      let childName =
        if head == "call": "" else: stringLiteral(stmt[1])
      var childPath = path
      if childName.len > 0:
        childPath.add(childName)
      let childBody = stmt[stmt.len - 1]
      discard parseCliScope(packageName, executableName, childBody,
        childPath, false, result.params, result.outputFlags,
        result.typedOutputs, result.dependencyPolicy, wholeBody, commands)
    else:
      discard

  if not isRoot:
    commands.add(result)

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
      var commands: seq[CliCommandDef] = @[]
      # A root scope walk validates ``outputs`` statements that appear
      # directly under ``cli:`` and seeds the cumulative output set that
      # each subcommand inherits, all in one source-order pass.
      let rootCmd = parseCliScope(packageName, result.exportName, cliBody,
        @[], true, @[], @[], @[], defaultDependencyPolicy(), cliBody,
        commands)
      discard rootCmd
      # ``parseCliScope`` only emits non-root commands into ``commands``.
      # Existing call sites — the wrapper generator, the interface
      # artifact pipeline, etc. — expect one ``CliCommandDef`` per
      # ``call:`` or ``subcmd``, never one for the synthetic root scope.
      result.commands.add(commands)
    else:
      # Named-Targets M0: detect the
      # ``implicitTargetName(call: T): string = body`` shape, which
      # Nim parses as ``Call(ObjConstr(Ident "implicitTargetName",
      # ExprColonExpr(call, T)), StmtList(...))``. We only flip the
      # inspection bit here; ``collectImplicitTargetNameHooks`` (in
      # ``macros_b``) emits the actual proc. The M1 engine reads
      # ``hasImplicitTargetNameHook`` to decide whether to invoke it.
      if stmt.kind in {nnkCall, nnkCommand} and stmt.len == 2 and
          stmt[0].kind == nnkObjConstr and stmt[0].len >= 1 and
          identText(stmt[0][0]).normalize == "implicittargetname":
        result.hasImplicitTargetNameHook = true
        # Named-Targets M1: capture the user-written parameter type from
        # the first ``ExprColonExpr`` (``call: T``) so the wrapper
        # emitted at every typed-tool call site can construct a ``T``
        # instance from the call's flag values. We deliberately use the
        # raw ``.repr`` form: Nim parses generic types like
        # ``MyCall[Foo]`` as a single AST node and we want to round-trip
        # whatever the author wrote (including qualified names from
        # imported modules).
        if stmt[0].len >= 2 and stmt[0][1].kind == nnkExprColonExpr and
            stmt[0][1].len == 2:
          result.implicitTargetNameHookCallType = stmt[0][1][1].repr

proc libraryKindLiteral(node: NimNode; fallback: LibraryKind): LibraryKind =
  ## Parse a ``kind:`` value inside a ``library foo:`` body. Accepts
  ## either an identifier (``static``, ``shared``, ``both``,
  ## ``header-only`` / ``headerOnly``), an ``AccQuoted`` form (e.g.
  ## `` `header-only` ``), or a string literal of the same tokens. Raises
  ## a compile-time error for unrecognised inputs so typos surface early
  ## instead of silently producing ``lkStatic``.
  discard fallback
  var text: string
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    text = node.strVal
  of nnkAccQuoted:
    # `` `header-only` `` parses to ``AccQuoted(header, -, only)``.
    # Reconstruct the original token by concatenating the children.
    text = ""
    for child in node:
      text.add(identText(child))
  else:
    text = identText(node)
  let norm = text.normalize
  case norm
  of "static", "lkstatic":
    lkStatic
  of "shared", "lkshared", "dynamic":
    lkShared
  of "both", "lkboth":
    lkBoth
  of "header-only", "headeronly", "lkheaderonly":
    lkHeaderOnly
  else:
    error("library kind must be one of: static, shared, both, header-only " &
      "(got '" & text & "')", node)
    lkStatic

proc parseLibrary(packageName: string; node: NimNode): LibraryDef =
  ## Mirrors ``parseExecutable``. Accepts two shapes:
  ##
  ##   ``library foo``                — bare command, no body. Defaults
  ##                                    to ``kind = lkStatic``.
  ##   ``library foo:`` + indented body — body may be ``discard`` or
  ##                                       carry a ``kind: <name>`` line.
  ##
  ## The body grammar deliberately stays minimal in M12: a single
  ## ``kind:`` setter is the only recognised field. Future fields plug in
  ## here without breaking older sources.
  discard packageName
  let loc = lineFile(node)
  if node.len < 2:
    error("library expects a name", node)
  result.name = identText(node[1])
  result.kind = lkStatic
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  if node.len < 3:
    return
  let body = node[2]
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    case calleeName(stmt).normalize
    of "kind":
      if stmt.len < 2:
        error("library kind: requires a value", stmt)
      # ``kind: shared`` parses to ``Call(kind, StmtList(shared))``; the
      # ``StmtList`` wraps a single identifier (or AccQuoted for
      # ``header-only``). Walk through to the leaf so
      # ``libraryKindLiteral`` sees the bare ident/literal.
      var valueNode = stmt[1]
      while valueNode.kind == nnkStmtList and valueNode.len == 1:
        valueNode = valueNode[0]
      result.kind = libraryKindLiteral(valueNode, result.kind)
    of "discard":
      discard
    else:
      # Unknown body member — ignore for forward compatibility but the
      # bare ``discard`` and a ``kind:`` setter are the only recognised
      # forms in M12.
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
  of nnkIfStmt, nnkIfExpr:
    # Spec-Implementation M1 — variant-conditioned ``uses:`` arms. At
    # macro expansion time we do NOT know the variant's resolved value
    # (the solver lands in M2), so we walk every branch's body and
    # collect the union of declared dependencies. M2 will refine this
    # to register the dependencies conditionally against the variant
    # assignment in the SAT formula.
    for branch in node:
      case branch.kind
      of nnkElifBranch, nnkElifExpr:
        if branch.len >= 2:
          collectUses(branch[^1], policyPath, output)
      of nnkElse, nnkElseExpr:
        if branch.len >= 1:
          collectUses(branch[^1], policyPath, output)
      else:
        discard
  of nnkCaseStmt:
    # Spec-Implementation M1 — variant-driven ``case`` selector. Walk
    # every arm's body for the same reason as the ``if`` arm above.
    for i in 1 ..< node.len:
      let branch = node[i]
      case branch.kind
      of nnkOfBranch, nnkElifBranch:
        if branch.len >= 2:
          collectUses(branch[^1], policyPath, output)
      of nnkElse:
        if branch.len >= 1:
          collectUses(branch[^1], policyPath, output)
      else:
        discard
  else:
    discard

proc parseNixPackageProvisioning(node: NimNode): NixPackageProvisioningDef =
  let loc = lineFile(node)
  if calleeName(node).normalize != "nixpackage" or node.len < 2:
    error("provisioning expects nixPackage \"selector\", executablePath = \"bin/name\"",
      node)
  result.selector = stringLiteral(node[1])
  result.packageId = result.selector
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for i in 2 ..< node.len:
    let executablePathValue = namedValue(node[i], "executablePath")
    if not executablePathValue.isNil:
      result.executablePath = stringLiteral(executablePathValue)
    let expressionFileValue = namedValue(node[i], "expressionFile")
    if not expressionFileValue.isNil:
      result.expressionFile = stringLiteral(expressionFileValue)
    let nixpkgsRefValue = namedValue(node[i], "nixpkgsRef")
    if not nixpkgsRefValue.isNil:
      result.nixpkgsRef = stringLiteral(nixpkgsRefValue)
    let nixpkgsRevValue = namedValue(node[i], "nixpkgsRev")
    if not nixpkgsRevValue.isNil:
      result.nixpkgsRev = stringLiteral(nixpkgsRevValue)
    let nixpkgsNarHashValue = namedValue(node[i], "nixpkgsNarHash")
    if not nixpkgsNarHashValue.isNil:
      result.nixpkgsNarHash = stringLiteral(nixpkgsNarHashValue)
    let packageIdValue = namedValue(node[i], "packageId")
    if not packageIdValue.isNil:
      result.packageId = stringLiteral(packageIdValue)
    let lockIdentityValue = namedValue(node[i], "lockIdentity")
    if not lockIdentityValue.isNil:
      result.lockIdentity = stringLiteral(lockIdentityValue)
  if result.selector.len == 0:
    error("nixPackage selector must not be empty", node)
  if result.nixpkgsRev.len > 0 and result.nixpkgsRef.len == 0:
    result.nixpkgsRef = "github:NixOS/nixpkgs/" & result.nixpkgsRev
  if result.nixpkgsRef.len > 0 and not result.selector.startsWith("nixpkgs#"):
    error("nixPackage nixpkgsRef/nixpkgsRev metadata applies only to nixpkgs# selectors",
      node)
  if result.lockIdentity.len == 0:
    if result.nixpkgsRef.len > 0:
      result.lockIdentity = result.nixpkgsRef
      if result.nixpkgsNarHash.len > 0:
        result.lockIdentity.add("?narHash=" & result.nixpkgsNarHash)
      result.lockIdentity.add("#" & result.selector["nixpkgs#".len .. ^1])
    else:
      result.lockIdentity = result.selector
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

proc parseVariantDeclaration(stmt: NimNode; pendingDoc: string;
                             output: var seq[VariantDecl]) =
  ## Spec-Implementation M1: recognise the two ``variant`` spellings
  ## inside a ``config:`` block and append a ``VariantDecl`` to
  ## ``output``. Other declaration shapes are silently skipped — the
  ## ``config:`` block accepts non-variant scalar metadata
  ## (``sourceRepository = "..."``) that the M1 surface treats as
  ## informational.
  ##
  ## Supported AST shapes:
  ##
  ##   * ``name: variant T = default`` →
  ##     ``Call(Ident name, StmtList(Command(Ident variant,
  ##       ExprEqExpr(typeExpr, defaultExpr))))``
  ##
  ##   * ``name: T = default`` paired with a leading ``## @variant``
  ##     doc directive →
  ##     ``Call(Ident name, StmtList(Asgn(typeExpr, defaultExpr)))``
  ##     plus a previous ``nnkCommentStmt`` whose content contains
  ##     ``@variant`` on its own line.
  let loc = lineFile(stmt)
  proc tagFromDocDirective(): bool =
    for line in pendingDoc.splitLines():
      var trimmed = line.strip()
      while trimmed.len > 0 and trimmed[0] == '#':
        trimmed = trimmed[1 .. ^1]
      trimmed = trimmed.strip()
      if trimmed == "@variant":
        return true
    false
  proc cleanDescription(): string =
    var lines: seq[string] = @[]
    for line in pendingDoc.splitLines():
      var trimmed = line.strip()
      while trimmed.len > 0 and trimmed[0] == '#':
        trimmed = trimmed[1 .. ^1]
      let stripped = trimmed.strip()
      if stripped == "@variant": continue
      if stripped.startsWith("@id "):
        continue
      lines.add(stripped)
    result = lines.join("\n").strip()
  proc explicitIdFromDocDirective(): string =
    for line in pendingDoc.splitLines():
      var trimmed = line.strip()
      while trimmed.len > 0 and trimmed[0] == '#':
        trimmed = trimmed[1 .. ^1]
      let stripped = trimmed.strip()
      if stripped.startsWith("@id "):
        return stripped[4 .. ^1].strip()
    ""

  if stmt.kind == nnkCall and stmt.len == 2 and
      stmt[0].kind in {nnkIdent, nnkSym} and
      stmt[1].kind == nnkStmtList and stmt[1].len == 1:
    let nameStr = identText(stmt[0])
    let inner = stmt[1][0]
    # Shape 1: ``name: variant T = default``
    if inner.kind == nnkCommand and inner.len == 2 and
        inner[0].kind in {nnkIdent, nnkSym} and
        identText(inner[0]).normalize == "variant" and
        inner[1].kind == nnkExprEqExpr and inner[1].len == 2:
      let typeRepr = inner[1][0].repr
      let defaultRepr = inner[1][1].repr
      output.add(VariantDecl(
        name: nameStr,
        nimType: typeRepr,
        defaultExpr: defaultRepr,
        description: cleanDescription(),
        explicitId: explicitIdFromDocDirective(),
        sourceFile: loc.file,
        sourceLine: loc.line))
      return
    # Shape 2: ``name: T = default`` plus ``@variant`` directive.
    if inner.kind == nnkAsgn and inner.len == 2 and
        tagFromDocDirective():
      let typeRepr = inner[0].repr
      let defaultRepr = inner[1].repr
      output.add(VariantDecl(
        name: nameStr,
        nimType: typeRepr,
        defaultExpr: defaultRepr,
        description: cleanDescription(),
        explicitId: explicitIdFromDocDirective(),
        sourceFile: loc.file,
        sourceLine: loc.line))
      return

proc collectConfigSection(body: NimNode; output: var seq[VariantDecl]) =
  ## Spec-Implementation M1: walk the ``config:`` block body, peeling
  ## leading doc comments per declaration so the ``@variant`` directive
  ## attaches to the next declaration. Non-variant declarations
  ## (``name = "value"``) are silently accepted as informational
  ## metadata; the M1 surface does not register them as Configurables.
  if body.kind != nnkStmtList:
    return
  var pendingDoc = ""
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      if pendingDoc.len > 0: pendingDoc.add "\n"
      pendingDoc.add stmt.strVal
      continue
    parseVariantDeclaration(stmt, pendingDoc, output)
    pendingDoc = ""

proc parsePackageDef(name: NimNode; body: NimNode): PackageDef =
  let loc = lineFile(name)
  result.packageName = identText(name)
  result.sourceFile = loc.file
  result.sourceLine = loc.line
  for stmt in body:
    if calleeName(stmt).normalize == "executable":
      result.executables.add(parseExecutable(result.packageName, stmt))
    elif calleeName(stmt).normalize == "library":
      result.libraries.add(parseLibrary(result.packageName, stmt))
    elif calleeName(stmt).normalize in ["defaulttoolprovisioning", "toolprovisioning"]:
      if stmt.len != 2:
        error("defaultToolProvisioning expects exactly one string literal", stmt)
      let provisioning = stringLiteral(stmt[1])
      if provisioning.normalize notin ["path", "nix", "tarball", "scoop"]:
        error("defaultToolProvisioning must be one of: path, nix, tarball, scoop", stmt[1])
      result.defaultToolProvisioning = provisioning
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
    elif calleeName(stmt).normalize == "config":
      # Spec-Implementation M1 — variants surface. The ``config:`` block
      # carries (a) informational scalar metadata (``sourceRepository``
      # etc.) the M1 surface accepts but does not register, and (b)
      # ``variant: T = default`` declarations that the ``package`` macro
      # lowers into ``declareVariant[T](...)`` calls plus a single
      # ``finalizeVariants()`` call once the block ends.
      if stmt.len >= 2:
        collectConfigSection(stmt[stmt.len - 1], result.variants)

proc escForCode(text: string): string =
  text.escape()

proc dependencyPolicyCode(policy: BuildActionDependencyPolicy): string =
  proc ignoredCode(): string =
    if policy.ignoredInputPrefixes.len == 0:
      return ""
    result = "ignoredInputPrefixes = @["
    for i, prefix in policy.ignoredInputPrefixes:
      if i > 0:
        result.add(", ")
      result.add(escForCode(prefix))
    result.add("]")

  case policy.kind
  of bdpDefault:
    "defaultDependencyPolicy(" & ignoredCode() & ")"
  of bdpDeclaredOnly:
    "declaredOnlyDependencyPolicy(" & ignoredCode() & ")"
  of bdpAutomaticMonitor:
    "automaticMonitorPolicy(" & ignoredCode() & ")"
  of bdpMakeDepfile:
    "makeDepfilePolicy(" & escForCode(policy.depfile) &
      (if policy.ignoredInputPrefixes.len > 0: ", " & ignoredCode() else: "") &
      ")"

proc packageLiteral(pkg: PackageDef): string =
  result = "PackageDef(packageName: " & escForCode(pkg.packageName) &
    ", defaultToolProvisioning: " & escForCode(pkg.defaultToolProvisioning) &
    ", nixProvisioning: @["
  for provisioningIndex, provisioning in pkg.nixProvisioning:
    if provisioningIndex > 0:
      result.add(", ")
    result.add("NixPackageProvisioningDef(selector: " & escForCode(
        provisioning.selector) &
      ", executablePath: " & escForCode(provisioning.executablePath) &
      ", expressionFile: " & escForCode(provisioning.expressionFile) &
      ", nixpkgsRef: " & escForCode(provisioning.nixpkgsRef) &
      ", nixpkgsRev: " & escForCode(provisioning.nixpkgsRev) &
      ", nixpkgsNarHash: " & escForCode(provisioning.nixpkgsNarHash) &
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
      ", hasImplicitTargetNameHook: " & $exe.hasImplicitTargetNameHook &
      ", implicitTargetNameHookCallType: " &
        escForCode(exe.implicitTargetNameHookCallType) &
      ", sourceFile: " & escForCode(exe.sourceFile) &
      ", sourceLine: " & $exe.sourceLine & ", commands: @[")
    for cmdIndex, cmd in exe.commands:
      if cmdIndex > 0:
        result.add(", ")
      result.add("CliCommandDef(name: " & escForCode(cmd.name) &
        ", path: @[")
      for pathIndex, segment in cmd.path:
        if pathIndex > 0:
          result.add(", ")
        result.add(escForCode(segment))
      result.add("], providerEntrypointId: " &
          escForCode(cmd.providerEntrypointId) &
        ", dependencyPolicy: " & dependencyPolicyCode(cmd.dependencyPolicy) &
        ", outputFlags: @[")
      for ofIndex, flagName in cmd.outputFlags:
        if ofIndex > 0:
          result.add(", ")
        result.add(escForCode(flagName))
      result.add("], typedOutputs: @[")
      for tdIndex, td in cmd.typedOutputs:
        if tdIndex > 0:
          result.add(", ")
        result.add("TypedOutputDef(fieldName: " & escForCode(td.fieldName) &
          ", types: @[")
        for typeIndex, typeName in td.types:
          if typeIndex > 0:
            result.add(", ")
          result.add(escForCode(typeName))
        result.add("], pathExpr: " & escForCode(td.pathExpr) &
          ", sourceFile: " & escForCode(td.sourceFile) &
          ", sourceLine: " & $td.sourceLine & ")")
      result.add("], sourceFile: " & escForCode(cmd.sourceFile) &
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
  result.add("], libraries: @[")
  for libIndex, lib in pkg.libraries:
    if libIndex > 0:
      result.add(", ")
    result.add("LibraryDef(name: " & escForCode(lib.name) &
      ", kind: " & $lib.kind &
      ", sourceFile: " & escForCode(lib.sourceFile) &
      ", sourceLine: " & $lib.sourceLine & ")")
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

proc escapeNimIdent(text: string): string =
  ## Backtick-quote a generated identifier that collides with a Nim
  ## keyword (e.g. ``out``, ``type``). Pass-through for ordinary names.
  ## Used in ``toolActionFormal`` / ``interfaceFormal`` and the matching
  ## arg-builder paths so flag declarations like ``flag out is string``
  ## survive code generation; without this they expand into
  ## ``proc c*(pkg: …; out: string = "")`` which fails Nim's keyword
  ## check on the formal parameter name.
  if validGeneratedIdent(text):
    text
  else:
    "`" & text & "`"

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
  # Read-side: backtick-quote the formal so a flag named after a Nim
  # keyword (``out``) still resolves to the formal parameter at the
  # call site instead of triggering a parser error.
  let valueRef = escapeNimIdent(param.name)
  if param.nimType.normalize == "seq[string]":
    helper & "(\"" & param.name & "\", " & valueRef & metaArgs & ")"
  else:
    helper & "(\"" & param.name & "\", " & valueRef & metaArgs & ")"


proc commandProcName(cmdName: string): string =
  if validGeneratedIdent(cmdName):
    return cmdName
  result = "subcmd"
  for ch in cmdName:
    if ch.isAlphaNumeric():
      result.add("_" & $ch)
    else:
      result.add("_" & toHex(ord(ch), 2).toLowerAscii())

proc titleCase(text: string): string =
  ## Typed-Outputs M0: lowercase-with-underscores -> CamelCase. Shared
  ## by ``titleIdent`` (which appends a ``Package`` suffix) and the
  ## per-tool-call ``BuildEdge`` subtype namer in
  ## ``buildEdgeSubtypeName`` (which does not).
  let normalized = selectorModuleName(text)
  var capitalizeNext = true
  for ch in normalized:
    if ch == '_':
      capitalizeNext = true
    elif capitalizeNext:
      result.add(ch.toUpperAscii())
      capitalizeNext = false
    else:
      result.add(ch)

proc titleIdent(text: string): string =
  let normalized = selectorModuleName(text)
  if normalized.len == 0:
    return "Package"
  result = titleCase(text)
  result.add("Package")

proc buildEdgeSubtypeName(exeExportName, cmdName: string): string =
  ## Typed-Outputs M0: per-tool-call ``BuildEdge`` subtype name. The
  ## convention is ``<TitleExportName><TitleCmdName>Edge`` — for
  ## ``executable buildNimUnittest:`` whose call is anonymous (``call:``
  ## or no subcommand) this yields ``BuildNimUnittestEdge``; for
  ## ``executable nim:`` with ``subcmd "c"`` it yields ``NimCEdge``.
  ## Empty ``cmdName`` collapses to just ``<TitleExportName>Edge``.
  result = titleCase(exeExportName)
  if cmdName.len > 0:
    result.add(titleCase(cmdName))
  result.add("Edge")

proc packageValueIdent(text: string): string =
  selectorModuleName(text)

proc commandCallableName(cmdName: string): string =
  if cmdName.len == 0:
    "`()`"
  else:
    commandProcName(cmdName)

proc shouldEmitArgCondition(param: CliParamDef): string =
  let formalRef = escapeNimIdent(param.name)
  if param.required:
    return "true"
  case param.nimType.normalize
  of "bool":
    formalRef
  of "int":
    formalRef & " != 0"
  of "seq[string]":
    formalRef & ".len > 0"
  else:
    formalRef & ".len > 0"

proc toolActionFormal(param: CliParamDef): string =
  result = escapeNimIdent(param.name) & ": " & param.nimType
  if not param.required:
    result.add(" = " & nimDefault(param.nimType))

proc toolActionArgExpr(param: CliParamDef): string =
  argBuilder(param)

proc outputFlagsLiteral(outputFlags: openArray[string]): string =
  ## Named-Targets M1: render the cumulative outputFlags as a Nim
  ## ``@[...]`` literal that the wrapper passes to
  ## ``computeImplicitTargetNames`` at runtime.
  result = "@["
  for i, flagName in outputFlags:
    if i > 0:
      result.add(", ")
    result.add(escForCode(flagName))
  result.add("]")

proc hookCallRecordExpr(callTypeRepr: string;
                        params: openArray[CliParamDef]): string =
  ## Named-Targets M1: build the typed-call-record constructor source
  ## for the implicit-target-name hook. The user wrote
  ## ``implicitTargetName(call: T): string = ...`` and we know ``T``
  ## from ``ExecutableDef.implicitTargetNameHookCallType``. We project
  ## every CLI parameter into a same-named field of ``T``. Nim's type
  ## checker raises if ``T`` is missing a field — the user is on the
  ## hook (pun intended) for keeping their record type in sync with
  ## the CLI flag schema.
  result = callTypeRepr & "("
  for i, param in params:
    if i > 0:
      result.add(", ")
    # Field name in the record matches the CLI flag name; value comes
    # from the wrapper's formal parameter of the same name (backticked
    # if the name collides with a Nim keyword).
    result.add(param.name & ": " & escapeNimIdent(param.name))
  result.add(")")

proc emitTargetNameWiring(packageNameLit: string;
                          outputFlags: openArray[string];
                          params: openArray[CliParamDef];
                          hookProcName: string;
                          hookCallTypeRepr: string;
                          sourceFileLit: string;
                          sourceLineLit: string;
                          indent = "  "): string =
  ## Named-Targets M1: generate the post-``recordToolInvocation``
  ## suffix that
  ##
  ##   * computes implicit names from the call's actual flag values,
  ##   * invokes the per-tool hook when one is registered (replacing
  ##     the canonical first entry),
  ##   * writes the names back onto the engine's edge record, and
  ##   * registers per-name rows in the project-scoped target-export
  ##     table, including the call-site source location so collision
  ##     diagnostics can cite both sides.
  ##
  ## Empty ``outputFlags`` and no hook elide the whole block — the edge
  ## stays anonymous, per spec.
  if outputFlags.len == 0 and hookProcName.len == 0:
    return ""
  let flagsLit = outputFlagsLiteral(outputFlags)
  result.add(indent & "var implicitNames = computeImplicitTargetNames(call, " &
    flagsLit & ")\n")
  if hookProcName.len > 0 and hookCallTypeRepr.len > 0:
    # Hook overrides the canonical (first) name. When no implicit
    # names exist yet (because the call elided every output flag, or
    # because no ``outputs`` statement was declared) we still
    # materialise the hook's return value as the first/only name —
    # the hook's purpose is to give those edges a name.
    let recordCtor = hookCallRecordExpr(hookCallTypeRepr, params)
    result.add(indent & "let hookName = " & hookProcName & "(" & recordCtor &
      ")\n")
    result.add(indent & "if implicitNames.len > 0:\n")
    result.add(indent & "  implicitNames[0] = hookName\n")
    result.add(indent & "else:\n")
    result.add(indent & "  implicitNames.add(hookName)\n")
  result.add(indent & "if implicitNames.len > 0:\n")
  result.add(indent & "  setRegisteredActionTargetNames(result.id, " &
    "implicitNames)\n")
  result.add(indent & "  registerImplicitTargetExports(result.id, " &
    packageNameLit & ", implicitNames, " & sourceFileLit & ", " &
    sourceLineLit & ")\n")

proc typedOutputTypesLiteral(types: openArray[string]): string =
  ## Typed-Outputs M1: render a typed-output's ``types`` field as a
  ## ``@[<type>...]`` string literal for the engine-side payload entry.
  ## Each type identifier is recorded as the source ``.repr`` so
  ## downstream consumers (CLI resolver, ``repro why``, the codetracer
  ## ``repro test`` integration) see the same spelling the user wrote.
  result = "@["
  for i, typeName in types:
    if i > 0:
      result.add(", ")
    result.add(escForCode(typeName))
  result.add("]")

proc emitBuildEdgeSubtypeDecl(subtypeName: string;
                              typedOutputs: openArray[TypedOutputDef];
                              indent = "  "): string =
  ## Typed-Outputs M0/M1: emit the ``type`` declaration for the per-call
  ## ``BuildEdge`` subtype. Shared between the package-block wrapper
  ## (``toolActionWrapperCode``) and ``defineCliInterface``'s emission
  ## path so both surface typed fields with the same shape. The first
  ## ``types`` entry names the static field type; further entries flow
  ## through to the engine-side typed-output payload at call time.
  result.add(indent & subtypeName & "* = object\n")
  result.add(indent & "  action*: BuildActionDef\n")
  for td in typedOutputs:
    let fieldType =
      if td.types.len > 0: td.types[0] else: "BuildActionDef"
    result.add(indent & "  " & escapeNimIdent(td.fieldName) & "*: " &
      fieldType & "\n")

proc emitTypedOutputBindings(typedOutputs: openArray[TypedOutputDef];
                             actionRef: string;
                             indent = "  "): string =
  ## Typed-Outputs M1: emit the per-call path-binding suffix.
  ##
  ##   * Evaluates each ``pathExpr`` in the call-site flag scope. The
  ##     ``pathExpr`` is stored as the ``.repr`` of the source-site
  ##     NimNode (the M0 deviation — see ``TypedOutputDef`` doc); we
  ##     inline it directly into the generated source so the outer
  ##     ``parseStmt`` reparses it for us. This is the M1 "reparse" hook
  ##     the spec mentions.
  ##   * Constructs ``result.<fieldName> = <FieldType>(path: <pathValue>)``
  ##     so framework adapter types like ``NimUnittestBinary`` carry the
  ##     bound path through to UFCS method calls like
  ##     ``edge.testBinary.run(...)``.
  ##   * Appends one ``BuildActionTypedOutput`` row on the engine-side
  ##     ``BuildActionDef`` so the (fieldName, types, path) triple
  ##     survives the payload codec round-trip and downstream consumers
  ##     can identify the output without re-parsing the DSL.
  for td in typedOutputs:
    let fieldType =
      if td.types.len > 0: td.types[0] else: "BuildActionDef"
    let pathLocal = "typedOutputPath_" & td.fieldName
    let typesLit = typedOutputTypesLiteral(td.types)
    # Inline the user's pathExpr source verbatim; ``parseStmt`` of the
    # surrounding wrapper-code string re-parses it in the call-site
    # flag scope. Brace it in a ``block:`` so even a multi-statement
    # path expression compiles to a single rhs (M0's stored repr
    # collapses to one expression for the common cases).
    result.add(indent & "let " & pathLocal & " = " & td.pathExpr & "\n")
    result.add(indent & "result." & escapeNimIdent(td.fieldName) &
      " = " & fieldType & "(path: " & pathLocal & ")\n")
    result.add(indent & "appendRegisteredActionTypedOutput(" & actionRef &
      ".id, " & escForCode(td.fieldName) & ", " & typesLit & ", " &
      pathLocal & ")\n")

proc toolActionWrapperCode(pkg: PackageDef): string =
  let typeName = titleIdent(pkg.packageName)
  let valueName = packageValueIdent(pkg.packageName)
  result = "{.experimental: \"callOperator\".}\n"
  result.add("type\n  " & typeName & "* = object\n")
  result.add("const " & valueName & "* = " & typeName & "()\n")
  # The marker is a uniqueness sentinel that ``usesImportCode`` queries
  # via ``when compiles(<mod>.reprobuildPackageMarker())`` to confirm an
  # imported module is a reprobuild project. Guarded by ``when not
  # declared`` so a single Nim file containing multiple ``package``
  # blocks emits the proc exactly once (the second/third expansion is a
  # no-op). See ``wrapperCode`` and ``defineCliInterfaceCode`` below for
  # the matching guards on the other two emission sites.
  result.add(
    "when not declared(reprobuildPackageMarker):\n" &
    "  proc reprobuildPackageMarker*() = discard\n")
  if pkg.executables.len != 1:
    return
  let exe = pkg.executables[0]
  # Typed-Outputs M0: emit a per-tool-call ``BuildEdge`` subtype for
  # every command whose ``typedOutputs`` is non-empty. The subtype has
  # one typed field per ``TypedOutputDef`` (field type = ``types[0]``);
  # the embedded ``action: BuildActionDef`` preserves access to the
  # engine-side edge record so existing call paths
  # (``setRegisteredActionTargetNames(edge.action.id, ...)``,
  # ``combineActionDeps``, etc.) still compose. Commands without typed
  # outputs keep returning ``BuildActionDef`` unchanged so the M0
  # ``outputs <flag>...`` form and every untyped in-tree wrapper
  # (``nim.c``, ``gcc.compile``, ``stylus``) stay binary-compatible.
  var emittedTypeBlock = false
  for cmd in exe.commands:
    if cmd.typedOutputs.len == 0:
      continue
    if not emittedTypeBlock:
      result.add("type\n")
      emittedTypeBlock = true
    let subtypeName = buildEdgeSubtypeName(exe.exportName, cmd.name)
    result.add(emitBuildEdgeSubtypeDecl(subtypeName, cmd.typedOutputs))
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
    let typedReturn = cmd.typedOutputs.len > 0
    let returnType =
      if typedReturn: buildEdgeSubtypeName(exe.exportName, cmd.name)
      else: "BuildActionDef"
    # ``actionRef`` reads through to the engine-side ``BuildActionDef``
    # record regardless of which return shape we picked, so the M1
    # target-name wiring below stays branch-free.
    let actionRef =
      if typedReturn: "result.action" else: "result"
    result.add("proc " & commandCallableName(cmd.name) & "*( " &
      formals.join("; ") & "): " & returnType & " {.discardable.} =\n")
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
    result.add("  " & actionRef &
      " = recordToolInvocation(selectedActionId, call, " &
      "deps = combineActionDeps(deps, after), extraInputs = extraInputs, " &
      "extraOutputs = extraOutputs, depfile = depfile, cacheable = cacheable, " &
      "commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy, " &
      "dependencyPolicy = " &
      dependencyPolicyCode(cmd.dependencyPolicy) & ")\n")
    # Typed-Outputs M1: bind each typed-output field by evaluating its
    # ``pathExpr`` in the call-site flag scope. The shared
    # ``emitTypedOutputBindings`` helper handles both the typed-handle
    # field assignment (``result.<field> = <FieldType>(path: ...)``)
    # and the engine-side ``BuildActionTypedOutput`` append so the
    # (fieldName, types, path) triple round-trips through the payload
    # codec to downstream consumers.
    if typedReturn:
      result.add(emitTypedOutputBindings(cmd.typedOutputs, actionRef))
    # Named-Targets M1: append the implicit-target-name wiring suffix.
    # The wrapper proc returns either ``BuildActionDef`` directly (no
    # typed outputs) or a ``BuildEdge`` subtype with an embedded
    # ``action: BuildActionDef`` field, so ``actionRef`` resolves to
    # the same engine-side edge record both ways.
    let hookProc =
      if exe.hasImplicitTargetNameHook and
          exe.implicitTargetNameHookCallType.len > 0:
        "implicitTargetNameFor" & titleIdent(exe.exportName)
      else:
        ""
    let wiringIndent = "  "
    # The M1 wiring code template references ``result.id`` directly;
    # when the return type is the typed subtype we need ``result.action.id``.
    # Generate the wiring as a small inline block parameterised by
    # ``actionRef``.
    if cmd.outputFlags.len > 0 or hookProc.len > 0:
      let flagsLit = outputFlagsLiteral(cmd.outputFlags)
      result.add(wiringIndent &
        "var implicitNames = computeImplicitTargetNames(call, " &
        flagsLit & ")\n")
      if hookProc.len > 0 and exe.implicitTargetNameHookCallType.len > 0:
        let recordCtor = hookCallRecordExpr(
          exe.implicitTargetNameHookCallType, cmd.params)
        result.add(wiringIndent & "let hookName = " & hookProc & "(" &
          recordCtor & ")\n")
        result.add(wiringIndent & "if implicitNames.len > 0:\n")
        result.add(wiringIndent & "  implicitNames[0] = hookName\n")
        result.add(wiringIndent & "else:\n")
        result.add(wiringIndent & "  implicitNames.add(hookName)\n")
      result.add(wiringIndent & "if implicitNames.len > 0:\n")
      result.add(wiringIndent & "  setRegisteredActionTargetNames(" &
        actionRef & ".id, implicitNames)\n")
      result.add(wiringIndent & "  registerImplicitTargetExports(" &
        actionRef & ".id, " & escForCode(pkg.packageName) &
        ", implicitNames, " & escForCode(cmd.sourceFile) & ", " &
        $cmd.sourceLine & ")\n")

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
    # Marker is a uniqueness sentinel queried via ``when compiles(...)``
    # by ``usesImportCode``; guarded so multiple ``package`` blocks in
    # the same Nim file don't redeclare the proc (see
    # ``toolActionWrapperCode`` for the matching guard).
    "when not declared(reprobuildPackageMarker):\n" &
    "  proc reprobuildPackageMarker*() = discard\n" &
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
        var spec = escapeNimIdent(param.name) & ": " & param.nimType
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
        var spec = escapeNimIdent(param.name) & ": " & param.nimType
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
    # M29 (Provisioning catalog cleanup): autoconf, automake, bun,
    # maturin, npm, pnpm, pyproject-hooks added so every catalog
    # entry under repro_dsl_stdlib/packages/ is discoverable via a
    # plain ``uses:`` line in reprobuild.nim.
    selector in [
      "autoconf",
      "automake",
      "bash",
      "bpftrace",
      "bpftool",
      "bun",
      "cachix",
      "capnp",
      "cargo",
      "cargo-nextest",
      "clang",
      "ctags",
      "create-dmg",
      "curl",
      "dpkg",
      "electron",
      "emcc",
      "esbuild",
      "flake8",
      "gcc",
      "gh",
      "git",
      "go",
      "installer",
      "just",
      "llvm-config",
      "make",
      "maturin",
      "mdbook",
      "nim",
      "nimble",
      "nix",
      "node",
      "npm",
      "npx",
      "openssl",
      "pcre-config",
      "pkg-config",
      "playwright",
      "pnpm",
      "pyproject-hooks",
      "pytest",
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
      "swc",
      "tmux",
      "tree-sitter",
      "tsx",
      "tup",
      "typescript",
      "uv",
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
    # Named-Targets M0/M1: ``outputs <flag> [<flag>...]`` declares the
    # cumulative output set for this subcommand. ``defineCliInterface``
    # has no parent scope so the lexical-scope rule degenerates to
    # "every named flag must be declared at the root of the
    # interface body OR on this subcommand"; both are visible via
    # ``commonParams + result.params`` at this point.
    if calleeName(stmt).normalize == "outputs":
      if stmt.len < 2:
        error("outputs requires at least one flag name", stmt)
      # Typed-Outputs M0: ``defineCliInterface`` accepts the typed form
      # too — it lowers to the same ``TypedOutputDef`` records that the
      # ``package`` macro builds. The ``BuildEdge`` subtype emission
      # path is in ``toolActionWrapperCode`` (the package-scoped
      # wrapper); the ``defineCliInterface`` wrapper currently returns
      # a plain ``BuildActionDef`` and only records the typed entries
      # for inspection. M1 unifies the two emission paths.
      if isTypedOutputsHead(stmt):
        let td = parseTypedOutputsStatement(stmt)
        var duplicate = false
        for existing in result.typedOutputs:
          if existing.fieldName == td.fieldName:
            duplicate = true
            break
        if not duplicate:
          result.typedOutputs.add(td)
        continue
      var operands: seq[NimNode] = @[]
      for i in 1 ..< stmt.len:
        collectOutputsOperands(stmt[i], operands)
      if operands.len == 0:
        error("outputs requires at least one flag name", stmt)
      for operand in operands:
        if operand.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
          error("outputs expects a flag name identifier, got: " &
            operand.repr, operand)
        let flagName = identText(operand)
        var visible = false
        for param in result.params:
          if param.name == flagName:
            visible = true
            break
        if not visible:
          error("outputs: '" & flagName &
            "' is not declared at the root of this defineCliInterface " &
            "body or on this subcmd", stmt)
        if result.outputFlags.find(flagName) < 0:
          result.outputFlags.add(flagName)
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
  result = escapeNimIdent(param.name) & ": " & param.nimType
  let defaultValue = interfaceParamDefault(param)
  if defaultValue.len > 0:
    result.add(" = " & defaultValue)

proc interfaceArgExpr(param: CliParamDef): string =
  let kindCode =
    if param.kind == cpkPositional: "cpkPositional" else: "cpkFlag"
  let valueRef = escapeNimIdent(param.name)
  cliArgHelperName(param) & "(" & escForCode(param.name) & ", " &
    valueRef & ", " & kindCode & ", " & $param.position & ", " &
    escForCode(param.alias) & ", " & $param.format & ", " &
    $param.placement & ", " & $param.repeated & ")"

proc shouldRecordCondition(param: CliParamDef): string =
  let formalRef = escapeNimIdent(param.name)
  if param.required:
    return "true"
  case param.nimType.normalize
  of "bool":
    formalRef
  of "int":
    formalRef & " != 0"
  of "seq[string]":
    formalRef & ".len > 0"
  else:
    formalRef & ".len > 0"

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
  # Marker is a uniqueness sentinel queried via ``when compiles(...)`` by
  # ``usesImportCode``. Guarded so a file declaring multiple
  # ``cliInterface`` blocks (or mixing them with ``package`` blocks)
  # emits the proc exactly once.
  result.add(
    "when not declared(reprobuildPackageMarker):\n" &
    "  proc reprobuildPackageMarker*() = discard\n")
  # Typed-Outputs M1 (unification): if any command declares typed
  # outputs, emit the same ``BuildEdge`` subtype shape the package-
  # block wrapper uses so ``defineCliInterface``-driven typed-tool
  # surfaces (the in-tree ``gccCompile`` / ``nimC`` fixtures, codetracer
  # adapter packages once they migrate) carry the same per-call typed
  # field set as their ``package``-block counterparts.
  var emittedTypeBlock = false
  for command in commands:
    if command.typedOutputs.len == 0:
      continue
    if not emittedTypeBlock:
      result.add("type\n")
      emittedTypeBlock = true
    let subtypeName = buildEdgeSubtypeName(toolSymbol, command.name)
    result.add(emitBuildEdgeSubtypeDecl(subtypeName, command.typedOutputs))
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
    let typedReturn = command.typedOutputs.len > 0
    let returnType =
      if typedReturn: buildEdgeSubtypeName(toolSymbol, command.name)
      else: "BuildActionDef"
    let actionRef =
      if typedReturn: "result.action" else: "result"
    result.add("proc " & interfaceProcName(command) & "*( " &
      formals.join("; ") & "): " & returnType & " {.discardable.} =\n")
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
    result.add("  " & actionRef &
      " = recordToolInvocation(selectedActionId, call, " &
      "deps = combineActionDeps(deps, after), extraInputs = extraInputs, " &
      "extraOutputs = extraOutputs, depfile = depfile, cacheable = cacheable, " &
      "commandStatsId = commandStatsId, actionCachePolicy = actionCachePolicy, " &
      "dependencyPolicy = " &
      dependencyPolicyCode(command.dependencyPolicy) & ")\n")
    # Typed-Outputs M1: bind typed fields against the call-site flag
    # values via the shared helper (the ``package``-block wrapper uses
    # the same one).
    if typedReturn:
      result.add(emitTypedOutputBindings(command.typedOutputs, actionRef))
    # Named-Targets M1: ``defineCliInterface`` has no per-tool naming
    # hook (those live on ``executable`` inside a ``package`` block),
    # and the wrapper is not bound to a package — the call site's
    # package isn't propagated through the typed-tool call protocol.
    # We still compute implicit names from the outputs flags and stamp
    # them on the edge record so the engine sees them, but we register
    # under ``toolId`` as the owning package. Callers that want a
    # proper per-package home for the export rows should declare the
    # tool inside a ``package`` block instead of using
    # ``defineCliInterface`` directly.
    #
    # Bridge the typed-return case onto the same
    # ``emitTargetNameWiring`` template by switching from a literal
    # ``result.id`` to ``<actionRef>.id``. We emit the wiring inline
    # rather than through the helper when typed outputs are present
    # because the helper hard-codes ``result.id``.
    if typedReturn:
      if command.outputFlags.len > 0:
        let flagsLit = outputFlagsLiteral(command.outputFlags)
        result.add("  var implicitNames = computeImplicitTargetNames(call, " &
          flagsLit & ")\n")
        result.add("  if implicitNames.len > 0:\n")
        result.add("    setRegisteredActionTargetNames(" & actionRef &
          ".id, implicitNames)\n")
        result.add("    registerImplicitTargetExports(" & actionRef &
          ".id, " & escForCode(toolId) & ", implicitNames, " &
          escForCode(command.sourceFile) & ", " &
          $command.sourceLine & ")\n")
    else:
      result.add(emitTargetNameWiring(
        packageNameLit = escForCode(toolId),
        outputFlags = command.outputFlags,
        params = command.params,
        hookProcName = "",
        hookCallTypeRepr = "",
        sourceFileLit = escForCode(command.sourceFile),
        sourceLineLit = $command.sourceLine))

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
