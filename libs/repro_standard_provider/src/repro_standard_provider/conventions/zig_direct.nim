## Zig (Mode 3) language convention (Tier 2b).
##
## Mode 3 minimal Zig convention for projects whose ``repro.nim``
## declares a Zig ``executable`` / ``library`` member AND DOES NOT
## ship a ``build.zig`` at the workspace root. The convention builds
## the per-member compile + link graph from pure layout — no
## ``build.zig`` needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M44 section of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``python-direct`` / alongside the
## other Mode 3 conventions):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``zig``.
##   * NO ``<projectRoot>/build.zig`` at the workspace root. The Mode 2
##     Zig convention's territory (deferred per the M44 honest-scope
##     cut — Mode 3 only for M44).
##   * At least one ``executable`` / ``library`` member is declared
##     AND resolves to a non-empty Zig source layout (Layout A or B).
##   * ``zig`` is on PATH at convention-emit time.
##
## **Layout**:
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.zig        (executable)
##       <projectRoot>/src/root.zig        (library; ``lib.zig`` also
##                                         accepted as a fallback)
##
##   Layout B — multiple packages per project file::
##
##       <projectRoot>/<member>/src/main.zig (executable)
##       <projectRoot>/<member>/src/root.zig (library)
##
## **Per-member zig argv**:
##
## | Member kind            | Argv                                                  |
## |------------------------|-------------------------------------------------------|
## | executable             | ``zig build-exe -O ReleaseSafe -femit-bin=<out> <src>``|
## | library (static)       | ``zig build-lib -O ReleaseSafe -femit-bin=<out> <src>``|
##
## The library output lands at
## ``<root>/.repro/build/<name>/lib<name>.a`` — the cross-language
## archive schema shared with ``c-cpp-direct``, the Rust convention's
## staticlib path, the Fortran convention's archive path, and Nim's
## archive output. Zig's ``build-lib`` produces a static archive by
## default; the resulting ``.a`` is directly consumable by a C/C++
## linker which is the load-bearing property for the M44 cross-language
## reverse direction.
##
## **M44 cross-language Zig ↔ C/C++**:
##
##   * **Forward (Zig binary → C library)**: a Zig ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers
##     emit per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The Zig
##     binary's ``zig build-exe`` link gains the C archive as a
##     trailing positional. The Zig user declares the C function via
##     ``extern fn`` OR ``@cImport(@cInclude("foo.h"))``; the link line
##     stays the same regardless.
##
##   * **Reverse (C/C++ binary → Zig library)**: a C/C++ ``executable``
##     ``depends_on`` a Zig ``library`` member. The Zig library's
##     ``cConsumable`` flag is derived from the dep edge; the archive
##     shape is the same ``zig build-lib`` static archive either way
##     (Zig static libs are C-ABI-compatible by construction when the
##     user marks routines with ``export``). Embedded helpers then emit
##     the C/C++ binary's per-source ``g++ -c`` + terminal ``g++ -o``
##     link action; the Zig staticlib lands on the link argv as a
##     trailing positional. The current milestone does NOT thread a
##     dedicated Zig runtime lib set onto the C++ link — Zig static
##     archives bundle the (minimal) compiler-rt routines they need
##     into the archive itself, so the gcc/ld driver resolves the
##     references against the archive without external runtime libs.
##
## Action-id prefixes for cross-language emit are
## ``zig-xlang-ccpp-compile-*``, ``zig-xlang-ccpp-archive-*``,
## ``zig-xlang-ccpp-exec-compile-*``, ``zig-xlang-ccpp-exec-link-*``
## (mirror of the rust-direct ``rust-xlang-ccpp-...`` /
## fortran-direct ``fortran-xlang-ccpp-...`` discriminators).
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Mode 2 ``build.zig`` recognition + ``zig build`` delegation —
##     deferred. ``build.zig`` is itself Zig code; recognising it
##     would require invoking ``zig build`` blindly without per-member
##     visibility. Mode 3 only for M44 per the milestone's honest cut.
##   * ``build.zig.zon`` (the Zig package manifest) recognition — Zig's
##     pre-1.0 package manager is still maturing; external deps are
##     out of scope.
##   * Multi-target / multi-arch (``-target x86_64-linux-gnu`` etc.) —
##     deferred.
##   * Test discovery (``zig test``) — deferred.
##   * WebAssembly target — deferred.
##   * Async runtime — deferred.
##   * Shared libraries (``zig build-lib -dynamic``) — Mode 3 emits
##     static archives only.
##   * Zig version churn: the convention pins no specific version. The
##     ``zig`` binary on PATH (or under ``D:/metacraft-dev-deps/zig/``)
##     drives whatever version the host carries. Per-fixture
##     compatibility with the host's Zig version is the user's
##     responsibility; the M9 harness SKIPs cleanly when Zig is
##     missing so a host without Zig still passes the gate.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Mirror of every other Mode 3 convention's scratch dir so
    ## ``repro clean`` (a single ``rm -rf .repro/``) sweeps all outputs.

  ZigSourceExtension = ".zig"

