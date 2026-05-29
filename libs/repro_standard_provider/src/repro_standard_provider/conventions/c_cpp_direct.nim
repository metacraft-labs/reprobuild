## C / C++ (Mode 3 / no-Makefile) language convention (Tier 2b).
##
## Mode 3 sibling of ``c_cpp_make.nim`` for projects whose ``repro.nim``
## declares a C/C++ ``executable`` / ``library`` member AND DOES NOT
## ship a ``Makefile`` (or any ecosystem manifest). The convention
## builds the per-source compile + link graph from pure layout — no
## ecosystem build system needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and ``reprobuild-specs/Language-Conventions/C-Cpp.md`` (the "plain
## C/C++" convention spec).
##
## **Recognition** (registered AFTER ``c_cpp_make``):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``gcc`` or ``clang``.
##   * NO root-level ``Makefile`` / ``GNUmakefile`` (the Make convention
##     would have matched FIRST — registration order is defensive in
##     either direction).
##   * NO root-level ``CMakeLists.txt`` (CMake's territory).
##   * NO root-level Autotools artefacts (``configure.ac`` /
##     ``Makefile.am``).
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty C/C++ source layout via ``resolveMemberDirs``.
##
## **Layout** (per ``resolveMemberDirs`` in ``cpp_dep_scanner``):
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/<sources>.{c,cpp,...}
##       <projectRoot>/include/<pkg>/<headers>.h
##
##   Layout B — multiple packages per project file (the canonical
##              Mode 3 multi-package shape)::
##
##       <projectRoot>/<member>/src/<sources>.{c,cpp,...}
##       <projectRoot>/<member>/include/<pkg>/<headers>.h
##
## **Per-source compile argv**::
##
##     gcc -c -O2 -Wall -Wextra -MD -MF <obj>.d \
##         -I <src-dir> -I <include-dir> \
##         -I <dep-include-dir>... \
##         -o <obj> <src>
##
## ``-MD -MF`` produces the depfile reprobuild consumes via
## ``makeDepfilePolicy(<depfile>)`` so header edits invalidate the
## action. Each upstream package's ``include/`` (resolved via the
## Mode 3 ``depends_on`` registry) is threaded onto the ``-I`` list so
## the downstream's ``#include "upstream/foo.h"`` resolves.
##
## **Link / archive argv**:
##
## | Member kind            | Argv                                                |
## |------------------------|-----------------------------------------------------|
## | executable             | ``cc -o <bin> <objs> <upstream-libs>``              |
## | library (static)       | ``ar rcs <pkg>/lib<n>.a <objs>``                    |
##
## The upstream library output paths flow onto the link argv as
## trailing positionals (gcc resolves symbols left-to-right; the .a
## must follow the .o files that reference it). The upstream's link
## action id is added to the executable's ``deps`` for sequencing,
## and its archive path is added to ``inputs`` for cache-hit
## invalidation. Same wiring shape as the Mode 3 Nim convention
## (commit ``0531e21``).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Shared libraries — the DSL doesn't yet thread ``kind: shared``
##     through to C library members; the Mode 3 fixture is static-only.
##   * Cross-compilation (``CC=<triple>-gcc``).
##   * MSVC (``cl.exe``) — the convention emits ``gcc``/``clang``
##     argv exclusively. Windows uses the mingw-w64 ``gcc.exe`` shipped
##     in MSYS2.
##   * Source layouts other than Layout A and Layout B — for example
##     a flat ``<projectRoot>/foo.c`` with sources at the project root
##     itself. Authors with non-standard layouts can write a ``build:``
##     block (Tier 1) or use Mode 2 + Makefile.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Identical to the C/C++ Make convention's scratch dir so the two
    ## conventions produce co-located outputs and ``repro clean`` finds
    ## both. The Mode 3 convention is registered AFTER c_cpp_make, so
    ## the scratch path stays stable when a project flips between Make
    ## and Mode 3.

