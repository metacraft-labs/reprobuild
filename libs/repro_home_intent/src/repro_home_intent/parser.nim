## Parser/validator for the narrow `home.nim` shape recognized by the
## intent layer.
##
## The parser is intentionally NOT a general Nim parser. It walks the
## source line by line, recognizing exactly the four top-level
## `profile` body forms (`activity`, `config`, `hosts`, and conditional
## blocks inside activities) plus their nested grammar. Any other Nim
## construct — `import`, `proc`, `var`, `for`, `let`, `case`, `=`
## bindings at top level — is rejected with `EUnstructured` carrying a
## precise file:line:col and a "saw / expected" pair.
##
## Comments and blank lines may appear anywhere; the parser records
## them in the surrounding line range so the editor can preserve them.
##
## The intent of refusing to handle general Nim is documented in the
## spec:
##
##   rejects files where the recognized patterns are obscured by user
##   code (e.g. a `for` loop building an activity body at runtime); in
##   that case fails closed with `EUnstructured` pointing at the manual
##   edit.

import std/strutils

import ./errors
import ./model
import ./predicate

const
  ProfileHeader = "profile"
  ActivityHeader = "activity"
  ConfigHeader = "config"
  HostsHeader = "hosts"
  WhenHeader = "when"
  IfHeader = "if"

type
  ParseCtx = object
    profilePath: string
    lines: seq[string]
    indentStep: int

proc lineEnding(src: string): string =
  if src.find("\r\n") >= 0: "\r\n" else: "\n"

proc splitKeepEmpty(src, ending: string): seq[string] =
  ## Split on `ending` while preserving every line — including a
  ## trailing empty line if the source ended with the separator (we
  ## strip that one back out so `len` reflects logical line count).
  result = src.split(ending)
  if result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc countLeadingSpaces(s: string): int =
  result = 0
  while result < s.len and s[result] == ' ':
    inc result

proc isBlankOrComment(s: string): bool =
  let t = s.strip()
  t.len == 0 or t.startsWith("#")

proc stripInlineComment(s: string): string =
  ## Return `s` with any `#`-comment chopped off. The intent profile
  ## doesn't contain string literals on a line where the `#`-comment
  ## handling would be ambiguous, except for host names and config
  ## values; we handle those explicitly elsewhere by scanning the
  ## right-hand side, so this helper is only used for header-style
  ## lines (`profile`, `activity`, `when`, `if`, `config`, `hosts`).
  let idx = s.find('#')
  if idx < 0: s
  else: s[0 ..< idx]

proc trimTrailing(s: string): string =
  ## Strip trailing CR (defensive — `splitKeepEmpty` already separates
  ## on the chosen line ending, but a stray CR may still appear when a
  ## file mixes endings).
  result = s
  while result.len > 0 and result[^1] in {' ', '\t', '\r'}:
    result.setLen(result.len - 1)

# ---------------------------------------------------------------------------
# Header recognizers.
# ---------------------------------------------------------------------------

type
  HeaderMatch = object
    matched: bool
    keyword: string
    rest: string          ## everything between the keyword and the trailing `:`
    indent: int

proc matchHeader(line: string; expectedKeyword: string): HeaderMatch =
  ## Match `<indent><keyword><rest>:` where `<rest>` may be empty,
  ## a quoted name, a list of identifiers, etc. The trailing `:` is
  ## required.
  let trimmed = stripInlineComment(line).trimTrailing()
  let indent = countLeadingSpaces(trimmed)
  let body = trimmed[indent .. ^1]
  if not body.endsWith(":"):
    return HeaderMatch(matched: false)
  let inner = body[0 ..< body.len - 1]
  if inner == expectedKeyword:
    return HeaderMatch(matched: true, keyword: expectedKeyword,
      rest: "", indent: indent)
  if inner.startsWith(expectedKeyword) and inner.len > expectedKeyword.len and
     inner[expectedKeyword.len] in {' ', '\t'}:
    return HeaderMatch(matched: true, keyword: expectedKeyword,
      rest: inner[expectedKeyword.len + 1 .. ^1].strip(), indent: indent)
  HeaderMatch(matched: false)

