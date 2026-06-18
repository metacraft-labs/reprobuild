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
##   6. **Binary-cache publish** (``from-source-meson-publish-<package>``)
##      — best-effort upload of ``<stagingDir>/usr/local`` to
##      ``repro-cache`` via ``apps/repro-binary-cache-client publish``.
##      Argv wraps the CLI invocation in ``sh -c ".. || true"`` so an
##      unreachable cache / missing key+cert env vars / missing CLI
##      degrades to a soft-fail without aborting the build. Depends on
##      every stage-copy action so the publish runs AFTER the install
##      tree is fully materialised. The 64-char hex cache-entry key is
##      derived at emit time via
##      ``cache_key.deriveCacheEntryKeyHex`` over the M9.L.4 v1
##      ``CacheEntryIdentity`` tuple (see ``deriveCacheKeyHex`` below
##      and the "Honest deferrals" section for the populated-vs-deferred
##      breakdown).
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

# M9.L.4 binary-cache publish wiring. ``cache_key`` derives the on-wire
# entry-key hex from a ``CacheEntryIdentity`` tuple; the convention
# threads the hex through the publish action's argv so other machines
# can substitute instead of rebuilding. ``types`` carries the
# ``PlatformTriple`` + ``ToolchainIdentity`` shapes that
# ``CacheEntryIdentity`` requires.
import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcs_types
import blake3

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
  let resolved = findExe("meson")
  if resolved.len > 0:
    return resolved
  # Stable placeholder so ``inlineExecCall`` doesn't refuse an empty
  # argv[0]. The action will fail at execution time with a clearer
  # diagnostic than a silent skip.
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
  let shExe = findExe("sh")
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
    commandStatsId = "from-source-meson.setup")
  (action, stamp)

proc emitCompileAction(projectRoot, mesonExe, buildDir, setupStamp: string):
                        tuple[action: BuildActionDef; stamp: string] =
  ## ``meson compile -C <buildDir>``. The stamp file lets downstream
  ## actions key off compile success without relying on meson's internal
  ## ``build.ninja`` touch behaviour.
  let stamp = compileStampPath(projectRoot)
  let shExe = findExe("sh")
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
    commandStatsId = "from-source-meson.compile")
  (action, stamp)

proc emitInstallAction(projectRoot, mesonExe, buildDir, staging,
                       compileStamp: string):
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
  createDir(extendedPath(staging))
  let stamp = installStampPath(projectRoot)
  let shExe = findExe("sh")
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
    commandStatsId = "from-source-meson.install")
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
                         member: FromSourceMesonMember): BuildActionDef =
  ## Copy ``<staging>/usr/local/bin/<member>`` to
  ## ``<projectRoot>/.repro/output/<member>/<member>``. This action is
  ## what the engine's output-collection step keys off — the canonical
  ## per-artifact output path matches the existing direct conventions'
  ## ``<root>/.repro/output/<name>/<name>`` schema.
  let outDir = artifactOutputDir(projectRoot, member.name)
  createDir(extendedPath(outDir))
  let outPath = artifactOutputPath(projectRoot, member.name, member.kind)
  let stagedPath = stagedBinaryPath(staging, member.name, member.kind)
  let shExe = findExe("sh")
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
    commandStatsId = "from-source-meson.stage." & kindTag)

