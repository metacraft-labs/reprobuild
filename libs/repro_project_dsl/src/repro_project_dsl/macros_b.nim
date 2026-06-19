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
  let pkgNameLit = newLit(pkg.packageName)
  let devEnvProc =
    if devEnvBody.len > 0:
      quote do:
        when defined(reproProviderMode):
          proc `devEnvProcName`*() =
            `devEnvBody`
    else:
      newStmtList()
  # Project-DSL-Composition M5 — Approach B: wrap the lowered build
  # body in a beginBuildBlock/endBuildBlock try/finally so helper-proc
  # call sites (and unknown preserved top-level statements) can find
  # the active package via `currentBuildState()` / `tryCurrentBuildState()`.
  if lifted.lifts.len == 0:
    let rootBody = lifted.rootBody
    result = quote do:
      when not defined(reproInterfaceMode):
        `devEnvProc`
        proc `procName`*() =
          let buildStateHandle = beginBuildBlock(`pkgNameLit`)
          try:
            `rootBody`
          finally:
            endBuildBlock(buildStateHandle)
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
          let buildStateHandle = beginBuildBlock(`pkgNameLit`)
          try:
            `rootBody`
          finally:
            endBuildBlock(buildStateHandle)
        when defined(reproProviderMode):
          `dispatchProc`
          when isMainModule:
            when compiles(`devEnvProcName`()):
              quit runPackageProvider(`pkgLiteral`, `procName`, `defsLiteral`,
                `dispatchName`, devEnvProc = `devEnvProcName`)
            else:
              quit runPackageProvider(`pkgLiteral`, `procName`, `defsLiteral`,
                `dispatchName`)

proc indentBody(text: string): string =
  ## Two-space-indent every non-empty line. Used by
  ## ``collectImplicitTargetNameHooks`` to inline a hook body into a
  ## generated ``proc … = …`` snippet without losing leading whitespace.
  result = ""
  for line in text.splitLines():
    if line.len == 0:
      result.add("\n")
    else:
      result.add("  ")
      result.add(line)
      result.add("\n")

proc tryParseHookSpec(stmt: NimNode):
    tuple[matched: bool; formalsRepr: string; returnTypeRepr: string;
          bodyRepr: string] =
  ## Named-Targets M0 hook recogniser.
  ##
  ## The user-facing syntax for the per-tool hook is
  ##
  ##   ``implicitTargetName(call: T): string = body``
  ##
  ## which is a complete Nim proc declaration in isolation, but Nim's
  ## parser cannot interpret it as such *inside the executable body* —
  ## that context only takes expressions and statement-list-tagged
  ## calls. As a consequence the construct parses into a peculiar AST
  ## that we reverse-engineer here:
  ##
  ## .. code-block::
  ##
  ##   Call
  ##     ObjConstr
  ##       Ident "implicitTargetName"
  ##       ExprColonExpr(call, T)        # one per formal parameter
  ##     StmtList
  ##       Asgn(<return-type>, <body>)   # ``: ReturnType = body`` collapse
  ##
  ## If the StmtList lacks the ``Asgn`` head we treat the body as a
  ## plain block returning ``string`` (the M0 default). Anything else
  ## is a parse failure and we surface ``matched=false`` so the
  ## ``package`` macro can leave the hook unemitted (the inspection
  ## bit on ``ExecutableDef`` still gets set so the M1 engine knows a
  ## hook *was* declared even if the form is unrecognised).
  result.returnTypeRepr = "string"
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len != 2:
    return
  let head = stmt[0]
  let tail = stmt[1]
  var formals: seq[string] = @[]
  if head.kind == nnkObjConstr and head.len >= 1 and
      identText(head[0]).normalize == "implicittargetname":
    for j in 1 ..< head.len:
      let child = head[j]
      if child.kind == nnkExprColonExpr and child.len == 2:
        formals.add(identText(child[0]) & ": " & child[1].repr)
      else:
        return
  else:
    return
  if tail.kind != nnkStmtList:
    return
  # Two shapes for the body:
  #   * Single child Asgn(<return-type>, <expr>) — the ``: T = body``
  #     collapse described above.
  #   * Anything else — treat the whole StmtList as the proc body and
  #     keep the default ``string`` return type.
  if tail.len == 1 and tail[0].kind == nnkAsgn and tail[0].len == 2:
    result.returnTypeRepr = tail[0][0].repr
    result.bodyRepr = tail[0][1].repr
  else:
    result.bodyRepr = tail.repr
  result.formalsRepr = formals.join("; ")
  result.matched = true

proc collectImplicitTargetNameHooks(pkgBody: NimNode): NimNode =
  ## Named-Targets M0: walk the ``package <name>:`` body and emit one
  ## hook proc for every ``executable <name>:`` block that carries an
  ## ``implicitTargetName(call: T): string`` body. The proc name is
  ## ``implicitTargetNameFor<TitleExportName>`` so multiple executables
  ## in the same package don't collide, and the typed call record is
  ## whatever the author wrote in the formal parameters — the DSL just
  ## rebinds the body verbatim and lets Nim type-check the result. The
  ## M1 engine looks the proc up by name when ``hasImplicitTargetNameHook``
  ## is set on the corresponding ``ExecutableDef``.
  result = newStmtList()
  for stmt in pkgBody:
    if calleeName(stmt).normalize != "executable":
      continue
    if stmt.len < 3:
      continue
    let exeName = identText(stmt[1])
    let exeBody = stmt[2]
    for exeStmt in exeBody:
      # ``implicitTargetName(call: T): string = body`` parses as a Call
      # whose head is an ``ObjConstr`` (see ``tryParseHookSpec``). The
      # Call's callee is the ObjConstr, not a plain ident, so the
      # ordinary ``calleeName`` lookup against ``implicittargetname``
      # never matches — we walk the executable body looking for the
      # ObjConstr shape directly.
      let spec = tryParseHookSpec(exeStmt)
      if not spec.matched:
        continue
      let procName = "implicitTargetNameFor" & titleIdent(exeName)
      let procSrc = "proc " & procName & "*(" & spec.formalsRepr &
        "): " & spec.returnTypeRepr & " =\n" &
        indentBody(spec.bodyRepr)
      result.add(parseStmt(procSrc))

proc emitVariantDeclarations(variants: seq[VariantDecl];
                              pkg: PackageDef): NimNode =
  ## Spec-Implementation M1/M2d: lower the parsed ``VariantDecl`` list
  ## into Nim source code. Emits a single ``import`` of the
  ## configurables umbrella (when variants OR solver-bound dependencies
  ## are present), one ``let <name> = declareVariant[T](<args>)`` per
  ## declaration, one ``registerSolverDependency(...)`` per
  ## ``PackageUseDef`` so the solver sees the package's dependency
  ## graph and conditional gates, plus a trailing ``finalizeVariants()``
  ## call. Together these make every variant's ``.value`` accessor work
  ## and let ``chosenVersion(pkg)`` return the solver-chosen version.
  ##
  ## The generated import is guarded by ``when not declared(...)`` so
  ## projects with multiple ``package`` blocks (or with their own
  ## explicit configurables import) don't get a redeclaration error.
  ##
  ## When neither variants nor tool-uses are present we elide the
  ## entire block — packages with no solver participation pay zero
  ## runtime cost.
  result = newStmtList()
  if variants.len == 0 and pkg.toolUses.len == 0:
    return
  # Emit the import lazily so package files without variants OR
  # solver-bound dependencies don't get an unused import.
  # ``finalizeVariants`` is the sentinel symbol that tells us the
  # configurables module is in scope.
  result.add(parseStmt(
    "when not declared(finalizeVariants):\n" &
    "  import repro_dsl_stdlib/configurables\n"))
  for entry in variants:
    let nameLit = escForCode(entry.name)
    let descLit = escForCode(entry.description)
    let idLit = escForCode(entry.explicitId)
    let fileLit = escForCode(entry.sourceFile)
    let lineLit = $entry.sourceLine
    # The declared default expression is re-parsed by Nim's compiler
    # when the generated ``let`` is type-checked. We pass it verbatim
    # so authors get whatever literal / constant expression syntax they
    # wrote — e.g. ``true``, ``"native"``, ``8080``. The generic ``T``
    # is inferred from the explicit type annotation; we re-emit the
    # nimType repr from the parser.
    let declCode =
      "let " & entry.name & "* = declareVariant[" & entry.nimType & "](\n" &
      "  defaultValue = " & entry.defaultExpr & ",\n" &
      "  scopeName = " & nameLit & ",\n" &
      "  description = " & descLit & ",\n" &
      "  explicitId = " & idLit & ",\n" &
      "  descriptionFile = " & fileLit & ",\n" &
      "  descriptionLine = " & lineLit & ",\n" &
      "  descriptionColumn = 0,\n" &
      "  site = newSourceSite(" & fileLit & ", " & lineLit &
        ", 0, ckDefault))\n"
    result.add(parseStmt(declCode))
  # Spec-Implementation M2d: emit one registerSolverDependency call per
  # parsed PackageUseDef. The solver consumes these to (a) materialize
  # the package version universe (via ``chosenVersion(...)``) and (b)
  # gate variant-conditioned arms (the ``gateVariant`` / ``gateValue``
  # pair is the M2c ``ConditionalGate``). Calls are emitted BEFORE
  # ``finalizeVariants()`` so the registry is populated when the
  # solver runs.
  for useDef in pkg.toolUses:
    if useDef.packageSelector.len == 0: continue
    let parentLit = escForCode(pkg.packageName)
    let depLit = escForCode(useDef.packageSelector)
    let rngLit = escForCode(useDef.rawConstraint)
    let gateVarLit = escForCode(useDef.gateVariant)
    let gateValLit = escForCode(useDef.gateValue)
    result.add(parseStmt(
      "registerSolverDependency(" & parentLit & ", " & depLit & ", " &
      rngLit & ", gateVariant = " & gateVarLit & ", gateValue = " &
      gateValLit & ")\n"))
  result.add(parseStmt("finalizeVariants()\n"))

# ---------------------------------------------------------------------------
# DSL-port M2 — ``config:`` + ``versions:`` block lowerers.
#
# Both lowerers operate on the ``sectionStmts`` partition returned by
# ``partitionPackageBody`` (M1). They walk that statement list looking
# for ``config:`` and ``versions:`` heads and emit one runtime call per
# entry into the result statement list. The result is spliced into the
# ``package`` macro's expansion AFTER the legacy
# ``parsePackageDef`` + ``buildCode`` chain so the M2 emissions sit
# alongside the variant-declaration emissions without colliding.
#
# ─────────────────────────────────────────────────────────────────────
# M1 risk addresses (Path-(B) implementation)
# ─────────────────────────────────────────────────────────────────────
#
# Risk #1 — Lexical-order divergence. M2 takes Path (B): ``config:``
#   entries and ``versions:`` entries are extracted eagerly at
#   macro-expansion time and emit ``recordConfigDefault`` /
#   ``registerVersion`` calls at the END of the macro's lowered output,
#   AFTER the preserved Nim statements. The M2 surface is name-keyed
#   (read by ``readConfigurable[T]("<pkg>.<name>")``), so the eager
#   extraction never depends on a lexical predecessor's runtime value.
#   The Path (A) in-place rewrite is documented as future M3+ work; it
#   becomes load-bearing only when a section lowerer needs to *read* a
#   lexically-preceding ``let`` binding, which neither ``config:`` nor
#   ``versions:`` does in M2.
#
# Risk #2 — ``parsePackageDef`` double-consume. The legacy
#   ``parsePackageDef.config:`` arm calls ``collectConfigSection`` which
#   feeds ``parseVariantDeclaration``. That proc recognises ONLY two
#   shapes — ``name: variant T = default`` (explicit ``variant``
#   keyword) and ``name: T = default`` paired with a ``## @variant``
#   doc directive — and SILENTLY skips everything else. M2's
#   ``collectM2ConfigEntries`` walks the same body but recognises
#   ONLY the plain typed-default shape (``name: T = default``) WHEN it
#   does NOT match either variant spelling. The two paths are therefore
#   mutually exclusive on a per-entry basis: a variant entry lowers to
#   ``declareVariant[T]`` AND NEVER ``recordConfigDefault``; a plain
#   scalar entry lowers to ``recordConfigDefault`` AND NEVER
#   ``declareVariant[T]``. The set discrimination happens locally —
#   each emitter inspects the entry's AST shape and the leading doc
#   directive in the same way the partner emitter does — so we can
#   ship them as independent passes without a shared "this entry is
#   M2-owned" tag.
#
# Risk #3 — variant declarations coordinate with M2 emission. Same
#   resolution as risk #2: ``emitVariantDeclarations`` and
#   ``emitM2ConfigDefaults`` operate on disjoint subsets of the same
#   ``config:`` body. The 11 NDE recipes (kernel, dbus-broker,
#   graphics-stack, …) declare ``name: T = default`` entries without
#   ``## @variant`` so the legacy variant emitter silently drops them;
#   M2's emitter picks them up. The variant-declaring kernel entries
#   (currently zero in production — every kernel knob is the plain
#   typed-default shape) stay routed through the legacy path. No
#   recipe needs a code change.
# ---------------------------------------------------------------------------

proc m2EntryHasVariantDocDirective(pendingDoc: string): bool =
  ## Same predicate ``parseVariantDeclaration`` uses to detect the
  ## ``## @variant`` directive. We duplicate (rather than expose) the
  ## helper so the M2 lowerer can stay self-contained — coupling it
  ## back into ``macros_a.nim`` would entangle two separate code paths
  ## that the milestone explicitly keeps disjoint.
  for line in pendingDoc.splitLines():
    var trimmed = line.strip()
    while trimmed.len > 0 and trimmed[0] == '#':
      trimmed = trimmed[1 .. ^1]
    trimmed = trimmed.strip()
    if trimmed == "@variant":
      return true
  false

proc m2EntryIsExplicitVariant(inner: NimNode): bool =
  ## True when the inner statement of ``name: <inner>`` is
  ## ``variant T = default`` — i.e. the explicit-keyword variant
  ## spelling ``parseVariantDeclaration`` accepts as Shape 1.
  inner.kind == nnkCommand and inner.len == 2 and
    inner[0].kind in {nnkIdent, nnkSym} and
    identText(inner[0]).normalize == "variant" and
    inner[1].kind == nnkExprEqExpr and inner[1].len == 2

proc m2ConfigEntryAst(stmt: NimNode):
    tuple[matched: bool; name: string; typeNode: NimNode; defaultNode: NimNode] =
  ## Recognise the plain typed-default shape
  ## ``name: T = default`` → ``Call(Ident, StmtList(Asgn(Type,
  ## Default)))`` (the same parser shape ``parseVariantDeclaration``'s
  ## Shape 2 inspects). Returns ``matched=false`` for anything else so
  ## the caller can decide what to do with non-matching entries.
  if stmt.kind != nnkCall or stmt.len != 2:
    return
  if stmt[0].kind notin {nnkIdent, nnkSym}:
    return
  if stmt[1].kind != nnkStmtList or stmt[1].len != 1:
    return
  let inner = stmt[1][0]
  if inner.kind != nnkAsgn or inner.len != 2:
    return
  result.matched = true
  result.name = identText(stmt[0])
  result.typeNode = inner[0]
  result.defaultNode = inner[1]

proc collectM2ConfigEntries(configBody: NimNode):
    seq[tuple[name: string; typeNode: NimNode; defaultNode: NimNode]] =
  ## Walk a ``config:`` block's body and return every plain
  ## typed-default entry — i.e. ``name: T = default`` WITHOUT the
  ## ``variant`` keyword AND WITHOUT a preceding ``## @variant`` doc
  ## directive. The remaining entries (explicit variant spelling or
  ## ``@variant`` doc directive) are handled by the legacy variant
  ## path (``parseVariantDeclaration`` in ``macros_a.nim``); the two
  ## passes are mutually exclusive on a per-entry basis so an entry
  ## is never double-emitted (M1 risk #2).
  if configBody.kind != nnkStmtList:
    return
  var pendingDoc = ""
  for stmt in configBody:
    if stmt.kind == nnkCommentStmt:
      if pendingDoc.len > 0: pendingDoc.add "\n"
      pendingDoc.add stmt.strVal
      continue
    let entry = m2ConfigEntryAst(stmt)
    if not entry.matched:
      pendingDoc = ""
      continue
    # Variant by inner-form ``variant T = default`` (Shape 1)?
    let inner =
      if stmt.kind == nnkCall and stmt.len == 2 and
         stmt[1].kind == nnkStmtList and stmt[1].len == 1:
        stmt[1][0]
      else:
        nil
    let isExplicitVariant =
      not inner.isNil and m2EntryIsExplicitVariant(inner)
    let isTaggedVariant = m2EntryHasVariantDocDirective(pendingDoc)
    pendingDoc = ""
    if isExplicitVariant or isTaggedVariant:
      continue
    result.add((name: entry.name,
                typeNode: entry.typeNode,
                defaultNode: entry.defaultNode))

proc m2TypeReprIsPrimitiveScalar(typeRepr: string): bool =
  ## True iff ``typeRepr`` names one of M2's four primitive scalar
  ## shapes (and their sized variants). The check is a deliberate
  ## string-match: at macro-expansion time we only have the verbatim
  ## source repr — semchecking would require a ``typed`` macro and pull
  ## in the full symbol environment.
  typeRepr in ["bool", "int", "int8", "int16", "int32", "int64",
               "uint", "uint8", "uint16", "uint32", "uint64",
               "string", "float", "float32", "float64"]

