## Haskell / Cabal language convention (Tier 2b) — M55.
##
## First **Phase 2** language convention. Opens the new-language-ecosystem
## sequence after the Phase 1 cluster (M40 java-maven, M41 kotlin-gradle,
## M42 csharp-dotnet, M43 swift-swiftpm, M46 ocaml-dune). Recognises a
## ``<name>.cabal`` package manifest at the project root and shells out
## to the stock ``cabal`` driver for a single offline
## ``cabal v2-build --offline -j1`` invocation. The action graph is
## intentionally coarse: one build action that produces
## ``dist-newstyle/build/<platform-tuple>/ghc-<ver>/<pkg>-<ver>/x/<exe>/
## build/<exe>/<exe>[.exe]`` per declared executable.
##
## **Distinction from a hypothetical future Tier 2c Haskell provider.**
## A Tier 2c Haskell provider would re-implement Cabal's per-module
## dep-ordering + (-)package-database resolution and lift individual
## ``ghc`` invocations into the reprobuild DAG. That heavyweight path is
## explicitly DEFERRED per the M55 spec — Cabal's heuristics are
## non-trivial to re-implement. M55 is strictly the lightweight Mode 2
## ecosystem-delegation sibling.
##
## **Recognition contract**:
##   * Exactly one ``<name>.cabal`` file at the project root (the Cabal
##     package manifest filename — uniquely identifies a Cabal package;
##     no other convention recognises this extension). The filename
##     varies per package (it's named after the package, e.g.
##     ``hello.cabal``); the convention scans the top level for any
##     file ending in ``.cabal``.
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists BOTH a Haskell compiler token AND ``cabal``
##     (the HARD precondition — mirrors M40's "both halves required"
##     and M46's "ocaml + dune" pattern; Cabal isn't a built-in part
##     of the GHC distribution per se, it's a separate ``cabal-install``
##     binary, and the convention won't dispatch unless both are
##     declared). Recognised compiler tokens: ``haskell`` / ``ghc``
##     (any one of the two counts as the compiler signal). The
##     ``cabal`` token is strictly required separately.
##   * Defers when ``stack.yaml`` is present at the project root —
##     Stack (Stackage) is the competing Haskell build tool which a
##     future ``haskell-stack`` sibling can handle. The presence of
##     ``stack.yaml`` is a strong signal that the user intends Stack
##     even when a ``.cabal`` file is also present (Stack projects
##     typically carry both).
##   * at least one ``executable`` member declared (library targets
##     are DEFERRED to a follow-up M; see Honest scope below).
##   * a ``ghc`` driver is on PATH.
##   * a ``cabal`` driver is on PATH.
##
## **Offline mode** (M55 keeps builds hermetic — Cabal's ``v2-build``
## sub-command supports ``--offline`` which disables Hackage access and
## forces resolution to use only the local store + any pre-populated
## ``cabal.project.freeze`` lockfile).
##   * The action runs ``cabal v2-build --offline -j1
##     --enable-relocatable``. The ``-j1`` pin keeps the build
##     deterministic (no race between parallel module-compile jobs) at
##     a small wall-clock cost; the convention prefers determinism for
##     the M55 fixture-and-test surface. A follow-up M may flip this to
##     ``-j auto`` for larger projects.
##   * Real-world projects pulling external Hackage dependencies should
##     run ``cabal v2-update`` once with network access BEFORE invoking
##     the convention to populate the Cabal store + any
##     ``cabal.project.freeze`` lockfile. The convention itself never
##     reaches the network.
##   * The M55 fixture is stdlib-only (depends on ``base`` only) so no
##     provisioning warm step is required for the fixture; the
##     convention can be exercised end-to-end without provisioning
##     external deps.
##
## **Emitted actions**:
##   1. ``haskell-cabal-build`` — single ``<cabal> v2-build --offline
##      -j1 --enable-relocatable`` action under the project root.
##      Inputs: the ``<name>.cabal`` manifest plus ``cabal.project`` /
##      ``cabal.project.freeze`` (when present) plus every ``.hs`` /
##      ``.lhs`` source file recursively walked under the project root
##      (excluding ``dist-newstyle/`` / ``.repro/`` / ``.git/``).
##      Outputs: one
##      ``dist-newstyle/build/<platform-tuple>/ghc-<ghc-ver>/<pkg>-<pkg-ver>/
##      x/<exe>/build/<exe>/<exe>[.exe]`` per declared executable. Uses
##      ``automaticMonitorPolicy`` (automatic monitoring is the spec
##      baseline for opaque tools, Reprobuild-Development M17): ``cabal
##      v2-build`` spawns ``ghc`` worker processes and the engine monitors
##      their real read-set instead of trusting only statically declared
##      inputs.
##
## **Output paths**:
##   * Executable: ``<projectRoot>/dist-newstyle/build/<platform-tuple>/
##     ghc-<ghcVersion>/<packageName>-<packageVersion>/x/<exeName>/
##     build/<exeName>/<exeName>[.exe]``.
##   * ``<platform-tuple>`` varies by host OS + arch (e.g.
##     ``x86_64-windows`` on Windows; ``x86_64-linux`` on Linux;
##     ``aarch64-osx`` on Apple Silicon macOS). The convention probes
##     ``ghc --print-host-platform`` at emit time to compute the exact
##     tuple, falling back to a sensible per-OS default when the probe
##     fails (the resolved path under ``.exe`` is still findable by
##     walking ``dist-newstyle/`` — the path-fragility note in the M55
##     spec).
##   * ``<ghcVersion>`` is parsed from ``ghc --numeric-version`` (e.g.
##     ``9.10.1``); fallback ``unknown`` if the probe fails.
##   * ``<packageName>`` / ``<packageVersion>`` parsed from the
##     ``.cabal`` manifest's ``name:`` / ``version:`` fields.
##   * On Windows the executable suffix is ``.exe``; on POSIX no suffix.
##     The convention emits the platform-appropriate suffix per the
##     host the convention is running on (matching SwiftPM's
##     ``.exe``-on-Windows pattern).
##
## **Honest scope** (deferred per M55 spec):
##   * Mode 3 Haskell — explicitly DEFERRED. The per-source ``ghc``
##     story requires re-implementing Cabal's package-database +
##     module-dep-ordering heuristics. Track as a future milestone if
##     demand surfaces.
##   * Library targets (``library`` stanza in ``.cabal``) — DEFERRED.
##     Haskell libraries live in ``dist-newstyle/`` as a per-package
##     installed-package-database entry; the path predication is more
##     involved than the executable case. M55 supports executables only.
##   * Multi-package cabal projects (``cabal.project`` with
##     ``packages: pkg1 pkg2``) — DEFERRED. M55 pins to a
##     single-package-per-project shape; multi-package projects can be
##     added in a follow-up M.
##   * ``cabal v2-test`` discovery — deferred to a follow-up M (mirrors
##     M40 / M41 / M42 / M43 / M46 deferral of test-task discovery).
##   * External Hackage dependencies — the convention assumes the
##     Cabal store is pre-populated (or that the package depends only
##     on ``base`` like the M55 fixture). A future M may add a
##     ``cabal.project.freeze`` hard-precondition mirroring M42's
##     ``packages.lock.json`` requirement.
##   * Stack (``stack.yaml`` + Stackage) — a future ``haskell-stack``
##     sibling will handle that ecosystem. The convention's
##     ``recognize`` defers when ``stack.yaml`` is present at the root.
##   * Legacy ``cabal build`` (v1-style) — out of scope per the M55
##     spec; only ``v2-*`` commands.
##   * Haskell↔C FFI (``foreign import ccall``) cross-language —
##     deferred.
##
## **Provisioning note**: on a development host that doesn't ship GHC +
## cabal (the M55 default on Windows — the dev shell doesn't currently
## bundle Haskell), the canonical install path is GHCup
## (``https://www.haskell.org/ghcup/``). On Windows the documented
## install command is the GHCup PowerShell bootstrapper. M55 pins
## ``GHC_VERSION=9.10.1`` + ``CABAL_VERSION=3.12.1.0``. Total dev-shell
## footprint ~1.2 GB (GHC is the heaviest single toolchain in the
## catalog). env.ps1 should prepend GHCup's ``%LOCALAPPDATA%\Programs\
## ghcup\bin\`` to PATH so ``ghc`` and ``cabal`` resolve via PATH (a
## follow-up provisioning milestone covers the full catalog work).
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M55.

