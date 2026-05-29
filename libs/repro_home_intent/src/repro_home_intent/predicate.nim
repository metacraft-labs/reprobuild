## Predicate parser, normalizer, and evaluator for `when` / `if`
## clauses inside an activity body.
##
## Per `Home-Profile-Intent-Layer.md`:
##
##   The standard predicate set is:
##     - Platform: `windows`, `macos`, `linux`, `bsd`, `wsl`
##     - Architecture: `x86_64`, `arm64`, `arm32`
##     - Host identity: `host` (string compared via `==`, `!=`, `in`)
##     - Boolean combinators: `and`, `or`, `not`, parentheses
##
##   Normalization rules:
##     - Trim whitespace
##     - Sort commutative `and`/`or` operand sets lexicographically
##     - Drop redundant parentheses
##     - Lowercase standard predicate identifiers
##
##   Two predicates whose normalized forms are identical are the same
##   `when` block.

import std/[algorithm, sets, strutils]

import ./errors

const
  StandardPlatformIdents* = ["windows", "macos", "linux", "bsd", "wsl"]
  StandardArchIdents* = ["x86_64", "arm64", "arm32"]
  StandardHostIdent* = "host"

type
  PredNodeKind* = enum
    pnBoolLit       ## `true` / `false`
    pnIdent         ## bare identifier (standard or user-defined)
    pnStrLit        ## "string literal"
    pnList          ## `[a, b, c]`
    pnAnd
    pnOr
    pnNot
    pnEq            ## `host == "foo"`
    pnNe            ## `host != "foo"`
    pnIn            ## `host in ["foo", "bar"]`

  PredNode* = ref object
    case kind*: PredNodeKind
    of pnBoolLit:
      boolVal*: bool
    of pnIdent:
      ident*: string
    of pnStrLit:
      strVal*: string
    of pnList:
      items*: seq[PredNode]
    of pnAnd, pnOr:
      operands*: seq[PredNode]
    of pnNot:
      operand*: PredNode
    of pnEq, pnNe, pnIn:
      lhs*, rhs*: PredNode

  HostContext* = object
    ## Runtime facts a predicate evaluates against. Populated from
    ## `host_identity.currentHost()` plus the platform/arch detection
    ## the build/apply layer already performs. Tests construct one
    ## directly to exercise referentially-transparent evaluation.
    platform*: string   ## one of: windows, macos, linux, bsd, wsl
    arch*: string       ## one of: x86_64, arm64, arm32
    host*: string       ## the resolved host identity string
    isWsl*: bool        ## true if running under WSL on Linux

  UserPredicateLookup* = proc(name: string): bool {.gcsafe.}
    ## Callback the parser uses to learn whether an unknown predicate
    ## identifier is defined by an imported user module. Returns true if
    ## the identifier is known; the evaluator then calls
    ## `UserPredicateEvaluator`. The CLI/parser wires these up from the
    ## actual user-module set.

  UserPredicateEvaluator* = proc(name: string;
                                 ctx: HostContext): bool {.gcsafe.}

# ---------------------------------------------------------------------------
# Tokeniser.
# ---------------------------------------------------------------------------

type
  TokenKind = enum
    tkEof, tkIdent, tkStr, tkLParen, tkRParen, tkLBracket, tkRBracket,
    tkComma, tkAnd, tkOr, tkNot, tkEq, tkNe, tkIn, tkTrue, tkFalse

  Token = object
    kind: TokenKind
    text: string
    col: int

  Lexer = object
    src: string
    pos: int
    tokens: seq[Token]

proc isIdentStart(c: char): bool {.inline.} =
  c.isAlphaAscii() or c == '_'

proc isIdentCont(c: char): bool {.inline.} =
  c.isAlphaAscii() or c.isDigit() or c == '_'

