## The static `.nimble` reader (NPC-AREQ8 step 1).
##
## Reads the declarative subset of a `.nimble` file into a typed record and
## classifies the file:
##
## ===============  ========================================================
## class            meaning
## ===============  ========================================================
## plain            every field the version record needs is a string literal
##                  (or a `@[...]` of them, or a literal `toTable`) at top
##                  level
## closed-when      as plain, and some of those fields are inside `when`
##                  blocks whose conditions are in the closed set
## feature          as plain, with `feature "x":` or `dev:` blocks
## needs-override   a field is guarded by a condition outside the closed set,
##                  or a requirement Nimble accepts cannot be expressed in the
##                  solver's language: a person must supply the requirements
## needs-probe      a field is computed but host-independent (a non-literal
##                  value, a `requires` in a loop or routine, an `include` of
##                  a local file, a runtime `if`, the old INI format while it
##                  is not admitted): `nimble dump` would read it faithfully
## unreadable       the file is not valid Nim, or a requirement is one Nimble
##                  itself rejects
## ===============  ========================================================
##
## Only the first three are statically readable; for the other three the
## record carries the `unreadable` flag and is not offered to the solver until
## an override supplies its requirements or a probe reads them (§4.3 steps
## 2-4). Precedence when several apply: unreadable > needs-override >
## needs-probe > feature > closed-when > plain.
##
## **Nothing is evaluated.** The reader tokenizes and walks the statement
## structure (`syntax`). It does not run NimScript, does not start a process,
## does not read any file but the one it is given, and does not look at the
## bodies of `task`, `before` and `after`; their presence sets `has_tasks` /
## `has_hooks`. A condition outside the closed set is never assumed true or
## false: what it guards is kept, as written, in `undecided`.

{.push raises: [].}

import std/[parsecfg, sequtils, streams, strutils]

import ./lexer
import ./syntax
import ./conditions
import ./requirements

export conditions, requirements

type
  ReaderClass* = enum
    rcPlain = "plain"
    rcClosedWhen = "closed-when"
    rcFeature = "feature"
    rcNeedsOverride = "needs-override"
    rcNeedsProbe = "needs-probe"
    rcUnreadable = "unreadable"

  FileFormat* = enum
    ffNimScript = "nimscript"
    ffIni = "ini" ## the old `[Package]` / `[Deps]` format

  Field* = enum
    ## The fields whose value the version record needs (§4.2 `requires`,
    ## `layout` and `binaries`).
    fRequires = "requires"
    fVersion = "version"
    fSrcDir = "srcDir"
    fBinDir = "binDir"
    fBin = "bin"
    fNamedBin = "namedBin"
    fBackend = "backend"
    fInstallDirs = "installDirs"
    fInstallFiles = "installFiles"
    fInstallExt = "installExt"
    fSkipDirs = "skipDirs"
    fSkipFiles = "skipFiles"
    fSkipExt = "skipExt"
    fPaths = "paths"

  IssueKind* = enum
    ikParseError = "parse-error"
    ikMalformedRequirement = "malformed-requirement"
    ikUntranslatableRequirement = "untranslatable-requirement"
    ikConditionOutsideClosedSet = "fields-under-when"
    ikComputedRequires = "computed-requires"
    ikComputedValue = "computed-field"
    ikFieldsUnderIf = "fields-under-if"
    ikFieldsInControlFlow = "fields-in-control-flow"
    ikFieldsInRoutine = "fields-in-routine"
    ikFieldsInUnrecognisedStatement = "fields-in-unrecognised-statement"
    ikIncludeOfLocalFile = "include-local-file"
    ikIniFormat = "ini-format"

  Issue* = object
    ## One reason the file is outside the declarative subset.
    kind*: IssueKind
    fields*: set[Field] ## the record fields it affects
    detail*: string     ## what was found, with the input named
    line*: int

  Entry* = object
    ## One requirement entry `(condition, target, range, features)`.
    requirement*: Requirement
    condition*: Condition ## `nil`: unconditional
    line*: int

  Feature* = object
    name*: string
    rootOnly*: bool ## the `dev` feature: only for the package itself
    requires*: seq[Entry]

  TaskRequires* = object
    ## `taskRequires`: applies only to a package being developed.
    task*: string
    requires*: seq[Entry]

  ConditionalField* = object
    ## A layout or binary field set under a closed-set condition.
    field*: Field
    append*: bool
    values*: seq[string]
    pairs*: seq[(string, string)] ## for `namedBin`
    condition*: Condition
    line*: int

  ForeignDep* = object
    name*: string
    condition*: Condition

  Undecided* = object
    ## Something the reader found under a condition it cannot decide (or a
    ## runtime `if`). Kept as written for an override author; never offered
    ## to the solver.
    what*: string ## "requires", "taskRequires", "foreignDep" or a field
    text*: string ## the value as written
    condition*: string ## the guarding condition as written
    why*: UndecidableKind
    line*: int

  Flag* = enum
    flHasTasks = "has_tasks"
    flHasHooks = "has_hooks"
    flUnreadable = "unreadable"
    flTopLevelExec = "top-level-exec"
    flImportsLocalModule = "imports-local-module"

  NimbleFile* = object
    fileName*: string
    format*: FileFormat
    readerClass*: ReaderClass
    resolutionClass*: ReaderClass
      ## the class counting only what resolution and `--path` need
      ## (`requires`, the `nim` range, `srcDir`, `paths`)
    issues*: seq[Issue]
    packageName*, version*, author*, description*, license*: string
    srcDir*, binDir*, backend*: string
    bin*: seq[string]
    namedBin*: seq[(string, string)]
    installDirs*, installFiles*, installExt*: seq[string]
    skipDirs*, skipFiles*, skipExt*, paths*: seq[string]
    conditionalFields*: seq[ConditionalField]
    nim*: seq[Entry] ## `requires "nim ..."`, kept apart (toolchain)
    requires*: seq[Entry]
    features*: seq[Feature]
    taskRequires*: seq[TaskRequires]
    taskRequiresErrors*: seq[RequirementError]
    foreignDeps*: seq[ForeignDep]
    undecided*: seq[Undecided]
    flags*: set[Flag]
    hooks*: seq[string]
      ## the install hooks the file declares, as `before install` /
      ## `after install`, in file order and each once; their presence is
      ## `has_hooks`. The bodies are never read.

  ReaderOptions* = object
    admitIniFormat*: bool
      ## Read the old INI format as data. Off by default: the declarative
      ## subset as specified does not include it, so such a file is
      ## needs-probe. Turning it on is the whole change admitting it needs.

