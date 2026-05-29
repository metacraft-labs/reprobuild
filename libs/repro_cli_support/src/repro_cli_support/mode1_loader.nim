## Mode 1 (layout-as-manifest) loader.
##
## M48 — Mode 1 zero-ceremony across Mode 3 languages.
##
## Mode 1 is "Mode 3 without persistence": the user drops files into
## convention-shaped directories (``apps/<name>/src/main.rs``,
## ``libs/<name>/src/lib.rs``) and runs ``repro build`` with NO
## ``repro.nim`` / ``reprobuild.nim`` and NO ``repro.scanned-deps.nim``
## anywhere on disk. The engine synthesises both files in memory from
## the layout + extension census, runs the Mode 3 scanner over the
## synthesised member list, and dispatches to the appropriate
## convention.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Mode 1 ↔
## Mode 3 relationship" and the M48 section of
## ``reprobuild-specs/Mode3-Language-Expansion.milestones.org``.
##
## ## Persistence policy
##
## Per spec, Mode 1's defining property is **the scanner output is NOT
## persisted to disk**. To make this property testable with the
## existing engine plumbing (which compiles the project provider from
## an on-disk ``repro.nim``), we write the synthesised project files
## under ``<workspaceRoot>/.repro/mode1-synth/`` rather than the
## workspace root itself. The synth dir is plain build scratch — every
## ``repro clean`` wipes it, and the user's source tree is never
## touched. The test ``test_mode1_no_persistence.nim`` guards against
## regression by asserting that ``<workspaceRoot>/repro.scanned-deps.nim``
## is absent after a Mode 1 build.
##
## ## Honest scope
##
##   * Single-language workspaces only. Mixed-language Mode 1 (e.g.
##     ``apps/foo`` is C, ``libs/bar`` is Rust) is DEFERRED per the M48
##     spec scope-down; the loader reports a hard error naming both
##     languages and instructing the user to graduate to Mode 3.
##   * Layout-shaped subdirs only: ``apps/<name>/``, ``libs/<name>/``,
##     ``tools/<name>/``, ``cmd/<name>/``, ``pkg/<name>/``, plus the
##     single-package ``src/`` shape (workspace root holds ``src/`` and
##     no apps/libs/...). Phase 3 conventions (Java/Maven, Kotlin/Gradle,
##     C# .NET, Swift/SwiftPM, OCaml/Dune) are N/A — they require a
##     manifest by construction.
##   * Ambiguous-import detection: when a single-segment import
##     (``use foo``, ``import foo``) could resolve to two in-workspace
##     packages, the loader emits a HARD ERROR listing all candidates
##     and exits non-zero. NEVER silently picks one. This is the
##     documented Mode 1 failure mode (silent wrong-builds) being
##     defended against.

import std/[algorithm, os, sets, strutils, tables]

import repro_core

# Re-export the types the CLI needs so callers don't have to import
# repro_core separately just for Mode 1 plumbing.
export WorkspaceMember, DepEdge, ScanResult

type
  Mode1TargetKind* = enum
    ## A Mode 1 synthesised target is either an executable (an entry
    ## with a ``main`` symbol / ``__main__.py``) or a library (everything
    ## else under ``libs/``).
    m1tkExecutable
    m1tkLibrary

  Mode1Language* = enum
    ## The supported Mode 1 languages — the M30–M33 + M37 + M44 + M45
    ## Mode 3 set. Per spec, Phase 3 conventions (Java/Maven, Kotlin/
    ## Gradle, .NET, Swift, OCaml/Dune) are N/A.
    m1lUnknown
    m1lNim
    m1lRust
    m1lGo
    m1lPython
    m1lJavaScriptTypeScript
    m1lCCpp
    m1lFortran
    m1lZig
    m1lD

  Mode1Target* = object
    ## A single layout-inferred target.
    name*: string
      ## Directory basename (``apps/foo`` → ``foo``).
    relDir*: string
      ## Forward-slash relative path from the workspace root
      ## (``apps/foo``).
    absDir*: string
      ## Absolute path on disk.
    kind*: Mode1TargetKind
    language*: Mode1Language
    extensionCensus*: Table[string, int]
      ## File-extension census (lowercase ext including the leading
      ## dot). Surfaced in ``repro show-conventions`` so the user can
      ## audit the heuristic.
    sourceFiles*: seq[string]
      ## Absolute paths to recognized source files in this target.
      ## Sorted alphabetically for determinism.
    entrySource*: string
      ## Best-effort entry source path (the ``main.<ext>`` or
      ## ``__main__.py`` or ``lib.<ext>`` that the convention will
      ## treat as the crate root). Empty when the loader couldn't
      ## identify a single entry (e.g. an executable target with both
      ## ``main.rs`` and ``main.go`` — but that case is rejected by
      ## the mixed-language guard before we get here).

  Mode1Diagnostic* = object
    ## A non-fatal observation surfaced by ``repro show-conventions``.
    target*: string
      ## Target name the diagnostic applies to (empty for
      ## workspace-wide observations).
    message*: string

  Mode1AmbiguousImport* = object
    ## A single ambiguous-import incident: an import head that
    ## resolves to TWO or more in-workspace targets. The loader emits
    ## a hard error listing every incident so the user sees the full
    ## set before fixing.
    fromTarget*: string
      ## Target whose source raised the ambiguity.
    importHead*: string
      ## First segment of the ``use`` / ``import`` / etc. path.
    sourceFile*: string
      ## Absolute path to the source file containing the import.
    lineNumber*: int
      ## 1-based line number of the import statement.
    rawLine*: string
      ## Trimmed source line carrying the import (for evidence).
    candidates*: seq[string]
      ## Names of the in-workspace targets the head could resolve to.

  Mode1Workspace* = object
    ## The result of running the Mode 1 loader over a workspace root.
    workspaceRoot*: string
    targets*: seq[Mode1Target]
      ## Layout-inferred targets, sorted alphabetically by ``relDir``.
    diagnostics*: seq[Mode1Diagnostic]
      ## Non-fatal observations.
    ambiguousImports*: seq[Mode1AmbiguousImport]
      ## Hard-error candidates: when non-empty, Mode 1 must exit
      ## non-zero with the formatted message.
    edges*: seq[DepEdge]
      ## Resolved inter-target dep edges (proven by the scanner).
      ## Empty when ``ambiguousImports.len > 0``.
    syntheticProjectFile*: string
      ## Absolute path to the on-disk ``repro.nim`` the loader
      ## synthesises (under ``<workspaceRoot>/.repro/mode1-synth/``).
      ## Empty when ``targets.len == 0``.

