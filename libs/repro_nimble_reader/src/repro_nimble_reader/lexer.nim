## A tokenizer for the Nim syntax `.nimble` files are written in.
##
## The static reader never evaluates a `.nimble` file (NPC-AREQ8, threat
## model G1): it reads tokens and structure and nothing else. This module is
## the lexical half of that reader. It follows the Nim manual's lexical rules
## (https://nim-lang.org/docs/manual.html#lexical-analysis) for everything a
## `.nimble` file can contain, and reports an error for every input the Nim
## lexer itself rejects that the reader could otherwise misread: an
## unterminated string, character literal or multi-line comment, an unknown
## escape sequence, and a tab used as whitespace.
##
## Comments are dropped. String literals are decoded (escape sequences in
## ordinary strings; `""` in raw strings; the leading-newline rule of
## triple-quoted strings), because the reader compares their values.

{.push raises: [].}

import std/[strutils, unicode]

type
  TokenKind* = enum
    tkIdent    ## an identifier or a keyword (see `isKeyword`)
    tkString   ## a string literal of any form; `value` is decoded
    tkChar     ## a character literal
    tkNumber   ## a numeric literal, kept verbatim
    tkOperator ## a run of operator characters, including `=`, `:`, `.`
    tkOpenParen, tkCloseParen
    tkOpenBracket, tkCloseBracket
    tkOpenCurly, tkCloseCurly
    tkComma, tkSemicolon
    tkAccent   ## a backtick
    tkEof

  StringForm* = enum
    sfNormal      ## `"..."`
    sfRaw         ## `r"..."`
    sfTriple      ## `"""..."""`
    sfGeneralized ## `ident"..."` or `ident"""..."""`, a call with a raw string

  Token* = object
    kind*: TokenKind
    text*: string      ## the source text (identifier, operator, number)
    value*: string     ## the decoded value of a string literal
    form*: StringForm  ## which string form, for `tkString`
    line*: int         ## 1-based
    col*: int          ## 0-based column of the first character
    firstOnLine*: bool ## the first token on its source line
    spaceBefore*: bool ## whitespace or a line start precedes it
    spaceAfter*: bool  ## whitespace, a comment or a line end follows it

  LexError* = object
    line*: int
    col*: int
    message*: string

  LexResult* = object
    tokens*: seq[Token]    ## always ends with one `tkEof`
    errors*: seq[LexError] ## empty when the source lexes as Nim
    docComments*: seq[(int, int)]
      ## (line, column) of each `##` documentation comment that starts a
      ## line. Nim parses those as statements, so a block holding only
      ## documentation comments is not empty.

const
  OperatorChars* = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.',
                    '|', '=', '%', '&', '$', '@', '~', ':'}
  IdentStartChars = {'a'..'z', 'A'..'Z', '_', '\x80'..'\xFF'}
  IdentChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

  Keywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case",
    "cast", "concept", "const", "continue", "converter", "defer", "discard",
    "distinct", "div", "do", "elif", "else", "end", "enum", "except",
    "export", "finally", "for", "from", "func", "if", "import", "in",
    "include", "interface", "is", "isnot", "iterator", "let", "macro",
    "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
    "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
    "template", "try", "tuple", "type", "using", "var", "when", "while",
    "xor", "yield"]

proc styleTail(s: string): string =
  ## Everything after the first character, lower-cased, underscores removed:
  ## the part of a Nim identifier that is compared style-insensitively.
  for i in 1 ..< s.len:
    if s[i] != '_':
      result.add toLowerAscii(s[i])

proc nimIdentEq*(a, b: string): bool =
  ## Nim's identifier equality: the first character is compared exactly, the
  ## rest ignoring case and underscores (`srcDir` == `src_dir` == `srcdir`,
  ## but `SrcDir` is another identifier).
  a.len > 0 and b.len > 0 and a[0] == b[0] and styleTail(a) == styleTail(b)

proc styleKey*(s: string): string =
  ## A fully case- and underscore-insensitive key, the comparison Nim's
  ## `defined(...)` symbol table and Nimble's `normalize` use.
  for c in s:
    if c != '_':
      result.add toLowerAscii(c)

proc isKeyword*(t: Token; word: string): bool =
  t.kind == tkIdent and nimIdentEq(t.text, word)

proc isAnyKeyword*(t: Token): bool =
  if t.kind != tkIdent:
    return false
  for k in Keywords:
    if nimIdentEq(t.text, k):
      return true
  false

