## JavaScript / TypeScript (Mode 3 / no-package.json) language
## convention (Tier 2b).
##
## Mode 3 sibling of ``javascript_typescript.nim`` for projects whose
## ``repro.nim`` declares a JS/TS ``executable`` / ``library`` member
## AND DOES NOT ship a ``package.json`` / ``tsconfig.json`` / any
## bundler config (``vite.config.*``, ``webpack.config.*``,
## ``rollup.config.*``, etc.) at the workspace root. The convention
## builds the per-package bundle graph from pure layout — no npm
## install, no tsc, no lockfile.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M33 section of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``javascript_typescript``):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``node`` or ``typescript``.
##   * NO ``<projectRoot>/package.json`` (the Mode 2 JS/TS convention
##     would have matched FIRST — registration order is defensive in
##     either direction).
##   * NO ``<projectRoot>/tsconfig.json`` (tsconfig presence implies the
##     user is curating the TS surface; route through Mode 2).
##   * NO bundler config (``vite.config.*``, ``webpack.config.*``,
##     ``rollup.config.*``, ``parcel.config.*``, ``next.config.*``,
##     ``nuxt.config.*``) at the workspace root (those force Mode 2's
##     Mode B fallback).
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty JS/TS source layout via the M33
##     ``jsts_dep_scanner.resolveJsTsMemberDirs`` helper.
##   * ``node`` is on PATH at convention-emit time. We need the
##     interpreter as the launcher's payload command. The bundler
##     (``esbuild``) is resolved at apply time via ``npx --yes``; we do
##     NOT require it at recognise time.
##
## **Layout** (per ``resolveJsTsMemberDirs``):
##
##   Layout B-src — per-member ``src/`` (canonical multi-package shape;
##                  idiomatic JS/TS)::
##
##       <projectRoot>/<member>/src/index.ts        (library entry)
##       <projectRoot>/<member>/src/main.ts         (executable entry)
##
##   Layout B-flat — per-member without ``src/`` (compact shape)::
##
##       <projectRoot>/<member>/index.ts
##       <projectRoot>/<member>/main.ts
##
##   Layout A      — single-package project::
##
##       <projectRoot>/src/<member>.ts
##
## **Per-member action graph**:
##
## | Member kind  | Actions                                                 |
## |--------------|---------------------------------------------------------|
## | library      | (no actions — the executable's esbuild bundle reads     |
## |              |  the library's sources directly via --alias.)           |
## | executable   | (1) ``esbuild --bundle <entry> --alias:<lib>=<lib-src>``|
## |              |     ``--platform=node --format=esm --outfile=<out.js>`` |
## |              | (2) ``fs.writeText`` wrapper script                     |
## |              |     ``<root>/.repro/build/<name>/<name>(.cmd)``         |
##
## **Why no per-library compile action?** esbuild's bundler can read
## TypeScript and JavaScript source files directly, transpile them on
## the fly, and inline them into a single self-contained ``.js`` file.
## Per-library compile actions would add ceremony (a staging dir per
## library, plus the bundle action's ``--alias`` would need to point
## at the staged outputs instead of the source tree) for zero
## additional functionality. The trade-off is that the executable's
## bundle action's ``inputs`` MUST include every upstream library's
## sources for cache invalidation; we enumerate those explicitly at
## emit time.
##
## The wrapper script:
##   * Invokes ``node <bundled.js>`` with the caller's argv passed
##     through. The bundle is self-contained ESM (``--format=esm``)
##     so no module-resolution machinery is needed at runtime.
##
## **Output schema**:
##
##   * Library: NO outputs at workspace root. The library's sources
##     are consumed by every downstream executable's bundle action.
##   * Executable: ``<root>/.repro/build/<name>/<name>.js`` (the
##     bundled output) PLUS the wrapper at
##     ``<root>/.repro/build/<name>/<name>.cmd`` (Windows) or
##     ``<root>/.repro/build/<name>/<name>`` (POSIX).
##
## **Dep wiring**:
##
## A ``depends_on calc: mathlib`` edge turns into:
##   * The calc bundle action's argv carries
##     ``--alias:mathlib=<mathlib-src-dir>/<entry-basename>`` so
##     ``import { add } from "mathlib"`` resolves to the library's
##     entry file at bundle time.
##   * The calc bundle action declares every recursive ``.ts``/``.js``
##     file under the mathlib source dir as ``inputs`` so a change to
##     any of them invalidates the bundle's cache.
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * External npm packages (anything not in-workspace). Mode 3 is
##     in-workspace only; users with external deps write a
##     ``package.json`` and let the Mode 2 convention drive the build.
##   * ``tsconfig.json`` user config — the convention emits sensible
##     esbuild defaults (``--platform=node --format=esm``, target
##     ES2022) and ignores any tsconfig.
##   * Test discovery (``*.test.ts``) — deferred; mirror of Mode 2's
##     test-target staging.
##   * Watch mode / dev server — out of scope (Reprobuild's domain is
##     reproducible builds, not interactive dev).
##   * JSX / React — deferred; React projects almost always ship a
##     ``package.json`` and route through Mode 2.
##   * CommonJS-only packages — best-effort via esbuild; documented
##     edge cases.
##   * Source maps — deferred (esbuild can emit them via
##     ``--sourcemap`` but the M33 surface keeps the action graph
##     minimal).
##   * Console-script binary entries (``"bin"`` map) — deferred. M33
##     commits to ``main.ts`` / ``main.js`` as the executable entry
##     shape; the explicit-bin-entry surface is a future addition.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Identical to the Mode 2 JS/TS convention's scratch dir so the
    ## two conventions produce co-located outputs and ``repro clean``
    ## finds both. The Mode 3 convention is registered AFTER
    ## ``javascript_typescript``, so the scratch path stays stable
    ## when a project flips between package.json and Mode 3.

  EsbuildVersion* = "0.24.0"
    ## Pinned esbuild version. Matches the Mode 2 convention's
    ## ``emitEsbuildAction`` pin so the same bundler is used regardless
    ## of how a project routes. The version pin keeps bundle bytes
    ## stable across machines.

  ## Bundler / TypeScript / Mode 2 markers — when any of these are
  ## present at the workspace root, the project routes through the
  ## Mode 2 JS/TS convention instead of Mode 3.
  Mode2ConfigFiles* = [
    "package.json",
    "tsconfig.json",
    "vite.config.js", "vite.config.mjs", "vite.config.cjs",
    "vite.config.ts", "vite.config.mts",
    "webpack.config.js", "webpack.config.mjs", "webpack.config.cjs",
    "webpack.config.ts",
    "rollup.config.js", "rollup.config.mjs", "rollup.config.cjs",
    "rollup.config.ts",
    "next.config.js", "next.config.mjs", "next.config.cjs",
    "next.config.ts",
    "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.ts",
    "parcel.config.js", "parcel.config.json",
    "turbo.json",
    "nx.json",
    "lerna.json",
  ]