proc m2IsBareIdentRepr(typeRepr: string): bool =
  ## True iff ``typeRepr`` is a single Nim identifier with no
  ## generic-brackets / dots / spaces — the syntactic shape of a
  ## user-defined enum reference. Authors writing complex types
  ## (``Table[string, int]``, qualified ``foo.Bar``, …) stay silently
  ## passed through.
  if typeRepr.len == 0:
    return false
  for ch in typeRepr:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '_'}:
      return false
  # First char must be a letter or underscore (Nim ident rule).
  typeRepr[0] in {'A'..'Z', 'a'..'z', '_'}

proc m2SeqElementRepr(typeRepr: string): string =
  ## If ``typeRepr`` matches the shape ``seq[<inner>]``, return the
  ## inner repr (with surrounding whitespace stripped); otherwise the
  ## empty string. ``seq[int]`` → ``"int"``, ``seq[string]`` →
  ## ``"string"``, ``seq[DesktopKind]`` → ``"DesktopKind"``.
  if not typeRepr.startsWith("seq[") or not typeRepr.endsWith("]"):
    return ""
  let inner = typeRepr[4 ..< typeRepr.len - 1].strip()
  return inner

proc m2TypeReprIsSupportedScalar(typeRepr: string): bool =
  ## True iff the ``T`` from a ``name: T = default`` entry names one of
  ## the shapes M2 (post-M9.D) handles:
  ##   * a primitive scalar (``bool`` / ``int`` / ``string`` / ``float``
  ##     + sized variants), or
  ##   * a bare identifier (presumed to be an enum type — the runtime's
  ##     ``when T is enum`` branch validates at instantiation), or
  ##   * ``seq[Ident]`` where ``Ident`` is a bare identifier (presumed
  ##     to be a ``seq[Enum]``; ``seq[string]`` and similar primitive
  ##     element types stay rejected here so the runtime's static-error
  ##     branch never fires).
  ##
  ## Authors writing complex types (``Table[string, int]``,
  ## ``seq[seq[X]]``, qualified types, …) get a silent passthrough so
  ## the legacy NDE recipes keep compiling.
  let trimmed = typeRepr.strip()
  if m2TypeReprIsPrimitiveScalar(trimmed):
    return true
  if m2IsBareIdentRepr(trimmed):
    return true
  let inner = m2SeqElementRepr(trimmed)
  if inner.len > 0 and m2IsBareIdentRepr(inner) and
      not m2TypeReprIsPrimitiveScalar(inner):
    return true
  return false

proc emitM2ConfigDefaults(packageName: string;
                          sectionStmts: NimNode): NimNode =
  ## Scan ``sectionStmts`` for every ``config:`` head and emit one
  ## ``recordConfigDefault[T](<packageName>, <name>, <default>)`` call
  ## per recognised entry. The result is appended at the end of the
  ## ``package`` macro's expansion so every registration runs at
  ## module-init time before any host code reads the cell.
  ##
  ## Type filter: M2 only emits for the four primitive types its
  ## ``DslScalarKind`` enum covers (bool / int / string / float and
  ## their sized variants). Entries with non-scalar types
  ## (``seq[string]``, custom enums, …) are silently passed through;
  ## the legacy NDE recipes carry several such entries which would
  ## otherwise trigger a ``recordConfigDefault: unsupported`` static
  ## error at macro-expansion time. M3+ widens the runtime to cover
  ## these shapes when the Cell-backed pathway lands.
  result = newStmtList()
  if sectionStmts.kind != nnkStmtList:
    return
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "config":
      continue
    if stmt.len < 2:
      continue
    let configBody = stmt[stmt.len - 1]
    for entry in collectM2ConfigEntries(configBody):
      let typeRepr = entry.typeNode.repr
      if not m2TypeReprIsSupportedScalar(typeRepr):
        continue
      let nameLit = escForCode(entry.name)
      let pkgLit = escForCode(packageName)
      let defaultRepr = entry.defaultNode.repr
      # ``recordConfigDefault[T]`` is the generic facade in
      # ``dsl_port_runtime.nim``. We emit the explicit generic
      # parameter so Nim picks the bool/int/string/float branch
      # without having to infer from the literal — a literal like ``5``
      # would otherwise lose its desired ``int8`` / ``int32`` flavour.
      result.add(parseStmt(
        "recordConfigDefault[" & typeRepr & "](" &
        pkgLit & ", " & nameLit & ", " & defaultRepr & ")\n"))

proc m2VersionsEntryAst(stmt: NimNode):
    tuple[matched: bool; version: string; body: NimNode] =
  ## Recognise ``"<version-string>": <body>`` inside a ``versions:``
  ## block. Parses as ``Call`` or ``Command`` whose head is a string
  ## literal and tail is an ``nnkStmtList``.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 2:
    return
  if stmt[0].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return
  if stmt[^1].kind != nnkStmtList:
    return
  result.matched = true
  result.version = stmt[0].strVal
  result.body = stmt[^1]

proc emitM2Versions(packageName: string;
                    sectionStmts: NimNode): NimNode =
  ## Scan ``sectionStmts`` for ``versions:`` heads and emit one
  ## ``registerVersion(<packageName>, DslVersionInfo(...))`` call per
  ## inner ``"<version>":`` block. The four named keys
  ## ``sourceRevision``, ``sourceChecksum``, ``sourceUrl``,
  ## ``sourceRepository`` are recognised; everything else is currently
  ## ignored (M3+ widens via the ``extras`` table). Unknown assignment
  ## keys are NOT a hard error — they sit alongside the recognised
  ## keys so authors can co-locate forward-compat fields without a
  ## macro-expansion failure.
  result = newStmtList()
  if sectionStmts.kind != nnkStmtList:
    return
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "versions":
      continue
    if stmt.len < 2:
      continue
    let versionsBody = stmt[stmt.len - 1]
    if versionsBody.kind != nnkStmtList:
      continue
    for versionStmt in versionsBody:
      let parsed = m2VersionsEntryAst(versionStmt)
      if not parsed.matched:
        continue
      var sourceRevision = ""
      var sourceChecksum = ""
      var sourceUrl = ""
      var sourceRepository = ""
      for assignment in parsed.body:
        if assignment.kind notin {nnkAsgn, nnkFastAsgn}:
          continue
        if assignment[0].kind notin {nnkIdent, nnkSym}:
          continue
        if assignment[1].kind notin {nnkStrLit, nnkRStrLit,
                                      nnkTripleStrLit}:
          continue
        let key = identText(assignment[0])
        let value = assignment[1].strVal
        case key
        of "sourceRevision": sourceRevision = value
        of "sourceChecksum": sourceChecksum = value
        of "sourceUrl": sourceUrl = value
        of "sourceRepository": sourceRepository = value
        else: discard
      let pkgLit = escForCode(packageName)
      let versionLit = escForCode(parsed.version)
      let revLit = escForCode(sourceRevision)
      let sumLit = escForCode(sourceChecksum)
      let urlLit = escForCode(sourceUrl)
      let repoLit = escForCode(sourceRepository)
      result.add(parseStmt(
        "registerVersion(" & pkgLit & ", DslVersionInfo(\n" &
        "  version: " & versionLit & ",\n" &
        "  sourceRevision: " & revLit & ",\n" &
        "  sourceChecksum: " & sumLit & ",\n" &
        "  sourceUrl: " & urlLit & ",\n" &
        "  sourceRepository: " & repoLit & "))\n"))

# ---------------------------------------------------------------------------
# DSL-port M3 — ``executable`` / ``library`` / ``files`` artifact lowerer.
#
# M3 ports v8's three artifact templates as an OBSERVER pass that
# records each artifact into the new ``dslPortArtifactRegistry`` sidecar
# (see ``dsl_port_runtime.nim``). The legacy ``parsePackageDef``'s
# ``executable`` and ``library`` arms continue to populate
# ``pkg.executables`` / ``pkg.libraries`` — production's typed-tool
# wrapper, cli interface emission, ``buildXxx*`` proc, and per-package
# const all live downstream of those legacy records. The two pathways
# co-exist by design; the migration plan is documented in
# ``cross_project.nim`` above ``SectionOwnership``.
#
# ─────────────────────────────────────────────────────────────────────
# Path (A) vs Path (B) — decision: A2 (hybrid)
# ─────────────────────────────────────────────────────────────────────
#
# M2 took Path (B) (eager extract at end of macro expansion). M3's
# spec says Path (A) is "likely forced" because artifact bodies
# contain ``build:`` blocks that reference lexically-preceding ``let``
# bindings. The full in-place rewrite (Path A1) would replace each
# ``executable``/``library``/``files`` call/command with a
# ``block: registerArtifact(...)`` expression in source order — but
# this collides with the legacy ``parsePackageDef`` chain whose
# emission STILL needs the original section heads to populate
# ``pkg.executables`` / ``pkg.libraries`` and downstream wrapper
# code.
#
# A2 (hybrid) chosen: keep partition output structure; M3's emitter
# walks the partitioned section list (same as M2's emitters) AND
# emits one ``registerArtifact(...)`` call per recognised entry into
# the macro expansion. The calls are appended AFTER the preserved Nim
# statements so any author-supplied helper proc or ``let`` binding
# the body references is already in scope. Body verbatim recording is
# the only payload M3 actually needs (lowering of cli:/build: is M4+
# work) so the simpler hybrid covers M3's acceptance with no risk to
# the legacy chain.
#
# When M4 lands and starts emitting actual ``cli:`` / ``build:``
# lowerings INSIDE the registered artifact body, M3's emitter will
# pivot to A1 (in-place body rewrite); the runtime API stays
# unchanged.
# ---------------------------------------------------------------------------

proc m3ArtifactNameNode(headNode: NimNode): tuple[matched: bool;
                                                  artifactName: string;
                                                  isIdentForm: bool;
                                                  identNode: NimNode] =
  ## Recognise the name node in ``executable <name>:``. Accepts:
  ##
  ##   * string-form  — ``executable "myTool": ...`` → ``StrLit``;
  ##   * ident-form   — ``executable myTool: ...`` → ``Ident`` / ``Sym`` /
  ##                                                ``AccQuoted``.
  ##
  ## The artifact name is the string verbatim (string-form) or the
  ## ident's text (ident-form, no kebab translation — keeps the
  ## registry's keying scheme symmetric with the source-level spelling).
  case headNode.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    result.matched = true
    result.artifactName = headNode.strVal
    result.isIdentForm = false
    result.identNode = nil
  of nnkIdent, nnkSym, nnkAccQuoted:
    result.matched = true
    result.artifactName = identText(headNode)
    result.isIdentForm = true
    result.identNode = headNode
  else:
    discard

proc m3ArtifactEntryAst(stmt: NimNode):
    tuple[matched: bool; artifactName: string; bodyRepr: string;
          isIdentForm: bool; identNode: NimNode] =
  ## Recognise an artifact-template invocation:
  ##
  ##   ``executable <name>: <body>``
  ##   ``library    <name>: <body>``
  ##   ``files      <name>: <body>``
  ##
  ## All three parse as ``Call(head, name, StmtList(body))`` or the
  ## ``Command`` variant. The section-head (``executable`` /
  ## ``library`` / ``files``) is already discriminated by
  ## ``classifyPackageSections``; here we only extract the name and
  ## the body repr.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 3:
    return
  let nameInfo = m3ArtifactNameNode(stmt[1])
  if not nameInfo.matched:
    return
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return
  result.matched = true
  result.artifactName = nameInfo.artifactName
  result.bodyRepr = body.repr
  result.isIdentForm = nameInfo.isIdentForm
  result.identNode = nameInfo.identNode

proc m3KindLit(ownership: SectionOwnership): NimNode =
  ## Map the section-ownership tag to the matching ``DslArtifactKind``
  ## enum value (as a NimNode reference). The three M3 ownerships are
  ## the only ones this is called for.
  case ownership
  of soM3ExecutableArtifact: ident("dakExecutable")
  of soM3LibraryArtifact:    ident("dakLibrary")
  of soM3FilesArtifact:      ident("dakFiles")
  else:
    # Defensive — caller filters by ownership before calling here.
    ident("dakExecutable")