proc isOp*(t: Token; op: string): bool =
  t.kind == tkOperator and t.text == op

type
  Lexer = object
    src: string
    pos: int
    line: int
    lineStart: int
    atLineStart: bool
    pendingSpace: bool
    result: LexResult

proc err(L: var Lexer; message: string) =
  L.result.errors.add LexError(line: L.line, col: L.pos - L.lineStart,
                               message: message)

proc cur(L: Lexer): char =
  if L.pos < L.src.len: L.src[L.pos] else: '\0'

proc peek(L: Lexer; off = 1): char =
  let p = L.pos + off
  if p < L.src.len: L.src[p] else: '\0'

proc newline(L: var Lexer) =
  ## Consume one line ending (`\n`, `\r\n` or a lone `\r`).
  if L.cur == '\r' and L.peek == '\n':
    inc L.pos
  inc L.pos
  inc L.line
  L.lineStart = L.pos
  L.atLineStart = true
  L.pendingSpace = true

proc markSpaceAfterPrevious(L: var Lexer) =
  if L.result.tokens.len > 0:
    L.result.tokens[^1].spaceAfter = true

proc skipMultilineComment(L: var Lexer; doc: bool) =
  ## `#[ ... ]#` and `##[ ... ]##`, which nest.
  var depth = 1
  inc L.pos, (if doc: 3 else: 2)
  while L.pos < L.src.len:
    let c = L.cur
    if c == '\n' or c == '\r':
      L.newline()
      continue
    if doc and c == '#' and L.peek == '#' and L.peek(2) == '[':
      inc depth
      inc L.pos, 3
    elif not doc and c == '#' and L.peek == '[':
      inc depth
      inc L.pos, 2
    elif doc and c == ']' and L.peek == '#' and L.peek(2) == '#':
      dec depth
      inc L.pos, 3
      if depth == 0:
        return
    elif not doc and c == ']' and L.peek == '#':
      dec depth
      inc L.pos, 2
      if depth == 0:
        return
    else:
      inc L.pos
  L.err("unterminated multi-line comment")

proc skipWhitespaceAndComments(L: var Lexer) =
  while L.pos < L.src.len:
    case L.cur
    of ' ':
      inc L.pos
      L.pendingSpace = true
      L.markSpaceAfterPrevious()
    of '\t':
      # The Nim lexer rejects a tab used as whitespace.
      L.err("tabs are not allowed, use spaces instead")
      inc L.pos
      L.pendingSpace = true
    of '\n', '\r':
      L.markSpaceAfterPrevious()
      L.newline()
    of '#':
      L.markSpaceAfterPrevious()
      if L.peek == '#' and L.atLineStart:
        L.result.docComments.add (L.line, L.pos - L.lineStart)
      if L.peek == '[':
        L.skipMultilineComment(doc = false)
      elif L.peek == '#' and L.peek(2) == '[':
        L.skipMultilineComment(doc = true)
      else:
        while L.pos < L.src.len and L.cur notin {'\n', '\r'}:
          inc L.pos
      L.pendingSpace = true
    else:
      return

proc addToken(L: var Lexer; tok: sink Token) =
  var t = tok
  t.firstOnLine = L.atLineStart
  t.spaceBefore = L.pendingSpace
  L.atLineStart = false
  L.pendingSpace = false
  L.result.tokens.add t

proc readEscape(L: var Lexer; into: var string) =
  ## After a backslash in an ordinary string or character literal.
  inc L.pos
  let c = L.cur
  case c
  of 'n', 'N', 'l', 'L': into.add '\n'; inc L.pos
  of 'p', 'P': into.add "\n"; inc L.pos
  of 'r', 'R', 'c', 'C': into.add '\r'; inc L.pos
  of 't', 'T': into.add '\t'; inc L.pos
  of 'f', 'F': into.add '\f'; inc L.pos
  of 'v', 'V': into.add '\v'; inc L.pos
  of 'a', 'A': into.add '\a'; inc L.pos
  of 'b', 'B': into.add '\b'; inc L.pos
  of 'e', 'E': into.add '\e'; inc L.pos
  of '\\', '"', '\'': into.add c; inc L.pos
  of 'x', 'X':
    inc L.pos
    var v = 0
    for _ in 0 ..< 2:
      let h = L.cur
      if h in HexDigits:
        v = v * 16 + (if h in Digits: ord(h) - ord('0')
          else: ord(toLowerAscii(h)) - ord('a') + 10)
        inc L.pos
      else:
        L.err("invalid \\x escape")
        return
    into.add chr(v)
  of 'u', 'U':
    inc L.pos
    var v = 0
    if L.cur == '{':
      inc L.pos
      var digits = 0
      while L.cur in HexDigits:
        let h = L.cur
        v = v * 16 + (if h in Digits: ord(h) - ord('0')
          else: ord(toLowerAscii(h)) - ord('a') + 10)
        inc L.pos
        inc digits
      if L.cur != '}' or digits == 0 or v > 0x10FFFF:
        L.err("invalid \\u{...} escape")
        return
      inc L.pos
    else:
      for _ in 0 ..< 4:
        let h = L.cur
        if h in HexDigits:
          v = v * 16 + (if h in Digits: ord(h) - ord('0')
            else: ord(toLowerAscii(h)) - ord('a') + 10)
          inc L.pos
        else:
          L.err("invalid \\u escape")
          return
    into.add $Rune(v)
  of '0'..'9':
    var v = 0
    var n = 0
    while L.cur in Digits and n < 3:
      v = v * 10 + ord(L.cur) - ord('0')
      inc L.pos
      inc n
    if v > 255:
      L.err("invalid character constant")
      return
    into.add chr(v)
  else:
    L.err("invalid character constant")
    inc L.pos

