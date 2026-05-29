## D (Mode 3) language convention (Tier 2b).
##
## Mode 3 minimal D convention for projects whose ``repro.nim`` declares
## a D ``executable`` / ``library`` member AND DOES NOT ship a
## ``dub.json`` or ``dub.sdl`` at the workspace root. The convention
## builds the per-member compile + link graph from pure layout — no
## ``dub`` manifest needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M45 section of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``zig-direct`` / alongside the
## other Mode 3 conventions):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``d``, ``dmd``, ``ldc2``, or ``gdc``.
##   * NO ``<projectRoot>/dub.json`` and NO ``<projectRoot>/dub.sdl``
##     at the workspace root. The future Mode 2 D convention's
##     territory (deferred per the M45 honest-scope cut — Mode 3 only
##     for M45).
##   * At least one ``executable`` / ``library`` member is declared
##     AND resolves to a non-empty D source layout (Layout A or B).
##   * A D compiler (``ldc2`` / ``ldmd2`` / ``dmd``) is on PATH at
##     convention-emit time. ``ldc2``/``ldmd2`` is preferred when
##     available — LLVM-based, well-supported on Windows. ``dmd``
##     falls back. ``gdc`` (the GCC-based driver) is recognised as a
##     ``uses:`` token but the convention itself drives the front-end
##     via ``ldmd2``/``dmd`` argv shape (gdc uses gcc-style flags
##     instead — deferred).
##
## **Layout**:
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.d         (executable)
##       <projectRoot>/src/lib.d          (library; ``<member>.d``
##                                        also accepted as a fallback)
##
##   Layout B — multiple packages per project file::
##
##       <projectRoot>/<member>/src/main.d (executable)
##       <projectRoot>/<member>/src/lib.d  (library)
##
## **Per-member D argv** (using ``ldmd2`` — the DMD-compatible driver
## shipped with LDC, which avoids LDC's ``ldc2`` host-CPU auto-detection
## crash on some recent AMD CPUs; falls back to ``dmd`` when neither
## ``ldmd2`` nor ``ldc2`` is on PATH):
##
## | Member kind            | Argv                                          |
## |------------------------|-----------------------------------------------|
## | executable             | ``ldmd2 -of=<out> -release -O <src.d>*``      |
## | library (static)       | ``ldmd2 -lib -of=<out> -release -O <src.d>*`` |
##
## The library output lands at
## ``<root>/.repro/build/<name>/lib<name>.a`` — the cross-language
## archive schema shared with ``c-cpp-direct``, the Rust convention's
## staticlib path, the Fortran convention's archive path, Nim's
## archive output, and Zig's static archive. D's ``-lib`` produces a
## static archive by default; on Windows the ``ldmd2``/``dmd`` driver
## accepts ``.a`` as the output extension and produces an ar-style
## archive directly. The resulting ``.a`` is directly consumable by a
## C/C++ linker which is the load-bearing property for the M45
## cross-language reverse direction.
##
## **M45 cross-language D ↔ C/C++**:
##
##   * **Forward (D binary → C library)**: a D ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers
##     emit per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The D
##     binary's ``ldmd2`` link gains the C archive via the linker
##     pass-through ``-L=<archive-path>`` (the ldmd2/dmd driver
##     refuses ``.a`` as a positional source on Windows because the
##     extension isn't D-source-recognised; ``-L=`` forwards the
##     archive to the underlying linker which resolves the symbol).
##     The D user declares the C function via ``extern (C)``; the
##     link line stays the same regardless.
##
##   * **Reverse (C/C++ binary → D library)**: a C/C++ ``executable``
##     ``depends_on`` a D ``library`` member. The D library's
##     ``cConsumable`` flag is derived from the dep edge; the archive
##     shape is the same ``ldmd2 -lib`` static archive either way (D
##     static libs are C-ABI-compatible by construction when the user
##     marks routines with ``extern (C)``). Embedded helpers then emit
##     the C/C++ binary's per-source ``g++ -c`` + terminal ``g++ -o``
##     link action; the D staticlib lands on the link argv as a
##     trailing positional. For libraries that use only ``extern (C)``
##     entry points + ``core.stdc.*`` (the C header bindings; no
##     druntime / phobos required), the gcc/ld driver resolves all
##     references against the archive itself without external runtime
##     libs — same property Zig's M44 cross-language fixture relies on.
##
##     For libraries that pull in D's standard library (``import
##     std.*``) or D garbage collector, the C/C++ link would
##     additionally need ``-lphobos2-ldc -ldruntime-ldc -lm
##     -lpthread`` (POSIX) plus ``Initialize_runtime``/``Terminate_runtime``
##     calls. The M45 honest-scope cut limits the reverse fixture to
##     C-ABI-only entry points + ``core.stdc.*`` (no
##     ``import std.*`` / no GC) so the C/C++ link line stays minimal;
##     full ``phobos2`` linking is deferred to a future milestone.
##
## Action-id prefixes for cross-language emit are
## ``d-xlang-ccpp-compile-*``, ``d-xlang-ccpp-archive-*``,
## ``d-xlang-ccpp-exec-compile-*``, ``d-xlang-ccpp-exec-link-*``
## (mirror of the rust-direct ``rust-xlang-ccpp-...`` /
## fortran-direct ``fortran-xlang-ccpp-...`` / zig-direct
## ``zig-xlang-ccpp-...`` discriminators).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Mode 2 ``dub.json`` / ``dub.sdl`` recognition + ``dub build``
##     delegation — deferred. The future Mode 2 D convention will key
##     on these manifests and shell out to ``dub build
##     --build=release``. Mode 3 only for M45 per the milestone's
##     honest cut.
##   * ``import`` dependency scanner — deferred. Cross-package edges
##     are hand-authored as ``depends_on`` in ``repro.nim`` until a
##     future milestone adds a D ``import foo.bar;`` scanner.
##   * Multi-target / multi-arch (``-mtriple=...``) — deferred.
##   * Test discovery (``dub test`` / ``unittest`` blocks) — deferred.
##   * D shared libraries — deferred (Mode 3 emits static archives
##     only).
##   * Full ``phobos2`` linking for the reverse cross-language path —
##     deferred per the C-ABI-only fixture scope above.
##   * GDC support — the convention's ``uses:`` token list recognises
##     ``gdc`` but the per-member argv shape is ``ldmd2``/``dmd``-
##     style; full GDC support (gcc-style flags) deferred.
##   * D version churn: the convention pins no specific version. The
##     ``ldmd2`` / ``dmd`` binary on PATH (or under
##     ``D:/metacraft-dev-deps/ldc/<v>/ldc2-<v>-windows-x64/bin/``)
##     drives whatever D front-end version the host carries.
##   * The M9 harness SKIPs cleanly when D is missing so a host
##     without any D compiler still passes the gate.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Mirror of every other Mode 3 convention's scratch dir so
    ## ``repro clean`` (a single ``rm -rf .repro/``) sweeps all outputs.

  DSourceExtension = ".d"

