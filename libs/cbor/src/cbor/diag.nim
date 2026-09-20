## A reader for CBOR diagnostic notation (RFC 8949 §8, extended per
## RFC 8610 Appendix G).
##
## ## Why a library has a notation parser in it
##
## Because the published test vectors are written in it. RFC 8949
## Appendix A gives its examples as a two-column table of *diagnostic
## notation* against *encoded bytes*, and RFC 9052 Appendix C gives
## every COSE example in diagnostic notation and in no other form. A
## suite that wants to be pinned to those documents rather than to its
## own output has to be able to read the left column; typing the left
## column into Nim literals by hand reintroduces exactly the
## transcription step the vectors exist to avoid.
##
## ## What it accepts
##
##   * integers of any width — outside the 64-bit range they become
##     RFC 8949 §3.4.3 bignums, which is how Appendix A prints them;
##   * floats, `Infinity`, `-Infinity`, `NaN`;
##   * `true`, `false`, `null`, `undefined`, `simple(n)`;
##   * `h'…'` byte strings (whitespace inside is ignored, so the RFC's
##     wrapped hex needs no pre-processing), `'…'` byte strings from
##     ASCII, `"…"` text strings with `\"`, `\\`, `\/`, `\b`, `\f`,
##     `\n`, `\r`, `\t` and `\uXXXX` including surrogate pairs;
##   * `[…]`, `{…}`, and their `[_ …]` / `{_ …}` indefinite forms;
##   * `(_ …, …)` indefinite-length strings, with the chunk boundaries
##     preserved;
##   * `n(…)` tags;
##   * `<< … >>`, the embedded-CBOR byte string COSE uses for its
##     protected header buckets. The enclosed item is encoded
##     faithfully — map order as written — because that is what the
##     published COSE examples' `/ protected h'…' /` comments say the
##     bytes are, and what their signatures are over.
##
## Anything else is refused with `cekBadDiagnostic`. It never skips what
## it does not understand: a parser that skipped would let a vector
## corpus shrink silently, and a corpus that can shrink silently is not
## a corpus.

import std/[parseutils, strutils]

import ./item
import ./bignum
import ./writer

type
  Parser = object
    src: string
    pos: int

proc badAt(p: Parser; what: string;
           site: tuple[filename: string, line: int, column: int])
          {.noreturn.} =
  var context =
    if p.pos > p.src.high: "<end of input>"
    else: p.src[p.pos .. min(p.pos + 24, p.src.high)]
  context = context.replace("\n", " ")
  cborFailAt(cekBadDiagnostic,
             what & " at offset " & $p.pos & ": " & context, site)

template bad(p: Parser; what: string) =
  ## A template for the same reason `cborFail` is one: the site recorded
  ## has to be the rule's line, not this wrapper's.
  badAt(p, what, instantiationInfo())

proc atEnd(p: Parser): bool = p.pos >= p.src.len

proc skipTrivia(p: var Parser) =
  while p.pos < p.src.len:
    let c = p.src[p.pos]
    if c in {' ', '\t', '\r', '\n'}:
      inc p.pos
    elif c == '/':
      # A `/…/` comment. Scanning to the next '/' is correct even for
      # the RFC's `/ AES-CBC-MAC-256//64 /`, which is two adjacent
      # comments rather than one; both are consumed here.
      let close = p.src.find('/', p.pos + 1)
      if close < 0:
        p.bad("unterminated comment")
      p.pos = close + 1
    else:
      return

proc peek(p: var Parser): char =
  p.skipTrivia()
  if p.atEnd: '\0' else: p.src[p.pos]

proc expect(p: var Parser; c: char) =
  if p.peek() != c:
    p.bad("expected '" & $c & "'")
  inc p.pos

proc tryEat(p: var Parser; c: char): bool =
  if p.peek() == c:
    inc p.pos
    true
  else:
    false

