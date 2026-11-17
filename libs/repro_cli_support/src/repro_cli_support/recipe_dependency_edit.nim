## Package-dependency edits of a `repro.nim`: the text rewrites `repro add`
## and `repro remove` make to a package's dependency sections.
##
## A package names its dependencies in four sections (the DSL reference,
## "Dependencies"): `uses:`, `buildDeps:`, `nativeBuildDeps:` and
## `runtimeDeps:`. Each entry is a string literal, a package name optionally
## followed by a version constraint in the grammar
## `repro_solver/uses_constraints` reads (`"openssl >=3.3 <4.0"`).
##
## The edits are MINIMAL and DETERMINISTIC, so the diff a reviewer sees is the
## dependency and nothing else:
##
## * `addDependency` appends one entry line after the last statement of the
##   package's first section of the requested kind, at the indentation of
##   that section's entries. When the package has no such section, it inserts
##   the section header and the entry in front of the package body's first
##   statement, indented as the body is: after the package's `##` doc
##   comment, and before the plain `#` comment lines directly above that
##   statement, which document it and stay with it.
## * `removeDependency` deletes the entry lines that name the package
##   unconditionally, in every section of the package. A section left with no
##   statement loses its header too, so removing what `addDependency` added
##   restores the original bytes.
## * A section written inline (`uses: "x"`, `uses: ["x", "y"]`, a bracket
##   continued over lines) is not extended, and an entry inside a list is not
##   removed; a lone inline entry is removed with its header.
## * Every other byte is kept: line endings (per line; an inserted line takes
##   its neighbour's), comments, blank lines and the final newline (or its
##   absence). An entry already present is not written twice, and
##   one written with a different constraint is refused rather than rewritten,
##   because the constraint is the author's statement of intent.
##
## Structure is read as text, by indentation, the way
## `scanReproUsesDeclarations` reads it. Nothing is compiled or evaluated. The
## text is first LEXED the way Nim lexes it (the manual, "Lexical Analysis",
## https://nim-lang.org/docs/manual.html#lexical-analysis): a `#` starts a
## comment only outside a string or character literal, `#[ … ]#` comments
## nest and may span lines, a `"""` literal spans lines, and a literal
## prefixed by an identifier (`r"…"`, `fmt"…"`) is raw, with `""` for a quote
## and no backslash escapes. A line that begins inside a multi-line literal or
## comment belongs to the statement that opened it: it is never read as a
## statement of its own, and an entry is never inserted into it.
## An entry under a `when` / `if` / `case` arm, or written as anything but a
## string literal, is never edited: an edit there would change which
## configurations the entry applies to.
##
## The module is PURE: texts in, texts out. The caller (`repro add` /
## `repro remove` in `repro_cli_support`) reads and writes the files.

import std/[strutils]

import repro_lock
import repro_cli_support/recipe_constraints

