## Declared lock-file names, their doc comments, and the two diagnostics.
##
## Named-Lock-Files NLF-M7, design §4.2 / §4.8 / §4.9 / §5.3.
##
## Three concepts stay separable here exactly as §3 requires: a **name** is a
## declared symbol (this module), a **file** is a solved graph on disk
## (`repro_lock`), and a **binding** is the assignment of one to the other for
## one invocation (`binding.nim`). Nothing below ever composes a name with an
## identity — §6.2 forbids the name from entering any key, and the way that is
## kept true is that this module has no identity type in it at all.
##
## ## Why a leaf with no dependencies
##
## The declaration registry is read at four layers that do not otherwise share
## a library: the project DSL's macros (artifact designation), the stdlib's
## build context (the fifth slot), the CLI (`--lock`, `repro lock list`), and
## the lock-generation path (one solve per lock file). A leaf importing only
## `std` is the only shape all four can take a dependency on.
##
## ## Test-double policy
##
## This module contains no doubles and no test-only branches. The doc-comment
## attachment below is the real attachment used by the `lockFile` macro; the
## diagnostics are the real strings the compiler and the CLI print.

import std/[algorithm, strutils, tables]

const
  DefaultLockFileName* = "default"
    ## §3.1 — the well-known lock file the stdlib declares. "A workspace that
    ## declares nothing, binds nothing, and passes nothing gets precisely the
    ## behaviour specified in §2.1."
  HostToolsLockFileName* = "hostTools"
    ## §4.8 "Library portability" — the second well-known name, so a library
    ## that references it compiles in a workspace that did not declare it.
    ## §4.8 records the well-known set as an open question (Q-3) precisely
    ## because it is a compatibility surface; it is kept to these two.

type
  LockFileDecl* = object
    ## One declared lock file. Mirrors `VariantDecl`'s description /
    ## sourceFile / sourceLine triple deliberately — §4.2 requires the
    ## `lockFile` declaration to follow the existing comment-attachment
    ## contract "rather than a parallel one", and storing the same fields is
    ## the visible half of following it.
    name*: string
    path*: string
      ## The committed binding from `path = "…"`, or `""` for an unbound
      ## declaration (§5.3 case 2).
    description*: string
      ## The attached doc comment with `@directive` lines removed, as
      ## `parseDocComment` returns it.
    sourceFile*: string
    sourceLine*: int
    sourceColumn*: int
      ## Comment-Attachment rule 6: the position is the **first `##` line of
      ## the run and its column**, not the declaration's line with column 0.
      ## §4.2 singles this out as "the rule most easily got wrong — the
      ## existing variant path emits `descriptionColumn = 0` and the
      ## declaration's line rather than the comment run's".
    predeclared*: bool
      ## True for the stdlib's well-known names. Reported as
      ## `(stdlib, predeclared)` in the §4.9 in-scope listing.
    ownerPackage*: string
      ## Non-empty when the declaration is PRIVATE to a package (§4.8's
      ## opt-in escape hatch). A private lock file does not unify with a
      ## same-named one elsewhere.

  LockFileError* = object of CatchableError
    ## Raised for a duplicate declaration and for a binding of an undeclared
    ## name. Both are errors rather than last-wins, per §4.2 reason 2 and
    ## §5.1's closing paragraph.

proc predeclaredLockFiles*(): seq[LockFileDecl] =
  ## The well-known set, in the order the §4.9 diagnostic prints it.
  @[
    LockFileDecl(name: DefaultLockFileName, predeclared: true,
      description: "The workspace lock file. Everything that does not say " &
        "otherwise resolves here."),
    LockFileDecl(name: HostToolsLockFileName, predeclared: true,
      description: "Tools that run on the build machine: code generators, " &
        "compilers, anything whose output is consumed during the build " &
        "rather than shipped.")]

var declared: seq[LockFileDecl] = predeclaredLockFiles()

proc resetLockFileDeclarations*() =
  ## Drop every workspace declaration, leaving the well-known set. Called
  ## between test scenarios; nothing on a build path calls it.
  declared = predeclaredLockFiles()

proc lockFileDeclarations*(): seq[LockFileDecl] =
  ## Every declared lock file, well-known first then in declaration order.
  declared