proc matchAnyHeader(line: string): tuple[ok: bool; keyword, rest: string;
                                         indent: int] =
  ## Try each known header in turn. Returns the first match (longest-
  ## match-first is unnecessary because the keywords are all unique
  ## prefixes of distinct identifiers).
  for kw in [ProfileHeader, ActivityHeader, WhenHeader, IfHeader,
             ConfigHeader, HostsHeader]:
    let m = matchHeader(line, kw)
    if m.matched:
      return (true, m.keyword, m.rest, m.indent)
  (false, "", "", 0)

# ---------------------------------------------------------------------------
# Indent detection.
# ---------------------------------------------------------------------------

proc detectIndentStep(lines: seq[string]; profileHeaderLine: int): int =
  ## Detect indent width by looking at the first non-blank, non-comment
  ## line strictly indented more than the `profile` header. Falls back
  ## to 2 if nothing is more deeply indented.
  let baseIndent = countLeadingSpaces(lines[profileHeaderLine - 1])
  for i in profileHeaderLine .. lines.high:
    let s = lines[i]
    if isBlankOrComment(s): continue
    let ind = countLeadingSpaces(s)
    if ind > baseIndent:
      return ind - baseIndent
  2

# ---------------------------------------------------------------------------
# Top-level scan.
# ---------------------------------------------------------------------------

proc validateNonProfileTopLevel(ctx: ParseCtx; idx: int) =
  ## Lines before the `profile` header must be `import`, `from`,
  ## `include`, or blank/comment. Anything else is treated as
  ## structured-edit-hostile user code.
  let line = ctx.lines[idx]
  if isBlankOrComment(line): return
  let stripped = line.strip()
  if stripped.startsWith("import ") or stripped == "import" or
     stripped.startsWith("from ") or stripped.startsWith("include "):
    return
  raiseUnstructured(ctx.profilePath, idx + 1,
    countLeadingSpaces(line) + 1,
    "'" & stripped & "'",
    "an `import` statement or a `profile <name>:` block header")

proc findProfileHeader(ctx: ParseCtx): int =
  ## Locate the unique `profile <name>:` header. Returns 1-based line
  ## number. Raises `EUnstructured` if absent or if there are multiple.
  var found = -1
  for i, line in ctx.lines:
    let m = matchHeader(line, ProfileHeader)
    if m.matched:
      if found >= 0:
        raiseUnstructured(ctx.profilePath, i + 1, m.indent + 1,
          "a second `profile " & m.rest & ":` header",
          "exactly one `profile <name>:` block per file")
      found = i
    else:
      if found < 0:
        validateNonProfileTopLevel(ctx, i)
  if found < 0:
    raiseUnstructured(ctx.profilePath, 1, 1,
      "no `profile <name>:` header",
      "a top-level `profile <name>:` block")
  result = found + 1

# ---------------------------------------------------------------------------
# Block-range helpers.
# ---------------------------------------------------------------------------

proc nextStructuralLine(lines: seq[string]; start: int): int =
  ## Index (0-based) of the next non-blank, non-comment line at or
  ## after `start`. Returns -1 if none.
  for i in start .. lines.high:
    if not isBlankOrComment(lines[i]):
      return i
  -1

proc isStructuralChild(line: string; childIndent: int): bool =
  ## A line counts as a child of an indented block if it is blank,
  ## a comment, or content at column `childIndent` or deeper.
  if isBlankOrComment(line): return true
  countLeadingSpaces(line) >= childIndent

proc lastStructuralIdx(lines: seq[string]; startIdx, childIndent: int): int =
  ## 0-based index of the last line still inside the block whose body
  ## starts at `startIdx` and whose minimum content indent is
  ## `childIndent`. Returns `startIdx - 1` if there is no body
  ## (immediate dedent).
  var endIdx = startIdx - 1
  for i in startIdx .. lines.high:
    if isBlankOrComment(lines[i]):
      endIdx = i
      continue
    if countLeadingSpaces(lines[i]) < childIndent:
      break
    endIdx = i
  # Trim trailing blank/comment-only lines belonging to the parent.
  # We keep them attached when they sit between two children at the
  # same indent (so comments survive); we shed them only at the very
  # end of the block to avoid stealing the next block's leading
  # whitespace.
  while endIdx >= startIdx and isBlankOrComment(lines[endIdx]):
    dec endIdx
  endIdx