const
  ResolutionFields* = {fRequires, fSrcDir, fPaths}
  SeqFields = {fBin, fInstallDirs, fInstallFiles, fInstallExt, fSkipDirs,
               fSkipFiles, fSkipExt, fPaths}
  ScalarFields = {fVersion, fSrcDir, fBinDir, fBackend}
  InformationalFields = ["author", "description", "license", "packageName"]
  ExecCalls = ["exec", "staticExec", "gorge", "gorgeEx", "selfExec"]

proc rank(c: ReaderClass): int =
  case c
  of rcPlain: 0
  of rcClosedWhen: 1
  of rcFeature: 2
  of rcNeedsProbe: 3
  of rcNeedsOverride: 4
  of rcUnreadable: 5

proc issueClass(k: IssueKind): ReaderClass =
  case k
  of ikParseError, ikMalformedRequirement: rcUnreadable
  of ikUntranslatableRequirement, ikConditionOutsideClosedSet: rcNeedsOverride
  else: rcNeedsProbe

proc isStaticallyReadable*(f: NimbleFile): bool =
  f.readerClass in {rcPlain, rcClosedWhen, rcFeature}

proc fieldOf(name: string): (bool, Field) =
  for f in Field:
    if f != fRequires and nimIdentEq(name, $f):
      return (true, f)
  (false, fRequires)

# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

type
  Ctx = object
    condition: Condition ## conjunction of the enclosing closed conditions
    decided: bool        ## false under an undecidable condition or `if`
    why: UndecidableKind
    condText: string
    feature: int         ## index into `features`, or -1

  Walker = object
    tree: SyntaxTree
    file: NimbleFile
    sawClosedWhen: bool
    sawFeature: bool

proc issue(w: var Walker; kind: IssueKind; fields: set[Field]; detail: string;
           line: int) =
  w.file.issues.add Issue(kind: kind, fields: fields, detail: detail, line: line)

proc text(w: Walker; first, last: int): string = w.tree.sourceText(first, last)

