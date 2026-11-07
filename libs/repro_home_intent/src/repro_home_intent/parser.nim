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

import std/[strutils, tables]
from repro_core/paths import extendedPath
from repro_profile/data_refs import dataFilePathProblem
from repro_profile/catalog_refs import catalogImportPathProblem
from repro_profile/concerns import concernListProblem
# The lexer's keyword rule, shared with the `package` macro and the
# structural editor, so all three agree on which names cannot be bare.
from repro_project_dsl/selector_names import isNimKeyword
from repro_profile/host_system import HostSystemKey, ManagedElsewhereKeyword,
  AddOnKeyword, FullKeyword, SystemModeKey, SystemActivitiesKey,
  systemPointerProblem, systemBlockProblem

import ./errors
import ./model
import ./predicate

const
  ProfileHeader = "profile"
  ActivityHeader = "activity"
  ConfigHeader = "config"
  HostsHeader = "hosts"
  ResourcesHeader = "resources"
  StowHeader = "stow"
  AdapterPreferenceHeader = "adapterPreference"
  DataHeader = "data"
  CatalogsHeader = "catalogs"
  WhenHeader = "when"
  IfHeader = "if"
  ElifHeader = "elif"
  ElseHeader = "else"

  KnownAdapterPreferenceOs* = ["windows", "linux", "darwin", "macos"]
    ## M2.5: the closed set of OS keys recognized inside an
    ## `adapterPreference:` block. `macos` is an alias for `darwin` and
    ## is canonicalized to `"darwin"` at parse time so resolve-time
    ## lookups use a single canonical key.

  KnownAdapterPreferenceAdapters* = ["tarball", "builtin", "scoop", "nix",
    "path"]
    ## The closed set of realization kinds recognized inside an
    ## `adapterPreference:` list — the profile's selection policy (GM4b,
    ## Provisioning-Contributions.md §"Selection policy"). `builtin` is the
    ## former spelling of `tarball`. Any entry outside this set raises a
    ## structured parse error.

  KnownResourceKinds* = ["env.userPath", "fs.managedBlock",
    "shell.integration", "env.userVariable", "windows.registryValue",
    "windows.startup", "fs.userFile",
    "systemd.userUnit", "launchd.userAgent",
    "linux.dconfKey", "linux.kdeConfigKey",
    "pkg.homebrewFormula", "pkg.homebrewCask"]
    ## M78: the home-scope, elevation-free resource kinds whose M68
    ## drivers exist and that a `home.nim` `resources:` block may
    ## declare. An unrecognized kind is rejected with `EUnstructured`
    ## (the parser MUST NOT silently skip it). `fs.userFile` is the
    ## home-scope analogue of system-scope `fs.systemFile`; it writes
    ## a whole file at a `~`-relative `$HOME` path. `systemd.userUnit`
    ## and `launchd.userAgent` are the M83 step 4b POSIX home-scope
    ## user-services drivers (Linux + macOS respectively); the
    ## parser accepts them on every host even though their apply
    ## paths are platform-bound — a Windows-host `home.nim` that
    ## guards them under `when linux:` / `when macos:` predicates
    ## parses without error and the planner emits them only when
    ## the predicate matches the running host. `linux.dconfKey` and
    ## `linux.kdeConfigKey` are the M83 step 7 GNOME / KDE desktop-
    ## environment-settings drivers (Linux-only; the parser accepts
    ## them on every host, the apply path raises
    ## `ENotImplementedPlatform` off-Linux). `pkg.homebrewFormula`
    ## and `pkg.homebrewCask` are the M83 step 9 macOS Homebrew
    ## drivers (`brew install <name>` and `brew install --cask
    ## <name>` respectively; macOS-only; the apply path raises
    ## `ENotImplementedPlatform` off-macOS).

type
  ParseCtx = object
    profilePath: string
    lines: seq[string]
    indentStep: int
    tolerant: bool
      ## `inspectProfile`: step over the constructs the profile macro
      ## accepts but a text reader cannot see into (helper calls, an
      ## activity's `stow:` / `resources:` block, statements before the
      ## `profile` header), recording each as an `nkOpaque` extent.
      ## `loadProfile` (false) refuses them, as it always has.

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
             ElifHeader, ElseHeader,
             ConfigHeader, HostsHeader, ResourcesHeader,
             AdapterPreferenceHeader, DataHeader, CatalogsHeader]:
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
      # `inspectProfile` steps over what precedes the `profile` block (a
      # `const` the profile reads with `staticRead`, a helper `proc`): the
      # inspector never edits there, and the compiled profile is what
      # evaluates it.
      if found < 0 and not ctx.tolerant:
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

# ---------------------------------------------------------------------------
# Helper calls (inspectProfile only).
# ---------------------------------------------------------------------------
#
# The profile macro accepts a call statement in an activity body (the
# helper-proc splat, Profile-Migration-Patterns.md §How do I splat a helper
# module into an activity body?), in `config:` and in `resources:` (resource
# constructors and helpers such as `zshShellSetup()`). What such a call
# contributes is known only once the profile is compiled. `inspectProfile`
# records its extent -- the call line plus the continuation lines up to the
# parenthesis that closes it -- so an edit elsewhere can step over it.

proc helperCallName(body: string): string =
  ## The callee of a call statement `name(...)` / `mod.name(...)` starting
  ## `body`, or "" when `body` does not start with one. `package(...)` is
  ## the package constructor, never a helper.
  var i = 0
  while i < body.len and (body[i].isAlphaAscii() or body[i].isDigit() or
                          body[i] in {'_', '.'}):
    inc i
  if i == 0 or not (body[0].isAlphaAscii() or body[0] == '_') or
     body[i - 1] == '.':
    return ""
  let name = body[0 ..< i]
  var j = i
  while j < body.len and body[j] == ' ':
    inc j
  if j >= body.len or body[j] != '(':
    return ""
  if name == "package" or name in ["for", "while", "case", "if", "when",
                                   "elif", "else", "proc", "func", "template",
                                   "macro", "return", "discard"]:
    return ""
  name

proc helperCallEnd(lines: seq[string]; idx: int): int =
  ## The 0-based index of the last line of the call statement starting on
  ## line `idx`: the line holding the `)` that closes its first `(`. String
  ## literals (plain, raw and triple-quoted) and `#` comments are skipped
  ## when counting parentheses. Continuation lines must be indented deeper
  ## than the call (or blank / comment). Returns -1 when the statement is
  ## not one call: it never closes, or text other than a comment follows
  ## the closing parenthesis.
  let callIndent = countLeadingSpaces(lines[idx])
  var depth = 0
  var started = false
  var inTriple = false
  var i = idx
  while i < lines.len:
    let line = lines[i]
    if i > idx and not inTriple:
      let t = line.strip()
      if t.len > 0 and not t.startsWith("#") and
         countLeadingSpaces(line) <= callIndent:
        return -1
    var c = 0
    while c < line.len:
      let ch = line[c]
      if inTriple:
        if ch == '"' and c + 2 < line.len and line[c + 1] == '"' and
           line[c + 2] == '"':
          inTriple = false
          c += 3
        else:
          inc c
        continue
      if ch == '#':
        break
      if ch == '"':
        if c + 2 < line.len and line[c + 1] == '"' and line[c + 2] == '"':
          inTriple = true
          c += 3
          continue
        let raw = c > 0 and line[c - 1] in {'r', 'R'}
        inc c
        while c < line.len and line[c] != '"':
          if not raw and line[c] == '\\':
            inc c
          inc c
        inc c
        continue
      if ch == '(':
        inc depth
        started = true
      elif ch == ')':
        dec depth
        if started and depth == 0:
          let rest = line[c + 1 .. ^1].strip()
          if rest.len == 0 or rest.startsWith("#"):
            return i
          return -1
      inc c
    inc i
  -1

proc opaqueHelperCall(ctx: ParseCtx; idx, indent: int): IntentNode =
  ## The `nkOpaque` extent of the helper call starting on line `idx`, or nil
  ## when the line does not start a complete call statement (or the parse
  ## is not tolerant).
  if not ctx.tolerant:
    return nil
  let body = stripInlineComment(ctx.lines[idx]).strip()
  let name = helperCallName(body)
  if name.len == 0:
    return nil
  let last = helperCallEnd(ctx.lines, idx)
  if last < 0:
    return nil
  let shown =
    if last == idx: body
    else: name & "(...)"
  IntentNode(kind: nkOpaque, startLine: idx + 1, endLine: last + 1,
    indent: indent, opaqueKind: okHelperCall,
    opaqueConstruct: "helper call `" & shown & "` (" & ctx.profilePath &
      ":" & $(idx + 1) & ")")

proc isQuotedPackageNameChar(ch: char): bool =
  ch.isAlphaAscii() or ch.isDigit() or ch in {'_', '-'}