proc emitM3Artifacts(packageName: string;
                     classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list; for every entry whose ownership
  ## tag claims an M3 artifact, emit one ``registerArtifact(...)`` call
  ## with the artifact's name, kind, and body repr.
  ##
  ## Ident-form injection: ``executable myTool: ...`` additionally
  ## emits ``let myTool {.inject, used.}: DslArtifact = DslArtifact(...)``
  ## so the binding is referenceable from downstream code in the same
  ## scope — mirroring v8's ``Executable[name]`` value-handle return.
  ## The injected handle is the metadata record, NOT the v8
  ## ``Executable[name]`` typed value (which M4+ wires up alongside the
  ## ``cli:`` lowering).
  ##
  ## String-form recovery: ``executable "myTool": ...`` does NOT
  ## inject a binding (there is no Nim identifier to inject); the
  ## registry append is the sole emission.
  ##
  ## Collision guard: ``wrapperCode`` ALWAYS emits
  ## ``const <packageValueIdent>* = <Title>Package()`` at module top
  ## level (see ``macros_a.nim:wrapperCode``). When the artifact ident
  ## matches that const's name — common in stdlib packages where
  ## ``package gcc:`` contains ``executable gcc:`` — the M3 injection
  ## would shadow / redefine the legacy const and fail compilation.
  ## We skip the injection in that case (the runtime registry still
  ## records the artifact; only the per-binding let is suppressed).
  ## M4+ may pivot the legacy const to a typed-tool value, eliminating
  ## the conflict; until then the skip preserves backward compatibility
  ## with every NDE recipe + ``examples/hello-world-c/repro.nim`` +
  ## ``examples/hello-world-multi-output/repro.nim``.
  let pkgValueIdent = packageValueIdent(packageName)
  result = newStmtList()
  for entry in classified:
    if entry.ownership notin {soM3ExecutableArtifact,
                              soM3LibraryArtifact,
                              soM3FilesArtifact}:
      continue
    let parsed = m3ArtifactEntryAst(entry.stmt)
    if not parsed.matched:
      continue
    let pkgLit = newLit(packageName)
    let nameLit = newLit(parsed.artifactName)
    let bodyLit = newLit(parsed.bodyRepr)
    let kindLit = m3KindLit(entry.ownership)
    # Append one record per recognised entry. The ``DslArtifact``
    # object literal is constructed at runtime so the registry append
    # cost stays proportional to the number of artifacts (not the
    # body size — the body repr is captured at macro-expansion time
    # into the ``bodyLit`` string literal).
    let registerCall = quote do:
      registerArtifact(`pkgLit`, DslArtifact(
        packageName: `pkgLit`,
        artifactName: `nameLit`,
        kind: `kindLit`,
        bodyRepr: `bodyLit`))
    let artifactValueIdent =
      if parsed.isIdentForm: packageValueIdent(parsed.artifactName)
      else: ""
    let wouldCollideWithLegacyConst =
      parsed.isIdentForm and artifactValueIdent == pkgValueIdent
    if parsed.isIdentForm and parsed.identNode != nil and
       parsed.identNode.kind in {nnkIdent, nnkAccQuoted} and
       not wouldCollideWithLegacyConst:
      # Ident-form injection. Inject a ``let`` binding so the author
      # can refer to ``myTool`` lexically after the declaration. The
      # ``{.inject, used.}`` pragma pair is the same shape v8's
      # ``transformPackageBody`` uses for library / files ident-form
      # (see ``tools/prototypes/v8/intended/reprobuild.nim`` line
      # ~907). We give the binding the ``DslArtifact`` type so M4+
      # can widen it (e.g. to ``Executable[name]``) without renaming
      # the symbol.
      #
      # We only attempt injection when the ident shape is something
      # we can plausibly redeclare at module top level. ``nnkSym``
      # entries (already-resolved symbols) are rejected — that
      # shouldn't normally happen inside an ``untyped`` macro body
      # but defensive-skip avoids a ``redefinition`` error if the
      # caller hand-quotes a Sym.
      let identNode = parsed.identNode.copyNimTree()
      result.add(quote do:
        `registerCall`
        let `identNode` {.inject, used.}: DslArtifact = DslArtifact(
          packageName: `pkgLit`,
          artifactName: `nameLit`,
          kind: `kindLit`,
          bodyRepr: `bodyLit`))
    else:
      result.add(registerCall)

# ---------------------------------------------------------------------------
# DSL-port M4 — ``build:`` block lowerers (package-level + artifact-scoped).
#
# v8's ``build:`` macro (see ``tools/prototypes/v8/staged/package_catalog/
# project_package_dsl.nim`` line 418) is a context wrapper: push a
# ``BuildBlockState`` onto a thread-local stack, run the body verbatim,
# pop on exit. M4 ports that shape into production.
#
# Two surfaces, both routed off the same partitioned-section input:
#
#   1. Package-level — ``build:`` at the top of a ``package <name>:``
#      body. ``classifySectionStmt`` tags these as ``soM4Build``.
#      ``emitM4BuildActions`` walks the classified seq, picks every
#      ``soM4Build`` entry, and emits one
#      ``beginBuildContext / registerBuildAction / try body finally
#      endBuildContext`` block per entry into the macro expansion.
#
#   2. Artifact-scoped — ``build:`` nested inside ``executable`` /
#      ``library`` / ``files``. The outer artifact is tagged
#      ``soM3*Artifact`` (M3's ownership); ``emitM4ArtifactBuild
#      Lowering`` re-walks that artifact's body looking for ``build:``
#      heads and emits the same wrap-and-register block, but with the
#      artifact name in the second position so ``output()`` calls
#      inside attribute to ``(pkg, artifact)`` rather than ``(pkg,
#      "")``.
#
# Body re-walk discipline: BOTH emitters consume the actual NimNode of
# the ``build:`` body — either directly from the partitioned section
# list (package-level) or from the artifact-body re-walk
# (artifact-scoped). M3 records the artifact's body REPR as a string
# in ``DslArtifact.bodyRepr`` for diagnostic purposes; M4 NEVER calls
# ``parseStmt`` on that string. The recorded ``bodyRepr`` field on
# ``DslBuildAction`` is captured the SAME way (string literal) but is
# also a diagnostic surface only — the lowerer emits the body as a
# verbatim ``NimNode`` splice, not from the repr round-trip.
#
# ─────────────────────────────────────────────────────────────────────
# M3 reviewer risks addressed
# ─────────────────────────────────────────────────────────────────────
#
# Risk #1 — ``bodyRepr`` is a string. M4 re-walks the partitioned
#   section list (and for artifact-scoped builds, re-walks the
#   artifact body in place) to get the actual NimNode. ``parseStmt``
#   on the recorded repr is NEVER invoked.
#
# Risk #2 — Section-ownership migration. M4 ADDS the ``soM4Build``
#   tag and starts using it for the package-level form. ``parsePackageDef``
#   does NOT have a dedicated arm for top-level ``build:`` (its only
#   build-related code path is the ``collectBuildStatements`` walker
#   used by ``buildCode``, which lifts the body into the synthesized
#   ``buildXxxPackage*()`` proc). Therefore M4's package-level emission
#   does NOT displace any ``parsePackageDef`` arm — the new M4 init
#   block runs ALONGSIDE the legacy ``buildXxxPackage*()`` proc
#   emission, and both surfaces coexist. See the "double-emit risk"
#   analysis in the report for the complete argument.
#
#   For artifact-scoped builds, the legacy ``parseExecutable`` /
#   ``parseLibrary`` arms do NOT consume the nested ``build:`` body
#   at all (they only walk for ``name:``, ``cli:``, ``kind:``, etc.).
#   The only legacy consumer of nested ``build:`` is
#   ``collectBuildStatements``, which lifts the body into the same
#   ``buildXxxPackage*()`` proc. Again the two pathways coexist; M4's
#   emission is additive.
#
# Risk #3 — Collision guard / typed-tool handle coordination. M4
#   uses neither the typed-tool handle nor the per-package const —
#   the M4 ``output(path)`` recorder is the only user-facing proc and
#   it operates on the active-context stack frame, not on a named
#   handle. There is no shape M4 emits that could collide with the
#   legacy ``const <pkg>* = <Title>Package()`` or the
#   ``Executable[name]`` typed-tool handles.
#
# Risk #4 — v8's executable requires a ``cli:`` block. M3 already
#   chose NOT to enforce this constraint (artifacts record into the
#   sidecar regardless), and M4 inherits that decision: a ``build:``
#   block inside an ``executable`` artifact records its outputs even
#   when no ``cli:`` is declared. The ``cli:`` lowering arrives in M6
#   and may add the enforcement at that point.
# ---------------------------------------------------------------------------

proc m4BuildEntryBody(stmt: NimNode): NimNode =
  ## Extract the ``StmtList`` body from a ``build:`` section call.
  ##
  ## ``build:`` parses as ``Call(Ident "build", StmtList(...))`` or
  ## ``Command(Ident "build", StmtList(...))``. Returns the inner
  ## ``StmtList`` (a copy so subsequent splicing does not share AST
  ## with the user's source tree); returns ``nil`` for any unexpected
  ## shape so callers can defensively skip.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return nil
  if stmt.len < 2:
    return nil
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return nil
  return body.copyNimTree()

proc emitM4BuildActions*(packageName: string;
                        classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for package-level ``build:``
  ## entries (``soM4Build`` ownership) and emit one wrap-and-register
  ## block per entry. The result is appended to the macro's expansion
  ## AFTER M3's artifact emission, so the ``output(path)`` proc and
  ## the ``beginBuildContext`` runtime helper are in scope.
  ##
  ## Each entry's verbatim Nim body is spliced VERBATIM into the
  ## try-clause — no ``parseStmt(bodyRepr)``, no re-shaping. The
  ## ``bodyRepr`` literal captured here is a DIAGNOSTIC surface only,
  ## consumed by ``registeredBuildActions`` callers that want to verify
  ## what was recorded.
  ##
  ## Provider-mode disjointness: the user's verbatim body is gated on
  ## ``when not defined(reproProviderMode)`` so the legacy
  ## ``buildXxxPackage*()`` proc — which ALSO consumes the body via
  ## ``collectBuildStatements`` and is invoked from
  ## ``runPackageProvider`` under ``--define:reproProviderMode +
  ## isMainModule`` — does NOT see the body run twice in provider
  ## mode. The ``registerBuildAction`` row + the ``beginBuildContext``
  ## push/pop pair remain unconditional so the registry surface is
  ## observable from BOTH modes (provider-mode tooling that wants to
  ## inspect the recorded action shape can still call
  ## ``registeredBuildActions``). See the ownership comment above
  ## ``emitM4BuildActions`` for the complete double-emit analysis.
  result = newStmtList()
  for entry in classified:
    if entry.ownership != soM4Build:
      continue
    let body = m4BuildEntryBody(entry.stmt)
    if body.isNil:
      continue
    let pkgLit = newLit(packageName)
    let artifactLit = newLit("")
    let bodyReprLit = newLit(body.repr)
    # The verbatim body is spliced into the try-clause. Each statement
    # the author wrote runs at module-init time inside the active
    # build context so ``output(path)`` resolves correctly.
    #
    # The body splice itself is gated on ``not defined(reproProviderMode)``
    # to keep the provider-mode legacy chain (``runPackageProvider``
    # → ``buildXxxPackage*()``) the sole executor in that mode. Tests
    # do not define ``reproProviderMode`` so the body still runs at
    # module-init and the M4 acceptance fixtures observe the expected
    # outputs / actions.
    result.add(quote do:
      block:
        registerBuildAction(`pkgLit`, `artifactLit`, `bodyReprLit`)
        beginBuildContext(`pkgLit`, `artifactLit`)
        try:
          when not defined(reproProviderMode):
            `body`
        finally:
          endBuildContext())

proc emitM4ArtifactBuildLowering*(packageName: string;
                                  classified: seq[ClassifiedSection]): NimNode =
  ## For every M3 artifact entry in the classified seq, re-walk its
  ## body looking for nested ``build:`` heads and emit one
  ## wrap-and-register block per entry.
  ##
  ## The re-walk uses ``classifyPackageSections`` on the artifact's body
  ## — the SAME partition seam M3 uses on the package body. The
  ## ``build:`` head inside an artifact body classifies as ``soM4Build``
  ## via ``classifySectionStmt``; we pick those entries and emit a
  ## ``beginBuildContext(packageName, artifactName) / register / try
  ## body finally end`` block, exactly mirroring the package-level
  ## emission but with a non-empty ``artifactName``.
  ##
  ## Why classify the artifact body at all? It's the simplest way to
  ## ALSO survive a recipe author writing ``build:`` MULTIPLE times
  ## inside the same artifact (rare but legal — conditional ``when``
  ## branches that each open a build block). The classifier emits one
  ## entry per syntactic occurrence; the emitter dispatches once per
  ## entry. We deliberately do NOT widen the M4 surface to handle
  ## ``output("name", path)`` (two-arg) or other v8 helpers — that
  ## arrives in M5+ as the build-body lowering deepens. For M4 the
  ## acceptance is the single-arg ``output(path)`` recorder.
  result = newStmtList()
  for entry in classified:
    if entry.ownership notin {soM3ExecutableArtifact,
                              soM3LibraryArtifact,
                              soM3FilesArtifact}:
      continue
    let parsed = m3ArtifactEntryAst(entry.stmt)
    if not parsed.matched:
      continue
    let artifactName = parsed.artifactName
    if entry.stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if entry.stmt.len < 3:
      continue
    let artifactBody = entry.stmt[^1]
    if artifactBody.kind != nnkStmtList:
      continue
    # Re-walk the artifact body via the same classifier. ``build:``
    # heads inside the artifact body classify as ``soM4Build`` and we
    # extract their inner ``StmtList`` to splice verbatim.
    let artifactClassified = classifyPackageSections(artifactBody)
    for innerEntry in artifactClassified:
      if innerEntry.ownership != soM4Build:
        continue
      let body = m4BuildEntryBody(innerEntry.stmt)
      if body.isNil:
        continue
      let pkgLit = newLit(packageName)
      let artifactLit = newLit(artifactName)
      let bodyReprLit = newLit(body.repr)
      # Same provider-mode disjointness as ``emitM4BuildActions``:
      # the user's body splice is gated on
      # ``not defined(reproProviderMode)`` so the legacy
      # ``buildXxxPackage*()`` (which also pulls artifact-scoped
      # ``build:`` bodies via ``collectBuildStatements``) stays the
      # sole executor in provider mode.
      result.add(quote do:
        block:
          registerBuildAction(`pkgLit`, `artifactLit`, `bodyReprLit`)
          beginBuildContext(`pkgLit`, `artifactLit`)
          try:
            when not defined(reproProviderMode):
              `body`
          finally:
            endBuildContext())

# ---------------------------------------------------------------------------
# DSL-port M5 — ``service:`` block lowerer.
#
# v8's ``service`` template (see ``tools/prototypes/v8/staged/package_
# catalog/project_package_dsl.nim`` lines 906-1116) pushes a
# ``ServiceBlockState`` onto a thread-local stack, runs the user body
# (whose body-setters mutate the active frame), then materialises a
# ``ServiceDef`` on the way out. M5 ports the MINIMAL contract:
#
#   * ``service <ident>:`` (named) or ``service "string":`` (string-form).
#   * Body-setter ``executable <ident>`` → records ``executableRef``
#     as the ident's text.
#   * Body-setter ``args "a", "b", ...`` → records ``args`` as the
#     literal string list (in declaration order).
#   * Everything else inside the body is silently preserved into
#     ``bodyRepr`` for diagnostic; M6+ may parse more setters (``on:``
#     triggers, ``hotReload``, ``reloadOnChange``, ``runtimeFile``).
#
# ─────────────────────────────────────────────────────────────────────
# M4 reviewer risks addressed
# ─────────────────────────────────────────────────────────────────────
#
# Risk #1 — Section-ownership: M5 adds the ``soM5Service`` tag distinct
#   from v8's ``service:`` body-setter procs. The legacy
#   ``parsePackageDef`` does NOT recognise ``service:`` at all (no arm
#   in ``macros_a.nim``), so M5's ownership is exclusive — symmetric
#   with M3's ``files:`` treatment. No statement is double-emitted.
#
# Risk #2 — Provider-mode gating: services do NOT have a legacy
#   provider-mode dispatcher (no ``buildXxxPackage*()`` arm consumes
#   ``service:`` bodies). The body-setters we lower (``executable
#   <ident>``, ``args "..."``) have no side effects beyond mutating the
#   active-service frame — they don't shell out, write files, or invoke
#   typed-tool wrappers. We therefore do NOT gate the body splice on
#   ``when not defined(reproProviderMode)``. The unconditional emission
#   keeps the registration observable from BOTH modes; future
#   body-setters that DO have side effects (M5+ ``hotReload`` etc.)
#   can introduce per-setter gating without changing M5's surface.
#
# Risk #3 — Context-stack reuse vs new stack: we introduce a NEW
#   thread-local stack (``dslPortActiveServiceContext``) rather than
#   extending the M4 ``DslBuildContextFrame``. Reasoning is documented
#   above ``dslPortActiveServiceContext`` in ``dsl_port_runtime.nim`` —
#   tl;dr: v8's ``service`` sits at the SAME lexical level as ``build:``
#   in the package body, NOT inside one, so the two stacks should be
#   disjoint. Extending the M4 frame would also ripple the ABI through
#   every M4 emitter site.
#
# Risk #4 — Multi-output registry: ``dslPortServiceRegistry`` is a
#   ``Table[packageName, seq[DslServiceDef]]`` keyed by package name —
#   O(1) per-package lookup AND preserves per-package insertion order
#   (since each bucket is a ``seq``). Symmetric with M2's
#   ``dslPortVersionRegistry`` shape.
#
# Risk #5 — ``currentBuildContext()`` raise convention: M4 returns a
#   zero-value frame on empty (not raise). M5 follows the same
#   convention: the body-setter procs treat an empty active-service
#   stack as a silent no-op rather than raising. This matches v8's
#   ``service`` template behaviour at the source-shape level — body
#   setters appear ONLY inside ``service:`` bodies, so the empty-stack
#   path is unreachable from a correctly-shaped recipe. The no-op exists
#   for defensive safety against macro-expansion bugs.
# ---------------------------------------------------------------------------

proc m5ServiceNameNode(headNode: NimNode):
    tuple[matched: bool; serviceName: string] =
  ## Recognise the name node in ``service <name>:``. Accepts:
  ##
  ##   * string-form  — ``service "myService": ...`` → ``StrLit``;
  ##   * ident-form   — ``service myService: ...`` → ``Ident`` / ``Sym`` /
  ##                                                ``AccQuoted``.
  ##
  ## The service name is the string verbatim (string-form) or the
  ## ident's text (ident-form, no kebab translation — keeps the
  ## registry's keying scheme symmetric with the source-level
  ## spelling). Symmetric with M3's ``m3ArtifactNameNode``.
  case headNode.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    result.matched = true
    result.serviceName = headNode.strVal
  of nnkIdent, nnkSym, nnkAccQuoted:
    result.matched = true
    result.serviceName = identText(headNode)
  else:
    discard

proc m5ServiceEntryAst(stmt: NimNode):
    tuple[matched: bool; serviceName: string; body: NimNode] =
  ## Recognise a service-section invocation:
  ##
  ##   ``service <name>: <body>``
  ##
  ## Parses as ``Call(Ident "service", <name>, StmtList(body))`` or
  ## the ``Command`` variant. The section-head (``service``) is already
  ## discriminated by ``classifyPackageSections``; here we only extract
  ## the name and the body.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 3:
    return
  let nameInfo = m5ServiceNameNode(stmt[1])
  if not nameInfo.matched:
    return
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return
  result.matched = true
  result.serviceName = nameInfo.serviceName
  result.body = body

proc m5ServiceStringLitArg(stmt: NimNode): NimNode =
  ## Recognise a ``setter "literal"`` shape inside a ``service:`` body
  ## and return the string-literal NimNode (already a copy ready to be
  ## spliced into a runtime call). Returns ``nil`` for any other shape
  ## (non-Call/Command stmt, wrong arity, non-string-literal arg).
  ##
  ## Used by the M9.C setters which all share the
  ## ``<head> "string-literal"`` AST shape:
  ##   * ``description "..."``
  ##   * ``type "..."``
  ##   * ``execStart "..."``
  ##   * ``wantedBy "..."``
  ##   * ``wants "..."``
  ##   * ``requires "..."``
  ##   * ``before "..."``
  ##   * ``after "..."``
  ##   * ``restart "..."``
  ##   * ``user "..."``
  ##   * ``group "..."``
  if stmt.kind notin {nnkCall, nnkCommand}:
    return nil
  if stmt.len != 2:
    return nil
  let arg = stmt[1]
  if arg.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return nil
  return arg.copyNimTree()

proc m5ParseServiceBody(body: NimNode): tuple[
    executableRef: string; argStringLits: seq[NimNode];
    descriptionLit: NimNode; typeLit: NimNode; execStartLit: NimNode;
    wantedByLits: seq[NimNode]; wantsLits: seq[NimNode];
    requiresLits: seq[NimNode]; beforeLits: seq[NimNode];
    afterLits: seq[NimNode];
    envPairs: seq[tuple[keyLit: NimNode; valueLit: NimNode]];
    restartLit: NimNode; userLit: NimNode; groupLit: NimNode] =
  ## Walk a ``service:`` body and extract:
  ##
  ##   * ``executable <ident>`` setter → records ``executableRef`` as
  ##     the ident's ``strVal``. Only the LAST occurrence wins (matches
  ##     v8's behavior — v8 raises on the second occurrence, but M5
  ##     keeps the leniency until a real recipe needs the stricter
  ##     check; future tightening goes through the M5+ body-setter
  ##     widening).
  ##   * ``args "a", "b", ...`` setter → appends every string-literal
  ##     argument to ``argStringLits`` in declaration order. Non-literal
  ##     argument nodes are silently skipped — the variant ID surface
  ##     (``cachePort`` ident etc.) only lands in v8 because the staged
  ##     layer evaluates the body at runtime; M5 runs at macro-expansion
  ##     time and can only freeze literals. M5+ widens this when the
  ##     variant-as-string lowering arrives.
  ##
  ## M9.C extensions — systemd-unit metadata setters. All accept a
  ## single string-literal argument (caught by ``m5ServiceStringLit
  ## Arg``); ``env`` uses the call form ``env("KEY", "VALUE")``:
  ##   * ``description "..."`` / ``type "..."`` / ``execStart "..."``
  ##   * ``wantedBy "..."`` / ``wants "..."`` / ``requires "..."``
  ##   * ``before "..."`` / ``after "..."``
  ##   * ``env("KEY", "VALUE")``  — call form (see env-form rationale
  ##     in dsl_port_runtime.nim above ``DslServiceDef.env``)
  ##   * ``restart "..."`` / ``user "..."`` / ``group "..."``
  ##
  ## Other body statements (``hotReload``, ``restartOnCrash``, ``on
  ## change ...``, ``runtimeFile``, …) are silently preserved as raw
  ## body shape; the M5 emitter still captures the full body's ``repr``
  ## into ``DslServiceDef.bodyRepr`` so the diagnostic surface is open
  ## for M6+ to parse them out later.
  result.argStringLits = @[]
  result.wantedByLits = @[]
  result.wantsLits = @[]
  result.requiresLits = @[]
  result.beforeLits = @[]
  result.afterLits = @[]
  result.envPairs = @[]
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 2:
      continue
    let head = stmt[0]
    # We accept ``nnkAccQuoted`` for the head because some M9.C setter
    # names collide with Nim keywords (``type``) and recipes need to
    # write them as ``\`type\` "simple"``. ``identText`` already
    # collapses ``nnkAccQuoted`` to the bare ident string.
    if head.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      continue
    let headName = identText(head).normalize
    case headName
    of "executable":
      # ``executable <ident>`` — record the ident's text. We accept
      # nnkIdent / nnkSym / nnkAccQuoted; anything else is silently
      # skipped (the diagnostic body capture still records it).
      if stmt.len >= 2 and stmt[1].kind in
          {nnkIdent, nnkSym, nnkAccQuoted}:
        result.executableRef = identText(stmt[1])
    of "args":
      # ``args "a", "b", ...`` — append every string-literal argument.
      for i in 1 ..< stmt.len:
        let arg = stmt[i]
        if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          result.argStringLits.add(arg.copyNimTree())
    of "description":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.descriptionLit = lit
    of "type":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.typeLit = lit
    of "execstart":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.execStartLit = lit
    of "wantedby":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.wantedByLits.add(lit)
    of "wants":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.wantsLits.add(lit)
    of "requires":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.requiresLits.add(lit)
    of "before":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.beforeLits.add(lit)
    of "after":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.afterLits.add(lit)
    of "env":
      # ``env("KEY", "VALUE")`` — call form. Two string-literal args.
      # The alternative ``env "KEY"="VALUE"`` form parses as
      # Command(Ident "env", Asgn(StrLit, StrLit)) which is parser-
      # noisy; the call form parses as a clean nnkCall and matches
      # how M5 already lowers ``output("path")`` in M4 emission.
      if stmt.kind == nnkCall and stmt.len == 3 and
          stmt[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
          stmt[2].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        result.envPairs.add((keyLit: stmt[1].copyNimTree(),
                             valueLit: stmt[2].copyNimTree()))
    of "restart":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.restartLit = lit
    of "user":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.userLit = lit
    of "group":
      let lit = m5ServiceStringLitArg(stmt)
      if lit != nil:
        result.groupLit = lit
    else:
      discard

proc emitM5Services*(packageName: string;
                    classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``service:`` entries
  ## (``soM5Service`` ownership) and emit one wrap-and-register block
  ## per entry. The result is appended to the macro's expansion AFTER
  ## M4's emissions so the M5 runtime helpers
  ## (``beginServiceContext`` / ``setActiveServiceExecutable`` /
  ## ``addActiveServiceArg`` / ``finishServiceContext``) are in scope.
  ##
  ## Per-entry emission shape:
  ##
  ##   block:
  ##     beginServiceContext(<pkg>, <serviceName>, <bodyRepr>)
  ##     try:
  ##       setActiveServiceExecutable(<executableRef>)  # if present
  ##       addActiveServiceArg(<arg-1>)                 # per arg
  ##       addActiveServiceArg(<arg-2>)
  ##       ...
  ##     finally:
  ##       finishServiceContext()
  ##
  ## The body-setter calls are NOT spliced from the user's body
  ## verbatim — we parse the executable ref + args out at macro
  ## expansion time and emit the equivalent runtime calls. This avoids
  ## having to make the body-setter idents (``executable`` / ``args``)
  ## bind to something callable in the lexical scope. The full body's
  ## ``repr`` is captured into ``DslServiceDef.bodyRepr`` for
  ## diagnostic surfacing; M6+ may pivot to a verbatim splice when the
  ## body-setter taxonomy grows.
  result = newStmtList()
  for entry in classified:
    if entry.ownership != soM5Service:
      continue
    let parsed = m5ServiceEntryAst(entry.stmt)
    if not parsed.matched:
      continue
    let parsedBody = m5ParseServiceBody(parsed.body)
    let pkgLit = newLit(packageName)
    let svcNameLit = newLit(parsed.serviceName)
    let bodyReprLit = newLit(parsed.body.repr)
    let exeRefLit = newLit(parsedBody.executableRef)
    # Build the try-clause body: one setActiveServiceExecutable call
    # (only when the body provided a ref) plus one addActiveServiceArg
    # per recognised string-literal arg. M9.C extensions emit one
    # body-setter call per recognised systemd-unit setter.
    let tryBody = newStmtList()
    if parsedBody.executableRef.len > 0:
      tryBody.add(quote do:
        setActiveServiceExecutable(`exeRefLit`))
    for argLit in parsedBody.argStringLits:
      tryBody.add(quote do:
        addActiveServiceArg(`argLit`))
    # M9.C: scalar (last-wins) setters — only emit when the body
    # provided a literal so unused defaults stay as the runtime's
    # empty-string ground state.
    if parsedBody.descriptionLit != nil:
      let lit = parsedBody.descriptionLit
      tryBody.add(quote do:
        setActiveServiceDescription(`lit`))
    if parsedBody.typeLit != nil:
      let lit = parsedBody.typeLit
      tryBody.add(quote do:
        setActiveServiceType(`lit`))
    if parsedBody.execStartLit != nil:
      let lit = parsedBody.execStartLit
      tryBody.add(quote do:
        setActiveServiceExecStart(`lit`))
    # M9.C: repeating (append-per-occurrence) setters.
    for lit in parsedBody.wantedByLits:
      tryBody.add(quote do:
        addActiveServiceWantedBy(`lit`))
    for lit in parsedBody.wantsLits:
      tryBody.add(quote do:
        addActiveServiceWants(`lit`))
    for lit in parsedBody.requiresLits:
      tryBody.add(quote do:
        addActiveServiceRequires(`lit`))
    for lit in parsedBody.beforeLits:
      tryBody.add(quote do:
        addActiveServiceBefore(`lit`))
    for lit in parsedBody.afterLits:
      tryBody.add(quote do:
        addActiveServiceAfter(`lit`))
    # M9.C: env("KEY", "VALUE") — call form, one record per pair.
    for pair in parsedBody.envPairs:
      let keyLit = pair.keyLit
      let valueLit = pair.valueLit
      tryBody.add(quote do:
        addActiveServiceEnv(`keyLit`, `valueLit`))
    # M9.C: scalar (last-wins) run-as / restart setters.
    if parsedBody.restartLit != nil:
      let lit = parsedBody.restartLit
      tryBody.add(quote do:
        setActiveServiceRestart(`lit`))
    if parsedBody.userLit != nil:
      let lit = parsedBody.userLit
      tryBody.add(quote do:
        setActiveServiceUser(`lit`))
    if parsedBody.groupLit != nil:
      let lit = parsedBody.groupLit
      tryBody.add(quote do:
        setActiveServiceGroup(`lit`))
    # The package-init block. The body-setter splice is unconditional
    # (no provider-mode gate) — see the "Risk #2" commentary above the
    # M5 emitter for the rationale.
    result.add(quote do:
      block:
        beginServiceContext(`pkgLit`, `svcNameLit`, `bodyReprLit`)
        try:
          `tryBody`
        finally:
          finishServiceContext())

# ---------------------------------------------------------------------------
# DSL-port M6 — ``cli:`` block ``pos`` / ``flag`` / ``boolFlag`` lowerer.
#
# v8's ``cli`` template (see ``tools/prototypes/v8/staged/package_
# catalog/project_package_dsl.nim`` line 830) pushes a CLI-scope handle
# onto a graph stack and runs the user body. Inside, the
# ``pos`` / ``flag`` / ``boolFlag`` macros (lines 682-820) emit a
# ``recordCliPos`` / ``recordCliFlag`` / ``recordCliBoolFlag`` call per
# statement keyed off the current section (root or ``subcmd``). M6 ports
# the MINIMAL contract: each statement registers one ``DslCliParam`` row
# against ``<pkg>.<artifact>.<subcmd="">`` via ``registerCliParam``.
#
# ─────────────────────────────────────────────────────────────────────
# Scope decisions (deferred to a follow-on milestone)
# ─────────────────────────────────────────────────────────────────────
#
# * Subcommand nesting. v8 walks ``subcmd "<name>":`` heads inside
#   ``cli:`` and routes recorded params to the matching section. M6
#   honours ROOT params only; the schema reserves the ``subcmd`` field
#   so the deferral does not require a registry schema bump. See the
#   "Honest deferrals" report in M6's commit log.
#
# * Per-parameter options (``alias = "..."``, ``required = true``,
#   ``position = 2``, ``name = "...override"``). The legacy
#   ``parseParam`` chain handles these for typed-tool wrapper emission;
#   M6's registry captures only the minimal ``(name, typeName, kind)``
#   triple plus the bucket key.
#
# * ``policy`` declarations inside ``cli:``. v8's ``policy``
#   (project_package_dsl.nim line 822) is currently consumed by the
#   legacy ``parseCommandDependencyPolicy`` arm; M6 skips it.
#
# ─────────────────────────────────────────────────────────────────────
# M5 reviewer risks addressed
# ─────────────────────────────────────────────────────────────────────
#
# Risk #1 — Section-ownership: ``cli:`` is an artifact-INTERNAL sub-block
#   (sits inside ``executable``/``library``/``files`` bodies), NOT a
#   top-level package section. ``classifySectionStmt`` therefore does
#   NOT introduce a new top-level ownership tag; instead M6 piggybacks
#   on the M3 ``soM3*Artifact`` tags and RE-WALKS the artifact body
#   (same pattern M4 uses in ``emitM4ArtifactBuildLowering``). The
#   legacy ``parseExecutable``'s ``cli:`` arm continues to walk the same
#   body and populate ``pkg.executables[].commands`` for the typed-tool
#   wrapper emission — the two sidecars are disjoint and no Nim code is
#   double-emitted.
#
# Risk #2 — Provider-mode gating: M6 only registers metadata into the
#   sidecar registry; it does not splice any user body. Provider-mode
#   gating is therefore N/A (no double-execution risk).
#
# Risk #3 — Empty-stack convention: there is no M6 active-context
#   stack. The emitter knows ``(packageName, artifactName)`` at
#   macro-expansion time via the re-walk; the ``subcmd`` slot is
#   always "" for M6 (root-scope only). Future milestones that add
#   subcmd nesting will introduce a per-subcmd push/pop pair, mirroring
#   M4 / M5 — at which point the empty-stack convention follows M4 /
#   M5's "silent no-op" precedent.
#
# Risk #4 — Multi-bucket registry: ``dslPortCliParams`` is a
#   ``Table[string, seq[DslCliParam]]`` keyed by
#   ``<pkg>.<artifact>.<subcmd>``. The key uniquely identifies a
#   bucket and preserves per-bucket insertion order. Symmetric with
#   M4's ``dslPortOutputs`` keying convention.
# ---------------------------------------------------------------------------

proc m6CliBlockBody(stmt: NimNode): NimNode =
  ## Extract the ``StmtList`` body from a ``cli:`` section call.
  ##
  ## ``cli:`` parses as ``Call(Ident "cli", StmtList(...))`` or
  ## ``Command(Ident "cli", StmtList(...))``. Returns the inner
  ## ``StmtList`` (no copy — M6 only reads it for spec extraction);
  ## returns ``nil`` for any unexpected shape so callers can
  ## defensively skip.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return nil
  if stmt.len < 2:
    return nil
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return nil
  return body

proc m6CliParamKindLit(kind: DslCliParamKind): NimNode =
  ## Render a ``DslCliParamKind`` literal as a NimNode reference. Used
  ## by the emitter to construct the kind argument of the
  ## ``registerCliParam(...)`` runtime call.
  case kind
  of cpkPos:      ident("cpkPos")
  of cpkFlag:     ident("cpkFlag")
  of cpkBoolFlag: ident("cpkBoolFlag")

proc m6ParseCliParam(stmt: NimNode):
    tuple[matched: bool; name: string; typeName: string;
          kind: DslCliParamKind] =
  ## Parse one ``pos <name> is <Type>`` / ``flag <name> is <Type>`` /
  ## ``boolFlag <name>`` statement out of a ``cli:`` body. Returns
  ## ``matched = false`` for any other shape (silently skipped — the
  ## body may also contain ``subcmd "<name>":`` heads, ``outputs``
  ## statements, ``dependencyPolicy``, etc., which M6 does not
  ## consume).
  ##
  ## Type extraction: M6 recognises ``<name> is <Type>`` (the v8
  ## ``typedIsArg`` form, ``project_package_dsl.nim`` line 674). The
  ## type NimNode is rendered via ``.repr`` to a string —
  ## "string" / "int" / "bool" / "seq[string]" — matching v8's
  ## ``cliTypeNameFromNode`` output for the common shapes. For
  ## ``boolFlag`` the source omits the type; we default the recorded
  ## ``typeName`` to "bool".
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 2:
    return
  let head = stmt[0]
  if head.kind notin {nnkIdent, nnkSym}:
    return
  let headName = identText(head).normalize
  case headName
  of "pos":
    result.kind = cpkPos
  of "flag":
    result.kind = cpkFlag
  of "boolflag":
    result.kind = cpkBoolFlag
  else:
    return
  let nameArg = stmt[1]
  # Common case: ``<name> is <Type>`` infix.
  if nameArg.kind == nnkInfix and nameArg.len == 3 and
      nameArg[0].eqIdent("is"):
    if nameArg[1].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      return
    result.name = identText(nameArg[1])
    result.typeName = nameArg[2].repr
    result.matched = true
    return
  # Bare-name case: ``boolFlag verbose`` (no type, defaults to "bool").
  # Also accept ``pos input`` / ``flag x`` defensively even though
  # those are non-canonical (legacy ``parseParam`` errors on them).
  if nameArg.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    result.name = identText(nameArg)
    result.typeName =
      if result.kind == cpkBoolFlag: "bool"
      else: "string"
        # Fallback for the bare ``flag`` / ``pos`` shape — M6 does not
        # emit these in any of its acceptance fixtures, but the
        # default keeps the registry well-formed if a recipe author
        # writes the shape regardless. The legacy ``parseParam`` chain
        # surfaces the missing-type error elsewhere.
    result.matched = true

proc m6EmitParamRegistration(packageName, artifactName, subcmd: string;
                             param: tuple[matched: bool; name: string;
                                          typeName: string;
                                          kind: DslCliParamKind]): NimNode =
  ## Build one ``registerCliParam(...)`` call site for the given
  ## parsed parameter. Caller has already validated ``param.matched``.
  let pkgLit = newLit(packageName)
  let artifactLit = newLit(artifactName)
  let subcmdLit = newLit(subcmd)
  let nameLit = newLit(param.name)
  let typeLit = newLit(param.typeName)
  let kindLit = m6CliParamKindLit(param.kind)
  quote do:
    registerCliParam(`pkgLit`, `artifactLit`, `subcmdLit`,
                     `nameLit`, `typeLit`, `kindLit`)

proc emitM6CliLowering*(packageName: string;
                       classified: seq[ClassifiedSection]): NimNode =
  ## For every M3 artifact entry in the classified seq, re-walk the
  ## artifact body looking for a nested ``cli:`` head and emit one
  ## ``registerCliParam(...)`` per recognised ``pos`` / ``flag`` /
  ## ``boolFlag`` statement.
  ##
  ## Mirrors the body-rewalk pattern M4's
  ## ``emitM4ArtifactBuildLowering`` uses: read the artifact body
  ## from the partitioned section list (NOT from the recorded
  ## ``bodyRepr`` string — never ``parseStmt`` a repr round-trip),
  ## scan its top-level statements for the ``cli:`` head, and
  ## dispatch inside its inner ``StmtList``.
  ##
  ## Subcommand handling: deferred. Any ``subcmd "<name>":`` head
  ## inside the ``cli:`` body is silently skipped — the params it
  ## declares do NOT show up in M6's registry. Follow-on milestone
  ## opens the per-subcmd walker; the schema's ``subcmd`` field is
  ## already wired.
  result = newStmtList()
  for entry in classified:
    if entry.ownership notin {soM3ExecutableArtifact,
                              soM3LibraryArtifact,
                              soM3FilesArtifact}:
      continue
    let parsed = m3ArtifactEntryAst(entry.stmt)
    if not parsed.matched:
      continue
    let artifactName = parsed.artifactName
    if entry.stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if entry.stmt.len < 3:
      continue
    let artifactBody = entry.stmt[^1]
    if artifactBody.kind != nnkStmtList:
      continue
    # Walk the artifact body for ``cli:`` heads. We do NOT re-classify
    # via ``classifyPackageSections`` here — ``cli:`` is not a
    # top-level section type, so it has no entry in
    # ``classifySectionStmt`` and would land on the legacy ownership.
    # Direct head-name match is sufficient.
    for inner in artifactBody:
      if calleeName(inner).normalize != "cli":
        continue
      let cliBody = m6CliBlockBody(inner)
      if cliBody.isNil:
        continue
      # Dispatch on each top-level statement of the ``cli:`` body.
      # Statements we don't recognise (``subcmd``, ``outputs``,
      # ``dependencyPolicy``, ``policy``) are silently skipped — the
      # legacy ``parseExecutable`` arm continues to consume them via
      # ``parseCliScope`` for the typed-tool wrapper emission.
      for cliStmt in cliBody:
        let p = m6ParseCliParam(cliStmt)
        if not p.matched:
          continue
        result.add(m6EmitParamRegistration(
          packageName, artifactName, "", p))

# ---------------------------------------------------------------------------
# DSL-port M9.E — ``variant <configField>:`` + ``validate:`` lowerers.
#
# ## variant <configField>: arm parsing
#
# Source-level shape (the v8 spec memo's example, adapted to Nim's parser):
#
#   variant desktopKind:
#     `case` dkSway:
#       uses "sway >=0.1.0"
#     `case` dkGnome:
#       uses "gnome >=0.1.0"
#
# Note the backticked ``\`case\``. Nim's parser reserves ``case`` for
# case-statements which require ``of`` branches; using the bare keyword
# inside a package body fails with ``invalid indentation``. The
# backticked form parses as ``Command(AccQuoted(Ident "case"),
# Ident "dkSway", StmtList(...))`` which the emitter recognises.
# Authors get the same look-and-feel as the v8 prototype; the backticks
# are the cost of staying inside Nim's grammar.
#
# Each ``\`case\``-arm body MAY contain one or more ``uses "string"``
# statements. M9.E supports ONLY ``uses:`` arms — other body shapes
# (``build:`` / ``service:`` / ``files:`` per-arm bodies) are explicit
# deferrals; they appear inside the arm body but the emitter silently
# skips them. The full body's ``$body.repr`` is captured into
# ``DslVariantArm.usesClauses`` ONLY for the recognised ``uses:``
# entries — diagnostics for the deferred shapes can be added when the
# next milestone lands.
#
# At emission time, the macro emits:
#
#     registerVariantArm("<pkg>", "<configField>", "<armValue>",
#                        ord(<armValueIdent>), @[<usesClauses>])
#
# The ``ord(<armValueIdent>)`` call is evaluated at MODULE-INIT TIME
# (not at macro-expansion) because Nim's enum literals are typed values
# the Nim VM only resolves once their type context is in scope. The
# enum identifier MUST be visible at module scope at the point the
# ``package`` macro emits its registration block; this matches the
# pattern M9.D uses for ``recordConfigDefault[E](pkg, name, dkSway)``
# (the recipe declares the enum at module top level above the
# ``package`` block).
#
# ## validate: body parsing
#
# The expected body shape is a single ``proc(): bool = ...`` lambda
# literal:
#
#   validate:
#     proc(): bool =
#       readConfigurable[DesktopKind]("pkg", "activeAtBoot", dkSway) in
#         readConfigurable[seq[DesktopKind]]("pkg", "desktopKind", @[])
#
# The macro splices the lambda verbatim as the third argument of a
# ``registerValidateExpr("<pkg>", "<exprRepr>", <lambda>)`` call. The
# expression-repr is captured via ``$lambdaBody.repr`` so the
# diagnostic message surfaces something close to the source-level
# predicate.
#
# Future ergonomic shortcut (explicit deferral): we could detect a bare
# expression (``nnkInfix(in, ...)`` etc.) and wrap it inside a
# ``proc(): bool = <expr>`` automatically, with config-field bindings
# auto-injected by enumerating the M2 ``config:`` block above the
# ``validate:`` head. That requires the macro to scan the partitioned
# section list for field idents + types, then emit per-field
# ``let <field> = readConfigurable[T](...)`` bindings inside the
# generated closure. Pragmatic deferral for M9.E — the closure form
# above is what every fixture today uses.
# ---------------------------------------------------------------------------

proc m9eVariantHeadAst(stmt: NimNode):
    tuple[matched: bool; configField: string; body: NimNode] =
  ## Recognise ``variant <configField>: <body>``. Parses as
  ## ``Call(Ident "variant", <configField>, StmtList(body))`` or the
  ## ``Command`` variant. The ``variant`` head is already discriminated
  ## by ``classifyPackageSections``; here we only extract the field
  ## name and the body.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 3:
    return
  let nameNode = stmt[1]
  if nameNode.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return
  result.matched = true
  result.configField = identText(nameNode)
  result.body = body

proc m9eVariantArmAst(stmt: NimNode):
    tuple[matched: bool; armIdent: NimNode; body: NimNode] =
  ## Recognise a ``\`case\` <enumValue>: <body>`` arm. Parses as
  ## ``Command(AccQuoted(Ident "case"), <armIdent>, StmtList(body))``.
  ## Also accepts the bare-ident form ``of <enumValue>:`` for symmetry
  ## with case-statement spelling — but Nim's parser only honours ``of``
  ## inside a ``case``-statement context, so in practice every arm
  ## comes through as the backticked head.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return
  if stmt.len < 3:
    return
  let head = stmt[0]
  let headName =
    if head.kind == nnkAccQuoted: identText(head)
    elif head.kind in {nnkIdent, nnkSym}: identText(head)
    else: ""
  if headName.normalize notin ["case", "of"]:
    return
  let armNode = stmt[1]
  if armNode.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return
  let body = stmt[^1]
  if body.kind != nnkStmtList:
    return
  result.matched = true
  result.armIdent = armNode
  result.body = body

proc m9eCollectUsesClauses(armBody: NimNode): seq[NimNode] =
  ## Scan an arm body for ``uses "string"`` statements; return one
  ## string-literal NimNode per recognised clause (already copied so
  ## the splice is safe). Non-``uses:`` body statements are silently
  ## ignored — M9.E's per-arm support is restricted to ``uses:`` as an
  ## explicit deferral.
  result = @[]
  if armBody.kind != nnkStmtList:
    return
  for stmt in armBody:
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len != 2:
      continue
    let head = stmt[0]
    if head.kind notin {nnkIdent, nnkSym}:
      continue
    if identText(head).normalize != "uses":
      continue
    let arg = stmt[1]
    if arg.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      continue
    result.add(arg.copyNimTree())

proc emitM9EVariantArms*(packageName: string;
                         classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``soM9EVariant`` entries and
  ## emit one ``registerVariantArm(...)`` call per recognised
  ## ``\`case\` <enumValue>:`` arm inside each ``variant
  ## <configField>:`` body.
  ##
  ## Per-arm emission shape:
  ##
  ##   registerVariantArm(<pkg>, <configField>, "<armValue>",
  ##                      ord(<armIdent>), @["use-1", "use-2", ...])
  ##
  ## The ``ord(<armIdent>)`` reads the enum value's ordinal at
  ## module-init time; the enum type MUST be visible at module scope
  ## above the ``package`` macro invocation (the recipe declares the
  ## enum at module top level — same shape M9.D recipes already use).
  result = newStmtList()
  for entry in classified:
    if entry.ownership != soM9EVariant:
      continue
    let parsed = m9eVariantHeadAst(entry.stmt)
    if not parsed.matched:
      continue
    let pkgLit = newLit(packageName)
    let fieldLit = newLit(parsed.configField)
    for armStmt in parsed.body:
      let armParsed = m9eVariantArmAst(armStmt)
      if not armParsed.matched:
        continue
      let armValueStr = identText(armParsed.armIdent)
      if armValueStr.len == 0:
        continue
      let armValueLit = newLit(armValueStr)
      let armIdentNode = armParsed.armIdent.copyNimTree()
      # The ``armValueRepr`` expression evaluates ``$<armIdent>`` at
      # module-init time so it reflects an enum's explicit string value
      # when present (e.g. ``$dkSway == "sway"`` for ``dkSway = "sway"``;
      # ``$dkSway == "dkSway"`` for a bare ``dkSway``). NDE-I close-out:
      # bridges the M9.E source-ident capture with M9.D's ``$value``
      # stored spelling so ``activeVariantArms`` matches under both
      # explicit- and bare-value enum shapes.
      let armReprExpr = nnkPrefix.newTree(ident("$"),
                                          armIdentNode.copyNimTree())
      # Build the @["..", ".."] bracket of uses-clauses.
      let usesBracket = nnkPrefix.newTree(
        ident("@"), nnkBracket.newTree())
      for clauseLit in m9eCollectUsesClauses(armParsed.body):
        usesBracket[1].add(clauseLit)
      result.add(quote do:
        registerVariantArm(`pkgLit`, `fieldLit`, `armValueLit`,
                           ord(`armIdentNode`), `usesBracket`,
                           armValueRepr = `armReprExpr`))

proc m9eValidateClosureFromBody(body: NimNode): NimNode =
  ## Inspect a ``validate:`` body. The expected shape is a single
  ## ``proc(): bool = ...`` lambda literal; we splice it verbatim as
  ## the closure argument of ``registerValidateExpr``. The body may
  ## also be a ``StmtList`` wrapping the lambda; we unwrap once.
  ##
  ## Returns ``nil`` when the body does not match — the emitter then
  ## silently skips emission (no Nim code generated). The body's repr
  ## is still captured for the diagnostic surface via a sibling helper.
  var node = body
  if node.kind == nnkStmtList and node.len == 1:
    node = node[0]
  if node.kind in {nnkLambda, nnkProcDef, nnkDo}:
    return node.copyNimTree()
  return nil

proc emitM9EValidates*(packageName: string;
                      classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``soM9EValidate`` entries and
  ## emit one ``registerValidateExpr(<pkg>, <exprRepr>, <closure>)``
  ## call per recognised block.
  ##
  ## The closure body is the user's ``proc(): bool = ...`` literal,
  ## spliced verbatim. The ``exprRepr`` argument is the body's
  ## ``$body.repr`` (captured at macro-expansion time) so the runtime
  ## diagnostic message points back to source-level intent.
  result = newStmtList()
  for entry in classified:
    if entry.ownership != soM9EValidate:
      continue
    let stmt = entry.stmt
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 2:
      continue
    let body = stmt[^1]
    if body.kind != nnkStmtList:
      continue
    let closureNode = m9eValidateClosureFromBody(body)
    if closureNode == nil:
      continue
    let pkgLit = newLit(packageName)
    let exprReprLit = newLit(body.repr)
    result.add(quote do:
      registerValidateExpr(`pkgLit`, `exprReprLit`, `closureNode`))

# ---------------------------------------------------------------------------
# DSL-port M9.G — ``bootloader:`` block lowerer.
#
# Source-level shape (the v8 spec memo's NDEM1 example):
#
#   package reproosDesktop:
#     bootloader:
#       generationEntry: true
#       timeout: 5
#       menuEntry:
#         title "ReproOS - generation {{ generation.id }}"
#         kernel "/boot/vmlinuz-{{ generation.id }}"
#         initrd "/boot/initrd.img-{{ generation.id }}"
#         cmdline "root=LABEL=ReproOS ro quiet"
#
# Per-package single block; nested setters dispatched on head name. The
# ``generationEntry`` / ``timeout`` / ``defaultEntry`` setters are
# lowered to ``registerBootloaderConfig(...)`` calls (one per setter —
# the runtime merges into the row keyed by ``packageName`` so argument
# order does not matter). Each ``menuEntry:`` body is lowered to a
# ``registerBootloaderMenuEntry(...)`` call with the four canonical
# fields (title/kernel/initrd/cmdline) extracted from the body's setter
# statements.
#
# Setters with unrecognised heads or non-string-literal payloads inside
# a ``menuEntry:`` body are silently skipped — they appear in the
# diagnostic surface via the runtime's ``extras`` slot when a future
# milestone widens the field set. Skipped payloads default to ``""``.
# ---------------------------------------------------------------------------

proc m9gUnwrapSetterPayload(arg: NimNode): NimNode =
  ## Unwrap a setter payload node. The DSL recognises two source-level
  ## spellings for setters:
  ##
  ##   * ``key value`` — parses as ``Command(Ident "key", <payloadNode>)``
  ##     where ``stmt[1]`` is the payload directly.
  ##   * ``key: value`` — parses as ``Call(Ident "key", StmtList(
  ##     <payloadNode>))`` where ``stmt[1]`` is a ``StmtList`` wrapping
  ##     the payload.
  ##
  ## Returns the underlying payload node in either case; returns the
  ## input verbatim for any other shape so caller-level matchers can
  ## reject it.
  if arg.kind == nnkStmtList and arg.len == 1:
    return arg[0]
  return arg

proc m9gExtractStrLit(arg: NimNode): string =
  ## Extract a string-literal payload from a setter argument. Returns
  ## ``""`` when the argument is not a string literal. Handles both
  ## the ``key "value"`` (Command) and ``key: "value"`` (Call+StmtList)
  ## spellings via ``m9gUnwrapSetterPayload``.
  let n = m9gUnwrapSetterPayload(arg)
  if n.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return n.strVal
  return ""

proc m9gExtractBoolLit(arg: NimNode): tuple[matched: bool; value: bool] =
  ## Extract a bool-literal payload from a setter argument. Recognises
  ## ``true`` / ``false`` idents (Nim parses bare ``true`` / ``false``
  ## as ``nnkIdent``) AND ``nnkSym`` references that resolve to the bool
  ## values. Returns ``(matched=false, ...)`` for anything else. Handles
  ## both the ``key true`` (Command) and ``key: true`` (Call+StmtList)
  ## spellings via ``m9gUnwrapSetterPayload``.
  let n = m9gUnwrapSetterPayload(arg)
  if n.kind in {nnkIdent, nnkSym}:
    let s = identText(n).normalize
    if s == "true":
      return (true, true)
    if s == "false":
      return (true, false)

proc m9gExtractIntLit(arg: NimNode): tuple[matched: bool; value: int] =
  ## Extract an int-literal payload from a setter argument. Returns
  ## ``(matched=false, ...)`` when the argument is not an integer
  ## literal. Handles both the ``key 5`` (Command) and ``key: 5`` (Call+
  ## StmtList) spellings via ``m9gUnwrapSetterPayload``.
  let n = m9gUnwrapSetterPayload(arg)
  if n.kind in {nnkIntLit, nnkInt8Lit, nnkInt16Lit,
                nnkInt32Lit, nnkInt64Lit}:
    return (true, int(n.intVal))

proc m9gSetterHeadName(stmt: NimNode): string =
  ## Return the lowercased head ident name of a setter statement, or
  ## ``""`` when the statement is not a simple setter shape.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return ""
  if stmt.len < 2:
    return ""
  let head = stmt[0]
  if head.kind notin {nnkIdent, nnkSym}:
    return ""
  result = identText(head).normalize

proc m9gParseMenuEntry(body: NimNode):
    tuple[title, kernel, initrd, cmdline: string] =
  ## Walk a ``menuEntry:`` body and extract the four canonical string
  ## fields. Missing fields default to ``""`` — the recipe author is
  ## responsible for declaring every field the apply phase needs.
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    let head = m9gSetterHeadName(stmt)
    if head.len == 0:
      continue
    if stmt.len != 2:
      continue
    let payload = m9gExtractStrLit(stmt[1])
    case head
    of "title": result.title = payload
    of "kernel": result.kernel = payload
    of "initrd": result.initrd = payload
    of "cmdline": result.cmdline = payload
    else: discard

proc emitM9GBootloader*(packageName: string;
                       classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``soM9GBootloader`` entries
  ## and emit one ``registerBootloaderConfig`` call per recognised
  ## top-level setter PLUS one ``registerBootloaderMenuEntry`` call per
  ## recognised ``menuEntry:`` block.
  ##
  ## Per-package emission shape:
  ##
  ##   registerBootloaderConfig("<pkg>", true, -1, "")
  ##   registerBootloaderConfig("<pkg>", false, 5, "")
  ##   registerBootloaderMenuEntry("<pkg>",
  ##                               "<title>", "<kernel>",
  ##                               "<initrd>", "<cmdline>")
  ##
  ## ``parsePackageDef`` does NOT recognise ``bootloader:`` (no arm in
  ## ``macros_a.nim``), so M9.G's ownership is exclusive.
  result = newStmtList()
  let pkgLit = newLit(packageName)
  # Always emit one initialising call so the package row exists even if
  # the body declares only ``menuEntry:`` blocks. (The runtime is
  # idempotent on re-init so this is safe.)
  var bootloaderBlockSeen = false
  for entry in classified:
    if entry.ownership != soM9GBootloader:
      continue
    bootloaderBlockSeen = true
    let stmt = entry.stmt
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 2:
      continue
    let body = stmt[^1]
    if body.kind != nnkStmtList:
      continue
    for setterStmt in body:
      let head = m9gSetterHeadName(setterStmt)
      if head.len == 0:
        continue
      case head
      of "generationentry":
        if setterStmt.len != 2:
          continue
        let parsed = m9gExtractBoolLit(setterStmt[1])
        if not parsed.matched:
          continue
        let boolLit = newLit(parsed.value)
        result.add(quote do:
          registerBootloaderConfig(`pkgLit`, `boolLit`, -1, ""))
      of "timeout":
        if setterStmt.len != 2:
          continue
        let parsed = m9gExtractIntLit(setterStmt[1])
        if not parsed.matched:
          continue
        let intLit = newLit(parsed.value)
        result.add(quote do:
          registerBootloaderConfig(`pkgLit`, false, `intLit`, ""))
      of "defaultentry":
        if setterStmt.len != 2:
          continue
        let payload = m9gExtractStrLit(setterStmt[1])
        if payload.len == 0:
          continue
        let strLit = newLit(payload)
        result.add(quote do:
          registerBootloaderConfig(`pkgLit`, false, -1, `strLit`))
      of "menuentry":
        if setterStmt.len < 2:
          continue
        let menuBody = setterStmt[^1]
        if menuBody.kind != nnkStmtList:
          continue
        let fields = m9gParseMenuEntry(menuBody)
        let titleLit = newLit(fields.title)
        let kernelLit = newLit(fields.kernel)
        let initrdLit = newLit(fields.initrd)
        let cmdlineLit = newLit(fields.cmdline)
        result.add(quote do:
          registerBootloaderMenuEntry(`pkgLit`,
            `titleLit`, `kernelLit`, `initrdLit`, `cmdlineLit`))
      else:
        discard
  # If we saw at least one bootloader block but emitted no setter calls
  # (e.g. only unrecognised heads), still emit one init call so the
  # package row is non-empty / observable to ``registeredBootloaderConfig``.
  if bootloaderBlockSeen and result.len == 0:
    result.add(quote do:
      registerBootloaderConfig(`pkgLit`, false, -1, ""))

# ---------------------------------------------------------------------------
# DSL-port M9.H — ``fetch:`` block emitter.
#
# Walks each ``soM9HFetch`` classified section, parses the six recognised
# setters out of the body, and emits a single ``registerFetchSpec(...)``
# call per declared block. Setter parsing uses the same helpers the M9.G
# emitter uses (``m9gExtractStrLit`` / ``m9gExtractBoolLit`` /
# ``m9gExtractIntLit`` / ``m9gSetterHeadName``); the helpers' M9.G prefix
# is incidental — they parse any setter spelling the DSL accepts.
#
# Rejection rules (parse-time ``error()``):
#   * Neither ``url`` nor ``gitUrl`` declared → "fetch: block must
#     specify one of url: or gitUrl:".
#   * Both ``url`` AND ``gitUrl`` declared (conflicting kind) → "fetch:
#     block declares both url: and gitUrl: — pick one".
#   * Neither ``sha256`` nor ``blake3`` declared → "fetch: block must
#     specify either sha256: or blake3:".
#
# Default values:
#   * ``extractStrip`` defaults to 1 when not declared.
#   * ``extractedRoot`` defaults to "" when not declared.
#   * ``gitRevision`` defaults to "" when not declared (only meaningful
#     for ``gitUrl`` mode).
#
# Precedence:
#   * If both ``sha256`` and ``blake3`` appear in the same body, the
#     ``blake3`` value wins (matches the M9.H spec).
# ---------------------------------------------------------------------------

proc m9hSetterValueNode(arg: NimNode): NimNode =
  ## Return the value-side node of a ``key value`` / ``key: value``
  ## setter. The DSL accepts two source-level spellings:
  ##
  ##   * ``key value`` — parses as ``Command(Ident "key",
  ##     <valueNode>)`` where ``stmt[1]`` is the value node directly.
  ##   * ``key: value`` — parses as ``Call(Ident "key", StmtList(
  ##     <valueNode>))`` where ``stmt[1]`` is a ``StmtList`` wrapping
  ##     the value node.
  ##
  ## Returns the underlying value node in either case. M9.H splices
  ## these nodes verbatim into the emitted ``registerFetchSpec(...)``
  ## call so the recipe author may use arbitrary compile-time string
  ## expressions (e.g. ``"abc" & repeat("0", 61)``) as setter values —
  ## ``m9gExtractStrLit`` only matches naked string literals, which is
  ## too restrictive for the M9.H surface.
  if arg.kind == nnkStmtList and arg.len == 1:
    return arg[0]
  return arg

proc emitM9HFetch*(packageName: string;
                  classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``soM9HFetch`` entries and
  ## emit one ``registerFetchSpec(...)`` call per recognised ``fetch:``
  ## block. Returns an empty ``StmtList`` when no entry is found.
  ##
  ## Per-block emission shape:
  ##
  ##   registerFetchSpec("<pkg>",
  ##                     <url-or-gitUrl-expr>,
  ##                     <gitRevision-expr>,
  ##                     <dshaSha256 | dshaBlake3>,
  ##                     <hashHex-expr>,
  ##                     <dfkTarball | dfkGitArchive>,
  ##                     <extractStrip-expr>,
  ##                     <extractedRoot-expr>)
  ##
  ## The string-valued setters splice the source-level value node
  ## verbatim into the call — this lets the recipe use any compile-
  ## time string expression (a naked literal, a ``$`` interpolation, a
  ## ``&``-concat, ...) without restricting the macro to one shape.
  ## Parse-time presence checks (``url`` / ``gitUrl`` exclusive,
  ## ``sha256`` / ``blake3`` at least one) still run against the
  ## node's structural presence.
  result = newStmtList()
  let pkgLit = newLit(packageName)
  for entry in classified:
    if entry.ownership != soM9HFetch:
      continue
    let stmt = entry.stmt
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 2:
      continue
    let body = stmt[^1]
    if body.kind != nnkStmtList:
      continue
    # Per-block accumulators. Each "*Node" holds the AST node spliced
    # into the emitted call; ``nil`` means "setter not declared".
    var urlNode: NimNode = nil
    var gitUrlNode: NimNode = nil
    var gitRevisionNode: NimNode = nil
    var sha256Node: NimNode = nil
    var blake3Node: NimNode = nil
    var extractStripNode: NimNode = nil
    var extractedRootNode: NimNode = nil
    for setterStmt in body:
      let head = m9gSetterHeadName(setterStmt)
      if head.len == 0:
        continue
      if setterStmt.len != 2:
        continue
      let valueNode = m9hSetterValueNode(setterStmt[1])
      case head
      of "url": urlNode = valueNode
      of "giturl": gitUrlNode = valueNode
      of "gitrevision": gitRevisionNode = valueNode
      of "sha256": sha256Node = valueNode
      of "blake3": blake3Node = valueNode
      of "extractstrip": extractStripNode = valueNode
      of "extractedroot": extractedRootNode = valueNode
      else: discard
    # Validate.
    if urlNode == nil and gitUrlNode == nil:
      error("fetch: block must specify one of url: or gitUrl: " &
            "(package " & packageName & ")", stmt)
    if urlNode != nil and gitUrlNode != nil:
      error("fetch: block declares both url: and gitUrl: — pick one " &
            "(package " & packageName & ")", stmt)
    if sha256Node == nil and blake3Node == nil:
      error("fetch: block must specify either sha256: or blake3: " &
            "(package " & packageName & ")", stmt)
    # Resolve kind + final URL.
    let kindIdent =
      if gitUrlNode != nil: ident("dfkGitArchive")
      else: ident("dfkTarball")
    let finalUrlNode =
      if gitUrlNode != nil: gitUrlNode
      else: urlNode
    # Resolve hash (blake3 wins if both declared).
    let hashAlgIdent =
      if blake3Node != nil: ident("dshaBlake3")
      else: ident("dshaSha256")
    let hashHexNode =
      if blake3Node != nil: blake3Node
      else: sha256Node
    # Defaults for the optional setters.
    let gitRevisionFinal =
      if gitRevisionNode != nil: gitRevisionNode
      else: newLit("")
    let extractStripFinal =
      if extractStripNode != nil: extractStripNode
      else: newLit(1)
    let extractedRootFinal =
      if extractedRootNode != nil: extractedRootNode
      else: newLit("")
    result.add(quote do:
      registerFetchSpec(`pkgLit`, `finalUrlNode`, `gitRevisionFinal`,
        `hashAlgIdent`, `hashHexNode`,
        `kindIdent`, `extractStripFinal`, `extractedRootFinal`))

# ---------------------------------------------------------------------------
# DSL-port M9.I — per-package convention-layer flag-injection emitter.
#
# Walks each ``soM9IMesonOptions`` / ``soM9ICmakeFlags`` /
# ``soM9IConfigureFlags`` / ``soM9IMakeFlags`` / ``soM9INinjaFlags``
# classified section, walks the block body's string-literal sequence in
# source-declaration order, and emits one ``registerBuildFlag(packageName,
# "", "<channel>", <flag>)`` call per recognised string literal. M9.I
# always registers package-level rows (``artifactName == ""``); artifact-
# level injection is a follow-up.
#
# Body shape: each block's body is expected to be ``nnkStmtList`` whose
# children are string literals OR command/call shapes whose unwrapped
# payload is a string literal. Anything else (comment, discard, unknown
# node kind) is silently skipped so forward-compat with future block
# extensions stays open.
#
# The string literals are spliced VERBATIM into the emitted call so the
# recipe author may use any compile-time string expression (a naked
# literal, a ``$`` interpolation, a ``&``-concat, ...) — the M9.H
# precedent (see ``m9hSetterValueNode``).
# ---------------------------------------------------------------------------

proc m9iCollectFlagNodes(body: NimNode; outNodes: var seq[NimNode]) =
  ## Walk a flag-block body and append each recognised flag-expression
  ## node into ``outNodes`` in source-declaration order. Accepted
  ## shapes:
  ##
  ##   * Bare string literal child (``"-Daudit=false"``).
  ##   * Any other expression child whose VALUE is computed at compile
  ##     time (``"abc" & repeat("0", 1)`` etc.). The emitter does not
  ##     distinguish — it splices the node verbatim into the call so
  ##     Nim semchecks the type at the call site.
  ##
  ## Skipped (silently): ``nnkCommentStmt``, empty ``nnkDiscardStmt``,
  ## and ``nnkIncludeStmt`` — matches the package-body partition rules.
  if body.kind != nnkStmtList:
    return
  for child in body:
    if child.kind == nnkCommentStmt:
      continue
    if child.kind == nnkDiscardStmt and child.len > 0 and
       child[0].kind == nnkEmpty:
      continue
    if child.kind == nnkIncludeStmt:
      continue
    outNodes.add(child)

proc emitM9IBuildFlags*(packageName: string;
                       classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for the five M9.I block ownerships
  ## and emit one ``registerBuildFlag(...)`` call per recognised flag
  ## expression. Returns an empty ``StmtList`` when no entry is found.
  ##
  ## Per-flag emission shape:
  ##
  ##   registerBuildFlag("<pkg>", "", "<channel>", <flagExpr>)
  ##
  ## ``<channel>`` is one of ``"meson"`` / ``"cmake"`` / ``"configure"``
  ## / ``"make"`` / ``"ninja"`` (the M9.I channel taxonomy). The
  ## ``artifactName`` argument is always the empty string at M9.I —
  ## artifact-level flag injection is reserved for a follow-up
  ## milestone.
  result = newStmtList()
  let pkgLit = newLit(packageName)
  let artifactLit = newLit("")
  for entry in classified:
    var channel: string = ""
    case entry.ownership
    of soM9IMesonOptions: channel = "meson"
    of soM9ICmakeFlags: channel = "cmake"
    of soM9IConfigureFlags: channel = "configure"
    of soM9IMakeFlags: channel = "make"
    of soM9INinjaFlags: channel = "ninja"
    else: continue
    let channelLit = newLit(channel)
    let stmt = entry.stmt
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 2:
      continue
    let body = stmt[^1]
    if body.kind != nnkStmtList:
      continue
    var flagNodes: seq[NimNode] = @[]
    m9iCollectFlagNodes(body, flagNodes)
    for flagNode in flagNodes:
      let flagNodeCopy = flagNode.copyNimTree()
      result.add(quote do:
        registerBuildFlag(`pkgLit`, `artifactLit`, `channelLit`,
                          `flagNodeCopy`))

# ---------------------------------------------------------------------------
# DSL-port M9.R.3 — ``library <name>: api:`` block emission.
#
# Walks the classified section list looking for ``soM3LibraryArtifact``
# entries whose body contains a nested ``api:`` block. For each
# matching library emits one runtime block that builds a ``LibraryApi``
# record from the per-field body contents and calls
# ``registerLibraryApi(packageName, libraryName, api)`` into module-init
# code.
#
# Field grammar (re-walked at emit time):
#
#   * Scalar setters: ``pkgConfig "..."`` / ``soname "..."`` /
#     ``sover "..."`` / ``languageStandard <ident>`` /
#     ``linkKind <ident>`` — single string-literal or single identifier
#     argument.
#   * Listing blocks: ``headers:`` / ``privateHeaders:`` / ``links:`` /
#     ``privateLinks:`` / ``defines:`` / ``privateDefines:`` /
#     ``compileOptions:`` / ``privateCompileOptions:`` — body of
#     children, each child is either a string literal, a bare
#     identifier (the M9.R.3 ``links:`` shape — the identifier name
#     becomes a string at the registry layer), or arbitrary Nim
#     control-flow (``if`` / ``case``) whose leaves resolve to one of
#     the two scalar shapes. Variant-conditional content is supported
#     because the macro splices control-flow nodes verbatim into the
#     registration block; the variant's resolved ``.value`` is
#     available at registration time (which runs at module init —
#     AFTER ``finalizeVariants()`` from the M1 emission chain).
# ---------------------------------------------------------------------------

proc m9r3IsApiBody(node: NimNode): bool =
  ## Recognise the ``api:`` body callsite inside a ``library <name>:``
  ## body. Both ``Call(api, StmtList(...))`` and
  ## ``Command(api, StmtList(...))`` parse as call-kind nodes here; the
  ## section head is the bare ident ``api``.
  if node.kind notin {nnkCall, nnkCommand}:
    return false
  if node.len < 2:
    return false
  let head = node[0]
  if head.kind notin {nnkIdent, nnkSym}:
    return false
  result = ($head).normalize == "api"

proc m9r3FindApiBody(libraryStmt: NimNode): NimNode =
  ## Return the ``StmtList`` node of the ``api:`` body inside a
  ## ``library <name>: ...`` call, or ``nil`` when the library has no
  ## ``api:`` block. The ``library`` statement always has the
  ## ``StmtList`` body as its trailing child (per ``parseLibrary``'s
  ## ``node[2]`` access).
  result = nil
  if libraryStmt.kind notin {nnkCall, nnkCommand}:
    return
  if libraryStmt.len < 3:
    return
  let libBody = libraryStmt[^1]
  if libBody.kind != nnkStmtList:
    return
  for child in libBody:
    if m9r3IsApiBody(child):
      let apiBody = child[^1]
      if apiBody.kind == nnkStmtList:
        return apiBody

proc m9r3LinkKindLit(text: string; node: NimNode): NimNode =
  ## Lower a ``linkKind`` literal to the corresponding ``LibraryLinkKind``
  ## enum value AST. Raises a compile-time error for unrecognised tokens
  ## so typos surface early.
  let norm = text.normalize
  case norm
  of "static", "llkstatic":   ident("llkStatic")
  of "shared", "llkshared":   ident("llkShared")
  of "both", "llkboth":       ident("llkBoth")
  of "unset", "llkunset":     ident("llkUnset")
  else:
    error("library api: linkKind must be one of: static, shared, both " &
          "(got '" & text & "')", node)
    ident("llkUnset")

proc m9r3IdentOrStrText(node: NimNode): tuple[ok: bool; text: string] =
  ## Project a single-token AST node onto the string the registry
  ## stores. Accepts string literals (use ``strVal``), bare identifiers
  ## (stringify), and ``AccQuoted`` (concatenate components). Returns
  ## ``ok=false`` for anything else so the caller can fall back to
  ## ``$node.repr`` or skip.
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    (true, node.strVal)
  of nnkIdent, nnkSym:
    (true, $node)
  of nnkAccQuoted:
    var acc = ""
    for c in node:
      let part = m9r3IdentOrStrText(c)
      if part.ok: acc.add(part.text)
    (true, acc)
  else:
    (false, "")

proc m9r3RewriteListChild(node: NimNode; targetVar: NimNode): NimNode =
  ## Transform a single ``headers:`` / ``links:`` / etc. body child into
  ## a statement that appends one or more string values to
  ## ``targetVar`` (a local ``var seq[string]`` the registration block
  ## holds). The transformation rules:
  ##
  ##   * String literal     → ``targetVar.add("<lit>")``
  ##   * Bare identifier    → ``targetVar.add("<ident name>")``
  ##   * AccQuoted          → ``targetVar.add("<reconstructed text>")``
  ##   * Control-flow (if / case / when) → recurse into the branch
  ##     bodies and emit the rewritten arm statements.
  ##   * Anything else      → splice as-is wrapped in
  ##     ``targetVar.add(<expr>)`` so author-supplied expressions that
  ##     evaluate to ``string`` still land in the seq. The Nim
  ##     semchecker validates the expression type at the call site.
  case node.kind
  of nnkCommentStmt, nnkDiscardStmt:
    return newStmtList()
  of nnkStrLit..nnkTripleStrLit:
    let lit = newLit(node.strVal)
    return quote do:
      `targetVar`.add(`lit`)
  of nnkIdent, nnkSym:
    let lit = newLit($node)
    return quote do:
      `targetVar`.add(`lit`)
  of nnkAccQuoted:
    let parsed = m9r3IdentOrStrText(node)
    if parsed.ok:
      let lit = newLit(parsed.text)
      return quote do:
        `targetVar`.add(`lit`)
    return newStmtList()
  of nnkStmtList:
    result = newStmtList()
    for child in node:
      result.add(m9r3RewriteListChild(child, targetVar))
  of nnkIfStmt, nnkIfExpr, nnkWhenStmt:
    result = newNimNode(node.kind)
    for branch in node:
      let newBranch = newNimNode(branch.kind)
      case branch.kind
      of nnkElifBranch, nnkElifExpr:
        newBranch.add(branch[0].copyNimTree())
        newBranch.add(m9r3RewriteListChild(branch[1], targetVar))
      of nnkElse, nnkElseExpr:
        newBranch.add(m9r3RewriteListChild(branch[0], targetVar))
      else:
        for child in branch:
          newBranch.add(child.copyNimTree())
      result.add(newBranch)
  of nnkCaseStmt:
    result = newNimNode(nnkCaseStmt)
    result.add(node[0].copyNimTree())
    for i in 1 ..< node.len:
      let branch = node[i]
      let newBranch = newNimNode(branch.kind)
      case branch.kind
      of nnkOfBranch:
        for j in 0 ..< branch.len - 1:
          newBranch.add(branch[j].copyNimTree())
        newBranch.add(m9r3RewriteListChild(branch[^1], targetVar))
      of nnkElifBranch:
        newBranch.add(branch[0].copyNimTree())
        newBranch.add(m9r3RewriteListChild(branch[1], targetVar))
      of nnkElse:
        newBranch.add(m9r3RewriteListChild(branch[0], targetVar))
      else:
        for child in branch:
          newBranch.add(child.copyNimTree())
      result.add(newBranch)
  else:
    # Catch-all: splice the expression verbatim, expecting it to
    # evaluate to a string at runtime.
    let exprCopy = node.copyNimTree()
    return quote do:
      `targetVar`.add(`exprCopy`)

proc m9r3CollectListAppends(body: NimNode; targetVar: NimNode): NimNode =
  ## Walk the children of an ``api:`` listing block and emit the seq-
  ## append statements (with control-flow preserved for variant-
  ## conditional content). Returns a ``StmtList`` of zero or more
  ## ``targetVar.add(<value>)`` statements.
  result = newStmtList()
  if body.kind != nnkStmtList:
    return
  for child in body:
    case child.kind
    of nnkCommentStmt:
      continue
    of nnkDiscardStmt:
      continue
    else:
      result.add(m9r3RewriteListChild(child, targetVar))

proc m9r4ProcDefName(procDef: NimNode): string =
  ## Return the proc's identifier with the trailing ``*`` export marker
  ## stripped. ``procDef[0]`` is either a bare ``nnkIdent`` /
  ## ``nnkSym`` (``proc foo(...)``) or ``nnkPostfix(*, <ident>)`` (the
  ## canonical ``proc foo*(...)`` exports: shape).
  let head = procDef[0]
  case head.kind
  of nnkPostfix:
    if head.len >= 2 and head[1].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      result = head[1].repr
    else:
      result = head.repr
  of nnkIdent, nnkSym, nnkAccQuoted:
    result = head.repr
  else:
    result = head.repr

proc m9r4FormalParamsRaw(formalParams: NimNode): string =
  ## Render the ``nnkFormalParams`` node as the raw Nim parameter list
  ## text the registry stores (without the surrounding ``()``).
  ##
  ## ``formalParams[0]`` is the return type slot — we skip it here, the
  ## return text is rendered separately by ``m9r4ReturnRaw``.
  ##
  ## We use ``repr`` on each ``nnkIdentDefs`` child so author-supplied
  ## types (``ptr Pcm``, ``cstring``, generic params, etc.) survive
  ## intact; the macro never type-checks the parameters because the
  ## library types are typically opaque at this expansion site.
  if formalParams.kind != nnkFormalParams:
    return ""
  result = ""
  var first = true
  for i in 1 ..< formalParams.len:
    let child = formalParams[i]
    if not first:
      result.add(", ")
    first = false
    result.add(child.repr.strip)

proc m9r4ReturnRaw(formalParams: NimNode): string =
  ## Render the return-type slot (``formalParams[0]``) as raw Nim text.
  ## ``nnkEmpty`` (no return type) collapses to "".
  if formalParams.kind != nnkFormalParams or formalParams.len == 0:
    return ""
  let ret = formalParams[0]
  if ret.kind == nnkEmpty:
    return ""
  result = ret.repr.strip

proc m9r4DocFromBody(body: NimNode): string =
  ## Extract the first doc-comment statement from a proc body, if any.
  ## ``nnkCommentStmt`` carries the comment text in ``strVal``. Returns
  ## empty string when the body is missing, empty, or has no leading
  ## doc comment. Matches the Nim convention that the doc comment is
  ## the first statement of the proc body.
  if body.kind == nnkEmpty:
    return ""
  if body.kind != nnkStmtList:
    return ""
  for child in body:
    case child.kind
    of nnkCommentStmt:
      return child.strVal.strip
    else:
      return ""
  return ""

proc m9r4ProcDefRecord(procDef: NimNode; exportsSym: NimNode): NimNode =
  ## Emit one ``exportsSym.add(ExportedSymbol(...))`` statement for a
  ## single ``proc <name>*(<params>): <ret>`` declaration inside an
  ## ``exports:`` sub-block.
  let name = m9r4ProcDefName(procDef)
  let formalParams = procDef[3]
  let paramsRaw = m9r4FormalParamsRaw(formalParams)
  let returnRaw = m9r4ReturnRaw(formalParams)
  let doc = m9r4DocFromBody(procDef[^1])
  let nameLit = newLit(name)
  let paramsLit = newLit(paramsRaw)
  let returnLit = newLit(returnRaw)
  let docLit = newLit(doc)
  result = quote do:
    `exportsSym`.add(ExportedSymbol(
      name: `nameLit`,
      paramsRaw: `paramsLit`,
      returnRaw: `returnLit`,
      doc: `docLit`))

proc m9r4CollectExports(body: NimNode; exportsSym: NimNode): NimNode =
  ## Walk the children of an ``exports:`` sub-block and emit one
  ## ``exportsSym.add(...)`` statement per ``nnkProcDef`` child. Doc
  ## comments and discard statements at the block level are skipped.
  ## Any other node shape is rejected with an actionable compile-time
  ## error naming the offending node + suggesting the canonical
  ## ``proc <name>*(<params>): <ret>`` shape.
  result = newStmtList()
  if body.kind != nnkStmtList:
    return
  for child in body:
    case child.kind
    of nnkCommentStmt, nnkDiscardStmt:
      continue
    of nnkProcDef:
      result.add(m9r4ProcDefRecord(child, exportsSym))
    else:
      error("library api: exports: only accepts proc declarations; got " &
            $child.kind & " (" & child.repr.strip & "). " &
            "Use the shape: proc <name>*(<params>): <return>", child)

proc emitM9R3LibraryApis*(packageName: string;
                          classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list for ``soM3LibraryArtifact``
  ## entries; for each library whose body contains an ``api:`` block,
  ## emit one ``block: ... registerLibraryApi(pkg, lib, api)`` statement
  ## that builds the typed record + registers it.
  ##
  ## Recipes whose library body is bare (``library libFoo: discard`` or
  ## carries only a ``kind:`` setter) produce NO emission so the
  ## registry stays empty for them — ``registeredLibraryApi`` returns
  ## the default-zero record with ``declared == false``.
  result = newStmtList()
  let pkgLit = newLit(packageName)
  for entry in classified:
    if entry.ownership != soM3LibraryArtifact:
      continue
    let stmt = entry.stmt
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt.len < 3:
      continue
    let apiBody = m9r3FindApiBody(stmt)
    if apiBody == nil:
      continue
    # Library name: the second child is the name node (string-form or
    # ident-form, mirroring ``m3ArtifactNameNode``).
    let nameNode = stmt[1]
    var libraryName = ""
    case nameNode.kind
    of nnkStrLit..nnkTripleStrLit:
      libraryName = nameNode.strVal
    of nnkIdent, nnkSym, nnkAccQuoted:
      libraryName = $nameNode.repr
    else:
      libraryName = nameNode.repr
    let libLit = newLit(libraryName)
    # Local var names used inside the registration block. Pre-built
    # identifiers so the ``quote do:`` splice + the per-field appends
    # bind to the same symbol.
    let apiSym = ident("m9r3ApiRec")
    let headersSym = ident("m9r3Headers")
    let privateHeadersSym = ident("m9r3PrivateHeaders")
    let linksSym = ident("m9r3Links")
    let privateLinksSym = ident("m9r3PrivateLinks")
    let definesSym = ident("m9r3Defines")
    let privateDefinesSym = ident("m9r3PrivateDefines")
    let compileOptsSym = ident("m9r3CompileOptions")
    let privateCompileOptsSym = ident("m9r3PrivateCompileOptions")
    let exportsSym = ident("m9r4Exports")
    # Per-field setter statements. We START with the seq-init lines so
    # ``targetVar`` is always defined before the rewriter touches it.
    var setters = newStmtList()
    setters.add(quote do:
      var `headersSym`: seq[string] = @[])
    setters.add(quote do:
      var `privateHeadersSym`: seq[string] = @[])
    setters.add(quote do:
      var `linksSym`: seq[string] = @[])
    setters.add(quote do:
      var `privateLinksSym`: seq[string] = @[])
    setters.add(quote do:
      var `definesSym`: seq[string] = @[])
    setters.add(quote do:
      var `privateDefinesSym`: seq[string] = @[])
    setters.add(quote do:
      var `compileOptsSym`: seq[string] = @[])
    setters.add(quote do:
      var `privateCompileOptsSym`: seq[string] = @[])
    setters.add(quote do:
      var `exportsSym`: seq[ExportedSymbol] = @[])
    setters.add(quote do:
      var `apiSym` = LibraryApi(declared: true))
    # Walk the api: body and dispatch per-field.
    for fieldStmt in apiBody:
      case fieldStmt.kind
      of nnkCommentStmt, nnkDiscardStmt:
        continue
      else: discard
      let head = calleeName(fieldStmt).normalize
      case head
      of "pkgconfig":
        if fieldStmt.len < 2:
          error("library api: pkgConfig requires a string argument", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if parsed.ok:
          let lit = newLit(parsed.text)
          setters.add(quote do:
            `apiSym`.pkgConfig = `lit`)
        else:
          let exprCopy = valueNode.copyNimTree()
          setters.add(quote do:
            `apiSym`.pkgConfig = `exprCopy`)
      of "soname":
        if fieldStmt.len < 2:
          error("library api: soname requires a string argument", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if parsed.ok:
          let lit = newLit(parsed.text)
          setters.add(quote do:
            `apiSym`.soname = `lit`)
        else:
          let exprCopy = valueNode.copyNimTree()
          setters.add(quote do:
            `apiSym`.soname = `exprCopy`)
      of "sover":
        if fieldStmt.len < 2:
          error("library api: sover requires a string argument", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if parsed.ok:
          let lit = newLit(parsed.text)
          setters.add(quote do:
            `apiSym`.sover = `lit`)
        else:
          let exprCopy = valueNode.copyNimTree()
          setters.add(quote do:
            `apiSym`.sover = `exprCopy`)
      of "languagestandard":
        if fieldStmt.len < 2:
          error("library api: languageStandard requires a value", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if parsed.ok:
          let lit = newLit(parsed.text)
          setters.add(quote do:
            `apiSym`.languageStandard = `lit`)
        else:
          let exprCopy = valueNode.copyNimTree()
          setters.add(quote do:
            `apiSym`.languageStandard = `exprCopy`)
      of "linkkind":
        if fieldStmt.len < 2:
          error("library api: linkKind requires a value", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if not parsed.ok:
          error("library api: linkKind must be one of: static, shared, both",
                valueNode)
        let kindLit = m9r3LinkKindLit(parsed.text, valueNode)
        setters.add(quote do:
          `apiSym`.linkKind = `kindLit`)
      of "headers":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, headersSym))
      of "privateheaders":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, privateHeadersSym))
      of "links":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, linksSym))
      of "privatelinks":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, privateLinksSym))
      of "defines":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, definesSym))
      of "privatedefines":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, privateDefinesSym))
      of "compileoptions":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, compileOptsSym))
      of "privatecompileoptions":
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r3CollectListAppends(body, privateCompileOptsSym))
      of "exports":
        # DSL-port M9.R.4: ``exports:`` sub-block declares the library's
        # FFI-callable symbols as Nim proc signatures. Each
        # ``nnkProcDef`` child gets lowered to an ``ExportedSymbol``
        # record whose ``name`` / ``paramsRaw`` / ``returnRaw`` / ``doc``
        # fields preserve the source text faithfully. Non-proc children
        # raise an actionable compile-time error inside
        # ``m9r4CollectExports``.
        if fieldStmt.len >= 2:
          let body = fieldStmt[^1]
          setters.add(m9r4CollectExports(body, exportsSym))
      else:
        # Unknown field — silently ignore for forward compatibility
        # (future ``api:`` sub-blocks).
        discard
    # Wrap the setters + registration call in a ``block:`` so the
    # local vars don't leak into the surrounding scope. The
    # ``block:`` runs at module-init time (the package macro emits
    # the M9.R.3 emission AFTER ``variantsEmission`` so resolved
    # variant values are queryable from inside the block).
    result.add(quote do:
      block:
        `setters`
        `apiSym`.headers = `headersSym`
        `apiSym`.privateHeaders = `privateHeadersSym`
        `apiSym`.links = `linksSym`
        `apiSym`.privateLinks = `privateLinksSym`
        `apiSym`.defines = `definesSym`
        `apiSym`.privateDefines = `privateDefinesSym`
        `apiSym`.compileOptions = `compileOptsSym`
        `apiSym`.privateCompileOptions = `privateCompileOptsSym`
        `apiSym`.exports = `exportsSym`
        registerLibraryApi(`pkgLit`, `libLit`, `apiSym`))