type
  JsTsDirectMemberKind = enum
    jdmkExecutable
    jdmkLibrary

  JsTsDirectMember = object
    name: string
    kind: JsTsDirectMemberKind
    package: string  ## Owning ``package <name>:`` block (Mode 3).

  JsTsDirectEmitTarget = object
    member: JsTsDirectMember
    srcDir: string
      ## Source dir holding the entry file.
    entrySource: string
      ## Path to the entry file (one of ``index.{ts,tsx,js,mjs,cjs}``
      ## or ``main.{ts,tsx,js,mjs,cjs}``).
    sourceFiles: seq[string]
      ## Every JS/TS source file under ``srcDir`` (recursive). Drives
      ## the bundle action's inputs for cache invalidation.
    workspaceImports: seq[string]
      ## In-workspace package names imported by this member's sources
      ## (the scanner-extracted dep heads, filtered against the
      ## workspace member set). Used at emit time to compose the
      ## bundle action's ``--alias:<lib>=<lib-src>`` flags.

  JsTsDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the Python / Go / Rust Mode 3 conventions' same-named record.
    libraryName: string
    package: string
    entrySource: string
      ## Path to the library's entry file. The downstream bundle
      ## action passes ``--alias:<libraryName>=<entrySource>`` so the
      ## library's bare specifier resolves to the entry at bundle time.
    sourceFiles: seq[string]
      ## Every ``.ts`` / ``.js`` file under the library's source dir;
      ## landed on each downstream bundle action's ``inputs`` for
      ## cache invalidation.

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesJsTs(source: string): bool =
  ## True when the ``uses:`` block names ``node`` or ``typescript``.
  ## Mirrors the Mode 2 convention's same-named helper.
  if source.len == 0:
    return false
  var sawJsTs = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "node" or token == "typescript":
      sawJsTs = true
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
  sawJsTs