const
  Mode1ScratchDirName* = ".repro/mode1-synth"
    ## Sub-path under the workspace root where the loader materializes
    ## the synthesised ``repro.nim`` + ``repro.scanned-deps.nim``.
    ## Plain build scratch — wiped by ``repro clean`` and gitignored
    ## by every fixture's standard ``.gitignore`` ``\.repro/`` rule.

  LayoutContainerDirs* = ["apps", "libs", "tools", "cmd", "pkg", "bin"]
    ## Directory names under the workspace root that the loader scans
    ## for layout-shaped targets. Each subdir is one candidate target.

  SingleTargetRootMarkerDir* = "src"
    ## When the workspace root has a ``src/`` dir AND no
    ## ``LayoutContainerDirs`` are present, the workspace is treated as
    ## a single-package project rooted at the workspace itself. The
    ## inferred target's name is the workspace's basename and its kind
    ## is ``executable`` iff the ``src/`` contains a ``main.<ext>`` /
    ## ``__main__.py`` entry.

# ----------------------------------------------------------------------
# Language detection from a file-extension census.
# ----------------------------------------------------------------------

const Mode1LanguageExtensions: array[16, tuple[ext: string;
                                               language: Mode1Language]] = [
  (".nim",   m1lNim),
  (".rs",    m1lRust),
  (".go",    m1lGo),
  (".py",    m1lPython),
  (".ts",    m1lJavaScriptTypeScript),
  (".tsx",   m1lJavaScriptTypeScript),
  (".js",    m1lJavaScriptTypeScript),
  (".jsx",   m1lJavaScriptTypeScript),
  (".c",     m1lCCpp),
  (".cpp",   m1lCCpp),
  (".cc",    m1lCCpp),
  (".cxx",   m1lCCpp),
  (".f90",   m1lFortran),
  (".f95",   m1lFortran),
  (".zig",   m1lZig),
  (".d",     m1lD),
]

proc languageOfExtension*(ext: string): Mode1Language =
  let lower = ext.toLowerAscii
  for entry in Mode1LanguageExtensions:
    if entry.ext == lower:
      return entry.language
  m1lUnknown

proc languageName*(lang: Mode1Language): string =
  case lang
  of m1lUnknown: "unknown"
  of m1lNim: "nim"
  of m1lRust: "rust"
  of m1lGo: "go"
  of m1lPython: "python"
  of m1lJavaScriptTypeScript: "javascript-typescript"
  of m1lCCpp: "c-cpp"
  of m1lFortran: "fortran"
  of m1lZig: "zig"
  of m1lD: "d"

proc dslUsesToken*(lang: Mode1Language): string =
  ## The string that goes into the synthesised ``repro.nim``'s
  ## ``uses:`` block. Conventions match these tokens via their
  ## ``packageUses<Lang>`` parser.
  case lang
  of m1lUnknown: ""
  of m1lNim: "nim"
  of m1lRust: "rust"
  of m1lGo: "go"
  of m1lPython: "python"
  of m1lJavaScriptTypeScript: "javascript-typescript"
  of m1lCCpp: "gcc"
  of m1lFortran: "gfortran"
  of m1lZig: "zig"
  of m1lD: "ldmd2"

