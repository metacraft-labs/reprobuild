## Project-DSL-Composition M5 — cross-project edge references.
##
## Ported from the v8 prototype's `intended/reprobuild.nim` (lines
## 1085-1346). Three pieces:
##
##   1. Compile-time `uses:` registry + cycle detection.
##   2. Top-level `build:` binding collection (the `let foo = ...`
##      shapes whose RHS becomes a public member of `<package>.build`).
##   3. Storage / accessor-template / instrumentation code generators.
##
## The shapes mirror v8 verbatim where Nim semantics let us; the
## differences are flagged inline.

type
  CrossProjectBuildBinding = object
    ## One top-level `let`/`var` binding inside a producer's `build:`
    ## block.
    name: string
    rhs: NimNode
    typeAnnot: NimNode

# ---------------------------------------------------------------------------
# Compile-time uses-registry + cycle detection (v8 lines 1085-1132).
# ---------------------------------------------------------------------------

var crossProjectUsesRegistry {.compileTime.}:
    seq[tuple[name: string; uses: seq[string]]] = @[]

proc lookupUsesForPackage(name: string): seq[string] {.compileTime.} =
  for entry in crossProjectUsesRegistry:
    if entry.name == name:
      return entry.uses
  return @[]

proc transitivelyUses(name, target: string;
                      seen: var seq[string]): bool {.compileTime.} =
  if name in seen:
    return false
  seen.add name
  for u in lookupUsesForPackage(name):
    if u == target:
      return true
    if transitivelyUses(u, target, seen):
      return true
  return false

proc registerCrossProjectUses(packageName: string;
                              usesList: seq[string]) {.compileTime.} =
  for i in 0 ..< crossProjectUsesRegistry.len:
    if crossProjectUsesRegistry[i].name == packageName:
      crossProjectUsesRegistry[i] = (packageName, usesList)
      return
  crossProjectUsesRegistry.add (packageName, usesList)

proc detectCrossProjectCycle(packageName: string;
                             usesList: seq[string]): string {.compileTime.} =
  ## Non-empty string == cycle detected. v8 error wording preserved.
  for u in usesList:
    var seen: seq[string] = @[]
    if transitivelyUses(u, packageName, seen):
      return "cross-project build-reference cycle detected: '" &
        packageName & "' uses '" & u & "', which transitively uses '" &
        packageName & "'. Break the cycle by inlining one side's edges " &
        "or factoring the shared bindings into a third package."
  return ""

# ---------------------------------------------------------------------------
# Top-level binding collection (v8 lines 1162-1225).
# ---------------------------------------------------------------------------

proc sanitizeIdentJoin(parts: varargs[string]): string =
  ## Join idents with `_` while replacing consecutive underscores and
  ## leading-underscore segments so the result is a valid Nim ident.
  ## Bindings authored as `_t_engine_x` (leading `_`) flow through
  ## here unchanged in their suffix segment but the JOIN never
  ## produces `__` (which Nim rejects).
  result = ""
  for part in parts:
    if part.len == 0:
      continue
    var cleaned = ""
    var lastWasUnderscore = false
    for ch in part:
      if ch == '_':
        if lastWasUnderscore:
          continue
        cleaned.add(ch)
        lastWasUnderscore = true
      else:
        cleaned.add(ch)
        lastWasUnderscore = false
    if result.len > 0 and (result[^1] == '_' or cleaned[0] == '_'):
      if result[^1] == '_' and cleaned[0] == '_':
        # both — drop the leading underscore on the new part
        result.add(cleaned[1 ..< cleaned.len])
      else:
        result.add(cleaned)
    else:
      if result.len > 0:
        result.add('_')
      result.add(cleaned)

proc composeBindingStorageIdent(packageName, bindingName: string): NimNode =
  ident(sanitizeIdentJoin("composeBindingStorage", packageName, bindingName))

proc composeBindingInitFlagIdent(packageName, bindingName: string): NimNode =
  ## M3-reviewer carry-forward: paired initialisation flag so the
  ## accessor can raise a clear "producer hasn't run yet" error.
  ident(sanitizeIdentJoin("composeBindingInit", packageName, bindingName))

