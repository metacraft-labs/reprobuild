## From-source CMake language convention (Tier 2b) — M9.L.1.
##
## Sibling of both the M38 ``c-cpp-cmake`` convention and the M9.L.0
## ``from-source-meson`` convention. Where ``c-cpp-cmake`` recognises
## in-tree CMake projects (``<projectRoot>/CMakeLists.txt`` exists),
## this convention recognises **from-source recipes** — the recipe
## declares a ``fetch:`` block (vendored / upstream tarball) and *no*
## ``CMakeLists.txt`` is present at projectRoot because the source has
## to be fetched + extracted first. The first such recipe is
## ``recipes/packages/source/kcoreaddons`` (the second is json-c, etc.).
##
## ## Recognition contract
##
## The convention claims a project when ALL of the following hold:
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists.
##   * ``uses:`` lists ``cmake``.
##   * The first ``package <ident>:`` block has a registered
##     ``DslFetchSpec`` (M9.H) AND a non-empty URL — i.e. the recipe
##     declared a ``fetch:`` block.
##   * At least one ``executable`` / ``library`` member is declared in
##     the recipe source.
##   * NO ``CMakeLists.txt`` at ``<projectRoot>`` (otherwise the existing
##     in-tree M38 ``c-cpp-cmake`` convention claims it).
##
## Tool availability (``cmake`` / ``ninja`` / ``gcc`` on PATH) is NOT
## gated by ``recognize``. The actions emitted by ``emitFragment``
## reference the resolved binaries via ``findExe`` lazily — the host
## may legitimately register a from-source recipe (so the unit + smoke
## tests round-trip) on a machine without cmake installed. The actual
## build step still requires the toolchain at execution time. This
## matches the from-source-meson sibling's behaviour.
##
## ## Pipeline
##
## ``emitFragment`` produces the following action chain:
##
##   1. **Fetch** (``ccpp-fetch-<package>``) — downloads the tarball at
##      the URL declared in ``fetch:``, verifies the sha256/blake3, and
##      extracts to ``<projectRoot>/src/`` (or the path declared in
##      ``extractedRoot``). Implemented by the shared
##      ``conventions/fetch_action.emitFetchAction`` helper.
##
##   2. **CMake configure** (``from-source-cmake-configure``) — invokes
##      ``cmake -S <srcDir> -B <buildDir> -G Ninja
##      -DCMAKE_BUILD_TYPE=Release <cmakeFlags...>``. ``cmakeFlags``
##      come from the M9.I ``registeredBuildFlags`` registry on the
##      ``"cmake"`` channel; order is preserved. Depends on the fetch
##      action.
##
##   3. **CMake build** (``from-source-cmake-build``) — invokes
##      ``cmake --build <buildDir>``. Depends on the configure action.
##
##   4. **CMake install** (``from-source-cmake-install``) — invokes
##      ``cmake --install <buildDir> --prefix <stagingDir>``. Depends on
##      the build action.
##
##   5. **Per-artifact stage-copy** (``from-source-cmake-stage-<member>``)
##      — copies the installed binary from
##      ``<stagingDir>/bin/<sanitisedMember>`` (or ``lib/`` for library
##      members) to ``<projectRoot>/.repro/output/<member>/<member>``.
##      One action per declared ``executable`` / ``library`` member.
##      Depends on the install action.
##
## ## Scratch layout
##
##   * Source extraction lives at ``<projectRoot>/src/`` (shared with
##     ``fetch_action``'s default extractedRoot).
##   * Build dir lives at
##     ``<projectRoot>/.repro/build/from-source-cmake/build/``.
##   * Staging dir lives at
##     ``<projectRoot>/.repro/build/from-source-cmake/staging/``.
##   * Per-artifact output lives at
##     ``<projectRoot>/.repro/output/<member>/<member>``.
##
## ## Binary-cache publishing (M9.L.4-refactor Step B)
##
## The install + stage-copy actions stamp
## ``BuildActionDef.publishToBinaryCache = true`` AND
## ``cacheEntryIdentity = some(computeCacheEntryIdentity(...))`` so the
## engine's ``BinaryCachePublisher`` hook publishes the install tree to
## ``repro-cache`` after a successful run. The convention no longer
## emits a publish edge of its own — see the meson convention's
## "Binary-cache publishing" section for the architectural rationale.
##
## ## Honest deferrals
##
##   * **End-to-end build run.** On hosts without ``cmake`` / ``ninja``
##     on PATH the convention still emits the action graph (so the unit
##     test exercises the wiring), but the run will fail at action
##     execution time. The ``scripts/validate-from-source-cmake-
##     kcoreaddons.ps1`` script is gated on cmake availability.
##   * **Installed-binary path resolution.** CMake's ``cmake --install``
##     uses ``--prefix`` as a relocation root: binaries land at
##     ``<prefix>/bin/<member>`` and libraries at ``<prefix>/lib/<...>``.
##     We pass ``--prefix <stagingDir>`` so paths are predictable; the
##     M9.L.1 vertical slice doesn't try to honour recipe-side
##     ``-DCMAKE_INSTALL_PREFIX=`` overrides in cmakeFlags (CMake's
##     ``--prefix`` on ``cmake --install`` is documented to override the
##     configure-time value regardless).
##   * **Multi-config backends.** Single-config (Ninja) only — same
##     deferral as the in-tree ``c-cpp-cmake`` sibling.
##   * **Library outputs.** Library member kinds emit a stage-copy that
##     looks under ``<stagingDir>/lib/`` instead of ``<stagingDir>/bin/``,
##     but the per-library archive path heuristic is not exhaustively
##     covered (KF6 / Qt-style libraries use SONAME-versioned files like
##     ``libKF6CoreAddons.so.6.10.0`` plus symlinks; the M9.L.1
##     vertical slice assumes ``lib<member>.a`` or
##     ``lib<member>.so`` shape). kcoreaddons (the M9.L.1 vertical
##     slice) is library-only.
##
## TODO(reprobuild-as-ninja-generator): the medium-term plan is to
## replace ``cmake -G Ninja`` with the reprobuild-cmake fork
## (https://github.com/metacraft-labs/reprobuild-cmake) so cmake
## emits a reprobuild-native recipe directly from its configured
## graph, gaining incremental compilation + HCR via reprobuild's
## scheduler. See CMake-Reprobuild-Generator.md and
## From-Source-Build-Recipes.md "Exception: build systems that can
## generate Ninja builds". Until that lands, run cmake → ninja
## via the regular ``cmake --build`` path.
##
## See ``reprobuild-specs/M9-DSL-Port-Engine-Provider.milestones.org``
## §M9.L.