proc entryFileNamesForLanguage(lang: Mode1Language; kind: Mode1TargetKind;
                               targetName: string): seq[string] =
  ## Names the loader recognises as an "entry source" — the file the
  ## convention treats as the crate root / main module. The first
  ## entry on the list that exists on disk wins. The Nim per-target
  ## entry typically follows the ``<targetName>.nim`` shape rather
  ## than a canonical ``lib.nim`` / ``main.nim`` so we include both.
  if kind == m1tkExecutable:
    case lang
    of m1lNim: @[targetName & ".nim", "main.nim", "app.nim"]
    of m1lRust: @["main.rs"]
    of m1lGo: @["main.go"]
    of m1lPython: @["__main__.py", "main.py"]
    of m1lJavaScriptTypeScript: @["main.ts", "main.js", "index.ts", "index.js"]
    of m1lCCpp: @["main.c", "main.cpp", "main.cc", "main.cxx"]
    of m1lFortran: @["main.f90", "main.f95"]
    of m1lZig: @["main.zig"]
    of m1lD: @["main.d", "app.d"]
    of m1lUnknown: @[]
  else:
    case lang
    of m1lNim: @[targetName & ".nim", "lib.nim"]
    of m1lRust: @["lib.rs"]
    of m1lGo: @[]  # Go libraries have no canonical entry file.
    of m1lPython: @["__init__.py"]
    of m1lJavaScriptTypeScript: @["lib.ts", "lib.js", "index.ts", "index.js"]
    of m1lCCpp: @["lib.c", "lib.cpp", "lib.cc", "lib.cxx"]
    of m1lFortran: @["lib.f90"]
    of m1lZig: @["lib.zig", "root.zig"]
    of m1lD: @["lib.d"]
    of m1lUnknown: @[]

# ----------------------------------------------------------------------
# Workspace walker.
# ----------------------------------------------------------------------

const SkippedDirNames = [
  ".repro", ".git", ".nimcache", ".cargo", "target", "node_modules",
  "build", "dist", "__pycache__", ".venv", "venv"
]

proc shouldSkipDir(basename: string): bool =
  basename in SkippedDirNames

proc walkTargetSources(targetDir: string): tuple[
    sourceFiles: seq[string];
    census: Table[string, int];
    hasMain: bool;
    hasInit: bool] =
  ## Walk ``targetDir`` recursively, collecting all source files (any
  ## file whose extension matches one of the supported Mode 1
  ## languages), the extension census, and flags noting whether a
  ## ``main.*`` or ``__init__.py`` file is present anywhere in the
  ## tree. The walk skips standard build/version-control dirs.
  result.census = initTable[string, int]()
  if not dirExists(targetDir):
    return
  var queue: seq[string] = @[targetDir]
  while queue.len > 0:
    let cur = queue[0]
    queue.delete(0)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        if basename.startsWith("."):
          continue
        case kind
        of pcFile, pcLinkToFile:
          let ext = splitFile(basename).ext.toLowerAscii
          if ext.len == 0:
            continue
          let lang = languageOfExtension(ext)
          if lang == m1lUnknown:
            continue
          result.sourceFiles.add(path)
          result.census.mgetOrPut(ext, 0) += 1
          let baseLower = basename.toLowerAscii
          if baseLower.startsWith("main.") or baseLower == "__main__.py":
            result.hasMain = true
          if baseLower == "__init__.py":
            result.hasInit = true
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          queue.add(path)
    except OSError:
      discard
  result.sourceFiles.sort(system.cmp[string])

proc dominantLanguage(census: Table[string, int]):
    tuple[language: Mode1Language; tied: seq[Mode1Language]] =
  ## Pick the language with the highest file count from a census.
  ## Returns ``tied`` when multiple languages share the top count
  ## (a per-target mixed-language signal).
  var counts = initTable[Mode1Language, int]()
  for ext, count in census.pairs:
    let lang = languageOfExtension(ext)
    if lang == m1lUnknown:
      continue
    counts.mgetOrPut(lang, 0) += count
  var top = 0
  var winner = m1lUnknown
  for lang, count in counts.pairs:
    if count > top:
      top = count
      winner = lang
  if winner == m1lUnknown:
    return
  result.language = winner
  for lang, count in counts.pairs:
    if count == top and lang != winner:
      result.tied.add(lang)