proc fieldOfLoose(name: string): (bool, Field) =
  ## Like `fieldOf`, but ignoring the case of the first character too, so a
  ## look-alike such as `Requires` or `SrcDir` (another identifier to Nim,
  ## and an error at evaluation) is reported rather than silently skipped.
  for f in Field:
    if f != fRequires and styleKey(name) == styleKey($f):
      return (true, f)
  (false, fRequires)

proc mentionedFields(w: Walker; first, last: int): set[Field] =
  ## Does this token range call `requires` or assign / append to a record
  ## field? A purely lexical scan: it errs towards "yes".
  let toks = w.tree.tokens
  var parens = 0
  for i in first .. min(last, toks.len - 1):
    let t = toks[i]
    if t.kind == tkOpenParen:
      inc parens
    elif t.kind == tkCloseParen:
      dec parens
    if t.kind != tkIdent:
      continue
    if i > 0 and (toks[i - 1].isOp(".") or toks[i - 1].isKeyword("var") or
        toks[i - 1].isKeyword("let") or toks[i - 1].isKeyword("const")):
      continue
    if styleKey(t.text) == "requires":
      result.incl fRequires
      continue
    let (known, f) = fieldOfLoose(t.text)
    if not known or parens > 0:
      # Inside parentheses `srcDir = "x"` is a named argument or a parameter
      # default, not an assignment to the field.
      continue
    let n = if i + 1 < toks.len: toks[i + 1] else: Token(kind: tkEof)
    if n.kind == tkOperator and n.text in ["=", "&=", "+="]:
      result.incl f
    elif n.isOp(".") and i + 2 < toks.len and toks[i + 2].kind == tkIdent and
        nimIdentEq(toks[i + 2].text, "add"):
      result.incl f
    elif n.kind == tkOpenBracket:
      var depth = 0
      var j = i + 1
      while j <= last and j < toks.len:
        if toks[j].kind == tkOpenBracket: inc depth
        elif toks[j].kind == tkCloseBracket:
          dec depth
          if depth == 0: break
        inc j
      if j + 1 < toks.len and toks[j + 1].isOp("="):
        result.incl f

proc literalStrings(e: Expr; ok: var bool): seq[string] =
  ## A string literal or `@[...]` / `[...]` of string literals.
  case e.kind
  of ekString:
    result.add e.text
  of ekPrefix:
    if e.text == "@" and e.kids.len == 1 and e.kids[0].kind == ekBracket:
      result = literalStrings(e.kids[0], ok)
    else:
      ok = false
  of ekBracket:
    for k in e.kids:
      if k.kind == ekString:
        result.add k.text
      else:
        ok = false
  else:
    ok = false

proc seqLiteral(e: Expr; ok: var bool): seq[string] =
  ## `@["a", "b"]` exactly: the only literal a `seq[string]` field takes.
  if e.kind == ekPrefix and e.text == "@" and e.kids.len == 1 and
      e.kids[0].kind == ekBracket:
    for k in e.kids[0].kids:
      if k.kind == ekString:
        result.add k.text
      else:
        ok = false
  else:
    ok = false

proc tableLiteral(e: Expr; ok: var bool): seq[(string, string)] =
  ## `{"a": "b"}.toTable`, `{...}.toTable()`, `toTable({...})`,
  ## `toTable {...}`, and the `toOrderedTable` spellings.
  var curly: Expr = nil
  proc isTableName(x: Expr): bool =
    x.kind == ekIdent and (nimIdentEq(x.text, "toTable") or
                           nimIdentEq(x.text, "toOrderedTable"))
  case e.kind
  of ekDot:
    if isTableName(e.kids[1]): curly = e.kids[0]
  of ekCall, ekCommand:
    if e.kids.len == 1 and e.kids[0].kind == ekDot and isTableName(e.kids[
        0].kids[1]):
      curly = e.kids[0].kids[0]
    elif e.kids.len == 2 and isTableName(e.kids[0]):
      curly = e.kids[1]
  else:
    discard
  if curly.isNil or curly.kind != ekCurly:
    ok = false
    return
  for pair in curly.kids:
    if pair.kind == ekColon and pair.kids[0].kind == ekString and
        pair.kids[1].kind == ekString:
      result.add (pair.kids[0].text, pair.kids[1].text)
    else:
      ok = false

proc undecided(w: var Walker; ctx: Ctx; what, text: string; line: int) =
  w.file.undecided.add Undecided(what: what, text: text, condition: ctx.condText,
                                 why: ctx.why, line: line)

