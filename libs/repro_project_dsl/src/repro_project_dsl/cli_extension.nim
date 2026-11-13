## Reprobuild's extension of the clispec ``cli:`` language.
##
## Included by ``macros_a.nim``. The ``cli:`` grammar itself — ``pos``,
## ``flag``, ``boolFlag``, ``call:``, ``subcmd`` and the ``alias`` /
## ``required`` / ``repeated`` / ``format`` / ``placement`` / ``position``
## arguments — is parsed by the clispec library into its typed model
## (``clispec/dsl``, ``parseCliModel``). What a ``cli:`` block says about the
## BUILD GRAPH is reprobuild's and lives here, carried in the model's typed
## extension slots (``ReproCliParamExt`` / ``ReproCliCommandExt`` in
## ``types.nim``):
##
## * ``role = input|output`` on a parameter;
## * ``dependencyPolicy`` and ``nonDeterminism`` on a scope;
## * ``outputs``, ``optionalOutputs`` and ``removeBeforeRun``, which name
##   parameters visible in the scope;
## * ``subTools``, once, directly under ``cli:`` (optionally per platform in a
##   ``when``);
## * the provider entry point each command's typed wrapper records.
##
## clispec hands each of these to the two hooks below
## (``parseCliParamExtension`` / ``parseCliCommandExtension``), resolved by
## overload on the extension types. Every nested ``subcmd`` starts from a
## copy of its parent's extension, which is what makes all of them inherited
## by nested scopes, exactly as before the grammar moved to clispec.
##
## The argv an external tool is finally run with is rendered from the
## recorded ``PublicCliCall`` by the engine (``argvForCall``), and the
## typed-tool wrapper that records it is generated in ``macros_a.nim``; both
## stay in reprobuild.

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

proc parseCaptureBreadth(value: NimNode;
                         fallback: MonitorCaptureBreadth):
    MonitorCaptureBreadth =
  ## DA-6 — parse ``captureBreadth = fullCapture`` / ``= omitAmbientReads``.
  ##
  ## An unrecognised word is a compile ERROR rather than a silent fallback, for
  ## the reason ``parseNonDeterminismDecl`` below gives for the same choice: the
  ## failure this declaration can produce is a capture that grades
  ## ``mcComplete`` while missing evidence a consumer needed, and a misspelt
  ## narrowing that silently inherited the enclosing scope's value would be
  ## read by its author as "the narrowing took".
  case identText(value).normalize
  of "fullcapture", "full":
    mcbFullCapture
  of "omitambientreads", "omitambient":
    mcbOmitAmbientReads
  else:
    error("captureBreadth expects fullCapture or omitAmbientReads, got: " &
      value.repr & ". Those are the only two declarations that are true: " &
      "io-mon's DA-5 split proved over all 256 interest sets that " &
      "`FullInterest - {ecAmbientReads}` is the ONLY safe proper subset for " &
      "a reprobuild edge, because every other category carries a record kind " &
      "some consumer reads (mrEnvRead keys the action cache via " &
      "cacheEnvInputs, mrNonDeterministic gates publication via " &
      "applyEntropyBlessingPolicy, mrIpcConnect/mrExternalContent are not " &
      "gate-able at all).", value)
    fallback