type
  DependencyEditStatus* = enum
    desChanged      ## the text was edited
    desUnchanged    ## the entry is already there; nothing to do
    desNotFound     ## nothing to remove
    desRefused      ## an edit this module does not make (see `diagnostic`)

  DependencyHunk* = object
    ## One contiguous change, in the ORIGINAL text's line coordinates.
    at*: int                  ## 0-based index of the first affected line
    deleted*: seq[string]     ## the original lines removed (without EOL)
    inserted*: seq[string]    ## the lines inserted in their place

  DependencyEdit* = object
    status*: DependencyEditStatus
    text*: string             ## the edited text (the input unless changed)
    sections*: seq[string]    ## the sections edited (`uses`, `buildDeps`, ...)
    entry*: string            ## the entry added, or the one already there
    line*: int                ## 1-based line of the entry concerned, or 0
    hunks*: seq[DependencyHunk]
    diagnostic*: string

  DependencyRequest* = object
    ## A `repro add` argument, as the entry it becomes.
    ok*: bool
    selector*: string         ## the package name
    entry*: string            ## the literal's text: `name` or `name <range>`
    diagnostic*: string

  PackageChoice* = object
    ## Which `package` block of a `repro.nim` an edit targets.
    ok*: bool
    usage*: bool              ## a failure that is a usage error (exit 2)
    name*: string
    diagnostic*: string

  SourceLines = object
    raw: seq[string]          ## each line, with its `\r` when it had one
    trailing: bool            ## the text ends in a line terminator
    crlf: bool                ## inserted lines end in `\r\n`
    opaque: seq[bool]
      ## The line BEGINS inside a string literal or a block comment an
      ## earlier line opened: a continuation, never a statement.
    code: seq[string]
      ## The line's code, stripped: comments removed, literals kept.

  Lexer = object
    ## What is open at the end of the line lexed last.
    triple: bool              ## a `"""` literal
    commentDepth: int         ## nested `#[` block comments
    docComment: bool          ## the outermost one opened as `##[`

  PackageBlock = object
    name: string
    header: int               ## line index of `package <name>:`
    indent: int
    bodyStart: int            ## first statement of the body
    bodyIndent: int
    bodyEnd: int              ## one past the body's last line

  Entry = object
    first, last: int          ## its lines (`last` > `first` for a
                              ## multi-line comment after it)
    value: string

  Section = object
    head: string
    header: int
    indent: int
    inline: bool
      ## Not a block of one entry per line: `uses: "x"`, `uses: ["x", "y"]`
      ## and a bracket continued over several lines.
    inlineValues: seq[string] ## every string literal of an inline section
    childIndent: int          ## indentation of its statements
    lastCode: int             ## its last statement's last line (header if none)
    entries: seq[Entry]       ## its unconditional string-literal entries

const
  PackageNameChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '+'}

# ---------------------------------------------------------------------------
# Reading the text
# ---------------------------------------------------------------------------

proc bare(line: string): string =
  if line.endsWith("\r"): line[0 ..< ^1] else: line

proc lexLine(line: string; st: var Lexer): string =
  ## The code of ``line`` (comments removed, literals kept verbatim), given
  ## what earlier lines left open in ``st``, which it updates.
  var i = 0
  let n = line.len
  while i < n:
    let c = line[i]
    if st.commentDepth > 0:
      if line.continuesWith("]#", i):
        dec st.commentDepth
        i += 2
        if st.commentDepth == 0 and st.docComment and i < n and
            line[i] == '#':
          inc i                                   # `]##`
      elif line.continuesWith("#[", i):
        inc st.commentDepth
        i += 2
      else:
        inc i
    elif st.triple:
      if line.continuesWith("\"\"\"", i):
        # Three or more quotes close it; the extra ones belong to the
        # literal (the manual, "Triple quoted string literals").
        var j = i
        while j < n and line[j] == '"': inc j
        result.add(line[i ..< j])
        st.triple = false
        i = j
      else:
        result.add(c)
        inc i
    elif c == '#':
      if line.continuesWith("##[", i):
        st.commentDepth = 1
        st.docComment = true
        i += 3
      elif line.continuesWith("#[", i):
        st.commentDepth = 1
        st.docComment = false
        i += 2
      else:
        break                                     # a line comment
    elif c == '"':
      if line.continuesWith("\"\"\"", i):
        st.triple = true
        result.add("\"\"\"")
        i += 3
        continue
      let raw = i > 0 and line[i - 1] in IdentChars
      var j = i + 1
      while j < n:
        if raw and line[j] == '"' and j + 1 < n and line[j + 1] == '"':
          j += 2
        elif not raw and line[j] == '\\':
          j += 2
        elif line[j] == '"':
          inc j
          break
        else:
          inc j
      j = min(j, n)
      result.add(line[i ..< j])
      i = j
    elif c == '\'' and (i == 0 or line[i - 1] notin IdentChars):
      # A character literal (`'"'`, `'#'`, `'\''`). A `'` right after an
      # identifier character is a numeric type suffix (`1'u8`) instead.
      var j = -1
      if i + 1 < n and line[i + 1] == '\\':
        j = line.find('\'', i + 3)
      elif i + 2 < n and line[i + 2] == '\'':
        j = i + 2
      if j < 0:
        result.add(c)
        inc i
      else:
        result.add(line[i .. j])
        i = j + 1
    else:
      result.add(c)
      inc i
  result = result.strip()

