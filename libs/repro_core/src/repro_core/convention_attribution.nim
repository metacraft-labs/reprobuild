## Per-target convention attribution + no-match diagnostics + toolchain
## probing for ``repro show-conventions``.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Observability"
## for the contract: ``repro show-conventions`` must report (per target)
## the language convention that claimed it, and (per workspace) which
## directories LOOK target-shaped but no convention claimed them, plus
## the toolchain version for each detected language where available.
##
## ## Why a heuristic instead of calling the real ``recognize``
##
## The standard provider's ``recognize`` procs (Mode 2 / Tier 2b) are
## the source of truth at build time: they're per-language plugins that
## the standard-provider binary links and dispatches via
## ``firstMatchingConvention``. The ``repro`` CLI is a SEPARATE process
## from ``repro-standard-provider`` and does not link the per-language
## plugins (the CLI is `repro_cli_support`-based and sits below the
## provider in the dep DAG — pulling the provider down would invert the
## layering and bloat the CLI binary).
##
## Three options for crossing that boundary were considered (see the
## hand-off in the milestone notes):
##
##   * **1a — IPC.** Spawn ``repro-standard-provider`` as a subprocess
##     in a "query" mode. Highest fidelity, also the highest engineering
##     cost (new IPC surface, new error paths, slower startup). Deferred
##     to a follow-on milestone.
##   * **1b — Shared introspection library.** Hoist each plugin's
##     ``recognize`` into a thin sibling library both binaries link.
##     Right long-term answer, but requires refactoring seven
##     conventions all at once.
##   * **1c — Heuristic.** Manifest-file detection + extension census.
##     This module is option 1c.
##
## The pragmatic decision is to ship 1c now and document it as a
## heuristic. For 95%+ of workspaces the manifest-file signal alone is
## load-bearing (``Cargo.toml`` ⇒ Rust, ``pyproject.toml`` ⇒ Python,
## etc.); the extension census picks up the rest where a project has no
## manifest (``c-cpp-make`` with a bare ``Makefile`` lacking a manifest
## marker, a Nim package without a ``.nimble``, etc.).
##
## The standard-provider's actual ``recognize`` remains the source of
## truth at build time — this heuristic is for diagnostics only.

import std/[algorithm, os, osproc, strutils, tables]

import ./project_file

type
  ConventionAttribution* = object
    ## The conclusion the heuristic reached for a single target
    ## directory.
    convention*: string
      ## One of ``KnownConventionRegistry`` (``nim`` / ``rust`` / etc.)
      ## or the empty string when no convention matched.
    evidence*: string
      ## Short human-readable explanation of why this convention was
      ## picked (the manifest file that fired, the extension census
      ## ratios, etc.). Surfaced in ``repro show-conventions`` text
      ## output so the user can audit the heuristic.

  UnclaimedDirectory* = object
    ## A directory that looked target-shaped (under ``apps/``, ``libs/``,
    ## ``cmd/``, ``tools/``, or holding source-ish files at the
    ## workspace root) but no language convention's heuristic claimed
    ## it.
    relPath*: string
      ## Path relative to the workspace root, forward-slash separated.
    reason*: string
      ## Why the heuristic rejected this directory ("no manifest and no
      ## recognised source extensions", "matched <lang> extensions but
      ## no <lang> manifest file", ...).
    sampleFiles*: seq[string]
      ## Up to a handful of filenames from inside the directory,
      ## stripped of the workspace prefix. Surfaced for grep-ability in
      ## the diagnostic output.

  ToolchainProbeResult* = object
    ## Result of probing ``<tool> --version`` for a language. The probe
    ## is cached per ``(tool, args)`` tuple via ``probeToolchainCached``.
    available*: bool
      ## ``true`` when the tool was found on PATH and the subprocess
      ## exited zero with non-empty output.
    version*: string
      ## First non-empty line of the captured ``stdout+stderr``.
      ## Empty when ``available`` is ``false``.
    path*: string
      ## Absolute path the tool resolved to via ``findExe``. Empty when
      ## the tool isn't on PATH.

