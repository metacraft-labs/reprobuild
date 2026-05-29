## Python (Mode 3 / no-pyproject.toml) language convention (Tier 2b).
##
## Mode 3 sibling of ``python.nim`` for projects whose ``repro.nim``
## declares a Python ``executable`` / ``library`` member AND DOES NOT
## ship a ``pyproject.toml`` (or legacy ``setup.py``) at the workspace
## root. The convention builds the per-package staging + byte-compile
## graph from pure layout — no PEP 517 backend, no wheel, no
## installer.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 3"
## and the M32 section of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## **Recognition** (registered AFTER ``python``):
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists ``python3`` or ``python``.
##   * NO ``<projectRoot>/pyproject.toml`` (the Mode 2 Python convention
##     would have matched FIRST — registration order is defensive in
##     either direction).
##   * NO ``<projectRoot>/setup.py`` (legacy setuptools manifest — also
##     a Mode 2 / wheel-build trigger).
##   * At least one ``executable`` / ``library`` member resolves to a
##     non-empty Python package layout via the M32 ``python_dep_scanner``
##     ``resolvePythonMemberDirs`` helper.
##   * ``python3`` (or ``python``) is on PATH at convention-emit time.
##     We need the interpreter for the byte-compile action and as the
##     launcher's payload command.
##
## **Layout** (per ``resolvePythonMemberDirs``):
##
##   Layout B-flat — multiple packages per project file (canonical
##                   Mode 3 multi-package shape; the simplest)::
##
##       <projectRoot>/<member>/<member>/__init__.py
##
##   Layout B-src  — per-member ``src/`` (matches Python's src-layout)::
##
##       <projectRoot>/<member>/src/<member>/__init__.py
##
##   Layout A      — single-package project file::
##
##       <projectRoot>/src/<member>/__init__.py
##       <projectRoot>/<member>/__init__.py
##
## **Per-member action graph**:
##
## | Member kind  | Actions                                                 |
## |--------------|---------------------------------------------------------|
## | library      | (1) ``fs.preserveTree`` stage package dir →             |
## |              |     ``<root>/.repro/build/<name>/<name>/`` (sources)    |
## |              | (2) ``python -m compileall`` byte-compile staged tree   |
## | executable   | (1) ``fs.preserveTree`` stage package dir → same        |
## |              | (2) ``python -m compileall`` byte-compile staged tree   |
## |              | (3) ``fs.writeText`` wrapper script                     |
## |              |     ``<root>/.repro/build/<name>/<name>(.cmd)``         |
##
## The wrapper script:
##   * Sets ``PYTHONPATH`` to a ``;``-separated (Windows) or
##     ``:``-separated (POSIX) list of every upstream library's
##     staging dir PLUS this member's own staging dir. The staging
##     dir is the *parent* of the package's directory (so the
##     ``<name>/__init__.py`` package is importable by its bare name
##     from PYTHONPATH).
##   * Invokes ``python -m <name>`` (the executable member's package
##     MUST define ``<name>/__main__.py`` — this is the simplest
##     entry-point shape Python supports and the one M32 commits to).
##
## **Output schema**:
##
##   * Library: ``<root>/.repro/build/<name>/<name>/__init__.py`` +
##     siblings, with adjacent ``.pyc`` byte-code files written by the
##     compileall action.
##   * Executable: as above PLUS the wrapper at
##     ``<root>/.repro/build/<name>/<name>.cmd`` (Windows) or
##     ``<root>/.repro/build/<name>/<name>`` (POSIX).
##
## **Dep wiring**:
##
## A ``depends_on calc: mathlib`` edge turns into:
##   * The calc executable's wrapper PYTHONPATH includes mathlib's
##     staging dir (so ``from mathlib import add`` resolves at runtime).
##   * The calc wrapper-emit action declares the mathlib byte-compile
##     action id in ``deps`` for sequencing, and the mathlib staging
##     dir's stamp on its inputs for cache invalidation.
##
## **Out of scope for this milestone (documented as deferred)**:
##
##   * PyPI / external deps. Mode 3 is in-workspace only; users with
##     external deps write a ``pyproject.toml`` and let the Mode 2
##     convention drive the build.
##   * PEP 420 namespace packages (no ``__init__.py``). The convention
##     requires ``__init__.py`` for member discovery.
##   * Dynamic imports (``importlib.import_module``). The scanner is
##     blind to them; users add manual ``depends_on`` edges.
##   * pytest discovery and a ``#test`` target — deferred. Mode 2
##     graduates test discovery in a separate sibling milestone; the
##     Mode 3 surface mirrors that staging.
##   * Native extensions (Cython / C extensions). Mode 2 (maturin /
##     scikit-build-core) handles these.
##   * Console-script entry points (``[project.scripts]``-style
##     ``pkg.module:func`` entries). M32 commits to ``__main__.py`` as
##     the executable shape; the explicit entry-point surface is a
##     future addition.
##   * Virtualenv management. The convention assumes the dev-deps
##     ``python3`` is the one on PATH; per-member venvs are NOT
##     created.