type
  CCppMemberKind = enum
    ccmkExecutable
    ccmkLibraryStatic

  CCppMember = object
    name: string
    kind: CCppMemberKind
    package: string  ## Owning ``package <name>:`` block (Mode 3).

  CCppEmitTarget = object
    member: CCppMember
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  CCppWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of the
    ## Nim convention's ``NimWorkspaceLibrary``.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    includeDir: string
      ## The owning package's public include dir — added to a downstream
      ## executable's ``-I`` so its ``#include "pkg/foo.h"`` resolves
      ## at compile time.

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesCCppCompiler(source: string): bool =
  ## True when the ``uses:`` block names ``gcc`` or ``clang``. Unlike
  ## the Make convention's check, Mode 3 does NOT require ``make`` in
  ## ``uses:`` — there is no Makefile.
  if source.len == 0:
    return false
  var sawCompiler = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gcc" or token == "clang":
      sawCompiler = true
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
  sawCompiler

type
  CCppPackageUses = object
    package: string
    tokens: seq[string]

proc consumeCCppUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractCCppPackageUses(source: string): seq[CCppPackageUses] =
  ## Local mirror of the Nim convention's ``extractPackageUses``. Used
  ## for cross-language filtering — when a Mode 3 workspace declares
  ## packages for both ``gcc``/``clang`` and other toolchains, this
  ## convention should only emit actions for the ``gcc``/``clang``
  ## packages. The first matching convention wins dispatch (Nim is
  ## registered earlier and handles the mixed case end-to-end), so this
  ## filter is mostly defensive — it keeps a pure C/C++ project's
  ## semantics intact while allowing a mixed project that somehow
  ## reaches this convention (e.g. via a test-time isolated registry)
  ## to emit only the C/C++ subset.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(CCppPackageUses(
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
        consumeCCppUsesToken(currentTokens, raw)
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
          consumeCCppUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesCCpp(usesEntries: openArray[CCppPackageUses];
                     package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names ``gcc`` or ``clang``.
  ## Empty ``package`` (member declared at top level, no enclosing
  ## ``package`` block) falls back to the file-wide ``usesIncludesCCppCompiler``
  ## hint so single-package fixtures continue to work unchanged.
  if package.len == 0:
    return usesIncludesCCppCompiler(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "gcc" or token == "clang":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[CCppMember] =
  ## Walk ``source`` text and emit ``CCppMember`` rows with the owning
  ## ``package <name>:`` block. Mirror of the Nim convention's
  ## ``extractPackageMembers`` — same indentation-tracking heuristic;
  ## same caveats. Members declared at top level (outside any
  ## ``package`` block) get an empty ``package`` field which the
  ## downstream wiring treats as ambient/single-package.
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
        result.add(CCppMember(
          name: name, kind: ccmkExecutable,
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
        result.add(CCppMember(
          name: name, kind: ccmkLibraryStatic,
          package: currentPackage))
      continue

proc rootMakefile(projectRoot: string): string =
  for name in ["GNUmakefile", "Makefile", "makefile"]:
    let candidate = projectRoot / name
    if fileExists(extendedPath(candidate)):
      return candidate
  ""

proc hasCMakeLists(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "CMakeLists.txt"))

proc hasAutotoolsArtifacts(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in")) or
    fileExists(extendedPath(projectRoot / "Makefile.am"))

proc collectSourceFiles(srcDir: string): seq[string] =
  ## Every ``.c`` / ``.cpp`` / ``.cc`` / ``.cxx`` under ``srcDir``,
  ## recursively. Headers are NOT compiled — they're picked up via the
  ## depfile mechanism.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc resolveTarget(projectRoot: string; member: CCppMember): CCppEmitTarget =
  ## Resolve a member's source directory + include directory + the
  ## list of sources to compile via ``resolveMemberDirs`` (the shared
  ## scanner helper that handles Layout A vs Layout B).
  result.member = member
  let resolved = resolveMemberDirs(projectRoot, member.name)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.includeDir = resolved.includeDir
  result.sourceFiles = collectSourceFiles(resolved.srcDir)

proc ccCompiler(): string =
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc arDriver(): string =
  let candidate = findExe("ar")
  if candidate.len > 0:
    return candidate
  "ar"

proc isCpp(source: string): bool =
  let lower = source.toLowerAscii
  lower.endsWith(".cpp") or lower.endsWith(".cc") or
    lower.endsWith(".cxx") or lower.endsWith(".cpp")

proc usesIncludesRustToolchain(source: string): bool =
  ## M34: defer mixed Rust+C/C++ workspaces to the ``rust-direct``
  ## convention (registered later in the standard provider) so a single
  ## convention claims the workspace and emits both directions of the
  ## cross-language matrix from one fragment. Mirrors the Nim
  ## convention's claim of mixed Nim+C/C++ workspaces (registered first).
  ##
  ## Detects ``rust`` / ``rustc`` tokens in any ``uses:`` block,
  ## file-wide. The detail of WHICH package owns which token doesn't
  ## matter — what matters is whether the rust-direct convention will
  ## resolve at least one member. ``rust_direct``'s own recognize does
  ## the full check; we replicate the cheap shape here so we can decline
  ## without importing the sibling convention.
  if source.len == 0:
    return false
  var sawRust = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "rust" or token == "rustc":
      sawRust = true
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
  sawRust

proc hasCargoToml(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "Cargo.toml"))

proc workspaceClaimedByRustDirect(projectRoot, source: string): bool =
  ## True when the ``rust-direct`` Mode 3 convention will recognize the
  ## same workspace. M34 hands cross-language Rust↔C/C++ mixed
  ## workspaces to ``rust-direct`` (it embeds the C/C++ cross helpers
  ## the same way ``nim`` does), so this convention declines.
  ##
  ## The check mirrors ``rust_direct.rustDirectRecognize`` cheaply:
  ## ``uses:`` names rust/rustc anywhere AND no ``Cargo.toml`` at the
  ## workspace root (Mode 2 rust would claim Cargo projects first).
  ## We don't probe for ``rustc`` on PATH or scan source layouts here —
  ## if rust-direct ultimately declines (e.g. no Rust members resolve)
  ## the standard provider's dispatch falls back to c-cpp-direct via
  ## the next match attempt.
  if not usesIncludesRustToolchain(source):
    return false
  if hasCargoToml(projectRoot):
    return false
  true

proc usesIncludesGoToolchain(source: string): bool =
  ## M36: defer mixed Go+C/C++ workspaces to the ``go-direct``
  ## convention (registered later in the standard provider) so a single
  ## convention claims the workspace and emits both directions of the
  ## cross-language matrix (cgo forward + c-archive reverse) from one
  ## fragment. Mirrors ``usesIncludesRustToolchain`` shape.
  ##
  ## Detects ``go`` token in any ``uses:`` block, file-wide. The detail
  ## of WHICH package owns the token doesn't matter — what matters is
  ## whether the go-direct convention will resolve at least one member.
  ## ``go_direct``'s own recognize does the full check; we replicate the
  ## cheap shape here so we can decline without importing the sibling
  ## convention.
  if source.len == 0:
    return false
  var sawGo = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "go":
      sawGo = true
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
  sawGo

proc hasGoMod(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "go.mod"))

proc hasGoWork(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "go.work"))

proc workspaceClaimedByGoDirect(projectRoot, source: string): bool =
  ## True when the ``go-direct`` Mode 3 convention will recognize the
  ## same workspace. M36 hands cross-language Go↔C/C++ mixed workspaces
  ## (cgo forward AND c-archive reverse) to ``go-direct`` (it embeds
  ## the C/C++ cross helpers the same way ``rust-direct`` does), so
  ## this convention declines.
  ##
  ## The check mirrors ``go_direct.goDirectRecognize`` cheaply: ``uses:``
  ## names ``go`` anywhere AND no ``go.mod`` / ``go.work`` at the
  ## workspace root (the Mode 2 ``go`` convention would claim manifest-
  ## based Go projects first). We don't probe for ``go`` on PATH here —
  ## if go-direct ultimately declines (e.g. no Go members resolve) the
  ## standard provider's dispatch falls back to c-cpp-direct via the
  ## next match attempt.
  if not usesIncludesGoToolchain(source):
    return false
  if hasGoMod(projectRoot):
    return false
  if hasGoWork(projectRoot):
    return false
  true

proc cCppDirectRecognize(projectRoot: string;
                         request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO root-level Makefile/GNUmakefile/makefile (Make convention's
  ##     territory).
  ##   * NO root-level CMakeLists.txt (CMake's territory).
  ##   * NO root-level Autotools artefacts (Autotools' territory).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names gcc/clang.
  ##   * at least one ``executable`` / ``library`` member declared AND
  ##     resolves to a non-empty C/C++ source layout via
  ##     ``resolveMemberDirs``.
  ##   * a C compiler (gcc/clang) is on PATH at convention-emit time.
  ##   * M34: NO ``rust`` / ``rustc`` in any ``uses:`` block AND no
  ##     ``Cargo.toml``. A mixed Rust+C/C++ workspace routes through
  ##     ``rust-direct`` (which embeds the C/C++ cross helpers and emits
  ##     both directions of the cross-language matrix from a single
  ##     fragment).
  ##   * M36: NO ``go`` in any ``uses:`` block AND no ``go.mod`` /
  ##     ``go.work``. A mixed Go+C/C++ workspace routes through
  ##     ``go-direct`` (which embeds the C/C++ cross helpers and emits
  ##     both directions of the cgo / c-archive cross-language matrix
  ##     from a single fragment).
  if rootMakefile(projectRoot).len > 0:
    return false
  if hasCMakeLists(projectRoot):
    return false
  if hasAutotoolsArtifacts(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesCCppCompiler(source):
    return false
  if workspaceClaimedByRustDirect(projectRoot, source):
    return false
  if workspaceClaimedByGoDirect(projectRoot, source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if ccCompiler().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveTarget(projectRoot, member)
    if resolved.sourceFiles.len > 0:
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

proc staticLibraryPathFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc objFileFor(objDir, source, srcDir: string): string =
  ## Map a source path to its object path under ``objDir``. Use the
  ## source path RELATIVE to ``srcDir`` so two sources with the same
  ## basename (``a/foo.c`` vs ``b/foo.c``) don't collide.
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

proc emitCompileAction(projectRoot, ccExe: string;
                       member: CCppMember;
                       source, objFile, depFile: string;
                       srcDir, includeDir: string;
                       depIncludeDirs: openArray[string]): BuildActionDef =
  ## One ``gcc -c`` action for a single C/C++ source. ``includeDir`` is
  ## the OWN package's include dir (a ``-I`` pinning so headers under
  ## ``include/<pkg>/`` resolve); ``depIncludeDirs`` are the upstream
  ## packages' include dirs, threaded through Mode 3 dep wiring.
  ##
  ## C++ source files (``.cpp`` / ``.cc`` / ``.cxx``) are detected by
  ## extension and compiled with ``-std=c++20``; C sources get
  ## ``-std=c17``. The ``.cpp`` driver swap is not done here (we always
  ## invoke ``gcc`` / ``clang``; the language is selected via the
  ## ``-x`` flag implicit in the source extension).
  var argv = @[ccExe, "-c", "-O2", "-Wall", "-Wextra",
    "-MD", "-MF", depFile]
  if isCpp(source):
    argv.add("-std=c++20")
  else:
    argv.add("-std=c17")
  # Own source dir on -I so ``#include "sibling.h"`` resolves.
  if dirExists(extendedPath(srcDir)):
    argv.add("-I")
    argv.add(srcDir)
  # Own include dir on -I so ``#include "pkg/foo.h"`` resolves.
  if includeDir.len > 0 and dirExists(extendedPath(includeDir)):
    argv.add("-I")
    argv.add(includeDir)
  # Dep packages' include dirs.
  for incDir in depIncludeDirs:
    if incDir.len == 0:
      continue
    if not dirExists(extendedPath(incDir)):
      continue
    argv.add("-I")
    argv.add(incDir)
  argv.add("-o")
  argv.add(objFile)
  argv.add(source)
  let actionId = "ccpp-direct-compile-" & sanitizeNamePart(member.name) & "-" &
    sanitizeNamePart(extractFilename(source))
  let kindTag = case member.kind
    of ccmkExecutable: "executable"
    of ccmkLibraryStatic: "library-static"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    inputs = @[source],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "ccpp-direct." & kindTag & ".compile")

proc emitLinkAction(projectRoot, ccExe: string;
                    member: CCppMember;
                    objFiles: seq[string];
                    compileActionIds: seq[string];
                    depLibraries: openArray[CCppWorkspaceLibrary]):
                      BuildActionDef =
  ## ``cc -o <bin> <objs> <upstream-libs>`` link action for an
  ## ``executable`` member. The upstream libraries' archive paths land
  ## as trailing positionals (gcc/ld resolve symbols left-to-right;
  ## ``.a``s must follow the ``.o``s that reference them).
  let binaryOutput = binaryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[ccExe, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in depLibraries:
    argv.add(lib.outputPath)
  var deps = compileActionIds
  var inputs = objFiles
  for lib in depLibraries:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "ccpp-direct-link-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "ccpp-direct.executable.link")

proc emitArchiveAction(projectRoot, arExe: string;
                       member: CCppMember;
                       objFiles: seq[string];
                       compileActionIds: seq[string]): BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action for a static library.
  let archiveOutput = staticLibraryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "ccpp-direct-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileActionIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "ccpp-direct.library-static.archive")

proc readScannedDepsSource(projectRoot: string): string =
  ## Read ``<projectRoot>/repro.scanned-deps.nim`` when present and the
  ## project file ``include``s it. Empty string otherwise. Mirror of
  ## the Nim convention's same-named helper.
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
  ## (optionally) the included ``repro.scanned-deps.nim`` text.
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
  ## Tarjan-style three-colour DFS. Mirror of the Nim convention's
  ## same-named helper.
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
  ## Mode 3 dep-graph validation. Raises ``ValueError`` on undeclared-
  ## package references or cycles. The standard provider binary turns
  ## the ``ValueError`` into a non-zero exit + a "repro-standard-provider:"
  ## prefixed message.
  for edge in edges:
    if declaredPackages.find(edge.fromPackage) < 0:
      raise newException(ValueError,
        "c-cpp-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "c-cpp-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "c-cpp-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppMember]): PackageDef =
  var name = "c_cpp_direct_convention"
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

proc emitForMember(projectRoot, ccExe, arExe: string;
                   target: CCppEmitTarget;
                   depLibraries: openArray[CCppWorkspaceLibrary]):
                     tuple[compiles: seq[BuildActionDef];
                           terminal: BuildActionDef] =
  ## Emit per-source compiles + the terminal link/archive action for
  ## one member. ``depLibraries`` is the resolved set of upstream
  ## libraries to thread onto the link line (executables only;
  ## libraries don't link other libraries at archive time — the
  ## downstream binary handles that).
  let objDir = objDirFor(projectRoot, target.member.name)
  createDir(extendedPath(objDir))
  var compileActions: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  var compileIds: seq[string] = @[]
  var depIncludeDirs: seq[string] = @[]
  for lib in depLibraries:
    if lib.includeDir.len > 0 and lib.includeDir notin depIncludeDirs:
      depIncludeDirs.add(lib.includeDir)
  for source in target.sourceFiles:
    let objFile = objFileFor(objDir, source, target.srcDir)
    let depFile = objFile & ".d"
    createDir(extendedPath(parentDir(objFile)))
    objFiles.add(objFile)
    let action = emitCompileAction(projectRoot, ccExe, target.member,
      source, objFile, depFile, target.srcDir, target.includeDir,
      depIncludeDirs)
    compileActions.add(action)
    compileIds.add(action.id)
  case target.member.kind
  of ccmkExecutable:
    let link = emitLinkAction(projectRoot, ccExe, target.member,
      objFiles, compileIds, depLibraries)
    (compileActions, link)
  of ccmkLibraryStatic:
    let archive = emitArchiveAction(projectRoot, arExe, target.member,
      objFiles, compileIds)
    (compileActions, archive)

proc cCppDirectEmitFragment(projectRoot: string;
                            request: ProviderGraphRequest):
                              GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members, validate Mode 3 dep edges,
  ## emit per-source compile + per-member link/archive actions via the
  ## DSL, hand the whole thing to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    # Cross-language filter: in a mixed workspace this convention is
    # never invoked (the Nim convention wins dispatch and emits both
    # languages' actions inline), but the filter is defensive — it
    # guarantees a pure C/C++ project's semantics stay identical while
    # making the convention's output deterministic when a non-C/C++
    # package shares the same ``repro.nim``.
    let usesEntries = extractCCppPackageUses(source)
    var members: seq[CCppMember] = @[]
    for member in allMembers:
      if not packageUsesCCpp(usesEntries, member.package, source):
        continue
      members.add(member)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "c-cpp-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-direct convention: neither 'gcc' nor 'clang' on PATH; " &
          "cannot compile C/C++ sources")
    let arExe = arDriver()
    var targets: seq[CCppEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.sourceFiles.len == 0:
        raise newException(ValueError,
          "c-cpp-direct convention: no C/C++ sources resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & member.name & "/src/ and " &
            "<root>/src/)")
      targets.add(target)
    # Mode 3 ``depends_on`` resolution: collect every workspace dep
    # edge (manual + scanner-emitted) and validate them against the
    # set of packages the project file actually declares.
    let rawDepEdges = collectWorkspaceDepEdges(projectRoot, source)
    let depEdges = dedupDepEdges(rawDepEdges)
    var declaredPackages: seq[string] = @[]
    for member in members:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    validateWorkspaceDeps(depEdges, declaredPackages)

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # Emit LIBRARIES first so their archive output paths + ar
      # action ids are known by the time we reach each executable's
      # link action. Index libraries by owning package so
      # ``depends_on <app>: <lib>`` can resolve to "every library
      # member of <lib>'s package".
      var packageLibraries = initTable[string, seq[CCppWorkspaceLibrary]]()
      for i, target in targets:
        if target.member.kind != ccmkLibraryStatic:
          continue
        let emitted = emitForMember(projectRoot, ccExe, arExe, target, @[])
        for a in emitted.compiles:
          allActions.add(a)
        allActions.add(emitted.terminal)
        if target.member.package.len > 0:
          let archivePath = staticLibraryPathFor(
            projectRoot, target.member.name)
          let entry = CCppWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: emitted.terminal.id,
            outputPath: archivePath,
            includeDir: target.includeDir)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Now executables — their compile + link actions consume the
      # already-registered library archives.
      for i, target in targets:
        if target.member.kind != ccmkExecutable:
          continue
        var entryDeps: seq[CCppWorkspaceLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if not packageLibraries.hasKey(edge.toPackage):
              # Dep on an executable-only package (no library to link)
              # — silent no-op for the link line. Sequence-only build
              # ordering lands when the runtime can route binary-on-
              # binary ordering.
              continue
            for lib in packageLibraries[edge.toPackage]:
              entryDeps.add(lib)
        let emitted = emitForMember(projectRoot, ccExe, arExe, target,
          entryDeps)
        for a in emitted.compiles:
          allActions.add(a)
        allActions.add(emitted.terminal)
        discard target(target.member.name, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registration order: AFTER ``c_cpp_make`` so a project
  ## carrying a Makefile routes through Make; this convention picks up
  ## the no-Makefile case.
  LanguageConvention(
    name: "c-cpp-direct",
    recognize: cCppDirectRecognize,
    emitFragment: cCppDirectEmitFragment)
