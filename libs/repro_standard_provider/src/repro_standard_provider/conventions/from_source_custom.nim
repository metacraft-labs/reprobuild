## From-source custom-shell language convention (Tier 2b) — M9.N Batch C.1.
##
## The catch-all sibling of the four Tier 2b ``from-source-*``
## conventions (meson / cmake / autotools / make). Where each of those
## claims a recipe that drives a specific build system (recognised by a
## populated channel-specific flag registry), this convention claims
## recipes whose upstream build is expressed as a verbatim shell
## sequence via the new ``shell()`` action surface on ``build:`` blocks
## (M9.N Batch C.1 DSL widening).
##
## ## Recognition contract
##
## The convention claims a project when ALL of the following hold:
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists.
##   * The first ``package <ident>:`` block has registered one or more
##     shell actions via the M9.N Batch C.1 ``shell()`` surface (i.e.
##     ``registeredShellActions(packageName)`` returns a non-empty seq).
##   * The package has NO populated flag channels — meson / cmake /
##     configure / make / ninja are all empty (otherwise one of the four
##     standard from-source siblings claims the recipe first).
##   * The package has NO in-tree build manifest at projectRoot
##     (``Makefile.am`` / ``configure.ac`` / ``meson.build`` /
##     ``CMakeLists.txt`` / ``Makefile`` / ``GNUmakefile``) — otherwise
##     the corresponding in-tree convention claims the project.
##   * At least one ``executable`` / ``library`` / ``files`` member is
##     declared in the recipe source.
##
## The recipe MAY also declare a ``fetch:`` block; the convention prepends
## a fetch action when present and the shell-action chain depends on it.
##
## ## Pipeline
##
## ``emitFragment`` produces:
##
##   1. **Fetch** (``ccpp-fetch-<package>``, optional) — only when
##      ``registeredFetchSpec`` returns a non-empty URL.
##   2. **Shell actions** (``from-source-custom-shell-<i>``) — one action
##      per ``registeredShellActions`` row in declaration order. Each
##      action's argv is ``[sh, -c, <substituted-command>]`` where
##      ``$fetch`` / ``$extracted`` / ``$out`` placeholders have been
##      resolved to absolute paths. Each shell action depends on the
##      previous shell action (and the first depends on the fetch action
##      when one is present).
##   3. **Stage-copy** (``from-source-custom-stage-<member>``) — one
##      action per declared artifact member. Copies
##      ``<out>/bin/<member>`` (or ``<out>/lib/<member>`` / ``<out>/<member>``)
##      to ``<projectRoot>/.repro/output/<member>/<member>``. Depends on
##      the LAST shell action.
##
## ## ``$fetch`` / ``$extracted`` / ``$out`` substitution
##
## The convention performs token-replacement on each shell action's
## ``command`` field before composing the script:
##
##   * ``$fetch``      — ``<projectRoot>/.repro/fetch/<hash>.tar`` (the
##                       downloaded tarball; only meaningful when the
##                       recipe also declares ``fetch:``).
##   * ``$extracted``  — ``<projectRoot>/src/`` (or the recipe's
##                       ``extractedRoot`` if set).
##   * ``$out``        — ``<projectRoot>/.repro/build/from-source-custom/<package>/``
##                       (the per-package output root the shell actions
##                       write into; the stage-copy step probes
##                       ``<out>/bin/<member>`` etc.).
##
## Substitution is a straight ``replace`` against the recorded command
## string. Recipes whose commands legitimately contain a literal ``$out``
## (e.g. a string passed to ``printf``) need to be split across multiple
## shell actions; this is documented in the M9.N Batch C.1 spec hand-off.
##
## ## Binary-cache publishing (M9.L.4-refactor Step B)
##
## The last shell action + every stage-copy edge stamp
## ``BuildActionDef.publishToBinaryCache = true`` AND
## ``cacheEntryIdentity = some(computeCacheEntryIdentity(...))`` so the
## engine's ``BinaryCachePublisher`` hook publishes after a successful
## run. The ``ToolchainIdentity.name`` is ``"custom"`` — distinct from
## the four other from-source conventions so cache entries don't collide
## across recipes that drift between flag-channel and custom-shell
## shapes.
##
## ## Scratch layout
##
##   * Source extraction lives at ``<projectRoot>/src/`` (shared with
##     ``fetch_action``'s default extractedRoot).
##   * Shell-action output dir lives at
##     ``<projectRoot>/.repro/build/from-source-custom/<package>/``.
##   * Per-action stamps live alongside the output dir as
##     ``<out>/.stamps/<actionId>.stamp``.
##   * Per-artifact output lives at
##     ``<projectRoot>/.repro/output/<member>/<member>``.
##
## ## Honest deferrals
##
##   * **End-to-end build run.** On hosts without ``sh`` the convention
##     still emits the graph; the actions fail at execution time.
##   * **Per-shell-action ``cwd`` override.** The DSL records a ``cwd``
##     slot on each row but the M9.N Batch C.1 emitter ignores it (all
##     actions cd into ``$extracted`` first). A follow-up can lift the
##     row's ``cwd`` into a ``cd`` prefix when non-empty.
##   * **Per-shell-action ``deps`` / ``outputs``.** The DSL records both
##     slots but the M9.N Batch C.1 emitter ignores them (every shell
##     action chains to the previous one, and every shell action's
##     output is a per-action stamp). A follow-up can honour the rows
##     when populated.
##   * **Custom artifact paths.** The stage-copy step probes a fixed
##     candidate list (``<out>/bin/<member>``, ``<out>/lib/<member>``,
##     ``<out>/<member>``). Recipes that install to non-standard paths
##     need to lift those paths via a per-artifact ``installedAs:``
##     override — deferred.