proc validateQuotedPackageName(ctx: ParseCtx; idx, column: int;
                               name, spelling: string) =
  ## A double-quoted package name (``"7zip"``, ``package("7zip")``). A
  ## package name is a selector string, not a Nim identifier
  ## (Package-Model.md §"Package names"), so the quoted form is the one that
  ## reaches a name starting with a digit — the profile macro accepts a
  ## string literal there. It holds the characters the bare and backtick
  ## forms allow, with no rule about the first.
  if name.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, column,
      "an empty quoted package name " & spelling,
      "a non-empty package name (e.g. \"7zip\")")
  for ch in name:
    if not isQuotedPackageNameChar(ch):
      raiseUnstructured(ctx.profilePath, idx + 1, column,
        "'" & spelling & "' as a quoted package name",
        "a quoted name containing only letters, digits, `_`, and `-`")

proc refuseBareKeyword(ctx: ParseCtx; idx, column: int;
                       name, spelling, quotedForm: string) =
  ## Refuse an unquoted package name that is a Nim keyword (``nil``,
  ## ``type``; matched style-insensitively, as the lexer does, so ``n_il``
  ## too). In the profile macro such a line is the keyword, not a package
  ## reference, so it never names the package ``nil``; reading it as one
  ## would make the structural editor see a package the compiled profile
  ## does not have. A keyword-named package is written quoted
  ## (Home-Profile-Intent-Layer.md §"`package(...)` — explicit constructor
  ## forms"), as the editor writes it.
  if isNimKeyword(name):
    raiseUnstructured(ctx.profilePath, idx + 1, column,
      spelling & ", the Nim keyword `" & name & "`",
      "a package named by a Nim keyword written quoted (e.g. " &
      quotedForm & ")")

proc parsePackageCallForm(ctx: ParseCtx; idx, indent: int;
                          body: string): IntentNode =
  ## M69: parse the new `package(<id>[, "<version>"])` call form used
  ## inside `activity <name>:` blocks. Returns an `nkPackageRef`
  ## carrying `packageVersion = ""` for the bare-arg call
  ## `package(<id>)` and the literal version string for the
  ## `package(<id>, "<version>")` form. A malformed call (missing
  ## closing paren, non-identifier id, version not a double-quoted
  ## string literal, extra arguments, etc.) is rejected with
  ## `EUnstructured` naming the offending text.
  doAssert body.startsWith("package(")
  let openIdx = "package".len  # position of '('
  let closeIdx = body.rfind(')')
  if closeIdx <= openIdx:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & body & "'",
      "a `package(<id>)` or `package(<id>, \"<version>\")` call " &
      "with a closing parenthesis")
  let trailing = body[closeIdx + 1 .. ^1].strip()
  if trailing.len > 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "trailing text after `package(...)` call: '" & trailing & "'",
      "no content after the closing parenthesis")
  let inner = body[openIdx + 1 ..< closeIdx]
  # Split at the FIRST top-level comma (outside any string literal).
  var idArg = ""
  var versionArg = ""
  var hasVersion = false
  var i = 0
  while i < inner.len and inner[i] != ',':
    idArg.add inner[i]
    inc i
  if i < inner.len and inner[i] == ',':
    hasVersion = true
    inc i  # past comma
    versionArg = inner[i .. ^1]
  var pkgId = idArg.strip()
  if pkgId.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "an empty package id in `package(...)`",
      "a package identifier (e.g. `package(jdk)`)")
  if pkgId[0] == '"':
    # `package("windows-terminal")` / `package("7zip", "26.01")`:
    # Home-Profile-Intent-Layer.md §"`package(...)` — explicit constructor
    # forms", the quoted-name form.
    if pkgId.len < 2 or pkgId[^1] != '"':
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & pkgId & "' as a `package(...)` id",
        "a double-quoted package name with a closing quote")
    let quoted = pkgId
    pkgId = pkgId[1 ..< pkgId.len - 1]
    validateQuotedPackageName(ctx, idx, indent + 1, pkgId, quoted)
  elif not (pkgId[0].isAlphaAscii() or pkgId[0] == '_'):
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & pkgId & "' as a `package(...)` id",
      "an identifier starting with a letter or underscore")
  else:
    for ch in pkgId:
      if not (ch.isAlphaAscii() or ch.isDigit() or ch in {'_', '-'}):
        raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
          "'" & pkgId & "' as a `package(...)` id",
          "an identifier of letters, digits, `_`, and `-`")
    # An unquoted id that is a Nim keyword (`package(nil)`) is not a name to
    # the profile macro: Nim parses it as the keyword (a `nil` literal), so
    # reading it as the package `nil` here would disagree with what the
    # compiled profile does. The quoted form reaches such a name.
    refuseBareKeyword(ctx, idx, indent + 1, pkgId,
      "'" & pkgId & "' as a `package(...)` id",
      "package(\"" & pkgId & "\")")
  var version = ""
  if hasVersion:
    let vTrim = versionArg.strip()
    if vTrim.len < 2 or vTrim[0] != '"' or vTrim[^1] != '"':
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & versionArg & "' as a `package(...)` version literal",
        "a double-quoted version string (e.g. \"21.0.5\")")
    version = vTrim[1 ..< vTrim.len - 1]
    if version.len == 0:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "an empty version literal in `package(" & pkgId & ", \"\")`",
        "a non-empty double-quoted version string")
  result = IntentNode(kind: nkPackageRef,
    startLine: idx + 1, endLine: idx + 1, indent: indent,
    packageName: pkgId, packageLine: idx + 1,
    packageVersion: version)

proc parsePackageRefLine(ctx: ParseCtx; idx: int): IntentNode =
  ## Parse a bare package-reference line. The spec allows
  ## `--version-pin` style attributes; we treat the whole post-name
  ## tail as an opaque string we'll preserve byte-for-byte. Comments
  ## are ignored (they hang off the line).
  ##
  ## M83 Phase F3: also accept the Phase A backtick-quoted form
  ## ``` `hyphenated-package` ``` so a Phase-A-shaped profile (which
  ## must use backticks for hyphenated identifiers — `nnkAccQuoted`
  ## in Nim) still parses through the structural editor's source-text
  ## reader. The extracted `packageName` is the inner text;
  ## surrounding backticks are dropped to match the bare-identifier
  ## storage shape.
  ##
  ## M69: also accept the `package(<id>[, "<version>"])` call form.
  ## This is the spec-mandated DSL extension that lets `home.nim`
  ## activities reference catalog packages with an optional pinned
  ## version. Bare-identifier references continue to parse exactly as
  ## before.
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let indent = countLeadingSpaces(trimmed)
  let body = trimmed[indent .. ^1]
  if body.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "an empty line treated as a package reference",
      "a bare package identifier (e.g. `git`)")
  # M69: detect the `package(<id>[, "<version>"])` call form FIRST so
  # the bare-identifier rejection logic (which forbids `(` after the
  # name) doesn't fire against a legitimate call.
  if body.startsWith("package(") or body.startsWith("package ("):
    # Normalize the optional whitespace between `package` and `(`.
    var normalized = body
    if body.startsWith("package ("):
      normalized = "package(" & body["package (".len .. ^1]
    return parsePackageCallForm(ctx, idx, indent, normalized)
  # The package name is the first identifier token (bare or
  # backtick-quoted); the rest may be whitespace + flag-style
  # attributes which we accept and preserve.
  var i = 0
  var pkgName = ""
  let bareForm = body[0] notin {'"', '`'}
  if body[0] == '"':
    # A quoted name, `"7zip"`: the bare form of a package name that is not
    # a Nim identifier (the profile macro accepts a string literal here).
    let closeIdx = body.find('"', 1)
    if closeIdx < 1:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & body & "'",
        "a closing double quote after the package name (e.g. \"7zip\")")
    pkgName = body[1 ..< closeIdx]
    i = closeIdx + 1
    validateQuotedPackageName(ctx, idx, indent + 2, pkgName,
      body[0 .. closeIdx])
  elif body[0] == '`':
    # Phase F3: backtick-quoted form `<name>`.
    let closeIdx = body.find('`', 1)
    if closeIdx <= 1:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & body & "'",
        "a closing backtick after the package name " &
        "(e.g. `windows-terminal`)")
    pkgName = body[1 ..< closeIdx]
    i = closeIdx + 1
    if pkgName.len == 0 or
       not (pkgName[0].isAlphaAscii() or pkgName[0] == '_'):
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 2,
        "'`" & pkgName & "`'",
        "a backtick-quoted name starting with a letter or underscore")
    for ch in pkgName:
      if not (ch.isAlphaAscii() or ch.isDigit() or ch in {'_', '-'}):
        raiseUnstructured(ctx.profilePath, idx + 1, indent + 2,
          "'`" & pkgName & "`'",
          "a backtick-quoted name containing only " &
          "letters, digits, `_`, and `-`")
  else:
    while i < body.len and (body[i].isAlphaAscii() or body[i].isDigit() or
                            body[i] in {'_', '-'}):
      inc i
    pkgName = body[0 ..< i]
    if pkgName.len == 0 or not (body[0].isAlphaAscii() or body[0] == '_'):
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & body & "'",
        "a bare package reference starting with a letter or underscore")
  if bareForm:
    # Refuse Nim control-flow keywords — the spec explicitly calls out
    # `for` loops building an activity body at runtime as the canonical
    # unstructured case. Only the bare form: `"type"` and `` `type` `` are
    # names, which the profile macro reads as the package `type`.
    if pkgName in NimControlFlowKeywords:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "Nim `" & pkgName & "` keyword used to build an activity body",
        "a bare package reference (`for` / `while` / etc. are not allowed)")
    # Any other keyword (`nil`, `out`, ...) is not a package reference
    # either: refused rather than read as a package of that name.
    refuseBareKeyword(ctx, idx, indent + 1, pkgName,
      "'" & pkgName & "' as a bare package reference",
      "\"" & pkgName & "\"")
  # The package reference may NOT be a Nim assignment or call expression.
  # Reject `=`, `(`, and similar.
  let rest = body[i .. ^1].strip()
  if rest.len > 0 and (rest[0] == '=' or rest[0] == '(' or rest[0] == ','):
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & body & "'",
      "a bare package reference (no `=`, `(`, or `,`)")
  result = IntentNode(kind: nkPackageRef,
    startLine: idx + 1, endLine: idx + 1, indent: indent,
    packageName: pkgName, packageLine: idx + 1,
    packageVersion: "")