macro package*(name: untyped; body: untyped): untyped =
  ## Top-level package declaration.
  ##
  ## DSL-port M1 — the body is partitioned through
  ## ``partitionPackageBody`` (the production seam for v8's
  ## ``transformPackageBody`` proc, see
  ## ``tools/prototypes/v8/intended/reprobuild.nim`` lines ~691-995).
  ## Each top-level statement is classified as either:
  ##
  ##   * a recognised DSL section (``executable``, ``library``,
  ##     ``uses``, ``config``, ``outputs``, ``provisioning``,
  ##     ``devEnv``, ``build``, ``versions``, ``service``, ``files``,
  ##     ``depends_on``) — fed to ``parsePackageDef`` for legacy
  ##     section-handler lowering;
  ##   * a verbatim Nim statement (``let``, ``var``, ``for``, ``proc``,
  ##     ``template``, ``when``, ``if``, ``echo``, ``discard <expr>``,
  ##     plain proc call, …) — emitted verbatim at module top level so
  ##     the author's intent survives macro expansion.
  ##
  ## Subsequent milestones (DSL-port M2 — versions / M3 — config /
  ## M4 — build / M5 — files / M6 — service / M7 — cli / M8 —
  ## remaining sections) will progressively replace the legacy
  ## section handlers with v8-style template invocations against the
  ## partitioned section list. The unknown-Nim path stays stable.
  ##
  ## Three additional emissions remain from Project-DSL-Composition M5:
  ##
  ## 1. Active-build-context wrapping. The generated ``build<Name>*()``
  ##    proc opens with ``beginBuildBlock(packageName)`` and pairs it
  ##    with ``endBuildBlock(<state>)`` in a ``try/finally``. Helper
  ##    procs and preserved Nim statements that invoke typed-tool
  ##    wrappers find the active package via the thread-local stack
  ##    instead of relying on lexical position.
  ##
  ## 2. Cross-project edge references. Top-level ``let``/``var``
  ##    bindings inside the outermost ``build:`` block(s) become
  ##    public members of ``<package>.build`` via module-level
  ##    storage vars, paired init flags, accessor templates, and a
  ##    bridging ``template build*``. A compile-time ``uses:``
  ##    registry detects cycles before they cause downstream
  ##    semcheck failures.
  ##
  ## 3. Variant declarations. Each ``variant: T = default`` entry in
  ##    the ``config:`` block lowers to a
  ##    ``let <name> = declareVariant[T](...)`` plus a trailing
  ##    ``finalizeVariants()`` call.
  let (sectionStmts, preservedStmts) = partitionPackageBody(body)
  let pkg = parsePackageDef(name, body)
  let packageName = pkg.packageName
  # ── DSL-port M2: emit ``config:`` scalar registrations + ``versions:``
  # entries. The two emitters operate on the M1 ``sectionStmts``
  # partition and are mutually exclusive with the legacy
  # ``emitVariantDeclarations`` pass on the per-entry level (see
  # ``collectM2ConfigEntries`` for the disjointness argument that
  # addresses M1 risk #2). The result is appended at the END of the
  # macro's expansion so registrations happen at module-init time AFTER
  # the legacy ``registerPackageDef`` call and AFTER any preserved Nim
  # statements have run — that ordering keeps the M2 surface available
  # to downstream code regardless of whether the caller imports the
  # package's recipe before or after the host module's own setup.
  let m2ConfigEmission = emitM2ConfigDefaults(packageName, sectionStmts)
  let m2VersionsEmission = emitM2Versions(packageName, sectionStmts)
  # ── DSL-port M3: classify sections + emit artifact registrations.
  # The classifier attaches a ``SectionOwnership`` tag to every
  # partitioned section entry; ``emitM3Artifacts`` filters by the three
  # ``soM3*Artifact`` tags and emits one ``registerArtifact(...)`` call
  # per recognised entry. The legacy ``parsePackageDef`` chain below
  # continues to populate ``pkg.executables`` / ``pkg.libraries`` so
  # production's typed-tool wrapper, cli interface, ``buildXxx*`` proc,
  # and per-package const all keep working unchanged. See the comment
  # above ``emitM3Artifacts`` for the legacy-vs-M3 ownership decision.
  let classifiedSections = classifyPackageSections(sectionStmts)
  let m3ArtifactEmission = emitM3Artifacts(packageName, classifiedSections)
  # ── Spec-Implementation M1: variant declarations + finalization ────
  # ``parsePackageDef`` collected every ``variant: T = default`` (and
  # ``@variant``-tagged) declaration from the ``config:`` block into
  # ``pkg.variants``. We emit one ``let <name> = declareVariant[T](...)``
  # per entry plus a single ``finalizeVariants()`` call. The
  # ``declareVariant`` template lives in
  # ``repro_dsl_stdlib/configurables/variants.nim``; the import below
  # is gated so packages without variants don't pull the stdlib in.
  let variantsEmission = emitVariantDeclarations(pkg.variants, pkg)
  # ── M5: cross-project uses + cycle detection ─────────────────────
  var declaredUses: seq[string] = @[]
  for u in pkg.toolUses:
    if u.packageSelector.len > 0:
      declaredUses.add(u.packageSelector)
  let cycleError = detectCrossProjectCycle(packageName, declaredUses)
  if cycleError.len > 0:
    error(cycleError, name)
  registerCrossProjectUses(packageName, declaredUses)
  # ── M5: collect top-level build: bindings BEFORE lowering ────────
  let crossProjectBindings = collectTopLevelBuildBindings(body)
  # Splice storage writes after each captured binding so the lowered
  # build proc populates the module-level vars at runtime. We use the
  # ORIGINAL body for binding collection (read-only) and a copy for
  # the lowered builder (write-through).
  let bodyForBuild =
    if crossProjectBindings.len > 0:
      instrumentBuildBindings(body, packageName, crossProjectBindings)
    else:
      body
  # ── existing M0/M1 emissions ─────────────────────────────────────
  let recordActions = collectBuildStatements(bodyForBuild).len == 0 and
    pkg.executables.len > 0
  let generated = parseStmt(
    usesImportCode(pkg) &
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" &
    wrapperCode(pkg, recordActions))
  result = newStmtList()
  # Named-Targets M1: emit the per-tool ``implicitTargetName`` hook
  # procs BEFORE the typed-tool wrapper procs so the wrapper's
  # generated call site (``implicitTargetNameFor<TitleExportName>``)
  # type-checks against the already-declared hook.
  result.add(collectImplicitTargetNameHooks(body))
  result.add(generated)
  # Spec-Implementation M1: emit ``let <name> = declareVariant[T](...)``
  # bindings + the trailing ``finalizeVariants()`` call at top-level
  # module scope (after the package wrapper code so the variant
  # accessor symbols are visible to ``build:`` code emitted below).
  result.add(variantsEmission)
  # ── M5: cross-project storage / const / accessors ────────────────
  # `wrapperCode` and `toolActionWrapperCode` BOTH unconditionally
  # emit `const <packageValueIdent>* = <typeName>()` regardless of
  # executable count (see `macros_a.nim` lines 1423 / 1562). The
  # cross-project emitter therefore ALWAYS bridges via an overloaded
  # `build*` template instead of trying to redeclare the const.
  let legacyConstAlreadyEmitted = true
  let legacyTypeIdent = ident(titleIdent(packageName))
  if crossProjectBindings.len > 0:
    result.add(generatedCrossProjectStorage(packageName, crossProjectBindings))
    result.add(generatedCrossProjectPackageConst(packageName,
                                                 crossProjectBindings,
                                                 legacyConstAlreadyEmitted,
                                                 legacyTypeIdent))
    result.add(generatedCrossProjectAccessors(packageName,
                                              crossProjectBindings))
  # ── existing builder emission (now feeding instrumented body) ────
  result.add(buildCode(pkg, bodyForBuild))
  # ── DSL-port M1: preserved Nim statements (the v8 "verbatim" branch).
  # Computed once at the top of the macro via ``partitionPackageBody``;
  # emitted here at module top level so the author's intent runs at
  # expansion / module-init time. Until M2-M8 migrate section handlers
  # to v8-style template invocations the legacy ``parsePackageDef`` +
  # ``buildCode`` chain consumes ``sectionStmts``; this leg consumes
  # everything else.
  result.add(preservedStmts)
  # ── DSL-port M2: ``config:`` defaults + ``versions:`` registrations.
  # Both emitters operate on ``sectionStmts`` and append zero or more
  # runtime calls per recognised entry. They sit AFTER the preserved
  # statements so any author-supplied helper proc or ``let`` binding
  # the entry's default expression references is already in scope.
  result.add(m2ConfigEmission)
  result.add(m2VersionsEmission)
  # ── DSL-port M3: artifact registrations. Appended LAST so the
  # body repr captured at macro-expansion time is available to any
  # downstream consumer (M4+ will read this list at compile time via
  # the partitioned section walk; the runtime registry is the
  # diagnostic surface tests use today).
  result.add(m3ArtifactEmission)
  # ── DSL-port M4: ``build:`` block lowering (package-level +
  # artifact-scoped). Both emitters walk the SAME classified seq
  # M3's emitter consumed (no second classification pass) and emit
  # wrap-and-register blocks that splice the user's build body
  # verbatim. The blocks sit AFTER M3's artifact emission so the
  # M4 surface ALWAYS sees the registry rows M3 created — useful
  # for diagnostic paths that want to cross-reference an action's
  # artifactName against ``registeredArtifacts``.
  #
  # IMPORTANT: the legacy ``buildCode`` emission (above) ALSO
  # consumes the build body via ``collectBuildStatements`` and
  # synthesises ``buildXxxPackage*()``. That proc is only invoked
  # under ``reproProviderMode + isMainModule``, so test runs see
  # M4's init-time emission run exactly once. To keep provider mode
  # from also seeing the body twice (M4 init body splice + legacy
  # proc body splice), the M4 emitters gate the user's verbatim body
  # splice on ``when not defined(reproProviderMode)``. The
  # ``registerBuildAction`` + ``beginBuildContext`` / ``endBuildContext``
  # pair stays unconditional so the registry surface is observable
  # from both modes; only the body execution is mode-disjoint. See the
  # provider-mode disjointness commentary on ``emitM4BuildActions`` /
  # ``emitM4ArtifactBuildLowering`` for the complete rationale.
  let m4BuildActionEmission = emitM4BuildActions(packageName,
                                                  classifiedSections)
  let m4ArtifactBuildEmission = emitM4ArtifactBuildLowering(packageName,
                                                            classifiedSections)
  result.add(m4BuildActionEmission)
  result.add(m4ArtifactBuildEmission)
  # ── DSL-port M5: ``service:`` block lowering. Walks the SAME
  # classified seq M3/M4 consumed and emits one wrap-and-register block
  # per ``soM5Service`` entry. The block sits AFTER M4's emissions so
  # the M5 surface sees the registry rows M3/M4 created — useful for
  # diagnostic paths that want to cross-reference a service's
  # ``executableRef`` against ``registeredArtifacts``. Legacy
  # ``parsePackageDef`` does NOT recognise ``service:`` at all (no arm
  # in ``macros_a.nim``), so M5's ownership is exclusive — symmetric
  # with M3's ``files:`` treatment. See the "Risk #2" commentary above
  # ``emitM5Services`` for the provider-mode gating decision.
  let m5ServiceEmission = emitM5Services(packageName, classifiedSections)
  result.add(m5ServiceEmission)
  # ── DSL-port M6: ``cli:`` block ``pos`` / ``flag`` / ``boolFlag``
  # parameter registration. Walks the M3 artifact entries in the
  # classified seq, re-walks each artifact body looking for a nested
  # ``cli:`` head, and emits one ``registerCliParam(...)`` call per
  # recognised ``pos`` / ``flag`` / ``boolFlag`` statement. The legacy
  # ``parseExecutable`` arm continues to walk the same ``cli:`` body
  # and populate ``pkg.executables[].commands`` for the typed-tool
  # wrapper emission — the two sidecars are disjoint and observe the
  # body in parallel. See the ownership commentary above
  # ``emitM6CliLowering`` for the complete double-emit analysis.
  let m6CliEmission = emitM6CliLowering(packageName, classifiedSections)
  result.add(m6CliEmission)
  # ── DSL-port M9.E: ``variant <configField>:`` arm registrations +
  # ``validate:`` predicate registrations. The two emitters operate on
  # the same classified seq M3-M6 consumed and append per-block runtime
  # calls. ``parsePackageDef`` does NOT recognise either section
  # (``variant`` is distinct from the ``variant:`` declaration inside
  # ``config:`` which the legacy walker handles), so the M9.E ownership
  # is exclusive — symmetric with M5's ``service:`` treatment. The
  # blocks sit AFTER M6's emission so the M9.E surface sees every
  # registry row prior milestones created — useful for downstream
  # diagnostics that want to cross-reference a variant against the
  # config field's recorded default.
  let m9eVariantEmission = emitM9EVariantArms(packageName, classifiedSections)
  let m9eValidateEmission = emitM9EValidates(packageName, classifiedSections)
  result.add(m9eVariantEmission)
  result.add(m9eValidateEmission)
  # ── DSL-port M9.G: ``bootloader:`` block lowering. Per-package single
  # block; the emitter walks the setter list and emits one
  # ``registerBootloaderConfig`` call per recognised top-level setter
  # plus one ``registerBootloaderMenuEntry`` call per ``menuEntry:``
  # body. ``parsePackageDef`` does NOT recognise the section so M9.G's
  # ownership is exclusive — symmetric with M5's ``service:`` and
  # M9.E's ``variant:`` / ``validate:``. Block sits AFTER M9.E so the
  # M9.G surface sees every registry row prior milestones created.
  let m9gBootloaderEmission = emitM9GBootloader(packageName, classifiedSections)
  result.add(m9gBootloaderEmission)
  # ── DSL-port M9.H: ``fetch:`` block lowering. Per-package single block
  # (last writer wins if multiple ``fetch:`` blocks appear). The emitter
  # parses the six recognised setters (``url`` / ``gitUrl`` /
  # ``gitRevision`` / ``sha256`` / ``blake3`` / ``extractStrip`` /
  # ``extractedRoot``) and emits a single ``registerFetchSpec(...)`` call
  # per block. ``parsePackageDef`` does NOT recognise ``fetch:`` so
  # M9.H's ownership is exclusive — symmetric with M9.G's ``bootloader:``
  # treatment. NOTE: M9.H is REGISTRATION + parser ONLY; the build-
  # engine fetch action that consumes the registry (download + hash
  # verify + extract) is a separate milestone (M9.K).
  let m9hFetchEmission = emitM9HFetch(packageName, classifiedSections)
  result.add(m9hFetchEmission)
  # ── DSL-port M9.I: per-package convention-layer flag-injection blocks
  # (``mesonOptions:`` / ``cmakeFlags:`` / ``configureFlags:`` /
  # ``makeFlags:`` / ``ninjaFlags:``). Each block body is a sequence of
  # string literals (one per line, no setters) that the emitter walks in
  # source-declaration order, emitting one ``registerBuildFlag(...)``
  # call per literal. Repeatable inside a package body — successive
  # blocks APPEND to the registered seq (flag order is load-bearing for
  # autotools / make). ``parsePackageDef`` does NOT recognise any of the
  # five block heads so M9.I's ownership is exclusive — symmetric with
  # M9.H's ``fetch:`` treatment. NOTE: M9.I is REGISTRATION + parser
  # ONLY; the convention-side consumption (c_cpp_meson / c_cpp_cmake /
  # c_cpp_autotools / c_cpp_make widening) is deferred to M9.L.
  let m9iBuildFlagsEmission = emitM9IBuildFlags(packageName, classifiedSections)
  result.add(m9iBuildFlagsEmission)
  # ── DSL-port M9.R.1: per-package dep-block registration emission.
  # ``parsePackageDef`` already collected every constraint string into
  # the three seqs ``pkg.toolUses`` (the ``uses:`` / ``buildDeps:``
  # synonym pair), ``pkg.nativeBuildDeps``, and ``pkg.runtimeDeps``.
  # We emit one ``registerPackageDep(...)`` call per entry so the
  # in-memory accessors (``registeredBuildDeps`` /
  # ``registeredNativeBuildDeps`` / ``registeredRuntimeDeps``) return
  # the declared constraint strings at run / test time. The legacy
  # solver path (``registerSolverDependency`` emitted by
  # ``emitVariantDeclarations``) is UNCHANGED — this milestone
  # ADDITIVELY widens the surface so M9.R.2 / M9.R.5 callers have a
  # stable diagnostic registry to query.
  let pkgLitForDeps = newLit(packageName)
  let buildKindLit = newLit("build")
  let nativeKindLit = newLit("native")
  let runtimeKindLit = newLit("runtime")
  for useDef in pkg.toolUses:
    let constraintLit = newLit(useDef.rawConstraint)
    result.add(quote do:
      registerPackageDep(`pkgLitForDeps`, `buildKindLit`, `constraintLit`))
  for useDef in pkg.nativeBuildDeps:
    let constraintLit = newLit(useDef.rawConstraint)
    result.add(quote do:
      registerPackageDep(`pkgLitForDeps`, `nativeKindLit`, `constraintLit`))
  for useDef in pkg.runtimeDeps:
    let constraintLit = newLit(useDef.rawConstraint)
    result.add(quote do:
      registerPackageDep(`pkgLitForDeps`, `runtimeKindLit`, `constraintLit`))
  # ── DSL-port M9.R.3: per-library ``api:`` block registration emission.
  # ``emitM9R3LibraryApis`` walks the M3 ``soM3LibraryArtifact`` entries,
  # finds nested ``api:`` blocks, and emits one runtime block per match
  # that builds a ``LibraryApi`` value + calls ``registerLibraryApi``.
  # Libraries without an ``api:`` block produce NO emission so the
  # registry stays empty for them (the accessor returns the default-
  # zero record with ``declared == false``). The emission sits AFTER
  # the M9.R.1 dep registrations so the registry surface ordering
  # matches the source declaration ordering (M9.R.1's reset proc has
  # no overlap with M9.R.3's so the two reset calls are independent).
  let m9r3LibraryApiEmission = emitM9R3LibraryApis(packageName, classifiedSections)
  result.add(m9r3LibraryApiEmission)

