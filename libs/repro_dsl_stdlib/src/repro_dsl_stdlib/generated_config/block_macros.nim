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

import std/[macros, strutils, tables]

import ./structured
import ../configurables

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

proc lowerExpression(targetSym: NimNode; inputsSym: NimNode;
                     ctxSym: NimNode; path: seq[string];
                     fieldName: string;
                     expr: NimNode): NimNode

proc lowerBlock(rootSym: NimNode; inputsSym: NimNode;
                ctxSym: NimNode; path: seq[string];
                target: NimNode; body: NimNode): NimNode =
  ## Walk a block body, emitting `setField` calls into `target`.
  result = newStmtList()
  for stmt in body:
    case stmt.kind
    of nnkCommentStmt:
      continue
    of nnkAsgn:
      if stmt[0].kind notin {nnkIdent, nnkSym}:
        error("block content: assignment target must be a name", stmt)
      let key = $stmt[0]
      result.add lowerExpression(target, inputsSym, ctxSym,
        path & key, key, stmt[1])
    of nnkCall:
      if stmt.len >= 1 and stmt[0].kind in {nnkIdent, nnkSym} and
         stmt[^1].kind == nnkStmtList:
        let key = $stmt[0]
        # Nested section. Build a new sub-object, recurse into the body
        # using it as the target.
        let subSym = genSym(nskLet, "sub_" & key)
        let subInit = quote do:
          let `subSym` = svObject()
        result.add subInit
        result.add lowerBlock(rootSym, inputsSym, ctxSym,
          path & key, subSym, stmt[^1])
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
                     expr: NimNode): NimNode =
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
  let exprSym = genSym(nskLet, "v_" & fieldName)
  result.add newLetStmt(exprSym, expr)
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

macro contentMacroImpl(formatLit: static[ConfigFormat]; ctxArg: untyped;
                      body: untyped): RenderedContent =
  if body.kind != nnkStmtList:
    error("content block: expected an indented block", body)
  let rootSym = genSym(nskLet, "cfg_root")
  let inputsSym = genSym(nskLet, "cfg_inputs")
  let ctxSym = ctxArg
  result = newStmtList()
  result.add newLetStmt(rootSym, newCall(bindSym"svObject"))
  result.add newLetStmt(inputsSym, newCall(bindSym"newInputs"))
  result.add lowerBlock(rootSym, inputsSym, ctxSym, @[], rootSym, body)
  let formatNode = newCall(bindSym"ConfigFormat",
    newLit(ord(formatLit)))
  result.add quote do:
    RenderedContent(format: `formatNode`, value: `rootSym`,
      inputs: `inputsSym`)
  result = newBlockStmt(result)

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
