## The statement structure of a `.nimble` file, read without evaluating it.
##
## This is the structural half of the static reader. It groups the tokens of
## `lexer` into logical lines and statements by Nim's indentation rules, and
## parses the expressions the reader needs to look at (conditions, values,
## call arguments) into a small expression tree. It recognises the shapes the
## declarative subset is made of and treats every other statement as opaque:
## an opaque statement is kept as a token range, so the reader can still ask
## whether it touches a field the version record needs, but nothing inside it
## is interpreted.
##
## Structural errors that Nim's own parser reports — unbalanced brackets, a
## line indented where no block opens, a dedent to a column no enclosing block
## uses, a block opener with no body, an `elif`/`else` without a `when` or
## `if` — are reported as errors, so a file Nim cannot parse is never read as
## data. Expression shapes this parser does not know are not errors: they
## become `ekOther`, which the reader treats as a value it cannot read.

{.push raises: [].}

import std/strutils

import ./lexer

type
  SyntaxError* = object
    line*: int
    message*: string

  LogicalLine = object
    first, last: int ## token indices, inclusive
    indent: int

  ExprKind* = enum
    ekIdent, ekString, ekNumber, ekChar
    ekCall    ## `f(a, b)`, also `f"raw"`
    ekCommand ## `f a, b`
    ekInfix   ## `a op b`
    ekPrefix  ## `op a`
    ekPar     ## `(a, b)` or `(a)`
    ekBracket ## `[a, b]`
    ekCurly   ## `{a: b}`
    ekColon   ## `a: b` inside a constructor or argument list
    ekDot     ## `a.b`
    ekIndex   ## `a[b]`
    ekOther   ## a shape this reader does not parse

  Expr* = ref object
    kind*: ExprKind
    text*: string    ## identifier, operator, number, or the string value
    kids*: seq[Expr] ## operands; for calls the callee is kids[0]
    line*: int

  StmtKind* = enum
    skExpr   ## an expression statement or assignment; `head` holds it
    skWhen   ## `when` with its branches
    skIf     ## a runtime `if` with its branches
    skOpaque ## any other statement; only its token range is kept

  Branch* = object
    isElse*: bool
    condFirst*, condLast*: int ## token range of the condition
    body*: seq[Stmt]

  Stmt* = ref object
    kind*: StmtKind
    first*, last*: int         ## the whole statement's token range
    headFirst*, headLast*: int ## the head, without a block opener and body
    keyword*: string           ## the leading keyword of an opaque statement
    hasBlock*: bool            ## a `:` block follows the head
    body*: seq[Stmt]           ## that block, for `skExpr` heads
    branches*: seq[Branch]     ## for `skWhen` / `skIf`
    line*: int

  SyntaxTree* = object
    tokens*: seq[Token]
    stmts*: seq[Stmt]
    errors*: seq[SyntaxError]
    docComments: seq[(int, int)]

const
  BlockKeywords = ["when", "if", "elif", "else", "while", "for", "case", "of",
                   "try", "except", "finally", "block", "static", "defer"]
  RoutineKeywords = ["proc", "func", "template", "macro", "iterator",
                     "method", "converter"]
  SectionKeywords = ["const", "let", "var", "type", "import", "export",
                     "include", "from", "using", "mixin", "bind"]
  KeywordOperators = ["and", "or", "xor", "not", "in", "notin", "is", "isnot",
                      "of", "as", "from", "div", "mod", "shl", "shr"]
  # Commands whose `:` opens a body even when the body is on the same line.
  BlockCommands = ["task", "feature", "dev", "before", "after", "requires"]

proc keywordIn(t: Token; words: openArray[string]): string =
  if t.kind != tkIdent:
    return ""
  for w in words:
    if nimIdentEq(t.text, w):
      return w
  ""

proc isOperatorToken(t: Token): bool =
  t.kind == tkOperator or keywordIn(t, KeywordOperators).len > 0

# ---------------------------------------------------------------------------
# Logical lines
# ---------------------------------------------------------------------------

proc continuesLine(t: Token): bool =
  ## A line ending in a comma or a binary operator continues on the next line.
  ## A trailing `:` opens a block instead.
  if t.kind == tkComma:
    return true
  if t.kind == tkOperator:
    return t.text != ":"
  keywordIn(t, KeywordOperators).len > 0