proc collectDependsOnEntries(node: NimNode; output: var seq[string]) =
  ## Flatten a ``depends_on`` body into a list of declared dep names.
  ##
  ## Accepted shapes (any combination, in any order):
  ##
  ##   ``depends_on hello: greet``
  ##     parses to ``Command(depends_on, hello, StmtList(greet))``;
  ##     the body's leaf is a single identifier.
  ##
  ##   ``depends_on hello: greet, logFmt``
  ##     parses to ``Command(depends_on, hello, StmtList(Command(greet,
  ##     logFmt)))``; the body's leaf is a ``Command`` whose head is
  ##     ``greet`` and remaining children are the other deps.
  ##
  ##   ``depends_on hello:`` + indented body lines
  ##     parses to ``Command(depends_on, hello, StmtList(greet, logFmt,
  ##     ...))``; each child is one identifier (or a comma-separated
  ##     inline ``Command`` per the rule above).
  ##
  ## String literals (``"greet"``) are also accepted so generated files
  ## from external tooling can use either spelling. We don't error on
  ## anything else — unknown shapes are silently skipped so forward
  ## compatibility with future ``depends_on`` extensions stays open.
  case node.kind
  of nnkIdent, nnkSym:
    output.add(identText(node))
  of nnkStrLit..nnkTripleStrLit:
    output.add(node.strVal)
  of nnkStmtList, nnkBracket, nnkPar:
    for child in node:
      collectDependsOnEntries(child, output)
  of nnkCommand, nnkCall:
    for child in node:
      collectDependsOnEntries(child, output)
  of nnkAccQuoted:
    output.add(identText(node))
  else:
    discard