proc resolveEntrySource(targetDir, targetName: string;
                        language: Mode1Language;
                        kind: Mode1TargetKind; sourceFiles: seq[string]):
    string =
  ## Find the canonical entry source for a target. Probes the standard
  ## paths first (``src/<entry>`` then ``<entry>`` at the target root),
  ## then falls back to scanning the source-file set for a matching
  ## basename anywhere in the tree.
  let candidates = entryFileNamesForLanguage(language, kind, targetName)
  for name in candidates:
    let viaSrc = targetDir / "src" / name
    if fileExists(extendedPath(viaSrc)):
      return viaSrc
    let viaRoot = targetDir / name
    if fileExists(extendedPath(viaRoot)):
      return viaRoot
  # Fall back: any file in the source set whose basename matches one
  # of the candidates (handles nested entry-source layouts that real
  # projects sometimes adopt — e.g. ``src/<member>/main.rs``).
  for path in sourceFiles:
    let base = extractFilename(path).toLowerAscii
    if base in candidates:
      return path
  ""

proc detectLayoutTargets(workspaceRoot: string):
    seq[tuple[name, relDir, absDir: string]] =
  ## Walk ``workspaceRoot`` for layout-shaped container dirs
  ## (``apps/``, ``libs/``, ...) and enumerate every immediate subdir
  ## as a candidate target.
  var anyContainer = false
  for container in LayoutContainerDirs:
    let containerDir = workspaceRoot / container
    if not dirExists(extendedPath(containerDir)):
      continue
    anyContainer = true
    try:
      for kind, path in walkDir(containerDir):
        if kind notin {pcDir, pcLinkToDir}:
          continue
        let basename = extractFilename(path)
        if shouldSkipDir(basename) or basename.startsWith("."):
          continue
        let relDir = container & "/" & basename
        result.add((name: basename, relDir: relDir, absDir: path))
    except OSError:
      discard
  if not anyContainer:
    # Single-package shape: workspace root holds a ``src/`` directory
    # and no apps/libs/... containers. Treat the workspace itself as
    # the single target.
    let srcDir = workspaceRoot / SingleTargetRootMarkerDir
    if dirExists(extendedPath(srcDir)):
      let basename = extractFilename(absolutePath(workspaceRoot))
      let safeName =
        if basename.len > 0 and basename[0] in {'a' .. 'z', 'A' .. 'Z', '_'}:
          basename
        else:
          "app"
      result.add((name: safeName, relDir: ".", absDir: workspaceRoot))
  result.sort(proc (a, b: tuple[name, relDir, absDir: string]): int =
    cmp(a.relDir, b.relDir))

proc inferTargetKind(target: var Mode1Target; language: Mode1Language;
                     hasMain: bool; hasInit: bool;
                     relDir: string) =
  ## Pick executable vs library based on:
  ##   * relDir under ``apps/`` / ``cmd/`` / ``bin/`` / ``tools/`` is
  ##     executable; ``libs/`` / ``pkg/`` is library;
  ##   * Otherwise, presence of a ``main.<ext>`` / ``__main__.py``
  ##     means executable; otherwise library.
  let head =
    if relDir.startsWith("apps/") or relDir.startsWith("cmd/") or
        relDir.startsWith("bin/") or relDir.startsWith("tools/"):
      "exec"
    elif relDir.startsWith("libs/") or relDir.startsWith("pkg/"):
      "lib"
    else:
      ""
  if head == "exec":
    target.kind = m1tkExecutable
  elif head == "lib":
    target.kind = m1tkLibrary
  elif hasMain:
    target.kind = m1tkExecutable
  elif language == m1lPython and hasInit:
    target.kind = m1tkLibrary
  else:
    target.kind = m1tkLibrary

# ----------------------------------------------------------------------
# Import scanning + ambiguity detection.
# ----------------------------------------------------------------------

proc relativeFromRoot(workspaceRoot, sourcePath: string): string =
  result =
    try:
      relativePath(sourcePath, workspaceRoot)
    except OSError:
      sourcePath
  result = result.replace('\\', '/')

