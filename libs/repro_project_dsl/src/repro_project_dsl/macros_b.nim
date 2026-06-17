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

proc m2TypeReprIsSupportedScalar(typeRepr: string): bool =
  ## True iff the ``T`` from a ``name: T = default`` entry names one of
  ## the four primitive shapes M2's runtime understands. The check is
  ## a deliberate string-match: at macro-expansion time we only have
  ## the verbatim source repr — semchecking the type would require a
  ## ``typed`` macro and pull in the full symbol environment. The
  ## predicate covers the common spellings (``bool``, ``int``, ``int8``,
  ## …, ``int64``, ``uint``, ``string``, ``float``, ``float32``,
  ## ``float64``). Authors writing complex types (``seq[string]``,
  ## ``MyEnum``, ``Table[string, int]``, …) get a silent passthrough so
  ## the legacy NDE recipes keep compiling; future M3+ widens the
  ## supported set as the runtime grows new ``DslScalarKind`` arms.
  let trimmed = typeRepr.strip()
  trimmed in ["bool", "int", "int8", "int16", "int32", "int64",
              "uint", "uint8", "uint16", "uint32", "uint64",
              "string", "float", "float32", "float64"]

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