type
  ZigDirectMemberKind = enum
    zdmkExecutable
    zdmkLibraryStatic

  ZigDirectMember = object
    name: string
    kind: ZigDirectMemberKind
    package: string  ## Owning ``package <name>:`` block.
    cConsumable: bool
      ## M44 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library's archive is the canonical
      ## ``<root>/.repro/build/<name>/lib<name>.a`` (Zig static libs
      ## are already C-ABI compatible when routines are marked
      ## ``export``). The flag here is informational today — Zig's
      ## archive shape doesn't change based on consumer; the flag
      ## leaves room for a future split (e.g. ``-fPIC`` toggling) and
      ## drives the dep-graph wiring on the consumer side.

  ZigDirectEmitTarget = object
    member: ZigDirectMember
    srcDir: string
    entrySource: string

  ZigDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the C/C++ ``CCppWorkspaceLibrary``.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    cConsumable: bool

  ZigDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Discovered by ``collectCCppCrossMembers`` and emitted
    ## in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  ZigDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that this convention
    ## claims. Used for the reverse direction (C++ binary → Zig
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  ZigDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a Zig binary's
    ## link picks up as a trailing positional on the zig build-exe
    ## argv.
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

proc usesIncludesZigToolchain*(source: string): bool =
  ## True when the ``uses:`` block names ``zig``. Mirror of
  ## ``usesIncludesRustToolchain`` from rust_direct.nim.
  if source.len == 0:
    return false
  var sawZig = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "zig":
      sawZig = true
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
  sawZig