proc findLockFile*(name: string; ownerPackage = ""): int =
  ## Index of `name` in the registry, or `-1`. A private declaration matches
  ## only its owning package (§4.8): "a privately declared lock file does not
  ## unify with a same-named lock file elsewhere".
  for i, d in declared:
    if d.name != name: continue
    if d.ownerPackage.len == 0 or d.ownerPackage == ownerPackage:
      return i
  -1

proc isDeclaredLockFile*(name: string; ownerPackage = ""): bool =
  findLockFile(name, ownerPackage) >= 0

proc originOf*(d: LockFileDecl): string =
  ## What the §4.9 listing prints in parentheses after a name.
  if d.predeclared:
    "stdlib, predeclared"
  elif d.sourceFile.len == 0:
    "declared"
  else:
    d.sourceFile & ":" & $d.sourceLine

proc declareLockFile*(name: string; path = ""; description = "";
                      sourceFile = ""; sourceLine = 0; sourceColumn = 0;
                      ownerPackage = ""): string {.discardable.} =
  ## Register a declaration and return the name, so the generated
  ## `let hostTools* = declareLockFile("hostTools", …)` binds a symbol whose
  ## VALUE is the name. That is what makes `lockFile = hostTools` (§4.5) a
  ## plain expression and a typo an undeclared-identifier error from Nim
  ## itself before the richer §4.9 diagnostic ever has to fire.
  ##
  ## A duplicate is an error, not a merge. §4.2: "Two build blocks declaring
  ## `hostTools` has no sensible reading. Is that one lock file mentioned
  ## twice, or a conflict? Both answers are defensible, which is the
  ## problem."
  ##
  ## Re-declaring a well-known name with no new information is the one
  ## exception and is not a duplicate: §4.2 makes `default` "a declarable
  ## symbol, predeclared by the stdlib but writable explicitly at any
  ## designation site", so `lockFile default, path = "locks/aarch64.lock"`
  ## (the §4.10 retargeting spelling) must be accepted and must UPDATE the
  ## predeclared entry rather than collide with it.
  let existing = findLockFile(name, ownerPackage)
  if existing >= 0:
    if not declared[existing].predeclared:
      raise newException(LockFileError,
        "duplicate lock file declaration `" & name & "`\n" &
        "  already declared at " & originOf(declared[existing]))
    declared[existing].path = path
    if description.len > 0:
      declared[existing].description = description
      declared[existing].sourceFile = sourceFile
      declared[existing].sourceLine = sourceLine
      declared[existing].sourceColumn = sourceColumn
    return name
  declared.add(LockFileDecl(
    name: name, path: path, description: description,
    sourceFile: sourceFile, sourceLine: sourceLine,
    sourceColumn: sourceColumn, ownerPackage: ownerPackage))
  name

# ---------------------------------------------------------------------------
# §4.2 — doc-comment attachment
# ---------------------------------------------------------------------------

type
  AttachedDoc* = object
    ## The result of running the Comment-Attachment rules over a run of
    ## source lines that ENDS at a declaration.
    text*: string
      ## The raw joined comment body, `##` markers stripped, newline-joined.
      ## Directive extraction is NOT done here — that is `parseDocComment`'s
      ## job and §4.2 requires the canonical parser be the one that does it.
      ## Splitting the two is what lets NLF-DOC-5 catch a hand-rolled scanner:
      ## a scanner that also parsed directives would not need the canonical
      ## parser at all.
    line*: int
      ## 1-based line of the FIRST `##` line of the attaching run.
    column*: int
      ## 1-based column of that line's `#`.