proc lex(src: string): seq[Token] =
  ## Whitespace-insensitive tokenisation. Errors are deferred to the
  ## parser, which has the column information.
  var i = 0
  while i < src.len:
    let c = src[i]
    if c in {' ', '\t', '\r', '\n'}:
      inc i
      continue
    let startCol = i + 1
    if c == '(':
      result.add Token(kind: tkLParen, text: "(", col: startCol); inc i
    elif c == ')':
      result.add Token(kind: tkRParen, text: ")", col: startCol); inc i
    elif c == '[':
      result.add Token(kind: tkLBracket, text: "[", col: startCol); inc i
    elif c == ']':
      result.add Token(kind: tkRBracket, text: "]", col: startCol); inc i
    elif c == ',':
      result.add Token(kind: tkComma, text: ",", col: startCol); inc i
    elif c == '=' and i + 1 < src.len and src[i + 1] == '=':
      result.add Token(kind: tkEq, text: "==", col: startCol); inc i, 2
    elif c == '!' and i + 1 < src.len and src[i + 1] == '=':
      result.add Token(kind: tkNe, text: "!=", col: startCol); inc i, 2
    elif c == '"':
      var j = i + 1
      var s = ""
      while j < src.len and src[j] != '"':
        if src[j] == '\\' and j + 1 < src.len:
          s.add src[j + 1]
          inc j, 2
        else:
          s.add src[j]
          inc j
      if j >= src.len:
        # Unterminated string — let the parser surface this; emit what
        # we have and the parser will hit eof while looking for tkRBracket
        # / a closing context.
        result.add Token(kind: tkStr, text: s, col: startCol)
        i = j
      else:
        result.add Token(kind: tkStr, text: s, col: startCol)
        i = j + 1
    elif isIdentStart(c):
      var j = i + 1
      while j < src.len and isIdentCont(src[j]):
        inc j
      let id = src[i ..< j]
      case id
      of "and": result.add Token(kind: tkAnd, text: id, col: startCol)
      of "or": result.add Token(kind: tkOr, text: id, col: startCol)
      of "not": result.add Token(kind: tkNot, text: id, col: startCol)
      of "in": result.add Token(kind: tkIn, text: id, col: startCol)
      of "true": result.add Token(kind: tkTrue, text: id, col: startCol)
      of "false": result.add Token(kind: tkFalse, text: id, col: startCol)
      else:
        result.add Token(kind: tkIdent, text: id, col: startCol)
      i = j
    else:
      # Unknown character. Emit as an identifier token of length 1 so
      # the parser produces a precise diagnostic.
      result.add Token(kind: tkIdent, text: $c, col: startCol); inc i
  result.add Token(kind: tkEof, text: "", col: src.len + 1)

# ---------------------------------------------------------------------------
# Parser.
# ---------------------------------------------------------------------------

type
  Parser = object
    profilePath: string
    line: int                  ## line of the predicate within the profile
    src: string                ## the raw predicate source (for diagnostics)
    tokens: seq[Token]
    pos: int

proc peek(p: Parser): Token = p.tokens[p.pos]
proc advance(p: var Parser): Token =
  result = p.tokens[p.pos]
  if p.pos < p.tokens.high:
    inc p.pos

proc expect(p: var Parser; kind: TokenKind; what: string) =
  let t = p.peek()
  if t.kind != kind:
    raiseUnstructured(p.profilePath, p.line, t.col,
      "'" & t.text & "'", what)
  discard p.advance()

proc parseExpr(p: var Parser): PredNode
proc parseOr(p: var Parser): PredNode
proc parseAnd(p: var Parser): PredNode
proc parseNot(p: var Parser): PredNode
proc parseComparison(p: var Parser): PredNode
proc parseAtom(p: var Parser): PredNode

proc parseList(p: var Parser): PredNode =
  result = PredNode(kind: pnList)
  expect(p, tkLBracket, "'['")
  if p.peek().kind == tkRBracket:
    discard p.advance()
    return
  while true:
    result.items.add parseAtom(p)
    if p.peek().kind == tkComma:
      discard p.advance()
    else:
      break
  expect(p, tkRBracket, "']'")