import std/[algorithm, os, osproc, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## the M40 / M41 / M42 / M43 / M46 conventions' value, but M55
    ## doesn't actually use it as a build dir — Cabal writes to
    ## ``<projectRoot>/dist-newstyle/`` (its own convention). The
    ## constant is retained for consistency.

  CabalDistSubdir* = "dist-newstyle"
    ## Sub-directory under the project root where Cabal v2-* lays its
    ## build outputs. Hard-coded by Cabal (configurable via
    ## ``--builddir`` but not exercised by M55); the convention predicts
    ## the path under it.

  DefaultPlatformTupleWindows* = "x86_64-windows"
    ## Fallback platform tuple when ``ghc --print-host-platform`` is
    ## unavailable. Matches the Windows 64-bit GHC binary distribution.

  DefaultPlatformTuplePosix* = "x86_64-linux"
    ## Fallback platform tuple on POSIX hosts. The actual tuple varies
    ## by OS (Linux vs. macOS) and arch (x86_64 vs. aarch64) but
    ## ``x86_64-linux`` is the most common shape; the convention
    ## prefers the ``ghc --print-host-platform`` probe for accuracy.

type
  HaskellCabalMemberKind = enum
    hcmExecutable
    hcmLibrary

  HaskellCabalMember = object
    name: string
    kind: HaskellCabalMemberKind

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesHaskellCabal(source: string): bool =
  ## True when ``uses:`` lists BOTH a Haskell-compiler token AND
  ## ``cabal``. Mirrors M46 ocaml-dune's strict "both halves required"
  ## pattern. Recognised Haskell tokens: ``haskell`` / ``ghc`` (any
  ## one of the two counts as the compiler signal). The ``cabal``
  ## token is strictly required separately because cabal-install is
  ## a distinct binary from the GHC distribution.
  if source.len == 0:
    return false
  var sawHaskell = false
  var sawCabal = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "haskell" or token == "ghc":
      sawHaskell = true
    if token == "cabal" or token == "cabal-install":
      sawCabal = true
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
  sawHaskell and sawCabal

proc extractExecutables(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    if stripped.len > len("executable") and
        stripped[len("executable")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractLibraries(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("library"):
      continue
    if stripped.len > len("library") and
        stripped[len("library")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("library") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractMembers(source: string): seq[HaskellCabalMember] =
  for name in extractExecutables(source):
    result.add(HaskellCabalMember(name: name, kind: hcmExecutable))
  for name in extractLibraries(source):
    result.add(HaskellCabalMember(name: name, kind: hcmLibrary))

proc findCabalManifest*(projectRoot: string): string =
  ## Locate a ``<name>.cabal`` file at the project root. Returns the
  ## absolute path of the FIRST such file (deterministic — alphabetical
  ## order). Returns the empty string when no ``.cabal`` file is at the
  ## top level.
  ##
  ## Multi-cabal-file projects are atypical (and DEFERRED per the M55
  ## honest-scope cut); a single ``<pkg>.cabal`` is the common shape.
  if not dirExists(extendedPath(projectRoot)):
    return ""
  var candidates: seq[string] = @[]
  try:
    for kind, path in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let basename = extractFilename(path)
      if basename.toLowerAscii.endsWith(".cabal"):
        candidates.add(path)
  except OSError:
    return ""
  if candidates.len == 0:
    return ""
  candidates.sort(system.cmp[string])
  candidates[0]

proc hasCabalManifest(projectRoot: string): bool =
  findCabalManifest(projectRoot).len > 0

proc hasStackYaml(projectRoot: string): bool =
  ## True when ``<projectRoot>/stack.yaml`` exists. The convention
  ## defers to a future ``haskell-stack`` sibling when the Stack
  ## manifest is present at the root.
  fileExists(extendedPath(projectRoot / "stack.yaml"))

proc ghcExecutable(): string =
  ## Resolve a ``ghc`` driver on PATH. On Windows the binary is
  ## usually ``ghc.exe``; ``findExe`` resolves both shapes via
  ## PATHEXT.
  findExe("ghc")

proc cabalExecutable(): string =
  ## Resolve a ``cabal`` driver (cabal-install) on PATH. On Windows
  ## the binary is usually ``cabal.exe``; ``findExe`` resolves both
  ## shapes via PATHEXT.
  findExe("cabal")

proc haskellCabalRecognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasCabalManifest(projectRoot):
    return false
  if hasStackYaml(projectRoot):
    # Defer to a future haskell-stack sibling; mirrors the
    # M40-vs-M41 pom.xml-vs-gradle defer pattern.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesHaskellCabal(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # Only executables are supported in M55 — library-only projects
  # are deferred. ``recognize`` accepts the project as long as at
  # least one executable is declared (libraries alongside executables
  # are silently ignored at emit time).
  var sawExecutable = false
  for m in members:
    if m.kind == hcmExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if ghcExecutable().len == 0:
    return false
  if cabalExecutable().len == 0:
    return false
  true

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc parseCabalField*(manifestSource, field: string): string =
  ## Parse the first occurrence of a ``<field>:`` line from a Cabal
  ## manifest source. Returns the trimmed RHS or the empty string when
  ## the field isn't present. Cabal's manifest format is line-oriented
  ## (RFC-822-ish) so a simple line scan suffices for the top-level
  ## ``name:`` / ``version:`` fields.
  ##
  ## Note: this does NOT handle multi-line continuations or block
  ## stanzas — only the simple top-level ``<field>: <value>`` form which
  ## is sufficient for parsing the package's name and version.
  for rawLine in manifestSource.splitLines():
    var line = rawLine
    let commentIdx = line.find("--")
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    let lower = stripped.toLowerAscii
    let prefix = field.toLowerAscii & ":"
    if lower.startsWith(prefix):
      return stripped[prefix.len .. ^1].strip()
  ""

proc readCabalManifest(projectRoot: string): string =
  ## Read the discovered ``<name>.cabal`` file or return the empty
  ## string.
  let path = findCabalManifest(projectRoot)
  if path.len == 0:
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc parsePackageName*(projectRoot: string): string =
  ## Resolve the package name from the ``.cabal`` manifest's ``name:``
  ## field. Falls back to the manifest filename stem (e.g. ``hello``
  ## for ``hello.cabal``) when the field can't be parsed.
  let source = readCabalManifest(projectRoot)
  let parsed = parseCabalField(source, "name")
  if parsed.len > 0:
    return parsed
  let manifestPath = findCabalManifest(projectRoot)
  if manifestPath.len == 0:
    return ""
  let (_, name, _) = splitFile(manifestPath)
  name

proc parsePackageVersion*(projectRoot: string): string =
  ## Resolve the package version from the ``.cabal`` manifest's
  ## ``version:`` field. Falls back to ``0.0.0`` when unparseable.
  let source = readCabalManifest(projectRoot)
  let parsed = parseCabalField(source, "version")
  if parsed.len > 0:
    return parsed
  "0.0.0"

proc probeGhcNumericVersion*(ghcExe: string): string =
  ## Probe ``<ghc> --numeric-version`` and return the trimmed first
  ## line. Returns the empty string when the probe fails. Cached
  ## indirectly by the calling code (the convention re-resolves the
  ## probe per ``emitFragment`` invocation; the cost is acceptable
  ## given how rarely the convention fires).
  if ghcExe.len == 0:
    return ""
  try:
    let (output, exitCode) = execCmdEx(quoteShellCommand(@[ghcExe,
      "--numeric-version"]), options = {poStdErrToStdOut, poUsePath})
    if exitCode != 0:
      return ""
    for line in output.splitLines():
      let stripped = line.strip()
      if stripped.len > 0:
        return stripped
  except CatchableError:
    discard
  ""

proc probeGhcPlatformTuple*(ghcExe: string): string =
  ## Probe ``<ghc> --print-host-platform`` and return the trimmed first
  ## line. Returns a sensible per-OS default when the probe fails.
  ##
  ## GHC emits platform tuples like ``x86_64-w64-mingw32``,
  ## ``x86_64-unknown-linux``, ``aarch64-apple-darwin``. Cabal's
  ## ``dist-newstyle/`` layout further reshapes these to its own
  ## convention (e.g. ``x86_64-windows`` rather than
  ## ``x86_64-w64-mingw32``). The convention threads the GHC-reported
  ## tuple through unchanged because the convention's only consumer
  ## of the tuple is the predicted output path, and Cabal mirrors the
  ## GHC tuple verbatim in newer versions.
  if ghcExe.len > 0:
    try:
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[ghcExe,
        "--print-host-platform"]),
        options = {poStdErrToStdOut, poUsePath})
      if exitCode == 0:
        for line in output.splitLines():
          let stripped = line.strip()
          if stripped.len > 0:
            return stripped
    except CatchableError:
      discard
  when defined(windows):
    DefaultPlatformTupleWindows
  else:
    DefaultPlatformTuplePosix

proc producedExecutablePath*(projectRoot, platformTuple, ghcVersion,
                             packageName, packageVersion,
                             exeName: string): string =
  ## Predicted output path for a Cabal executable target. Cabal v2-*
  ## writes the executable into
  ## ``dist-newstyle/build/<platform-tuple>/ghc-<ghcVersion>/
  ## <packageName>-<packageVersion>/x/<exeName>/build/<exeName>/
  ## <exeName>[.exe]``.
  ##
  ## On Windows the binary suffix is ``.exe``; on POSIX it's no
  ## suffix. The convention emits the suffix appropriate for the host
  ## the convention runs on.
  let suffix =
    when defined(windows): ".exe"
    else: ""
  let pkgSlug = packageName & "-" & packageVersion
  let ghcSlug = "ghc-" & ghcVersion
  projectRoot / CabalDistSubdir / "build" / platformTuple / ghcSlug /
    pkgSlug / "x" / exeName / "build" / exeName / (exeName & suffix)

proc collectHaskellInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the build action: the
  ## ``<name>.cabal`` manifest plus ``cabal.project`` /
  ## ``cabal.project.freeze`` (when present) plus every ``.hs`` /
  ## ``.lhs`` source file recursively walked under the project root
  ## (excluding ``dist-newstyle/`` / ``.repro/`` / ``.git/``).
  ## Cabal-controlled subdirectories like ``dist-newstyle/`` MUST be
  ## skipped — they hold generated artefacts that change every build
  ## and would cause spurious cache misses if enumerated as inputs.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  let manifestPath = findCabalManifest(projectRoot)
  if manifestPath.len > 0:
    result.add(manifestPath)
  for extra in @["cabal.project", "cabal.project.freeze",
                 "cabal.project.local"]:
    let extraPath = projectRoot / extra
    if fileExists(extendedPath(extraPath)):
      result.add(extraPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["dist-newstyle", "dist", ".repro", ".git", ".stack-work",
             ".cabal", "node_modules"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          let lower = basename.toLowerAscii
          if lower.endsWith(".hs") or lower.endsWith(".lhs") or
              lower.endsWith(".hsc") or lower.endsWith(".hs-boot"):
            result.add(path)
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          stack.add(path)
    except OSError:
      discard
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitBuildAction(projectRoot, cabalExe, platformTuple,
                     ghcVersion, packageName, packageVersion: string;
                     execs: seq[string]): BuildActionDef =
  ## Emit the single ``cabal v2-build --offline -j1
  ## --enable-relocatable`` action. Outputs the predicted
  ## ``dist-newstyle/.../<exe>[.exe]`` path under the project root for
  ## each declared executable.
  ##
  ## ``v2-build`` is the modern Cabal command (Nix-style build store).
  ## ``--offline`` disables Hackage access (the M55 hermetic build
  ## guarantee). ``-j1`` keeps the build deterministic (single-threaded
  ## compile) at a small wall-clock cost; a follow-up M may flip to
  ## ``-j auto`` for larger projects. ``--enable-relocatable`` requests
  ## relocatable binaries (RPATH-friendly on POSIX; a no-op on Windows
  ## but harmless).
  var outputs: seq[string] = @[]
  for exe in execs:
    outputs.add(producedExecutablePath(projectRoot, platformTuple,
      ghcVersion, packageName, packageVersion, exe))
  if outputs.len > 0:
    createDir(extendedPath(parentDir(outputs[0])))
  let argv = @[cabalExe, "v2-build", "--offline", "-j1",
    "--enable-relocatable"]
  let inputs = collectHaskellInputs(projectRoot)
  buildAction(
    id = "haskell-cabal-build",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # ``cabal v2-build`` spawns ``ghc`` worker processes whose FS reads
    # aren't reliably observed via the Windows DLL-interpose path. Same
    # constraint M38/M39/M40/M41/M42/M43/M46 face for their configure /
    # package / build actions. Enumerate inputs explicitly via
    # ``collectHaskellInputs`` so per-source invalidation still works
    # without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "haskell-cabal.build")

proc syntheticPackage(projectRoot: string;
                      members: seq[HaskellCabalMember]): PackageDef =
  var name = "haskell_cabal_convention"
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

proc haskellCabalEmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  ## Convention entry — emit the single build action, hand the bundle
  ## to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "haskell-cabal convention: no executable members declared in " &
          projectFile & " (M55 supports executable targets only — " &
          "library targets are deferred)")
    var execs: seq[string] = @[]
    for m in members:
      if m.kind == hcmExecutable:
        execs.add(m.name)
    if execs.len == 0:
      raise newException(ValueError,
        "haskell-cabal convention: no executable members declared — " &
          "M55 supports executables only (library targets are deferred)")
    let ghcExe = ghcExecutable()
    if ghcExe.len == 0:
      raise newException(ValueError,
        "haskell-cabal convention: no 'ghc' on PATH (Haskell toolchain " &
          "required; install GHC + cabal via GHCup from " &
          "https://www.haskell.org/ghcup/ — M55 pins GHC 9.10.1 + " &
          "cabal-install 3.12.1.0)")
    let cabalExe = cabalExecutable()
    if cabalExe.len == 0:
      raise newException(ValueError,
        "haskell-cabal convention: no 'cabal' on PATH (cabal-install " &
          "required; install via GHCup from https://www.haskell.org/ghcup/)")
    if not hasCabalManifest(projectRoot):
      raise newException(ValueError,
        "haskell-cabal convention: no '<name>.cabal' file at project root " &
          projectRoot)
    if hasStackYaml(projectRoot):
      raise newException(ValueError,
        "haskell-cabal convention: 'stack.yaml' present at project root " &
          projectRoot & " — defers to a future haskell-stack convention " &
          "(Stack and Cabal projects are not interchangeable)")
    let packageName = parsePackageName(projectRoot)
    let packageVersion = parsePackageVersion(projectRoot)
    let ghcVersion = probeGhcNumericVersion(ghcExe)
    let platformTuple = probeGhcPlatformTuple(ghcExe)
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let buildAct = emitBuildAction(projectRoot, cabalExe,
        platformTuple,
        if ghcVersion.len > 0: ghcVersion else: "unknown",
        if packageName.len > 0: packageName else: "package",
        if packageVersion.len > 0: packageVersion else: "0.0.0",
        execs)
      defaultTarget(target("default", @[buildAct]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc haskellCabalConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "haskell-cabal",
    recognize: haskellCabalRecognize,
    emitFragment: haskellCabalEmitFragment)
