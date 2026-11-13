## The TOML subset Reprobuild's hand-written lock files use: basic strings
## with the common escapes, scalar ``key = value`` lines and arrays of inline
## tables (``key = [{ a = "x", b = "y" }]``). The pinned
## ``nim-toml-serialization`` does not read ``[[array.of.tables]]``, so the
## locks keep to this subset and read it with these helpers.
##
## The writers put each value on one line, but a reader takes a document as
## ``tomlStatements``, not as physical lines: TOML lets an array continue
## across newlines, and a hand-edited lock that does so is still a lock
## (Unified-Locking-And-Hooks.md §13.3, "A lock is read as TOML statements").
##
## Split out of ``repro_lock`` (GM4b) so the home-profile lock
## (``repro_home_apply/home_lock``) reads and writes the same subset without
## importing the solver ``repro_lock`` links.

import std/[strutils, tables]

# ---------------------------------------------------------------------------
# TOML escaping (basic-string subset)
# ---------------------------------------------------------------------------

proc tomlEscape*(s: string): string =
  result = newStringOfCap(s.len + 2)
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc tomlUnescape*(raw: string): string =
  result = newStringOfCap(raw.len)
  var i = 0
  while i < raw.len:
    let ch = raw[i]
    if ch == '\\' and i + 1 < raw.len:
      let nxt = raw[i + 1]
      case nxt
      of '\\': result.add('\\')
      of '"': result.add('"')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      else: result.add(nxt)
      i += 2
    else:
      result.add(ch)
      inc i


proc parseScalarString*(rhs: string): string =
  let s = rhs.strip()
  if s.len >= 2 and s[0] == '"' and s[^1] == '"':
    tomlUnescape(s[1 ..< s.high])
  else:
    s

iterator inlineTables*(rhs: string): Table[string, string] =
  ## Yield each ``{ k = "v", ... }`` inline table from an inline-table
  ## array right-hand side as a key→value map. Tolerant of whitespace;
  ## the writer always emits the canonical comma-space form.
  var s = rhs.strip()
  if s.len >= 2 and s[0] == '[' and s[^1] == ']':
    s = s[1 ..< s.high]
  var i = 0
  while i < s.len:
    while i < s.len and s[i] != '{': inc i
    if i >= s.len: break
    inc i  # past '{'
    var fields = initTable[string, string]()
    # Parse ``key = "value"`` pairs until the closing '}'.
    while i < s.len and s[i] != '}':
      while i < s.len and s[i] in {' ', '\t', ','}: inc i
      if i >= s.len or s[i] == '}': break
      # key
      var keyBuf = ""
      while i < s.len and s[i] notin {'=', ' ', '\t'}:
        keyBuf.add(s[i]); inc i
      while i < s.len and s[i] in {' ', '\t', '='}: inc i
      # value (quoted string only — the writer never emits bare values
      # inside the inline tables).
      if i < s.len and s[i] == '"':
        inc i
        var valBuf = ""
        while i < s.len and s[i] != '"':
          if s[i] == '\\' and i + 1 < s.len:
            valBuf.add(s[i]); valBuf.add(s[i + 1]); i += 2
          else:
            valBuf.add(s[i]); inc i
        inc i  # past closing quote
        if keyBuf.len > 0:
          fields[keyBuf] = tomlUnescape(valBuf)
    if i < s.len and s[i] == '}': inc i  # past '}'
    yield fields

# ---------------------------------------------------------------------------
# Statements: one ``key = value`` (or one table header) whatever its layout
# ---------------------------------------------------------------------------

type
  TomlSubsetLayoutError* = object of ValueError
    ## A document whose brackets or strings this subset cannot follow: an
    ## array or inline table still open at the end of the document, a
    ## closing bracket with nothing open, or a string that runs past the end
    ## of its line. The message names the line.

  TomlStatement* = object
    ## One TOML statement of a document: a table header, or a
    ## ``key = value`` pair whose value may span several physical lines
    ## (TOML lets an array continue across newlines, and lets comments sit
    ## between its elements).
    text*: string
      ## The statement as ONE line: its physical lines with their comments
      ## removed, joined by a single space, and stripped. What the
      ## line-oriented readers above take as "a line".
    first*, last*: int
      ## Its exact source bytes, ``text[first ..< last]`` of the scanned
      ## document: from its first non-blank character to the end of its last
      ## physical line, that line's terminator (``\n`` or ``\r\n``) excluded.
    line*: int  ## the 1-based line it starts on