proc attachLeadDoc*(lines: openArray[string]; declLineIndex: int): AttachedDoc =
  ## Comment-Attachment, applied upward from the declaration at
  ## `declLineIndex` (0-based into `lines`).
  ##
  ## The four rules NLF-DOC-3 and NLF-DOC-4 assert, implemented here and
  ## nowhere else:
  ##
  ##   * multiple consecutive `##` lines CONCATENATE, newline-joined;
  ##   * a non-comment statement between the comment and the declaration
  ##     CLEARS the buffer — the run must be immediately above;
  ##   * a trailing `##` (one BELOW the declaration) does not attach, which
  ##     is automatic here because the scan only ever moves upward;
  ##   * the recorded position is the FIRST line of the run and ITS column,
  ##     not the declaration's line with column 0.
  ##
  ## Blank lines are treated as non-comment statements and break the run. That
  ## is the stricter reading of "lead-only attachment" and it is the one that
  ## cannot silently pick up an unrelated comment paragraph.
  result = AttachedDoc(text: "", line: 0, column: 0)
  var collected: seq[string] = @[]
  var firstIdx = -1
  var idx = declLineIndex - 1
  while idx >= 0:
    let raw = lines[idx]
    let stripped = raw.strip()
    if not stripped.startsWith("##"):
      break
    var body = stripped[2 .. ^1]
    if body.len > 0 and body[0] == ' ':
      body = body[1 .. ^1]
    collected.add(body)
    firstIdx = idx
    dec idx
  if firstIdx < 0:
    return
  collected.reverse()
  result.text = collected.join("\n")
  result.line = firstIdx + 1
  result.column = lines[firstIdx].find('#') + 1

# ---------------------------------------------------------------------------
# §4.9 / §5.3 — the diagnostics
# ---------------------------------------------------------------------------

proc editDistance(a, b: string): int =
  ## Plain Levenshtein. Used only to pick the `did you mean` candidate.
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
    for j in 0 .. b.len: prev[j] = cur[j]
  prev[b.len]

proc suggestLockFileName*(typo: string; ownerPackage = ""): string =
  ## The §4.9 `did you mean` candidate, or `""` when nothing is close enough.
  ## The bound is deliberately tight: a suggestion that is not the name the
  ## author meant is worse than none, because it invites a second wrong edit.
  var best = ""
  var bestScore = high(int)
  for d in declared:
    if d.ownerPackage.len > 0 and d.ownerPackage != ownerPackage: continue
    let score = editDistance(typo.toLowerAscii(), d.name.toLowerAscii())
    if score < bestScore or (score == bestScore and d.name < best):
      bestScore = score
      best = d.name
  let bound = max(1, typo.len div 3)
  if bestScore <= bound: best else: ""

proc inScopeListingLines*(ownerPackage = ""): seq[string] =
  ## The `in scope here:` block of §4.9, one line per declared name.
  ##
  ## Each line carries the name, its origin, AND its description. §4.2
  ## consumer (2) is explicit that both diagnostics "should print each name's
  ## description alongside it. The §4.9 diagnostic is exactly where a reader
  ## who typed the wrong name learns what the right ones mean." A listing of
  ## bare names would satisfy the sentence and defeat the reason for it.
  result = @[]
  var width = 0
  var visible: seq[LockFileDecl] = @[]
  for d in declared:
    if d.ownerPackage.len > 0 and d.ownerPackage != ownerPackage: continue
    visible.add(d)
    width = max(width, d.name.len)
  for d in visible:
    var line = "    " & d.name & spaces(width - d.name.len) &
      "  (" & originOf(d) & ")"
    let firstLine = d.description.splitLines()[0].strip()
    if firstLine.len > 0:
      line.add("\n      " & firstLine)
    result.add(line)

proc undeclaredLockFileDiagnostic*(name: string; sourceFile: string;
                                   sourceLine, sourceColumn: int;
                                   ownerPackage = ""): string =
  ## §4.9's diagnostic, verbatim in shape:
  ##
  ## ```text
  ## Error: undeclared lock file `hostTool`
  ##   packages/mytool/repro.nim(28, 14)
  ##       lockFile hostTool
  ##                ^
  ##   no lock file with that name is declared in scope.
  ##
  ##   in scope here:
  ##     default        (stdlib, predeclared)
  ##     …
  ##
  ##   did you mean `hostTools`?
  ## ```
  ##
  ## The requirement it discharges is §4.9's: an undeclared name "MUST fail at
  ## recipe compile time. It MUST NOT be a runtime lookup miss, MUST NOT
  ## silently resolve to `default`, and MUST NOT produce an empty or zero
  ## value." This proc renders the message; the macro that calls it is what
  ## makes the failure a compile error.
  result = "undeclared lock file `" & name & "`\n"
  if sourceFile.len > 0:
    result.add("  " & sourceFile & "(" & $sourceLine & ", " &
      $sourceColumn & ")\n")
    result.add("      lockFile " & name & "\n")
    result.add("      " & spaces("lockFile ".len) & "^\n")
  result.add("  no lock file with that name is declared in scope.\n\n")
  result.add("  in scope here:\n")
  for line in inScopeListingLines(ownerPackage):
    result.add(line & "\n")
  let suggestion = suggestLockFileName(name, ownerPackage)
  if suggestion.len > 0:
    result.add("\n  did you mean `" & suggestion & "`?\n")