# ---------------------------------------------------------------------------
# Activity body parsing.
# ---------------------------------------------------------------------------

const
  ## Nim control-flow keywords that we explicitly refuse to confuse
  ## with bare package references. If any of these appear as the
  ## leading identifier of a line where a package reference is
  ## expected, we raise `EUnstructured` rather than silently parsing
  ## the line as a package named `for`, `while`, etc.
  NimControlFlowKeywords = ["for", "while", "case", "let", "var",
    "const", "proc", "func", "method", "iterator", "template",
    "macro", "type", "import", "from", "include", "discard", "return",
    "yield", "break", "continue", "try", "except", "finally",
    "static", "block", "asm", "defer", "echo"]

proc parsePackageRefLine(ctx: ParseCtx; idx: int): IntentNode =
  ## Parse a bare package-reference line. The spec allows
  ## `--version-pin` style attributes; we treat the whole post-name
  ## tail as an opaque string we'll preserve byte-for-byte. Comments
  ## are ignored (they hang off the line).
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let indent = countLeadingSpaces(trimmed)
  let body = trimmed[indent .. ^1]
  if body.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "an empty line treated as a package reference",
      "a bare package identifier (e.g. `git`)")
  # The package name is the first identifier token; the rest may be
  # whitespace + flag-style attributes which we accept and preserve.
  var i = 0
  while i < body.len and (body[i].isAlphaAscii() or body[i].isDigit() or
                          body[i] in {'_', '-'}):
    inc i
  let pkgName = body[0 ..< i]
  if pkgName.len == 0 or not (body[0].isAlphaAscii() or body[0] == '_'):
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & body & "'",
      "a bare package reference starting with a letter or underscore")
  # Refuse Nim control-flow keywords — the spec explicitly calls out
  # `for` loops building an activity body at runtime as the canonical
  # unstructured case.
  if pkgName in NimControlFlowKeywords:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "Nim `" & pkgName & "` keyword used to build an activity body",
      "a bare package reference (`for` / `while` / etc. are not allowed)")
  # The package reference may NOT be a Nim assignment or call expression.
  # Reject `=`, `(`, and similar.
  let rest = body[i .. ^1].strip()
  if rest.len > 0 and (rest[0] == '=' or rest[0] == '(' or rest[0] == ','):
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & body & "'",
      "a bare package reference (no `=`, `(`, or `,`)")
  result = IntentNode(kind: nkPackageRef,
    startLine: idx + 1, endLine: idx + 1, indent: indent,
    packageName: pkgName, packageLine: idx + 1)

proc parseConditional(ctx: ParseCtx; startIdx: int; indent: int;
                     keyword: CondKeyword;
                     childIndent: int): IntentNode

proc parseActivityChildren(ctx: ParseCtx; startIdx, endIdxExclusive,
                           childIndent: int): seq[IntentNode] =
  ## Parse lines [startIdx, endIdxExclusive) as children of an
  ## activity body. Children are package references OR conditional
  ## blocks.
  var i = startIdx
  while i < endIdxExclusive:
    let raw = ctx.lines[i]
    if isBlankOrComment(raw):
      inc i; continue
    let lineIndent = countLeadingSpaces(raw)
    if lineIndent != childIndent:
      raiseUnstructured(ctx.profilePath, i + 1, lineIndent + 1,
        "'" & raw.strip() & "' at indent " & $lineIndent,
        "content at indent " & $childIndent)
    let m = matchAnyHeader(raw)
    if m.ok and m.keyword == WhenHeader:
      let blk = parseConditional(ctx, i, childIndent, ckWhen,
        childIndent + ctx.indentStep)
      result.add blk
      # `blk.endLine` is 1-based and equals the 0-based index of the
      # next line to process (the conditional body's last line is at
      # 0-based index `blk.endLine - 1`).
      i = blk.endLine
    elif m.ok and m.keyword == IfHeader:
      let blk = parseConditional(ctx, i, childIndent, ckIf,
        childIndent + ctx.indentStep)
      result.add blk
      i = blk.endLine
    elif m.ok:
      raiseUnstructured(ctx.profilePath, i + 1, lineIndent + 1,
        "`" & m.keyword & "` block",
        "a package reference, `when <pred>:`, or `if <pred>:`")
    else:
      result.add parsePackageRefLine(ctx, i)
      inc i