proc parseAtom(p: var Parser): PredNode =
  let t = p.peek()
  case t.kind
  of tkTrue:
    discard p.advance()
    result = PredNode(kind: pnBoolLit, boolVal: true)
  of tkFalse:
    discard p.advance()
    result = PredNode(kind: pnBoolLit, boolVal: false)
  of tkStr:
    discard p.advance()
    result = PredNode(kind: pnStrLit, strVal: t.text)
  of tkIdent:
    discard p.advance()
    # M83 Phase F3: also accept the Phase A call-form predicate
    # (`windows()`, `linux()`, etc.) so a Phase-A-shaped profile
    # parses through the structural editor's source-text reader.
    # The empty argument list is collapsed to the bare identifier
    # in the AST — both forms canonicalize to the same predicate.
    if p.peek().kind == tkLParen:
      discard p.advance()
      if p.peek().kind == tkRParen:
        discard p.advance()
      else:
        let inner = p.peek()
        raiseUnstructured(p.profilePath, p.line, inner.col,
          "'" & inner.text & "'",
          "an empty argument list `()` after the predicate identifier")
    result = PredNode(kind: pnIdent, ident: t.text)
  of tkLParen:
    discard p.advance()
    result = parseExpr(p)
    expect(p, tkRParen, "')'")
  of tkLBracket:
    result = parseList(p)
  else:
    raiseUnstructured(p.profilePath, p.line, t.col,
      "'" & t.text & "'",
      "an identifier, string literal, '(' expression, '[' list, true, or false")

proc parseComparison(p: var Parser): PredNode =
  result = parseAtom(p)
  let t = p.peek()
  case t.kind
  of tkEq:
    discard p.advance()
    let rhs = parseAtom(p)
    result = PredNode(kind: pnEq, lhs: result, rhs: rhs)
  of tkNe:
    discard p.advance()
    let rhs = parseAtom(p)
    result = PredNode(kind: pnNe, lhs: result, rhs: rhs)
  of tkIn:
    discard p.advance()
    let rhs = parseAtom(p)
    result = PredNode(kind: pnIn, lhs: result, rhs: rhs)
  else:
    discard

proc parseNot(p: var Parser): PredNode =
  if p.peek().kind == tkNot:
    discard p.advance()
    let inner = parseNot(p)
    result = PredNode(kind: pnNot, operand: inner)
  else:
    result = parseComparison(p)

proc parseAnd(p: var Parser): PredNode =
  result = parseNot(p)
  if p.peek().kind == tkAnd:
    var operands = @[result]
    while p.peek().kind == tkAnd:
      discard p.advance()
      operands.add parseNot(p)
    result = PredNode(kind: pnAnd, operands: operands)

proc parseOr(p: var Parser): PredNode =
  result = parseAnd(p)
  if p.peek().kind == tkOr:
    var operands = @[result]
    while p.peek().kind == tkOr:
      discard p.advance()
      operands.add parseAnd(p)
    result = PredNode(kind: pnOr, operands: operands)

proc parseExpr(p: var Parser): PredNode =
  result = parseOr(p)

proc parsePredicate*(profilePath, source: string; line = 0): PredNode =
  ## Parse a predicate expression from `source`. `profilePath` and
  ## `line` are used only for diagnostics; pass empty / 0 if you're
  ## parsing an ad-hoc predicate from the CLI.
  var p = Parser(profilePath: profilePath, line: line,
    src: source, tokens: lex(source), pos: 0)
  result = parseExpr(p)
  let t = p.peek()
  if t.kind != tkEof:
    raiseUnstructured(profilePath, line, t.col,
      "'" & t.text & "'", "end of predicate expression")

# ---------------------------------------------------------------------------
# Normalization.
# ---------------------------------------------------------------------------

proc isStandardIdent*(name: string): bool =
  ## Is `name` one of the standard predicate identifiers? (Used for
  ## the lowercase-on-normalize rule; user-defined predicates retain
  ## their original case.)
  let lower = name.toLowerAscii()
  if lower in StandardPlatformIdents:
    return true
  if lower in StandardArchIdents:
    return true
  lower == StandardHostIdent

proc renderNode(n: PredNode): string

proc renderList(items: seq[PredNode]): string =
  result = "["
  for i, item in items:
    if i > 0:
      result.add ", "
    result.add renderNode(item)
  result.add "]"

