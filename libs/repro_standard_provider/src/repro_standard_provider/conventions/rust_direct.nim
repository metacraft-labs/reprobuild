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
## **M34 — cross-language Rust ↔ C/C++**:
## landed 2026-05-29. The convention claims mixed Rust + C/C++
## workspaces (``c-cpp-direct``'s ``recognize`` defers when ``uses:``
## anywhere names ``rust`` / ``rustc`` and no ``Cargo.toml`` is
## present, so a single convention emits both directions of the
## cross-language matrix from one fragment — mirror of how the Nim
## convention claims mixed Nim + C/C++ workspaces). Two directions:
##
##   * **Forward (Rust binary → C library)**: a Rust ``executable``
##     ``depends_on`` a C ``library`` member. Embedded C/C++ helpers
##     emit per-source ``gcc -c`` + ``ar rcs lib<name>.a``. The Rust
##     binary's ``rustc`` link action gains
##     ``-L native=<.repro/build/<lib>>`` ``-l static=<lib>`` flags
##     plus the archive on its ``inputs`` + the archive action's id on
##     its ``deps``.
##
##   * **Reverse (C++ binary → Rust library)**: a C++ ``executable``
##     ``depends_on`` a Rust ``library`` member. The Rust library's
##     ``cConsumable`` flag is derived from the dep edge; when set,
##     the library is emitted as ``--crate-type=staticlib`` (NOT
##     ``rlib``) landing at ``<root>/.repro/build/<name>/lib<name>.a``
##     (the canonical archive schema shared with ``c-cpp-direct`` and
##     Nim's archive output). Embedded helpers then emit the C++
##     binary's per-source ``g++ -c`` + terminal ``g++ -o`` link
##     action; the Rust staticlib lands on the link argv as a trailing
##     positional plus the platform-specific Rust-runtime libs
##     (``-lpthread -ldl -lm`` on POSIX; ``-lws2_32 -luserenv
##     -ladvapi32 -lbcrypt -lntdll`` on Windows MinGW).
##
## Action-id prefixes for cross-language emit are
## ``rust-xlang-ccpp-compile-*``, ``rust-xlang-ccpp-archive-*``,
## ``rust-xlang-ccpp-exec-compile-*``, ``rust-xlang-ccpp-exec-link-*``
## (mirrors the Nim convention's ``nim-xlang-ccpp-...`` discriminator).
##
## **cConsumable trade-off**: a library marked ``cConsumable=true``
## emits ``--crate-type=staticlib`` ONLY. A library consumed by BOTH
## Rust AND C/C++ would need both rlib + staticlib emit — DEFERRED.
## The current ``cConsumable`` derivation rejects this case implicitly:
## a Rust-on-Rust dep on the same library would still pick up the
## staticlib path on the ``--extern`` line, but rustc would reject
## staticlib metadata at the consumer's compile. Document; defer the
## dual-emit path to a follow-on milestone.
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
    cConsumable: bool
      ## M34 reverse cross-language: when a C/C++ executable in the
      ## same workspace ``depends_on`` this library's package, the
      ## library is emitted as ``--crate-type=staticlib`` landing at
      ## ``<root>/.repro/build/<name>/lib<name>.a`` (the canonical
      ## archive schema shared with c-cpp-direct + Nim). When false
      ## (no C/C++ downstream), the library emits ``--crate-type=rlib``
      ## as before (M30 behaviour preserved for pure Rust workspaces).

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
    cConsumable: bool
      ## True when ``outputPath`` is a staticlib (``lib<name>.a``);
      ## false when it's an rlib. Drives the rust-to-rust ``--extern``
      ## emit (rlib only) vs the reverse-direction C/C++ link
      ## (staticlib only).

  RustDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that the rust-direct
    ## convention claims. Discovered by ``collectCCppCrossMembers`` and
    ## emitted in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  RustDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that the rust-direct
    ## convention claims. Discovered by ``collectCCppCrossExecutables``
    ## and emitted in-line as per-source compile + terminal link
    ## actions. Used for the reverse direction (C++ binary → Rust
    ## staticlib).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  RustDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a Rust binary's
    ## link picks up via ``-L native=<dir>`` + ``-l static=<name>``
    ## flags. Indexed by owning package so a
    ## ``depends_on rustApp: cLibPkg`` edge can resolve to "every C
    ## library member of cLibPkg".
    package: string
    libraryName: string
    linkActionId: string
    outputPath: string
    nativeSearchDir: string  ## the parent directory of the archive
    includeDir: string       ## the C library's public include dir

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
  ## carries no metadata). M34 adds a sibling staticlib path for
  ## cross-language C/C++ consumption (see ``staticlibPathFor``).
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

