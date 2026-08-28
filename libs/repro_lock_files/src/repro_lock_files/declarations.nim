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

import std/[algorithm, os, strutils, tables]

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
  ##
  ## A recorded source position wins over the predeclared marker. §4.2 makes
  ## the well-known names re-declarable — `lockFile default, path = "…"` is
  ## §4.10's whole-graph retargeting spelling — and a listing that kept
  ## reporting `(stdlib, predeclared)` for a name the workspace has since
  ## declared would send a reader looking in the wrong file.
  if d.sourceFile.len > 0:
    d.sourceFile & ":" & $d.sourceLine
  elif d.predeclared:
    "stdlib, predeclared"
  else:
    "declared"

proc emitLockFileDeclarationsIfRequested*()
  ## Forward declaration. The emission is defined below, next to the format
  ## it writes; `declareLockFile` calls it so the document on disk is current
  ## the moment a declaration exists. See `LockFilesEmitEnvVar` for why it is
  ## not an exit proc.

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
    emitLockFileDeclarationsIfRequested()
    return name
  declared.add(LockFileDecl(
    name: name, path: path, description: description,
    sourceFile: sourceFile, sourceLine: sourceLine,
    sourceColumn: sourceColumn, ownerPackage: ownerPackage))
  emitLockFileDeclarationsIfRequested()
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

proc suggestIn*(decls: openArray[LockFileDecl]; typo: string;
                ownerPackage = ""): string =
  ## The §4.9 `did you mean` candidate over an EXPLICIT declaration list, or
  ## `""` when nothing is close enough. The bound is deliberately tight: a
  ## suggestion that is not the name the author meant is worse than none,
  ## because it invites a second wrong edit.
  ##
  ## Every renderer below takes its declaration list as a parameter rather
  ## than reading the module's registry, and that is load-bearing rather than
  ## stylistic: the same rendering has to run against the COMPILE-TIME
  ## registry (`ct_registry.nim`, which is where §4.9's error is raised) and
  ## against the run-time one (`repro lock list`). Nim cannot read another
  ## module's global from the VM, so a renderer that closed over the registry
  ## could only ever serve one of the two — and the two would drift, which for
  ## a diagnostic means the compile error and the listing disagreeing about
  ## what is in scope.
  var best = ""
  var bestScore = high(int)
  for d in decls:
    if d.ownerPackage.len > 0 and d.ownerPackage != ownerPackage: continue
    let score = editDistance(typo.toLowerAscii(), d.name.toLowerAscii())
    if score < bestScore or (score == bestScore and d.name < best):
      bestScore = score
      best = d.name
  let bound = max(1, typo.len div 3)
  if bestScore <= bound: best else: ""

proc inScopeListingLinesIn*(decls: openArray[LockFileDecl];
                            ownerPackage = ""): seq[string] =
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
  for d in decls:
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