proc renderNode(n: PredNode): string =
  case n.kind
  of pnBoolLit:
    result = if n.boolVal: "true" else: "false"
  of pnIdent:
    result = n.ident
  of pnStrLit:
    result = "\"" & n.strVal & "\""
  of pnList:
    result = renderList(n.items)
  of pnAnd:
    var parts: seq[string]
    for op in n.operands:
      if op.kind == pnOr:
        parts.add "(" & renderNode(op) & ")"
      else:
        parts.add renderNode(op)
    result = parts.join(" and ")
  of pnOr:
    var parts: seq[string]
    for op in n.operands:
      parts.add renderNode(op)
    result = parts.join(" or ")
  of pnNot:
    let inner = n.operand
    if inner.kind in {pnAnd, pnOr}:
      result = "not (" & renderNode(inner) & ")"
    else:
      result = "not " & renderNode(inner)
  of pnEq:
    result = renderNode(n.lhs) & " == " & renderNode(n.rhs)
  of pnNe:
    result = renderNode(n.lhs) & " != " & renderNode(n.rhs)
  of pnIn:
    result = renderNode(n.lhs) & " in " & renderNode(n.rhs)

proc flattenAnd(n: PredNode): seq[PredNode] =
  if n.kind == pnAnd:
    for op in n.operands:
      result.add flattenAnd(op)
  else:
    result.add n

proc flattenOr(n: PredNode): seq[PredNode] =
  if n.kind == pnOr:
    for op in n.operands:
      result.add flattenOr(op)
  else:
    result.add n

proc normalizeAst*(n: PredNode): PredNode =
  ## Reduce `n` to a canonical form by recursively:
  ##
  ##   - flattening nested `and` / `or` chains into n-ary operands
  ##   - sorting `and` / `or` operands lexicographically by their
  ##     own normalized renderings (since both operators are
  ##     commutative — this is the spec's "sort commutative
  ##     and/or operand sets" rule)
  ##   - dropping unary `and` / `or` wrappers (a chain that reduces
  ##     to one operand collapses)
  ##   - lowercasing identifiers that are in the standard predicate
  ##     set (the standard set is lowercase by convention; user-
  ##     defined identifiers retain their original casing)
  ##   - normalizing operands of `not`, `==`, `!=`, `in`, and `[]`
  ##     recursively
  ##
  ## Redundant parentheses fall out automatically from re-rendering
  ## an n-ary tree where each operator's precedence is fixed.
  case n.kind
  of pnBoolLit:
    result = PredNode(kind: pnBoolLit, boolVal: n.boolVal)
  of pnIdent:
    let canon =
      if isStandardIdent(n.ident): n.ident.toLowerAscii()
      else: n.ident
    result = PredNode(kind: pnIdent, ident: canon)
  of pnStrLit:
    result = PredNode(kind: pnStrLit, strVal: n.strVal)
  of pnList:
    result = PredNode(kind: pnList)
    for it in n.items:
      result.items.add normalizeAst(it)
  of pnAnd:
    var flat = flattenAnd(n)
    var norm: seq[PredNode] = @[]
    for op in flat:
      norm.add normalizeAst(op)
    norm.sort(proc (a, b: PredNode): int = cmp(renderNode(a), renderNode(b)))
    if norm.len == 1:
      result = norm[0]
    else:
      result = PredNode(kind: pnAnd, operands: norm)
  of pnOr:
    var flat = flattenOr(n)
    var norm: seq[PredNode] = @[]
    for op in flat:
      norm.add normalizeAst(op)
    norm.sort(proc (a, b: PredNode): int = cmp(renderNode(a), renderNode(b)))
    if norm.len == 1:
      result = norm[0]
    else:
      result = PredNode(kind: pnOr, operands: norm)
  of pnNot:
    result = PredNode(kind: pnNot, operand: normalizeAst(n.operand))
  of pnEq:
    result = PredNode(kind: pnEq,
      lhs: normalizeAst(n.lhs), rhs: normalizeAst(n.rhs))
  of pnNe:
    result = PredNode(kind: pnNe,
      lhs: normalizeAst(n.lhs), rhs: normalizeAst(n.rhs))
  of pnIn:
    result = PredNode(kind: pnIn,
      lhs: normalizeAst(n.lhs), rhs: normalizeAst(n.rhs))

proc canonicalize*(source: string; profilePath = ""; line = 0): string =
  ## Convenience: parse `source`, normalize, and re-render. The result
  ## is the canonical form of the predicate. Two predicate strings
  ## whose canonical forms are equal are treated as the same `when`
  ## block by the editor.
  let ast = parsePredicate(profilePath, source, line)
  let norm = normalizeAst(ast)
  result = renderNode(norm)

proc renderPredicate*(n: PredNode): string =
  ## Re-render a predicate AST in canonical form. Intended for the
  ## structural editor when it needs to write a new `when` / `if`
  ## block header.
  result = renderNode(n)