type
  ZigDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeZigUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractZigPackageUses(source: string): seq[ZigDirectPackageUses] =
  ## Mirror of the C/C++ convention's ``extractCCppPackageUses``.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(ZigDirectPackageUses(
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
        consumeZigUsesToken(currentTokens, raw)
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
          consumeZigUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesZig(usesEntries: openArray[ZigDirectPackageUses];
                    package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names ``zig``.
  if package.len == 0:
    return usesIncludesZigToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "zig":
        return true
    return false
  false

proc packageUsesAnyCCpp(usesEntries: openArray[ZigDirectPackageUses];
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

proc extractMembersWithOwnership(source: string): seq[ZigDirectMember] =
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
        result.add(ZigDirectMember(
          name: name, kind: zdmkExecutable,
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
        result.add(ZigDirectMember(
          name: name, kind: zdmkLibraryStatic,
          package: currentPackage))
      continue

proc isZigSourceFile*(path: string): bool =
  path.toLowerAscii.endsWith(ZigSourceExtension)

proc dirHasZigSources(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isZigSourceFile(path):
      return true
  false

proc resolveZigMemberDirs(projectRoot, memberName: string;
                          kind: ZigDirectMemberKind):
    tuple[srcDir: string; entrySource: string] =
  ## Layout B first (``<root>/<member>/src/...``) then Layout A
  ## (``<root>/src/...``). For executables the convention looks for
  ## ``<member>.zig`` then ``main.zig``; for libraries it looks for
  ## ``<member>.zig`` then ``root.zig`` (Zig 0.12+ default) then
  ## ``lib.zig`` (older fixtures).
  let candidatesB = projectRoot / memberName / "src"
  if dirHasZigSources(candidatesB):
    result.srcDir = candidatesB
    let memberFile = candidatesB / (memberName & ZigSourceExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of zdmkExecutable:
      let mainCand = candidatesB / ("main" & ZigSourceExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of zdmkLibraryStatic:
      let rootCand = candidatesB / ("root" & ZigSourceExtension)
      if fileExists(extendedPath(rootCand)):
        result.entrySource = rootCand
        return
      let libCand = candidatesB / ("lib" & ZigSourceExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesB):
      if isZigSourceFile(path):
        result.entrySource = path
        return
    return
  let candidatesA = projectRoot / "src"
  if dirHasZigSources(candidatesA):
    result.srcDir = candidatesA
    let memberFile = candidatesA / (memberName & ZigSourceExtension)
    if fileExists(extendedPath(memberFile)):
      result.entrySource = memberFile
      return
    case kind
    of zdmkExecutable:
      let mainCand = candidatesA / ("main" & ZigSourceExtension)
      if fileExists(extendedPath(mainCand)):
        result.entrySource = mainCand
        return
    of zdmkLibraryStatic:
      let rootCand = candidatesA / ("root" & ZigSourceExtension)
      if fileExists(extendedPath(rootCand)):
        result.entrySource = rootCand
        return
      let libCand = candidatesA / ("lib" & ZigSourceExtension)
      if fileExists(extendedPath(libCand)):
        result.entrySource = libCand
        return
    for path in walkDirRec(candidatesA):
      if isZigSourceFile(path):
        result.entrySource = path
        return

proc collectZigSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.zig`` under ``srcDir``, recursively. Used to compute the
  ## declared ``inputs`` of the link action so source-only edits
  ## invalidate the cache.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isZigSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc hasBuildZig(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "build.zig"))

proc zigCompiler(): string =
  let onPath = findExe("zig")
  if onPath.len > 0:
    return onPath
  # Optional fallback: bundled zig under D:/metacraft-dev-deps/zig/<version>/zig.exe
  # Mirror of the Rust convention's rustup-stable fallback and Go's
  # D:/metacraft-dev-deps/go/<version>/ probe.
  when defined(windows):
    let zigRoot = "D:/metacraft-dev-deps/zig"
    if dirExists(zigRoot):
      var best = ""
      for kind, path in walkDir(zigRoot):
        if kind != pcDir:
          continue
        let candidate = path / "zig.exe"
        if fileExists(extendedPath(candidate)):
          if candidate > best:
            best = candidate
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

proc resolveTarget(projectRoot: string; member: ZigDirectMember):
    ZigDirectEmitTarget =
  result.member = member
  let resolved = resolveZigMemberDirs(projectRoot, member.name, member.kind)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource

proc zigDirectRecognize(projectRoot: string;
                        request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``build.zig`` at the workspace root (the future Mode 2 Zig
  ##     convention's territory; M44 only recognises Mode 3).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``zig``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Zig source layout.
  ##   * ``zig`` is on PATH (or under
  ##     ``D:/metacraft-dev-deps/zig/<version>/zig.exe`` on Windows).
  if hasBuildZig(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesZigToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if zigCompiler().len == 0:
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
  ## Zig static library output. Lands at
  ## ``<root>/.repro/build/<name>/lib<name>.a`` — the canonical
  ## archive schema shared with ``c-cpp-direct``, Rust's staticlib
  ## path, Fortran's archive path, and Nim's archive output. Same
  ## path regardless of whether the consumer is Zig or C/C++.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc emitLinkAction(projectRoot, zigExe: string;
                    target: ZigDirectEmitTarget;
                    depLibraries: openArray[ZigDirectWorkspaceLibrary];
                    cCppUpstream: openArray[ZigDirectCCppUpstreamLibrary] = []):
                      BuildActionDef =
  ## One ``zig build-exe`` / ``zig build-lib`` invocation per member.
  ##
  ## Output paths:
  ##   * executable → ``.repro/build/<name>/<name>[.exe]``
  ##   * library    → ``.repro/build/<name>/lib<name>.a``
  ##
  ## Cross-language wiring:
  ##   * Forward (Zig binary → C archive): each upstream C archive
  ##     lands as a trailing positional on the ``zig build-exe`` argv;
  ##     zig forwards them to the underlying linker. The archive's
  ##     parent dir is added to ``-L`` via ``--library-directory`` so
  ##     the linker's search path covers the archive.
  ##   * Reverse (the staticlib emit path) is symmetric — the Zig
  ##     library's archive is the same lib<name>.a; consumer wiring
  ##     happens in the C/C++ helper's link action.
  let outDir = scratchPathFor(projectRoot, target.member.name)
  createDir(extendedPath(outDir))
  let outputPath =
    case target.member.kind
    of zdmkExecutable: binaryPathFor(projectRoot, target.member.name)
    of zdmkLibraryStatic: archivePathFor(projectRoot, target.member.name)
  let subcommand =
    case target.member.kind
    of zdmkExecutable: "build-exe"
    of zdmkLibraryStatic: "build-lib"
  # Zig argv:
  #   zig <subcommand> -O ReleaseSafe --name <member> -femit-bin=<out> <src>
  # We use ``--name`` for executables so the binary name matches the
  # member even when the entry source is ``main.zig``. For libraries,
  # ``--name`` controls the archive basename (zig will emit
  # ``lib<name>.a`` from ``build-lib`` regardless of the entry
  # source's basename, but we still pin ``--name`` for stability
  # across the layout-A vs layout-B file naming variants).
  var argv = @[
    zigExe,
    subcommand,
    "-O", "ReleaseSafe",
    "--name", target.member.name,
    "-femit-bin=" & outputPath,
  ]
  # Thread upstream Zig library archives as trailing positionals.
  # Zig forwards ``.a`` positionals to the linker for ``build-exe``
  # invocations; the symbols resolve at link time. We DON'T add them
  # for ``build-lib`` (a static archive can't depend on another
  # static archive at archive-build time; the downstream's link does
  # the resolution).
  if target.member.kind == zdmkExecutable:
    for lib in depLibraries:
      argv.add(lib.outputPath)
    # Forward direction (M44 cross-language): upstream C/C++ archives.
    # Same trailing-positional shape — Zig's build-exe forwards them
    # to the linker. The archive's parent dir is added via ``-L`` so
    # the linker's search path matches.
    var seenSearchDirs: seq[string] = @[]
    for c in cCppUpstream:
      let dir = parentDir(c.outputPath)
      if seenSearchDirs.find(dir) < 0:
        argv.add("-L")
        argv.add(dir)
        seenSearchDirs.add(dir)
    for c in cCppUpstream:
      argv.add(c.outputPath)
  argv.add(target.entrySource)
  let crateSources = collectZigSourcesUnderSrcDir(target.srcDir)
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
  let actionId = "zig-direct-link-" & sanitizeNamePart(target.member.name)
  let kindTag =
    case target.member.kind
    of zdmkExecutable: "executable"
    of zdmkLibraryStatic: "library-staticlib"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "zig-direct." & kindTag & ".link")

# ---------------------------------------------------------------------------
# M44 cross-language C/C++ helpers (mixed-workspace support). Mirror of
# rust_direct / fortran_direct — discriminator on the action-id prefix
# (``zig-xlang-ccpp-...``).
# ---------------------------------------------------------------------------

type
  ZigDirectCCppPlainMemberKind = enum
    zccmkExecutable
    zccmkLibraryStatic

  ZigDirectCCppPlainMember = object
    package: string
    name: string
    kind: ZigDirectCCppPlainMemberKind

proc extractCCppMembersFromText(source: string):
    seq[ZigDirectCCppPlainMember] =
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
        result.add(ZigDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: zccmkExecutable))
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
        result.add(ZigDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: zccmkLibraryStatic))
      continue

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[ZigDirectPackageUses]):
                               seq[ZigDirectCCppMember] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != zccmkLibraryStatic:
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
    result.add(ZigDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[ZigDirectPackageUses]):
                                   seq[ZigDirectCCppExecutable] =
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != zccmkExecutable:
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
    result.add(ZigDirectCCppExecutable(
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
                                member: ZigDirectCCppMember;
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
  let actionId = "zig-xlang-ccpp-compile-" &
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
    commandStatsId = "zig-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: ZigDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "zig-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "zig-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: ZigDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "zig-direct convention (mixed workspace): neither 'gcc' nor " &
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
# Reverse-direction (C++ binary → Zig staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: ZigDirectCCppExecutable;
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
  let actionId = "zig-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "zig-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: ZigDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 zigUpstream:
                                   openArray[ZigDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Zig
  ## staticlib lands as a trailing positional.
  ##
  ## Runtime-lib threading:
  ##
  ##   * On POSIX hosts, Zig static archives bundle their (minimal)
  ##     compiler-rt routines INTO the archive itself, so the gcc
  ##     driver resolves the references against the archive without
  ##     external runtime libs.
  ##   * On Windows, even a trivial ``zig build-lib -O ReleaseSafe``
  ##     pulls in Zig's std runtime, which references the NT API
  ##     (``NtClose``, ``RtlEqualUnicodeString``, ``NtQueryObject``,
  ##     ``NtDeviceIoControlFile``, …). These live in ``ntdll.dll``
  ##     and are NOT in the default mingw g++ link argv; without
  ##     ``-lntdll`` the link fails with ~hundreds of undefined
  ##     references. Append it at the END of the argv (after the
  ##     archive itself) so the archive's unresolved NT-API symbols
  ##     get resolved against ntdll's import lib. M53 added this
  ##     after the M44 ``mixed/cpp-uses-zig-lib`` fixture surfaced
  ##     the bug on the first dev shell that actually had Zig
  ##     provisioned.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in zigUpstream:
    argv.add(lib.outputPath)
  when defined(windows):
    # ntdll covers the Zig std-runtime's NT-API references. Place
    # AFTER the archive positional so the linker scans the archive
    # first (left-to-right), records its unresolved NT-API symbols,
    # and resolves them when it then scans ntdll's import lib.
    if zigUpstream.len > 0:
      argv.add("-lntdll")
  var deps = compileIds
  var inputs = objFiles
  for lib in zigUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "zig-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "zig-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: ZigDirectCCppExecutable;
                             zigUpstream:
                               openArray[ZigDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "zig-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "zig-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, zigUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

proc readScannedDepsSource(projectRoot: string): string =
  ## Read ``<projectRoot>/repro.scanned-deps.nim`` when present and the
  ## project file ``include``s it. Empty string otherwise. Mirror of
  ## the Rust / Fortran / C/C++ conventions' same-named helper.
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
        "zig-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "zig-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "zig-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[ZigDirectMember]): PackageDef =
  var name = "zig_direct_convention"
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

proc zigDirectEmitFragment(projectRoot: string;
                           request: ProviderGraphRequest):
                             GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members (Zig + C/C++ in mixed
  ## workspaces), validate Mode 3 dep edges, emit per-member
  ## ``zig build-exe`` / ``zig build-lib`` actions plus (in mixed
  ## workspaces) per-source ``gcc -c`` + ``ar rcs`` and C++ binary
  ## actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractZigPackageUses(source)
    var members: seq[ZigDirectMember] = @[]
    for member in allMembers:
      if not packageUsesZig(usesEntries, member.package, source):
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
        "zig-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let zigExe =
      if members.len > 0: zigCompiler() else: ""
    if members.len > 0 and zigExe.len == 0:
      raise newException(ValueError,
        "zig-direct convention: 'zig' not on PATH; " &
          "cannot compile Zig sources")
    var targets: seq[ZigDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.entrySource.len == 0:
        let layoutBHint =
          case member.kind
          of zdmkExecutable: member.name & "/src/main.zig"
          of zdmkLibraryStatic: member.name & "/src/root.zig"
        let layoutAHint =
          case member.kind
          of zdmkExecutable: "src/main.zig"
          of zdmkLibraryStatic: "src/root.zig"
        raise newException(ValueError,
          "zig-direct convention: no Zig sources resolved for " &
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

    # M44 reverse cross-language: derive ``cConsumable`` for each Zig
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package.
    # The flag is informational at this milestone — Zig's archive
    # shape is identical whether consumed by Zig or C/C++ — but
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
      var rewritten: seq[ZigDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == zdmkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # M44 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the Zig binary's link can reference each archive's output
      # path + link action id by the time we emit the link.
      var packageCCppLibraries =
        initTable[string, seq[ZigDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = ZigDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # Zig LIBRARIES next so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action.
      var packageLibraries =
        initTable[string, seq[ZigDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != zdmkLibraryStatic:
          continue
        let action = emitLinkAction(
          projectRoot = projectRoot,
          zigExe = zigExe,
          target = target,
          depLibraries = @[])
        allActions.add(action)
        if target.member.package.len > 0:
          let entry = ZigDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: action.id,
            outputPath: archivePathFor(projectRoot, target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Zig executables — consume upstream Zig libraries AND any
      # cross-language C/C++ archives the depends_on edges resolve to.
      for target in targets:
        if target.member.kind != zdmkExecutable:
          continue
        var entryDeps: seq[ZigDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[ZigDirectCCppUpstreamLibrary] = @[]
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
          zigExe = zigExe,
          target = target,
          depLibraries = entryDeps,
          cCppUpstream = entryCCppDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      # M44 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Zig archive.
      for exec in cCppCrossExecutables:
        var execZigUpstream: seq[ZigDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for zigLib in packageLibraries[edge.toPackage]:
                # All Zig archives are linkable from a C/C++ binary
                # when the Zig source marks routines as ``export``.
                # We pass them through regardless of cConsumable —
                # the flag is informational only at this milestone.
                execZigUpstream.add(zigLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execZigUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc zigDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``fortran-direct`` per the M44 spec —
  ## registration order between Zig and other Mode 3 conventions only
  ## matters when a workspace claims both Zig AND another language.
  ## In a Zig+C/C++ workspace this convention claims dispatch because
  ## ``c-cpp-direct``'s ``recognize`` defers when ``uses:`` names
  ## ``zig``.
  LanguageConvention(
    name: "zig-direct",
    recognize: zigDirectRecognize,
    emitFragment: zigDirectEmitFragment)