proc parseConditional(ctx: ParseCtx; startIdx: int; indent: int;
                     keyword: CondKeyword;
                     childIndent: int): IntentNode

proc parseActivityChildren(ctx: ParseCtx; startIdx, endIdxExclusive,
                           childIndent: int;
                           activityLevel = false): seq[IntentNode] =
  ## Parse lines [startIdx, endIdxExclusive) as children of an
  ## activity body. Children are package references OR conditional
  ## blocks. `inspectProfile` also steps over helper calls and -- directly
  ## in the activity body (`activityLevel`), the only place the profile
  ## macro accepts them -- `stow:` and `resources:` blocks.
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
    # M83 Phase F3: tolerate a bare `discard` line. The structural
    # editor synthesizes one as a no-op body placeholder when a
    # removal would otherwise leave the activity / conditional body
    # syntactically empty (Phase A macro form requires a body).
    if raw.strip() == "discard":
      inc i
      continue
    if ctx.tolerant and activityLevel:
      let blockName = stripInlineComment(raw).strip()
      if blockName in [StowHeader & ":", ResourcesHeader & ":"]:
        let last = lastStructuralIdx(ctx.lines, i + 1,
          childIndent + ctx.indentStep)
        let isStow = blockName == StowHeader & ":"
        result.add IntentNode(kind: nkOpaque, startLine: i + 1,
          endLine: max(last + 1, i + 1), indent: childIndent,
          opaqueKind: (if isStow: okActivityStowBlock
                       else: okActivityResources),
          opaqueConstruct: "`" & blockName & "` block (" & ctx.profilePath &
            ":" & $(i + 1) & ")")
        i = max(last + 1, i + 1)
        continue
    let call = opaqueHelperCall(ctx, i, childIndent)
    if not call.isNil:
      result.add call
      i = call.endLine
      continue
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
      parseActivityChildren(ctx, idx + 1, endIdx + 1, childIndent,
        activityLevel = true)
    else:
      @[]
  result = IntentNode(kind: nkActivity,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, activityName: m.rest,
    activityHeaderLine: idx + 1, activityChildren: bodyChildren)

# ---------------------------------------------------------------------------
# Guard chains in `config:` and `resources:` (GM3).
# ---------------------------------------------------------------------------
#
# A compiled profile guards `config:` entries and `resources:` declarations
# with a runtime `when <pred>:` chain (`elif <pred>:` / `else:` branches,
# nesting allowed); the profile macro gives each branch its predicate
# conjoined with the negation of every earlier branch, so exactly one branch
# applies on any host (`lowerWhenChain` in `repro_profile/macros.nim`). The
# inspector reads the same chain into `nkCondBlock`s carrying that effective
# guard, so the structural editor knows each guarded element's extent and
# the guard walkers (`applicableConfigEntries`, `applicableConfigPackages`,
# `applicableResourceEntries`) select from a parsed profile exactly what
# the planner selects from the compiled one.

type
  GuardLeafParser = proc (ctx: ParseCtx; idx, indent: int): IntentNode
    {.nimcall.}
    ## Parses the element (config entry, config package block, resource
    ## entry) whose first line is `idx`; the returned node's `endLine` is
    ## its last line (1-based), i.e. the 0-based index of the next line.

  GuardSection = object
    ## What a guard chain may hold, for diagnostics and for the keyword set.
    name: string          ## e.g. "a `config:` package block"
    allowIf: bool         ## `if <pred>:` accepted as a chain head
    leaf: GuardLeafParser

  GuardChain = object
    ## The chain being read at one nesting level. `open` while the previous
    ## sibling was a `when` / `if` / `elif` branch, so an `elif` / `else`
    ## may follow; `priors` are that chain's branch predicates so far.
    open: bool
    priors: seq[PredNode]

proc effectiveGuard(pred: PredNode; priors: seq[PredNode]): PredNode =
  ## `pred and not p1 and not p2 ...` -- the guard `lowerWhenChain` gives a
  ## branch. `pred` is nil for `else:`.
  var ops: seq[PredNode]
  if not pred.isNil:
    ops.add pred
  for prior in priors:
    ops.add PredNode(kind: pnNot, operand: prior)
  if ops.len == 1: ops[0]
  else: PredNode(kind: pnAnd, operands: ops)

proc guardKeyword(text: string): CondKeyword =
  case text
  of WhenHeader: ckWhen
  of IfHeader: ckIf
  of ElifHeader: ckElif
  else: ckElse

proc parseGuardedChildren(ctx: ParseCtx; startIdx, endIdxExclusive,
                          childIndent: int;
                          section: GuardSection): seq[IntentNode]

proc parseGuardBranch(ctx: ParseCtx; idx, indent: int; keywordText: string;
                      chain: var GuardChain;
                      section: GuardSection): IntentNode =
  ## One branch of a guard chain whose header (`when` / `if` / `elif` /
  ## `else`) is line `idx`. Its body holds `section`'s elements and nested
  ## chains. A branch the editor cannot evaluate is refused, never skipped:
  ## a compile-time `when defined(...)` is decided by the compiling host,
  ## so no guard the inspector could record describes it.
  let keyword = guardKeyword(keywordText)
  let m = matchHeader(ctx.lines[idx], keywordText)
  if not m.matched:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & ctx.lines[idx].strip() & "'",
      "a `" & keywordText & "` branch header ending in `:`")
  if keyword in {ckElif, ckElse} and not chain.open:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "`" & keywordText & "` without a preceding `when <pred>:` branch",
      "a `when <pred>:` branch before `" & keywordText & "` in " &
        section.name)
  if keyword == ckIf and not section.allowIf:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "`if " & m.rest & ":` in " & section.name,
      "`when <pred>:` (the profile macro accepts only `when` chains here)")
  var pred: PredNode = nil
  if keyword == ckElse:
    if m.rest.len != 0:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "'" & m.rest & "' after `else`", "`else:` with no predicate")
  else:
    if m.rest.len == 0:
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "an empty predicate",
        "a predicate expression after `" & keywordText & "`")
    if m.rest.startsWith("defined(") or m.rest.startsWith("defined ") or
       m.rest.contains(" defined("):
      raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
        "a compile-time `" & keywordText & " " & m.rest & ":` in " &
          section.name,
        "a runtime predicate guard such as `when linux():` -- a " &
        "`when defined(...)` branch is decided by the compiling host and " &
        "is not machine-editable; edit it by hand")
    pred = parsePredicate(ctx.profilePath, m.rest, idx + 1)
  if keyword in {ckWhen, ckIf}:
    chain.priors = @[]
  let guard = effectiveGuard(pred, chain.priors)
  if keyword == ckElse:
    chain.open = false
  else:
    chain.open = true
    chain.priors.add pred
  let childIndent = indent + ctx.indentStep
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, childIndent)
  let body =
    if endIdx >= idx + 1:
      parseGuardedChildren(ctx, idx + 1, endIdx + 1, childIndent, section)
    else:
      @[]
  result = IntentNode(kind: nkCondBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: indent, keyword: keyword,
    predicateSource: m.rest, predicateAst: guard,
    canonicalPredicate: renderPredicate(normalizeAst(guard)),
    condHeaderLine: idx + 1, condChildren: body)