proc logicalLines(tokens: seq[Token]; errors: var seq[SyntaxError]):
    seq[LogicalLine] =
  var depth = 0
  var stack: seq[TokenKind]
  var i = 0
  while i < tokens.len and tokens[i].kind != tkEof:
    var line = LogicalLine(first: i, indent: tokens[i].col)
    var j = i
    while true:
      let t = tokens[j]
      case t.kind
      of tkOpenParen, tkOpenBracket, tkOpenCurly:
        stack.add t.kind
        inc depth
      of tkCloseParen, tkCloseBracket, tkCloseCurly:
        let want = case t.kind
          of tkCloseParen: tkOpenParen
          of tkCloseBracket: tkOpenBracket
          else: tkOpenCurly
        if stack.len == 0 or stack[^1] != want:
          errors.add SyntaxError(line: t.line,
                                 message: "unbalanced '" & t.text & "'")
          if stack.len > 0:
            discard stack.pop()
            dec depth
        else:
          discard stack.pop()
          dec depth
      else:
        discard
      let next = tokens[j + 1]
      if next.kind == tkEof:
        if depth == 0 and continuesLine(t):
          # `requires "a",` as the last line: Nim expects an expression.
          errors.add SyntaxError(line: t.line,
            message: "expected an expression after '" & t.text & "'")
        break
      if next.firstOnLine and depth == 0 and not continuesLine(t):
        break
      inc j
    line.last = j
    result.add line
    i = j + 1
  if stack.len > 0:
    errors.add SyntaxError(line: tokens[^1].line,
                           message: "unclosed bracket at end of file")

# ---------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------

type
  ExprParser = object
    toks: ptr seq[Token]
    pos, last: int
    failed: bool

proc tok(p: ExprParser): Token =
  if p.pos <= p.last: p.toks[][p.pos] else: Token(kind: tkEof)

proc atEnd(p: ExprParser): bool = p.pos > p.last

proc other(line: int): Expr = Expr(kind: ekOther, line: line)

proc precedence(t: Token): int =
  ## Binary operator precedence, after the Nim manual's table. 0 means "not a
  ## binary operator here".
  let kw = keywordIn(t, KeywordOperators)
  if kw.len > 0:
    case kw
    of "or", "xor": return 3
    of "and": return 4
    of "in", "notin", "is", "isnot", "of", "as", "from": return 5
    of "div", "mod", "shl", "shr": return 9
    else: return 0
  if t.kind != tkOperator:
    return 0
  let s = t.text
  if s in ["=", ":", "."]:
    return 0
  if s.len > 1 and s[^1] == '=' and s[0] notin {'<', '>', '!', '=', '~', '?'}:
    return 1 # assignment-like operators
  if s.len > 1 and (s.endsWith("->") or s.endsWith("=>") or s.endsWith("~>")):
    return 1
  case s[0]
  of '$', '^': 10
  of '*', '%', '\\', '/': 9
  of '+', '-', '~', '|': 8
  of '&': 7
  of '.': 6
  of '=', '<', '>', '!': 5
  of '@', ':', '?': 2
  else: 0

proc parseExpr(p: var ExprParser; minPrec = 1): Expr

proc parseList(p: var ExprParser; close: TokenKind): seq[Expr] =
  ## After an opening bracket: comma-separated items up to `close`.
  while not p.atEnd and p.tok.kind != close:
    var item = p.parseExpr()
    if p.tok.isOp(":"):
      inc p.pos
      let value = p.parseExpr()
      item = Expr(kind: ekColon, kids: @[item, value], line: item.line)
    elif p.tok.isOp("="):
      # Named argument `f(a = b)`.
      inc p.pos
      let value = p.parseExpr()
      item = Expr(kind: ekColon, kids: @[item, value], line: item.line)
    result.add item
    if p.tok.kind == tkComma:
      inc p.pos
    elif p.tok.kind != close:
      p.failed = true
      return
  if p.tok.kind == close:
    inc p.pos
  else:
    p.failed = true