proc collectBuildBindingsFromBody(body: NimNode;
                                  bindings: var seq[CrossProjectBuildBinding]) =
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    if stmt.kind in {nnkLetSection, nnkVarSection}:
      for defn in stmt:
        if defn.kind != nnkIdentDefs:
          continue
        let rhs = defn[^1]
        if rhs.kind == nnkEmpty:
          continue
        let typeNode = defn[^2]
        let annot =
          if typeNode.kind == nnkEmpty: nil
          else: typeNode.copyNimTree()
        for j in 0 ..< defn.len - 2:
          let nameNode = defn[j]
          let identNode =
            case nameNode.kind
            of nnkPragmaExpr: nameNode[0]
            of nnkPostfix: nameNode[1]
            else: nameNode
          if identNode.kind in {nnkIdent, nnkSym}:
            bindings.add CrossProjectBuildBinding(
              name: $identNode,
              rhs: rhs.copyNimTree(),
              typeAnnot: annot)

proc collectTopLevelBuildBindings(body: NimNode):
                                  seq[CrossProjectBuildBinding] =
  result = @[]
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    if stmt.kind in {nnkCall, nnkCommand} and
       stmt.len >= 2 and
       stmt[0].kind in {nnkIdent, nnkSym} and
       $stmt[0] == "build" and
       stmt[^1].kind == nnkStmtList:
      collectBuildBindingsFromBody(stmt[^1], result)

# ---------------------------------------------------------------------------
# Emission helpers (v8 lines 1227-1346).
# ---------------------------------------------------------------------------

proc generatedCrossProjectStorage(packageName: string;
                                  bindings: openArray[CrossProjectBuildBinding]):
                                  NimNode =
  ## One module-level `var` per binding plus an init-flag, both exported.
  result = newStmtList()
  for binding in bindings:
    let storageIdent = composeBindingStorageIdent(packageName, binding.name)
    let initIdent = composeBindingInitFlagIdent(packageName, binding.name)
    if binding.typeAnnot != nil:
      # An explicit type annotation is resolvable at module scope without
      # evaluating the RHS, so the storage var can always be emitted.
      let annot = binding.typeAnnot.copyNimTree()
      result.add quote do:
        var `storageIdent`*: `annot`
        var `initIdent`* {.used.}: bool = false
    else:
      # No annotation: we must infer the type from the RHS via
      # `typeof`. The RHS is evaluated HERE at module scope, where
      # `build:`-block-local helpers (templates/procs defined inside the
      # block) and sibling build-local bindings are NOT visible. If the
      # type does not resolve here, the binding cannot back a
      # module-level cross-project storage var — so we skip the storage
      # entirely rather than emit an `undeclared identifier` hard error.
      # Such a binding stays a plain build-local `let` (still preserved
      # by the lowered builder); it just isn't reachable as
      # `<pkg>.build.<binding>`. The paired accessor template and the
      # storage-write splice both key off `when declared(<storageIdent>)`
      # so they consistently skip when the storage is absent.
      let rhs = binding.rhs.copyNimTree()
      result.add quote do:
        when compiles(typeof(`rhs`)):
          var `storageIdent`*: typeof(`rhs`)
          var `initIdent`* {.used.}: bool = false