type
  JsTsDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumeJsTsUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractJsTsPackageUses(source: string): seq[JsTsDirectPackageUses] =
  ## Local mirror of the C/C++ / Rust / Go / Python Mode 3 conventions'
  ## ``extract*PackageUses``. Used for cross-language filtering so this
  ## convention only emits actions for the JS/TS-using packages in a
  ## mixed workspace.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(JsTsDirectPackageUses(
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
        consumeJsTsUsesToken(currentTokens, raw)
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
          consumeJsTsUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesJsTs(usesEntries: openArray[JsTsDirectPackageUses];
                     package, source: string): bool =
  if package.len == 0:
    return usesIncludesJsTs(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "node" or token == "typescript":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[JsTsDirectMember] =
  ## Walk ``source`` text and emit ``JsTsDirectMember`` rows with the
  ## owning ``package <name>:`` block. Mirror of the Python convention's
  ## same-named helper.
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
        result.add(JsTsDirectMember(
          name: name, kind: jdmkExecutable,
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
        result.add(JsTsDirectMember(
          name: name, kind: jdmkLibrary,
          package: currentPackage))
      continue

proc hasMode2Marker(projectRoot: string): bool =
  ## True when any Mode 2 / bundler config file is present at the
  ## workspace root. Routes the project through Mode 2 instead.
  for name in Mode2ConfigFiles:
    if fileExists(extendedPath(projectRoot / name)):
      return true
  false

proc nodeExecutable(): string =
  findExe("node")

proc npxExecutable(): string =
  findExe("npx")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc collectMemberSources(srcDir: string): seq[string] =
  ## Every JS/TS source file under ``srcDir`` recursively, sorted for
  ## determinism. Skips ``node_modules`` / ``dist`` / ``.repro`` /
  ## ``__pycache__`` subdirs.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for path in walkDirRec(srcDir):
    let normalised = path.replace('\\', '/')
    if "/node_modules/" in normalised:
      continue
    if "/dist/" in normalised:
      continue
    if "/.repro/" in normalised:
      continue
    if "/__pycache__/" in normalised:
      continue
    if isJsTsSourceFile(path):
      result.add(path)
  result.sort(system.cmp[string])

proc collectMemberImports(sources: openArray[string];
                          memberName: string;
                          memberOwnPackage: string;
                          ownerToWorkspacePackage: Table[string, string]):
                            seq[string] =
  ## Walk every source under the member's dir and extract the
  ## in-workspace import head set. Node-builtin + external imports are
  ## dropped (mirror of the scanner's edge-emit policy).
  var workspaceSet: seq[string] = @[]
  for srcPath in sources:
    let text =
      try:
        readFile(extendedPath(srcPath))
      except CatchableError:
        continue
    for importRef in extractJsTsImportRefs(text):
      let head = importRef.head
      if head.len == 0:
        continue
      if isNodeBuiltinModule(head):
        continue
      if head == memberName:
        continue
      if ownerToWorkspacePackage.hasKey(head):
        let owner = ownerToWorkspacePackage[head]
        if owner == memberOwnPackage:
          continue
        if workspaceSet.find(head) < 0:
          workspaceSet.add(head)
  workspaceSet.sort(system.cmp[string])
  workspaceSet

proc resolveTarget(projectRoot: string; member: JsTsDirectMember;
                   workspaceNameIndex: Table[string, string]):
    JsTsDirectEmitTarget =
  result.member = member
  let resolved = resolveJsTsMemberDirs(projectRoot, member.name)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectMemberSources(resolved.srcDir)
  result.workspaceImports = collectMemberImports(result.sourceFiles,
    member.name, member.package, workspaceNameIndex)

proc projectFileForRoot(projectRoot: string): string =
  let projectMatch = resolveProjectFile(projectRoot)
  if projectMatch.path.len > 0: projectMatch.path
  else: projectRoot / LegacyProjectFileName

proc jsTsDirectRecognize(projectRoot: string;
                         request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``package.json`` / ``tsconfig.json`` / bundler config at
  ##     the workspace root (the Mode 2 JS/TS convention's territory).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``node`` / ``typescript``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty JS/TS source layout via
  ##     ``resolveJsTsMemberDirs``.
  ##   * ``node`` is on PATH at convention-emit time.
  if hasMode2Marker(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesJsTs(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if nodeExecutable().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolveJsTsMemberDirs(projectRoot, member.name)
    if resolved.srcDir.len > 0:
      atLeastOneResolved = true
      break
  atLeastOneResolved

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc bundleOutputFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / (member & ".js")

proc bundleMetafileFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / (member & ".js.meta.json")

proc wrapperPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".cmd")
  else:
    scratchPathFor(projectRoot, member) / member

# ----------------------------------------------------------------------
# Workspace dep edge handling — same shape as the c-cpp-direct /
# rust-direct / go-direct / python-direct conventions. Mode 3 dep
# validation runs over the union of ``depends_on`` lines from
# ``repro.nim`` + ``repro.scanned-deps.nim``.
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
        "jsts-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "jsts-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "jsts-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[JsTsDirectMember]): PackageDef =
  var name = "jsts_direct_convention"
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

# ----------------------------------------------------------------------
# Action emission.
# ----------------------------------------------------------------------

proc emitBundleAction(projectRoot, npxExe: string;
                      target: JsTsDirectEmitTarget;
                      upstreamLibs: openArray[JsTsDirectWorkspaceLibrary]):
                        BuildActionDef =
  ## ``esbuild --bundle <entry> --alias:<lib>=<lib-src-entry> ...
  ## --platform=node --format=esm --outfile=<out.js>``. Bundles the
  ## executable's entry + every transitive in-workspace library import
  ## into a single self-contained ``.js`` file.
  ##
  ## Routed through ``npx --yes --package esbuild@<EsbuildVersion>``
  ## so the convention works without a pre-installed ``node_modules/``.
  ## npx downloads the pinned esbuild into ``~/.npm/_npx/...`` on
  ## first use; subsequent runs hit the npx cache.
  ##
  ## ``--alias:<bare>=<path>`` lets esbuild's resolver redirect bare
  ## specifiers (``"mathlib"``) to file paths (``<root>/mathlib/src/
  ## index.ts``) without requiring ``package.json`` exports maps. The
  ## ``--platform=node`` switch keeps Node builtins external (no
  ## shimming fs/path/etc. into the bundle). ``--format=esm`` matches
  ## modern Node's preferred shape.
  let outFile = bundleOutputFor(projectRoot, target.member.name)
  let metafile = bundleMetafileFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(outFile)))

  var argv = @[
    npxExe,
    "--yes",
    "--package", "esbuild@" & EsbuildVersion,
    "esbuild",
    "--bundle",
    target.entrySource,
    "--platform=node",
    "--format=esm",
    "--target=es2022",
    "--outfile=" & outFile,
    "--metafile=" & metafile,
  ]
  # Add aliases for every upstream library — sort by library name for
  # determinism so the bundle action's fingerprint is stable across
  # emits.
  var sortedLibs: seq[JsTsDirectWorkspaceLibrary] = @[]
  for lib in upstreamLibs:
    sortedLibs.add(lib)
  sortedLibs.sort(proc (a, b: JsTsDirectWorkspaceLibrary): int =
    cmp(a.libraryName, b.libraryName))
  for lib in sortedLibs:
    argv.add("--alias:" & lib.libraryName & "=" & lib.entrySource)

  var inputs: seq[string] = @[target.entrySource]
  for src in target.sourceFiles:
    if inputs.find(src) < 0:
      inputs.add(src)
  for lib in sortedLibs:
    if inputs.find(lib.entrySource) < 0:
      inputs.add(lib.entrySource)
    for src in lib.sourceFiles:
      if inputs.find(src) < 0:
        inputs.add(src)

  buildAction(
    id = "jsts-direct-bundle-" & sanitizeNamePart(target.member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @[],
    inputs = inputs,
    outputs = @[outFile, metafile],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "jsts-direct.esbuild-bundle")

proc renderWrapperScript(nodeExe, bundlePath: string): string =
  ## Build the wrapper script content. The wrapper is the load-bearing
  ## artefact of an executable member; running it directly should
  ## produce the program's output regardless of the caller's CWD or
  ## environment.
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    lines.add("\"" & nodeExe & "\" \"" & bundlePath.replace('/', '\\') &
      "\" %*")
    return lines.join("\r\n") & "\r\n"
  else:
    var lines: seq[string] = @[]
    lines.add("#!/usr/bin/env sh")
    lines.add("exec \"" & nodeExe & "\" \"" & bundlePath & "\" \"$@\"")
    return lines.join("\n") & "\n"

proc emitWrapperAction(projectRoot, nodeExe: string;
                       target: JsTsDirectEmitTarget;
                       bundleActionId: string;
                       bundlePath: string):
                         tuple[action: BuildActionDef; wrapperPath: string] =
  ## ``fs.writeText`` action that materialises the wrapper script.
  ## Sequenced strictly after the bundle action so the wrapper's
  ## payload (the bundled ``.js`` file) is guaranteed to exist at the
  ## moment of the launcher's first invocation.
  let wrapperPath = wrapperPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(wrapperPath)))
  let script = renderWrapperScript(nodeExe, bundlePath)
  let action = fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "jsts-direct-wrapper-" & sanitizeNamePart(target.member.name),
    deps = [bundleActionId],
    commandStatsId = "jsts-direct.executable.wrapper")
  (action, wrapperPath)

proc jsTsDirectEmitFragment(projectRoot: string;
                            request: ProviderGraphRequest):
                              GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members, validate Mode 3 dep edges,
  ## emit per-executable esbuild bundle + wrapper actions via the DSL,
  ## hand the whole thing to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractJsTsPackageUses(source)
    var members: seq[JsTsDirectMember] = @[]
    for member in allMembers:
      if not packageUsesJsTs(usesEntries, member.package, source):
        continue
      members.add(member)
    if members.len == 0:
      raise newException(ValueError,
        "jsts-direct convention: no executable or library members " &
          "declared in " & projectFileForRoot(projectRoot))
    let nodeExe = nodeExecutable()
    if nodeExe.len == 0:
      raise newException(ValueError,
        "jsts-direct convention: 'node' not on PATH; cannot emit the " &
          "wrapper script")
    let npxExe = npxExecutable()
    if npxExe.len == 0:
      raise newException(ValueError,
        "jsts-direct convention: 'npx' not on PATH; cannot drive the " &
          "esbuild bundle (npx ships with node — re-source env.ps1)")

    # Build the workspace-name → owner-package index used by import
    # resolution at emit time.
    var workspaceNameIndex = initTable[string, string]()
    for member in members:
      if member.name.len > 0:
        workspaceNameIndex[member.name] = member.package
      if member.package.len > 0 and
          not workspaceNameIndex.hasKey(member.package):
        workspaceNameIndex[member.package] = member.package

    var targets: seq[JsTsDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member, workspaceNameIndex)
      if target.srcDir.len == 0:
        raise newException(ValueError,
          "jsts-direct convention: no JS/TS source dir resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & member.name & "/src/{index,main}.{ts,tsx,js,mjs,cjs}, " &
            "<root>/" & member.name & "/{index,main}.{ts,tsx,js,mjs,cjs}, " &
            "<root>/src/" & member.name & ".{ts,tsx,js,mjs,cjs})")
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
      # Pass 1: libraries. No actions emitted — the library's sources
      # are consumed by every downstream executable's bundle action.
      # We just record the library's metadata for downstream lookup.
      var packageLibraries =
        initTable[string, seq[JsTsDirectWorkspaceLibrary]]()
      var libraryByName = initTable[string, JsTsDirectWorkspaceLibrary]()
      for target in targets:
        if target.member.kind != jdmkLibrary:
          continue
        let entry = JsTsDirectWorkspaceLibrary(
          libraryName: target.member.name,
          package: target.member.package,
          entrySource: target.entrySource,
          sourceFiles: target.sourceFiles)
        if target.member.package.len > 0:
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        libraryByName[target.member.name] = entry
        # Register an empty per-member target so ``repro build .#<name>``
        # against a library member is a no-op rather than a hard error.
        discard target(target.member.name, @[])

      # Pass 2: executables. Each executable's esbuild bundle pulls in
      # the entry + every upstream library's sources directly via
      # ``--alias`` + the inputs list.
      for target in targets:
        if target.member.kind != jdmkExecutable:
          continue
        # Resolve this executable's upstream library dep set: union
        # of (a) ``depends_on`` edges from its owning package and
        # (b) import-derived workspace imports.
        var entryDeps: seq[JsTsDirectWorkspaceLibrary] = @[]
        if target.member.package.len > 0:
          for edge in depEdges:
            if edge.fromPackage != target.member.package:
              continue
            if packageLibraries.hasKey(edge.toPackage):
              for lib in packageLibraries[edge.toPackage]:
                if entryDeps.find(lib) < 0:
                  entryDeps.add(lib)
        for memberName in target.workspaceImports:
          if libraryByName.hasKey(memberName):
            let lib = libraryByName[memberName]
            if entryDeps.find(lib) < 0:
              entryDeps.add(lib)

        let bundleAction = emitBundleAction(projectRoot, npxExe,
          target, entryDeps)
        allActions.add(bundleAction)
        let bundlePath = bundleOutputFor(projectRoot, target.member.name)
        let wrapperResult = emitWrapperAction(
          projectRoot = projectRoot,
          nodeExe = nodeExe,
          target = target,
          bundleActionId = bundleAction.id,
          bundlePath = bundlePath)
        allActions.add(wrapperResult.action)
        discard target(target.member.name, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc jsTsDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registration order: AFTER ``javascript_typescript`` so a
  ## project carrying a ``package.json`` routes through the Mode 2
  ## convention; this convention picks up the no-package.json case.
  LanguageConvention(
    name: "jsts-direct",
    recognize: jsTsDirectRecognize,
    emitFragment: jsTsDirectEmitFragment)
