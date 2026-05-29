## Rust (Mode 3 / no-Cargo.toml) language convention (Tier 2b).
##
## Mode 3 sibling of ``rust.nim`` for projects whose ``repro.nim``
## declares a Rust ``executable`` / ``library`` member AND DOES NOT
## ship a ``Cargo.toml`` at the workspace root. The convention builds
## the per-crate compile + link graph from pure layout — no Cargo
## manifest needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and ``reprobuild-specs/Language-Conventions/Rust.md`` for the
## per-language contract.
##
## **Recognition** (registered AFTER ``rust``):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``rust`` or ``rustc``.
##   * NO ``<projectRoot>/Cargo.toml`` (the Mode 2 Rust convention
##     would have matched FIRST — registration order is defensive in
##     either direction).
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty Rust source layout via the M30 ``rust_dep_scanner``
##     ``resolveRustMemberDirs`` helper.
##   * ``rustc`` is on PATH at convention-emit time. Unlike the Mode 2
##     convention, Mode 3 does NOT require ``cargo`` — the build is
##     pure ``rustc`` invocations.
##
## **Layout** (per ``resolveRustMemberDirs`` in ``rust_dep_scanner``):
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/main.rs           (executable)
##       <projectRoot>/src/lib.rs            (library)
##
##   Layout B — multiple packages per project file (the canonical
##              Mode 3 multi-package shape)::
##
##       <projectRoot>/<member>/src/main.rs  (executable)
##       <projectRoot>/<member>/src/lib.rs   (library)
##
## **Per-crate rustc argv**:
##
## | Member kind            | Argv                                                  |
## |------------------------|-------------------------------------------------------|
## | library (rlib)         | ``rustc --crate-type=rlib --emit=link ...``           |
## | executable             | ``rustc --crate-type=bin --emit=link ...``            |
##
## The library output lands at ``<root>/.repro/build/<name>/lib<name>.rlib``
## — rlib is the only format that lets a downstream Rust crate
## consume the upstream via ``--extern <name>=<path>`` (staticlib
## carries no metadata, so a Rust ``use upstream::...`` line wouldn't
## compile). Each upstream library's rlib path is threaded onto the
## downstream's link argv via ``--extern <name>=<rlib>``; the
## upstream's link action id is added to the downstream's ``deps``
## for sequencing and the rlib path is added to ``inputs`` for
## cache-hit invalidation.
##
## **M34 follow-up — cross-language ``lib<name>.a`` staticlib**:
## the M30 spec's "Use the SAME workspace archive schema" line is
## load-bearing for the M34 cross-language matrix (a C binary linking
## a Rust library) but conflicts with Rust-to-Rust ``use`` (which
## requires rlib's metadata). M30 emits rlib only; M34 will add a
## second per-library action that emits ``--crate-type=staticlib``
## landing at ``lib<name>.a`` so a C/C++ ``cc -o`` link action can
## pick it up via the same archive-path convention as
## ``c-cpp-direct`` libraries.
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * Shared libraries (``cdylib`` / ``dylib``) — Mode 2 handles these
##     via the existing ``rust.nim`` convention. Mode 3 emits staticlib
##     only.
##   * Test discovery / ``rustc --test`` integration — defer.
##   * crates.io / git deps — Mode 3 is in-workspace only; users with
##     external deps write a ``Cargo.toml`` and let the Mode 2
##     convention drive the build. See the M30 honest-scope cut.
##   * ``-C metadata`` hash matching cargo's package-id — Mode 3 uses
##     an FNV-1a of the workspace-relative crate path (mirror of the
##     Mode 2 fallback for fixtures without a published source URL).
##   * Cross-compilation (``--target=<triple>``).

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Identical to the Mode 2 Rust convention's scratch dir so the two
    ## conventions produce co-located outputs and ``repro clean`` finds
    ## both. The Mode 3 convention is registered AFTER ``rust``, so the
    ## scratch path stays stable when a project flips between Cargo and
    ## Mode 3.

  RustEdition* = "2021"
    ## Edition fed to ``rustc --edition``. M30 hard-codes 2021; a
    ## per-package DSL field is an outstanding follow-up (the spec's
    ## "Edition read from a per-package DSL field" deliverable). Real
    ## fixtures all build under 2021 today; the constant stays here as
    ## a single point of edit for the future field.

