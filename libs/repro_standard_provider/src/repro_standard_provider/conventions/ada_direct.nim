## Ada (Mode 3) language convention (Tier 2b).
##
## Mode 3 minimal Ada convention for projects whose ``repro.nim`` declares
## an Ada ``executable`` / ``library`` member AND DOES NOT ship a
## ``.gpr`` (GNAT project file) at the workspace root. The convention
## builds the per-member compile + link graph from pure layout — no
## ``.gpr`` manifest needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M58 section of
## ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``d-direct`` per the M58 spec —
## seventh Mode 3 language):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``ada``, ``gnat``, or ``gnatmake``.
##   * NO ``<projectRoot>/*.gpr`` (GNAT project file) at the workspace
##     root. The future Mode 2 Ada convention's territory (deferred per
##     the M58 honest-scope cut — Mode 3 only for M58).
##   * At least one ``executable`` / ``library`` member is declared
##     AND resolves to a non-empty Ada source layout (Layout A or B).
##   * ``gnatmake`` is on PATH at convention-emit time.
##
## **Layout**:
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.adb        (executable)
##       <projectRoot>/src/lib.adb         (library; ``<member>.adb``
##                                          also accepted as a fallback)
##
##   Layout B — multiple packages per project file::
##
##       <projectRoot>/<member>/src/main.adb (executable)
##       <projectRoot>/<member>/src/lib.adb  (library)
##
## **Per-member argv**:
##
## | Member kind            | Argv                                          |
## |------------------------|-----------------------------------------------|
## | executable             | ``gnatmake -O2 -o <out> <src.adb>``           |
## | library (static)       | ``gcc -c -O2 -gnatp <src.adb>*`` then         |
## |                        | ``ar rcs <root>/.repro/build/<n>/lib<n>.a *.o``|
##
## For libraries we emit a per-source ``gcc -c -gnatp`` compile (Ada
## front-end via the gcc driver — gnatmake's all-in-one driver isn't
## a fit for static-archive packaging because it bundles bind +
## elaboration steps that don't apply to an archive). The resulting
## ``.o`` files are then packaged via ``ar rcs`` into the canonical
## ``<root>/.repro/build/<n>/lib<n>.a`` schema shared with the other
## Mode 3 obj+linker conventions (``c-cpp-direct``, ``fortran-direct``,
## ``rust-direct`` staticlib path, ``zig-direct``, ``d-direct``).
##
## The ``-gnatp`` flag suppresses Ada runtime checks (constraint /
## elaboration / overflow) — those would otherwise pull in the full
## GNAT runtime even for pure functions. For M58's "pure-Ada function
## with no elaboration" honest-scope cut this keeps the archive
## C-consumable without ``adainit()``/``adafinal()`` bracket calls.
##
## **M58 cross-language Ada ↔ C/C++**:
##
##   * **Forward (Ada binary → C library)**: an Ada ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers
##     emit per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The Ada
##     binary's ``gnatmake`` link gains the C archive via the gnatmake
##     trailing ``-largs -L<dir> -l:lib<name>.a`` linker pass-through
##     (gnatmake's ``-largs`` separator forwards everything after it
##     to the underlying linker). The Ada source declares the C
##     function via ``pragma Import (C, ...)``.
##
##   * **Reverse (C/C++ binary → Ada library)**: a C/C++ ``executable``
##     ``depends_on`` an Ada ``library`` member. The Ada library's
##     ``cConsumable`` flag is derived from the dep edge; the archive
##     shape is the same ``ar rcs`` static archive either way (Ada
##     static libs are C-ABI compatible when routines carry ``pragma
##     Export (C, ...)`` AND no Ada elaboration is required). Embedded
##     helpers then emit the C/C++ binary's per-source ``g++ -c`` +
##     terminal ``g++ -o`` link action; the Ada staticlib lands on the
##     link argv as a trailing positional.
##
##     The M58 honest-scope cut limits the reverse fixture to ``pragma
##     Export (C, ...)`` no-elaboration entry points (no ``Ada.Text_IO``,
##     no tagged types, no controlled types) so the gcc driver resolves
##     all references against the archive itself without ``-lgnat`` /
##     ``-lgnarl`` runtime libs and without explicit ``adainit()`` /
##     ``adafinal()`` bracket calls — same property Zig's M44 and D's
##     M45 reverse fixtures rely on for their respective runtimes.
##     Full GNAT runtime linking + tasking (``-lgnarl``) is deferred to
##     a future milestone.
##
## Action-id prefixes for cross-language emit are
## ``ada-xlang-ccpp-compile-*``, ``ada-xlang-ccpp-archive-*``,
## ``ada-xlang-ccpp-exec-compile-*``, ``ada-xlang-ccpp-exec-link-*``
## (mirror of the rust-direct ``rust-xlang-ccpp-...`` / fortran-direct
## ``fortran-xlang-ccpp-...`` / zig-direct ``zig-xlang-ccpp-...`` /
## d-direct ``d-xlang-ccpp-...`` discriminators).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Mode 2 ``.gpr`` / ``gprbuild`` recognition + delegation —
##     deferred. The future Mode 2 Ada convention will key on
##     ``<name>.gpr`` and shell out to ``gprbuild -P <name>.gpr``.
##     ``gprbuild`` is a sophisticated build system in its own right;
##     Mode 3 only for M58 per the milestone's honest cut.
##   * Full Ada elaboration via ``gnatbind -n`` + ``adainit()`` /
##     ``adafinal()`` bracket calls — deferred. The M58 fixture
##     restricts cross-language Ada functions to ``pragma Export (C, ...)``
##     pure no-elaboration routines.
##   * Ada tasking (``-lgnarl``) reverse direction — deferred.
##   * ``with`` clause cross-package scanner — deferred. Cross-package
##     edges are hand-authored as ``depends_on`` in ``repro.nim`` until
##     a future milestone adds a ``with Pkg.Sub;`` scanner.
##   * Multi-target / multi-arch — deferred.
##   * Ada-2012 contracts (``Pre`` / ``Post`` aspects) — out of scope.
##   * Test discovery (``AUnit`` / ``Ahven``) — deferred.
##   * Ada shared libraries — deferred (Mode 3 emits static archives
##     only).
##   * The M58 fixture SKIPs cleanly when ``gnatmake`` isn't on PATH so
##     a host without the GNAT toolchain still passes the gate.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Mirror of every other Mode 3 convention's scratch dir so
    ## ``repro clean`` (a single ``rm -rf .repro/``) sweeps all outputs.

  AdaBodyExtension = ".adb"
  AdaSpecExtension = ".ads"