proc addRequirementStrings(w: var Walker; ctx: Ctx; values: seq[string];
                           line: int) =
  for v in values:
    let reading = readRequirements(v)
    for e in reading.errors:
      let kind = if e.kind == reMalformed: ikMalformedRequirement
                 else: ikUntranslatableRequirement
      w.issue(kind, {fRequires}, "'" & e.input & "': " & e.reason, line)
    for r in reading.requirements:
      if not ctx.decided:
        w.undecided(ctx, "requires", r.source, line)
        continue
      let entry = Entry(requirement: r, condition: ctx.condition, line: line)
      if ctx.feature >= 0:
        w.file.features[ctx.feature].requires.add entry
      elif r.isNimTarget:
        w.file.nim.add entry
      else:
        w.file.requires.add entry

proc handleRequires(w: var Walker; s: Stmt; args: seq[Expr]; ctx: Ctx) =
  var ok = true
  var values: seq[string]
  var all = args
  if s.hasBlock:
    # `requires: "x"` passes the block's single expression as the argument;
    # a block of several statements is not a value.
    if s.body.len == 1 and s.body[0].kind == skExpr and not s.body[0].hasBlock:
      all.add w.tree.headExpr(s.body[0])
    else:
      ok = false
  for a in all:
    values.add literalStrings(a, ok)
  if not ok or all.len == 0:
    w.issue(ikComputedRequires, {fRequires},
            "requires " & w.text(s.headFirst + 1, s.last), s.line)
    return
  w.addRequirementStrings(ctx, values, s.line)

proc handleTaskRequires(w: var Walker; s: Stmt; args: seq[Expr]; ctx: Ctx) =
  ## Recorded for develop mode; never a record field, so it does not change
  ## the class (NPC-AREQ7).
  if args.len < 1 or args[0].kind != ekString:
    return
  var ok = true
  var values: seq[string]
  for a in args[1 .. ^1]:
    values.add literalStrings(a, ok)
  if not ok:
    return
  if not ctx.decided:
    for v in values:
      w.undecided(ctx, "taskRequires", v, s.line)
    return
  let task = args[0].text
  var idx = -1
  for i, t in w.file.taskRequires:
    if t.task == task:
      idx = i
  if idx < 0:
    w.file.taskRequires.add TaskRequires(task: task)
    idx = w.file.taskRequires.high
  for v in values:
    let reading = readRequirements(v)
    w.file.taskRequiresErrors.add reading.errors
    for r in reading.requirements:
      w.file.taskRequires[idx].requires.add Entry(requirement: r,
        condition: ctx.condition, line: s.line)

proc applyField(w: var Walker; ctx: Ctx; f: Field; append: bool;
                values: seq[string]; pairs: seq[(string, string)];
                written: string; line: int) =
  if not ctx.decided:
    w.undecided(ctx, $f, written, line)
    return
  if not ctx.condition.isNil:
    w.file.conditionalFields.add ConditionalField(field: f, append: append,
      values: values, pairs: pairs, condition: ctx.condition, line: line)
    return
  template setSeq(target: untyped) =
    if append: target.add values else: target = values
  case f
  of fVersion: w.file.version = values[0]
  of fSrcDir: w.file.srcDir = values[0]
  of fBinDir: w.file.binDir = values[0]
  of fBackend: w.file.backend = values[0]
  of fBin: setSeq(w.file.bin)
  of fInstallDirs: setSeq(w.file.installDirs)
  of fInstallFiles: setSeq(w.file.installFiles)
  of fInstallExt: setSeq(w.file.installExt)
  of fSkipDirs: setSeq(w.file.skipDirs)
  of fSkipFiles: setSeq(w.file.skipFiles)
  of fSkipExt: setSeq(w.file.skipExt)
  of fPaths: setSeq(w.file.paths)
  of fNamedBin:
    if append: w.file.namedBin.add pairs else: w.file.namedBin = pairs
  of fRequires: discard