# ---------------------------------------------------------------------------
# M9.L.4 — binary-cache publish action emission.
#
# After the per-artifact stage-copy actions complete the convention emits
# a best-effort publish action that uploads the install staging tree to
# ``repro-cache`` (see ``apps/repro-binary-cache-client/`` and
# ``recipes/cache/scripts/cache-helper.sh`` §cache_phase_publish for the
# CLI shape). The action's argv wraps the CLI call in ``sh -c ".. || true"``
# so an unreachable cache / missing key+cert env vars / CLI failure does
# NOT abort the build. The CLI itself short-circuits 0 on
# ``REPRO_CACHE_DISABLE=1`` and when the key/cert env vars are unset, so
# the convention does not duplicate that logic.
#
# Cache-key composition pulls from:
#   * packageName: ``extractFirstPackageName`` (recipe header).
#   * packageVersion: M2 ``registeredVersions(pkg)[^1].version`` (the
#     last-declared version wins; recipes typically declare a single
#     version). ``""`` when the recipe omits a ``versions:`` block.
#   * sortedOptions: empty for v1 — meson option mapping is deferred to
#     a follow-up milestone (see honest deferrals below).
#   * PlatformTriple: hardcoded to ``x86_64-linux-gnu`` with libc
#     variant ``glibc`` for v1 (the M9.L.4 vertical-slice target). Host
#     detection lives in a follow-up.
#   * ToolchainIdentity: ``name="meson"``, version + host-ldso left
#     empty — version/ldso detection deferred.
#   * sortedDepClosureDigest: empty for v1 — cross-recipe dep
#     resolution at emit time is deferred.
#   * providerRevision: BLAKE3 hex of the recipe file bytes (truncated
#     to 32 hex chars for human readability). Deterministic across
#     hosts when the recipe is byte-identical.
# ---------------------------------------------------------------------------

proc binaryCacheClientCli(): string =
  ## Resolve the publish CLI binary. Mirrors
  ## ``cache-helper.sh::cache_repro_binary_cache_client_bin`` shape —
  ## prefer the in-repo ``build/test-bin`` location, fall back to
  ## ``PATH`` lookup. The convention emits the resolved path verbatim
  ## into the action argv; the publish action's ``|| true`` wrapper
  ## means a missing CLI degrades to a soft-fail at execution time
  ## instead of an abort.
  let resolved = findExe("repro_binary_cache_client_cli")
  if resolved.len > 0:
    return resolved
  # Stable placeholder so ``inlineExecCall`` accepts the argv; the
  # ``|| true`` wrapper swallows the missing-binary failure at run
  # time. Documented in the module's "Honest deferrals" section.
  "repro_binary_cache_client_cli"

proc providerRevisionHex(projectRoot: string): string =
  ## BLAKE3 of the recipe file bytes, truncated to 32 hex chars. Empty
  ## when the recipe file can't be read (the publish key still derives
  ## via the rest of the identity tuple — the empty string round-trips
  ## through the canonical encoder).
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  let bodyStr =
    try: readFile(extendedPath(match.path))
    except CatchableError: ""
  if bodyStr.len == 0:
    return ""
  let dig = blake3.digest(bodyStr)
  let full = blake3.toHex(dig)
  if full.len >= 32: full[0 ..< 32] else: full

proc m9L4PlatformTriple(): bcs_types.PlatformTriple =
  ## Hardcoded Linux x86_64 GNU glibc triple — the M9.L.4 vertical-slice
  ## target. A follow-up milestone lifts host detection (Windows / macOS
  ## / aarch64) into a shared helper. The convention DOES populate every
  ## field so the canonical encoder round-trips identically across hosts
  ## that compute the same identity tuple.
  bcs_types.PlatformTriple(
    cpu: "x86_64",
    os: "linux",
    abi: "gnu",
    libcVariant: "glibc")

proc m9L4ToolchainIdentity(): bcs_types.ToolchainIdentity =
  ## Toolchain identity for the meson-driven from-source pipeline.
  ## Version + host-ldso detection are deferred (see module docstring
  ## "Honest deferrals"); the empty strings round-trip through the
  ## canonical encoder so a follow-up that fills them in will produce
  ## a DIFFERENT cache key (intended — the spec mandates toolchain
  ## differences shift the key).
  bcs_types.ToolchainIdentity(
    name: "meson",
    version: "",
    hostLdSoAbi: "",
    extraFingerprint: "")