proc startsOperand(t: Token): bool =
  case t.kind
  of tkIdent: not isOperatorToken(t) or t.isKeyword("not")
  of tkString, tkNumber, tkChar, tkOpenParen, tkOpenBracket, tkOpenCurly,
     tkAccent: true
  of tkOperator: t.text notin [":", "=", "."] and t.spaceBefore and
                 not t.spaceAfter
  else: false

proc parsePrimary(p: var ExprParser; allowCommand: bool): Expr =
  let t = p.tok
  case t.kind
  of tkOperator:
    if t.text in [":", "=", "."]:
      p.failed = true
      return other(t.line)
    inc p.pos
    let operand = p.parsePrimary(allowCommand = false)
    return Expr(kind: ekPrefix, text: t.text, kids: @[operand], line: t.line)
  of tkIdent:
    if t.isKeyword("not"):
      inc p.pos
      let operand = p.parseExpr(minPrec = 5)
      return Expr(kind: ekPrefix, text: "not", kids: @[operand], line: t.line)
    if isOperatorToken(t) or (t.isAnyKeyword and
        keywordIn(t, ["nil", "addr", "cast", "static", "ptr", "ref"]).len == 0):
      p.failed = true
      return other(t.line)
    inc p.pos
    result = Expr(kind: ekIdent, text: t.text, line: t.line)
  of tkString:
    inc p.pos
    result = Expr(kind: ekString, text: t.value, line: t.line)
  of tkNumber:
    inc p.pos
    result = Expr(kind: ekNumber, text: t.text, line: t.line)
  of tkChar:
    inc p.pos
    result = Expr(kind: ekChar, text: t.value, line: t.line)
  of tkOpenParen:
    inc p.pos
    result = Expr(kind: ekPar, kids: p.parseList(tkCloseParen), line: t.line)
  of tkOpenBracket:
    inc p.pos
    result = Expr(kind: ekBracket, kids: p.parseList(tkCloseBracket),
                  line: t.line)
  of tkOpenCurly:
    inc p.pos
    result = Expr(kind: ekCurly, kids: p.parseList(tkCloseCurly), line: t.line)
  of tkAccent:
    inc p.pos
    var name = ""
    while not p.atEnd and p.tok.kind != tkAccent:
      name.add p.tok.text
      inc p.pos
    if p.tok.kind != tkAccent:
      p.failed = true
      return other(t.line)
    inc p.pos
    result = Expr(kind: ekIdent, text: name, line: t.line)
  else:
    p.failed = true
    return other(t.line)
  # Postfix: calls, indexing, member access, generalized raw strings.
  while not p.atEnd and not p.failed:
    let n = p.tok
    if n.kind == tkOpenParen and not n.spaceBefore:
      inc p.pos
      result = Expr(kind: ekCall, kids: @[result] & p.parseList(tkCloseParen),
                    line: result.line)
    elif n.kind == tkOpenBracket and not n.spaceBefore:
      inc p.pos
      result = Expr(kind: ekIndex, kids: @[result] & p.parseList(tkCloseBracket),
                    line: result.line)
    elif n.kind == tkOpenCurly and not n.spaceBefore:
      inc p.pos
      result = Expr(kind: ekCall,
        kids: @[result, Expr(kind: ekCurly, kids: p.parseList(tkCloseCurly),
                             line: n.line)], line: result.line)
    elif n.isOp(".") and p.pos + 1 <= p.last and
        p.toks[][p.pos + 1].kind in {tkIdent, tkAccent}:
      inc p.pos
      let member = p.tok
      inc p.pos
      result = Expr(kind: ekDot,
        kids: @[result, Expr(kind: ekIdent, text: member.text,
            line: member.line)],
        line: result.line)
    elif n.kind == tkString and n.form == sfGeneralized:
      inc p.pos
      result = Expr(kind: ekCall,
        kids: @[result, Expr(kind: ekString, text: n.value, line: n.line)],
        line: result.line)
    else:
      break
  # Command syntax: `f a, b`.
  if allowCommand and not p.atEnd and not p.failed and
      result.kind in {ekIdent, ekDot} and p.tok.spaceBefore and
      startsOperand(p.tok):
    var args = @[result]
    while true:
      args.add p.parseExpr()
      if p.failed:
        break
      if not p.atEnd and p.tok.kind == tkComma:
        inc p.pos
        continue
      break
    result = Expr(kind: ekCommand, kids: args, line: result.line)

