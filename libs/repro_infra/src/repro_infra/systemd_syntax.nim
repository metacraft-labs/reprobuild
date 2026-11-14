## A unit file's text read with systemd's own grammar: its lines (with
## continuations), the words of a value, and the commands of an
## ``Exec*=`` line. A check that decides what a unit can reach must split
## the text where systemd splits it, or a line systemd reads as a setting
## of its own is folded into another one (A13 review round 6, findings 1
## and 2).
##
## Sources (systemd v257, the version of the supported bases' newest
## systemd; the grammar is unchanged since v246):
##
## - ``config_parse()`` in ``src/shared/conf-parser.c``
##   (https://github.com/systemd/systemd/blob/v257/src/shared/conf-parser.c):
##   a line whose first non-blank character is ``#`` or ``;`` is a comment
##   and is skipped, also inside a continuation; a line continues only when
##   its last character is a backslash that is not itself escaped -- the
##   whole accumulated text is scanned, a backslash escaping the character
##   after it -- and that backslash is replaced with a space before the next
##   line is appended as it is. ``\\`` at the end is an escaped backslash,
##   and ``\`` followed by a blank ends in a blank: neither continues.
## - ``read_line_full()`` in ``src/basic/fileio.c``
##   (https://github.com/systemd/systemd/blob/v257/src/basic/fileio.c): a
##   line ends at ``\n``, ``\r``, ``\r\n``, ``\n\r`` or ``\0``.
## - ``extract_first_word()`` in ``src/basic/extract-word.c``
##   (https://github.com/systemd/systemd/blob/v257/src/basic/extract-word.c)
##   with ``EXTRACT_UNQUOTE|EXTRACT_CUNESCAPE``, and ``cunescape_one()`` in
##   ``src/basic/escape.c``.
## - ``config_parse_exec()`` in ``src/core/load-fragment.c``
##   (https://github.com/systemd/systemd/blob/v257/src/core/load-fragment.c):
##   several commands in one line, separated by a lone unquoted ``;``
##   (``\;`` is a literal argument), each with its own prefix characters.

import std/strutils

const SyntaxMutation {.strdefine: "reproAddonMutation".} = ""
  ## ``unit-lines-continue-as-text`` (falsifying build): round 5's reading,
  ## a line continuing whenever its stripped text ends in a backslash.
  ## ``exec-first-command-only``: only the first command of an ``Exec*=``
  ## line is read.

const Blanks = {' ', '\t', '\n', '\r'}
  ## systemd's ``WHITESPACE``.

proc isTemplateUnit*(unit: string): bool =
  ## ``foo@.service``: a template unit name (``systemd.unit(5)``,
  ## "Description"), which ``systemctl show`` and ``start`` refuse.
  let at = unit.find('@')
  at > 0 and at + 1 < unit.len and unit[at + 1] == '.'

proc systemdRawLines*(text: string): seq[string] =
  ## ``text`` split into lines as ``read_line_full`` splits it: an end of
  ## line is a run of ``\n`` and ``\r`` in which neither repeats (``\r\n``
  ## and ``\n\r`` are one, ``\n\n`` two), or one ``\0``. A last line
  ## without an end of line is a line.
  var cur = ""
  var i = 0
  var seenAny = false
  while i < text.len:
    let c = text[i]
    seenAny = true
    if c == '\0':
      result.add(cur)
      cur = ""
      inc i
      continue
    if c in {'\n', '\r'}:
      result.add(cur)
      cur = ""
      inc i
      if i < text.len and text[i] in {'\n', '\r'} and text[i] != c:
        inc i
      continue
    cur.add(c)
    inc i
  if cur.len > 0 or (not seenAny and text.len > 0):
    result.add(cur)

proc endsInUnescapedBackslash(s: string): bool =
  ## ``config_parse``'s scan: a backslash escapes the character after it.
  var escaped = false
  for c in s:
    if escaped: escaped = false
    elif c == '\\': escaped = true
  escaped

proc systemdLogicalLines*(text: string): seq[string] =
  ## The lines ``config_parse`` hands to ``parse_line``, before it strips
  ## them: comments dropped, continuations joined.
  var continuation = ""
  var continuing = false
  var first = true
  for raw in systemdRawLines(text):
    var l = raw
    if first:
      first = false
      if l.startsWith("\xEF\xBB\xBF"): l = l[3 .. ^1]
    let lead = l.strip(trailing = false, chars = Blanks)
    if lead.len > 0 and lead[0] in {'#', ';'}:
      continue
    when SyntaxMutation == "unit-lines-continue-as-text":
      let t = l.strip(chars = Blanks)
      if continuing:
        continuation.add(" " & t)
      else:
        continuation = t
      if continuation.endsWith("\\"):
        continuation.setLen(continuation.len - 1)
        continuing = true
        continue
      result.add(continuation)
      continuation = ""
      continuing = false
    else:
      if continuing: continuation.add(l)
      else: continuation = l
      if endsInUnescapedBackslash(continuation):
        continuation[^1] = ' '
        continuing = true
        continue
      result.add(continuation)
      continuation = ""
      continuing = false
  if continuing:
    result.add(continuation)

