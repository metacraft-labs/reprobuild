## Generic crude-mode (Mode B) emitter for the standard provider.
##
## Conventions opt into Mode B by:
##
##   1. Setting ``LanguageConvention.crudeFallback`` to a closure that
##      delegates to ``emitCrudeFragment`` with the language's native
##      build-tool argv (``cargo build --release --locked --offline``,
##      ``go build ./...``, ``nimble build``, ...) and the conventional
##      output directories (``target``, ``build``, ``dist`` ...).
##
##   2. Detecting the fine-grained-incompatible shape inside their own
##      ``emitFragment`` (e.g. Rust's ``build.rs``) and invoking
##      ``crudeFallback(projectRoot, request)`` instead of returning the
##      Mode A fragment.
##
## The emitted fragment carries a *single* ``reprobuild.builtin.exec``
## action whose:
##
##   * ``argv`` is the native build tool's command line.
##   * ``cwd`` is the project root (the native tool relies on running
##     inside the project to find its manifest, lockfile, etc.).
##   * ``inputs`` enumerate the project source tree via ``walkDirRec``
##     filtered by ``inputGlob`` (defaulting to "everything"), with
##     ``outputDirs`` and the standard scratch / VCS directories pruned
##     so the action's own outputs don't appear as inputs.
##   * ``outputs`` are the conventional output dirs declared as opaque
##     directories. The engine treats them as preserve-tree roots so a
##     cold rebuild starts from a clean slate.
##   * ``dependencyPolicy`` is ``automaticMonitorPolicy()`` — the
##     io-monitor monitor (Filesystem-Policy-And-Observed-Inputs.md)
##     captures the actual reads/writes at runtime and the engine
##     promotes them to the action's effective inputs/outputs for cache
##     fingerprinting.
##   * ``pool`` is ``"compile"`` (one slot per native build, which is
##     itself usually internally parallel — Cargo and Go schedule
##     across cores on their own).
##   * ``cacheable`` is ``true`` — the action's fingerprint is the argv
##     + declared inputs + monitored inputs, all of which are stable
##     across rebuilds when nothing has changed.
##
## **Design decisions**:
##
## * The crude fragment goes through ``buildPackageFragment`` so the
##   produced ``GraphFragment`` has the same shape as a Mode A fragment.
##   The convention assembles a synthetic ``PackageDef`` carrying just
##   the supplied ``packageName`` — same pattern Nim/Rust/Go use for
##   their Mode A fragments, which also don't go through DSL evaluation.
##
## * ``inputGlob`` is intentionally narrow: it controls which files the
##   action declares as static inputs. The io-monitor monitor handles the
##   transitive case (Cargo registry caches, target/ writes, etc.) so
##   the static list only has to cover "everything under the project
##   root that a normal git tracker would see". The default ``["**/*"]``
##   means "every file"; pass narrower globs only when the convention
##   knows the build tool genuinely ignores some subtrees.
##
## * Output-dir pruning is path-prefix based, not glob based. The
##   action declares ``target`` (relative); we prune any file whose
##   absolute path begins with ``<projectRoot>/target/``. Same for the
##   stock prune list (``.repro``, ``.git``, ``node_modules``, ...).
##   Glob support would be overkill for the M6 scope — adding it later
##   is a non-breaking signature change.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl

const
  ## Directories pruned from the input enumeration regardless of what
  ## ``outputDirs`` lists. ``.repro`` is the engine's scratch root;
  ## ``.git`` / ``.hg`` / ``.svn`` are VCS metadata; the remaining
  ## entries are common native dependency caches and build-output
  ## directories from across the supported language ecosystems
  ## (Rust ``target`` / ``.cargo``, Python ``__pycache__`` / ``.venv`` /
  ## ``.tox`` / ``.pytest_cache`` / ``.mypy_cache``, JS/TS
  ## ``node_modules`` / ``.next`` / ``.nuxt``, JVM ``.gradle``, generic
  ## ``build`` / ``dist`` / ``coverage`` / ``htmlcov``). Per-convention
  ## ``outputDirs`` typically already cover one of these (Cargo declares
  ## ``target``); listing them here too is harmless and keeps the prune
  ## list useful for conventions that omit the declaration. Keep the
  ## list alphabetically sorted for diff-clean updates — anything not
  ## pruned here either ends up in the static input set or is captured
  ## by the io-monitor monitor.
  StockExcludeDirs* = [
    ".cargo",
    ".git",
    ".gradle",
    ".hg",
    ".mypy_cache",
    ".next",
    ".nuxt",
    ".pytest_cache",
    ".repro",
    ".svn",
    ".tox",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "htmlcov",
    "node_modules",
    "target",
    "venv"
  ]

proc normaliseRel(path: string): string =
  ## Normalise a relative path to forward slashes — keeps the exclude /
  ## glob matching cross-platform without forcing every caller to think
  ## about ``DirSep``.
  result = path.replace('\\', '/')
  while result.startsWith("./"):
    result = result[2 .. ^1]

proc startsWithSegment(rel, segment: string): bool =
  ## True when ``rel`` (forward-slash-normalised) begins with ``segment``
  ## followed by either nothing or a ``/``. Avoids the classic
  ## ``"target".startsWith("tar")`` misfire.
  if rel == segment:
    return true
  if rel.len <= segment.len:
    return false
  if not rel.startsWith(segment):
    return false
  rel[segment.len] == '/'

proc isExcludedDirSegment(rel: string;
                         excludeDirs: openArray[string]): bool =
  ## True when ``rel`` lives under any directory in ``excludeDirs``.
  for dir in excludeDirs:
    let normDir = normaliseRel(dir)
    if normDir.len == 0:
      continue
    if startsWithSegment(rel, normDir):
      return true
  false