proc staticlibPathFor(projectRoot, member: string): string =
  ## M34: cross-language Rust → C/C++ staticlib output. Lands at
  ## ``<root>/.repro/build/<name>/lib<name>.a`` — the canonical archive
  ## schema shared with ``c-cpp-direct`` and the Nim convention so a
  ## C/C++ consumer (or a user manually inspecting the build tree)
  ## finds the archive at the same path regardless of which language
  ## emitted it.
  ##
  ## Unlike rlib, the staticlib filename uses the literal member name
  ## (not the normalised crate name): the consumer's link line
  ## references the archive by path, not by ``--extern <name>``, so the
  ## crate-name normalisation doesn't matter. We follow ``c-cpp-direct``'s
  ## member-name shape so a graduation from rust-direct staticlib to
  ## a hand-rolled C library doesn't change the archive path.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

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
  ## invalidate the cache without needing the io-monitor monitor.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isRustSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc emitLinkAction(projectRoot, rustcExe: string;
                    target: RustDirectEmitTarget;
                    depLibraries: openArray[RustDirectWorkspaceLibrary];
                    cCppUpstream: openArray[RustDirectCCppUpstreamLibrary] = []):
                      BuildActionDef =
  ## One rustc invocation per crate. M30 collapses metadata + link
  ## into a single action (no separate ``--emit=metadata`` pass) —
  ## Mode 3 has no rmeta consumer at this milestone (cdylib / dylib /
  ## test discovery are deferred), and the pipelining benefit lands in
  ## the Mode 2 path which has the granular per-pass actions. The
  ## fixture builds in well under a second cold; a future
  ## pipelined-Mode-3 milestone can split the action if profiling
  ## warrants.
  ##
  ## **M34 cross-language wiring**:
  ##   * When the target member is a library AND ``cConsumable=true``,
  ##     emit ``--crate-type=staticlib`` landing at ``lib<name>.a``.
  ##     This is the reverse-direction (C++→Rust) plumbing.
  ##   * When ``cCppUpstream`` is non-empty (forward direction), thread
  ##     ``-L native=<dir>`` + ``-l static=<lib>`` onto the rustc argv
  ##     so the rust binary's link picks up the upstream C archives.
  let crateName = normaliseRustCrateName(target.member.name)
  let metaHash = crateMetadataHash(projectRoot, target.member)
  let outDir = scratchPathFor(projectRoot, target.member.name)
  createDir(extendedPath(outDir))
  let outputPath =
    case target.member.kind
    of rdmkExecutable: binaryPathFor(projectRoot, target.member.name)
    of rdmkLibraryStatic:
      if target.member.cConsumable:
        staticlibPathFor(projectRoot, target.member.name)
      else:
        rlibPathFor(projectRoot, target.member.name)
  let crateType =
    case target.member.kind
    of rdmkExecutable: "bin"
    of rdmkLibraryStatic:
      if target.member.cConsumable: "staticlib" else: "rlib"
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
  # M34 reverse cross-language: a ``no_std`` staticlib (the recommended
  # FFI pattern — see ``mixed/cpp-uses-rust-lib`` fixture's
  # addlib/src/lib.rs comment block) requires ``-C panic=abort`` because
  # the precompiled core crate would otherwise pull in unwinding panics
  # which need ``std``. We thread the flag unconditionally for
  # cConsumable targets. A ``no_std``-only staticlib without the flag
  # fails to link with rustc's "unwinding panics are not supported
  # without std" error; the flag is harmless for staticlibs that use
  # ``std`` (rustc just selects the abort runtime instead of unwind).
  if target.member.kind == rdmkLibraryStatic and target.member.cConsumable:
    argv.add("-C")
    argv.add("panic=abort")
  # Thread upstream Rust library archives via ``--extern <name>=<path>``.
  # Sequencing + cache invalidation handled below via ``deps`` /
  # ``inputs``.
  for lib in depLibraries:
    argv.add("--extern")
    argv.add(lib.crateName & "=" & lib.outputPath)
  # M34 forward direction: thread upstream C/C++ archives onto the
  # rustc link line. ``-L native=<dir>`` adds the archive's parent dir
  # to rustc's native-library search path; ``-l static=<libname>``
  # tells rustc to link the static archive named ``lib<libname>.a``
  # from that search path (the prefix + extension match the
  # ``staticLibraryPathFor`` schema in c-cpp-direct).
  var seenNativeDirs: seq[string] = @[]
  for c in cCppUpstream:
    if seenNativeDirs.find(c.nativeSearchDir) < 0:
      argv.add("-L")
      argv.add("native=" & c.nativeSearchDir)
      seenNativeDirs.add(c.nativeSearchDir)
  for c in cCppUpstream:
    argv.add("-l")
    argv.add("static=" & c.libraryName)
  argv.add(target.entrySource)
  let crateSources = collectRustSourcesUnderSrcDir(target.srcDir)
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
  let actionId = "rust-direct-link-" & sanitizeNamePart(target.member.name)
  let kindTag =
    case target.member.kind
    of rdmkExecutable: "executable"
    of rdmkLibraryStatic:
      if target.member.cConsumable: "library-staticlib"
      else: "library-rlib"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust-direct." & kindTag & ".link")