proc refuseRetiredCaptureIpc(node: NimNode) =
  ## DA-6 — ``captureIpc = ...`` is refused BY NAME, and this is the only
  ## place that can refuse it.
  ##
  ## The switch was already inert before DA-5, but only CONTINGENTLY: the
  ## engine happened to ask io-mon for every category, so a recipe asking for
  ## the IPC category got it either way. After DA-5 it is PERMANENTLY,
  ## STRUCTURALLY inert — ``categoryOf`` answers ``none`` for
  ## ``mrIpcConnect``, alongside ``mrExternalContent`` and the META kinds,
  ## because the harm the gate does is that the records are not there when
  ## ``mergeFragments`` derives its synthetic ``mrEventLoss``, and no
  ## granularity fixes that. There is therefore no set of categories at which
  ## either value of this switch could be honoured.
  ##
  ## ACCEPTING IT SILENTLY IS THE WORSE ANSWER, which is why this is an error
  ## and not a warning. A recipe that writes ``captureIpc = true`` believes it
  ## has widened something and a recipe that writes ``captureIpc = false``
  ## believes it has narrowed something; both are wrong, and the previous
  ## generation of this field spent a whole milestone carrying an ``INERT``
  ## comment that had gone stale precisely because nothing refused it.
  ## Measured before removing it: zero call sites outside reprobuild's own
  ## tests, across every recipe in this workspace.
  if node.isNil:
    return
  error("captureIpc has been RETIRED — delete the line. io-mon's " &
    "`mrIpcConnect` is not gate-able at any granularity (DA-5: `categoryOf` " &
    "answers `none` for it, as it does for `mrExternalContent` and the META " &
    "kinds), because the harm is that the records do not exist when " &
    "`mergeFragments` derives the synthetic `mrEventLoss` that forces " &
    "`mcIncomplete`. So no value of this switch could ever be honoured, and " &
    "the IPC connects an action makes are always observed. To declare how " &
    "much of io-mon's stream a TOOL asks for, use " &
    "`captureBreadth = fullCapture` / `= omitAmbientReads`.", node)

proc parseCommandDependencyPolicy(node: NimNode;
                                  fallback = defaultDependencyPolicy()):
    BuildActionDependencyPolicy =
  if calleeName(node).normalize != "dependencypolicy" or node.len < 2:
    error("dependencyPolicy expects a policy name", node)
  let text = identText(node[1]).normalize
  case text
  of "default":
    result = defaultDependencyPolicy()
  of "automaticmonitor", "monitor":
    result = automaticMonitorPolicy()
  of "makedepfile":
    result = makeDepfilePolicy()
  of "iomonreport", "iomon":
    result = iomonReportPolicy("")
  else:
    result = fallback
  for i in 2 ..< node.len:
    let depfileValue = namedValue(node[i], "depfile")
    if not depfileValue.isNil:
      let single = requireStrLit(depfileValue, "dependencyPolicy depfile")
      if single.len > 0 and single notin result.depfiles:
        result.depfiles.add(single)
    let depfilesValue = namedValue(node[i], "depfiles")
    if not depfilesValue.isNil:
      for path in stringSeqLiteral(depfilesValue):
        if path.len > 0 and path notin result.depfiles:
          result.depfiles.add(path)
    let ignoredValue = namedValue(node[i], "ignoredInputPrefixes")
    if not ignoredValue.isNil:
      result.ignoredInputPrefixes = stringSeqLiteral(ignoredValue)
    let captureBreadthValue = namedValue(node[i], "captureBreadth")
    if not captureBreadthValue.isNil:
      result.captureBreadth =
        parseCaptureBreadth(captureBreadthValue, result.captureBreadth)
    # DA-6 — `captureNonDeterminism` survives as a SPELLING of
    # `captureBreadth`, with its scope shrunk to the part that was ever safe.
    # `true` is "capture the non-determinism signals, ambient ones included";
    # `false` is "exclude the ambient ones", which is the ONLY member of the
    # old `ecNonDeterminism` bundle this flag could ever have dropped without
    # removing evidence a consumer reads — env reads still key the action
    # through `cacheEnvInputs` and entropy still gates publication through
    # `applyEntropyBlessingPolicy`, and neither is at this flag's mercy any
    # more. Absent leaves the inherited declaration alone, so no edge that
    # never mentioned the flag changes.
    let captureNonDeterminismValue =
      namedValue(node[i], "captureNonDeterminism")
    if not captureNonDeterminismValue.isNil:
      result.captureBreadth =
        if boolLiteral(captureNonDeterminismValue, true): mcbFullCapture
        else: mcbOmitAmbientReads
    refuseRetiredCaptureIpc(namedValue(node[i], "captureIpc"))
    let suppressSeedValue = namedValue(node[i], "suppressMonitorShimSeed")
    if not suppressSeedValue.isNil:
      result.suppressMonitorShimSeed =
        boolLiteral(suppressSeedValue, result.suppressMonitorShimSeed)