proc parseExpr(p: var ExprParser; minPrec = 1): Expr =
  result = p.parsePrimary(allowCommand = minPrec <= 1)
  while not p.atEnd and not p.failed:
    let t = p.tok
    let prec = precedence(t)
    if prec == 0 or prec < minPrec:
      break
    inc p.pos
    # `^` and assignment-like operators associate to the right.
    let rightAssoc = t.kind == tkOperator and (t.text[0] == '^' or prec == 1)
    let rhs = p.parseExpr(if rightAssoc: prec else: prec + 1)
    result = Expr(kind: ekInfix, text: (if t.kind ==
        tkIdent: t.text.toLowerAscii
      else: t.text),
                  kids: @[result, rhs], line: t.line)

proc parseExprRange*(tree: SyntaxTree; first, last: int): Expr =
  ## Parse tokens `first..last` as one expression. Anything the parser does
  ## not consume completely is `ekOther`.
  if first > last:
    return other(if first < tree.tokens.len: tree.tokens[first].line else: 0)
  var p = ExprParser(toks: unsafeAddr tree.tokens, pos: first, last: last)
  result = p.parseExpr()
  if p.failed or not p.atEnd:
    return other(tree.tokens[first].line)

# ---------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------

type
  StmtParser = object
    tree: ptr SyntaxTree
    lines: seq[LogicalLine]
    idx: int

proc toks(sp: StmtParser): ptr seq[Token] = addr sp.tree[].tokens

proc error(sp: var StmtParser; line: int; message: string) =
  sp.tree[].errors.add SyntaxError(line: line, message: message)

proc findDepth0(toks: seq[Token]; first, last: int;
                pred: proc (t: Token): bool {.noSideEffect, raises: [].}): int =
  var depth = 0
  for i in first .. last:
    let t = toks[i]
    case t.kind
    of tkOpenParen, tkOpenBracket, tkOpenCurly: inc depth
    of tkCloseParen, tkCloseBracket, tkCloseCurly: dec depth
    else:
      if depth == 0 and pred(t):
        return i
  -1

proc isColon(t: Token): bool {.noSideEffect.} = t.isOp(":")
proc isSemicolon(t: Token): bool {.noSideEffect.} = t.kind == tkSemicolon
proc isBranchKeyword(t: Token): bool {.noSideEffect.} =
  t.isKeyword("elif") or t.isKeyword("else")

proc parseBlock(sp: var StmtParser; indent: int): seq[Stmt]
proc parseInline(sp: var StmtParser; first, last: int): seq[Stmt]

proc childBlock(sp: var StmtParser; parentIndent, openerLine: int): seq[Stmt] =
  ## The indented block after a trailing `:` (or a routine's `=`).
  if sp.idx < sp.lines.len and sp.lines[sp.idx].indent > parentIndent:
    return sp.parseBlock(sp.lines[sp.idx].indent)
  # A block of documentation comments only is a block of comment statements.
  let nextLine = if sp.idx < sp.lines.len: sp.toks[][sp.lines[
      sp.idx].first].line
                 else: high(int)
  for (line, col) in sp.tree[].docComments:
    if line > openerLine and line < nextLine and col > parentIndent:
      return
  sp.error(openerLine, "expected an indented block")

proc skipIndented(sp: var StmtParser; parentIndent: int): int =
  ## Consume every following line indented deeper than `parentIndent`, for an
  ## opaque statement; return the last token index consumed, or -1.
  result = -1
  while sp.idx < sp.lines.len and sp.lines[sp.idx].indent > parentIndent:
    result = sp.lines[sp.idx].last
    inc sp.idx

proc lastTokenOf(stmts: seq[Stmt]; fallback: int): int =
  if stmts.len == 0: fallback else: stmts[^1].last

proc parseBranchBody(sp: var StmtParser; indent: int; colon, last: int;
                     line: int; branchLast: var int): seq[Stmt] =
  ## The body of one `when`/`if` branch: inline after `:` or an indented block.
  if colon < 0:
    sp.error(line, "expected ':'")
    branchLast = last
    return
  if colon < last:
    result = sp.parseInline(colon + 1, last)
    branchLast = last
  else:
    result = sp.childBlock(indent, line)
    branchLast = lastTokenOf(result, last)

