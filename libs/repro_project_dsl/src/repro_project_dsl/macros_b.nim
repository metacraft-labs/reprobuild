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
  let (sectionStmts {.used.}, preservedStmts) = partitionPackageBody(body)
  let pkg = parsePackageDef(name, body)
  let packageName = pkg.packageName
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