proc toLines(source: string): SourceLines =
  result.raw = source.split('\n')
  if result.raw.len > 0 and result.raw[^1].len == 0 and source.len > 0:
    result.trailing = true
    result.raw.setLen(result.raw.len - 1)
  elif source.len == 0:
    result.raw = @[]
  result.crlf = "\r\n" in source
  var st: Lexer
  for line in result.raw:
    result.opaque.add(st.triple or st.commentDepth > 0)
    result.code.add(lexLine(bare(line), st))

proc join(s: SourceLines): string =
  result = s.raw.join("\n")
  if s.trailing: result.add("\n")

proc indentOf(line: string): int =
  for ch in line:
    if ch == ' ': inc result
    else: break

proc isCode(s: SourceLines; i: int): bool =
  ## Line ``i`` starts a statement.
  not s.opaque[i] and s.code[i].len > 0

proc statementEnd(s: SourceLines; i: int): int =
  ## The last line of the statement line ``i`` starts: ``i``, plus every
  ## following line that begins inside a literal or a block comment the
  ## statement left open.
  result = i
  while result + 1 < s.raw.len and s.opaque[result + 1]:
    inc result

proc literalAt(code: string; start: int): tuple[ok: bool; value: string;
    next: int] =
  ## The one-line string literal at ``code[start]`` (`"x"`, or raw `r"x"`):
  ## its value and the index after it.
  var i = start
  var raw = false
  if i < code.len and code[i] in IdentChars:
    if i + 1 < code.len and code[i + 1] == '"' and code[i] in {'r', 'R'}:
      raw = true
      inc i
    else:
      return
  if i >= code.len or code[i] != '"' or code.continuesWith("\"\"\"", i):
    return
  inc i
  var value = ""
  while i < code.len:
    let c = code[i]
    if c == '"':
      if raw and i + 1 < code.len and code[i + 1] == '"':
        value.add('"')
        i += 2
        continue
      return (true, value, i + 1)
    if c == '\\' and not raw and i + 1 < code.len:
      inc i
    value.add(code[i])
    inc i

proc literalOf(code: string): tuple[ok: bool; value: string] =
  ## ``code`` is exactly one one-line string literal (a trailing comma
  ## allowed): its value.
  let lit = literalAt(code, 0)
  if not lit.ok: return
  let rest = code[lit.next .. ^1].strip()
  if rest.len == 0 or rest == ",":
    result = (true, lit.value)

proc literalsIn(code: string): seq[string] =
  ## The values of the one-line string literals in ``code`` (a line's code,
  ## comments already removed), in order.
  var i = 0
  while i < code.len:
    if code[i] == '"' or (code[i] in {'r', 'R'} and i + 1 < code.len and
        code[i + 1] == '"' and (i == 0 or code[i - 1] notin IdentChars)):
      if code.continuesWith("\"\"\"", i):
        let close = code.find("\"\"\"", i + 3)
        if close < 0: return
        i = close + 3
        continue
      let lit = literalAt(code, i)
      if not lit.ok: return
      result.add(lit.value)
      i = lit.next
    else:
      inc i

proc normalizedEntry(value: string): string =
  value.splitWhitespace().join(" ")

proc selectorOf(value: string): string =
  let parts = value.splitWhitespace()
  if parts.len == 0: "" else: parts[0]

proc packageHeaderName(code: string): string =
  ## The name a `package <name>:` line declares (backticks removed), or "".
  if not code.startsWith("package") or not code.endsWith(":"): return ""
  let inner = code["package".len ..< ^1]
  if inner.len == 0 or inner[0] notin {' ', '\t'}: return ""
  var name = inner.strip()
  if name.len >= 2 and name[0] == '`' and name[^1] == '`':
    name = name[1 ..< ^1]
  if name.len == 0: return ""
  for ch in name:
    if ch notin PackageNameChars: return ""
  name

proc packageBlocks(s: SourceLines): seq[PackageBlock] =
  for i in 0 ..< s.raw.len:
    if not s.isCode(i): continue
    let name = packageHeaderName(s.code[i])
    if name.len == 0: continue
    var b = PackageBlock(name: name, header: i, indent: indentOf(s.raw[i]),
      bodyStart: -1, bodyIndent: -1, bodyEnd: s.raw.len)
    for j in i + 1 ..< s.raw.len:
      if not s.isCode(j): continue
      let ind = indentOf(s.raw[j])
      if ind <= b.indent:
        b.bodyEnd = j
        break
      if b.bodyStart < 0:
        b.bodyStart = j
        b.bodyIndent = ind
    result.add(b)