proc splitInlineBranches(toks: seq[Token]; first, last: int): seq[int] =
  ## Indices of depth-0 `elif`/`else` keywords inside an inline body.
  var depth = 0
  for i in first .. last:
    let t = toks[i]
    case t.kind
    of tkOpenParen, tkOpenBracket, tkOpenCurly: inc depth
    of tkCloseParen, tkCloseBracket, tkCloseCurly: dec depth
    else:
      if depth == 0 and isBranchKeyword(t):
        result.add i

proc parseConditional(sp: var StmtParser; line: LogicalLine;
                      kind: StmtKind): Stmt =
  let toks = sp.toks
  result = Stmt(kind: kind, first: line.first, headFirst: line.first,
                headLast: line.first, line: toks[][line.first].line)
  var segFirst = line.first
  var lastTok = line.last
  # Branches on this logical line (`when a: x else: y`).
  var cutPoints: seq[int]
  let colon0 = findDepth0(toks[], line.first + 1, line.last, isColon)
  if colon0 >= 0 and colon0 < line.last:
    cutPoints = splitInlineBranches(toks[], colon0 + 1, line.last)
  var segments: seq[(int, int)]
  for c in cutPoints:
    segments.add (segFirst, c - 1)
    segFirst = c
  segments.add (segFirst, line.last)
  for si, (a, b) in segments:
    let isElse = toks[][a].isKeyword("else")
    let colon = findDepth0(toks[], a + 1, b, isColon)
    var br = Branch(isElse: isElse)
    if not isElse:
      br.condFirst = a + 1
      br.condLast = (if colon < 0: b else: colon - 1)
      if br.condFirst > br.condLast:
        sp.error(toks[][a].line, "expected a condition")
    var branchLast = b
    if si < segments.len - 1:
      if colon < 0 or colon == b:
        sp.error(toks[][a].line, "expected an inline branch body")
      else:
        br.body = sp.parseInline(colon + 1, b)
    else:
      br.body = sp.parseBranchBody(line.indent, colon, b, toks[][a].line,
                                   branchLast)
    lastTok = max(lastTok, branchLast)
    result.branches.add br
  # Further branches on following lines at the same indentation.
  while sp.idx < sp.lines.len and sp.lines[sp.idx].indent == line.indent and
      isBranchKeyword(toks[][sp.lines[sp.idx].first]):
    if result.branches.len > 0 and result.branches[^1].isElse:
      sp.error(toks[][sp.lines[sp.idx].first].line, "branch after 'else'")
    let bl = sp.lines[sp.idx]
    inc sp.idx
    let isElse = toks[][bl.first].isKeyword("else")
    let colon = findDepth0(toks[], bl.first + 1, bl.last, isColon)
    var br = Branch(isElse: isElse)
    if not isElse:
      br.condFirst = bl.first + 1
      br.condLast = (if colon < 0: bl.last else: colon - 1)
      if br.condFirst > br.condLast:
        sp.error(toks[][bl.first].line, "expected a condition")
    var branchLast = bl.last
    br.body = sp.parseBranchBody(bl.indent, colon, bl.last,
                                 toks[][bl.first].line, branchLast)
    lastTok = max(lastTok, branchLast)
    result.branches.add br
  result.last = lastTok