proc readTripleString(L: var Lexer; tok: var Token) =
  ## At the opening `"""`. No escapes. A newline directly after the opening
  ## quotes (optionally after spaces) is not part of the string. The string
  ## ends at the last `"` of a run of three or more quotes, so `""""` closes
  ## a string ending in one `"`.
  inc L.pos, 3
  var probe = L.pos
  while probe < L.src.len and L.src[probe] == ' ':
    inc probe
  if probe < L.src.len and L.src[probe] in {'\n', '\r'}:
    L.pos = probe
    L.newline()
    L.atLineStart = false
  while true:
    if L.pos >= L.src.len:
      L.err("unterminated triple-quoted string literal")
      return
    let c = L.cur
    if c == '"' and L.peek == '"' and L.peek(2) == '"':
      var run = 0
      while L.cur == '"':
        inc run
        inc L.pos
      for _ in 0 ..< run - 3:
        tok.value.add '"'
      return
    elif c == '\n' or c == '\r':
      tok.value.add '\n'
      L.newline()
      L.atLineStart = false
    else:
      tok.value.add c
      inc L.pos

proc readRawString(L: var Lexer; tok: var Token) =
  ## At the opening `"` of `r"..."` or `ident"..."`: `""` is one quote.
  inc L.pos
  while true:
    if L.pos >= L.src.len or L.cur in {'\n', '\r'}:
      L.err("unterminated raw string literal")
      return
    if L.cur == '"':
      if L.peek == '"':
        tok.value.add '"'
        inc L.pos, 2
      else:
        inc L.pos
        return
    else:
      tok.value.add L.cur
      inc L.pos

proc readNormalString(L: var Lexer; tok: var Token) =
  inc L.pos
  while true:
    if L.pos >= L.src.len or L.cur in {'\n', '\r'}:
      L.err("unterminated string literal")
      return
    case L.cur
    of '"':
      inc L.pos
      return
    of '\\':
      L.readEscape(tok.value)
    else:
      tok.value.add L.cur
      inc L.pos

proc readString(L: var Lexer; form: StringForm; startCol: int) =
  var tok = Token(kind: tkString, form: form, line: L.line, col: startCol)
  let start = L.pos
  if L.cur == '"' and L.peek == '"' and L.peek(2) == '"':
    if form == sfNormal:
      tok.form = sfTriple
    L.readTripleString(tok)
  elif form in {sfRaw, sfGeneralized}:
    L.readRawString(tok)
  else:
    L.readNormalString(tok)
  tok.text = L.src[start ..< min(L.pos, L.src.len)]
  L.addToken(tok)

proc readCharLit(L: var Lexer) =
  var tok = Token(kind: tkChar, line: L.line, col: L.pos - L.lineStart)
  let start = L.pos
  inc L.pos
  if L.cur == '\\':
    L.readEscape(tok.value)
  elif L.cur in {'\n', '\r', '\0'} or L.pos >= L.src.len:
    L.err("missing closing ' for character literal")
    return
  else:
    # One UTF-8 code point.
    let n = max(1, runeLenAt(L.src, L.pos))
    tok.value.add L.src[L.pos ..< min(L.pos + n, L.src.len)]
    inc L.pos, n
  if L.cur != '\'':
    L.err("missing closing ' for character literal")
    return
  inc L.pos
  tok.text = L.src[start ..< L.pos]
  L.addToken(tok)