# ---------------------------------------------------------------------------
# Evaluator.
# ---------------------------------------------------------------------------

proc evaluateBool*(n: PredNode; ctx: HostContext;
                   userPredicate: UserPredicateEvaluator = nil): bool =
  ## Evaluate a predicate AST against host facts. Referentially
  ## transparent: same AST + same `ctx` always returns the same bool.
  ## Unknown identifiers raise; the caller is responsible for ensuring
  ## the AST was validated through `validatePredicate` first.
  case n.kind
  of pnBoolLit:
    result = n.boolVal
  of pnIdent:
    let id = n.ident.toLowerAscii()
    if id in StandardPlatformIdents:
      if id == "wsl":
        result = ctx.isWsl
      else:
        result = ctx.platform == id
    elif id in StandardArchIdents:
      result = ctx.arch == id
    elif id == StandardHostIdent:
      raise newException(ValueError,
        "the `host` identifier is a string, not a bool — use `host == \"...\"`")
    else:
      if userPredicate == nil:
        raise newException(ValueError,
          "no user-predicate evaluator provided for '" & n.ident & "'")
      result = userPredicate(n.ident, ctx)
  of pnStrLit:
    raise newException(ValueError,
      "string literal cannot stand alone as a boolean predicate")
  of pnList:
    raise newException(ValueError,
      "list literal cannot stand alone as a boolean predicate")
  of pnAnd:
    result = true
    for op in n.operands:
      if not evaluateBool(op, ctx, userPredicate):
        return false
  of pnOr:
    result = false
    for op in n.operands:
      if evaluateBool(op, ctx, userPredicate):
        return true
  of pnNot:
    result = not evaluateBool(n.operand, ctx, userPredicate)
  of pnEq, pnNe, pnIn:
    # Comparison operands are either string literals, the `host` built-in,
    # or string-list literals (for `in`). Resolve to string(s) and compare.
    proc resolveStr(x: PredNode): string =
      case x.kind
      of pnStrLit: x.strVal
      of pnIdent:
        if x.ident.toLowerAscii() == StandardHostIdent:
          ctx.host
        else:
          raise newException(ValueError,
            "predicate comparison only supports `host` and string literals; got '" &
            x.ident & "'")
      else:
        raise newException(ValueError,
          "predicate comparison only supports `host` and string literals")
    case n.kind
    of pnEq:
      result = resolveStr(n.lhs) == resolveStr(n.rhs)
    of pnNe:
      result = resolveStr(n.lhs) != resolveStr(n.rhs)
    of pnIn:
      if n.rhs.kind != pnList:
        raise newException(ValueError,
          "right-hand side of `in` must be a list literal")
      let l = resolveStr(n.lhs)
      result = false
      for item in n.rhs.items:
        if resolveStr(item) == l:
          return true
    else: discard

# ---------------------------------------------------------------------------
# Predicate validation (resolve unknown identifiers to user modules).
# ---------------------------------------------------------------------------

proc collectIdents(n: PredNode; into: var HashSet[string]) =
  case n.kind
  of pnIdent:
    if not isStandardIdent(n.ident):
      into.incl(n.ident)
  of pnList:
    for it in n.items:
      collectIdents(it, into)
  of pnAnd, pnOr:
    for op in n.operands:
      collectIdents(op, into)
  of pnNot:
    collectIdents(n.operand, into)
  of pnEq, pnNe, pnIn:
    collectIdents(n.lhs, into)
    collectIdents(n.rhs, into)
  else: discard

proc validatePredicate*(profilePath: string; line: int; n: PredNode;
                       userLookup: UserPredicateLookup;
                       searchedModules: seq[string]) =
  ## Walk the AST and ensure every non-standard identifier resolves
  ## through `userLookup`. Identifiers in equality positions on the
  ## RHS of `==`/`!=`/`in` that are list items or the host built-in
  ## are allowed. Raises `EUnknownPredicate` for any identifier the
  ## lookup rejects.
  var idents = initHashSet[string]()
  collectIdents(n, idents)
  for id in idents:
    let known = if userLookup != nil: userLookup(id) else: false
    if not known:
      raiseUnknownPredicate(profilePath, id, line, 0, searchedModules)