proc lockFileListingText*(): string =
  ## What `repro lock list` prints: §4.2 consumer (1). "A workspace with three
  ## declared lock files is unusable if a reader cannot find out what each is
  ## *for* without grepping the recipes."
  ##
  ## The binding is printed too, because a listing that named the lock files
  ## but not what they currently resolve to would answer half the question an
  ## operator has.
  var width = 0
  for d in declared:
    width = max(width, d.name.len)
  result = ""
  for d in declared:
    result.add(d.name & spaces(width - d.name.len) & "  (" & originOf(d) & ")\n")
    if d.path.len > 0:
      result.add("    path: " & d.path & "\n")
    for line in d.description.splitLines():
      let stripped = line.strip()
      if stripped.len > 0:
        result.add("    " & stripped & "\n")

# ---------------------------------------------------------------------------
# §4.3 / §4.4 / §4.5 — the designation stack and the precedence chain
# ---------------------------------------------------------------------------

type
  LockFileScopeKind* = enum
    ## The rungs of §4.3's precedence chain, narrowest LAST so a plain stack
    ## top is the winner. Encoding the chain as a push order rather than as a
    ## comparison is what stops a future rung being added at the wrong
    ## priority: `activeLockFileName` has no ordering logic to get wrong.
    lskPackage      ## §4.3 package-level default
    lskArtifact     ## §4.3 `executable` / `library` designation
    lskBlock        ## §4.4 `withLockFile` block
    lskCall         ## §4.5 per-call `lockFile =` argument

  LockFileScope* = object
    kind*: LockFileScopeKind
    name*: string

var designationStack {.threadvar.}: seq[LockFileScope]

proc pushLockFileScope*(kind: LockFileScopeKind; name: string) =
  designationStack.add(LockFileScope(kind: kind, name: name))

proc popLockFileScope*() =
  if designationStack.len > 0:
    designationStack.setLen(designationStack.len - 1)

proc resetLockFileScopes*() =
  designationStack.setLen(0)

proc activeLockFileScopes*(): seq[LockFileScope] =
  designationStack

proc activeLockFileName*(): string =
  ## The lock file governing the region being evaluated right now, or `""`
  ## when nothing has designated one.
  ##
  ## `""` rather than `default` is deliberate and is the §5.3 distinction made
  ## structural: "an unbound `hostTools` resolves to `default`'s lock, which
  ## has `default`'s content, which is `default`'s key". A caller that needs a
  ## name uses `effectiveLockFileName`; a caller that needs to know whether
  ## anything was SAID reads this one. Collapsing them would make "nobody
  ## designated anything" indistinguishable from "somebody wrote
  ## `lockFile default`", and NLF-STAT-3 is exactly the test that those two
  ## produce identical fingerprints while remaining distinguishable in
  ## diagnostics.
  if designationStack.len == 0: "" else: designationStack[^1].name

proc effectiveLockFileName*(): string =
  ## `activeLockFileName()` with §4.3's final rung applied: `default`.
  let name = activeLockFileName()
  if name.len > 0: name else: DefaultLockFileName

proc resolveLockFilePath*(name: string; bindings: Table[string, string]):
    string =
  ## §5.3's resolution order for a declared lock file:
  ##
  ##   1. an explicit `--lock <name>=<path>` binding;
  ##   2. the declaration's committed `path =` field;
  ##   3. otherwise the workspace lock file — and there is **no third case,
  ##      and in particular no error for an unbound lock file**.
  ##
  ## Step 3 returns `default`'s resolved path, recursing at most once because
  ## `default` either has a binding, has a `path =`, or is the terminus.
  if bindings.hasKey(name):
    return bindings[name]
  let idx = findLockFile(name)
  if idx >= 0 and declared[idx].path.len > 0:
    return declared[idx].path
  if name == DefaultLockFileName:
    return ""
  resolveLockFilePath(DefaultLockFileName, bindings)
