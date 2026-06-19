## From-source Meson language convention (Tier 2b) — M9.L.0.
##
## Sibling of the M39 ``c-cpp-meson`` convention. Where ``c-cpp-meson``
## recognises in-tree meson projects (``<projectRoot>/meson.build``
## exists), this convention recognises **from-source recipes** — the
## recipe declares a ``fetch:`` block (vendored / upstream tarball) and
## *no* ``meson.build`` is present at projectRoot because the source has
## to be fetched + extracted first. The 74 ``recipes/packages/source/*``
## production recipes (dbus-broker, glib2, fontconfig, ...) all follow
## this shape.
##
## ## Recognition contract
##
## The convention claims a project when ALL of the following hold:
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists.
##   * ``uses:`` lists ``meson``.
##   * The first ``package <ident>:`` block has a registered
##     ``DslFetchSpec`` (M9.H) AND a non-empty URL — i.e. the recipe
##     declared a ``fetch:`` block.
##   * At least one ``executable`` / ``library`` member is declared in
##     the recipe source.
##   * NO ``meson.build`` at ``<projectRoot>`` (otherwise the existing
##     in-tree M39 ``c-cpp-meson`` convention claims it).
##
## Tool availability (``meson`` / ``ninja`` / ``gcc`` on PATH) is NOT
## gated by ``recognize``. The actions emitted by ``emitFragment``
## reference the resolved binaries via ``findExe`` lazily — the host
## may legitimately register a from-source recipe (so the unit + smoke
## tests round-trip) on a machine without meson installed. The actual
## build step still requires the toolchain at execution time.
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
##   2. **Meson setup** (``from-source-meson-setup``) — invokes
##      ``meson setup <buildDir> <srcDir> --buildtype=release
##      --backend=ninja <mesonOptions...>``. ``mesonOptions`` come from
##      the M9.I ``registeredBuildFlags`` registry on the ``"meson"``
##      channel; order is preserved. Depends on the fetch action.
##
##   3. **Meson compile** (``from-source-meson-compile``) — invokes
##      ``meson compile -C <buildDir>``. Depends on the setup action.
##
##   4. **Meson install** (``from-source-meson-install``) — invokes
##      ``meson install -C <buildDir> --destdir <stagingDir>``.
##      Depends on the compile action.
##
##   5. **Per-artifact stage-copy** (``from-source-meson-stage-<member>``)
##      — copies the installed binary from
##      ``<stagingDir>/usr/bin/<sanitisedMember>`` to
##      ``<projectRoot>/.repro/output/<member>/<member>``. One action
##      per declared ``executable``/``library`` member. Depends on the
##      install action.
##
## ## Binary-cache publishing (M9.L.4-refactor Step B)
##
## The install + stage-copy actions stamp
## ``BuildActionDef.publishToBinaryCache = true`` AND
## ``cacheEntryIdentity = some(computeCacheEntryIdentity(...))`` so the
## engine's ``BinaryCachePublisher`` hook (see
## ``libs/repro_build_engine/src/repro_build_engine.nim``
## §publishBinaryCacheBundle) uploads the install tree to ``repro-cache``
## after a successful run. The convention no longer emits a publish
## edge of its own — the Step A engine hook + this convention's passive
## metadata together replace the Step-A-era ``from-source-meson-publish-
## <pkg>`` action that lived in ``from_source_publish.nim`` before
## Step B. The 64-char hex cache-entry key is derived at run time by
## the publisher closure from the same ``CacheEntryIdentity`` tuple via
## ``cache_key.deriveCacheEntryKeyHex``.
##
## ## Scratch layout
##
##   * Source extraction lives at ``<projectRoot>/src/`` (shared with
##     ``fetch_action``'s default extractedRoot).
##   * Build dir lives at
##     ``<projectRoot>/.repro/build/from-source-meson/build/``.
##   * Staging dir lives at
##     ``<projectRoot>/.repro/build/from-source-meson/staging/``.
##   * Per-artifact output lives at
##     ``<projectRoot>/.repro/output/<member>/<member>``.
##
## ## Honest deferrals
##
##   * **End-to-end build run.** On hosts without ``meson`` / ``ninja``
##     on PATH the convention still emits the action graph (so the unit
##     test exercises the wiring), but the run will fail at action
##     execution time. The ``scripts/validate-from-source-meson-dbus-
##     broker.ps1`` script is gated on meson availability.
##   * **Installed-binary path resolution.** Meson's ``meson install``
##     defaults to ``${prefix}/bin/<member>`` where ``${prefix}`` is
##     ``/usr/local`` unless overridden. For the M9.L.0 vertical slice
##     we assume the recipe's mesonOptions don't override ``--prefix``;
##     a more general solution would parse ``-Dprefix=`` out of the
##     mesonOptions seq.
##   * **Multi-config backends.** Same deferral as the in-tree
##     ``c-cpp-meson`` sibling — ninja-only.
##   * **Library outputs.** Library member kinds emit a stage-copy that
##     looks under ``<stagingDir>/usr/lib/`` instead of ``usr/bin/``,
##     but the per-library archive path heuristic (``lib<name>.a`` vs
##     ``<name>.so`` vs ``<name>.dll``) is not exhaustively covered;
##     dbus-broker (the M9.L.0 vertical slice) is executable-only.
##   * **M9.L.4 publish — partial cache-key identity.** The v1
##     ``CacheEntryIdentity`` populates ``packageName`` (from the recipe
##     header), ``packageVersion`` (from the last entry of
##     ``registeredVersions(pkg)`` — empty when no ``versions:`` block
##     exists), ``providerRevision`` (BLAKE3 hex of the recipe bytes,
##     truncated to 32 chars), a hardcoded Linux x86_64 / GNU / glibc
##     ``PlatformTriple``, and a ``ToolchainIdentity`` whose ``name`` is
##     ``"meson"``. Deferred: ``sortedOptions`` (currently empty — the
##     M9.I mesonOptions registry needs to be projected into the
##     identity), ``sortedDepClosureDigest`` (currently empty — needs
##     cross-recipe dep resolution at emit time), host-specific platform
##     detection, toolchain version + host-ldso detection.
##   * **M9.L.4 publish — CLI path resolution.** The action argv
##     resolves the CLI via ``findExe("repro_binary_cache_client_cli")``
##     with a stable placeholder fallback. Hosts without the CLI built
##     soft-fail via the ``|| true`` wrapper; a follow-up can lift a
##     ``REPRO_BINARY_CACHE_CLIENT`` env-var override into the emitter.
##   * **M9.L.4 vertical-slice scope.** Only ``from_source_meson``
##     carries the publish action in this milestone; ``from_source_cmake``,
##     ``from_source_autotools``, and ``from_source_make`` follow in
##     M9.L.4.1 / L.4.2 / L.4.3.
##
## See ``reprobuild-specs/M9-DSL-Port-Engine-Provider.milestones.org``
## §M9.L.