proc generatedCrossProjectPackageConst(packageName: string;
                                       bindings:
                                         openArray[CrossProjectBuildBinding];
                                       perPackageConstAlreadyEmitted: bool;
                                       legacyPackageTypeIdent: NimNode):
                                       NimNode =
  ## Emit one of two shapes:
  ##
  ## 1. **Legacy const claimed the ident** (the common production case —
  ##    `wrapperCode` always emits `const <pkg>* = <Title>Package()`).
  ##    We can NOT shadow that const. Instead emit a bridging template
  ##    that lets `<pkg>.build` resolve to `PackageBuild["<pkg>"]`:
  ##
  ##        template build*(p: `legacyType`): PackageBuild["<pkg>"] =
  ##          PackageBuild["<pkg>"]()
  ##
  ##    The per-binding accessor templates (emitted via
  ##    `generatedCrossProjectAccessors`) dispatch on
  ##    `PackageBuild[name]` so the chain `<pkg>.build.<binding>`
  ##    type-checks end-to-end.
  ##
  ## 2. **No legacy const** (package has no executables / commands):
  ##    emit the v8-shape const directly.
  if bindings.len == 0:
    return newStmtList()
  let packageLit = newLit(packageName)
  if perPackageConstAlreadyEmitted:
    let legacyType = legacyPackageTypeIdent.copyNimTree()
    return quote do:
      template build*(p: `legacyType`): PackageBuild[`packageLit`] =
        PackageBuild[`packageLit`]()
  let packageIdent = ident(packageName)
  result = quote do:
    const `packageIdent`* {.inject.}: Package[`packageLit`] =
      Package[`packageLit`]()

proc generatedCrossProjectAccessors(packageName: string;
                                    bindings:
                                      openArray[CrossProjectBuildBinding]):
                                    NimNode =
  ## Per-binding accessor template — `<pkgName>.build.<binding>` resolves
  ## via Nim method-call syntax: `<pkgName>` is `Package[name]`,
  ## `.build` returns `PackageBuild[name]` (prelude template), and
  ## `<binding>` matches a template overloaded on `PackageBuild[name]`.
  ##
  ## Build-order guard (M3-reviewer carry-forward): the template body
  ## checks the init flag and raises a clear error if the consumer
  ## tries to read before the producer's builder ran.
  result = newStmtList()
  for binding in bindings:
    let templateIdent = ident(binding.name)
    let storageIdent = composeBindingStorageIdent(packageName, binding.name)
    let initIdent = composeBindingInitFlagIdent(packageName, binding.name)
    let packageLit = newLit(packageName)
    let bindingLit = newLit(binding.name)
    # Gate the accessor on the storage var actually existing: a
    # non-annotated binding whose RHS does not type at module scope is
    # not exposed (see `generatedCrossProjectStorage`), so its accessor
    # must be skipped too — otherwise it would reference an undeclared
    # `storageIdent`.
    result.add quote do:
      when declared(`storageIdent`):
        template `templateIdent`*(b: PackageBuild[`packageLit`]): auto =
          if not `initIdent`:
            raise newException(ValueError,
              "cross-project build binding '" & `packageLit` & ".build." &
              `bindingLit` & "' read before producer build: block ran. " &
              "Ensure '" & `packageLit` & "' is built before the consumer.")
          `storageIdent`

proc instrumentBuildBindings(body: NimNode;
                             packageName: string;
                             bindings: openArray[CrossProjectBuildBinding]):
                             NimNode =
  ## Walk the outermost `build:` block(s) and splice a storage-write +
  ## init-flag-set after each top-level `let`/`var` that the collector
  ## picked up. Returns a fresh tree.
  if bindings.len == 0:
    return body.copyNimTree()
  result = body.copyNimTree()
  if result.kind != nnkStmtList:
    return
  var bindingNames: seq[string] = @[]
  for b in bindings:
    bindingNames.add b.name
  for i in 0 ..< result.len:
    let stmt = result[i]
    if stmt.kind in {nnkCall, nnkCommand} and
       stmt.len >= 2 and
       stmt[0].kind in {nnkIdent, nnkSym} and
       $stmt[0] == "build" and
       stmt[^1].kind == nnkStmtList:
      let innerBody = stmt[^1]
      let rewritten = newStmtList()
      for innerStmt in innerBody:
        rewritten.add innerStmt.copyNimTree()
        if innerStmt.kind in {nnkLetSection, nnkVarSection}:
          for defn in innerStmt:
            if defn.kind != nnkIdentDefs:
              continue
            if defn[^1].kind == nnkEmpty:
              continue
            for j in 0 ..< defn.len - 2:
              let nameNode = defn[j]
              let identNode =
                case nameNode.kind
                of nnkPragmaExpr: nameNode[0]
                of nnkPostfix: nameNode[1]
                else: nameNode
              if identNode.kind in {nnkIdent, nnkSym} and
                 $identNode in bindingNames:
                let storageIdent =
                  composeBindingStorageIdent(packageName, $identNode)
                let initIdent =
                  composeBindingInitFlagIdent(packageName, $identNode)
                let valueIdent = ident($identNode)
                # Only write through to the storage var when it exists.
                # `when declared` mirrors the storage-emission decision in
                # `generatedCrossProjectStorage`: bindings that couldn't
                # back a module-level storage var (RHS not typeable at
                # module scope) get no write-through and simply remain
                # ordinary build-local `let`s.
                rewritten.add quote do:
                  when declared(`storageIdent`):
                    `storageIdent` = `valueIdent`
                    `initIdent` = true
      stmt[^1] = rewritten

