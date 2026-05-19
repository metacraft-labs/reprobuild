## `evalConfig:` block macro plus the macro-driven block forms used
## to declare configurables with attached doc comments and `@id`
## directives.
##
## `evalConfig` pushes a new `ConfigContext` onto the thread-local
## stack, runs the body, calls `finalize` on exit, and returns the
## finalized context.
##
## `scope <name>:` (a block form) prepends a segment to the scope-
## derived names of any `config:` declarations nested inside it.
##
## `config:` is the canonical multi-declaration syntax:
##
##   config:
##     ## TCP port the API server binds.
##     ## @id api-server-port
##     port = 8080
##
##     ## Default log level.
##     logLevel = "info"
##
## The block form parses leading doc comments per declaration,
## extracts the `@id` directive, and emits a `declareConfigurable[T]`
## call with the parsed metadata.

import std/[macros, strutils]

import ./types
import ./context
import ./api
import ./doc_directives

# `context` is used at expansion time by the `evalConfig` .dirty.
# template; export it explicitly to silence the false-positive
# unused-import warning.
export context

# ---------------------------------------------------------------------------
# AST recognition helpers
# ---------------------------------------------------------------------------

proc isConfigCall(n: NimNode): bool =
  n.kind in {nnkCall, nnkCommand} and
    n.len >= 1 and
    n[0].kind in {nnkIdent, nnkSym} and
    $n[0] == "config" and
    n[^1].kind == nnkStmtList

proc isScopeCall(n: NimNode): bool =
  n.kind in {nnkCall, nnkCommand} and
    n.len >= 2 and
    n[0].kind in {nnkIdent, nnkSym} and
    $n[0] == "scope" and
    n[^1].kind == nnkStmtList

proc isConfigurableAssign(node: NimNode): bool =
  ## Recognises `name = defaultValue` and `name: T = defaultValue`.
  case node.kind
  of nnkAsgn:
    node[0].kind in {nnkIdent, nnkSym}
  of nnkCall:
    # `name: T = value` parses as Call(Colon(name, T), default).
    node.len == 2 and
      node[0].kind == nnkExprColonExpr and
      node[0].len == 2 and
      node[0][0].kind in {nnkIdent, nnkSym}
  else: false

proc extractName(node: NimNode): string =
  case node.kind
  of nnkAsgn: $node[0]
  of nnkCall:
    if node.len == 2 and node[0].kind == nnkExprColonExpr:
      $node[0][0]
    else: ""
  else: ""

proc extractDefault(node: NimNode): NimNode =
  case node.kind
  of nnkAsgn: node[1].copyNimTree()
  of nnkCall: node[1].copyNimTree()
  else: newEmptyNode()

# ---------------------------------------------------------------------------
# Lowering of a single `config:` entry
# ---------------------------------------------------------------------------

proc emitOneScoped(node: NimNode; doc: string;
                   descFile: string; descLine, descCol: int;
                   scopedName: string): NimNode =
  ## Lower a single `name = value` declaration plus its attached doc
  ## into a `let name = declareConfigurable[T](...)` statement. The
  ## scope-derived name is computed at macro time and embedded as a
  ## literal string.
  ##
  ## The doc-comment directive parser runs HERE, at macro expansion
  ## time. This is what makes invalid `@id` values, unknown
  ## directive names, and reserved-future directives a compile-time
  ## error rather than a runtime exception.
  let nameStr = extractName(node)
  if nameStr.len == 0:
    error("config: declaration must have the form `name = value` or " &
          "`name: T = value`", node)
  let defaultExpr = extractDefault(node)
  var parsed: ParsedDocComment
  try:
    parsed = parseDocComment(doc)
  except EInvalidId as err:
    error("invalid @id in doc comment for `" & nameStr & "`: " & err.msg,
      node)
  except EUnknownDirective as err:
    error(err.msg, node)
  except EFutureDirective as err:
    error("doc comment for `" & nameStr & "`: " & err.msg, node)
  except DocDirectiveError as err:
    error(err.msg, node)
  let siteCall = newCall(bindSym"newSourceSite",
    newLit(descFile), newLit(descLine), newLit(descCol),
    bindSym"ckDefault")
  let declCall = newCall(bindSym"declareConfigurable",
    defaultExpr, newLit(scopedName),
    newLit(parsed.description), newLit(parsed.explicitId),
    newLit(descFile), newLit(descLine), newLit(descCol), siteCall)
  result = newLetStmt(ident(nameStr), declCall)