type
  NonDeterminismDecl = tuple[policy: NonDeterminismPolicy; justification: string]

proc parseNonDeterminismDecl(node: NimNode;
                             fallback: NonDeterminismDecl): NonDeterminismDecl =
  ## Windows-Build-Correctness M6 — parse the tool-level entropy blessing:
  ##
  ##   nonDeterminism entropyBlessed,
  ##     justification = "why this tool's randomness cannot reach its output"
  ##
  ## Two rules are enforced HERE rather than left to review, because both
  ## failures are silent at the point they matter (an action that quietly
  ## keeps caching):
  ##
  ##   * A blessing MUST carry a justification. "Do not bless anything you
  ##     cannot justify" is only a rule if the compiler asks for the reason;
  ##     a bare ``nonDeterminism entropyBlessed`` is a compile error naming
  ##     the tool.
  ##   * An unrecognised policy word is a compile ERROR, not a silent
  ##     fallback to the parent's value. ``dependencyPolicy`` falls back
  ##     (its unknown-word case predates this), but the failure modes are
  ##     not comparable: an unrecognised dependency policy leaves the
  ##     inherited monitoring in place, while a misspelt blessing that
  ##     silently inherited ``ndpUnblessed`` would read as "the author
  ##     tried to bless this and it did not take" — which is the SAFE
  ##     direction only by accident, and a misspelt word that inherited a
  ##     blessing from an enclosing scope would not be safe at all.
  if calleeName(node).normalize != "nondeterminism" or node.len < 2:
    error("nonDeterminism expects a policy name " &
      "(entropyBlessed or unblessed)", node)
  result = fallback
  let text = identText(node[1]).normalize
  case text
  of "entropyblessed", "blessed":
    result.policy = ndpEntropyBlessed
  of "unblessed", "none":
    result.policy = ndpUnblessed
    result.justification = ""
  else:
    error("nonDeterminism expects entropyBlessed or unblessed, got: " &
      identText(node[1]), node)
  for i in 2 ..< node.len:
    let justificationValue = namedValue(node[i], "justification")
    if not justificationValue.isNil:
      result.justification =
        foldStrLitConcat(justificationValue, "nonDeterminism justification")
  if result.policy == ndpEntropyBlessed and result.justification.len == 0:
    error("nonDeterminism entropyBlessed requires justification = \"...\": " &
      "state what this tool draws randomness FOR and why it cannot reach " &
      "the tool's output. An unjustified blessing silently restores cache " &
      "publication for a tool whose results may not be reproducible.", node)

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

proc platformConditionHolds(cond: NimNode): bool =
  ## The value of a ``when`` condition guarding ``subTools`` under ``cli:``.
  ## Only ``defined(<platform>)`` and its negation are accepted: the answer
  ## is the platform the recipe is compiled for, the same one a
  ## ``when defined(macosx)`` in the package's own code sees.
  if cond.kind == nnkPrefix and identText(cond[0]) == "not":
    return not platformConditionHolds(cond[1])
  if cond.kind in {nnkCall, nnkCommand} and cond.len == 2 and
      identText(cond[0]) == "defined":
    case identText(cond[1]).normalize
    of "macosx": return defined(macosx)
    of "linux": return defined(linux)
    of "windows": return defined(windows)
    of "posix": return defined(posix)
    else: discard
  error("a `when` under cli: may only test defined(macosx), " &
    "defined(linux), defined(windows) or defined(posix), or their negation",
    cond)

proc platformSubToolsStmts(stmt: NimNode): seq[NimNode] =
  ## The ``subTools`` statements a root ``cli:`` statement contributes on
  ## this platform: the statement itself, or the ``subTools`` statements of
  ## the ``when`` branch that holds. A tool's sub-tools can differ by
  ## platform -- the C compiler ``nim c`` runs is ``gcc`` on Linux and
  ## ``clang`` on macOS -- and a sub-tool another platform needs must not be
  ## declared here, because sub-tools precede the edge's own references on
  ## its ``PATH`` and would shadow them. A branch may hold nothing but
  ## ``subTools``: the rest of the ``cli:`` grammar is not platform-scoped,
  ## and the scope walk would drop it without a word.
  if stmt.kind == nnkWhenStmt:
    proc branchBody(branch: NimNode): NimNode =
      if branch.kind == nnkElifBranch: branch[1] else: branch[0]
    for branch in stmt:
      for inner in branchBody(branch):
        if calleeName(inner).normalize != "subtools":
          error("only subTools may appear inside a `when` under cli:", inner)
    for branch in stmt:
      if branch.kind == nnkElse or platformConditionHolds(branch[0]):
        for inner in branchBody(branch):
          result.add(inner)
        return
  elif calleeName(stmt).normalize == "subtools":
    result.add(stmt)


