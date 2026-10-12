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

proc artifactBuildBodyName(nameNode: NimNode): string =
  ## Extract the artifact member name from an ``executable <name>:`` /
  ## ``library <name>:`` head node. Mirrors ``m3ArtifactNameNode`` (which
  ## is declared further down) so the flattened build body can carry the
  ## owning member for the L3 per-artifact ``beginBuildContext`` push.
  ## Returns ``""`` for unrecognised name shapes.
  case nameNode.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    nameNode.strVal
  of nnkIdent, nnkSym, nnkAccQuoted:
    identText(nameNode)
  else:
    ""

proc artifactLockFileDesignation(artifactBody: NimNode): string =
  ## Named-Lock-Files NLF-M7 (§4.3) — the ``lockFile <name>`` line, read
  ## straight off the artifact body so the flattening pass can scope the
  ## artifact's edges without re-running the ``macros_a`` parser.
  for stmt in artifactBody:
    if calleeName(stmt).normalize != "lockfile": continue
    if stmt.len < 2: continue
    var nameNode = stmt[1]
    if nameNode.kind == nnkStmtList and nameNode.len == 1:
      nameNode = nameNode[0]
    if nameNode.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      return identText(nameNode)
  ""

proc wrapArtifactBuildBody(packageName, memberName: string;
                           stmts: NimNode; lockFileName = ""): NimNode =
  ## Wrap one artifact's flattened ``build:`` statements in a
  ## ``beginBuildContext(package, member) / try body finally
  ## endBuildContext()`` block. This restores the M4 per-artifact
  ## context frame around the artifact body in PROVIDER MODE — where the
  ## M4 emitters gate their body splice off and ``buildXxxPackage``
  ## (fed by this flattened list) is the sole executor. With the frame
  ## present, ``nim.c``'s ``maybeTagPublicInterface`` can attribute the
  ## edge to the owning ``(package, member)`` and tag declared
  ## ``executable``/``library`` members for binary-cache publication.
  ## The top-level (package-scoped) ``build:`` block is NOT wrapped —
  ## it carries no owning member, so its edges stay untagged (correct:
  ## they are not the package's declared public interface).
  ##
  ## Named-Lock-Files NLF-M7 (§4.3 / §4.4): when the artifact designates a
  ## lock file, the same wrapper pushes the designation for the duration of
  ## its edges. That is what makes designation a property of the ARTIFACT
  ## even though every artifact's ``build:`` statements are flattened into one
  ## package-level proc — without it the flattening would erase exactly the
  ## distinction §4.3 exists to express, and the canonical example (a
  ## ``hostTools`` tablegen and a ``targetRuntime`` app in one package) would
  ## emit both under one lock file.
  ##
  ## Push and pop sit in the SAME ``try``/``finally`` as the build context,
  ## for the reason §4.4 gives for `withLockFile`'s: a recipe that raises
  ## inside one artifact's body must not leave the next artifact's edges
  ## designated to a lock file nobody wrote.
  let pkgLit = newLit(packageName)
  let memberLit = newLit(memberName)
  if lockFileName.len == 0:
    return quote do:
      block:
        beginBuildContext(`pkgLit`, `memberLit`)
        try:
          `stmts`
        finally:
          endBuildContext()
  let lockLit = newLit(lockFileName)
  result = quote do:
    block:
      beginBuildContext(`pkgLit`, `memberLit`)
      pushLockFileScope(lskArtifact, `lockLit`)
      try:
        `stmts`
      finally:
        popLockFileScope()
        endBuildContext()

proc collectBuildStatements(pkgBody: NimNode; packageName = ""): NimNode =
  ## Aggregate every ``build:`` block in the package body — both the
  ## top-level ``build:`` and any per-artifact ``build:`` nested inside
  ## an ``executable`` or ``library`` member — into a single flat
  ## ``StmtList``. M9.N Batch C.1 introduced the per-``executable`` form
  ## (ninja / meson / gcc); M9.R.15q.1.10 extended the same shape to
  ## ``library`` so multi-library custom-shell recipes (e.g. boost's
  ## five-library bootstrap.sh + b2 pipeline) can anchor their build
  ## body on a library artifact instead of forcing a synthetic
  ## executable. Without this extension, ``library X: build: shell ...``
  ## silently dropped its body — the smoke test was the only path
  ## populating the shell-action registry (via macro module-init
  ## evaluation that briefly touched the body); the provider mode
  ## emitted no graph fragment and crashed with "provider did not write
  ## a response file".
  ##
  ## L3 PUBLISH-SCOPE: when ``packageName`` is supplied, each
  ## per-artifact ``build:`` body is wrapped in a
  ## ``beginBuildContext``/``endBuildContext`` pair carrying the owning
  ## ``(package, member)`` so provider-mode execution restores the M4
  ## frame and public-interface tagging fires (see
  ## ``wrapArtifactBuildBody``). Callers that only need the emptiness
  ## check omit ``packageName`` and get the raw (unwrapped) flattening.
  result = newStmtList()
  for stmt in pkgBody:
    if calleeName(stmt).normalize == "build":
      for buildStmt in stmt[1]:
        result.add(buildStmt)
    elif calleeName(stmt).normalize == "executable":
      # Same shape, and the same hazard, as the ``library`` arm below: a
      # bare ``executable X`` command carries no body and so has only two
      # children. The library arm grew this guard; this one did not, so a
      # bare executable reached ``stmt[2]`` and aborted the macro with
      # ``index 2 not in 0 .. 1``. A body-less executable has no
      # per-artifact ``build:`` to collect by definition, so skipping is
      # the whole fix.
      if stmt.len < 3:
        continue
      let exeBody = stmt[2]
      let member = artifactBuildBodyName(stmt[1])
      var artifactStmts = newStmtList()
      for exeStmt in exeBody:
        if calleeName(exeStmt).normalize == "build":
          for buildStmt in exeStmt[1]:
            artifactStmts.add(buildStmt)
      if artifactStmts.len > 0:
        if packageName.len > 0 and member.len > 0:
          result.add(wrapArtifactBuildBody(packageName, member, artifactStmts,
            artifactLockFileDesignation(exeBody)))
        else:
          for s in artifactStmts: result.add(s)
    elif calleeName(stmt).normalize == "library":
      # ``library X:`` with a body has the same shape as ``executable X:``
      # — a Call/Command node whose third child is the body StmtList. A
      # bare ``library X`` command (no body) has only two children; skip
      # it so we don't index out of bounds.
      if stmt.len < 3:
        continue
      let libBody = stmt[2]
      let member = artifactBuildBodyName(stmt[1])
      var artifactStmts = newStmtList()
      for libStmt in libBody:
        if calleeName(libStmt).normalize == "build":
          for buildStmt in libStmt[1]:
            artifactStmts.add(buildStmt)
      if artifactStmts.len > 0:
        if packageName.len > 0 and member.len > 0:
          result.add(wrapArtifactBuildBody(packageName, member, artifactStmts,
            artifactLockFileDesignation(libBody)))
        else:
          for s in artifactStmts: result.add(s)
    elif calleeName(stmt).normalize == "files":
      # M9.R.59.1: data-only ``files X:`` follows the same shape as
      # ``executable X:`` / ``library X:`` — a Call/Command node whose
      # third child is the body StmtList. Without this arm,
      # ``files X: build: shell ...`` silently drops its body in
      # provider mode (see the hwdata recipe's from-source-custom
      # driver). Same guard shape as the ``library`` arm: bare
      # ``files X`` (no body) has only two children and gets skipped.
      if stmt.len < 3:
        continue
      let filesBody = stmt[2]
      for filesStmt in filesBody:
        if calleeName(filesStmt).normalize == "build":
          for buildStmt in filesStmt[1]:
            result.add(buildStmt)

proc l2LowerDevEnvActivities(packageName: string;
                             body: NimNode): NimNode
  ## Forward declaration. Shared-Development-Services L2's dev-env
  ## ``activity`` / ``enable`` walker is defined after the M5 service
  ## emitter it reuses (``m5ServiceEmission``), which is ~2000 lines
  ## below ``buildCode``, the only caller.

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

proc usesInstallMirrorBuildCall(body: NimNode): bool =
  # Declaration-time metadata for explicit direct/qualified calls only. Do not
  # evaluate build code or attempt to expand arbitrary helper procedures.
  if body.kind in {nnkCall, nnkCommand} and body.len > 0:
    var callee = body[0]
    if callee.kind == nnkDotExpr:
      callee = callee[^1]
    if callee.kind in {nnkIdent, nnkSym} and
        (callee.eqIdent("cmake_package") or callee.eqIdent("meson_package") or
         callee.eqIdent("autotools_package") or callee.eqIdent("shell")):
      return true
  for child in body:
    if usesInstallMirrorBuildCall(child):
      return true

proc buildCode(pkg: PackageDef; body: NimNode): NimNode =
  let buildBody = collectBuildStatements(body, pkg.packageName)
  # Shared-Development-Services L2: the constructor-shaped
  # ``activity <name>(...):`` declarations and the ``enable`` call
  # sites are lowered before the body is spliced into
  # ``devEnv<Pkg>Package()``. ``activity "<name>"`` passes through
  # untouched to the proc that has always handled it.
  let devEnvBody = l2LowerDevEnvActivities(pkg.packageName,
    collectDevEnvStatements(body))
  if buildBody.len == 0 and devEnvBody.len == 0:
    return newStmtList()
  let lifted = liftForeachStatements(pkg, buildBody)
  let procName = ident("build" & titleIdent(pkg.packageName))
  let devEnvProcName = ident("devEnv" & titleIdent(pkg.packageName))
  let pkgLiteral = parseExpr(packageLiteral(pkg))
  let pkgNameLit = newLit(pkg.packageName)
  let devEnvProc =
    if devEnvBody.len > 0:
      # Shared-Development-Services D-SS11 (§4.6): the dev-env body runs
      # inside `beginResolverPackage` / `endResolverPackage`, so a
      # `<package>.<service>.shared(...)` call in an `enable` argument
      # can name the CONSUMING package without the author repeating it.
      #
      # The ambient is set HERE and nowhere else, which is also what
      # makes a resolver OUTSIDE a dev-env body refused rather than
      # misattributed: `resolveSharedService` raises when the ambient is
      # empty instead of recording a contribution attributed to "". §5's
      # attribution property -- "every converged member can already name
      # the package that contributed it" -- is unusable if the name can
      # be blank, and a blank contributor also makes
      # `withdrawPackageContributions` unable to find the row again.
      #
      # `try`/`finally` rather than a plain pair: a recipe body that
      # raises (a refused required configurable, say) must not leave the
      # ambient set for whatever is lowered next in the same process.
      quote do:
        when defined(reproProviderMode):
          proc `devEnvProcName`*() =
            beginResolverPackage(`pkgNameLit`)
            try:
              `devEnvBody`
            finally:
              endResolverPackage()
    else:
      newStmtList()
  # Project-DSL-Composition M5 — Approach B: wrap the lowered build
  # body in a beginBuildBlock/endBuildBlock try/finally so helper-proc
  # call sites (and unknown preserved top-level statements) can find
  # the active package via `currentBuildState()` / `tryCurrentBuildState()`.
  # M9.R.15q.2.1 — chicken-and-egg fix for from-source-custom convention:
  #
  # ``from_source_custom.fromSourceCustomRecognize`` consults
  # ``registeredShellActions(packageName)`` to decide whether to claim a
  # recipe. The registry is populated by ``shell(...)`` calls inside the
  # recipe's ``build:`` body, which only runs INSIDE ``buildXxxPackage()``.
  # Under ``reproProviderMode`` the M4 emitters gate the body splice off
  # (so the legacy provider chain is the sole executor), but the legacy
  # chain only runs ``buildXxxPackage`` AFTER the convention's
  # ``emitFragment`` has been called -- which is downstream of
  # ``recognise``. The result is that ``recognise`` always sees an empty
  # shell registry at provider startup and rejects the recipe, leaving
  # boost / ninja / meson / gcc with ``scheduler:actions=0`` and no graph
  # fragment.
  #
  # The fix is to emit a ``when defined(reproProviderMode):
  # buildXxxPackage()`` invocation at module-init time so the shell
  # registry is populated BEFORE ``recognise`` runs. An idempotency guard
  # checks ``registeredShellActions(pkg).len == 0`` before invoking so
  # the body never runs twice (the legacy ``runPackageProvider`` chain
  # also calls ``buildXxxPackage`` later via ``buildPackageFragment``;
  # without the guard, ``shell(...)`` rows would accumulate twice).
  #
  # The init call's ONLY needed side effect is populating the shell +
  # fetch registries. Running the build body, however, also re-runs
  # every typed-tool wrapper, which registers target-export rows via
  # ``registerImplicitTargetExports``. At module-init time there is no
  # active ``buildPackageFragment`` owning-package override (that is set
  # only during a real provider run), so those rows would be attributed
  # to the macro-baked owner (the tool's package) instead of THIS
  # package. Multiple typed-tool fixtures that each emit the same
  # implicit name (e.g. ``cli``) would then all register under one owner
  # and trip the within-package same-name collision check, raising at
  # module-init time and crashing the binary before any test runs.
  #
  # To keep the init call's reach scoped to the shell/fetch registries
  # we mirror ``buildPackageFragment``'s registry hygiene around it:
  #   * reset the target-export registry before AND after the body runs
  #     so init-time rows never accumulate across packages, and
  #   * set the per-package owning override for the duration so any rows
  #     that ARE produced are attributed to this package — exactly as
  #     the subsequent real provider run will attribute them.
  # The target-export rows produced here are transient (the real run
  # via ``buildPackageFragment`` resets the registry again and rebuilds
  # them), but ``dslPortShellActions`` is NOT reset by
  # ``resetTargetExportRegistry``, so the shell registry the
  # from-source-custom ``recognise`` consults survives — preserving the
  # original fix.
  #
  # The pass runs while the binary is still initialising, so a body that
  # raises here aborts the process before it can answer a single request.
  # Every recipe in a project is linked into ONE provider binary, so that
  # turns one recipe's startup-time assumption into "no target in this
  # project can be built" -- reported to the operator as nothing but
  # "provider exited with code 1" and a stack trace naming neither the
  # request nor the package.
  #
  # The pass is speculative by construction: its only durable effect is
  # the shell/fetch registry pre-population, and the real invocation
  # resets and rebuilds that per package. So a failure here is contained
  # and recorded rather than fatal. It is NOT discarded: the failure is
  # kept where a gate can assert it is empty, and nothing about the real
  # invocation is weakened -- the same body runs again with a real project
  # root, and if it raises THEN it raises as it always did.
  #
  # ``beginProviderStartupBody`` also lets a body ask, positively, whether
  # it is in this pass. Bodies previously had to infer it from an empty
  # ``activeProviderProjectRoot()``, which conflates the pass with a
  # planning fault that must stay fatal.
  #
  # ``Defect`` IS contained here, alongside ``CatchableError``, and that is
  # a decision rather than an oversight in either direction:
  #
  #   * A body running with no project root fails at index, slice and
  #     range operations at least as often as it raises -- ``path[0]`` on
  #     an empty string, ``splitPath`` results indexed blind. Those are
  #     ``Defect``s in Nim. Containing only ``CatchableError`` would leave
  #     the LIKELIEST failure of exactly the pass this exists to survive
  #     uncontained, and uncontained means the operator gets "provider
  #     exited with code 1" for every target in the project -- the symptom
  #     the containment was written to remove.
  #   * The usual argument against catching a ``Defect`` -- that the
  #     process' invariants are broken and continuing is unsound -- does
  #     not distinguish the two cases here. Whatever a half-run body
  #     leaves behind, it leaves behind identically when it raises a
  #     ``CatchableError`` half-way, and that has been contained since this
  #     block was written. The ``finally`` below restores the pass depth,
  #     the owning-package override and the target-export registry on both
  #     paths, and the pass' one durable effect -- the shell/fetch
  #     registry -- is rebuilt per package by the real invocation.
  #   * The containment is scoped to the STARTUP pass only. The same body
  #     invoked for real is not wrapped, so a ``Defect`` during planning
  #     stays fatal, which is where "the invariants are broken" is the
  #     right response.
  #   * It follows the boundary this repository already draws the same way:
  #     ``repro_resources/library_abi.nim``'s ``withState`` catches
  #     ``CatchableError`` and ``Defect`` and reports the second with a
  #     ``defect:`` prefix. The prefix is kept here so a reader of the
  #     failure log can tell which kind of failure a package had.
  #
  # What CANNOT be contained, and is not claimed to be: a ``quit`` in a
  # startup body. ``quit`` raises nothing -- it runs exit handlers and
  # ends the process -- so no handler anywhere can intercept it, and a
  # recipe that calls it still takes every target in the project down.
  # That is a property of ``quit``, not a gap in this block; the remedy is
  # that a recipe must raise rather than quit, which the gate asserts by
  # showing the raise IS contained.
  let providerModeInitCall =
    if buildBody.len > 0:
      quote do:
        when defined(reproProviderMode):
          if registeredShellActions(`pkgNameLit`).len == 0:
            resetTargetExportRegistry()
            setCurrentOwningPackageOverride(`pkgNameLit`)
            beginProviderStartupBody(`pkgNameLit`)
            try:
              `procName`()
            except CatchableError as reproStartupBodyError:
              noteProviderStartupBodyFailure(
                `pkgNameLit`, reproStartupBodyError.msg)
            except Defect as reproStartupBodyDefect:
              noteProviderStartupBodyFailure(
                `pkgNameLit`, "defect: " & reproStartupBodyDefect.msg)
            finally:
              endProviderStartupBody()
              clearCurrentOwningPackageOverride()
              resetTargetExportRegistry()
    else:
      newStmtList()
  # M9.R.15q.2.1 — translate shell-action rows into BuildActionDef rows.
  # Per-project providers don't dispatch through ``from_source_custom``'s
  # ``emitFragment``, so ``shell(...)`` rows registered by the user's
  # ``build:`` body never become BuildActionDef rows on their own.
  # ``synthesizeCustomShellBuildActions`` consumes the in-process shell
  # + fetch registries and emits the fetch + shell chain via
  # ``buildAction(...)`` directly into the per-thread registry
  # ``buildPackageFragment`` queries at fragment-emit time. The call is
  # a no-op when the shell registry is empty (the recipe drove a typed
  # constructor instead) or when no project root is active (the recipe
  # was imported by a test fixture outside provider mode).
  #
  # The proc resets ``dslPortShellActions`` for THIS package at entry so
  # repeat invocations don't accumulate duplicate rows. Without the
  # reset: the module-init invocation (the ``providerModeInitCall``
  # above) runs the body once, populating the shell registry; then
  # ``runPackageProvider`` invokes the same proc a SECOND time via
  # ``buildPackageFragment`` (which resets ``buildActionRegistry`` but
  # NOT ``dslPortShellActions``), so the body's ``shell(...)`` calls
  # double-register. The reset is per-package so other packages' rows
  # (imported via cross-recipe ``buildDeps:`` chains) survive.
  if lifted.lifts.len == 0:
    let rootBody = lifted.rootBody
    result = quote do:
      when not defined(reproInterfaceMode):
        `devEnvProc`
        proc `procName`*() =
          resetDslPortShellStateForPackage(`pkgNameLit`)
          let buildStateHandle = beginBuildBlock(`pkgNameLit`)
          try:
            `rootBody`
            synthesizeCustomShellBuildActions(`pkgNameLit`)
          finally:
            endBuildBlock(buildStateHandle)
        `providerModeInitCall`
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
          resetDslPortShellStateForPackage(`pkgNameLit`)
          let buildStateHandle = beginBuildBlock(`pkgNameLit`)
          try:
            `rootBody`
            synthesizeCustomShellBuildActions(`pkgNameLit`)
          finally:
            endBuildBlock(buildStateHandle)
        `providerModeInitCall`
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

proc emitLockFileDesignations(pkg: PackageDef; site: NimNode): NimNode =
  ## Named-Lock-Files NLF-M7 — §4.9's compile error and §4.3's registration.
  ##
  ## Two calls per designation, and they are two rather than one on purpose:
  ##
  ##   * `requireDeclaredLockFile` runs at MACRO-EXPANSION time and is what
  ##     makes an undeclared name "fail at **recipe compile time**" (§4.9's
  ##     requirement, which also forbids "a runtime lookup miss" and any
  ##     silent fall back to `default`);
  ##   * `registerArtifactLockFile` runs at MODULE-INIT time and is what lets
  ##     the compiled recipe report its own designations — to the propagation
  ##     (§4.1), to `repro lock list`, and to `repro graph`, which §4.6 asks
  ##     to "report pinned dependencies at the consumer".
  ##
  ## A designation is checked even when the artifact has no `build:` body.
  ## An artifact designating a lock file that does not exist is an author
  ## error regardless of whether the recipe currently emits an edge for it,
  ## and checking only the ones that do would make the diagnostic appear and
  ## disappear as a body is commented out.
  result = newStmtList()
  let pkgLit = newLit(pkg.packageName)
  let fileLit = newLit(pkg.sourceFile)
  var sites: seq[tuple[artifact, lockFileName: string; line: int]] = @[
    (artifact: "", lockFileName: pkg.lockFile, line: pkg.sourceLine)]
  for exe in pkg.executables:
    sites.add((artifact: exe.exportName, lockFileName: exe.lockFile,
      line: exe.sourceLine))
  for lib in pkg.libraries:
    sites.add((artifact: lib.name, lockFileName: lib.lockFile,
      line: lib.sourceLine))
  for entry in sites:
    if entry.lockFileName.len == 0: continue
    # `ident`, not `bindSym`: this is an ordinary proc called from the
    # `package` macro rather than a macro itself, so the emitted names are
    # resolved at the recipe. Both reach a recipe through
    # `repro_project_dsl`, which re-exports them.
    result.add(newCall(ident("requireDeclaredLockFile"),
      newLit(entry.lockFileName), pkgLit, fileLit, newLit(entry.line),
      newLit(0)))
    result.add(newCall(ident("registerArtifactLockFile"),
      pkgLit, newLit(entry.artifact), newLit(entry.lockFileName), fileLit,
      newLit(entry.line)))
  discard site

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
  if variants.len == 0 and pkg.toolUses.len == 0 and
      pkg.nativeBuildDeps.len == 0 and pkg.runtimeDeps.len == 0 and
      pkg.packageSources.len == 0:
    return
  # Emit the import lazily so package files without variants OR
  # solver-bound dependencies don't get an unused import.
  # ``finalizeVariantsAtModuleInit`` is the sentinel symbol that tells us the
  # configurables module is in scope. It is the symbol this expansion actually
  # CALLS, which is the property a sentinel needs: keying on ``finalizeVariants``
  # instead would skip the import for a module that somehow had only the older
  # name in scope, and the emission below would then not compile.
  result.add(parseStmt(
    "when not declared(finalizeVariantsAtModuleInit):\n" &
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
  # M5 SELF-HOST — the declared source provenances go FIRST. They are read
  # by `buildPackageDecls` inside `finalizeVariants()`, which the last
  # statement of this block calls, so anything emitted after that call would
  # arrive too late to reach the solve and the lock.
  for decl in pkg.packageSources:
    result.add(parseStmt(
      "packageSource(" & escForCode(decl.packageName) & ", " &
      escForCode(decl.source) & ")\n"))
  # Spec-Implementation M2d: emit one registerSolverDependency call per
  # parsed PackageUseDef. The solver consumes these to (a) materialize
  # the package version universe (via ``chosenVersion(...)``) and (b)
  # gate variant-conditioned arms (the ``gateVariant`` / ``gateValue``
  # pair is the M2c ``ConditionalGate``). Calls are emitted BEFORE
  # ``finalizeVariants()`` so the registry is populated when the
  # solver runs.
  #
  # Named-Lock-Files NLF-M7 (§4.6): all THREE dependency lists are emitted,
  # each entry carrying the list it was written in.
  #
  # Before this, only `pkg.toolUses` reached the solver at all —
  # `nativeBuildDeps:` and `runtimeDeps:` were parsed into their own slots and
  # then never registered, so the BUILD-platform half of the approved
  # host/target split was invisible to the solve. §4.6 measured the erasure
  # one layer further down (the `toolUses & nativeBuildDeps & runtimeDeps`
  # fold at serialization) and drew the same conclusion: "the platform
  # distinction the recipe expressed is **erased before the solver ever sees
  # it**." Both halves are fixed here and in `packageUseSeqLiteral`.
  #
  # The de-duplication is by (dep, kind), not by dep. §4.6 quotes
  # `From-Source-Build-Recipes.md`: "A dependency that appears in more than
  # one list must be written in each (reprobuild does not collapse them —
  # explicit is better)", and a package that writes the same library in both
  # `nativeBuildDeps:` and `buildDeps:` is asking for exactly the two
  # instances NLF-PROP-4 asserts. Collapsing them here would silently answer
  # "one".
  var emitted: seq[string] = @[]
  for (uses, kind) in [(pkg.toolUses, DepKindTarget),
                       (pkg.nativeBuildDeps, DepKindNative),
                       (pkg.runtimeDeps, DepKindRuntime)]:
    for useDef in uses:
      if useDef.packageSelector.len == 0: continue
      let key = useDef.packageSelector & "\x1f" & kind & "\x1f" &
        useDef.rawConstraint & "\x1f" & useDef.gateVariant & "\x1f" &
        useDef.gateValue
      if key in emitted: continue
      emitted.add(key)
      result.add(parseStmt(
        "registerSolverDependency(" & escForCode(pkg.packageName) & ", " &
        escForCode(useDef.packageSelector) & ", " &
        escForCode(useDef.rawConstraint) &
        ", gateVariant = " & escForCode(useDef.gateVariant) &
        ", gateValue = " & escForCode(useDef.gateValue) &
        ", depKind = " & escForCode(kind) & ")\n"))
  # ``finalizeVariantsAtModuleInit`` rather than ``finalizeVariants``: this
  # call sits at MODULE SCOPE, and the imports emitted above it mean one runs
  # per recipe in the transitive closure, over a registry that only grows. The
  # module-init spelling defers the solve to the first read of the answer so a
  # deep recipe pays ONE solve (or none) instead of one per imported recipe.
  # See ``repro_dsl_stdlib/configurables/variants.finalizeVariantsAtModuleInit``.
  result.add(parseStmt("finalizeVariantsAtModuleInit()\n"))

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
  ## True iff the ``T`` from a ``config:`` entry -- ``name: T = default``
  ## or, since Shared-Development-Services L5 made a key with no default
  ## a REQUIRED configurable, a bare ``name: T`` -- names one of the
  ## shapes M2 (post-M9.D) handles:
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
  # Shared-Development-Services L8: `seq[string]` IS carried now. The
  # doc comment above used to say it "stays rejected here so the
  # runtime's static-error branch never fires", and that branch no
  # longer exists -- `dskSeqString` is a real arm and a `seq[string]`
  # `config:` key is §5's CONTRIBUTION POINT ("a collection is a
  # configurable"). Until L8 such a key got NO cell at all: the one in
  # the repository, `fontPackages` in
  # `recipes/packages/de-foundation/graphics-stack/repro.nim`, carries a
  # comment saying exactly that and predicting this change ("When M3+
  # widens the runtime to cover `seq[string]`, the helper migrates to
  # `readConfigurable`").
  if inner.len > 0 and inner.strip() == "string":
    return true
  return false

proc m2TypeReprIsOrderedCollection*(typeRepr: string): bool =
  ## True iff `T` from a `config:` entry names the ORDERED COLLECTION
  ## the configurable lane carries, i.e. `seq[string]`.
  ##
  ## Shared-Development-Services L8: a `config:` key of this type is
  ## §5's CONTRIBUTION POINT. The predicate is separate from
  ## `m2TypeReprIsSupportedScalar` rather than folded into it because
  ## the two answer different questions -- "does this key get a slot"
  ## and "is that slot resolved by the contribution fold" -- and L7's
  ## review found the cost of one predicate answering two questions.
  let inner = m2SeqElementRepr(typeRepr.strip())
  inner.len > 0 and inner.strip() == "string"

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
      if m2TypeReprIsOrderedCollection(typeRepr):
        # Shared-Development-Services L8: an ordered-collection
        # `config:` key is a CONTRIBUTION POINT, resolved by §Resolution's
        # four-step fold rather than by the override table. A key with
        # no default seeds `@[]` -- see `recordContributionPoint`'s
        # comment on why an empty collection is a VALUE and not an
        # absence, i.e. why L5's "no default means REQUIRED" rule is
        # deliberately not applied to a collection.
        let seed = if entry.defaultNode == nil or
                      entry.defaultNode.kind == nnkEmpty: "@[]"
                   else: defaultRepr
        result.add(parseStmt(
          "recordContributionPoint[" & typeRepr & "](" &
          pkgLit & ", " & nameLit & ", " & seed & ")\n"))
        continue
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
  if stmt[^1].kind != nnkStmtList:
    return
  # Shape-matched as an entry (a call with an indented body) but keyed by
  # something other than a string literal. Previously this returned unmatched
  # and the CALLER skipped it, so the whole version entry — revision, url,
  # repository and all — vanished without a word.
  #
  # The key stays literal-only on purpose: it is the map key `registerVersion`
  # is indexed by, and it is compared and looked up as text. But saying so
  # beats dropping the entry.
  if stmt[0].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("a versions: entry must be keyed by a string literal, e.g. " &
      "\"1.2.3\": — the key is the version identity the entry registers under",
      stmt[0])
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
      # These hold emittable SOURCE, not values — the same
      # transform-don't-evaluate treatment the provisioning setters get. A
      # non-literal used to hit the `continue` below and be dropped in
      # silence, so `sourceRevision = AptJammyAdapterVersion` compiled and
      # registered an EMPTY revision.
      #
      # That is the drop behind the "keep the version string in sync with
      # <Const> in the stdlib module" comments in the recipes: the const
      # existed, the DSL just could not accept it, so the value was pasted and
      # a comment asked a human to keep the two aligned.
      var sourceRevision = "\"\""
      var sourceChecksum = "\"\""
      var sourceUrl = "\"\""
      var sourceRepository = "\"\""
      for assignment in parsed.body:
        # Doc comments and `discard` legitimately appear in these bodies, so a
        # non-assignment is still skipped quietly.
        if assignment.kind notin {nnkAsgn, nnkFastAsgn}:
          continue
        if assignment[0].kind notin {nnkIdent, nnkSym}:
          continue
        let key = identText(assignment[0])
        let value =
          if assignment[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
            assignment[1].strVal.escape()
          else:
            assignment[1].repr
        case key
        of "sourceRevision": sourceRevision = value
        of "sourceChecksum": sourceChecksum = value
        of "sourceUrl": sourceUrl = value
        of "sourceRepository": sourceRepository = value
        else:
          # A misspelt key is the same silent drop wearing a different hat.
          # Warn rather than error: this arm is reached by 400+ recipe files
          # and an unrecognised key may predate this check, so make the signal
          # visible without breaking a build that used to pass.
          warning("unknown versions: entry key '" & key &
            "' — recognised keys are sourceRevision, sourceChecksum, " &
            "sourceUrl, sourceRepository; this assignment is ignored",
            assignment[0])
      let pkgLit = escForCode(packageName)
      let versionLit = escForCode(parsed.version)
      let revLit = sourceRevision
      let sumLit = sourceChecksum
      let urlLit = sourceUrl
      let repoLit = sourceRepository
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

proc emitM9R2cArtifactSlots(packageName: string;
                            classified: seq[ClassifiedSection]): NimNode =
  ## DSL-port M9.R.2c — emit ONLY the per-kind typed slot ``var``
  ## declarations for every ident-form artifact in ``classified``.
  ##
  ## Pulled out of ``emitM3Artifacts`` so the slot declarations can be
  ## appended to the package macro's expansion BEFORE ``buildCode``
  ## emits the ``build<Pkg>*()`` proc whose body references the slot
  ## by name. If the slot ``var`` were emitted AFTER the proc, Nim's
  ## semcheck would see the proc body's identifier use before the
  ## module-level binding declaration and reject the assignment as
  ## ``undeclared identifier``. The two emitters operate on the SAME
  ## classified seq with the SAME collision rules so the var emission
  ## and the registry append stay in lockstep.
  ##
  ## Per-kind slot type:
  ##   * ``library <n>:``    -> ``var <n>: Library``
  ##   * ``executable <n>:`` -> ``var <n>: Executable``
  ##   * ``files <n>``       -> ``var <n>: BuildActionDef``
  ##
  ## ``Library`` / ``Executable`` live in
  ## ``repro_dsl_stdlib/types/{library,executable}.nim``; recipes that
  ## declare a ``library`` / ``executable`` artifact need to import the
  ## typed-value layer. Most recipes already do this via
  ## ``import repro_dsl_stdlib/types/package_result`` (which re-exports
  ## ``library`` + ``executable`` since M9.R.2c). ``BuildActionDef``
  ## lives in ``repro_project_dsl`` and is always in scope.
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
    let artifactValueIdent =
      if parsed.isIdentForm: packageValueIdent(parsed.artifactName)
      else: ""
    let wouldCollideWithLegacyConst =
      parsed.isIdentForm and
      artifactValueIdent.normalize == pkgValueIdent.normalize
    if parsed.isIdentForm and parsed.identNode != nil and
       parsed.identNode.kind in {nnkIdent, nnkAccQuoted} and
       not wouldCollideWithLegacyConst:
      let identNode = parsed.identNode.copyNimTree()
      let slotTypeNode = case entry.ownership
        of soM3LibraryArtifact:    ident("Library")
        of soM3ExecutableArtifact: ident("Executable")
        of soM3FilesArtifact:      ident("BuildActionDef")
        else:                      ident("BuildActionDef")
      let varSection = nnkVarSection.newTree(
        nnkIdentDefs.newTree(
          nnkPragmaExpr.newTree(
            identNode,
            nnkPragma.newTree(ident("inject"), ident("used"))),
          slotTypeNode,
          newEmptyNode()))
      result.add(varSection)

proc emitM3Artifacts(packageName: string;
                     classified: seq[ClassifiedSection]): NimNode =
  ## Walk the classified section list; for every entry whose ownership
  ## tag claims an M3 artifact, emit one ``registerArtifact(...)`` call
  ## with the artifact's name, kind, and body repr.
  ##
  ## String-form recovery: ``executable "myTool": ...`` records the
  ## verbatim string into the registry; ident-form
  ## ``executable myTool:`` records ``myTool`` as the artifact name AND
  ## (via ``emitM9R2cArtifactSlots``, NOT this proc) gets a typed
  ## module-level ``var myTool: Executable`` injection so author code
  ## can refer to ``myTool`` lexically AND assign to it from a
  ## ``build:`` block.
  ##
  ## Collision guard (relevant for ``emitM9R2cArtifactSlots`` —
  ## documented here because the same rule applies to the var
  ## emission): ``wrapperCode`` ALWAYS emits
  ## ``const <packageValueIdent>* = <Title>Package()`` at module top
  ## level (see ``macros_a.nim:wrapperCode``). When the artifact ident
  ## matches that const's name — common in stdlib packages where
  ## ``package gcc:`` contains ``executable gcc:`` — the slot var
  ## injection would shadow / redefine the legacy const and fail
  ## compilation. ``emitM9R2cArtifactSlots`` skips the var injection
  ## in that case (the runtime registry still records the artifact;
  ## only the per-binding var is suppressed). The registry append
  ## itself is UNCONDITIONAL — every ident-form / string-form
  ## artifact ends up in ``registeredArtifacts``.
  ##
  ## DSL-port M9.R.2c: the per-kind typed slot ``var`` declarations
  ## moved to ``emitM9R2cArtifactSlots`` (called BEFORE ``buildCode``
  ## in the package macro so the slot binding precedes the generated
  ## ``build<Pkg>*()`` proc whose body may assign to it). This emitter
  ## now handles only the ``registerArtifact`` runtime calls.
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
    # DSL-port M9.R.2c — the per-kind typed slot ``var`` declarations
    # are emitted by ``emitM9R2cArtifactSlots`` BEFORE ``buildCode`` in
    # the package macro so the slot binding precedes the generated
    # ``build<Pkg>*()`` proc body that may assign to it via the
    # assignment-binding pattern (``libfoo = c_library(...)``). This
    # emitter only handles the ``registerArtifact`` runtime call,
    # preserving M3's sidecar-registry semantics.
    #
    # The collision guard + ident-form check live in
    # ``emitM9R2cArtifactSlots`` (same rules); the registerArtifact
    # call is unconditional (always emitted) so even artifacts that
    # collide with the legacy ``packageValueIdent`` const still appear
    # in ``registeredArtifacts`` for diagnostic queries.
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
          when not defined(reproProviderMode) and not defined(reproInterfaceMode):
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
            when not defined(reproProviderMode) and not defined(reproInterfaceMode):
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
  ## The argument is spliced VERBATIM into the generated call
  ## (``quote do: setActiveServiceDescription(`lit`)``), so it does not have to
  ## be a literal — the Nim compiler type-checks and evaluates whatever is
  ## written. Restricting to ``nnkStrLit`` meant a ``const`` or a helper call
  ## was SILENTLY DROPPED: this proc returned nil and the caller simply left the
  ## field unset, with no diagnostic.
  ##
  ## Accepting any expression means a non-string one now fails at the spliced
  ## call site with an ordinary type mismatch instead of vanishing. That is the
  ## point — the macro never evaluates or inspects the value, it only relocates
  ## it, and the compiler does the rest.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return nil
  if stmt.len != 2:
    return nil
  return stmt[1].copyNimTree()

const
  ## The trigger heads and actions ``Package-Model.md`` §"Service
  ## Lifecycle And Reactive Triggers" specifies, quoted back at the author
  ## in a refusal. Spelled out as text rather than derived from the enum,
  ## because the enum names (``stkChangeOutput``) are not what anybody
  ## writes in a recipe.
  m5ServiceRecognisedTriggers = "`on rebuild <ident>`, " &
    "`on change <buildOutput>`, `on change \"<path>\"`, `on start`, " &
    "`on stop` and `on crash`"
  m5ServiceRecognisedActions = "`hotReload`, `restart`, " &
    "`sendSignal \"<SIG...>\"`, `exec <cmd>` and `notify <endpoint>`"
  m5ServiceNoSilentDropRule = "An unrecognised spelling here is REFUSED " &
    "rather than dropped: a trigger that is recorded but can never fire, " &
    "or one recorded with none of its actions, is indistinguishable from " &
    "support for it. This is the same defect the `args` setter had before " &
    "Shared-Development-Services L1, where a non-literal argument vanished " &
    "with no diagnostic."
  m5ServiceSetterSurface = "`executable <ident>`, `args \"...\", ...`, " &
    "`runtimeFile <buildOutput>`, `identity <mode>`, `scope <value>`, " &
    "`readiness <probe>`, `workingDirectory \"<dir>\"`, " &
    "`stateDirectory \"<dir>\"`, `instance:`, `converge <point>`, " &
    "the systemd-unit setters and `on <trigger>:` blocks"
  m5ServiceHeadDropRule = "An extra argument here is REFUSED rather than " &
    "dropped: it is never semchecked, so an identifier that does not " &
    "exist compiles clean and an argument that is accepted and then not " &
    "there is indistinguishable from support for it."

const
  ## The trigger MODIFIERS ``Package-Model.md`` §"Service Lifecycle And
  ## Reactive Triggers" specifies and this release does not implement.
  ## They are a THIRD category beside the trigger heads and the actions,
  ## and the distinction is what the refusal below exists to say: an
  ## unrecognised spelling is a mistake, whereas a modifier is a
  ## documented spelling the implementation has not caught up with.
  m5ServiceSpecifiedModifiers: array[2, tuple[name, spec: string]] = [
    (name: "debounce",
     spec: "`debounce = \"200ms\"` -- \"wait for the trigger to stop " &
       "firing for the given duration before running the body\""),
    (name: "coalesce",
     spec: "`coalesce` -- \"if multiple triggers fire while a body is " &
       "running, run the body once more afterwards rather than queueing " &
       "each event\"")]

proc m5ServiceStmtAnchor(stmt: NimNode): NimNode =
  ## The node whose line info is the offending STATEMENT's own start.
  ##
  ## ``error(msg, node)`` reports ``node``'s line info, and for an
  ## assignment Nim puts that on the ``=`` rather than on the statement:
  ## a ``debounce = "200ms"`` indented by six spaces reported column 16
  ## while every sibling refusal in this walker reports the offending
  ## statement's own column 7. The left-hand side carries the real start,
  ## so anchor there. Right line either way — this is about the column,
  ## which is harmless for a one-line statement and misleading for a
  ## wrapped one.
  if stmt.kind in {nnkAsgn, nnkExprEqExpr} and stmt.len > 0:
    return stmt[0]
  stmt

proc m5ServiceModifierName(stmt: NimNode): string =
  ## The name of the ``Package-Model.md`` trigger modifier this statement
  ## spells, or ``""`` when it is not one.
  ##
  ## Every shape a modifier could plausibly be written in is matched on
  ## its HEAD identifier, deliberately: ``coalesce`` is a bare ident,
  ## ``debounce = "200ms"`` an ``nnkAsgn`` in a body and an
  ## ``nnkExprEqExpr`` beside a trigger head, and ``debounce "200ms"``
  ## a command. All four are the same author intent and all four earn the
  ## same answer — the alternative is a diagnostic that depends on which
  ## of them the author guessed.
  var head: NimNode = nil
  if stmt.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    head = stmt
  elif stmt.kind in {nnkAsgn, nnkExprEqExpr, nnkCall, nnkCommand} and
      stmt.len > 0 and stmt[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    head = stmt[0]
  if head == nil:
    return ""
  let name = identText(head).normalize
  for candidate in m5ServiceSpecifiedModifiers:
    if name == candidate.name:
      return candidate.name
  ""

proc m5ServiceUnimplementedModifier(
    stmt: NimNode; modifier, position: string) =
  ## Refuse a trigger modifier — ``debounce`` / ``coalesce`` — as
  ## SPECIFIED BUT NOT IMPLEMENTED, in the shape ``on ready:`` already
  ## uses: cite the section, say what is missing, and name the open
  ## decision.
  ##
  ## Before this, both landed on ``m5ServiceUnknownAction``, whose
  ## message calls them "trigger action"s and lists only the five
  ## actions — so an author writing a spelling ``Package-Model.md``
  ## §"Service Lifecycle And Reactive Triggers" sets out verbatim was
  ## told it is not a thing, rather than that it is specified and not
  ## yet built. Refusing is still right; only the message was wrong.
  var specText = ""
  for candidate in m5ServiceSpecifiedModifiers:
    if candidate.name == modifier:
      specText = candidate.spec
  error("`" & modifier & "` is a trigger MODIFIER that Package-Model.md " &
    "§\"Service Lifecycle And Reactive Triggers\" specifies and that this " &
    "release does NOT implement, so `" & stmt.repr.strip() & "` " &
    position & " is refused rather than accepted and discarded. The " &
    "section lists it under \"Modifiers attached to an `on:` block " &
    "coalesce noisy signals\": " & specText & ". What is missing: a " &
    "modifier has nowhere to be carried -- `ServiceTriggerDef` has a " &
    "field for the trigger, its subject and its actions and none for a " &
    "modifier, unlike the supervisor options of `restart`, which reach " &
    "the record as `ServiceTriggerAction.argument` text -- and nothing " &
    "consumes a trigger yet: Shared-Development-Services L1 records " &
    "triggers and stops there, supervisor lowering is a later milestone. " &
    "The open decision: the section says \"modifiers attached to an " &
    "`on:` block\" and never fixes WHERE one is written, so neither " &
    "`debounce = \"200ms\"` inside the body nor `on <trigger>, debounce " &
    "= \"200ms\":` beside the head is the established spelling, and that " &
    "has to be settled before either is accepted. Until then a modifier " &
    "is REFUSED rather than dropped: one that is accepted and never " &
    "applied is indistinguishable from support for it. Recognised in " &
    "this release: " & m5ServiceRecognisedTriggers & ", with the actions " &
    m5ServiceRecognisedActions & ".", m5ServiceStmtAnchor(stmt))

proc m5ServiceUnknownTrigger(stmt, spec: NimNode) =
  ## Refuse an ``on <trigger>:`` head the walker does not recognise.
  ##
  ## Before Shared-Development-Services L1's follow-up this returned
  ## ``nil`` and the caller skipped the statement: ``on ready:`` produced
  ## NO RECORD AT ALL and compiled clean.
  ##
  ## ``on ready:`` is handled by name because it is the spelling
  ## ``Shared-Development-Services.md`` §9's worked example uses, so it is
  ## the one spelling an author is most likely to arrive at — and the one
  ## where "unrecognised" is least informative.
  let spelling = spec.repr.strip()
  var message = "`service` does not recognise the trigger `on " &
    spelling & ":`. Package-Model.md §\"Service Lifecycle And Reactive " &
    "Triggers\" specifies " & m5ServiceRecognisedTriggers & ". "
  if spelling.normalize == "ready":
    message.add("`on ready:` is the spelling Shared-Development-" &
      "Services.md §9 \"Worked example\" uses, and it is deliberately NOT " &
      "recognised yet: a readiness trigger needs the `readiness` probe " &
      "that says WHEN the service is ready -- §9 declares it one line " &
      "above, as `readiness httpGet(\"/debug/ready\", port = port)` -- " &
      "which this release does not implement, and whose edge semantics " &
      "are still that spec's §8 open decision D-SS10. ")
  message.add(m5ServiceNoSilentDropRule)
  error(message, stmt)

proc m5ServiceUnknownAction(stmt: NimNode; triggerDesc: string) =
  ## Refuse a statement inside an ``on <trigger>:`` body that is not one
  ## of the five actions. Before L1's follow-up this returned ``nil`` and
  ## the caller skipped it, so ``on crash: converge relyingParties``
  ## recorded the trigger with ZERO actions and the identifier
  ## ``relyingParties`` never reached the compiler at all.
  ##
  ## A spelling the SPEC contains belongs to
  ## ``m5ServiceUnimplementedModifier`` instead; this message is for a
  ## spelling that is in neither the implementation nor the spec.
  error("`service` does not recognise the trigger action `" &
    stmt.repr.strip() & "` inside " & triggerDesc & ". Package-Model.md " &
    "§\"Service Lifecycle And Reactive Triggers\" specifies " &
    m5ServiceRecognisedActions & ". " & m5ServiceNoSilentDropRule,
    m5ServiceStmtAnchor(stmt))

proc m5ServiceTriggerOptionText(stmt: NimNode): string =
  ## The supervisor options of ``restart`` / ``hotReload`` /
  ## ``restartOnCrash``, as source text — ALL of them.
  ##
  ## ``Package-Model.md`` §"Service Lifecycle And Reactive Triggers"
  ## specifies them as a list ("Optional named arguments configure
  ## supervisor-level policy: ``backoff = exponential|linear|fixed``,
  ## ``maxRetries = <n>``, ``delay = "5s"``"), so
  ## ``restart backoff = exponential, maxRetries = 3`` is three AST
  ## children and reading only ``stmt[1]`` dropped ``maxRetries`` — the
  ## spec's own spelling, silently half-recorded. They are text rather
  ## than parsed for the reason the original note gives: no lowering
  ## consumes them yet, and a schema invented here would be a second
  ## place to change when one does.
  var parts: seq[string] = @[]
  for i in 1 ..< stmt.len:
    parts.add(stmt[i].repr)
  parts.join(", ")

proc m5ServiceTriggerActionCall(stmt: NimNode; triggerDesc: string): NimNode =
  ## Shared-Development-Services L1 — one action inside an ``on
  ## <trigger>:`` body, lowered to its ``addActiveServiceTriggerAction``
  ## call. ``nil`` only for a statement that carries no action at all (a
  ## doc comment, a ``discard``); an action the taxonomy does not contain
  ## is a macro ``error`` here, not a ``nil`` the caller drops.
  ##
  ## The action taxonomy is ``Package-Model.md`` §"Service Lifecycle And
  ## Reactive Triggers": ``hotReload`` / ``restart`` / ``sendSignal`` /
  ## ``exec`` / ``notify``.
  ##
  ## ``triggerDesc`` is the enclosing trigger's source text, used only in
  ## diagnostics: a service can carry several ``on`` blocks and an error
  ## that names the action without naming its trigger sends the author
  ## grepping.
  if stmt.kind in {nnkCommentStmt, nnkEmpty, nnkDiscardStmt}:
    # A doc comment or an explicit ``discard`` is not an action and is not
    # a mistake. Everything else in the body is claimed to be one.
    return nil
  let modifier = m5ServiceModifierName(stmt)
  if modifier.len > 0:
    # Specified, not implemented — and it says so, rather than claiming
    # the author invented the word.
    m5ServiceUnimplementedModifier(stmt, modifier, "inside " & triggerDesc)
  if stmt.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    case identText(stmt).normalize
    of "hotreload":
      return quote do:
        addActiveServiceTriggerAction(stakHotReload)
    of "restart":
      return quote do:
        addActiveServiceTriggerAction(stakRestart)
    else:
      m5ServiceUnknownAction(stmt, triggerDesc)
  if stmt.kind notin {nnkCall, nnkCommand} or stmt.len < 2 or
      stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    m5ServiceUnknownAction(stmt, triggerDesc)
  let head = stmt[0]
  let headName = identText(head).normalize
  case headName
  of "sendsignal", "exec", "notify":
    # One argument, exactly. The runtime record carries one, so reading
    # ``stmt[1]`` and ignoring the rest dropped the others in silence.
    if stmt.len != 2:
      error("`" & identText(head) & "` takes exactly one argument; `" &
        stmt.repr.strip() & "` inside " & triggerDesc & " has " &
        $(stmt.len - 1) & ". " & m5ServiceNoSilentDropRule, stmt)
    let arg = stmt[1].copyNimTree()
    let kindLit =
      case headName
      of "sendsignal": ident("stakSendSignal")
      of "exec": ident("stakExec")
      else: ident("stakNotify")
    return quote do:
      addActiveServiceTriggerAction(`kindLit`, `arg`)
  of "hotreload", "restart":
    # ``restart backoff = exponential, maxRetries = 3`` / ``hotReload
    # otherwise sendSignal "SIGHUP"`` — the option text, verbatim and
    # whole.
    let optionLit = newLit(m5ServiceTriggerOptionText(stmt))
    let kindLit =
      if headName == "restart": ident("stakRestart")
      else: ident("stakHotReload")
    return quote do:
      addActiveServiceTriggerAction(`kindLit`, `optionLit`)
  else:
    m5ServiceUnknownAction(stmt, triggerDesc)

proc m5ServiceTriggerEmission(stmt: NimNode): NimNode =
  ## Lower one ``on <trigger>:`` block to its begin/try/finally triple.
  ## NEVER returns ``nil``: a head this milestone does not recognise is a
  ## macro ``error``, which is the whole point of the follow-up to
  ## Shared-Development-Services L1 — see ``m5ServiceUnknownTrigger``.
  ##
  ##   on rebuild api:        -> beginActiveServiceTrigger(stkRebuild, "api")
  ##   on change cfg:         -> beginActiveServiceTrigger(stkChangeOutput, cfg)
  ##   on change "/var/x":    -> beginActiveServiceTrigger(stkChangePath, "/var/x")
  ##   on start: / stop: / crash:
  ##
  ## ``on change <expr>`` splices ``<expr>`` VERBATIM into the
  ## ``BuildOutput`` overload, so a misspelled handle is a type error at
  ## the spliced call site rather than a watch that silently never fires.
  if stmt.kind notin {nnkCall, nnkCommand} or stmt.len < 3 or
      stmt[^1].kind != nnkStmtList:
    # ``on crash`` without the colon parses as a two-child Command. The
    # arity guard used to decline it silently, so a dropped colon turned a
    # crash policy into nothing at all.
    error("`on <trigger>:` needs a block body of actions; `" &
      stmt.repr.strip() & "` has none. Package-Model.md §\"Service " &
      "Lifecycle And Reactive Triggers\" spells it `on <trigger>:` " &
      "followed by an indented body drawn from " &
      m5ServiceRecognisedActions & ". " & m5ServiceNoSilentDropRule, stmt)
  let body = stmt[^1]
  let spec = stmt[1]
  let triggerDesc = "`on " & spec.repr.strip() & ":`"
  var beginCall: NimNode = nil
  if spec.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    case identText(spec).normalize
    of "start":
      beginCall = quote do:
        beginActiveServiceTrigger(stkStart)
    of "stop":
      beginCall = quote do:
        beginActiveServiceTrigger(stkStop)
    of "crash":
      beginCall = quote do:
        beginActiveServiceTrigger(stkCrash)
    else:
      m5ServiceUnknownTrigger(stmt, spec)
  elif spec.kind in {nnkCall, nnkCommand} and spec.len == 2 and
       spec[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    let subject = spec[1].copyNimTree()
    case identText(spec[0]).normalize
    of "rebuild":
      # The rebuilt artifact is named by IDENT, so the macro records the
      # text and never evaluates the node — the same rule the
      # ``executable <ident>`` setter follows.
      let subjectLit =
        if subject.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
          newLit(identText(subject))
        elif subject.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          newLit(subject.strVal)
        else:
          newLit(subject.repr)
      beginCall = quote do:
        beginActiveServiceTrigger(stkRebuild, `subjectLit`)
    of "change":
      if subject.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        beginCall = quote do:
          beginActiveServiceTrigger(stkChangePath, `subject`)
      else:
        beginCall = quote do:
          beginActiveServiceTrigger(stkChangeOutput, `subject`)
    else:
      m5ServiceUnknownTrigger(stmt, spec)
  else:
    m5ServiceUnknownTrigger(stmt, spec)
  # Everything between the trigger spec and the body. The two reads above
  # and below are ``stmt[1]`` and ``stmt[^1]``, so a third child was
  # DROPPED IN SILENCE — and the head is exactly where
  # ``Package-Model.md`` puts a modifier ("modifiers attached to an `on:`
  # block"): `on change cfg, debounce = "200ms":` compiled clean and
  # recorded nothing of the modifier. Same defect class as the in-body
  # case, one position over, so it is closed with it rather than left for
  # the first author who reads the spec's sentence the other way.
  for i in 2 ..< stmt.len - 1:
    let extra = stmt[i]
    let modifier = m5ServiceModifierName(extra)
    if modifier.len > 0:
      m5ServiceUnimplementedModifier(extra, modifier,
        "attached to the head of " & triggerDesc)
    error("`on <trigger>:` takes one trigger spec and a block body of " &
      "actions; `" & extra.repr.strip() & "` beside the head of " &
      triggerDesc & " is neither. Package-Model.md §\"Service Lifecycle " &
      "And Reactive Triggers\" specifies " & m5ServiceRecognisedTriggers &
      ", with a body drawn from " & m5ServiceRecognisedActions & ". " &
      m5ServiceNoSilentDropRule, m5ServiceStmtAnchor(extra))
  let actionBody = newStmtList()
  for inner in body:
    # ``nil`` only for a doc comment or a ``discard``; anything else that
    # is not an action has already been refused by name.
    let call = m5ServiceTriggerActionCall(inner, triggerDesc)
    if call != nil:
      actionBody.add(call)
  if actionBody.len == 0:
    actionBody.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
  result = quote do:
    block:
      `beginCall`
      try:
        `actionBody`
      finally:
        finishActiveServiceTrigger()

proc m5ServiceShortFormEmission(stmt: NimNode): NimNode =
  ## The short-form atoms of ``Package-Model.md`` §"Service Lifecycle And
  ## Reactive Triggers":
  ##
  ##   hotReload                    = on rebuild <own executable>: hotReload
  ##   restartOnCrash               = on crash: restart
  ##   reloadOnChange cfg, "SIGHUP" = on change cfg: sendSignal "SIGHUP"
  ##
  ## ``nil`` when the statement is not one of them.
  if stmt.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    case identText(stmt).normalize
    of "hotreload":
      # "``hotReload`` (without arguments) implicitly targets ``on
      # rebuild`` for the service's own executable", so the subject is
      # left empty rather than guessed: the service record already names
      # its executable.
      return quote do:
        block:
          beginActiveServiceTrigger(stkRebuild)
          try:
            addActiveServiceTriggerAction(stakHotReload)
          finally:
            finishActiveServiceTrigger()
    of "restartoncrash":
      return quote do:
        block:
          beginActiveServiceTrigger(stkCrash)
          try:
            addActiveServiceTriggerAction(stakRestart)
          finally:
            finishActiveServiceTrigger()
    else:
      return nil
  if stmt.kind notin {nnkCall, nnkCommand}:
    return nil
  # ``restartOnCrash()`` parses as a one-child Call, so the arity guard
  # has to precede every ``stmt[1]`` read below or the macro indexes past
  # the node and aborts the whole package expansion.
  if stmt.len < 2:
    return nil
  if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return nil
  case identText(stmt[0]).normalize
  of "restartoncrash":
    # ``restartOnCrash backoff = exponential, maxRetries = 3`` — option
    # text verbatim, for the same reason the ``restart`` action carries it
    # that way, and ALL of it, for the reason
    # ``m5ServiceTriggerOptionText`` gives.
    let optionLit = newLit(m5ServiceTriggerOptionText(stmt))
    return quote do:
      block:
        beginActiveServiceTrigger(stkCrash)
        try:
          addActiveServiceTriggerAction(stakRestart, `optionLit`)
        finally:
          finishActiveServiceTrigger()
  of "reloadonchange":
    if stmt.len != 3:
      # ``reloadOnChange cfg, "SIGHUP"`` — a build output (or path) plus a
      # signal name. A wrong arity used to fall through to the setter walk
      # and be preserved as raw body text, i.e. dropped.
      error("`reloadOnChange` takes a build output (or a path string) and " &
        "a signal name: `reloadOnChange <buildOutput>, \"<SIG...>\"`. `" &
        stmt.repr.strip() & "` has " & $(stmt.len - 1) & " argument(s). " &
        m5ServiceNoSilentDropRule, stmt)
    let subject = stmt[1].copyNimTree()
    let signal = stmt[2].copyNimTree()
    let beginCall =
      if subject.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        quote do:
          beginActiveServiceTrigger(stkChangePath, `subject`)
      else:
        quote do:
          beginActiveServiceTrigger(stkChangeOutput, `subject`)
    return quote do:
      block:
        `beginCall`
        try:
          addActiveServiceTriggerAction(stakSendSignal, `signal`)
        finally:
          finishActiveServiceTrigger()
  else:
    return nil

# ---------------------------------------------------------------------------
# Shared-Development-Services L4 — `identity` and `scope`.
#
# §4: "Two fields answer it, and they are **orthogonal**. Conflating them
# is the mistake this section is written to prevent." So they are two
# setters, parsed independently, each with its own refusal.
#
# The reading below is SHARED between the two walkers that need it:
# `m5ParseServiceBody` (which emits the body-setter calls) and
# `l3CollectExports` (which lifts the declared values into the interface
# artifact). A second, divergent reading is the drift `m5ServiceEmission`'s
# own doc comment warns about -- the lift would then be able to report an
# identity the lowering never recorded.
# ---------------------------------------------------------------------------

const
  l4RecognisedIdentityModes = "`identity derived` (the default) and " &
    "`identity stable \"<id>\"`"
  l4RecognisedScopes = "`scope project` (the default), " &
    "`scope workspace`, `scope user` and `scope system`"
  l6RecognisedCompatibility = "`compatibility <n>`, where `<n>` is an " &
    "integer literal greater than zero"
  l6CompatibilityNearMisses = ["compatibilitymajor", "major",
    "interfacemajor", "majorcompatibility", "compat", "compatmajor"]
    ## Spellings an author plausibly reaches for that `normalize` does
    ## NOT fold onto `compatibility`, so the head matcher would miss them
    ## and `m5ParseServiceBody`'s closing `else: discard` would drop them
    ## in silence. Every entry is already in normal form (lowercase, no
    ## underscores), which is what the matcher compares against -- the
    ## asymmetry L5's blocking defect was.
  l4IdentityDropRule = "A spelling this setter does not recognise is " &
    "REFUSED rather than dropped, and the reason is sharper here than " &
    "anywhere else in the service body: an `identity` that is accepted " &
    "and discarded leaves the service on the DEFAULT `derived` identity, " &
    "whose documented failure mode (Shared-Development-Services.md §4.2) " &
    "is that a developer's database silently forks on the next " &
    "configuration change -- \"the symptom is \"my test user is gone\" " &
    "rather than anything pointing at the cause\"."

type
  L4ServiceIdentityScope = object
    ## What a `service` body declared about its instance identity and
    ## scope. The `*Declared` flags separate "the author wrote the
    ## default" from "the author wrote nothing"; both resolve to the same
    ## value, and only the first makes a SECOND declaration a conflict.
    identityKind: ServiceIdentityKind
    stableId: string
    identityDeclared: bool
    identityAnchor: NimNode
    scope: ServiceScope
    scopeDeclared: bool
    scopeAnchor: NimNode
    # Shared-Development-Services L6 (§4.3): the MAJOR COMPATIBILITY
    # FIELD. It lives on this record, and is read by this record's
    # walker, for the reason the walker exists at all: a SECOND,
    # divergent reading of a `service` body would let the lift report a
    # value the refusals never validated. The type keeps its L4 name
    # because every call site is keyed on it; what it holds is "what the
    # body declared about its INSTANCE", and the major is that.
    compatibilityMajor: uint32
    compatibilityDeclared: bool
    compatibilityAnchor: NimNode
    # Shared-Development-Services D-SS11 (§4.6): the CONTRIBUTION POINTS
    # the body declares with `converge <point>`. Read HERE, by the
    # shared walker, for the same reason the major is: the lift and the
    # lowering must not have two readings of one declaration. The
    # lowering (`m5ParseServiceBody`) keeps its own `converge` arm
    # because it is the one that REFUSES a bad shape with a line the
    # author wrote; this arm only collects, and a shape that arm refuses
    # never reaches a lift that would otherwise have carried nothing.
    convergePoints: seq[string]
    # Shared-Development-Services D-SS11: whether the body declared an
    # `instance:` block, i.e. whether this service is a daemon-owned
    # SHARED instance at all. Collected here so the LIFT can decide
    # which services get a resolver declaration const; the lowering's
    # own `instance` arm (`l9ParseInstanceBlock`) keeps every refusal.
    instanceDeclared: bool

proc l4NewIdentityScope(): L4ServiceIdentityScope =
  L4ServiceIdentityScope(
    identityKind: sikDerived, stableId: "", identityDeclared: false,
    identityAnchor: nil, scope: sscProject, scopeDeclared: false,
    scopeAnchor: nil, compatibilityMajor: 0'u32,
    compatibilityDeclared: false, compatibilityAnchor: nil,
    convergePoints: @[], instanceDeclared: false)

proc l4ScopeFromName(name: string):
    tuple[found: bool; scope: ServiceScope] =
  ## Map a `scope` argument's ident text to its enum value. Derived from
  ## the enum rather than from a hand-kept list, so a fifth scope cannot
  ## be added to `ServiceScope` and silently stay unspellable.
  for candidate in ServiceScope:
    if name == ($candidate)[3 .. ^1].normalize:
      return (true, candidate)
  (false, sscProject)

proc l4ScopeSpellings(): string =
  ## Every scope word, derived from the enum. Used only in diagnostics.
  var parts: seq[string] = @[]
  for candidate in ServiceScope:
    parts.add("`" & ($candidate)[3 .. ^1].normalize & "`")
  parts.join(", ")

proc l4HeadWordOf(node: NimNode): string =
  ## The FIRST ident of a head expression — `identity` for `identity`,
  ## for `identity.stable` and for `identity.stable.v2` alike — or `""`
  ## when the node is not an ident-or-dot path.
  ##
  ## The dotted case is why this is a separate proc. It is the open
  ## escalation on
  ## `issues/2026-10-08-service-body-setters-are-silently-dropped.md`:
  ## `identity.stable "com.example.sso"` and `scope.workspace` compile
  ## with ZERO errors and leave the service on the DEFAULT identity,
  ## because the previous matcher covered ident, sym, accent-quoted,
  ## assignment and single-child-call shapes and not `nnkDotExpr`.
  case node.kind
  of nnkIdent, nnkSym, nnkAccQuoted: identText(node)
  of nnkDotExpr:
    if node.len == 2: l4HeadWordOf(node[0]) else: ""
  else: ""

proc l4IdentityScopeHeadName(stmt: NimNode): string =
  ## `"identity"` / `"scope"` / `"compatibility"` when `stmt` spells one
  ## of the three instance-declaration setters in a shape the setter walk
  ## would otherwise SKIP, else `""`.
  ##
  ## Which shapes those are is not hypothetical. `m5ParseServiceBody`
  ## continues past anything that is not an `nnkCall`/`nnkCommand` with
  ## at least two children, so a bare `identity` and an `identity =
  ## derived` both compiled clean and recorded nothing at all. This is
  ## the same family as the nineteen dropped constructs this campaign has
  ## found, caught before it shipped rather than after.
  ##
  ## L6 adds two shapes to the list, and one of them was already a filed
  ## defect:
  ##
  ##   * `compatibility` in any of those shapes, for the new setter; and
  ##   * a DOTTED head for ANY of the three — `identity.stable "x"`,
  ##     `scope.workspace`, `compatibility.major 2`. A dotted head is not
  ##     a statement at the wrong level, it is a *spelling* of the right
  ##     one, and the three setters §4 owns are the ones whose silent
  ##     loss costs a durable-state decision. The issue's GENERAL case
  ##     (`description.x "..."`, `totallyMadeUp = 3`) is untouched and
  ##     stays open: what a blanket refusing `else` arm should say about a
  ##     statement recognised at a DIFFERENT level is the judgement that
  ##     issue was filed to defer.
  var head: NimNode = nil
  if stmt.kind in {nnkIdent, nnkSym, nnkAccQuoted, nnkDotExpr}:
    head = stmt
  elif stmt.kind in {nnkAsgn, nnkExprEqExpr} and stmt.len > 0:
    head = stmt[0]
  elif stmt.kind in {nnkCall, nnkCommand} and stmt.len == 1:
    head = stmt[0]
  elif stmt.kind in {nnkCall, nnkCommand} and stmt.len >= 2 and
      stmt[0].kind == nnkDotExpr:
    # `identity.stable "x"` — a CALL with arguments, which the walk below
    # skips on `stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}`.
    head = stmt[0]
  if head == nil:
    return ""
  let name = l4HeadWordOf(head).normalize
  if name == "identity" or name == "scope" or name == "compatibility":
    return name
  ""

proc l6CompatibilityNearMiss(stmt: NimNode): string =
  ## The author's spelling when `stmt`'s head is a NEAR MISS for
  ## `compatibility`, else `""`.
  ##
  ## `compatibilityMajor` normalizes to `compatibilitymajor`, which the
  ## head matcher does not recognise, so the setter walk's closing
  ## `else: discard` would drop it with no diagnostic and the service
  ## would carry major 0 — the undeclared value — while its author
  ## believed otherwise. That is the silently-dropped family on a surface
  ## this milestone adds, which the campaign's standing hunt requires be
  ## probed rather than hoped about.
  var head: NimNode = nil
  if stmt.kind in {nnkIdent, nnkSym, nnkAccQuoted, nnkDotExpr}:
    head = stmt
  elif stmt.kind in {nnkAsgn, nnkExprEqExpr, nnkCall, nnkCommand} and
      stmt.len > 0:
    head = stmt[0]
  if head == nil:
    return ""
  let name = l4HeadWordOf(head).normalize
  if name.len == 0:
    return ""
  for candidate in l6CompatibilityNearMisses:
    if name == candidate:
      return l4HeadWordOf(head)
  ""

proc l4ParseIdentitySetter(stmt: NimNode;
                           acc: var L4ServiceIdentityScope) =
  ## Read one `identity <mode>` setter into `acc`, or refuse it.
  if acc.identityDeclared:
    error("`service` already declares its identity as `" &
      (if acc.identityKind == sikStable:
         "stable \"" & acc.stableId & "\""
       else: "derived") & "`; `" & stmt.repr.strip() & "` is a SECOND " &
      "`identity` declaration. Shared-Development-Services.md §4.2 gives " &
      "a service one identity -- \"There is one instance per `(id, " &
      "scope)`\" -- so two declarations have no meaning to pick between. " &
      "Last-wins is refused rather than implemented because it would " &
      "make the field that decides whether durable state survives a " &
      "redefinition depend on statement order. Delete one.",
      m5ServiceStmtAnchor(stmt))
  if stmt.len != 2:
    error("`identity` takes exactly one mode; `" & stmt.repr.strip() &
      "` has " & $(stmt.len - 1) & " argument(s). " &
      "Shared-Development-Services.md §4.2 specifies " &
      l4RecognisedIdentityModes & ". " & l4IdentityDropRule, stmt)
  let arg = stmt[1]
  if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("`identity` takes a MODE, not a string; `" &
      stmt.repr.strip() & "` quotes its argument. If " &
      escForCode(arg.strVal) & " is the IDENTIFIER, write `identity " &
      "stable " & escForCode(arg.strVal) & "`. If it is the MODE, " &
      "unquote it: Shared-Development-Services.md §4.2 specifies " &
      l4RecognisedIdentityModes & ".", stmt)
  if arg.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    case identText(arg).normalize
    of "derived":
      acc.identityKind = sikDerived
      acc.stableId = ""
      acc.identityDeclared = true
      acc.identityAnchor = stmt
      return
    of "stable":
      error("`identity stable` needs the identifier: `identity stable " &
        "\"<id>\"`. Shared-Development-Services.md §4.2: \"The author " &
        "assigns a stable identifier, independent of the build. There is " &
        "one instance per `(id, scope)`, and it survives redefinition.\" " &
        "Without the id there is no key to share an instance under, and " &
        "the service would fall back to `derived` -- the mode `stable` " &
        "exists to avoid. The id is a name, not a secret: a " &
        "reverse-DNS-style string or a GUID.", stmt)
    else:
      error("`service` does not recognise the identity mode `" &
        arg.repr.strip() & "`. Shared-Development-Services.md §4.2 " &
        "specifies " & l4RecognisedIdentityModes & ", and the rule for " &
        "choosing: \"a service declares `stable` if and only if it owns " &
        "state that must outlive a change to its own definition. " &
        "Everything else takes `derived`.\" " & l4IdentityDropRule, stmt)
  if arg.kind notin {nnkCall, nnkCommand} or arg.len != 2 or
      arg[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    error("`service` does not recognise the identity mode `" &
      arg.repr.strip() & "`. Shared-Development-Services.md §4.2 " &
      "specifies " & l4RecognisedIdentityModes & ". " &
      l4IdentityDropRule, stmt)
  let mode = identText(arg[0]).normalize
  let idNode = arg[1]
  if mode == "derived":
    error("`identity derived` takes no identifier; `" &
      stmt.repr.strip() & "` supplies one. " &
      "Shared-Development-Services.md §4.2: a `derived` identity \"is a " &
      "digest of the service's materialised definition: the executable, " &
      "the rendered configuration outputs, the arguments\" -- there is " &
      "nothing for an author-supplied id to mean, and recording one the " &
      "resolver ignores would read as support for it. Write `identity " &
      "stable " & idNode.repr.strip() & "` to declare that identifier, " &
      "or `identity derived` to keep the digest.", stmt)
  if mode != "stable":
    error("`service` does not recognise the identity mode `" &
      arg.repr.strip() & "`. Shared-Development-Services.md §4.2 " &
      "specifies " & l4RecognisedIdentityModes & ". " &
      l4IdentityDropRule, stmt)
  if idNode.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("`identity stable` needs a STRING LITERAL identifier; `" &
      idNode.repr.strip() & "` is not one. " &
      "Shared-Development-Services.md §4.2: the identifier \"is not " &
      "derived from a path, because a path is what distinguishes the " &
      "worktrees that are supposed to share the instance\", and it is " &
      "\"independent of the build\". An expression could be neither -- " &
      "`getCurrentDir()` and a build output both type-check -- and the " &
      "failure would be invisible: the service would simply not be the " &
      "same instance in the next worktree. A literal cannot be either, " &
      "so the restriction is the guarantee. Write `identity stable " &
      "\"<id>\"`.", stmt)
  if idNode.strVal.strip().len == 0:
    error("`identity stable \"\"` declares an EMPTY identifier. " &
      "Shared-Development-Services.md §4.2: the identifier \"is chosen " &
      "to be globally unique by construction -- a reverse-DNS-style " &
      "string, or a GUID\". The empty string is the opposite: every " &
      "service that wrote it would share one instance and one state " &
      "directory.", stmt)
  acc.identityKind = sikStable
  acc.stableId = idNode.strVal
  acc.identityDeclared = true
  acc.identityAnchor = stmt

proc l4ParseScopeSetter(stmt: NimNode;
                        acc: var L4ServiceIdentityScope) =
  ## Read one `scope <value>` setter into `acc`, or refuse it.
  if acc.scopeDeclared:
    error("`service` already declares its scope as `" &
      ($acc.scope)[3 .. ^1].normalize & "`; `" & stmt.repr.strip() &
      "` is a SECOND `scope` declaration. Shared-Development-" &
      "Services.md §4.1 gives a service one scope -- the table reads " &
      "\"One instance per\" -- so two have nothing to pick between. " &
      "Delete one.", m5ServiceStmtAnchor(stmt))
  if stmt.len != 2:
    error("`scope` takes exactly one value; `" & stmt.repr.strip() &
      "` has " & $(stmt.len - 1) & " argument(s). " &
      "Shared-Development-Services.md §4.1 specifies " &
      l4RecognisedScopes & ". " & l4IdentityDropRule, stmt)
  let arg = stmt[1]
  if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("`scope` takes one of the words " & l4ScopeSpellings() &
      ", not a string; `" & stmt.repr.strip() & "` quotes it. Write " &
      "`scope " & arg.strVal & "`.", stmt)
  if arg.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    error("`service` does not recognise the scope `" &
      arg.repr.strip() & "`. Shared-Development-Services.md §4.1 " &
      "specifies " & l4RecognisedScopes & ". " & l4IdentityDropRule,
      stmt)
  let resolved = l4ScopeFromName(identText(arg).normalize)
  if not resolved.found:
    error("`service` does not recognise the scope `" &
      arg.repr.strip() & "`. Shared-Development-Services.md §4.1 " &
      "specifies " & l4RecognisedScopes & " -- the words are " &
      l4ScopeSpellings() & ". `project` and `workspace` are this " &
      "campaign's two narrower additions; `user` and `system` are the " &
      "lease scopes Ephemeral-State-Leases.md §4.1 already resolved, " &
      "routing to the user and system daemon respectively. " &
      l4IdentityDropRule, stmt)
  acc.scope = resolved.scope
  acc.scopeDeclared = true
  acc.scopeAnchor = stmt

proc l6ParseCompatibilitySetter(stmt: NimNode;
                                acc: var L4ServiceIdentityScope) =
  ## Read one `compatibility <n>` setter into `acc`, or refuse it.
  ##
  ## §4.3's third outcome is the only one not decided on the
  ## fingerprint, and the only one that REFUSES. So every way of getting
  ## the field wrong is refused here rather than resolved to a default:
  ## a service whose major silently read 0 when its author wrote
  ## something else would attach to an instance of a different generation
  ## and be handed a handle whose members it cannot use, which is the
  ## damage §4.3's bottom row exists to prevent.
  if acc.compatibilityDeclared:
    error("`service` already declares its major compatibility as `" &
      $acc.compatibilityMajor & "`; `" & stmt.repr.strip() & "` is a " &
      "SECOND `compatibility` declaration. Shared-Development-" &
      "Services.md §4.3 compares ONE major per service -- \"major " &
      "compatibility field differs | Refuse\" -- so two have nothing to " &
      "pick between, and last-wins would make the field that decides a " &
      "REFUSAL depend on statement order. Delete one.",
      m5ServiceStmtAnchor(stmt))
  if stmt.len != 2:
    error("`compatibility` takes exactly one major; `" &
      stmt.repr.strip() & "` has " & $(stmt.len - 1) & " argument(s). " &
      "Shared-Development-Services.md §4.3 compares a single major " &
      "compatibility field; the spelling is " & l6RecognisedCompatibility &
      ". " & l4IdentityDropRule, stmt)
  let arg = stmt[1]
  if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("`compatibility` takes a NUMBER, not a string; `" &
      stmt.repr.strip() & "` quotes it. The major is compared for " &
      "EQUALITY against a running instance's (§4.3), and comparing it " &
      "as text would make `\"2\"` and `\" 2\"` different generations of " &
      "the same service. Write `compatibility " & arg.strVal & "`.", stmt)
  # THE LITERAL-KIND SET IS A RANGE AND NOT `nnkIntLit`, AND THAT IS A
  # DEFECT THIS MILESTONE'S OWN PROBE SWEEP FOUND BEFORE IT SHIPPED.
  # Nim's parser widens an integer literal that does not fit `int32` to
  # `nnkInt64Lit`: `compatibility 4294967295` -- a legal major, since the
  # field is a u32 -- arrived here as `nnkInt64Lit` and was refused with
  # "needs an INTEGER LITERAL; `4294967295'i64` is not one", a message
  # that contradicts itself, while the does-not-fit refusal below was
  # UNREACHABLE. Measured with `nim check` over 36 generated spellings.
  # The unsigned kinds are accepted too, because `compatibility 2'u32`
  # spells the field's own type and refusing it would be arbitrary.
  if arg.kind notin {nnkIntLit .. nnkInt64Lit, nnkUIntLit .. nnkUInt64Lit}:
    error("`compatibility` needs an INTEGER LITERAL; `" &
      arg.repr.strip() & "` is not one. " & l6RecognisedCompatibility &
      " is the whole of the surface, and the restriction is the " &
      "guarantee: §4.3's refusal is the one outcome that stops a build, " &
      "and a major computed from an expression -- a const, a `when`, a " &
      "build output -- could differ between the consumer's compilation " &
      "and the producer's without either author seeing why the attach " &
      "was refused. A literal cannot.", stmt)
  # A value above `high(int64)` arrives with a NEGATIVE `intVal`, so the
  # fit check has to come FIRST or such a literal would be reported as
  # "not a whole number greater than zero" -- true of the bit pattern and
  # false of what the author wrote.
  if arg.intVal > int64(high(uint32)) or
      (arg.kind in {nnkUIntLit .. nnkUInt64Lit} and arg.intVal < 0):
    error("`compatibility " & arg.repr.strip() & "` does not fit the " &
      "field; the major is a 32-bit unsigned number on the wire " &
      "(`ServiceInterfaceDef.compatibilityMajor` and the v23 interface " &
      "envelope), and a value that wrapped would compare EQUAL to a " &
      "different generation -- which is §4.3's refusal failing to fire. " &
      "The largest major is " & $high(uint32) & ".", stmt)
  if arg.intVal <= 0:
    error("`compatibility " & $arg.intVal & "` declares " &
      (if arg.intVal == 0: "the UNDECLARED major"
       else: "a major that is not a whole number greater than zero") &
      ". 0 is what a service that wrote NO `compatibility` setter " &
      "carries, and what every interface artifact written before this " &
      "field existed decodes to -- so `compatibility 0` is " &
      "indistinguishable from not declaring it, and a setter whose " &
      "value cannot be observed is the silent drop this surface is " &
      "written to avoid. Write `compatibility 1` for the first " &
      "generation, or delete the line.", stmt)
  acc.compatibilityMajor = uint32(arg.intVal)
  acc.compatibilityDeclared = true
  acc.compatibilityAnchor = stmt

proc l4ServiceIdentityScope(body: NimNode): L4ServiceIdentityScope =
  ## THE reading of a `service` body's `identity`, `scope` and
  ## `compatibility` setters. Both walkers call this one proc; see the
  ## section comment above.
  result = l4NewIdentityScope()
  if body == nil or body.kind != nnkStmtList:
    return
  for stmt in body:
    let nearMiss = l6CompatibilityNearMiss(stmt)
    if nearMiss.len > 0:
      error("`service` does not recognise the setter `" & nearMiss &
        "`; did you mean `compatibility`? " & l6RecognisedCompatibility &
        " is the spelling Shared-Development-Services.md §4.3's major " &
        "compatibility field is declared with. This is refused rather " &
        "than skipped because the setter walk's closing `else: discard` " &
        "would drop it in silence and leave the service on the " &
        "UNDECLARED major 0 -- so a service the author believed was " &
        "generation 2 would compare equal to every service that " &
        "declared nothing.", m5ServiceStmtAnchor(stmt))
    let dropped = l4IdentityScopeHeadName(stmt)
    if dropped.len > 0:
      error("`" & stmt.repr.strip() & "` is not a shape `" & dropped &
        "` is written in, and this walker would otherwise SKIP it " &
        "entirely -- no diagnostic, no record, the service left on the " &
        "default. Shared-Development-Services.md §4 spells the three " &
        "setters as commands: " & l4RecognisedIdentityModes & ", " &
        l4RecognisedScopes & ", and " & l6RecognisedCompatibility & ". " &
        l4IdentityDropRule,
        m5ServiceStmtAnchor(stmt))
    if stmt.kind notin {nnkCall, nnkCommand}:
      continue
    if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      continue
    case identText(stmt[0]).normalize
    of "identity": l4ParseIdentitySetter(stmt, result)
    of "scope": l4ParseScopeSetter(stmt, result)
    of "compatibility": l6ParseCompatibilitySetter(stmt, result)
    of "instance":
      # COLLECT ONLY -- presence, nothing else. `l9ParseInstanceBlock`
      # on the lowering path reads and refuses the block's contents.
      result.instanceDeclared = true
    of "converge":
      # COLLECT ONLY -- no refusal here. `m5ParseServiceBody`'s own
      # `converge` arm refuses every non-identifier argument by name, it
      # runs on the SAME body in the same macro expansion, and a second
      # `error` here would report one authoring mistake twice on two
      # generated lines. A shape it refuses aborts the compilation, so
      # this walker never lifts a point the lowering rejected.
      for i in 1 ..< stmt.len:
        if stmt[i].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
          let point = identText(stmt[i])
          if not result.convergePoints.contains(point):
            result.convergePoints.add(point)
    else: discard

# ---------------------------------------------------------------------------
# Shared-Development-Services L9 — the SUPERVISION setters of a `service`
# body: `readiness`, `workingDirectory`, `stateDirectory` and the
# `instance:` block.
#
# WHY THEY EXIST AND WHAT THEY REPLACE. L8's review measured the
# remainder it left: "the `instance` block and `readiness` still require
# a `servicePlaceholder`, so `declared once` is only PARTLY unblocked."
# A recipe that wanted a SHARED instance therefore wrote the service
# TWICE -- a typed `service` block for the identity, the scope and the
# command, and a `servicePlaceholder` whose opaque JSON carried the
# probe, the working directory, the state directories and the `instance`
# block -- joined by nothing but the service NAME.
# `infra/repro.nim` is the production instance of exactly that shape, and
# it is what L9's first gate clause ("declared ONCE") is measured on.
#
# EVERY NEAR MISS IS REFUSED BY NAME. The setter walk below ends in
# `else: discard`, so an unrecognised head is dropped in silence: a
# recipe would compile, the service would carry no readiness, and a
# consumer that `dependsOn` it would start against an instance that is
# listening but not seeded. That is the campaign's dominant finding in
# its worst form -- not a missing value but a race -- so the walker
# refuses:
#
#   * a bare `readiness` / `instance` / `workingDirectory` /
#     `stateDirectory` ident, which the Call/Command filter drops;
#   * a DOTTED head (`cfg.readiness fileExists(...)`), which the
#     ident-kind filter drops;
#   * a readiness kind that is not one of the three the SUPERVISOR
#     implements;
#   * `environment`, `identity`, `scope` and `ttlSeconds` inside the
#     `instance:` block, each naming where it does belong;
#   * a second occurrence of any of them.
# ---------------------------------------------------------------------------

const
  l9RecognisedReadiness = "`readiness none`, " &
    "`readiness fileExists(\"<path>\")`, " &
    "`readiness httpGet(port = <n>)` and " &
    "`readiness httpGet(url = \"<base>\")`"
  l9RecognisedLease = "`lease keep` (the default -- D-SS5), " &
    "`lease immediate` and `lease delayed(<seconds>)`"
  l9ReadinessKinds = ["none", "fileexists", "httpget"]
  l9SupervisionHeads = ["readiness", "workingdirectory", "statedirectory",
    "instance"]
  l9SupervisionSurface = "`readiness <probe>`, " &
    "`workingDirectory \"<dir>\"`, `stateDirectory \"<dir>\"` and " &
    "`instance:`"
  l9NoSilentDropRule = "Refused rather than dropped: this walker's " &
    "closing `else: discard` would leave the service with no readiness " &
    "probe at all, and a service with no probe is reported READY as " &
    "soon as it is spawned -- so a consumer that `dependsOn` it would " &
    "start against an instance that is listening and not yet seeded. " &
    "That failure is a race rather than a missing value, which makes " &
    "it the worst of the shapes this campaign hunts."

type
  L9ServiceSupervision = object
    ## What a `service` body declared about its SUPERVISION, in a shape
    ## the emitter can splice. Expressions are kept as nodes and never
    ## evaluated here, exactly as `m5ServiceStringLitArg` does: the
    ## macro relocates, the compiler type-checks.
    readinessDeclared: bool
    readinessKind: string
      ## "none" | "fileExists" | "httpGet". The AUTHOR'S spelling of the
      ## recognised kind, not the normalised one, because it appears in
      ## the lowered record and in `repro dev-env --json`.
    readinessPathExpr: NimNode
    readinessUrlExpr: NimNode
    readinessPortExpr: NimNode
    readinessTimeoutExpr: NimNode
    workingDirectoryExpr: NimNode
    stateDirectoryExprs: seq[NimNode]
    instanceDeclared: bool
    instanceLeaseExpr: NimNode
      ## An `int64` expression. Nil when the block declared no `lease`,
      ## which is `keep`.

proc l9NewSupervision(): L9ServiceSupervision =
  L9ServiceSupervision(stateDirectoryExprs: @[])

proc l9DottedSetterHead(stmt: NimNode): string =
  ## The supervision setter name a DOTTED head spells, or "".
  ##
  ## `cfg.readiness fileExists(...)` parses as
  ## `Command(DotExpr(cfg, readiness), Call(...))`, and the setter
  ## walk's `if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
  ## continue` drops it with no diagnostic. The shape is plausible
  ## enough to be written -- the `args cfg.path` setter beside it takes
  ## exactly that kind of expression -- and the consequence is the
  ## silent no-probe race above.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return ""
  if stmt.len < 1 or stmt[0].kind != nnkDotExpr:
    return ""
  var node = stmt[0]
  while node.kind == nnkDotExpr and node.len == 2:
    node = node[1]
  if node.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return ""
  let word = identText(node).normalize
  if word in l9SupervisionHeads:
    return word
  ""

proc l9BareSetterHead(stmt: NimNode): string =
  ## The supervision setter name a BARE IDENT spells, or "".
  ##
  ## `readiness` on its own, or `instance` with no body, reaches the
  ## setter walk as an `nnkIdent`, is not one of the short-form reactive
  ## atoms, and is then dropped by `if stmt.kind notin {nnkCall,
  ## nnkCommand}: continue`.
  if stmt.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return ""
  let word = identText(stmt).normalize
  if word in l9SupervisionHeads:
    return word
  ""

proc l9EmptyCallSetterHead(stmt: NimNode): string =
  ## The supervision setter name an ARGUMENT-LESS CALL spells, or "".
  ##
  ## `readiness()` / `instance()` / `workingDirectory()` /
  ## `stateDirectory()` reach the setter walk as an `nnkCall` of length
  ## ONE, so they survive the statement-kind filter and are then dropped
  ## by `if stmt.len < 2: continue` -- the ARITY filter, which is the
  ## third of this walker's three `continue`s and was the one left
  ## uncovered when the other two were closed.
  ##
  ## This matches ONLY the four supervision names, deliberately. A
  ## one-child `nnkCall` is a legal spelling elsewhere in this DSL --
  ## `m5ServiceShortFormEmission` records that `restartOnCrash()` parses
  ## exactly this way -- so refusing the SHAPE would reject working
  ## recipes. It is the shape plus one of these four names that can only
  ## be a mistake, because none of the four has a zero-argument meaning.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return ""
  if stmt.len != 1:
    return ""
  if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return ""
  let word = identText(stmt[0]).normalize
  if word in l9SupervisionHeads:
    return word
  ""

proc l9RefuseSupervisionNearMisses(stmt: NimNode) =
  ## The three drop shapes, refused before the setter walk reads a head:
  ## a bare ident, a dotted head, and an argument-less call. One per
  ## `continue` in the walk.
  let empty = l9EmptyCallSetterHead(stmt)
  if empty.len > 0:
    error("`" & stmt.repr.strip() & "` calls the setter `" & empty &
      "` with NO ARGUMENTS, and the setter walk drops a statement with " &
      "fewer than two children before it ever reads the head -- so " &
      "this would be skipped entirely. None of the supervision " &
      "setters has a zero-argument meaning: " & l9SupervisionSurface &
      ". (An EMPTY `instance:` block is spelled `instance:` with a " &
      "`discard` body, not `instance()`.) " & l9NoSilentDropRule,
      m5ServiceStmtAnchor(stmt))
  let bare = l9BareSetterHead(stmt)
  if bare.len > 0:
    error("`" & stmt.repr.strip() & "` is a bare identifier, and `" &
      bare & "` is a SETTER that takes an argument. The setter walk " &
      "would skip it entirely. The supervision setters are " &
      l9SupervisionSurface & "; the readiness probes are " &
      l9RecognisedReadiness & ". " & l9NoSilentDropRule,
      m5ServiceStmtAnchor(stmt))
  let dotted = l9DottedSetterHead(stmt)
  if dotted.len > 0:
    error("`" & stmt.repr.strip() & "` writes the setter `" & dotted &
      "` behind a dotted head, and the setter walk accepts only a bare " &
      "setter name -- so it would be skipped entirely. Write `" &
      dotted & " ...` at the top level of the `service` body. " &
      l9NoSilentDropRule,
      m5ServiceStmtAnchor(stmt))

proc l9ParseReadinessSetter(stmt: NimNode;
                            result: var L9ServiceSupervision) =
  ## `readiness none` | `readiness fileExists(...)` |
  ## `readiness httpGet(...)`.
  if result.readinessDeclared:
    error("`readiness` is declared twice in one `service` body. The " &
      "first declaration WINS at runtime (the body-setter is " &
      "first-wins, like `identity`), so a second one is dead text -- " &
      "and which probe a dependent waits on must not depend on " &
      "statement order.", m5ServiceStmtAnchor(stmt))
  if stmt.len != 2:
    error("`readiness` takes exactly one probe. " &
      l9RecognisedReadiness & ", each optionally with " &
      "`timeoutMs = <n>` inside the parentheses.",
      m5ServiceStmtAnchor(stmt))
  let probe = stmt[1]
  if probe.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    let word = identText(probe).normalize
    if word == "none":
      result.readinessDeclared = true
      result.readinessKind = "none"
      return
    if word in l9ReadinessKinds:
      error("`readiness " & identText(probe) & "` names a probe KIND " &
        "and gives it nothing to probe. Write it as a call: " &
        l9RecognisedReadiness & ".", m5ServiceStmtAnchor(stmt))
    error("`readiness " & identText(probe) & "` is not a probe this " &
      "build knows. The supervisor implements exactly three kinds (" &
      "`readinessOk` in `repro_cli_support/dev_session.nim` switches " &
      "on `none`, `fileExists` and `httpGet`), and anything else is " &
      "NEVER READY -- so a fourth word would reach the artifact and " &
      "hang the session until its timeout with nothing said. " &
      l9RecognisedReadiness & ".", m5ServiceStmtAnchor(stmt))
  if probe.kind notin {nnkCall, nnkCommand}:
    error("`readiness` takes a probe written as `none` or as a call; `" &
      probe.repr.strip() & "` is a " & $probe.kind & ". " &
      l9RecognisedReadiness & ".", m5ServiceStmtAnchor(stmt))
  if probe[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    error("`readiness " & probe.repr.strip() & "`: the probe's kind " &
      "must be a bare name. " & l9RecognisedReadiness & ".",
      m5ServiceStmtAnchor(stmt))
  let kindWord = identText(probe[0]).normalize
  if kindWord notin l9ReadinessKinds:
    error("`readiness " & identText(probe[0]) & "(...)` is not a probe " &
      "this build knows; the supervisor implements `none`, " &
      "`fileExists` and `httpGet` and reports anything else as never " &
      "ready. " & l9RecognisedReadiness & ".",
      m5ServiceStmtAnchor(stmt))
  if kindWord == "none":
    error("`readiness none(...)` takes no arguments -- it says there " &
      "is nothing to wait for. Write `readiness none`.",
      m5ServiceStmtAnchor(stmt))
  var positional: seq[NimNode] = @[]
  for i in 1 ..< probe.len:
    let arg = probe[i]
    if arg.kind in {nnkExprEqExpr, nnkAsgn}:
      if arg.len != 2 or arg[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
        error("`readiness " & identText(probe[0]) & "`: `" &
          arg.repr.strip() & "` is not a named argument this probe " &
          "accepts.", m5ServiceStmtAnchor(arg))
      case identText(arg[0]).normalize
      of "timeoutms":
        if result.readinessTimeoutExpr != nil:
          error("`readiness " & identText(probe[0]) &
            "`: `timeoutMs` is given twice.", m5ServiceStmtAnchor(arg))
        result.readinessTimeoutExpr = arg[1].copyNimTree()
      of "port":
        if kindWord != "httpget":
          error("`readiness fileExists`: `port` belongs to " &
            "`httpGet`, not to a file probe. A file probe waits for a " &
            "PATH to exist, which is `readiness " &
            "fileExists(\"<path>\")`.", m5ServiceStmtAnchor(arg))
        if result.readinessPortExpr != nil:
          error("`readiness httpGet`: `port` is given twice.",
            m5ServiceStmtAnchor(arg))
        result.readinessPortExpr = arg[1].copyNimTree()
      of "url":
        if kindWord != "httpget":
          error("`readiness fileExists`: `url` belongs to `httpGet`, " &
            "not to a file probe.", m5ServiceStmtAnchor(arg))
        if result.readinessUrlExpr != nil:
          error("`readiness httpGet`: `url` is given twice.",
            m5ServiceStmtAnchor(arg))
        result.readinessUrlExpr = arg[1].copyNimTree()
      of "path":
        if kindWord == "httpget":
          error("`readiness httpGet`: `path` is NOT accepted, and that " &
            "is a limit of the supervisor rather than of this macro. " &
            "`readinessOk` probes `httpRequest(spec.readinessUrl, " &
            "\"/\")` -- the request path is always `/` -- so a `path` " &
            "here would be recorded, carried to the artifact and then " &
            "read by nothing. Front the service with an endpoint at " &
            "`/`, or wait on a file the service writes last " &
            "(`readiness fileExists(\"<path>\")`), which is what " &
            "\"seeded\" rather than \"listening\" usually means anyway.",
            m5ServiceStmtAnchor(arg))
        if result.readinessPathExpr != nil:
          error("`readiness fileExists`: the path is given twice.",
            m5ServiceStmtAnchor(arg))
        result.readinessPathExpr = arg[1].copyNimTree()
      else:
        error("`readiness " & identText(probe[0]) & "`: `" &
          identText(arg[0]) & "` is not an argument this probe " &
          "accepts. `fileExists` takes a path and `timeoutMs`; " &
          "`httpGet` takes `port` or `url` and `timeoutMs`. An " &
          "unrecognised name is refused rather than ignored: an " &
          "argument that parses and is read by nothing is " &
          "indistinguishable from support for it.",
          m5ServiceStmtAnchor(arg))
    else:
      positional.add(arg.copyNimTree())
  case kindWord
  of "fileexists":
    if positional.len > 1:
      error("`readiness fileExists` takes ONE path. The timeout is a " &
        "NAMED argument -- `readiness fileExists(\"<path>\", " &
        "timeoutMs = <n>)` -- so a second positional argument would " &
        "be read by nothing.", m5ServiceStmtAnchor(stmt))
    if positional.len == 1:
      if result.readinessPathExpr != nil:
        error("`readiness fileExists`: the path is given both " &
          "positionally and as `path =`.", m5ServiceStmtAnchor(stmt))
      result.readinessPathExpr = positional[0]
    if result.readinessPathExpr == nil:
      error("`readiness fileExists()` declares no path, so there is " &
        "nothing to wait for and the probe can never go ready. Write " &
        "`readiness fileExists(\"<path>\")`.",
        m5ServiceStmtAnchor(stmt))
  of "httpget":
    if positional.len > 0:
      error("`readiness httpGet` takes NAMED arguments only -- " &
        "`port = <n>` or `url = \"<base>\"`, plus `timeoutMs = <n>`. " &
        "A positional argument reads as the request path, which the " &
        "supervisor does not honour (it probes `/`), so it would be " &
        "accepted and then not there.", m5ServiceStmtAnchor(stmt))
    if result.readinessPortExpr != nil and result.readinessUrlExpr != nil:
      error("`readiness httpGet` is given both `port` and `url`, which " &
        "are two answers to the same question. `port = <n>` IS " &
        "`url = \"http://127.0.0.1:<n>\"`; write one of them.",
        m5ServiceStmtAnchor(stmt))
    if result.readinessPortExpr == nil and result.readinessUrlExpr == nil:
      error("`readiness httpGet()` names nothing to probe. Write " &
        "`readiness httpGet(port = <n>)` for a loopback listener, or " &
        "`readiness httpGet(url = \"<base>\")` for anything else.",
        m5ServiceStmtAnchor(stmt))
  else: discard
  result.readinessDeclared = true
  result.readinessKind = (if kindWord == "fileexists": "fileExists"
                          else: "httpGet")

proc l9ParseInstanceBlock(stmt: NimNode;
                          result: var L9ServiceSupervision) =
  ## `instance:` -- "this service is a SHARED instance the daemon owns".
  if result.instanceDeclared:
    error("`instance:` is declared twice in one `service` body. The " &
      "first declaration wins at runtime, so the second is dead text " &
      "-- and D-SS5's lease is what decides whether a developer's " &
      "identity database is reaped.", m5ServiceStmtAnchor(stmt))
  if stmt.len != 2 or stmt[^1].kind != nnkStmtList:
    error("`instance` is a BLOCK, not a value: write `instance:` with " &
      "its settings indented beneath it. The settings are " &
      l9RecognisedLease & "; an empty block is legal and means " &
      "\"shared, with the default `keep` lease\". A non-block " &
      "`instance` is refused rather than ignored, because ignoring it " &
      "would leave the service SESSION-OWNED while its author " &
      "believed it was shared -- the same refusal " &
      "`parseSharedServiceInstance` raises for a non-object `instance` " &
      "key in a placeholder's JSON.", m5ServiceStmtAnchor(stmt))
  result.instanceDeclared = true
  for entry in stmt[^1]:
    let bareWord =
      if entry.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
        identText(entry).normalize
      else:
        ""
    if bareWord.len > 0:
      error("`instance:` does not recognise the bare word `" &
        identText(entry) & "`. Its settings are " & l9RecognisedLease &
        ".", m5ServiceStmtAnchor(entry))
    # A BARE `discard` is the empty block, and it is accepted for a
    # language reason rather than a taste one: Nim has no syntax for an
    # empty indented body, so `instance:` + `discard` is the ONLY way an
    # author can write "shared, with the default `keep` lease". Refusing
    # it would make the legal declaration unspellable. `discard <expr>`
    # is NOT accepted -- it carries something, and what it carries would
    # be read by nothing.
    if entry.kind == nnkDiscardStmt and
        (entry.len == 0 or entry[0].kind == nnkEmpty):
      continue
    if entry.kind notin {nnkCall, nnkCommand, nnkAsgn, nnkExprEqExpr}:
      error("`instance:` does not recognise `" & entry.repr.strip() &
        "` (a " & $entry.kind & "). Its settings are " &
        l9RecognisedLease & ". A bare `discard` is accepted, as the " &
        "only way Nim lets an author write an empty block.",
        m5ServiceStmtAnchor(entry))
    let head = (if entry.kind in {nnkAsgn, nnkExprEqExpr}: entry[0]
                else: entry[0])
    if head.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      error("`instance:` setting names must be bare words; `" &
        entry.repr.strip() & "` is not. Its settings are " &
        l9RecognisedLease & ".", m5ServiceStmtAnchor(entry))
    case identText(head).normalize
    of "environment":
      error("`instance:` does not take an `environment`, and the " &
        "omission is deliberate. The selected environment is a " &
        "PER-INVOCATION tracked input (`REPRO_ENVIRONMENT` -> " &
        "`canonicalEnvironmentSelection`, " &
        "Shared-Development-Services.md §6.4) and it is already part " &
        "of the instance key (§6.5), so this lane DERIVES it from the " &
        "selection. A name written here would be a second answer to " &
        "\"which environment is this instance keyed under\", and the " &
        "two could disagree with nothing said -- a developer running " &
        "`REPRO_ENVIRONMENT=production` would attach to the instance " &
        "the recipe called `dev`.", m5ServiceStmtAnchor(entry))
    of "identity":
      error("`instance:` does not take an `identity`. An instance's " &
        "identity is a setter of the `service` block itself -- " &
        "`identity stable \"<id>\"` (§4.2) -- one level out from here. " &
        "Declaring it in both places would give one service two " &
        "answers to \"are these the same instance?\".",
        m5ServiceStmtAnchor(entry))
    of "scope":
      error("`instance:` does not take a `scope`. Like the identity, " &
        "the scope is a setter of the `service` block itself (`scope " &
        "project|workspace|user|system`, §4.1), one level out from " &
        "here.", m5ServiceStmtAnchor(entry))
    of "ttlseconds":
      error("`instance:` does not take a bare `ttlSeconds`; the ttl " &
        "belongs to the lease that reads it -- `lease " &
        "delayed(<seconds>)`. Beside `lease keep` or `lease " &
        "immediate` a ttl is read by nothing, which is the same " &
        "refusal `parseSharedServiceInstance` raises for the JSON " &
        "spelling.", m5ServiceStmtAnchor(entry))
    of "lease":
      if result.instanceLeaseExpr != nil:
        error("`instance:` declares `lease` twice. " &
          l9RecognisedLease & ".", m5ServiceStmtAnchor(entry))
      if entry.kind in {nnkAsgn, nnkExprEqExpr}:
        error("`lease` is written as a command, not an assignment: " &
          l9RecognisedLease & ".", m5ServiceStmtAnchor(entry))
      if entry.len != 2:
        error("`lease` takes exactly one word. " & l9RecognisedLease &
          ".", m5ServiceStmtAnchor(entry))
      let value = entry[1]
      if value.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
        case identText(value).normalize
        of "keep":
          # THE CONSTANT, not a literal `-1`. The implicit default
          # twenty lines down already lowers through
          # `SharedServiceInstanceKeepTtlSeconds`, so writing the
          # literal here meant one newly-written block reached the same
          # number by two routes -- which is exactly the drift the
          # constant was introduced to end.
          result.instanceLeaseExpr = newLit(SharedServiceInstanceKeepTtlSeconds)
        of "immediate":
          result.instanceLeaseExpr = newLit(0'i64)
        of "delayed":
          error("`lease delayed` needs its ttl: `lease " &
            "delayed(<seconds>)`. A delayed lease with no ttl is an " &
            "immediate one wearing the wrong name -- the same refusal " &
            "`parseSharedServiceInstance` raises for the JSON " &
            "spelling.", m5ServiceStmtAnchor(entry))
        else:
          error("`lease " & identText(value) & "` is not a lease this " &
            "build knows. " & l9RecognisedLease & ".",
            m5ServiceStmtAnchor(entry))
      elif value.kind in {nnkCall, nnkCommand} and value.len >= 1 and
          value[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
        let word = identText(value[0]).normalize
        if word != "delayed":
          error("`lease " & identText(value[0]) & "(...)` is not a " &
            "lease this build knows; only `delayed` takes an " &
            "argument. " & l9RecognisedLease & ".",
            m5ServiceStmtAnchor(entry))
        if value.len != 2:
          error("`lease delayed(<seconds>)` takes exactly one ttl.",
            m5ServiceStmtAnchor(entry))
        let ttl = value[1]
        if ttl.kind != nnkIntLit:
          error("`lease delayed(<seconds>)` takes an integer LITERAL, " &
            "so the macro can refuse a non-positive one here rather " &
            "than at run time: `" & ttl.repr.strip() & "` is a " &
            $ttl.kind & ".", m5ServiceStmtAnchor(entry))
        if ttl.intVal <= 0:
          error("`lease delayed(" & $ttl.intVal & ")` is not a delay. " &
            "A ttl of zero is `lease immediate` and a negative one is " &
            "`lease keep`; write the lease you mean.",
            m5ServiceStmtAnchor(entry))
        result.instanceLeaseExpr = newLit(int64(ttl.intVal))
      else:
        error("`lease` takes one of " & l9RecognisedLease & "; `" &
          value.repr.strip() & "` is a " & $value.kind & ".",
          m5ServiceStmtAnchor(entry))
    else:
      error("`instance:` does not recognise the setting `" &
        identText(head) & "`. Its settings are " & l9RecognisedLease &
        ". An unrecognised setting is refused rather than ignored: a " &
        "lease that parses and is read by nothing leaves the instance " &
        "on the default, which decides whether a state-owning service " &
        "is reaped.", m5ServiceStmtAnchor(entry))

proc l9ParseWorkingDirectory(stmt: NimNode;
                             result: var L9ServiceSupervision) =
  if result.workingDirectoryExpr != nil:
    error("`workingDirectory` is declared twice in one `service` " &
      "body; the first wins at runtime, so the second is dead text.",
      m5ServiceStmtAnchor(stmt))
  if stmt.len != 2:
    error("`workingDirectory` takes exactly one directory: " &
      "`workingDirectory \"<dir>\"`. A relative path is resolved " &
      "against the project root by the supervisor -- the same " &
      "resolution a placeholder's `cwd` gets, not a second one.",
      m5ServiceStmtAnchor(stmt))
  result.workingDirectoryExpr = stmt[1].copyNimTree()

proc l9ParseStateDirectory(stmt: NimNode;
                           result: var L9ServiceSupervision) =
  if stmt.len < 2:
    error("`stateDirectory` takes at least one directory: " &
      "`stateDirectory \"<dir>\"`. It is the typed form of a " &
      "placeholder's `resources: [{\"kind\": \"directory\", \"path\": " &
      "...}]` -- a directory the supervisor creates before the service " &
      "starts -- and it REPEATS, because a service may own several.",
      m5ServiceStmtAnchor(stmt))
  for i in 1 ..< stmt.len:
    result.stateDirectoryExprs.add(stmt[i].copyNimTree())

proc m5ParseServiceBody(body: NimNode): tuple[
    executableRef: string; executableExpr: NimNode;
    argExprs: seq[NimNode]; runtimeFileExprs: seq[NimNode];
    reactiveEmissions: seq[NimNode];
    descriptionLit: NimNode; typeLit: NimNode; execStartLit: NimNode;
    wantedByLits: seq[NimNode]; wantsLits: seq[NimNode];
    requiresLits: seq[NimNode]; beforeLits: seq[NimNode];
    afterLits: seq[NimNode];
    envPairs: seq[tuple[keyLit: NimNode; valueLit: NimNode]];
    restartLit: NimNode; userLit: NimNode; groupLit: NimNode;
    convergePointNames: seq[string];
    identityScope: L4ServiceIdentityScope;
    supervision: L9ServiceSupervision] =
  ## Walk a ``service:`` body and extract its setters.
  ##
  ## ``Package-Model.md`` §Collections is the authority for the four
  ## setters this milestone makes real:
  ##
  ##   * ``executable <expr>`` — "May be an in-scope ident produced by an
  ##     ``executable`` block, or any other expression that evaluates to
  ##     an ``Executable[name]``". The IDENT form records the ident's
  ##     text without evaluating it (so it works before the artifact slot
  ##     variable has a value, which is what M5 relied on and what the
  ##     three M5 fixtures pin); any OTHER expression is spliced verbatim
  ##     into ``setActiveServiceExecutable``, where the compiler resolves
  ##     it against that proc's overload set.
  ##   * ``args "...", ...`` — every argument is now spliced verbatim,
  ##     literal or not. M5 accepted ``nnkStrLit`` only and SILENTLY
  ##     DROPPED everything else, which is how a ``cfg.path`` reference
  ##     would have vanished with no diagnostic. The ``args`` overload
  ##     set distinguishes a plain ``string`` (no edge) from a
  ##     ``BuildOutputPath`` (records the producing edge), so a type the
  ##     setter does not accept is now a compile error at the spliced
  ##     call site instead of an argument that is not there.
  ##   * ``runtimeFile <buildOutput>`` — "declares a build output that
  ##     the service must have alongside it at runtime even though the
  ##     path does not appear on argv".
  ##   * ``on <trigger>:`` blocks, plus the ``hotReload`` /
  ##     ``restartOnCrash`` / ``reloadOnChange`` short-form atoms.
  ##
  ## Shared-Development-Services L4 adds two more, read by the SHARED
  ## ``l4ServiceIdentityScope`` so the interface lift reads them the same
  ## way this walker does:
  ##
  ##   * ``identity derived`` (the default) / ``identity stable "<id>"``
  ##     — §4.2's two identity modes.
  ##   * ``scope project`` (the default) / ``workspace`` / ``user`` /
  ##     ``system`` — §4.1's four scopes.
  ##
  ## ``config:`` is REFUSED here, with the reason: "``service`` does not
  ## have a ``config:`` setter. Configuration is the package's job".
  ##
  ## M9.C extensions — systemd-unit metadata setters — are unchanged:
  ## ``description`` / ``type`` / ``execStart`` / ``wantedBy`` /
  ## ``wants`` / ``requires`` / ``before`` / ``after`` /
  ## ``env("KEY", "VALUE")`` / ``restart`` / ``user`` / ``group``.
  ##
  ## Any other statement is still silently preserved as raw body shape;
  ## the emitter captures the full body's ``repr`` into
  ## ``DslServiceDef.bodyRepr``.
  result.argExprs = @[]
  result.runtimeFileExprs = @[]
  result.reactiveEmissions = @[]
  result.wantedByLits = @[]
  result.wantsLits = @[]
  result.requiresLits = @[]
  result.beforeLits = @[]
  result.afterLits = @[]
  result.envPairs = @[]
  result.convergePointNames = @[]
  result.identityScope = l4NewIdentityScope()
  result.supervision = l9NewSupervision()
  if body.kind != nnkStmtList:
    return
  # L4: `identity` / `scope` are read by the shared walker, which also
  # raises every refusal for them. Done BEFORE the setter loop so an
  # unrecognised identity is reported at the `identity` statement rather
  # than at whatever the loop reaches first.
  result.identityScope = l4ServiceIdentityScope(body)
  for stmt in body:
    # The short-form reactive atoms are bare idents (``hotReload``,
    # ``restartOnCrash``) as well as calls, so they are tried before the
    # Call/Command filter below — which is why M5 dropped them.
    let shortForm = m5ServiceShortFormEmission(stmt)
    if shortForm != nil:
      result.reactiveEmissions.add(shortForm)
      continue
    # Shared-Development-Services L9: the two shapes the three filters
    # below drop in silence -- a bare supervision setter name and a
    # dotted head. Refused HERE, before any filter, because each filter
    # is a `continue` with no diagnostic.
    l9RefuseSupervisionNearMisses(stmt)
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
    of "config":
      error("`service` has no `config:` setter. Package-Model.md " &
        "§Collections: \"Configuration is the package's job: " &
        "package-level `config:` configurables plus rendering helpers " &
        "(`literalConfigFile`, `configFile`, etc.) produce a " &
        "`BuildOutput`, and the service consumes that output the same " &
        "way any other build output is consumed -- either by reference " &
        "on argv or via `runtimeFile`.\" Move the values to the " &
        "package's `config:` block, render them with " &
        "`renderConfigFile(...)`, and pass the handle on `args` or " &
        "declare it with `runtimeFile`.", stmt)
    of "on":
      # Always a node, or a macro ``error`` naming the offending spelling.
      # It is deliberately NOT guarded with ``if emission != nil``: that
      # guard is exactly how ``on ready:`` used to disappear.
      result.reactiveEmissions.add(m5ServiceTriggerEmission(stmt))
    of "executable":
      # ``executable <ident>`` — record the ident's text, unevaluated.
      # Any other expression is kept as a node and spliced.
      if stmt.len >= 2 and stmt[1].kind in
          {nnkIdent, nnkSym, nnkAccQuoted}:
        result.executableRef = identText(stmt[1])
        result.executableExpr = nil
      else:
        result.executableRef = ""
        result.executableExpr = stmt[1].copyNimTree()
    of "args":
      # ``args "a", expr, ...`` — append EVERY argument node.
      for i in 1 ..< stmt.len:
        result.argExprs.add(stmt[i].copyNimTree())
    of "runtimefile":
      for i in 1 ..< stmt.len:
        result.runtimeFileExprs.add(stmt[i].copyNimTree())
    of "readiness":
      # Shared-Development-Services L9. §9.1's worked example writes
      # `readiness httpGet("/debug/ready", port = port)` as a setter of
      # the `service` block, and until now there was none: the probe
      # could only be declared in a `servicePlaceholder`'s JSON.
      l9ParseReadinessSetter(stmt, result.supervision)
    of "workingdirectory":
      l9ParseWorkingDirectory(stmt, result.supervision)
    of "statedirectory":
      l9ParseStateDirectory(stmt, result.supervision)
    of "instance":
      l9ParseInstanceBlock(stmt, result.supervision)
    of "converge":
      # Shared-Development-Services L8 -- `converge <point>, <point>`.
      #
      # §9.1's worked example writes this verb, in `on ready:`:
      # "Converge the contributions once the instance answers.
      #  Idempotent and attributed: a second consumer registers only its
      #  own members and never re-mints an existing client id."
      #
      # It is a TOP-LEVEL setter here rather than an `on ready:` action
      # and the reason is which lane runs it: the trigger actions
      # (`sendSignal`, `restart`) are things the SUPERVISOR does to a
      # running process, while a registration is a RESOURCE the resource
      # lane reconciles after the instance answers. Putting it in the
      # trigger list would have made the supervisor its owner, which is
      # D-SS10's "an ordinary `dependsOn` onto the service node" read
      # backwards.
      #
      # EVERY ARGUMENT MUST BE A BARE IDENTIFIER naming a contribution
      # point of the declaring activity. A string literal, a dotted
      # path, a call -- anything else -- is REFUSED rather than dropped,
      # because a `converge "relyingParties"` that compiled and
      # registered nothing is the exact defect shape this campaign keeps
      # finding.
      if stmt.len < 2:
        error("`converge` takes at least one contribution point, e.g. " &
          "`converge relyingParties`. On its own it registers nothing.",
          m5ServiceStmtAnchor(stmt))
      for i in 1 ..< stmt.len:
        if stmt[i].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
          error("`converge` takes BARE IDENTIFIERS naming contribution " &
            "points of the declaring activity; `" &
            stmt[i].repr.strip() & "` is a " & $stmt[i].kind & ". A " &
            "quoted name or a dotted path is refused rather than " &
            "dropped: a `converge` that compiles and registers nothing " &
            "is indistinguishable from one that works.",
            m5ServiceStmtAnchor(stmt[i]))
          continue
        result.convergePointNames.add(identText(stmt[i]))
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
    of "identity", "scope", "compatibility":
      # L4 / L6: already read (and validated) by `l4ServiceIdentityScope`
      # above. Named here rather than left to the `else` so the three are
      # visibly ACCOUNTED FOR by this walker; falling through to
      # `discard` would read as "not a setter".
      #
      # `compatibility` is read by this walker and NOT carried onto
      # `DslServiceDef`: §4.4/§6.5 key an instance by
      # `(identity, scope, environment)` and the major is not in that
      # key, so the lowered `gnkService` payload -- whose job is to
      # materialise -- has no reader for it. The LIFT carries it (see
      # `ServiceInterfaceDef.compatibilityMajor`), which is where §4.3
      # compares it. The reading is still shared, so the refusals above
      # fire for a recipe whether or not it is being lifted.
      discard
    else:
      discard

proc m5ServiceEmission(packageName: string; stmt: NimNode): NimNode =
  ## Lower ONE ``service <name>:`` statement to its wrap-and-register
  ## block, or return ``nil`` when ``stmt`` is not a recognised service
  ## entry.
  ##
  ## Extracted from ``emitM5Services``' loop body by
  ## Shared-Development-Services L2 with no change in behaviour, so that
  ## a ``service`` written inside a dev-env ``activity`` body lowers
  ## through exactly the same emitter as one written at package level. A
  ## second, parallel service lowerer is the drift this avoids: every
  ## setter, every refusal and every typed edge L1 built would otherwise
  ## have to be kept in step across two walkers.
  ##
  ## Everything between the service NAME and its block body is refused
  ## here, before the entry is parsed. ``m5ServiceEntryAst`` accepts any
  ## arity of three or more and reads only ``stmt[1]`` and ``stmt[^1]``,
  ## so ``service api, junkArg:`` lowered exactly as ``service api:``
  ## would and ``junkArg`` never reached the compiler — the same defect,
  ## in the same position, as the ``on change cfg, debounce = "200ms":``
  ## head one level down. The refusal lives in this shared emitter
  ## rather than in either walker so the package-level path and the
  ## dev-env ``activity`` path cannot drift apart on it.
  if stmt.kind in {nnkCall, nnkCommand} and stmt.len > 3 and
      stmt[^1].kind == nnkStmtList:
    for i in 2 ..< stmt.len - 1:
      let extra = stmt[i]
      error("`service <name>:` takes one name and a block body of " &
        "setters; `" & extra.repr.strip() & "` beside the head of " &
        "`service " & stmt[1].repr.strip() & ":` is neither. " &
        "Package-Model.md §Collections: a service is declared by name " &
        "and everything it carries is a setter in the body — " &
        m5ServiceSetterSurface & ". " & m5ServiceHeadDropRule,
        m5ServiceStmtAnchor(extra))
  let parsed = m5ServiceEntryAst(stmt)
  if not parsed.matched:
    return nil
  let parsedBody = m5ParseServiceBody(parsed.body)
  let pkgLit = newLit(packageName)
  let svcNameLit = newLit(parsed.serviceName)
  let bodyReprLit = newLit(parsed.body.repr)
  let exeRefLit = newLit(parsedBody.executableRef)
  # Build the try-clause body: one setActiveServiceExecutable call
  # (only when the body provided a ref) plus one addActiveServiceArg
  # per arg. M9.C extensions emit one body-setter call per recognised
  # systemd-unit setter.
  let tryBody = newStmtList()
  if parsedBody.executableExpr != nil:
    let exeExpr = parsedBody.executableExpr
    tryBody.add(quote do:
      setActiveServiceExecutable(`exeExpr`))
  elif parsedBody.executableRef.len > 0:
    tryBody.add(quote do:
      setActiveServiceExecutable(`exeRefLit`))
  for pointName in parsedBody.convergePointNames:
    let pointLit = newLit(pointName)
    tryBody.add(quote do:
      addActiveServiceConvergePoint(`pointLit`))
  for argExpr in parsedBody.argExprs:
    tryBody.add(quote do:
      addActiveServiceArg(`argExpr`))
  for fileExpr in parsedBody.runtimeFileExprs:
    tryBody.add(quote do:
      addActiveServiceRuntimeFile(`fileExpr`))
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
  # L4: identity and scope. Emitted only when the body DECLARED them --
  # the runtime frame is already initialised to `sikDerived` /
  # `sscProject`, so an unconditional call would make a recipe that said
  # nothing indistinguishable from one that wrote the default, and
  # `setActiveServiceIdentity`'s first-wins guard would then be armed by
  # the macro rather than by the author.
  if parsedBody.identityScope.identityDeclared:
    let kindLit =
      if parsedBody.identityScope.identityKind == sikStable:
        ident("sikStable")
      else:
        ident("sikDerived")
    let idLit = newLit(parsedBody.identityScope.stableId)
    tryBody.add(quote do:
      setActiveServiceIdentity(`kindLit`, `idLit`))
  if parsedBody.identityScope.scopeDeclared:
    let scopeLit = ident($parsedBody.identityScope.scope)
    tryBody.add(quote do:
      setActiveServiceScope(`scopeLit`))
  # L9: the supervision setters. Emitted only when the body DECLARED
  # them, for the reason L4's identity emission gives: the runtime frame
  # is already on the ground state, so an unconditional call would make
  # a recipe that said nothing indistinguishable from one that wrote the
  # default — and for `readiness` the ground state (`srkUnset`) is what
  # sends the supervisor to the placeholder's probe.
  if parsedBody.supervision.readinessDeclared:
    let kindIdent =
      case parsedBody.supervision.readinessKind
      of "none": ident("srkNone")
      of "fileExists": ident("srkFileExists")
      else: ident("srkHttpGet")
    let pathExpr =
      if parsedBody.supervision.readinessPathExpr != nil:
        parsedBody.supervision.readinessPathExpr
      else:
        newLit("")
    let timeoutExpr =
      if parsedBody.supervision.readinessTimeoutExpr != nil:
        parsedBody.supervision.readinessTimeoutExpr
      else:
        newLit(0)
    # `port = <n>` IS `url = "http://127.0.0.1:<n>"`, derived here so
    # the supervisor has one url field to read rather than two shapes
    # to reconcile. 127.0.0.1 and not `localhost`, because a dev
    # service binds loopback and `localhost` can resolve to `::1` on a
    # host whose service listens on IPv4 only.
    let urlExpr =
      if parsedBody.supervision.readinessUrlExpr != nil:
        parsedBody.supervision.readinessUrlExpr
      elif parsedBody.supervision.readinessPortExpr != nil:
        let portExpr = parsedBody.supervision.readinessPortExpr
        quote do:
          "http://127.0.0.1:" & $(`portExpr`)
      else:
        newLit("")
    tryBody.add(quote do:
      setActiveServiceReadiness(ServiceReadinessDef(
        kind: `kindIdent`,
        path: `pathExpr`,
        url: `urlExpr`,
        timeoutMs: int(`timeoutExpr`))))
  if parsedBody.supervision.workingDirectoryExpr != nil:
    let dirExpr = parsedBody.supervision.workingDirectoryExpr
    tryBody.add(quote do:
      setActiveServiceWorkingDirectory(`dirExpr`))
  for dirExpr in parsedBody.supervision.stateDirectoryExprs:
    tryBody.add(quote do:
      addActiveServiceStateDirectory(`dirExpr`))
  if parsedBody.supervision.instanceDeclared:
    let leaseExpr =
      if parsedBody.supervision.instanceLeaseExpr != nil:
        parsedBody.supervision.instanceLeaseExpr
      else:
        newLit(SharedServiceInstanceKeepTtlSeconds)
    tryBody.add(quote do:
      setActiveServiceInstance(int64(`leaseExpr`)))
  # L1: the reactive surface, after the declarative setters so an
  # ``on change cfg:`` block sees the same handle the args did.
  for emission in parsedBody.reactiveEmissions:
    tryBody.add(emission)
  if tryBody.len == 0:
    tryBody.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
  # The package-init block. The body-setter splice is unconditional
  # (no provider-mode gate) — see the "Risk #2" commentary above the
  # M5 emitter for the rationale.
  let declareSym = genSym(nskProc, "declareService")
  result = quote do:
    block:
      proc `declareSym`() {.closure.} =
        beginServiceContext(`pkgLit`, `svcNameLit`, `bodyReprLit`)
        try:
          `tryBody`
        finally:
          finishServiceContext()
      registerServiceDeclarator(`pkgLit`, `svcNameLit`, `declareSym`)
      `declareSym`()

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
  ##     proc declare() {.closure.} =
  ##       beginServiceContext(<pkg>, <serviceName>, <bodyRepr>)
  ##       try:
  ##         setActiveServiceExecutable(<executable>)   # if present
  ##         addActiveServiceArg(<arg-1>)               # per arg
  ##         addActiveServiceRuntimeFile(<file-1>)      # per runtimeFile
  ##         <on-trigger blocks>
  ##       finally:
  ##         finishServiceContext()
  ##     registerServiceDeclarator(<pkg>, <serviceName>, declare)
  ##     declare()
  ##
  ## Shared-Development-Services L1 wrapped the body in a RE-RUNNABLE
  ## closure and registers it, as well as running it eagerly exactly as
  ## M5 did. The eager run keeps every existing reader of
  ## ``registeredServices`` seeing what it saw before; the registration
  ## is what lets ``buildPackageFragment`` re-evaluate the body AFTER the
  ## ``build:`` body has run, which is the only moment a service's
  ## rendered-config ``BuildOutput`` exists in provider mode (the
  ## ``build:`` splice is gated on ``not defined(reproProviderMode)`` —
  ## see ``emitM4BuildActions``). Without the re-run a service's
  ## ``args "--config", cfg.path`` would record an empty path in provider
  ## mode and nothing would say so.
  ##
  ## The body-setter calls are NOT spliced from the user's body
  ## verbatim for the scalar setters — we parse them out at macro
  ## expansion time and emit the equivalent runtime calls — but the
  ## VALUE expressions are spliced verbatim, so the compiler resolves
  ## and type-checks them. The full body's ``repr`` is captured into
  ## ``DslServiceDef.bodyRepr`` for diagnostic surfacing.
  ##
  ## The per-entry lowering itself lives in ``m5ServiceEmission``, which
  ## L2's dev-env ``activity`` walker shares.
  result = newStmtList()
  for entry in classified:
    if entry.ownership != soM5Service:
      continue
    let emission = m5ServiceEmission(packageName, entry.stmt)
    if emission == nil:
      continue
    result.add(emission)


# ---------------------------------------------------------------------------
# Shared-Development-Services L2 — the "names the available members"
# refusal.
#
# L2's gate: "a wrong member name failing the project's recipe
# COMPILATION with a message naming the available members". Nim's own
# diagnostic for a missing field is ``undeclared field: 'connectionStrin'
# for type recipe.ManagedPostgres``, which stops the build but names
# nothing the author could have written instead. This macro supplies that
# half, and the activity walker arranges for it to run ONLY on a member
# the type does not have (see ``l2MemberCheckStmts``), so the type's
# member list is computed exactly where it is about to be printed.
# ---------------------------------------------------------------------------

proc l2AppendRecListNames(recList: NimNode; acc: var seq[string]) =
  ## Field names out of an ``nnkRecList``, including the discriminator and
  ## every branch of a variant object.
  for entry in recList:
    case entry.kind
    of nnkIdentDefs:
      for i in 0 ..< entry.len - 2:
        var name = entry[i]
        if name.kind == nnkPostfix:
          name = name[1]
        if name.kind == nnkPragmaExpr:
          name = name[0]
        if name.kind == nnkPostfix:
          name = name[1]
        if name.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
          let text = identText(name)
          if text.len > 0 and text notin acc:
            acc.add(text)
    of nnkRecCase:
      if entry.len > 0:
        l2AppendRecListNames(newStmtList(entry[0]), acc)
      for i in 1 ..< entry.len:
        let branch = entry[i]
        if branch.len > 0 and branch[^1].kind == nnkRecList:
          l2AppendRecListNames(branch[^1], acc)
    of nnkRecList:
      l2AppendRecListNames(entry, acc)
    of nnkNilLit, nnkEmpty, nnkCommentStmt:
      discard
    else:
      discard

proc l2AppendTypeMemberNames(node: NimNode; acc: var seq[string];
                             depth: int) =
  ## Member names of whatever type ``node`` denotes. Follows ``ref`` /
  ## ``ptr``, object inheritance and ``distinct``; ``depth`` bounds the
  ## walk so a pathological type cannot hang the compiler.
  if depth > 8 or node == nil:
    return
  var target = node
  if target.kind == nnkBracketExpr and target.len == 2 and
      target[0].kind in {nnkIdent, nnkSym} and
      identText(target[0]).normalize == "typedesc":
    target = target[1]
  var impl: NimNode = nil
  if target.kind in {nnkSym, nnkIdent}:
    impl = target.getTypeImpl()
  else:
    impl = target
  if impl == nil:
    return
  case impl.kind
  of nnkRefTy, nnkPtrTy:
    if impl.len > 0:
      l2AppendTypeMemberNames(impl[0], acc, depth + 1)
  of nnkDistinctTy:
    if impl.len > 0:
      l2AppendTypeMemberNames(impl[0], acc, depth + 1)
  of nnkObjectTy:
    if impl.len >= 3 and impl[2].kind == nnkRecList:
      l2AppendRecListNames(impl[2], acc)
    if impl.len >= 2 and impl[1].kind == nnkOfInherit and impl[1].len > 0:
      l2AppendTypeMemberNames(impl[1][0], acc, depth + 1)
  of nnkTupleTy:
    l2AppendRecListNames(impl, acc)
  of nnkBracketExpr:
    # A generic instance (``MyObj[int]``): the member names live on the
    # generic body.
    if impl.len > 0:
      l2AppendTypeMemberNames(impl[0], acc, depth + 1)
  else:
    discard

macro activityMemberRefusal*(ty: typedesc; anchor: untyped;
                             activityName, paramName,
                             memberName: static string): untyped =
  ## Refuse one ``<param>.<member>`` access, naming the members ``ty``
  ## actually has.
  ##
  ## Invoked only from the ``when not compiles(...)`` guard the activity
  ## walker emits, so reaching this macro at all means the access does
  ## not typecheck. It therefore always errors; there is no success path
  ## and no node it could return.
  ##
  ## ``anchor`` is the offending ``<param>.<member>`` expression from the
  ## recipe, passed ``untyped`` so it is NOT semchecked here (it cannot
  ## be — that is the point) and used only for its line info. Without it
  ## the diagnostic reports against this macro's own line in the DSL,
  ## which is the "reported against generated code" failure the message
  ## itself warns about.
  var inst = ty.getTypeInst()
  var typeNode = inst
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2:
    typeNode = typeNode[1]
  var members: seq[string] = @[]
  l2AppendTypeMemberNames(typeNode, members, 0)
  let typeText = typeNode.repr.strip()
  let available =
    if members.len == 0:
      "type `" & typeText & "` has no member fields at all"
    else:
      "available members of `" & typeText & "`: " & members.join(", ")
  error("activity `" & activityName & "`: parameter `" & paramName &
    "` has no member `" & memberName & "`. " & available & ". " &
    "`Package-Model.md` §\"Activity declaration shape\": \"The body uses " &
    "them like ordinary Nim values -- `db.connectionString`, " &
    "`assets.bucket` -- with full typechecking\". A member written here " &
    "that the parameter's type does not have is refused at the recipe's " &
    "own line rather than reported against generated code.", anchor)

# ---------------------------------------------------------------------------
# Shared-Development-Services L2 — the dev-env ``activity`` constructor
# shape.
#
# ``Package-Model.md`` §"Activity declaration shape" is the authority:
#
#   "Activities are declared with a function-call shape. Required
#    dependencies are constructor-style typed parameters; everything that
#    has a default lives in an inner ``config:`` block."
#   "Required dependencies (``db``, ``assets``) are typed parameters of the
#    activity. The body uses them like ordinary Nim values —
#    ``db.connectionString``, ``assets.bucket`` — with full typechecking and
#    go-to-definition."
#   "``enable myApi(db = mainDb, assets = assets): <overrides>`` is a typed
#    call into the activity's generated entry point. Parameter names and
#    types are checked the same way Nim checks any function call."
#
# WHY A WALKER RATHER THAN AN OVERLOADED ``activity`` MACRO. The obvious
# implementation is a ``macro activity*(decl, body: untyped)`` overloading
# today's ``proc activity*(name: string)``. Measured on this tree, that
# does not work and cannot be made to: with both in the overload set Nim
# semchecks the call's arguments before choosing a candidate, so
# ``activity myApi(db: ManagedPostgres):`` fails with
# ``undeclared identifier: 'myApi'`` — the parameter list is read as an
# object constructor. Dropping the proc to make room for the macro is
# exactly what L2's gate forbids ("``proc activity(name: string)``
# continues to work for the parameterless case"), and there are real
# callers: ``isonim-platform/repro.nim`` and ``codetracer/repro.nim``
# declare ten bare activities between them.
#
# So the constructor form is lowered by the ``package`` macro's own
# dev-env walker, the way every other block in this DSL is, and
# ``activity "<name>"`` is left VERBATIM for the proc to handle. The
# generated entry point even registers the name by calling that proc, so
# the two forms share one registry.
#
# WHAT IS LOWERED, AND WHAT IS NOT. ``activity <name>(<p>: <T>, ...):``
# becomes an ordinary nested Nim proc whose parameters are the declared
# ones followed by one parameter per ``config:`` key, carrying that key's
# default. That is the whole of the typing story: the body is spliced
# verbatim, so ``db.connectionString`` is a real field access on a real
# typed value, and ``enable`` is a real Nim call whose argument names and
# types the compiler checks. Nothing here reimplements typechecking.
#
# A ``service <name>:`` statement in the body is lowered by
# ``m5ServiceEmission`` — L1's emitter, shared rather than duplicated.
# Every other statement is passed through untouched, because the spec says
# the body is ordinary Nim.
# ---------------------------------------------------------------------------

const
  l2ActivityHeadRule = "`Package-Model.md` §\"Activity declaration " &
    "shape\": an activity is `activity <name>(<param>: <Type>, ...): " &
    "<body>`, or `activity <name>: <body>` with no parameters. The " &
    "parameterless `activity \"<name>\"` string form is unchanged and is " &
    "not affected by this."
  l2ActivityConfigRule = "`Package-Model.md` §\"Activity declaration " &
    "shape\": a `config:` key is `<name>: <Type> = <default>`, or " &
    "`<name>: <Type>` when the caller must supply it."
  l2NoSilentDropRule = "An unrecognised spelling here is REFUSED rather " &
    "than dropped: a parameter, a `config:` key or an `enable` override " &
    "that is accepted and then not there is indistinguishable from " &
    "support for it. This is the same defect the `args` setter and the " &
    "`on <trigger>:` walker had before Shared-Development-Services L1."
  l2ActivityConfigHeadDropRule = "An extra argument here is REFUSED " &
    "rather than dropped: it is never semchecked, so an identifier that " &
    "does not exist compiles clean, and an argument that is accepted and " &
    "then has no effect is indistinguishable from support for it."

type
  L2ActivityParam = object
    ## One constructor-style typed parameter, as written.
    name: string
    typeNode: NimNode

  L2ActivityConfigKey = object
    ## One ``config:`` key, as written. ``defaultNode`` is ``nil`` when
    ## the key has no default, which makes the key a REQUIRED
    ## CONFIGURABLE (Shared-Development-Services L5, §6): the slot
    ## exists and has no seed.
    ##
    ## IT NO LONGER MAKES THE GENERATED PARAMETER REQUIRED AT THE
    ## ``enable`` SITE, which is what this comment said before L5.
    ## ``l2ActivityEmission`` gives such a parameter the default
    ## ``requiredConfigurableValue[T](...)``, so an ``enable`` site may
    ## leave it out and have the SELECTED ENVIRONMENT supply it -- that
    ## is §6's first route, and the ``enable`` argument is its second.
    ## A site that supplies neither is refused: at expansion by
    ## ``l5RefuseUnsatisfiableRequiredKeys`` when nothing can ever
    ## satisfy it, and at resolution by ``requiredConfigurableValue``
    ## otherwise.
    name: string
    typeNode: NimNode
    defaultNode: NimNode
    description: string

var l2ActivityConfigKeyNames {.compileTime.}: Table[string, seq[string]]
  ## ``<package>\x1f<activity>`` → its ``config:`` key names, recorded by
  ## the activity walker and read by the ``enable`` walker so an
  ## unrecognised override can name the keys that do exist. Compile-time
  ## only, and per-compilation: it carries no state between recipes.

var l2ActivityParamNames {.compileTime.}: Table[string, seq[string]]
  ## Same key. Read only to tell an author who wrote a CONSTRUCTOR
  ## parameter in the override body that it belongs in the parentheses —
  ## a mistake that would otherwise be reported as an unknown key.

proc l2ActivityKey(packageName, activityName: string): string =
  packageName & "\x1f" & activityName

proc l2ActivityEntryProcName(activityName: string): string =
  ## The generated entry point's name. Deterministic from the activity
  ## name alone, which is what lets the ``enable`` walker name it without
  ## a registry: both walkers compute this same string.
  "reproActivity_" & activityName

proc l2CommentText(node: NimNode): string =
  ## A ``nnkCommentStmt``'s text with any leading ``#`` markers stripped,
  ## line by line. Same treatment ``collectConfigSection`` gives a
  ## ``config:`` doc comment, for the same reason: the node's ``strVal``
  ## is not consistently marker-free.
  var lines: seq[string] = @[]
  for line in node.strVal.splitLines():
    var trimmed = line.strip()
    while trimmed.len > 0 and trimmed[0] == '#':
      trimmed = trimmed[1 .. ^1]
    lines.add(trimmed.strip())
  result = lines.join("\n").strip()

proc l2StmtAnchor(stmt: NimNode): NimNode =
  ## The node a refusal about ``stmt`` should report at.
  ##
  ## Nim puts a call node's line info on its opening parenthesis and an
  ## assignment's on its ``=``, so anchoring on the statement itself
  ## reports a column several tokens to the right of the thing the author
  ## has to look at. Anchoring on the HEAD gives the statement's own
  ## column. Same fix, and the same reason, as L1's
  ## ``m5ServiceStmtAnchor``.
  if stmt.kind in {nnkCall, nnkCommand, nnkAsgn, nnkExprEqExpr,
                   nnkExprColonExpr, nnkObjConstr} and stmt.len > 0:
    return stmt[0]
  stmt

proc l2IsHeadNamed(stmt: NimNode; name: string): bool =
  ## ``stmt`` is a Call/Command whose head ident is ``name``.
  if stmt.kind notin {nnkCall, nnkCommand}:
    return false
  if stmt.len < 1:
    return false
  if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return false
  identText(stmt[0]).normalize == name.normalize

proc l2ActivityEntryAst(stmt: NimNode): tuple[matched: bool;
    activityName: string; paramsNode: NimNode; body: NimNode] =
  ## Recognise ``activity <ident>: <body>`` and
  ## ``activity <ident>(<p>: <T>, ...): <body>``.
  ##
  ## The parameter list parses as an ``nnkObjConstr`` (because its
  ## children are ``nnkExprColonExpr``) and the empty list
  ## ``activity foo():`` as an ``nnkCall``; both are accepted. A string
  ## head (``activity "default"``) is NOT matched — that is the proc
  ## form, and leaving it unmatched is how it keeps reaching the proc.
  result.paramsNode = nil
  if not l2IsHeadNamed(stmt, "activity"):
    return
  if stmt.len != 3:
    # An ObjConstr head can only be a parameter list: `foo(a: b)` is not
    # a string expression, so it can never have been meant for
    # `proc activity(name: string)`. Refused rather than passed on,
    # because Nim reports it as `undeclared identifier: 'foo'` -- which
    # is true of the ACTIVITY NAME and tells the author nothing.
    #
    # An IDENT or CALL head at this arity is left alone on purpose:
    # `activity someName` and `activity nameOf(x)` are both legal uses
    # of the string-form proc, and refusing them would break the surface
    # this milestone must preserve.
    if stmt.len == 2 and stmt[1].kind == nnkObjConstr and
        stmt[1].len > 0 and
        stmt[1][0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      error("activity `" & identText(stmt[1][0]) & "`: an activity with " &
        "parameters needs a body. " & l2ActivityHeadRule & " " &
        l2NoSilentDropRule, l2StmtAnchor(stmt))
    return
  if stmt[2].kind != nnkStmtList:
    return
  let headNode = stmt[1]
  case headNode.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    result.matched = true
    result.activityName = identText(headNode)
    result.body = stmt[2]
  of nnkObjConstr, nnkCall:
    if headNode.len < 1 or
        headNode[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      return
    result.matched = true
    result.activityName = identText(headNode[0])
    result.paramsNode = headNode
    result.body = stmt[2]
  else:
    discard

proc l2ParseActivityParams(activityName: string;
                           paramsNode: NimNode): seq[L2ActivityParam] =
  ## ``(db: ManagedPostgres, assets: ObjectStore)`` → one entry each. The
  ## type is kept as a NODE and spliced into the generated proc's
  ## signature, so the compiler resolves it; this walker never interprets
  ## it.
  result = @[]
  if paramsNode == nil:
    return
  for i in 1 ..< paramsNode.len:
    let child = paramsNode[i]
    if child.kind == nnkExprColonExpr and child.len == 2 and
        child[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      result.add(L2ActivityParam(
        name: identText(child[0]),
        typeNode: child[1].copyNimTree()))
    else:
      error("activity `" & activityName & "`: `" & child.repr.strip() &
        "` is not a typed parameter. Every parameter needs a declared " &
        "type: `<name>: <Type>`. " & l2ActivityHeadRule & " " &
        l2NoSilentDropRule, l2StmtAnchor(child))

proc l2ConfigTypeNodeIsPlausible(node: NimNode): bool =
  ## Whether a ``config:`` entry's single body node can be read as a TYPE
  ## expression. The question only arises for the no-default form
  ## (``externalDomain: string``), whose AST is otherwise
  ## indistinguishable from a nested block (``database:`` followed by an
  ## indented body) or from a value written where a type belongs
  ## (``port: 8080``). Both of those are refused rather than lowered into
  ## a parameter whose "type" the compiler will reject with a message
  ## about generated code.
  node.kind notin {nnkCall, nnkCommand, nnkStmtList, nnkAsgn,
                   nnkExprEqExpr, nnkCommentStmt, nnkStrLit, nnkRStrLit,
                   nnkTripleStrLit, nnkIntLit, nnkInt64Lit, nnkFloatLit,
                   nnkCharLit, nnkNilLit, nnkIfStmt, nnkForStmt,
                   nnkWhileStmt, nnkCaseStmt, nnkLetSection,
                   nnkVarSection, nnkConstSection, nnkDiscardStmt}

proc l2ParseActivityConfig(activityName: string;
                           body: NimNode): seq[L2ActivityConfigKey] =
  ## Walk every ``config:`` block in an activity body. More than one is
  ## accepted and they concatenate, which costs nothing and keeps a
  ## recipe that groups its keys from being a special case.
  result = @[]
  for stmt in body:
    if not l2IsHeadNamed(stmt, "config"):
      continue
    if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
      error("activity `" & activityName & "`: `config:` needs a block " &
        "body of key declarations. " & l2ActivityConfigRule & " " &
        l2NoSilentDropRule, l2StmtAnchor(stmt))
    # ``config:`` is ``Call(config, StmtList)`` — arity two. Anything
    # between the head and the block body was DROPPED IN SILENCE: this
    # walk reads ``stmt[^1]`` and never looked at ``stmt[1 .. ^2]``, so
    # ``config noSuchProc(1, 2), alsoMissing:`` compiled clean with both
    # identifiers never semchecked. Nothing is ever legal on this head,
    # so the refusal is arity plus the message and carries no design
    # decision — see ``reprobuild-pm/issues/2026-10-08-activity-config-
    # head-arguments-are-silently-dropped.md``. ``config port:`` is the
    # plausible slip it exists for: an author reaching for a per-key
    # head and getting an ignored one.
    for i in 1 ..< stmt.len - 1:
      let extra = stmt[i]
      error("activity `" & activityName & "`: `config:` takes no " &
        "arguments, and `" & extra.repr.strip() & "` is written on its " &
        "head. Every key is declared INSIDE the block body. " &
        l2ActivityConfigRule & " " & l2ActivityConfigHeadDropRule,
        l2StmtAnchor(extra))
    var pendingDoc = ""
    for entry in stmt[^1]:
      if entry.kind == nnkCommentStmt:
        if pendingDoc.len > 0:
          pendingDoc.add("\n")
        pendingDoc.add(l2CommentText(entry))
        continue
      if entry.kind == nnkCall and entry.len == 2 and
          entry[0].kind in {nnkIdent, nnkSym, nnkAccQuoted} and
          entry[1].kind == nnkStmtList and entry[1].len == 1:
        let inner = entry[1][0]
        if inner.kind == nnkAsgn and inner.len == 2:
          result.add(L2ActivityConfigKey(
            name: identText(entry[0]),
            typeNode: inner[0].copyNimTree(),
            defaultNode: inner[1].copyNimTree(),
            description: pendingDoc))
          pendingDoc = ""
          continue
        if l2ConfigTypeNodeIsPlausible(inner):
          result.add(L2ActivityConfigKey(
            name: identText(entry[0]),
            typeNode: inner.copyNimTree(),
            defaultNode: nil,
            description: pendingDoc))
          pendingDoc = ""
          continue
      # Named by KEY rather than by the entry's ``repr``: a
      # ``name:``-with-a-block node reprs as ``name do:`` across several
      # lines, which makes the first line of the diagnostic say nothing.
      if entry.kind in {nnkCall, nnkCommand} and entry.len == 2 and
          entry[0].kind in {nnkIdent, nnkSym, nnkAccQuoted} and
          entry[1].kind == nnkStmtList:
        var declared: seq[string] = @[]
        for inner in entry[1]:
          # Flattened: a nested block's ``repr`` spans lines, and a
          # diagnostic whose first line is `host do:` says nothing.
          declared.add(inner.repr.strip().splitLines().join(" / "))
        error("activity `" & activityName & "`: `config:` key `" &
          identText(entry[0]) & "` is declared as `" &
          declared.join("; ") & "`, which is neither a type with a " &
          "default nor a bare type. " & l2ActivityConfigRule & " " &
          l2NoSilentDropRule, l2StmtAnchor(entry))
      error("activity `" & activityName & "`: `" & entry.repr.strip() &
        "` is not a `config:` key declaration. " & l2ActivityConfigRule &
        " " & l2NoSilentDropRule, l2StmtAnchor(entry))

proc l2WalkMemberUses(node: NimNode; paramNames: seq[string];
                      calleePosition: bool;
                      acc: var seq[tuple[param, member: string;
                                         anchor: NimNode]]) =
  ## Collect every ``<param>.<member>`` field access in an activity body.
  ##
  ## A dot expression in CALLEE position (``db.listTables(2)``) is skipped
  ## deliberately: ``compiles(db.listTables)`` is false for a proc that
  ## needs more arguments, so checking it would refuse a correct recipe.
  ## Method-call syntax on a parameter is therefore left entirely to the
  ## compiler, which reports it the way it reports any other call.
  if node.kind == nnkDotExpr and node.len == 2 and
      node[0].kind in {nnkIdent, nnkSym} and
      node[1].kind in {nnkIdent, nnkSym, nnkAccQuoted} and
      not calleePosition:
    let base = identText(node[0]).normalize
    for name in paramNames:
      if name.normalize == base:
        acc.add((param: name, member: identText(node[1]), anchor: node))
        break
  if node.kind in {nnkCall, nnkCommand} and node.len > 0:
    l2WalkMemberUses(node[0], paramNames, true, acc)
    for i in 1 ..< node.len:
      l2WalkMemberUses(node[i], paramNames, false, acc)
  else:
    for child in node:
      l2WalkMemberUses(child, paramNames, false, acc)

proc l2MemberCheckStmts(activityName: string;
                        params: seq[L2ActivityParam];
                        body: NimNode): NimNode =
  ## One guarded refusal per distinct ``<param>.<member>`` pair the body
  ## uses, emitted at the TOP of the generated entry point so it is
  ## semchecked before the body that contains the offending access.
  ##
  ## The guard is ``when not compiles(<param>.<member>)``, so the refusal
  ## macro runs ONLY for a member the type does not have — and the
  ## message it then produces can name the members the type DOES have,
  ## which is what L2's gate asks for and what Nim's own
  ## ``undeclared field`` error does not do.
  result = newStmtList()
  if params.len == 0:
    return
  var names: seq[string] = @[]
  for p in params:
    names.add(p.name)
  var uses: seq[tuple[param, member: string; anchor: NimNode]] = @[]
  l2WalkMemberUses(body, names, false, uses)
  var seen: seq[string] = @[]
  for use in uses:
    let key = use.param & "." & use.member
    if key in seen:
      continue
    seen.add(key)
    let paramIdent = ident(use.param)
    let access = newDotExpr(paramIdent, ident(use.member))
    let refusal = newCall(ident("activityMemberRefusal"),
      newCall(ident("typeof"), paramIdent), use.anchor.copyNimTree(),
      newLit(activityName), newLit(use.param), newLit(use.member))
    # The refusal reports at the recipe's own line rather than at
    # generated code, which is the difference between a diagnostic an
    # author can act on and one they have to decode.
    refusal.copyLineInfo(use.anchor)
    result.add(quote do:
      when not compiles(`access`):
        `refusal`)

proc l2RefuseL5HeadsHere(context: string; stmt: NimNode) =
  ## Shared-Development-Services L5, D-SS8 enforced in the OTHER
  ## direction: an `environment <name>:` or `instanceOverrides <...>:`
  ## written inside a `devEnv:` body or an activity body is refused BY
  ## NAME, rather than copied through to fail as `undeclared identifier:
  ## environment` on the author's line.
  ##
  ## D-SS8 resolves that `devEnv:` and an environment's bindings stay
  ## SEPARATE SURFACES, and the L5 walker already refuses `activity` /
  ## `enable` / `devEnv` inside an environment body. This is the mirror,
  ## and without it the separation held in one direction only. Measured:
  ## at the base of this milestone both shapes reached the verbatim
  ## passthrough and produced an `undeclared identifier` error -- loud,
  ## which is why this is an improvement rather than a defect fix, but
  ## it said nothing about where the declaration belongs.
  ## DOT-AWARE, for the same reason `l5RefuseDottedHeads` exists on the
  ## package body. `environment.dev:` inside a `devEnv:` body parses as
  ## `Call(DotExpr(environment, dev), StmtList)`, so an ident-only test
  ## returned early here and the statement reached the verbatim
  ## passthrough to fail as `undeclared identifier: 'environment'` --
  ## loud, but mislocated, and it is the DOTTED shape of the standing
  ## hunt's open issue. The dotted head gets the same named refusal as
  ## the bare one, since the author's mistake (wrong surface) is the
  ## same and the spelling is secondary.
  if stmt.kind notin {nnkCall, nnkCommand} or stmt.len < 1:
    return
  var head = ""
  if stmt[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    head = identText(stmt[0]).normalize
  elif stmt[0].kind == nnkDotExpr:
    # The LEFTMOST segment, walked here rather than through
    # `l5DottedPath`: that proc is declared further down the file, and a
    # forward declaration to read one ident is more machinery than the
    # loop.
    var node = stmt[0]
    while node.kind == nnkDotExpr and node.len == 2:
      node = node[0]
    if node.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      head = identText(node).normalize
  if head notin ["environment", "instanceoverrides"]:
    return
  let spelled = if head == "environment": "environment" else: "instanceOverrides"
  error(context & ": `" & spelled & "` is a PACKAGE-LEVEL declaration " &
    "and does not belong here. `Shared-Development-Services.md` §6: an " &
    "environment is \"a named set of bindings to configurables, and " &
    "nothing else\" -- it binds the configurables an activity declares " &
    "and is not a statement about which activities run, so the two stay " &
    "separate surfaces (D-SS8). Move it to the package body, beside " &
    "`devEnv:`.", l2StmtAnchor(stmt))

proc l2SeqLiteral(items: openArray[NimNode]): NimNode =
  ## ``@[a, b]`` — or ``@[]`` when empty.
  var bracket = nnkBracket.newTree()
  for item in items:
    bracket.add(item)
  nnkPrefix.newTree(ident("@"), bracket)

proc l2ActivityDefLiteral(packageName, activityName: string;
                          params: seq[L2ActivityParam];
                          config: seq[L2ActivityConfigKey];
                          bodyRepr: string): NimNode =
  ## The ``DslActivityDef`` object constructor the generated code
  ## registers. Built as AST rather than as source text so no string
  ## escaping stands between a recipe's own spelling and the record.
  var paramItems: seq[NimNode] = @[]
  for p in params:
    paramItems.add(nnkObjConstr.newTree(ident("DslActivityParamDef"),
      nnkExprColonExpr.newTree(ident("name"), newLit(p.name)),
      nnkExprColonExpr.newTree(ident("typeRepr"),
        newLit(p.typeNode.repr.strip()))))
  var configItems: seq[NimNode] = @[]
  for c in config:
    configItems.add(nnkObjConstr.newTree(ident("DslActivityConfigDef"),
      nnkExprColonExpr.newTree(ident("name"), newLit(c.name)),
      nnkExprColonExpr.newTree(ident("typeRepr"),
        newLit(c.typeNode.repr.strip())),
      nnkExprColonExpr.newTree(ident("defaultRepr"),
        newLit(if c.defaultNode == nil: "" else: c.defaultNode.repr.strip())),
      nnkExprColonExpr.newTree(ident("hasDefault"),
        newLit(c.defaultNode != nil)),
      nnkExprColonExpr.newTree(ident("description"), newLit(c.description))))
  nnkObjConstr.newTree(ident("DslActivityDef"),
    nnkExprColonExpr.newTree(ident("packageName"), newLit(packageName)),
    nnkExprColonExpr.newTree(ident("activityName"), newLit(activityName)),
    nnkExprColonExpr.newTree(ident("params"), l2SeqLiteral(paramItems)),
    nnkExprColonExpr.newTree(ident("config"), l2SeqLiteral(configItems)),
    nnkExprColonExpr.newTree(ident("bodyRepr"), newLit(bodyRepr)))

proc l2ActivityEmission(packageName: string; stmt: NimNode): NimNode =
  ## Lower ONE ``activity <name>(...): <body>`` statement, or return
  ## ``nil`` when ``stmt`` is not one.
  let parsed = l2ActivityEntryAst(stmt)
  if not parsed.matched:
    return nil
  let params = l2ParseActivityParams(parsed.activityName, parsed.paramsNode)
  let config = l2ParseActivityConfig(parsed.activityName, parsed.body)
  var seenNames: seq[string] = @[]
  for p in params:
    if p.name.normalize in seenNames:
      error("activity `" & parsed.activityName & "`: parameter `" &
        p.name & "` is declared twice.", stmt)
    seenNames.add(p.name.normalize)
  for c in config:
    if c.name.normalize in seenNames:
      error("activity `" & parsed.activityName & "`: `config:` key `" &
        c.name & "` collides with a constructor parameter of the same " &
        "name. The two become one parameter list on the generated entry " &
        "point, so the names have to be distinct.", stmt)
    seenNames.add(c.name.normalize)

  # Record for the ``enable`` walker's diagnostics.
  let key = l2ActivityKey(packageName, parsed.activityName)
  var configNames: seq[string] = @[]
  for c in config:
    configNames.add(c.name)
  var paramNames: seq[string] = @[]
  for p in params:
    paramNames.add(p.name)
  l2ActivityConfigKeyNames[key] = configNames
  l2ActivityParamNames[key] = paramNames

  # The entry point. Parameters first, then one per ``config:`` key
  # carrying that key's default — which is what makes ``enable`` a plain
  # Nim call with named arguments and nothing more.
  var formal = nnkFormalParams.newTree(newEmptyNode())
  for p in params:
    formal.add(nnkIdentDefs.newTree(ident(p.name), p.typeNode.copyNimTree(),
      newEmptyNode()))
  for c in config:
    # Shared-Development-Services L5 (§6): a key WITH a default reads
    # its default through `environmentBoundValue`, so the selected
    # environment's binding is what the parameter defaults to.
    #
    # A parameter default is evaluated at CALL time, and the `enable`
    # call that invokes this entry point runs long after module init --
    # which is where `applySelectedEnvironment` ran. So the ordering
    # that makes the binding visible is Nim's own evaluation order and
    # not new staging, which is §6.1's requirement.
    #
    # An `enable` override that passes the argument explicitly still
    # wins, because the default is then not evaluated at all. That is
    # the owner overriding its own environment at its own enable site
    # and is not the §6.6 case -- a CONSUMER's attempt to bind is
    # refused at the binding site, in the consumer's own compilation.
    #
    # A key WITHOUT a default is a REQUIRED configurable: the slot
    # exists and has NO SEED, and §6 gives it TWO routes to a value --
    # an `environment` binding, or an argument at this `enable` site.
    # So its parameter default reads the slot through
    # `requiredConfigurableValue`, which hands back a satisfied value
    # and refuses an unsatisfied one BY NAME, naming both routes. An
    # `enable` that passes the argument explicitly never evaluates the
    # default at all, so the second route is unaffected.
    #
    # L3's `InterfaceConfigKey.hasDefault` still reports `false` for
    # such a key, because that is read from `c.defaultNode` and this
    # change does not touch `l2ParseActivityConfig`. "Required" and
    # "has a default" remain the same distinction; what changed is that
    # required no longer means SLOTLESS.
    #
    # A key whose TYPE the configurable lane does not carry gets
    # `newEmptyNode()` and stays required at the Nim level, because
    # there is genuinely no slot for it -- the separate refusal
    # `m2TypeReprIsSupportedScalar` governs, and the two are not
    # merged.
    #
    # Shared-Development-Services L8: AN ORDERED COLLECTION WITH NO
    # DEFAULT IS NOT REQUIRED, so it does not take the
    # `requiredConfigurableValue` route. Its slot is seeded `@[]` by
    # `recordContributionPoint` and its parameter default reads the
    # FOLD through `environmentBoundValue` -- which is what makes a
    # consumer's contribution reach the service's argv at the enable
    # site. Taking the required route instead would raise
    # `EDslPortUnsatisfiedRequired` on every workspace where no
    # consumer has contributed, i.e. would make an owner unable to
    # start its own service alone.
    let default =
      if c.defaultNode == nil and
         m2TypeReprIsOrderedCollection(c.typeNode.repr):
        newCall(bindSym"environmentBoundValue",
          newLit(packageName & "." & parsed.activityName & "." & c.name),
          parseExpr("newSeq[string]()"))
      elif c.defaultNode == nil:
        if m2TypeReprIsSupportedScalar(c.typeNode.repr):
          parseExpr("requiredConfigurableValue[" & c.typeNode.repr & "](" &
            escForCode(packageName) & ", " &
            escForCode(packageName & "." & parsed.activityName & "." &
              c.name) & ", " &
            escForCode(parsed.activityName) & ", " &
            escForCode(c.name) & ")")
        else:
          newEmptyNode()
      else:
        let keyLit = newLit(packageName & "." & parsed.activityName & "." &
          c.name)
        let declared = c.defaultNode.copyNimTree()
        newCall(bindSym"environmentBoundValue", keyLit, declared)
    formal.add(nnkIdentDefs.newTree(ident(c.name), c.typeNode.copyNimTree(),
      default))

  let procBody = newStmtList()
  procBody.add(l2MemberCheckStmts(parsed.activityName, params, parsed.body))
  for entry in parsed.body:
    if l2IsHeadNamed(entry, "config"):
      continue
    if l2IsHeadNamed(entry, "service"):
      let emission = m5ServiceEmission(packageName, entry)
      if emission != nil:
        procBody.add(emission)
        continue
      error("activity `" & parsed.activityName & "`: `" &
        entry.repr.strip() & "` is not a recognised `service <name>:` " &
        "declaration. `Package-Model.md` §Collections: a service is " &
        "`service <name>:` with a block body of setters. " &
        l2NoSilentDropRule, l2StmtAnchor(entry))
    l2RefuseL5HeadsHere("activity `" & parsed.activityName & "`", entry)
    procBody.add(entry.copyNimTree())
  if procBody.len == 0:
    procBody.add(nnkDiscardStmt.newTree(newEmptyNode()))

  let procDef = nnkProcDef.newTree(
    ident(l2ActivityEntryProcName(parsed.activityName)),
    newEmptyNode(), newEmptyNode(), formal,
    newEmptyNode(), newEmptyNode(), procBody)
  procDef.copyLineInfo(stmt)

  let nameLit = newLit(parsed.activityName)
  let defLiteral = l2ActivityDefLiteral(packageName, parsed.activityName,
    params, config, parsed.body.repr)
  result = newStmtList(
    procDef,
    # The name goes through the SAME ``proc activity(name: string)`` the
    # string form uses, so a parameterised activity is selectable by the
    # dev-env activity gate exactly like a bare one and there is one
    # registry of names rather than two.
    quote do:
      activity(`nameLit`),
    quote do:
      registerActivityDeclaration(`defLiteral`))

proc l2EnableEntryAst(stmt: NimNode): tuple[matched: bool;
    activityName: string; argsNode: NimNode; overrides: NimNode] =
  ## Recognise ``enable <name>``, ``enable <name>(<arg> = <expr>, ...)``
  ## and either of those with a ``: <overrides>`` block.
  result.argsNode = nil
  result.overrides = nil
  if stmt.len notin {2, 3}:
    return
  if not l2IsHeadNamed(stmt, "enable"):
    return
  if stmt.len == 3:
    if stmt[2].kind != nnkStmtList:
      return
    result.overrides = stmt[2]
  let headNode = stmt[1]
  case headNode.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    result.matched = true
    result.activityName = identText(headNode)
  of nnkCall:
    if headNode.len < 1 or
        headNode[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      return
    result.matched = true
    result.activityName = identText(headNode[0])
    result.argsNode = headNode
  of nnkObjConstr:
    # ``enable myApi(db: mainDb)`` — a ``:`` where the spec writes ``=``.
    # Refused rather than passed on, because as an object constructor it
    # would be reported against a type the author never named.
    error("`enable " & identText(headNode[0]) & "(...)` passes its " &
      "arguments with `=`, not `:`: `enable " & identText(headNode[0]) &
      "(db = mainDb, assets = assets)`. `Package-Model.md` " &
      "§\"Systems And Enable Composition\": \"`enable myApi(db = mainDb, " &
      "assets = assets): <overrides>` is a typed call into the " &
      "activity's generated entry point.\"", l2StmtAnchor(stmt))
  else:
    discard

proc l2EnableOverridePair(activityName: string; stmt: NimNode):
    tuple[name: string; value: NimNode] =
  ## One override statement → its key and value. ``Package-Model.md``:
  ## "The override body uses the function-call setter form (``port
  ## 9090``)". The assignment form (``port = 9090``) is accepted too,
  ## because it is what an author who has just written
  ## ``db = mainDb`` three characters earlier will reach for.
  if stmt.kind in {nnkCommand, nnkCall, nnkAsgn, nnkExprEqExpr} and
      stmt.len == 2 and stmt[0].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    return (name: identText(stmt[0]), value: stmt[1].copyNimTree())
  error("`enable " & activityName & "`: `" & stmt.repr.strip() &
    "` is not an override. Each line of the override body sets ONE " &
    "`config:` key: `<key> <value>` (or `<key> = <value>`). " &
    l2NoSilentDropRule, l2StmtAnchor(stmt))

proc l2EnableEmission(packageName: string; stmt: NimNode): NimNode =
  ## Lower ONE ``enable ...`` statement to the typed call into the
  ## activity's generated entry point, or return ``nil`` when ``stmt`` is
  ## not one.
  let parsed = l2EnableEntryAst(stmt)
  if not parsed.matched:
    return nil
  let key = l2ActivityKey(packageName, parsed.activityName)
  let known = l2ActivityConfigKeyNames.hasKey(key)
  if not known:
    # The generated entry point is a proc nested in this package's
    # `devEnv<Pkg>Package()`, so an `enable` can only reach an activity
    # this package declared ABOVE it. Nim would report the generated
    # proc's name (`reproActivity_api`), which names an identifier the
    # author never wrote.
    var declared: seq[string] = @[]
    for registryKey in l2ActivityConfigKeyNames.keys:
      let parts = registryKey.split("\x1f")
      if parts.len == 2 and parts[0] == packageName:
        declared.add(parts[1])
    let available =
      if declared.len == 0:
        "this package declares no constructor-shaped activities"
      else:
        "declared above in this `devEnv:` block: " & declared.join(", ")
    error("`enable " & parsed.activityName & "`: package `" & packageName &
      "` declares no activity named `" & parsed.activityName &
      "` above this line. " & available & ". `Package-Model.md` " &
      "§\"Systems And Enable Composition\": `enable` is \"a typed call " &
      "into the activity's generated entry point\", so the declaration " &
      "has to come first. (A bare `activity \"<name>\"` declares a NAME " &
      "only and has no entry point to enable.)", l2StmtAnchor(stmt))
  let call = newCall(ident(l2ActivityEntryProcName(parsed.activityName)))
  if parsed.argsNode != nil:
    for i in 1 ..< parsed.argsNode.len:
      let child = parsed.argsNode[i]
      if child.kind == nnkExprEqExpr and child.len == 2:
        call.add(nnkExprEqExpr.newTree(child[0].copyNimTree(),
          child[1].copyNimTree()))
      else:
        call.add(child.copyNimTree())
  if parsed.overrides != nil:
    var seen: seq[string] = @[]
    for entry in parsed.overrides:
      if entry.kind in {nnkCommentStmt, nnkEmpty}:
        continue
      if entry.kind == nnkDiscardStmt:
        continue
      let pair = l2EnableOverridePair(parsed.activityName, entry)
      if pair.name.normalize in seen:
        error("`enable " & parsed.activityName & "`: `" & pair.name &
          "` is set twice in the override body.", l2StmtAnchor(entry))
      seen.add(pair.name.normalize)
      if known:
        var isConfigKey = false
        for name in l2ActivityConfigKeyNames[key]:
          if name.normalize == pair.name.normalize:
            isConfigKey = true
            break
        if not isConfigKey:
          var isParam = false
          for name in l2ActivityParamNames[key]:
            if name.normalize == pair.name.normalize:
              isParam = true
              break
          let available =
            if l2ActivityConfigKeyNames[key].len == 0:
              "activity `" & parsed.activityName &
                "` declares no `config:` keys at all"
            else:
              "available `config:` keys: " &
                l2ActivityConfigKeyNames[key].join(", ")
          if isParam:
            error("`enable " & parsed.activityName & "`: `" & pair.name &
              "` is a CONSTRUCTOR PARAMETER of activity `" &
              parsed.activityName & "`, not a `config:` key, so it is " &
              "passed in the parentheses rather than in the override " &
              "body: `enable " & parsed.activityName & "(" & pair.name &
              " = ...)`. " & available & ".", l2StmtAnchor(entry))
          error("`enable " & parsed.activityName & "`: activity `" &
            parsed.activityName & "` has no `config:` key named `" &
            pair.name & "`. " & available & ".", l2StmtAnchor(entry))
      call.add(nnkExprEqExpr.newTree(ident(pair.name), pair.value))
  call.copyLineInfo(stmt)
  result = newStmtList(call)

proc l2LowerDevEnvActivities(packageName: string; body: NimNode): NimNode =
  ## Rewrite a ``devEnv:`` body's ``activity <name>(...):`` declarations
  ## and ``enable ...`` call sites. Every other statement — including
  ## ``activity "<name>"``, ``servicePlaceholder``, ``useTool``,
  ## ``setEnv`` and ordinary Nim — is copied through verbatim.
  result = newStmtList()
  if body.kind != nnkStmtList:
    return body
  for stmt in body:
    let activityEmission = l2ActivityEmission(packageName, stmt)
    if activityEmission != nil:
      result.add(activityEmission)
      continue
    let enableEmission = l2EnableEmission(packageName, stmt)
    if enableEmission != nil:
      result.add(enableEmission)
      continue
    l2RefuseL5HeadsHere("`devEnv:` of package `" & packageName & "`", stmt)
    result.add(stmt.copyNimTree())


# ---------------------------------------------------------------------------
# Shared-Development-Services L5 — `environment <name>:`, and §6.6's line.
#
# `Shared-Development-Services.md` §6 is the authority and its first
# sentence is the entire specification of the `environment` head:
#
#   "An environment is a named set of bindings to configurables, and
#    nothing else."
#
# So the walker below accepts exactly ONE statement shape in the body --
# `<configurable> = <expression>` -- and REFUSES everything else by
# name, with the place the refused thing belongs. "And nothing else" is
# not a stylistic preference: §6.2 records that putting these bindings
# in a `system` "types correctly and it is still wrong", and §6.3
# records the two drafts that were wrong. A body that also accepted a
# host, a topology or an activity list would be the second of those
# drafts wearing a different head.
#
# TWO HEADS LAND HERE, AND THEY ARE DELIBERATELY SEPARATE:
#
#   * `environment <name>:` -- the OWNER's binding set. §6.
#   * `instanceOverrides <package>.<service>:` -- the CONSUMER's two
#     permitted statements, §6.6's left column: the instance SCOPE
#     (§4.1) and the consumer's OWN LEASE POLICY (which
#     `Ephemeral-State-Leases.md` §2.2 already allows per consuming
#     edge). A SEPARATE head and not a section of `environment`
#     precisely because the gate says an environment binds configurables
#     AND NOTHING ELSE; folding a scope override into it would make that
#     false. It resolves nothing, takes no lease and starts nothing --
#     L6's attach decision and L7's resolver read the record.
#
# D-SS8 is resolved by that split and by what the walker refuses:
# `devEnv:` and an environment's bindings stay SEPARATE SURFACES.
# `devEnv:` says which activities this project runs; an environment says
# what the configurables those activities declare are bound to. The
# walker refuses an `activity` or `enable` statement inside an
# `environment` body by name, and refuses a binding inside `devEnv:`
# nowhere -- because `devEnv:` never accepted one.
# ---------------------------------------------------------------------------

const
  l5EnvironmentRule = "`Shared-Development-Services.md` §6: \"An " &
    "environment is a named set of bindings to configurables, and " &
    "nothing else.\" The body is `<configurable> = <expression>` lines " &
    "and nothing else -- `environment <name>:` is not a machine, has " &
    "no topology and declares no activities (§6.2)."
  l5OwnershipRule = "`Shared-Development-Services.md` §6.6: \"a " &
    "consumer may decide what affects only itself; the environment " &
    "binds everything that defines the instance.\" A consumer may " &
    "override the instance SCOPE and its own LEASE POLICY -- write " &
    "those in `instanceOverrides <package>.<service>:` -- and may not " &
    "bind any configurable the environment owns."
  l5NoSilentDropRule = "An unrecognised spelling here is REFUSED " &
    "rather than dropped: a binding that is accepted and then not in " &
    "force is indistinguishable from support for it, and for an " &
    "ENVIRONMENT the value that goes missing is the one deciding which " &
    "issuer a developer talks to (§6.4). Same defect the `args` setter " &
    "and the `on <trigger>:` walker had before L1."
  l5OverridesRule = "`Shared-Development-Services.md` §6.6 and §4.1: " &
    "`instanceOverrides <package>.<service>:` takes `scope project` | " &
    "`workspace` | `user` | `system`, and `lease keep` | `immediate` | " &
    "`delayed(<seconds>)`. Those two are the whole of what a consumer " &
    "may say about somebody else's instance."

type
  L5ConfigDecl = object
    ## One configurable an `environment` block may bind, as the owner
    ## declared it.
    qualifier: string
      ## The declaring activity; "" for a package-level `config:` key.
    name: string
    typeNode: NimNode
    defaultNode: NimNode
      ## `nil` when the key has no default.
    paramIndex: int
      ## This key's POSITION in the generated entry point's parameter
      ## list, or `-1` for a package-level key (which has no entry
      ## point). `l2ActivityEmission` emits the constructor parameters
      ## first and then one parameter per `config:` key in declaration
      ## order, so the position is
      ## `<constructor parameter count> + <index among the config keys>`
      ## -- and that is what lets the required-key check decide a
      ## POSITIONAL `enable` argument, which carries no name.
    positionalUndecidable: bool
      ## True when the declaring activity's parameter list makes the
      ## "argument at list index `i` binds the parameter at index `i`"
      ## rule unsound, which in this tree means exactly one thing: a
      ## `varargs` constructor parameter, whose greedy matching moves
      ## every later parameter's position with the argument count. The
      ## check then says nothing about a positional site for this
      ## activity -- see `l5ParamsDefeatPositionalIndexing` for the
      ## measurement and `l5RefuseUnsatisfiableRequiredKeys` for the
      ## consequence.

  L5Binding = object
    key: string
    qualifier: string
    name: string
    valueNode: NimNode
    anchor: NimNode

proc l5DottedPath(node: NimNode; parts: var seq[string]): bool =
  ## Flatten `a.b.c` into `@["a", "b", "c"]`. False when `node` is not a
  ## pure ident-or-dot path -- a call, an index, a literal.
  ##
  ## THE DOTTED SHAPE IS WHY THIS PROC IS SHARED BY EVERY L5 READING.
  ## The standing hunt's one open defect is that a DOTTED HEAD
  ## (`identity.stable "x"`) was dropped in silence by L4's setter loop,
  ## and an L5 binding path is dotted BY DESIGN (`sso.externalDomain`).
  ## So every spelling that reaches a binding or a head goes through
  ## this one reading, and a path it cannot flatten is refused rather
  ## than skipped.
  case node.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    parts.add(identText(node))
    result = true
  of nnkDotExpr:
    if node.len != 2:
      return false
    if not l5DottedPath(node[0], parts):
      return false
    result = l5DottedPath(node[1], parts)
  else:
    result = false

proc l5ParamsDefeatPositionalIndexing(params: seq[L2ActivityParam]): bool =
  ## Whether this activity's CONSTRUCTOR parameters make Nim's
  ## positional-argument rule undecidable at expansion.
  ##
  ## Nim's rule, measured rather than assumed (nim 2.3.1, x86_64-linux):
  ## an argument at call-argument-list index `i` binds the parameter at
  ## index `i`, whatever named arguments sit beside it. `f(a = 1, "y")`
  ## binds `"y"` to the SECOND parameter, and `f(b = "x", "pos")` is
  ## refused with "positional param was already given as named param".
  ## So a name is not needed to decide where a positional lands -- an
  ## INDEX is, and the macro has it, because it emitted the parameter
  ## list.
  ##
  ## `varargs` is the one shape that breaks it, and it breaks it in
  ## BOTH directions -- measured, which is why this is a skip and not a
  ## refusal. For `g2(extras: varargs[string], a = "A", b = "B")`,
  ## `g2("x", "y")` binds `"y"` to **b** and leaves `a` at its default;
  ## `g2("x", "y", "z")` binds `a = "y"`, `b = "z"`. So an index rule
  ## would call `a` SUPPLIED when nothing supplied it (an
  ## under-refusal, which hides) and `b` UNSUPPLIED when something did
  ## (an over-refusal, which refuses a working recipe). Neither is
  ## acceptable, so a positional site on a `varargs` activity is not
  ## decided here at all.
  ##
  ## Not a hypothetical in this tree: `activity sso(extras:
  ## varargs[string])` with `enable sso("a")` compiles today with
  ## `externalDomain` required and unsupplied, which is the fixture
  ## `l5VarargsPkg` in
  ## `libs/repro_project_dsl/tests/l5_environment_argv_fixtures.nim`.
  ## A required `config:` key behind such a parameter is left to the
  ## resolution-time refusal, and that refusal is asserted on that
  ## fixture rather than assumed.
  ##
  ## The test is on the type's `repr` and not on a resolved type,
  ## because at expansion the type is still an unsemchecked node the
  ## author wrote (`l2ParseActivityParams` splices it verbatim and never
  ## interprets it). An alias that resolves to `varargs` would be missed
  ## -- an UNDER-detection in the direction of this proc's conservative
  ## answer, and the resolution refusal still covers it.
  for p in params:
    for word in p.typeNode.repr.split({' ', '\t', '[', ']', ',', '(', ')',
                                       '.', ';'}):
      if word.len > 0 and word.normalize == "varargs":
        return true
  false

proc l5CollectDeclaredConfigurables(sectionStmts: NimNode):
    seq[L5ConfigDecl] =
  ## Every configurable THIS package declares, from both authoring
  ## surfaces: the package-level `config:` block, and each
  ## `devEnv:`/`activity ...:` body's `config:` block.
  ##
  ## ONE READING PER SURFACE, and each is the one another walker already
  ## uses: `collectM2ConfigEntries` for the package level (the same proc
  ## `emitM2ConfigDefaults` reads, so a key an environment may bind is
  ## exactly a key that got a `recordConfigDefault`) and
  ## `l2ParseActivityConfig` for the activity level (the same proc
  ## `l2ActivityEmission` reads, so the binding-target set and the
  ## generated parameter list cannot disagree). L4's evidence drawer
  ## names the alternative and why it is wrong: "a second reading would
  ## let the interface artifact report an identity the lowering never
  ## recorded".
  for stmt in sectionStmts:
    let head = calleeName(stmt).normalize
    if head == "config" and stmt.len >= 2 and stmt[^1].kind == nnkStmtList:
      for entry in collectM2ConfigEntries(stmt[^1]):
        result.add(L5ConfigDecl(qualifier: "", name: entry.name,
          typeNode: entry.typeNode, defaultNode: entry.defaultNode,
          paramIndex: -1, positionalUndecidable: false))
    elif head == "devenv" and stmt.len >= 2 and stmt[^1].kind == nnkStmtList:
      for devStmt in stmt[^1]:
        let parsed = l2ActivityEntryAst(devStmt)
        if not parsed.matched:
          continue
        # THE SAME READING `l2ActivityEmission` USES for the generated
        # parameter list, which is what makes `paramIndex` the position
        # an `enable` site's positional argument actually lands on.
        # A second reading of the parameter list here would be the
        # asymmetry this milestone's review found twice.
        let params = l2ParseActivityParams(parsed.activityName,
          parsed.paramsNode)
        let undecidable = l5ParamsDefeatPositionalIndexing(params)
        var configIndex = 0
        for key in l2ParseActivityConfig(parsed.activityName, parsed.body):
          result.add(L5ConfigDecl(qualifier: parsed.activityName,
            name: key.name, typeNode: key.typeNode,
            defaultNode: key.defaultNode,
            paramIndex: params.len + configIndex,
            positionalUndecidable: undecidable))
          inc configIndex

proc l5ContainsNormalized(names: openArray[string]; name: string): bool =
  ## Membership under NIM IDENTIFIER EQUALITY, not byte equality.
  ##
  ## WHY EVERY L5 NAME TEST GOES THROUGH THIS. Nim identifiers are case-
  ## and underscore-insensitive after the first character, so
  ## `desktopKind`, `desktopkind` and `desktop_kind` are ONE identifier
  ## -- and `l5FindDecl` already resolves a binding path that way
  ## (`.normalize` on BOTH sides). A guard beside it that compared the
  ## author's spelling VERBATIM was therefore false for every
  ## alternative spelling of the same name, while the resolution it
  ## guards still succeeded: the guard was skipped, `l5FindDecl` mapped
  ## the alternative spelling onto the declared key, and the binding was
  ## accepted and applied. Measured on the variant guard before this
  ## existed: `desktopKind = @[l5dkB]` was refused and `desktopkind =
  ## @[l5dkB]` / `desktop_kind = @[l5dkB]` compiled clean.
  ##
  ## That is the same asymmetry `l5HeadName` carried for
  ## `instanceOverrides` (one normalized side against a camelCase
  ## literal), reached from the other direction. One helper, so a new
  ## name test cannot reintroduce it by writing `in` or `notin`.
  let wanted = name.normalize
  for candidate in names:
    if candidate.normalize == wanted:
      return true
  false

proc l5CollectVariantNames(sectionStmts: NimNode): seq[string] =
  ## Every `config:` entry of this package that is a VARIANT -- declared
  ## `variant <name>: T = default` or tagged with a `## @variant` doc
  ## directive.
  ##
  ## Read with the SAME helpers `collectM2ConfigEntries` uses to EXCLUDE
  ## them, so the two lists are complements by construction rather than
  ## by two readings that could overlap or leave a gap.
  ##
  ## It exists for the diagnostic alone, and the diagnostic is D-SS6's
  ## resolution made legible: an environment is NOT a variant and does
  ## not bind one. Without this, binding a variant was refused as "this
  ## package declares no `config:` key for it" -- true, and it sends the
  ## author looking for a missing declaration that is in fact right
  ## there on the next line.
  # The THIRD spelling, and the one `collectM2ConfigEntries` does NOT
  # exclude: a plain `config:` key with a separate top-level
  # `variant <name>:` arm block over it (M9.E). That key reaches
  # `recordConfigDefault` like any other, so without this it would be
  # bindable from an environment -- and it is the one spelling a real
  # recipe in this repository uses (`t_dsl_variant_uses.nim`). Named
  # here so all three spellings answer the same way.
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "variant":
      continue
    if stmt.len < 2 or stmt[1].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      continue
    let name = identText(stmt[1])
    if not l5ContainsNormalized(result, name):
      result.add(name)
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "config":
      continue
    if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
      continue
    var pendingDoc = ""
    for entry in stmt[^1]:
      if entry.kind == nnkCommentStmt:
        if pendingDoc.len > 0: pendingDoc.add("\n")
        pendingDoc.add(entry.strVal)
        continue
      # The name is read from `entry[0]` rather than from
      # `m2ConfigEntryAst(entry).name`, and the difference is not
      # cosmetic: `m2ConfigEntryAst` matches only the PLAIN
      # `name: T = default` shape, so for the explicit inner spelling
      # (`buildKind:` / `variant string = "debug"`) it answers
      # `matched=false` and the name would never be collected -- which
      # is how the explicit spelling slipped past the first version of
      # this proc, measured.
      if entry.kind != nnkCall or entry.len != 2 or
          entry[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted} or
          entry[1].kind != nnkStmtList or entry[1].len != 1:
        pendingDoc = ""
        continue
      let inner = entry[1][0]
      let isVariant = m2EntryIsExplicitVariant(inner) or
        m2EntryHasVariantDocDirective(pendingDoc)
      pendingDoc = ""
      let name = identText(entry[0])
      if isVariant and not l5ContainsNormalized(result, name):
        result.add(name)

proc l5DeclaredKeyNames(decls: openArray[L5ConfigDecl]): seq[string] =
  for decl in decls:
    if decl.qualifier.len == 0:
      result.add(decl.name)
    else:
      result.add(decl.qualifier & "." & decl.name)

proc l5FindDecl(decls: openArray[L5ConfigDecl];
                qualifier, name: string): int =
  result = -1
  for i, decl in decls:
    if decl.qualifier.normalize == qualifier.normalize and
        decl.name.normalize == name.normalize:
      return i

proc l5ActivityIsDeclared(decls: openArray[L5ConfigDecl];
                          qualifier: string): bool =
  for decl in decls:
    if decl.qualifier.len > 0 and
        decl.qualifier.normalize == qualifier.normalize:
      return true
  false

proc l5HeadName(stmt: NimNode; headWord: string): bool =
  ## Whether `stmt` is the `headWord` declaration head at all, refusing
  ## the DOTTED spelling (`environment.dev:`) by name on the way past.
  ##
  ## `environment.dev:` parses as `Call(DotExpr(environment, dev),
  ## StmtList)`, whose callee is not an ident, so a `calleeName`-style
  ## test answers "" and the statement falls through to the
  ## preserved-Nim bucket to fail as an undeclared identifier a long way
  ## from the mistake. The standing hunt's one open defect is exactly
  ## this shape on a service setter, so L5's heads check for it first.
  if stmt.kind notin {nnkCall, nnkCommand} or stmt.len < 1:
    return false
  let callee = stmt[0]
  if callee.kind == nnkDotExpr:
    var parts: seq[string] = @[]
    if l5DottedPath(callee, parts) and parts.len > 1 and
        parts[0].normalize == headWord.normalize:
      error("`" & headWord & "` is a declaration head, not a member: `" &
        callee.repr.strip() & "` writes the name with a DOT. Write `" &
        headWord & " " & parts[1 .. ^1].join(".") & ":` instead. " &
        l5NoSilentDropRule, l2StmtAnchor(callee))
    return false
  if callee.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
    return false
  # `.normalize` on BOTH sides. `headWord` is spelled as the author
  # writes it (`instanceOverrides`) because every refusal message quotes
  # it, and `normalize` lowercases -- so comparing one normalized side
  # against a camelCase literal answered false for every
  # `instanceOverrides` block and the head fell through to the
  # preserved-Nim bucket. Found by this milestone's own test, which is
  # why the test asserts on the RECORD and not on an exit code.
  identText(callee).normalize == headWord.normalize

proc l5RequireHeadArity(stmt: NimNode; headWord, rule: string) =
  ## `Call(head, name, StmtList)` -- arity three, body last. Every other
  ## arity is refused rather than read past: an argument written on a
  ## head is never semchecked, so an identifier that does not exist
  ## compiles clean, which is the defect
  ## `reprobuild-pm/issues/2026-10-08-activity-config-head-arguments-
  ## are-silently-dropped.md` records on the `config:` head.
  if stmt.len == 2 and stmt[1].kind == nnkStmtList:
    error("`" & headWord & ":` needs a NAME: `" & headWord &
      " <name>:` with a block body. " & rule, l2StmtAnchor(stmt))
  if stmt.len == 2:
    error("`" & headWord & " " & stmt[1].repr.strip() &
      "` needs a block body. " & rule, l2StmtAnchor(stmt))
  if stmt.len < 2:
    error("`" & headWord & "` needs a name and a block body. " & rule,
      l2StmtAnchor(stmt))
  if stmt[^1].kind != nnkStmtList:
    error("`" & headWord & " " & stmt[1].repr.strip() &
      "` needs a block body. " & rule, l2StmtAnchor(stmt))
  if stmt.len > 3:
    var extras: seq[string] = @[]
    for i in 2 ..< stmt.len - 1:
      extras.add(stmt[i].repr.strip())
    error("`" & headWord & " " & stmt[1].repr.strip() &
      "` takes exactly one name, and `" & extras.join(", ") &
      "` is also written on its head. " & rule & " " &
      l5NoSilentDropRule, l2StmtAnchor(stmt[2]))

proc l5EnvironmentName(stmt: NimNode): string =
  ## The environment's name, refusing every spelling that is not a bare
  ## identifier. A STRING LITERAL is refused BY NAME because it is the
  ## plausible slip -- `activity "<name>"` is a real spelling one line
  ## away -- and because §6's example writes an identifier.
  let nameNode = stmt[1]
  if nameNode.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    return identText(nameNode)
  if nameNode.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("`environment " & nameNode.repr.strip() & ":` names its " &
      "environment with a STRING. Write `environment " & nameNode.strVal &
      ":` -- a bare identifier, as §6 writes it. (The quoted form is " &
      "the `activity \"<name>\"` spelling, a different declaration.)",
      l2StmtAnchor(nameNode))
  error("`environment " & nameNode.repr.strip() & ":` is not a name. " &
    "An environment's name is a bare identifier. " & l5EnvironmentRule,
    l2StmtAnchor(nameNode))
  ""

proc l5ParseEnvironmentBody(packageName, environmentName: string;
                            body: NimNode;
                            decls: seq[L5ConfigDecl];
                            variants: seq[string]): seq[L5Binding] =
  ## Read one `environment <name>:` body into its binding set, refusing
  ## everything that is not a binding and every binding whose target is
  ## not this package's to bind.
  ##
  ## THE SECOND REFUSAL IS THE MILESTONE'S POINT (the `:gate:` says so):
  ## "a consumer-side attempt to bind an environment-owned configurable
  ## failing the CONSUMER'S recipe compilation rather than producing a
  ## second instance quietly -- that negative is the milestone's point,
  ## because the permissive version of this feature passes every
  ## positive test."
  ##
  ## It fires on OWNERSHIP, not on spelling. A binding path whose first
  ## segment is neither a `config:` key of this package nor an activity
  ## this package declares names SOMEBODY ELSE's configurable, and §6.6
  ## puts that in the right column: "Bind any configurable the
  ## environment owns" is what a consumer may not do. The refusal
  ## happens in the CONSUMER's compilation because the `environment`
  ## block being walked is in the consumer's own recipe -- there is no
  ## route by which a consumer's binding of a foreign key becomes a
  ## second instance, because it never becomes anything.
  var seen: seq[string] = @[]
  for stmt in body:
    if stmt.kind in {nnkCommentStmt, nnkEmpty}:
      continue
    if stmt.kind == nnkDiscardStmt:
      continue
    if stmt.kind notin {nnkAsgn, nnkExprEqExpr}:
      # Name the three shapes an author most plausibly reaches for, each
      # with where it belongs, rather than one generic refusal. §6.2 and
      # §6.6 are the two places the wrong instinct comes from.
      let headWord = calleeName(stmt).normalize
      if headWord in ["activity", "enable", "devenv"]:
        error("environment `" & environmentName & "`: `" & headWord &
          "` does not belong in an environment body. An environment " &
          "BINDS the configurables an activity declares; which " &
          "activities run is `devEnv:`'s statement and stays a separate " &
          "surface (D-SS8). " & l5EnvironmentRule, l2StmtAnchor(stmt))
      if headWord in ["service", "system", "host", "platforms", "scope",
                      "lease", "identity"]:
        error("environment `" & environmentName & "`: `" & headWord &
          "` does not belong in an environment body. §6.2: an " &
          "environment \"is not a machine and has no topology\"; it is " &
          "a binding set. " &
          (if headWord in ["scope", "lease"]:
             "A consumer's instance scope and lease policy go in " &
             "`instanceOverrides <package>.<service>:` (§6.6). "
           else: "") & l5EnvironmentRule, l2StmtAnchor(stmt))
      error("environment `" & environmentName & "`: `" &
        stmt.repr.strip().splitLines().join(" / ") &
        "` is not a binding. " & l5EnvironmentRule & " " &
        l5NoSilentDropRule, l2StmtAnchor(stmt))
    var parts: seq[string] = @[]
    if not l5DottedPath(stmt[0], parts) or parts.len == 0:
      error("environment `" & environmentName & "`: `" &
        stmt[0].repr.strip() & "` is not a configurable path. Write " &
        "`<name> = <expression>` for a package-level `config:` key or " &
        "`<activity>.<name> = <expression>` for an activity's. " &
        l5EnvironmentRule, l2StmtAnchor(stmt))
    let available = l5DeclaredKeyNames(decls)
    let availableText =
      if available.len == 0:
        "package `" & packageName & "` declares no configurables at all"
      else:
        "package `" & packageName & "` declares: " & available.join(", ")
    # §6.6's REFUSAL, and the three spellings that reach it. The order
    # matters: the FOREIGN-PACKAGE cases are tested before the
    # unknown-key case, because a consumer's most plausible spelling is
    # the fully-qualified `<dep>.<activity>.<name>` and a diagnostic
    # about path nesting would send that author looking in the wrong
    # place entirely.
    if parts.len > 2:
      # `infra.sso.externalDomain` -- the consumer's spelling. Three or
      # more segments can only mean "somebody else's package", because
      # a configurable of THIS package is reached as `<name>` or
      # `<activity>.<name>` and never more deeply.
      error("environment `" & environmentName & "` of package `" &
        packageName & "` binds `" & parts.join(".") & "`, which names " &
        "package `" & parts[0] & "`'s configurable. A consumer may not " &
        "bind a configurable another package's environment owns, and " &
        "an environment binds only the configurables its OWN package " &
        "declares: there is one resolved configuration per `(identity, " &
        "scope, environment)` (§6.5), and a second binding of it would " &
        "be a request for a second instance. " & l5OwnershipRule & " " &
        availableText & ".", l2StmtAnchor(stmt))
    let qualifier = if parts.len == 2: parts[0] else: ""
    let name = parts[^1]
    if qualifier.len > 0 and not l5ActivityIsDeclared(decls, qualifier):
      # `sso.externalDomain` where `sso` is a DEPENDENCY's activity
      # rather than one of this package's -- the same §6.6 case reached
      # by the shorter spelling, so it gets the same refusal.
      error("environment `" & environmentName & "` of package `" &
        packageName & "` binds `" & parts.join(".") & "`, and `" &
        qualifier & "` is not an activity this package declares. An " &
        "environment binds only the configurables its OWN package " &
        "declares; `" & qualifier & "`'s belong to whoever declared " &
        "it, and its own environment binds them. " & l5OwnershipRule &
        " " & availableText & ".", l2StmtAnchor(stmt))
    if qualifier.len == 0 and l5ContainsNormalized(variants, name):
      # D-SS6, made legible at the one call site where the difference
      # bites. The membership test is `l5ContainsNormalized` and NOT
      # `name in variants`, and that is the whole of D-SS6's
      # enforcement rather than a detail: `l5FindDecl` below normalizes
      # BOTH sides, so with a verbatim test here `desktopkind` and
      # `desktop_kind` skipped this guard, were resolved onto the
      # variant's own declared key, and were ACCEPTED AND APPLIED --
      # measured, both spellings compiling clean while `desktopKind`
      # was refused. A guard that one spelling of its target walks past
      # is not a guard.
      #
      # A VARIANT is solver-participating: the solver CHOOSES
      # its value to satisfy constraints, and `--variant name=value`
      # contributes to it. An environment is SELECTED, not solved, and
      # binding a variant from one would put the selection in the SAT
      # objective where any package in the closure could move it --
      # which is §6.3's "consumer-overridable configuration" through a
      # side door.
      error("environment `" & environmentName & "` of package `" &
        packageName & "` binds `" & name & "`, which is a VARIANT " &
        "rather than a plain `config:` key. An environment does not " &
        "bind a variant: a variant is solver-participating -- the " &
        "solver chooses its value and `--variant " & name &
        "=<value>` contributes to it -- while an environment is " &
        "SELECTED. Binding one here would put the selection in the " &
        "solver's objective, where any package in the closure could " &
        "move it (D-SS6; §6.3's \"consumer-overridable " &
        "configuration\" draft). " & availableText & ".",
        l2StmtAnchor(stmt))
    let idx = l5FindDecl(decls, qualifier, name)
    if idx < 0:
      error("environment `" & environmentName & "` of package `" &
        packageName & "` binds `" & parts.join(".") &
        "`, which this package declares no `config:` key for. " &
        availableText & ". " & l5EnvironmentRule, l2StmtAnchor(stmt))
    # THE TARGET MUST HAVE A SLOT, AND THAT IS CHECKED HERE RATHER THAN
    # LEFT TO MODULE INIT. §6's ordering sentence is "the service or
    # activity declares its configurables; an environment binds them",
    # and a binding whose target was never registered as a configurable
    # can never be in force.
    #
    # ONE shape reaches this now, and it used to be two. The second --
    # an ACTIVITY `config:` key with NO DEFAULT -- WAS REFUSED HERE AND
    # IS NO LONGER, because refusing it conflated "no default" with "no
    # slot" and made `Shared-Development-Services.md`'s own worked
    # examples illegal: §6 (line 421) and §9.1 (line 646) both declare
    # `externalDomain: string` with no default and bind it from an
    # `environment` block, which is §6's whole argument -- the external
    # identity is the environment's to bind, and a hostname has no
    # sensible default. Such a key is now a REQUIRED CONFIGURABLE: a
    # slot with no seed, registered by
    # `emitL5ActivityConfigDefaults`, satisfiable from here or from
    # `enable <activity>(...)`, and refused when NOTHING can satisfy it
    # (`l5RefuseUnsatisfiableRequiredKeys`, at expansion) or when the
    # SELECTED environment does not (`requiredConfigurableValue`, at
    # resolution).
    #
    # What remains is the genuinely slot-less shape: a key whose TYPE
    # the configurable lane does not carry. `emitM2ConfigDefaults`
    # filters package-level entries through
    # `m2TypeReprIsSupportedScalar` and silently passes the rest
    # through; `collectM2ConfigEntries`, which this walker reads, does
    # NOT. So `tags: seq[string] = @["a"]` is in `decls`, has no slot,
    # and binding it used to fail inside `dsl_port_runtime.nim` as
    # `setConfigurable: unsupported type seq[string]` -- loud, but
    # pointing at a library line and saying nothing about the
    # environment, the package or the key. "No default" and
    # "unsupported type" are DIFFERENT refusals and are not merged.
    if not m2TypeReprIsSupportedScalar(decls[idx].typeNode.repr):
      error("environment `" & environmentName & "` of package `" &
        packageName & "` binds `" & parts.join(".") & "`, whose type `" &
        decls[idx].typeNode.repr.strip() & "` the configurable lane " &
        "does not carry: it carries bool / int / string / float / a " &
        "declared enum / `seq[<enum>]`. A key of any other type gets " &
        "no configurable slot, so a binding to it could never be in " &
        "force. " & l5NoSilentDropRule, l2StmtAnchor(stmt))
    let key =
      if qualifier.len == 0: packageName & "." & decls[idx].name
      else: packageName & "." & decls[idx].qualifier & "." & decls[idx].name
    if key in seen:
      error("environment `" & environmentName & "`: `" & parts.join(".") &
        "` is bound twice. One environment binds one configurable once " &
        "-- a second binding in the same set would need a merge rule " &
        "L5 deliberately does not add (§6.1).", l2StmtAnchor(stmt))
    seen.add(key)
    result.add(L5Binding(key: key, qualifier: decls[idx].qualifier,
      name: decls[idx].name, valueNode: stmt[1].copyNimTree(),
      anchor: stmt))

proc l5BindingsLiteral(bindings: openArray[L5Binding]): NimNode =
  var items: seq[string] = @[]
  for b in bindings:
    items.add("EnvironmentBindingDef(key: " & escForCode(b.key) &
      ", qualifier: " & escForCode(b.qualifier) &
      ", name: " & escForCode(b.name) &
      ", valueRepr: " & escForCode(b.valueNode.repr.strip()) &
      ", precedence: epOverride" &
      ", sourceFile: " & escForCode(b.anchor.lineInfoObj.filename) &
      ", sourceLine: " & $b.anchor.lineInfoObj.line & ")")
  parseExpr("@[" & items.join(", ") & "]")

proc l5EnvironmentEmission(packageName: string; stmt: NimNode;
                           decls: seq[L5ConfigDecl];
                           variants: seq[string];
                           seenNames: var seq[string];
                           boundKeys: var seq[string]): NimNode =
  ## Lower ONE `environment <name>:` statement, or return `nil` when
  ## `stmt` is not one.
  if not l5HeadName(stmt, "environment"):
    return nil
  l5RequireHeadArity(stmt, "environment", l5EnvironmentRule)
  let envName = l5EnvironmentName(stmt)
  if envName.normalize in seenNames:
    error("`environment " & envName & ":` is declared twice in package `" &
      packageName & "`. Two binding sets under one name would make " &
      "which issuer a developer gets depend on statement order, which " &
      "is the failure §6.4 is written about.", l2StmtAnchor(stmt))
  seenNames.add(envName.normalize)
  let bindings = l5ParseEnvironmentBody(packageName, envName, stmt[^1],
    decls, variants)
  # The keys THIS package's environments bind, accumulated across every
  # `environment` block, for `l5RefuseUnsatisfiableRequiredKeys`. Taken
  # from the bindings the walker just resolved rather than re-read from
  # the AST, so the required-key check and the emission cannot disagree
  # about what is bound.
  for b in bindings:
    if b.key notin boundKeys:
      boundKeys.add(b.key)
  let pkgLit = newLit(packageName)
  let nameLit = newLit(envName)
  let defLiteral = parseExpr("DslEnvironmentDef(packageName: " &
    escForCode(packageName) & ", name: " & escForCode(envName) &
    ", sourceFile: " & escForCode(stmt.lineInfoObj.filename) &
    ", sourceLine: " & $stmt.lineInfoObj.line & ")")
  let bindingsExpr = l5BindingsLiteral(bindings)
  let applierBody = newStmtList()
  for b in bindings:
    let keyLit = newLit(b.key)
    let valueNode = b.valueNode.copyNimTree()
    applierBody.add(quote do:
      bindEnvironmentConfigurable(`pkgLit`, `nameLit`, `keyLit`, `valueNode`))
  if applierBody.len == 0:
    applierBody.add(nnkDiscardStmt.newTree(newEmptyNode()))
  let defVar = genSym(nskVar, "l5EnvDef")
  let inner = newStmtList()
  inner.add(nnkVarSection.newTree(nnkIdentDefs.newTree(
    defVar, newEmptyNode(), defLiteral)))
  inner.add(newAssignment(nnkDotExpr.newTree(defVar, ident("bindings")),
    bindingsExpr))
  inner.add(newCall(ident("registerEnvironment"), defVar))
  inner.add(newCall(ident("registerEnvironmentApplier"), pkgLit, nameLit,
    nnkLambda.newTree(newEmptyNode(), newEmptyNode(), newEmptyNode(),
      nnkFormalParams.newTree(newEmptyNode()), newEmptyNode(),
      newEmptyNode(), applierBody)))
  result = nnkBlockStmt.newTree(newEmptyNode(), inner)
  result.copyLineInfo(stmt)

proc l5ParseOverrideTarget(stmt: NimNode):
    tuple[targetPackage, targetService: string] =
  ## `instanceOverrides <package>.<service>:` -- the head names WHOSE
  ## service, because a consumer's override is per consuming edge and an
  ## unqualified service name would be ambiguous the moment two
  ## dependencies declare one.
  var parts: seq[string] = @[]
  if not l5DottedPath(stmt[1], parts) or parts.len != 2:
    error("`instanceOverrides " & stmt[1].repr.strip() & ":` names its " &
      "target as `<package>.<service>`. " & l5OverridesRule,
      l2StmtAnchor(stmt[1]))
  (targetPackage: parts[0], targetService: parts[1])

proc l5ParseOverrideBody(targetRepr: string; body: NimNode):
    tuple[scopeDeclared: bool; scope: NimNode; leaseKind: string;
          ttl: int] =
  ## The two permitted statements of §6.6's left column, and nothing
  ## else. Everything refused here is refused BY CATEGORY: a
  ## configurable binding is the right column and says so; an identity
  ## is the right column and says so.
  result.leaseKind = "clkUnset"
  var sawLease = false
  for stmt in body:
    if stmt.kind in {nnkCommentStmt, nnkEmpty} or
        stmt.kind == nnkDiscardStmt:
      continue
    if stmt.kind in {nnkAsgn, nnkExprEqExpr}:
      error("`instanceOverrides " & targetRepr & "`: `" &
        stmt.repr.strip() & "` BINDS a configurable, and a consumer " &
        "may not. " & l5OwnershipRule, l2StmtAnchor(stmt))
    let head = calleeName(stmt).normalize
    if head == "scope":
      if result.scopeDeclared:
        error("`instanceOverrides " & targetRepr &
          "`: `scope` is declared twice.", l2StmtAnchor(stmt))
      if stmt.len != 2:
        error("`instanceOverrides " & targetRepr & "`: `" &
          stmt.repr.strip() & "` is not `scope <word>`. " &
          l5OverridesRule, l2StmtAnchor(stmt))
      let word = stmt[1]
      if word.kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
        error("`instanceOverrides " & targetRepr & "`: `scope " &
          word.repr.strip() & "` names its scope with " &
          (if word.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
             "a STRING" else: "something that is not a bare word") &
          ". " & l5OverridesRule, l2StmtAnchor(word))
      let resolved = l4ScopeFromName(identText(word))
      if not resolved.found:
        error("`instanceOverrides " & targetRepr & "`: `" &
          identText(word) & "` is not a scope; the scopes are " &
          l4ScopeSpellings() & ". " & l5OverridesRule,
          l2StmtAnchor(word))
      result.scopeDeclared = true
      result.scope = ident($resolved.scope)
      continue
    if head == "lease":
      if sawLease:
        error("`instanceOverrides " & targetRepr &
          "`: `lease` is declared twice.", l2StmtAnchor(stmt))
      if stmt.len != 2:
        error("`instanceOverrides " & targetRepr & "`: `" &
          stmt.repr.strip() & "` is not `lease <policy>`. " &
          l5OverridesRule, l2StmtAnchor(stmt))
      sawLease = true
      let policy = stmt[1]
      if policy.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
        case identText(policy).normalize
        of "keep": result.leaseKind = "clkKeep"
        of "immediate": result.leaseKind = "clkImmediate"
        of "delayed":
          error("`instanceOverrides " & targetRepr & "`: `lease " &
            "delayed` needs a ttl in seconds: `lease delayed(900)`. " &
            l5OverridesRule, l2StmtAnchor(policy))
        else:
          error("`instanceOverrides " & targetRepr & "`: `" &
            identText(policy) & "` is not a lease policy. " &
            l5OverridesRule, l2StmtAnchor(policy))
        continue
      if policy.kind in {nnkCall, nnkCommand} and policy.len == 2 and
          policy[0].kind in {nnkIdent, nnkSym} and
          identText(policy[0]).normalize == "delayed":
        if policy[1].kind notin {nnkIntLit .. nnkInt64Lit}:
          error("`instanceOverrides " & targetRepr & "`: `lease " &
            "delayed(" & policy[1].repr.strip() & ")` needs an INTEGER " &
            "LITERAL of seconds. A computed ttl would make the reap " &
            "deadline a function of the build, which is the property " &
            "§4.2 refuses for an identity and the same argument " &
            "applies here. " & l5OverridesRule, l2StmtAnchor(policy[1]))
        result.leaseKind = "clkDelayed"
        result.ttl = int(policy[1].intVal)
        continue
      error("`instanceOverrides " & targetRepr & "`: `lease " &
        policy.repr.strip() & "` is not a lease policy. " &
        l5OverridesRule, l2StmtAnchor(policy))
    if head in ["identity", "args", "executable", "runtimefile", "on",
                "config"]:
      error("`instanceOverrides " & targetRepr & "`: `" & head &
        "` is the OWNER's statement about its own service, not a " &
        "consumer's about an instance of it. §6.6's right column: a " &
        "consumer may not \"Change the instance identity, or the " &
        "environment it resolved against\". " & l5OverridesRule,
        l2StmtAnchor(stmt))
    error("`instanceOverrides " & targetRepr & "`: `" &
      stmt.repr.strip().splitLines().join(" / ") &
      "` is not a recognised statement. " & l5OverridesRule & " " &
      l5NoSilentDropRule, l2StmtAnchor(stmt))

proc l5OverrideEmission(packageName: string; stmt: NimNode;
                        seenTargets: var seq[string]): NimNode =
  ## Lower ONE `instanceOverrides <package>.<service>:` statement, or
  ## return `nil` when `stmt` is not one.
  if not l5HeadName(stmt, "instanceOverrides"):
    return nil
  l5RequireHeadArity(stmt, "instanceOverrides", l5OverridesRule)
  let target = l5ParseOverrideTarget(stmt)
  let targetRepr = target.targetPackage & "." & target.targetService
  # A SECOND block for the same target is REFUSED, and this is a
  # silently-dropped construct the standing hunt found rather than a
  # hypothetical: two `instanceOverrides other.svc:` blocks compiled
  # clean, both rows were appended, and `consumerInstanceOverride`
  # returns the FIRST -- so the second author's `scope` was accepted and
  # had no effect. Measured at this milestone's own working tree before
  # the fix.
  if targetRepr.normalize in seenTargets:
    error("`instanceOverrides " & targetRepr & "` is declared twice in " &
      "package `" & packageName & "`. One consuming edge has one scope " &
      "and one lease policy; a second block would be accepted and then " &
      "ignored, because the resolver reads the first. " &
      l5NoSilentDropRule, l2StmtAnchor(stmt))
  seenTargets.add(targetRepr.normalize)
  let parsed = l5ParseOverrideBody(targetRepr, stmt[^1])
  if not parsed.scopeDeclared and parsed.leaseKind == "clkUnset":
    # A block that declares NEITHER says nothing about the instance, and
    # the row it would record is indistinguishable from no row at all --
    # so an author who wrote it and expected something got nothing.
    error("`instanceOverrides " & targetRepr & "`: the body declares " &
      "neither `scope` nor `lease`, so it says nothing about the " &
      "instance and the record it would write is indistinguishable " &
      "from no record. " & l5OverridesRule, l2StmtAnchor(stmt))
  let scopeExpr =
    if parsed.scopeDeclared: parsed.scope else: ident("sscProject")
  let code = "registerConsumerInstanceOverride(" &
    "ConsumerInstanceOverrideDef(consumerPackage: " &
    escForCode(packageName) & ", targetPackage: " &
    escForCode(target.targetPackage) & ", targetService: " &
    escForCode(target.targetService) & ", scopeDeclared: " &
    (if parsed.scopeDeclared: "true" else: "false") & ", scope: " &
    scopeExpr.repr & ", leaseKind: " & parsed.leaseKind &
    ", leaseTtlSeconds: " & $parsed.ttl & ", sourceFile: " &
    escForCode(stmt.lineInfoObj.filename) & ", sourceLine: " &
    $stmt.lineInfoObj.line & "))"
  result = parseStmt(code)
  result.copyLineInfo(stmt)

type
  L5EnableSite = object
    ## One `enable <activity> ...` call site, as the required-key check
    ## needs to see it.
    activity: string
    supplied: seq[string]
      ## The `config:` key / parameter names this site passes BY NAME,
      ## from the parenthesised arguments and from the override body.
    positionalIndices: seq[int]
      ## The PARAMETER POSITIONS this site fills POSITIONALLY. Nim binds
      ## an argument written at call-argument-list index `i` to the
      ## parameter at index `i` -- measured, see
      ## `l5ParamsDefeatPositionalIndexing` -- so a positional argument
      ## carries no name and still says exactly which parameter it
      ## supplies.
      ##
      ## This replaces a blanket `positional: bool` skip, which was a
      ## stated under-refusal and hid a genuinely unsatisfiable recipe:
      ## `activity sso(db: P16Db)` with a required `externalDomain`,
      ## `enable sso(P16DbValue)` and no environment binding the key
      ## compiled clean although the positional demonstrably lands on
      ## `db`. The arity was available the whole time, because the macro
      ## emitted the parameter list.
      ##
      ## Only the PARENTHESISED arguments can be positional: the
      ## override body's entries are lowered to named arguments by
      ## `l2EnableEmission`, so they never occupy a position.
    anchor: NimNode

proc l5CollectEnableSites(sectionStmts: NimNode): seq[L5EnableSite] =
  ## Every `enable ...` site in this package's `devEnv:` body.
  ##
  ## ONE READING, and it is the reading `l2EnableEmission` already uses:
  ## `l2EnableEntryAst` for the head and `l2EnableOverridePair` for each
  ## override line. A second reading here is exactly the asymmetry this
  ## milestone's review found twice -- a guard that disagrees with the
  ## resolver beside it -- so there is not one.
  ##
  ## `l2EnableEmission` runs FIRST (it is reached from `buildCode`,
  ## emitted before the L5 passes), so a malformed override body has
  ## already been refused by the time this walk reaches it and
  ## `l2EnableOverridePair` cannot be the thing that reports it.
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "devenv":
      continue
    if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
      continue
    for devStmt in stmt[^1]:
      let parsed = l2EnableEntryAst(devStmt)
      if not parsed.matched:
        continue
      var site = L5EnableSite(activity: parsed.activityName,
        supplied: @[], positionalIndices: @[], anchor: devStmt)
      if parsed.argsNode != nil:
        for i in 1 ..< parsed.argsNode.len:
          let child = parsed.argsNode[i]
          if child.kind == nnkExprEqExpr and child.len == 2:
            site.supplied.add(identText(child[0]))
          else:
            # `argsNode[0]` is the activity name, so the argument
            # written at `argsNode[i]` is argument `i - 1` of the
            # lowered call -- and `l2EnableEmission` copies the
            # parenthesised arguments through IN ORDER, so that index
            # is the one Nim matches against the parameter list.
            site.positionalIndices.add(i - 1)
      if parsed.overrides != nil:
        for entry in parsed.overrides:
          if entry.kind in {nnkCommentStmt, nnkEmpty, nnkDiscardStmt}:
            continue
          site.supplied.add(
            l2EnableOverridePair(parsed.activityName, entry).name)
      result.add(site)

proc l5RefuseUnsatisfiableRequiredKeys(packageName: string;
                                      sectionStmts: NimNode;
                                      decls: seq[L5ConfigDecl];
                                      boundKeys: seq[string]) =
  ## REFUSAL ONE OF TWO: a required `config:` key that NOTHING CAN EVER
  ## SATISFY (§6).
  ##
  ## A `config:` key declared without a default is REQUIRED: a slot
  ## with no seed. §6 gives it two routes to a value -- an
  ## `environment` binding, or an argument at `enable <activity>(...)`.
  ## At expansion the macro can see BOTH: every `environment` block of
  ## this package (D-SS7 puts them in the owning package) and every
  ## `enable` site. A required key that no declared environment binds
  ## and that an `enable` site does not supply can never be satisfied,
  ## whatever is selected later.
  ##
  ## "DOES NOT SUPPLY" IS DECIDED BY NAME **AND BY ARITY**, which is
  ## what this walker's first revision got wrong. It skipped any
  ## `enable` site passing a POSITIONAL argument, on the ground that
  ## which parameter a positional binds cannot be decided from a name
  ## -- true, and beside the point, because it can be decided from an
  ## INDEX and the macro emitted the parameter list. The skip hid a
  ## genuinely unsatisfiable recipe: `activity sso(db: P16Db)` with a
  ## required `externalDomain`, `enable sso(P16DbValue)` and no
  ## environment binding the key compiled clean at `nim check` although
  ## the positional demonstrably lands on `db`.
  ##
  ## THE ARITY RULE, measured on nim 2.3.1 rather than assumed: Nim
  ## binds the argument written at call-argument-list index `i` to the
  ## parameter at index `i`, whatever named arguments sit beside it
  ## (`f(a = 1, "y")` binds `"y"` to the second parameter, and
  ## `f(b = "x", "pos")` is refused as "positional param was already
  ## given as named param"). `l2ActivityEmission` emits the constructor
  ## parameters first and then one per `config:` key in declaration
  ## order, so a required key's position is
  ## `<parameter count> + <index among the config keys>`
  ## (`L5ConfigDecl.paramIndex`) and it is supplied positionally when
  ## some positional argument reaches that position.
  ##
  ## WHAT IT STILL CANNOT DECIDE, and it is one shape rather than a
  ## class: a `varargs` constructor parameter, whose greedy matching
  ## makes the index of every later parameter wrong in BOTH directions
  ## (see `l5ParamsDefeatPositionalIndexing` for the measurement).
  ## `L5ConfigDecl.positionalUndecidable` carries it, a positional site
  ## on such an activity is skipped exactly as before, and the
  ## resolution-time refusal is what catches it -- asserted on the
  ## `l5VarargsPkg` fixture rather than assumed. Everything else -- a
  ## mix of positional and named in either order, an extra positional,
  ## too few, a name repeated, a name for a parameter also given
  ## positionally -- is decided here or is Nim's own arity error.
  ##
  ## WHY THIS IS AT EXPANSION AND NOT ONLY AT RESOLUTION, which is the
  ## constraint that killed the design this replaces. A refusal that
  ## fires only when a particular environment is SELECTED leaves the
  ## defect silently inert for every build that selects another one, or
  ## none -- `l5NoSilentDropRule`'s case exactly. So the check must not
  ## depend on the selection in order to catch a key nothing can bind,
  ## and this one depends only on what is DECLARED.
  ##
  ## THE PREDICATE IS "SOME `enable` SITE LEAVES IT UNSUPPLIED", NOT
  ## "NO `enable` SITE SUPPLIES IT", and the difference is load-bearing
  ## rather than a weakening. An activity that is DECLARED and never
  ## enabled never calls its entry point, so its required key is never
  ## read and there is nothing to drop -- and that is a real shape, not
  ## a hypothetical: `l3_lift_fixtures.nim`'s `l3LiftProducer` declares
  ## `activity sso` with `externalDomain: string` precisely so the
  ## interface LIFT can carry a key whose `hasDefault` is false. The
  ## unsatisfiable case is an `enable` that reaches the read with
  ## nothing able to answer it.
  ##
  ## PACKAGE-LEVEL `config:` keys are not checked here, and the reason
  ## is that they have no `enable` route at all: "required" on that
  ## surface would mean "an environment MUST bind it", which is a
  ## different ruling and not one §6 makes. The package-level parser
  ## does not admit the no-default spelling in the first place -- it is
  ## dropped in silence, which is recorded in
  ## `reprobuild-pm/issues/2026-10-08-package-level-dsl-heads-and-
  ## bodies-silently-drop-arguments.md`, not introduced here.
  let enables = l5CollectEnableSites(sectionStmts)
  for decl in decls:
    if decl.qualifier.len == 0:
      continue
    if decl.defaultNode != nil:
      continue
    if m2TypeReprIsOrderedCollection(decl.typeNode.repr):
      # Shared-Development-Services L8: an ordered collection with no
      # default is NOT required, so it is not unsatisfiable either. Its
      # slot is seeded `@[]` and a consumer's `contribute:` -- a THIRD
      # route §6 does not enumerate, because §6 is about bindings and
      # this is a contribution -- is how members reach it.
      continue
    let key = packageName & "." & decl.qualifier & "." & decl.name
    if l5ContainsNormalized(boundKeys, key):
      continue
    var envText = "no `environment` block in package `" & packageName &
      "` binds `" & decl.qualifier & "." & decl.name & "`"
    if boundKeys.len > 0:
      envText.add(" (the environments of this package bind: ")
      var shown: seq[string] = @[]
      for bound in boundKeys:
        if bound notin shown:
          shown.add(bound)
      envText.add(shown.join(", ") & ")")
    for site in enables:
      if site.activity.normalize != decl.qualifier.normalize:
        continue
      if l5ContainsNormalized(site.supplied, decl.name):
        continue
      if decl.positionalUndecidable and site.positionalIndices.len > 0:
        # A `varargs` constructor parameter: the one shape whose
        # positional arithmetic is unsound. Left to the resolution-time
        # refusal rather than guessed at in either direction.
        continue
      if decl.paramIndex >= 0 and decl.paramIndex in site.positionalIndices:
        continue
      error("activity `" & decl.qualifier & "` of package `" &
        packageName & "` declares `config:` key `" & decl.name &
        "` WITHOUT A DEFAULT, which makes it REQUIRED -- and NOTHING " &
        "CAN EVER SATISFY IT: " & envText & ", and `enable " &
        decl.qualifier & "` here does not pass it. A required key is " &
        "satisfied one of exactly two ways (§6): bind it in an " &
        "environment of this package (`environment <name>: " &
        decl.qualifier & "." & decl.name & " = <value>`), or pass it " &
        "at this enable site (`enable " & decl.qualifier & "(" &
        decl.name & " = <value>)`). " & l5NoSilentDropRule,
        l2StmtAnchor(site.anchor))

proc emitL5ActivityConfigDefaults(packageName: string;
                                  sectionStmts: NimNode): NimNode =
  ## Register each activity `config:` key as a CONFIGURABLE, under
  ## `<package>.<activity>.<name>`, at module-init time.
  ##
  ## WHY THIS EXISTS. L2 lowers an activity's `config:` keys to
  ## PARAMETERS of the generated entry point, with the author's default
  ## as the parameter default -- which is what makes `enable` a plain
  ## Nim call. That is unchanged. What was missing is the other half of
  ## §6.1's claim about the authoring surface: "`config:` is the
  ## authoring surface; it lowers to CONFIGURABLES with declared type
  ## and merge semantics". Without a registered configurable there is
  ## nothing for §6's `sso.externalDomain = ...` to bind, and the
  ## binding would have to invent a second lane -- exactly the new
  ## precedence model the gate forbids.
  ##
  ## EVERY key of a carried type is registered, with or without a
  ## default, and the difference between them is the SEED and not the
  ## slot. A key declared `externalDomain: string` with no default is a
  ## REQUIRED configurable: `recordConfigRequired` gives it a slot
  ## holding the type's zero as a SHAPE, which is what
  ## `setConfigurableRaw`'s kind check compares a binding against, and
  ## `dslPortLookup` refuses to hand that zero back as a value.
  ##
  ## IT USED TO SKIP SUCH A KEY, AND THE ENVIRONMENT WALKER REFUSED A
  ## BINDING TO IT. That was right against what it replaced -- a key
  ## that was accepted and then silently had no slot -- and wrong as an
  ## end state: it conflated "no default" with "no slot", and it made
  ## `Shared-Development-Services.md`'s own worked examples illegal
  ## (§6 line 421 and §9.1 line 646 both declare
  ## `externalDomain: string` with no default and bind it from an
  ## `environment` block, which is §6's whole argument -- the external
  ## identity is the environment's to bind, and a hostname has no
  ## sensible default). The refusal is replaced by two narrower ones:
  ## `l5RefuseUnsatisfiableRequiredKeys` at expansion (nothing can ever
  ## satisfy this key) and `requiredConfigurableValue` at resolution
  ## (this configuration does not satisfy it).
  ##
  ## L3's `InterfaceConfigKey.hasDefault` is UNCHANGED and still reports
  ## `false` for such a key: it is read from `l2ParseActivityConfig`'s
  ## `defaultNode`, which this change does not touch.
  ##
  ## The type filter is `m2TypeReprIsSupportedScalar`, the same
  ## predicate `emitM2ConfigDefaults` applies to the package-level
  ## surface, so the slot set is ONE predicate over both surfaces and
  ## the walker's refusal is exact on both. The `when compiles(...)`
  ## guard below is kept beside it rather than as the filter: the port's
  ## configurable lane carries bool / int / string / float / enum /
  ## seq[enum], and `compiles` answers true for a qualified enum the
  ## package-level emitter skips -- a disagreement that made a slot-less
  ## key look bindable.
  result = newStmtList()
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "devenv":
      continue
    if stmt.len < 2 or stmt[^1].kind != nnkStmtList:
      continue
    for devStmt in stmt[^1]:
      let parsed = l2ActivityEntryAst(devStmt)
      if not parsed.matched:
        continue
      for key in l2ParseActivityConfig(parsed.activityName, parsed.body):
        # THE SAME TYPE PREDICATE `emitM2ConfigDefaults` USES, so the
        # slot set is ONE predicate over both authoring surfaces rather
        # than two tests that can disagree -- and so the environment
        # walker's refusal (`m2TypeReprIsSupportedScalar` at the binding
        # site) is exact on both. The `when compiles(...)` guards below
        # are kept, but they are NOT the filter: `compiles` answers true
        # for a qualified enum (`mymod.Kind`) that the package-level
        # emitter would have skipped, which is precisely the
        # disagreement that let a slot-less key look bindable.
        #
        # THE TYPE TEST COMES FIRST, AND THE DEFAULT TEST SECOND. It
        # used to be the other way round, with `defaultNode == nil`
        # answered by `continue`, so a key with no default got no slot
        # at all -- the conflation of "no default" with "no slot" this
        # change undoes.
        if not m2TypeReprIsSupportedScalar(key.typeNode.repr):
          continue
        let pkgLit = newLit(packageName)
        let nameLit = newLit(parsed.activityName & "." & key.name)
        let typeNode = key.typeNode.copyNimTree()
        if m2TypeReprIsOrderedCollection(key.typeNode.repr):
          # Shared-Development-Services L8, same statement as the
          # package-level emitter: an ordered collection is a
          # CONTRIBUTION POINT and is never REQUIRED.
          let seedNode =
            if key.defaultNode == nil: parseExpr("@[]")
            else: key.defaultNode.copyNimTree()
          result.add(quote do:
            recordContributionPoint[`typeNode`](`pkgLit`, `nameLit`,
              `seedNode`))
          continue
        if key.defaultNode == nil:
          # A REQUIRED configurable: the slot exists, with NO seed
          # (§6). Two things may satisfy it -- an `environment`
          # binding or an argument at `enable <activity>(...)` -- and
          # the slot is what makes the FIRST of those possible at all.
          # Before this, `Shared-Development-Services.md`'s own worked
          # examples (§6's and §9.1's, both `externalDomain: string`
          # bound from an `environment` block) were refused.
          result.add(quote do:
            when compiles(recordConfigRequired[`typeNode`](`pkgLit`,
                `nameLit`)):
              recordConfigRequired[`typeNode`](`pkgLit`, `nameLit`))
          continue
        let defaultNode = key.defaultNode.copyNimTree()
        result.add(quote do:
          when compiles(recordConfigDefault[`typeNode`](`pkgLit`,
              `nameLit`, `defaultNode`)):
            recordConfigDefault[`typeNode`](`pkgLit`, `nameLit`,
              `defaultNode`))

proc l5RefuseDottedHeads(body: NimNode) =
  ## Refuse `environment.dev:` / `instanceOverrides.x:` -- a DOTTED
  ## declaration head -- over the package's WHOLE body.
  ##
  ## WHY THE WHOLE BODY AND NOT THE SECTION PARTITION. A dotted head's
  ## callee is an `nnkDotExpr`, so `isKnownPackageSection` answers false
  ## and `partitionPackageBody` routes the statement to the
  ## PRESERVED-NIM bucket, where it is emitted verbatim at module top
  ## level and fails as `undeclared identifier: environment`. That is
  ## loud rather than silent -- so it is not the standing hunt's open
  ## defect, which is a drop -- but it points the author at generated
  ## code instead of at their own line and says nothing about the
  ## spelling. Measured here, and the reason this walk sees the body the
  ## partition did not keep.
  ##
  ## It walks only the top level: a dotted head nested inside a
  ## `devEnv:` or `build:` body is that walker's business, and claiming
  ## it here would refuse a legitimate `obj.field = x` in build code.
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    if stmt.kind notin {nnkCall, nnkCommand} or stmt.len < 1:
      continue
    if stmt[0].kind != nnkDotExpr:
      continue
    var parts: seq[string] = @[]
    if not l5DottedPath(stmt[0], parts) or parts.len < 2:
      continue
    # Shared-Development-Services L8 adds `contribute` to this list for
    # the identical reason: `contribute.append:` is a dotted head whose
    # callee is an `nnkDotExpr`, so it lands in the preserved-Nim bucket
    # and fails as an undeclared identifier pointing at generated code.
    for headWord in ["environment", "instanceOverrides", "contribute"]:
      if parts[0].normalize == headWord.normalize:
        error("`" & headWord & "` is a declaration head, not a member: `" &
          stmt[0].repr.strip() & "` writes the name with a DOT. Write `" &
          headWord & " " & parts[1 .. ^1].join(".") & ":` instead. " &
          l5NoSilentDropRule, l2StmtAnchor(stmt[0]))

proc emitL5Environments(packageName: string;
                        sectionStmts, body: NimNode): NimNode =
  ## Every `environment <name>:` and `instanceOverrides <...>:` section
  ## of one package body, lowered in source order.
  result = newStmtList()
  l5RefuseDottedHeads(body)
  let decls = l5CollectDeclaredConfigurables(sectionStmts)
  let variants = l5CollectVariantNames(sectionStmts)
  var seenNames: seq[string] = @[]
  var seenTargets: seq[string] = @[]
  var boundKeys: seq[string] = @[]
  for stmt in sectionStmts:
    let envEmission = l5EnvironmentEmission(packageName, stmt, decls,
      variants, seenNames, boundKeys)
    if envEmission != nil:
      result.add(envEmission)
      continue
    let overrideEmission = l5OverrideEmission(packageName, stmt,
      seenTargets)
    if overrideEmission != nil:
      result.add(overrideEmission)
  # AFTER every `environment` block has been walked, because the check
  # asks whether ANY of them binds the key. It runs whether or not this
  # package declares an environment at all: a required key with no
  # environment and an `enable` that does not pass it is the case that
  # can never be satisfied, and a package with no `environment` block
  # is where it is most likely to be written.
  l5RefuseUnsatisfiableRequiredKeys(packageName, sectionStmts, decls,
    boundKeys)
  if result.len > 0:
    let pkgLit = newLit(packageName)
    result.add(quote do:
      discard applySelectedEnvironment(`pkgLit`))

# ---------------------------------------------------------------------------
# Shared-Development-Services L8 — the `contribute:` section.
#
# §5's authoring surface: a consumer adds its own members to a shared
# service's contribution point. The operation is spelled AT THE CALL
# SITE, which is `Configurable-System.md` §Resolution's requirement
# rather than a stylistic choice -- "with the operation declared at the
# call site the engine can say which contribution was dropped and which
# one dropped it", and step 4's diagnostic names the site it reads here.
#
# SHAPE, and why this one. The operation is the OUTER block and the
# bindings are L5's `key = value` assignments, verbatim:
#
#   contribute:
#     append:
#       infra.sso.relyingParties = "isonim-site"
#       infra.sso.fixtureUsers   = @["dev@isonim.test"]
#     appendForce:
#       infra.sso.relyingParties = "must-be-registered"
#     replaceOverride:
#       infra.edge.sites = @["only-this"]
#
# Six heads, one per (operation, priority) pair this port carries, and a
# seventh spelling is a compile error naming the six. The alternative --
# `append override infra.sso.x = "y"` -- parses as a command whose
# argument is an assignment, which is exactly the ambiguous shape the L5
# walker refuses for its own bindings.
#
# WHY THE KEY IS FULLY QUALIFIED AND MAY NAME A FOREIGN PACKAGE, where
# an `environment` binding may not. §6.6 is the reason the environment
# walker refuses a foreign key: bindings are the ENVIRONMENT's and a
# consumer that could bind one "would fork the instance it is trying to
# join". A contribution is the opposite case -- §5 exists so a consumer
# can add to a collection another package declared -- so the first
# segment is the OWNING package and two- or three-segment keys are both
# accepted (`<pkg>.<name>` and `<pkg>.<activity>.<name>`, byte-identical
# to the keys `recordConfigDefault` and `emitL5ActivityConfigDefaults`
# register).
#
# WHAT IS NOT CHECKED AT COMPILE TIME, said plainly: whether the key
# exists. It cannot be -- the owning package is a different module and
# its registrations run at ITS module init. The check is at the consumer's
# module init instead, where `contributeConfigurableRaw` raises
# `EDslPortMissingKey` naming the key, and `append` at a key that is a
# SCALAR raises `EDslPortNotAContributionPoint` naming the kind. Both are
# loud; neither is a drop.
# ---------------------------------------------------------------------------

const
  L8ContributeOperationHeads* = [
    "append", "appendoverride", "appendforce",
    "replace", "replaceoverride", "replaceforce"]
    ## The closed set of operation-block heads. Asserted as a constant
    ## rather than restated in each diagnostic so the refusal and the
    ## dispatch cannot disagree about which spellings exist.

type
  L8Contribution = object
    key: string
    operation: string      ## "coAppend" / "coReplace", as emitted code
    precedence: string     ## "epSet" / "epOverride" / "epForce"
    valueNode: NimNode
    anchor: NimNode

proc l8OperationHeadIsKnown(head: string): bool =
  for h in L8ContributeOperationHeads:
    if h == head: return true
  return false

proc l8HeadsList(): string =
  var parts: seq[string] = @[]
  for h in L8ContributeOperationHeads:
    parts.add("`" & h & "`")
  parts.join(", ")

proc l8OperationFor(head: string): tuple[op, prec: string] =
  case head
  of "append": ("coAppend", "epSet")
  of "appendoverride": ("coAppend", "epOverride")
  of "appendforce": ("coAppend", "epForce")
  of "replace": ("coReplace", "epSet")
  of "replaceoverride": ("coReplace", "epOverride")
  of "replaceforce": ("coReplace", "epForce")
  else: ("", "")

proc l8DottedKeyPath(n: NimNode): seq[string] =
  ## Flatten `a.b.c` into @["a", "b", "c"]. Returns an empty seq for
  ## anything that is not a chain of bare identifiers -- a call, an
  ## index, a string literal -- so the caller refuses it by shape.
  var cursor = n
  var reversed: seq[string] = @[]
  while cursor.kind == nnkDotExpr:
    if cursor.len != 2: return @[]
    if cursor[1].kind notin {nnkIdent, nnkSym}: return @[]
    reversed.add($cursor[1])
    cursor = cursor[0]
  if cursor.kind notin {nnkIdent, nnkSym}: return @[]
  reversed.add($cursor)
  for i in countdown(reversed.high, 0):
    result.add(reversed[i])

proc l8ParseContributeBody(body: NimNode): seq[L8Contribution] =
  ## Walk one `contribute:` body. Every refusal names the author's own
  ## line and says what to write instead.
  if body.kind != nnkStmtList:
    error("`contribute:` needs an indented body of operation blocks " &
      "(" & l8HeadsList() & "), each holding `<package>.<key> = " &
      "<member or @[members]>` assignments.", body)
    return
  if body.len == 0:
    error("`contribute:` is empty. An empty contribution section is " &
      "indistinguishable from a forgotten one, so it is refused rather " &
      "than compiled into nothing. Write at least one operation block " &
      "(" & l8HeadsList() & ") or delete the section.", body)
    return
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    if stmt.kind == nnkDotExpr or
       (stmt.kind in {nnkCall, nnkCommand} and stmt.len > 0 and
        stmt[0].kind == nnkDotExpr):
      error("`contribute:` operation heads are not dotted. Write " &
        "`append:` on its own line with the assignments indented " &
        "under it, not `append.something:`. Known heads: " &
        l8HeadsList() & ".", stmt)
      continue
    if stmt.kind notin {nnkCall, nnkCommand}:
      error("`contribute:` accepts only operation blocks (" &
        l8HeadsList() & "), each with an indented body. Got a " &
        $stmt.kind & ". A bare assignment directly under " &
        "`contribute:` has no operation, and the operation is half of " &
        "what a contribution is (Configurable-System.md §\"Operation " &
        "is a SECOND axis, independent of priority\").", stmt)
      continue
    if stmt[0].kind notin {nnkIdent, nnkSym}:
      error("`contribute:` operation head must be a bare identifier; " &
        "known heads: " & l8HeadsList() & ".", stmt)
      continue
    let head = ($stmt[0]).normalize
    if not l8OperationHeadIsKnown(head):
      error("`" & $stmt[0] & "` is not a `contribute:` operation. The " &
        "operations are " & l8HeadsList() & " -- `append*` adds and is " &
        "NEVER destructive at any priority, `replace*` says \"the " &
        "value is exactly this\" and IS destructive downward " &
        "(Configurable-System.md §\"Operation is a SECOND axis\"). " &
        "There is no `add`, no `set`, no `incl` and no `remove`: " &
        "`remove` is open as D-SS9's second half and is deliberately " &
        "not spelled here.", stmt)
      continue
    if stmt.len != 2 or stmt[^1].kind != nnkStmtList:
      error("`" & head & ":` takes an indented body of `" &
        "<package>.<key> = <member or @[members]>` assignments and " &
        "NOTHING on its own line. A head argument here would be read " &
        "by nothing.", stmt)
      continue
    let opBody = stmt[^1]
    let resolved = l8OperationFor(head)
    var seen = 0
    for inner in opBody:
      if inner.kind == nnkCommentStmt:
        continue
      if inner.kind notin {nnkAsgn, nnkExprEqExpr}:
        error("inside `" & head & ":` every statement is an assignment " &
          "`<package>.<key> = <member or @[members]>`. Got a " &
          $inner.kind & ", which would contribute nothing.", inner)
        continue
      let path = l8DottedKeyPath(inner[0])
      if path.len == 0:
        error("the left-hand side of a contribution must be a dotted " &
          "configurable key made of bare identifiers, e.g. " &
          "`infra.sso.relyingParties`.", inner)
        continue
      if path.len < 2 or path.len > 3:
        error("`" & path.join(".") & "` is not a contribution key. A " &
          "key is `<package>.<name>` or " &
          "`<package>.<activity>.<name>` -- the FIRST segment names " &
          "the package that DECLARED the contribution point, which is " &
          "normally another package than this one. A one-segment key " &
          "names no owner and a four-segment key names no slot the " &
          "configurable lane registers.", inner)
        continue
      inc seen
      result.add(L8Contribution(key: path.join("."),
        operation: resolved.op, precedence: resolved.prec,
        valueNode: inner[1].copyNimTree(), anchor: inner))
    if seen == 0:
      error("`" & head & ":` contributed nothing. A declared operation " &
        "block that resolves to no contribution is the defect shape " &
        "this campaign keeps finding; write at least one assignment or " &
        "delete the block.", stmt)

proc emitL8Contributions(packageName: string;
                         sectionStmts: NimNode;
                         body: NimNode): NimNode =
  ## Emit one `contributeMembers(...)` call per contribution, over EVERY
  ## `contribute:` section in the package body.
  ##
  ## EVERY section, not the first: a second `contribute:` block is a
  ## plausible authoring shape (one per service being consumed) and
  ## honouring only the first would silently drop the rest. Asserted by
  ## a test rather than left to this comment.
  result = newStmtList()
  l5RefuseDottedHeads(body)
  if sectionStmts.kind != nnkStmtList:
    return
  for stmt in sectionStmts:
    if calleeName(stmt).normalize != "contribute":
      continue
    if stmt.len != 2 or stmt[^1].kind != nnkStmtList:
      error("`contribute:` takes an indented body and no head " &
        "argument. A name here would be read by nothing -- unlike " &
        "`environment <name>:`, a contribution section is not named.",
        stmt)
      continue
    for c in l8ParseContributeBody(stmt[^1]):
      let keyLit = newLit(c.key)
      let pkgLit = newLit(packageName)
      let precIdent = ident(c.precedence)
      let opIdent = ident(c.operation)
      let valueNode = c.valueNode.copyNimTree()
      let fileLit = newLit(c.anchor.lineInfoObj().filename)
      let lineLit = newLit(c.anchor.lineInfoObj().line)
      result.add(quote do:
        contributeMembers(`keyLit`, `pkgLit`, `precIdent`, `opIdent`,
          l8ContributionMembers(`valueNode`), `fileLit`, `lineLit`))

# ---------------------------------------------------------------------------
# Shared-Development-Services L3 — services and activities travel through
# the interface lift as typed symbols.
#
# `Shared-Development-Services.md` §3 is the authority:
#
#   "A service declared in one project is referenced in another as a
#    **typed symbol carried by the interface lift**. … the member set a
#    consumer compiles against is emitted by the producer's interface
#    artifact, the **interface fingerprint** gates rebuilds, and a
#    signature change re-lifts, re-fingerprints and invalidates
#    consumers."
#
# and `Typed-Extension-Interfaces-And-Provider-Libraries.md` §2 names this
# "a third case for the same lift", after typed tools and typed
# extensions.
#
# WHAT THIS EMITS, AND WHY AT MODULE SCOPE. Three things, all top-level,
# none of them inside `devEnv<Pkg>Package()`:
#
#   1. one handle TYPE per constructor-shaped activity,
#      `<Title><Activity>Handle`, whose fields are the activity's
#      `config:` keys (declared type, verbatim) and the services its body
#      declares;
#   2. one `<Title>PackageExports` object whose fields are every export —
#      an activity handle per activity, a `LiftedServiceHandle` per
#      PACKAGE-LEVEL service — plus `liftedExports` and one accessor proc
#      per member, which is what makes `infra.sso` a typed symbol in a
#      consuming recipe;
#   3. `registerActivityInterface` / `registerServiceInterface` calls, the
#      records `toProjectInterface` folds into
#      `ProjectInterface.publicActivities` / `publicServices`.
#
# Module scope is load-bearing for (3) and measured, not assumed:
# `buildCode` wraps its whole result in `when not
# defined(reproInterfaceMode)` and the dev-env proc additionally in `when
# defined(reproProviderMode)`, so a registration emitted inside the
# dev-env body never runs in the mode that performs the lift. It would
# have produced an interface artifact carrying no services at all, and
# nothing would have failed to compile.
#
# WHY A SEPARATE PASS RATHER THAN A SECOND RETURN VALUE FROM
# `l2LowerDevEnvActivities`. That walker's output is spliced INTO the
# guarded dev-env proc; threading a second list out of it would mean
# every caller keeping the two halves apart. A separate read-only pass
# over the same body costs one more walk and cannot leak a statement into
# the wrong guard.
#
# WHAT THE HANDLE DOES *NOT* CARRY. A config field is declared with its
# type and left at that type's default — it is NOT pre-filled with the
# `config:` default expression. `Shared-Development-Services.md` §4.6 is
# why: "A handle is obtained by a RESOLVER, never by a constructor", and
# §7 says the handle's values are staged configurables and computed
# resource attributes of a RESOLVED instance. A handle minted by this
# accessor is an address, not an instance, so pre-filling it with
# defaults would make it read like one. The defaults themselves are not
# dropped: they travel in `ActivityConfigInterfaceDef.defaultRepr` /
# `hasDefault`, which is the "`config:` surface with defaults" the L3
# gate asks the LIFT to carry, and they already reach `enable` as real
# Nim parameter defaults through L2's generated entry point. L7 is where
# a resolved handle's members hold values.
# ---------------------------------------------------------------------------

type
  L3ServiceExport = object
    ## One lifted service.
    name: string
    activityName: string
    handleType: string
    identityScope: L4ServiceIdentityScope
      ## Shared-Development-Services L4: the declared identity and scope,
      ## read by the SHARED `l4ServiceIdentityScope` -- the same proc
      ## `m5ParseServiceBody` reads them with, so the lift cannot report
      ## an identity the lowering never recorded.
    anchor: NimNode

  L3ActivityExport = object
    ## One lifted activity signature.
    name: string
    handleType: string
    params: seq[L2ActivityParam]
    config: seq[L2ActivityConfigKey]
    services: seq[string]
    anchor: NimNode

proc l3ActivityHandleTypeName(packageName, activityName: string): string =
  ## `<TitlePackage><TitleActivity>Handle` — `infra` + `sso` →
  ## `InfraPackageSsoHandle`. Derived from `titleIdent` rather than from
  ## `titleCase` alone so the handle type can never collide with the
  ## package's own `<Title>Package` type or with a `BuildEdge` subtype
  ## (`titleCase(exe) & titleCase(cmd) & "Edge"`), both of which share
  ## this module's identifier namespace.
  titleIdent(packageName) & titleCase(activityName) & "Handle"

proc l3PackageExportsTypeName(packageName: string): string =
  titleIdent(packageName) & "Exports"

const
  # The FIXED module-scope names `l3LiftedExportSurface` emits, named
  # once so the emission and `l3CheckExportNames`' reservation cannot
  # drift apart. The two registry calls are not declarations of this
  # module, but they are resolved at module scope in the generated code,
  # and an accessor `proc` sharing one of their names would be an
  # overload of an imported routine rather than the export the author
  # asked for.
  l3LiftedExportsProcName = "liftedExports"
  l3RegisterActivityCallName = "registerActivityInterface"
  l3RegisterServiceCallName = "registerServiceInterface"

proc l3Exportable(name: string): bool =
  ## Whether a declared name can become a DOT-ACCESS typed symbol.
  ##
  ## L1 deliberately accepts a STRING service name (`service
  ## "renamed-api":` — `m5ServiceNameNode`, and
  ## `t_dsl_service_setter_surface_is_typed.nim`'s "the one-name head
  ## still compiles, three ways" pins it), and such a name cannot be a
  ## Nim field or proc. `Shared-Development-Services.md` §3 is explicit
  ## that the DSL reference surface is "typed symbols with dot access"
  ## while `<package>:<name>` is "the CLI disambiguation surface" — so a
  ## non-identifier name stays reachable at the CLI and is simply not
  ## reachable by dot access.
  ##
  ## Refusing it instead would weaken L1's gate, which is why this is a
  ## predicate and not an `error`. It is also not a SILENT drop: the
  ## export still reaches the interface artifact (`registerServiceInterface`
  ## / `registerActivityInterface` run for it regardless), and
  ## `l3LiftedExportSurface` emits a compile-time `warning` naming it and
  ## saying which surface it is missing from.
  validGeneratedIdent(name)

proc l3CollectExports(packageName: string; pkgBody: NimNode):
    tuple[activities: seq[L3ActivityExport];
          services: seq[L3ServiceExport]] =
  ## Read the package body for everything L3 lifts. Read-only: it reuses
  ## L2's parsers (`l2ActivityEntryAst`, `l2ParseActivityParams`,
  ## `l2ParseActivityConfig`) and L1's `m5ServiceEntryAst`, so a shape
  ## either walker refuses is refused here with the SAME message rather
  ## than silently lifted in a second, divergent reading.
  result.activities = @[]
  result.services = @[]
  for stmt in pkgBody:
    if calleeName(stmt).normalize == "service":
      let parsed = m5ServiceEntryAst(stmt)
      if parsed.matched:
        result.services.add(L3ServiceExport(
          name: parsed.serviceName, activityName: "", handleType: "",
          identityScope: l4ServiceIdentityScope(parsed.body),
          anchor: l2StmtAnchor(stmt)))
      continue
    if calleeName(stmt).normalize != "devenv":
      continue
    for devEnvStmt in stmt[stmt.len - 1]:
      let parsed = l2ActivityEntryAst(devEnvStmt)
      if not parsed.matched:
        continue
      let handleType = l3ActivityHandleTypeName(packageName,
        parsed.activityName)
      var entry = L3ActivityExport(
        name: parsed.activityName,
        handleType: handleType,
        params: l2ParseActivityParams(parsed.activityName, parsed.paramsNode),
        config: l2ParseActivityConfig(parsed.activityName, parsed.body),
        services: @[],
        anchor: l2StmtAnchor(devEnvStmt))
      for inner in parsed.body:
        if not l2IsHeadNamed(inner, "service"):
          continue
        let svc = m5ServiceEntryAst(inner)
        if not svc.matched:
          continue
        entry.services.add(svc.serviceName)
        result.services.add(L3ServiceExport(
          name: svc.serviceName, activityName: parsed.activityName,
          handleType: handleType,
          identityScope: l4ServiceIdentityScope(svc.body),
          anchor: l2StmtAnchor(inner)))
      result.activities.add(entry)

proc l3EmittedModuleScopeNames(packageName: string;
                               activities: seq[L3ActivityExport]):
    seq[tuple[name, what: string]] =
  ## Every name the code `l3LiftedExportSurface` emits for this package
  ## RESOLVES at module scope, with a phrase naming what each one is.
  ## Derived here and consumed by `l3CheckExportNames`, so an export
  ## cannot be given a name the lift is about to use, or to name, for
  ## something else.
  ##
  ## It is a derivation and not a hand-kept list: the three fixed names
  ## are the consts the emission itself interpolates, the reflection
  ## object comes from `l3PackageExportsTypeName`, the package's own type
  ## from `titleIdent` and the handle types from
  ## `l3ActivityHandleTypeName` by way of `act.handleType` — the same
  ## calls that produce the emitted text. A new emitted name is reserved
  ## by being added to that one source, not by being remembered here as
  ## well.
  ##
  ## IT COVERS WHAT THE EMISSION REFERENCES, NOT ONLY WHAT IT DECLARES.
  ## `titleIdent(packageName)` is the `pkg:` parameter type of
  ## `liftedExports` and of every accessor; the lift never declares it —
  ## `toolActionWrapperCode` does, as `type <Title>Package* = object` —
  ## but it declares it in the SAME module, so an accessor `proc` of that
  ## name is a redefinition there rather than an overload, and Nim
  ## reports it on a generated line. The five OTHER types the emission
  ## references (`LiftedServiceHandle`, `ActivityInterfaceDef`,
  ## `ActivityParamInterfaceDef`, `ActivityConfigInterfaceDef`,
  ## `ServiceInterfaceDef`) live in `types.nim` and reach the recipe by
  ## import, so an accessor of one of those names merely shadows the
  ## import and compiles — measured, each exit 0 — and reserving them
  ## would refuse a legal recipe.
  ##
  ## The ACCESSOR procs are deliberately absent: their names ARE the
  ## export names, and `claim` already refuses two exports sharing one.
  ## Only the handle types of EXPORTABLE activities are listed, because
  ## those are the only ones the emission declares (see `l3Exportable`).
  result = @[
    (l3LiftedExportsProcName,
     "the generated `proc " & l3LiftedExportsProcName &
       "` that carries every export's address"),
    (l3RegisterActivityCallName,
     "the registry call the lift emits for each activity"),
    (l3RegisterServiceCallName,
     "the registry call the lift emits for each service"),
    (l3PackageExportsTypeName(packageName),
     "the generated reflection object `" &
       l3PackageExportsTypeName(packageName) & "`"),
    (titleIdent(packageName),
     "the package's own type `" & titleIdent(packageName) &
       "`, which every signature the lift writes names")]
  for act in activities:
    if l3Exportable(act.name):
      result.add((act.handleType,
        "the generated handle type for activity `" & act.name & "`"))

proc l3CheckExportNames(packageName: string;
                        activities: seq[L3ActivityExport];
                        services: seq[L3ServiceExport]) =
  ## Refuse the name clashes the emission cannot survive, naming the
  ## clash rather than letting Nim report a redefinition in generated
  ## code.
  ##
  ## Each accessor is a top-level `proc <name>*(pkg: <Title>Package)`, so
  ## an export whose name is already a module-level VALUE in this recipe
  ## — the package const itself (`const infra* = InfraPackage()`) or an
  ## M9.R.2c artifact slot (`var apiBin {.inject.}: Executable`) — is a
  ## Nim redefinition: a proc and a var cannot share a name. Skipping the
  ## accessor instead would be the silent drop this campaign has found
  ## seven of; the reference `infra.<name>` would simply not resolve, with
  ## no diagnostic anywhere.
  let pkgValue = packageValueIdent(packageName)
  let emitted = l3EmittedModuleScopeNames(packageName, activities)
  var slots: seq[string] = @[]
  var owner: seq[string] = @[]
  proc claim(name, kind: string; anchor: NimNode) =
    let key = name.normalize
    for em in emitted:
      if key != em.name.normalize:
        continue
      error("`" & kind & " " & name & "`: `" & name & "` is RESERVED -- " &
        "the lift itself emits it at module scope for package `" &
        packageName & "`, as " & em.what & ". Exporting it would put a " &
        "top-level `proc " & name & "` beside that one, and Nim would " &
        "report the clash against GENERATED code, on no line an author " &
        "can act on. Rename the " & kind & ".", anchor)
    if key == pkgValue.normalize:
      error("`" & kind & " " & name & "`: package `" & packageName &
        "` exports it to consumers as `" & pkgValue & "." & name &
        "`, which needs a top-level `proc " & name & "`, and the " &
        "package's own `const " & pkgValue & "` already owns that name. " &
        "Rename the " & kind & ". (`Shared-Development-Services.md` §3: " &
        "\"`infra.sso` is a typed symbol\" — the symbol has to be " &
        "nameable.)", anchor)
    let idx = slots.find(key)
    if idx >= 0:
      error("`" & kind & " " & name & "`: package `" & packageName &
        "` already exports `" & name & "` as " & owner[idx] &
        ". Two exports of one package cannot share a name: a consumer " &
        "writing `" & pkgValue & "." & name & "` would have no way to " &
        "say which one it meant. `Shared-Development-Services.md` §3 " &
        "resolves a COLLISION BETWEEN PACKAGES by union and " &
        "`<package>:<name>` at the CLI; it says nothing about two " &
        "exports of one package, because that is an authoring mistake.",
        anchor)
    slots.add(key)
    owner.add("an " & kind)
  for act in activities:
    if l3Exportable(act.name):
      claim(act.name, "activity", act.anchor)
  for svc in services:
    if svc.activityName.len == 0 and l3Exportable(svc.name):
      claim(svc.name, "service", svc.anchor)
  for act in activities:
    # Inside ONE handle type a `config:` key and a service become fields
    # of the same object, so they collide there rather than at module
    # scope.
    var fields: seq[string] = @[]
    for c in act.config:
      if l3Exportable(c.name):
        fields.add(c.name.normalize)
    for svcName in act.services:
      if not l3Exportable(svcName):
        continue
      if svcName.normalize in fields:
        error("activity `" & act.name & "`: service `" & svcName &
          "` and `config:` key `" & svcName & "` would be the same " &
          "member of the lifted handle type `" & act.handleType &
          "`. Both are members a consumer reaches as `" & pkgValue & "." &
          act.name & "." & svcName & "`, so the names have to be " &
          "distinct.", act.anchor)
      fields.add(svcName.normalize)

proc l3ContributionPointLiterals(points: seq[string]): string =
  ## The `converge` point names as a comma-separated list of Nim string
  ## literals, for the generated `registerServiceInterface` call and the
  ## generated consumer-side const. One renderer, two emissions, so the
  ## artifact and the compile-time check cannot disagree about which
  ## points a service declares.
  var parts: seq[string] = @[]
  for point in points:
    parts.add(escForCode(point))
  parts.join(", ")

proc sharedServiceConstBase*(packageName, activityName,
                             serviceName: string): string =
  ## THE name prefix of the two consts a lifted shared service's
  ## resolver is reached through -- `<packageValue><TitleActivity?>`
  ## `<TitleService>`, so `infra` + "" + `sso` -> `infraSso` and
  ## `infra` + `idp` + `sso` -> `infraIdpSso`.
  ##
  ## EXPORTED, AND CALLED BY BOTH EMITTERS. `l3LiftedExportSurface`
  ## (the producer's own macro expansion, for a workspace-sibling
  ## import) and `emitLiftedServiceSymbols` in
  ## `repro_interface_artifacts` (the stub, for a consumer that reached
  ## the producer through its artifact) both have to produce the SAME
  ## const names, because the resolver macro reconstructs the name from
  ## the author's expression and cannot know which route the author took.
  ## Two hand-kept copies of this derivation is how a resolver would
  ## compile against one route and not the other with nothing failing --
  ## the divergence `emitLiftedServiceSymbols`' own header warns about.
  ## So there is one copy and the stub calls it.
  ##
  ## The ACTIVITY is in the name because two activities of one package
  ## may each declare a service of the same bare name, and L3's
  ## module-scope clash check only claims PACKAGE-LEVEL export names. A
  ## const named for the service alone would leave one of the two
  ## silently unreachable.
  result = packageValueIdent(packageName)
  if activityName.len > 0:
    result.add(titleCase(activityName))
  result.add(titleCase(serviceName))

proc l3LiftedExportSurface(pkg: PackageDef; pkgBody: NimNode): NimNode =
  ## The whole L3 emission for one package, or an empty statement list
  ## when the package exports no service and no constructor-shaped
  ## activity.
  let collected = l3CollectExports(pkg.packageName, pkgBody)
  if collected.activities.len == 0 and collected.services.len == 0:
    return newStmtList()
  l3CheckExportNames(pkg.packageName, collected.activities,
    collected.services)
  let typeName = titleIdent(pkg.packageName)
  let exportsType = l3PackageExportsTypeName(pkg.packageName)
  # The non-identifier names, warned about ONCE each. Not an `error`:
  # see `l3Exportable`. Not silence either: a name the author declared
  # and that does not appear on the new surface is said out loud, with
  # the surface it IS reachable from.
  for act in collected.activities:
    if not l3Exportable(act.name):
      warning("activity `" & act.name & "`: `" & act.name & "` is not a " &
        "legal Nim identifier, so package `" & pkg.packageName & "` does " &
        "not export it for dot access -- a consumer cannot write `" &
        packageValueIdent(pkg.packageName) & "." & act.name & "`. It is " &
        "still declared, still lifted into the interface artifact, and " &
        "still addressable at the CLI as `" & pkg.packageName & ":" &
        act.name & "`. `Shared-Development-Services.md` §3 keeps those " &
        "two surfaces apart on purpose. Rename it to a plain identifier " &
        "to make it referenceable from a recipe.", act.anchor)
      continue
    for c in act.config:
      if not l3Exportable(c.name):
        warning("activity `" & act.name & "`: `config:` key `" & c.name &
          "` is not a legal Nim identifier, so it is not a member of the " &
          "lifted handle type `" & act.handleType & "` and a consumer " &
          "cannot read it. It still reaches the interface artifact and " &
          "still works as an `enable` override in this package.", act.anchor)
    for svcName in act.services:
      if not l3Exportable(svcName):
        warning("activity `" & act.name & "`: service `" & svcName &
          "` is not a legal Nim identifier, so it is not a member of the " &
          "lifted handle type `" & act.handleType & "`. It is still " &
          "declared, still lowered with its typed edges, and still " &
          "addressable at the CLI as `" & pkg.packageName & ":" & svcName &
          "`.", act.anchor)
  for svc in collected.services:
    if svc.activityName.len == 0 and not l3Exportable(svc.name):
      warning("service `" & svc.name & "`: `" & svc.name & "` is not a " &
        "legal Nim identifier, so package `" & pkg.packageName & "` does " &
        "not export it for dot access. It is still declared, still " &
        "lifted into the interface artifact, and still addressable at " &
        "the CLI as `" & pkg.packageName & ":" & svc.name & "`.",
        svc.anchor)
  var code = "type\n"
  for act in collected.activities:
    if not l3Exportable(act.name):
      continue
    code.add("  " & act.handleType & "* = object\n")
    code.add("    ## Shared-Development-Services L3: the lifted handle " &
      "type for activity\n    ## `" & act.name & "` of package `" &
      pkg.packageName & "`. Its FIELDS are the member set a\n" &
      "    ## consuming recipe compiles against; their VALUES belong to a " &
      "resolved\n    ## instance and are L7's work (see " &
      "`Shared-Development-Services.md` §7).\n")
    var fieldCount = 0
    for c in act.config:
      if not l3Exportable(c.name):
        continue
      code.add("    " & c.name & "*: " & c.typeNode.repr.strip() & "\n")
      inc fieldCount
    for svcName in act.services:
      if not l3Exportable(svcName):
        continue
      code.add("    " & svcName & "*: LiftedServiceHandle\n")
      inc fieldCount
    if fieldCount == 0:
      code.add("    discard\n")
  code.add("  " & exportsType & "* = object\n")
  code.add("    ## Shared-Development-Services L3: every service and " &
    "activity package\n    ## `" & pkg.packageName & "` exports. Reflected " &
    "by `liftedExportRefusal` to name\n    ## what is available when a " &
    "consumer misspells a reference, which is why it\n    ## is an object " &
    "with fields and not a list of accessor procs.\n")
  var exportCount = 0
  for act in collected.activities:
    if not l3Exportable(act.name):
      continue
    code.add("    " & act.name & "*: " & act.handleType & "\n")
    inc exportCount
  for svc in collected.services:
    if svc.activityName.len == 0 and l3Exportable(svc.name):
      code.add("    " & svc.name & "*: LiftedServiceHandle\n")
      inc exportCount
  if exportCount == 0:
    code.add("    discard\n")
  code.add("proc " & l3LiftedExportsProcName & "*(pkg: " & typeName &
    "): " & exportsType & " =\n")
  code.add("  ## Shared-Development-Services L3: the ADDRESSES of this " &
    "package's\n  ## exports. Not a resolver (§4.6) and not an instance " &
    "(§7) — it is what\n  ## makes the names typed.\n")
  code.add("  discard pkg\n")
  for act in collected.activities:
    if not l3Exportable(act.name):
      continue
    for svcName in act.services:
      if not l3Exportable(svcName):
        continue
      code.add("  result." & act.name & "." & svcName &
        " = LiftedServiceHandle(packageName: " &
        escForCode(pkg.packageName) & ", activityName: " &
        escForCode(act.name) & ", serviceName: " & escForCode(svcName) &
        ")\n")
  for svc in collected.services:
    if svc.activityName.len == 0 and l3Exportable(svc.name):
      code.add("  result." & svc.name &
        " = LiftedServiceHandle(packageName: " &
        escForCode(pkg.packageName) & ", activityName: \"\", serviceName: " &
        escForCode(svc.name) & ")\n")
  for act in collected.activities:
    if not l3Exportable(act.name):
      continue
    code.add("proc " & act.name & "*(pkg: " & typeName & "): " &
      act.handleType & " =\n  pkg." & l3LiftedExportsProcName & "." &
      act.name & "\n")
  for svc in collected.services:
    if svc.activityName.len == 0 and l3Exportable(svc.name):
      code.add("proc " & svc.name & "*(pkg: " & typeName &
        "): LiftedServiceHandle =\n  pkg." & l3LiftedExportsProcName &
        "." & svc.name & "\n")
  for act in collected.activities:
    var params: seq[string] = @[]
    for p in act.params:
      let info = act.anchor.lineInfoObj()
      params.add("ActivityParamInterfaceDef(name: " & escForCode(p.name) &
        ", nimType: " & escForCode(p.typeNode.repr.strip()) &
        ", sourceFile: " & escForCode(info.filename) &
        ", sourceLine: " & $info.line & ")")
    var configs: seq[string] = @[]
    for c in act.config:
      let info = act.anchor.lineInfoObj()
      configs.add("ActivityConfigInterfaceDef(name: " & escForCode(c.name) &
        ", nimType: " & escForCode(c.typeNode.repr.strip()) &
        ", defaultRepr: " &
        escForCode(if c.defaultNode == nil: ""
                   else: c.defaultNode.repr.strip()) &
        ", hasDefault: " & $(c.defaultNode != nil) &
        ", description: " & escForCode(c.description) &
        ", sourceFile: " & escForCode(info.filename) &
        ", sourceLine: " & $info.line & ")")
    var svcNames: seq[string] = @[]
    for svcName in act.services:
      svcNames.add(escForCode(svcName))
    let info = act.anchor.lineInfoObj()
    code.add(l3RegisterActivityCallName & "(" & escForCode(pkg.packageName) &
      ", ActivityInterfaceDef(name: " & escForCode(act.name) &
      ", handleType: " & escForCode(act.handleType) &
      ", params: @[" & params.join(", ") & "]" &
      ", config: @[" & configs.join(", ") & "]" &
      ", services: @[" & svcNames.join(", ") & "]" &
      ", sourceFile: " & escForCode(info.filename) &
      ", sourceLine: " & $info.line & "))\n")
  for svc in collected.services:
    let info = svc.anchor.lineInfoObj()
    # L4: the declared identity and scope travel with the signature.
    # Written as the enum's own name rather than as an ordinal so the
    # generated code is readable and a reordered enum cannot silently
    # re-map a declaration.
    code.add(l3RegisterServiceCallName & "(" & escForCode(pkg.packageName) &
      ", ServiceInterfaceDef(name: " & escForCode(svc.name) &
      ", activityName: " & escForCode(svc.activityName) &
      ", handleType: " & escForCode(svc.handleType) &
      ", identityKind: " & $svc.identityScope.identityKind &
      ", identityStableId: " & escForCode(svc.identityScope.stableId) &
      ", scope: " & $svc.identityScope.scope &
      # L6: the declared MAJOR COMPATIBILITY FIELD. 0 when the body
      # declared none, which is the undeclared value every pre-v23
      # interface artifact decodes to -- see
      # `ServiceInterfaceDef.compatibilityMajor`.
      ", compatibilityMajor: " & $svc.identityScope.compatibilityMajor &
      "'u32" &
      # D-SS11 (§4.6): the owner's contribution points travel WITH the
      # signature. Emitted from the same `l4ServiceIdentityScope`
      # reading the lowering uses, so the lift cannot carry a point the
      # service does not converge.
      ", contributionPoints: @[" &
      l3ContributionPointLiterals(svc.identityScope.convergePoints) &
      "]" &
      ", sourceFile: " & escForCode(info.filename) &
      ", sourceLine: " & $info.line & "))\n")
  # Shared-Development-Services D-SS11 (§4.6): the RESOLVER's two
  # generated consts, one pair per service that declares an `instance:`
  # block.
  #
  # They are what makes `<package>.<service>.shared(...)` a compile-time
  # checked surface in a CONSUMER's recipe: `...SharedPoints` is read by
  # `sharedServiceResolve` as a `static seq[string]` so a misspelled
  # point is refused by name with the list, and `...SharedService`
  # carries the declaration record the resolution is built from.
  #
  # ONLY FOR A SERVICE WITH AN `instance:` BLOCK. A session-owned
  # service has no registry entry to attach to (§4.5 keys the registry
  # on instances), so a resolver for one could never do anything;
  # `sharedServiceNotResolvable` says that by name instead, which is why
  # the absence of the const is a usable diagnostic rather than a gap.
  #
  # THE OWNER'S RECIPE DIRECTORY travels in the record. The resolver's
  # attach decision needs the owner's own project interface artifact --
  # §4.3 compares fingerprints and the consumer has no other way to
  # reach the owner's -- and the declaration's `sourceFile` is the one
  # fact already lifted that locates it. See
  # `SharedServiceDeclarationDef.ownerRecipeDir` for why a path here is
  # not a §4.4 violation.
  var resolverCode = ""
  for svc in collected.services:
    if not svc.identityScope.instanceDeclared:
      continue
    if not l3Exportable(svc.name):
      continue
    if svc.activityName.len > 0 and not l3Exportable(svc.activityName):
      continue
    let base = sharedServiceConstBase(pkg.packageName, svc.activityName,
      svc.name)
    let points = l3ContributionPointLiterals(svc.identityScope.convergePoints)
    resolverCode.add("const " & base & "SharedPoints* = @[" & points &
      "]\n")
    resolverCode.add("const " & base & "SharedService* = " &
      "SharedServiceDeclarationDef(ownerPackage: " &
      escForCode(pkg.packageName) & ", serviceName: " &
      escForCode(svc.name) & ", activityName: " &
      escForCode(svc.activityName) & ", ownerRecipeDir: " &
      # The DIRECTORY, computed here rather than emitted as a
      # `parentDir(...)` call: the generated code lands in a recipe whose
      # imports this emitter does not control, and a stub that needed
      # `std/os` in scope would be a build break in the consumer rather
      # than a diagnostic.
      escForCode(parentDir(svc.anchor.lineInfoObj().filename)) &
      ", contributionPoints: @[" & points & "])\n")
  if resolverCode.len > 0:
    code.add(resolverCode)
  result = parseStmt(code)
  result.copyLineInfo(pkgBody)


# ---------------------------------------------------------------------------
# Shared-Development-Services L3 — the consumer side: a reference to a
# dependency's export is refused by NAME, with the names that exist.
#
# L3's gate: "a misspelled name, an absent member and a type mismatch each
# failing B's recipe compilation with a message naming what is
# available". Nim already fails all three; what it does not do is name the
# alternatives. `activityMemberRefusal` supplies that for a member of an
# activity PARAMETER (L2); these two supply it for a reference through a
# dependency's package const, which is the spelling §3 writes
# (`infra.sso`, `sso.issuer`).
#
# The type-mismatch case is deliberately left to the compiler. Nim's own
# diagnostic for `enable stack(sso = infra.sso)` against a parameter of
# the wrong type names both the type it got and the type it expected,
# which is what "naming what is available" means for a mismatch; a DSL
# refusal could not improve on it and would have to re-implement overload
# resolution to fire at the right times.
# ---------------------------------------------------------------------------

macro liftedExportRefusal*(ty: typedesc; anchor: untyped;
                           packageName, packageValue,
                           memberName: static string): untyped =
  ## Refuse one `<dep>.<name>` reference, naming the exports `ty` has.
  ##
  ## Same contract as `activityMemberRefusal`: reached only from a `when
  ## not compiles(...)` guard, so it always errors, and `anchor` is
  ## `untyped` purely for line info so the diagnostic lands on the
  ## recipe's own line.
  var typeNode = ty.getTypeInst()
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2:
    typeNode = typeNode[1]
  var members: seq[string] = @[]
  l2AppendTypeMemberNames(typeNode, members, 0)
  let available =
    if members.len == 0:
      "package `" & packageName & "` lifts no services or activities at all"
    else:
      "services and activities package `" & packageName & "` exports: " &
        members.join(", ")
  error("`" & packageValue & "." & memberName & "`: package `" &
    packageName & "` exports no service or activity named `" & memberName &
    "`. " & available & ". `Shared-Development-Services.md` §3: \"`infra" &
    ".sso` is a typed symbol. A misspelling, a member that does not " &
    "exist, or a type that does not match is a compile error in THIS " &
    "project's recipe compilation -- not a runtime \"no such service\".\"",
    anchor)

macro liftedMemberRefusal*(ty: typedesc; anchor: untyped;
                           reference, memberName: static string): untyped =
  ## Refuse one `<dep>.<export>.<member>` access, naming the members the
  ## lifted handle type has.
  var typeNode = ty.getTypeInst()
  if typeNode.kind == nnkBracketExpr and typeNode.len == 2:
    typeNode = typeNode[1]
  var members: seq[string] = @[]
  l2AppendTypeMemberNames(typeNode, members, 0)
  let typeText = typeNode.repr.strip()
  let available =
    if members.len == 0:
      "lifted type `" & typeText & "` has no members at all"
    else:
      "available members of `" & typeText & "`: " & members.join(", ")
  error("`" & reference & "." & memberName & "`: the lifted handle `" &
    reference & "` has no member `" & memberName & "`. " & available &
    ". `Shared-Development-Services.md` §3: what the lift carries for " &
    "each exported service is \"the type of its handle and that type's " &
    "members\", so a member written here that the lifted type does not " &
    "have is refused at the recipe's own line.", anchor)

# ---------------------------------------------------------------------------
# Shared-Development-Services D-SS11 (§4.6) — THE RESOLVER, and its
# refusals.
#
#   enable stack(sso = infra.sso.shared(
#                        relyingParties = append("codetracer-cli")))
#
# §4.6 decides the spelling: "`<package>.<service>.shared()` -- a
# resolver on the typed declaration symbol, reached by dot syntax, never
# by a string. It returns a `SharedServiceHandle[T]`, a type DISTINCT
# from the declaration's". And it decides where the call lives: "In the
# consuming project's own recipe, at its `enable <activity>(...)` call."
#
# WHY THREE MACROS AND NOT ONE. `shared` must see the author's
# IDENTIFIERS (`infra`, `sso`) to know which service is meant, so its
# first parameter is `untyped`. But the check that a contribution names a
# DECLARED point needs the owner's point list as a compile-time VALUE,
# and that value lives in a generated `const` the owner's lift emitted.
# A macro cannot test whether an identifier it just built resolves, so
# the emission is `when declared(<const>): <checked call> else:
# <refusal>` -- and the checked call has to be a second macro, because
# only a macro can read the const as `static` and `error` naming its
# contents. The third macro is the refusal, which exists so the message
# names the author's own expression rather than Nim's "undeclared
# identifier".
#
# WHAT IS SYNTAX AND WHAT IS A VALUE. The OPERATION is syntax, exactly as
# L8's `contribute:` heads are: `append(...)` / `appendOverride(...)` /
# `appendForce(...)`, read from the call's head and never from a value.
# `Configurable-System.md` §"Operation is a SECOND axis" requires the
# operation "declared at the call site" so "the engine can say which
# contribution was dropped and which one dropped it"; a value-carried
# operation could be computed, and then the site would not say it. The
# MEMBERS are a value, and both `append("a")` and `append(@["a", "b"])`
# are authorable through the same `l8ContributionMembers` overloads L8
# built.
#
# WHAT A RESOLVER DOES NOT DO HERE. It does not contact the daemon and
# does not compare a fingerprint: at macro-expansion and at evaluation
# there is no instance to decide against. It records a resolution that
# travels to the consumer's `repro up`, where §4's machinery runs
# against THIS call site -- see `resolveSharedService`'s own comment.
# ---------------------------------------------------------------------------

const
  SharedResolverOperationHeads* = [
    "append", "appendoverride", "appendforce",
    "replace", "replaceoverride", "replaceforce"]
    ## The closed set, normalized. The SAME six L8's `contribute:`
    ## carries (`L8ContributeOperationHeads`), spelled as calls rather
    ## than as blocks because a resolver argument is an expression. Not
    ## shared with that constant by identity because the two surfaces are
    ## allowed to diverge -- a resolver refuses the three `replace` heads
    ## and `contribute:` does not -- and a shared constant would hide
    ## that in a predicate.

proc l11OperationHeadsList(): string =
  var parts: seq[string] = @[]
  for h in SharedResolverOperationHeads:
    parts.add("`" & h & "`")
  parts.join(", ")

proc l11OperationFor(head: string): tuple[op, prec: string] =
  ## Head -> (operation, precedence), identical to L8's mapping.
  case head
  of "append": ("coAppend", "epSet")
  of "appendoverride": ("coAppend", "epOverride")
  of "appendforce": ("coAppend", "epForce")
  of "replace": ("coReplace", "epSet")
  of "replaceoverride": ("coReplace", "epOverride")
  of "replaceforce": ("coReplace", "epForce")
  else: ("", "")

proc l11DeclarationChain(decl: NimNode): seq[string] =
  ## Flatten the author's declaration expression into the identifier
  ## chain `<packageValue>[.<activity>].<service>`.
  ##
  ## `infra.sso.shared(...)` reaches a macro whose first parameter is
  ## `untyped` as the CALL `sso(infra)` -- Nim has already rewritten the
  ## dot into a call to find `shared` -- so both that shape and the plain
  ## `nnkDotExpr` of `shared(infra.sso)` have to be read. Anything else
  ## (a string literal, an index, a call with arguments) returns an empty
  ## chain and the caller refuses it by shape rather than guessing.
  var cursor = decl
  var reversed: seq[string] = @[]
  while true:
    case cursor.kind
    of nnkCall, nnkCommand:
      if cursor.len != 2: return @[]
      if cursor[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}: return @[]
      reversed.add(identText(cursor[0]))
      cursor = cursor[1]
    of nnkDotExpr:
      if cursor.len != 2: return @[]
      if cursor[1].kind notin {nnkIdent, nnkSym, nnkAccQuoted}: return @[]
      reversed.add(identText(cursor[1]))
      cursor = cursor[0]
    of nnkIdent, nnkSym:
      reversed.add(identText(cursor))
      break
    else:
      return @[]
  if reversed.len < 2:
    return @[]
  for i in countdown(reversed.high, 0):
    result.add(reversed[i])

proc l11ConstBaseName(chain: seq[string]): string =
  ## `<packageValue><TitleActivity?><TitleService>` -- the prefix both
  ## generated consts share, derived from the AUTHOR's expression by the
  ## same two helpers the emitters derive it from, so Nim's own
  ## identifier folding is the only difference the two can have.
  ##
  ## The activity is in the name because two activities of one package
  ## may each declare a service of the same bare name, and `l3`'s
  ## module-scope clash check only claims PACKAGE-LEVEL export names. A
  ## const named for the service alone would make one of the two
  ## unreachable -- silently, which is the whole class of defect this
  ## campaign keeps finding.
  if chain.len == 2:
    sharedServiceConstBase(chain[0], "", chain[1])
  else:
    var activity = chain[1]
    for i in 2 ..< chain.high:
      activity.add(titleCase(chain[i]))
    sharedServiceConstBase(chain[0], activity, chain[^1])

macro sharedServiceNotResolvable*(reference: static string;
                                  constName: static string;
                                  anchor: untyped): untyped =
  ## The `else` arm of the emitted `when declared(...)`: the named
  ## service has no generated resolver const.
  ##
  ## Reached only when the const is absent, so it always errors. Three
  ## things can put it here and the message says all three, because the
  ## author cannot see which from the call site: the service does not
  ## declare an `instance:` block (so it is not a shared instance at
  ## all -- §4.5 keys a registry on instances, and a session-owned
  ## service has no entry to attach to); the reference names something
  ## that is not a service; or the owner's package was reached in a way
  ## that did not lift it.
  error("`" & reference & ".shared()`: there is no shared-service " &
    "declaration for `" & reference & "`. A resolver is spelled against " &
    "a service whose `service` block declares an `instance:` block -- " &
    "that block is what makes it a daemon-owned SHARED instance " &
    "(Shared-Development-Services.md §4.5), and only such a service " &
    "gets the generated declaration const `" & constName & "` the " &
    "resolver reads. Either `" & reference & "` is not a service of " &
    "that package, or its `service` block has no `instance:`. A " &
    "session-owned service is reached as an ordinary dependency, not " &
    "by a resolver: §4.6 -- \"a consumer cannot reach the constructor " &
    "of a service it does not own\" -- cuts both ways, and there is " &
    "nothing to attach to.", anchor)

macro sharedServiceResolve*(points: static seq[string];
                            declaration: untyped;
                            reference: static string;
                            sourceFile: static string;
                            sourceLine: static int;
                            pairs: varargs[untyped]): untyped =
  ## The checked half of the resolver. `points` is the owner's declared
  ## contribution-point list, read as a compile-time value out of the
  ## generated const, which is what makes a misspelling a compile error
  ## IN THE CONSUMER'S RECIPE naming what is available -- the first of
  ## the two things §4.6 requires to land together.
  ##
  ## `pairs` arrives flattened: point-name node, value node, point-name
  ## node, value node. Flattened rather than as `nnkExprEqExpr` pairs
  ## because this macro's own parameters are typed and a named argument
  ## here would bind one of them.
  var emitted = newStmtList()
  var seen: seq[string] = @[]
  let available =
    if points.len == 0: "it converges no contribution points at all"
    else: "it converges `" & points.join("`, `") & "`"
  var contributionCalls: seq[NimNode] = @[]
  var i = 0
  while i + 1 < pairs.len:
    let nameNode = pairs[i]
    let valueNode = pairs[i + 1]
    i += 2
    let point = identText(nameNode)
    # 1. the point must be one the OWNER declared.
    var found = false
    for p in points:
      if p.normalize == point.normalize:
        found = true
        break
    if not found:
      error("`" & reference & ".shared(" & point & " = ...)`: service `" &
        reference & "` declares no contribution point `" & point &
        "`; " & available & ". Shared-Development-Services.md §4.6: " &
        "the owner's lifted interface carries its contribution points " &
        "so that \"a misspelled one is refused by name at the " &
        "consumer's compile time\" -- which is here.", nameNode)
      continue
    # 2. one contribution per point per resolver. Two would have to be
    #    merged or one dropped, and this macro is not the place either
    #    decision belongs: write one `append` with both members.
    if seen.contains(point.normalize):
      error("`" & reference & ".shared()` contributes to `" & point &
        "` twice. One resolver call makes ONE contribution per point: " &
        "two would need an order this call site does not state. Write " &
        "one `append(...)` listing every member.", nameNode)
      continue
    seen.add(point.normalize)
    # 3. the OPERATION is the head of the value expression, and the
    #    closed set is refused by name.
    if valueNode.kind notin {nnkCall, nnkCommand} or valueNode.len < 1 or
       valueNode[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      error("`" & reference & ".shared(" & point & " = " &
        valueNode.repr.strip() & ")`: a contribution states its " &
        "OPERATION at the call site -- " & l11OperationHeadsList() &
        ". `Configurable-System.md` §\"Operation is a SECOND axis, " &
        "independent of priority\" puts the operation at the call site " &
        "so the engine \"can say which contribution was dropped and " &
        "which one dropped it\"; a bare value names no operation, and " &
        "defaulting it would make an authoritative contribution " &
        "destructive or a destructive one quiet. Write `" & point &
        " = append(" & valueNode.repr.strip() & ")`.", valueNode)
      continue
    let head = identText(valueNode[0]).normalize
    var known = false
    for h in SharedResolverOperationHeads:
      if h == head:
        known = true
        break
    if not known:
      error("`" & identText(valueNode[0]) & "` is not a contribution " &
        "operation. The operations are " & l11OperationHeadsList() &
        ". `append*` adds and is NEVER destructive at any priority; " &
        "there is no `add`, no `set`, no `incl` and no `remove` " &
        "(`remove` is D-SS9's open second half).", valueNode)
      continue
    let resolved = l11OperationFor(head)
    if resolved.op == "coReplace":
      # STAGE 1 of §5.1's three refusals. The judgement is
      # `sharedServiceReplaceRefusal()`, shared with the evaluation and
      # converge sites so the three cannot drift; what is local here is
      # the SUBJECT (the author's own call as written) and the note that
      # this stage is the consumer's compile time.
      error("`" & reference & ".shared(" & point & " = " &
        identText(valueNode[0]) & "(...))`: " &
        sharedServiceReplaceRefusal() &
        " Refused at the CONSUMER's compile time, which is the earliest " &
        "of the three stages that refuse it.",
        valueNode)
      continue
    if valueNode.len < 2:
      error("`" & point & " = " & identText(valueNode[0]) &
        "()`: an operation with no members contributes nothing. A " &
        "declared contribution that resolves to no member is " &
        "indistinguishable from a forgotten one, so it is refused " &
        "rather than compiled into nothing. List the members, or " &
        "delete the argument.", valueNode)
      continue
    # Members: every argument of the operation call, through L8's two
    # `l8ContributionMembers` overloads, so `append("a")` and
    # `append(@["a", "b"])` are both authorable with no type decision
    # taken here.
    var membersExpr = newCall(ident"l8ContributionMembers", valueNode[1])
    for k in 2 ..< valueNode.len:
      membersExpr = nnkInfix.newTree(ident"&", membersExpr,
        newCall(ident"l8ContributionMembers", valueNode[k]))
    let siteFile = newLit(nameNode.lineInfoObj().filename)
    let siteLine = newLit(nameNode.lineInfoObj().line)
    contributionCalls.add(newCall(ident"sharedContribution",
      newLit(point), membersExpr, ident(resolved.prec),
      ident(resolved.op), siteFile, siteLine))
  if i < pairs.len:
    error("`" & reference & ".shared()`: trailing argument `" &
      pairs[pairs.len - 1].repr.strip() & "` is not a `<point> = " &
      "<operation>(<members>)` contribution. Every argument of a " &
      "resolver is a contribution; a positional one names no point and " &
      "would be read by nothing.", pairs[pairs.len - 1])
  var membersSeq = nnkPrefix.newTree(ident"@", nnkBracket.newTree())
  for call in contributionCalls:
    membersSeq[1].add(call)
  let fileLit = newLit(sourceFile)
  let lineLit = newLit(sourceLine)
  # The CONSUMING package is the ambient one the dev-env lowering set,
  # read at evaluation rather than baked in here: this macro expands
  # wherever the author wrote the resolver and has no way to know which
  # `package` block encloses it, while the generated dev-env proc does.
  emitted.add(newCall(
    nnkBracketExpr.newTree(ident"resolveSharedService",
      ident"LiftedServiceHandle"),
    declaration, newCall(ident"currentResolverPackage"), membersSeq,
    fileLit, lineLit))
  result = emitted
  result.copyLineInfo(declaration)

macro shared*(declaration: untyped;
              contributions: varargs[untyped]): untyped =
  ## THE RESOLVER, as §4.6 spells it: `<package>.<service>.shared(...)`.
  ##
  ## `.shared` WITHOUT PARENTHESES IS THE SAME CALL and is honoured, not
  ## dropped: Nim's dot-call sugar makes `infra.sso.shared` and
  ## `infra.sso.shared()` one AST, and a resolver with no contributions
  ## is a legitimate thing to write -- §9.4's consumer "contributes
  ## little" and a consumer may contribute nothing and only attach.
  ## Asserted rather than asserted-by-comment, because L9's review found
  ## four argument-less call forms that compiled and were silently
  ## dropped; the difference here is that there is no second spelling
  ## for this one to be confused with.
  let chain = l11DeclarationChain(declaration)
  if chain.len == 0:
    error("`shared()` is a resolver on a SERVICE DECLARATION reached by " &
      "dot access -- `<package>.<service>.shared(...)`, " &
      "Shared-Development-Services.md §4.6: \"a resolver on the typed " &
      "declaration symbol, reached by dot syntax, never by a string\". " &
      "`" & declaration.repr.strip() & "` is a " & $declaration.kind &
      ", not such a chain.", declaration)
    return newStmtList()
  let reference = chain.join(".")
  let base = l11ConstBaseName(chain)
  let pointsConst = ident(base & "SharedPoints")
  let declConst = ident(base & "SharedService")
  var pairs: seq[NimNode] = @[]
  for c in contributions:
    if c.kind != nnkExprEqExpr:
      error("`" & reference & ".shared()` takes `<point> = " &
        "<operation>(<members>)` arguments; `" & c.repr.strip() &
        "` is a " & $c.kind & ". §4.6: \"the consumer's contributions " &
        "are ARGUMENTS of the resolver call\", so an argument that " &
        "names no point is not a contribution and would be read by " &
        "nothing.", c)
      continue
    if c[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted}:
      error("`" & reference & ".shared()`: a contribution's point is a " &
        "bare identifier naming a point the owner declared; `" &
        c[0].repr.strip() & "` is a " & $c[0].kind & ".", c)
      continue
    pairs.add(c[0])
    pairs.add(c[1])
  let anchor = declaration.copyNimTree()
  let checked = newCall(ident"sharedServiceResolve", pointsConst, declConst,
    newLit(reference),
    newLit(declaration.lineInfoObj().filename),
    newLit(declaration.lineInfoObj().line))
  for p in pairs:
    checked.add(p)
  let refusal = newCall(ident"sharedServiceNotResolvable",
    newLit(reference), newLit(base & "SharedService"), anchor)
  result = nnkWhenStmt.newTree(
    nnkElifBranch.newTree(
      newCall(ident"declared", declConst), newStmtList(checked)),
    nnkElse.newTree(newStmtList(refusal)))
  result.copyLineInfo(declaration)

proc l3CollectDependencyReferences(node: NimNode; depValues: seq[string];
    acc: var seq[tuple[dep, member, member2: string; anchor: NimNode]]) =
  ## Collect `<dep>.<member>` and `<dep>.<member>.<member2>` out of a
  ## consumer body, where `<dep>` is the package const of a declared
  ## dependency.
  ##
  ## Only these two depths. A deeper chain's head is already covered by
  ## the depth-2 entry, and `<dep>.<member>(args)` in CALLEE position is
  ## skipped for the reason `l2WalkMemberUses` skips it: `compiles` is
  ## false for a routine that needs more arguments, so checking it would
  ## refuse a correct recipe.
  if node == nil:
    return
  if node.kind == nnkDotExpr and node.len == 2 and
      node[1].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    let base = node[0]
    if base.kind in {nnkIdent, nnkSym}:
      let baseText = identText(base).normalize
      for dep in depValues:
        if dep.normalize == baseText:
          acc.add((dep: dep, member: identText(node[1]), member2: "",
                   anchor: node))
          return
    elif base.kind == nnkDotExpr and base.len == 2 and
        base[0].kind in {nnkIdent, nnkSym} and
        base[1].kind in {nnkIdent, nnkSym, nnkAccQuoted}:
      let baseText = identText(base[0]).normalize
      for dep in depValues:
        if dep.normalize == baseText:
          acc.add((dep: dep, member: identText(base[1]),
                   member2: identText(node[1]), anchor: node))
          return
  if node.kind in {nnkCall, nnkCommand} and node.len > 0:
    for i in 1 ..< node.len:
      l3CollectDependencyReferences(node[i], depValues, acc)
    return
  for child in node:
    l3CollectDependencyReferences(child, depValues, acc)

proc l3DependencyReferenceChecks(pkg: PackageDef; pkgBody: NimNode): NimNode =
  ## One guarded refusal per distinct dependency reference the package's
  ## `devEnv:` body makes, emitted at MODULE scope so it is checked in
  ## every compilation mode rather than only under
  ## `-d:reproProviderMode`, which is the only mode that compiles the
  ## dev-env proc the references live in.
  result = newStmtList()
  var depValues: seq[string] = @[]
  for useDef in pkg.allToolUses():
    if useDef.packageSelector.len == 0:
      continue
    let value = packageValueIdent(useDef.packageSelector)
    if value.len > 0 and value notin depValues:
      depValues.add(value)
  if depValues.len == 0:
    return
  var refs: seq[tuple[dep, member, member2: string; anchor: NimNode]] = @[]
  for stmt in pkgBody:
    if calleeName(stmt).normalize != "devenv":
      continue
    l3CollectDependencyReferences(stmt[stmt.len - 1], depValues, refs)
  var seen: seq[string] = @[]
  for reference in refs:
    let key = reference.dep & "." & reference.member & "." & reference.member2
    if key in seen:
      continue
    seen.add(key)
    let depIdent = ident(reference.dep)
    let exportsType = ident(l3PackageExportsTypeName(reference.dep))
    let access = newDotExpr(depIdent, ident(reference.member))
    let nameRefusal = newCall(ident("liftedExportRefusal"),
      newCall(ident("typeof"), newCall(ident("default"), exportsType)),
      reference.anchor.copyNimTree(), newLit(reference.dep),
      newLit(reference.dep), newLit(reference.member))
    nameRefusal.copyLineInfo(reference.anchor)
    # Guarded on `declared(<Dep>PackageExports)` as well as on the
    # access: a dependency that lifts nothing has no type to reflect, and
    # there Nim's own `undeclared field` is the whole of the available
    # diagnostic.
    if reference.member2.len == 0:
      result.add(quote do:
        when declared(`exportsType`) and not compiles(`access`):
          `nameRefusal`)
      continue
    let fullAccess = newDotExpr(access.copyNimTree(),
      ident(reference.member2))
    let memberRefusal = newCall(ident("liftedMemberRefusal"),
      newCall(ident("typeof"), access.copyNimTree()),
      reference.anchor.copyNimTree(),
      newLit(reference.dep & "." & reference.member),
      newLit(reference.member2))
    memberRefusal.copyLineInfo(reference.anchor)
    result.add(quote do:
      when declared(`exportsType`):
        when not compiles(`access`):
          `nameRefusal`
        elif not compiles(`fullAccess`):
          `memberRefusal`)


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
    # A statement that IS a `uses` clause but whose argument is not a literal
    # used to be skipped here, which silently discarded a declared dependency
    # — the one failure mode this DSL must not have. The arg is spliced
    # verbatim into the emitted clause, so any expression the compiler can
    # resolve to the dependency string is fine; it just has to reach the
    # emitter rather than being dropped on the way.
    if arg.kind in {nnkStmtList, nnkStmtListExpr}:
      error("uses in a variant arm expects a single dependency expression",
        arg)
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
#   * ``dataFile`` defaults to false.
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
  ##                     <dfkTarball | dfkGitArchive | dfkDataFile>,
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
    var dataFile = false
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
      of "datafile":
        let parsed = m9gExtractBoolLit(setterStmt[1])
        if not parsed.matched:
          error("fetch: dataFile must be a bool literal", setterStmt)
        dataFile = parsed.value
      else: discard
    # Validate.
    if urlNode == nil and gitUrlNode == nil:
      error("fetch: block must specify one of url: or gitUrl: " &
            "(package " & packageName & ")", stmt)
    if urlNode != nil and gitUrlNode != nil:
      error("fetch: block declares both url: and gitUrl: — pick one " &
            "(package " & packageName & ")", stmt)
    if dataFile and gitUrlNode != nil:
      error("fetch: dataFile cannot be combined with gitUrl: " &
            "(package " & packageName & ")", stmt)
    if sha256Node == nil and blake3Node == nil:
      error("fetch: block must specify either sha256: or blake3: " &
            "(package " & packageName & ")", stmt)
    # Resolve kind + final URL.
    let kindIdent =
      if dataFile: ident("dfkDataFile")
      elif gitUrlNode != nil: ident("dfkGitArchive")
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
# DSL-port M9.R.6.1 — M9.I emitter RETIRED.
#
# The ``emitM9IBuildFlags`` proc, the ``m9iCollectFlagNodes`` helper,
# and the five block parser arms in ``cross_project.classifySectionStmt``
# (``soM9IMesonOptions`` / ``soM9ICmakeFlags`` / ``soM9IConfigureFlags``
# / ``soM9IMakeFlags`` / ``soM9INinjaFlags``) were removed on
# 2026-06-19 alongside the ``registerBuildFlag`` /
# ``registeredBuildFlags`` runtime registry. Recipes route per-tool
# options through their explicit ``build:`` body calling one of the
# M9.R.2b Layer-1 typed constructors (``meson_package(...)`` /
# ``cmake_package(...)`` / ``autotools_package(...)``) with the option
# seq inlined as a ``configureOptions`` / ``cacheVars`` argument.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# DSL-port M9.R.10b — default ``build:`` synthesis emission.
#
# Closes M9.R.6's deferred wiring. When a recipe declares a ``fetch:``
# block AND no explicit ``build:`` block AND its ``nativeBuildDeps:``
# name a recognised convention tool (meson / cmake / autoconf-automake-
# libtool / make), the package macro emits a synthesised module-init
# block that calls the matching stdlib synthesiser
# (``synthesizeMesonPackage`` / ``synthesizeCmakePackage`` /
# ``synthesizeAutotoolsPackage``) and slices the result into the
# artifact slots declared by the recipe's ``executable`` / ``library``
# / ``files`` sections.
#
# Two runtime-time gates fire inside the emitted block:
#
#   * ``shouldSynthesizeDefaultBuild`` — the M9.R.6 gate that consults
#     ``registeredNativeBuildDeps(packageName)``. Returns ``false`` when
#     the recipe declared no recognised convention tool, or declared a
#     custom-shell driver (sh / perl / python) with no canonical
#     pipeline.
#   * ``raiseCustomBuildRequired`` — fires AT MODULE INIT when the
#     recipe's ``nativeBuildDeps:`` resolve to the custom convention
#     (sh / perl / python) but the recipe authored no ``build:`` block.
#     The runtime raise documents the recipe name + the actionable
#     remediation (add a ``build:`` block calling ``shell(...)`` per
#     upstream step).
#
# Compile-time skip path: ``shouldSynthesizeDefaultBuild`` /
# ``defaultBuildConventionFor`` / ``synthesizeMesonPackage`` etc. live
# in ``repro_dsl_stdlib/synthesis``, which depends on
# ``repro_project_dsl``. Recipes that need synthesis import the
# stdlib's ``synthesis`` aggregator explicitly. The emitted block is
# gated on ``when compiles(defaultBuildConventionFor("<pkg>")):`` so
# recipes that did NOT import the synthesis surface produce no
# emission at all (the recipe simply has no automatic build pipeline;
# the convention layer's fetch + sentinel actions still emit). A
# recipe that declares ``fetch:`` + a recognised tool but forgot to
# import ``repro_dsl_stdlib/synthesis`` is observable via the absence
# of any auto-registered build action; downstream consumers can
# diagnose by checking ``registeredBuildActions(packageName)``.
#
# Artifact-slot assignment: the emitter walks the classified section
# list for ``soM3ExecutableArtifact`` / ``soM3LibraryArtifact`` /
# ``soM3FilesArtifact`` entries and emits one slot assignment per
# ident-form artifact (string-form artifacts produce no slot — they
# match the ``emitM9R2cArtifactSlots`` behaviour). The assignment uses
# the typed constructor result's ``.executable(name)`` /
# ``.library(name)`` / ``.files(name)`` slicing methods.
# ---------------------------------------------------------------------------

proc hasClassifiedOwnership(classified: seq[ClassifiedSection];
                            ownership: SectionOwnership): bool =
  for entry in classified:
    if entry.ownership == ownership:
      return true
  false

proc emitM9R10bDefaultBuildSynthesis*(packageName: string;
                                      classified: seq[ClassifiedSection];
                                      sourceFile: string; sourceLine: int):
                                        NimNode =
  ## Emit a default-build synthesis dispatch block when the package
  ## macro detects ``fetch:`` AND no explicit ``build:`` AND a
  ## recognised convention tool in ``nativeBuildDeps:``. See the module
  ## comment above for the dispatch matrix + gating rationale.
  ##
  ## Returns an empty ``StmtList`` when synthesis does not apply at
  ## compile-time (either the recipe declared a ``build:`` block or it
  ## declared no ``fetch:`` block). The runtime gate
  ## (``shouldSynthesizeDefaultBuild``) handles the case where the
  ## recipe declared ``fetch:`` but its ``nativeBuildDeps:`` don't
  ## match any recognised convention (no-op fall-through) and the case
  ## where the convention resolves to ``custom`` (raises a documented
  ## ``ValueError`` at module-init).
  result = newStmtList()
  let hasExplicitBuild = hasClassifiedOwnership(classified, soM4Build)
  if hasExplicitBuild:
    return
  let hasFetchBlock = hasClassifiedOwnership(classified, soM9HFetch)
  if not hasFetchBlock:
    return
  # Collect ident-form artifacts so the synthesised block can slice
  # them out of the constructor result via the typed slicing methods.
  type ArtifactSlot = object
    name: string
    identNode: NimNode
    ownership: SectionOwnership
  var slots: seq[ArtifactSlot] = @[]
  for entry in classified:
    if entry.ownership notin {soM3ExecutableArtifact,
                              soM3LibraryArtifact,
                              soM3FilesArtifact}:
      continue
    let parsed = m3ArtifactEntryAst(entry.stmt)
    if not parsed.matched:
      continue
    if not parsed.isIdentForm:
      continue
    if parsed.identNode == nil or
       parsed.identNode.kind notin {nnkIdent, nnkAccQuoted}:
      continue
    # Skip slots that ``emitM9R2cArtifactSlots`` would have skipped:
    # an artifact whose name collides with the legacy package const.
    let pkgValueIdent = packageValueIdent(packageName)
    let artifactValueIdent = packageValueIdent(parsed.artifactName)
    if artifactValueIdent == pkgValueIdent:
      continue
    slots.add(ArtifactSlot(
      name: parsed.artifactName,
      identNode: parsed.identNode.copyNimTree(),
      ownership: entry.ownership))
  let pkgLit = newLit(packageName)
  let artifactLit = newLit("")
  let bodyReprLit = newLit("default-build-synthesis (M9.R.10b)")
  # Build the per-convention dispatch arms. Each arm calls the matching
  # ``synthesize<X>Package`` entry point, stores the multi-artifact
  # result in ``synthPkg``, and assigns the typed slot vars from the
  # result's slicing methods.
  let synthPkgIdent = ident("synthPkg")
  let srcDirIdent = ident("srcDir")
  proc buildAssignments(slots: seq[ArtifactSlot]): NimNode =
    result = newStmtList()
    for slot in slots:
      let nameLit = newLit(slot.name)
      let slotIdent = slot.identNode.copyNimTree()
      case slot.ownership
      of soM3ExecutableArtifact:
        result.add(quote do:
          `slotIdent` = `synthPkgIdent`.executable(`nameLit`))
      of soM3LibraryArtifact:
        result.add(quote do:
          `slotIdent` = `synthPkgIdent`.library(`nameLit`))
      of soM3FilesArtifact:
        result.add(quote do:
          `slotIdent` = `synthPkgIdent`.files(`nameLit`))
      else:
        discard
  let mesonAssignments = buildAssignments(slots)
  let cmakeAssignments = buildAssignments(slots)
  let autotoolsAssignments = buildAssignments(slots)
  let dispatchBlock = quote do:
    let conv = defaultBuildConventionFor(`pkgLit`)
    if shouldSynthesizeDefaultBuild(`pkgLit`,
                                    hasExplicitBuild = false,
                                    hasFetchBlock = true):
      let `srcDirIdent` = "./src"
      case conv
      of ConventionMeson:
        let `synthPkgIdent` = synthesizeMesonPackage(`pkgLit`, `srcDirIdent`)
        `mesonAssignments`
      of ConventionCmake:
        let `synthPkgIdent` = synthesizeCmakePackage(`pkgLit`, `srcDirIdent`)
        `cmakeAssignments`
      of ConventionAutotools, ConventionMake:
        let `synthPkgIdent` = synthesizeAutotoolsPackage(`pkgLit`,
          `srcDirIdent`)
        `autotoolsAssignments`
      else:
        discard
    elif conv == ConventionCustom:
      # Custom-shell driver toolset with no ``build:`` body — raise an
      # actionable error at module init.
      raiseCustomBuildRequired(`pkgLit`)
  # Wrap the dispatch in the same begin/end-build-context bookkeeping
  # ``emitM4BuildActions`` uses so the registry surface sees the synth
  # block as an attributable build action. The verbatim body splice is
  # gated on ``when not defined(reproProviderMode)`` to match the
  # provider-mode disjointness rule (the legacy
  # ``buildXxxPackage*()`` chain re-runs the same body under
  # ``runPackageProvider`` + ``isMainModule``). The block is further
  # gated on ``when compiles(defaultBuildConventionFor(...)):`` so
  # recipes that did NOT import ``repro_dsl_stdlib/synthesis`` produce
  # no emission at all — the convention layer's fetch + sentinel
  # actions still emit.
  let synthBlock = quote do:
    when compiles(defaultBuildConventionFor(`pkgLit`)):
      from repro_dsl_stdlib/install_mirror_tools import registerInstallMirrorTools
      block:
        if shouldSynthesizeDefaultBuild(`pkgLit`, hasExplicitBuild = false,
                                       hasFetchBlock = true):
          registerInstallMirrorTools(`pkgLit`, `sourceFile`, `sourceLine`)
        registerBuildAction(`pkgLit`, `artifactLit`, `bodyReprLit`)
        beginBuildContext(`pkgLit`, `artifactLit`)
        try:
          when not defined(reproProviderMode) and
              not defined(reproInterfaceMode):
            `dispatchBlock`
        finally:
          endBuildContext()
  result.add(synthBlock)

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

proc nlfM8MultiVersionLit(text: string; node: NimNode): NimNode =
  ## Named-Lock-Files NLF-M8 (§9.3) — lower a ``multiVersion`` literal to a
  ## ``MultiVersionPolicy`` enum value.
  ##
  ## The two spellings §9.3 writes are the only two accepted. In particular
  ## there is no ``multiVersion unset``: writing the line is the act of making
  ## a claim, so a spelling that means "I wrote a line that says nothing"
  ## would be a way to look like an author who considered the question without
  ## having answered it — which is the state §9.3's naming exists to keep
  ## distinguishable from silence.
  case text.normalize
  of "forbidden": ident("mvForbidden")
  of "allowed":   ident("mvAllowed")
  else:
    error("library api: multiVersion must be one of: forbidden, allowed " &
          "(got '" & text & "'). See Named-Lock-Files.md §9.3 — omitting the " &
          "line inherits `forbidden` from the language convention.", node)
    ident("mvForbidden")

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
      of "multiversion":
        # Named-Lock-Files NLF-M8, design §9.3 — the per-library property,
        # beside `linkKind` because it is consumption metadata of the same
        # kind. The source position recorded is the `multiVersion` LINE's,
        # because §9.4's diagnostic cites the declaration the author has to
        # change and the library's own line is not that.
        if fieldStmt.len < 2:
          error("library api: multiVersion requires a value " &
                "(forbidden | allowed)", fieldStmt)
        let valueNode = fieldStmt[1]
        let parsed = m9r3IdentOrStrText(valueNode)
        if not parsed.ok:
          error("library api: multiVersion must be one of: forbidden, allowed",
                valueNode)
        let policyLit = nlfM8MultiVersionLit(parsed.text, valueNode)
        let info = fieldStmt.lineInfoObj
        let fileLit = newLit(info.filename)
        let lineLit = newLit(info.line)
        setters.add(quote do:
          `apiSym`.multiVersion = `policyLit`
          `apiSym`.multiVersionSourceFile = `fileLit`
          `apiSym`.multiVersionSourceLine = `lineLit`)
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

macro resourceModule*(modulePath: static string; body: untyped = nil): untyped =
  ## TI2 producer-surface declaration: a producer's ``repro.nim`` NAMES the
  ## separate module carrying its ``resourceType`` blocks (the RP5c2 vm-harness
  ## shape — ``src/vm_harness/repro/resources.nim`` — NOT inline in
  ## ``repro.nim``), plus any extra ``--path`` search roots that module's imports
  ## need, WITHOUT importing it into the core build:
  ##
  ## .. code-block:: nim
  ##   resourceModule "src/vm_harness/repro/resources.nim":
  ##     path "src"
  ##
  ## This is a PURE MARKER. It expands to nothing, so a producer's core
  ## ``just build`` (which compiles ``repro.nim`` but imports only
  ## ``repro_project_dsl``) never pulls in the resource module's driver closure
  ## — the module stays outside the core build (RP5c1 invariant).
  ##
  ## The declaration is consumed at CONSUMER macro-expansion by a TEXTUAL scan of
  ## the producer's ``repro.nim`` (``producerDeclaredResourceModule`` in
  ## ``macros_a``), NOT by importing this module — so detection
  ## (``workspaceProducerDeclaresResourceType``), the accessor-cache freshness
  ## stamp (``producerSourceStamp``), and the interface-lift resolve
  ## (``resolveProducerTypedContract`` → ``interfaceLiftPlan`` with
  ## ``resourceModule``/``extraPaths``) all read the SAME declared module +
  ## extra paths. The body's ``path "<dir>"`` entries name extra ``--path``
  ## roots relative to the producer root.
  discard modulePath
  discard body
  newEmptyNode()

proc provisioningContributionLiteral(
    contribution: ProvisioningContributionDef): string =
  result = "ProvisioningContributionDef(targetPackage: " &
    escForCode(contribution.targetPackage) &
    ", targetInterfaceFingerprint: " &
    escForCode(contribution.targetInterfaceFingerprint) &
    ", contributor: " & escForCode(contribution.contributor) &
    ", developInterface: " & $contribution.developInterface &
    ", nixProvisioning: @["
  for i, provisioning in contribution.nixProvisioning:
    if i > 0: result.add(", ")
    # Spliced verbatim, in step with ``macros_a.packageLiteral``.
    result.add("NixPackageProvisioningDef(selector: " &
      codeOrEmpty(provisioning.selector) &
      ", executablePath: " & codeOrEmpty(provisioning.executablePath) &
      ", expressionFile: " & codeOrEmpty(provisioning.expressionFile) &
      ", nixpkgsRef: " & codeOrEmpty(provisioning.nixpkgsRef) &
      ", nixpkgsRev: " & codeOrEmpty(provisioning.nixpkgsRev) &
      ", nixpkgsNarHash: " & codeOrEmpty(provisioning.nixpkgsNarHash) &
      ", packageId: " & codeOrEmpty(provisioning.packageId) &
      ", lockIdentity: " & codeOrEmpty(provisioning.lockIdentity) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], tarballProvisioning: @[")
  for i, provisioning in contribution.tarballProvisioning:
    if i > 0: result.add(", ")
    # Spliced verbatim — these fields hold emittable SOURCE. Kept in step with
    # the identical emitter in ``macros_a.packageLiteral``; the two must agree,
    # since a `provisioningFor` contribution and an in-package `provisioning:`
    # block are the same declaration reached by different routes.
    result.add("TarballProvisioningDef(url: " &
      codeOrEmpty(provisioning.url) & ", mirrors: @[")
    for j, mirror in provisioning.mirrors:
      if j > 0: result.add(", ")
      result.add(mirror)
    result.add("], prunePaths: @[")
    for j, prunePath in provisioning.prunePaths:
      if j > 0: result.add(", ")
      result.add(prunePath)
    result.add("], sha256: " & codeOrEmpty(provisioning.sha256) &
      ", executableAlias: " & codeOrEmpty(provisioning.executableAlias) &
      ", nonRedistributable: " & $provisioning.nonRedistributable &
      ", launcher: " & codeOrEmpty(provisioning.launcher) &
      ", closureManifest: " & codeOrEmpty(provisioning.closureManifest) &
      ", archiveType: " & codeOrEmpty(provisioning.archiveType) &
      ", executablePath: " & codeOrEmpty(provisioning.executablePath) &
      ", stripComponents: " & $provisioning.stripComponents &
      ", packageId: " & codeOrEmpty(provisioning.packageId) &
      ", lockIdentity: " & codeOrEmpty(provisioning.lockIdentity) &
      ", cpu: " & codeOrEmpty(provisioning.cpu) &
      ", os: " & codeOrEmpty(provisioning.os) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], scoopProvisioning: @[")
  for i, provisioning in contribution.scoopProvisioning:
    if i > 0: result.add(", ")
    # Spliced verbatim, in step with ``macros_a.packageLiteral``.
    result.add("ScoopProvisioningDef(bucket: " &
      codeOrEmpty(provisioning.bucket) &
      ", app: " & codeOrEmpty(provisioning.app) &
      ", version: " & codeOrEmpty(provisioning.version) &
      ", preferredVersion: " & codeOrEmpty(provisioning.preferredVersion) &
      ", manifestChecksum: " & codeOrEmpty(provisioning.manifestChecksum) &
      ", manifestUrl: " & codeOrEmpty(provisioning.manifestUrl) &
      ", executablePath: " & codeOrEmpty(provisioning.executablePath) &
      ", requiresExecutionProfileChecksum: " &
        $provisioning.requiresExecutionProfileChecksum &
      ", packageId: " & codeOrEmpty(provisioning.packageId) &
      ", lockIdentity: " & codeOrEmpty(provisioning.lockIdentity) &
      ", sourceFile: " & escForCode(provisioning.sourceFile) &
      ", sourceLine: " & $provisioning.sourceLine & ")")
  result.add("], sourceFile: " & escForCode(contribution.sourceFile) &
    ", sourceLine: " & $contribution.sourceLine & ")")

macro provisioningFor*(target: untyped; body: untyped): untyped =
  ## Publish realization metadata for a package interface owned by another
  ## module. The contribution is ordinary static registry data, so interface
  ## extraction can carry it without executing a provider at resolution time.
  var contribution = ProvisioningContributionDef(
    targetPackage: stringLiteral(target),
    sourceFile: target.lineInfoObj().filename,
    sourceLine: target.lineInfoObj().line)
  let statements = if body.kind == nnkStmtList: body else: newStmtList(body)
  for stmt in statements:
    let rawName =
      if stmt.kind in {nnkIdent, nnkSym}: $stmt
      else: calleeName(stmt)
    let name = rawName.normalize
    case name
    of "interfacefingerprint":
      if stmt.len != 2:
        error("interfaceFingerprint expects exactly one string literal", stmt)
      contribution.targetInterfaceFingerprint = stringLiteral(stmt[1])
    of "contributor":
      if stmt.len != 2:
        error("contributor expects exactly one string literal", stmt)
      contribution.contributor = stringLiteral(stmt[1])
    of "developinterface":
      contribution.developInterface = true
    of "nixpackage":
      contribution.nixProvisioning.add(parseNixPackageProvisioning(stmt))
    of "tarball":
      contribution.tarballProvisioning.add(parseTarballProvisioning(stmt))
    of "scoopapp", "scooppackage":
      contribution.scoopProvisioning.add(parseScoopProvisioning(stmt))
    else:
      error("unsupported provisioningFor entry: " & rawName, stmt)
  if contribution.targetPackage.len == 0:
    error("provisioningFor requires a non-empty package name", target)
  if contribution.contributor.len == 0:
    error("provisioningFor requires contributor \"...\"", target)
  if contribution.targetInterfaceFingerprint.len == 0 and
      not contribution.developInterface:
    error("provisioningFor requires interfaceFingerprint or developInterface",
      target)
  if contribution.nixProvisioning.len == 0 and
      contribution.tarballProvisioning.len == 0 and
      contribution.scoopProvisioning.len == 0:
    error("provisioningFor requires at least one realization", target)
  parseStmt("registerProvisioningContributionDef(" &
    provisioningContributionLiteral(contribution) & ")")


const
  reproBin* {.strdefine.} = ""
    ## Absolute path to the engine binary, handed in by the recipe compile.
    ## Empty outside that compile (a plain `nim c` of a recipe), which is
    ## exactly when the import emission below must stay silent.
  reproConsumerRoot* {.strdefine.} = ""
    ## The consumer repo the recipe belongs to. The macro cannot derive it:
    ## it expands in the extraction scratch directory, so `getProjectPath()`
    ## points there rather than at the project.

proc collectDslDeps(sectionStmts: NimNode): seq[string] =
  ## Package names listed in a top-level ``dslDeps:`` block, in declaration
  ## order, deduplicated.
  ##
  ## NOT ``uses:``. ``uses:`` declares TOOLS to provision and mixes bare
  ## version requirements (``"nim >=2.0"``) with nested ``uses "<x>"``
  ## package entries, which is why the engine-side reader
  ## (``declaredPackageDeps``) has to tell those apart. A ``dslDeps:`` body
  ## is uniformly one bare package name per line, so every string literal in
  ## it is a name and there is no version grammar to filter.
  for section in sectionStmts:
    if section.kind notin {nnkCall, nnkCommand}:
      continue
    if section.len < 2 or section[0].kind notin {nnkIdent, nnkSym}:
      continue
    if ($section[0]).normalize != "dsldeps":
      continue
    let body = section[^1]
    if body.kind != nnkStmtList:
      continue
    # Body is a sequence of bare string literals, one package per line --
    # the same shape `mesonOptions:` / `cmakeFlags:` use. No version
    # grammar here: a DSL-export dependency is imported at recipe-compile
    # time from a workspace checkout, so there is no version to resolve.
    for stmt in body:
      if stmt.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        continue
      let name = stmt.strVal
      if name.len > 0 and name notin result:
        result.add(name)

proc importAliasFor(name: string): string =
  ## A collision-free alias. EVERY package's DSL export module is named
  ## ``repro.nim``, so a bare ``import repro`` would be ambiguous across two
  ## dependencies and would also clash with the consumer's own recipe. The
  ## import is therefore path-qualified and aliased per dependency.
  result = "repro_dep_"
  for ch in name:
    let ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
             (ch >= '0' and ch <= '9')
    result.add(if ok: ch else: '_')

proc emitDeclaredPackageImports(sectionStmts: NimNode): NimNode =
  ## STAGE 1 of the two-stage expansion: turn each declared package
  ## dependency into an ``import`` of that package's own ``repro.nim``, so
  ## the public ``foo*`` symbols it defines are in scope for the rest of the
  ## recipe -- the standard Nim export mechanism, with no separate manifest
  ## of "what this package contributes to the DSL".
  ##
  ## Resolution goes through the ENGINE (``internal resolve-package``) rather
  ## than being reimplemented here, so the path this imports and the path the
  ## engine puts on ``--path:`` come from one function and cannot drift.
  ##
  ## Emits NOTHING unless every precondition holds: the defines are present
  ## (so a plain ``nim c`` of a recipe is unchanged), the dependency resolves,
  ## and it actually ships a ``repro.nim``. A dependency with no DSL surface
  ## is normal -- most are ordinary build dependencies -- and must not become
  ## a compile error.
  result = newStmtList()
  when reproBin.len == 0 or reproConsumerRoot.len == 0:
    when defined(reproDslDepsDebug):
      static: echo "DSLDEPS-DEBUG: defines absent"
    return
  else:
    when defined(reproDslDepsDebug):
      static: echo "DSLDEPS-DEBUG: bin=" & reproBin & " root=" & reproConsumerRoot
    let collected = collectDslDeps(sectionStmts)
    when defined(reproDslDepsDebug):
      echo "DSLDEPS-DEBUG: collected=" & $collected
    for name in collected:
      # Quoted by hand rather than with `quoteShell`: this module is
      # `include`d, so it inherits whatever the host imported, and the
      # emission must not add a new import dependency to every recipe.
      let resolved = staticExec(
        reproBin & " internal resolve-package \"" &
        reproConsumerRoot & "\" \"" & name & "\"").strip()
      if resolved.len == 0:
        continue
      let recipe = resolved & "/repro.nim"
      if not fileExists(recipe):
        continue
      result.add(
        nnkImportStmt.newTree(
          nnkInfix.newTree(
            ident("as"),
            newLit(recipe),
            ident(importAliasFor(name)))))

macro package*(name: untyped; body: untyped): untyped =
  ## Top-level package declaration — STAGE 1.
  ##
  ## This stage interprets nothing. Its whole job is to find the canonical
  ## ``platforms <expr>`` declaration, wrap that ONE sub-expression in a scope
  ## where the platform vocabulary is bound, and hand both the resulting value
  ## and the untouched body to ``packageImpl``. Everything else — every
  ## section handler, every emission — happens in stage 2, unchanged.
  ##
  ## Why the split exists, in one line: it makes ``windows`` a symbol the
  ## compiler resolves instead of an identifier a macro reads as text, which
  ## is what gives a typo the compiler's own caret and spelling suggestion,
  ## puts name resolution under Nim's scope rules rather than under this
  ## macro's, and makes ``platforms desktopSet`` work with no second code
  ## path. ``DSL-Macro-Authoring-Guide.md`` in reprobuild-specs has the long
  ## version.
  ##
  ## The body is passed on VERBATIM, ``platforms`` statement included. Stage 2
  ## therefore still holds the author's original nodes and can point
  ## ``error(msg, node)`` at the right line — the diagnostics regression
  ## usually assumed to be the price of staging is not one.
  # Dependency blocks are lowered into ONE expression yielding every entry,
  # tagged by `depKind` so stage 2 can route each back to its own list. The
  # `when`s inside them ride along with their conditions untouched, so the
  # compiler -- not this macro -- decides which entries a host contributes.
  #
  # One combined parameter rather than four: the four blocks differ only by
  # the tag already on every entry, and a single list keeps the order they
  # were written in, which the lists downstream rely on.
  let usesAccum = genSym(nskVar, "reproAllUses")
  let usesStmts = newNimNode(nnkStmtList)
  usesStmts.add(nnkVarSection.newTree(nnkIdentDefs.newTree(
    usesAccum,
    nnkBracketExpr.newTree(bindSym"seq", bindSym"PackageUseDef"),
    newCall(ident("@"), newNimNode(nnkBracket)))))
  var sawUsesBlock = false
  for stmt in body:
    let head = calleeName(stmt).normalize
    let depKind =
      case head
      of "uses", "builddeps": DepKindTarget
      of "nativebuilddeps": DepKindNative
      of "runtimedeps": DepKindRuntime
      else: ""
    if depKind.len == 0:
      continue
    for i in 1 ..< stmt.len:
      sawUsesBlock = true
      usesStmts.add(newCall(nnkDotExpr.newTree(usesAccum, ident("add")),
        lowerUsesBlock(stmt[i], depKind)))
  usesStmts.add(usesAccum)
  var usesExpr: NimNode =
    if sawUsesBlock: nnkBlockStmt.newTree(newEmptyNode(), usesStmts)
    else: bindSym"NoPackageUses"

  var provisioningExpr: NimNode = bindSym"NoToolProvisioning"
  var seenProvisioning = false
  var declaredExpr: NimNode = bindSym"NoPlatformConstraints"
  var seenPlatforms = false
  for stmt in body:
    # `defaultToolProvisioning <expr>` gets the same treatment as `platforms`
    # below: wrap the ONE sub-expression in the scope that binds the mode
    # vocabulary and let the compiler evaluate it. Stage 2 then receives a
    # value and never has to ask what the author wrote.
    #
    # This is what makes a computed mode work --
    # `defaultToolProvisioning(when defined(windows): tarball else: nix)` --
    # with no branch-selection logic here. A macro that tried to read the
    # `when` itself would be re-implementing a Nim evaluator, which is the
    # anti-pattern `DSL-Macro-Authoring-Guide.md` was written about: the
    # understood grammar is always a subset of Nim's, and the gap is silent.
    if stmt.kind in {nnkCall, nnkCommand} and stmt.len == 2 and
       (stmt[0].eqIdent("defaultToolProvisioning") or
        stmt[0].eqIdent("toolProvisioning")):
      if seenProvisioning:
        error("defaultToolProvisioning: may be declared only once per package",
          stmt)
      seenProvisioning = true
      provisioningExpr = newCall(bindSym"withToolProvisioningVocabulary",
        stmt[1])
    # `platforms[windows]` — no space — is `nnkBracketExpr`, array indexing,
    # not a call. Nothing downstream matches it, so without this it would
    # reach the partition as ordinary user code and fail as "undeclared
    # identifier: platforms" a long way from the actual mistake.
    if stmt.kind == nnkBracketExpr and stmt.len >= 1 and
       stmt[0].eqIdent("platforms"):
      error("platforms: missing a space — `platforms[...]` is array " &
        "indexing to Nim, not a declaration. Write `platforms [" &
        (if stmt.len > 1: stmt[1].repr else: "windows") & "]`.", stmt)
    if not isResolvedPlatformsForm(stmt) or not stmt[0].eqIdent("platforms"):
      continue
    if seenPlatforms:
      error("platforms: may be declared only once per package", stmt)
    seenPlatforms = true
    declaredExpr = newCall(bindSym"withPlatformVocabulary",
      newCall(bindSym"toConstraintDefs", stmt[1]))
  # `ident`, not `bindSym`: stage 2 is declared BELOW this macro (it is the
  # bulk of the file and reads better after the entry point), and `bindSym`
  # resolves in the definition scope, where the name does not exist yet.
  return newCall(ident("packageImpl"), name, declaredExpr, provisioningExpr,
    usesExpr, body)

macro packageImpl*(name: untyped;
                   resolvedPlatforms: static seq[PlatformConstraintDef];
                   resolvedToolProvisioning: static string;
                   resolvedUses: static seq[PackageUseDef];
                   body: untyped): untyped =
  ## Top-level package declaration — STAGE 2.
  ##
  ## ``resolvedPlatforms`` arrives as VALUES: stage 1 handed the author's
  ## expression to the compiler, so ``windows`` has become
  ## ``PlatformConstraint(cpu: "any", os: "windows")`` and a computed seq has
  ## been evaluated. ``body`` arrives untyped and unmodified, so source
  ## locations are still available for diagnostics.
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
  let pkg = parsePackageDef(name, body, resolvedPlatforms,
    resolvedToolProvisioning, resolvedUses)
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
  let declaredImports = emitDeclaredPackageImports(sectionStmts)
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
  # ── Named-Lock-Files NLF-M7: §4.9's compile error, §4.3's registration ──
  let lockFileEmission = emitLockFileDesignations(pkg, name)
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
  # Cross-Repo-Source-Consumption SC-9: anchor the workspace-producer schema
  # discovery on the CONSUMER's own source file (``name.lineInfoObj().filename``
  # — the consumer's ``repro.nim`` path at macro expansion), so a ``uses:``
  # selector naming an on-disk workspace sibling imports that producer's
  # exported CLI schema module and the consumer can bind it as a typed call.
  let consumerSourceFile = name.lineInfoObj().filename
  let movedPackageError =
    unresolvedMovedPackageDiagnostic(pkg, consumerSourceFile)
  if movedPackageError.len > 0:
    error(movedPackageError, name)
  let generated = parseStmt(
    usesImportCode(pkg, consumerSourceFile) &
    "registerPackageDef(" & packageLiteral(pkg) & ")\n" &
    wrapperCode(pkg, recordActions))
  result = newStmtList()
  # Stage-1 imports for declared package dependencies, emitted BEFORE the
  # generated body so the symbols a dependency's `repro.nim` exports are in
  # scope for it. `usesImportCode` below covers only the hardcoded allowlist
  # of BUNDLED stdlib packages; this covers everything else, which is what
  # lets a third-party package contribute DSL constructors without being
  # vendored into reprobuild's `libs/`.
  result.add(declaredImports)
  # Named-Targets M1: emit the per-tool ``implicitTargetName`` hook
  # procs BEFORE the typed-tool wrapper procs so the wrapper's
  # generated call site (``implicitTargetNameFor<TitleExportName>``)
  # type-checks against the already-declared hook.
  result.add(collectImplicitTargetNameHooks(body))
  result.add(generated)
  # Shared-Development-Services L3: the lifted service/activity surface —
  # the handle types, the `<Title>PackageExports` reflection object, the
  # accessor procs that make `<dep>.<service>` a typed symbol, and the
  # `registerActivityInterface` / `registerServiceInterface` records
  # `toProjectInterface` folds into the interface artifact. Emitted AFTER
  # `generated` because the accessors' first parameter is the
  # `<Title>Package` type `wrapperCode` declares there, and at module
  # scope rather than inside `buildCode` because `buildCode`'s whole
  # result sits under `when not defined(reproInterfaceMode)` — the one
  # mode that performs the lift.
  result.add(l3LiftedExportSurface(pkg, body))
  result.add(l3DependencyReferenceChecks(pkg, body))
  # Spec-Implementation M1: emit ``let <name> = declareVariant[T](...)``
  # bindings + the trailing ``finalizeVariants()`` call at top-level
  # module scope (after the package wrapper code so the variant
  # accessor symbols are visible to ``build:`` code emitted below).
  result.add(lockFileEmission)
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
  # ── DSL-port M9.R.2c: per-kind typed artifact slot ``var`` decls.
  # MUST sit BEFORE ``buildCode`` so the slot bindings precede the
  # generated ``build<Pkg>*()`` proc whose body may assign to them
  # via the assignment-binding pattern documented in
  # ``From-Source-Build-Recipes.md`` §"Artifact binding by assignment".
  # The companion ``registerArtifact`` calls still ride on
  # ``emitM3Artifacts`` further below — they don't need to precede
  # ``buildCode`` since the build body never references them.
  let m9r2cArtifactSlotEmission =
    emitM9R2cArtifactSlots(packageName, classifiedSections)
  if m9r2cArtifactSlotEmission.len > 0:
    result.add(quote do:
      import repro_dsl_stdlib/types)
  result.add(m9r2cArtifactSlotEmission)
  # ── existing builder emission (now feeding instrumented body) ────
  # M9.R.13b.3 — DEFERRED: `buildCode` emits
  # ``when defined(reproProviderMode) and isMainModule: quit
  # runPackageProvider(...)`` at module top level, which exits the
  # process during ``NimMainModule`` BEFORE any subsequent top-level
  # registration call (``registerFetchSpec`` from M9.H,
  # ``registerVersion`` from M2, ``registerArtifact`` from M3,
  # ``registerLibraryApi`` from M9.R.3, etc.) runs. The runtime
  # registries that the build body queries (``registeredFetchSpec``
  # inside the ``autotools_package`` / ``cmake_package`` /
  # ``meson_package`` constructors, for example) therefore see empty
  # tables and the auto-emitted fetch action never makes it into the
  # graph -- ``./src/configure`` fails ``exit 127`` because the
  # source tree was never extracted. Deferring ``buildCode``'s
  # emission to AFTER every other ``register*`` emission below moves
  # the ``quit`` past those registrations so they all run during
  # ``NimMainModule`` before the process exits. The buildCode-after
  # ordering is structurally equivalent to the prior layout for
  # non-provider-mode builds (where no ``quit`` is emitted at all)
  # and only changes the execution order under
  # ``reproProviderMode + isMainModule``.
  let buildCodeEmission = buildCode(pkg, bodyForBuild)
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
  # ── Shared-Development-Services L5: each dev-env activity's `config:`
  # key becomes a CONFIGURABLE under `<package>.<activity>.<name>`, so
  # §6's `sso.externalDomain = ...` has an existing slot to bind rather
  # than needing a second lane. Emitted directly after M2's package-level
  # `config:` registrations because it is the same statement about the
  # other authoring surface, and BEFORE the environment emission below,
  # which writes into these slots.
  result.add(emitL5ActivityConfigDefaults(packageName, sectionStmts))
  # ── DSL-port M3: artifact registrations. Appended LAST so the
  # body repr captured at macro-expansion time is available to any
  # downstream consumer (M4+ will read this list at compile time via
  # the partitioned section walk; the runtime registry is the
  # diagnostic surface tests use today).
  result.add(m3ArtifactEmission)
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
  #
  # ORDERING (must stay ABOVE the M4 ``build:`` lowering below). The
  # Layer-1 constructors a ``build:`` body calls (``cmake_package`` /
  # ``meson_package`` / ``autotools_package``) query this registry
  # WHILE THE BODY RUNS — the declared deps decide auto-threaded cache
  # vars, link-library dirs and CMake module paths. Emitting the
  # registrations after the body left the FIRST module-init pass
  # reading an EMPTY dep list (so the auto-threading silently did
  # nothing) while any later pass in the same process read the rows the
  # first pass had left behind. A recipe reachable twice in one process
  # — the per-consumer sibling shims materialise one module instance
  # per consumer, so a diamond in the source dep closure instantiates a
  # shared recipe several times — therefore produced TWO DIFFERENT
  # configure actions for one package and tripped the Named-Targets
  # within-package collision check. Registering first makes every pass
  # read the same declared dep list, so the lowered graph is a pure
  # function of the recipe.
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
  if m9hFetchEmission.len > 0:
    let fetchPackageName = newLit(packageName)
    let fetchSourceFile = newLit(pkg.sourceFile)
    let fetchSourceLine = newLit(pkg.sourceLine)
    result.add(parseStmt(
      "from repro_dsl_stdlib/source_fetch_tools import registerSourceFetchTools\n"))
    result.add(quote do:
      registerSourceFetchTools(`fetchPackageName`, `fetchSourceFile`,
        `fetchSourceLine`))
  if usesInstallMirrorBuildCall(collectBuildStatements(bodyForBuild, packageName)):
    let mirrorPackageName = newLit(packageName)
    let mirrorSourceFile = newLit(pkg.sourceFile)
    let mirrorSourceLine = newLit(pkg.sourceLine)
    result.add(parseStmt(
      "from repro_dsl_stdlib/install_mirror_tools import registerInstallMirrorTools\n"))
    result.add(quote do:
      registerInstallMirrorTools(`mirrorPackageName`, `mirrorSourceFile`,
        `mirrorSourceLine`))
  # ── DSL-port M9.R.10b: default ``build:`` synthesis. When a recipe
  # declares ``fetch:`` AND no explicit ``build:`` block, dispatch to
  # the ``synthesizeMesonPackage`` / ``synthesizeCmakePackage`` /
  # ``synthesizeAutotoolsPackage`` stdlib entry points based on the
  # recipe's recognised ``nativeBuildDeps:`` tool. The dispatch is
  # ``when compiles(...)``-gated so recipes that did NOT import
  # ``repro_dsl_stdlib/synthesis`` produce no emission. See the
  # ``emitM9R10bDefaultBuildSynthesis`` doc comment for the full
  # dispatch matrix + gating rationale.
  let m9r10bSynthesisEmission =
    emitM9R10bDefaultBuildSynthesis(packageName, classifiedSections,
      pkg.sourceFile, pkg.sourceLine)
  result.add(m9r10bSynthesisEmission)
  # ── DSL-port M9.R.6.1: the M9.I block emitter is GONE. Recipes
  # spell per-tool options via an explicit ``build:`` body calling
  # one of the M9.R.2b Layer-1 typed constructors
  # (``meson_package(...)`` / ``cmake_package(...)`` /
  # ``autotools_package(...)``) with the option seq inlined as a
  # ``configureOptions`` / ``cacheVars`` argument. A recipe that
  # still declares a ``mesonOptions:`` / ``cmakeFlags:`` /
  # ``configureFlags:`` / ``makeFlags:`` / ``ninjaFlags:`` block
  # falls through the ``classifySectionStmt`` arms to the legacy
  # parser which silently discards unknown sections (see the
  # comment on the ``else`` arm in ``cross_project.nim``).
  # ── DSL-port M9.R.1: the dep-block registration emission USED to sit
  # here. It now runs BEFORE the M4 ``build:`` lowering (see the
  # emission site above ``m4BuildActionEmission``) because the Layer-1
  # package constructors read the dep registry while the body executes.
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
  # ── Shared-Development-Services L5: `environment <name>:` binding
  # sets and `instanceOverrides <package>.<service>:` consumer records.
  # Emitted LAST of the register-* passes and before ``buildCode``, for
  # one ordering reason that is load-bearing: the trailing
  # ``applySelectedEnvironment`` contributes the selected environment's
  # bindings through ``setConfigurable``, which REQUIRES the slot to
  # exist -- so every ``recordConfigDefault`` emission (M2's package
  # level and L5's activity level) has to have run first. Nothing below
  # reads a configurable at module-init time, so nothing is left reading
  # a pre-environment value.
  let l5EnvironmentEmissionNode = emitL5Environments(packageName,
                                                     sectionStmts, body)
  result.add(l5EnvironmentEmissionNode)
  # ── Shared-Development-Services L8: `contribute:` sections. Emitted
  # AFTER the environment pass for the ordering reason that pass states
  # for itself -- every contribution-point slot has to exist before a
  # contribution can reach it, and `applySelectedEnvironment` is where a
  # `replace` from an environment lands. Within the fold the order of
  # these calls only decides ties at one priority, which §Resolution
  # settles as "contribution order"; so emission order here IS the
  # authored order and nothing re-sorts it.
  result.add(emitL8Contributions(packageName, sectionStmts, body))
  # M9.R.13b.3 — emit ``buildCode`` LAST so its
  # ``when defined(reproProviderMode) and isMainModule: quit
  # runPackageProvider(...)`` exit point runs AFTER every other
  # register-* top-level statement above. The quit is what made the
  # M9.H ``registerFetchSpec`` (and every other registration emitted
  # below it in the prior layout) unreachable under
  # ``reproProviderMode``; moving buildCode to the end restores the
  # invariant the runtime relies on (all module-init registrations
  # run before the provider protocol takes over the process).
  result.add(buildCodeEmission)

macro projectExtension*(name: untyped; originalProject: untyped;
                        body: untyped): untyped =
  ## Workspace-Manifest-Optional MO-6 — ``projectExtension <name>,
  ## <originalProject>:`` declares an EXTENSION recipe that contributes
  ## libraries, build-graph edges, and named targets ONTO an
  ## already-defined ``originalProject`` *without modifying that
  ## project's source*. See
  ## ``reprobuild-specs/Project-DSL-Composition.md`` §"Project
  ## extensions".
  ##
  ## The body shape is identical to ``package`` / ``project`` — ``uses:``,
  ## ``library``, ``executable``, ``build:`` with typed-tool calls,
  ## let-bound edges, and ``aggregate(...)`` targets all mean exactly
  ## what they mean inside a ``package`` block. The macro therefore
  ## lowers the body through the SAME package mechanics, emitting a
  ## fully-formed provider package named ``name``. When this recipe is
  ## checked out as a develop-mode sibling of ``originalProject``, the
  ## CLI's recipe-discovery pass
  ## (``discoverProjectExtensionRecipes`` in
  ## ``libs/repro_cli_support/src/repro_cli_support.nim``) finds it by
  ## the ``projectExtension <ext>, <originalProject>:`` head and merges
  ## the extension's provider-graph fragments into ``originalProject``'s
  ## snapshot at build time — so ``repro build <originalProject>`` yields
  ## the AUGMENTED graph. When the extension repo is absent it is simply
  ## not discovered and ``originalProject`` builds standalone (the
  ## extension is inert; no error).
  ##
  ## This is distinct from ``uses:`` (the CONSUME path): ``uses:`` pulls
  ## a producer's exported binding INTO a consumer; ``projectExtension``
  ## pushes new edges/targets OUTWARD onto an unaware target. The two do
  ## NOT share a code path — ``uses:`` flows through
  ## ``registerCrossProjectUses`` / ``generatedCrossProjectAccessors``;
  ## ``projectExtension`` flows through the CLI's snapshot-merge pass.
  expectKind(name, {nnkIdent, nnkSym, nnkAccQuoted, nnkStrLit})
  expectKind(originalProject, {nnkIdent, nnkSym, nnkAccQuoted, nnkStrLit})
  # The ``originalProject`` argument names the extended project; it is
  # consumed by the CLI's textual recipe-discovery convention rather than
  # by macro expansion. Validate it (above) so a malformed head fails at
  # the recipe rather than silently mis-routing the contribution.
  result = newStmtList(newCall(bindSym"package", name, body))

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