proc fnmatchSimple(name, pattern: string): bool =
  ## Lightweight ``fnmatch``-style matcher: ``*`` matches any (possibly
  ## empty) substring, ``?`` matches any single char. No ``[...]``
  ## class support — the M6 fixtures don't need it. Kept as a local
  ## helper so the convention library is independent of which glob api
  ## the stdlib happens to ship.
  var i = 0
  var j = 0
  var starI = -1
  var starJ = 0
  while i < name.len:
    if j < pattern.len and (pattern[j] == '?' or pattern[j] == name[i]):
      inc i; inc j
    elif j < pattern.len and pattern[j] == '*':
      starI = i
      starJ = j
      inc j
    elif starI >= 0:
      inc starI
      i = starI
      j = starJ + 1
    else:
      return false
  while j < pattern.len and pattern[j] == '*':
    inc j
  j == pattern.len

proc inputGlobMatches(rel: string; patterns: openArray[string]): bool =
  ## Match ``rel`` against ``patterns``. Empty pattern list means "no
  ## pattern given" — treat as a permissive match so callers can pass
  ## ``[]`` to mean "everything". The default ``"**/*"`` and bare
  ## ``"*"`` also match everything. Anything else falls back to a
  ## lightweight ``fnmatchSimple`` ( ``*`` / ``?`` ) applied either to
  ## the full path (when the pattern contains ``/``) or to the basename
  ## otherwise. ``**/`` segments are stripped — the recursive walk
  ## already provides depth.
  if patterns.len == 0:
    return true
  for p in patterns:
    if p == "**/*" or p == "*":
      return true
    var pattern = p
    if pattern.startsWith("**/"):
      pattern = pattern[3 .. ^1]
    let tail = rel.extractFilename
    if pattern.contains('/'):
      if fnmatchSimple(rel, pattern):
        return true
    elif tail.len > 0 and fnmatchSimple(tail, pattern):
      return true
    elif rel == pattern:
      return true
  false

proc collectCrudeInputs(projectRoot: string;
                       outputDirs, inputGlob: openArray[string]): seq[string] =
  ## Enumerate every file under ``projectRoot`` that survives the
  ## exclude filters and matches ``inputGlob``. Returns absolute paths
  ## sorted so the declared input list is stable across rebuilds.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  var excludes = newSeq[string]()
  for e in StockExcludeDirs:
    excludes.add(e)
  for outDir in outputDirs:
    excludes.add(outDir)
  for entry in walkDirRec(projectRoot, yieldFilter = {pcFile}):
    let rel = normaliseRel(entry.relativePath(projectRoot))
    if rel.len == 0:
      continue
    if isExcludedDirSegment(rel, excludes):
      continue
    if not inputGlobMatches(rel, inputGlob):
      continue
    result.add(entry)
  result.sort(system.cmp[string])

proc crudeActionIdFor(packageName: string): string =
  ## Stable action id for the crude fallback. Sanitises ``packageName``
  ## so the id remains a valid Reprobuild action id even when the
  ## convention passes a name with hyphens / dots / non-ASCII chars.
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "package"
  "crude-build-" & sanitized

proc syntheticPackage(projectRoot, packageName: string): PackageDef =
  ## Minimal ``PackageDef`` for ``buildPackageFragment``. Same shape
  ## the Mode A conventions use — the runtime only reads ``packageName``
  ## and ``sourceFile`` from it.
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: packageName,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc emitCrudeFragment*(projectRoot: string;
                       request: ProviderGraphRequest;
                       packageName: string;
                       nativeBuildArgv: openArray[string];
                       outputDirs: openArray[string];
                       inputGlob: openArray[string] = ["**/*"]):
                         GraphFragment {.gcsafe.} =
  ## See module doc. Build the single-action Mode B fragment for
  ## ``packageName``. Idempotent — callers may invoke this repeatedly
  ## across requests; the action id is derived from ``packageName`` so
  ## two different packages don't collide in the engine's action store.
  ##
  ## The DSL runtime mutates module-level registries that aren't
  ## annotated ``gcsafe`` (they predate the provider host). Same shape
  ## as the Mode A conventions' ``cast(gcsafe)`` escape hatch.
  {.cast(gcsafe).}:
    if nativeBuildArgv.len == 0:
      raise newException(ValueError,
        "crude fallback: nativeBuildArgv must be non-empty (caller " &
        "supplied no command to delegate to)")
    let argvSeq = @nativeBuildArgv
    let outputsSeq = @outputDirs
    let inputs = collectCrudeInputs(projectRoot, outputsSeq, inputGlob)
    let absoluteOutputs = block:
      var acc: seq[string] = @[]
      for o in outputsSeq:
        if isAbsolute(o):
          acc.add(o)
        else:
          acc.add(projectRoot / o)
      acc
    let pkg = syntheticPackage(projectRoot, packageName)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let call = inlineExecCall(argvSeq, cwd = projectRoot)
      let action = buildAction(
        id = crudeActionIdFor(packageName),
        call = call,
        inputs = inputs,
        outputs = absoluteOutputs,
        pool = "compile",
        cacheable = true,
        dependencyPolicy = automaticMonitorPolicy(),
        commandStatsId = "standard-provider.crude")
      # Single-action target: register exactly ONE alias so the engine's
      # "direct target alias" bookkeeping (libs/repro_cli_support) doesn't
      # complain about two distinct target names pointing at the same
      # action. The Mode A conventions get away with both
      # ``target(pkgName, allActions)`` and ``defaultTarget(target("default", allActions))``
      # because each target carries >1 action and thus doesn't trigger
      # the single-action alias path.
      defaultTarget(target("default", action))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)
