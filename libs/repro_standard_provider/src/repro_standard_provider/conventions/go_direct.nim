## Go (Mode 3 / no-go.mod) language convention (Tier 2b).
##
## Mode 3 sibling of ``go.nim`` for projects whose ``repro.nim``
## declares a Go ``executable`` / ``library`` member AND DOES NOT
## ship a ``go.mod`` at the workspace root. The convention builds the
## per-package compile + link graph from pure layout — no Go module
## manifest needed.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and ``reprobuild-specs/Language-Conventions/Go.md`` for the
## per-language contract. M31 of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``go``):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``go``.
##   * NO ``<projectRoot>/go.mod`` (the Mode 2 Go convention would have
##     matched FIRST — registration order is defensive in either
##     direction).
##   * NO ``<projectRoot>/go.work`` (workspaces stay deferred, matching
##     Mode 2).
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty Go source layout via the M31
##     ``go_dep_scanner.resolveGoMemberDirs`` helper, OR (M36) at least
##     one C/C++ member declared so a Go-claimable cross-language
##     workspace resolves even when only the C/C++ side is non-empty.
##   * ``go`` is on PATH at convention-emit time. We need the driver
##     for ``go tool compile`` / ``go tool link`` and for the one
##     ``go list -export`` invocation that materialises the stdlib
##     archive paths.
##   * M36: cgo (``import "C"``) is now ACCEPTED — the per-cgo-member
##     build switches from ``go tool compile`` to ``go build`` so the
##     cgo preprocessor + link integration runs. Pure-Go members in the
##     same workspace keep the M31 fast path.
##
## **Layout** (per ``resolveGoMemberDirs`` in ``go_dep_scanner``):
##
##   Layout B — multiple packages per project file (the canonical
##              Mode 3 multi-package shape; idiomatic Go)::
##
##       <projectRoot>/<member>/*.go      (each member's package)
##
##   Layout A — one package per project file::
##
##       <projectRoot>/src/*.go           OR
##       <projectRoot>/*.go
##
## **Per-package argv (using ``go tool compile`` + ``go tool link``)**:
##
## | Member kind  | Argv                                                  |
## |--------------|-------------------------------------------------------|
## | library      | ``go tool compile -p <name> -importcfg ... -pack``    |
## |              | ``                  -o <name>.a <name>/*.go``         |
## | executable   | ``go tool compile -p main -importcfg ... -pack``      |
## |              | ``                  -o <name>.a <name>/*.go``         |
## |              | ``go tool link -importcfg ... -o <name>[.exe] <name>.a``|
##
## The convention bypasses ``go.mod`` entirely. Stdlib package archives
## are located via a single ``GO111MODULE=off go list -export -json
## -deps <stdlib-roots>`` call at emit time (mirror of the M5/M14 Mode 2
## emit-time ``go list`` pattern, but module-free). The resulting
## ``packagefile <importPath>=<gocache-path>`` lines are written into
## per-package ``importcfg`` files alongside the workspace-internal
## library archives.
##
## **Output schema**:
##
##   * Library: ``<root>/.repro/build/<name>/<name>.a``
##     — Go's archive naming; the M36 cross-language work will add a
##     sibling ``lib<name>.a`` symlink/copy so C/C++ binaries can
##     consume the archive via the canonical archive-path convention
##     shared with c-cpp-direct / rust-direct.
##   * Executable: ``<root>/.repro/build/<name>/<name>(.exe)``
##
## **Dep wiring**:
##
## A ``depends_on calc: mathlib`` edge turns into:
##   * calc's compile gets ``-I <root>/.repro/build/mathlib/`` (search
##     path for the upstream library archive — Go's compile-time
##     equivalent of C's ``-I``).
##   * calc's link gets ``-L <root>/.repro/build/mathlib/`` AND
##     references the upstream's ``mathlib.a`` via the per-binary
##     ``importcfg.link`` file.
##   * The upstream's compile action id is added to calc's compile +
##     link ``deps`` for sequencing.
##   * The upstream's archive path is added to calc's ``inputs`` for
##     cache-hit invalidation.
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * External Go modules (anything that isn't in-workspace). Mode 3
##     is in-workspace only; users with external deps write a
##     ``go.mod`` and let the Mode 2 ``go`` convention drive the build.
##     The scanner silently drops external imports (paths with a dot
##     in the first segment).
##   * ``go test`` discovery — defer; the Mode 2 ``go`` convention has
##     it via the M22 ``TestGoFiles`` / ``XTestGoFiles`` surface.
##   * Cross-package internal dep via ``internal/`` directories — the
##     scanner doesn't enforce the access restriction.
##   * ``-trimpath`` + reproducible-build flags — these come for free
##     with ``go tool compile`` but a future M can thread them
##     explicitly into the argv for byte-deterministic outputs.
##
## **M36 — cross-language Go ↔ C/C++**:
## landed 2026-05-29. The convention claims mixed Go + C/C++
## workspaces (``c-cpp-direct``'s ``recognize`` defers when ``uses:``
## anywhere names ``go`` and no ``go.mod`` / ``go.work`` is present, so
## a single convention emits both directions of the cgo + c-archive
## matrix from one fragment — mirror of how ``rust_direct`` claims
## mixed Rust + C/C++ workspaces and Nim claims mixed Nim + C/C++).
## Two directions:
##
##   * **Forward (Go binary → C library)**: a Go ``executable``
##     ``depends_on`` a C ``library`` member, and/or any Go source under
##     the Go member's source dir carries an ``import "C"`` line. The
##     embedded C/C++ helpers emit per-source ``gcc -c`` + ``ar rcs
##     lib<name>.a``. The Go binary's build switches from
##     ``go tool compile / go tool link`` (the M31 path) to
##     ``go build`` because cgo requires the full Go build pipeline
##     (cgo preprocessor + linker integration). The build runs with
##     ``CGO_ENABLED=1`` and ``CC=gcc``; ``-ldflags '-L<archive-dir>
##     -l<libname>'`` threads the upstream C archive onto the cgo link.
##
##   * **Reverse (C/C++ binary → Go c-archive)**: a C/C++ ``executable``
##     ``depends_on`` a Go ``library`` member. The Go library's
##     ``cConsumable`` flag is derived from the dep edge; when set, the
##     library is emitted via ``go build -buildmode=c-archive -o
##     <root>/.repro/build/<name>/lib<name>.a`` (the canonical archive
##     schema shared with ``c-cpp-direct`` / Nim / Rust). Go's c-archive
##     toolchain also auto-emits a sibling ``lib<name>.h`` header in the
##     same dir (the C consumer ``#include``s that header to get the
##     ``//export``ed functions' C declarations). Embedded helpers then
##     emit the C++ binary's per-source ``g++ -c`` + terminal ``g++ -o``
##     link action; the Go c-archive lands on the link argv as a
##     trailing positional plus the platform-specific Go-runtime libs.
##
## Action-id prefixes for cross-language emit are
## ``go-xlang-ccpp-compile-*``, ``go-xlang-ccpp-archive-*``,
## ``go-xlang-ccpp-exec-compile-*``, ``go-xlang-ccpp-exec-link-*`` plus
## ``go-direct-build-*`` for cgo Go binaries and
## ``go-direct-c-archive-*`` for c-archive Go libraries (mirrors the
## rust-direct convention's ``rust-xlang-ccpp-...`` discriminator).
##
## **Pure-Go regression**: Mode 3 workspaces with no cgo AND no C/C++
## members keep the M31 ``go tool compile`` + ``go tool link`` per-
## member paths. The expensive ``go build`` invocation is only used
## when cgo is actually needed (the M31 fast path for hermetic per-
## package Go builds stays in place for pure-Go workspaces).
##
## **NimMain-equivalent for Go runtime**: Go's c-archive auto-
## initializes the Go runtime when any exported function is called
## (the generated header's ``//export``ed wrappers handle the
## ``_cgo_init`` dance). Unlike Nim's ``NimMain()``, the C consumer
## does NOT need to call anything explicitly — the fixture's C source
## calls the exported Go function directly.
##
## **Out of scope for M36 (documented as deferred)**:
##
##   * Cross-compiling cgo — host-build only.
##   * Pure-cgo with C code inlined directly in the Go source's
##     ``import "C"`` block — fixtures keep the simple ``#include
##     "<header>.h"`` shape only.
##   * Auto-generated FFI declarations both ways — users hand-write the
##     ``//export`` directive and the C consumer's wrapper header.
##   * c-archive on macOS framework path — out of scope (host POSIX +
##     Windows MinGW only).

import std/[algorithm, json, os, osproc, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Identical to the Mode 2 Go convention's scratch dir so the two
    ## conventions produce co-located outputs and ``repro clean`` finds
    ## both. The Mode 3 convention is registered AFTER ``go``, so the
    ## scratch path stays stable when a project flips between go.mod
    ## and Mode 3.

  GoLangFlag* = "1.21"
    ## Edition-ish flag fed to ``go tool compile`` via ``-lang=go1.21``.
    ## M31 hard-codes a conservative baseline; a per-package DSL field
    ## is an outstanding follow-up (the spec's "Edition read from a
    ## per-package DSL field" deliverable applies the same way to Go).
    ## Any in-workspace ``.go`` file using a newer language feature
    ## would fail compile loudly, at which point the user can either
    ## bump this constant or add the future DSL field.

type
  GoDirectMemberKind = enum
    gdmkExecutable
    gdmkLibraryStatic

  GoDirectMember = object
    name: string
    kind: GoDirectMemberKind
    package: string  ## Owning ``package <name>:`` block (Mode 3).
    usesCgo: bool
      ## M36 forward direction: at least one ``.go`` file under this
      ## member's source dir carries an ``import "C"`` line. Drives the
      ## build path: cgo-using members route through ``go build``
      ## (with ``CGO_ENABLED=1`` + ``CC=gcc``); pure-Go members keep
      ## the M31 ``go tool compile`` / ``go tool link`` fast path.
    cConsumable: bool
      ## M36 reverse direction: when a C/C++ executable in the same
      ## workspace ``depends_on`` this library's package, the library
      ## is emitted via ``go build -buildmode=c-archive`` landing at
      ## ``<root>/.repro/build/<name>/lib<name>.a`` (the canonical
      ## archive schema shared with c-cpp-direct + Nim + Rust).
      ## When false (no C/C++ downstream), the library emits via
      ## ``go tool compile -pack`` as before (M31 behaviour preserved
      ## for pure Go workspaces).

  GoDirectEmitTarget = object
    member: GoDirectMember
    srcDir: string
    entrySource: string
    sourceFiles: seq[string]
      ## Every ``.go`` file directly in ``srcDir`` (NOT recursed —
      ## Mode 3 single-package members compile from a flat dir, mirror
      ## of Go's own "one package per directory" rule).
    stdlibImports: seq[string]
      ## Unique stdlib package paths (e.g. ``fmt``, ``encoding/json``)
      ## imported by this member's sources. Used to compose the
      ## ``importcfg`` ``packagefile`` lines plus the
      ## ``importcfg.link`` transitive closure.
    workspaceImports: seq[string]
      ## Unique in-workspace package names (the import path's last
      ## segment) imported by this member's sources. Cross-referenced
      ## against the workspace library index at emit time.

  GoDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the C/C++ / Rust Mode 3 conventions'
    ## ``CCppWorkspaceLibrary`` / ``RustDirectWorkspaceLibrary``.
    libraryName: string
    package: string
    compileActionId: string
    outputPath: string
      ## ``<root>/.repro/build/<name>/<name>.a`` (M31 pure-Go path) OR
      ## ``<root>/.repro/build/<name>/lib<name>.a`` (M36 c-archive).
    archiveDir: string
      ## Parent dir of ``outputPath``. Used as the downstream's ``-I``
      ## search path so the upstream archive resolves under its bare
      ## package name.
    cConsumable: bool
      ## True when ``outputPath`` is a c-archive (``lib<name>.a``);
      ## false when it's the pure-Go ``<name>.a``. Drives the
      ## downstream wiring (Go-to-Go via importcfg vs C-to-Go via
      ## ``-L`` + ``-l`` plus runtime libs).

  GoDirectCCppMember = object
    ## Cross-language C/C++ ``library`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that the go-direct
    ## convention claims. Discovered by ``collectCCppCrossMembers`` and
    ## emitted in-line as per-source ``gcc -c`` + ``ar rcs`` actions.
    package: string
    libraryName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  GoDirectCCppExecutable = object
    ## Cross-language C/C++ ``executable`` member belonging to a
    ## ``uses: gcc/clang`` package in a workspace that the go-direct
    ## convention claims. Discovered by ``collectCCppCrossExecutables``
    ## and emitted in-line as per-source compile + terminal link
    ## actions. Used for the reverse direction (C/C++ binary → Go
    ## c-archive).
    package: string
    executableName: string
    srcDir: string
    includeDir: string
    sourceFiles: seq[string]

  GoDirectCCppUpstreamLibrary = object
    ## Bookkeeping for an emitted C/C++ archive that a cgo Go binary's
    ## ``go build`` step picks up via ``-ldflags '-L<dir> -l<name>'``.
    ## Indexed by owning package so a ``depends_on goApp: cLibPkg``
    ## edge can resolve to "every C library member of cLibPkg".
    package: string
    libraryName: string
    linkActionId: string
    outputPath: string
    nativeSearchDir: string
    includeDir: string

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesGo(source: string): bool =
  ## True when the ``uses:`` block names ``go``. Mode 3 intentionally
  ## doesn't match on any other token — the Mode 2 ``go`` convention's
  ## ``usesIncludesGo`` uses the exact same check, but the Mode 3
  ## convention is the one without a manifest to anchor on.
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

type
  GoDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeGoUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractGoPackageUses(source: string): seq[GoDirectPackageUses] =
  ## Local mirror of the C/C++ / Rust Mode 3 conventions'
  ## ``extractCCppPackageUses`` / ``extractRustPackageUses``. Used for
  ## cross-language filtering so this convention only emits actions
  ## for the ``go``-using packages in a mixed workspace.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(GoDirectPackageUses(
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
        consumeGoUsesToken(currentTokens, raw)
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
          consumeGoUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesGo(usesEntries: openArray[GoDirectPackageUses];
                   package, source: string): bool =
  if package.len == 0:
    return usesIncludesGo(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "go":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[GoDirectMember] =
  ## Walk ``source`` text and emit ``GoDirectMember`` rows with the
  ## owning ``package <name>:`` block. Mirror of the C/C++ / Rust
  ## conventions' same-named helper.
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
        result.add(GoDirectMember(
          name: name, kind: gdmkExecutable,
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
        result.add(GoDirectMember(
          name: name, kind: gdmkLibraryStatic,
          package: currentPackage))
      continue

proc hasGoMod(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "go.mod"))

proc hasGoWork(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "go.work"))

proc goExecutable(): string =
  findExe("go")

proc goSourceFilesHaveCgo(sources: openArray[string]): bool =
  ## Returns true when ANY ``.go`` file in ``sources`` carries an
  ## ``import "C"`` line. M36: cgo is now ACCEPTED and routes through
  ## ``go build`` instead of the M31 per-package
  ## ``go tool compile / go tool link`` fast path.
  for entry in sources:
    let filename = extractFilename(entry)
    if filename.toLowerAscii.startsWith("_cgo_"):
      return true
    var content: string
    try:
      content = readFile(extendedPath(entry))
    except CatchableError:
      continue
    for rawLine in content.splitLines():
      var line = rawLine
      let commentIdx = line.find("//")
      if commentIdx >= 0:
        line = line[0 ..< commentIdx]
      let stripped = line.strip()
      if stripped == "import \"C\"":
        return true
      if stripped == "\"C\"":
        return true
  false

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc collectMemberGoSources(srcDir: string): seq[string] =
  ## Every non-test ``.go`` file DIRECTLY under ``srcDir`` (not
  ## recursed). Mode 3 single-package members compile from a flat dir;
  ## a nested subdir would be a separate Go package which the scanner
  ## doesn't model as Mode 3 members.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for kind, entry in walkDir(srcDir):
    if kind != pcFile:
      continue
    if isGoSourceFile(entry):
      result.add(entry)
  result.sort(system.cmp[string])

proc collectMemberImports(sources: openArray[string];
                          memberName: string;
                          memberOwnPackage: string;
                          ownerToWorkspacePackage: Table[string, string]):
    tuple[stdlib: seq[string]; workspace: seq[string]] =
  ## Walk every source under the member's source dir and split the
  ## imports into stdlib + in-workspace. External-module imports
  ## (paths with a dot in the first segment) and self-imports are
  ## dropped (mirror of the scanner's edge-emit policy).
  var stdlibSet: seq[string] = @[]
  var workspaceSet: seq[string] = @[]
  for srcPath in sources:
    let text =
      try:
        readFile(extendedPath(srcPath))
      except CatchableError:
        continue
    for importRef in extractGoImportRefs(text):
      let path = importRef.path
      if path.len == 0:
        continue
      if isGoStdlibImport(path):
        if stdlibSet.find(path) < 0:
          stdlibSet.add(path)
        continue
      if isGoExternalModuleImport(path):
        # Mode 3 is in-workspace only; external imports are dropped
        # silently. The convention's recognise step has already
        # ensured the user opted into Mode 3 (no go.mod). A future
        # diagnostic for "external import with no go.mod" could land
        # here — for now stay quiet so the build proceeds and Go's
        # own compile-time error reports the missing package.
        continue
      let last = importLastSegment(path)
      if last == memberName:
        continue
      if ownerToWorkspacePackage.hasKey(last):
        let owner = ownerToWorkspacePackage[last]
        if owner == memberOwnPackage:
          # Self-import via a sibling member sharing the same package
          # — no workspace edge needed.
          continue
        if workspaceSet.find(last) < 0:
          workspaceSet.add(last)
        continue
      # Unrecognised — looks workspace-internal but doesn't match
      # any declared member. Drop silently; the actual compile will
      # produce Go's own "no Go files in <dir>" error if the user
      # mistyped. The convention's depends_on validation also
      # catches workspace dep issues at the package level.
  stdlibSet.sort(system.cmp[string])
  workspaceSet.sort(system.cmp[string])
  result.stdlib = stdlibSet
  result.workspace = workspaceSet

proc resolveTarget(projectRoot: string; member: GoDirectMember;
                   workspaceNameIndex: Table[string, string]):
    GoDirectEmitTarget =
  ## Resolve a member's source dir + source files + scanned imports
  ## via the shared scanner helper that handles Layout B vs Layout A.
  result.member = member
  let resolved = resolveGoMemberDirs(projectRoot, member.name)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectMemberGoSources(resolved.srcDir)
  let imports = collectMemberImports(result.sourceFiles, member.name,
    member.package, workspaceNameIndex)
  result.stdlibImports = imports.stdlib
  result.workspaceImports = imports.workspace
  # M36: per-member cgo detection. Only this member's sources matter
  # (a sibling Go member without cgo keeps the M31 fast path even when
  # another member uses cgo).
  result.member.usesCgo = goSourceFilesHaveCgo(result.sourceFiles)

proc goDirectRecognize(projectRoot: string;
                       request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``go.mod`` at the workspace root (the Mode 2 Go
  ##     convention's territory).
  ##   * NO ``go.work`` (workspaces deferred).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``go`` SOMEWHERE in the file (M36: a mixed
  ##     workspace where only the C/C++ side resolves still counts —
  ##     we claim because c-cpp-direct defers when ``go`` is named).
  ##   * at least one ``executable`` / ``library`` member is declared.
  ##     For pure-Go workspaces, at least one Go member must resolve
  ##     via ``resolveGoMemberDirs``; for mixed workspaces, we also
  ##     accept a C/C++ member resolving via the cpp_dep_scanner's
  ##     ``resolveMemberDirs`` (M36 cross-language path).
  ##   * ``go`` is on PATH at convention-emit time. We still need it
  ##     for the stdlib closure resolution and the cgo / c-archive
  ##     ``go build`` invocations.
  ##   * M36: cgo (``import "C"``) is ACCEPTED and routes through this
  ##     convention's ``go build`` path; the M31 cgo-rejection is
  ##     lifted.
  if hasGoMod(projectRoot):
    return false
  if hasGoWork(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesGo(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if goExecutable().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveGoMemberDirs(projectRoot, member.name)
    if resolved.srcDir.len > 0:
      atLeastOneResolved = true
      break
  # M36: mixed-workspace fallback — even if no Go member resolves
  # (the workspace might be C/C++-heavy with go-claimed packages whose
  # source lives at a non-canonical location), accept the workspace
  # when a C/C++ member resolves. The emit step's per-member resolve
  # will raise a clean error if the user's ``executable goName`` is
  # missing sources entirely.
  if not atLeastOneResolved:
    for member in members:
      let cResolved = resolveMemberDirs(projectRoot, member.name)
      if cResolved.srcDir.len > 0:
        atLeastOneResolved = true
        break
  atLeastOneResolved

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc archivePathFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / (member & ".a")

proc importcfgPathFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / (member & ".importcfg")

proc linkImportcfgPathFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / (member & ".importcfg.link")

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".exe")
  else:
    scratchPathFor(projectRoot, member) / member

# ----------------------------------------------------------------------
# Stdlib archive resolution.
#
# Mode 3 has no ``go.mod`` so we can't run ``go list ./...`` to get the
# full per-module transitive closure. Instead we compute the union of
# every stdlib import across the workspace's members, then run a single
# ``GO111MODULE=off go list -export -json -deps <unique-stdlib-roots>``
# call to pull GOCACHE paths for every transitively required stdlib
# package. The result is a table keyed on import path → absolute
# archive path that the per-member ``importcfg`` and per-binary
# ``importcfg.link`` files reference verbatim.
# ----------------------------------------------------------------------

proc resolveStdlibArchives(goExe, projectRoot: string;
                          stdlibImports: openArray[string]):
                            Table[string, string] =
  ## Map every stdlib import path (direct + transitive) to its
  ## ``GOCACHE`` archive path. ``stdlibImports`` is the union of direct
  ## stdlib imports across all workspace members; ``go list -deps``
  ## expands that to the transitive closure.
  ##
  ## ``GO111MODULE=off`` is the load-bearing knob: without it, ``go
  ## list`` running outside a module errors out with "directory does
  ## not contain main module". The legacy GOPATH mode happily resolves
  ## stdlib import paths against the in-tree ``GOROOT/src`` tree
  ## without needing a module manifest.
  result = initTable[string, string]()
  if stdlibImports.len == 0:
    return
  var unique: seq[string] = @[]
  for path in stdlibImports:
    if unique.find(path) < 0:
      unique.add(path)
  unique.sort(system.cmp[string])

  var argv = @[goExe, "list", "-export", "-json", "-deps"]
  for path in unique:
    argv.add(path)
  let cmd = quoteShellCommand(argv)

  # ``GO111MODULE=off`` is fed via the per-process env override so the
  # subprocess sees module-mode disabled regardless of the host's
  # ambient setting. ``poParentStreams`` is NOT used — we drain stdout
  # the same way the Mode 2 convention does (large output on Windows).
  let prev = getEnv("GO111MODULE")
  putEnv("GO111MODULE", "off")
  defer:
    if prev.len == 0:
      delEnv("GO111MODULE")
    else:
      putEnv("GO111MODULE", prev)

  let (output, exitCode) = execCmdEx(cmd,
    options = {poStdErrToStdOut, poUsePath},
    workingDir = projectRoot)
  if exitCode != 0:
    raise newException(ValueError,
      "go-direct convention: 'go list -export -json -deps' exited " &
        $exitCode & " for " & projectRoot &
        " (stdlib closure resolution):\n" & output)

  # Parse the concatenated-JSON output, the same shape ``go.nim``
  # consumes.
  var depth = 0
  var startIdx = -1
  var inString = false
  var escape = false
  var i = 0
  while i < output.len:
    let ch = output[i]
    if inString:
      if escape:
        escape = false
      elif ch == '\\':
        escape = true
      elif ch == '"':
        inString = false
    else:
      case ch
      of '"':
        inString = true
      of '{':
        if depth == 0:
          startIdx = i
        inc depth
      of '}':
        dec depth
        if depth == 0 and startIdx >= 0:
          let fragment = output[startIdx .. i]
          try:
            let node = parseJson(fragment)
            if node.kind == JObject and "ImportPath" in node:
              let pkgPath = node["ImportPath"].getStr()
              var exportPath = ""
              if "Export" in node:
                exportPath = node["Export"].getStr()
              # Some stdlib packages (``unsafe``) carry no Export — the
              # compiler handles them intrinsically; we just don't emit
              # a packagefile line for them.
              if pkgPath.len > 0 and exportPath.len > 0:
                result[pkgPath] = exportPath
          except CatchableError:
            discard
          startIdx = -1
      else:
        discard
    inc i

proc renderImportcfg(stdlibArchives: Table[string, string];
                     stdlibImports: openArray[string];
                     workspaceImports: openArray[string];
                     workspaceLibs:
                       openArray[GoDirectWorkspaceLibrary]): string =
  ## Build the per-package ``importcfg`` text. Direct imports only —
  ## the link-time ``importcfg.link`` carries the full transitive
  ## stdlib closure plus every in-workspace library archive.
  result.add("# import config\n")
  for importPath in stdlibImports:
    if stdlibArchives.hasKey(importPath):
      result.add("packagefile " & importPath & "=" &
        stdlibArchives[importPath] & "\n")
  for memberName in workspaceImports:
    for lib in workspaceLibs:
      if lib.libraryName == memberName:
        result.add("packagefile " & memberName & "=" &
          lib.outputPath & "\n")
        break

proc renderLinkImportcfg(stdlibArchives: Table[string, string];
                        workspaceLibs:
                          openArray[GoDirectWorkspaceLibrary];
                        binaryName, binaryArchive: string): string =
  ## Build the link-time ``importcfg.link`` — the FULL transitive
  ## closure. Includes:
  ##   * Every stdlib archive ``go list -deps`` resolved.
  ##   * Every in-workspace library archive.
  ##   * The binary's own ``<name>.a`` (mapped under the magic
  ##     ``main`` import path so ``go tool link`` finds ``main.main``).
  result.add("# import config\n")
  # Sort stdlib entries deterministically.
  var stdlibPaths: seq[string] = @[]
  for path in stdlibArchives.keys:
    stdlibPaths.add(path)
  stdlibPaths.sort(system.cmp[string])
  for path in stdlibPaths:
    result.add("packagefile " & path & "=" & stdlibArchives[path] & "\n")
  for lib in workspaceLibs:
    result.add("packagefile " & lib.libraryName & "=" &
      lib.outputPath & "\n")
  if binaryName.len > 0 and binaryArchive.len > 0:
    result.add("packagefile main=" & binaryArchive & "\n")

# ----------------------------------------------------------------------
# Action emission.
# ----------------------------------------------------------------------

proc emitImportcfgAction(projectRoot, member: string;
                         text: string): tuple[action: BuildActionDef;
                                              path: string] =
  let path = importcfgPathFor(projectRoot, member)
  createDir(extendedPath(parentDir(path)))
  let action = fs.writeText(
    output = path,
    text = text,
    actionId = "go-direct-importcfg-" & sanitizeNamePart(member),
    commandStatsId = "go-direct.importcfg")
  (action, path)

proc emitLinkImportcfgAction(projectRoot, member: string;
                             text: string): tuple[action: BuildActionDef;
                                                  path: string] =
  let path = linkImportcfgPathFor(projectRoot, member)
  createDir(extendedPath(parentDir(path)))
  let action = fs.writeText(
    output = path,
    text = text,
    actionId = "go-direct-importcfg-link-" & sanitizeNamePart(member),
    commandStatsId = "go-direct.importcfg-link")
  (action, path)

proc emitCompileAction(projectRoot, goExe: string;
                       target: GoDirectEmitTarget;
                       importcfgPath, importcfgActionId: string;
                       depCompileActionIds: openArray[string];
                       depArchives: openArray[string]): BuildActionDef =
  ## One ``go tool compile`` action per member. For libraries this
  ## produces the final ``<name>.a`` archive; for executables this
  ## produces the main package's ``<name>.a`` which the link step
  ## consumes.
  let archive = archivePathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(archive)))
  let pFlag =
    case target.member.kind
    of gdmkExecutable: "main"
    of gdmkLibraryStatic: target.member.name
  var argv = @[
    goExe,
    "tool",
    "compile",
    "-p", pFlag,
    "-lang=go" & GoLangFlag,
    "-complete",
    "-importcfg", importcfgPath,
    "-pack",
    "-o", archive,
  ]
  # ``-I <upstream-archive-dir>`` so the compiler resolves the upstream
  # archive by bare package name. Mirrors ``c-cpp-direct``'s ``-I``
  # thread-through, just for Go's compile-time archive search.
  for archiveDir in depArchives:
    argv.add("-I")
    argv.add(archiveDir)
  for src in target.sourceFiles:
    argv.add(src)

  var inputs: seq[string] = @[importcfgPath]
  for src in target.sourceFiles:
    inputs.add(src)
  # Upstream archive paths land on inputs for cache invalidation.
  for archiveDir in depArchives:
    discard archiveDir  # archiveDir is the parent of an upstream .a;
    # the per-lib outputPath is the precise dep — added below via
    # depArchives' callers.

  var deps: seq[string] = @[importcfgActionId]
  for actionId in depCompileActionIds:
    if deps.find(actionId) < 0:
      deps.add(actionId)

  let kindTag =
    case target.member.kind
    of gdmkExecutable: "executable"
    of gdmkLibraryStatic: "library"
  buildAction(
    id = "go-direct-compile-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[archive],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct." & kindTag & ".compile")

proc emitLinkAction(projectRoot, goExe: string;
                    target: GoDirectEmitTarget;
                    compileActionId, compileArchive: string;
                    linkImportcfgPath, linkImportcfgActionId: string;
                    depArchiveDirs: openArray[string];
                    depCompileActionIds: openArray[string];
                    depArchivePaths: openArray[string]):
                      BuildActionDef =
  ## ``go tool link`` action for an executable member. Consumes the
  ## compile output + the per-binary ``importcfg.link``. Produces the
  ## final executable under ``<scratch>/<member>/<member>(.exe)``.
  let binaryOutput = binaryPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[
    goExe,
    "tool",
    "link",
    "-importcfg", linkImportcfgPath,
    "-buildmode=exe",
  ]
  # ``-L`` Go-tool-link search dirs so a stray archive lookup falls
  # back to the right directory (defensive — importcfg.link already
  # carries the explicit paths).
  for d in depArchiveDirs:
    argv.add("-L")
    argv.add(d)
  argv.add("-o")
  argv.add(binaryOutput)
  argv.add(compileArchive)

  var inputs: seq[string] = @[linkImportcfgPath, compileArchive]
  for archive in depArchivePaths:
    if inputs.find(archive) < 0:
      inputs.add(archive)

  var deps: seq[string] = @[compileActionId, linkImportcfgActionId]
  for actionId in depCompileActionIds:
    if deps.find(actionId) < 0:
      deps.add(actionId)

  buildAction(
    id = "go-direct-link-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct.executable.link")

# ----------------------------------------------------------------------
# M36 cgo + c-archive paths.
#
# Pure-Go members use the M31 ``go tool compile`` + ``go tool link``
# fast path emitted above. Cgo executables and c-archive libraries
# switch to a coarse-grained ``go build`` invocation because cgo
# requires Go's full build pipeline (the cgo preprocessor + linker
# integration). The c-archive build mode additionally tells Go to emit
# a sibling ``.h`` header alongside the archive.
# ----------------------------------------------------------------------

proc cArchivePathFor(projectRoot, member: string): string =
  ## ``<root>/.repro/build/<member>/lib<member>.a`` — the canonical
  ## archive schema shared with c-cpp-direct + Nim + Rust. Used when
  ## the library is consumed by a C/C++ binary (``cConsumable=true``).
  scratchPathFor(projectRoot, member) / ("lib" & member & ".a")

proc cArchiveHeaderPathFor(projectRoot, member: string): string =
  ## Go's c-archive build mode emits a sibling ``.h`` header. The C
  ## consumer ``#include``s this header to get the C-callable
  ## declarations for every ``//export``ed Go function.
  scratchPathFor(projectRoot, member) / ("lib" & member & ".h")

proc gomodPathFor(projectRoot, memberSrcDir: string): string =
  ## Synthesised ``go.mod`` lives INSIDE the cgo member's source dir
  ## so ``go build`` finds a module context (modern Go refuses to
  ## build outside a module). The Mode 3 convention's recognise step
  ## checks only ``<projectRoot>/go.mod`` — a per-member go.mod here
  ## doesn't trigger the Mode 2 ``go`` convention's recognise (which
  ## would steal the workspace).
  memberSrcDir / "go.mod"

proc gomodTextFor(member: GoDirectMember): string =
  ## Minimal go.mod payload: just a module declaration with the
  ## member's name. We pin to Go 1.21 (matching ``GoLangFlag``).
  "module local/" & member.name & "\n\ngo " & GoLangFlag & "\n"

proc emitGoModAction(projectRoot: string;
                     target: GoDirectEmitTarget): tuple[
                       action: BuildActionDef; path: string] =
  ## Emit the synthesised ``go.mod`` for a cgo / c-archive member.
  ## The build action depends on this action's id; the file's
  ## existence is the load-bearing precondition for ``go build``.
  let path = gomodPathFor(projectRoot, target.srcDir)
  createDir(extendedPath(parentDir(path)))
  let action = fs.writeText(
    output = path,
    text = gomodTextFor(target.member),
    actionId = "go-direct-gomod-" & sanitizeNamePart(target.member.name),
    commandStatsId = "go-direct.gomod")
  (action, path)

proc emitCgoBuildAction(projectRoot, goExe: string;
                        target: GoDirectEmitTarget;
                        gomodActionId, gomodPath: string;
                        depArchiveDirs: openArray[string];
                        depArchiveLibNames: openArray[string];
                        depArchivePaths: openArray[string];
                        depCompileActionIds: openArray[string]):
                          BuildActionDef =
  ## M36 forward direction: a Go executable member that uses cgo. We
  ## switch from the M31 ``go tool compile / go tool link`` per-package
  ## path to ``go build`` because cgo requires Go's full build pipeline
  ## (the cgo preprocessor + C compiler invocation + linker
  ## integration). The build runs with ``CGO_ENABLED=1`` (Go's default)
  ## and ``CC=gcc`` (or whichever C compiler is on PATH); upstream C
  ## archives are threaded via ``-ldflags=-extldflags=-L<dir> -l<name>``
  ## so the cgo link picks them up.
  ##
  ## Action-id prefix ``go-direct-build-<name>`` discriminates from the
  ## M31 ``go-direct-compile-<name>`` / ``go-direct-link-<name>`` per-
  ## package paths (the same workspace can have a mix of cgo and non-
  ## cgo members, each routed independently).
  ##
  ## **cwd is the member's source dir** so ``go build .`` resolves
  ## the synthesised ``go.mod`` (modern Go requires module context;
  ## the Mode 3 ``go-direct`` convention forbids a workspace-root
  ## ``go.mod``, so we synthesise a per-member one inside the source
  ## dir which doesn't trigger Mode 2 ``go`` recognise at the
  ## workspace root level).
  let binaryOutput = binaryPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[
    goExe,
    "build",
    "-o", binaryOutput,
  ]
  var ldflagsParts: seq[string] = @[]
  for d in depArchiveDirs:
    ldflagsParts.add("-L" & d)
  for n in depArchiveLibNames:
    ldflagsParts.add("-l" & n)
  if ldflagsParts.len > 0:
    # Quote the inner ``-extldflags`` value so the Go linker's flag
    # parser treats ``-L<dir> -l<name>`` as a single argument to
    # ``-extldflags``. Without the quotes, the Go linker splits on
    # space and the ``-l<name>`` is treated as a top-level link flag
    # (which doesn't exist on the Go linker, producing a usage dump).
    let extldflagsValue = ldflagsParts.join(" ")
    argv.add("-ldflags=-extldflags \"" & extldflagsValue & "\"")
  argv.add(".")
  var inputs: seq[string] = @[gomodPath]
  for src in target.sourceFiles:
    inputs.add(src)
  for a in depArchivePaths:
    if inputs.find(a) < 0:
      inputs.add(a)
  var deps: seq[string] = @[gomodActionId]
  for actionId in depCompileActionIds:
    if deps.find(actionId) < 0:
      deps.add(actionId)
  buildAction(
    id = "go-direct-build-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, target.srcDir),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct.executable.cgo.build")

proc emitCArchiveBuildAction(projectRoot, goExe: string;
                             target: GoDirectEmitTarget;
                             gomodActionId, gomodPath: string):
                               BuildActionDef =
  ## M36 reverse direction: a Go library member that a C/C++ binary
  ## consumes. We emit ``go build -buildmode=c-archive`` so the
  ## resulting archive is C-callable (the standard Go ``compile -pack``
  ## archive carries Go-only metadata; c-archive mode emits a stable
  ## ABI archive plus a sibling ``.h`` header with declarations for
  ## every ``//export``ed function).
  ##
  ## Like ``emitCgoBuildAction``, the action runs from the member's
  ## source dir with a synthesised ``go.mod`` (modern Go requires
  ## module context for ``go build``).
  let archivePath = cArchivePathFor(projectRoot, target.member.name)
  let headerPath = cArchiveHeaderPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(archivePath)))
  var argv = @[
    goExe,
    "build",
    "-buildmode=c-archive",
    "-o", archivePath,
  ]
  argv.add(".")
  var inputs: seq[string] = @[gomodPath]
  for src in target.sourceFiles:
    inputs.add(src)
  buildAction(
    id = "go-direct-c-archive-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, target.srcDir),
    deps = @[gomodActionId],
    inputs = inputs,
    outputs = @[archivePath, headerPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct.library.c-archive")

# ----------------------------------------------------------------------
# M36 cross-language C/C++ helpers (mixed-workspace support).
#
# When a Mode 3 workspace declares both Go packages and C/C++ packages
# in a single ``repro.nim``, the go-direct convention claims the WHOLE
# workspace because ``c-cpp-direct``'s recognize defers when any
# ``uses:`` block names ``go`` (and no ``go.mod`` / ``go.work`` is
# present). We then take responsibility for emitting the C/C++
# packages' archive + binary actions in-line so the cross-package
# ``depends_on goApp: cppLib`` / ``depends_on cppApp: goLib`` edges
# produce a coherent action graph within a single
# ``buildPackageFragment`` call. Mirrors the rust-direct convention's
# pattern (M34).
#
# Shared archive schema:
#   C archive path  : <root>/.repro/build/<libName>/lib<libName>.a
#   Go c-archive    : <root>/.repro/build/<libName>/lib<libName>.a
#   Go c-archive hdr: <root>/.repro/build/<libName>/lib<libName>.h
#   obj dir         : <root>/.repro/build/<libName>/obj/
#   per-source obj  : <root>/.repro/build/<libName>/obj/<sanitized-stem>.o
#   exec path       : <root>/.repro/build/<exeName>/<exeName>[.exe]
# ----------------------------------------------------------------------

type
  GoDirectCCppMemberKind = enum
    gdccmkExecutable
    gdccmkLibraryStatic

  GoDirectCCppPlainMember = object
    package: string
    name: string
    kind: GoDirectCCppMemberKind

proc extractCCppMembersFromText(source: string):
    seq[GoDirectCCppPlainMember] =
  ## Walk ``source`` text for ``library`` / ``executable`` declarations
  ## with their owning ``package``. Mirror of rust_direct's
  ## ``extractCCppMembersFromText``. Used with a follow-up ``uses:``
  ## filter to keep only members in ``uses: gcc/clang`` packages.
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
        result.add(GoDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: gdccmkExecutable))
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
        result.add(GoDirectCCppPlainMember(
          package: currentPackage,
          name: name,
          kind: gdccmkLibraryStatic))
      continue

proc packageUsesAnyCCpp(usesEntries: openArray[GoDirectPackageUses];
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
                             usesEntries: openArray[GoDirectPackageUses]):
                               seq[GoDirectCCppMember] =
  ## Walk the project file for ``library`` declarations in packages
  ## whose ``uses:`` block names ``gcc``/``clang``. Each resolvable
  ## member is returned as a ``GoDirectCCppMember`` carrying its source
  ## set (used downstream to emit ``gcc -c`` + ``ar rcs`` actions).
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != gdccmkLibraryStatic:
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
    result.add(GoDirectCCppMember(
      package: entry.package,
      libraryName: entry.name,
      srcDir: resolved.srcDir,
      includeDir: resolved.includeDir,
      sourceFiles: sourceFiles))

proc collectCCppCrossExecutables(projectRoot, source: string;
                                 usesEntries: openArray[GoDirectPackageUses]):
                                   seq[GoDirectCCppExecutable] =
  ## Reverse-direction sibling of ``collectCCppCrossMembers``: harvest
  ## ``executable`` members from ``uses: gcc/clang`` packages so the
  ## go-direct convention can emit the C/C++ binary's compile + link
  ## inside the same fragment that emits the upstream Go c-archive.
  let members = extractCCppMembersFromText(source)
  for entry in members:
    if entry.kind != gdccmkExecutable:
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
    result.add(GoDirectCCppExecutable(
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
                                member: GoDirectCCppMember;
                                source, objFile, depFile: string):
                                  BuildActionDef =
  ## ``gcc -c`` action for one C/C++ source belonging to a cross-
  ## language upstream library that a Go binary consumes. Action-id
  ## prefix ``go-xlang-ccpp-compile-`` mirrors the rust-direct
  ## convention's ``rust-xlang-ccpp-compile-`` discriminator.
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
  let actionId = "go-xlang-ccpp-compile-" &
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
    commandStatsId = "go-direct.xlang.ccpp.compile")

proc emitCCppCrossArchiveAction(projectRoot, arExe: string;
                                member: GoDirectCCppMember;
                                objFiles, compileIds: seq[string]):
                                  BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action. Action-id prefix
  ## ``go-xlang-ccpp-archive-`` mirrors the rust-direct convention's
  ## discriminator.
  let archiveOutput = ccppCrossArchivePath(projectRoot, member.libraryName)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "go-xlang-ccpp-archive-" & sanitizeNamePart(member.libraryName),
    call = inlineExecCall(argv, projectRoot),
    deps = compileIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct.xlang.ccpp.archive")

proc emitCCppCrossMember(projectRoot: string;
                         member: GoDirectCCppMember):
                           tuple[compiles: seq[BuildActionDef];
                                 archive: BuildActionDef;
                                 archivePath: string;
                                 includeDir: string] =
  ## Emit the full per-source ``gcc -c`` set plus the terminal
  ## ``ar rcs`` archive action for one cross-language upstream C
  ## library. Returns the archive path + include dir so the caller can
  ## wire the downstream cgo Go binary's ``go build`` argv.
  let ccExe = ccCompilerCross()
  if ccExe.len == 0:
    raise newException(ValueError,
      "go-direct convention (mixed workspace): neither 'gcc' nor " &
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
# Reverse-direction (C/C++ binary → Go c-archive) executable emit.
# ---------------------------------------------------------------------------

proc isCxxSourceList(sources: openArray[string]): bool =
  for source in sources:
    if isCxxSource(source):
      return true
  false

proc goRuntimeLinkLibs(): seq[string] =
  ## A Go c-archive carries references to a small set of platform
  ## libraries that the consumer's link line must satisfy. These cover
  ## the Go runtime's thread + sync primitives, math, dynamic linker
  ## interactions, plus Windows-specific bits.
  ##
  ## **POSIX**: ``-lpthread -ldl -lm`` (Go runtime needs threads +
  ## ``dlopen`` family + math symbols).
  ##
  ## **Windows MinGW (gcc / g++ via MSYS2 mingw64)**: the Go runtime
  ## touches the Win32 sockets API (``-lws2_32``), CryptoAPI
  ## (``-lbcrypt``), NT process primitives (``-lntdll``), winmm
  ## (``-lwinmm``), advapi32 + userenv for security tokens, plus the
  ## standard C runtime (gcc handles ``-lmsvcrt`` implicitly).
  when defined(windows):
    @["-lws2_32", "-lwinmm", "-lbcrypt", "-lntdll", "-luserenv",
      "-ladvapi32"]
  else:
    @["-lpthread", "-ldl", "-lm"]

proc emitCCppCrossExecCompileAction(projectRoot, ccExe: string;
                                    exec: GoDirectCCppExecutable;
                                    source, objFile, depFile: string):
                                      BuildActionDef =
  ## Per-source compile action for a cross-language C/C++ executable
  ## that links a Go c-archive. Action-id prefix
  ## ``go-xlang-ccpp-exec-compile-`` mirrors the rust-direct
  ## convention's reverse-direction shape.
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
  let actionId = "go-xlang-ccpp-exec-compile-" &
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
    commandStatsId = "go-direct.xlang.ccpp.exec.compile")

proc emitCCppCrossExecLinkAction(projectRoot, linkDriver: string;
                                 exec: GoDirectCCppExecutable;
                                 objFiles, compileIds: seq[string];
                                 goUpstream:
                                   openArray[GoDirectWorkspaceLibrary]):
                                   BuildActionDef =
  ## Terminal ``g++ -o <bin>`` link action. Each upstream Go c-archive
  ## lands as a trailing positional (gcc/ld resolves symbols left-to-
  ## right; ``.a``s must follow the ``.o``s that reference them). The
  ## platform-specific Go runtime libs land AFTER the Go archives so
  ## they pick up the runtime symbols the Go archive references.
  let binaryOutput = ccppCrossBinaryPath(projectRoot, exec.executableName)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[linkDriver, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  for lib in goUpstream:
    argv.add(lib.outputPath)
  for libFlag in goRuntimeLinkLibs():
    argv.add(libFlag)
  var deps = compileIds
  var inputs = objFiles
  for lib in goUpstream:
    if deps.find(lib.compileActionId) < 0:
      deps.add(lib.compileActionId)
    if inputs.find(lib.outputPath) < 0:
      inputs.add(lib.outputPath)
  buildAction(
    id = "go-xlang-ccpp-exec-link-" & sanitizeNamePart(exec.executableName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "go-direct.xlang.ccpp.exec.link")

proc emitCCppCrossExecutable(projectRoot: string;
                             exec: GoDirectCCppExecutable;
                             goUpstream:
                               openArray[GoDirectWorkspaceLibrary]):
                               tuple[compiles: seq[BuildActionDef];
                                     link: BuildActionDef;
                                     binaryPath: string] =
  ## Emit the per-source ``gcc -c`` / ``g++ -c`` set plus the terminal
  ## ``gcc -o`` / ``g++ -o`` link action for one cross-language C/C++
  ## executable that consumes upstream Go c-archives. The link argv is
  ## augmented with each upstream Go archive's path + the platform-
  ## specific Go runtime libs so the C/C++ binary's link resolves the
  ## Go symbols.
  let cExe = ccCompilerCross()
  if cExe.len == 0:
    raise newException(ValueError,
      "go-direct convention (mixed workspace): neither 'gcc' nor " &
        "'clang' on PATH; cannot compile cross-language C/C++ " &
        "executable '" & exec.executableName & "'")
  let needsCxxDriver = isCxxSourceList(exec.sourceFiles)
  let linkDriver =
    if needsCxxDriver:
      let cxx = cxxCompilerCross()
      if cxx.len == 0:
        raise newException(ValueError,
          "go-direct convention (mixed workspace): C/C++ executable '" &
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
    objFiles, compileIds, goUpstream)
  result.compiles = compileActions
  result.link = link
  result.binaryPath = ccppCrossBinaryPath(projectRoot, exec.executableName)

# ----------------------------------------------------------------------
# Workspace dep edge handling — copy of the c-cpp-direct / rust-direct
# helpers. Mode 3 dep validation runs over the union of
# ``depends_on`` lines from ``repro.nim`` + ``repro.scanned-deps.nim``.
# ----------------------------------------------------------------------

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
        "go-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "go-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "go-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[GoDirectMember]): PackageDef =
  var name = "go_direct_convention"
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

proc goDirectEmitFragment(projectRoot: string;
                          request: ProviderGraphRequest):
                            GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members (Go + C/C++ in mixed
  ## workspaces), validate Mode 3 dep edges, resolve stdlib archives,
  ## emit per-member compile + per-executable link actions plus (in
  ## mixed workspaces) per-source ``gcc -c`` + ``ar rcs`` and C++
  ## binary actions via the DSL.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractGoPackageUses(source)
    var members: seq[GoDirectMember] = @[]
    for member in allMembers:
      if not packageUsesGo(usesEntries, member.package, source):
        continue
      members.add(member)
    # M36 cross-language: enumerate C/C++ library members the
    # convention emits archives for (forward direction: cgo Go binary
    # → C archive), and C/C++ executable members the convention emits
    # per-source compile + terminal link actions for (reverse: C++
    # binary → Go c-archive).
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
        "go-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let goExe = goExecutable()
    if members.len > 0 and goExe.len == 0:
      raise newException(ValueError,
        "go-direct convention: 'go' not on PATH; " &
          "cannot compile Go sources")

    # Build the workspace-name → owner-package index used by import
    # resolution at scan time.
    var workspaceNameIndex = initTable[string, string]()
    for member in members:
      if member.name.len > 0:
        workspaceNameIndex[member.name] = member.package
      if member.package.len > 0 and
          not workspaceNameIndex.hasKey(member.package):
        workspaceNameIndex[member.package] = member.package

    var targets: seq[GoDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member, workspaceNameIndex)
      if target.sourceFiles.len == 0:
        raise newException(ValueError,
          "go-direct convention: no Go sources resolved for member '" &
            member.name & "' under " & projectRoot &
            " (looked for <root>/" & member.name & "/, <root>/src/, " &
            "and <root>/)")
      targets.add(target)

    let rawDepEdges = collectWorkspaceDepEdges(projectRoot, source)
    let depEdges = dedupDepEdges(rawDepEdges)
    var declaredPackages: seq[string] = @[]
    for member in members:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    # Include cross-language C/C++ packages in the declared set so the
    # validator accepts ``depends_on goApp: cLibPkg`` /
    # ``depends_on cppApp: goLibPkg`` without spuriously rejecting the
    # C/C++ side as undeclared.
    for member in cCppCrossMembers:
      if member.package.len > 0 and
          declaredPackages.find(member.package) < 0:
        declaredPackages.add(member.package)
    for exec in cCppCrossExecutables:
      if exec.package.len > 0 and
          declaredPackages.find(exec.package) < 0:
        declaredPackages.add(exec.package)
    validateWorkspaceDeps(depEdges, declaredPackages)

    # M36 reverse cross-language: derive ``cConsumable`` for each Go
    # library from the dep graph. A library is cConsumable when ANY
    # C/C++ executable in the workspace ``depends_on`` its package.
    # The flag toggles the library's build path between
    # ``go tool compile -pack`` (Go-to-Go consumption — M31 fast path)
    # and ``go build -buildmode=c-archive`` (C/C++ consumption — M36).
    var cConsumedPackages: seq[string] = @[]
    for exec in cCppCrossExecutables:
      for edge in depEdges:
        if edge.fromPackage != exec.package:
          continue
        if cConsumedPackages.find(edge.toPackage) < 0:
          cConsumedPackages.add(edge.toPackage)
    if cConsumedPackages.len > 0:
      var rewritten: seq[GoDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == gdmkLibraryStatic and
            entry.member.package.len > 0 and
            cConsumedPackages.find(entry.member.package) >= 0:
          entry.member.cConsumable = true
        rewritten.add(entry)
      targets = rewritten

    # M36 forward cross-language: also mark Go executables that
    # depend_on a C/C++ package as cgo-using (forces the ``go build``
    # path even if the user's source doesn't explicitly carry an
    # ``import "C"`` line — the build still needs the cgo machinery
    # to link the C archive). The per-source scan (in resolveTarget)
    # already sets usesCgo for explicit ``import "C"`` cases; the
    # depends_on edge is an additional trigger.
    var ccppPackageSet: seq[string] = @[]
    for member in cCppCrossMembers:
      if member.package.len > 0 and
          ccppPackageSet.find(member.package) < 0:
        ccppPackageSet.add(member.package)
    if ccppPackageSet.len > 0:
      var rewritten: seq[GoDirectEmitTarget] = @[]
      for target in targets:
        var entry = target
        if entry.member.kind == gdmkExecutable and
            entry.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage == entry.member.package and
                ccppPackageSet.find(edge.toPackage) >= 0:
              entry.member.usesCgo = true
              break
        rewritten.add(entry)
      targets = rewritten

    # Union of every stdlib import across all PURE-GO members (i.e.
    # the M31 fast-path members; cgo + c-archive targets use ``go
    # build`` which resolves its own stdlib closure under GOCACHE).
    var stdlibUnion: seq[string] = @[]
    for target in targets:
      if target.member.usesCgo or target.member.cConsumable:
        continue
      for path in target.stdlibImports:
        if stdlibUnion.find(path) < 0:
          stdlibUnion.add(path)
    var stdlibArchives = initTable[string, string]()
    if stdlibUnion.len > 0:
      stdlibArchives = resolveStdlibArchives(goExe, projectRoot,
        stdlibUnion)

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]

      # M36 cross-language step 1: emit C/C++ upstream archives FIRST
      # so the cgo Go binary's go build can reference each archive's
      # output path + archive action id by the time we hand it to
      # emitCgoBuildAction. Index by owning package so a
      # ``depends_on goApp: cLibPkg`` edge resolves to "every C
      # library member of cLibPkg".
      var packageCCppLibraries =
        initTable[string, seq[GoDirectCCppUpstreamLibrary]]()
      for member in cCppCrossMembers:
        let bundle = emitCCppCrossMember(projectRoot, member)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.archive)
        let entry = GoDirectCCppUpstreamLibrary(
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

      # Pass 1: Go libraries. Pure-Go members route through the M31
      # ``go tool compile -pack`` path; cConsumable members route
      # through ``go build -buildmode=c-archive`` (M36 reverse).
      var packageLibraries =
        initTable[string, seq[GoDirectWorkspaceLibrary]]()
      var libraryByName = initTable[string, GoDirectWorkspaceLibrary]()
      for target in targets:
        if target.member.kind != gdmkLibraryStatic:
          continue
        if target.member.cConsumable:
          # M36 reverse direction: emit the c-archive build action.
          let gomod = emitGoModAction(projectRoot, target)
          allActions.add(gomod.action)
          let cArchiveAction = emitCArchiveBuildAction(
            projectRoot = projectRoot,
            goExe = goExe,
            target = target,
            gomodActionId = gomod.action.id,
            gomodPath = gomod.path)
          allActions.add(cArchiveAction)
          let archive = cArchivePathFor(projectRoot, target.member.name)
          let entry = GoDirectWorkspaceLibrary(
            libraryName: target.member.name,
            package: target.member.package,
            compileActionId: cArchiveAction.id,
            outputPath: archive,
            archiveDir: parentDir(archive),
            cConsumable: true)
          if target.member.package.len > 0:
            if not packageLibraries.hasKey(target.member.package):
              packageLibraries[target.member.package] = @[]
            packageLibraries[target.member.package].add(entry)
          libraryByName[target.member.name] = entry
          discard target(target.member.name, allActions)
          continue
        # M31 fast path: pure-Go library, ``go tool compile -pack``.
        let importcfgText = renderImportcfg(stdlibArchives,
          target.stdlibImports, target.workspaceImports, @[])
        let importcfg = emitImportcfgAction(projectRoot,
          target.member.name, importcfgText)
        allActions.add(importcfg.action)
        let compileAction = emitCompileAction(
          projectRoot = projectRoot,
          goExe = goExe,
          target = target,
          importcfgPath = importcfg.path,
          importcfgActionId = importcfg.action.id,
          depCompileActionIds = @[],
          depArchives = @[])
        allActions.add(compileAction)
        let archive = archivePathFor(projectRoot, target.member.name)
        let entry = GoDirectWorkspaceLibrary(
          libraryName: target.member.name,
          package: target.member.package,
          compileActionId: compileAction.id,
          outputPath: archive,
          archiveDir: parentDir(archive),
          cConsumable: false)
        if target.member.package.len > 0:
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        libraryByName[target.member.name] = entry
        discard target(target.member.name, allActions)

      # Pass 2: Go executables. Pure-Go members route through the M31
      # ``go tool compile`` + ``go tool link`` path; cgo members route
      # through ``go build`` (M36 forward).
      for target in targets:
        if target.member.kind != gdmkExecutable:
          continue
        # Resolve this executable's upstream library dep set: union
        # of (a) ``depends_on`` edges from its owning package and
        # (b) import-derived workspace imports (defensive — Mode 3
        # uses scanner-emitted edges, but a manual depends_on must
        # still wire). Skip cConsumable libs from the Go-to-Go path
        # — those are c-archives, not Go importable archives.
        var entryDeps: seq[GoDirectWorkspaceLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                if not lib.cConsumable and entryDeps.find(lib) < 0:
                  entryDeps.add(lib)
        for memberName in target.workspaceImports:
          if libraryByName.hasKey(memberName):
            let lib = libraryByName[memberName]
            if not lib.cConsumable and entryDeps.find(lib) < 0:
              entryDeps.add(lib)

        # Cgo executables: forward-direction C/C++ upstream archives.
        var entryCCppDeps: seq[GoDirectCCppUpstreamLibrary] = @[]
        if target.member.usesCgo and target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageCCppLibraries.hasKey(edge.toPackage):
              for cLib in packageCCppLibraries[edge.toPackage]:
                entryCCppDeps.add(cLib)

        if target.member.usesCgo:
          # M36 forward direction: cgo go build action. Pure-Go deps
          # are still possible (a cgo executable that also imports a
          # pure-Go sibling library); ``go build`` resolves those
          # automatically by scanning the source tree. We thread the
          # workspace library archive paths into ``inputs`` for
          # cache invalidation only.
          var depCompileActionIds: seq[string] = @[]
          var depArchivePaths: seq[string] = @[]
          for lib in entryDeps:
            depCompileActionIds.add(lib.compileActionId)
            depArchivePaths.add(lib.outputPath)
          var ccppArchiveDirs: seq[string] = @[]
          var ccppArchiveLibNames: seq[string] = @[]
          var ccppArchivePaths: seq[string] = @[]
          for cLib in entryCCppDeps:
            if depCompileActionIds.find(cLib.linkActionId) < 0:
              depCompileActionIds.add(cLib.linkActionId)
            if ccppArchiveDirs.find(cLib.nativeSearchDir) < 0:
              ccppArchiveDirs.add(cLib.nativeSearchDir)
            if ccppArchiveLibNames.find(cLib.libraryName) < 0:
              ccppArchiveLibNames.add(cLib.libraryName)
            ccppArchivePaths.add(cLib.outputPath)
          for p in depArchivePaths:
            if ccppArchivePaths.find(p) < 0:
              ccppArchivePaths.add(p)
          let gomod = emitGoModAction(projectRoot, target)
          allActions.add(gomod.action)
          let cgoAction = emitCgoBuildAction(
            projectRoot = projectRoot,
            goExe = goExe,
            target = target,
            gomodActionId = gomod.action.id,
            gomodPath = gomod.path,
            depArchiveDirs = ccppArchiveDirs,
            depArchiveLibNames = ccppArchiveLibNames,
            depArchivePaths = ccppArchivePaths,
            depCompileActionIds = depCompileActionIds)
          allActions.add(cgoAction)
          discard target(target.member.name, allActions)
          continue

        # M31 fast path: pure-Go executable.
        var depCompileActionIds: seq[string] = @[]
        var depArchiveDirs: seq[string] = @[]
        var depArchivePaths: seq[string] = @[]
        for lib in entryDeps:
          depCompileActionIds.add(lib.compileActionId)
          if depArchiveDirs.find(lib.archiveDir) < 0:
            depArchiveDirs.add(lib.archiveDir)
          depArchivePaths.add(lib.outputPath)

        let importcfgText = renderImportcfg(stdlibArchives,
          target.stdlibImports, target.workspaceImports, entryDeps)
        let importcfg = emitImportcfgAction(projectRoot,
          target.member.name, importcfgText)
        allActions.add(importcfg.action)

        let compileAction = emitCompileAction(
          projectRoot = projectRoot,
          goExe = goExe,
          target = target,
          importcfgPath = importcfg.path,
          importcfgActionId = importcfg.action.id,
          depCompileActionIds = depCompileActionIds,
          depArchives = depArchiveDirs)
        allActions.add(compileAction)

        let compileArchive = archivePathFor(projectRoot, target.member.name)
        let linkImportcfgText = renderLinkImportcfg(
          stdlibArchives, entryDeps,
          target.member.name, compileArchive)
        let linkImportcfg = emitLinkImportcfgAction(projectRoot,
          target.member.name, linkImportcfgText)
        allActions.add(linkImportcfg.action)

        let linkAction = emitLinkAction(
          projectRoot = projectRoot,
          goExe = goExe,
          target = target,
          compileActionId = compileAction.id,
          compileArchive = compileArchive,
          linkImportcfgPath = linkImportcfg.path,
          linkImportcfgActionId = linkImportcfg.action.id,
          depArchiveDirs = depArchiveDirs,
          depCompileActionIds = depCompileActionIds,
          depArchivePaths = depArchivePaths)
        allActions.add(linkAction)
        discard target(target.member.name, allActions)

      # M36 reverse cross-language: emit C/C++ executables LAST so
      # each binary's link can reference the upstream Go c-archive's
      # action id + output path. The depends_on edge map indexes the
      # cppApp's upstream Go libs by ``toPackage``; for each edge
      # whose ``toPackage`` resolved a Go library marked cConsumable
      # we thread the c-archive onto the C/C++ link.
      for exec in cCppCrossExecutables:
        var execGoUpstream: seq[GoDirectWorkspaceLibrary] = @[]
        if exec.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != exec.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for goLib in packageLibraries[edge.toPackage]:
                # Only c-archive (cConsumable) archives are linkable
                # from a C/C++ binary. A pure-Go ``.a`` carries Go-
                # only metadata + no C-resolvable symbols.
                if goLib.cConsumable:
                  execGoUpstream.add(goLib)
        let bundle = emitCCppCrossExecutable(projectRoot, exec,
          execGoUpstream)
        for a in bundle.compiles:
          allActions.add(a)
        allActions.add(bundle.link)
        discard target(exec.executableName, allActions)

      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc goDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registration order: AFTER ``go`` so a project carrying
  ## a ``go.mod`` routes through the Mode 2 convention; this convention
  ## picks up the no-go.mod case.
  LanguageConvention(
    name: "go-direct",
    recognize: goDirectRecognize,
    emitFragment: goDirectEmitFragment)
