## Block-macro layer for `tomlContent:`, `iniContent:`, `yamlContent:`,
## `jsonContent:`, `shellExports:`, `textContent`. The macros transform
## DSL syntax like:
##
##   tomlContent:
##     database:
##       url = "postgres://..."
##       pool_size = 32
##     http:
##       port = 8080
##
## into runtime construction of a `StructuredValue` tree (insertion
## order preserved) plus a sequence of `ResolvedInput` records that the
## caller threads into the cache key.
##
## Configurable reads inside the block expand normally — the surrounding
## `evalConfig:` context resolves them, and the block-macro builder
## proc records every primitive that flows in as a `ResolvedInput`.
##
## The macros are intentionally lightweight: complex configuration
## should use `fs.writeStructured(...)` directly with a `JsonNode` or
## `StructuredValue` built by ordinary Nim code.

import std/[macros, os, strutils, tables]

import ./structured
import ./described
import ../configurables

export described

# ---------------------------------------------------------------------------
# RenderedContent — the materialized output of a block macro
# ---------------------------------------------------------------------------

type
  ResolvedInputs* = ref object
    items*: seq[(string, ConfigurableValue)]

  RenderedContent* = object
    format*: ConfigFormat
    value*: StructuredValue
    inputs*: ResolvedInputs

proc newInputs*(): ResolvedInputs =
  ResolvedInputs(items: @[])

proc recordInput*[T](rin: ResolvedInputs; name: string; v: T) =
  ## Threadsafe-by-construction recording of a typed input value. The
  ## name is the configurable's scope-derived name (or scope.field for
  ## staged-dot access).
  rin.items.add (name, wrapValue(v))

# ---------------------------------------------------------------------------
# Runtime helpers used by the lowered AST
# ---------------------------------------------------------------------------

proc resolveAndRecord*[T](inputs: ResolvedInputs;
                          ctx: ConfigContext;
                          c: Configurable[T];
                          recordedName: string): T =
  ## Read a configurable's resolved value AND record it in the input
  ## set under the given name. The caller (macro-generated code)
  ## supplies the name based on the DSL field path.
  result = read(ctx, c)
  inputs.items.add (recordedName, wrapValue(result))

proc setStringField*(obj: StructuredValue; key, value: string) =
  obj.setField(key, svString(value))

proc setIntField*(obj: StructuredValue; key: string; value: int) =
  obj.setField(key, svInt(value))

proc setBoolField*(obj: StructuredValue; key: string; value: bool) =
  obj.setField(key, svBool(value))

proc setObjectField*(obj: StructuredValue; key: string;
                    sub: StructuredValue) =
  obj.setField(key, sub)

proc setArrayField*(obj: StructuredValue; key: string;
                   sub: StructuredValue) =
  obj.setField(key, sub)

# ---------------------------------------------------------------------------
# Block macros for each format
# ---------------------------------------------------------------------------

type
  FieldRecord = object
    ## One key a block writes, for the compile-time check of a block that
    ## names a description: its path, the symbol its value was bound to
    ## (nil for a section), its literal text when it is a literal, and the
    ## statement that wrote it (for the error's position).
    path: seq[string]
    valueSym: NimNode
    literal: string
    literalKnown: bool
    site: NimNode

proc lowerExpression(targetSym: NimNode; inputsSym: NimNode;
                     ctxSym: NimNode; path: seq[string];
                     fieldName: string;
                     expr: NimNode;
                     fields: var seq[FieldRecord]; site: NimNode): NimNode

proc keyName(node: NimNode): string =
  ## A block key: a name, a backquoted name (`` `target-dir` ``, for a key
  ## that is not a Nim identifier) or a string literal.
  case node.kind
  of nnkIdent, nnkSym:
    $node
  of nnkAccQuoted:
    var name = ""
    for part in node:
      name.add(if part.kind in {nnkIdent, nnkSym}: $part else: part.repr)
    name
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    node.strVal
  else:
    error("block content: a key must be a name, a backquoted name or a " &
      "string literal", node)

proc lowerBlock(rootSym: NimNode; inputsSym: NimNode;
                ctxSym: NimNode; path: seq[string];
                target: NimNode; body: NimNode;
                fields: var seq[FieldRecord]): NimNode =
  ## Walk a block body, emitting `setField` calls into `target`, and record
  ## every key written in `fields`.
  result = newStmtList()
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      continue
    of nnkAsgn:
      if stmt[0].kind notin {nnkIdent, nnkSym, nnkAccQuoted, nnkStrLit,
          nnkRStrLit, nnkTripleStrLit}:
        error("block content: assignment target must be a name", stmt)
      let key = keyName(stmt[0])
      result.add lowerExpression(target, inputsSym, ctxSym,
        path & key, key, stmt[1], fields, stmt)
    of nnkCall:
      if stmt.len >= 1 and stmt[0].kind in {nnkIdent, nnkSym, nnkAccQuoted,
          nnkStrLit} and stmt[^1].kind == nnkStmtList:
        let key = keyName(stmt[0])
        fields.add FieldRecord(path: path & key, site: stmt)
        # Nested section. Build a new sub-object, recurse into the body
        # using it as the target.
        let subSym = genSym(nskLet, "sub")
        let subInit = quote do:
          let `subSym` = svObject()
        result.add subInit
        result.add lowerBlock(rootSym, inputsSym, ctxSym,
          path & key, subSym, stmt[^1], fields)
        result.add quote do:
          setObjectField(`target`, `key`, `subSym`)
      else:
        error("block content: unrecognized statement form", stmt)
    of nnkInfix:
      error("block content: expressions must be `name = value` or " &
        "`name:` blocks", stmt)
    else:
      error("block content: unrecognized statement kind " & $stmt.kind,
        stmt)