# ----------------------------------------------------------------------
# Convention attribution. The order in ``attributeConvention`` mirrors
# the dispatch order in the standard-provider binary
# (``addDefaultConvention(nim …); rust …; go …; python …;
# javascript_typescript …; c_cpp_autotools …; c_cpp_cmake …;
# c_cpp_meson …; c_cpp_make …``). When multiple manifests coexist in a
# target directory the order here decides who wins — same as the live
# registry.
# ----------------------------------------------------------------------

const
  ## Manifest files that uniquely identify a language convention. The
  ## table is ``(filename, convention-name)`` and the same filename
  ## never appears under two conventions — these are point-of-truth
  ## indicators (``Cargo.toml`` is Rust; nothing else uses it).
  ##
  ## The Nim entry is ``*.nimble`` — we look for any file ending in
  ## ``.nimble`` at the top level since ``.nimble`` files are named
  ## after the package (``foo.nimble``). That tail-match is handled
  ## inline in ``attributeConvention``; the table itself uses the
  ## special sentinel ``"*.nimble"`` so iteration order still decides
  ## tie-breaking against other manifests.
  ManifestSignals: array[23, tuple[fileName, convention: string]] = [
    ("*.nimble",           "nim"),
    ("Cargo.toml",         "rust"),
    ("go.mod",             "go"),
    ("pyproject.toml",     "python"),
    ("setup.py",           "python"),
    ("setup.cfg",          "python"),
    ("package.json",       "javascript-typescript"),
    ("tsconfig.json",      "javascript-typescript"),
    ("configure.ac",       "c-cpp-autotools"),
    ("configure.in",       "c-cpp-autotools"),
    ("Makefile.am",        "c-cpp-autotools"),
    ("CMakeLists.txt",     "c-cpp-cmake"),
    ("meson.build",        "c-cpp-meson"),
    ("pom.xml",            "java-maven"),
    ("build.gradle.kts",   "kotlin-gradle"),
    ("build.gradle",       "kotlin-gradle"),
    ("*.csproj",           "csharp-dotnet"),
    ("Package.swift",      "swift-swiftpm"),
    ("dune-project",       "ocaml-dune"),
    ("*.cabal",            "haskell-cabal"),
    ("Makefile",           "c-cpp-make"),
    ("makefile",           "c-cpp-make"),
    ("GNUmakefile",        "c-cpp-make"),
  ]

  ## Per-extension language attribution. We track a coarse "this dir is
  ## mostly <lang>" heuristic from the extension census; the table here
  ## maps lowercase extensions (with the leading dot) to a convention
  ## name.
  ExtensionSignals: array[28, tuple[ext, convention: string]] = [
    (".nim",   "nim"),
    (".rs",    "rust"),
    (".go",    "go"),
    (".py",    "python"),
    (".ts",    "javascript-typescript"),
    (".tsx",   "javascript-typescript"),
    (".js",    "javascript-typescript"),
    (".jsx",   "javascript-typescript"),
    (".mjs",   "javascript-typescript"),
    (".cjs",   "javascript-typescript"),
    (".c",     "c-cpp-make"),
    (".cc",    "c-cpp-make"),
    (".cpp",   "c-cpp-make"),
    (".cxx",   "c-cpp-make"),
    (".h",     "c-cpp-make"),
    (".java",  "java-maven"),
    (".kt",    "kotlin-gradle"),
    (".cs",    "csharp-dotnet"),
    (".swift", "swift-swiftpm"),
    (".f90",   "fortran-direct"),
    (".f95",   "fortran-direct"),
    (".f03",   "fortran-direct"),
    (".f08",   "fortran-direct"),
    (".zig",   "zig-direct"),
    (".ml",    "ocaml-dune"),
    (".mli",   "ocaml-dune"),
    (".hs",    "haskell-cabal"),
    (".lhs",   "haskell-cabal"),
  ]