proc handleAssignment(w: var Walker; s: Stmt; opIdx: int; ctx: Ctx) =
  let toks = w.tree.tokens
  let op = toks[opIdx].text
  let rhs = w.tree.parseExprRange(opIdx + 1, s.headLast)
  let written = w.text(opIdx + 1, s.headLast)
  let lhs = w.tree.parseExprRange(s.headFirst, opIdx - 1)
  var name = ""
  var indexKey: Expr = nil
  if lhs.kind == ekIdent:
    name = lhs.text
  elif lhs.kind == ekIndex and lhs.kids.len == 2 and lhs.kids[0].kind == ekIdent:
    name = lhs.kids[0].text
    indexKey = lhs.kids[1]
  else:
    let m = w.mentionedFields(s.headFirst, opIdx - 1)
    if m != {}:
      w.issue(ikFieldsInUnrecognisedStatement, m, w.text(s.first, s.last), s.line)
    return
  if indexKey.isNil:
    for info in InformationalFields:
      if nimIdentEq(name, info):
        if op == "=" and rhs.kind == ekString:
          case info
          of "author": w.file.author = rhs.text
          of "description": w.file.description = rhs.text
          of "license": w.file.license = rhs.text
          of "packageName": w.file.packageName = rhs.text
          else: discard
        return
  let (known, f) = fieldOf(name)
  if not known:
    let (lookalike, lf) = fieldOfLoose(name)
    if lookalike:
      w.issue(ikFieldsInUnrecognisedStatement, {lf}, w.text(s.first, s.last),
              s.line)
    return
  var ok = true
  if not indexKey.isNil:
    # `namedBin["src"] = "name"`
    if f == fNamedBin and op == "=" and indexKey.kind == ekString and
        rhs.kind == ekString:
      w.applyField(ctx, f, true, @[], @[(indexKey.text, rhs.text)], written, s.line)
    else:
      w.issue(ikComputedValue, {f}, $f & "[...] " & op & " " & written, s.line)
    return
  if f in ScalarFields:
    if op == "=" and rhs.kind == ekString:
      w.applyField(ctx, f, false, @[rhs.text], @[], written, s.line)
      return
  elif f in SeqFields:
    if op == "=":
      let values = seqLiteral(rhs, ok)
      if ok:
        w.applyField(ctx, f, false, values, @[], written, s.line)
        return
    elif op == "&=":
      let values = literalStrings(rhs, ok)
      if ok:
        w.applyField(ctx, f, true, values, @[], written, s.line)
        return
  elif f == fNamedBin and op == "=":
    let pairs = tableLiteral(rhs, ok)
    if ok:
      w.applyField(ctx, f, false, @[], pairs, written, s.line)
      return
  w.issue(ikComputedValue, {f}, $f & " " & op & " " & written, s.line)

proc handleAppend(w: var Walker; s: Stmt; f: Field; args: seq[Expr]; ctx: Ctx) =
  var ok = args.len == 1 and f in SeqFields
  var values: seq[string]
  if ok:
    values = literalStrings(args[0], ok)
  if ok:
    w.applyField(ctx, f, true, values, @[], w.text(s.headFirst, s.headLast), s.line)
  else:
    w.issue(ikComputedValue, {f}, w.text(s.headFirst, s.last), s.line)

proc walk(w: var Walker; stmts: seq[Stmt]; ctx: Ctx)

proc handleConditional(w: var Walker; s: Stmt; ctx: Ctx; isIf: bool) =
  # An `else` (or a later `elif`) is guarded by the negation of every earlier
  # condition, so once one condition is undecidable every later branch is.
  var guard: Condition = nil
  var guardDecidable = true
  var guardWhy = ukOther
  var guardText = ""
  for br in s.branches:
    var branchCond: Condition = nil
    var decidable = guardDecidable
    var why = guardWhy
    var condText = guardText
    if br.isElse:
      branchCond = guard
      if condText.len == 0:
        condText = "else"
      else:
        condText = "else of " & condText
    else:
      let written = w.text(br.condFirst, br.condLast)
      let reading = readCondition(w.tree.condExpr(br))
      if reading.decidable and guardDecidable:
        branchCond = conjoin(guard, reading.condition)
        guard = conjoin(guard, negate(reading.condition))
      else:
        decidable = false
        if not reading.decidable:
          why = reading.why
          condText = written
          if guardDecidable:
            guardWhy = reading.why
            guardText = written
        guardDecidable = false
    let bodyFirst = if br.body.len > 0: br.body[0].first else: 0
    let bodyLast = if br.body.len > 0: br.body[^1].last else: -1
    let fields = w.mentionedFields(bodyFirst, bodyLast)
    if fields != {} and ctx.decided:
      if not decidable:
        w.issue(ikConditionOutsideClosedSet, fields,
                $why & ": " & condText, s.line)
      if isIf:
        w.issue(ikFieldsUnderIf, fields, "if " & condText, s.line)
      elif decidable:
        w.sawClosedWhen = true
    var inner = ctx
    if ctx.decided:
      inner.condition = conjoin(ctx.condition, branchCond)
      if not decidable or isIf:
        inner.decided = false
        inner.why = if decidable: ukRuntimeIf else: why
        inner.condText = (if isIf: "if " else: "") &
          (if decidable and not br.isElse: w.text(br.condFirst, br.condLast)
            else: condText)
    w.walk(br.body, inner)