proc undeclaredDiagnosticIn*(decls: openArray[LockFileDecl];
                             name: string; sourceFile: string;
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
  for line in inScopeListingLinesIn(decls, ownerPackage):
    result.add(line & "\n")
  let suggestion = suggestIn(decls, name, ownerPackage)
  if suggestion.len > 0:
    result.add("\n  did you mean `" & suggestion & "`?\n")

proc suggestLockFileName*(typo: string; ownerPackage = ""): string =
  ## `suggestIn` against the run-time registry.
  suggestIn(declared, typo, ownerPackage)

proc inScopeListingLines*(ownerPackage = ""): seq[string] =
  ## `inScopeListingLinesIn` against the run-time registry.
  inScopeListingLinesIn(declared, ownerPackage)

proc undeclaredLockFileDiagnostic*(name: string; sourceFile: string;
                                   sourceLine, sourceColumn: int;
                                   ownerPackage = ""): string =
  ## `undeclaredDiagnosticIn` against the run-time registry.
  undeclaredDiagnosticIn(declared, name, sourceFile, sourceLine,
    sourceColumn, ownerPackage)

proc listingTextOf*(decls: openArray[LockFileDecl]): string =
  ## What `repro lock list` prints: §4.2 consumer (1). "A workspace with three
  ## declared lock files is unusable if a reader cannot find out what each is
  ## *for* without grepping the recipes."
  ##
  ## The binding is printed too, because a listing that named the lock files
  ## but not what they currently resolve to would answer half the question an
  ## operator has.
  var width = 0
  for d in decls:
    width = max(width, d.name.len)
  result = ""
  for d in decls:
    result.add(d.name & spaces(width - d.name.len) & "  (" & originOf(d) & ")\n")
    if d.path.len > 0:
      result.add("    path: " & d.path & "\n")
    for line in d.description.splitLines():
      let stripped = line.strip()
      if stripped.len > 0:
        result.add("    " & stripped & "\n")

proc lockFileListingText*(): string =
  ## `listingTextOf` against the run-time registry.
  listingTextOf(declared)

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

# ---------------------------------------------------------------------------
# §4.3 — the artifact / package designation registry
# ---------------------------------------------------------------------------

type
  ArtifactDesignation* = object
    ## One `lockFile <name>` written at an `executable` / `library` / package
    ## declaration. §4.3: "**The artifact declaration, not the package, is the
    ## designation site.** … A package routinely declares both a host build
    ## tool and a shipped binary — the example above is the canonical shape —
    ## so package-level designation would be too coarse to express the
    ## motivating case."
    packageName*: string
    artifactName*: string
      ## Empty for the package-level default, which "remains available as a
      ## default that artifacts inherit and may override".
    lockFileName*: string
    sourceFile*: string
    sourceLine*: int

var designations: seq[ArtifactDesignation] = @[]

proc resetArtifactDesignations*() =
  designations.setLen(0)

proc registerArtifactLockFile*(packageName, artifactName, lockFileName: string;
                               sourceFile = ""; sourceLine = 0) =
  ## Record a designation. Emitted by the `package` macro's expansion, so the
  ## compiled recipe carries its own designation table and the propagation
  ## input can be built from the recipe rather than re-parsed out of it.
  designations.add(ArtifactDesignation(
    packageName: packageName, artifactName: artifactName,
    lockFileName: lockFileName, sourceFile: sourceFile,
    sourceLine: sourceLine))

proc artifactDesignations*(): seq[ArtifactDesignation] =
  designations

proc designationFor*(packageName, artifactName: string): string =
  ## §4.3's precedence chain, restricted to the two DECLARATION rungs (the
  ## block and per-call rungs are dynamic and live on the designation stack).
  ##
  ## Narrowest wins: an artifact designation outranks its package's default,
  ## and the absence of both is `""` — inherit, per §4.6's table.
  for d in designations:
    if d.packageName == packageName and d.artifactName == artifactName and
        artifactName.len > 0:
      return d.lockFileName
  for d in designations:
    if d.packageName == packageName and d.artifactName.len == 0:
      return d.lockFileName
  ""

# ---------------------------------------------------------------------------
# §4.2 consumer (1) — getting the declarations OUT of a compiled recipe
# ---------------------------------------------------------------------------

const LockFilesEmitEnvVar* = "REPRO_EMIT_LOCK_FILES"
  ## When this names a writable path, a compiled recipe writes its declared
  ## lock files there as it declares them.
  ##
  ## `repro lock list` runs in the CLI process; the declarations live in the
  ## RECIPE process, because `lockFile hostTools` lowers to a `let` binding
  ## whose initializer registers it at module init. Something has to carry
  ## them across, and this is the same shape `REPRO_EMIT_SOLVER_INPUTS`
  ## already uses for the solver inputs — one env var, honoured by the
  ## compiled provider, ignored by every ordinary run.
  ##
  ## ## Why the emission is EAGER, and not an exit proc
  ##
  ## NLF-M7 hung it off `addExitProc`, reasoning that a recipe may declare
  ## lock files and nothing else — no packages, no variants, no `build:`
  ## block — so hanging it off `finalizeVariants()` (where the solver-inputs
  ## emission lives) would silently produce an empty listing for exactly the
  ## workspace §4.2's example shows. That reasoning is right and the exit proc
  ## was the wrong way to act on it.
  ##
  ## **[MEASURED] NLF-M8.** An exit proc that reads a module-level global
  ## SEGFAULTS. `exitprocs.callClosures` runs after ORC has destroyed module
  ## globals, so `declared`'s strings are freed by the time the closure walks
  ## them and `strutils.replace` faults on a nil payload. Three lines
  ## reproduce it: import this module, set the variable, exit.
  ##
  ## The consequence is worse than a crash, and it is the reason this is
  ## documented here at length rather than fixed quietly. The crash happened
  ## in the PROVIDER child process; the CLI saw exit 139 as a failed command,
  ## caught it with the probe's `except CatchableError`, and printed the
  ## well-known set — which is indistinguishable from "this workspace
  ## declares nothing". A listing that reports confidently about the wrong
  ## thing is the defect class this whole campaign exists to catch, and it had
  ## got inside the feature's own diagnostics, behind two layers of silence.
  ##
  ## So the write happens at DECLARATION time, while the globals are alive and
  ## while a failure would still be attributable. Each declaration rewrites
  ## the file, so the last one leaves a complete document; there are a handful
  ## of declarations in a workspace and the cost is not measurable. A recipe
  ## that declares nothing writes nothing, and the reader falls back to the
  ## well-known set — which for that recipe is the true answer rather than a
  ## masked failure.

proc renderLockFileDeclarations*(decls: openArray[LockFileDecl]): string =
  ## The emit format: one tab-separated record per declaration, and a header
  ## naming the version so a reader can refuse a format it does not know
  ## rather than mis-parsing one.
  ##
  ## Descriptions are newline-escaped, because a description is multi-line by
  ## construction (§4.2's example has two lines) and an un-escaped newline
  ## would make the record separator ambiguous — the §1.3 hazard in miniature.
  result = "# repro lock files v1\tname\tpath\tsourceFile\tsourceLine\t" &
    "sourceColumn\tdescription\n"
  for d in decls:
    result.add(d.name & "\t" & d.path & "\t" & d.sourceFile & "\t" &
      $d.sourceLine & "\t" & $d.sourceColumn & "\t" &
      d.description.replace("\\", "\\\\").replace("\n", "\\n") & "\n")

proc parseLockFileDeclarations*(text: string): seq[LockFileDecl] =
  ## Read back what `renderLockFileDeclarations` wrote.
  result = @[]
  for raw in text.splitLines():
    if raw.len == 0 or raw.startsWith("#"): continue
    let parts = raw.split('\t')
    if parts.len < 6: continue
    var description = ""
    var i = 0
    let encoded = parts[5]
    while i < encoded.len:
      if encoded[i] == '\\' and i + 1 < encoded.len:
        case encoded[i + 1]
        of 'n': description.add('\n')
        of '\\': description.add('\\')
        else: description.add(encoded[i + 1])
        i += 2
      else:
        description.add(encoded[i])
        inc i
    var line = 0
    var column = 0
    try:
      line = parseInt(parts[3])
      column = parseInt(parts[4])
    except ValueError:
      discard
    result.add(LockFileDecl(
      name: parts[0], path: parts[1], sourceFile: parts[2],
      sourceLine: line, sourceColumn: column, description: description,
      predeclared: parts[2].len == 0))

proc emitLockFileDeclarationsIfRequested*() =
  ## Write the registry to `REPRO_EMIT_LOCK_FILES` when it is set.
  ##
  ## Called from `declareLockFile` — see `LockFilesEmitEnvVar` for why that
  ## and not an exit proc.
  ##
  ## Best-effort: a write failure never disturbs the process, exactly as the
  ## solver-inputs emission is best-effort, because a diagnostic surface must
  ## not be able to fail a build. Note what that sentence does NOT license:
  ## the failure this replaced was not a write failure but a SIGSEGV, which no
  ## `except` clause catches, and "best-effort" is not a licence to run code
  ## at a point where the data it reads may already be gone.
  let path = getEnv(LockFilesEmitEnvVar)
  if path.len == 0: return
  try:
    writeFile(path, renderLockFileDeclarations(declared))
  except CatchableError:
    discard