import std/[os, strutils, options]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root — mirrors
    ## the other from-source siblings.

  FromSourceCustomSubdir* = "from-source-custom"
    ## Per-convention sub-directory under ``.repro/build/``.

  OutputDirName* = ".repro/output"
    ## Canonical per-artifact output dir.

type
  FromSourceCustomMemberKind = enum
    fscExecutable
    fscLibrary
    fscFiles

  FromSourceCustomMember = object
    name: string
    kind: FromSourceCustomMemberKind

# ---------------------------------------------------------------------------
# Source helpers — same shape as the prior from-source siblings.
# ---------------------------------------------------------------------------

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc extractMembers(source: string): seq[FromSourceCustomMember] =
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
      kind = fscLibrary
    elif stripped.startsWith("files") and
        (stripped.len == len("files") or
         stripped[len("files")] in {' ', '\t'}):
      verb = "files"
      kind = fscFiles
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
      result.add(FromSourceCustomMember(name: name, kind: kind))

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

proc hasInTreeBuildArtifact(projectRoot: string): bool =
  ## True when the project root carries an in-tree build-system
  ## manifest. The from-source variant intentionally yields when any of
  ## these are present at the root so the in-tree sibling convention
  ## claims the project.
  for name in ["Makefile.am", "configure.ac", "configure.in",
               "meson.build", "CMakeLists.txt", "Makefile",
               "GNUmakefile"]:
    if fileExists(extendedPath(projectRoot / name)):
      return true
  false

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------

proc customOutDir(projectRoot, packageName: string): string =
  ## Per-package ``$out`` destination — the directory the recipe's
  ## shell commands write into. Mirrors the staging-dir convention of
  ## the other from-source siblings but uses the package name so two
  ## packages in the same workspace don't clobber each other's outputs.
  projectRoot / ScratchDirName / FromSourceCustomSubdir / packageName

proc shellStampPath(projectRoot, packageName, actionId: string): string =
  customOutDir(projectRoot, packageName) / ".stamps" / (actionId & ".stamp")

proc artifactOutputDir(projectRoot, member: string): string =
  projectRoot / OutputDirName / member

proc artifactOutputPath(projectRoot, member: string;
                        kind: FromSourceCustomMemberKind): string =
  case kind
  of fscExecutable:
    when defined(windows):
      artifactOutputDir(projectRoot, member) / (member & ".exe")
    else:
      artifactOutputDir(projectRoot, member) / member
  of fscLibrary:
    artifactOutputDir(projectRoot, member) / ("lib" & member & ".a")
  of fscFiles:
    artifactOutputDir(projectRoot, member) / member

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

# ---------------------------------------------------------------------------
# Substitution
# ---------------------------------------------------------------------------