import std/[os, strutils, tables]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

# M9.L.4-refactor Step B binary-cache identity wiring. The shared
# ``from_source_identity`` module owns the cache-key composition; the
# meson convention only supplies the convention tag (``"meson"``) per
# stage-copy / install action. Sibling conventions
# (``from_source_cmake`` / ``from_source_autotools`` /
# ``from_source_make``) share the same helper to keep the identity
# tuple's wiring single-sourced. The Step-A-era publish-action emitter
# is gone — the engine's ``BinaryCachePublisher`` hook publishes
# transparently when ``BuildActionDef.publishToBinaryCache`` is true
# and ``cacheEntryIdentity`` is populated.
import std/options
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root — mirrors the
    ## in-tree c_cpp_* conventions.

  FromSourceMesonSubdir* = "from-source-meson"
    ## Per-convention sub-directory under ``.repro/build/``. Lets a
    ## project simultaneously host an in-tree meson build (the
    ## ``meson`` subdir from ``c-cpp-meson``) and a from-source build
    ## (this convention's subdir) without colliding.

  OutputDirName* = ".repro/output"
    ## Canonical per-artifact output dir. Mirrors the existing direct
    ## conventions' (c_cpp_direct etc.) shape.

type
  FromSourceMesonMemberKind = enum
    fsmExecutable
    fsmLibraryStatic

  FromSourceMesonMember = object
    name: string
    kind: FromSourceMesonMemberKind