import std/[os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

# M9.L.4-refactor Step B binary-cache identity wiring. The shared
# ``from_source_identity`` module owns the cache-key composition; this
# convention only supplies the convention tag (``"cmake"``) per stage-
# copy / install action. The Step-A-era publish-action emitter is gone
# — the engine's ``BinaryCachePublisher`` hook publishes transparently
# when ``BuildActionDef.publishToBinaryCache`` is true and
# ``cacheEntryIdentity`` is populated.
import std/options
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root — mirrors the
    ## in-tree c_cpp_* conventions and the from-source-meson sibling.

  FromSourceCmakeSubdir* = "from-source-cmake"
    ## Per-convention sub-directory under ``.repro/build/``. Lets a
    ## project simultaneously host an in-tree cmake build (the
    ## ``cmake`` subdir from ``c-cpp-cmake``) and a from-source build
    ## (this convention's subdir) without colliding.

  OutputDirName* = ".repro/output"
    ## Canonical per-artifact output dir. Mirrors the existing direct
    ## conventions' (c_cpp_direct etc.) shape.

type
  FromSourceCmakeMemberKind = enum
    fscExecutable
    fscLibraryStatic

  FromSourceCmakeMember = object
    name: string
    kind: FromSourceCmakeMemberKind

# ---------------------------------------------------------------------------
# Source helpers — shared verbatim with from_source_meson.nim. Copied
# (not imported) because c_cpp_cmake / c_cpp_meson keep the procs
# private; lifting them to a shared module would force a refactor and
# the existing convention tests need byte-identical recognise behaviour
# on the in-tree path.
# ---------------------------------------------------------------------------

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesCmake(source: string): bool =
  ## True when ``uses:`` lists ``cmake``. The from-source variant is
  ## intentionally less strict than the in-tree convention's ``cmake AND
  ## a C compiler`` rule: from-source recipes routinely depend on a C
  ## compiler implicitly via the build system + system toolchain, so
  ## requiring the recipe to spell ``gcc`` in ``uses:`` would reject
  ## legitimate recipes.
  ##
  ## Unlike the c_cpp_cmake sibling's parser, this variant tolerates
  ## inline ``## ...`` doc-comments INSIDE the ``uses:`` block (the
  ## production recipes routinely annotate every entry — see
  ## ``recipes/packages/source/kcoreaddons/repro.nim``). The block
  ## terminator is now "truly empty raw line" (zero chars after the
  ## ORIGINAL line is stripped) rather than "empty after comment-
  ## removal", so a ``    ## comment`` line stays inside the block.
  if source.len == 0:
    return false
  var inBlock = false
  var sawCmake = false
  proc consume(token: string) {.closure.} =
    if token == "cmake":
      sawCmake = true
  for rawLine in source.splitLines():
    if rawLine.strip().len == 0:
      if inBlock:
        inBlock = false
      continue
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      # The original line was non-empty but became empty after comment
      # stripping — it's a comment-only line inside an existing block.
      # Keep ``inBlock`` as-is and move on.
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
    # M9.R.5a: accept the renamed ``buildDeps:`` / ``nativeBuildDeps:``
    # block headers alongside the legacy ``uses:`` synonym. The from-
    # source-cmake convention needs to keep claiming cmake-driven
    # recipes after the M9.R.5a sweep moved every ``cmake`` entry into
    # ``nativeBuildDeps:`` (the BUILD-platform tools bucket).
    let blockHeader = block:
      if stripped.startsWith("uses:"): "uses:"
      elif stripped.startsWith("nativeBuildDeps:"): "nativeBuildDeps:"
      elif stripped.startsWith("buildDeps:"): "buildDeps:"
      else: ""
    if blockHeader.len > 0:
      let payload = stripped[blockHeader.len .. ^1].strip()
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
  sawCmake

proc extractMembers(source: string): seq[FromSourceCmakeMember] =
  ## Scan the recipe text for ``executable <name>:`` / ``library <name>:``
  ## declarations. Same shape as ``from_source_meson.extractMembers``;
  ## the from-source convention claims every executable/library declared
  ## anywhere in the recipe body.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = fscExecutable
    var verb = ""
    if stripped.startsWith("executable") and
        (stripped.len == len("executable") or
         stripped[len("executable")] in {' ', '\t'}):
      verb = "executable"
      kind = fscExecutable
    elif stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      verb = "library"
      kind = fscLibraryStatic
    else:
      continue
    let rest = stripped[verb.len .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(FromSourceCmakeMember(name: name, kind: kind))

proc extractFirstPackageName(source: string): string =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("package"):
      continue
    if stripped.len > len("package") and
        stripped[len("package")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("package") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      return name
  ""

proc hasCMakeListsTxt(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "CMakeLists.txt"))

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------

proc buildScratchDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceCmakeSubdir / "build"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

# M9.R.6.1: ``stagingDir`` / ``configureStampPath`` / ``buildStampPath``
# / ``installStampPath`` / ``artifactOutputDir`` / ``artifactOutputPath``
# / ``cmakeExecutable`` helpers + the 5-stage emit procs were removed
# alongside the legacy ``emitFragment`` body. Only the sentinel helpers
# below remain.

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc sentinelStampPath(projectRoot: string): string =
  buildScratchDir(projectRoot) / "from-source-cmake-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 fetchActionId, fetchStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  ## Emit the M9.R.6.1 narrowed synthesis sentinel. See
  ## ``from_source_meson.emitSynthesisSentinelAction`` for the rationale.
  createDir(extendedPath(parentDir(sentinelStampPath(projectRoot))))
  let stamp = sentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-cmake sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  let argv = @["sh", "-c", script]
  buildAction(
    id = "from-source-cmake-sentinel",
    call = inlineExecCall(argv, projectRoot),
    deps = @[fetchActionId],
    inputs = @[fetchStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-cmake.sentinel",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc registriesIncludeCmake(packageName: string): bool {.gcsafe.} =
  ## M9.R.6: structured-registry check. Replaces the source-text
  ## ``usesIncludesCmake`` parser for primary recognition. Reads
  ## ``registeredNativeBuildDeps(packageName)`` and matches when any
  ## constraint string's leading token is ``"cmake"``.
  {.cast(gcsafe).}:
    for raw in registeredNativeBuildDeps(packageName):
      let stripped = raw.strip()
      var head = ""
      for ch in stripped:
        if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
          break
        head.add(ch)
      if head == "cmake":
        return true
  false

proc fromSourceCmakeRecognize(projectRoot: string;
                              request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## M9.R.6: registry-based recognition. Reads
  ## ``registeredNativeBuildDeps`` (M9.R.1) for the ``"cmake"`` token
  ## as the primary signal, with the legacy source-text
  ## ``usesIncludesCmake`` scanner as a fallback.
  ##
  ## M9.N: claims a recipe based on DECLARATION (``fetch:`` registered +
  ## ``nativeBuildDeps:`` declares ``cmake`` + no in-tree
  ## ``CMakeLists.txt`` at projectRoot). NO host-PATH gate — the engine
  ## resolves tool identity AFTER recognise, possibly via cache
  ## substitute or source build.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if hasCMakeListsTxt(projectRoot):
    # In-tree project — the existing M38 ``c-cpp-cmake`` convention
    # claims this. The from-source variant intentionally yields so the
    # in-tree fixture tests don't change behaviour.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
    return false
  # M9.R.6: structured-registry check first; legacy text scanner is the
  # OR'd fallback so the recognise behaviour stays a superset.
  if not registriesIncludeCmake(dslPackageName) and
      not usesIncludesCmake(source):
    return false
  {.cast(gcsafe).}:
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      return false
  if extractMembers(source).len == 0:
    return false
  true

proc syntheticPackage(projectRoot: string;
                      members: seq[FromSourceCmakeMember]): PackageDef =
  var name = "from_source_cmake_convention"
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

proc fromSourceCmakeEmitFragment(projectRoot: string;
                                 request: ProviderGraphRequest):
                                   GraphFragment {.gcsafe.} =
  ## M9.R.6.1 narrowed emitFragment — emits exactly fetch + sentinel.
  ## See ``from_source_meson.fromSourceMesonEmitFragment`` for the
  ## rationale. The configure/build/install/stage-copy actions live in
  ## the recipe's explicit ``build:`` block via the M9.R.2b
  ## ``cmake_package(...)`` constructor.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "from-source-cmake convention: no executable or library " &
          "members declared in " & projectFile)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-cmake convention: no 'package <name>:' block in " &
          projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-cmake convention: no fetch: spec registered for " &
          "package '" & dslPackageName & "' — recognise() should have " &
          "rejected this project")
    let pkg = syntheticPackage(projectRoot, members)
    let identity = computeCacheEntryIdentity(projectRoot,
      dslPackageName, "cmake")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let sentinelAct = emitSynthesisSentinelAction(projectRoot,
        dslPackageName, fetchAct.id, fetchStamp, identity)
      allActions.add(sentinelAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceCmakeConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ##
  ## TODO(reprobuild-as-ninja-generator): once the ``reprobuild-cmake/``
  ## workspace fork lifts cmake's generator backend into reprobuild's
  ## DAG, this convention should perform per-source DAG lifting rather
  ## than shelling out to ``cmake --build``. Until that lands, the
  ## convention runs cmake → ninja via the regular ``cmake --build``
  ## path. The from-source-meson sibling has a similar potential
  ## optimisation via parsing the generated ``build.ninja``.
  LanguageConvention(
    name: "from-source-cmake",
    recognize: fromSourceCmakeRecognize,
    emitFragment: fromSourceCmakeEmitFragment)