proc deriveCacheKeyHex(projectRoot, packageName: string): string =
  ## Compose the M9.L.4 v1 ``CacheEntryIdentity`` and derive its
  ## 64-char hex key. The deferrals (empty options / empty dep-closure
  ## / hardcoded platform / partial toolchain) are documented in the
  ## module docstring's "Honest deferrals" section.
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  var identity = newCacheEntryIdentity(
    packageName = packageName,
    packageVersion = versionStr,
    platform = m9L4PlatformTriple(),
    toolchain = m9L4ToolchainIdentity(),
    providerRevision = providerRevisionHex(projectRoot))
  # options + depClosure intentionally empty for v1.
  deriveCacheEntryKeyHex(identity)

proc emitPublishAction(projectRoot, staging, packageName: string;
                      stageDeps: seq[string];
                      stageOutputs: seq[string]): BuildActionDef =
  ## Emit a best-effort publish action that uploads ``<staging>/usr/local``
  ## to ``repro-cache`` via the ``repro_binary_cache_client_cli publish``
  ## subcommand. Depends on every per-artifact stage-copy action so the
  ## publish runs AFTER the install tree is fully populated.
  ##
  ## The action's argv is ``sh -c "<cli> publish <hex> <prefix>
  ## --package-name=<pkg> --package-version=<ver> || true"`` — the
  ## ``|| true`` wrapper makes the action always exit 0 so an
  ## unreachable cache / missing key+cert / missing CLI does NOT abort
  ## the build. The CLI itself short-circuits 0 on
  ## ``REPRO_CACHE_DISABLE=1``.
  let cliBin = binaryCacheClientCli()
  let hexKey = deriveCacheKeyHex(projectRoot, packageName)
  let prefixDir = staging / "usr" / "local"
  let versionStr = block:
    var v = ""
    let vs = registeredVersions(packageName)
    if vs.len > 0:
      v = vs[^1].version
    v
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedCli = cliBin.replace("\\", "/").replace("\"", "\\\"")
    let escapedPrefix = prefixDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedPkg = packageName.replace("\"", "\\\"")
    let escapedVer = versionStr.replace("\"", "\\\"")
    let script = "\"" & escapedCli & "\" publish " & hexKey & " \"" &
      escapedPrefix & "\" --package-name=\"" & escapedPkg &
      "\" --package-version=\"" & escapedVer & "\" || true"
    argv = @[shExe, "-c", script]
  else:
    # No ``sh`` on PATH — fall back to a direct invocation. The action
    # will exit non-zero on failure (no shell ``|| true`` available),
    # but this branch only triggers on truly minimal Windows hosts
    # without MSYS2 / git-bash sh, which the convention's other
    # actions ALSO require.
    argv = @[cliBin, "publish", hexKey, prefixDir,
      "--package-name=" & packageName,
      "--package-version=" & versionStr]
  buildAction(
    id = "from-source-meson-publish-" & sanitizeNamePart(packageName),
    call = inlineExecCall(argv, projectRoot),
    deps = stageDeps,
    inputs = stageOutputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-meson.publish")

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc fromSourceMesonRecognize(projectRoot: string;
                              request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if hasMesonBuild(projectRoot):
    # In-tree project — the existing M39 ``c-cpp-meson`` convention
    # claims this. The from-source variant intentionally yields so the
    # in-tree fixture tests don't change behaviour.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesMeson(source):
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
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
      # 4. Install
      let installPair = emitInstallAction(projectRoot, mesonExe, buildDir,
        staging, compilePair.stamp)
      allActions.add(installPair.action)
      # 5. Per-artifact stage-copy
      var stageDeps: seq[string] = @[]
      var stageOutputs: seq[string] = @[]
      for member in members:
        let stageAct = emitStageCopyAction(projectRoot, staging,
          installPair.stamp, member)
        allActions.add(stageAct)
        stageDeps.add(stageAct.id)
        for outPath in stageAct.outputs:
          stageOutputs.add(outPath)
      # 6. Binary-cache publish (M9.L.4). Best-effort: argv wraps the
      # CLI in ``sh -c ".. || true"`` so an unreachable cache /
      # missing key+cert / missing CLI does NOT abort the build.
      allActions.add(emitPublishAction(projectRoot, staging,
        dslPackageName, stageDeps, stageOutputs))
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