proc lowerExpression(targetSym: NimNode; inputsSym: NimNode;
                     ctxSym: NimNode; path: seq[string];
                     fieldName: string;
                     expr: NimNode;
                     fields: var seq[FieldRecord]; site: NimNode): NimNode =
  ## Lower a single `name = <expr>` assignment into a `setField` call
  ## on `targetSym`. The expression is evaluated at runtime: if it
  ## returns a primitive, the corresponding `svBool/svInt/svString`
  ## constructor wraps it; if it returns a `Configurable[T]`, the
  ## runtime helper resolves it through `ctxSym` and records the input
  ## under the scope path.
  let target = targetSym
  let scopeName = path.join(".")
  result = newStmtList()
  # We need to dispatch on the static type of `expr`. The trick:
  # generate a `when expr is Configurable[T] ...` chain.
  let exprSym = genSym(nskLet, "v")
  result.add newLetStmt(exprSym, expr)
  var record = FieldRecord(path: path, valueSym: exprSym, site: site)
  case expr.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    record.literal = expr.strVal
    record.literalKnown = true
  of nnkIntLit .. nnkInt64Lit:
    record.literal = $expr.intVal
    record.literalKnown = true
  of nnkIdent:
    if expr.eqIdent("true") or expr.eqIdent("false"):
      record.literal = ($expr).toLowerAscii
      record.literalKnown = true
  else:
    discard
  fields.add record
  let recordedName = newLit(scopeName)
  let dispatch = quote do:
    when `exprSym` is Configurable[int]:
      let v = resolveAndRecord(`inputsSym`, `ctxSym`, `exprSym`, `recordedName`)
      setIntField(`target`, `fieldName`, v)
    elif `exprSym` is Configurable[string]:
      let v = resolveAndRecord(`inputsSym`, `ctxSym`, `exprSym`, `recordedName`)
      setStringField(`target`, `fieldName`, v)
    elif `exprSym` is Configurable[bool]:
      let v = resolveAndRecord(`inputsSym`, `ctxSym`, `exprSym`, `recordedName`)
      setBoolField(`target`, `fieldName`, v)
    elif `exprSym` is int:
      setIntField(`target`, `fieldName`, `exprSym`)
    elif `exprSym` is bool:
      setBoolField(`target`, `fieldName`, `exprSym`)
    elif `exprSym` is string:
      setStringField(`target`, `fieldName`, `exprSym`)
    elif `exprSym` is StructuredValue:
      `target`.setField(`fieldName`, `exprSym`)
    else:
      {.error: "block content: unsupported field expression type for " &
        astToStr(`exprSym`).}
  result.add dispatch

# Sequence overload used by the runtime helper for shellExports `PATH = @[...]`.
proc setStringListField*(obj: StructuredValue; key: string;
                        values: openArray[string]) =
  let arr = svArray()
  for v in values: arr.add svString(v)
  obj.setField(key, arr)

proc withLineInfo(node, site: NimNode): NimNode =
  ## `node` with every node in it placed at `site`, so a compile error the
  ## check raises points at the statement that wrote the key.
  result = node
  result.copyLineInfo(site)
  for i in 0 ..< result.len:
    result[i] = withLineInfo(result[i], site)

proc snippetCheck(description: NimNode; writer: string;
                  fields: seq[FieldRecord]): NimNode =
  ## The compile-time check of a block written against a description: one
  ## constant holding the issue of every key (`snippetIssues`, a single
  ## evaluation that reads the description's table, which was derived once
  ## where the description was declared), then one `when` per key that
  ## turns its issue into a compile error at the statement that wrote it.
  result = newStmtList()
  if fields.len == 0:
    return
  var list = nnkBracket.newTree()
  for f in fields:
    var pathLit = nnkBracket.newTree()
    for segment in f.path:
      pathLit.add newLit(segment)
    if f.valueSym.isNil:
      list.add newCall(bindSym"sectionField", pathLit)
    else:
      list.add newCall(bindSym"snippetField", pathLit,
        newCall(ident"typeof", f.valueSym), newLit(f.literal),
        newLit(f.literalKnown))
  let issues = genSym(nskConst, "snippetIssues")
  result.add newNimNode(nnkConstSection).add(newNimNode(nnkConstDef).add(
    issues, newEmptyNode(),
    newCall(bindSym"snippetIssues", description, list)))
  for i, f in fields:
    let issue = nnkBracketExpr.newTree(issues, newLit(i))
    let message = newCall(bindSym"snippetErrorText", description,
      newLit(writer), issue)
    let check = nnkWhenStmt.newTree(nnkElifBranch.newTree(
      infix(newDotExpr(issue, ident"kind"), "!=", bindSym"cikNone"),
      newStmtList(nnkPragma.newTree(nnkExprColonExpr.newTree(
        ident"error", message)))))
    result.add withLineInfo(check, f.site)