proc tryEatWord(p: var Parser; word: string): bool =
  p.skipTrivia()
  if p.pos + word.len <= p.src.len and
     p.src[p.pos ..< p.pos + word.len] == word:
    # A bare word must not be the prefix of a longer bare word.
    let after = p.pos + word.len
    if after < p.src.len and p.src[after] in
        {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      return false
    p.pos = after
    return true
  false

proc parseHexString(p: var Parser): seq[byte] =
  ## `h'…'`, already past the `h`. Whitespace inside is skipped so the
  ## RFC's 64-column wrapping needs no pre-processing.
  p.expect('\'')
  var nibbles = ""
  while true:
    if p.atEnd:
      p.bad("unterminated h'…'")
    let c = p.src[p.pos]
    inc p.pos
    if c == '\'':
      break
    if c in {' ', '\t', '\r', '\n'}:
      continue
    if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      p.bad("not a hex digit in h'…': " & $c)
    nibbles.add c
  if nibbles.len mod 2 != 0:
    p.bad("h'…' has an odd number of hex digits")
  result = newSeq[byte](nibbles.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(nibbles[2 * i .. 2 * i + 1]))

proc addUtf8(s: var string; cp: int) =
  if cp < 0x80:
    s.add chr(cp)
  elif cp < 0x800:
    s.add chr(0xc0 or (cp shr 6))
    s.add chr(0x80 or (cp and 0x3f))
  elif cp < 0x10000:
    s.add chr(0xe0 or (cp shr 12))
    s.add chr(0x80 or ((cp shr 6) and 0x3f))
    s.add chr(0x80 or (cp and 0x3f))
  else:
    s.add chr(0xf0 or (cp shr 18))
    s.add chr(0x80 or ((cp shr 12) and 0x3f))
    s.add chr(0x80 or ((cp shr 6) and 0x3f))
    s.add chr(0x80 or (cp and 0x3f))

proc readHex4(p: var Parser): int =
  if p.pos + 4 > p.src.len:
    p.bad("truncated \\u escape")
  result = parseHexInt(p.src[p.pos ..< p.pos + 4])
  p.pos += 4

proc parseQuoted(p: var Parser; quote: char): string =
  ## The body of a `'…'` or `"…"` literal, already past the quote.
  ## Escapes are honoured in both; UTF-8 is produced for `\uXXXX`.
  while true:
    if p.atEnd:
      p.bad("unterminated string")
    let c = p.src[p.pos]
    inc p.pos
    if c == quote:
      return
    if c != '\\':
      result.add c
      continue
    if p.atEnd:
      p.bad("string ends in a backslash")
    let e = p.src[p.pos]
    inc p.pos
    case e
    of '"': result.add '"'
    of '\'': result.add '\''
    of '\\': result.add '\\'
    of '/': result.add '/'
    of 'b': result.add '\b'
    of 'f': result.add '\f'
    of 'n': result.add '\n'
    of 'r': result.add '\r'
    of 't': result.add '\t'
    of 'u':
      var cp = p.readHex4()
      if cp >= 0xd800 and cp <= 0xdbff:
        # A high surrogate must be followed by \uDC00..\uDFFF; the pair
        # is one code point. RFC 8949 Appendix A uses this for U+10151.
        if p.pos + 2 > p.src.len or p.src[p.pos] != '\\' or
           p.src[p.pos + 1] != 'u':
          p.bad("high surrogate without a low surrogate")
        p.pos += 2
        let lo = p.readHex4()
        if lo < 0xdc00 or lo > 0xdfff:
          p.bad("not a low surrogate")
        cp = 0x10000 + ((cp - 0xd800) shl 10) + (lo - 0xdc00)
      elif cp >= 0xdc00 and cp <= 0xdfff:
        p.bad("unpaired low surrogate")
      result.addUtf8(cp)
    else:
      p.bad("unknown escape \\" & $e)

proc parseValue(p: var Parser): CborItem

proc parseIndefiniteString(p: var Parser): CborItem =
  ## `(_ chunk, chunk, …)`, already past `(_`.
  var chunks: seq[CborItem] = @[]
  if p.peek() != ')':
    while true:
      chunks.add p.parseValue()
      if not p.tryEat(','):
        break
  p.expect(')')
  if chunks.len == 0:
    p.bad("(_ …) with no chunks")
  let kind = chunks[0].kind
  if kind notin {ckBytes, ckText}:
    p.bad("(_ …) chunks must be strings")
  for c in chunks:
    if c.kind != kind or c.indefinite:
      p.bad("(_ …) chunks must all be definite strings of one type")
  if kind == ckBytes:
    result = CborItem(kind: ckBytes)
    for c in chunks:
      result.chunks.add c.bytes.len
      for b in c.bytes:
        result.bytes.add b
  else:
    result = CborItem(kind: ckText)
    for c in chunks:
      result.chunks.add c.text.len
      result.text.add c.text
  result.indefinite = true

proc parseNumberOrTag(p: var Parser): CborItem =
  p.skipTrivia()
  let start = p.pos
  if p.pos < p.src.len and p.src[p.pos] == '-':
    inc p.pos
  var digits = 0
  while p.pos < p.src.len and p.src[p.pos] in {'0' .. '9'}:
    inc p.pos
    inc digits
  if digits == 0:
    p.bad("expected a number")
  var isFloat = false
  if p.pos < p.src.len and p.src[p.pos] == '.':
    isFloat = true
    inc p.pos
    while p.pos < p.src.len and p.src[p.pos] in {'0' .. '9'}:
      inc p.pos
  if p.pos < p.src.len and p.src[p.pos] in {'e', 'E'}:
    isFloat = true
    inc p.pos
    if p.pos < p.src.len and p.src[p.pos] in {'+', '-'}:
      inc p.pos
    while p.pos < p.src.len and p.src[p.pos] in {'0' .. '9'}:
      inc p.pos
  let literal = p.src[start ..< p.pos]
  if isFloat:
    var v: float
    if parseutils.parseFloat(literal, v) != literal.len:
      p.bad("not a float literal: " & literal)
    return cFloat(v, cfwDouble)
  # An integer, unless a '(' follows — then it is a tag number.
  if p.peek() == '(':
    inc p.pos
    if literal.startsWith("-"):
      p.bad("a tag number cannot be negative")
    let m = decimalToMagnitude(literal)
    if not magnitudeFitsUint64(m):
      p.bad("tag number does not fit 64 bits")
    let content = p.parseValue()
    p.expect(')')
    return cTag(magnitudeToUint64(m), content)
  integerFromDecimal(literal)

proc parseValue(p: var Parser): CborItem =
  let c = p.peek()
  case c
  of '\0':
    p.bad("expected a value")
  of '[':
    inc p.pos
    var indef = false
    if p.peek() == '_':
      inc p.pos
      indef = true
    var elems: seq[CborItem] = @[]
    if p.peek() != ']':
      while true:
        elems.add p.parseValue()
        if not p.tryEat(','):
          break
    p.expect(']')
    result = if indef: cIndefArray(elems) else: cArray(elems)
  of '{':
    inc p.pos
    var indef = false
    if p.peek() == '_':
      inc p.pos
      indef = true
    var entries: seq[CborPair] = @[]
    if p.peek() != '}':
      while true:
        let k = p.parseValue()
        p.expect(':')
        let v = p.parseValue()
        entries.add cPair(k, v)
        if not p.tryEat(','):
          break
    p.expect('}')
    result = if indef: cIndefMap(entries) else: cMap(entries)
  of '(':
    inc p.pos
    if not p.tryEat('_'):
      p.bad("a bare '(' is only valid as the '(_' of an indefinite string")
    result = p.parseIndefiniteString()
  of '<':
    if p.pos + 1 >= p.src.len or p.src[p.pos + 1] != '<':
      p.bad("expected '<<'")
    p.pos += 2
    let inner = p.parseValue()
    p.skipTrivia()
    if p.pos + 1 >= p.src.len or p.src[p.pos] != '>' or
       p.src[p.pos + 1] != '>':
      p.bad("expected '>>'")
    p.pos += 2
    result = cBytes(encodeItem(inner))
  of '\'':
    inc p.pos
    let s = p.parseQuoted('\'')
    var b = newSeq[byte](s.len)
    for i in 0 ..< s.len:
      b[i] = byte(ord(s[i]))
    result = cBytes(b)
  of '"':
    inc p.pos
    result = cText(p.parseQuoted('"'))
  else:
    if p.tryEatWord("true"): return cTrue()
    if p.tryEatWord("false"): return cFalse()
    if p.tryEatWord("null"): return cNull()
    if p.tryEatWord("undefined"): return cUndefined()
    if p.tryEatWord("Infinity"): return cFloat(Inf, cfwHalf)
    if p.tryEatWord("NaN"): return cFloat(NaN, cfwHalf)
    if p.tryEatWord("simple"):
      p.expect('(')
      let inner = p.parseValue()
      p.expect(')')
      if inner.kind != ckUInt or inner.arg > 255'u64:
        p.bad("simple(n) needs 0 <= n <= 255")
      return cSimple(uint8(inner.arg))
    if c == 'h' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '\'':
      inc p.pos
      return cBytes(p.parseHexString())
    if c == '-':
      # `-Infinity` is the only bare word that starts with a sign.
      if p.pos + 1 < p.src.len and p.src[p.pos + 1] == 'I':
        inc p.pos
        if not p.tryEatWord("Infinity"):
          p.bad("expected -Infinity")
        return cFloat(-Inf, cfwHalf)
    result = p.parseNumberOrTag()

proc parseDiagnostic*(text: string): CborItem =
  ## One data item written in diagnostic notation, and nothing after it
  ## but whitespace and comments.
  var p = Parser(src: text, pos: 0)
  result = p.parseValue()
  p.skipTrivia()
  if not p.atEnd:
    p.bad("trailing text after the item")