proc substitutePlaceholders*(command, fetchPath, extractedPath,
                             outPath: string): string =
  ## Replace ``$fetch`` / ``$extracted`` / ``$out`` tokens in
  ## ``command`` with their resolved absolute paths. Exposed (and
  ## starred) so the convention test can pin the substitution shape
  ## without having to round-trip through the full emit pipeline.
  ##
  ## Implementation: straight ``replace`` against the recorded command
  ## string. The longest substring is replaced first so a recipe whose
  ## command embeds ``$extracted`` is NOT corrupted by a ``$ex`` partial
  ## match — but at present all three placeholders share a leading ``$``
  ## and no two are substrings of each other, so the order is just for
  ## defensive symmetry.
  result = command.replace("$extracted", extractedPath)
  result = result.replace("$fetch", fetchPath)
  result = result.replace("$out", outPath)

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc emitShellActions(projectRoot, packageName, extractedPath, outPath,
                      fetchPath: string;
                      shellRows: seq[DslShellAction];
                      fetchActionId: string;
                      fetchStamp: string;
                      identity: CacheEntryIdentity):
                        tuple[actions: seq[BuildActionDef];
                              lastStamp: string;
                              lastId: string] =
  ## Emit one ``BuildActionDef`` per shell action in declaration order.
  ## Each action shells out via ``sh -c <substituted-command>``; the
  ## last action stamps the binary-cache identity so the engine's
  ## ``BinaryCachePublisher`` hook fires after a successful run.
  ##
  ## Chain: action[0] depends on the fetch action when one was emitted
  ## (otherwise no deps); action[i>0] depends on action[i-1].
  result.actions = @[]
  createDir(extendedPath(customOutDir(projectRoot, packageName) / ".stamps"))
  var prevId = ""
  var prevStamp = ""
  for i, row in shellRows:
    let actionId = "from-source-custom-shell-" & $(i + 1) & "-" &
      sanitizeNamePart(packageName)
    let stamp = shellStampPath(projectRoot, packageName, actionId)
    let substituted = substitutePlaceholders(
      row.command, fetchPath, extractedPath, outPath)
    # Compose the script: cd into $extracted, mkdir -p $out, run the
    # substituted command, touch the stamp.
    let escapedExtracted = extractedPath.replace("\\", "/").
      replace("\"", "\\\"")
    let escapedOut = outPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let escapedStampDir = parentDir(stamp).replace("\\", "/").
      replace("\"", "\\\"")
    let script = "set -e; mkdir -p \"" & escapedExtracted &
      "\"; mkdir -p \"" & escapedOut & "\"; mkdir -p \"" &
      escapedStampDir & "\"; cd \"" & escapedExtracted & "\"; " &
      substituted & "; touch \"" & escapedStamp & "\""
    let argv = @["sh", "-c", script]
    var deps: seq[string] = @[]
    var inputs: seq[string] = @[]
    if prevId.len > 0:
      deps.add(prevId)
      inputs.add(prevStamp)
    elif fetchActionId.len > 0:
      deps.add(fetchActionId)
      inputs.add(fetchStamp)
    let isLast = i == shellRows.high
    let action = buildAction(
      id = actionId,
      call = inlineExecCall(argv, projectRoot),
      deps = deps,
      inputs = inputs,
      outputs = @[stamp],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.shell",
      publishToBinaryCache = isLast,
      cacheEntryIdentity = if isLast: some(identity)
                           else: none(CacheEntryIdentity),
      # M9.N Batch B: bare ``sh`` is resolved by the engine via the
      # ``toolIdentityRefs`` catalog at fork time.
      toolIdentityRefs = @["sh"])
    result.actions.add(action)
    prevId = actionId
    prevStamp = stamp
  result.lastStamp = prevStamp
  result.lastId = prevId

proc stagingCandidatePaths(outPath, member: string;
                           kind: FromSourceCustomMemberKind): seq[string] =
  ## Probe order — the recipe's shell commands typically write the
  ## artefact under ``$out/bin/<member>`` (executable), ``$out/lib/...``
  ## (library), or ``$out/<member>`` (files). The first existing
  ## candidate wins.
  case kind
  of fscExecutable:
    @[
      outPath / "bin" / member,
      outPath / member,
      outPath / "sbin" / member,
    ]
  of fscLibrary:
    @[
      outPath / "lib" / ("lib" & member & ".a"),
      outPath / "lib" / ("lib" & member & ".so"),
      outPath / "lib" / (member & ".a"),
    ]
  of fscFiles:
    @[
      outPath / "share" / member,
      outPath / member,
    ]