type
  AdaDirectMemberKind = enum
    admkExecutable
    admkLibraryStatic

  AdaDirectMember = object
    name: string
    kind: AdaDirectMemberKind
    package: string  ## Owning ``package <name>:`` block.
    cConsumable: bool
      ## M58 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library's archive is the canonical
      ## ``<root>/.repro/build/<name>/lib<name>.a``. Ada static libs
      ## are C-ABI compatible when routines carry ``pragma Export
      ## (C, ...)`` AND no Ada elaboration is required (M58
      ## honest-scope cut). The flag is informational today —
      ## archive shape doesn't change based on consumer — but
      ## drives the dep-graph wiring on the consumer side.

  AdaDirectEmitTarget = object
    member: AdaDirectMember
    srcDir: string
    entrySource: string
    sourceFiles: seq[string]

  AdaDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    cConsumable: bool

  AdaDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Discovered by ``collectCCppCrossMembers`` and emitted
    ## in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  AdaDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Used for the reverse direction (C++ binary → Ada
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  AdaDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that an Ada binary's
    ## link picks up via gnatmake's ``-largs`` linker pass-through.
    package: string
    libraryName: string
    linkActionId: string
    outputPath: string
    includeDir: string

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

const AdaToolchainTokens = ["ada", "gnat", "gnatmake"]

proc isAdaToolchainToken(token: string): bool =
  for entry in AdaToolchainTokens:
    if token == entry:
      return true
  false

proc usesIncludesAdaToolchain*(source: string): bool =
  ## True when the ``uses:`` block names any of the Ada toolchain
  ## tokens (``ada``/``gnat``/``gnatmake``). Mirror of
  ## ``usesIncludesDToolchain`` from d_direct.nim.
  if source.len == 0:
    return false
  var sawAda = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if isAdaToolchainToken(token):
      sawAda = true
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
          consume(firstToken)
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
          consume(firstToken)
  sawAda