proc sectionsOf(s: SourceLines; b: PackageBlock): seq[Section] =
  if b.bodyStart < 0: return
  for i in b.bodyStart ..< b.bodyEnd:
    if not s.isCode(i) or indentOf(s.raw[i]) != b.bodyIndent: continue
    let code = s.code[i]
    var head = ""
    for h in ReproDependencyBlockHeads:
      if code.startsWith(h) and code[h.len .. ^1].strip().startsWith(":"):
        head = h
    if head.len == 0: continue
    var sec = Section(head: head, header: i, indent: b.bodyIndent,
      childIndent: -1, lastCode: s.statementEnd(i))
    let after = code[code.find(':') + 1 .. ^1].strip()
    if after.len > 0:
      # Not a block: the statement runs on over every deeper line (a
      # bracket continued onto the next lines).
      sec.inline = true
      sec.inlineValues = literalsIn(after)
      for j in sec.lastCode + 1 ..< b.bodyEnd:
        if not s.isCode(j): continue
        if indentOf(s.raw[j]) <= sec.indent: break
        sec.inlineValues.add(literalsIn(s.code[j]))
        sec.lastCode = s.statementEnd(j)
      result.add(sec)
      continue
    for j in i + 1 ..< b.bodyEnd:
      if not s.isCode(j): continue
      let ind = indentOf(s.raw[j])
      if ind <= sec.indent: break
      if sec.childIndent < 0: sec.childIndent = ind
      sec.lastCode = s.statementEnd(j)
      if ind != sec.childIndent: continue
      let lit = literalOf(s.code[j])
      if lit.ok:
        sec.entries.add(Entry(first: j, last: sec.lastCode, value: lit.value))
    result.add(sec)

proc parseDependencyRequest*(arg: string): DependencyRequest =
  ## ``arg`` as the `uses:` entry it becomes. Accepts the entry as `uses:`
  ## writes it (`openssl`, `openssl >=3.3 <4.0`) and `name@<constraint>`
  ## (`openssl@>=3.3 <4.0`, `openssl@3.3.1`), which is the same entry with
  ## `@` for the space. Refuses what an entry cannot express: an empty
  ## name, a name with characters a package name does not have, `@` with
  ## nothing after it, `@latest` (an entry states a constraint, not a
  ## resolution), a quote or backslash, and a constraint the version grammar
  ## does not read.
  let text = arg.strip()
  if text.len == 0:
    result.diagnostic = "no package was named"
    return
  var name, constraint: string
  let at = text.find('@')
  if at >= 0:
    name = text[0 ..< at].strip()
    constraint = text[at + 1 .. ^1].strip()
    if constraint.len == 0:
      result.diagnostic = "'" & text & "' names no constraint after `@`; " &
        "write the package alone to add it unconstrained"
      return
    if constraint == "latest":
      result.diagnostic = "'" & text & "': a `uses:` entry states a " &
        "version constraint, not a resolution; write the package alone " &
        "and let the lock resolve it"
      return
  else:
    let parts = text.splitWhitespace()
    name = parts[0]
    constraint = text[text.find(parts[0]) + parts[0].len .. ^1].strip()
  if name.len == 0:
    result.diagnostic = "'" & text & "' names no package"
    return
  if name[0] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    result.diagnostic = "'" & name & "' is not a package name (it must " &
      "start with a letter, a digit or `_`)"
    return
  for ch in name:
    if ch notin PackageNameChars:
      result.diagnostic = "'" & name & "' is not a package name (`" & $ch &
        "` is not allowed in one)"
      return
  for ch in constraint:
    if ch in {'"', '\\'} or ch < ' ':
      result.diagnostic = "the constraint '" & constraint & "' contains a " &
        "character a `uses:` entry cannot carry"
      return
  result.selector = name
  result.entry =
    if constraint.len == 0: name
    else: name & " " & normalizedEntry(constraint)
  let parsed = parseReproUsesConstraint(result.entry)
  if parsed.kind == uckUnparseable:
    result.diagnostic = "the constraint '" & constraint & "' is not a " &
      "version constraint `uses:` reads: " & parsed.diagnostic
    return
  result.ok = true