proc cunescapeOne(s: string; i: var int; ok: var bool): string =
  ## ``cunescape_one`` for the sequence after a backslash at ``s[i]``
  ## (``i`` is left on its last character). Unknown sequences fail.
  ok = true
  let c = s[i]
  case c
  of 'a': "\a"
  of 'b': "\b"
  of 'f': "\f"
  of 'n': "\n"
  of 'r': "\r"
  of 't': "\t"
  of 'v': "\v"
  of '\\': "\\"
  of '"': "\""
  of '\'': "'"
  of 's': " "
  of 'x':
    if i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      let v = parseHexInt(s[i + 1 .. i + 2])
      i += 2
      if v == 0: ok = false
      $char(v)
    else:
      ok = false
      ""
  of 'u', 'U':
    let n = if c == 'u': 4 else: 8
    if i + n < s.len and s[i + 1 .. i + n].allCharsInSet(HexDigits):
      let v = parseHexInt(s[i + 1 .. i + n])
      i += n
      if v == 0 or v > 0x10FFFF: ok = false
      # Only the boundaries and prefixes matter to the callers; a code
      # point is kept as a placeholder character of the same width.
      if v < 0x80: $char(v) else: "?"
    else:
      ok = false
      ""
  of '0'..'7':
    if i + 2 < s.len and s[i + 1] in {'0'..'7'} and s[i + 2] in {'0'..'7'}:
      let v = (ord(c) - ord('0')) * 64 + (ord(s[i + 1]) - ord('0')) * 8 +
              (ord(s[i + 2]) - ord('0'))
      i += 2
      if v == 0 or v > 255: ok = false
      $char(v and 0xff)
    else:
      ok = false
      ""
  else:
    ok = false
    ""

proc extractWord*(s: string; p: var int; word: var string; ok: var bool): bool =
  ## ``extract_first_word(&p, &word, NULL, EXTRACT_UNQUOTE|EXTRACT_CUNESCAPE)``
  ## from position ``p``: false when no word is left; ``ok`` false when
  ## systemd would fail (an unterminated quote, a trailing backslash, an
  ## escape it does not know). Leaves ``p`` after the separators that
  ## follow the word, as systemd does.
  ok = true
  word = ""
  while p < s.len and s[p] in Blanks: inc p
  if p >= s.len: return false
  var quote = '\0'
  while p < s.len:
    let c = s[p]
    if quote != '\0':
      if c == quote:
        quote = '\0'
      elif c == '\\':
        inc p
        if p >= s.len:
          ok = false
          return true
        var e: bool
        word.add(cunescapeOne(s, p, e))
        if not e:
          ok = false
          return true
      else:
        word.add(c)
      inc p
      continue
    if c in {'"', '\''}:
      quote = c
      inc p
      continue
    if c == '\\':
      inc p
      if p >= s.len:
        ok = false
        return true
      var e: bool
      word.add(cunescapeOne(s, p, e))
      if not e:
        ok = false
        return true
      inc p
      continue
    if c in Blanks:
      while p < s.len and s[p] in Blanks: inc p
      return true
    word.add(c)
    inc p
  if quote != '\0': ok = false
  true

type ExecCommand* = object
  ## One command of an ``Exec*=`` line.
  prefix*: string        ## its prefix characters (``-@:+!``), in order
  path*: string          ## the executable, after the prefix
  args*: seq[string]     ## the words after it

proc execCommands*(value: string; ok: var bool): seq[ExecCommand] =
  ## The commands of an ``Exec*=`` value as ``config_parse_exec`` reads
  ## them. ``ok`` false when systemd would not read the line as written
  ## (a word it cannot extract), so the caller fails closed.
  ok = true
  var p = 0
  while true:
    var first: string
    var okW: bool
    if not extractWord(value, p, first, okW):
      return
    if not okW:
      ok = false
      return
    if first == ";":
      continue
    var cmd = ExecCommand()
    var i = 0
    # The prefix loop of ``config_parse_exec``: each of ``-@:`` once, then
    # ``+`` or ``!``/``!!``; ``|`` (systemd 258) is kept as a prefix too.
    while i < first.len and first[i] in {'-', '@', ':', '+', '!', '|'}:
      cmd.prefix.add(first[i])
      inc i
    cmd.path = first[i .. ^1]
    var more = false
    while p < value.len:
      if value[p] == ';' and (p + 1 >= value.len or value[p + 1] in Blanks):
        inc p
        while p < value.len and value[p] in Blanks: inc p
        more = true
        break
      if value[p] == '\\' and p + 1 < value.len and value[p + 1] == ';' and
          (p + 2 >= value.len or value[p + 2] in Blanks):
        p += 2
        while p < value.len and value[p] in Blanks: inc p
        cmd.args.add(";")
        continue
      var w: string
      if not extractWord(value, p, w, okW): break
      if not okW:
        ok = false
        return
      cmd.args.add(w)
    result.add(cmd)
    when SyntaxMutation == "exec-first-command-only":
      return
    if not more: return