proc isExtensionForConvention*(ext, convention: string): bool =
  ## Test hook + helper. ``ext`` is matched case-insensitively (the
  ## extension census itself lowercases input).
  let lower = ext.toLowerAscii
  for entry in ExtensionSignals:
    if entry.ext == lower and entry.convention == convention:
      return true
  false

proc dirFileCensus(dir: string;
                   maxEntries: int = 200): tuple[total: int;
                                                 perConvention:
                                                   Table[string, int];
                                                 samples: seq[string]] =
  ## Walk ``dir`` (one level deep + a bounded ``src/`` peek) and count
  ## files by convention. Returns the total file count, a per-convention
  ## frequency table, and up to 6 sample filenames for diagnostics.
  ## The walk is bounded (``maxEntries``) so a pathologically large
  ## directory doesn't gum up ``repro show-conventions``.
  result.perConvention = initTable[string, int]()
  if not dirExists(dir):
    return
  var queue: seq[string] = @[dir]
  var depth: Table[string, int]
  depth[dir] = 0
  while queue.len > 0 and result.total < maxEntries:
    let cur = queue[0]
    queue.delete(0)
    let curDepth = depth.getOrDefault(cur, 0)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        if basename.startsWith("."):
          continue
        case kind
        of pcFile, pcLinkToFile:
          # Skip the workspace project files (``repro.nim`` /
          # ``reprobuild.nim`` / ``repro.scanned-deps.nim``) so they
          # don't pollute the extension census toward ``nim``. The
          # project file's presence is a manifest signal handled by
          # ``attributeConvention``'s pass 1; counting it again at the
          # extension level would tip the tie-break against the real
          # source language in Mode 3 mixed workspaces. M30: this was
          # observable on rust-mode3 fixtures where 2 ``.rs`` files
          # tied 2 workspace ``.nim`` files and alphabetic ordering
          # mis-attributed the target to ``nim``.
          if basename == "repro.nim" or basename == "reprobuild.nim" or
              basename == "repro.scanned-deps.nim":
            continue
          inc result.total
          let ext = splitFile(basename).ext.toLowerAscii
          if ext.len > 0:
            for entry in ExtensionSignals:
              if entry.ext == ext:
                result.perConvention.mgetOrPut(entry.convention, 0) += 1
                break
          if result.samples.len < 6:
            result.samples.add(basename)
          if result.total >= maxEntries:
            break
        of pcDir, pcLinkToDir:
          if curDepth >= 2:
            continue
          if basename in ["target", "node_modules", ".repro", ".git",
              "build", ".nimcache", ".cargo", "dist", "__pycache__"]:
            continue
          # Peek into ``src/`` / direct children — extension census
          # is dominated by manifest-dir + ``src/`` content. M32:
          # also peek into a Python flat-layout package dir (``foo/``
          # at depth 1 contains ``__init__.py``) so Mode 3 Python
          # workspaces with the ``<member>/<member>/__init__.py``
          # layout surface their ``.py`` files in the census.
          if curDepth == 0 or basename == "src":
            queue.add(path)
            depth[path] = curDepth + 1
          elif curDepth == 1 and
              fileExists(path / "__init__.py"):
            queue.add(path)
            depth[path] = curDepth + 1
    except OSError:
      discard