macro depends_on*(packageName: untyped; deps: untyped): untyped =
  ## Mode 3 DSL: declare in-workspace dep edges from ``packageName`` to
  ## every entry in ``deps``. Used both in hand-authored ``repro.nim``
  ## (for scanner-blind deps) and in generated ``repro.scanned-deps.nim``
  ## (the ``repro deps refresh`` output).
  ##
  ## Expansion emits one ``registerWorkspaceDep(<pkg>, <dep>)`` runtime
  ## call per declared dep. The runtime registry is inspection-only today
  ## (see ``WorkspaceDepEdge`` in ``runtime_core.nim``); the standard
  ## provider does NOT yet consume these edges for graph wiring. The
  ## Mode 3 Nim pilot establishes the DSL surface; consumption is
  ## deferred to a follow-on milestone, per
  ## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Honest scope".
  let pkgName = identText(packageName)
  if pkgName.len == 0:
    error("depends_on expects a package identifier as its first argument",
      packageName)
  var entries: seq[string] = @[]
  collectDependsOnEntries(deps, entries)
  result = newStmtList()
  for entry in entries:
    if entry.len == 0:
      continue
    let pkgLit = newLit(pkgName)
    let depLit = newLit(entry)
    result.add(quote do:
      registerWorkspaceDep(`pkgLit`, `depLit`))
