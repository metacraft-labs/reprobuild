## Compile-time help for writing a clispec ``cli:`` body in a proc.
##
## reprobuild describes its command lines (repro's own, the add-on's, the
## commands a description splices from another program) as compile-time
## procs that return a ``cli:`` body built with ``quote do:``, so one
## declaration can be spliced into several commands and several programs.
## ``quote`` binds what it can, and the ``cli:`` language is read as written,
## the way a macro's untyped argument is; ``unbound`` turns such a body back
## into what was written. It imports only ``std/macros`` and runs at compile
## time only, so a program that merely reads a description (the thin client)
## links nothing for it.

import std/macros

proc unbound*(n: NimNode): NimNode {.compileTime.} =
  ## ``n`` with every symbol ``quote`` bound turned back into the identifier
  ## it was written as, line information kept. The ``cli:`` language is read
  ## as written, the way a macro's untyped argument is: ``required = false``
  ## names the literal ``false``, which clispec reads as an identifier, not
  ## a symbol of ``system``.
  ##
  ## A ``help`` text written as string literals joined with ``&``, to keep
  ## the lines short, is folded into the one literal clispec requires there,
  ## a statement list spliced into a scope is flattened into it, and a type
  ## such as ``seq[string]`` is kept a bracket expression. Applying it to a
  ## body it already converted changes nothing.
  if n.kind == nnkInfix and n.len == 3 and n[0].eqIdent("&"):
    let left = unbound(n[1])
    let right = unbound(n[2])
    if left.kind in {nnkStrLit..nnkTripleStrLit} and
        right.kind in {nnkStrLit..nnkTripleStrLit}:
      result = newLit(left.strVal & right.strVal)
      result.copyLineInfo(n)
      return
  # `quote` turns `seq[string]` into a call of the `[]` operator; the
  # language reads (and help prints) the bracket expression as written.
  if n.kind == nnkCall and n.len >= 2 and
      n[0].kind in {nnkSym, nnkOpenSymChoice, nnkClosedSymChoice} and
      (if n[0].kind == nnkSym: $n[0] else: $n[0][0]) == "[]":
    result = nnkBracketExpr.newNimNode(n)
    for child in n[1 .. ^1]:
      result.add(unbound(child))
    return
  case n.kind
  of nnkSym:
    result = ident($n)
    result.copyLineInfo(n)
  of nnkOpenSymChoice, nnkClosedSymChoice:
    result = ident($n[0])
    result.copyLineInfo(n)
  of nnkNone, nnkEmpty, nnkIdent, nnkCharLit..nnkUInt64Lit,
      nnkFloatLit..nnkFloat64Lit, nnkStrLit..nnkTripleStrLit, nnkNilLit:
    result = n
  of nnkStmtList:
    # A shared group of declarations is spliced in as a statement list of
    # its own; its statements belong to the scope it is spliced into, which
    # is where clispec reads them.
    result = n.kind.newNimNode(n)
    for child in n:
      let converted = unbound(child)
      if converted.kind == nnkStmtList:
        for statement in converted:
          result.add(statement)
      else:
        result.add(converted)
  else:
    result = n.kind.newNimNode(n)
    for child in n:
      result.add(unbound(child))