proc packageNamesOf*(source: string): seq[string] =
  ## The names of the `package` blocks of a `repro.nim`, in order.
  for b in packageBlocks(toLines(source)):
    result.add(b.name)

proc choosePackage*(source, requested, path: string): PackageChoice =
  ## The package an edit targets: ``requested`` (`--package`) when given and
  ## declared; otherwise the file's only package. A file declaring several
  ## packages requires ``requested`` (a usage error without it).
  let names = packageNamesOf(source)
  if requested.len > 0:
    if requested in names:
      return PackageChoice(ok: true, name: requested)
    return PackageChoice(diagnostic: path & " declares no package '" &
      requested & "'" & (if names.len > 0: " (it declares: " &
        names.join(", ") & ")" else: ""))
  case names.len
  of 0:
    PackageChoice(diagnostic: path & " declares no `package` block to " &
      "edit")
  of 1:
    PackageChoice(ok: true, name: names[0])
  else:
    PackageChoice(usage: true, diagnostic: path & " declares " &
      $names.len & " packages (" & names.join(", ") & "); name the one " &
      "to edit with --package=<name>")

proc blockNamed(s: SourceLines; name: string): tuple[ok: bool;
    b: PackageBlock] =
  for b in packageBlocks(s):
    if b.name == name: return (true, b)

# ---------------------------------------------------------------------------
# The edits
# ---------------------------------------------------------------------------

proc eolNear(s: SourceLines; at: int): string =
  ## The `\r` (or nothing) a line inserted at index ``at`` ends with: the line
  ## ending of the terminated line before it, else of the one after it, else
  ## the file's.
  let prev = at - 1
  if prev >= 0 and (prev < s.raw.len - 1 or s.trailing):
    return (if s.raw[prev].endsWith("\r"): "\r" else: "")
  if at < s.raw.len and (at < s.raw.len - 1 or s.trailing):
    return (if s.raw[at].endsWith("\r"): "\r" else: "")
  if s.crlf: "\r" else: ""

proc literalLine(indent: int; entry: string): string =
  repeat(' ', max(indent, 0)) & "\"" & entry & "\""

proc nestingStep(b: PackageBlock; sections: seq[Section]): int =
  ## The step one level of nesting takes in this file: an existing block
  ## section's, else the package body's own.
  result = b.bodyIndent - b.indent
  for sec in sections:
    if not sec.inline and sec.childIndent > sec.indent:
      result = sec.childIndent - sec.indent
      break
  if result <= 0: result = 2

proc sectionInsertionPoint(s: SourceLines; b: PackageBlock): int =
  ## Where a new section goes: in front of the body's first statement and of
  ## the plain `#` comments directly above it, which document that statement
  ## and stay with it; but after a `##` doc comment, which documents the
  ## package, and after a blank line that separates a comment from the
  ## statement.
  result = b.bodyStart
  var k = b.bodyStart - 1
  while k > b.header:
    var opener = k
    while opener > b.header and s.opaque[opener]: dec opener
    let text = bare(s.raw[opener]).strip()
    if opener <= b.header or s.code[opener].len > 0 or
        not text.startsWith("#") or text.startsWith("##"):
      break
    result = opener
    k = opener - 1

proc inlineRefusal(sec: Section; package, verb: string): string =
  "`" & sec.head & ":` of package '" & package & "' (line " &
    $(sec.header + 1) & ") is written inline, not as a block with one " &
    "entry per line; rewrite it as a block to " & verb & " it"

proc insertLines(s: var SourceLines; at: int; lines: seq[string]) =
  ## Insert ``lines`` (without EOL) in front of line index ``at``.
  let eol = s.eolNear(at)
  var inserted: seq[string]
  for line in lines: inserted.add(line & eol)
  if at == s.raw.len and not s.trailing and s.raw.len > 0:
    # Appending after an unterminated last line: that line gets the
    # terminator and the new last line goes without one, as the file did.
    s.raw[^1].add(eol)
    inserted[^1] = lines[^1]
  var next = s.raw[0 ..< at]
  next.add(inserted)
  next.add(s.raw[at .. ^1])
  s.raw = next

