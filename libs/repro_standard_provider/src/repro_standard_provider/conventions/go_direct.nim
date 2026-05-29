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
##     ``go_dep_scanner.resolveGoMemberDirs`` helper.
##   * ``go`` is on PATH at convention-emit time. We need the driver
##     for ``go tool compile`` / ``go tool link`` and for the one
##     ``go list -export`` invocation that materialises the stdlib
##     archive paths.
##   * No cgo (any ``import "C"`` line anywhere under the project root
##     forces the Mode 3 path off; cgo support is deferred to M36).
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
##   * Cgo deps — deferred to M36 (Go ↔ C cross-language). M31 keeps
##     rejecting any ``import "C"`` line at recognise time so the user
##     gets a clean miss instead of a partial build.
##   * ``-trimpath`` + reproducible-build flags — these come for free
##     with ``go tool compile`` but a future M can thread them
##     explicitly into the argv for byte-deterministic outputs.

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
      ## ``<root>/.repro/build/<name>/<name>.a``
    archiveDir: string
      ## Parent dir of ``outputPath``. Used as the downstream's ``-I``
      ## search path so the upstream archive resolves under its bare
      ## package name.

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

proc projectGoFilesHaveCgo(projectRoot: string): bool =
  ## Conservative cgo check: any ``import "C"`` line under the project
  ## root forces Mode 3 off (cgo proper is deferred to M36). Mirror of
  ## the Mode 2 ``go`` convention's same-named helper but inlined here
  ## so the two conventions don't import each other.
  if not dirExists(extendedPath(projectRoot)):
    return false
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    if not lower.endsWith(".go"):
      continue
    let filename = extractFilename(entry)
    if filename.toLowerAscii.startsWith("_cgo_") and lower.endsWith(".go"):
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

proc goDirectRecognize(projectRoot: string;
                       request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``go.mod`` at the workspace root (the Mode 2 Go
  ##     convention's territory).
  ##   * NO ``go.work`` (workspaces deferred).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``go``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Go source layout via
  ##     ``resolveGoMemberDirs``.
  ##   * No ``import "C"`` line anywhere under the project root (cgo
  ##     forces Mode 3 off; cgo is M36).
  ##   * ``go`` is on PATH at convention-emit time.
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
  if projectGoFilesHaveCgo(projectRoot):
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveGoMemberDirs(projectRoot, member.name)
    if resolved.srcDir.len > 0:
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
    dependencyPolicy = declaredOnlyDependencyPolicy(),
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
    dependencyPolicy = declaredOnlyDependencyPolicy(),
    commandStatsId = "go-direct.executable.link")

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
  ## Convention entry — enumerate members, validate Mode 3 dep edges,
  ## resolve stdlib archives, emit per-member compile + per-executable
  ## link actions via the DSL, hand the whole thing to
  ## ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractGoPackageUses(source)
    var members: seq[GoDirectMember] = @[]
    for member in allMembers:
      if not packageUsesGo(usesEntries, member.package, source):
        continue
      members.add(member)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "go-direct convention: no executable or library members " &
          "declared in " & projectFile)
    let goExe = goExecutable()
    if goExe.len == 0:
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
    validateWorkspaceDeps(depEdges, declaredPackages)

    # Union of every stdlib import across all members → single
    # ``go list -deps`` call to resolve GOCACHE archive paths.
    var stdlibUnion: seq[string] = @[]
    for target in targets:
      for path in target.stdlibImports:
        if stdlibUnion.find(path) < 0:
          stdlibUnion.add(path)
    let stdlibArchives = resolveStdlibArchives(goExe, projectRoot,
      stdlibUnion)

    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      # Pass 1: libraries. Each library member's compile produces the
      # archive downstream executables consume.
      var packageLibraries =
        initTable[string, seq[GoDirectWorkspaceLibrary]]()
      var libraryByName = initTable[string, GoDirectWorkspaceLibrary]()
      for target in targets:
        if target.member.kind != gdmkLibraryStatic:
          continue
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
          archiveDir: parentDir(archive))
        if target.member.package.len > 0:
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        libraryByName[target.member.name] = entry
        discard target(target.member.name, allActions)

      # Pass 2: executables. Each executable's compile consumes any
      # in-workspace libraries it imports (resolved via the
      # ``depends_on`` graph plus the import-derived workspace name
      # set); its link consumes the compile + every transitive
      # workspace library archive via importcfg.link.
      for target in targets:
        if target.member.kind != gdmkExecutable:
          continue
        # Resolve this executable's upstream library dep set: union
        # of (a) ``depends_on`` edges from its owning package and
        # (b) import-derived workspace imports (defensive — Mode 3
        # uses scanner-emitted edges, but a manual depends_on must
        # still wire).
        var entryDeps: seq[GoDirectWorkspaceLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                if entryDeps.find(lib) < 0:
                  entryDeps.add(lib)
        # Add libraries the scanner found via direct imports, in case
        # the depends_on edges don't catch them (e.g. user forgot to
        # run ``repro deps refresh``). This keeps the build sound even
        # when the scanned-deps file is stale.
        for memberName in target.workspaceImports:
          if libraryByName.hasKey(memberName):
            let lib = libraryByName[memberName]
            if entryDeps.find(lib) < 0:
              entryDeps.add(lib)

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