proc contentCode(formatLit: ConfigFormat; ctxArg, description: NimNode;
                 writer: string; body: NimNode): NimNode =
  if body.kind != nnkStmtList:
    error("content block: expected an indented block", body)
  let rootSym = genSym(nskLet, "cfg_root")
  let inputsSym = genSym(nskLet, "cfg_inputs")
  let ctxSym = ctxArg
  var fields: seq[FieldRecord] = @[]
  result = newStmtList()
  result.add newLetStmt(rootSym, newCall(bindSym"svObject"))
  result.add newLetStmt(inputsSym, newCall(bindSym"newInputs"))
  result.add lowerBlock(rootSym, inputsSym, ctxSym, @[], rootSym, body,
    fields)
  if not description.isNil:
    result.add snippetCheck(description, writer, fields)
    # The run-time half: what the compiler cannot see (a configurable's
    # resolved value, a `StructuredValue` built by code), in one walk.
    # The block's position names the recipe file by its name only: the
    # message is compiled into the recipe's binary, which must not carry the
    # checkout's absolute path.
    let site = body.lineInfoObj
    result.add newCall(bindSym"checkStructured", description, rootSym,
      newLit(writer & " block at " & site.filename.extractFilename & "(" &
        $site.line & ", " & $site.column & ")"))
  let formatNode = newCall(bindSym"ConfigFormat",
    newLit(ord(formatLit)))
  result.add quote do:
    RenderedContent(format: `formatNode`, value: `rootSym`,
      inputs: `inputsSym`)
  result = newBlockStmt(result)

macro contentMacroImpl(formatLit: static[ConfigFormat]; ctxArg: untyped;
                      body: untyped): RenderedContent =
  contentCode(formatLit, ctxArg, nil, "", body)

macro describedContentMacroImpl(formatLit: static[ConfigFormat];
                                writer: static[string]; ctxArg: untyped;
                                description: untyped;
                                body: untyped): RenderedContent =
  contentCode(formatLit, ctxArg, description, writer, body)

template tomlContent*(ctx: ConfigContext;
                      body: untyped): RenderedContent =
  contentMacroImpl(cfToml, ctx, body)

template iniContent*(ctx: ConfigContext;
                     body: untyped): RenderedContent =
  contentMacroImpl(cfIni, ctx, body)

template yamlContent*(ctx: ConfigContext;
                      body: untyped): RenderedContent =
  contentMacroImpl(cfYaml, ctx, body)

template jsonContent*(ctx: ConfigContext;
                      body: untyped): RenderedContent =
  contentMacroImpl(cfJson, ctx, body)

template shellExports*(ctx: ConfigContext;
                       body: untyped): RenderedContent =
  contentMacroImpl(cfShellExports, ctx, body)

# The same blocks written for a described program: `description` is the
# `CliConfigTable` constant of the program that reads the file (a tool's
# `<executable>ConfigDescription`). Every key and value is checked against it
# at compile time where the compiler can see it, and the built tree at run
# time (see `described.nim`).

template tomlContent*(ctx: ConfigContext; description: untyped;
                      body: untyped): RenderedContent =
  describedContentMacroImpl(cfToml, "tomlContent", ctx, description, body)

template iniContent*(ctx: ConfigContext; description: untyped;
                     body: untyped): RenderedContent =
  describedContentMacroImpl(cfIni, "iniContent", ctx, description, body)

template yamlContent*(ctx: ConfigContext; description: untyped;
                      body: untyped): RenderedContent =
  describedContentMacroImpl(cfYaml, "yamlContent", ctx, description, body)

template jsonContent*(ctx: ConfigContext; description: untyped;
                      body: untyped): RenderedContent =
  describedContentMacroImpl(cfJson, "jsonContent", ctx, description, body)

template shellExports*(ctx: ConfigContext; description: untyped;
                       body: untyped): RenderedContent =
  describedContentMacroImpl(cfShellExports, "shellExports", ctx,
    description, body)

proc textContent*(text: string): RenderedContent =
  let root = svObject()
  root.setField("text", svString(text))
  RenderedContent(format: cfText, value: root, inputs: newInputs())

proc textContent*(ctx: ConfigContext;
                  c: Configurable[string]): RenderedContent =
  let inputs = newInputs()
  let s = resolveAndRecord(inputs, ctx, c, "$text")
  let root = svObject()
  root.setField("text", svString(s))
  RenderedContent(format: cfText, value: root, inputs: inputs)