proc addDependency*(source, package, section, entry: string): DependencyEdit =
  ## Add ``entry`` (a `DependencyRequest.entry`) to section ``section``
  ## (`uses`, `buildDeps`, `nativeBuildDeps`, `runtimeDeps`) of package
  ## ``package``. See the module documentation for where it goes.
  result.text = source
  result.entry = entry
  result.sections = @[section]
  if section notin ReproDependencyBlockHeads:
    result.status = desRefused
    result.diagnostic = "'" & section & "' is not a dependency section"
    return
  var s = toLines(source)
  let found = blockNamed(s, package)
  if not found.ok:
    result.status = desRefused
    result.diagnostic = "no package '" & package & "'"
    return
  let b = found.b
  if b.bodyStart < 0:
    result.status = desRefused
    result.diagnostic = "package '" & package & "' (line " & $(b.header + 1) &
      ") has no body to add a section to"
    return
  let selector = selectorOf(entry)
  let sections = sectionsOf(s, b)
  var target = -1
  for k, sec in sections:
    if sec.head != section: continue
    if target < 0: target = k
    var present: seq[tuple[line: int; value: string]]
    for e in sec.entries: present.add((e.first, e.value))
    for v in sec.inlineValues: present.add((sec.header, v))
    for (line, value) in present:
      if selectorOf(value) != selector: continue
      result.line = line + 1
      if normalizedEntry(value) == normalizedEntry(entry) or
          normalizedEntry(entry) == selector:
        result.status = desUnchanged
        result.entry = value
        result.diagnostic = "'" & selector & "' is already in `" & section &
          ":` of package '" & package & "' (line " & $(line + 1) & ": \"" &
          value & "\")"
      else:
        result.status = desRefused
        result.entry = value
        result.diagnostic = "'" & selector & "' is already in `" & section &
          ":` of package '" & package & "' with another constraint (line " &
          $(line + 1) & ": \"" & value & "\"); edit that entry, or remove " &
          "it first with `repro remove " & selector & "`"
      return
  var hunk: DependencyHunk
  if target >= 0:
    let sec = sections[target]
    if sec.inline:
      result.status = desRefused
      result.line = sec.header + 1
      result.diagnostic = inlineRefusal(sec, package, "add to")
      return
    let indent =
      if sec.childIndent > sec.indent: sec.childIndent
      else: sec.indent + nestingStep(b, sections)
    hunk.at = sec.lastCode + 1
    hunk.inserted = @[literalLine(indent, entry)]
  else:
    hunk.at = sectionInsertionPoint(s, b)
    hunk.inserted = @[repeat(' ', b.bodyIndent) & section & ":",
      literalLine(b.bodyIndent + nestingStep(b, sections), entry)]
  s.insertLines(hunk.at, hunk.inserted)
  result.hunks = @[hunk]
  result.line = hunk.at + hunk.inserted.len
  result.text = join(s)
  result.status = desChanged

proc conditionalLiteral(code: string): tuple[ok: bool; value: string] =
  ## ``code`` is one string literal, or an arm written with its entry on the
  ## same line (`else: "x"`, `of "a": "x"`, `when c: "x"`): that literal.
  result = literalOf(code)
  if result.ok: return
  for kw in ["when ", "if ", "elif ", "else", "of "]:
    if code.startsWith(kw):
      let colon = code.rfind(':')
      if colon > 0:
        result = literalOf(code[colon + 1 .. ^1].strip())
      return

