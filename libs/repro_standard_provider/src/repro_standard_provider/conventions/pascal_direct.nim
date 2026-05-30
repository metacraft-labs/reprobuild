## Pascal (Mode 3) language convention (Tier 2b).
##
## Mode 3 minimal Pascal convention for projects whose ``repro.nim``
## declares a Pascal ``executable`` / ``library`` member AND DOES NOT
## ship a ``*.lpi`` (Lazarus project file) at the workspace root. The
## convention builds the per-member compile + link graph from pure
## layout — no Lazarus / ``lazbuild`` manifest needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M59 section of
## ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``ada-direct`` per the M59 spec —
## eighth Mode 3 language):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``pascal``, ``fpc``, or ``freepascal``.
##   * NO ``<projectRoot>/*.lpi`` (Lazarus project file) at the workspace
##     root. The future Mode 2 Pascal convention's territory (deferred
##     per the M59 honest-scope cut — Mode 3 only for M59).
##   * At least one ``executable`` / ``library`` member is declared
##     AND resolves to a non-empty Pascal source layout (Layout A or B).
##   * ``fpc`` is on PATH at convention-emit time.
##
## **Layout**:
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.pas        (executable; ``.pp`` / ``.lpr``
##                                          also accepted)
##       <projectRoot>/src/lib.pas         (library; ``<member>.pas``
##                                          also accepted as a fallback)
##
##   Layout B — multiple packages per project file::
##
##       <projectRoot>/<member>/src/main.pas (executable)
##       <projectRoot>/<member>/src/lib.pas  (library)
##
## **Per-member argv**:
##
## | Member kind            | Argv                                          |
## |------------------------|-----------------------------------------------|
## | executable             | ``fpc -O2 -FE<scratch> -o<out> <src.pas>``    |
## | library (static)       | ``fpc -O2 -CX -FE<scratch> <src.pas>`` then   |
## |                        | ``ar rcs <root>/.repro/build/<n>/lib<n>.a *.o``|
##
## For libraries we emit a per-source fpc compile (``-CX`` produces a
## smartlinkable .o set). The resulting ``.o`` files are then packaged
## via ``ar rcs`` into the canonical
## ``<root>/.repro/build/<n>/lib<n>.a`` schema shared with the other
## Mode 3 obj+linker conventions (``c-cpp-direct``, ``fortran-direct``,
## ``rust-direct`` staticlib path, ``zig-direct``, ``d-direct``,
## ``ada-direct``).
##
## For the M59 honest-scope cut we restrict cross-language Pascal
## entry points to ``cdecl`` + ``public name '...'`` directives (no
## Pascal RTL init), keeping the archive C-consumable without runtime
## bootstrap calls. Same property M58 Ada's ``pragma Export (C, ...)``
## and M44/M45's Zig/D reverse fixtures rely on.
##
## **M59 cross-language Pascal ↔ C/C++**:
##
##   * **Forward (Pascal binary → C library)**: a Pascal ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers
##     emit per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The Pascal
##     binary's ``fpc`` link gains the C archive via ``-Fl<dir>`` (lib
##     search path) plus a trailing ``-k<archive>`` linker pass-through
##     (``-k`` forwards a token straight to the underlying linker).
##     The Pascal source declares the C function via
##     ``external 'c_add'; cdecl;``.
##
##   * **Reverse (C/C++ binary → Pascal library)**: a C/C++
##     ``executable`` ``depends_on`` a Pascal ``library`` member. The
##     Pascal library's archive shape is the same ``ar rcs`` static
##     archive either way (Pascal static libs are C-ABI compatible when
##     routines carry ``public name '...'; cdecl;`` AND no Pascal RTL
##     bootstrap is required). Embedded helpers then emit the C/C++
##     binary's per-source ``g++ -c`` + terminal ``g++ -o`` link
##     action; the Pascal staticlib lands on the link argv as a
##     trailing positional.
##
##     The M59 honest-scope cut limits the reverse fixture to
##     ``public name '...'; cdecl;`` pure no-RTL-init entry points (no
##     Pascal ``writeln``, no objects, no managed types) so the gcc
##     driver resolves all references against the archive itself
##     without ``-lfprt`` / ``-lc`` runtime libs and without explicit
##     RTL bootstrap calls — same property M58 Ada's M44 Zig and M45
##     D reverse fixtures rely on for their respective runtimes. Full
##     FPC runtime linking (``-lfprt -lc``) is deferred to a future
##     milestone.
##
## Action-id prefixes for cross-language emit are
## ``pascal-xlang-ccpp-compile-*``, ``pascal-xlang-ccpp-archive-*``,
## ``pascal-xlang-ccpp-exec-compile-*``, ``pascal-xlang-ccpp-exec-link-*``
## (mirror of the rust-direct / fortran-direct / zig-direct / d-direct
## / ada-direct ``<lang>-xlang-ccpp-...`` discriminators).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Mode 2 ``.lpi`` / ``lazbuild`` recognition + delegation —
##     deferred. The future Mode 2 Pascal convention will key on
##     ``<name>.lpi`` and shell out to ``lazbuild <name>.lpi``.
##     Lazarus is a sophisticated IDE/build system in its own right;
##     Mode 3 only for M59 per the milestone's honest cut.
##   * Delphi compatibility (``-Mdelphi``) — out of scope.
##   * Full Pascal runtime linking (``-lfprt -lc``) reverse direction —
##     deferred. The M59 fixture restricts cross-language Pascal
##     functions to ``public name '...'; cdecl;`` pure no-RTL-bootstrap
##     routines.
##   * ``uses`` clause cross-package scanner — deferred. Cross-package
##     edges are hand-authored as ``depends_on`` in ``repro.nim`` until
##     a future milestone adds a ``uses Pkg;`` scanner.
##   * Multi-target / multi-arch — deferred.
##   * Pascal shared libraries — deferred (Mode 3 emits static archives
##     only).
##   * The M59 fixture SKIPs cleanly when ``fpc`` isn't on PATH so a
##     host without the FPC toolchain still passes the gate.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Mirror of every other Mode 3 convention's scratch dir so
    ## ``repro clean`` (a single ``rm -rf .repro/``) sweeps all outputs.

  PascalSourceExtensions = [".pas", ".pp", ".lpr"]

type
  PascalDirectMemberKind = enum
    pdmkExecutable
    pdmkLibraryStatic

  PascalDirectMember = object
    name: string
    kind: PascalDirectMemberKind
    package: string  ## Owning ``package <name>:`` block.
    cConsumable: bool
      ## M59 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library's archive is the canonical
      ## ``<root>/.repro/build/<name>/lib<name>.a``. Pascal static
      ## libs are C-ABI compatible when routines carry ``public name
      ## '...'; cdecl;`` AND no Pascal RTL bootstrap is required (M59
      ## honest-scope cut). The flag is informational today —
      ## archive shape doesn't change based on consumer — but
      ## drives the dep-graph wiring on the consumer side.

  PascalDirectEmitTarget = object
    member: PascalDirectMember
    srcDir: string
    entrySource: string
    sourceFiles: seq[string]

  PascalDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    cConsumable: bool

  PascalDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Discovered by ``collectCCppCrossMembers`` and emitted
    ## in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  PascalDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Used for the reverse direction (C++ binary → Pascal
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  PascalDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a Pascal binary's
    ## link picks up via fpc's ``-k`` linker pass-through.
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

const PascalToolchainTokens = ["pascal", "fpc", "freepascal"]

proc isPascalToolchainToken(token: string): bool =
  for entry in PascalToolchainTokens:
    if token == entry:
      return true
  false

proc usesIncludesPascalToolchain*(source: string): bool =
  ## True when the ``uses:`` block names any of the Pascal toolchain
  ## tokens (``pascal``/``fpc``/``freepascal``). Mirror of
  ## ``usesIncludesAdaToolchain`` from ada_direct.nim.
  if source.len == 0:
    return false
  var sawPascal = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if isPascalToolchainToken(token):
      sawPascal = true
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
  sawPascal

type
  PascalDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumePascalUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractPascalPackageUses(source: string): seq[PascalDirectPackageUses] =
  ## Mirror of the D / Fortran / Zig / Ada convention's
  ## ``extract<Lang>PackageUses``.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(PascalDirectPackageUses(
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
        consumePascalUsesToken(currentTokens, raw)
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
          consumePascalUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesPascal(usesEntries: openArray[PascalDirectPackageUses];
                       package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names a Pascal toolchain
  ## token. When ``package`` is empty (no package block at all) we
  ## fall back to the workspace-wide ``usesIncludesPascalToolchain``.
  if package.len == 0:
    return usesIncludesPascalToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if isPascalToolchainToken(token):
        return true
    return false
  false

proc packageUsesAnyCCpp(usesEntries: openArray[PascalDirectPackageUses];
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

proc extractMembersWithOwnership(source: string): seq[PascalDirectMember] =
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
        result.add(PascalDirectMember(
          name: name, kind: pdmkExecutable,
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
        result.add(PascalDirectMember(
          name: name, kind: pdmkLibraryStatic,
          package: currentPackage))
      continue

proc isPascalSourceFile*(path: string): bool =
  let lower = path.toLowerAscii
  for ext in PascalSourceExtensions:
    if lower.endsWith(ext):
      return true
  false

proc pascalExtensionOf(path: string): string =
  let lower = path.toLowerAscii
  for ext in PascalSourceExtensions:
    if lower.endsWith(ext):
      return ext
  ""

proc dirHasPascalSources(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isPascalSourceFile(path):
      return true
  false

proc findEntrySourceWithName(dir, stem: string): string =
  ## Look for ``<dir>/<stem>.<ext>`` for each of the Pascal source
  ## extensions in priority order (``.pas`` first, then ``.pp``,
  ## then ``.lpr``).
  for ext in PascalSourceExtensions:
    let candidate = dir / (stem & ext)
    if fileExists(extendedPath(candidate)):
      return candidate
  ""

proc resolvePascalMemberDirs(projectRoot, memberName: string;
                             kind: PascalDirectMemberKind):
    tuple[srcDir: string; entrySource: string] =
  ## Layout B first (``<root>/<member>/src/...``) then Layout A
  ## (``<root>/src/...``). For executables the convention looks for
  ## ``<member>.{pas,pp,lpr}`` then ``main.{pas,pp,lpr}``; for
  ## libraries it looks for ``<member>.{pas,pp,lpr}`` then
  ## ``lib.{pas,pp,lpr}``.
  let candidatesB = projectRoot / memberName / "src"
  if dirHasPascalSources(candidatesB):
    result.srcDir = candidatesB
    let memberFile = findEntrySourceWithName(candidatesB, memberName)
    if memberFile.len > 0:
      result.entrySource = memberFile
      return
    case kind
    of pdmkExecutable:
      let mainCand = findEntrySourceWithName(candidatesB, "main")
      if mainCand.len > 0:
        result.entrySource = mainCand
        return
    of pdmkLibraryStatic:
      let libCand = findEntrySourceWithName(candidatesB, "lib")
      if libCand.len > 0:
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesB):
      if isPascalSourceFile(path):
        result.entrySource = path
        return
    return
  let candidatesA = projectRoot / "src"
  if dirHasPascalSources(candidatesA):
    result.srcDir = candidatesA
    let memberFile = findEntrySourceWithName(candidatesA, memberName)
    if memberFile.len > 0:
      result.entrySource = memberFile
      return
    case kind
    of pdmkExecutable:
      let mainCand = findEntrySourceWithName(candidatesA, "main")
      if mainCand.len > 0:
        result.entrySource = mainCand
        return
    of pdmkLibraryStatic:
      let libCand = findEntrySourceWithName(candidatesA, "lib")
      if libCand.len > 0:
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesA):
      if isPascalSourceFile(path):
        result.entrySource = path
        return

proc collectPascalSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.pas`` / ``.pp`` / ``.lpr`` under ``srcDir``, recursively.
  ## Used to compute the declared ``inputs`` so source edits invalidate
  ## the cache.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isPascalSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc hasLazarusProjectFile(projectRoot: string): bool =
  ## True when the workspace root carries any ``*.lpi`` (Lazarus
  ## project file). The future Mode 2 Pascal convention's territory;
  ## the M59 Mode 3 path defers when one is present.
  if not dirExists(extendedPath(projectRoot)):
    return false
  try:
    for kind, path in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if path.toLowerAscii.endsWith(".lpi"):
        return true
  except OSError:
    discard
  false

proc fpcDriver*(): string =
  ## Locate ``fpc``. The Windows MSYS2 install path is
  ## ``mingw-w64-x86_64-fpc``; scoop also ships ``freepascal``. The
  ## convention itself just probes PATH.
  findExe("fpc")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc resolveTarget(projectRoot: string; member: PascalDirectMember):
    PascalDirectEmitTarget =
  result.member = member
  let resolved = resolvePascalMemberDirs(projectRoot, member.name, member.kind)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectPascalSourcesUnderSrcDir(resolved.srcDir)

proc pascalDirectRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``*.lpi`` at the workspace root (the future Mode 2 Pascal
  ##     convention's territory; M59 only recognises Mode 3).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``pascal``/``fpc``/``freepascal``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Pascal source layout.
  ##   * ``fpc`` is on PATH.
  if hasLazarusProjectFile(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesPascalToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if fpcDriver().len == 0:
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
  ## Pascal static library output. Lands at
  ## ``<root>/.repro/build/<name>/lib<name>.a`` — the canonical
  ## archive schema shared with ``c-cpp-direct``, Rust's staticlib
  ## path, Fortran's archive path, Nim's archive output, Zig's static
  ## archive, D's archive, Ada's archive.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc pascalObjFor(objDir, source, srcDir: string): string =
  var rel: string
  try:
    rel = relativePath(source, srcDir)
  except OSError:
    rel = extractFilename(source)
  rel = rel.replace('\\', '/')
  var stem = rel
  let ext = pascalExtensionOf(stem)
  if ext.len > 0 and stem.toLowerAscii.endsWith(ext):
    stem = stem[0 ..< stem.len - ext.len]
  objDir / (sanitizeNamePart(stem) & ".o")

proc emitCompileAction(projectRoot, fpcExe: string;
                       member: PascalDirectMember;
                       source, objFile, objDir, srcDir: string):
                       BuildActionDef =
  ## ``fpc -O2 -CX -Fu<srcDir> -FU<objDir> -FE<objDir> <src.pas>``.
  ## Compiles a single Pascal source to an object file via fpc's
  ## smartlinkable (``-CX``) backend. ``-Fu<srcDir>`` is the unit
  ## search path; ``-FU<objDir>`` redirects unit (.ppu/.o) outputs;
  ## ``-FE<objDir>`` redirects the compiler's executable output path
  ## (harmless for library compiles but keeps fpc from emitting an
  ## ``a.out`` next to the source). The resulting ``.o`` is then
  ## packaged via ``ar rcs`` into the canonical archive schema.
  var argv = @[
    fpcExe,
    "-O2",
    "-CX",
    "-Fu" & srcDir,
    "-FU" & objDir,
    "-FE" & objDir,
    source,
  ]
  let actionId = "pascal-direct-compile-" &
    sanitizeNamePart(member.name) & "-" &
    sanitizeNamePart(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "pascal-direct.compile")

proc emitArchiveAction(projectRoot, arExe: string;
                       member: PascalDirectMember;
                       objFiles, compileIds: seq[string]): BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>``. Same shape as Ada / Fortran / C/C++
  ## archive actions.
  let archiveOutput = archivePathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "pascal-direct-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "pascal-direct.archive")

proc emitExecutableLinkAction(projectRoot, fpcExe: string;
                              target: PascalDirectEmitTarget;
                              depLibraries:
                                openArray[PascalDirectWorkspaceLibrary];
                              cCppUpstream:
                                openArray[PascalDirectCCppUpstreamLibrary] = []):
                                BuildActionDef =
  ## ``fpc -O2 -Fu<srcDir> -FE<scratch> -o<bin> <src.pas>
  ##       [-Fl<dir>... -k<archive>...]``.
  ##
  ## fpc is Pascal's all-in-one driver — it handles compile + link in
  ## a single invocation. ``-Fu<srcDir>`` adds a unit search path so
  ## fpc sees sibling units the entry source references via ``uses``
  ## clauses. ``-FE<scratch>`` redirects the executable output dir;
  ## ``-o<bin>`` sets the explicit binary path so we always produce a
  ## known path even when fpc would otherwise infer it from the
  ## entry-source basename.
  ##
  ## Upstream archives flow onto the link line via two flags:
  ##   * ``-Fl<dir>`` — adds the archive's parent directory to the
  ##     linker's library search path.
  ##   * ``-k<archive>`` — passes a single token straight through to
  ##     the underlying linker. We pass each archive's full path so
  ##     ld picks it up by absolute path regardless of search-path
  ##     order. (fpc collapses repeated ``-k`` tokens into the linker
  ##     command line.)
  let outputPath = binaryPathFor(projectRoot, target.member.name)
  let outputDir = parentDir(outputPath)
  createDir(extendedPath(outputDir))
  var argv = @[fpcExe, "-O2"]
  if target.srcDir.len > 0:
    argv.add("-Fu" & target.srcDir)
  argv.add("-FE" & outputDir)
  argv.add("-o" & outputPath)
  # Upstream archives — search-path + linker pass-through.
  for lib in depLibraries:
    let parent = parentDir(lib.outputPath)
    if parent.len > 0:
      argv.add("-Fl" & parent)
  for c in cCppUpstream:
    let parent = parentDir(c.outputPath)
    if parent.len > 0:
      argv.add("-Fl" & parent)
  argv.add(target.entrySource)
  # ``-k`` forwards a token straight to the linker; one per archive.
  for lib in depLibraries:
    argv.add("-k" & lib.outputPath)
  for c in cCppUpstream:
    argv.add("-k" & c.outputPath)
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
    id = "pascal-direct-link-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "pascal-direct.executable.link")

# ---------------------------------------------------------------------------
# M59 cross-language C/C++ helpers (mixed-workspace support). Mirror of
# fortran_direct / zig_direct / d_direct / ada_direct — discriminator on
# the action-id prefix (``pascal-xlang-ccpp-...``).
# ---------------------------------------------------------------------------

type
  PascalDirectCCppPlainMemberKind = enum
    pccmkExecutable
    pccmkLibraryStatic

  PascalDirectCCppPlainMember = object
    package: string
    name: string
    kind: PascalDirectCCppPlainMemberKind

proc extractCCppMembersFromText(source: string):
    seq[PascalDirectCCppPlainMember] =
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
        result.add(PascalDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: pccmkExecutable))
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
        result.add(PascalDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: pccmkLibraryStatic))
      continue

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[PascalDirectPackageUses]):
                               seq[PascalDirectCCppMember] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != pccmkLibraryStatic:
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
    result.add(PascalDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries:
                                   openArray[PascalDirectPackageUses]):
                                   seq[PascalDirectCCppExecutable] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != pccmkExecutable:
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
    result.add(PascalDirectCCppExecutable(
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
                                member: PascalDirectCCppMember;
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
  let actionId = "pascal-xlang-ccpp-compile-" &
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
    commandStatsId = "pascal-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: PascalDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "pascal-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "pascal-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: PascalDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "pascal-direct convention (mixed workspace): neither 'gcc' nor " &
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
# Reverse-direction (C++ binary → Pascal staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: PascalDirectCCppExecutable;
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
  let actionId = "pascal-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "pascal-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: PascalDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 pascalUpstream:
                                   openArray[PascalDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Pascal
  ## staticlib lands as a trailing positional. The M59 honest-scope
  ## cut limits the reverse fixture to ``public name '...'; cdecl;``
  ## no-RTL-bootstrap entry points so the gcc driver resolves all
  ## references against the Pascal archive itself without external
  ## runtime libs — same property M58 Ada / M44 Zig / M45 D reverse
  ## fixtures rely on for their respective runtimes.
  ##
  ## When a future milestone adds full FPC-runtime linking the link
  ## line will additionally need ``-lfprt -lc``.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in pascalUpstream:
    argv.add(lib.outputPath)
  var deps = compileIds
  var inputs = objFiles
  for lib in pascalUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "pascal-xlang-ccpp-exec-link-" &
      sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "pascal-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: PascalDirectCCppExecutable;
                             pascalUpstream:
                               openArray[PascalDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "pascal-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "pascal-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, pascalUpstream)
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
        "pascal-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "pascal-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "pascal-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[PascalDirectMember]): PackageDef =
  var name = "pascal_direct_convention"
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

proc pascalDirectEmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate Pascal members + (in mixed workspaces)
  ## cross-language C/C++ helpers, validate Mode 3 dep edges, emit
  ## per-member ``fpc`` / ``ar rcs`` actions plus cross-language
  ## ``gcc -c`` + ``ar rcs`` + C++ executable actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractPascalPackageUses(source)
    var members: seq[PascalDirectMember] = @[]
    for member in allMembers:
      if not packageUsesPascal(usesEntries, member.package, source):
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
        "pascal-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let fpcExe =
      if members.len > 0: fpcDriver() else: ""
    if members.len > 0 and fpcExe.len == 0:
      raise newException(ValueError,
        "pascal-direct convention: 'fpc' not on PATH; " &
          "cannot compile Pascal sources")
    var targets: seq[PascalDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.entrySource.len == 0:
        let layoutBHint =
          case member.kind
          of pdmkExecutable: member.name & "/src/main.pas"
          of pdmkLibraryStatic: member.name & "/src/lib.pas"
        let layoutAHint =
          case member.kind
          of pdmkExecutable: "src/main.pas"
          of pdmkLibraryStatic: "src/lib.pas"
        raise newException(ValueError,
          "pascal-direct convention: no Pascal sources resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & layoutBHint &
            " and <root>/" & layoutAHint &
            "; ``.pp`` / ``.lpr`` accepted in place of ``.pas``)")
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

    # M59 reverse cross-language: derive ``cConsumable`` for each Pascal
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package.
    # The flag is informational at this milestone — Pascal's archive
    # shape is identical whether consumed by Pascal or C/C++ (a regular
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
      var rewritten: seq[PascalDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == pdmkLibraryStatic and
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
      # M59 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the Pascal binary's link can reference each archive's
      # output path + link action id by the time we emit the link.
      var packageCCppLibraries =
        initTable[string, seq[PascalDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = PascalDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # Pascal LIBRARIES next so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action.
      var packageLibraries =
        initTable[string, seq[PascalDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != pdmkLibraryStatic:
          continue
        let objDir = objDirFor(projectRoot, target.member.name)
        createDir(extendedPath(objDir))
        var objFiles: seq[string] = @[]
        var compileIds: seq[string] = @[]
        for source in target.sourceFiles:
          let objFile = pascalObjFor(objDir, source, target.srcDir)
          createDir(extendedPath(parentDir(objFile)))
          let action = emitCompileAction(projectRoot, fpcExe,
            target.member, source, objFile, objDir, target.srcDir)
          allActions.add(action)
          objFiles.add(objFile)
          compileIds.add(action.id)
        let archiveAction = emitArchiveAction(projectRoot, arExe,
          target.member, objFiles, compileIds)
        allActions.add(archiveAction)
        if target.member.package.len > 0:
          let entry = PascalDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: archiveAction.id,
            outputPath: archivePathFor(projectRoot, target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Pascal executables — consume upstream Pascal libraries AND any
      # cross-language C/C++ archives the depends_on edges resolve to.
      for target in targets:
        if target.member.kind != pdmkExecutable:
          continue
        var entryDeps: seq[PascalDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[PascalDirectCCppUpstreamLibrary] = @[]
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
          fpcExe = fpcExe,
          target = target,
          depLibraries = entryDeps,
          cCppUpstream = entryCCppDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      # M59 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Pascal archive.
      for exec in cCppCrossExecutables:
        var execPascalUpstream: seq[PascalDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for pascalLib in packageLibraries[edge.toPackage]:
                # All Pascal archives are linkable from a C/C++ binary
                # when the Pascal source marks routines with ``public
                # name '...'; cdecl;``. We pass them through regardless
                # of cConsumable — the flag is informational only at
                # this milestone.
                execPascalUpstream.add(pascalLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execPascalUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc pascalDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``ada-direct`` per the M59 spec —
  ## registration order between Pascal and other Mode 3 conventions
  ## only matters when a workspace claims both Pascal AND another
  ## language. In a Pascal+C/C++ workspace this convention claims
  ## dispatch because ``c-cpp-direct``'s ``recognize`` defers when
  ## ``uses:`` names a Pascal toolchain token
  ## (``pascal``/``fpc``/``freepascal``).
  LanguageConvention(
    name: "pascal-direct",
    recognize: pascalDirectRecognize,
    emitFragment: pascalDirectEmitFragment)
