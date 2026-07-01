## Nim language convention (Tier 2b) — Mode A "fine-grained" plugin.
##
## Recognises a project whose ``reprobuild.nim`` has ``uses:`` containing
## ``nim`` AND a conventional ``<pkg>.nimble`` (or ``src/<pkg>.nim``) on
## disk plus at least one ``executable`` / ``library`` member, and emits
## the three-phase Nim build graph the convention spec
## (``reprobuild-specs/Language-Conventions/Nim.md`` §"Mode A — Fine-grained
## build graph") prescribes:
##
##   Phase 1 (one action per entrypoint):
##     ``nim c --skipParentCfg --skipUserCfg --compileOnly --noLinking
##       --nimcache:<scratch>/<entry>/nimcache --mm:orc -d:release
##       <projectRoot>/src/<entry>.nim``
##     produces the C files + the ``<entry>.json`` nimcache manifest.
##
##   Phase 2 (one action per ``.c`` file, derived from the manifest's
##   ``compile`` array):
##     ``gcc -c -o <obj> -MD -MF <obj>.d <nim-emitted-flags> <c-file>``
##     each depends on phase 1 and writes a depfile (depfile policy).
##
##   Phase 3 (one action per entrypoint):
##     ``gcc -o <projectRoot>/.repro/build/<entry>/<entry>.exe <objs>
##       <linker-flags-from-manifest>``
##     depends on every phase-2 action.
##
## **Design decision (M3 Option 1 — eager + M18 fingerprint cache).** The
## convention invokes ``nim c --compileOnly`` from ``emitFragment`` itself
## (via ``osproc.execCmdEx``) so it can read the manifest and enumerate
## the per-file compile actions *at convention-emit time*. The pure-
## dyndep alternative — a generator action that produces a ``dyndep``
## file the engine reads at build time, with the engine SYNTHESISING per-
## ``.c`` actions from the fragment — would require extending the engine's
## current dyndep contract (which can only attach extra deps/outputs to
## actions that already exist, not create new ones). That refactor is
## deferred to a follow-on milestone.
##
## M18 lands the headline perf goal (the eager subprocess no longer fires
## on every ``repro build``) via a pragmatic fingerprint sidecar in
## ``conventions/emit_cache.nim``: ``runNimCompileOnly`` hashes the
## ``.nim`` source set + the entry source + the ``--app:lib`` toggle +
## the nim driver path, compares against
## ``<nimcacheDir>/nim-c-compileonly.repro-emit-fingerprint``, and skips
## the subprocess on a match (the previous run's manifest is reused).
## This keeps a static-graph emit shape while making cold-snapshot
## re-emits cheap when the source set is unchanged.
##
## The eager ``nim c`` run also doubles as the Phase 1 action: we encode
## the *same* command line into the inline-exec call so the engine's
## action cache fingerprints the work and skips a re-run when nothing has
## changed.
##
## **M22 test discovery**: when a recognised project ships
## ``tests/test_*.nim`` files, the convention also emits a per-test
## ``nim c -r`` action under a non-default ``test`` target. Each test
## file becomes one verification action that compiles AND runs the
## test; success is signalled by a companion ``fs.stamp`` writing a
## ``<scratch>/tests/<name>.stamp`` file. The stamp gives the engine
## something to declare as the test's output (so a re-run of
## ``repro build .#test`` becomes a no-op when sources are unchanged)
## without forcing the convention to mutate the test action's argv into
## a multi-step shell pipeline. ``repro build .#test`` builds the test
## target; ``repro build .#default`` stays library/executable-only.
##
## **Caveats**:
##   * Requires ``nim`` on ``PATH`` at convention-emit time (the same
##     condition Phase 1 needs at build time). When ``nim`` is missing,
##     ``recognize`` returns ``false`` so dispatch falls through to the
##     "no convention matched" diagnostic with the regular project hint.
##   * Phase 2/3 hard-code ``gcc`` as the C compiler — matches the Nim
##     compiler's default on Linux/MinGW. M3+ should consult ``uses:``
##     for ``msvc``/``clang`` pins and pick the matching compiler driver.