proc parseGuardedChildren(ctx: ParseCtx; startIdx, endIdxExclusive,
                          childIndent: int;
                          section: GuardSection): seq[IntentNode] =
  ## Lines [startIdx, endIdxExclusive) at `childIndent`: `section`'s
  ## elements, or guard chains holding them.
  var chain = GuardChain()
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
    if m.ok and m.keyword in [WhenHeader, IfHeader, ElifHeader, ElseHeader]:
      let blk = parseGuardBranch(ctx, i, childIndent, m.keyword, chain,
        section)
      result.add blk
      i = blk.endLine
    else:
      chain = GuardChain()
      # `inspectProfile`: a helper or constructor call (`gitIdentity(...)`
      # in `config:`, `fsUserFile(...)` / `zshShellSetup()` in `resources:`)
      # is stepped over; `loadProfile` refuses it through `section.leaf`.
      let call = opaqueHelperCall(ctx, i, childIndent)
      let node =
        if call.isNil: section.leaf(ctx, i, childIndent)
        else: call
      result.add node
      i = node.endLine

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
      "a `<key> = <value>` configurable assignment, or a " &
      "`when <pred>:` / `elif <pred>:` / `else:` guard around assignments")
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

proc parseConfigEntryLeaf(ctx: ParseCtx; idx, indent: int): IntentNode =
  parseConfigEntry(ctx, idx, indent)

const ConfigEntrySection = GuardSection(name: "a `config:` package block",
  allowIf: false,
  leaf: parseConfigEntryLeaf)

proc parseConfigPackage(ctx: ParseCtx; idx, pkgIndent,
                        entryIndent: int): IntentNode =
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let body = trimmed[pkgIndent .. ^1]
  if not body.endsWith(":"):
    raiseUnstructured(ctx.profilePath, idx + 1, pkgIndent + 1,
      "'" & body & "'",
      "a `<package>:` header inside `config:`, or a `when <pred>:` / " &
      "`elif <pred>:` / `else:` guard around package blocks")
  let pkgName = body[0 ..< body.len - 1].strip()
  for c in pkgName:
    if not (c.isAlphaAscii() or c.isDigit() or c in {'_', '-'}):
      raiseUnstructured(ctx.profilePath, idx + 1, pkgIndent + 1,
        "'" & pkgName & "' as a `config:` package name",
        "a package identifier, or a `when <pred>:` / `elif <pred>:` / " &
        "`else:` guard around package blocks")
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  let entries =
    if endIdx >= idx + 1:
      parseGuardedChildren(ctx, idx + 1, endIdx + 1, entryIndent,
        ConfigEntrySection)
    else:
      @[]
  result = IntentNode(kind: nkConfigPackage,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: pkgIndent, configPackageName: pkgName,
    configPackageHeaderLine: idx + 1, configEntries: entries)

proc parseConfigPackageLeaf(ctx: ParseCtx; idx, indent: int): IntentNode =
  parseConfigPackage(ctx, idx, indent, indent + ctx.indentStep)

const ConfigPackageSection = GuardSection(name: "`config:`",
  allowIf: false,
  leaf: parseConfigPackageLeaf)

proc parseConfigBlock(ctx: ParseCtx; idx, parentIndent,
                      pkgIndent: int): IntentNode =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, pkgIndent)
  let packages =
    if endIdx >= idx + 1:
      parseGuardedChildren(ctx, idx + 1, endIdx + 1, pkgIndent,
        ConfigPackageSection)
    else:
      @[]
  result = IntentNode(kind: nkConfigBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, configHeaderLine: idx + 1,
    configPackages: packages)

proc parseHostSystemText(ctx: ParseCtx; idx: int; raw: string;
                         startCol: int; hostName: string): string =
  ## The value of a block-form host entry's `system:` line, the text form of
  ## what the `profile` macro accepts (`repro_profile/host_system`):
  ## `managedElsewhere` (returns "") or `managedElsewhere("<pointer>")`
  ## (returns the pointer), optionally followed by a `#` comment.
  let expected = "`" & ManagedElsewhereKeyword & "` or `" &
    ManagedElsewhereKeyword & "(\"<managing repository>\")`"
  var s = raw.strip()
  if not s.startsWith(ManagedElsewhereKeyword):
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & s & "' as the `system:` value of hosts entry \"" & hostName &
      "\"", expected)
  s = s[ManagedElsewhereKeyword.len .. ^1].strip()
  if s.len == 0 or s.startsWith("#"):
    return ""
  # `("...")`: a plain string literal with `\\` and `\"` escapes.
  if not s.startsWith("(\""):
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & raw.strip() & "' as the `system:` value of hosts entry \"" &
      hostName & "\"", expected)
  var i = 2
  var pointer = ""
  while i < s.len and s[i] != '"':
    if s[i] == '\\' and i + 1 < s.len:
      pointer.add s[i + 1]
      inc i, 2
    else:
      pointer.add s[i]
      inc i
  if i + 1 >= s.len or s[i + 1] != ')':
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "an unterminated `" & ManagedElsewhereKeyword & "(...)` in hosts " &
      "entry \"" & hostName & "\"", expected)
  let tail = s[i + 2 .. ^1].strip()
  if tail.len > 0 and not tail.startsWith("#"):
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & tail & "' after the `system:` value of hosts entry \"" &
      hostName & "\"", "nothing, or a `#` comment")
  let problem = systemPointerProblem(pointer)
  if problem.len > 0:
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "system: " & problem & " in hosts entry \"" & hostName & "\"",
      expected)
  pointer

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

proc gatherHostList(ctx: ParseCtx; idx: int; first: string;
                    ownerIndent: int): tuple[text: string; lastIdx: int] =
  ## The text of the `[...]` activity list that starts on line `idx` with
  ## `first` (the text after the `:`), and the 0-based index of the line
  ## holding its `]`. A list may span lines, as any Nim array literal may
  ## (zah/dotfiles writes its long host entries that way): the continuation
  ## lines are those indented deeper than `ownerIndent` (the host entry or
  ## the `activities:` key), comments dropped. When `first` does not open a
  ## list, or the list never closes, the line's own text is returned with
  ## `lastIdx = idx`, so `splitHostList` refuses it as before.
  let head = stripInlineComment(first).strip()
  if not head.startsWith("[") or head.contains(']'):
    return (head, idx)
  var text = head
  var j = idx + 1
  while j < ctx.lines.len:
    let line = ctx.lines[j]
    if isBlankOrComment(line):
      inc j
      continue
    if countLeadingSpaces(line) <= ownerIndent:
      break
    let piece = stripInlineComment(line).strip()
    text.add " " & piece
    if piece.contains(']'):
      return (text, j)
    inc j
  (head, idx)

const SystemValueExpected = "`" & ManagedElsewhereKeyword & "`, `" &
  ManagedElsewhereKeyword & "(\"<managing repository>\")`, `" & AddOnKeyword &
  "`, `" & FullKeyword & "` or the block form (`" & SystemModeKey & ": " &
  AddOnKeyword & " | " & FullKeyword & "` and `" & SystemActivitiesKey &
  ": [...]`)"
  ## What a `system:` value may be, for diagnostics.

proc finishSystemBlock(ctx: ParseCtx; idx, col: int; hostName: string;
                       mode: string; hasActivities: bool;
                       activities: seq[string]): HostSystemDecl =
  ## Validate a block-form `system:` value with the words the `profile`
  ## macro uses (`host_system.systemBlockProblem`) and build it.
  let problem = systemBlockProblem(mode, hasActivities, activities)
  if problem.len > 0:
    raiseUnstructured(ctx.profilePath, idx + 1, col + 1,
      "system: " & problem & " in hosts entry \"" & hostName & "\"",
      "`" & SystemModeKey & ": " & AddOnKeyword & " | " & FullKeyword &
      "` and a non-empty `" & SystemActivitiesKey & ": [...]`")
  HostSystemDecl(mode: (if mode == FullKeyword: hsmFull else: hsmAddOn),
    activities: activities)

proc readSystemBlockPair(ctx: ParseCtx; idx, col: int; hostName: string;
                         key, value: string; seen: var seq[string];
                         mode: var string; hasActivities: var bool;
                         activities: var seq[string]) =
  ## One `key: value` of a block-form `system:` value (either spelling).
  if key in seen:
    raiseUnstructured(ctx.profilePath, idx + 1, col + 1,
      "a second `" & key & ":` in the `system:` value of hosts entry \"" &
      hostName & "\"", "each of `" & SystemModeKey & ":` / `" &
      SystemActivitiesKey & ":` at most once")
  seen.add key
  case key
  of SystemModeKey:
    mode = value.strip()
    if mode.len == 0 or not mode.allCharsInSet(IdentChars):
      raiseUnstructured(ctx.profilePath, idx + 1, col + 1,
        "'" & value.strip() & "' as the `system: " & SystemModeKey &
        ":` of hosts entry \"" & hostName & "\"", "`" & AddOnKeyword & "` or `" &
        FullKeyword & "`")
  of SystemActivitiesKey:
    hasActivities = true
    activities = splitHostList(ctx, idx, value, col)
  else:
    raiseUnstructured(ctx.profilePath, idx + 1, col + 1,
      "'" & key & ":' in the `system:` value of hosts entry \"" & hostName &
      "\"", "`" & SystemModeKey & ":` and `" & SystemActivitiesKey & ":`")