proc removeDependency*(source, package, selector: string): DependencyEdit =
  ## Remove every unconditional entry naming ``selector`` from the
  ## dependency sections of package ``package``. See the module
  ## documentation.
  result.text = source
  var s = toLines(source)
  let found = blockNamed(s, package)
  if not found.ok:
    result.status = desRefused
    result.diagnostic = "no package '" & package & "'"
    return
  let b = found.b
  var drop = newSeq[bool](s.raw.len)
  for sec in sectionsOf(s, b):
    if sec.inline:
      var named = false
      for v in sec.inlineValues:
        if selectorOf(v) == selector: named = true
      if not named: continue
      let single = literalOf(s.code[sec.header][
        s.code[sec.header].find(':') + 1 .. ^1].strip())
      if sec.lastCode != s.statementEnd(sec.header) or not single.ok:
        # A list on one line, or a bracket over several: removing the one
        # element is an edit of an expression, which this module does not
        # make, and removing the other entries would be worse.
        result = DependencyEdit(status: desRefused, text: source,
          line: sec.header + 1, diagnostic: "'" & selector & "' is " &
            "declared in " & inlineRefusal(sec, package, "remove it from"))
        return
      for j in sec.header .. sec.lastCode: drop[j] = true
      result.sections.add(sec.head)
      if result.entry.len == 0: result.entry = single.value
      if result.line == 0: result.line = sec.header + 1
      continue
    var hit = false
    for e in sec.entries:
      if selectorOf(e.value) == selector:
        for j in e.first .. e.last: drop[j] = true
        hit = true
        if result.entry.len == 0: result.entry = e.value
        if result.line == 0: result.line = e.first + 1
    if not hit: continue
    result.sections.add(sec.head)
    # A section left with no statement goes, header and all, with the
    # comments between its header and its last statement; the lines after
    # that (a blank separator, a trailing comment) stay.
    var remaining = false
    for j in sec.header + 1 .. sec.lastCode:
      if s.isCode(j) and not drop[j]:
        remaining = true
        break
    if not remaining:
      for j in sec.header .. sec.lastCode: drop[j] = true
  if result.sections.len == 0:
    # Not an unconditional entry anywhere: say where it IS, if anywhere in
    # the package (under a `when` / `if` / `case` arm, or in a nested call).
    var nestedAt: seq[string]
    if b.bodyStart >= 0:
      for i in b.bodyStart ..< b.bodyEnd:
        if not s.isCode(i): continue
        let lit = conditionalLiteral(s.code[i])
        if lit.ok and selectorOf(lit.value) == selector:
          nestedAt.add($(i + 1))
    if nestedAt.len > 0:
      result.status = desRefused
      result.line = parseInt(nestedAt[0])
      result.diagnostic = "'" & selector & "' is declared in package '" &
        package & "' only under a condition or a nested call (line " &
        nestedAt.join(", ") & "); edit it there by hand"
    else:
      result.status = desNotFound
      result.diagnostic = "'" & selector & "' is not a dependency of " &
        "package '" & package & "'"
    return
  var kept: seq[string]
  var i = 0
  while i < s.raw.len:
    if drop[i]:
      var hunk = DependencyHunk(at: i)
      while i < s.raw.len and drop[i]:
        hunk.deleted.add(bare(s.raw[i]))
        inc i
      result.hunks.add(hunk)
    else:
      kept.add(s.raw[i])
      inc i
  if drop[^1] and not s.trailing and kept.len > 0:
    # The unterminated last line went: the new last line goes without the
    # terminator it had, as `insertLines` gave it one (the round trip).
    kept[^1] = bare(kept[^1])
  s.raw = kept
  result.text = join(s)
  result.status = desChanged

# ---------------------------------------------------------------------------
# The lock
# ---------------------------------------------------------------------------

type
  LockAgreement* = enum
    laUnreadable    ## the lock does not parse; nothing was compared
    laConsistent    ## it resolves every entry compared, within its range
    laStale         ## it does not reflect the recipe (`missing`, `outside`)
    laUndecided
      ## a removed package it still resolves: whether something else still
      ## requires it is a question only a solve answers

  LockComparison* = object
    ## What `repro.lock` records, compared with the unconditional entries of
    ## the dependency sections an edit touched. Offline: the lock's
    ## `packages` (the solve's output: name, version, selection) against the
    ## recipe text, by package name, the way the recipe/lock consistency
    ## check (H1) relates a `uses:` entry to its resolution.
    agreement*: LockAgreement
    compared*: int            ## the entries compared
    missing*: seq[string]     ## entries the lock resolves no package for
    outside*: seq[string]
      ## `"<entry>" (locked <version>)`: a resolution the range excludes
    stillLocked*: seq[string]
      ## `<name> <version>`: removed, no longer declared unconditionally in
      ## the package, and still resolved by the lock
    notCompared*: seq[string]
      ## `"<entry>" (locked <version>)`: a version the range grammar cannot
      ## compare
    diagnostic*: string       ## why the lock could not be read