# ---------------------------------------------------------------------------
# Source helpers — shared verbatim with c_cpp_meson.nim. Copied (not
# imported) because c_cpp_meson keeps the procs private; lifting them to
# a shared module would force a refactor and the existing convention
# tests need byte-identical recognise behaviour on the in-tree path.
# ---------------------------------------------------------------------------

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesMeson(source: string): bool =
  ## True when ``uses:`` lists ``meson``. The from-source variant is
  ## intentionally less strict than the in-tree convention's ``meson AND
  ## a C compiler`` rule: from-source recipes routinely depend on a C
  ## compiler implicitly via the build system + system toolchain, so
  ## requiring the recipe to spell ``gcc`` in ``uses:`` would reject
  ## legitimate recipes.
  ##
  ## Unlike the c_cpp_meson sibling's parser, this variant tolerates
  ## inline ``## ...`` doc-comments INSIDE the ``uses:`` block (the
  ## production recipes routinely annotate every entry — see
  ## ``recipes/packages/source/dbus-broker/repro.nim``). The block
  ## terminator is now "truly empty raw line" (zero chars after the
  ## ORIGINAL line is stripped) rather than "empty after comment-
  ## removal", so a ``    ## comment`` line stays inside the block.
  if source.len == 0:
    return false
  var inBlock = false
  var sawMeson = false
  proc consume(token: string) {.closure.} =
    if token == "meson":
      sawMeson = true
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
    # M9.R.5a: the recipe sweep renamed ``uses:`` to ``buildDeps:`` and
    # split BUILD-platform tools into ``nativeBuildDeps:``. The recognise
    # parser accepts all three block headers so the from-source-meson
    # convention keeps claiming meson-driven recipes regardless of
    # whether ``meson`` lives under the legacy ``uses:`` synonym, the
    # canonical ``buildDeps:`` slot, or the new ``nativeBuildDeps:``
    # bucket (which is where the sweep put meson for every from-source
    # recipe — see ``recipes/packages/source/dbus-broker/repro.nim``).
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
  sawMeson

proc extractMembers(source: string): seq[FromSourceMesonMember] =
  ## Scan the recipe text for ``executable <name>:`` / ``library <name>:``
  ## declarations. Same shape as ``c_cpp_meson.extractMembers``; the
  ## from-source convention claims every executable/library declared
  ## anywhere in the recipe body.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = fsmExecutable
    var verb = ""
    if stripped.startsWith("executable") and
        (stripped.len == len("executable") or
         stripped[len("executable")] in {' ', '\t'}):
      verb = "executable"
      kind = fsmExecutable
    elif stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      verb = "library"
      kind = fsmLibraryStatic
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
      result.add(FromSourceMesonMember(name: name, kind: kind))

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

proc hasMesonBuild(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "meson.build"))

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------

proc buildScratchDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceMesonSubdir / "build"

proc stagingDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceMesonSubdir / "staging"

proc setupStampPath(projectRoot: string): string =
  ## A custom stamp file the setup action touches on success. The
  ## downstream compile / install actions key off the stamp instead of
  ## meson's ``build.ninja`` (which can be touched during compile too).
  buildScratchDir(projectRoot) / "from-source-meson-setup.stamp"

proc compileStampPath(projectRoot: string): string =
  buildScratchDir(projectRoot) / "from-source-meson-compile.stamp"

proc installStampPath(projectRoot: string): string =
  buildScratchDir(projectRoot) / "from-source-meson-install.stamp"

proc artifactOutputDir(projectRoot, member: string): string =
  projectRoot / OutputDirName / member

proc artifactOutputPath(projectRoot, member: string;
                        kind: FromSourceMesonMemberKind): string =
  case kind
  of fsmExecutable:
    when defined(windows):
      artifactOutputDir(projectRoot, member) / (member & ".exe")
    else:
      artifactOutputDir(projectRoot, member) / member
  of fsmLibraryStatic:
    artifactOutputDir(projectRoot, member) / ("lib" & member & ".a")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