proc parseInlineSystemBlock(ctx: ParseCtx; idx: int; raw: string;
                            startCol: int; hostName: string):
    HostSystemDecl =
  ## `{mode: addOn, activities: [a, b]}` on one line, optionally followed by
  ## a `#` comment. Commas inside the `[...]` list do not split pairs.
  let s = raw.strip()
  var depth = 0
  var close = -1
  for i, c in s:
    case c
    of '[': inc depth
    of ']': dec depth
    of '}':
      if depth == 0:
        close = i
        break
    else: discard
  if close < 0:
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "an unterminated `{...}` as the `system:` value of hosts entry \"" &
      hostName & "\"", SystemValueExpected)
  let tail = s[close + 1 .. ^1].strip()
  if tail.len > 0 and not tail.startsWith("#"):
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & tail & "' after the `system:` value of hosts entry \"" &
      hostName & "\"", "nothing, or a `#` comment")
  var pieces: seq[string]
  var current = ""
  depth = 0
  for c in s[1 ..< close]:
    case c
    of '[': inc depth; current.add c
    of ']': dec depth; current.add c
    of ',':
      if depth == 0:
        pieces.add current
        current = ""
      else:
        current.add c
    else: current.add c
  if current.strip().len > 0 or pieces.len > 0:
    pieces.add current
  var seen: seq[string]
  var mode = ""
  var hasActivities = false
  var activities: seq[string]
  for piece in pieces:
    let colon = piece.find(':')
    if colon <= 0:
      raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
        "'" & piece.strip() & "' in the `system:` value of hosts entry \"" &
        hostName & "\"", "`key: value` pairs")
    readSystemBlockPair(ctx, idx, startCol, hostName,
      piece[0 ..< colon].strip(), piece[colon + 1 .. ^1], seen, mode,
      hasActivities, activities)
  finishSystemBlock(ctx, idx, startCol, hostName, mode, hasActivities,
    activities)

proc parseIndentedSystemBlock(ctx: ParseCtx; idx, keyIndent: int;
                              hostName: string):
    tuple[decl: HostSystemDecl; lastIdx: int] =
  ## The block form written under a bare `system:` line at 0-based line
  ## `idx` (indent `keyIndent`): `mode:` / `activities:` lines indented
  ## deeper, the list free to span lines as any activity list may.
  var seen: seq[string]
  var mode = ""
  var hasActivities = false
  var activities: seq[string]
  var j = idx
  var last = idx
  var pairIndent = -1
  while j + 1 < ctx.lines.len:
    let line = ctx.lines[j + 1]
    if isBlankOrComment(line):
      inc j
      continue
    let ind = countLeadingSpaces(line)
    if ind <= keyIndent:
      break
    inc j
    if pairIndent < 0:
      pairIndent = ind
    elif ind != pairIndent:
      raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind & " in the `system:` " &
        "block of hosts entry \"" & hostName & "\"",
        "`" & SystemModeKey & ":` / `" & SystemActivitiesKey &
        ":` at indent " & $pairIndent)
    let body = trimTrailing(line)[ind .. ^1]
    let colon = body.find(':')
    if colon <= 0:
      raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
        "'" & body & "' in the `system:` block of hosts entry \"" & hostName &
        "\"", "`" & SystemModeKey & ": ...` or `" & SystemActivitiesKey &
        ": [...]`")
    let key = body[0 ..< colon].strip()
    var value = stripInlineComment(body[colon + 1 .. ^1])
    if key == SystemActivitiesKey:
      let gathered = gatherHostList(ctx, j, body[colon + 1 .. ^1], ind)
      value = gathered.text
      j = gathered.lastIdx
    readSystemBlockPair(ctx, j, ind + colon + 1, hostName, key, value, seen,
      mode, hasActivities, activities)
    last = j
  if pairIndent < 0:
    raiseUnstructured(ctx.profilePath, idx + 1, keyIndent + 1,
      "an empty `system:` in hosts entry \"" & hostName & "\"",
      SystemValueExpected)
  (finishSystemBlock(ctx, idx, keyIndent, hostName, mode, hasActivities,
    activities), last)

proc parseHostSystemValue(ctx: ParseCtx; idx: int; raw: string;
                          startCol, keyIndent: int; hostName: string):
    tuple[decl: HostSystemDecl; lastIdx: int] =
  ## The value of a block-form host entry's `system:` key at 0-based line
  ## `idx`, the text form of what the `profile` macro accepts
  ## (`repro_profile/host_system`), and the 0-based index of its last line.
  let value = raw.strip()
  if value.len == 0 or value.startsWith("#"):
    return parseIndentedSystemBlock(ctx, idx, keyIndent, hostName)
  if value.startsWith("{"):
    return (parseInlineSystemBlock(ctx, idx, raw, startCol, hostName), idx)
  let word = stripInlineComment(value).strip()
  if word == AddOnKeyword:
    return (HostSystemDecl(mode: hsmAddOn), idx)
  if word == FullKeyword:
    return (HostSystemDecl(mode: hsmFull), idx)
  if not value.startsWith(ManagedElsewhereKeyword):
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & value & "' as the `system:` value of hosts entry \"" & hostName &
      "\"", SystemValueExpected)
  let pointer = parseHostSystemText(ctx, idx, raw, startCol, hostName)
  (HostSystemDecl(mode: hsmManagedElsewhere, managedBy: pointer), idx)

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
  if rest.len == 0 or rest.startsWith("#"):
    # Block form (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped
    # apply): `activities: [...]` and / or `applies: [...]` lines, indented
    # under the host -- the same surface the `profile` macro accepts, with
    # the same refusals.
    result = IntentNode(kind: nkHostsEntry,
      startLine: idx + 1, endLine: idx + 1, indent: entryIndent,
      hostName: hostName, hostEntryLine: idx + 1, hostBlockForm: true)
    let childIndent = entryIndent + ctx.indentStep
    let endIdx = lastStructuralIdx(ctx.lines, idx + 1, childIndent)
    var seenKeys: seq[string]
    var j = idx
    while j < endIdx:
      inc j
      let line = ctx.lines[j]
      if isBlankOrComment(line):
        continue
      let ind = countLeadingSpaces(line)
      if ind != childIndent:
        raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
          "'" & line.strip() & "' at indent " & $ind,
          "`activities: [...]`, `applies: [...]` or `system: ...` at indent " &
          $childIndent)
      let body = trimTrailing(line)[ind .. ^1]
      let colon = body.find(':')
      let key = if colon > 0: body[0 ..< colon].strip() else: ""
      if key notin ["activities", "applies", HostSystemKey]:
        raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
          "'" & body & "' in hosts entry \"" & hostName & "\"",
          "`activities: [...]`, `applies: [...]` or `system: ...`")
      if key in seenKeys:
        raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
          "a second `" & key & ":` in hosts entry \"" & hostName & "\"",
          "each of `activities:` / `applies:` / `system:` at most once")
      seenKeys.add key
      if key == HostSystemKey:
        let parsed = parseHostSystemValue(ctx, j, body[colon + 1 .. ^1],
          ind + colon + 1, ind, hostName)
        result.hostSystemDeclared = true
        result.hostSystem = parsed.decl
        j = parsed.lastIdx
        continue
      let keyLine = j
      let gathered = gatherHostList(ctx, j, body[colon + 1 .. ^1], ind)
      let list = splitHostList(ctx, j, gathered.text, ind + colon + 1)
      j = gathered.lastIdx
      if key == "activities":
        result.hostActivities = list
        result.hostActivitiesLine = keyLine + 1
        result.hostListEndLine = gathered.lastIdx + 1
      else:
        let problem = concernListProblem(list)
        if problem.len > 0:
          raiseUnstructured(ctx.profilePath, j + 1, ind + 1,
            "applies: " & problem & " in hosts entry \"" & hostName & "\"",
            "known concern names, each at most once")
        result.hostAppliesDeclared = true
        result.hostApplies = list
    if seenKeys.len == 0:
      raiseUnstructured(ctx.profilePath, idx + 1, i + 1,
        "a host entry with neither a list nor an indented block",
        "`[activities]` or an indented `activities:` / `applies:` block")
    result.endLine = max(endIdx + 1, idx + 1)
    return
  let gathered = gatherHostList(ctx, idx, rest, entryIndent)
  let activities = splitHostList(ctx, idx, gathered.text, i)
  result = IntentNode(kind: nkHostsEntry,
    startLine: idx + 1, endLine: gathered.lastIdx + 1, indent: entryIndent,
    hostName: hostName, hostActivities: activities,
    hostEntryLine: idx + 1, hostListEndLine: gathered.lastIdx + 1)

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
    let entry = parseHostsEntry(ctx, i, entryIndent)
    entries.add entry
    i = entry.endLine
  result = IntentNode(kind: nkHostsBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, hostsHeaderLine: idx + 1,
    hostsEntries: entries)