proc attributeConvention*(targetDir: string): ConventionAttribution =
  ## Decide which language convention most likely claims ``targetDir``.
  ##
  ## Algorithm:
  ##   1. Walk the directory's top-level files; if a manifest filename
  ##      from ``ManifestSignals`` is present, that convention wins.
  ##      Order in ``ManifestSignals`` decides ties (Cargo.toml +
  ##      package.json in the same dir → Rust because Rust is listed
  ##      first; matches the standard-provider dispatch order).
  ##   2. Otherwise, run a file-extension census over the top level +
  ##      ``src/``. The convention with the highest file count wins.
  ##   3. If neither step picks a convention, return the empty string.
  ##
  ## Returns a ``ConventionAttribution`` whose ``evidence`` field always
  ## documents *why* the picker fired (or didn't).
  if not dirExists(targetDir):
    result.convention = ""
    result.evidence = "directory does not exist"
    return
  # Pass 1: manifest detection. Walk top-level entries once and record
  # which manifests are present. We also note any ``*.nimble`` and
  # ``*.csproj`` for the glob-match sentinels.
  var presentManifests: seq[string] = @[]
  var nimbleSeen = ""
  var csprojSeen = ""
  var cabalSeen = ""
  try:
    for kind, path in walkDir(targetDir):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let basename = extractFilename(path)
      if basename.toLowerAscii.endsWith(".nimble") and nimbleSeen.len == 0:
        nimbleSeen = basename
      if basename.toLowerAscii.endsWith(".csproj") and csprojSeen.len == 0:
        csprojSeen = basename
      if basename.toLowerAscii.endsWith(".cabal") and cabalSeen.len == 0:
        cabalSeen = basename
      for entry in ManifestSignals:
        if entry.fileName == basename:
          presentManifests.add(basename)
  except OSError:
    discard
  # Walk ``ManifestSignals`` in declared order so dispatch order wins.
  for entry in ManifestSignals:
    if entry.fileName == "*.nimble":
      if nimbleSeen.len > 0:
        result.convention = entry.convention
        result.evidence = "manifest: " & nimbleSeen
        return
      continue
    if entry.fileName == "*.csproj":
      # M42: ``*.csproj`` is the .NET SDK-style project filename
      # pattern (e.g. ``hello.csproj``). The csharp-dotnet convention
      # additionally requires ``packages.lock.json`` at the project
      # root for the offline-build guarantee, but the attribution
      # heuristic here is intentionally manifest-presence-only —
      # ``packages.lock.json`` absence is a "no manifest" condition
      # that the heuristic's evidence string honestly reports as
      # ``csharp-dotnet`` (so ``repro show-conventions`` still tells
      # the user which convention WOULD claim the project once the
      # lockfile is generated).
      if csprojSeen.len > 0:
        result.convention = entry.convention
        result.evidence = "manifest: " & csprojSeen
        return
      continue
    if entry.fileName == "*.cabal":
      # M55: ``*.cabal`` is the Haskell Cabal package manifest filename
      # pattern (e.g. ``hello.cabal`` — the filename varies per
      # package). The haskell-cabal convention additionally requires
      # both ``haskell``/``ghc`` AND ``cabal`` tokens in ``uses:`` for
      # full dispatch, but the attribution heuristic here is
      # intentionally manifest-presence-only — token absence is a
      # "no manifest" condition that the heuristic's evidence string
      # honestly reports as ``haskell-cabal`` (so
      # ``repro show-conventions`` still tells the user which
      # convention WOULD claim the project once the uses block is
      # filled in).
      if cabalSeen.len > 0:
        result.convention = entry.convention
        result.evidence = "manifest: " & cabalSeen
        return
      continue
    if entry.fileName in presentManifests:
      result.convention = entry.convention
      result.evidence = "manifest: " & entry.fileName
      return
  # Pass 2: extension census.
  let census = dirFileCensus(targetDir)
  if census.total == 0:
    result.convention = ""
    result.evidence = "no files found"
    return
  if census.perConvention.len == 0:
    result.convention = ""
    result.evidence = "no recognised source extensions (" &
      $census.total & " files)"
    return
  var bestName = ""
  var bestCount = 0
  for k, v in census.perConvention.pairs:
    if v > bestCount or (v == bestCount and k < bestName):
      bestName = k
      bestCount = v
  # Refinement for Mode 3 C/C++: when the extension census picks
  # ``c-cpp-make`` but NO Makefile (or CMakeLists / configure.ac) is
  # present at the target root, the project actually routes to the
  # Mode 3 ``c-cpp-direct`` convention. Re-attribute so
  # ``repro show-conventions`` reflects what the standard-provider
  # dispatch will actually do at build time.
  if bestName == "c-cpp-make":
    let hasMakefile = fileExists(targetDir / "Makefile") or
      fileExists(targetDir / "GNUmakefile") or
      fileExists(targetDir / "makefile")
    let hasCmake = fileExists(targetDir / "CMakeLists.txt")
    let hasMeson = fileExists(targetDir / "meson.build")
    let hasAutotools = fileExists(targetDir / "configure.ac") or
      fileExists(targetDir / "configure.in") or
      fileExists(targetDir / "Makefile.am")
    if hasCmake and not hasAutotools:
      # M38: when CMakeLists.txt is present alongside .c sources but no
      # autotools artefacts, route through the M38 ``c-cpp-cmake`` Tier
      # 2b convention rather than the Make convention (which would
      # reject the project for CMakeLists.txt presence anyway).
      bestName = "c-cpp-cmake"
    elif hasMeson and not hasAutotools and not hasCmake:
      # M39: when meson.build is present alongside .c sources but no
      # autotools/cmake artefacts, route through the M39 ``c-cpp-meson``
      # Tier 2b convention rather than the Make convention (which
      # rejects the project for meson.build presence in any case).
      bestName = "c-cpp-meson"
    elif not hasMakefile and not hasCmake and not hasMeson and not hasAutotools:
      bestName = "c-cpp-direct"
  # M30 refinement for Mode 3 Rust: same shape as the C/C++ refinement
  # above. When the extension census picks ``rust`` (i.e. ``.rs``
  # files dominate the target dir) but NO ``Cargo.toml`` is present
  # at the target root OR at the workspace root containing it, the
  # project routes through the Mode 3 ``rust-direct`` convention. Mode
  # 3 is in-workspace only, so we don't need to walk further up the
  # ancestry for a workspace ``Cargo.toml`` (Mode 2's Cargo workspace
  # support handles that ancestor case via its own ``recognize``).
  if bestName == "rust":
    if not fileExists(targetDir / "Cargo.toml"):
      bestName = "rust-direct"
  # M31 refinement for Mode 3 Go: when the extension census picks
  # ``go`` (i.e. ``.go`` files dominate the target dir) but NO
  # ``go.mod`` is present at the target root, the project routes
  # through the Mode 3 ``go-direct`` convention. Mirror of the C/C++
  # and Rust refinements above.
  if bestName == "go":
    if not fileExists(targetDir / "go.mod"):
      bestName = "go-direct"
  # M32 refinement for Mode 3 Python: when the extension census picks
  # ``python`` (i.e. ``.py`` files dominate the target dir) but NO
  # ``pyproject.toml`` / ``setup.py`` / ``setup.cfg`` is present at
  # the target root, the project routes through the Mode 3
  # ``python-direct`` convention. Mirror of the C/C++, Rust, and Go
  # refinements above.
  if bestName == "python":
    if not fileExists(targetDir / "pyproject.toml") and
        not fileExists(targetDir / "setup.py") and
        not fileExists(targetDir / "setup.cfg"):
      bestName = "python-direct"
  # M33 refinement for Mode 3 JS/TS: when the extension census picks
  # ``javascript-typescript`` (i.e. ``.ts`` / ``.js`` / etc. files
  # dominate the target dir) but NO ``package.json`` / ``tsconfig.json``
  # / bundler config is present at the target root, the project routes
  # through the Mode 3 ``jsts-direct`` convention. Mirror of the
  # C/C++, Rust, Go, and Python refinements above.
  if bestName == "javascript-typescript":
    if not fileExists(targetDir / "package.json") and
        not fileExists(targetDir / "tsconfig.json") and
        not fileExists(targetDir / "vite.config.js") and
        not fileExists(targetDir / "vite.config.ts") and
        not fileExists(targetDir / "vite.config.mjs") and
        not fileExists(targetDir / "webpack.config.js") and
        not fileExists(targetDir / "webpack.config.ts") and
        not fileExists(targetDir / "rollup.config.js") and
        not fileExists(targetDir / "rollup.config.ts"):
      bestName = "jsts-direct"
  result.convention = bestName
  result.evidence = "extension census: " & $bestCount & "/" &
    $census.total & " files match " & bestName

