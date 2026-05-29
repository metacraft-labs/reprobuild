## Fortran (Mode 3) language convention (Tier 2b).
##
## Mode 3 minimal Fortran convention for projects whose ``repro.nim``
## declares a Fortran ``executable`` / ``library`` member. There is no
## Mode 2 Fortran convention sibling (the Fortran Package Manager ``fpm``
## integration is deferred per ``Language-Conventions/Fortran.md``); this
## file ships the only Fortran convention today.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and ``reprobuild-specs/Language-Conventions/Fortran.md`` (the full
## per-language spec — note this convention covers the Mode 3 minimal
## subset only; ``fpm`` recognition, module ``USE`` cross-package scanning,
## fixed-form ``.f``/``.for``, and the per-source phase-split
## ``-fsyntax-only`` Modern-Fortran-Makefile pattern are all deferred).
##
## **Recognition** (registered AFTER ``python-direct``, mirroring the
## ordering chain of new Mode 3 conventions):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``gfortran`` or ``fortran``.
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty Fortran source layout (Layout A: ``<root>/src/*.f90`` ;
##     Layout B: ``<member>/src/*.f90``).
##   * ``gfortran`` is on PATH at convention-emit time.
##
## **Layout** (mirrors the C/C++ Mode 3 layout):
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.f90        (executable)
##       <projectRoot>/src/lib.f90         (library)
##
##   Layout B — multiple packages per project file::
##
##       <projectRoot>/<member>/src/main.f90 (executable)
##       <projectRoot>/<member>/src/lib.f90  (library)
##
## **Per-source compile argv**::
##
##     gfortran -c -O2 -ffree-form -fimplicit-none \
##         -o <obj> <src.f90>
##
## **Link / archive argv**:
##
## | Member kind      | Argv                                              |
## |------------------|---------------------------------------------------|
## | library (static) | ``ar rcs <root>/.repro/build/<n>/lib<n>.a <objs>``|
## | executable       | ``gfortran -o <bin> <objs> <upstream archives>``  |
##
## The executable link goes through gfortran (not gcc) so the Fortran
## runtime (``libgfortran``, ``libquadmath`` on some platforms,
## ``libgcc_s``) is pulled in automatically.
##
## **M37 cross-language Fortran ↔ C/C++**:
## landed 2026-05-29. The convention claims mixed Fortran + C/C++
## workspaces (``c-cpp-direct``'s ``recognize`` defers when ``uses:``
## anywhere names ``gfortran``/``fortran``, mirroring the rust-direct /
## go-direct pattern). Two directions:
##
##   * **Forward (Fortran binary → C library)**: a Fortran ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers emit
##     per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The Fortran
##     binary's ``gfortran -o`` link action gains the C archive as a
##     trailing positional. The Fortran user declares the C function via
##     ``iso_c_binding`` ``bind(C, name="<symbol>")``; the link line
##     stays the same regardless.
##
##   * **Reverse (C/C++ binary → Fortran library)**: a C/C++ ``executable``
##     ``depends_on`` a Fortran ``library`` member. The Fortran library's
##     ``cConsumable`` flag is derived from the dep edge; when set, the
##     library's archive landing path stays the canonical
##     ``<root>/.repro/build/<name>/lib<name>.a`` (Fortran archives are
##     always ``ar rcs`` so the cConsumable toggle only switches the
##     downstream's link driver from ``gfortran -o`` to ``g++ -o`` and
##     threads ``-lgfortran -lquadmath -lm`` (and ``-lpthread`` on
##     POSIX) so the C++ link resolves the Fortran runtime symbols).
##     Embedded helpers then emit the C/C++ binary's per-source ``g++
##     -c`` + terminal ``g++ -o`` link action; the Fortran staticlib
##     lands on the link argv as a trailing positional plus the
##     platform-specific Fortran-runtime libs.
##
## Action-id prefixes for cross-language emit are
## ``fortran-xlang-ccpp-compile-*``, ``fortran-xlang-ccpp-archive-*``,
## ``fortran-xlang-ccpp-exec-compile-*``, ``fortran-xlang-ccpp-exec-link-*``
## (mirror of the rust-direct ``rust-xlang-ccpp-...`` discriminator).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * ``fpm.toml`` recognition + Mode 2 ``fpm`` delegation — deferred.
##   * Fixed-form ``.f`` / ``.for`` sources — deferred; only free-form
##     ``.f90``/``.f95``/``.f03``/``.f08`` are accepted today.
##   * Module ``USE`` cross-package scanning — the spec calls for parsing
##     ``USE <name>`` to derive per-source intra-member DAG edges. M37
##     keeps fixtures flat (one source per member) so the within-member
##     order doesn't matter; cross-package deps go through the explicit
##     ``uses:`` and ``depends_on`` lines.
##   * Per-source phase-split ``-fsyntax-only`` Module-interface pass —
##     deferred. M37 compiles in a single pass per source.
##   * ``ifx`` / ``nvfortran`` / ``lfortran`` compilers — deferred; the
##     convention hard-codes ``gfortran``.
##   * Cross-compilation.
##   * Shared libraries (``cdylib``-equivalent).

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Mirror of every other Mode 3 convention's scratch dir so
    ## ``repro clean`` (a single rm -rf .repro/) sweeps all outputs.

  FortranSourceExtensions = [".f90", ".f95", ".f03", ".f08"]
    ## Free-form Fortran sources only. Fixed-form ``.f`` / ``.for`` is
    ## deferred per the M37 honest-scope cut.

type
  FortranDirectMemberKind = enum
    fdmkExecutable
    fdmkLibraryStatic

  FortranDirectMember = object
    name: string
    kind: FortranDirectMemberKind
    package: string  ## Owning ``package <name>:`` block.
    cConsumable: bool
      ## M37 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library's downstream link gains the Fortran runtime libs
      ## (``-lgfortran`` + friends). The archive shape is the same
      ## ``ar rcs lib<name>.a`` either way — Fortran static libs are
      ## C-ABI-compatible by construction when the user marks routines
      ## with ``bind(C)``. The flag here only drives the cross-language
      ## downstream's link-time runtime injection.

  FortranDirectEmitTarget = object
    member: FortranDirectMember
    srcDir: string
    sourceFiles: seq[string]

  FortranDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the C/C++ ``CCppWorkspaceLibrary``.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    cConsumable: bool

  FortranDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Discovered by ``collectCCppCrossMembers`` and emitted
    ## in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  FortranDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Used for the reverse direction (C++ binary → Fortran
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  FortranDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a Fortran binary's
    ## link picks up as a trailing positional on the gfortran argv.
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

proc usesIncludesFortranToolchain*(source: string): bool =
  ## True when the ``uses:`` block names ``gfortran`` or ``fortran``.
  ## Mirror of ``usesIncludesRustToolchain`` from rust_direct.nim.
  if source.len == 0:
    return false
  var sawFortran = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gfortran" or token == "fortran":
      sawFortran = true
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
  sawFortran

type
  FortranDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeFortranUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractFortranPackageUses(source: string): seq[FortranDirectPackageUses] =
  ## Mirror of the C/C++ convention's ``extractCCppPackageUses``.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(FortranDirectPackageUses(
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
        consumeFortranUsesToken(currentTokens, raw)
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
          consumeFortranUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesFortran(usesEntries: openArray[FortranDirectPackageUses];
                       package, source: string): bool =
  ## True when ``package``'s ``uses:`` names ``gfortran`` / ``fortran``.
  if package.len == 0:
    return usesIncludesFortranToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "gfortran" or token == "fortran":
        return true
    return false
  false

proc packageUsesAnyCCpp(usesEntries: openArray[FortranDirectPackageUses];
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

proc extractMembersWithOwnership(source: string): seq[FortranDirectMember] =
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
        result.add(FortranDirectMember(
          name: name, kind: fdmkExecutable,
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
        result.add(FortranDirectMember(
          name: name, kind: fdmkLibraryStatic,
          package: currentPackage))
      continue

proc isFortranSourceFile*(path: string): bool =
  let lower = path.toLowerAscii
  for ext in FortranSourceExtensions:
    if lower.endsWith(ext):
      return true
  false

proc dirHasFortranSources(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isFortranSourceFile(path):
      return true
  false

proc resolveFortranMemberDirs(projectRoot, memberName: string):
    tuple[srcDir: string; entrySource: string] =
  ## Layout B first (``<root>/<member>/src/...``) then Layout A
  ## (``<root>/src/...``).
  let subdirSrc = projectRoot / memberName / "src"
  if dirHasFortranSources(subdirSrc):
    result.srcDir = subdirSrc
    for ext in FortranSourceExtensions:
      let cand = subdirSrc / (memberName & ext)
      if fileExists(extendedPath(cand)):
        result.entrySource = cand
        return
      let mainCand = subdirSrc / ("main" & ext)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    for path in walkDirRec(subdirSrc):
      if isFortranSourceFile(path):
        result.entrySource = path
        return
    return
  let topSrc = projectRoot / "src"
  if dirHasFortranSources(topSrc):
    result.srcDir = topSrc
    for ext in FortranSourceExtensions:
      let cand = topSrc / (memberName & ext)
      if fileExists(extendedPath(cand)):
        result.entrySource = cand
        return
      let mainCand = topSrc / ("main" & ext)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    for path in walkDirRec(topSrc):
      if isFortranSourceFile(path):
        result.entrySource = path
        return

proc collectFortranSources(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isFortranSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc gfortranCompiler(): string =
  findExe("gfortran")

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

proc arDriver(): string =
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

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
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc isFortranExtension(path: string): bool =
  let lower = path.toLowerAscii
  for ext in FortranSourceExtensions:
    if lower.endsWith(ext):
      return true
  false

proc fortranObjFor(objDir, source, srcDir: string): string =
  var rel: string
  try:
    rel = relativePath(source, srcDir)
  except OSError:
    rel = extractFilename(source)
  rel = rel.replace('\\', '/')
  var stem = rel
  for ext in FortranSourceExtensions:
    if stem.toLowerAscii.endsWith(ext):
      stem = stem[0 ..< stem.len - ext.len]
      break
  objDir / (sanitizeNamePart(stem) & ".o")

proc resolveTarget(projectRoot: string;
                   member: FortranDirectMember): FortranDirectEmitTarget =
  result.member = member
  let resolved = resolveFortranMemberDirs(projectRoot, member.name)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.sourceFiles = collectFortranSources(resolved.srcDir)

proc fortranDirectRecognize(projectRoot: string;
                            request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``gfortran`` / ``fortran``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Fortran source layout.
  ##   * ``gfortran`` is on PATH.
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesFortranToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if gfortranCompiler().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveTarget(projectRoot, member)
    if resolved.sourceFiles.len > 0:
      atLeastOneResolved = true
      break
  atLeastOneResolved

proc emitCompileAction(projectRoot, gfortranExe: string;
                      member: FortranDirectMember;
                      source, objFile: string): BuildActionDef =
  ## ``gfortran -c`` for one source file. No depfile — gfortran does
  ## emit ``-MD`` style output but the Mode 3 minimal contract keeps
  ## headers / module-USE scanning out of scope, so the action declares
  ## the source file alone as the input.
  let argv = @[
    gfortranExe, "-c",
    "-O2",
    "-ffree-form",
    "-fimplicit-none",
    "-J", parentDir(objFile),
    "-I", parentDir(objFile),
    "-o", objFile,
    source,
  ]
  let actionId = "fortran-direct-compile-" &
    sanitizeNamePart(member.name) & "-" &
    sanitizeNamePart(extractFilename(source))
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "fortran-direct.compile")

proc emitArchiveAction(projectRoot, arExe: string;
                      member: FortranDirectMember;
                      objFiles, compileIds: seq[string]):
                        BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>``. Same shape as c-cpp-direct's
  ## archive action.
  let archiveOutput = archivePathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "fortran-direct-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "fortran-direct.archive")

proc fortranRuntimeLinkLibs(): seq[string] =
  ## Libraries a C/C++ binary must link to satisfy a Fortran archive's
  ## runtime references. ``-lgfortran`` is mandatory (the Fortran I/O
  ## runtime; ``print *`` resolves through it). ``-lquadmath`` and
  ## ``-lm`` are pulled in for math intrinsics; the gfortran driver
  ## itself adds them to its own link line so we mirror that here. On
  ## POSIX the gfortran runtime also touches pthread.
  when defined(windows):
    @["-lgfortran", "-lquadmath", "-lm"]
  else:
    @["-lgfortran", "-lquadmath", "-lm", "-lpthread"]

proc emitLinkAction(projectRoot, gfortranExe: string;
                   target: FortranDirectEmitTarget;
                   objFiles, compileIds: seq[string];
                   depLibraries: openArray[FortranDirectWorkspaceLibrary];
                   cCppUpstream: openArray[FortranDirectCCppUpstreamLibrary]):
                     BuildActionDef =
  ## ``gfortran -o <bin> <objs> <upstream archives>``. Threads each
  ## upstream Fortran archive AND each upstream C/C++ archive as a
  ## trailing positional. gfortran's link driver pulls in libgfortran
  ## + libquadmath + libgcc_s automatically — no explicit ``-l`` flags
  ## needed on the gfortran driver path.
  let outputPath = binaryPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(outputPath)))
  var argv = @[gfortranExe, "-o", outputPath]
  for obj in objFiles:
    argv.add(obj)
  for lib in depLibraries:
    argv.add(lib.outputPath)
  for c in cCppUpstream:
    argv.add(c.outputPath)
  var inputs = objFiles
  for lib in depLibraries:
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  for c in cCppUpstream:
    if inputs.find(c.outputPath) < 0:
      inputs.add(c.outputPath)
  var deps = compileIds
  for lib in depLibraries:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
  for c in cCppUpstream:
    if deps.find(c.linkActionId) < 0:
      deps.add(c.linkActionId)
  buildAction(
    id = "fortran-direct-link-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "fortran-direct.link")

# ---------------------------------------------------------------------------
# M37 cross-language C/C++ helpers (mixed-workspace support). Mirror of
# rust_direct's emit shape — discriminator on the action-id prefix
# (``fortran-xlang-ccpp-...``).
# ---------------------------------------------------------------------------

type
  FortranDirectCCppPlainMemberKind = enum
    fccmkExecutable
    fccmkLibraryStatic

  FortranDirectCCppPlainMember = object
    package: string
    name: string
    kind: FortranDirectCCppPlainMemberKind

proc extractCCppMembersFromText(source: string):
    seq[FortranDirectCCppPlainMember] =
  ## Mirror of rust_direct's ``extractCCppMembersFromText``.
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
        result.add(FortranDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: fccmkExecutable))
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
        result.add(FortranDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: fccmkLibraryStatic))
      continue

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[FortranDirectPackageUses]):
                               seq[FortranDirectCCppMember] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != fccmkLibraryStatic:
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
    result.add(FortranDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[FortranDirectPackageUses]):
                                   seq[FortranDirectCCppExecutable] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != fccmkExecutable:
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
    result.add(FortranDirectCCppExecutable(
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
                                member: FortranDirectCCppMember;
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
  let actionId = "fortran-xlang-ccpp-compile-" &
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
    commandStatsId = "fortran-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: FortranDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "fortran-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "fortran-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: FortranDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "fortran-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile upstream C/C++ library '" &
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
# Reverse-direction (C++ binary → Fortran staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: FortranDirectCCppExecutable;
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
  let actionId = "fortran-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "fortran-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: FortranDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 fortranUpstream:
                                   openArray[FortranDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Fortran
  ## staticlib lands as a trailing positional, followed by the Fortran
  ## runtime libs (-lgfortran -lquadmath -lm; -lpthread on POSIX) so
  ## the C++ link resolves Fortran runtime symbols.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in fortranUpstream:
    argv.add(lib.outputPath)
  for libFlag in fortranRuntimeLinkLibs():
    argv.add(libFlag)
  var deps = compileIds
  var inputs = objFiles
  for lib in fortranUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "fortran-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "fortran-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: FortranDirectCCppExecutable;
                             fortranUpstream:
                               openArray[FortranDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "fortran-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "fortran-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, fortranUpstream)
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
        "fortran-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "fortran-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "fortran-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[FortranDirectMember]): PackageDef =
  var name = "fortran_direct_convention"
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

proc fortranDirectEmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractFortranPackageUses(source)
    var members: seq[FortranDirectMember] = @[]
    for member in allMembers:
      if not packageUsesFortran(usesEntries, member.package, source):
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
        "fortran-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let gfortranExe =
      if members.len > 0: gfortranCompiler() else: ""
    if members.len > 0 and gfortranExe.len == 0:
      raise newException(ValueError,
        "fortran-direct convention: 'gfortran' not on PATH; " &
          "cannot compile Fortran sources")
    var targets: seq[FortranDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.sourceFiles.len == 0:
        raise newException(ValueError,
          "fortran-direct convention: no Fortran sources resolved for " &
            "member '" & member.name & "' under " & projectRoot)
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

    # M37 reverse cross-language: derive ``cConsumable`` for each
    # Fortran library from the dep graph.
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[FortranDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == fdmkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    let pkg = syntheticPackage(projectRoot, members)
    let arExe = arDriver()
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # M37 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the Fortran binary's link can reference each archive's
      # output path + link action id by the time we emit the link.
      var packageCCppLibraries =
        initTable[string, seq[FortranDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = FortranDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # Fortran LIBRARIES next so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action.
      var packageLibraries =
        initTable[string, seq[FortranDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != fdmkLibraryStatic:
          continue
        let objDir = objDirFor(projectRoot, target.member.name)
        createDir(extendedPath(objDir))
        var objFiles: seq[string] = @[]
        var compileIds: seq[string] = @[]
        for source in target.sourceFiles:
          let objFile = fortranObjFor(objDir, source, target.srcDir)
          createDir(extendedPath(parentDir(objFile)))
          let action = emitCompileAction(projectRoot, gfortranExe,
            target.member, source, objFile)
          allActions.add(action)
          objFiles.add(objFile)
          compileIds.add(action.id)
        let archiveAction = emitArchiveAction(projectRoot, arExe,
          target.member, objFiles, compileIds)
        allActions.add(archiveAction)
        if target.member.package.len > 0:
          let entry = FortranDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: archiveAction.id,
            outputPath: archivePathFor(projectRoot, target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Fortran executables — consume already-registered upstream
      # libraries (both Fortran and cross-language C/C++).
      for target in targets:
        if target.member.kind != fdmkExecutable:
          continue
        let objDir = objDirFor(projectRoot, target.member.name)
        createDir(extendedPath(objDir))
        var objFiles: seq[string] = @[]
        var compileIds: seq[string] = @[]
        for source in target.sourceFiles:
          let objFile = fortranObjFor(objDir, source, target.srcDir)
          createDir(extendedPath(parentDir(objFile)))
          let action = emitCompileAction(projectRoot, gfortranExe,
            target.member, source, objFile)
          allActions.add(action)
          objFiles.add(objFile)
          compileIds.add(action.id)
        var entryDeps: seq[FortranDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[FortranDirectCCppUpstreamLibrary] = @[]
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
        let linkAction = emitLinkAction(projectRoot, gfortranExe,
          target, objFiles, compileIds,
          entryDeps, entryCCppDeps)
        allActions.add(linkAction)
        discard target(target.member.name, allActions)
      # M37 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Fortran archive.
      for exec in cCppCrossExecutables:
        var execFortranUpstream: seq[FortranDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for fortranLib in packageLibraries[edge.toPackage]:
                # Fortran archives are always linkable from a C/C++
                # binary when bind(C)-marked. We pass them through
                # regardless of cConsumable (the flag's only effect at
                # this milestone is to drive the runtime injection
                # via fortranRuntimeLinkLibs, which we hard-emit).
                execFortranUpstream.add(fortranLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execFortranUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fortranDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Registered AFTER ``python-direct`` (and AFTER all the other Mode 3
  ## conventions) per the M37 spec — there is no Mode 2 Fortran
  ## convention sibling so registration order between Fortran and other
  ## languages only matters when a workspace claims both Fortran AND
  ## another language. In a Fortran+C/C++ workspace this convention
  ## claims dispatch because c-cpp-direct defers when ``uses:`` names
  ## ``gfortran``/``fortran``.
  LanguageConvention(
    name: "fortran-direct",
    recognize: fortranDirectRecognize,
    emitFragment: fortranDirectEmitFragment)