# ---------------------------------------------------------------------------
# Resources block parsing (M78).
# ---------------------------------------------------------------------------
#
# Surface syntax (line-oriented, consistent with `config:`):
#
#   resources:
#     env.userPath launcherDir:
#       entries = "~/.repro/bin"
#     fs.managedBlock shellRc:
#       hostFile = "~/.bashrc"
#       blockId = "repro-home"
#       content = "export EDITOR=nvim"
#     when windows:
#       windows.registryValue hideExt:
#         key = r"HKCU\Software\..."
#         name = "HideFileExt"
#         valueKind = "dword"
#         value = "0"
#
# An entry header is `<kind> <address>:` — `<kind>` is one of
# `KnownResourceKinds`, `<address>` is a stable id. The body is
# `<key> = <value>` attribute lines. Entries may nest inside
# `when`/`if` predicate blocks.

proc parseResourceAttr(ctx: ParseCtx; idx, attrIndent: int): IntentNode =
  ## Parse a `<key> = <value>` payload line inside a resource entry.
  ## The RHS bytes are preserved verbatim (no leading `=`).
  let raw = ctx.lines[idx]
  let trimmed = trimTrailing(raw)
  let indent = countLeadingSpaces(trimmed)
  var i = indent
  while i < trimmed.len and (trimmed[i].isAlphaAscii() or
                             trimmed[i].isDigit() or trimmed[i] == '_'):
    inc i
  let key = trimmed[indent ..< i]
  if key.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & trimmed[indent .. ^1] & "'",
      "a `<key> = <value>` resource attribute")
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  if i >= trimmed.len or trimmed[i] != '=':
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & trimmed[indent .. ^1] & "'",
      "a `<key> = <value>` resource attribute")
  inc i
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  let rhs = trimmed[i .. ^1]
  if rhs.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, i + 1,
      "missing value", "a value expression after `=`")
  result = IntentNode(kind: nkResourceAttr,
    startLine: idx + 1, endLine: idx + 1, indent: attrIndent,
    resourceAttrKey: key, resourceAttrValueSource: rhs,
    resourceAttrLine: idx + 1)

proc parseDependsOnListLiteral(raw: string): seq[string] =
  ## Parse a `[a, b, c]` list literal into its string elements. Each
  ## element must be a double-quoted string. The brackets are
  ## required; whitespace and newlines around elements are stripped.
  ## An empty `[]` yields an empty seq. Helper for
  ## `parseDependsOnAttr` — used only for that one resource-attribute
  ## RHS so the home parser stays line-oriented for every other key.
  let t = raw.strip()
  if t.len < 2 or t[0] != '[' or t[^1] != ']':
    raise newException(ValueError,
      "expected a '[\"kind:name\", ...]' list literal, got: '" & raw & "'")
  let inner = t[1 ..< t.len - 1]
  var elem = ""
  var inQuote = false

  proc flushElem(items: var seq[string]) =
    let v = elem.strip()
    if v.len > 0:
      # Unquote: every element must be a double-quoted string for
      # explicit shape validation; a bare identifier is rejected
      # downstream by the empty-after-unquote / no-colon checks.
      if v.len >= 2 and v[0] == '"' and v[^1] == '"':
        items.add(v[1 ..< v.len - 1])
      else:
        items.add(v)
    elem = ""

  for c in inner:
    if c == '"':
      inQuote = not inQuote
      elem.add(c)
    elif c == ',' and not inQuote:
      flushElem(result)
    else:
      elem.add(c)
  flushElem(result)

proc parseDependsOnAttr*(profilePath: string; entry: IntentNode;
                        attr: IntentNode): seq[tuple[kind, name: string]] =
  ## Validate the shape of a `depends_on = ["kind:name", ...]`
  ## resource attribute and return the parsed dependency edges
  ## (M82 home-scope follow-up).
  ##
  ## Mirrors the system-scope `parseDependsOn` (in
  ## `libs/repro_infra/src/repro_infra/profile.nim`) shape rules:
  ##
  ##   * the RHS must be a `[...]` list literal of double-quoted
  ##     `"kind:name"` strings;
  ##   * each entry uses FIRST-COLON-SPLIT semantics — the substring
  ##     before the FIRST `:` is the dependency kind tag, everything
  ##     after is the dependency target name (which may itself
  ##     contain further colons);
  ##   * empty entries, entries without a `:`, entries with an empty
  ##     kind, or entries with an empty name are rejected with
  ##     `EUnstructured` naming the offending text.
  ##
  ## The kind tag is NOT validated against a closed allowed-set at
  ## parse time — the planner catches an unknown / mistyped kind
  ## downstream when no resource in the desired set satisfies the
  ## `(kind, name)` pair. This keeps the parser cross-scope
  ## (home-scope and a future system-scope home variant could share
  ## this proc without locking in a specific kind set).
  doAssert attr.kind == nkResourceAttr
  doAssert attr.resourceAttrKey == "depends_on"
  let line = attr.resourceAttrLine
  let entryAddress = entry.resourceAddress
  var items: seq[string]
  try:
    items = parseDependsOnListLiteral(attr.resourceAttrValueSource)
  except ValueError as e:
    raiseUnstructured(profilePath, line, 1,
      "'" & attr.resourceAttrValueSource & "'",
      "a `depends_on = [\"kind:name\", ...]` list literal (resource '" &
        entryAddress & "': " & e.msg & ")")
  for item in items:
    let t = item.strip()
    if t.len == 0:
      raiseUnstructured(profilePath, line, 1,
        "an empty entry in `depends_on`",
        "a non-empty 'kind:name' string in `depends_on` for resource '" &
          entryAddress & "'")
    let colon = t.find(':')
    if colon < 0:
      raiseUnstructured(profilePath, line, 1,
        "'" & t & "' in `depends_on`",
        "a 'kind:name' string with a ':' separator in `depends_on` " &
          "for resource '" & entryAddress & "'")
    let depKind = t[0 ..< colon].strip()
    let depName = t[colon + 1 .. ^1].strip()
    if depKind.len == 0:
      raiseUnstructured(profilePath, line, 1,
        "'" & t & "' (empty kind) in `depends_on`",
        "a non-empty kind before the ':' in `depends_on` for " &
          "resource '" & entryAddress & "'")
    if depName.len == 0:
      raiseUnstructured(profilePath, line, 1,
        "'" & t & "' (empty name) in `depends_on`",
        "a non-empty name after the ':' in `depends_on` for " &
          "resource '" & entryAddress & "'")
    result.add((kind: depKind, name: depName))

proc parseResourceEntry(ctx: ParseCtx; idx, entryIndent,
                        attrIndent: int): IntentNode =
  ## Parse a `<kind> <address>:` resource declaration and its
  ## `<key> = <value>` payload lines. An unrecognized kind or a
  ## malformed header is rejected with `EUnstructured` (NOT skipped).
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let body = trimmed[entryIndent .. ^1]
  if not body.endsWith(":"):
    raiseUnstructured(ctx.profilePath, idx + 1, entryIndent + 1,
      "'" & body & "'",
      "a `<kind> <address>:` resource header inside `resources:`")
  let inner = body[0 ..< body.len - 1].strip()
  # Split off the kind: it is the first whitespace-delimited token.
  var sp = 0
  while sp < inner.len and inner[sp] notin {' ', '\t'}:
    inc sp
  let kind = inner[0 ..< sp]
  let address = inner[sp .. ^1].strip()
  if kind.len == 0 or address.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, entryIndent + 1,
      "'" & inner & "'",
      "a `<kind> <address>:` resource header (kind + address)")
  if kind notin KnownResourceKinds:
    raiseUnstructured(ctx.profilePath, idx + 1, entryIndent + 1,
      "'" & kind & "' as a resource kind",
      "one of: " & KnownResourceKinds.join(", "))
  for c in address:
    if not (c.isAlphaAscii() or c.isDigit() or c in {'_', '-', '.'}):
      raiseUnstructured(ctx.profilePath, idx + 1, entryIndent + 1,
        "'" & address & "' as a resource address",
        "a stable id of letters, digits, `_`, `-`, `.`")
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, attrIndent)
  var attrs: seq[IntentNode]
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != attrIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "content at indent " & $attrIndent)
    attrs.add parseResourceAttr(ctx, i, attrIndent)
    inc i
  result = IntentNode(kind: nkResourceEntry,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: entryIndent, resourceKind: kind, resourceAddress: address,
    resourceHeaderLine: idx + 1, resourceAttrs: attrs)