# ---------------------------------------------------------------------------
# M34 cross-language C/C++ helpers (mixed-workspace support).
#
# When a Mode 3 workspace declares both Rust packages and C/C++ packages
# in a single ``repro.nim`` (the user opted into the canonical pattern of
# one project file per workspace), the rust-direct convention claims the
# WHOLE workspace because ``c-cpp-direct``'s recognize defers to us when
# any ``uses:`` block names ``rust`` / ``rustc``. We then take
# responsibility for emitting the C/C++ packages' archive + binary
# actions in-line so the cross-package
# ``depends_on rustApp: cppLib`` / ``depends_on cppApp: rustLib``
# edges produce a coherent action graph within a single
# ``buildPackageFragment`` call. Mirrors the Nim convention's pattern
# (commits 29d1e42 + 9ce2d13).
#
# Shared archive schema:
#   C archive path  : <root>/.repro/build/<libName>/lib<libName>.a
#   Rust staticlib  : <root>/.repro/build/<libName>/lib<libName>.a
#   obj dir         : <root>/.repro/build/<libName>/obj/
#   per-source obj  : <root>/.repro/build/<libName>/obj/<sanitized-stem>.o
#   exec path       : <root>/.repro/build/<exeName>/<exeName>[.exe]
#
# These helpers intentionally MIRROR (not import from) the equivalent
# logic in ``c_cpp_direct.nim`` and ``nim.nim`` so the conventions stay
# independently evolvable.
# ---------------------------------------------------------------------------

type
  RustDirectCCppMemberKind = enum
    rdccmkExecutable
    rdccmkLibraryStatic

  RustDirectCCppPlainMember = object
    package: string
    name: string
    kind: RustDirectCCppMemberKind