proc parseOneLine(sp: var StmtParser; line: LogicalLine): Stmt =
  ## One logical line that begins a statement at the current indentation.
  let toks = sp.toks
  let head = toks[][line.first]
  let headLine = head.line
  if head.isKeyword("when"):
    return sp.parseConditional(line, skWhen)
  if head.isKeyword("if"):
    return sp.parseConditional(line, skIf)
  if isBranchKeyword(head):
    sp.error(headLine, "'" & head.text & "' without 'when' or 'if'")
    let last = max(line.last, sp.skipIndented(line.indent))
    return Stmt(kind: skOpaque, first: line.first, last: last,
                headFirst: line.first, headLast: line.last, line: headLine,
                keyword: head.text)
  let blockKw = keywordIn(head, BlockKeywords)
  let routineKw = keywordIn(head, RoutineKeywords)
  let sectionKw = keywordIn(head, SectionKeywords)
  if blockKw.len > 0 or routineKw.len > 0 or sectionKw.len > 0 or
      (head.isAnyKeyword and keywordIn(head, ["discard", "return", "raise",
        "yield", "break", "continue", "asm", "nil", "addr", "cast"]).len ==
        0 and
       not isOperatorToken(head)):
    # An opaque statement: its own line plus every deeper-indented line, and
    # the `of`/`elif`/`else`/`except`/`finally` lines of a `case` or `try`.
    let kw = (if blockKw.len > 0: blockKw elif routineKw.len > 0: routineKw
      elif sectionKw.len > 0: sectionKw else: head.text)
    var last = line.last
    let tail = toks[][line.last]
    let opensBlock = tail.isOp(":") or (routineKw.len > 0 and tail.isOp("="))
    let deeper = sp.skipIndented(line.indent)
    if deeper >= 0:
      last = deeper
    elif opensBlock:
      sp.error(headLine, "expected an indented block")
    if kw in ["case", "try"]:
      while sp.idx < sp.lines.len and sp.lines[sp.idx].indent == line.indent and
          keywordIn(toks[][sp.lines[sp.idx].first],
                    ["of", "elif", "else", "except", "finally"]).len > 0:
        last = sp.lines[sp.idx].last
        inc sp.idx
        let d = sp.skipIndented(line.indent)
        if d >= 0:
          last = d
    return Stmt(kind: skOpaque, first: line.first, last: last,
                headFirst: line.first, headLast: line.last, line: headLine,
                keyword: kw)
  # An expression statement, possibly with a `:` body.
  var colon = -1
  if toks[][line.last].isOp(":"):
    colon = line.last
  elif keywordIn(head, BlockCommands).len > 0:
    colon = findDepth0(toks[], line.first + 1, line.last, isColon)
  if colon < 0:
    return Stmt(kind: skExpr, first: line.first, last: line.last,
                headFirst: line.first, headLast: line.last, line: headLine)
  result = Stmt(kind: skExpr, first: line.first, headFirst: line.first,
                headLast: colon - 1, hasBlock: true, line: headLine)
  if colon < line.last:
    result.body = sp.parseInline(colon + 1, line.last)
    result.last = line.last
  else:
    result.body = sp.childBlock(line.indent, headLine)
    result.last = lastTokenOf(result.body, line.last)

proc parseInline(sp: var StmtParser; first, last: int): seq[Stmt] =
  ## Statements written after a `:` on the same line, separated by `;`.
  var a = first
  while a <= last:
    var b = findDepth0(sp.toks[], a, last, isSemicolon)
    let segLast = (if b < 0: last else: b - 1)
    if segLast >= a:
      let line = LogicalLine(first: a, last: segLast,
                             indent: high(int) div 2)
      let saved = sp.idx
      # An inline statement owns no following lines.
      let savedLines = sp.lines
      sp.lines = @[]
      sp.idx = 0
      result.add sp.parseOneLine(line)
      sp.lines = savedLines
      sp.idx = saved
    if b < 0:
      break
    a = b + 1

proc splitSemicolons(sp: var StmtParser; line: LogicalLine): seq[LogicalLine] =
  ## A logical line may hold several statements separated by `;`, unless a
  ## block opener comes first (then the `;` belongs to the inline body).
  let toks = sp.toks
  var a = line.first
  while true:
    let colon = findDepth0(toks[], a, line.last, isColon)
    let semi = findDepth0(toks[], a, line.last, isSemicolon)
    if semi < 0 or (colon >= 0 and colon < semi):
      result.add LogicalLine(first: a, last: line.last, indent: line.indent)
      return
    if semi > a:
      result.add LogicalLine(first: a, last: semi - 1, indent: line.indent)
    a = semi + 1
    if a > line.last:
      return

proc isExprBranchKeyword(t: Token): bool {.noSideEffect.} =
  keywordIn(t, ["elif", "else", "of", "except", "finally"]).len > 0

proc isExprKeyword(t: Token): bool {.noSideEffect.} =
  keywordIn(t, ["when", "if", "case", "try"]).len > 0