proc scanImportsForLanguage(target: Mode1Target;
                            workspaceRoot: string):
    seq[tuple[head: string; lineNumber: int; raw: string;
              sourceFile: string]] =
  ## Generic per-source import extraction. Reuses the per-language
  ## scanners in ``repro_core`` so the import-recognition semantics
  ## stay identical to Mode 3.
  for sourcePath in target.sourceFiles:
    let text =
      try:
        readFile(extendedPath(sourcePath))
      except CatchableError:
        continue
    case target.language
    of m1lRust:
      for useRef in extractRustUseRefs(text):
        if isRustIntraCrateHead(useRef.crateHead):
          continue
        if isRustStdlibCrate(useRef.crateHead):
          continue
        result.add((head: useRef.crateHead,
                    lineNumber: useRef.lineNumber,
                    raw: useRef.raw,
                    sourceFile: sourcePath))
    of m1lNim:
      var lineNo = 0
      for raw in text.splitLines():
        inc lineNo
        let stripped = raw.strip()
        if stripped.len == 0:
          continue
        if not (stripped.startsWith("import ") or
                stripped.startsWith("from ")):
          continue
        # Cheap first-segment extraction — the Mode 3 nim scanner does
        # this through a real path-walk, but here we just need the head
        # for ambiguity detection.
        var rest = stripped
        if rest.startsWith("from "):
          rest = rest[len("from ") .. ^1]
        elif rest.startsWith("import "):
          rest = rest[len("import ") .. ^1]
        rest = rest.strip()
        var head = ""
        for ch in rest:
          if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
            head.add(ch)
          else:
            break
        if head.len == 0 or head in ["std", "system", "json", "os",
            "strutils", "sequtils", "tables", "sets", "algorithm",
            "options", "math", "times", "strformat", "parsejson"]:
          continue
        result.add((head: head, lineNumber: lineNo, raw: stripped,
                    sourceFile: sourcePath))
    of m1lGo:
      # The Go scanner's import block extraction is in repro_core;
      # for Mode 1 ambiguity detection we use a minimal line scan.
      var lineNo = 0
      var inBlock = false
      for raw in text.splitLines():
        inc lineNo
        let stripped = raw.strip()
        if stripped.len == 0:
          continue
        if stripped.startsWith("import ("):
          inBlock = true
          continue
        if inBlock:
          if stripped == ")":
            inBlock = false
            continue
          # Quote-delimited import path; the head is the first segment.
          let q1 = stripped.find('"')
          let q2 = if q1 >= 0: stripped.find('"', q1 + 1) else: -1
          if q1 < 0 or q2 < 0:
            continue
          let path = stripped[q1 + 1 ..< q2]
          let head = path.split('/')[0]
          result.add((head: head, lineNumber: lineNo, raw: stripped,
                      sourceFile: sourcePath))
        elif stripped.startsWith("import "):
          let rest = stripped[len("import ") .. ^1].strip()
          let q1 = rest.find('"')
          let q2 = if q1 >= 0: rest.find('"', q1 + 1) else: -1
          if q1 < 0 or q2 < 0:
            continue
          let path = rest[q1 + 1 ..< q2]
          let head = path.split('/')[0]
          result.add((head: head, lineNumber: lineNo, raw: stripped,
                      sourceFile: sourcePath))
    of m1lPython:
      var lineNo = 0
      for raw in text.splitLines():
        inc lineNo
        let stripped = raw.strip()
        if stripped.len == 0:
          continue
        var head = ""
        if stripped.startsWith("import "):
          let rest = stripped[len("import ") .. ^1].strip()
          for ch in rest:
            if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
              head.add(ch)
            else:
              break
        elif stripped.startsWith("from "):
          let rest = stripped[len("from ") .. ^1].strip()
          for ch in rest:
            if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
              head.add(ch)
            else:
              break
        if head.len == 0:
          continue
        if head in ["os", "sys", "json", "typing", "collections",
            "itertools", "functools", "pathlib", "argparse",
            "re", "math", "time", "datetime", "subprocess", "io"]:
          continue
        result.add((head: head, lineNumber: lineNo, raw: stripped,
                    sourceFile: sourcePath))
    else:
      # Other languages: no ambiguity scan yet; rely on the standard
      # per-language scanner downstream.
      discard

# ----------------------------------------------------------------------
# Public entry point — load the workspace.
# ----------------------------------------------------------------------

proc hasAnyProjectFile*(workspaceRoot: string): bool =
  ## True when ``workspaceRoot`` (or any layout-shaped subdir) holds a
  ## ``repro.nim`` / ``reprobuild.nim``. Used by the CLI dispatcher to
  ## decide between Mode 3 (project file present) and Mode 1 (absent).
  ## Mode 1 only fires when NO project file is present anywhere in the
  ## workspace tree the loader would otherwise scan.
  for fname in [CanonicalProjectFileName, LegacyProjectFileName]:
    if fileExists(extendedPath(workspaceRoot / fname)):
      return true
  for container in LayoutContainerDirs:
    let containerDir = workspaceRoot / container
    if not dirExists(extendedPath(containerDir)):
      continue
    try:
      for kind, path in walkDir(containerDir):
        if kind notin {pcDir, pcLinkToDir}:
          continue
        for fname in [CanonicalProjectFileName, LegacyProjectFileName]:
          if fileExists(extendedPath(path / fname)):
            return true
    except OSError:
      discard
  false