proc emitStageCopyAction(projectRoot, outPath, lastShellStamp,
                         lastShellId: string;
                         member: FromSourceCustomMember;
                         identity: CacheEntryIdentity): BuildActionDef =
  ## Copy the per-artifact output from the shell-actions' ``$out`` tree
  ## into the canonical ``<projectRoot>/.repro/output/<member>/<member>``
  ## path. The script probes a fixed candidate list (first existing
  ## wins) — failure to find ANY candidate hard-fails the build.
  let outDir = artifactOutputDir(projectRoot, member.name)
  createDir(extendedPath(outDir))
  let outArtifactPath = artifactOutputPath(projectRoot, member.name, member.kind)
  let candidates = stagingCandidatePaths(outPath, member.name, member.kind)
  let escapedOut = outArtifactPath.replace("\\", "/").replace("\"", "\\\"")
  let escapedOutDir = outDir.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; mkdir -p \"" & escapedOutDir & "\"; "
  var open = 0
  for c in candidates:
    let escapedC = c.replace("\\", "/").replace("\"", "\\\"")
    script.add("if [ -f \"" & escapedC & "\" ]; then cp -f \"" &
      escapedC & "\" \"" & escapedOut & "\"; else ")
    inc open
  script.add("echo \"from-source-custom: no candidate found for member " &
    member.name & "\" >&2; exit 1")
  for _ in 0 ..< open:
    script.add("; fi")
  let argv = @["sh", "-c", script]
  let kindTag = case member.kind
    of fscExecutable: "executable"
    of fscLibrary: "library"
    of fscFiles: "files"
  var deps: seq[string] = @[]
  var inputs: seq[string] = @[]
  if lastShellId.len > 0:
    deps.add(lastShellId)
    inputs.add(lastShellStamp)
  buildAction(
    id = "from-source-custom-stage-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outArtifactPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-custom.stage." & kindTag,
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc fromSourceCustomRecognize(projectRoot: string;
                               request: ProviderGraphRequest):
                                 bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## Claims a recipe based on DECLARATION (``registeredShellActions``
  ## non-empty + all four flag channels empty + no in-tree build
  ## manifest). NO host-PATH gate — the engine resolves tool identity
  ## AFTER recognise.
  if hasInTreeBuildArtifact(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
    return false
  {.cast(gcsafe).}:
    let shellRows = registeredShellActions(dslPackageName)
    if shellRows.len == 0:
      return false
    # All four standard flag channels must be empty — otherwise the
    # more-specific from-source sibling claims the recipe first. The
    # registration order in ``apps/repro-standard-provider`` puts the
    # standard from-source siblings BEFORE this convention, so the
    # check is defensive in either direction.
    for channel in ["meson", "cmake", "configure", "make"]:
      let flags = registeredBuildFlags(dslPackageName, "", channel)
      if flags.len > 0:
        return false
  if extractMembers(source).len == 0:
    return false
  true

proc syntheticPackage(projectRoot: string;
                     members: seq[FromSourceCustomMember]): PackageDef =
  var name = "from_source_custom_convention"
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

proc readToolUses(source: string): seq[string] =
  ## Heuristic ``uses:`` parser — same shape as the
  ## from-source-meson sibling. Tokens become entries in
  ## ``toolIdentityRefs`` on every shell action so the engine resolves
  ## the bare tool names via the catalog at fork time.
  result = @[]
  if source.len == 0:
    return
  var inBlock = false
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
          if firstToken.len > 0:
            result.add(firstToken)
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
          if firstToken.len > 0:
            result.add(firstToken)

proc fromSourceCustomEmitFragment(projectRoot: string;
                                  request: ProviderGraphRequest):
                                    GraphFragment {.gcsafe.} =
  ## Lower the recipe into a fetch (optional) + shell-action chain +
  ## per-member stage-copy action graph. See module docstring's pipeline
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
        "from-source-custom convention: no executable / library / files " &
          "members declared in " & projectFile)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-custom convention: no 'package <name>:' block in " &
          projectRoot)
    let shellRows = registeredShellActions(dslPackageName)
    if shellRows.len == 0:
      raise newException(ValueError,
        "from-source-custom convention: no shell() actions registered " &
          "for package '" & dslPackageName & "' — recognise() should have " &
          "rejected this project")
    let spec = registeredFetchSpec(dslPackageName)
    let extractedPath = fetchExtractedRoot(projectRoot, spec)
    let outPath = customOutDir(projectRoot, dslPackageName)
    let fetchPath = fetchTarballPath(projectRoot, spec.hashHex)
    let pkg = syntheticPackage(projectRoot, members)
    let toolUses = readToolUses(source)
    discard toolUses  # reserved — current emitter hardcodes ``sh``.
    # M9.L.4-refactor Step B: compose the binary-cache identity once.
    let identity = computeCacheEntryIdentity(projectRoot,
      dslPackageName, "custom")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      var fetchId = ""
      var fetchStamp = ""
      if spec.url.len > 0 and spec.hashHex.len > 0:
        # Optional fetch: emit only when the recipe declared one.
        let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
        allActions.add(fetchAct)
        fetchId = fetchAct.id
        fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let shellOutcome = emitShellActions(projectRoot, dslPackageName,
        extractedPath, outPath, fetchPath, shellRows, fetchId, fetchStamp,
        identity)
      for a in shellOutcome.actions:
        allActions.add(a)
      for member in members:
        let stageAct = emitStageCopyAction(projectRoot, outPath,
          shellOutcome.lastStamp, shellOutcome.lastId, member, identity)
        allActions.add(stageAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceCustomConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ##
  ## Registered AFTER the four standard from-source-* siblings so the
  ## more-specific conventions claim first. The catch-all role is the
  ## point — this convention claims recipes whose upstream build is
  ## expressed as a verbatim shell sequence and no standard flag-channel
  ## convention can claim them.
  LanguageConvention(
    name: "from-source-custom",
    recognize: fromSourceCustomRecognize,
    emitFragment: fromSourceCustomEmitFragment)