# ----------------------------------------------------------------------
# No-match diagnostics. Walk the workspace's "target-shaped" parents
# (``apps/``, ``libs/``, ``cmd/``, ``tools/``, ``pkg/``) plus the
# workspace root, and report any direct child directory that the
# heuristic didn't claim.
# ----------------------------------------------------------------------

const
  TargetShapedParents = ["apps", "libs", "cmd", "tools", "pkg"]
    ## Mode-1 layout slots from the spec §"Mode 1 — layout-as-manifest".
    ## A subdir of any of these is assumed to be a candidate target.

proc isLikelyTargetDir(dir: string): bool =
  ## True when ``dir`` has any file content at all (after filtering out
  ## hidden/dotfile noise). Used to skip empty placeholder dirs from
  ## the no-match output.
  if not dirExists(dir):
    return false
  try:
    for kind, path in walkDir(dir):
      let basename = extractFilename(path)
      if basename.startsWith("."):
        continue
      case kind
      of pcFile, pcLinkToFile:
        return true
      of pcDir, pcLinkToDir:
        if basename in ["target", "node_modules", ".repro", ".git",
            "build", ".nimcache", ".cargo", "dist", "__pycache__"]:
          continue
        # A non-empty subdir is enough evidence the user intended this
        # to be a target slot.
        return true
  except OSError:
    discard
  false