type
  RustDirectMemberKind = enum
    rdmkExecutable
    rdmkLibraryStatic

  RustDirectMember = object
    name: string
    kind: RustDirectMemberKind
    package: string  ## Owning ``package <name>:`` block (Mode 3).

  RustDirectEmitTarget = object
    member: RustDirectMember
    srcDir: string
    entrySource: string

  RustDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of the
    ## C/C++ ``CCppWorkspaceLibrary``.
    libraryName: string
    package: string
    linkActionId: string
    outputPath: string
    crateName: string
      ## ``-`` → ``_`` normalised name used as rustc's ``--crate-name``
      ## and as the ``--extern <name>=...`` key in downstream crates.

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesRustToolchain(source: string): bool =
  ## True when the ``uses:`` block names ``rust`` or ``rustc``. Mode 3
  ## intentionally DOES NOT match on ``cargo`` — that's the Mode 2
  ## convention's territory.
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

type
  RustDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeRustUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractRustPackageUses(source: string): seq[RustDirectPackageUses] =
  ## Local mirror of the C/C++ convention's ``extractCCppPackageUses``.
  ## Used for cross-language filtering so this convention only emits
  ## actions for the ``rust`` / ``rustc``-using packages in a mixed
  ## workspace.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(RustDirectPackageUses(
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
        consumeRustUsesToken(currentTokens, raw)
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
          consumeRustUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesRust(usesEntries: openArray[RustDirectPackageUses];
                     package, source: string): bool =
  ## True when ``package``'s ``uses:`` block names ``rust`` / ``rustc``.
  ## Empty ``package`` (member declared at top level, no enclosing
  ## ``package`` block) falls back to the file-wide
  ## ``usesIncludesRustToolchain`` hint so single-package fixtures
  ## continue to work unchanged.
  if package.len == 0:
    return usesIncludesRustToolchain(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "rust" or token == "rustc":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[RustDirectMember] =
  ## Walk ``source`` text and emit ``RustDirectMember`` rows with the
  ## owning ``package <name>:`` block. Mirror of the C/C++ convention's
  ## ``extractMembersWithOwnership`` — same indentation-tracking
  ## heuristic; same caveats.
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
        result.add(RustDirectMember(
          name: name, kind: rdmkExecutable,
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
        result.add(RustDirectMember(
          name: name, kind: rdmkLibraryStatic,
          package: currentPackage))
      continue

proc hasCargoToml(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "Cargo.toml"))

proc rustcCompiler(): string =
  findExe("rustc")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc memberKindString(kind: RustDirectMemberKind): string =
  case kind
  of rdmkExecutable: "executable"
  of rdmkLibraryStatic: "library"

proc resolveTarget(projectRoot: string; member: RustDirectMember):
    RustDirectEmitTarget =
  ## Resolve a member's source directory + crate root file via the
  ## shared scanner helper that handles Layout A vs Layout B.
  result.member = member
  let resolved = resolveRustMemberDirs(
    projectRoot, member.name, memberKindString(member.kind))
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource

proc rustDirectRecognize(projectRoot: string;
                         request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``Cargo.toml`` at the workspace root (the Mode 2 Rust
  ##     convention's territory).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``rust`` / ``rustc``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Rust source layout via
  ##     ``resolveRustMemberDirs``.
  ##   * ``rustc`` is on PATH at convention-emit time.
  if hasCargoToml(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesRustToolchain(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if rustcCompiler().len == 0:
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

proc rlibPathFor(projectRoot, member: string): string =
  ## Mode 3 Rust library output lands at
  ## ``<root>/.repro/build/<name>/lib<name>.rlib`` — the only format
  ## that lets a downstream Rust crate ``use upstream::...`` (staticlib
  ## carries no metadata). The M34 cross-language work will land a
  ## sibling ``lib<name>.a`` staticlib action so C/C++ consumers can
  ## pick the same library up via the canonical archive-path
  ## convention.
  ##
  ## The crate name (with ``-`` collapsed to ``_``) is used in the
  ## filename so a downstream ``--extern <crateName>=...`` matches
  ## rustc's own crate-name resolution on the file's basename. M30
  ## library member names already use ``_`` by convention (the C
  ## archive schema in c-cpp-direct uses the literal member name);
  ## we use the normalised form here for consistency with rustc's
  ## ``lib<crate>-...rlib`` shape.
  let crateName = normaliseRustCrateName(member)
  scratchPathFor(projectRoot, member) / ("lib" & crateName & ".rlib")

proc fnv1aHex(value: string): string =
  ## FNV-1a 64-bit hash, hex-encoded. Same algorithm as
  ## ``conventions/rust.nim``'s ``stableHashHex`` — kept here so the
  ## Mode 3 convention doesn't have to depend on the Mode 2 module.
  var hash = 0xcbf29ce484222325'u64
  for ch in value:
    hash = hash xor uint64(ord(ch))
    hash = hash * 0x100000001b3'u64
  hash.toHex(16).toLowerAscii()

proc crateMetadataHash(projectRoot: string; member: RustDirectMember): string =
  ## Stable ``-C metadata`` hash for a Mode 3 crate. FNV-1a of the
  ## workspace-relative crate name (per the M30 spec's honest-scope cut
  ## — Mode 3 doesn't pretend to match cargo's package-id hash; users
  ## who need that interop write a ``Cargo.toml``).
  fnv1aHex(member.name & "@" & RustEdition)

proc collectRustSourcesUnderSrcDir(srcDir: string): seq[string] =
  ## Every ``.rs`` under ``srcDir``, recursively. Used to compute the
  ## declared ``inputs`` of the link action so source-only edits
  ## invalidate the cache without needing the FS-snoop monitor.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isRustSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc emitLinkAction(projectRoot, rustcExe: string;
                    target: RustDirectEmitTarget;
                    depLibraries: openArray[RustDirectWorkspaceLibrary]):
                      BuildActionDef =
  ## One rustc invocation per crate. M30 collapses metadata + link
  ## into a single action (no separate ``--emit=metadata`` pass) —
  ## Mode 3 has no rmeta consumer at this milestone (cdylib / dylib /
  ## test discovery are deferred), and the pipelining benefit lands in
  ## the Mode 2 path which has the granular per-pass actions. The
  ## fixture builds in well under a second cold; a future
  ## pipelined-Mode-3 milestone can split the action if profiling
  ## warrants.
  let crateName = normaliseRustCrateName(target.member.name)
  let metaHash = crateMetadataHash(projectRoot, target.member)
  let outDir = scratchPathFor(projectRoot, target.member.name)
  createDir(extendedPath(outDir))
  let outputPath =
    case target.member.kind
    of rdmkExecutable: binaryPathFor(projectRoot, target.member.name)
    of rdmkLibraryStatic: rlibPathFor(projectRoot, target.member.name)
  let crateType =
    case target.member.kind
    of rdmkExecutable: "bin"
    of rdmkLibraryStatic: "rlib"
  var argv = @[
    rustcExe,
    "--crate-name", crateName,
    "--edition", RustEdition,
    "--crate-type", crateType,
    "--emit=link",
    "-C", "opt-level=2",
    "-C", "metadata=" & metaHash,
    "-o", outputPath,
  ]
  # Thread upstream library archives via ``--extern <name>=<path>``.
  # Sequencing + cache invalidation handled below via ``deps`` /
  # ``inputs``.
  for lib in depLibraries:
    argv.add("--extern")
    argv.add(lib.crateName & "=" & lib.outputPath)
  argv.add(target.entrySource)
  let crateSources = collectRustSourcesUnderSrcDir(target.srcDir)
  var inputs = crateSources
  for lib in depLibraries:
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  var deps: seq[string] = @[]
  for lib in depLibraries:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
  let actionId = "rust-direct-link-" & sanitizeNamePart(target.member.name)
  let kindTag =
    case target.member.kind
    of rdmkExecutable: "executable"
    of rdmkLibraryStatic: "library-rlib"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "rust-direct." & kindTag & ".link")

proc readScannedDepsSource(projectRoot: string): string =
  ## Read ``<projectRoot>/repro.scanned-deps.nim`` when present and the
  ## project file ``include``s it. Empty string otherwise. Mirror of
  ## the Nim / C/C++ conventions' same-named helper.
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
  ## Tarjan-style three-colour DFS. Mirror of the Nim / C/C++
  ## conventions' same-named helper.
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
        "rust-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "rust-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "rust-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[RustDirectMember]): PackageDef =
  var name = "rust_direct_convention"
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

proc rustDirectEmitFragment(projectRoot: string;
                            request: ProviderGraphRequest):
                              GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members, validate Mode 3 dep edges,
  ## emit per-crate ``rustc`` actions via the DSL, hand the whole thing
  ## to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    # Cross-language filter: in a mixed workspace this convention may
    # share a ``repro.nim`` with packages routed through other
    # conventions. The filter is defensive — it keeps the emit
    # deterministic and prevents the convention from claiming
    # non-Rust members.
    let usesEntries = extractRustPackageUses(source)
    var members: seq[RustDirectMember] = @[]
    for member in allMembers:
      if not packageUsesRust(usesEntries, member.package, source):
        continue
      members.add(member)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "rust-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let rustcExe = rustcCompiler()
    if rustcExe.len == 0:
      raise newException(ValueError,
        "rust-direct convention: 'rustc' not on PATH; " &
          "cannot compile Rust sources")
    var targets: seq[RustDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member)
      if target.entrySource.len == 0:
        raise newException(ValueError,
          "rust-direct convention: no Rust crate root resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & member.name & "/src/" &
            (if member.kind == rdmkExecutable: "main.rs" else: "lib.rs") &
            " and <root>/src/" &
            (if member.kind == rdmkExecutable: "main.rs" else: "lib.rs") &
            ")")
      targets.add(target)
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
      # Emit LIBRARIES first so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action. Index libraries by owning package so
      # ``depends_on <app>: <lib>`` can resolve to "every library
      # member of <lib>'s package".
      var packageLibraries =
        initTable[string, seq[RustDirectWorkspaceLibrary]]()
      for i, target in targets:
        if target.member.kind != rdmkLibraryStatic:
          continue
        let action = emitLinkAction(rustcExe = rustcExe,
          projectRoot = projectRoot, target = target,
          depLibraries = @[])
        allActions.add(action)
        if target.member.package.len > 0:
          let rlibOutput = rlibPathFor(
            projectRoot, target.member.name)
          let entry = RustDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: action.id,
            outputPath: rlibOutput,
            crateName: normaliseRustCrateName(target.member.name))
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Now executables — their compile + link actions consume the
      # already-registered library archives.
      for i, target in targets:
        if target.member.kind != rdmkExecutable:
          continue
        var entryDeps: seq[RustDirectWorkspaceLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if not packageLibraries.hasKey(edge.toPackage):
              # Dep on an executable-only package (no library to link)
              # — silent no-op for the link line. Same shape as the
              # C/C++ Mode 3 convention.
              continue
            for lib in packageLibraries[edge.toPackage]:
              entryDeps.add(lib)
        let action = emitLinkAction(rustcExe = rustcExe,
          projectRoot = projectRoot, target = target,
          depLibraries = entryDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc rustDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registration order: AFTER ``rust`` so a project carrying
  ## a ``Cargo.toml`` routes through the Mode 2 convention; this
  ## convention picks up the no-Cargo.toml case.
  LanguageConvention(
    name: "rust-direct",
    recognize: rustDirectRecognize,
    emitFragment: rustDirectEmitFragment)