import std/[algorithm, os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Identical to the Mode 2 Python convention's scratch dir so the
    ## two conventions produce co-located outputs and ``repro clean``
    ## finds both. The Mode 3 convention is registered AFTER
    ## ``python``, so the scratch path stays stable when a project
    ## flips between pyproject.toml and Mode 3.

  EntryModuleFile* = "__main__.py"
    ## Filename Mode 3 expects in an executable member's package dir
    ## so ``python -m <name>`` works. M32 commits to ``__main__.py`` as
    ## the single supported entry shape — it's the simplest Python
    ## convention (the same one ``python -m pip``, ``python -m
    ## venv``, etc use). Custom entry points (``pkg.module:func``)
    ## are a future addition.

type
  PythonDirectMemberKind = enum
    pdmkExecutable
    pdmkLibrary

  PythonDirectMember = object
    name: string
    kind: PythonDirectMemberKind
    package: string  ## Owning ``package <name>:`` block (Mode 3).

  PythonDirectEmitTarget = object
    member: PythonDirectMember
    pkgDir: string
      ## Source dir holding the package's ``__init__.py``.
    entrySource: string
      ## Path to ``__init__.py``. Used as the canonical input for
      ## diagnostics.
    sourceFiles: seq[string]
      ## Every ``.py`` file under ``pkgDir`` (recursive). Drives the
      ## staging action's inputs and the byte-compile's per-file
      ## output set.
    workspaceImports: seq[string]
      ## In-workspace package names imported by this member's sources
      ## (the scanner-extracted dep heads, filtered against the
      ## workspace member set). Used at emit time to compose the
      ## wrapper's PYTHONPATH from upstream staging dirs.

  PythonDirectWorkspaceLibrary = object
    ## Emitted-library bookkeeping for Mode 3 dep wiring. Mirror of
    ## the C/C++ / Rust / Go Mode 3 conventions' same-named record.
    libraryName: string
    package: string
    byteCompileActionId: string
      ## Action id of the byte-compile action; downstream wrappers
      ## sequence on this id so the staged tree exists before the
      ## wrapper resolves PYTHONPATH at runtime.
    stagingDir: string
      ## ``<root>/.repro/build/<name>``. This is the directory ABOVE
      ## the package dir; we add it to PYTHONPATH so ``import <name>``
      ## resolves to ``<stagingDir>/<name>/__init__.py``.
    packageDirOutput: string
      ## The staged package's ``__init__.py`` (used as the upstream's
      ## stamp on a downstream's inputs for cache invalidation).

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesPython(source: string): bool =
  ## True when the ``uses:`` block names ``python3`` or ``python``.
  ## Mode 3 intentionally accepts both spellings, matching the Mode 2
  ## convention's same-named helper.
  if source.len == 0:
    return false
  var sawPython = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "python3" or token == "python":
      sawPython = true
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
  sawPython

type
  PythonDirectPackageUses = object
    package: string
    tokens: seq[string]

proc consumePythonUsesToken(tokens: var seq[string]; token: string) =
  let trimmed = token.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
  if trimmed.len == 0:
    return
  let firstToken = trimmed.split({' ', '\t', '>', '<', '='})[0]
  if firstToken.len == 0:
    return
  if tokens.find(firstToken) < 0:
    tokens.add(firstToken)

proc extractPythonPackageUses(source: string): seq[PythonDirectPackageUses] =
  ## Local mirror of the C/C++ / Rust / Go Mode 3 conventions'
  ## ``extract*PackageUses``. Used for cross-language filtering so this
  ## convention only emits actions for the ``python``-using packages
  ## in a mixed workspace.
  var currentPackage = ""
  var packageColumn = -1
  var currentTokens: seq[string] = @[]
  var inUsesBlock = false
  var usesColumn = -1
  template flushPackage() =
    if currentPackage.len > 0:
      result.add(PythonDirectPackageUses(
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
        consumePythonUsesToken(currentTokens, raw)
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
          consumePythonUsesToken(currentTokens, raw)
      continue
  flushPackage()

proc packageUsesPython(usesEntries: openArray[PythonDirectPackageUses];
                       package, source: string): bool =
  if package.len == 0:
    return usesIncludesPython(source)
  for entry in usesEntries:
    if entry.package != package:
      continue
    for token in entry.tokens:
      if token == "python3" or token == "python":
        return true
    return false
  false

proc extractMembersWithOwnership(source: string): seq[PythonDirectMember] =
  ## Walk ``source`` text and emit ``PythonDirectMember`` rows with
  ## the owning ``package <name>:`` block. Mirror of the C/C++ / Rust /
  ## Go conventions' same-named helper.
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
        result.add(PythonDirectMember(
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
        result.add(PythonDirectMember(
          name: name, kind: pdmkLibrary,
          package: currentPackage))
      continue

proc hasPyprojectToml(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "pyproject.toml"))

proc hasSetupPy(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "setup.py"))

proc pythonExecutable(): string =
  let py3 = findExe("python3")
  if py3.len > 0:
    return py3
  findExe("python")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc collectMemberPySources(pkgDir: string): seq[string] =
  ## Every ``.py`` file under ``pkgDir`` recursively, sorted for
  ## determinism. Skips ``__pycache__`` directories.
  if not dirExists(extendedPath(pkgDir)):
    return @[]
  for path in walkDirRec(pkgDir):
    let normalised = path.replace('\\', '/')
    if "/__pycache__/" in normalised:
      continue
    if path.toLowerAscii.endsWith(".py"):
      result.add(path)
  result.sort(system.cmp[string])

proc collectMemberImports(sources: openArray[string];
                          memberName: string;
                          memberOwnPackage: string;
                          ownerToWorkspacePackage: Table[string, string]):
                            seq[string] =
  ## Walk every source under the member's package dir and extract the
  ## in-workspace import head set. Stdlib + third-party imports are
  ## dropped (mirror of the scanner's edge-emit policy).
  var workspaceSet: seq[string] = @[]
  for srcPath in sources:
    let text =
      try:
        readFile(extendedPath(srcPath))
      except CatchableError:
        continue
    for importRef in extractPythonImportRefs(text):
      let head = importRef.head
      if head.len == 0:
        continue
      if isPythonStdlibModule(head):
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

proc resolveTarget(projectRoot: string; member: PythonDirectMember;
                   workspaceNameIndex: Table[string, string]):
    PythonDirectEmitTarget =
  result.member = member
  let resolved = resolvePythonMemberDirs(projectRoot, member.name)
  if resolved.pkgDir.len == 0:
    return
  result.pkgDir = resolved.pkgDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectMemberPySources(resolved.pkgDir)
  result.workspaceImports = collectMemberImports(result.sourceFiles,
    member.name, member.package, workspaceNameIndex)

proc projectFileForRoot(projectRoot: string): string =
  let projectMatch = resolveProjectFile(projectRoot)
  if projectMatch.path.len > 0: projectMatch.path
  else: projectRoot / LegacyProjectFileName

proc executableHasMainModule(target: PythonDirectEmitTarget): bool =
  ## True when the executable member's package dir contains
  ## ``__main__.py`` (the M32 supported entry-point shape).
  if target.member.kind != pdmkExecutable:
    return true
  if target.pkgDir.len == 0:
    return false
  fileExists(extendedPath(target.pkgDir / EntryModuleFile))

proc pythonDirectRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract:
  ##   * NO ``pyproject.toml`` at the workspace root (the Mode 2 Python
  ##     convention's territory).
  ##   * NO ``setup.py`` (legacy setuptools manifest — also Mode 2).
  ##   * ``repro.nim`` (or legacy ``reprobuild.nim``) exists AND
  ##     ``uses:`` names ``python3`` / ``python``.
  ##   * at least one ``executable`` / ``library`` member is declared
  ##     AND resolves to a non-empty Python package layout via
  ##     ``resolvePythonMemberDirs``.
  ##   * ``python3`` (or ``python``) is on PATH at convention-emit
  ##     time.
  if hasPyprojectToml(projectRoot):
    return false
  if hasSetupPy(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesPython(source):
    return false
  let members = extractMembersWithOwnership(source)
  if members.len == 0:
    return false
  if pythonExecutable().len == 0:
    return false
  var atLeastOneResolved = false
  for member in members:
    let resolved = resolvePythonMemberDirs(projectRoot, member.name)
    if resolved.pkgDir.len > 0:
      atLeastOneResolved = true
      break
  atLeastOneResolved

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc stagingDirFor(projectRoot, member: string): string =
  ## Parent of the staged package dir. This is what we add to
  ## PYTHONPATH so ``import <member>`` resolves to
  ## ``<stagingDir>/<member>/__init__.py``.
  scratchPathFor(projectRoot, member)

proc stagedPackageDirFor(projectRoot, member: string): string =
  stagingDirFor(projectRoot, member) / member

proc stagedInitFileFor(projectRoot, member: string): string =
  stagedPackageDirFor(projectRoot, member) / "__init__.py"

proc wrapperPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".cmd")
  else:
    scratchPathFor(projectRoot, member) / member

# ----------------------------------------------------------------------
# Workspace dep edge handling — same shape as the c-cpp-direct /
# rust-direct / go-direct conventions. Mode 3 dep validation runs over
# the union of ``depends_on`` lines from ``repro.nim`` +
# ``repro.scanned-deps.nim``.
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
        "python-direct convention: depends_on references undeclared " &
          "package '" & edge.fromPackage & "' (line " & $edge.sourceLine & ")")
    if declaredPackages.find(edge.toPackage) < 0:
      raise newException(ValueError,
        "python-direct convention: depends_on " & edge.fromPackage &
          ": '" & edge.toPackage &
          "' references a package that is not declared in this workspace " &
          "(line " & $edge.sourceLine & ")")
  let cycle = detectDepCycle(edges, declaredPackages)
  if cycle.len > 0:
    raise newException(ValueError,
      "python-direct convention: depends_on graph contains a cycle: " &
        cycle.join(" -> "))

proc syntheticPackage(projectRoot: string;
                      members: seq[PythonDirectMember]): PackageDef =
  var name = "python_direct_convention"
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

proc emitByteCompileAction(projectRoot, pythonExe: string;
                           target: PythonDirectEmitTarget;
                           stageActionId: string;
                           stagedInitPath: string): BuildActionDef =
  ## Drive ``python -m compileall -q -f <stagedPkgDir>`` against the
  ## *staged* package directory (not the source tree). Writing the
  ## ``__pycache__/`` byte-code beside the staged sources means the
  ## wrapper finds the cached form on every invocation without
  ## touching the workspace's source tree.
  ##
  ## Note: we don't declare per-``.py`` ``.pyc`` outputs here — Python's
  ## compileall writes ``__pycache__/<mod>.cpython-<ver>.pyc`` whose
  ## tag depends on the runtime interpreter version. Declaring them up
  ## front would couple the action graph to the host's Python minor.
  ## Instead we declare a ``stamp`` output via the ``commandStatsId``
  ## tag and rely on the action-cache fingerprint over the inputs.
  let stagedPkgDir = stagedPackageDirFor(projectRoot, target.member.name)
  let stampPath = scratchPathFor(projectRoot, target.member.name) /
    (target.member.name & ".pyc.stamp")
  createDir(extendedPath(parentDir(stampPath)))
  let kindTag =
    case target.member.kind
    of pdmkExecutable: "executable"
    of pdmkLibrary: "library"
  # Drive compileall over the staged package dir. ``-q`` keeps stdout
  # quiet; we don't pass ``-f`` because the staged tree is rebuilt
  # whenever the preserveTree action runs, so its mtimes are always
  # fresh relative to the (yet-absent) ``__pycache__/`` siblings.
  #
  # Wrapping the compileall + stamp-touch in a single ``cmd /c`` (on
  # Windows) or ``sh -c`` (on POSIX) lets us declare a stable output
  # path the engine can fingerprint. The stamp file's content is the
  # staged init path's mtime — sufficient for cache invalidation.
  when defined(windows):
    let stampCmd = "echo compiled > " & quoteShell(stampPath)
    let pyCmd = quoteShell(pythonExe) & " -m compileall -q " &
      quoteShell(stagedPkgDir)
    let argv = @[
      "cmd", "/c",
      pyCmd & " && " & stampCmd
    ]
    let action = buildAction(
      id = "python-direct-bytecompile-" & sanitizeNamePart(target.member.name),
      call = inlineExecCall(argv, projectRoot),
      deps = @[stageActionId],
      inputs = @[stagedInitPath],
      outputs = @[stampPath],
      pool = "compile",
      dependencyPolicy = declaredOnlyDependencyPolicy(),
      commandStatsId = "python-direct." & kindTag & ".byte-compile")
    return action
  else:
    let stampCmd = "echo compiled > '" & stampPath & "'"
    let pyCmd = "'" & pythonExe & "' -m compileall -q '" & stagedPkgDir & "'"
    let argv = @[
      "sh", "-c",
      pyCmd & " && " & stampCmd
    ]
    let action = buildAction(
      id = "python-direct-bytecompile-" & sanitizeNamePart(target.member.name),
      call = inlineExecCall(argv, projectRoot),
      deps = @[stageActionId],
      inputs = @[stagedInitPath],
      outputs = @[stampPath],
      pool = "compile",
      dependencyPolicy = declaredOnlyDependencyPolicy(),
      commandStatsId = "python-direct." & kindTag & ".byte-compile")
    return action

proc renderWrapperScript(pythonExe, memberName: string;
                         stagingDirs: openArray[string]): string =
  ## Build the wrapper script content. ``stagingDirs`` is the ordered
  ## list of every PYTHONPATH entry the wrapper must export: the
  ## member's own staging dir first, then upstream library staging
  ## dirs sorted for determinism.
  ##
  ## The wrapper is the load-bearing artefact of an executable member;
  ## running it directly should produce the program's output regardless
  ## of the caller's CWD or environment, mirroring the Mode 2
  ## console-script launcher's contract.
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    # Use PowerShell-style explicit path concatenation. ``setlocal``
    # ensures our PYTHONPATH manipulation doesn't leak into the
    # caller's environment.
    lines.add("setlocal")
    # Set PYTHONPATH with the member's staging dir + upstream
    # staging dirs prepended.
    var pathExpr = ""
    for i, dir in stagingDirs:
      if i > 0:
        pathExpr.add(";")
      pathExpr.add(dir)
    lines.add("set \"PYTHONPATH=" & pathExpr & ";%PYTHONPATH%\"")
    # ``python -m <name>`` invokes the package's ``__main__.py``.
    lines.add("\"" & pythonExe & "\" -m " & memberName & " %*")
    lines.add("set \"WRAPPER_EXIT=%ERRORLEVEL%\"")
    lines.add("endlocal & exit /b %WRAPPER_EXIT%")
    return lines.join("\r\n") & "\r\n"
  else:
    var lines: seq[string] = @[]
    lines.add("#!/usr/bin/env sh")
    var pathExpr = ""
    for i, dir in stagingDirs:
      if i > 0:
        pathExpr.add(":")
      pathExpr.add(dir)
    lines.add("export PYTHONPATH=\"" & pathExpr & "${PYTHONPATH:+:$PYTHONPATH}\"")
    lines.add("exec \"" & pythonExe & "\" -m " & memberName & " \"$@\"")
    return lines.join("\n") & "\n"

proc emitWrapperAction(projectRoot, pythonExe: string;
                       target: PythonDirectEmitTarget;
                       ownStagingDir: string;
                       upstreamLibs: openArray[PythonDirectWorkspaceLibrary];
                       byteCompileActionId: string;
                       depByteCompileActionIds: openArray[string];
                       depPackageInits: openArray[string]):
                         tuple[action: BuildActionDef; wrapperPath: string] =
  ## ``fs.writeText`` action that materialises the wrapper script.
  ## Outputs the script path; depends on the byte-compile action so the
  ## wrapper's PYTHONPATH targets are guaranteed populated by the time
  ## the launcher runs.
  let wrapperPath = wrapperPathFor(projectRoot, target.member.name)
  createDir(extendedPath(parentDir(wrapperPath)))
  # Collect staging dirs deterministically: own dir first, then upstream
  # dirs sorted by library name.
  var stagingDirs: seq[string] = @[ownStagingDir]
  var upstreamSorted: seq[PythonDirectWorkspaceLibrary] = @[]
  for lib in upstreamLibs:
    upstreamSorted.add(lib)
  upstreamSorted.sort(proc (a, b: PythonDirectWorkspaceLibrary): int =
    cmp(a.libraryName, b.libraryName))
  for lib in upstreamSorted:
    if stagingDirs.find(lib.stagingDir) < 0:
      stagingDirs.add(lib.stagingDir)

  let script = renderWrapperScript(pythonExe, target.member.name, stagingDirs)

  # The byte-compile action id is the primary sequencing dep. Upstream
  # byte-compile action ids land on deps so the wrapper can't run
  # before its imports' staged trees are populated.
  var deps: seq[string] = @[byteCompileActionId]
  for actionId in depByteCompileActionIds:
    if deps.find(actionId) < 0:
      deps.add(actionId)

  let action = fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "python-direct-wrapper-" & sanitizeNamePart(target.member.name),
    deps = deps,
    commandStatsId = "python-direct.executable.wrapper")
  (action, wrapperPath)

proc emitStageAction(projectRoot: string;
                     target: PythonDirectEmitTarget):
                       tuple[action: BuildActionDef; stagedInitPath: string] =
  ## ``fs.preserveTree`` action that copies the source package dir into
  ## the staging dir. The convention's first per-member action; every
  ## downstream action sequences on this one.
  ##
  ## The source is the in-repo package dir (e.g.
  ## ``<root>/mathlib/mathlib/``); the destination is the staged
  ## package dir (e.g. ``<root>/.repro/build/mathlib/mathlib/``).
  let stagedPkgDir = stagedPackageDirFor(projectRoot, target.member.name)
  let stagedInitPath = stagedInitFileFor(projectRoot, target.member.name)
  createDir(extendedPath(stagedPkgDir))
  # ``fs.preserveTree`` walks the source dir, emits one input/output
  # per file, and reproduces the directory layout under the output
  # root. Excluding ``__pycache__/`` keeps stale host-Python byte-code
  # out of the staging dir.
  let action = fs.preserveTree(
    sourceRoot = target.pkgDir,
    outputRoot = stagedPkgDir,
    actionId = "python-direct-stage-" & sanitizeNamePart(target.member.name),
    excludePrefixes = ["__pycache__"],
    commandStatsId = "python-direct.stage")
  (action, stagedInitPath)

proc pythonDirectEmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  ## Convention entry — enumerate members, validate Mode 3 dep edges,
  ## emit per-member stage + byte-compile (+ wrapper) actions via the
  ## DSL, hand the whole thing to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembersWithOwnership(source)
    let usesEntries = extractPythonPackageUses(source)
    var members: seq[PythonDirectMember] = @[]
    for member in allMembers:
      if not packageUsesPython(usesEntries, member.package, source):
        continue
      members.add(member)
    if members.len == 0:
      raise newException(ValueError,
        "python-direct convention: no executable or library members " &
          "declared in " & projectFileForRoot(projectRoot))
    let pythonExe = pythonExecutable()
    if pythonExe.len == 0:
      raise newException(ValueError,
        "python-direct convention: neither 'python3' nor 'python' on " &
          "PATH; cannot run the byte-compile action")

    # Build the workspace-name → owner-package index used by import
    # resolution at emit time.
    var workspaceNameIndex = initTable[string, string]()
    for member in members:
      if member.name.len > 0:
        workspaceNameIndex[member.name] = member.package
      if member.package.len > 0 and
          not workspaceNameIndex.hasKey(member.package):
        workspaceNameIndex[member.package] = member.package

    var targets: seq[PythonDirectEmitTarget] = @[]
    for member in members:
      let target = resolveTarget(projectRoot, member, workspaceNameIndex)
      if target.pkgDir.len == 0:
        raise newException(ValueError,
          "python-direct convention: no Python package dir resolved " &
            "for member '" & member.name & "' under " & projectRoot &
            " (looked for <root>/" & member.name & "/" & member.name &
            "/__init__.py, <root>/" & member.name & "/src/" &
            member.name & "/__init__.py, <root>/src/" & member.name &
            "/__init__.py, <root>/" & member.name & "/__init__.py)")
      if target.member.kind == pdmkExecutable and
          not executableHasMainModule(target):
        raise newException(ValueError,
          "python-direct convention: executable member '" &
            member.name & "' is missing " & EntryModuleFile &
            " in " & target.pkgDir &
            " (the Mode 3 Python convention requires __main__.py so " &
            "'python -m " & member.name & "' resolves)")
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
      # Pass 1: libraries. Each library member is staged + byte-
      # compiled. The byte-compile action id + the staged init path
      # are recorded for downstream wrappers to pick up.
      var packageLibraries =
        initTable[string, seq[PythonDirectWorkspaceLibrary]]()
      var libraryByName = initTable[string, PythonDirectWorkspaceLibrary]()
      for target in targets:
        if target.member.kind != pdmkLibrary:
          continue
        let stageResult = emitStageAction(projectRoot, target)
        allActions.add(stageResult.action)
        let byteCompile = emitByteCompileAction(projectRoot, pythonExe,
          target, stageResult.action.id, stageResult.stagedInitPath)
        allActions.add(byteCompile)
        let entry = PythonDirectWorkspaceLibrary(
          libraryName: target.member.name,
          package: target.member.package,
          byteCompileActionId: byteCompile.id,
          stagingDir: stagingDirFor(projectRoot, target.member.name),
          packageDirOutput: stageResult.stagedInitPath)
        if target.member.package.len > 0:
          if not packageLibraries.hasKey(target.member.package):
            packageLibraries[target.member.package] = @[]
          packageLibraries[target.member.package].add(entry)
        libraryByName[target.member.name] = entry
        discard target(target.member.name, allActions)

      # Pass 2: executables. Each executable's stage + byte-compile
      # actions PLUS a wrapper script. The wrapper's PYTHONPATH
      # threads through every upstream library's staging dir; the
      # wrapper-emit action sequences on every upstream byte-compile
      # action id.
      for target in targets:
        if target.member.kind != pdmkExecutable:
          continue
        # Resolve this executable's upstream library dep set: union
        # of (a) ``depends_on`` edges from its owning package and
        # (b) import-derived workspace imports.
        var entryDeps: seq[PythonDirectWorkspaceLibrary] = @[]
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

        let stageResult = emitStageAction(projectRoot, target)
        allActions.add(stageResult.action)
        let byteCompile = emitByteCompileAction(projectRoot, pythonExe,
          target, stageResult.action.id, stageResult.stagedInitPath)
        allActions.add(byteCompile)

        var depByteCompileActionIds: seq[string] = @[]
        var depPackageInits: seq[string] = @[]
        for lib in entryDeps:
          depByteCompileActionIds.add(lib.byteCompileActionId)
          depPackageInits.add(lib.packageDirOutput)

        let ownStagingDir = stagingDirFor(projectRoot, target.member.name)
        let wrapperResult = emitWrapperAction(
          projectRoot = projectRoot,
          pythonExe = pythonExe,
          target = target,
          ownStagingDir = ownStagingDir,
          upstreamLibs = entryDeps,
          byteCompileActionId = byteCompile.id,
          depByteCompileActionIds = depByteCompileActionIds,
          depPackageInits = depPackageInits)
        allActions.add(wrapperResult.action)
        discard target(target.member.name, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc pythonDirectConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registration order: AFTER ``python`` so a project
  ## carrying a ``pyproject.toml`` routes through the Mode 2
  ## convention; this convention picks up the no-pyproject case.
  LanguageConvention(
    name: "python-direct",
    recognize: pythonDirectRecognize,
    emitFragment: pythonDirectEmitFragment)