proc isClaimedHelper(absPath: string; claimedNorm: openArray[string]): bool =
  for claimed in claimedNorm:
    if absPath == claimed:
      return true
  false

proc bestConventionLabel(census: tuple[total: int;
                                       perConvention: Table[string, int];
                                       samples: seq[string]]): string =
  ## Used by the no-match diagnostic to attribute the "looks like X but
  ## no manifest" hint. Picks the convention with the highest file
  ## count; ties break on convention name (alphabetic) for
  ## determinism.
  var bestName = ""
  var bestCount = 0
  for k, v in census.perConvention.pairs:
    if v > bestCount or (v == bestCount and k < bestName):
      bestName = k
      bestCount = v
  bestName

proc hasManifestFile(absDir: string): bool =
  ## True when the dir contains a top-level manifest from
  ## ``ManifestSignals``. The no-match diagnostic flags any target-
  ## shaped dir that lacks a manifest, even if the extension census
  ## would have attributed a convention (the standard provider's
  ## ``recognize`` is manifest-driven at build time, so a sourceful
  ## dir with no manifest is still a build-time "no convention claimed
  ## it" — worth surfacing as a diagnostic).
  if not dirExists(absDir):
    return false
  try:
    for kind, path in walkDir(absDir):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let basename = extractFilename(path)
      if basename.toLowerAscii.endsWith(".nimble"):
        return true
      if basename.toLowerAscii.endsWith(".csproj"):
        return true
      if basename.toLowerAscii.endsWith(".cabal"):
        return true
      for entry in ManifestSignals:
        if entry.fileName == "*.nimble":
          continue
        if entry.fileName == "*.csproj":
          continue
        if entry.fileName == "*.cabal":
          continue
        if entry.fileName == basename:
          return true
  except OSError:
    discard
  false

proc inspectUnclaimed(absDir, relForReport: string;
                      acc: var seq[UnclaimedDirectory]) =
  ## Helper for ``findUnclaimedDirectories``. Hoisted out of the parent
  ## proc because Nim closures can't capture a ``result`` seq without
  ## tripping the memory-safety check.
  ##
  ## A directory is reported as a no-match when EITHER:
  ##   * the heuristic attributed no convention at all (no manifest +
  ##     no recognised extensions), OR
  ##   * the extension census matched a language but no top-level
  ##     manifest is present (the standard provider's ``recognize`` is
  ##     manifest-driven; a sourceful dir without a manifest will fail
  ##     to match any convention at build time).
  ##
  ## Dirs that have BOTH a manifest AND content are considered claimed
  ## by the heuristic — those become positive attributions printed in
  ## the per-target section, not no-match diagnostics.
  if not isLikelyTargetDir(absDir):
    return
  if hasManifestFile(absDir):
    return
  let census = dirFileCensus(absDir)
  let reason =
    if census.total == 0:
      "no files found"
    elif census.perConvention.len == 0:
      "no language convention claimed it"
    else:
      bestConventionLabel(census) & " sources present but no manifest file"
  acc.add(UnclaimedDirectory(
    relPath: relForReport,
    reason: reason,
    sampleFiles: census.samples))