type
  DDirectMemberKind = enum
    ddmkExecutable
    ddmkLibraryStatic

  DDirectMember = object
    name: string
    kind: DDirectMemberKind
    package: string  ## Owning ``package <name>:`` block.
    cConsumable: bool
      ## M45 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library's archive is the canonical
      ## ``<root>/.repro/build/<name>/lib<name>.a`` (D static libs
      ## are already C-ABI compatible when routines are marked
      ## ``extern (C)``). The flag is informational today — D's
      ## archive shape doesn't change based on consumer — but
      ## drives the dep-graph wiring on the consumer side.

  DDirectEmitTarget = object
    member: DDirectMember
    srcDir: string
    entrySource: string

  DDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the Zig convention's ``ZigDirectWorkspaceLibrary``.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    cConsumable: bool

  DDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Discovered by ``collectCCppCrossMembers`` and emitted
    ## in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  DDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Used for the reverse direction (C++ binary → D
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  DDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a D binary's
    ## link picks up via ``-L=<archive>`` (linker pass-through).
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

const DToolchainTokens = ["d", "dmd", "ldc2", "gdc"]

proc isDToolchainToken(token: string): bool =
  for entry in DToolchainTokens:
    if token == entry:
      return true
  false

proc usesIncludesDToolchain*(source: string): bool =
  ## True when the ``uses:`` block names any of the D toolchain
  ## tokens (``d``/``dmd``/``ldc2``/``gdc``). Mirror of
  ## ``usesIncludesZigToolchain`` from zig_direct.nim.
  if source.len == 0:
    return false
  var sawD = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if isDToolchainToken(token):
      sawD = true
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
  sawD