proc extractCCppMembersFromText(source: string):
    seq[RustDirectCCppPlainMember] =
  ## Walk ``source`` text for ``library`` / ``executable`` declarations
  ## with their owning ``package``. Mirror of c_cpp_direct's
  ## ``extractMembersWithOwnership`` — same indentation tracking. Used
  ## by ``collectCCppCrossMembers`` / ``collectCCppCrossExecutables``
  ## with a follow-up ``uses:`` filter to keep only members in
  ## ``uses: gcc/clang`` packages.
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
        result.add(RustDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: rdccmkExecutable))
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
        result.add(RustDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: rdccmkLibraryStatic))
      continue

proc packageUsesAnyCCpp(usesEntries: openArray[RustDirectPackageUses];
                       package: string): bool =
  ## True when ``package``'s ``uses:`` block names ``gcc`` or ``clang``.
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

proc collectCCppSourceFiles(srcDir: string): seq[string] =
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    if isCCppSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectCCppCrossMembers(projectRoot, source: string;
                             usesEntries: openArray[RustDirectPackageUses]):
                               seq[RustDirectCCppMember] =
  ## Walk the project file for ``library`` declarations in packages
  ## whose ``uses:`` block names ``gcc``/``clang``. Each resolvable
  ## member is returned as a ``RustDirectCCppMember`` carrying its
  ## source set (used downstream to emit ``gcc -c`` + ``ar rcs``
  ## actions).
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != rdccmkLibraryStatic:
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
    result.add(RustDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[RustDirectPackageUses]):
                                   seq[RustDirectCCppExecutable] =
  ## Reverse-direction sibling of ``collectCCppCrossMembers``: harvest
  ## ``executable`` members from ``uses: gcc/clang`` packages so the
  ## rust-direct convention can emit the C++ binary's compile + link
  ## inside the same fragment that emits the upstream Rust staticlib.
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != rdccmkExecutable:
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
    result.add(RustDirectCCppExecutable(
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
                                member: RustDirectCCppMember;
                                source, objFile, depFile: string):
                                  BuildActionDef =
  ## ``gcc -c`` action for one C/C++ source belonging to a cross-
  ## language upstream library that a Rust binary consumes. Action-id
  ## prefix ``rust-xlang-ccpp-compile-`` mirrors the Nim convention's
  ## ``nim-xlang-ccpp-compile-`` discriminator.
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
  let actionId = "rust-xlang-ccpp-compile-" &
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
    commandStatsId = "rust-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: RustDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action. Action-id prefix
  ## ``rust-xlang-ccpp-archive-`` mirrors the Nim convention's
  ## discriminator.
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "rust-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: RustDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  ## Emit the full per-source ``gcc -c`` set plus the terminal
  ## ``ar rcs`` archive action for one cross-language upstream C
  ## library. Returns the archive path + include dir so the caller can
  ## wire the downstream Rust binary's rustc argv.
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "rust-direct convention (mixed workspace): neither 'gcc' nor " &
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
# Reverse-direction (C++ binary → Rust staticlib) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc rustRuntimeLinkLibs(): seq[string] =
  ## A Rust staticlib carries references to a small set of platform
  ## libraries that the consumer's link line must satisfy. The Rust
  ## documentation's authoritative source for this list is
  ## ``rustc --print=native-static-libs --crate-type=staticlib``
  ## but invoking rustc to read it at convention-emit time would add
  ## a recipe-time dependency on rustc. We hard-code the standard
  ## Windows MinGW + POSIX defaults here; the dynamic resolution path
  ## is a follow-on milestone (documented in M34 outstanding tasks).
  ##
  ## **Windows MinGW (gcc / g++ via MSYS2 mingw64)**: the Rust stdlib
  ## touches the Win32 socket API (``-lws2_32``), security tokens
  ## (``-luserenv -ladvapi32``), the Cryptography Next Gen API
  ## (``-lbcrypt``), NT-internal helpers (``-lntdll``), and the C
  ## runtime (``-lmsvcrt`` — picked up implicitly by gcc). We list the
  ## explicit ``-l`` flags here; the implicit ones are handled by the
  ## gcc driver's default link line.
  ##
  ## **Windows MSVC**: not supported by this convention today —
  ## c-cpp-direct emits gcc-style argv exclusively. Mode 2 ``rust``
  ## handles MSVC via cargo.
  ##
  ## **POSIX**: ``-lpthread -ldl -lm`` — the same triple Nim's
  ## ``nimRuntimeLinkLibs`` ships with. The Rust stdlib touches them
  ## for the same reasons (libstd's thread + dynlib + math symbols).
  when defined(windows):
    @["-lws2_32", "-luserenv", "-ladvapi32", "-lbcrypt", "-lntdll"]
  else:
    @["-lpthread", "-ldl", "-lm"]

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: RustDirectCCppExecutable;
                                    source, objFile, depFile: string):
                                      BuildActionDef =
  ## Per-source compile action for a cross-language C/C++ executable
  ## that links a Rust staticlib. Action-id prefix
  ## ``rust-xlang-ccpp-exec-compile-`` mirrors the Nim convention's
  ## reverse-direction shape.
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
  let actionId = "rust-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "rust-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: RustDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 rustUpstream:
                                   openArray[RustDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Rust
  ## staticlib lands as a trailing positional (gcc/ld resolves
  ## symbols left-to-right; ``.a``s must follow the ``.o``s that
  ## reference them). The platform-specific Rust runtime libs land
  ## AFTER the Rust archives so they pick up the runtime symbols the
  ## Rust archive references.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in rustUpstream:
    argv.add(lib.outputPath)
  for libFlag in rustRuntimeLinkLibs():
    argv.add(libFlag)
  var deps = compileIds
  var inputs = objFiles
  for lib in rustUpstream:
    if deps.find(lib.linkActionId) < 0:
      deps.add(lib.linkActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "rust-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "rust-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: RustDirectCCppExecutable;
                             rustUpstream:
                               openArray[RustDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  ## Emit the per-source ``gcc -c`` / ``g++ -c`` set plus the terminal
  ## ``gcc -o`` / ``g++ -o`` link action for one cross-language C/C++
  ## executable that consumes upstream Rust staticlibs. The link argv
  ## is augmented with each upstream Rust staticlib's path + the
  ## platform-specific Rust runtime libs so the C++ binary's link
  ## resolves the Rust symbols.
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "rust-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "rust-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, rustUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

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
  ## Convention entry — enumerate members (Rust + C/C++ in mixed
  ## workspaces), validate Mode 3 dep edges, emit per-crate ``rustc``
  ## actions plus (in mixed workspaces) per-source ``gcc -c`` + ``ar
  ## rcs`` and C++ binary actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractRustPackageUses(source)
    var members: seq[RustDirectMember] = @[]
    for member in allMembers:
      if not packageUsesRust(usesEntries, member.package, source):
        continue
      members.add(member)
    # M34 cross-language: enumerate C/C++ library members that the
    # rust-direct convention should emit upstream archives for (forward
    # direction: Rust binary → C archive), and C/C++ executable members
    # the convention should emit per-source compile + terminal link
    # actions for (reverse direction: C++ binary → Rust staticlib).
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
        "rust-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let rustcExe =
      if members.len > 0: rustcCompiler() else: ""
    if members.len > 0 and rustcExe.len == 0:
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
    # Include cross-language C/C++ packages in the declared set so the
    # validator accepts ``depends_on rustApp: cLibPkg`` /
    # ``depends_on cppApp: rustLibPkg`` without spuriously rejecting
    # the C/C++ side as undeclared.
    for member in cCppCrossMembers:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    for exec in cCppCrossExecutables:
      if exec.package.len > 0 and
          declaredPackages.find(exec.package) < 0:
        declaredPackages.add(exec.package)
    validateWorkspaceDeps(depEdges, declaredPackages)

    # M34 reverse cross-language: derive ``cConsumable`` for each Rust
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package. The
    # flag toggles the library's rustc argv between rlib (Rust-to-Rust
    # consumption) and staticlib (C/C++ consumption).
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[RustDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == rdmkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # M34 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the rust binary's link can reference each archive's output
      # path + link action id by the time we hand it to emitLinkAction.
      # Index by owning package so a ``depends_on rustApp: cLibPkg``
      # edge resolves to "every C library member of cLibPkg".
      var packageCCppLibraries =
        initTable[string, seq[RustDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = RustDirectCCppUpstreamLibrary(
          package: member.package,
          libraryName: member.libraryName,
          linkActionId: bundle.archive.id,
          outputPath: bundle.archivePath,
          nativeSearchDir: parentDir(bundle.archivePath),
          includeDir: bundle.includeDir)
        if not packageCCppLibraries.hasKey(member.package):
          packageCCppLibraries[member.package] = @[]
        packageCCppLibraries[member.package].add(entry)
        discard target(member.libraryName, allActions)
      # Rust LIBRARIES next so their archive output paths + link
      # action ids are known by the time we reach each executable's
      # link action. Index libraries by owning package so
      # ``depends_on <app>: <lib>`` can resolve to "every library
      # member of <lib>'s package".
      var packageLibraries =
        initTable[string, seq[RustDirectWorkspaceLibrary]]()
      for target in targets:
        if target.member.kind != rdmkLibraryStatic:
          continue
        let action = emitLinkAction(rustcExe = rustcExe,
          projectRoot = projectRoot, target = target,
          depLibraries = @[])
        allActions.add(action)
        if target.member.package.len > 0:
          let outputPath =
            if target.member.cConsumable:
              staticlibPathFor(projectRoot, target.member.name)
            else:
              rlibPathFor(projectRoot, target.member.name)
          let entry = RustDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            linkActionId: action.id,
            outputPath: outputPath,
            crateName: normaliseRustCrateName(target.member.name),
            cConsumable: target.member.cConsumable)
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        discard target(target.member.name, allActions)
      # Rust executables — their compile + link actions consume the
      # already-registered Rust library rlibs AND any cross-language
      # C/C++ archives the depends_on edges resolve to.
      for target in targets:
        if target.member.kind != rdmkExecutable:
          continue
        var entryDeps: seq[RustDirectWorkspaceLibrary] = @[]
        var entryCCppDeps: seq[RustDirectCCppUpstreamLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                # cConsumable libraries are NOT pulled in via --extern
                # — they're staticlib (no metadata). Rust-to-Rust
                # consumption of a same-package library is not the
                # forward-direction wiring; document + defer.
                if not lib.cConsumable:
                  entryDeps.add(lib)
            if packageCCppLibraries.hasKey(edge.toPackage):
              for cLib in packageCCppLibraries[edge.toPackage]:
                entryCCppDeps.add(cLib)
        let action = emitLinkAction(rustcExe = rustcExe,
          projectRoot = projectRoot, target = target,
          depLibraries = entryDeps,
          cCppUpstream = entryCCppDeps)
        allActions.add(action)
        discard target(target.member.name, allActions)
      # M34 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Rust staticlib's
      # link-action id + output path. The depends_on edge map indexes
      # the cppApp's upstream Rust libs by ``toPackage``; for each
      # edge whose ``toPackage`` resolved a Rust library marked
      # cConsumable we thread the archive onto the C/C++ link.
      for exec in cCppCrossExecutables:
        var execRustUpstream: seq[RustDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for rustLib in packageLibraries[edge.toPackage]:
                # Only staticlib (cConsumable) archives are linkable
                # from a C/C++ binary. An rlib carries Rust-only
                # metadata + no resolvable symbols for the C++ linker.
                if rustLib.cConsumable:
                  execRustUpstream.add(rustLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execRustUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)
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