proc findUnclaimedDirectories*(workspaceRoot: string;
                               claimedPaths: openArray[string] = []):
                                 seq[UnclaimedDirectory] =
  ## Walk ``workspaceRoot``'s target-shaped slots and return every
  ## candidate directory that the attribution heuristic didn't claim.
  ##
  ## ``claimedPaths`` is the set of absolute directory paths that the
  ## scanner already attributed (typically the ``projectRoot`` of every
  ## ``WorkspaceMember``). Anything under one of these paths is
  ## considered handled and skipped.
  ##
  ## The result is deterministic — sorted by ``relPath`` (forward-slash
  ## normalised, lexicographic).
  result = @[]
  if not dirExists(workspaceRoot):
    return
  var claimedNorm: seq[string] = @[]
  for p in claimedPaths:
    let abs =
      try:
        absolutePath(p).replace('\\', '/')
      except OSError:
        p.replace('\\', '/')
    claimedNorm.add(abs)
  let absRoot =
    try:
      absolutePath(workspaceRoot).replace('\\', '/')
    except OSError:
      workspaceRoot.replace('\\', '/')

  # Inspect direct children under each target-shaped parent.
  for parent in TargetShapedParents:
    let parentAbs = workspaceRoot / parent
    if not dirExists(parentAbs):
      continue
    try:
      for kind, path in walkDir(parentAbs):
        if kind notin {pcDir, pcLinkToDir}:
          continue
        let basename = extractFilename(path)
        if basename.startsWith("."):
          continue
        let absChild =
          try:
            absolutePath(path).replace('\\', '/')
          except OSError:
            path.replace('\\', '/')
        if isClaimedHelper(absChild, claimedNorm):
          continue
        let rel = parent & "/" & basename
        inspectUnclaimed(path, rel, result)
    except OSError:
      discard

  # Also consider the workspace root itself if it has source-shaped
  # content but the scanner didn't pick it up (no project file, no
  # member). We only flag the root when the heuristic itself fails — a
  # successful attribution means the root is already understood by the
  # heuristic and the user can audit it via the registry list.
  if not isClaimedHelper(absRoot, claimedNorm):
    # Workspace root: only flag when it's NOT a parent that holds
    # target-shaped children (avoid double-counting an ``apps/``-only
    # repo as both root + every app).
    var hasTargetParent = false
    for parent in TargetShapedParents:
      if dirExists(workspaceRoot / parent):
        hasTargetParent = true
        break
    if not hasTargetParent and not hasManifestFile(workspaceRoot):
      let census = dirFileCensus(workspaceRoot)
      if census.total > 0:
        let reason =
          if census.perConvention.len == 0:
            "no language convention claimed it"
          else:
            bestConventionLabel(census) &
              " sources present but no manifest file"
        result.add(UnclaimedDirectory(
          relPath: ".",
          reason: reason,
          sampleFiles: census.samples))

  result.sort(proc (a, b: UnclaimedDirectory): int =
    cmp(a.relPath, b.relPath))

# ----------------------------------------------------------------------
# Toolchain probe. ``<tool> --version`` (or the language-specific
# equivalent) is invoked at most once per process per tool — cached in
# a module-local table.
# ----------------------------------------------------------------------

type
  ToolchainProbeSpec = object
    convention: string
    exeName: string
    versionArgs: seq[string]