type
  DDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeDUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractDPackageUses(source: string): seq[DDirectPackageUses] =
  ## Mirror of the C/C++ convention's ``extractCCppPackageUses`` and
  ## the Zig convention's ``extractZigPackageUses``.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(DDirectPackageUses(
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
        consumeDUsesToken(currentTokens, raw)
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
          consumeDUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesD(usesEntries: openArray[DDirectPackageUses];
                  package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names a D toolchain
  ## token. When ``package`` is empty (no package block at all) we
  ## fall back to the workspace-wide ``usesIncludesDToolchain``.
  if package.len == 0:
    return usesIncludesDToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if isDToolchainToken(token):
        return true
    return false
  false

proc packageUsesAnyCCpp(usesEntries: openArray[DDirectPackageUses];
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

proc extractMembersWithOwnership(source: string): seq[DDirectMember] =
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
        result.add(DDirectMember(
          name: name, kind: ddmkExecutable,
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
        result.add(DDirectMember(
          name: name, kind: ddmkLibraryStatic,
          package: currentPackage))
      continue

proc isDSourceFile*(path: string): bool =
  path.toLowerAscii.endsWith(DSourceExtension)

proc dirHasDSources(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isDSourceFile(path):
      return true
  false

proc resolveDMemberDirs(projectRoot, memberName: string;
                        kind: DDirectMemberKind):
    tuple[srcDir: string; entrySource: string] =
  ## Layout B first (``<root>/<member>/src/...``) then Layout A
  ## (``<root>/src/...``). For executables the convention looks for
  ## ``<member>.d`` then ``main.d``; for libraries it looks for
  ## ``<member>.d`` then ``lib.d``.
  let candidatesB = projectRoot / memberName / "src"
  if dirHasDSources(candidatesB):
    result.srcDir = candidatesB
    let memberFile = candidatesB / (memberName & DSourceExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of ddmkExecutable:
      let mainCand = candidatesB / ("main" & DSourceExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of ddmkLibraryStatic:
      let libCand = candidatesB / ("lib" & DSourceExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesB):
      if isDSourceFile(path):
        result.entrySource = path
        return
    return
  let candidatesA = projectRoot / "src"
  if dirHasDSources(candidatesA):
    result.srcDir = candidatesA
    let memberFile = candidatesA / (memberName & DSourceExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of ddmkExecutable:
      let mainCand = candidatesA / ("main" & DSourceExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of ddmkLibraryStatic:
      let libCand = candidatesA / ("lib" & DSourceExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesA):
      if isDSourceFile(path):
        result.entrySource = path
        return

proc collectDSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.d`` under ``srcDir``, recursively. Used to compute the
  ## declared ``inputs`` of the link action so source-only edits
  ## invalidate the cache.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isDSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc hasDubManifest(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "dub.json")) or
    fileExists(extendedPath(projectRoot / "dub.sdl"))

proc dCompiler*(): string =
  ## Locate a D front-end. Preference order:
  ##   1. ``ldmd2`` on PATH (DMD-compatible driver shipped with LDC;
  ##      avoids LDC ``ldc2``'s host-CPU auto-detection crash on some
  ##      recent AMD CPUs).
  ##   2. ``dmd`` on PATH.
  ##   3. ``ldc2`` on PATH (last because of the host-CPU caveat above).
  ##   4. Windows fallback: probe ``D:/metacraft-dev-deps/ldc/<v>/
  ##      ldc2-<v>-windows-x64/bin/ldmd2.exe`` (preferring ``ldmd2``
  ##      over ``ldc2`` in the bundled tree for the same reason).
  let ldmd = findExe("ldmd2")
  if ldmd.len > 0:
    return ldmd
  let dmd = findExe("dmd")
  if dmd.len > 0:
    return dmd
  let ldc = findExe("ldc2")
  if ldc.len > 0:
    return ldc
  when defined(windows):
    let ldcRoot = "D:/metacraft-dev-deps/ldc"
    if dirExists(ldcRoot):
      var best = ""
      for kind, path in walkDir(ldcRoot):
        if kind != pcDir:
          continue
        # Layout: ldc/<version>/ldc2-<version>-windows-x64/bin/ldmd2.exe
        for kind2, sub in walkDir(path):
          if kind2 != pcDir:
            continue
          let candidate = sub / "bin" / "ldmd2.exe"
          if fileExists(extendedPath(candidate)):
            if candidate > best:
              best = candidate
            continue
          let fallback = sub / "bin" / "ldc2.exe"
          if fileExists(extendedPath(fallback)):
            if candidate > best:
              best = fallback
      if best.len > 0:
        return best
  ""

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc resolveTarget(projectRoot: string; member: DDirectMember):
    DDirectEmitTarget =
  result.member = member
  let resolved = resolveDMemberDirs(projectRoot, member.name, member.kind)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource

proc dDirectRecognize(projectRoot: string;
                      request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``dub.json`` / ``dub.sdl`` at the workspace root (the
  ##     future Mode 2 D convention's territory; M45 only recognises
  ##     Mode 3).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``d``/``dmd``/``ldc2``/``gdc``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty D source layout.
  ##   * a D compiler is on PATH (or under
  ##     ``D:/metacraft-dev-deps/ldc/<v>/...`` on Windows).
  if hasDubManifest(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesDToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if dCompiler().len == 0:
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

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".exe")
  else:
    scratchPathFor(projectRoot, member) / member

proc archivePathFor(projectRoot, member: string): string =
  ## D static library output. Lands at
  ## ``<root>/.repro/build/<name>/lib<name>.a`` — the canonical
  ## archive schema shared with ``c-cpp-direct``, Rust's staticlib
  ## path, Fortran's archive path, Nim's archive output, and Zig's
  ## static archive. Same path regardless of whether the consumer is
  ## D or C/C++.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc emitLinkAction(projectRoot, dExe: string;
                    target: DDirectEmitTarget;
                    depLibraries: openArray[DDirectWorkspaceLibrary];
                    cCppUpstream: openArray[DDirectCCppUpstreamLibrary] = []):
                      BuildActionDef =
  ## One ``ldmd2`` / ``dmd`` invocation per member.
  ##
  ## Output paths:
  ##   * executable → ``.repro/build/<name>/<name>[.exe]``
  ##   * library    → ``.repro/build/<name>/lib<name>.a``
  ##
  ## Cross-language wiring:
  ##   * Forward (D binary → C archive): each upstream C archive
  ##     lands as ``-L=<archive-path>`` on the ldmd2 argv (linker
  ##     pass-through). The ldmd2/dmd driver refuses ``.a`` as a
  ##     positional source on Windows; ``-L=`` forwards the archive
  ##     to the underlying linker which resolves the symbol at link
  ##     time.
  ##   * Reverse (the staticlib emit path) is symmetric — the D
  ##     library's archive is the same lib<name>.a; consumer wiring
  ##     happens in the C/C++ helper's link action.
  let outDir = scratchPathFor(projectRoot, target.member.name)
  createDir(extendedPath(outDir))
  let outputPath =
    case target.member.kind
    of ddmkExecutable: binaryPathFor(projectRoot, target.member.name)
    of ddmkLibraryStatic: archivePathFor(projectRoot, target.member.name)
  # D argv:
  #   ldmd2 -release -O -of=<out> <src> [extra-srcs...] [-L=<archive>...]
  # For library targets, ``-lib`` is added before ``-of=`` so the
  # driver emits a static archive instead of an executable.
  var argv = @[dExe, "-release", "-O"]
  if target.member.kind == ddmkLibraryStatic:
    argv.add("-lib")
  argv.add("-of=" & outputPath)
  argv.add(target.entrySource)
  # Additional sibling sources under the same src dir get appended so
  # multi-file libraries / executables compile cleanly. ldmd2/dmd
  # accepts a list of ``.d`` files as positional args and produces a
  # single object module per source, linked together by the driver.
  let crateSources = collectDSourcesUnderSrcDir(target.srcDir)
  for src in crateSources:
    if src != target.entrySource and argv.find(src) < 0:
      argv.add(src)
  # Thread upstream D library archives as ``-L=`` linker pass-through.
  # We DON'T add them for ``-lib`` (a static archive can't depend on
  # another static archive at archive-build time; the downstream's
  # link does the resolution).
  if target.member.kind == ddmkExecutable:
    for lib in depLibraries:
      argv.add("-L=" & lib.outputPath)
    # Forward direction (M45 cross-language): upstream C/C++ archives.
    # Same ``-L=`` shape — ldmd2's linker resolves them at link time.
    for c in cCppUpstream:
      argv.add("-L=" & c.outputPath)
  var inputs = crateSources
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
  let actionId = "d-direct-link-" & sanitizeNamePart(target.member.name)
  let kindTag =
    case target.member.kind
    of ddmkExecutable: "executable"
    of ddmkLibraryStatic: "library-staticlib"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "d-direct." & kindTag & ".link")

# ---------------------------------------------------------------------------
# M45 cross-language C/C++ helpers (mixed-workspace support). Mirror of
# rust_direct / fortran_direct / zig_direct — discriminator on the
# action-id prefix (``d-xlang-ccpp-...``).
# ---------------------------------------------------------------------------

type
  DDirectCCppPlainMemberKind = enum
    dccmkExecutable
    dccmkLibraryStatic

  DDirectCCppPlainMember = object
    package: string
    name: string
    kind: DDirectCCppPlainMemberKind

proc extractCCppMembersFromText(source: string):
    seq[DDirectCCppPlainMember] =
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
        result.add(DDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: dccmkExecutable))
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
        result.add(DDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: dccmkLibraryStatic))
      continue

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[DDirectPackageUses]):
                               seq[DDirectCCppMember] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != dccmkLibraryStatic:
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
    result.add(DDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[DDirectPackageUses]):
                                   seq[DDirectCCppExecutable] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != dccmkExecutable:
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
    result.add(DDirectCCppExecutable(
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
                                member: DDirectCCppMember;
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
  let actionId = "d-xlang-ccpp-compile-" &
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
    commandStatsId = "d-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: DDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "d-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "d-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: DDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "d-direct convention (mixed workspace): neither 'gcc' nor " &
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
# Reverse-direction (C++ binary → D staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: DDirectCCppExecutable;
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
  let actionId = "d-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "d-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: DDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 dUpstream:
                                   openArray[DDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream D
  ## staticlib lands as a trailing positional. The M45 honest-scope
  ## cut limits the reverse fixture to C-ABI-only entry points +
  ## ``core.stdc.*`` (no ``import std.*`` / no GC) so the gcc driver
  ## resolves all references against the D archive itself without
  ## external runtime libs — same property Zig's M44 reverse fixture
  ## relies on.
  ##
  ## When a future milestone adds full ``phobos2``/``druntime``
  ## linking the link line will additionally need ``-lphobos2-ldc
  ## -ldruntime-ldc -lm -lpthread`` (POSIX) plus
  ## ``Initialize_runtime``/``Terminate_runtime`` bracket calls.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in dUpstream:
    argv.add(lib.outputPath)
  var deps = compileIds
  var inputs = objFiles
  for lib in dUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "d-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "d-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: DDirectCCppExecutable;
                             dUpstream:
                               openArray[DDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "d-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "d-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, dUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

proc readScannedDepsSource(projectRoot: string): string =
  ## Read ``<projectRoot>/repro.scanned-deps.nim`` when present and the
  ## project file ``include``s it. Empty string otherwise. Mirror of
  ## the Rust / Fortran / C/C++ / Zig conventions' same-named helper.
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
        "d-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "d-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "d-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[DDirectMember]): PackageDef =
  var name = "d_direct_convention"
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

proc dDirectEmitFragment(projectRoot: string;
                         request: ProviderGraphRequest):
                           GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members (D + C/C++ in mixed
  ## workspaces), validate Mode 3 dep edges, emit per-member
  ## ``ldmd2``/``dmd`` actions plus (in mixed workspaces) per-source
  ## ``gcc -c`` + ``ar rcs`` and C++ binary actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractDPackageUses(source)
    var members: seq[DDirectMember] = @[]
    for member in allMembers:
      if not packageUsesD(usesEntries, member.package, source):
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
        "d-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let dExe =
      if members.len > 0: dCompiler() else: ""
    if members.len > 0 and dExe.len == 0:
      raise newException(ValueError,
        "d-direct convention: no D compiler ('ldmd2', 'dmd', or " &
          "'ldc2') on PATH; cannot compile D sources")
    var targets: seq[DDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.entrySource.len == 0:
        let layoutBHint =
          case member.kind
          of ddmkExecutable: member.name & "/src/main.d"
          of ddmkLibraryStatic: member.name & "/src/lib.d"
        let layoutAHint =
          case member.kind
          of ddmkExecutable: "src/main.d"
          of ddmkLibraryStatic: "src/lib.d"
        raise newException(ValueError,
          "d-direct convention: no D sources resolved for " &
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

    # M45 reverse cross-language: derive ``cConsumable`` for each D
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package.
    # The flag is informational at this milestone — D's archive
    # shape is identical whether consumed by D or C/C++ — but
    # drives the consumer-side wiring (the C/C++ helper threads the
    # archive onto the link argv).
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[DDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == ddmkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # M45 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the D binary's link can reference each archive's output
      # path + link action id by the time we emit the link.
      var packageCCppLibraries =
        initTable[string, seq[DDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = DDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # D LIBRARIES next so their archive output paths + link action
      # ids are known by the time we reach each executable's link
      # action.
      var packageLibraries =
        initTable[string, seq[DDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != ddmkLibraryStatic:
          continue
        let action = emitLinkAction(
          projectRoot = projectRoot,
          dExe = dExe,
          target = target,
          depLibraries = @[])
        allActions.add(action)
        if target.member.package.len > 0:
          let entry = DDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: action.id,
            outputPath: archivePathFor(projectRoot, target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # D executables — consume upstream D libraries AND any
      # cross-language C/C++ archives the depends_on edges resolve to.
      for target in targets:
        if target.member.kind != ddmkExecutable:
          continue
        var entryDeps: seq[DDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[DDirectCCppUpstreamLibrary] = @[]
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
        let action = emitLinkAction(
          projectRoot = projectRoot,
          dExe = dExe,
          target = target,
          depLibraries = entryDeps,
          cCppUpstream = entryCCppDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      # M45 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream D archive.
      for exec in cCppCrossExecutables:
        var execDUpstream: seq[DDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for dLib in packageLibraries[edge.toPackage]:
                # All D archives are linkable from a C/C++ binary
                # when the D source marks routines as ``extern (C)``.
                # We pass them through regardless of cConsumable —
                # the flag is informational only at this milestone.
                execDUpstream.add(dLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execDUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc dDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``zig-direct`` per the M45 spec —
  ## registration order between D and other Mode 3 conventions only
  ## matters when a workspace claims both D AND another language. In
  ## a D+C/C++ workspace this convention claims dispatch because
  ## ``c-cpp-direct``'s ``recognize`` defers when ``uses:`` names a
  ## D toolchain token (``d``/``dmd``/``ldc2``/``gdc``).
  LanguageConvention(
    name: "d-direct",
    recognize: dDirectRecognize,
    emitFragment: dDirectEmitFragment)