proc parseConditional(ctx: ParseCtx; startIdx: int; indent: int;
                     keyword: CondKeyword;
                     childIndent: int): IntentNode =
  let raw = ctx.lines[startIdx]
  let m = matchHeader(raw, if keyword == ckWhen: WhenHeader else: IfHeader)
  if not m.matched:
    raiseUnstructured(ctx.profilePath, startIdx + 1, indent + 1,
      "'" & raw.strip() & "'",
      "a `when <pred>:` or `if <pred>:` header")
  if m.rest.len == 0:
    raiseUnstructured(ctx.profilePath, startIdx + 1, indent + 1,
      "an empty predicate",
      "a predicate expression after `" & m.keyword & "`")
  let predAst = parsePredicate(ctx.profilePath, m.rest, startIdx + 1)
  let canon = renderPredicate(normalizeAst(predAst))
  let endIdx = lastStructuralIdx(ctx.lines, startIdx + 1, childIndent)
  let bodyChildren =
    if endIdx >= startIdx + 1:
      parseActivityChildren(ctx, startIdx + 1, endIdx + 1, childIndent)
    else:
      @[]
  result = IntentNode(kind: nkCondBlock,
    startLine: startIdx + 1, endLine: max(endIdx + 1, startIdx + 1),
    indent: indent, keyword: keyword,
    predicateSource: m.rest, predicateAst: predAst,
    canonicalPredicate: canon, condHeaderLine: startIdx + 1,
    condChildren: bodyChildren)

# ---------------------------------------------------------------------------
# Top-level block parsers.
# ---------------------------------------------------------------------------

proc parseActivity(ctx: ParseCtx; idx, parentIndent,
                   childIndent: int): IntentNode =
  let raw = ctx.lines[idx]
  let m = matchHeader(raw, ActivityHeader)
  if not m.matched:
    raiseUnstructured(ctx.profilePath, idx + 1, parentIndent + 1,
      "'" & raw.strip() & "'",
      "an `activity <name>:` header")
  if m.rest.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, parentIndent + 1,
      "an empty activity name",
      "an identifier after `activity`")
  # The name must be a single Nim identifier.
  for c in m.rest:
    if not (c.isAlphaAscii() or c.isDigit() or c == '_'):
      raiseUnstructured(ctx.profilePath, idx + 1, parentIndent + 1,
        "'" & m.rest & "' as the activity name",
        "a single identifier")
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, childIndent)
  let bodyChildren =
    if endIdx >= idx + 1:
      parseActivityChildren(ctx, idx + 1, endIdx + 1, childIndent)
    else:
      @[]
  result = IntentNode(kind: nkActivity,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, activityName: m.rest,
    activityHeaderLine: idx + 1, activityChildren: bodyChildren)

proc parseConfigEntry(ctx: ParseCtx; idx: int; entryIndent: int): IntentNode =
  let raw = ctx.lines[idx]
  let trimmed = trimTrailing(raw)
  # Find `=` outside of any quoted segment. Simpler: a config-entry
  # line is always `<key> = <value>` with the LHS being an identifier;
  # so the first `=` after the leading identifier is the assignment.
  let indent = countLeadingSpaces(trimmed)
  var i = indent
  while i < trimmed.len and (trimmed[i].isAlphaAscii() or
                             trimmed[i].isDigit() or trimmed[i] == '_'):
    inc i
  let key = trimmed[indent ..< i]
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  if i >= trimmed.len or trimmed[i] != '=':
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & trimmed[indent .. ^1] & "'",
      "a `<key> = <value>` configurable assignment")
  inc i
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  let rhs = trimmed[i .. ^1]
  if rhs.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, i + 1,
      "missing value", "a value expression after `=`")
  result = IntentNode(kind: nkConfigEntry,
    startLine: idx + 1, endLine: idx + 1, indent: entryIndent,
    configKey: key, configValueSource: rhs, configEntryLine: idx + 1)