proc parseCliParamExtension(ext: var ReproCliParamExt; kind: CliParamKind;
                            arg: NimNode): bool =
  ## clispec hook: ``role = input|output|ordinary``, on positionals and flags
  ## alike. Every other argument clispec does not take is left unclaimed,
  ## and clispec ignores it, as the grammar always has.
  let roleValue = namedValue(arg, "role")
  if roleValue.isNil:
    return false
  ext.role = roleLiteral(roleValue, ext.role)
  true

proc requireVisibleOutputFlag(cmd: CliCommandDef; operand: NimNode;
                              statement, purpose: string): string =
  ## The flag an ``optionalOutputs`` / ``removeBeforeRun`` operand names,
  ## which must be a ``role = output`` parameter visible in this scope: only
  ## the tool can declare an output optional or removable, and only for a
  ## path the edge declares as its own.
  if operand.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    error(statement & " expects a flag name identifier, got: " &
      operand.repr, operand)
  result = identText(operand)
  var found = false
  for param in cmd.params:
    if param.name == result:
      found = true
      if param.ext.role != carOutput:
        error(statement & ": '" & result & "' is not an output " &
          "(declare it with `role = output`); " & purpose, operand)
      break
  if not found:
    error(statement & ": '" & result & "' is not a flag or " &
      "positional visible in this cli scope", operand)

proc parseCliCommandExtension(cmd: var CliCommandDef; stmt: NimNode;
                              scope: CliScope): bool =
  ## clispec hook: one statement of a ``cli:`` / ``call:`` / ``subcmd`` scope
  ## that is not a parameter or a nested scope, in source order. Returns
  ## false for a statement this vocabulary does not know, which clispec then
  ## ignores (a ``when`` holding ``subTools`` is read separately, from the
  ## root, by ``parseReproCliBlock``).
  case calleeName(stmt).normalize
  of "dependencypolicy":
    cmd.ext.dependencyPolicy = parseCommandDependencyPolicy(stmt,
      cmd.ext.dependencyPolicy)
  of "nondeterminism":
    # M6: the blessing is inherited from the enclosing ``cli:`` scope exactly
    # the way ``dependencyPolicy`` is, which is what makes it a property of
    # the TOOL: ``nim`` writes it once above its subcommands and both
    # ``nim c`` and ``nim js`` carry it.
    let decl = parseNonDeterminismDecl(stmt,
      (cmd.ext.nonDeterminism, cmd.ext.nonDeterminismJustification))
    cmd.ext.nonDeterminism = decl.policy
    cmd.ext.nonDeterminismJustification = decl.justification
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
      for existing in cmd.ext.typedOutputs:
        if existing.fieldName == td.fieldName:
          duplicate = true
          break
      if not duplicate:
        cmd.ext.typedOutputs.add(td)
    else:
      # Validate every named operand against the currently visible set,
      # telling a flag declared on a sibling subcmd (`not in lexical scope`)
      # from one declared nowhere (`does not exist`).
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
        for param in cmd.params:
          if param.name == flagName:
            visible = true
            break
        if not visible:
          if cliDeclaredParamNames(scope.wholeBody).find(flagName) >= 0:
            error("outputs: '" & flagName &
              "' is not in lexical scope (declared on a sibling subcmd, " &
              "not on this subcmd or an enclosing one)", stmt)
          else:
            error("outputs: '" & flagName &
              "' does not exist (no flag or positional by that name " &
              "declared in this cli interface)", stmt)
        if cmd.ext.outputFlags.find(flagName) < 0:
          cmd.ext.outputFlags.add(flagName)
  of "removebeforerun":
    # ``removeBeforeRun <flag>...`` — outputs the engine removes before
    # the edge runs, for a tool that refuses to write over an existing
    # output (create-dmg's ``hdiutil convert``). Only an OUTPUT parameter
    # may be named: that is what keeps the removal to paths the edge
    # declares as its own, and it is checked here, where the author can
    # still see the declaration.
    if stmt.len < 2:
      error("removeBeforeRun requires at least one output flag name", stmt)
    var operands: seq[NimNode] = @[]
    for i in 1 ..< stmt.len:
      collectOutputsOperands(stmt[i], operands)
    for operand in operands:
      let flagName = requireVisibleOutputFlag(cmd, operand,
        "removeBeforeRun", "only an edge's own outputs may be removed " &
        "before it runs")
      if cmd.ext.removeBeforeRunFlags.find(flagName) < 0:
        cmd.ext.removeBeforeRunFlags.add(flagName)
  of "optionaloutputs":
    # Only the tool can declare an optional candidate. Require an output
    # parameter so arbitrary input paths cannot be removed or claimed.
    if stmt.len < 2:
      error("optionalOutputs requires at least one output flag name", stmt)
    var operands: seq[NimNode] = @[]
    for i in 1 ..< stmt.len:
      collectOutputsOperands(stmt[i], operands)
    for operand in operands:
      let flagName = requireVisibleOutputFlag(cmd, operand,
        "optionalOutputs", "only an edge's own outputs may be optional")
      if cmd.ext.optionalOutputFlags.find(flagName) < 0:
        cmd.ext.optionalOutputFlags.add(flagName)
  of "subtools":
    # Read from the root scope by ``parseReproCliBlock``; refused anywhere
    # else, because it describes the tool, not one of its commands.
    if not scope.isRoot:
      error("subTools is a property of the TOOL: declare it once, " &
        "directly under cli:, not inside a subcmd", stmt)
  else:
    return false
  true