proc sectionEntryValues(s: SourceLines; b: PackageBlock;
                        sections: openArray[string]): seq[string] =
  for sec in sectionsOf(s, b):
    if sections.len > 0 and sec.head notin sections: continue
    for e in sec.entries: result.add(e.value)
    for v in sec.inlineValues: result.add(v)

proc compareWithLock*(recipe, package: string; sections: openArray[string];
                      lockText: string;
                      removed: openArray[string] = []): LockComparison =
  ## Compare ``lockText`` (a `repro.lock`) with the unconditional entries of
  ## sections ``sections`` of package ``package`` in ``recipe`` (the edited
  ## text), and with the packages ``removed`` from it. Pure.
  ##
  ## * An entry whose name the lock resolves no (selected) package for is
  ##   `missing`; one whose resolved version its range does not admit is
  ##   `outside`. Either makes the lock `laStale`.
  ## * A removed package that no section of the package still names, and
  ##   that the lock still resolves, is `stillLocked` and the verdict
  ##   `laUndecided`: the lock records no dependency edges (`LockedPackage`),
  ##   so whether another dependency still requires it is not in the lock.
  ## * Entries under a `when` / `if` / `case` arm are not compared.
  var ld: LockedDependencies
  try:
    ld = parseLockedDependencies(lockText)
  except CatchableError as err:
    result.agreement = laUnreadable
    result.diagnostic = err.msg
    return
  var versions: seq[tuple[name, version: string]]
  for p in ld.packages:
    if p.selection != ssUnselected: versions.add((p.name, p.version))
  proc lockedVersions(name: string): seq[string] =
    for (n, v) in versions:
      if n == name: result.add(v)
  let s = toLines(recipe)
  let found = blockNamed(s, package)
  var still: seq[string]
  if found.ok:
    for value in sectionEntryValues(s, found.b, sections):
      inc result.compared
      let c = parseReproUsesConstraint(value)
      let locked = lockedVersions(c.selector)
      if locked.len == 0:
        result.missing.add(c.selector)
        continue
      if c.kind notin {uckRange, uckExact}: continue
      var admitted, undecidable = false
      for v in locked:
        if c.admits(v): admitted = true
        elif not isComparableVersion(v): undecidable = true
      if admitted: continue
      let note = "\"" & value & "\" (locked " & locked.join(", ") & ")"
      if undecidable: result.notCompared.add(note)
      else: result.outside.add(note)
    for value in sectionEntryValues(s, found.b, []):
      still.add(selectorOf(value))
  for name in removed:
    if name in still: continue
    let locked = lockedVersions(name)
    if locked.len > 0:
      result.stillLocked.add(name & " " & locked.join(", "))
  result.agreement =
    if result.missing.len > 0 or result.outside.len > 0: laStale
    elif result.stillLocked.len > 0: laUndecided
    else: laConsistent

proc renderDependencyDiff*(path, before: string;
                           hunks: openArray[DependencyHunk]): string =
  ## A unified diff (three lines of context) of ``hunks`` against
  ## ``before``, the text they were computed from, labelled ``path``.
  let s = toLines(before)
  result = "--- " & path & "\n+++ " & path & "\n"
  var offset = 0
  for h in hunks:
    let first = max(0, h.at - 3)
    let tail = h.at + h.deleted.len
    let last = min(s.raw.len, tail + 3)
    let oldCount = last - first
    let newCount = oldCount - h.deleted.len + h.inserted.len
    result.add("@@ -" & $(first + 1) & "," & $oldCount & " +" &
      $(first + 1 + offset) & "," & $newCount & " @@\n")
    for j in first ..< h.at: result.add(" " & bare(s.raw[j]) & "\n")
    for line in h.deleted: result.add("-" & line & "\n")
    for line in h.inserted: result.add("+" & line & "\n")
    for j in tail ..< last: result.add(" " & bare(s.raw[j]) & "\n")
    offset += h.inserted.len - h.deleted.len
