## The TOML subset Reprobuild's hand-written lock files use: basic strings
## with the common escapes, scalar ``key = value`` lines and arrays of inline
## tables (``key = [{ a = "x", b = "y" }]``). The pinned
## ``nim-toml-serialization`` does not read ``[[array.of.tables]]``, so the
## locks keep to this subset and read it with these helpers.
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