# ---------------------------------------------------------------------------
# Tool discovery — lazy. ``recognize`` does NOT call these (per the
# module docstring): a host without meson can still register the
# convention, exercise it via tests, and lower the action graph; the
# actual build run will fail loudly at execution time.
# ---------------------------------------------------------------------------

proc mesonExecutable(): string =
  ## M9.N Batch B: emit the BARE tool name ``meson`` (not an absolute
  ## path returned by ``findExe``). The convention now stamps
  ## ``toolIdentityRefs = @["meson", ...]`` on every action it emits;
  ## the engine resolves that ref through its catalog at fork time and
  ## prepends the resolved bin directory to ``PATH``, so the bare
  ## ``meson`` argv-entry finds the right binary regardless of whether
  ## the host has meson installed.
  ##
  ## Pre-Batch-B the convention baked the host-resolved absolute path
  ## here, which produced an invalid argv on hosts without meson —
  ## the engine then tried to fork ``""`` and failed. With Batch B's
  ## env-plumbing in place, deferring resolution to the engine is the
  ## only honest shape: a host without meson now sees the engine fall
  ## through to the substitute / source-build path instead of
  ## tripping at recognise / emit time.
  "meson"

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc emitSetupAction(projectRoot, mesonExe, srcDir, buildDir: string;
                     mesonOptions: seq[string];
                     fetchDeps: seq[string];
                     fetchStamps: seq[string]):
                       tuple[action: BuildActionDef; stamp: string] =
  ## ``meson setup <buildDir> <srcDir> --buildtype=release
  ## --backend=ninja <mesonOptions...>``.
  ##
  ## The convention always passes ``--buildtype=release`` AND
  ## ``--backend=ninja`` as anchor flags. Recipes whose mesonOptions
  ## already include ``--buildtype=...`` will see meson honour the LAST
  ## occurrence (right-most wins) — this is consistent with the in-tree
  ## c_cpp_meson convention's behaviour.
  createDir(extendedPath(buildDir))
  let stamp = setupStampPath(projectRoot)
  # M9.N Batch B: emit bare ``sh`` so the engine's PATH plumbing
  # (via ``toolIdentityRefs``) resolves it through the catalog at
  # fork time. ``findExe`` is the legacy fallback only when the
  # caller didn't supply the ref list — once Batch B lands, every
  # action emitted here carries ``toolIdentityRefs``.
  let shExe = "sh"
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMeson = mesonExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedBuild = buildDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    var trailingOpts = ""
    for opt in mesonOptions:
      trailingOpts.add(" \"")
      trailingOpts.add(opt.replace("\"", "\\\""))
      trailingOpts.add("\"")
    let script = "set -e; \"" & escapedMeson & "\" setup \"" &
      escapedBuild & "\" \"" & escapedSrc &
      "\" --buildtype=release --backend=ninja" & trailingOpts &
      "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[mesonExe, "setup", buildDir, srcDir,
      "--buildtype=release", "--backend=ninja"]
    for opt in mesonOptions:
      argv.add(opt)
  var inputs: seq[string] = @[]
  for st in fetchStamps:
    inputs.add(st)
  let action = buildAction(
    id = "from-source-meson-setup",
    call = inlineExecCall(argv, projectRoot),
    deps = fetchDeps,
    inputs = inputs,
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-meson.setup",
    # M9.N Batch B: the setup action shells out via ``sh -c`` to
    # ``meson setup --backend=ninja`` which probes ``ninja`` and a
    # working C compiler at configure time. The engine resolves each
    # ref via the catalog and prepends the resolved bin dirs to PATH
    # at fork time, so the script's bare ``meson`` invocation finds
    # the right binary regardless of whether the host has meson
    # installed. ``sh`` is added so the shell-wrapped script path
    # itself is plumbed when the host lacks ``sh`` on PATH.
    toolIdentityRefs = @["meson", "ninja", "gcc", "sh"])
  (action, stamp)