proc absorbExpressionBranches(sp: var StmtParser; st: Stmt; line: LogicalLine) =
  ## `const x = when c:` / `let y = case v` continue with `else:` / `of`
  ## lines at the statement's own indentation. Such a statement is never data
  ## the reader reads, so the branches are only absorbed into its token range.
  if st.kind in {skWhen, skIf}:
    return
  if line.first + 1 > line.last or
      findDepth0(sp.toks[], line.first + 1, line.last, isExprKeyword) < 0:
    return
  while sp.idx < sp.lines.len and sp.lines[sp.idx].indent == line.indent and
      isExprBranchKeyword(sp.toks[][sp.lines[sp.idx].first]):
    st.last = max(st.last, sp.lines[sp.idx].last)
    inc sp.idx
    let d = sp.skipIndented(line.indent)
    if d >= 0:
      st.last = max(st.last, d)

proc checkCommaContinuations(sp: var StmtParser; line: LogicalLine;
                             indent: int) =
  ## A statement of a block continued after a comma (outside brackets) goes
  ## on deeper than the block: Nim rejects `requires "a",` followed by `"b"`
  ## at the statement's own column. After a binary operator Nim accepts the
  ## same column, and the deeper lines of an `import` or a section belong to
  ## that statement, so only this case is checked.
  let toks = sp.toks
  var depth = 0
  for i in line.first .. line.last:
    let t = toks[][i]
    if i > line.first and t.firstOnLine and depth == 0 and
        toks[][i - 1].kind == tkComma and t.col <= indent:
      sp.error(t.line, "invalid indentation")
    case t.kind
    of tkOpenParen, tkOpenBracket, tkOpenCurly: inc depth
    of tkCloseParen, tkCloseBracket, tkCloseCurly: dec depth
    else: discard

proc parseBlock(sp: var StmtParser; indent: int): seq[Stmt] =
  while sp.idx < sp.lines.len:
    let line = sp.lines[sp.idx]
    if line.indent < indent:
      return
    if line.indent > indent:
      sp.error(sp.toks[][line.first].line, "invalid indentation")
      inc sp.idx
      continue
    inc sp.idx
    sp.checkCommaContinuations(line, indent)
    let parts = sp.splitSemicolons(line)
    for pi, part in parts:
      if pi < parts.len - 1:
        # Only the last statement of the line may own an indented block.
        let saved = sp.lines
        let savedIdx = sp.idx
        sp.lines = @[]
        sp.idx = 0
        result.add sp.parseOneLine(part)
        sp.lines = saved
        sp.idx = savedIdx
      else:
        let st = sp.parseOneLine(part)
        sp.absorbExpressionBranches(st, part)
        result.add st

proc parseNim*(src: string): SyntaxTree =
  ## Read the statement structure of `src`. Never raises and never evaluates.
  let lexed = lexNim(src)
  result.tokens = lexed.tokens
  result.docComments = lexed.docComments
  for e in lexed.errors:
    result.errors.add SyntaxError(line: e.line, message: e.message)
  let lines = logicalLines(result.tokens, result.errors)
  if lines.len == 0:
    return
  var sp = StmtParser(tree: addr result, lines: lines)
  let topIndent = lines[0].indent
  if topIndent != 0:
    result.errors.add SyntaxError(line: result.tokens[lines[0].first].line,
                                  message: "invalid indentation")
  result.stmts = sp.parseBlock(topIndent)
  while sp.idx < lines.len:
    # A dedent below the top-level indentation, or to a column no block uses.
    result.errors.add SyntaxError(line: result.tokens[lines[sp.idx].first].line,
                                  message: "invalid indentation")
    inc sp.idx
    let more = sp.parseBlock(lines[sp.idx - 1].indent)
    result.stmts.add more

proc headExpr*(tree: SyntaxTree; s: Stmt): Expr =
  tree.parseExprRange(s.headFirst, s.headLast)

proc condExpr*(tree: SyntaxTree; b: Branch): Expr =
  tree.parseExprRange(b.condFirst, b.condLast)

proc sourceText*(tree: SyntaxTree; first, last: int): string =
  ## A readable rendering of tokens `first..last`, for diagnostics.
  for i in first .. min(last, tree.tokens.len - 1):
    let t = tree.tokens[i]
    if i > first and t.spaceBefore:
      result.add ' '
    case t.kind
    of tkString: result.add '"' & t.value.replace("\"", "\\\"") & '"'
    of tkEof: discard
    else: result.add t.text