proc parseReproCliBlock(packageName, executableName: string;
                        cliBody: NimNode): seq[CliCommandDef] =
  ## The commands of an ``executable``'s ``cli:`` block: one per ``call:``
  ## or ``subcmd`` (never one for the root scope — the wrapper generator,
  ## the interface artifact pipeline and the rest expect exactly that), with
  ## reprobuild's extension filled in.
  let model = parseCliModel[ReproCliCommandExt, ReproCliParamExt](cliBody,
    # M6: every tool starts UNBLESSED. A tool is blessed only where its own
    # spec says so, in writing, with a reason.
    ReproCliCommandExt(dependencyPolicy: defaultDependencyPolicy(),
      nonDeterminism: ndpUnblessed))
  # ``subTools "a", "b"`` — the bare-name tools this tool shells out to
  # (cargo -> rustc and the C linker). A tool-level property, so it is read
  # from the root scope only and copied onto every command.
  var subTools: seq[string] = @[]
  for rootStmt in cliBody:
    for subToolsStmt in platformSubToolsStmts(rootStmt):
      if subToolsStmt.len < 2:
        error("subTools expects one or more tool names", subToolsStmt)
      for i in 1 ..< subToolsStmt.len:
        let name = stringLiteral(subToolsStmt[i])
        if name.len == 0:
          error("subTools expects string tool names", subToolsStmt[i])
        if name notin subTools:
          subTools.add(name)
  result = model.commands
  for command in result.mitems:
    # clispec records the compiler's file names; the DSL records them the
    # way a recipe-relative or installed-prefix compile must
    # (``recipeSourceName``, as ``lineFile`` does for every other site).
    command.sourceFile = recipeSourceName(command.sourceFile)
    for param in command.params.mitems:
      param.sourceFile = recipeSourceName(param.sourceFile)
    command.ext.providerEntrypointId =
      if command.name.len == 0:
        packageName & "." & executableName & ".call"
      else:
        packageName & "." & executableName & "." & command.path.join(".")
    command.ext.subTools = subTools
