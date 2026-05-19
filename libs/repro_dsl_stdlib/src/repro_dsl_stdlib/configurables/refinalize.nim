## `withOverrides`: incremental refinalize.
##
## Returns a new finalized context that shares structure with the
## parent. Only the dirty closure is re-resolved; nodes whose
## recomputed value is byte-identical to the previous value do NOT
## propagate dirtiness further.

import std/[macros]

import ./types
import ./context
import ./api

proc withOverridesImpl*[T](parent: ConfigContext;
                           target: Configurable[T];
                           newValue: T): ConfigContext =
  ## Single-override path used by the integration gate. The full
  ## DSL `withOverrides(c1.override v1, c2.override v2):` macro
  ## form lowers to a sequence of calls into this function.
  let child = parent.shallowClone()
  pushContext(child)
  try:
    let node = child.nodeOf(target.id)
    let site = newSourceSite("", 0, 0, ckOverride)
    child.addContribution(node, prOverride, wrapValue(newValue), site)
    child.finalizeIncremental([target.id])
  finally:
    discard popContext()
  child

macro withOverrides*(parent: ConfigContext; body: untyped): untyped =
  ## Block form: each statement inside `body` is `c.override v` (or
  ## `c := v`); the macro lowers to `withOverridesImpl(parent, c, v)`
  ## chained left-to-right. This is the user-facing surface.
  if body.kind != nnkStmtList:
    error("withOverrides expects an indented block of overrides", body)
  result = newStmtList()
  let chainSym = genSym(nskVar, "chain")
  result.add quote do:
    var `chainSym` = `parent`.shallowClone()
    pushContext(`chainSym`)
  var seeds: seq[NimNode] = @[]
  for s in body:
    case s.kind
    of nnkCommand, nnkCall:
      # accept both `c.override v` and `override c v`
      let head = s[0]
      if head.kind == nnkDotExpr and head[1].eqIdent("override"):
        let target = head[0]
        let value = s[1]
        result.add quote do:
          override(`target`, `value`)
        seeds.add quote do:
          `target`.id
      else:
        error("withOverrides only accepts `c.override v` statements; " &
              "got `" & s.repr & "`", s)
    of nnkInfix:
      if s[0].eqIdent(":="):
        let target = s[1]
        let value = s[2]
        result.add quote do:
          `target` := `value`
        seeds.add quote do:
          `target`.id
      else:
        error("withOverrides only accepts `c := v` or `c.override v`",
          s)
    else:
      error("withOverrides only accepts override statements", s)
  let seedSeq = nnkBracket.newTree()
  for s in seeds: seedSeq.add s
  let seedArr = nnkPrefix.newTree(ident"@", seedSeq)
  result.add quote do:
    try:
      `chainSym`.finalizeIncremental(`seedArr`)
    finally:
      discard popContext()
    `chainSym`