proc handleOpaque(w: var Walker; s: Stmt) =
  let toks = w.tree.tokens
  case s.keyword
  of "include":
    # Any include that is not of the standard library may call `requires`.
    var path = ""
    for i in s.headFirst + 1 .. s.last + 1:
      let t = if i <= s.last: toks[i] else: Token(kind: tkComma)
      if t.kind == tkComma:
        if path.len > 0 and not (path == "std" or path.startsWith("std/")):
          w.issue(ikIncludeOfLocalFile, {fRequires},
                  "include " & w.text(s.headFirst + 1, s.last), s.line)
          return
        path = ""
      elif t.kind == tkString:
        path.add t.value
      else:
        path.add t.text
  of "import", "from":
    for i in s.headFirst + 1 .. s.headLast:
      let t = toks[i]
      if t.kind == tkString or (t.isOp(".") and i + 1 <= s.headLast and
          toks[i + 1].isOp("/")) or t.isOp("./") or t.isOp("../"):
        w.file.flags.incl flImportsLocalModule
  of "const", "let", "var", "type", "export", "using", "mixin", "bind":
    discard
  else:
    let fields = w.mentionedFields(s.first, s.last)
    if fields != {}:
      let kind = if s.keyword in ["proc", "func", "template", "macro",
                                  "iterator", "method", "converter"]:
                   ikFieldsInRoutine
                 else: ikFieldsInControlFlow
      w.issue(kind, fields, s.keyword & " at line " & $s.line, s.line)

proc depth0Assignment(w: Walker; s: Stmt): int =
  var depth = 0
  for i in s.headFirst .. s.headLast:
    let t = w.tree.tokens[i]
    case t.kind
    of tkOpenParen, tkOpenBracket, tkOpenCurly: inc depth
    of tkCloseParen, tkCloseBracket, tkCloseCurly: dec depth
    of tkOperator:
      if depth == 0 and i > s.headFirst and (t.text == "=" or
          (t.text.len >= 2 and t.text[^1] == '=' and
           t.text[0] notin {'<', '>', '!', '=', '~', '^'})):
        return i
    else: discard
  -1