proc layoutError(lineNo: int; msg: string) {.noreturn.} =
  raise newException(TomlSubsetLayoutError, "line " & $lineNo & ": " & msg)

iterator tomlStatements*(doc: string): TomlStatement =
  ## Yield every statement of ``doc`` in order, skipping blank and comment
  ## lines. A statement ends at the end of the first physical line on which
  ## every ``[`` / ``{`` its value opened is closed — so
  ##
  ##     deps = [{ name = "a" }
  ##     , { name = "b" }]
  ##
  ## is ONE statement, read and replaced as a whole. Brackets, ``#`` and
  ## quotes inside a basic (``"…"``, with escapes) or literal (``'…'``)
  ## string are text, not structure. A line that opens with ``[`` while
  ## nothing is open is a table header and is a statement on its own.
  ##
  ## Raises ``TomlSubsetLayoutError`` where the subset cannot follow the
  ## layout (see the type). Multi-line strings are not part of the subset:
  ## no lock writer emits one, and one would read as a string running past
  ## its line.
  ## (TOML 1.0, "Array" and "Inline Table": https://toml.io/en/v1.0.0#array)
  var depth = 0
  var current: TomlStatement
  var open = false
  var lineNo = 0
  var pos = 0
  while pos < doc.len:
    var eol = doc.find('\n', pos)
    if eol < 0: eol = doc.len
    var contentEnd = eol
    if contentEnd > pos and doc[contentEnd - 1] == '\r': dec contentEnd
    inc lineNo
    let raw = doc[pos ..< contentEnd]
    let stripped = raw.strip()
    if not open:
      if stripped.len == 0 or stripped.startsWith("#"):
        pos = eol + 1
        continue
      current = TomlStatement(first: pos + (raw.len - raw.strip(
        trailing = false).len), line: lineNo)
      open = true
      if stripped.startsWith("["):
        # A table header: `[lock]`, `[[certificate_policy.rule]]`. Its
        # brackets are its name, not a value.
        current.text = stripped
        current.last = contentEnd
        open = false
        yield current
        pos = eol + 1
        continue
    # Scan the physical line: track open brackets, drop the comment.
    var kept = newStringOfCap(raw.len)
    var i = 0
    while i < raw.len:
      let ch = raw[i]
      if ch == '"' or ch == '\'':
        var j = i + 1
        while j < raw.len and raw[j] != ch:
          if ch == '"' and raw[j] == '\\' and j + 1 < raw.len: j += 2
          else: inc j
        if j >= raw.len:
          layoutError(lineNo, "a string runs past the end of the line " &
            "(the lock format has no multi-line strings)")
        kept.add(raw[i .. j])
        i = j + 1
        continue
      case ch
      of '#':
        break
      of '[', '{':
        inc depth
      of ']', '}':
        dec depth
        if depth < 0:
          layoutError(lineNo, "'" & $ch & "' closes nothing; the line " &
            "continues a value that has already ended")
      else: discard
      kept.add(ch)
      inc i
    let piece = kept.strip()
    if piece.len > 0:
      if current.text.len > 0: current.text.add(' ')
      current.text.add(piece)
    current.last = contentEnd
    if depth == 0:
      open = false
      yield current
    pos = eol + 1
  if open:
    # Name the key: a value cut short (a truncated line) is the usual cause,
    # and the key is what tells the reader which record was lost. The
    # ``<key>: truncated`` wording is the one the per-key readers use for a
    # value that ends early on its own line.
    let eq = current.text.find('=')
    let key = if eq > 0: current.text[0 ..< eq].strip() & ": " else: ""
    layoutError(current.line, key & "truncated: the value that starts " &
      "here is still open at the end of the document")