proc emitCompileAction(projectRoot, mesonExe, buildDir, setupStamp: string):
                        tuple[action: BuildActionDef; stamp: string] =
  ## ``meson compile -C <buildDir>``. The stamp file lets downstream
  ## actions key off compile success without relying on meson's internal
  ## ``build.ninja`` touch behaviour.
  let stamp = compileStampPath(projectRoot)
  # M9.N Batch B: see emitSetupAction — bare ``sh`` is resolved via
  # ``toolIdentityRefs`` at fork time.
  let shExe = "sh"
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMeson = mesonExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedBuild = buildDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; \"" & escapedMeson & "\" compile -C \"" &
      escapedBuild & "\"; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[mesonExe, "compile", "-C", buildDir]
  let action = buildAction(
    id = "from-source-meson-compile",
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-meson-setup"],
    inputs = @[setupStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-meson.compile",
    # M9.N Batch B: same toolset as setup. ``meson compile`` re-invokes
    # the ninja backend (which in turn invokes the C compiler) and
    # shells out via ``sh -c``.
    toolIdentityRefs = @["meson", "ninja", "gcc", "sh"])
  (action, stamp)

proc emitInstallAction(projectRoot, mesonExe, buildDir, staging,
                       compileStamp: string;
                       identity: CacheEntryIdentity):
                         tuple[action: BuildActionDef; stamp: string] =
  ## ``meson install -C <buildDir> --destdir <staging>``.
  ##
  ## Meson's ``--destdir`` is the standard escape hatch for non-root
  ## installs: meson honours the recipe's ``--prefix`` setting but
  ## prefixes every install path with ``<destdir>``. For the M9.L.0
  ## slice we assume the default prefix ``/usr/local`` (or whatever
  ## the recipe pins via ``mesonOptions``) and harvest binaries from
  ## ``<staging><prefix>/bin/<member>``. See module docstring's "Honest
  ## deferrals" section for the limitations.
  ##
  ## M9.L.4-refactor Step B: stamps the binary-cache identity tuple on
  ## the install action so the engine's ``BinaryCachePublisher`` hook
  ## fires after a successful install. The convention is unaware of the
  ## CLI shape (publish argv / network) — that lives in the engine.
  createDir(extendedPath(staging))
  let stamp = installStampPath(projectRoot)
  # M9.N Batch B: see emitSetupAction — bare ``sh`` is resolved via
  # ``toolIdentityRefs`` at fork time.
  let shExe = "sh"
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMeson = mesonExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedBuild = buildDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStaging = staging.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; \"" & escapedMeson & "\" install -C \"" &
      escapedBuild & "\" --destdir \"" & escapedStaging &
      "\"; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[mesonExe, "install", "-C", buildDir, "--destdir", staging]
  let action = buildAction(
    id = "from-source-meson-install",
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-meson-compile"],
    inputs = @[compileStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-meson.install",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    # M9.N Batch B: ``meson install`` re-invokes the build system to
    # determine install targets; bare ``meson`` resolves via PATH.
    toolIdentityRefs = @["meson", "ninja", "sh"])
  (action, stamp)

proc dasherise(name: string): string =
  ## Heuristic camelCase → dash conversion: ``dbusBroker`` →
  ## ``dbus-broker``. Used to map a recipe-side member name to the
  ## meson-installed binary name. Limited to the M9.L.0 vertical slice
  ## (dbus-broker) — a follow-up milestone can lift a per-artifact
  ## ``installedAs:`` override into the DSL when more recipes surface
  ## naming mismatches.
  for i, ch in name:
    if ch in {'A' .. 'Z'} and i > 0:
      result.add('-')
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc stagedBinaryPath(staging, member: string;
                      kind: FromSourceMesonMemberKind): string =
  ## Heuristic guess at the meson-installed path. ``meson install
  ## --destdir <staging>`` lays binaries at ``<staging><prefix>/bin/...``.
  ## We assume the default prefix ``/usr/local`` per Meson's docs;
  ## recipes that override ``--prefix`` via mesonOptions will need an
  ## ``installPrefix:`` knob (deferred — see module docstring).
  let dashName = dasherise(member)
  case kind
  of fsmExecutable:
    when defined(windows):
      staging / "usr" / "local" / "bin" / (dashName & ".exe")
    else:
      staging / "usr" / "local" / "bin" / dashName
  of fsmLibraryStatic:
    staging / "usr" / "local" / "lib" / ("lib" & dashName & ".a")

proc emitStageCopyAction(projectRoot, staging, installStamp: string;
                         member: FromSourceMesonMember;
                         identity: CacheEntryIdentity): BuildActionDef =
  ## Copy ``<staging>/usr/local/bin/<member>`` to
  ## ``<projectRoot>/.repro/output/<member>/<member>``. This action is
  ## what the engine's output-collection step keys off — the canonical
  ## per-artifact output path matches the existing direct conventions'
  ## ``<root>/.repro/output/<name>/<name>`` schema.
  ##
  ## M9.L.4-refactor Step B: stamps the binary-cache identity tuple on
  ## the stage-copy action so the engine's ``BinaryCachePublisher`` hook
  ## fires after a successful per-artifact stage. The identity is the
  ## same value the install action carries — both edges contribute to
  ## the same logical cache entry.
  let outDir = artifactOutputDir(projectRoot, member.name)
  createDir(extendedPath(outDir))
  let outPath = artifactOutputPath(projectRoot, member.name, member.kind)
  let stagedPath = stagedBinaryPath(staging, member.name, member.kind)
  # M9.N Batch B: see emitSetupAction — bare ``sh`` is resolved via
  # ``toolIdentityRefs`` at fork time.
  let shExe = "sh"
  var argv: seq[string]
  if shExe.len > 0:
    let escapedStaged = stagedPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedOut = outPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedOutDir = outDir.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; mkdir -p \"" & escapedOutDir &
      "\"; cp -f \"" & escapedStaged & "\" \"" & escapedOut & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @["cp", stagedPath, outPath]
  let kindTag = case member.kind
    of fsmExecutable: "executable"
    of fsmLibraryStatic: "library-static"
  buildAction(
    id = "from-source-meson-stage-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-meson-install"],
    inputs = @[installStamp],
    outputs = @[outPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-meson.stage." & kindTag,
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    # M9.N Batch B: stage-copy is pure ``sh`` (mkdir + cp); no
    # toolchain refs needed.
    toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# M9.L.4-refactor Step B — the convention NO LONGER emits a publish
# action. The engine's ``BinaryCachePublisher`` hook (see
# ``libs/repro_build_engine/src/repro_build_engine.nim``) fires after
# every successful action that carries
# ``BuildAction.publishToBinaryCache = true`` AND
# ``cacheEntryIdentity.isSome``. The install + stage-copy actions above
# stamp both fields via the ``from_source_identity`` helper module so
# the engine publishes transparently when an instrumented producer
# build wires a non-nil publisher closure into its
# ``BuildEngineConfig``.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc registriesIncludeMeson(packageName: string): bool {.gcsafe.} =
  ## M9.R.6: structured-registry check. Replaces the source-text
  ## ``usesIncludesMeson`` parser for primary recognition. Reads
  ## ``registeredNativeBuildDeps(packageName)`` and matches when any
  ## constraint string's leading token is ``"meson"``. The registry is
  ## populated by the recipe macro at module-init time so the check
  ## fires reliably even when ``nativeBuildDeps:`` was declared inside
  ## a ``when`` / ``case`` branch the text scanner can't reach.
  {.cast(gcsafe).}:
    for raw in registeredNativeBuildDeps(packageName):
      let stripped = raw.strip()
      var head = ""
      for ch in stripped:
        if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
          break
        head.add(ch)
      if head == "meson":
        return true
  false

proc fromSourceMesonRecognize(projectRoot: string;
                              request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## M9.R.6: registry-based recognition. Reads
  ## ``registeredNativeBuildDeps`` (M9.R.1) for the ``"meson"`` token
  ## as the primary signal, with the legacy source-text
  ## ``usesIncludesMeson`` scanner as a fallback for recipes whose
  ## macro hasn't yet populated the registry at probe time (the lock-
  ## free registry takes one module-init pass to be visible).
  ##
  ## M9.N: claims a recipe based on DECLARATION (``fetch:`` registered +
  ## ``nativeBuildDeps:`` declares ``meson`` + no in-tree
  ## ``meson.build`` at projectRoot). NO host-PATH gate — the engine
  ## resolves tool identity AFTER recognise, possibly via cache
  ## substitute or source build.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if hasMesonBuild(projectRoot):
    # In-tree project — the existing M39 ``c-cpp-meson`` convention
    # claims this. The from-source variant intentionally yields so the
    # in-tree fixture tests don't change behaviour.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
    return false
  # M9.R.6: structured-registry check first; legacy text scanner is
  # the OR'd fallback so the recognise behaviour stays a superset of
  # the pre-M9.R.6 shape (no regression on recipes whose macros haven't
  # populated the registry yet).
  if not registriesIncludeMeson(dslPackageName) and
      not usesIncludesMeson(source):
    return false
  {.cast(gcsafe).}:
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      return false
  if extractMembers(source).len == 0:
    return false
  true

proc syntheticPackage(projectRoot: string;
                      members: seq[FromSourceMesonMember]): PackageDef =
  var name = "from_source_meson_convention"
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

proc fromSourceMesonEmitFragment(projectRoot: string;
                                 request: ProviderGraphRequest):
                                   GraphFragment {.gcsafe.} =
  ## Lower the recipe into a fetch + setup + compile + install + per-
  ## member stage-copy action graph. See module docstring's pipeline
  ## section.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "from-source-meson convention: no executable or library " &
          "members declared in " & projectFile)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-meson convention: no 'package <name>:' block in " &
          projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-meson convention: no fetch: spec registered for " &
          "package '" & dslPackageName & "' — recognise() should have " &
          "rejected this project")
    let mesonExe = mesonExecutable()
    let mesonOptions = registeredBuildFlags(dslPackageName, "", "meson")
    let srcDir = fetchExtractedRoot(projectRoot, spec)
    let buildDir = buildScratchDir(projectRoot)
    let staging = stagingDir(projectRoot)
    let pkg = syntheticPackage(projectRoot, members)
    # M9.L.4-refactor Step B: compose the binary-cache identity once
    # and thread it onto the install + stage-copy edges. The engine's
    # ``BinaryCachePublisher`` hook consumes the same tuple from the
    # decoded ``BuildAction``; conventions stay tool-agnostic.
    let identity = computeCacheEntryIdentity(projectRoot,
      dslPackageName, "meson")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      # 1. Fetch
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      # 2. Setup
      let setupPair = emitSetupAction(projectRoot, mesonExe, srcDir,
        buildDir, mesonOptions, @[fetchAct.id], @[fetchStamp])
      allActions.add(setupPair.action)
      # 3. Compile
      let compilePair = emitCompileAction(projectRoot, mesonExe, buildDir,
        setupPair.stamp)
      allActions.add(compilePair.action)
      # 4. Install — carries the binary-cache identity so the engine
      # hook publishes the install tree after success.
      let installPair = emitInstallAction(projectRoot, mesonExe, buildDir,
        staging, compilePair.stamp, identity)
      allActions.add(installPair.action)
      # 5. Per-artifact stage-copy — each edge also carries the
      # identity. The engine's hook fires per successful action; the
      # convention does NOT emit a separate publish edge any more (the
      # Step-A-era ``emitPublishAction`` retired in Step B).
      for member in members:
        let stageAct = emitStageCopyAction(projectRoot, staging,
          installPair.stamp, member, identity)
        allActions.add(stageAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceMesonConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ##
  ## TODO(reprobuild-as-ninja-generator): once the ``reprobuild-cmake/``
  ## workspace fork lifts cmake's generator backend into reprobuild's
  ## DAG, a sibling ``from_source_cmake.nim`` convention should perform
  ## per-source DAG lifting rather than shelling out to ``cmake
  ## --build``. The from-source-meson convention has a similar potential
  ## optimisation via parsing the generated ``build.ninja`` — defer to
  ## the same future milestone.
  LanguageConvention(
    name: "from-source-meson",
    recognize: fromSourceMesonRecognize,
    emitFragment: fromSourceMesonEmitFragment)