proc handleExpr(w: var Walker; s: Stmt; ctx: Ctx) =
  let opIdx = w.depth0Assignment(s)
  if opIdx >= 0 and not s.hasBlock:
    w.handleAssignment(s, opIdx, ctx)
    return
  let e = w.tree.headExpr(s)
  var callee: Expr = nil
  var args: seq[Expr]
  case e.kind
  of ekCall, ekCommand:
    callee = e.kids[0]
    args = e.kids[1 .. ^1]
  of ekIdent:
    callee = e
  else:
    discard
  if not callee.isNil and callee.kind == ekIdent:
    let name = callee.text
    if nimIdentEq(name, "requires"):
      w.handleRequires(s, args, ctx)
      return
    if nimIdentEq(name, "taskRequires"):
      w.handleTaskRequires(s, args, ctx)
      return
    if nimIdentEq(name, "foreignDep"):
      if args.len == 1 and args[0].kind == ekString:
        if ctx.decided:
          w.file.foreignDeps.add ForeignDep(name: args[0].text,
                                            condition: ctx.condition)
        else:
          w.undecided(ctx, "foreignDep", args[0].text, s.line)
      return
    if nimIdentEq(name, "task"):
      # The body is never read.
      w.file.flags.incl flHasTasks
      return
    if nimIdentEq(name, "before") or nimIdentEq(name, "after"):
      if args.len >= 1 and args[0].kind == ekIdent and
          nimIdentEq(args[0].text, "install"):
        w.file.flags.incl flHasHooks
        let hook = (if nimIdentEq(name, "before"): "before" else: "after") &
          " install"
        if hook notin w.file.hooks: w.file.hooks.add hook
      else:
        w.file.flags.incl flHasTasks
      return
    if s.hasBlock and (nimIdentEq(name, "feature") or nimIdentEq(name, "dev")):
      var fname = ""
      if nimIdentEq(name, "dev") and args.len == 0:
        fname = "dev"
      elif nimIdentEq(name, "feature") and args.len == 1 and
          args[0].kind == ekString:
        fname = args[0].text
      if fname.len > 0:
        w.sawFeature = true
        # Like Nimble's declarative parser, a later block of the same name
        # replaces an earlier one.
        var idx = -1
        for i, f in w.file.features:
          if f.name == fname:
            idx = i
        if idx < 0:
          w.file.features.add Feature(name: fname, rootOnly: fname == "dev")
          idx = w.file.features.high
        else:
          w.file.features[idx].requires = @[]
        var inner = ctx
        inner.feature = idx
        w.walk(s.body, inner)
        return
    for x in ExecCalls:
      if nimIdentEq(name, x):
        w.file.flags.incl flTopLevelExec
        return
    if nimIdentEq(name, "add") and args.len == 2 and args[0].kind == ekIdent:
      let (known, f) = fieldOf(args[0].text)
      if known:
        w.handleAppend(s, f, args[1 .. ^1], ctx)
        return
  if not callee.isNil and callee.kind == ekDot and
      callee.kids[0].kind == ekIdent and nimIdentEq(callee.kids[1].text, "add"):
    let (known, f) = fieldOf(callee.kids[0].text)
    if known:
      w.handleAppend(s, f, args, ctx)
      return
  let fields = w.mentionedFields(s.first, s.last)
  if fields != {}:
    w.issue(ikFieldsInUnrecognisedStatement, fields, w.text(s.first, s.last),
            s.line)

proc walk(w: var Walker; stmts: seq[Stmt]; ctx: Ctx) =
  for s in stmts:
    case s.kind
    of skWhen: w.handleConditional(s, ctx, isIf = false)
    of skIf: w.handleConditional(s, ctx, isIf = true)
    of skOpaque: w.handleOpaque(s)
    of skExpr: w.handleExpr(s, ctx)

# ---------------------------------------------------------------------------
# The old INI format
# ---------------------------------------------------------------------------

proc looksLikeIni(src: string): bool =
  ## Nimble tries the INI format first; a NimScript file never starts with a
  ## section header, so the first significant line decides.
  for raw in src.splitLines:
    let l = raw.strip
    if l.len == 0 or l.startsWith("#") or l.startsWith(";"):
      continue
    return l.startsWith("[")
  false