import std/[algorithm, json, os, osproc, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Nim
    ## convention writes into. Kept as a const so the e2e validator and
    ## any cleanup scripts agree with the convention on a single edit.

type
  NimEntrypoint = object
    ## Single ``executable foo`` declaration discovered in
    ## ``reprobuild.nim``. Library-only packages join the dispatch surface
    ## via ``NimLibraryTarget`` (M12); the two kinds share Phase 1/2 of
    ## the build graph and differ only in the Phase 3 link action.
    name: string
    sourceFile: string
      ## Absolute path to ``<projectRoot>/src/<name>.nim``.
    package: string
      ## Mode 3: the ``package <name>:`` block this entrypoint is
      ## declared inside. Empty when the convention can't attribute the
      ## member (single-package fixtures or a parse failure). Used by
      ## the workspace-dep wiring to map ``depends_on <pkg>: <dep>``
      ## edges back to the link-action that needs the dep's library
      ## output threaded through.

  NimLibraryKind = enum
    nlkStatic
    nlkShared
    nlkBoth
    nlkHeaderOnly

  NimLibraryTarget = object
    ## Single ``library foo`` declaration discovered in
    ## ``reprobuild.nim``. M12 supports ``kind: static|shared|both|header-only``.
    name: string
    sourceFile: string
      ## Absolute path to ``<projectRoot>/src/<name>.nim``.
    kind: NimLibraryKind
    package: string
      ## Mode 3: the ``package <name>:`` block this library is declared
      ## inside. Same contract as ``NimEntrypoint.package``.
    cConsumable: bool
      ## Reverse-cross-language: true when at least one C/C++ Mode 3
      ## ``executable`` in the same workspace depends on this library
      ## (i.e. ``depends_on cppApp: <thisPackage>`` is declared with
      ## ``cppApp`` in a ``uses: gcc/clang`` package). Triggers
      ## ``--noMain`` on Phase 1's ``nim c`` invocation so the resulting
      ## ``.o`` files (and hence the archive) carry only ``NimMain`` and
      ## the user's ``{.exportc.}`` symbols — without Nim's default
      ## ``int main(...)`` which would collide with the C/C++ binary's
      ## own ``main()`` at link time.

  NimWorkspaceLibrary = object
    ## A library target after it has been emitted: holds the link-action
    ## id (the convention's Phase 3 ``ar rcs`` or ``gcc -shared`` action)
    ## plus the resulting library output path. The
    ## ``depends_on`` consumer uses this to add a library to a downstream
    ## executable's link inputs + argv.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    kind: NimLibraryKind

  CCppUpstreamLibrary = object
    ## Cross-language upstream archive provided by a C/C++ Mode 3 package
    ## inside the same workspace. The Nim convention, when claiming a
    ## mixed-language project, emits the per-source compile + ``ar``
    ## archive actions for these in-line and then threads the archive
    ## onto every downstream Nim executable's link. The include dir is
    ## additionally pushed onto Phase 1's ``nim c`` invocation via
    ## ``--passC:-I<dir>`` so the Nim compiler's generated ``.c`` files
    ## can resolve user ``{.importc, header: "<pkg>/foo.h".}`` headers.
    package*: string
    libraryName*: string
    linkActionId*: string
    outputPath*: string
    includeDir*: string

  NimcacheCompileStep = object
    ## One row of the ``compile`` array in ``<entry>.json``. The Nim
    ## compiler emits ``[<absolute c file>, <gcc command template>]``;
    ## we keep the entry as parsed and decode the gcc command lazily.
    cFile: string
    gccCommand: string

  NimcacheManifest = object
    compile: seq[NimcacheCompileStep]
    link: seq[string]
    linkcmd: string

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## under ``projectRoot``; return the empty string when neither is
  ## present. Used by both ``recognize`` and ``emitFragment``; never
  ## raises. See ``repro_core/project_file`` for the alias contract.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesNim(source: string): bool =
  ## True when the ``uses:`` block names a ``nim`` or ``nim >=x`` toolchain.
  ## Mirrors the heuristic in ``project_intro.readUsesHint`` but trims the
  ## version constraint suffix off each entry. Conservative: any error
  ## in parsing returns ``false`` so dispatch falls through.
  if source.len == 0:
    return false
  var inBlock = false
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        for raw in stripped.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          if firstToken == "nim":
            return true
        continue
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          if firstToken == "nim":
            return true
  false

proc extractEntrypoints(source: string): seq[string] =
  ## Heuristic line-scan for ``executable <name>`` declarations. Same
  ## scope as the rest of the Tier 2b heuristics — diagnostic-grade, not
  ## a DSL evaluator. Ignores ``executable <name>:`` blocks too (the
  ## colon is dropped before comparison).
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    # Stop at the first whitespace/colon — block-form ``executable foo:``
    # and inline-form ``executable foo`` both collapse to "foo".
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc parseNimLibraryKind(text: string): NimLibraryKind =
  ## Mirrors ``libraryKindLiteral`` in the DSL; accepts the same token
  ## set the DSL grammar does. Conservative-static on unknowns — keeps
  ## the heuristic line-scanner from raising on malformed bodies (the
  ## DSL evaluator would have rejected them earlier).
  case text.normalize
  of "shared", "lkshared", "dynamic":
    nlkShared
  of "both", "lkboth":
    nlkBoth
  of "header-only", "headeronly", "lkheaderonly":
    nlkHeaderOnly
  else:
    nlkStatic

proc extractLibraries(source: string): seq[NimLibraryTarget] =
  ## Heuristic line-scan for ``library <name>`` declarations and any
  ## subsequent indented ``kind: <token>`` line in their body. Mirrors
  ## ``extractEntrypoints`` for the executable case; diagnostic-grade,
  ## not a DSL evaluator. Accepts both shapes:
  ##
  ##   library foo                 — bare command, ``kind`` defaults to
  ##                                 ``nlkStatic``.
  ##   library foo:                — block form. The body may carry a
  ##     kind: shared                ``kind: <token>`` line. We pick up
  ##                                 the first ``kind:`` line encountered
  ##                                 while indented under the declaration.
  ##
  ## Indentation tracking: we record the column of the ``library`` keyword
  ## and treat any subsequent non-empty line whose leading whitespace
  ## exceeds that column as part of the library body. The first line that
  ## un-indents back to ``library``'s column closes the body.
  var current: ref NimLibraryTarget
  var libraryColumn = -1
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    var indent = 0
    for ch in line:
      if ch == ' ':
        inc indent
      elif ch == '\t':
        indent += 8
      else:
        break
    if current != nil:
      if indent > libraryColumn:
        # Still inside the library body. Look for ``kind: <token>``.
        if stripped.startsWith("kind:"):
          var value = stripped[5 .. ^1].strip()
          if value.len > 0:
            value = value.strip(chars = {'"', '\''})
            current[].kind = parseNimLibraryKind(value)
        continue
      else:
        # Un-indented — body closed. Emit and fall through to look at
        # the current line as a fresh statement.
        result.add(current[])
        current = nil
        libraryColumn = -1
    if stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      let rest = stripped[len("library") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len == 0:
        continue
      var lib = NimLibraryTarget(name: name, kind: nlkStatic)
      current = new(NimLibraryTarget)
      current[] = lib
      libraryColumn = indent
  if current != nil:
    result.add(current[])

type
  NimMemberOwnership = object
    ## Map a member name (``executable foo`` / ``library bar``) back to
    ## the ``package <name>:`` block it was declared inside. The Mode 3
    ## ``depends_on`` macro names packages, not members, so the
    ## convention needs the owning-package mapping to wire dep edges
    ## from a downstream package's link action to an upstream package's
    ## library output.
    package*: string
    member*: string
    kind*: string  ## "executable" or "library"

proc extractPackageMembers*(source: string): seq[NimMemberOwnership] =
  ## Walk the project source text and emit ``(package, member, kind)``
  ## tuples in declaration order. Diagnostic-grade text scan — same
  ## scope as ``extractEntrypoints``/``extractLibraries``. Recognises
  ## the canonical Mode 3 shape:
  ##
  ##   package <pkg>:
  ##     uses: ...
  ##     library <name>            # static (default)
  ##     library <name>:
  ##       kind: shared
  ##     executable <name>:
  ##       discard
  ##
  ## Indentation tracking: a ``package <pkg>:`` opens a body at the
  ## first non-blank line that's MORE indented than ``package``. Any
  ## member declaration encountered while the body is open is attributed
  ## to ``<pkg>``. A line that un-indents back to ``package``'s column
  ## closes the package body.
  ##
  ## Members declared at top level (outside any ``package`` block) are
  ## emitted with an empty ``package`` field — they exist in the
  ## fixtures the M3 baseline tests cover (``reprobuild-examples/nim/binary``
  ## etc., where the whole project is one ``package`` block) and the
  ## consumer treats empty ownership as "ambient/single-package".
  var currentPackage = ""
  var packageColumn = -1
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    var indent = 0
    for ch in line:
      if ch == ' ':
        inc indent
      elif ch == '\t':
        indent += 8
      else:
        break
    if currentPackage.len > 0 and indent <= packageColumn:
      currentPackage = ""
      packageColumn = -1
    if stripped.startsWith("package") and
        (stripped.len == len("package") or
         stripped[len("package")] in {' ', '\t'}):
      let rest = stripped[len("package") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len == 0:
        continue
      currentPackage = name
      packageColumn = indent
      continue
    if stripped.startsWith("executable") and
        (stripped.len == len("executable") or
         stripped[len("executable")] in {' ', '\t'}):
      let rest = stripped[len("executable") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len > 0:
        result.add(NimMemberOwnership(
          package: currentPackage, member: name, kind: "executable"))
      continue
    if stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      let rest = stripped[len("library") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len > 0:
        result.add(NimMemberOwnership(
          package: currentPackage, member: name, kind: "library"))
      continue

type
  PackageUsesEntry* = object
    ## Per-package ``uses:`` block as captured by ``extractPackageUses``.
    ## ``tokens`` lists the bare toolchain names (without version
    ## constraints) the package opts into. The cross-language wiring
    ## consumes this to bucket members by toolchain so the Nim
    ## convention only emits Nim phases for ``uses: "nim"`` packages
    ## and routes ``uses: "gcc"`` / ``uses: "clang"`` packages through
    ## the embedded C/C++ helper.
    package*: string
    tokens*: seq[string]

proc consumeUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractPackageUses*(source: string): seq[PackageUsesEntry] =
  ## Walk ``source`` and emit one ``PackageUsesEntry`` per declared
  ## ``package <name>:`` block, with the bare token list parsed from
  ## the body's ``uses:`` block (inline or indented form). Diagnostic
  ## -grade text scan — same scope as ``extractPackageMembers``.
  ##
  ## Recognised shapes::
  ##
  ##   package foo:
  ##     uses:
  ##       "nim >=2.2 <3.0"
  ##       "gcc >=11"
  ##
  ##   package foo:
  ##     uses: "nim >=2.2"
  ##
  ## The version constraint tail (``>=2.2 <3.0``) is dropped so the
  ## ``tokens`` field carries only the bare toolchain identifier
  ## (``"nim"``, ``"gcc"``, ``"clang"``, etc.). Members declared at top
  ## level with no enclosing ``package`` block are not surfaced here —
  ## ``hasUsesTokenAny`` consumers fall back to the file-wide
  ## ``usesIncludesNim`` / ``usesIncludesCCppCompiler`` heuristics.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(PackageUsesEntry(
        package: currentPackage,
        tokens: currentTokens))
    currentPackage = ""
    packageColumn = -1
    currentTokens = @[]
    inUsesBlock = false
    usesColumn = -1
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    var indent = 0
    for ch in line:
      if ch == ' ': inc indent
      elif ch == '\t': indent += 8
      else: break
    # Close the prior package when un-indenting back to its column.
    if currentPackage.len > 0 and indent <= packageColumn:
      flushPackage()
    # Track end of ``uses:`` block by un-indenting back to its column.
    if inUsesBlock and indent <= usesColumn:
      inUsesBlock = false
      usesColumn = -1
    if inUsesBlock:
      for raw in stripped.split({',', ' ', '\t'}):
        consumeUsesToken(currentTokens, raw)
      continue
    if stripped.startsWith("package") and
        (stripped.len == len("package") or
         stripped[len("package")] in {' ', '\t'}):
      let rest = stripped[len("package") .. ^1].strip()
      if rest.len == 0:
        continue
      var name = ""
      for ch in rest:
        if ch in {' ', '\t', ':', ','}:
          break
        name.add(ch)
      if name.len == 0:
        continue
      # New package — flush the previous one (defensive; should already
      # have been closed by the indent-check above when sibling packages
      # share an indent column).
      flushPackage()
      currentPackage = name
      packageColumn = indent
      continue
    if currentPackage.len > 0 and stripped.startsWith("uses:"):
      let payload = stripped[len("uses:") .. ^1].strip()
      if payload.len == 0:
        inUsesBlock = true
        usesColumn = indent
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          consumeUsesToken(currentTokens, raw)
      continue
  # Flush trailing package (no un-indent after the last block).
  flushPackage()

proc packageUsesToken*(entries: openArray[PackageUsesEntry];
                      package: string): seq[string] =
  ## Return ``package``'s ``uses:`` token list, or the empty seq when
  ## the package is missing or the file is single-block (no ``package``
  ## wrapper).
  for entry in entries:
    if entry.package == package:
      return entry.tokens
  @[]

proc packageUsesAny*(entries: openArray[PackageUsesEntry];
                    package: string; tokens: openArray[string]): bool =
  ## True when any of ``tokens`` is named in ``package``'s ``uses:``
  ## block. Convenience over ``packageUsesToken`` for the cross-language
  ## bucketing.
  let pkgTokens = packageUsesToken(entries, package)
  for token in pkgTokens:
    for needle in tokens:
      if token == needle:
        return true
  false

proc hasAnyMember(source: string): bool =
  ## True when the package declares at least one ``executable`` or
  ## ``library`` member. Delegates to the per-shape extractors so the
  ## sentinel check matches the same token boundary the per-shape
  ## scanners use (``library<sp|tab>name``, never ``libraryName``).
  if extractEntrypoints(source).len > 0:
    return true
  extractLibraries(source).len > 0

proc findNimbleFile(projectRoot: string): string =
  ## Return the absolute path of the first ``*.nimble`` file in
  ## ``projectRoot``, or the empty string. The Nim convention's recognition
  ## spec wants ``<pkgname>.nimble`` — but stem-vs-package matching is
  ## brittle when pkgname uses camelCase (``nimBinaryExample``) while the
  ## conventional snake_case ``.nimble`` stem (``nim_binary_example``) is
  ## what nimble itself enforces. The looser check "*any* .nimble at the
  ## root" is good enough for M3: every Nim package ships exactly one.
  for kind, path in walkDir(projectRoot):
    if kind == pcFile and path.endsWith(".nimble"):
      return path
  ""

proc nimExecutable(): string =
  ## Resolve the ``nim`` executable on PATH or return ``""`` if missing.
  ## Recognise time: avoids declaring a match we can't fulfil at emit.
  findExe("nim")

proc nimRecognize(projectRoot: string;
                  request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M3):
  ##   * ``reprobuild.nim`` mentions ``nim`` in ``uses:``
  ##   * at least one ``executable`` (or ``library``) member is declared
  ##   * either a ``*.nimble`` exists at the project root, OR at least
  ##     one declared executable has its ``src/<name>.nim`` on disk
  ##   * the ``nim`` compiler is on PATH (so emit can run it)
  ##
  ## **Layout B** (one-source-tree-per-member): the per-member source
  ## file may also live at ``<projectRoot>/<member>/src/<member>.nim``.
  ## This is the canonical mixed-workspace layout (it mirrors the C/C++
  ## ``Layout B`` shape and keeps two languages' source trees from
  ## stomping each other). Recognition accepts either form.
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesNim(source):
    return false
  if not hasAnyMember(source):
    return false
  if nimExecutable().len == 0:
    return false
  let hasNimble = findNimbleFile(projectRoot).len > 0
  if hasNimble:
    return true
  for name in extractEntrypoints(source):
    if fileExists(extendedPath(projectRoot / "src" / (name & ".nim"))):
      return true
    if fileExists(extendedPath(projectRoot / name / "src" / (name & ".nim"))):
      return true
  for lib in extractLibraries(source):
    if fileExists(extendedPath(projectRoot / "src" / (lib.name & ".nim"))):
      return true
    if fileExists(extendedPath(projectRoot / lib.name / "src" /
        (lib.name & ".nim"))):
      return true
  false

proc scratchPathFor(projectRoot, entry: string): string =
  projectRoot / ScratchDirName / entry

proc nimcachePathFor(projectRoot, entry: string): string =
  scratchPathFor(projectRoot, entry) / "nimcache"

proc objDirFor(projectRoot, entry: string): string =
  scratchPathFor(projectRoot, entry) / "obj"

proc binaryPathFor(projectRoot, entry: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, entry) / (entry & ".exe")
  else:
    scratchPathFor(projectRoot, entry) / entry

proc staticLibraryPathFor(projectRoot, entry: string): string =
  ## ``libfoo.a`` lives under the per-library scratch dir so the
  ## convention's outputs line up neatly: one ``.a`` per ``library``
  ## declaration. ``ar`` writes archive members keyed by member basename;
  ## the per-entry scratch keeps two libraries from stomping each other
  ## even on case-insensitive filesystems.
  scratchPathFor(projectRoot, entry) / ("lib" & entry & ".a")

proc sharedLibraryPathFor(projectRoot, entry: string): string =
  ## Platform-specific shared library name. Nim convention M12 picks the
  ## native suffix:
  ##   * Windows : ``<entry>.dll``
  ##   * macOS   : ``lib<entry>.dylib``
  ##   * Other   : ``lib<entry>.so``
  when defined(windows):
    scratchPathFor(projectRoot, entry) / (entry & ".dll")
  elif defined(macosx):
    scratchPathFor(projectRoot, entry) / ("lib" & entry & ".dylib")
  else:
    scratchPathFor(projectRoot, entry) / ("lib" & entry & ".so")

proc nimcacheManifestPathFor(projectRoot, entry: string): string =
  nimcachePathFor(projectRoot, entry) / (entry & ".json")

proc nimCompileOnlyArgv(nimExe, nimcacheDir, entrySource: string;
                        appLib = false;
                        cIncludeDirs: openArray[string] = [];
                        noMain = false): seq[string] =
  ## The literal argv for both the eager (emit-time) and recorded
  ## (graph-action) Phase 1 invocation. Keeping these identical is the
  ## whole point of Option 1: the cached fingerprint of the recorded
  ## action matches what we just executed.
  ##
  ## M12: when ``appLib`` is true, append ``--app:lib`` so Nim emits a
  ## linkcmd that produces a shared library rather than an executable.
  ## ``ar``-based static linking ignores Nim's linkcmd entirely so the
  ## static path leaves ``appLib`` false (preserving the executable-mode
  ## linkcmd in the manifest, even though we discard it).
  ##
  ## **Cross-language**: ``cIncludeDirs`` lists upstream C/C++ Mode 3
  ## package include directories. Each becomes a ``--passC:-I<dir>`` flag
  ## so the C compiler Nim invokes on the manifest's emitted ``.c`` files
  ## can resolve user-written ``{.importc, header: "<pkg>/foo.h".}``
  ## headers. The flag is threaded into Phase 1's argv (not just Phase 2)
  ## so the SAME argv is fingerprinted by the emit-cache: a new dep
  ## include-dir flips the fingerprint and the cache miss is correct.
  ##
  ## **Reverse cross-language**: ``noMain`` adds ``--noMain`` to suppress
  ## Nim's generated ``int main(...)`` so the resulting ``.o`` files can
  ## be archived into a static library safe for consumption from a C/C++
  ## binary that has its own ``main()``. The ``NimMain`` runtime
  ## initializer is still emitted; the user's C/C++ code calls it once at
  ## startup. Toggled on for ``library`` targets whose package is the
  ## ``depends_on`` target of an executable in a ``uses: gcc/clang``
  ## package within the same workspace — see ``isLibraryCConsumed``.
  result = @[
    nimExe,
    "c",
    "--skipParentCfg",
    "--skipUserCfg",
    "--compileOnly",
    "--noLinking",
    "--nimcache:" & nimcacheDir,
    "--mm:orc",
    "--define:release"
  ]
  if appLib:
    result.add("--app:lib")
  if noMain:
    result.add("--noMain")
  for incDir in cIncludeDirs:
    if incDir.len == 0:
      continue
    result.add("--passC:-I" & incDir)
  result.add(entrySource)

const
  NimEmitCacheBaseName = "nim-c-compileonly"
    ## Sidecar file basename for the M18 emit-time fingerprint cache.
    ## See ``emit_cache.nim`` for the contract.

proc nimEmitCacheFingerprint(nimExe, entrySource, manifestPath: string;
                             nimSources: openArray[string];
                             appLib: bool;
                             cIncludeDirs: openArray[string] = [];
                             noMain = false): string =
  ## Fingerprint key for the nim-c-compileonly cache.
  ##
  ## Inputs that participate in the key:
  ##   * the Nim driver path (``findExe("nim")`` resolved on this run);
  ##   * the entry source path (which entry we're compiling);
  ##   * the ``appLib`` toggle (controls whether ``--app:lib`` is emitted,
  ##     which materially changes the nimcache linkcmd);
  ##   * the manifest output path (so two scratch dirs can't share a
  ##     fingerprint sidecar even if their source set is identical);
  ##   * every ``.nim`` source file under ``<projectRoot>/src/`` plus the
  ##     entry source itself — content digest folded in via
  ##     ``fileInput``.
  ##
  ## **M29 Part A**: the Nim driver's reported version is now folded in
  ## via ``toolVersionInput`` (running ``nim --version`` once per emit
  ## process, with the result cached). The same-path-different-binary
  ## case (e.g. ``choosenim`` swapping the resolved binary, or a system
  ## ``nim`` upgraded in place) is therefore handled directly: the
  ## reported version string changes and the cache misses naturally.
  ##
  ## Not in the key today:
  ##   * the ``nim`` binary's raw bytes (hash). Version output is the
  ##     pragmatic stand-in — it changes whenever Nim's behaviour
  ##     materially changes and is cheap to compute. A future M can
  ##     fold in the full binary hash if a same-version-different-bytes
  ##     case crops up.
  ##   * environment variables. The convention's argv is hermetic at
  ##     the source level — Nim doesn't read ``NIMCACHE_DIR`` etc. when
  ##     ``--nimcache:`` is set on the command line.
  var inputs: seq[EmitCacheInput] = @[
    textInput("nim-exe:" & nimExe),
    toolVersionInput(nimExe),
    textInput("entry-source:" & entrySource),
    textInput("manifest:" & manifestPath),
    textInput("app-lib:" & (if appLib: "true" else: "false")),
    textInput("no-main:" & (if noMain: "true" else: "false")),
    fileInput(entrySource),
  ]
  for source in nimSources:
    inputs.add(fileInput(source))
  for incDir in cIncludeDirs:
    inputs.add(textInput("c-inc-dir:" & incDir))
  computeEmitCacheFingerprint(inputs)

proc runNimCompileOnly(nimExe, nimcacheDir, entrySource: string;
                       nimSources: openArray[string];
                       manifestPath: string;
                       appLib = false;
                       cIncludeDirs: openArray[string] = [];
                       noMain = false) =
  ## Execute the eager Phase 1 run and surface any failure as a
  ## ``ValueError`` carrying the captured stderr. The standard provider
  ## binary's outer ``try/except`` (in ``apps/repro-standard-provider``)
  ## converts these into the protocol-level error response.
  ##
  ## **M6.5 pipe-buffer audit**: previously used
  ## ``osproc.startProcess(..., options = {poStdErrToStdOut}) +
  ## outputStream.readAll() + waitForExit()`` which deadlocks on Windows
  ## when ``nim c`` output exceeds the ~64 KB OS pipe buffer (a real
  ## project with thousands of modules emits enough log chatter to hit
  ## this). Switched to ``execCmdEx`` which drains the pipe continuously
  ## via background reader, matching the Go convention's
  ## ``runGoListExport`` pattern.
  ##
  ## The captured output is used **only** for the non-zero-exit
  ## diagnostic; the actual graph data is parsed from the on-disk
  ## ``nimcache.json`` manifest after the process exits, so any progress
  ## chatter in the merged stdout/stderr is harmless here.
  ##
  ## **M18 emit-cache fast path**: when a sidecar fingerprint at
  ## ``<nimcacheDir>/nim-c-compileonly.repro-emit-fingerprint`` matches
  ## the current source-set fingerprint AND the nimcache manifest is on
  ## disk, we skip the subprocess entirely — the previous run's manifest
  ## is still valid. The convention's caller re-parses the manifest
  ## unconditionally; that work is cheap (~10 KB JSON) compared to the
  ## ~1-2 s ``nim c`` invocation. The sidecar is refreshed on every
  ## subprocess success so a partial run never poisons the cache.
  createDir(extendedPath(nimcacheDir))
  let fingerprint = nimEmitCacheFingerprint(nimExe, entrySource,
    manifestPath, nimSources, appLib, cIncludeDirs, noMain)
  if emitCacheIsUsable(nimcacheDir, NimEmitCacheBaseName, fingerprint,
      [manifestPath]):
    return
  let argv = nimCompileOnlyArgv(nimExe, nimcacheDir, entrySource, appLib,
    cIncludeDirs, noMain)
  let cmd = quoteShellCommand(argv)
  let (output, exitCode) = execCmdEx(cmd,
    options = {poStdErrToStdOut, poUsePath})
  if exitCode != 0:
    raise newException(ValueError,
      "nim convention: 'nim c --compileOnly' exited " & $exitCode &
        " for " & entrySource & ":\n" & output)
  writeEmitCacheFingerprint(nimcacheDir, NimEmitCacheBaseName, fingerprint)

proc parseNimcacheManifest(manifestPath: string): NimcacheManifest =
  ## Decode the nimcache ``<entry>.json`` Nim writes alongside the
  ## ``.c`` files. We pull just the fields Phase 2/3 need; any future
  ## extension (``configFiles``, ``depfiles``) plugs in here.
  let raw = readFile(extendedPath(manifestPath))
  let node = parseJson(raw)
  if node.kind != JObject:
    raise newException(ValueError,
      "nim convention: nimcache manifest is not a JSON object: " & manifestPath)
  if "compile" in node and node["compile"].kind == JArray:
    for entry in node["compile"]:
      if entry.kind != JArray or entry.len != 2:
        continue
      result.compile.add(NimcacheCompileStep(
        cFile: entry[0].getStr(),
        gccCommand: entry[1].getStr()))
  if "link" in node and node["link"].kind == JArray:
    for item in node["link"]:
      result.link.add(item.getStr())
  if "linkcmd" in node:
    result.linkcmd = node["linkcmd"].getStr()

proc splitCommandLine(cmd: string): seq[string] =
  ## Minimal POSIX-style argv tokeniser sufficient for the gcc commands
  ## Nim emits — whitespace separated, no quoted multi-word arguments
  ## (Nim quotes paths containing spaces but our scratch dir is under
  ## ``.repro/build`` which we control). Anything fancier would need a
  ## real lexer; on Windows, ``CreateProcessW`` re-joins these via
  ## ``CommandLineToArgvW`` rules so a single-pass whitespace split is
  ## safe as long as no token contains a space.
  var token = ""
  for ch in cmd:
    if ch in {' ', '\t'}:
      if token.len > 0:
        result.add(token)
        token = ""
    else:
      token.add(ch)
  if token.len > 0:
    result.add(token)

proc rewriteGccArgv(rawArgv: seq[string]; cFile, objFile, depFile: string):
    seq[string] =
  ## Take the gcc argv Nim baked into the nimcache manifest and rewrite
  ## the per-file outputs:
  ##   * replace ``-o <something>`` with ``-o <objFile>``
  ##   * drop the trailing ``<cFile>`` (we re-add it explicitly)
  ##   * append ``-MD -MF <depFile>`` for incremental dep tracking
  ##
  ## We keep every other flag verbatim — Nim picks ``-O3 -fno-ident``
  ## etc. for us and the convention spec wants those preserved.
  var argv: seq[string] = @[]
  var i = 0
  while i < rawArgv.len:
    let token = rawArgv[i]
    if token == "-o" and i + 1 < rawArgv.len:
      argv.add("-o")
      argv.add(objFile)
      inc i, 2
      continue
    if token == cFile:
      inc i
      continue
    argv.add(token)
    inc i
  argv.add("-MD")
  argv.add("-MF")
  argv.add(depFile)
  argv.add(cFile)
  argv

proc gccDriverFromCommand(rawArgv: seq[string]; gccDefault: string): string =
  ## Pluck the driver (first token) out of the manifest command; fall
  ## back to whatever ``findExe`` resolved. Nim emits ``gcc.exe`` on
  ## Windows / ``gcc`` on POSIX as the first token.
  if rawArgv.len > 0:
    return rawArgv[0]
  gccDefault

proc objFileFromManifestCFile(objDir, cFile: string): string =
  ## Nim emits one ``.c`` per Nim module with mangled names like
  ## ``@mfoo.nim.c`` or ``@psystem.nim.c``. Reuse those names for the
  ## per-file ``.o`` so the manifest's ``link`` array (which already
  ## carries the matching ``.o`` paths) lines up with what Phase 2
  ## produces, edge for edge.
  let stem = extractFilename(cFile)
  objDir / (stem & ".o")

proc actionIdFor(prefix, entry, detail: string): string =
  ## Build a Reprobuild-safe action id. The DSL's ``sanitizeNodePart``
  ## already rewrites unsafe chars, but keeping the *human* id readable
  ## helps the ``--log=actions`` output.
  var sanitized = ""
  for ch in detail:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  prefix & "-" & entry & "-" & sanitized

proc collectNimSources(srcDir: string): seq[string] =
  ## Every ``.nim`` under ``<projectRoot>/src``. These become the
  ## Phase-1 action's declared inputs so source-only edits invalidate
  ## the action without relying on the io-monitor monitor.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    if entry.toLowerAscii.endsWith(".nim"):
      result.add(entry)
  result.sort(system.cmp[string])

type
  RustWorkspaceUpstream = object
    ## Forward cross-language: a Rust staticlib emitted in-line that a
    ## Nim entrypoint's Phase 3 gcc link picks up. Same shape as
    ## ``CCppUpstreamLibrary`` minus the include dir (Rust ABI is
    ## consumed via Nim ``{.importc.}`` pragmas, not header files).
    package*: string
    libraryName*: string
    linkActionId*: string
    outputPath*: string

proc rustCrossRuntimeLinkLibs(): seq[string]
  ## Forward declaration — full definition lower in this module (near
  ## the other M35 Rust cross-language helpers). Required because
  ## ``emitForEntrypoint`` below references it for the forward direction
  ## (Nim app uses Rust lib) and is itself defined before the Rust
  ## helpers' textual position in the file.

proc emitForEntrypoint(projectRoot, nimExe: string;
                      entry: NimEntrypoint;
                      depLibraries: openArray[NimWorkspaceLibrary] = [];
                      cCppDepLibraries: openArray[CCppUpstreamLibrary] = [];
                      rustDepLibraries: openArray[RustWorkspaceUpstream] = []):
                        tuple[phase1: BuildActionDef;
                              phase2: seq[BuildActionDef];
                              phase3: BuildActionDef] =
  ## Materialise the three-phase graph for a single ``executable``.
  ## Eagerly runs ``nim c --compileOnly`` so the manifest is on disk
  ## before we register Phase 2/3 — or skips the run when the M18
  ## emit-time fingerprint cache says the previous manifest is still
  ## current.
  ##
  ## **Mode 3 dep wiring**: ``depLibraries`` enumerates the workspace
  ## libraries this entrypoint's package depends on (resolved from the
  ## ``depends_on`` registry / ``repro.scanned-deps.nim``). Each library's
  ## ``outputPath`` is added to the Phase 3 link action's ``inputs`` AND
  ## to its argv as a trailing positional, and its ``linkActionId`` is
  ## added to the Phase 3 ``deps`` list. Net effect: the engine sequences
  ## the entrypoint's link strictly after the dep library's link action,
  ## and the resulting executable links the static archive into its image.
  ##
  ## **Cross-language dep wiring**: ``cCppDepLibraries`` enumerates the
  ## C/C++ Mode 3 packages this entrypoint's package depends on (resolved
  ## the same way as ``depLibraries`` but routed through the embedded
  ## C/C++ archive helpers). For each such dep:
  ##   * ``--passC:-I<includeDir>`` is threaded into Phase 1's ``nim c``
  ##     argv so the generated ``.c`` files can resolve ``#include
  ##     "<pkg>/foo.h"`` lines emitted by user
  ##     ``{.importc, header: "<pkg>/foo.h".}`` declarations.
  ##   * The archive path is added to Phase 3's link inputs + argv as a
  ##     trailing positional, and the archive action's id is added to
  ##     Phase 3's deps — identical wiring shape to the same-language case.
  let nimcacheDir = nimcachePathFor(projectRoot, entry.name)
  let objDir = objDirFor(projectRoot, entry.name)
  let binaryOutput = binaryPathFor(projectRoot, entry.name)
  let manifestPath = nimcacheManifestPathFor(projectRoot, entry.name)
  createDir(extendedPath(objDir))
  # M18: collect the full ``src/`` source set ONCE so the same fingerprint
  # serves the cache check AND the Phase 1 action's declared inputs.
  let nimSources = collectNimSources(projectRoot / "src")
  # Cross-language: stable, deduplicated list of upstream include dirs to
  # thread onto ``nim c``'s argv via ``--passC:-I<dir>``.
  var cIncludeDirs: seq[string] = @[]
  for lib in cCppDepLibraries:
    if lib.includeDir.len == 0:
      continue
    if lib.includeDir notin cIncludeDirs:
      cIncludeDirs.add(lib.includeDir)
  runNimCompileOnly(nimExe, nimcacheDir, entry.sourceFile, nimSources,
    manifestPath, false, cIncludeDirs)
  let manifest = parseNimcacheManifest(manifestPath)
  if manifest.compile.len == 0:
    raise newException(ValueError,
      "nim convention: nimcache manifest carries no compile steps for " &
        entry.name)

  let phase1Outputs = block:
    var outs = @[nimcacheDir, manifestPath]
    for step in manifest.compile:
      outs.add(step.cFile)
    outs

  let phase1Id = actionIdFor("nim-c-compileonly", entry.name, "umbrella")
  let phase1Argv = nimCompileOnlyArgv(nimExe, nimcacheDir, entry.sourceFile,
    false, cIncludeDirs)
  let phase1Action = buildAction(
    id = phase1Id,
    call = inlineExecCall(phase1Argv, projectRoot),
    inputs = nimSources,
    outputs = phase1Outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.compileOnly")

  var phase2: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  for step in manifest.compile:
    let cFile = step.cFile
    let rawArgv = splitCommandLine(step.gccCommand)
    let driver = gccDriverFromCommand(rawArgv, findExe("gcc"))
    let objFile = objFileFromManifestCFile(objDir, cFile)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    var gccArgv = rewriteGccArgv(
      if rawArgv.len > 0: rawArgv[1 .. ^1] else: @[],
      cFile, objFile, depFile)
    gccArgv.insert(driver, 0)
    let action = buildAction(
      id = actionIdFor("gcc-compile", entry.name, extractFilename(cFile)),
      call = inlineExecCall(gccArgv, projectRoot),
      deps = @[phase1Id],
      inputs = @[cFile],
      outputs = @[objFile],
      pool = "compile",
      depfile = depFile,
      dependencyPolicy = makeDepfilePolicy(depFile),
      commandStatsId = "nim.c.gcc-compile")
    phase2.add(action)

  # Phase 3 — link. Reconstruct the linker argv from the manifest's
  # ``linkcmd``: keep every flag Nim emitted but redirect the output to
  # our scratch binary path and use *our* object files.
  let linkRawArgv = splitCommandLine(manifest.linkcmd)
  var linkerArgv: seq[string] = @[]
  if linkRawArgv.len > 0:
    linkerArgv.add(linkRawArgv[0])
  else:
    linkerArgv.add(findExe("gcc"))
  # Walk the manifest linkcmd, keep flags, drop ``-o ...`` and any
  # token that ends in ``.o`` (we'll add our objs ourselves), so that
  # extra link flags such as ``-Wl,-Bstatic -lpthread`` survive.
  var i = if linkRawArgv.len > 0: 1 else: 0
  while i < linkRawArgv.len:
    let token = linkRawArgv[i]
    if token == "-o" and i + 1 < linkRawArgv.len:
      inc i, 2
      continue
    if token.endsWith(".o"):
      inc i
      continue
    linkerArgv.add(token)
    inc i
  # Move the -o pair to the front (right after the driver), then objs,
  # then any remaining flags. Nim emits link libs trailing-after-objs
  # which is what gcc expects, so keep that order.
  var finalArgv: seq[string] = @[linkerArgv[0], "-o", binaryOutput]
  for obj in objFiles:
    finalArgv.add(obj)
  for j in 1 ..< linkerArgv.len:
    finalArgv.add(linkerArgv[j])

  # Mode 3 dep-library wiring: thread each upstream library's archive
  # onto the link line so the dynamic loader sees the symbols at
  # runtime. Static archives go at the END of the argv — gcc/ld resolve
  # symbols left-to-right, so the .a must follow the .o files that
  # reference it. Shared libraries land in the same slot for the M-
  # baseline (we can teach the link argv to use ``-L<dir> -l<name>``
  # later; absolute-path positionals are unambiguous enough for now).
  for lib in depLibraries:
    finalArgv.add(lib.outputPath)
  # Cross-language: upstream C/C++ archives slot at the same position
  # as same-language deps. Symbol resolution is unaffected because
  # ``{.importc.}`` declarations in Nim sources don't disambiguate
  # symbol origin at link time — the archives are interchangeable from
  # gcc/ld's perspective.
  for lib in cCppDepLibraries:
    finalArgv.add(lib.outputPath)
  # M35 forward cross-language: upstream Rust staticlibs slot at the
  # same position. The Rust archive's exported symbols (declared via
  # ``#[no_mangle] pub extern "C"`` in the Rust source) are picked up
  # by gcc/ld and satisfy the Nim entrypoint's ``{.importc, cdecl.}``
  # references. The Rust runtime libs (platform-specific) are appended
  # below; they MUST trail the archive so gcc/ld resolves the runtime
  # symbols against the archive's references.
  for lib in rustDepLibraries:
    finalArgv.add(lib.outputPath)
  if rustDepLibraries.len > 0:
    for libFlag in rustCrossRuntimeLinkLibs():
      finalArgv.add(libFlag)

  let phase2Ids = block:
    var ids: seq[string] = @[]
    for action in phase2:
      ids.add(action.id)
    ids

  var phase3Deps = phase2Ids
  var phase3Inputs = objFiles
  for lib in depLibraries:
    if phase3Deps.find(lib.linkActionId) < 0:
      phase3Deps.add(lib.linkActionId)
    if phase3Inputs.find(lib.outputPath) < 0:
      phase3Inputs.add(lib.outputPath)
  for lib in cCppDepLibraries:
    if phase3Deps.find(lib.linkActionId) < 0:
      phase3Deps.add(lib.linkActionId)
    if phase3Inputs.find(lib.outputPath) < 0:
      phase3Inputs.add(lib.outputPath)
  for lib in rustDepLibraries:
    if phase3Deps.find(lib.linkActionId) < 0:
      phase3Deps.add(lib.linkActionId)
    if phase3Inputs.find(lib.outputPath) < 0:
      phase3Inputs.add(lib.outputPath)

  let phase3Action = buildAction(
    id = actionIdFor("gcc-link", entry.name, "binary"),
    call = inlineExecCall(finalArgv, projectRoot),
    deps = phase3Deps,
    inputs = phase3Inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.gcc-link")

  (phase1Action, phase2, phase3Action)

proc arDriver(): string =
  ## Resolve ``ar`` on PATH; fall back to the literal token so emit
  ## still produces a coherent argv even when ``ar`` is missing (the
  ## graph-action will report ``ar: command not found`` at build time —
  ## the operator can install GNU binutils and re-run).
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

proc emitForLibrary(projectRoot, nimExe: string;
                   lib: NimLibraryTarget): tuple[
                     phase1: BuildActionDef;
                     phase2: seq[BuildActionDef];
                     phase3: seq[BuildActionDef]] =
  ## Materialise the three-phase graph for a single ``library`` member.
  ## Shares Phase 1/2 with the executable path; Phase 3 differs by
  ## ``lib.kind``:
  ##
  ##   * ``nlkStatic``     — replace gcc link with ``ar rcs libfoo.a <objs>``
  ##   * ``nlkShared``     — keep Nim's emitted linkcmd (Phase 1 invoked
  ##                          with ``--app:lib`` so the linkcmd already
  ##                          carries ``-shared``); redirect the output
  ##                          path to ``libfoo.<so|dylib|dll>``.
  ##   * ``nlkBoth``       — emit BOTH the ``ar`` static action AND the
  ##                          ``gcc -shared`` action, in parallel; Phase 1
  ##                          uses ``--app:lib`` so the manifest carries
  ##                          a shared linkcmd we can reuse.
  ##   * ``nlkHeaderOnly`` — caller is expected to filter these out
  ##                          before reaching ``emitForLibrary``. We treat
  ##                          accidental calls as a bug.
  if lib.kind == nlkHeaderOnly:
    raise newException(ValueError,
      "nim convention: emitForLibrary called for header-only library '" &
        lib.name & "' — header-only libraries emit no actions")

  let useAppLib = lib.kind in {nlkShared, nlkBoth}
  # Reverse cross-language: thread ``--noMain`` onto Phase 1 when this
  # library is to be consumed by a C/C++ binary that has its own
  # ``main()``. Without this, the Nim entrypoint compile emits an
  # ``int main(...)`` in the ``<libname>.nim.c`` translation unit; once
  # the archive is pulled into the C/C++ link to resolve any Nim symbol
  # (``nimAdd``, ``NimMain``), the linker observes the archive's
  # ``main`` defined and the C/C++ binary's ``main`` defined → duplicate
  # symbol error. ``--noMain`` suppresses the Nim-emitted ``main`` while
  # preserving the ``NimMain`` runtime initializer the C/C++ binary
  # calls explicitly.
  let useNoMain = lib.cConsumable
  let nimcacheDir = nimcachePathFor(projectRoot, lib.name)
  let objDir = objDirFor(projectRoot, lib.name)
  let manifestPath = nimcacheManifestPathFor(projectRoot, lib.name)
  createDir(extendedPath(objDir))
  # M18: collect the ``src/`` source set ONCE so the same fingerprint
  # serves the emit-cache check AND the Phase 1 action's declared inputs.
  let nimSources = collectNimSources(projectRoot / "src")
  runNimCompileOnly(nimExe, nimcacheDir, lib.sourceFile, nimSources,
    manifestPath, useAppLib, cIncludeDirs = [], noMain = useNoMain)
  let manifest = parseNimcacheManifest(manifestPath)
  if manifest.compile.len == 0:
    raise newException(ValueError,
      "nim convention: nimcache manifest carries no compile steps for " &
        lib.name)

  let phase1Outputs = block:
    var outs = @[nimcacheDir, manifestPath]
    for step in manifest.compile:
      outs.add(step.cFile)
    outs

  let phase1Id = actionIdFor("nim-c-compileonly", lib.name, "umbrella")
  let phase1Argv = nimCompileOnlyArgv(nimExe, nimcacheDir, lib.sourceFile,
    useAppLib, cIncludeDirs = [], noMain = useNoMain)
  let phase1Action = buildAction(
    id = phase1Id,
    call = inlineExecCall(phase1Argv, projectRoot),
    inputs = nimSources,
    outputs = phase1Outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.compileOnly")

  var phase2: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  for step in manifest.compile:
    let cFile = step.cFile
    let rawArgv = splitCommandLine(step.gccCommand)
    let driver = gccDriverFromCommand(rawArgv, findExe("gcc"))
    let objFile = objFileFromManifestCFile(objDir, cFile)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    var gccArgv = rewriteGccArgv(
      if rawArgv.len > 0: rawArgv[1 .. ^1] else: @[],
      cFile, objFile, depFile)
    # For shared linkage we need every translation unit compiled with
    # -fPIC. Nim's manifest already emits the right thing on POSIX for
    # ``--app:lib`` but be explicit so the static-only path stays safe
    # to switch via ``kind: shared`` without a recompile of the .o files
    # ending up in the wrong shape. No-op on Windows/MinGW where -fPIC
    # is the default.
    if useAppLib:
      var alreadyPic = false
      for tok in gccArgv:
        if tok == "-fPIC" or tok == "-fpic":
          alreadyPic = true
          break
      if not alreadyPic:
        gccArgv.insert("-fPIC", 1)
    gccArgv.insert(driver, 0)
    let action = buildAction(
      id = actionIdFor("gcc-compile", lib.name, extractFilename(cFile)),
      call = inlineExecCall(gccArgv, projectRoot),
      deps = @[phase1Id],
      inputs = @[cFile],
      outputs = @[objFile],
      pool = "compile",
      depfile = depFile,
      dependencyPolicy = makeDepfilePolicy(depFile),
      commandStatsId = "nim.c.gcc-compile")
    phase2.add(action)

  let phase2Ids = block:
    var ids: seq[string] = @[]
    for action in phase2:
      ids.add(action.id)
    ids

  var phase3: seq[BuildActionDef] = @[]

  if lib.kind in {nlkStatic, nlkBoth}:
    let staticOutput = staticLibraryPathFor(projectRoot, lib.name)
    var arArgv: seq[string] = @[arDriver(), "rcs", staticOutput]
    for obj in objFiles:
      arArgv.add(obj)
    let staticAction = buildAction(
      id = actionIdFor("ar-archive", lib.name, "static"),
      call = inlineExecCall(arArgv, projectRoot),
      deps = phase2Ids,
      inputs = objFiles,
      outputs = @[staticOutput],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "nim.c.ar-archive")
    phase3.add(staticAction)

  if lib.kind in {nlkShared, nlkBoth}:
    let sharedOutput = sharedLibraryPathFor(projectRoot, lib.name)
    # Reuse Nim's linkcmd structure (driver + flags) just like the
    # executable path. Phase 1 ran with ``--app:lib`` so the linkcmd
    # already carries ``-shared``. We still rebuild the argv defensively
    # to redirect ``-o`` to our scratch path and ensure our object list
    # is on the link line.
    let linkRawArgv = splitCommandLine(manifest.linkcmd)
    var linkerArgv: seq[string] = @[]
    if linkRawArgv.len > 0:
      linkerArgv.add(linkRawArgv[0])
    else:
      linkerArgv.add(findExe("gcc"))
    var sawShared = false
    var i = if linkRawArgv.len > 0: 1 else: 0
    while i < linkRawArgv.len:
      let token = linkRawArgv[i]
      if token == "-o" and i + 1 < linkRawArgv.len:
        inc i, 2
        continue
      if token.endsWith(".o"):
        inc i
        continue
      if token == "-shared":
        sawShared = true
      linkerArgv.add(token)
      inc i
    var finalArgv: seq[string] = @[linkerArgv[0], "-o", sharedOutput]
    if not sawShared:
      finalArgv.add("-shared")
    for obj in objFiles:
      finalArgv.add(obj)
    for j in 1 ..< linkerArgv.len:
      finalArgv.add(linkerArgv[j])
    let sharedAction = buildAction(
      id = actionIdFor("gcc-link-shared", lib.name, "shared"),
      call = inlineExecCall(finalArgv, projectRoot),
      deps = phase2Ids,
      inputs = objFiles,
      outputs = @[sharedOutput],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "nim.c.gcc-link-shared")
    phase3.add(sharedAction)

  (phase1Action, phase2, phase3)

proc memberOwner(ownership: openArray[NimMemberOwnership];
                 kind, member: string): string =
  ## Look up the ``package`` field of the first ownership entry that
  ## matches ``(kind, member)``. Returns the empty string when none
  ## match — used as a "single-package fallback" by the entrypoint and
  ## library collectors so the baseline single-``package`` fixtures
  ## continue to work unchanged.
  for entry in ownership:
    if entry.kind == kind and entry.member == member:
      return entry.package
  ""

proc packageOwnsNimToolchain(usesEntries: openArray[PackageUsesEntry];
                             pkg: string; source: string): bool =
  ## True when ``pkg``'s ``uses:`` block names a Nim toolchain. The
  ## fallback applies to single-package fixtures where the member is
  ## declared at top level (no ``package <name>:`` wrapper, so
  ## ``ownership`` returns an empty package name): in that case the
  ## convention treats the WHOLE file's ``uses:`` as the answer, mirroring
  ## the pre-Mode-3 behaviour of the M0-M29 baseline fixtures.
  if pkg.len == 0:
    return usesIncludesNim(source)
  packageUsesAny(usesEntries, pkg, ["nim"])

proc resolveNimMemberSource(projectRoot, memberName: string): string =
  ## Resolve a Nim member's source file by trying Layout A first
  ## (``<projectRoot>/src/<name>.nim``), then Layout B
  ## (``<projectRoot>/<name>/src/<name>.nim``). Returns the empty string
  ## when neither shape resolves. Layout B keeps two languages' source
  ## trees from stomping each other in a mixed workspace; Layout A
  ## remains the canonical single-package shape.
  let layoutA = projectRoot / "src" / (memberName & ".nim")
  if fileExists(extendedPath(layoutA)):
    return layoutA
  let layoutB = projectRoot / memberName / "src" / (memberName & ".nim")
  if fileExists(extendedPath(layoutB)):
    return layoutB
  ""

proc collectEntrypoints(projectRoot, source: string): seq[NimEntrypoint] =
  let ownership = extractPackageMembers(source)
  let usesEntries = extractPackageUses(source)
  for name in extractEntrypoints(source):
    let path = resolveNimMemberSource(projectRoot, name)
    if path.len == 0:
      continue
    let owningPackage = memberOwner(ownership, "executable", name)
    # Cross-language filter: skip members the owning package does not
    # delegate to the Nim toolchain. The single-package fallback (empty
    # ``owningPackage``) collapses to the file-wide ``uses:`` hint, so
    # M0-M29 fixtures whose member is declared at the top level continue
    # to work unchanged.
    if not packageOwnsNimToolchain(usesEntries, owningPackage, source):
      continue
    result.add(NimEntrypoint(
      name: name,
      sourceFile: path,
      package: owningPackage))

proc collectNimTestFiles(projectRoot: string): seq[string] =
  ## M22: walk ``<projectRoot>/tests/`` for files named ``test_*.nim``.
  ## Returns a deterministically-sorted list of absolute paths so the
  ## per-test action ids (and therefore the engine's action-cache
  ## fingerprint set) are stable across emits. The convention skips
  ## ``test_*.nim`` files under ``node_modules/`` / ``.repro/`` — neither
  ## should exist in a Nim project but the filter is defensive in case
  ## a future fixture grows a vendor dir.
  let testsDir = projectRoot / "tests"
  if not dirExists(extendedPath(testsDir)):
    return @[]
  for entry in walkDirRec(testsDir):
    let normalised = entry.replace('\\', '/')
    if "/.repro/" in normalised:
      continue
    let basename = extractFilename(entry)
    if not basename.toLowerAscii.endsWith(".nim"):
      continue
    if not basename.toLowerAscii.startsWith("test_"):
      continue
    result.add(entry)
  result.sort(system.cmp[string])

proc testStampPathFor(projectRoot, testStem: string): string =
  ## M22: per-test stamp file under ``<scratch>/tests/<stem>.stamp``.
  ## The stem is the test file's basename without the ``.nim`` suffix —
  ## matches Nim's own convention for naming compiled artefacts.
  projectRoot / ScratchDirName / "tests" / (testStem & ".stamp")

proc nimTestStem(testFile: string): string =
  ## Map ``tests/test_greet.nim`` to ``test_greet``. Used as the action
  ## id suffix and the stamp file basename.
  var name = extractFilename(testFile)
  if name.toLowerAscii.endsWith(".nim"):
    name = name[0 ..< name.len - len(".nim")]
  name

proc emitTestAction(projectRoot, nimExe, testFile: string;
                    nimSources: seq[string]):
                      tuple[run: BuildActionDef; stamp: BuildActionDef] =
  ## M22: emit the per-test ``nim c -r`` action + a chained
  ## ``fs.stamp`` companion. The run action compiles AND executes the
  ## test (``-r`` is "run after compile"); ``--hints:off --warnings:off``
  ## keep the captured output focused on test failures; ``--path:src``
  ## adds the project's library source root to the import search path
  ## so the test can ``import <library_module>`` without a ``..``
  ## relative path.
  ##
  ## The action declares the test file + every ``.nim`` under ``src/``
  ## as inputs (same set used by the Phase 1 library/executable actions)
  ## so a library-source edit invalidates the test action. Outputs are
  ## empty — the test produces a temporary binary that's discarded after
  ## ``-r`` runs it. ``automaticMonitorPolicy()`` lets the io-monitor pick
  ## up any transitive source reads the eager input list missed.
  ##
  ## The chained ``fs.stamp`` writes ``<scratch>/tests/<stem>.stamp``
  ## after the run succeeds. The stamp file gives the engine a declared
  ## output to track so ``repro build .#test`` becomes a no-op on a
  ## re-run when nothing has changed. The stamp's text is the test
  ## stem — purely diagnostic; the engine only cares about file
  ## existence + mtime.
  let stem = nimTestStem(testFile)
  let argv = @[
    nimExe,
    "c",
    "-r",
    "--skipParentCfg",
    "--skipUserCfg",
    "--hints:off",
    "--warnings:off",
    "--path:" & (projectRoot / "src"),
    testFile,
  ]
  var inputs: seq[string] = @[testFile]
  for src in nimSources:
    inputs.add(src)
  let runAction = buildAction(
    id = actionIdFor("nim-test-run", stem, "run"),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.c.test-run")
  let stampPath = testStampPathFor(projectRoot, stem)
  createDir(extendedPath(parentDir(stampPath)))
  let stampAction = fs.stamp(
    output = stampPath,
    title = "nim-test:" & stem,
    entries = @[stem],
    actionId = actionIdFor("nim-test-stamp", stem, "stamp"),
    deps = @[runAction.id],
    commandStatsId = "nim.c.test-stamp")
  (runAction, stampAction)

proc collectLibraries(projectRoot, source: string): seq[NimLibraryTarget] =
  let ownership = extractPackageMembers(source)
  let usesEntries = extractPackageUses(source)
  for lib in extractLibraries(source):
    let path = resolveNimMemberSource(projectRoot, lib.name)
    if path.len == 0:
      continue
    let owningPackage = memberOwner(ownership, "library", lib.name)
    if not packageOwnsNimToolchain(usesEntries, owningPackage, source):
      continue
    result.add(NimLibraryTarget(
      name: lib.name,
      sourceFile: path,
      kind: lib.kind,
      package: owningPackage))

# ---------------------------------------------------------------------------
# Cross-language C/C++ helpers (mixed-workspace support).
#
# When a Mode 3 workspace declares both Nim packages and C/C++ packages in
# a single ``repro.nim`` (the user opted into the canonical pattern of one
# project file per workspace), the Nim convention wins recognition because
# it's registered first. It then takes responsibility for emitting the C/C++
# upstream packages' archive actions in-line so the cross-package
# ``depends_on nimApp: cppLib`` edge produces a coherent action graph
# within a single ``buildPackageFragment`` call.
#
# Both directions are now in scope inside this convention:
#
#   * Nim app uses C library — ``collectCCppCrossMembers`` enumerates
#     C/C++ ``library`` members in ``uses: gcc/clang`` packages; the
#     Nim entrypoint's link picks up ``lib<name>.a`` as a trailing
#     positional and ``--passC:-I<inc>`` lands on Phase 1's argv.
#
#   * C/C++ app uses Nim library — ``collectCCppCrossExecutables``
#     enumerates ``executable`` members in ``uses: gcc/clang`` packages;
#     each executable's link picks up the upstream Nim ``lib<name>.a``
#     (the existing Nim ``library`` emit, with ``--noMain`` threaded
#     onto Phase 1 to suppress duplicate ``main`` at link time — see
#     ``NimLibraryTarget.cConsumable``). The C/C++ binary itself is
#     emitted by helpers below that mirror ``c_cpp_direct``'s per-source
#     ``gcc -c`` + terminal ``gcc -o`` link shape.
#
# These helpers intentionally MIRROR (not import from) the equivalent
# logic in ``c_cpp_direct.nim`` so the two conventions stay independently
# evolvable. The shared schema is:
#
#   archive path     : <root>/.repro/build/<libName>/lib<libName>.a
#   obj dir          : <root>/.repro/build/<libName>/obj/
#   per-source obj   : <root>/.repro/build/<libName>/obj/<sanitized-stem>.o
#   exec path        : <root>/.repro/build/<exeName>/<exeName>[.exe]
#
# which is identical to the path c_cpp_direct emits, so a downstream user
# who graduates a package from mixed-workspace back to pure C/C++ does not
# observe an archive path change.
# ---------------------------------------------------------------------------

type
  CCppCrossMember = object
    package*: string
    libraryName*: string
    srcDir*: string
    includeDir*: string
    sourceFiles*: seq[string]

  CCppCrossExecutable = object
    ## Cross-language C/C++ executable member belonging to a ``uses:
    ## gcc/clang`` package in a workspace whose dispatch is owned by the
    ## Nim convention. Discovered by ``collectCCppCrossExecutables`` and
    ## emitted in-line as per-source ``gcc -c`` + terminal ``gcc -o``
    ## actions, with any ``depends_on cppExe: <nimLib-package>`` edges
    ## threaded as trailing-positional archive paths onto the link argv.
    package*: string
    executableName*: string
    srcDir*: string
    includeDir*: string
    sourceFiles*: seq[string]

  NimUpstreamLibrary = object
    ## Reverse cross-language: bookkeeping for a Nim ``library`` after
    ## its archive has been emitted, indexed by owning package so a
    ## downstream C/C++ executable's link can pick it up via
    ## ``depends_on cppApp: nimLibPkg``.  Mirror of
    ## ``CCppUpstreamLibrary`` but routed the other way through the
    ## same convention's emit pass.
    package*: string
    libraryName*: string
    linkActionId*: string
    outputPath*: string

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    let lower = path.toLowerAscii
    if lower.endsWith(".c") or lower.endsWith(".cpp") or
        lower.endsWith(".cc") or lower.endsWith(".cxx"):
      result.add(path)
  result.sort(system.cmp[string])

proc resolveCCppMemberDirs(projectRoot, memberName: string):
    tuple[srcDir, includeDir, entrySource: string] =
  ## Local mirror of ``cpp_dep_scanner.resolveMemberDirs``. Tries
  ## Layout B (``<root>/<memberName>/src/``) first then Layout A
  ## (``<root>/src/``); returns empty strings when neither matches.
  let subSrc = projectRoot / memberName / "src"
  if dirExists(extendedPath(subSrc)):
    for path in walkDirRec(subSrc):
      let lower = path.toLowerAscii
      if lower.endsWith(".c") or lower.endsWith(".cpp") or
          lower.endsWith(".cc") or lower.endsWith(".cxx"):
        result.srcDir = subSrc
        let inc = projectRoot / memberName / "include"
        if dirExists(extendedPath(inc)):
          result.includeDir = inc
        result.entrySource = path
        return
  let topSrc = projectRoot / "src"
  if dirExists(extendedPath(topSrc)):
    for path in walkDirRec(topSrc):
      let lower = path.toLowerAscii
      if lower.endsWith(".c") or lower.endsWith(".cpp") or
          lower.endsWith(".cc") or lower.endsWith(".cxx"):
        result.srcDir = topSrc
        let inc = projectRoot / "include"
        if dirExists(extendedPath(inc)):
          result.includeDir = inc
        result.entrySource = path
        return

proc ccCompilerCross(): string =
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[PackageUsesEntry]):
                               seq[CCppCrossMember] =
  ## Walk the project file for ``library`` declarations inside packages
  ## whose ``uses:`` block names ``gcc`` or ``clang``. Each resolvable
  ## member is returned as a ``CCppCrossMember`` with its source set
  ## (used downstream to emit ``gcc -c`` + ``ar rcs`` actions).
  ## Executables in C/C++ packages are NOT surfaced — the mixed-
  ## workspace contract emits only archives for cross-language
  ## consumption.
  let ownership = extractPackageMembers(source)
  for entry in ownership:
    if entry.kind != "library":
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAny(usesEntries, entry.package, ["gcc", "clang"]):
      continue
    let resolved = resolveCCppMemberDirs(projectRoot, entry.member)
    if resolved.srcDir.len == 0:
      continue
    let sourceFiles = collectCCppSourceFiles(resolved.srcDir)
    if sourceFiles.len == 0:
      continue
    result.add(CCppCrossMember(
      package: entry.package,
      libraryName: entry.member,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[PackageUsesEntry]):
                                   seq[CCppCrossExecutable] =
  ## Walk the project file for ``executable`` declarations inside
  ## packages whose ``uses:`` block names ``gcc`` or ``clang``. Each
  ## resolvable member becomes a ``CCppCrossExecutable`` carrying the
  ## source set the per-source compile + link emit consumes downstream.
  ##
  ## This is the reverse-direction sibling of
  ## ``collectCCppCrossMembers``: that one harvested ``library``
  ## members so they could be archived for a downstream Nim binary's
  ## consumption; this one harvests ``executable`` members so the Nim
  ## convention can emit the C/C++ binary's compile + link inside the
  ## same fragment that emits the upstream Nim library's archive.
  ##
  ## Library members in ``uses: gcc/clang`` packages are still routed
  ## through ``collectCCppCrossMembers`` — the two collectors share the
  ## member ownership table but partition by ``kind``. Header-only
  ## libraries are not surfaced (no emit action).
  let ownership = extractPackageMembers(source)
  for entry in ownership:
    if entry.kind != "executable":
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAny(usesEntries, entry.package, ["gcc", "clang"]):
      continue
    let resolved = resolveCCppMemberDirs(projectRoot, entry.member)
    if resolved.srcDir.len == 0:
      continue
    let sourceFiles = collectCCppSourceFiles(resolved.srcDir)
    if sourceFiles.len == 0:
      continue
    result.add(CCppCrossExecutable(
      package: entry.package,
      executableName: entry.member,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc ccppCrossScratch(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc ccppCrossObjDir(projectRoot, member: string): string =
  ccppCrossScratch(projectRoot, member) / "obj"

proc ccppCrossArchivePath(projectRoot, member: string): string =
  ccppCrossScratch(projectRoot, member) / ("lib" & member & ".a")

proc ccppSanitize(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc ccppCrossObjFor(objDir, source, srcDir: string): string =
  var rel: string
  try:
    rel = relativePath(source, srcDir)
  except OSError:
    rel = extractFilename(source)
  rel = rel.replace('\\', '/')
  let stem =
    if rel.toLowerAscii.endsWith(".cpp"): rel[0 ..< rel.len - 4]
    elif rel.toLowerAscii.endsWith(".cxx"): rel[0 ..< rel.len - 4]
    elif rel.toLowerAscii.endsWith(".cc"): rel[0 ..< rel.len - 3]
    elif rel.toLowerAscii.endsWith(".c"): rel[0 ..< rel.len - 2]
    else: rel
  objDir / (ccppSanitize(stem) & ".o")

proc isCxxSource(path: string): bool =
  let lower = path.toLowerAscii
  lower.endsWith(".cpp") or lower.endsWith(".cc") or lower.endsWith(".cxx")

proc emitCCppCrossCompileAction(projectRoot, ccExe: string;
                                member: CCppCrossMember;
                                source, objFile, depFile: string):
                                  BuildActionDef =
  ## ``gcc -c`` action for one C/C++ source belonging to a cross-language
  ## upstream library. Mirrors ``c_cpp_direct.emitCompileAction`` — kept
  ## inline so the Nim convention doesn't import ``c_cpp_direct``.
  ## The action id prefix is ``nim-xlang-ccpp-compile-`` so the test
  ## surface can distinguish the cross-language emit shape from the
  ## pure C/C++ convention's ``ccpp-direct-compile-`` shape.
  var argv = @[ccExe, "-c", "-O2", "-Wall", "-Wextra",
    "-MD", "-MF", depFile]
  if isCxxSource(source):
    argv.add("-std=c++20")
  else:
    argv.add("-std=c17")
  if dirExists(extendedPath(member.srcDir)):
    argv.add("-I")
    argv.add(member.srcDir)
  if member.includeDir.len > 0 and
      dirExists(extendedPath(member.includeDir)):
    argv.add("-I")
    argv.add(member.includeDir)
  argv.add("-o")
  argv.add(objFile)
  argv.add(source)
  let actionId = "nim-xlang-ccpp-compile-" &
    ccppSanitize(member.libraryName) & "-" &
    ccppSanitize(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "nim.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: CCppCrossMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action for a cross-language
  ## upstream library. The action id prefix mirrors the compile action's
  ## ``nim-xlang-ccpp-`` discriminator.
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "nim-xlang-ccpp-archive-" & ccppSanitize(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: CCppCrossMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  ## Emit the full per-source ``gcc -c`` set plus the terminal
  ## ``ar rcs`` archive action for one cross-language upstream library.
  ## Returns the archive path + include dir so the caller can wire the
  ## downstream Nim entrypoint's compile + link argv.
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "nim convention (mixed workspace): neither 'gcc' nor 'clang' on " &
        "PATH; cannot compile upstream C/C++ library '" &
        member.libraryName & "' for cross-language consumption")
  let arExe = arDriver()
  let objDir = ccppCrossObjDir(projectRoot, member.libraryName)
  createDir(extendedPath(objDir))
  var compileActions: seq[BuildActionDef] = @[]
  var compileIds: seq[string] = @[]
  var objFiles: seq[string] = @[]
  for source in member.sourceFiles:
    let objFile = ccppCrossObjFor(objDir, source, member.srcDir)
    let depFile = objFile & ".d"
    createDir(extendedPath(parentDir(objFile)))
    objFiles.add(objFile)
    let action = emitCCppCrossCompileAction(projectRoot, ccExe, member,
      source, objFile, depFile)
    compileActions.add(action)
    compileIds.add(action.id)
  let archive = emitCCppCrossArchiveAction(projectRoot, arExe, member,
    objFiles, compileIds)
  result.compiles = compileActions
  result.archive = archive
  result.archivePath = ccppCrossArchivePath(projectRoot, member.libraryName)
  result.includeDir = member.includeDir

# ---------------------------------------------------------------------------
# Reverse-direction C/C++ executable emit (C binary uses Nim library).
# ---------------------------------------------------------------------------

proc ccppCrossBinaryPath(projectRoot, member: string): string =
  ## ``<root>/.repro/build/<member>/<member>[.exe]`` — identical schema
  ## to the C/C++ direct convention's executable output path, so a
  ## graduate-to-pure-C/C++ never changes the executable path.
  when defined(windows):
    ccppCrossScratch(projectRoot, member) / (member & ".exe")
  else:
    ccppCrossScratch(projectRoot, member) / member

proc isCxxSourceList(sources: openArray[string]): bool =
  ## True when any source is a C++ extension (``.cpp``, ``.cc``,
  ## ``.cxx``). Drives the link driver choice: a mixed/all-C++ target
  ## must link with ``g++`` so the C++ stdlib (``libstdc++``) is
  ## auto-linked; a pure-C target can link with ``gcc``.
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc cxxCompilerCross(): string =
  ## Resolve the C++ link driver for cross-language executable emit.
  ## Prefer ``g++`` so the C++ stdlib is auto-linked when the C/C++
  ## binary contains any ``.cpp`` source; fall back to ``clang++``.
  let gpp = findExe("g++")
  if gpp.len > 0:
    return gpp
  findExe("clang++")

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: CCppCrossExecutable;
                                    source, objFile, depFile: string):
                                      BuildActionDef =
  ## Per-source ``gcc -c`` (or ``g++ -c``) action for one C/C++ source
  ## belonging to a cross-language executable. Mirrors
  ## ``emitCCppCrossCompileAction`` for libraries but uses the
  ## ``nim-xlang-ccpp-exec-compile-`` action-id prefix so a test can
  ## discriminate the executable's compiles from the library's.
  ##
  ## The driver argument is selected by the caller — ``gcc`` for a pure
  ## C source, ``g++`` for a C++ source — so the language-specific
  ## ``-std=...`` flag the action sets below pairs with a driver that
  ## actually accepts it.
  var argv = @[ccExe, "-c", "-O2", "-Wall", "-Wextra",
    "-MD", "-MF", depFile]
  if isCxxSource(source):
    argv.add("-std=c++20")
  else:
    argv.add("-std=c17")
  if dirExists(extendedPath(exec.srcDir)):
    argv.add("-I")
    argv.add(exec.srcDir)
  if exec.includeDir.len > 0 and
      dirExists(extendedPath(exec.includeDir)):
    argv.add("-I")
    argv.add(exec.includeDir)
  argv.add("-o")
  argv.add(objFile)
  argv.add(source)
  let actionId = "nim-xlang-ccpp-exec-compile-" &
    ccppSanitize(exec.executableName) & "-" &
    ccppSanitize(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "nim.xlang.ccpp.exec.compile")

proc nimRuntimeLinkLibs(): seq[string] =
  ## Nim's static-library archive carries references to a small set of
  ## system libraries that the C/C++ binary must link against because
  ## the archive itself doesn't pull them in.
  ##
  ## Concretely, the Nim runtime touches:
  ##   * ``-lm``       — POSIX math (``pow``, ``log``, etc. used by the
  ##                     Nim system module for ``float`` formatting).
  ##   * ``-lpthread`` — POSIX threads (the Nim runtime threads on by
  ##                     default; even single-threaded programs touch
  ##                     ``pthread_*`` weakly).
  ##   * ``-ldl``      — POSIX dynamic loader (``dlopen`` for Nim's
  ##                     ``dynlib`` pragma; harmless on programs that
  ##                     don't use it but the symbol may still be
  ##                     referenced from the runtime).
  ##
  ## On Windows MinGW the C runtime + msvcrt subset gcc ships covers
  ## these symbols without explicit ``-l`` flags (the probe at the top
  ## of the milestone confirmed a hand-built C++ binary linking against
  ## the Nim archive ran end-to-end with NO extra ``-l`` flags). On
  ## POSIX we add them defensively.
  when defined(windows):
    @[]
  else:
    @["-lm", "-lpthread", "-ldl"]

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: CCppCrossExecutable;
                                 objFiles, compileIds: seq[string];
                                 nimUpstream: openArray[NimUpstreamLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action for a cross-language C/C++
  ## executable. The upstream Nim archives' output paths land as
  ## trailing positionals (gcc/ld resolves symbols left-to-right;
  ## ``.a``s must follow the ``.o``s that reference them). Each upstream
  ## archive's action id is added to ``deps`` for sequencing, and its
  ## path is added to ``inputs`` for cache-hit invalidation.
  ##
  ## Nim's runtime touches ``-lm``/``-lpthread``/``-ldl`` on POSIX (the
  ## Nim-self-linked executable's link line carries these implicitly via
  ## the nimcache linkcmd). When a C/C++ binary links against a Nim
  ## archive, the archive itself doesn't pull these in — we have to add
  ## them to the link argv ourselves. ``nimRuntimeLinkLibs`` returns the
  ## platform-specific set.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in nimUpstream:
    argv.add(lib.outputPath)
  for libFlag in nimRuntimeLinkLibs():
    argv.add(libFlag)
  var deps = compileIds
  var inputs = objFiles
  for lib in nimUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "nim-xlang-ccpp-exec-link-" & ccppSanitize(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: CCppCrossExecutable;
                             nimUpstream: openArray[NimUpstreamLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  ## Emit the per-source ``gcc -c`` / ``g++ -c`` set plus the terminal
  ## ``gcc -o`` / ``g++ -o`` link action for one cross-language C/C++
  ## executable. The link argv is augmented with each upstream Nim
  ## library's archive path (resolved via the workspace ``depends_on``
  ## edge map) so the C++ binary's link resolves ``NimMain`` and the
  ## user's ``{.exportc.}`` symbols.
  ##
  ## Returns the per-source compile actions, the terminal link action,
  ## and the binary output path so the caller can register the member's
  ## target.
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "nim convention (mixed workspace): neither 'gcc' nor 'clang' on " &
        "PATH; cannot compile cross-language C/C++ executable '" &
        exec.executableName & "'")
  # Pick the link driver based on language content. A target that
  # contains any C++ source needs ``g++`` (or ``clang++``) so libstdc++
  # is auto-linked; pure-C targets link with ``gcc``.
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "nim convention (mixed workspace): C/C++ executable '" &
            exec.executableName & "' has C++ sources but neither 'g++' " &
            "nor 'clang++' on PATH for the link step")
      cxx
    else:
      cExe
  let objDir = ccppCrossObjDir(projectRoot, exec.executableName)
  createDir(extendedPath(objDir))
  var compileActions: seq[BuildActionDef] = @[]
  var compileIds: seq[string] = @[]
  var objFiles: seq[string] = @[]
  for source in exec.sourceFiles:
    # Per-source driver: C source compiles via ``gcc`` (or ``clang``);
    # C++ source compiles via ``g++`` (or ``clang++``). This matters for
    # ``-std=c++20`` to be accepted on the compile and for the C++
    # standard library include path to be on the search list.
    let perSourceDriver =
      if isCxxSource(source):
        let cxx = cxxCompilerCross()
        if cxx.len > 0: cxx
        else: cExe
      else:
        cExe
    let objFile = ccppCrossObjFor(objDir, source, exec.srcDir)
    let depFile = objFile & ".d"
    createDir(extendedPath(parentDir(objFile)))
    objFiles.add(objFile)
    let action = emitCCppCrossExecCompileAction(projectRoot,
      perSourceDriver, exec, source, objFile, depFile)
    compileActions.add(action)
    compileIds.add(action.id)
  let link = emitCCppCrossExecLinkAction(projectRoot, linkDriver, exec,
    objFiles, compileIds, nimUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

# ---------------------------------------------------------------------------
# M35 cross-language Rust helpers (mixed-workspace support, both directions).
#
# When a Mode 3 workspace declares both Nim packages and Rust packages in a
# single ``repro.nim``, the Nim convention claims the workspace (registered
# first) and takes responsibility for emitting the Rust packages' actions
# in-line so the cross-package ``depends_on`` edges produce a coherent
# action graph within a single ``buildPackageFragment`` call. Mirrors the
# C/C++ cross-language helpers above; the trade-offs are identical.
#
# Two directions:
#
#   * Forward (Nim app uses Rust lib) — ``collectRustCrossLibraries``
#     enumerates ``library`` members in ``uses: rust/rustc`` packages.
#     Each library is emitted as ``rustc --crate-type=staticlib`` landing
#     at ``<root>/.repro/build/<libName>/lib<libName>.a`` (canonical
#     archive schema shared with c-cpp-direct + Nim). The Nim
#     entrypoint's Phase 3 gcc link picks up the archive as a trailing
#     positional plus the platform-specific Rust runtime libs
#     (``-lws2_32 -luserenv -ladvapi32 -lbcrypt -lntdll`` on Windows
#     MinGW; ``-lpthread -ldl -lm`` on POSIX). The Nim source uses
#     ``proc rust_X(...): cint {.importc, cdecl.}`` to call into Rust.
#
#   * Reverse (Rust app uses Nim lib) — ``collectRustCrossExecutables``
#     enumerates ``executable`` members in ``uses: rust/rustc`` packages.
#     Each executable is emitted as ``rustc --crate-type=bin`` with
#     ``-L native=<nimlib-build-dir>`` ``-l static=<nimlib>`` flags plus
#     the platform-specific Nim runtime libs (``-lm`` on POSIX; empty on
#     Windows). The upstream Nim library's ``cConsumable`` flag is
#     derived from the dep graph (any Rust executable depending on the
#     library's package → cConsumable=true), which threads ``--noMain``
#     onto the Nim library's Phase 1 so the resulting archive's
#     ``main()`` doesn't collide with the Rust binary's own entry point.
#     The Rust source includes ``extern "C" { fn NimMain(); fn nimX();
#     }`` and calls ``NimMain()`` once at startup.
#
# Action-id prefixes for Rust cross-language emit are
# ``nim-xlang-rust-lib-link-<name>`` (forward staticlib emit) and
# ``nim-xlang-rust-exec-link-<name>`` (reverse binary emit). The
# discriminator mirrors the C/C++ helper's ``nim-xlang-ccpp-*`` shape so
# tests can partition the two cross-language matrices.
# ---------------------------------------------------------------------------

type
  RustCrossLibrary = object
    ## Cross-language Rust ``library`` member belonging to a ``uses:
    ## rust/rustc`` package in a workspace whose dispatch is owned by the
    ## Nim convention. Discovered by ``collectRustCrossLibraries`` and
    ## emitted in-line as a single ``rustc --crate-type=staticlib``
    ## action. Output lands at ``<root>/.repro/build/<libName>/lib<libName>.a``.
    package*: string
    libraryName*: string
    srcDir*: string
    entrySource*: string

  RustCrossExecutable = object
    ## Cross-language Rust ``executable`` member belonging to a ``uses:
    ## rust/rustc`` package. Discovered by ``collectRustCrossExecutables``
    ## and emitted in-line as a single ``rustc --crate-type=bin`` action.
    ## When the executable's package ``depends_on`` a Nim library
    ## package, the upstream Nim archive is threaded onto the rustc link
    ## argv via ``-L native=<dir>`` + ``-l static=<libname>``.
    package*: string
    executableName*: string
    srcDir*: string
    entrySource*: string

proc rustCrossScratch(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc rustCrossStaticlibPath(projectRoot, member: string): string =
  ## ``<root>/.repro/build/<member>/lib<member>.a`` — canonical
  ## cross-language archive schema shared with c-cpp-direct + Nim's
  ## own static library output + rust_direct's reverse staticlib
  ## emit.
  rustCrossScratch(projectRoot, member) / ("lib" & member & ".a")

proc rustCrossBinaryPath(projectRoot, member: string): string =
  when defined(windows):
    rustCrossScratch(projectRoot, member) / (member & ".exe")
  else:
    rustCrossScratch(projectRoot, member) / member

proc rustcCrossCompiler(): string =
  findExe("rustc")

proc collectRustSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.rs`` under ``srcDir`` recursively. Used as the declared
  ## ``inputs`` set of the rustc action so a source-only edit invalidates
  ## the cache without depending on the io-monitor monitor.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isRustSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc resolveRustCrossMember(projectRoot, memberName, memberKind: string):
    tuple[srcDir, entrySource: string] =
  ## Wrapper over the shared Mode 3 Rust scanner helper. Returns empty
  ## strings when no layout matches; the caller skips the member.
  let resolved = resolveRustMemberDirs(projectRoot, memberName, memberKind)
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource

proc collectRustCrossLibraries(projectRoot, source: string;
                               usesEntries: openArray[PackageUsesEntry]):
                                 seq[RustCrossLibrary] =
  ## Walk the project file for ``library`` declarations inside packages
  ## whose ``uses:`` block names ``rust`` or ``rustc``. Each resolvable
  ## member becomes a ``RustCrossLibrary`` carrying its source set + crate
  ## root (used downstream to emit a single ``rustc --crate-type=staticlib``
  ## action). Executables in Rust packages are routed through
  ## ``collectRustCrossExecutables`` separately.
  let ownership = extractPackageMembers(source)
  for entry in ownership:
    if entry.kind != "library":
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAny(usesEntries, entry.package, ["rust", "rustc"]):
      continue
    let resolved = resolveRustCrossMember(projectRoot, entry.member, "library")
    if resolved.entrySource.len == 0:
      continue
    result.add(RustCrossLibrary(
      package: entry.package,
      libraryName: entry.member,
      srcDir: resolved.srcDir,
      entrySource: resolved.entrySource))

proc collectRustCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[PackageUsesEntry]):
                                   seq[RustCrossExecutable] =
  ## Walk the project file for ``executable`` declarations inside
  ## packages whose ``uses:`` block names ``rust`` or ``rustc``. Each
  ## resolvable member becomes a ``RustCrossExecutable``; emit downstream
  ## produces a single ``rustc --crate-type=bin`` action that picks up
  ## any upstream Nim staticlibs the depends_on edges resolve to.
  let ownership = extractPackageMembers(source)
  for entry in ownership:
    if entry.kind != "executable":
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAny(usesEntries, entry.package, ["rust", "rustc"]):
      continue
    let resolved = resolveRustCrossMember(projectRoot, entry.member,
      "executable")
    if resolved.entrySource.len == 0:
      continue
    result.add(RustCrossExecutable(
      package: entry.package,
      executableName: entry.member,
      srcDir: resolved.srcDir,
      entrySource: resolved.entrySource))

proc rustCrossRuntimeLinkLibs(): seq[string] =
  ## Platform-specific link libs a Rust staticlib carries unresolved
  ## references to. The Nim entrypoint's gcc link picks these up so the
  ## resulting binary can satisfy the Rust archive's references to
  ## platform APIs. Hard-coded set mirrors ``rust_direct.rustRuntimeLinkLibs``
  ## (same trade-off; dynamic resolution via ``rustc --print=native-static-libs``
  ## deferred per M34 outstanding tasks).
  when defined(windows):
    @["-lws2_32", "-luserenv", "-ladvapi32", "-lbcrypt", "-lntdll"]
  else:
    @["-lpthread", "-ldl", "-lm"]

proc rustFnv1aHex(value: string): string =
  ## FNV-1a 64-bit hash, hex-encoded. Same algorithm as rust_direct's
  ## ``fnv1aHex`` — kept local so this convention doesn't import the
  ## sibling module.
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

const RustCrossEdition = "2021"
  ## Edition fed to ``rustc --edition``. Mirrors ``rust_direct.RustEdition``.

proc emitRustCrossLibrary(projectRoot: string;
                          lib: RustCrossLibrary): BuildActionDef =
  ## ``rustc --crate-type=staticlib`` action for one cross-language Rust
  ## library. Output lands at the canonical archive schema
  ## ``<root>/.repro/build/<name>/lib<name>.a``. ``-C panic=abort`` is
  ## threaded unconditionally so a no_std staticlib (the realistic FFI
  ## pattern) links cleanly with rustc's precompiled core crate; the flag
  ## is harmless for staticlibs that use std (rustc selects abort runtime
  ## instead of unwind).
  let rustcExe = rustcCrossCompiler()
  if rustcExe.len == 0:
    raise newException(ValueError,
      "nim convention (mixed workspace): 'rustc' not on PATH; cannot " &
        "compile upstream Rust library '" & lib.libraryName &
        "' for cross-language consumption")
  let outputPath = rustCrossStaticlibPath(projectRoot, lib.libraryName)
  createDir(extendedPath(parentDir(outputPath)))
  let crateName = normaliseRustCrateName(lib.libraryName)
  let metaHash = rustFnv1aHex(lib.libraryName & "@" & RustCrossEdition)
  var argv = @[
    rustcExe,
    "--crate-name", crateName,
    "--edition", RustCrossEdition,
    "--crate-type", "staticlib",
    "--emit=link",
    "-C", "opt-level=2",
    "-C", "metadata=" & metaHash,
    "-C", "panic=abort",
    "-o", outputPath,
    lib.entrySource,
  ]
  let inputs = collectRustSourcesUnderSrcDir(lib.srcDir)
  buildAction(
    id = "nim-xlang-rust-lib-link-" & ccppSanitize(lib.libraryName),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.xlang.rust.lib.link")

proc emitRustCrossExecutable(projectRoot: string;
                             exec: RustCrossExecutable;
                             nimUpstream:
                               openArray[NimUpstreamLibrary]): BuildActionDef =
  ## ``rustc --crate-type=bin`` action for one cross-language Rust
  ## executable. The link argv carries ``-L native=<dir>`` + ``-l
  ## static=<libname>`` per upstream Nim staticlib, plus the
  ## platform-specific Nim runtime libs (``-lm`` on POSIX; nothing extra
  ## on Windows MinGW — rustc's link line picks the C runtime up
  ## implicitly). The Rust source initialises Nim via an explicit
  ## ``NimMain()`` call at startup; the Nim library was emitted with
  ## ``--noMain`` (via ``cConsumable`` derivation) so no ``main`` symbol
  ## collides with Rust's entry point.
  ##
  ## **Windows toolchain note**: when the Rust binary links against a
  ## Nim archive AND we're on Windows, the rustc invocation is forced to
  ## ``--target x86_64-pc-windows-gnu`` so rustc uses the gcc-mingw
  ## linker (which understands the MinGW gcc-compiled object files in
  ## the Nim archive — Nim's runtime references symbols like
  ## ``__mingw_printf`` / ``__emutls_get_address`` that MSVC link.exe
  ## cannot resolve). The default ``x86_64-pc-windows-msvc`` target
  ## remains in use for pure-Rust workspaces; only the cross-language
  ## reverse direction switches. Requires the gnu target to be
  ## installed (``rustup target add x86_64-pc-windows-gnu``) — the
  ## per-fixture probe in the validation script skips with a clear
  ## diagnostic when the target is missing.
  let rustcExe = rustcCrossCompiler()
  if rustcExe.len == 0:
    raise newException(ValueError,
      "nim convention (mixed workspace): 'rustc' not on PATH; cannot " &
        "compile cross-language Rust executable '" & exec.executableName & "'")
  let outputPath = rustCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(outputPath)))
  let crateName = normaliseRustCrateName(exec.executableName)
  let metaHash = rustFnv1aHex(exec.executableName & "@" & RustCrossEdition)
  var argv = @[
    rustcExe,
    "--crate-name", crateName,
    "--edition", RustCrossEdition,
    "--crate-type", "bin",
    "--emit=link",
    "-C", "opt-level=2",
    "-C", "metadata=" & metaHash,
    "-o", outputPath,
  ]
  # M35 Windows cross-toolchain fix: rustc's default target on a
  # Windows MSVC-built host is ``x86_64-pc-windows-msvc``, which makes
  # rustc invoke ``link.exe`` (MSVC's linker). MSVC link.exe doesn't
  # understand MinGW gcc-compiled object files (the Nim archive's
  # contents) — symbols like ``__mingw_printf`` and ``__emutls_get_address``
  # remain unresolved. Forcing the target to ``x86_64-pc-windows-gnu``
  # routes rustc through its gcc-mingw linker which CAN resolve those
  # references. Required only when there's a Nim upstream to link
  # against; pure-Rust workspaces continue to use the host default.
  when defined(windows):
    if nimUpstream.len > 0:
      argv.add("--target")
      argv.add("x86_64-pc-windows-gnu")
  # Thread upstream Nim staticlibs onto the rustc link via -L native +
  # -l static. Each unique native dir lands once; the -l static=<libname>
  # entries follow so rustc/ld picks them up in declared order.
  var seenNativeDirs: seq[string] = @[]
  for lib in nimUpstream:
    let nativeDir = parentDir(lib.outputPath)
    if seenNativeDirs.find(nativeDir) < 0:
      argv.add("-L")
      argv.add("native=" & nativeDir)
      seenNativeDirs.add(nativeDir)
  for lib in nimUpstream:
    argv.add("-l")
    argv.add("static=" & lib.libraryName)
  # Nim's static archive references libm on POSIX (the runtime touches
  # math symbols for float formatting). rustc handles -lm via its own
  # link-line on POSIX; we add it explicitly so the Nim runtime symbols
  # resolve even if a future rustc default drops it. Empty on Windows
  # MinGW (rustc's default link line covers the C runtime via msvcrt
  # implicitly when --target=x86_64-pc-windows-gnu is set).
  when not defined(windows):
    if nimUpstream.len > 0:
      argv.add("-l")
      argv.add("m")
  argv.add(exec.entrySource)
  var inputs = collectRustSourcesUnderSrcDir(exec.srcDir)
  for lib in nimUpstream:
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  var deps: seq[string] = @[]
  for lib in nimUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
  buildAction(
    id = "nim-xlang-rust-exec-link-" & ccppSanitize(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "nim.xlang.rust.exec.link")

proc readScannedDepsSource(projectRoot: string): string =
  ## Read ``<projectRoot>/repro.scanned-deps.nim`` when present and the
  ## project file ``include``s it. Returns the empty string in every
  ## other case — there is no scanned-deps file, the file is unreadable,
  ## or the project file doesn't ``include`` it. Used to fold the
  ## machine-authored ``depends_on`` edges into the convention's
  ## workspace-dep resolution alongside any hand-written edges in
  ## ``repro.nim``.
  let scannedPath = projectRoot / "repro.scanned-deps.nim"
  if not fileExists(extendedPath(scannedPath)):
    return ""
  let projectFile = resolveProjectFile(projectRoot).path
  if projectFile.len == 0:
    return ""
  if not scannedDepsArePresent(projectFile):
    return ""
  try:
    readFile(extendedPath(scannedPath))
  except CatchableError:
    ""

proc collectWorkspaceDepEdges(projectRoot, source: string):
    seq[ManualDepEdge] =
  ## Aggregate every ``depends_on`` edge declared in ``repro.nim`` plus
  ## (optionally) the included ``repro.scanned-deps.nim`` text. The two
  ## sources are unioned as a multiset; ``extractManualDependsOnFromText``
  ## returns edges in source order so the caller's later dedup pass
  ## preserves a deterministic ordering.
  result = extractManualDependsOnFromText(source)
  let scanned = readScannedDepsSource(projectRoot)
  if scanned.len > 0:
    for edge in extractManualDependsOnFromText(scanned):
      result.add(edge)

proc dedupDepEdges(edges: openArray[ManualDepEdge]): seq[ManualDepEdge] =
  ## Collapse identical ``(fromPackage, toPackage)`` pairs into one
  ## entry. Source-line metadata of the first occurrence wins so error
  ## messages point at the earliest evidence the operator can see.
  var seen: seq[string] = @[]
  for edge in edges:
    let key = edge.fromPackage & "\x1f" & edge.toPackage
    if seen.find(key) >= 0:
      continue
    seen.add(key)
    result.add(edge)

proc detectDepCycle(edges: openArray[ManualDepEdge];
                    packages: openArray[string]): seq[string] =
  ## Return one cycle path (in declaration order) if the dep graph
  ## contains a cycle, else the empty seq. Standard Tarjan-style DFS
  ## using three-state colouring; the returned path starts and ends at
  ## the same node so the caller can rendering "A -> B -> A".
  ##
  ## Edges referencing packages NOT in ``packages`` are ignored here —
  ## the undeclared-dep check runs separately and produces a more
  ## helpful diagnostic. We don't want a missing-dep typo to also
  ## report a spurious "no cycle found" outcome.
  var adj = initTable[string, seq[string]]()
  for pkg in packages:
    adj[pkg] = @[]
  for edge in edges:
    if adj.hasKey(edge.fromPackage) and adj.hasKey(edge.toPackage):
      adj[edge.fromPackage].add(edge.toPackage)
  const White = 0
  const Gray = 1
  const Black = 2
  var colour = initTable[string, int]()
  for pkg in packages:
    colour[pkg] = White
  var stack: seq[string] = @[]
  proc dfs(node: string): seq[string] =
    colour[node] = Gray
    stack.add(node)
    for nxt in adj[node]:
      if not colour.hasKey(nxt):
        continue
      case colour[nxt]
      of Gray:
        # Found a cycle; rewind stack to the first occurrence of nxt.
        var cycle: seq[string] = @[]
        var started = false
        for item in stack:
          if started or item == nxt:
            started = true
            cycle.add(item)
        cycle.add(nxt)
        return cycle
      of White:
        let nested = dfs(nxt)
        if nested.len > 0:
          return nested
      else:
        discard
    discard stack.pop()
    colour[node] = Black
    return @[]
  for pkg in packages:
    if colour[pkg] == White:
      let cycle = dfs(pkg)
      if cycle.len > 0:
        return cycle
  @[]

proc validateWorkspaceDeps*(edges: openArray[ManualDepEdge];
                            declaredPackages: openArray[string]) =
  ## Mode 3 dep-graph validation. Raises ``ValueError`` with a
  ## human-readable diagnostic when:
  ##
  ##   * an edge names a ``fromPackage`` or ``toPackage`` that doesn't
  ##     match any declared workspace package, OR
  ##   * the resulting graph contains a cycle.
  ##
  ## The standard provider binary turns the ``ValueError`` into a
  ## non-zero exit + a "repro-standard-provider:" prefixed message — see
  ## ``apps/repro-standard-provider/repro_standard_provider.nim``.
  for edge in edges:
    if declaredPackages.find(edge.fromPackage) < 0:
      raise newException(ValueError,
        "nim convention: depends_on references undeclared package '" &
          edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "nim convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "nim convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      entrypoints: seq[NimEntrypoint];
                      libraries: seq[NimLibraryTarget] = @[]): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants. The Nim
  ## convention doesn't go through DSL evaluation, so we synthesise the
  ## shape ``buildPackageFragment`` needs purely from the recognised
  ## members. ``packageName`` shows up in diagnostics only.
  var name = "nim_convention"
  if entrypoints.len > 0:
    name = entrypoints[0].name
  elif libraries.len > 0:
    name = libraries[0].name
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: name,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc nimEmitFragment(projectRoot: string;
                     request: ProviderGraphRequest): GraphFragment {.gcsafe.} =
  ## Convention entry — eager Phase 1, parse manifest, register Phase
  ## 2/3 via the DSL, hand the whole thing to
  ## ``buildPackageFragment`` so the standard runtime emits the
  ## GraphFragment with all the engine-side bookkeeping (digest,
  ## evaluationInputs, target metadata).
  ##
  ## The DSL runtime mutates module-level registries that aren't
  ## annotated ``gcsafe`` (they predate the provider host). The
  ## standard-provider binary is single-threaded so the ``cast(gcsafe)``
  ## block below is the established escape hatch — same shape the
  ## trycompile provider uses to call ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let entrypoints = collectEntrypoints(projectRoot, source)
    let allLibraries = collectLibraries(projectRoot, source)
    let usesEntries = extractPackageUses(source)
    # Header-only libraries emit no actions but still need to be
    # acknowledged by the convention. Filter them out at the convention
    # level so emitForLibrary never receives one.
    var buildableLibraries: seq[NimLibraryTarget] = @[]
    for lib in allLibraries:
      if lib.kind != nlkHeaderOnly:
        buildableLibraries.add(lib)
    # Cross-language: enumerate C/C++ library members the Nim
    # convention should emit upstream archives for. These belong to
    # packages whose ``uses:`` lists ``gcc`` or ``clang`` (NOT
    # ``nim``). The mixed-workspace contract emits the archive in-line
    # so the cross-package ``depends_on nimApp: cppLib`` edge produces
    # a coherent action graph within a single buildPackageFragment
    # call.
    let cCppCrossMembers = collectCCppCrossMembers(
      projectRoot, source, usesEntries)
    # Reverse cross-language: enumerate C/C++ executable members in
    # ``uses: gcc/clang`` packages. The Nim convention emits the
    # per-source compile + terminal link actions in-line so a
    # ``depends_on cppApp: nimLibPkg`` edge wires the upstream Nim
    # archive onto the C/C++ binary's link line within the same
    # ``buildPackageFragment`` call. Library members in the same
    # packages are routed through ``collectCCppCrossMembers`` above —
    # the two collectors partition by ``kind``.
    let cCppCrossExecutables = collectCCppCrossExecutables(
      projectRoot, source, usesEntries)
    # M35 forward cross-language (Nim app uses Rust lib): enumerate
    # Rust ``library`` members in ``uses: rust/rustc`` packages. The
    # Nim convention emits a single ``rustc --crate-type=staticlib``
    # action per library, landing at the canonical archive path so the
    # Nim entrypoint's Phase 3 gcc link can pick it up via a trailing
    # positional + the Rust runtime libs. Mirrors the C/C++ forward
    # direction's shape.
    let rustCrossLibraries = collectRustCrossLibraries(
      projectRoot, source, usesEntries)
    # M35 reverse cross-language (Rust app uses Nim lib): enumerate
    # Rust ``executable`` members in ``uses: rust/rustc`` packages. The
    # Nim convention emits a single ``rustc --crate-type=bin`` action
    # per executable; each binary's link argv carries
    # ``-L native=<dir>`` ``-l static=<libname>`` for any upstream Nim
    # staticlib the depends_on edge resolves to. The Nim library's
    # ``cConsumable`` toggle drives the ``--noMain`` flag (see below)
    # so the archive's ``main`` symbol doesn't collide with Rust's own
    # entry point.
    let rustCrossExecutables = collectRustCrossExecutables(
      projectRoot, source, usesEntries)
    if entrypoints.len == 0 and buildableLibraries.len == 0 and
        cCppCrossMembers.len == 0 and cCppCrossExecutables.len == 0 and
        rustCrossLibraries.len == 0 and rustCrossExecutables.len == 0:
      if allLibraries.len > 0:
        raise newException(ValueError,
          "nim convention: package declares only header-only libraries; " &
            "no compile/link actions to emit. Add an executable or a " &
            "static/shared library member.")
      raise newException(ValueError,
        "nim convention: no executable or library entry points " &
          "discovered under " & projectRoot)
    let nimExe = nimExecutable()
    if nimExe.len == 0:
      raise newException(ValueError,
        "nim convention: 'nim' executable not on PATH; cannot run Phase 1")
    let pkg = syntheticPackage(projectRoot, entrypoints, buildableLibraries)
    # Mode 3 ``depends_on`` resolution: collect every workspace dep edge
    # (manual + scanner-emitted) and validate them against the set of
    # packages the project file actually declares. Validation rejects
    # cycles and references to undeclared packages BEFORE any expensive
    # ``nim c`` invocation runs — the diagnostic is immediate, and
    # nothing in ``.repro/build`` is touched on failure.
    let rawDepEdges = collectWorkspaceDepEdges(projectRoot, source)
    let depEdges = dedupDepEdges(rawDepEdges)
    var declaredPackages: seq[string] = @[]
    for entry in entrypoints:
      if entry.package.len > 0 and
          declaredPackages.find(entry.package) < 0:
        declaredPackages.add(entry.package)
    for lib in buildableLibraries:
      if lib.package.len > 0 and
          declaredPackages.find(lib.package) < 0:
        declaredPackages.add(lib.package)
    # Cross-language: include any C/C++ packages we're going to emit
    # archives for so the validator accepts ``depends_on nimApp: cppLib``
    # without spuriously rejecting cppLib as undeclared.
    for member in cCppCrossMembers:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    # Reverse cross-language: include C/C++ executable packages so the
    # validator accepts ``depends_on cppApp: nimLibPkg`` (cppApp is the
    # ``fromPackage`` here; if it's not declared, the validation pass
    # rejects the edge as undeclared).
    for exec in cCppCrossExecutables:
      if exec.package.len > 0 and
          declaredPackages.find(exec.package) < 0:
        declaredPackages.add(exec.package)
    # M35 forward cross-language: include Rust library packages so
    # ``depends_on nimApp: rustLibPkg`` survives validation.
    for lib in rustCrossLibraries:
      if lib.package.len > 0 and
          declaredPackages.find(lib.package) < 0:
        declaredPackages.add(lib.package)
    # M35 reverse cross-language: include Rust executable packages so
    # ``depends_on rustApp: nimLibPkg`` survives validation.
    for exec in rustCrossExecutables:
      if exec.package.len > 0 and
          declaredPackages.find(exec.package) < 0:
        declaredPackages.add(exec.package)
    validateWorkspaceDeps(depEdges, declaredPackages)

    # Reverse cross-language: mark Nim libraries as ``cConsumable`` so
    # ``emitForLibrary`` adds ``--noMain`` to Phase 1 — Nim's default
    # ``int main(...)`` is in the entry's translation unit (not pulled
    # in by demand at link time), so once the C/C++ binary's link picks
    # up the archive to resolve ``NimMain``/user exports, the archive's
    # ``main`` symbol collides with the C/C++ binary's own ``main``.
    # ``--noMain`` suppresses Nim's ``main`` while keeping ``NimMain``.
    #
    # A library is marked cConsumable when ANY C/C++ executable in the
    # workspace ``depends_on`` the library's package. We rebuild the
    # ``buildableLibraries`` seq in place so the downstream emit pass
    # sees the right toggle. Pure same-language consumption (Nim app ->
    # Nim lib) doesn't need ``--noMain``: the Nim entrypoint has its
    # own ``main`` already and the linker doesn't pull in the archive's
    # member for that symbol — but ``--noMain`` is harmless there too
    # (the executable's link uses its own entrypoint's main).
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    # M35 reverse cross-language: a Rust executable consuming a Nim
    # library has the same ``main``-collision concern. Without
    # ``--noMain``, the Nim archive's ``int main(...)`` collides with
    # Rust's own entry point (rustc emits ``fn main()`` from the
    # executable crate's lib.rs/main.rs). Mark the library cConsumable
    # so its Phase 1 picks up ``--noMain``; the Rust executable then
    # calls ``NimMain()`` explicitly before any Nim function.
    for exec in rustCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[NimLibraryTarget] = @[]
      for lib in buildableLibraries:
        var entry = lib
        if entry.package.len > 0 and
            cConsumedPackages.find(entry.package) >= 0:
          entry.cConsumable = true
        rewritten.add(entry)
      buildableLibraries = rewritten
    # M22: discover ``tests/test_*.nim`` once at the top so registerAll
    # only walks the filesystem a single time per emit.
    let testFiles = collectNimTestFiles(projectRoot)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      var testActions: seq[BuildActionDef] = @[]
      # Cross-language: emit C/C++ archives FIRST so each Nim
      # entrypoint's link can reference the archive output path + link
      # action id by the time we hand it to emitForEntrypoint.
      var packageCCppLibraries =
        initTable[string, seq[CCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = CCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # M35 forward cross-language: emit Rust staticlibs alongside C/C++
      # archives so the Nim entrypoint's Phase 3 link can pick them up
      # via trailing positionals (same shape as the C/C++ side; the
      # only difference is the Rust runtime libs that follow). Index
      # by owning package so a ``depends_on nimApp: rustLibPkg`` edge
      # resolves to "every Rust library member of rustLibPkg".
      var packageRustUpstream =
        initTable[string, seq[RustWorkspaceUpstream]]()
      for lib in rustCrossLibraries:
        let action = emitRustCrossLibrary(projectRoot, lib)
        allActions.add(action)
        let entry = RustWorkspaceUpstream(
          package: lib.package,
          libraryName: lib.libraryName,
          linkActionId: action.id,
          outputPath: action.outputs[0])
        if not packageRustUpstream.hasKey(lib.package):
          packageRustUpstream[lib.package] = @[]
        packageRustUpstream[lib.package].add(entry)
        discard target(lib.libraryName, allActions)
      # Mode 3 dep wiring: emit Nim LIBRARIES next so their link-action
      # ids + archive output paths are known by the time we reach each
      # executable's Phase 3. Index libraries by owning package so
      # ``depends_on hello: greet`` can resolve to "every library member
      # of the greet package". A package may declare multiple libraries
      # — the executable's link gets all of them on its argv.
      var packageLibraries = initTable[string, seq[NimWorkspaceLibrary]]()
      # Reverse cross-language: when a Nim library's package is the
      # ``toPackage`` of a C/C++ executable's depends_on edge, we
      # additionally remember the Nim archive (link-action id +
      # output path) keyed by package so the C/C++ executable's link
      # can pick it up below.
      var packageNimUpstream = initTable[string, seq[NimUpstreamLibrary]]()
      for lib in buildableLibraries:
        let bundle = emitForLibrary(projectRoot, nimExe, lib)
        allActions.add(bundle.phase1)
        for a in bundle.phase2:
          allActions.add(a)
        for a in bundle.phase3:
          allActions.add(a)
        if lib.package.len > 0:
          # Pick the first Phase 3 action's output as the canonical
          # library artefact for the dep-wiring layer. Static
          # libraries always emit a single ``ar`` action; ``both``
          # libraries emit static + shared and we prefer the static
          # archive for link-line wiring (mirrors the executable
          # default ``-Bstatic`` behaviour). Shared-only libraries
          # use their ``.so``/``.dll``/``.dylib`` output.
          if bundle.phase3.len > 0:
            let chosen = bundle.phase3[0]
            if chosen.outputs.len > 0:
              let entry = NimWorkspaceLibrary(
                libraryName: lib.name,
                package: lib.package,
                linkActionId: chosen.id,
                outputPath: chosen.outputs[0],
                kind: lib.kind)
              if not packageLibraries.hasKey(lib.package):
                packageLibraries[lib.package] = @[]
              packageLibraries[lib.package].add(entry)
              # Reverse cross-language: route the SAME archive to a
              # downstream C/C++ executable. For ``kind: both`` libraries
              # we prefer the static archive (Phase 3's first entry) for
              # the same reason same-language wiring does.
              if lib.cConsumable:
                let nimUp = NimUpstreamLibrary(
                  package: lib.package,
                  libraryName: lib.name,
                  linkActionId: chosen.id,
                  outputPath: chosen.outputs[0])
                if not packageNimUpstream.hasKey(lib.package):
                  packageNimUpstream[lib.package] = @[]
                packageNimUpstream[lib.package].add(nimUp)
        discard target(lib.name, allActions)
      # Resolve dep edges for each entrypoint: the set of libraries
      # imported by the executable's package, in declaration order.
      # Both Nim and C/C++ deps are looked up here — the schema-by-
      # convention design means the entrypoint's link gets both flavours
      # threaded onto its argv naturally.
      for entry in entrypoints:
        var entryDeps: seq[NimWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[CCppUpstreamLibrary] = @[]
        var entryRustDeps: seq[RustWorkspaceUpstream] = @[]
        if entry.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != entry.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                entryDeps.add(lib)
            if packageCCppLibraries.hasKey(edge.toPackage):
              for lib in packageCCppLibraries[edge.toPackage]:
                entryCCppDeps.add(lib)
            if packageRustUpstream.hasKey(edge.toPackage):
              for lib in packageRustUpstream[edge.toPackage]:
                entryRustDeps.add(lib)
            # A dep on a declared package that ships no library
            # member of either flavour (executable-only package) is
            # legal — silent no-op for the link line, build-order
            # sequencing comes once executable-on-executable wiring
            # lands.
        let triple = emitForEntrypoint(projectRoot, nimExe, entry,
          entryDeps, entryCCppDeps, entryRustDeps)
        allActions.add(triple.phase1)
        for a in triple.phase2:
          allActions.add(a)
        allActions.add(triple.phase3)
        discard target(entry.name, allActions)
      # Reverse cross-language: emit C/C++ executables LAST so each
      # binary's link can reference the upstream Nim archive's
      # link-action id + output path. The depends_on edge map indexes
      # the cppApp's upstream Nim libs by ``toPackage``; for each edge
      # whose ``toPackage`` resolved a Nim library we thread the
      # archive onto the C/C++ link.
      for exec in cCppCrossExecutables:
        var execNimUpstream: seq[NimUpstreamLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageNimUpstream.hasKey(edge.toPackage):
              for nimLib in packageNimUpstream[edge.toPackage]:
                execNimUpstream.add(nimLib)
            # Cross-language dep on a C/C++ library is already handled
            # via the upstream-archive emit at the top of this proc —
            # nothing further to do here because the C/C++ binary's
            # ``-I``/``-L`` for sibling C/C++ packages is out of scope
            # for this milestone (no fixture exercises it). Silent
            # no-op preserves the build's success when only the
            # cross-language edge is present.
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execNimUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      # M35 reverse cross-language: emit Rust executables LAST so each
      # binary's link can reference the upstream Nim archive's
      # link-action id + output path. The depends_on edge map indexes
      # the rustApp's upstream Nim libs by ``toPackage``; for each edge
      # whose ``toPackage`` resolved a Nim library we thread the
      # archive onto the rustc link via ``-L native=<dir>`` + ``-l
      # static=<libname>``. Mirror of the C/C++ reverse direction
      # above; the only difference is the rustc invocation (vs gcc)
      # and the Nim runtime libs (``-lm`` on POSIX only — Windows
      # MinGW's rustc-default link line picks up the C runtime).
      for exec in rustCrossExecutables:
        var execNimUpstream: seq[NimUpstreamLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageNimUpstream.hasKey(edge.toPackage):
              for nimLib in packageNimUpstream[edge.toPackage]:
                execNimUpstream.add(nimLib)
        let action = emitRustCrossExecutable(projectRoot, exec,
          execNimUpstream)
        allActions.add(action)
        discard target(exec.executableName, allActions)
      if entrypoints.len > 0 or buildableLibraries.len > 0 or
          cCppCrossMembers.len > 0 or cCppCrossExecutables.len > 0 or
          rustCrossLibraries.len > 0 or rustCrossExecutables.len > 0:
        defaultTarget(target("default", allActions))
      # M22 test-target emission. Each ``tests/test_*.nim`` file becomes
      # a (nim c -r, fs.stamp) action pair. The test target is non-
      # default so ``repro build .#default`` doesn't run the tests; the
      # operator opts in via ``repro build .#test``. When no test files
      # are present the target isn't emitted at all (current behaviour
      # for nim/binary, nim/multi-binary, nim/library stays unchanged).
      if testFiles.len > 0:
        let nimSources = collectNimSources(projectRoot / "src")
        for testFile in testFiles:
          let pair = emitTestAction(projectRoot, nimExe, testFile,
            nimSources)
          testActions.add(pair.run)
          testActions.add(pair.stamp)
        discard target("test", testActions)
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc nimConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Provider plugins typically expose a ``XConvention()`` factory so
  ## consumers can also build *isolated* registries for tests without
  ## touching ``defaultConventionRegistry``.
  LanguageConvention(
    name: "nim",
    recognize: nimRecognize,
    emitFragment: nimEmitFragment)