type
  AdaDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeAdaUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractAdaPackageUses(source: string): seq[AdaDirectPackageUses] =
  ## Mirror of the D / Fortran / Zig convention's
  ## ``extract<Lang>PackageUses``.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(AdaDirectPackageUses(
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
    if currentPackage.len > 0 and indent <= packageColumn:
      flushPackage()
    if inUsesBlock and indent <= usesColumn:
      inUsesBlock = false
      usesColumn = -1
    if inUsesBlock:
      for raw in stripped.split({',', ' ', '\t'}):
        consumeAdaUsesToken(currentTokens, raw)
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
          consumeAdaUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesAda(usesEntries: openArray[AdaDirectPackageUses];
                    package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names an Ada toolchain
  ## token. When ``package`` is empty (no package block at all) we
  ## fall back to the workspace-wide ``usesIncludesAdaToolchain``.
  if package.len == 0:
    return usesIncludesAdaToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if isAdaToolchainToken(token):
        return true
    return false
  false

proc packageUsesAnyCCpp(usesEntries: openArray[AdaDirectPackageUses];
                       package: string): bool =
  if package.len == 0:
    return false
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "gcc" or token == "clang":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[AdaDirectMember] =
  ## Walk ``source`` for ``executable`` / ``library`` declarations with
  ## owning ``package``. Identical heuristic as the other Mode 3
  ## conventions.
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
      if ch == ' ': inc indent
      elif ch == '\t': indent += 8
      else: break
    if currentPackage.len > 0 and indent <= packageColumn:
      currentPackage = ""
      packageColumn = -1
    if stripped.startsWith("package") and
        (stripped.len == len("package") or
         stripped[len("package")] in {' ', '\t'}):
      let rest = stripped[len("package") .. ^1].strip()
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
        result.add(AdaDirectMember(
          name: name, kind: admkExecutable,
          package: currentPackage))
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
        result.add(AdaDirectMember(
          name: name, kind: admkLibraryStatic,
          package: currentPackage))
      continue

proc isAdaBodyFile*(path: string): bool =
  path.toLowerAscii.endsWith(AdaBodyExtension)

proc isAdaSpecFile*(path: string): bool =
  path.toLowerAscii.endsWith(AdaSpecExtension)

proc isAdaSourceFile*(path: string): bool =
  isAdaBodyFile(path) or isAdaSpecFile(path)

proc dirHasAdaBodies(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isAdaBodyFile(path):
      return true
  false

proc resolveAdaMemberDirs(projectRoot, memberName: string;
                          kind: AdaDirectMemberKind):
    tuple[srcDir: string; entrySource: string] =
  ## Layout B first (``<root>/<member>/src/...``) then Layout A
  ## (``<root>/src/...``). For executables the convention looks for
  ## ``<member>.adb`` then ``main.adb``; for libraries it looks for
  ## ``<member>.adb`` then ``lib.adb``.
  let candidatesB = projectRoot / memberName / "src"
  if dirHasAdaBodies(candidatesB):
    result.srcDir = candidatesB
    let memberFile = candidatesB / (memberName & AdaBodyExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of admkExecutable:
      let mainCand = candidatesB / ("main" & AdaBodyExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of admkLibraryStatic:
      let libCand = candidatesB / ("lib" & AdaBodyExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesB):
      if isAdaBodyFile(path):
        result.entrySource = path
        return
    return
  let candidatesA = projectRoot / "src"
  if dirHasAdaBodies(candidatesA):
    result.srcDir = candidatesA
    let memberFile = candidatesA / (memberName & AdaBodyExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of admkExecutable:
      let mainCand = candidatesA / ("main" & AdaBodyExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of admkLibraryStatic:
      let libCand = candidatesA / ("lib" & AdaBodyExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesA):
      if isAdaBodyFile(path):
        result.entrySource = path
        return

proc collectAdaSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.adb`` (body) under ``srcDir``, recursively. Specs
  ## (``.ads``) are not added as build inputs — gnatmake / gcc-ada
  ## pulls them in via the source-search-path automatically. Used to
  ## compute the declared ``inputs`` so source edits invalidate the
  ## cache.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isAdaBodyFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc hasGnatProjectFile(projectRoot: string): bool =
  ## True when the workspace root carries any ``*.gpr`` (GNAT project
  ## file). The future Mode 2 Ada convention's territory; the M58
  ## Mode 3 path defers when one is present.
  if not dirExists(extendedPath(projectRoot)):
    return false
  try:
    for kind, path in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if path.toLowerAscii.endsWith(".gpr"):
        return true
  except OSError:
    discard
  false

proc gnatmakeDriver*(): string =
  ## Locate ``gnatmake``. The Windows MSYS2 install path is the
  ## canonical one (M58 spec calls for ``mingw-w64-x86_64-gcc-ada``);
  ## the convention itself just probes PATH.
  findExe("gnatmake")

proc gccAdaCompiler*(): string =
  ## Locate ``gcc`` for per-source Ada compilation (libraries).
  ## gcc with the Ada front-end installed handles ``.adb`` sources
  ## directly via ``-c -gnatp``.
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc resolveTarget(projectRoot: string; member: AdaDirectMember):
    AdaDirectEmitTarget =
  result.member = member
  let resolved = resolveAdaMemberDirs(projectRoot, member.name, member.kind)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectAdaSourcesUnderSrcDir(resolved.srcDir)

proc adaDirectRecognize(projectRoot: string;
                        request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``*.gpr`` at the workspace root (the future Mode 2 Ada
  ##     convention's territory; M58 only recognises Mode 3).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``ada``/``gnat``/``gnatmake``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Ada source layout.
  ##   * ``gnatmake`` is on PATH.
  if hasGnatProjectFile(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesAdaToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if gnatmakeDriver().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveTarget(projectRoot, member)
    if resolved.entrySource.len > 0:
      atLeastOneResolved = true
      break
  atLeastOneResolved

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc objDirFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / "obj"

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".exe")
  else:
    scratchPathFor(projectRoot, member) / member

proc archivePathFor(projectRoot, member: string): string =
  ## Ada static library output. Lands at
  ## ``<root>/.repro/build/<name>/lib<name>.a`` — the canonical
  ## archive schema shared with ``c-cpp-direct``, Rust's staticlib
  ## path, Fortran's archive path, Nim's archive output, Zig's static
  ## archive, D's archive.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc adaObjFor(objDir, source, srcDir: string): string =
  var rel: string
  try:
    rel = relativePath(source, srcDir)
  except OSError:
    rel = extractFilename(source)
  rel = rel.replace('\\', '/')
  var stem = rel
  if stem.toLowerAscii.endsWith(AdaBodyExtension):
    stem = stem[0 ..< stem.len - AdaBodyExtension.len]
  objDir / (sanitizeNamePart(stem) & ".o")

proc emitCompileAction(projectRoot, gccExe: string;
                       member: AdaDirectMember;
                       source, objFile, srcDir: string): BuildActionDef =
  ## ``gcc -c -O2 -gnatp -I<srcDir> -o <obj> <src.adb>``. Compiles a
  ## single Ada body to an object file. ``-gnatp`` suppresses Ada
  ## runtime checks (constraint / elaboration / overflow) so the
  ## resulting ``.o`` doesn't pull in the GNAT runtime. ``-I<srcDir>``
  ## tells the Ada front-end where to find sibling spec files
  ## (``.ads``) in the same package.
  var argv = @[
    gccExe, "-c",
    "-O2",
    "-gnatp",
    "-I" & srcDir,
    "-o", objFile,
    source,
  ]
  let actionId = "ada-direct-compile-" &
    sanitizeNamePart(member.name) & "-" &
    sanitizeNamePart(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ada-direct.compile")

proc emitArchiveAction(projectRoot, arExe: string;
                       member: AdaDirectMember;
                       objFiles, compileIds: seq[string]): BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>``. Same shape as Fortran / C/C++
  ## archive actions.
  let archiveOutput = archivePathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "ada-direct-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ada-direct.archive")

proc emitExecutableLinkAction(projectRoot, gnatmakeExe: string;
                              target: AdaDirectEmitTarget;
                              depLibraries:
                                openArray[AdaDirectWorkspaceLibrary];
                              cCppUpstream:
                                openArray[AdaDirectCCppUpstreamLibrary] = []):
                                BuildActionDef =
  ## ``gnatmake -O2 -o <bin> <src.adb> -aI<srcDir>
  ##  [-largs <archives...>]``.
  ##
  ## gnatmake is Ada's all-in-one driver — it handles compile + bind +
  ## elaboration + link in a single invocation. The ``-aI<srcDir>``
  ## flag adds source search paths; without it gnatmake only sees the
  ## entry-source's directory. The ``-largs`` separator forwards every
  ## following arg to the linker, which is how we thread upstream
  ## archives (Ada workspace libs AND cross-language C archives).
  let outputPath = binaryPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(outputPath)))
  var argv = @[gnatmakeExe, "-O2", "-o", outputPath]
  # Source search paths — gnatmake needs ``-aI`` for every dir that
  # holds Ada sources the entry-source references via ``with`` clauses.
  if target.srcDir.len > 0:
    argv.add("-aI" & target.srcDir)
  argv.add(target.entrySource)
  let hasLinkerExtras = depLibraries.len > 0 or cCppUpstream.len > 0
  if hasLinkerExtras:
    argv.add("-largs")
    for lib in depLibraries:
      argv.add(lib.outputPath)
    for c in cCppUpstream:
      argv.add(c.outputPath)
  var inputs = target.sourceFiles
  for lib in depLibraries:
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  for c in cCppUpstream:
    if inputs.find(c.outputPath) < 0:
      inputs.add(c.outputPath)
  var deps: seq[string] = @[]
  for lib in depLibraries:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
  for c in cCppUpstream:
    if deps.find(c.linkActionId) < 0:
      deps.add(c.linkActionId)
  buildAction(
    id = "ada-direct-link-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ada-direct.executable.link")

# ---------------------------------------------------------------------------
# M58 cross-language C/C++ helpers (mixed-workspace support). Mirror of
# fortran_direct / zig_direct / d_direct — discriminator on the
# action-id prefix (``ada-xlang-ccpp-...``).
# ---------------------------------------------------------------------------

type
  AdaDirectCCppPlainMemberKind = enum
    accmkExecutable
    accmkLibraryStatic

  AdaDirectCCppPlainMember = object
    package: string
    name: string
    kind: AdaDirectCCppPlainMemberKind

proc extractCCppMembersFromText(source: string):
    seq[AdaDirectCCppPlainMember] =
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
      if ch == ' ': inc indent
      elif ch == '\t': indent += 8
      else: break
    if currentPackage.len > 0 and indent <= packageColumn:
      currentPackage = ""
      packageColumn = -1
    if stripped.startsWith("package") and
        (stripped.len == len("package") or
         stripped[len("package")] in {' ', '\t'}):
      let rest = stripped[len("package") .. ^1].strip()
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
        result.add(AdaDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: accmkExecutable))
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
        result.add(AdaDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: accmkLibraryStatic))
      continue

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[AdaDirectPackageUses]):
                               seq[AdaDirectCCppMember] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != accmkLibraryStatic:
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAnyCCpp(usesEntries, entry.package):
      continue
    let resolved = resolveMemberDirs(projectRoot, entry.name)
    if resolved.srcDir.len == 0:
      continue
    let sourceFiles = collectCCppSourceFiles(resolved.srcDir)
    if sourceFiles.len == 0:
      continue
    result.add(AdaDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[AdaDirectPackageUses]):
                                   seq[AdaDirectCCppExecutable] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != accmkExecutable:
      continue
    if entry.package.len == 0:
      continue
    if not packageUsesAnyCCpp(usesEntries, entry.package):
      continue
    let resolved = resolveMemberDirs(projectRoot, entry.name)
    if resolved.srcDir.len == 0:
      continue
    let sourceFiles = collectCCppSourceFiles(resolved.srcDir)
    if sourceFiles.len == 0:
      continue
    result.add(AdaDirectCCppExecutable(
      package: entry.package,
      executableName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc ccppCrossScratch(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc ccppCrossObjDir(projectRoot, member: string): string =
  ccppCrossScratch(projectRoot, member) / "obj"

proc ccppCrossArchivePath(projectRoot, member: string): string =
  ccppCrossScratch(projectRoot, member) / ("lib" & member & ".a")

proc ccppCrossBinaryPath(projectRoot, member: string): string =
  when defined(windows):
    ccppCrossScratch(projectRoot, member) / (member & ".exe")
  else:
    ccppCrossScratch(projectRoot, member) / member

proc isCxxSource(path: string): bool =
  let lower = path.toLowerAscii
  lower.endsWith(".cpp") or lower.endsWith(".cc") or lower.endsWith(".cxx")

proc ccCompilerCross(): string =
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc cxxCompilerCross(): string =
  let gpp = findExe("g++")
  if gpp.len > 0:
    return gpp
  findExe("clang++")

proc arDriverCross(): string =
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

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
  objDir / (sanitizeNamePart(stem) & ".o")

proc emitCCppCrossCompileAction(projectRoot, ccExe: string;
                                member: AdaDirectCCppMember;
                                source, objFile, depFile: string):
                                  BuildActionDef =
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
  let actionId = "ada-xlang-ccpp-compile-" &
    sanitizeNamePart(member.libraryName) & "-" &
    sanitizeNamePart(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "ada-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: AdaDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "ada-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ada-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: AdaDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "ada-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile upstream C/C++ library '" &
        member.libraryName & "' for cross-language consumption")
  let arExe = arDriverCross()
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
# Reverse-direction (C++ binary → Ada staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: AdaDirectCCppExecutable;
                                    source, objFile, depFile: string):
                                      BuildActionDef =
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
  let actionId = "ada-xlang-ccpp-exec-compile-" &
    sanitizeNamePart(exec.executableName) & "-" &
    sanitizeNamePart(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "ada-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: AdaDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 adaUpstream:
                                   openArray[AdaDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Ada
  ## staticlib lands as a trailing positional. The M58 honest-scope
  ## cut limits the reverse fixture to ``pragma Export (C, ...)``
  ## no-elaboration entry points so the gcc driver resolves all
  ## references against the Ada archive itself without external
  ## runtime libs — same property Zig's M44 / D's M45 reverse
  ## fixtures rely on for their respective runtimes.
  ##
  ## When a future milestone adds full GNAT-runtime linking the link
  ## line will additionally need ``-lgnat -lm`` (and ``-lgnarl`` for
  ## tasking).
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in adaUpstream:
    argv.add(lib.outputPath)
  var deps = compileIds
  var inputs = objFiles
  for lib in adaUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "ada-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ada-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: AdaDirectCCppExecutable;
                             adaUpstream:
                               openArray[AdaDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "ada-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "ada-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, adaUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

proc readScannedDepsSource(projectRoot: string): string =
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
  result = extractManualDependsOnFromText(source)
  let scanned = readScannedDepsSource(projectRoot)
  if scanned.len > 0:
    for edge in extractManualDependsOnFromText(scanned):
      result.add(edge)

proc dedupDepEdges(edges: openArray[ManualDepEdge]): seq[ManualDepEdge] =
  var seen: seq[string] = @[]
  for edge in edges:
    let key = edge.fromPackage & "\x1f" & edge.toPackage
    if seen.find(key) >= 0:
      continue
    seen.add(key)
    result.add(edge)

proc detectDepCycle(edges: openArray[ManualDepEdge];
                    packages: openArray[string]): seq[string] =
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
  for edge in edges:
    if declaredPackages.find(edge.fromPackage) < 0:
      raise newException(ValueError,
        "ada-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "ada-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "ada-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[AdaDirectMember]): PackageDef =
  var name = "ada_direct_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
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

proc adaDirectEmitFragment(projectRoot: string;
                           request: ProviderGraphRequest):
                             GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate Ada members + (in mixed workspaces)
  ## cross-language C/C++ helpers, validate Mode 3 dep edges, emit
  ## per-member ``gnatmake`` / ``gcc -c -gnatp`` / ``ar rcs`` actions
  ## plus cross-language ``gcc -c`` + ``ar rcs`` + C++ executable
  ## actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractAdaPackageUses(source)
    var members: seq[AdaDirectMember] = @[]
    for member in allMembers:
      if not packageUsesAda(usesEntries, member.package, source):
        continue
      members.add(member)
    let cCppCrossMembers = collectCCppCrossMembers(
      projectRoot, source, usesEntries)
    let cCppCrossExecutables = collectCCppCrossExecutables(
      projectRoot, source, usesEntries)
    if members.len == 0 and cCppCrossMembers.len == 0 and
        cCppCrossExecutables.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "ada-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let gnatmakeExe =
      if members.len > 0: gnatmakeDriver() else: ""
    if members.len > 0 and gnatmakeExe.len == 0:
      raise newException(ValueError,
        "ada-direct convention: 'gnatmake' not on PATH; " &
          "cannot compile Ada sources")
    let gccExe =
      if members.len > 0: gccAdaCompiler() else: ""
    if members.len > 0 and gccExe.len == 0:
      raise newException(ValueError,
        "ada-direct convention: neither 'gcc' nor 'clang' on PATH; " &
          "cannot compile Ada library sources")
    var targets: seq[AdaDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.entrySource.len == 0:
        let layoutBHint =
          case member.kind
          of admkExecutable: member.name & "/src/main.adb"
          of admkLibraryStatic: member.name & "/src/lib.adb"
        let layoutAHint =
          case member.kind
          of admkExecutable: "src/main.adb"
          of admkLibraryStatic: "src/lib.adb"
        raise newException(ValueError,
          "ada-direct convention: no Ada sources resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & layoutBHint &
            " and <root>/" & layoutAHint & ")")
      targets.add(target)
    let rawDepEdges = collectWorkspaceDepEdges(projectRoot, source)
    let depEdges = dedupDepEdges(rawDepEdges)
    var declaredPackages: seq[string] = @[]
    for member in members:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    for member in cCppCrossMembers:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    for exec in cCppCrossExecutables:
      if exec.package.len > 0 and
          declaredPackages.find(exec.package) < 0:
        declaredPackages.add(exec.package)
    validateWorkspaceDeps(depEdges, declaredPackages)

    # M58 reverse cross-language: derive ``cConsumable`` for each Ada
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package.
    # The flag is informational at this milestone — Ada's archive
    # shape is identical whether consumed by Ada or C/C++ (a regular
    # ``ar rcs``) — but drives the consumer-side wiring (the C/C++
    # helper threads the archive onto the link argv).
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[AdaDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == admkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    let pkg = syntheticPackage(projectRoot, members)
    let arExe = arDriverCross()
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # M58 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the Ada binary's link can reference each archive's output
      # path + link action id by the time we emit the link.
      var packageCCppLibraries =
        initTable[string, seq[AdaDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = AdaDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # Ada LIBRARIES next so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action.
      var packageLibraries =
        initTable[string, seq[AdaDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != admkLibraryStatic:
          continue
        let objDir = objDirFor(projectRoot, target.member.name)
        createDir(extendedPath(objDir))
        var objFiles: seq[string] = @[]
        var compileIds: seq[string] = @[]
        for source in target.sourceFiles:
          let objFile = adaObjFor(objDir, source, target.srcDir)
          createDir(extendedPath(parentDir(objFile)))
          let action = emitCompileAction(projectRoot, gccExe,
            target.member, source, objFile, target.srcDir)
          allActions.add(action)
          objFiles.add(objFile)
          compileIds.add(action.id)
        let archiveAction = emitArchiveAction(projectRoot, arExe,
          target.member, objFiles, compileIds)
        allActions.add(archiveAction)
        if target.member.package.len > 0:
          let entry = AdaDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: archiveAction.id,
            outputPath: archivePathFor(projectRoot, target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Ada executables — consume upstream Ada libraries AND any
      # cross-language C/C++ archives the depends_on edges resolve to.
      for target in targets:
        if target.member.kind != admkExecutable:
          continue
        var entryDeps: seq[AdaDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[AdaDirectCCppUpstreamLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                entryDeps.add(lib)
            if packageCCppLibraries.hasKey(edge.toPackage):
              for cLib in packageCCppLibraries[edge.toPackage]:
                entryCCppDeps.add(cLib)
        let action = emitExecutableLinkAction(
          projectRoot = projectRoot,
          gnatmakeExe = gnatmakeExe,
          target = target,
          depLibraries = entryDeps,
          cCppUpstream = entryCCppDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      # M58 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Ada archive.
      for exec in cCppCrossExecutables:
        var execAdaUpstream: seq[AdaDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for adaLib in packageLibraries[edge.toPackage]:
                # All Ada archives are linkable from a C/C++ binary
                # when the Ada source marks routines with ``pragma
                # Export (C, ...)``. We pass them through regardless
                # of cConsumable — the flag is informational only at
                # this milestone.
                execAdaUpstream.add(adaLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execAdaUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc adaDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``d-direct`` per the M58 spec —
  ## registration order between Ada and other Mode 3 conventions only
  ## matters when a workspace claims both Ada AND another language.
  ## In an Ada+C/C++ workspace this convention claims dispatch because
  ## ``c-cpp-direct``'s ``recognize`` defers when ``uses:`` names an
  ## Ada toolchain token (``ada``/``gnat``/``gnatmake``).
  LanguageConvention(
    name: "ada-direct",
    recognize: adaDirectRecognize,
    emitFragment: adaDirectEmitFragment)