const
  ToolchainProbeSpecs: array[20, ToolchainProbeSpec] = [
    ToolchainProbeSpec(convention: "nim",
                       exeName: "nim",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "rust",
                       exeName: "rustc",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "rust-direct",
                       exeName: "rustc",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "go",
                       exeName: "go",
                       versionArgs: @["version"]),
    ToolchainProbeSpec(convention: "go-direct",
                       exeName: "go",
                       versionArgs: @["version"]),
    ToolchainProbeSpec(convention: "python",
                       exeName: "python3",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "python-direct",
                       exeName: "python3",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "javascript-typescript",
                       exeName: "node",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "jsts-direct",
                       exeName: "node",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "c-cpp-autotools",
                       exeName: "autoconf",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "c-cpp-make",
                       exeName: "gcc",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "c-cpp-direct",
                       exeName: "gcc",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "fortran-direct",
                       exeName: "gfortran",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "java-maven",
                       exeName: "javac",
                       versionArgs: @["-version"]),
    ToolchainProbeSpec(convention: "kotlin-gradle",
                       exeName: "gradle",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "csharp-dotnet",
                       exeName: "dotnet",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "swift-swiftpm",
                       exeName: "swift",
                       versionArgs: @["--version"]),
    ToolchainProbeSpec(convention: "zig-direct",
                       exeName: "zig",
                       versionArgs: @["version"]),
    ToolchainProbeSpec(convention: "ocaml-dune",
                       exeName: "ocaml",
                       versionArgs: @["-version"]),
    ToolchainProbeSpec(convention: "haskell-cabal",
                       exeName: "ghc",
                       versionArgs: @["--numeric-version"]),
  ]

var toolchainProbeCache: Table[string, ToolchainProbeResult]
  ## Module-local cache keyed by ``convention``. The probe runs at most
  ## once per language per process — same shape as
  ## ``toolVersionFingerprint`` in the standard-provider's
  ## ``emit_cache.nim`` (we intentionally duplicate the small helper
  ## rather than pull the standard provider into the CLI's dep
  ## closure; ``repro_core`` is the lowest layer of the dep DAG).

proc resetToolchainProbeCache*() =
  ## Test hook only: clear the module-local probe cache so unit tests
  ## can assert on repeat-call caching. Production code never needs
  ## this — toolchain identity within a single CLI invocation is fixed.
  toolchainProbeCache = initTable[string, ToolchainProbeResult]()

proc firstNonEmptyLine(s: string): string =
  for line in s.splitLines():
    let stripped = line.strip()
    if stripped.len > 0:
      return stripped
  s.strip()

proc probeToolchainSpec(spec: ToolchainProbeSpec): ToolchainProbeResult =
  ## Run a single probe spec. Result is cached in
  ## ``toolchainProbeCache[spec.convention]``; second-and-later calls
  ## return the cached value without spawning.
  if toolchainProbeCache.hasKey(spec.convention):
    return toolchainProbeCache[spec.convention]
  result.available = false
  result.version = ""
  result.path = findExe(spec.exeName)
  if result.path.len == 0:
    toolchainProbeCache[spec.convention] = result
    return
  var argv = @[result.path]
  for a in spec.versionArgs:
    argv.add(a)
  try:
    let (output, exitCode) = execCmdEx(quoteShellCommand(argv),
      options = {poStdErrToStdOut, poUsePath})
    if exitCode == 0 and output.len > 0:
      result.version = firstNonEmptyLine(output)
      if result.version.len > 0:
        result.available = true
  except CatchableError:
    discard
  toolchainProbeCache[spec.convention] = result

proc probeToolchain*(convention: string): ToolchainProbeResult =
  ## Public entry point. Look up ``convention`` in the static spec
  ## table; return a probe result. Unknown conventions return a
  ## not-available result with the empty path/version (the CLI's
  ## diagnostic emitter prints the conventional "not on PATH (skipped)"
  ## fallback in that case).
  for spec in ToolchainProbeSpecs:
    if spec.convention == convention:
      return probeToolchainSpec(spec)
  return ToolchainProbeResult(available: false, version: "", path: "")