proc readIni(w: var Walker; src: string) =
  ## Nimble 0.20.1 `packageparser.readPackageInfoFromNimble`: sections
  ## `[Package]` and `[Deps]`/`[Dependencies]`, list values split on commas
  ## and line breaks, and an error for any other section or key.
  w.file.format = ffIni
  let ctx = Ctx(decided: true, feature: -1)
  var section = ""
  var tasks: seq[string]
  try:
    var p: CfgParser
    open(p, newStringStream(src), w.file.fileName)
    defer: close(p)
    while true:
      let ev = next(p)
      case ev.kind
      of cfgEof:
        break
      of cfgSectionStart:
        section = ev.section
      of cfgKeyValuePair:
        let key = normalize(ev.key)
        case normalize(section)
        of "package":
          case key
          of "name": w.file.packageName = ev.value
          of "version": w.file.version = ev.value
          of "author": w.file.author = ev.value
          of "description": w.file.description = ev.value
          of "license": w.file.license = ev.value
          of "srcdir": w.file.srcDir = ev.value
          of "bindir": w.file.binDir = ev.value
          of "backend": w.file.backend = ev.value.toLowerAscii
          of "skipdirs": w.file.skipDirs.add splitList(ev.value)
          of "skipfiles": w.file.skipFiles.add splitList(ev.value)
          of "skipext": w.file.skipExt.add splitList(ev.value)
          of "installdirs": w.file.installDirs.add splitList(ev.value)
          of "installfiles": w.file.installFiles.add splitList(ev.value)
          of "installext": w.file.installExt.add splitList(ev.value)
          of "paths": w.file.paths.add splitList(ev.value)
          of "bin":
            for item in splitList(ev.value):
              let parts = item.split('=', 1)
              if parts[0].endsWith(".nim"):
                w.issue(ikParseError, {}, "ini: `bin` entry is a source file: " &
                        parts[0], 0)
              elif parts.len == 2:
                w.file.namedBin.add (parts[0], parts[1])
              else:
                w.file.bin.add item
          of "nimbletasks":
            for t in splitList(ev.value):
              tasks.add normalize(t)
              w.file.flags.incl flHasTasks
          of "beforehooks", "afterhooks":
            for t in splitList(ev.value):
              if normalize(t) == "install":
                w.file.flags.incl flHasHooks
                let hook = (if normalize(ev.key) == "beforehooks": "before"
                            else: "after") & " install"
                if hook notin w.file.hooks: w.file.hooks.add hook
              else: w.file.flags.incl flHasTasks
          of "entrypoints", "testentrypoint":
            discard
          else:
            w.issue(ikParseError, {}, "ini: invalid field '" & ev.key & "'", 0)
        of "deps", "dependencies":
          if key == "requires":
            w.addRequirementStrings(ctx, @[ev.value], 0)
          elif key.endsWith("requires"):
            let task = key[0 ..< key.len - "requires".len]
            if task notin tasks and task != "test":
              w.issue(ikParseError, {}, "ini: no task '" & task & "' for " &
                      ev.key, 0)
            else:
              var entries: seq[Entry]
              let reading = readRequirements(ev.value)
              w.file.taskRequiresErrors.add reading.errors
              for r in reading.requirements:
                entries.add Entry(requirement: r)
              w.file.taskRequires.add TaskRequires(task: task,
                  requires: entries)
          else:
            w.issue(ikParseError, {}, "ini: invalid field '" & ev.key & "'", 0)
        else:
          w.issue(ikParseError, {}, "ini: invalid section '" & section & "'", 0)
      of cfgOption:
        w.issue(ikParseError, {}, "ini: options are not allowed: --" & ev.key, 0)
      of cfgError:
        w.issue(ikParseError, {}, "ini: " & ev.msg, 0)
  except CatchableError as e:
    w.issue(ikParseError, {}, "ini: " & e.msg, 0)
  except Defect as d:
    raise d # a bug, not a parse error; re-raised by name (see below)
  except Exception as e:
    # Nim 2.2.4's `std/streams` declares its implementation callbacks without
    # a `raises` list, so every `CfgParser` call is typed as raising bare
    # `Exception`, which `{.push raises: [].}` refuses. Such an exception
    # reports the file as unparseable, like any other parser failure. A
    # `Defect` is let through above, and by name: a bare `raise` is itself
    # typed `Exception` there.
    w.issue(ikParseError, {}, "ini: " & e.msg, 0)

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

proc classify(w: var Walker) =
  var cls = rcPlain
  var res = rcPlain
  if w.sawClosedWhen:
    cls = rcClosedWhen
    res = rcClosedWhen
  if w.sawFeature:
    cls = rcFeature
    res = rcFeature
  for i in w.file.issues:
    let c = issueClass(i.kind)
    if rank(c) > rank(cls):
      cls = c
    if (i.fields == {} or (i.fields * ResolutionFields) != {}) and
        rank(c) > rank(res):
      res = c
  w.file.readerClass = cls
  w.file.resolutionClass = res
  if cls notin {rcPlain, rcClosedWhen, rcFeature}:
    w.file.flags.incl flUnreadable

proc readNimbleSource*(src: string; fileName = "";
                       options = ReaderOptions()): NimbleFile =
  ## Read the text of a `.nimble` file. Never raises, never evaluates.
  var w = Walker(file: NimbleFile(fileName: fileName))
  if looksLikeIni(src):
    w.readIni(src)
    if not options.admitIniFormat and
        not w.file.issues.anyIt(it.kind == ikParseError):
      w.issue(ikIniFormat, {fRequires}, "the old INI format is not in the " &
              "declarative subset", 0)
    w.classify()
    return w.file
  w.tree = parseNim(src)
  for e in w.tree.errors:
    w.issue(ikParseError, {}, e.message, e.line)
  if w.tree.errors.len == 0:
    w.walk(w.tree.stmts, Ctx(decided: true, feature: -1))
  w.classify()
  w.file