# ---------------------------------------------------------------------------
# Body-preservation walker (M5 in-place transform — minimal viable shape).
#
# v8's `transformPackageBody` lowers known DSL keywords (executable,
# library, files, service, build:, versions, config) into staged-primitive
# calls AND preserves unknown nodes verbatim. The production DSL today
# uses `parsePackageDef` (data extraction) + `buildCode` (synthesised
# proc with `collectBuildStatements`) for the lowered output. Unknown
# top-level nodes (top-level echo, top-level let outside build:, raw
# Nim) are silently dropped.
#
# The minimum-viable production port (this proc): emit the unknown
# top-level statements alongside the existing generated code so they
# survive expansion. We do NOT yet rewrite known DSL keywords here —
# `parsePackageDef` + `buildCode` still produce the lowered output for
# those. The two emissions COEXIST; that's the "add-alongside" strategy
# the M5 milestone notes flag as pragmatic.
# ---------------------------------------------------------------------------

proc isKnownPackageSection(stmt: NimNode): bool =
  if stmt.kind notin {nnkCall, nnkCommand}:
    return false
  if stmt.len < 1:
    return false
  let head = stmt[0]
  if head.kind notin {nnkIdent, nnkSym}:
    return false
  let n = ($head).normalize
  result = n in ["build", "executable", "library", "files", "service",
                 "devenv", "uses", "usesimportpath", "defaulttoolprovisioning",
                 "toolprovisioning", "provisioning", "versions", "config",
                 "depends_on", "dependson"]

proc preservedTopLevelNodes(body: NimNode): NimNode =
  ## Collect everything in `body` that is NOT a recognised DSL section.
  ## These get emitted verbatim at module top level so raw `let`/`var`/
  ## `const`, helper `proc`s, and `when`/`if` branches survive the
  ## package macro instead of being dropped.
  ##
  ## `nnkIncludeStmt` is INTENTIONALLY excluded from preservation.
  ## Today's `include "x.nim"` shape inside a package body is dead
  ## code (see `repro.nim`'s `include "repro.tests.nim"` — silently
  ## dropped by the legacy pipeline, M6 migrates it). Promoting
  ## include to module top level would require the included file's
  ## top-level shape to be valid standalone, which it isn't for
  ## `repro.tests.nim` (its body is a `build:` block — only valid
  ## inside a `package` macro). M6's test-suite-migration milestone
  ## chooses the final shape (data-iteration vs helper-proc vs
  ## cross-project reference) and lights up the appropriate
  ## preservation path then.
  result = newStmtList()
  if body.kind != nnkStmtList:
    return
  for stmt in body:
    if isKnownPackageSection(stmt):
      continue
    # `discard` placeholders are noise — skip them.
    if stmt.kind == nnkDiscardStmt and stmt.len > 0 and
       stmt[0].kind == nnkEmpty:
      continue
    # Doc-comment-as-string-literal at body head is metadata, not code.
    if stmt.kind == nnkCommentStmt:
      continue
    # Includes contain package-section keywords as their primary use
    # today and the legacy pipeline drops them silently; promoting to
    # top level breaks repro.nim's existing shape.
    if stmt.kind == nnkIncludeStmt:
      continue
    result.add(stmt.copyNimTree())