proc expandConfigBlock(body: NimNode;
                       prefix: seq[string]): NimNode =
  ## Walk a `config:` block body, peeling leading doc comments per
  ## declaration. Each declaration is lowered with the current scope
  ## prefix.
  result = newStmtList()
  var stmts: seq[NimNode] = @[]
  for s in body: stmts.add s.copyNimTree()
  var pos = 0
  var pendingDoc = ""
  var pendingLine = 0
  var pendingCol = 0
  var pendingFile = ""
  while pos < stmts.len:
    let s = stmts[pos]
    if s.kind == nnkCommentStmt:
      if pendingDoc.len == 0:
        let info = s.lineInfoObj
        pendingFile = info.filename
        pendingLine = info.line
        pendingCol = info.column
      if pendingDoc.len > 0: pendingDoc.add "\n"
      pendingDoc.add s.strVal
      inc pos; continue
    if not isConfigurableAssign(s):
      # Non-comment, non-declaration statement breaks the doc chain.
      result.add s.copyNimTree()
      pendingDoc = ""
      pendingFile = ""
      pendingLine = 0
      pendingCol = 0
      inc pos
      continue
    let info = s.lineInfoObj
    let descFile =
      if pendingDoc.len > 0: pendingFile else: info.filename
    let descLine = if pendingDoc.len > 0: pendingLine else: 0
    let descCol = if pendingDoc.len > 0: pendingCol else: 0
    let nameStr = extractName(s)
    let scopedName =
      if prefix.len == 0: nameStr
      else: prefix.join(".") & "." & nameStr
    result.add emitOneScoped(s, pendingDoc, descFile, descLine,
      descCol, scopedName)
    pendingDoc = ""
    pendingFile = ""
    pendingLine = 0
    pendingCol = 0
    inc pos

proc rewriteConfigBlocks(node: NimNode; prefix: seq[string]): NimNode =
  ## Walks an AST, pre-expanding `scope` and `config:` calls so the
  ## scope-derived name composition happens at macro time. This is
  ## the bottom-up workaround for macro-expansion order: by the time
  ## the outer `scope`'s macro body sees `config:`, the inner
  ## `config:` macro would otherwise already have expanded with an
  ## empty scope stack. We pre-expand here instead, threading the
  ## prefix explicitly.
  if node.isScopeCall():
    var newPrefix = prefix
    if node[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      newPrefix.add node[1].strVal
    else:
      error("scope expects a literal string name", node[1])
    let body = node[^1]
    var rewritten = newStmtList()
    for child in body:
      rewritten.add rewriteConfigBlocks(child, newPrefix)
    return rewritten
  if node.isConfigCall():
    return expandConfigBlock(node[^1], prefix)
  case node.kind
  of nnkIdent, nnkSym, nnkStrLit, nnkRStrLit, nnkTripleStrLit,
     nnkIntLit, nnkFloatLit, nnkCharLit, nnkNilLit,
     nnkCommentStmt, nnkEmpty:
    return node.copyNimTree()
  else: discard
  result = node.kind.newTree()
  for child in node:
    result.add rewriteConfigBlocks(child, prefix)

# ---------------------------------------------------------------------------
# Public macros
# ---------------------------------------------------------------------------

macro scope*(name: static string; body: untyped): untyped =
  ## Push `name` onto the scope prefix for any `config:` blocks
  ## nested inside `body`. The walker pre-expands those blocks here
  ## so the scope-derived name is composed at macro time. Other
  ## statements pass through unchanged.
  let prefix = @[name]
  result = newStmtList()
  if body.kind == nnkStmtList:
    for child in body:
      result.add rewriteConfigBlocks(child, prefix)
  else:
    result.add rewriteConfigBlocks(body, prefix)

macro config*(body: untyped): untyped =
  ## Block-form configurable declaration, the canonical syntax inside
  ## activity / package / system / profile bodies. Parses leading doc
  ## lines per inner statement and produces typed `Configurable[T]`
  ## variables.
  if body.kind != nnkStmtList:
    error("`config:` expects an indented block of declarations", body)
  result = expandConfigBlock(body, @[])

# ---------------------------------------------------------------------------
# evalConfig:
# ---------------------------------------------------------------------------

template evalConfig*(body: untyped): ConfigContext {.dirty.} =
  ## Push a fresh `ConfigContext`, run `body`, finalize on exit, and
  ## return the finalized context as the block's value. The template
  ## is intentionally `{.dirty.}` so identifiers introduced by inner
  ## macros flow back into the surrounding scope without hygienic
  ## renaming.
  block:
    let ctx = newConfigContext()
    pushContext(ctx)
    try:
      body
      ctx.finalize()
    finally:
      discard popContext()
    ctx