proc readNumber(L: var Lexer) =
  var tok = Token(kind: tkNumber, line: L.line, col: L.pos - L.lineStart)
  let start = L.pos
  while L.cur in IdentChars:
    inc L.pos
  # A fraction, only when a digit follows the dot (`1..2` is a range).
  if L.cur == '.' and L.peek in Digits:
    inc L.pos
    while L.cur in IdentChars:
      inc L.pos
  if L.cur in {'+', '-'} and L.pos > start and
      L.src[L.pos - 1] in {'e', 'E'} and L.peek in Digits:
    inc L.pos
    while L.cur in IdentChars:
      inc L.pos
  if L.cur == '\'' and L.peek in IdentStartChars:
    inc L.pos
    while L.cur in IdentChars:
      inc L.pos
  tok.text = L.src[start ..< L.pos]
  L.addToken(tok)

proc readIdent(L: var Lexer) =
  let startCol = L.pos - L.lineStart
  let start = L.pos
  while L.cur in IdentChars:
    inc L.pos
  let text = L.src[start ..< L.pos]
  if L.cur == '"':
    if text in ["r", "R"]:
      L.readString(sfRaw, startCol)
      # The `r` prefix belongs to the literal: its source text starts there.
      L.result.tokens[^1].text = text & L.result.tokens[^1].text
      return
    # A generalized raw string literal: `ident"..."` is a call.
    L.addToken(Token(kind: tkIdent, text: text, line: L.line, col: startCol))
    L.readString(sfGeneralized, L.pos - L.lineStart)
    return
  L.addToken(Token(kind: tkIdent, text: text, line: L.line, col: startCol))

proc lexNim*(src: string): LexResult =
  ## Tokenize `src`. Never raises; problems are reported in `errors`.
  var L = Lexer(src: src, line: 1, atLineStart: true, pendingSpace: true)
  # A UTF-8 byte order mark is skipped, as the Nim lexer does.
  if src.startsWith("\xEF\xBB\xBF"):
    L.pos = 3
    L.lineStart = 3
  while true:
    L.skipWhitespaceAndComments()
    if L.pos >= L.src.len:
      break
    let col = L.pos - L.lineStart
    let c = L.cur
    case c
    of IdentStartChars:
      L.readIdent()
    of Digits:
      L.readNumber()
    of '"':
      L.readString(sfNormal, col)
    of '\'':
      L.readCharLit()
    of '(':
      L.addToken(Token(kind: tkOpenParen, text: "(", line: L.line, col: col)); inc L.pos
    of ')':
      L.addToken(Token(kind: tkCloseParen, text: ")", line: L.line, col: col)); inc L.pos
    of '[':
      L.addToken(Token(kind: tkOpenBracket, text: "[", line: L.line, col: col)); inc L.pos
    of ']':
      L.addToken(Token(kind: tkCloseBracket, text: "]", line: L.line,
          col: col)); inc L.pos
    of '{':
      L.addToken(Token(kind: tkOpenCurly, text: "{", line: L.line, col: col)); inc L.pos
    of '}':
      L.addToken(Token(kind: tkCloseCurly, text: "}", line: L.line, col: col)); inc L.pos
    of ',':
      L.addToken(Token(kind: tkComma, text: ",", line: L.line, col: col)); inc L.pos
    of ';':
      L.addToken(Token(kind: tkSemicolon, text: ";", line: L.line, col: col)); inc L.pos
    of '`':
      L.addToken(Token(kind: tkAccent, text: "`", line: L.line, col: col)); inc L.pos
    of OperatorChars:
      let start = L.pos
      while L.cur in OperatorChars:
        # `.}`, `.)` and `.]` close a pragma or a dotted bracket: the dot is
        # an operator of its own and the bracket is lexed next.
        if L.cur == '.' and L.peek in {'}', ')', ']'} and L.pos > start:
          break
        inc L.pos
        if L.src[L.pos - 1] == '.' and L.cur in {'}', ')', ']'}:
          break
      L.addToken(Token(kind: tkOperator, text: L.src[start ..< L.pos],
                       line: L.line, col: col))
    else:
      L.err("invalid token: '" & c & "' (\\" & $ord(c) & ")")
      inc L.pos
  L.markSpaceAfterPrevious()
  L.addToken(Token(kind: tkEof, line: L.line, col: L.pos - L.lineStart))
  L.result.tokens[^1].firstOnLine = true
  L.result