proc parseConfigPackage(ctx: ParseCtx; idx, pkgIndent,
                        entryIndent: int): IntentNode =
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let body = trimmed[pkgIndent .. ^1]
  if not body.endsWith(":"):
    raiseUnstructured(ctx.profilePath, idx + 1, pkgIndent + 1,
      "'" & body & "'",
      "a `<package>:` header inside `config:`")
  let pkgName = body[0 ..< body.len - 1].strip()
  for c in pkgName:
    if not (c.isAlphaAscii() or c.isDigit() or c in {'_', '-'}):
      raiseUnstructured(ctx.profilePath, idx + 1, pkgIndent + 1,
        "'" & pkgName & "' as a `config:` package name",
        "a package identifier")
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  var entries: seq[IntentNode]
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != entryIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "content at indent " & $entryIndent)
    entries.add parseConfigEntry(ctx, i, entryIndent)
    inc i
  result = IntentNode(kind: nkConfigPackage,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: pkgIndent, configPackageName: pkgName,
    configPackageHeaderLine: idx + 1, configEntries: entries)

proc parseConfigBlock(ctx: ParseCtx; idx, parentIndent,
                      pkgIndent: int): IntentNode =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, pkgIndent)
  var packages: seq[IntentNode]
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != pkgIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "content at indent " & $pkgIndent)
    let blk = parseConfigPackage(ctx, i, pkgIndent,
      pkgIndent + ctx.indentStep)
    packages.add blk
    i = blk.endLine
  result = IntentNode(kind: nkConfigBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, configHeaderLine: idx + 1,
    configPackages: packages)

proc splitHostList(ctx: ParseCtx; idx: int; raw: string;
                  startCol: int): seq[string] =
  ## Parse a `[a, b, c]` activity list. The brackets are required.
  let s = raw.strip()
  if s.len < 2 or s[0] != '[' or s[^1] != ']':
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & raw & "'",
      "a `[activity, ...]` list of activity identifiers")
  let inner = s[1 ..< s.len - 1].strip()
  if inner.len == 0:
    return @[]
  for piece in inner.split(","):
    let id = piece.strip()
    if id.len == 0:
      raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
        "an empty activity name in '" & raw & "'",
        "non-empty activity identifiers")
    for c in id:
      if not (c.isAlphaAscii() or c.isDigit() or c == '_'):
        raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
          "'" & id & "' inside the activity list",
          "a single identifier")
    result.add id

proc parseHostsEntry(ctx: ParseCtx; idx, entryIndent: int): IntentNode =
  let raw = ctx.lines[idx]
  let trimmed = trimTrailing(raw)
  let indent = countLeadingSpaces(trimmed)
  # `"hostname": [act, ...]`. Scan for the closing quote then a colon.
  if indent >= trimmed.len or trimmed[indent] != '"':
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & trimmed[indent .. ^1] & "'",
      "a `\"hostname\": [activities]` entry")
  var i = indent + 1
  var hostName = ""
  while i < trimmed.len and trimmed[i] != '"':
    if trimmed[i] == '\\' and i + 1 < trimmed.len:
      hostName.add trimmed[i + 1]
      inc i, 2
    else:
      hostName.add trimmed[i]
      inc i
  if i >= trimmed.len:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "an unterminated host-name string",
      "a closing `\"` for the host name")
  inc i # past the closing quote
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  if i >= trimmed.len or trimmed[i] != ':':
    raiseUnstructured(ctx.profilePath, idx + 1, i + 1,
      "missing `:` after host name",
      "a `:` separator before the activity list")
  inc i
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  let rest = trimmed[i .. ^1]
  let activities = splitHostList(ctx, idx, rest, i)
  result = IntentNode(kind: nkHostsEntry,
    startLine: idx + 1, endLine: idx + 1, indent: entryIndent,
    hostName: hostName, hostActivities: activities,
    hostEntryLine: idx + 1)