proc hasMode2Manifest*(workspaceRoot: string): bool =
  ## True when ``workspaceRoot`` carries a Mode 2 ecosystem manifest
  ## (``Cargo.toml`` / ``go.mod`` / ``pyproject.toml`` / ``package.json``
  ## / ``CMakeLists.txt`` / etc.). Mode 1 only fires when NEITHER a
  ## project file NOR a Mode 2 manifest is present.
  for marker in ["Cargo.toml", "go.mod", "pyproject.toml", "setup.py",
                 "setup.cfg", "package.json", "tsconfig.json",
                 "CMakeLists.txt", "configure.ac", "Makefile.am",
                 "meson.build", "pom.xml", "build.gradle",
                 "build.gradle.kts", "Package.swift", "dune-project",
                 "Makefile", "GNUmakefile", "makefile"]:
    if fileExists(extendedPath(workspaceRoot / marker)):
      return true
  # Any *.nimble at the root counts as a Mode 2 Nim manifest.
  try:
    for kind, path in walkDir(workspaceRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let base = extractFilename(path).toLowerAscii
      if base.endsWith(".nimble") or base.endsWith(".csproj"):
        return true
  except OSError:
    discard
  false

proc loadMode1Workspace*(workspaceRoot: string): Mode1Workspace =
  ## Main entry point: walk ``workspaceRoot`` and produce a synthesised
  ## Mode 1 member list + dep graph. The caller is responsible for
  ## persisting the synthesised project file via
  ## ``materializeMode1ProjectFile`` (under
  ## ``<workspaceRoot>/.repro/mode1-synth/``).
  ##
  ## The returned ``Mode1Workspace`` has ``targets.len == 0`` when the
  ## walker couldn't find any layout-shaped directories — in that case
  ## the caller should report the standard "no project file" error
  ## with a Mode 1 hint.
  result.workspaceRoot = workspaceRoot
  if not dirExists(extendedPath(workspaceRoot)):
    return
  let candidates = detectLayoutTargets(workspaceRoot)
  if candidates.len == 0:
    return

  # Per-target source enumeration + language detection.
  var languageHistogram: Table[Mode1Language, int]
  for cand in candidates:
    let walk = walkTargetSources(cand.absDir)
    if walk.sourceFiles.len == 0:
      result.diagnostics.add(Mode1Diagnostic(
        target: cand.name,
        message: "no Mode 1-recognised source files under " & cand.relDir))
      continue
    let dom = dominantLanguage(walk.census)
    if dom.language == m1lUnknown:
      result.diagnostics.add(Mode1Diagnostic(
        target: cand.name,
        message: "extension census found " & $walk.census.len &
          " extension types but none mapped to a Mode 1 language"))
      continue
    if dom.tied.len > 0:
      var languages = @[languageName(dom.language)]
      for t in dom.tied:
        languages.add(languageName(t))
      result.diagnostics.add(Mode1Diagnostic(
        target: cand.name,
        message: "tied extension census between languages: " &
          languages.join(", ") & " — picking " &
          languageName(dom.language)))
    var target = Mode1Target(
      name: cand.name,
      relDir: cand.relDir,
      absDir: cand.absDir,
      language: dom.language,
      extensionCensus: walk.census,
      sourceFiles: walk.sourceFiles)
    inferTargetKind(target, dom.language, walk.hasMain, walk.hasInit,
      cand.relDir)
    target.entrySource = resolveEntrySource(cand.absDir, target.name,
      dom.language, target.kind, walk.sourceFiles)
    result.targets.add(target)
    languageHistogram.mgetOrPut(dom.language, 0) += 1

  # Mixed-language workspace guard. Per spec scope-down, Mode 1 only
  # handles single-language workspaces; mixed-language Mode 1 is
  # deferred. Report the languages found + the targets that selected
  # each so the user can see the structure of the rejection.
  if languageHistogram.len > 1:
    var byLang: Table[Mode1Language, seq[string]]
    for t in result.targets:
      byLang.mgetOrPut(t.language, @[]).add(t.relDir)
    var summary: seq[string]
    for lang, _ in languageHistogram.pairs:
      let dirs = byLang.getOrDefault(lang, @[])
      summary.add(languageName(lang) & " (" & dirs.join(", ") & ")")
    result.diagnostics.add(Mode1Diagnostic(
      target: "",
      message: "Mode 1 mixed-language workspace not supported: " &
        summary.join("; ") &
        ". Mixed-language Mode 1 is DEFERRED per spec; " &
        "graduate to Mode 3 by writing a repro.nim with explicit " &
        "per-package uses: clauses."))
    return

  if result.targets.len == 0:
    return

  # Build the in-workspace name index for ambiguity detection. We key
  # on a normalised target name; two targets sharing the same
  # normalised key are themselves a workspace-design error, but the
  # detection happens at scan time when an import references them.
  proc normalizeKey(s: string): string =
    result = newStringOfCap(s.len)
    for ch in s:
      if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        result.add(ch.toLowerAscii)
      elif ch in {'_', '-'}:
        result.add('_')

  # For each in-workspace target, build the set of names an import
  # might use to reach it. We accept the bare target name plus the
  # `<container>/<name>` shape (the M30+ scanners normalise on the
  # bare name).
  var nameIndex: Table[string, seq[string]]
  for t in result.targets:
    let key = normalizeKey(t.name)
    if key.len == 0:
      continue
    nameIndex.mgetOrPut(key, @[]).add(t.relDir)

  # Resolve every in-workspace import head against the name index.
  # When a head maps to TWO or more relDirs the loader records an
  # ambiguity. When it maps to ONE distinct relDir the loader emits
  # a dep edge.
  var seenEdges = initHashSet[string]()
  for target in result.targets:
    let imports = scanImportsForLanguage(target, workspaceRoot)
    for imp in imports:
      let key = normalizeKey(imp.head)
      if key.len == 0:
        continue
      if not nameIndex.hasKey(key):
        continue
      let candidates = nameIndex[key]
      # Self-import: skip.
      if candidates.len == 1 and candidates[0] == target.relDir:
        continue
      let distinctSet = block:
        var s = initHashSet[string]()
        for c in candidates:
          s.incl(c)
        s
      if distinctSet.len > 1:
        result.ambiguousImports.add(Mode1AmbiguousImport(
          fromTarget: target.relDir,
          importHead: imp.head,
          sourceFile: imp.sourceFile,
          lineNumber: imp.lineNumber,
          rawLine: imp.raw,
          candidates: candidates.sorted))
        continue
      var toTarget = ""
      for c in candidates:
        if c != target.relDir:
          toTarget = c
          break
      if toTarget.len == 0:
        continue
      let evidence = relativeFromRoot(workspaceRoot, imp.sourceFile) &
        ":" & $imp.lineNumber & ": " & imp.raw
      let edgeKey = target.relDir & "\x1f" & toTarget & "\x1f" & evidence
      if edgeKey in seenEdges:
        continue
      seenEdges.incl(edgeKey)
      result.edges.add(DepEdge(
        fromPackage: target.relDir,
        toPackage: toTarget,
        evidence: evidence))

  if result.ambiguousImports.len > 0:
    # Wipe edges so the caller's "happy path" emit doesn't surface
    # partial results; the ambiguous-import diagnostic is the only
    # output a Mode 1 user should see in this case.
    result.edges = @[]
    return

  result.edges.sort(proc (a, b: DepEdge): int =
    let c1 = cmp(a.fromPackage, b.fromPackage)
    if c1 != 0: return c1
    let c2 = cmp(a.toPackage, b.toPackage)
    if c2 != 0: return c2
    cmp(a.evidence, b.evidence))

# ----------------------------------------------------------------------
# Diagnostic rendering — used by both the ``repro build`` error path
# and ``repro show-conventions``.
# ----------------------------------------------------------------------

proc renderAmbiguousImportError*(ws: Mode1Workspace): string =
  ## Format the ambiguous-import incidents into the hard-error message
  ## the CLI emits. The message lists every incident in deterministic
  ## order.
  result = "Mode 1: ambiguous import detected in " & ws.workspaceRoot &
    "\n"
  for incident in ws.ambiguousImports:
    let rel = relativeFromRoot(ws.workspaceRoot, incident.sourceFile)
    result.add("  - " & rel & ":" & $incident.lineNumber & ": import '" &
      incident.importHead & "' resolves to candidates: " &
      incident.candidates.join(", ") & "\n")
  result.add("\n" &
    "Resolve by graduating to Mode 3: write a repro.nim with " &
    "explicit `depends_on` lines naming the intended target.")

# ----------------------------------------------------------------------
# Synthesised file rendering. The output mirrors the on-disk Mode 3
# project file shape so the existing standard-provider dispatch picks
# it up without modification.
# ----------------------------------------------------------------------

proc renderSynthesizedProjectFile*(ws: Mode1Workspace): string =
  ## Produce the synthesised ``repro.nim`` body for a Mode 1 workspace.
  ## One ``package`` block per target; the package name is the target
  ## name (Mode 3 conventions key on the package name so two targets
  ## under different containers can't collide on this).
  result = "## Mode 1 synthesised project file. DO NOT EDIT.\n"
  result.add("##\n")
  result.add("## Generated from layout at " & ws.workspaceRoot & "\n")
  result.add("## by ``repro build`` in Mode 1 (no on-disk repro.nim).\n")
  result.add("\n")
  result.add("import repro_project_dsl\n")
  result.add("\n")
  for target in ws.targets:
    let usesToken = dslUsesToken(target.language)
    result.add("package " & target.name & ":\n")
    result.add("  uses:\n")
    result.add("    \"" & usesToken & "\"\n")
    result.add("\n")
    case target.kind
    of m1tkExecutable:
      result.add("  executable " & target.name & ":\n")
      result.add("    discard\n")
    of m1tkLibrary:
      result.add("  library " & target.name & "\n")
    result.add("\n")
  if ws.edges.len > 0:
    result.add("# Workspace-internal dependencies inferred by the " &
      "Mode 1 scanner.\n")
    result.add("include \"repro.scanned-deps.nim\"\n")

proc renderSynthesizedScannedDeps*(ws: Mode1Workspace): string =
  ## Produce the synthesised ``repro.scanned-deps.nim`` body.
  result = "# repro.scanned-deps.nim (Mode 1 synthesised)\n"
  result.add("#\n")
  result.add("# DO NOT EDIT — derived in-memory by Mode 1 from\n")
  result.add("# " & ws.workspaceRoot & ".\n")
  result.add("#\n")
  result.add("# Scanner schema: v1\n")
  result.add("# Targets scanned: " & $ws.targets.len & "\n")
  result.add("\n")
  for edge in ws.edges:
    # Translate target relDirs to the package names that appear in the
    # synthesised project file. Both keys are formed from the target
    # ``relDir``; we look up the matching target's ``name``.
    var fromName = edge.fromPackage
    var toName = edge.toPackage
    for t in ws.targets:
      if t.relDir == edge.fromPackage:
        fromName = t.name
      if t.relDir == edge.toPackage:
        toName = t.name
    result.add("# " & edge.evidence & "\n")
    result.add("depends_on " & fromName & ": " & toName & "\n")
    result.add("\n")

proc materializeMode1ProjectFile*(ws: var Mode1Workspace): string =
  ## Write the synthesised ``repro.nim`` + ``repro.scanned-deps.nim``
  ## to ``<workspaceRoot>/.repro/mode1-synth/`` and return the path to
  ## the synthesised ``repro.nim``. Returns the empty string when the
  ## workspace has no Mode 1 targets.
  ##
  ## CRITICAL: writes ONLY under ``.repro/mode1-synth/`` — the user's
  ## source tree is never touched and the policy "Mode 1 doesn't write
  ## ``repro.scanned-deps.nim`` to the workspace root" stays intact.
  if ws.targets.len == 0:
    return ""
  let synthDir = ws.workspaceRoot / Mode1ScratchDirName
  createDir(extendedPath(synthDir))
  let projectPath = synthDir / "repro.nim"
  let depsPath = synthDir / "repro.scanned-deps.nim"
  writeFile(extendedPath(projectPath), renderSynthesizedProjectFile(ws))
  writeFile(extendedPath(depsPath), renderSynthesizedScannedDeps(ws))
  # Materialize per-member entry source shims so the standard
  # provider's per-language ``resolveMemberDirs`` helpers find an
  # on-disk source. The shim is a tiny stub that includes the user's
  # real source file via the language's textual-include facility
  # (``include!()`` in Rust, ``include`` in Nim). The shim layout
  # mirrors what each convention expects:
  #
  #   * Nim (``conventions/nim.nim``): all members share
  #     ``<projectRoot>/src/<member>.nim``.
  #   * Rust direct (``conventions/rust_direct.nim``): per-member
  #     ``<projectRoot>/<member>/src/{main,lib}.rs`` (Layout B).
  #
  # We can't symlink the user's sources (Windows symlinks need admin
  # rights) and we can't move them (we'd corrupt the user's source
  # tree) so the include-pointer shim is the pragmatic compromise.
  for target in ws.targets:
    if target.entrySource.len == 0:
      continue
    var entryName = ""
    var memberDir = ""
    case target.language
    of m1lRust:
      memberDir = synthDir / target.name / "src"
      entryName =
        if target.kind == m1tkExecutable: "main.rs" else: "lib.rs"
    of m1lNim:
      memberDir = synthDir / "src"
      entryName = target.name & ".nim"
    else:
      discard
    if entryName.len == 0:
      continue
    createDir(extendedPath(memberDir))
    let entryPath = memberDir / entryName
    let escaped = target.entrySource.replace('\\', '/')
    let shim =
      case target.language
      of m1lRust:
        # Rust's ``include!()`` macro expands the file's tokens at the
        # call site so the user's ``main.rs`` / ``lib.rs`` is compiled
        # verbatim. The macro accepts absolute paths cross-platform.
        "// Mode 1 synthesised shim — includes the user's source.\n" &
        "include!(\"" & escaped & "\");\n"
      of m1lNim:
        # Nim's ``include`` directive is textual, but it changes the
        # current-file-relative path for nested ``import`` resolution
        # to the included file's directory. That's a problem here
        # because the user's source lives under ``apps/<name>/src/``
        # and the synthesised greet/mathlib sibling shims live under
        # ``<synthDir>/src/``. Reading the file content and emitting
        # it verbatim keeps Nim's import resolution rooted at the
        # synth dir, where the sibling shims sit.
        let realContent =
          try:
            readFile(extendedPath(target.entrySource))
          except CatchableError:
            ""
        if realContent.len > 0:
          "## Mode 1 synthesised shim — verbatim copy of the user's source\n" &
          "## (" & escaped & ").\n" &
          realContent
        else: ""
      else: ""
    if shim.len > 0:
      writeFile(extendedPath(entryPath), shim)
  ws.syntheticProjectFile = projectPath
  projectPath