proc parseResourceEntryLeaf(ctx: ParseCtx; idx, indent: int): IntentNode =
  parseResourceEntry(ctx, idx, indent, indent + ctx.indentStep)

const ResourceSection = GuardSection(name: "`resources:`",
  # The M78 text grammar accepted `if <pred>:` here; kept.
  allowIf: true, leaf: parseResourceEntryLeaf)

proc parseResourceChildren(ctx: ParseCtx; startIdx, endIdxExclusive,
                           childIndent: int): seq[IntentNode] =
  ## Parse lines [startIdx, endIdxExclusive) as children of a
  ## `resources:` block: `<kind> <address>:` resource entries or guard
  ## chains (`when` / `if` / `elif` / `else`) holding them.
  parseGuardedChildren(ctx, startIdx, endIdxExclusive, childIndent,
    ResourceSection)

proc parseResourcesBlock(ctx: ParseCtx; idx, parentIndent,
                         entryIndent: int): IntentNode =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  let entries =
    if endIdx >= idx + 1:
      parseResourceChildren(ctx, idx + 1, endIdx + 1, entryIndent)
    else:
      @[]
  result = IntentNode(kind: nkResourcesBlock,
    startLine: idx + 1, endLine: max(endIdx + 1, idx + 1),
    indent: parentIndent, resourcesHeaderLine: idx + 1,
    resourcesEntries: entries)

# ---------------------------------------------------------------------------
# adapterPreference block parsing (M2.5).
# ---------------------------------------------------------------------------
#
# Surface syntax:
#
#   adapterPreference:
#     windows: [scoop, tarball, path]
#     linux:   [nix, tarball, path]
#     darwin:  [nix, path]
#
# Per-OS keys with realization-kind lists: the profile's selection policy
# (GM4b). The OS keys are the closed set `KnownAdapterPreferenceOs`; entries
# are the closed set `KnownAdapterPreferenceAdapters`. Unknown OS keys or
# unknown kinds raise EUnstructured. An empty list (e.g. `windows: []`) is
# accepted; resolution uses the default selection policy for that OS when
# the seq is empty.

proc canonicalizeOsKey(rawOsKey: string): string =
  ## `macos` is an alias for `darwin`. Both canonicalize to `"darwin"`
  ## so resolve-time lookups use a single key.
  let lc = rawOsKey.toLowerAscii()
  if lc == "macos":
    "darwin"
  else:
    lc

proc parseAdapterChainList(ctx: ParseCtx; idx: int; rawList: string;
                           startCol: int): seq[string] =
  ## Parse a `[adapter, adapter, ...]` list inline on the OS-key line.
  ## The brackets are required. Whitespace around entries is stripped.
  let s = rawList.strip()
  if s.len < 2 or s[0] != '[' or s[^1] != ']':
    raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
      "'" & rawList & "'",
      "a `[adapter, ...]` chain list (e.g. `[scoop, builtin, path]`)")
  let inner = s[1 ..< s.len - 1].strip()
  if inner.len == 0:
    return @[]
  for piece in inner.split(","):
    let adapter = piece.strip()
    if adapter.len == 0:
      raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
        "an empty adapter name in '" & rawList & "'",
        "non-empty adapter identifiers (one of: " &
          KnownAdapterPreferenceAdapters.join(", ") & ")")
    for c in adapter:
      if not (c.isAlphaAscii() or c.isDigit() or c == '_'):
        raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
          "'" & adapter & "' inside the adapter chain",
          "an adapter identifier of letters, digits, and `_`")
    if adapter notin KnownAdapterPreferenceAdapters:
      raiseUnstructured(ctx.profilePath, idx + 1, startCol + 1,
        "'" & adapter & "' as an adapter name",
        "one of: " & KnownAdapterPreferenceAdapters.join(", "))
    result.add adapter

proc parseAdapterPreferenceEntry(ctx: ParseCtx; idx, entryIndent: int;
                                 outTable: var OrderedTable[string, seq[string]]) =
  ## Parse a single `<os>: [adapter, ...]` line inside the
  ## `adapterPreference:` block. The OS key is restricted to the closed
  ## set `KnownAdapterPreferenceOs`; unknown keys raise a structured
  ## parse error. `macos` is canonicalized to `darwin` so a profile
  ## that writes either alias survives the canonicalization once.
  let raw = ctx.lines[idx]
  let trimmed = stripInlineComment(raw).trimTrailing()
  let indent = countLeadingSpaces(trimmed)
  # Extract the OS key: scan for the first `:` separator.
  var i = indent
  while i < trimmed.len and (trimmed[i].isAlphaAscii() or
                             trimmed[i].isDigit() or trimmed[i] == '_'):
    inc i
  let osKey = trimmed[indent ..< i]
  if osKey.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & trimmed[indent .. ^1] & "'",
      "a `<os>: [adapter, ...]` entry inside `adapterPreference:`")
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  if i >= trimmed.len or trimmed[i] != ':':
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "missing `:` after OS key '" & osKey & "'",
      "a `:` separator before the adapter chain list")
  inc i
  while i < trimmed.len and trimmed[i] in {' ', '\t'}:
    inc i
  let rest = trimmed[i .. ^1]
  if rest.len == 0:
    raiseUnstructured(ctx.profilePath, idx + 1, i + 1,
      "missing chain list after '" & osKey & ":'",
      "a `[adapter, ...]` chain list (e.g. `[scoop, builtin, path]`)")
  let osKeyLc = osKey.toLowerAscii()
  if osKeyLc notin KnownAdapterPreferenceOs:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "'" & osKey & "' as an OS key inside `adapterPreference:`",
      "one of: " & KnownAdapterPreferenceOs.join(", "))
  let canonical = canonicalizeOsKey(osKey)
  if canonical in outTable:
    raiseUnstructured(ctx.profilePath, idx + 1, indent + 1,
      "a second `" & osKey & ":` entry in `adapterPreference:`",
      "exactly one entry per OS (note `macos` and `darwin` alias)")
  let adapters = parseAdapterChainList(ctx, idx, rest, i)
  outTable[canonical] = adapters

proc parseAdapterPreferenceBlock(ctx: ParseCtx; idx, entryIndent: int):
    OrderedTable[string, seq[string]] =
  ## Parse the body of an `adapterPreference:` block. Each child line
  ## must be a `<os>: [adapter, ...]` entry at `entryIndent`. Comments
  ## and blank lines are skipped.
  result = initOrderedTable[string, seq[string]]()
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
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
    parseAdapterPreferenceEntry(ctx, i, entryIndent, result)
    inc i

# ---------------------------------------------------------------------------
# data block parsing (GM4).
#
#   data:
#     "data/apps.toml"
#
# One string literal per line, each a plan-time data file relative to the
# profile directory -- the same shape the `profile` macro's `data:` section
# accepts, validated by the same rule (`dataFilePathProblem`).
# ---------------------------------------------------------------------------

proc parseDataBlock(ctx: ParseCtx; idx, entryIndent: int): seq[string] =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != entryIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "a data-file path at indent " & $entryIndent)
    let text = stripInlineComment(line).strip()
    if text.len < 2 or text[0] != '"' or text[^1] != '"' or
       text[1 ..< text.len - 1].contains('"'):
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & text & "' inside `data:`",
        "a quoted data-file path such as \"data/apps.toml\"")
    let path = text[1 ..< text.len - 1]
    let problem = dataFilePathProblem(path)
    if problem.len > 0:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "\"" & path & "\" inside `data:` (" & problem & ")",
        "a data-file path relative to the profile directory")
    if path in result:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "\"" & path & "\" declared twice", "each data file once")
    result.add path
    inc i

# ---------------------------------------------------------------------------
# catalogs block parsing.
#
#   catalogs:
#     "../reprobuild-scoop-packages/repro"
#
# One string literal per line, each the Nim module of a contribution
# catalog relative to the profile directory -- the shape the `profile`
# macro's `catalogs:` section accepts, validated by the same rule
# (`catalogImportPathProblem`).
# ---------------------------------------------------------------------------

proc parseCatalogsBlock(ctx: ParseCtx; idx, entryIndent: int): seq[string] =
  let endIdx = lastStructuralIdx(ctx.lines, idx + 1, entryIndent)
  var i = idx + 1
  while i <= endIdx:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    if ind != entryIndent:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & line.strip() & "' at indent " & $ind,
        "a catalog module path at indent " & $entryIndent)
    let text = stripInlineComment(line).strip()
    if text.len < 2 or text[0] != '"' or text[^1] != '"' or
       text[1 ..< text.len - 1].contains('"'):
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "'" & text & "' inside `catalogs:`",
        "a quoted catalog module path such as " &
        "\"../reprobuild-scoop-packages/repro\"")
    let path = text[1 ..< text.len - 1]
    let problem = catalogImportPathProblem(path)
    if problem.len > 0:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "\"" & path & "\" inside `catalogs:` (" & problem & ")",
        "a catalog module path relative to the profile directory")
    if path in result:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "\"" & path & "\" declared twice", "each catalog once")
    result.add path
    inc i