proc parseHostsBlock(ctx: ParseCtx; idx, parentIndent,
                     entryIndent: int): IntentNode =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  var entries: seq[IntentNode]
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != entryIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "content at indent " & $entryIndent)
    entries.add parseHostsEntry(ctx, i, entryIndent)
    inc i
  result = IntentNode(kind: nkHostsBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, hostsHeaderLine: idx + 1,
    hostsEntries: entries)

# ---------------------------------------------------------------------------
# Profile body.
# ---------------------------------------------------------------------------

proc parseProfileBody(ctx: ParseCtx; profileHeaderIdx: int): IntentNode =
  let headerLine = ctx.lines[profileHeaderIdx]
  let baseIndent = countLeadingSpaces(headerLine)
  let childIndent = baseIndent + ctx.indentStep
  # Extract the profile name.
  let m = matchHeader(headerLine, ProfileHeader)
  var profileName = m.rest
  if profileName.startsWith("\"") and profileName.endsWith("\""):
    profileName = profileName[1 ..< profileName.len - 1]
  result = IntentNode(kind: nkProfileRoot,
    startLine: profileHeaderIdx + 1, indent: baseIndent,
    name: profileName, headerLine: profileHeaderIdx + 1)
  var i = profileHeaderIdx + 1
  var lastBodyIdx = profileHeaderIdx
  var sawConfig = false
  var sawHosts = false
  while i <= ctx.lines.high:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind < childIndent:
      # Dedented past the profile body — the rest of the file must be
      # blank/comment (the spec doesn't define top-level code after
      # `profile`, so anything else is unstructured).
      let m = matchAnyHeader(line)
      if m.ok and m.keyword == ProfileHeader:
        # A second `profile` would have been caught earlier.
        discard
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "'",
        "either nested content at indent " & $childIndent &
        " or end-of-file")
    if ind != childIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "a top-level profile section at indent " & $childIndent)
    let hm = matchAnyHeader(line)
    if not hm.ok:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "'",
        "one of `activity <name>:`, `config:`, or `hosts:`")
    case hm.keyword
    of ActivityHeader:
      let blk = parseActivity(ctx, i, childIndent,
        childIndent + ctx.indentStep)
      result.children.add blk
      lastBodyIdx = blk.endLine - 1
      i = blk.endLine
    of ConfigHeader:
      if sawConfig:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `config:` block",
          "exactly one `config:` block per profile")
      sawConfig = true
      let blk = parseConfigBlock(ctx, i, childIndent,
        childIndent + ctx.indentStep)
      result.children.add blk
      lastBodyIdx = blk.endLine - 1
      i = blk.endLine
    of HostsHeader:
      if sawHosts:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `hosts:` block",
          "exactly one `hosts:` block per profile")
      sawHosts = true
      let blk = parseHostsBlock(ctx, i, childIndent,
        childIndent + ctx.indentStep)
      result.children.add blk
      lastBodyIdx = blk.endLine - 1
      i = blk.endLine
    else:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "`" & hm.keyword & "` at the profile top level",
        "one of `activity <name>:`, `config:`, or `hosts:`")
  result.endLine = lastBodyIdx + 1

# ---------------------------------------------------------------------------
# Public entry points.
# ---------------------------------------------------------------------------

proc parseProfile*(profilePath, source: string): Profile =
  ## Parse a profile source string. Raises `EUnstructured` if the
  ## source does not match the recognized shape. Comments and blank
  ## lines anywhere are preserved.
  let ending = lineEnding(source)
  let trailingNewline = source.endsWith(ending)
  let rawLines = splitKeepEmpty(source, ending)
  var ctx = ParseCtx(profilePath: profilePath, lines: rawLines, indentStep: 2)
  let headerLine = findProfileHeader(ctx)
  ctx.indentStep = detectIndentStep(ctx.lines, headerLine)
  let root = parseProfileBody(ctx, headerLine - 1)
  result = Profile(path: profilePath, lines: ctx.lines,
    lineEnding: ending, hasTrailingNewline: trailingNewline,
    root: root, indentStep: ctx.indentStep)

proc loadProfile*(profilePath: string): Profile =
  ## Read `profilePath` and parse it. `ENoProfile` and `EUnstructured`
  ## propagate to the caller.
  let src = readFile(profilePath)
  result = parseProfile(profilePath, src)