# ---------------------------------------------------------------------------
# Profile body.
# ---------------------------------------------------------------------------

proc parseProfileBody(ctx: ParseCtx; profileHeaderIdx: int;
                      outAdapterPreference: var OrderedTable[string, seq[string]];
                      outDataFiles: var seq[string];
                      outCatalogImports: var seq[string]):
    IntentNode =
  ## M2.5: also populates `outAdapterPreference` (empty table when no
  ## `adapterPreference:` block was present).
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
  var sawResources = false
  var sawAdapterPreference = false
  var sawData = false
  var sawCatalogs = false
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
        "one of `activity <name>:`, `config:`, `hosts:`, " &
        "`resources:`, `adapterPreference:`, `data:`, or `catalogs:`")
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
    of ResourcesHeader:
      if sawResources:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `resources:` block",
          "exactly one `resources:` block per profile")
      sawResources = true
      let blk = parseResourcesBlock(ctx, i, childIndent,
        childIndent + ctx.indentStep)
      result.children.add blk
      lastBodyIdx = blk.endLine - 1
      i = blk.endLine
    of AdapterPreferenceHeader:
      if sawAdapterPreference:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `adapterPreference:` block",
          "exactly one `adapterPreference:` block per profile")
      sawAdapterPreference = true
      let entryIndent = childIndent + ctx.indentStep
      outAdapterPreference = parseAdapterPreferenceBlock(ctx, i, entryIndent)
      let endIdx = lastStructuralIdx(ctx.lines, i + 1, entryIndent)
      lastBodyIdx = endIdx
      i = max(endIdx + 1, i + 1)
    of DataHeader:
      if sawData:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `data:` block",
          "exactly one `data:` block per profile")
      sawData = true
      let entryIndent = childIndent + ctx.indentStep
      outDataFiles = parseDataBlock(ctx, i, entryIndent)
      let endIdx = lastStructuralIdx(ctx.lines, i + 1, entryIndent)
      lastBodyIdx = endIdx
      i = max(endIdx + 1, i + 1)
    of CatalogsHeader:
      if sawCatalogs:
        raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
          "a second `catalogs:` block",
          "exactly one `catalogs:` block per profile")
      sawCatalogs = true
      let entryIndent = childIndent + ctx.indentStep
      outCatalogImports = parseCatalogsBlock(ctx, i, entryIndent)
      let endIdx = lastStructuralIdx(ctx.lines, i + 1, entryIndent)
      lastBodyIdx = endIdx
      i = max(endIdx + 1, i + 1)
    else:
      raiseUnstructured(ctx.profilePath, i + 1, ind + 1,
        "`" & hm.keyword & "` at the profile top level",
        "one of `activity <name>:`, `config:`, `hosts:`, " &
        "`resources:`, `adapterPreference:`, `data:`, or `catalogs:`")
  result.endLine = lastBodyIdx + 1

# ---------------------------------------------------------------------------
# Public entry points.
# ---------------------------------------------------------------------------

proc parseProfile*(profilePath, source: string; tolerant = false): Profile =
  ## Parse a profile source string. Raises `EUnstructured` if the
  ## source does not match the recognized shape. Comments and blank
  ## lines anywhere are preserved. `tolerant` is `inspectProfile`'s mode:
  ## the constructs a text reader cannot see into become `nkOpaque`
  ## extents instead of refusals (see `ParseCtx.tolerant`).
  let ending = lineEnding(source)
  let trailingNewline = source.endsWith(ending)
  let rawLines = splitKeepEmpty(source, ending)
  var ctx = ParseCtx(profilePath: profilePath, lines: rawLines, indentStep: 2,
    tolerant: tolerant)
  let headerLine = findProfileHeader(ctx)
  ctx.indentStep = detectIndentStep(ctx.lines, headerLine)
  var adapterPreference = initOrderedTable[string, seq[string]]()
  var dataFiles: seq[string]
  var catalogImports: seq[string]
  let root = parseProfileBody(ctx, headerLine - 1, adapterPreference,
    dataFiles, catalogImports)
  result = Profile(path: profilePath, lines: ctx.lines,
    lineEnding: ending, hasTrailingNewline: trailingNewline,
    root: root, indentStep: ctx.indentStep,
    adapterPreference: adapterPreference, dataFileRefs: dataFiles,
    catalogImports: catalogImports)

proc loadProfile*(profilePath: string): Profile =
  ## Read `profilePath` and parse it. `ENoProfile` and `EUnstructured`
  ## propagate to the caller. Every construct must be one the text reader
  ## can read: a helper call, an activity's `stow:` / `resources:` block or
  ## a statement before the `profile` header is refused. Callers that act on
  ## the whole profile from its text (the bundle builder, `repro home set` /
  ## `get`) use this; the structural edits use `inspectProfile`.
  let src = readFile(extendedPath(profilePath))
  result = parseProfile(profilePath, src)

proc inspectProfile*(profilePath: string): Profile =
  ## Read `profilePath` as the structural editor's inspector: like
  ## `loadProfile`, but the constructs only the compiled profile can
  ## evaluate -- helper calls (activity bodies, `config:`, `resources:`),
  ## an activity's `stow:` and `resources:` blocks, statements before the
  ## `profile` header -- are recorded as `nkOpaque` extents and stepped
  ## over (Home-Profile-Intent-Layer.md §Structural Edit Contract). An edit
  ## that would need to read inside one names it (`opaqueConstruct`).
  ## Everything else is refused exactly as `loadProfile` refuses it.
  let src = readFile(extendedPath(profilePath))
  result = parseProfile(profilePath, src, tolerant = true)

iterator opaqueNodes*(nodes: seq[IntentNode]): IntentNode =
  ## The `nkOpaque` extents among `nodes` and, recursively, inside their
  ## guard blocks.
  var stack = @[nodes]
  while stack.len > 0:
    let level = stack.pop()
    for n in level:
      case n.kind
      of nkOpaque: yield n
      of nkCondBlock: stack.add n.condChildren
      else: discard

proc inspectHostsBlock*(profilePath: string): Profile =
  ## Read only what `repro home enable` / `disable` edit: the `profile`
  ## header and its `hosts:` block. The returned profile's root has the
  ## parsed `hosts:` block as its only child (none when the profile has no
  ## `hosts:` block yet) and spans the whole profile body, so a block the
  ## editor creates goes at its end. Nothing else in the body is read: an
  ## activity, `config:` or `resources:` construct the inspector cannot read
  ## does not stop a `hosts:` edit, and keeps its bytes
  ## (Home-Profile-Intent-Layer.md §CLI Edit Semantics). A `hosts:` block
  ## the inspector cannot read, or a second one, is refused.
  let src = readFile(extendedPath(profilePath))
  let ending = lineEnding(src)
  var ctx = ParseCtx(profilePath: profilePath,
    lines: splitKeepEmpty(src, ending), indentStep: 2, tolerant: true)
  let headerLine = findProfileHeader(ctx)
  ctx.indentStep = detectIndentStep(ctx.lines, headerLine)
  let baseIndent = countLeadingSpaces(ctx.lines[headerLine - 1])
  let childIndent = baseIndent + ctx.indentStep
  var profileName = matchHeader(ctx.lines[headerLine - 1], ProfileHeader).rest
  if profileName.startsWith("\"") and profileName.endsWith("\""):
    profileName = profileName[1 ..< profileName.len - 1]
  let root = IntentNode(kind: nkProfileRoot, startLine: headerLine,
    indent: baseIndent, name: profileName, headerLine: headerLine)
  # The `profile` block is the last thing in the file (`parseProfileBody`
  # refuses anything after it), so every later line belongs to its body.
  var lastBodyIdx = headerLine - 1
  var sawHosts = false
  var i = headerLine
  while i < ctx.lines.len:
    let line = ctx.lines[i]
    if isBlankOrComment(line):
      inc i; continue
    let ind = countLeadingSpaces(line)
    lastBodyIdx = i
    if ind == childIndent and matchHeader(line, HostsHeader).matched and
       matchHeader(line, HostsHeader).rest.len == 0:
      if sawHosts:
        raiseUnstructured(profilePath, i + 1, ind + 1,
          "a second `hosts:` block",
          "exactly one `hosts:` block per profile")
      sawHosts = true
      let blk = parseHostsBlock(ctx, i, childIndent,
        childIndent + ctx.indentStep)
      root.children.add blk
      lastBodyIdx = max(lastBodyIdx, blk.endLine - 1)
      i = blk.endLine
      continue
    inc i
  root.endLine = lastBodyIdx + 1
  Profile(path: profilePath, lines: ctx.lines, lineEnding: ending,
    hasTrailingNewline: src.endsWith(ending), root: root,
    indentStep: ctx.indentStep)
