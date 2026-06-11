import std/[options, os, strutils]

import repro_build_engine
import repro_core
import repro_hash
import repro_interface_artifacts

type
  DevEnvEdgeError* = object of CatchableError

  DevEnvEdgeStats* = object
    providerBuildLaunched*: bool
    providerBuildSkippedFresh*: bool
    providerBuildCacheHit*: bool
    providerIntrospectionLaunched*: bool
    providerIntrospectionCacheHit*: bool
    artifactWriteLaunched*: bool
    artifactWriteSkipped*: bool
    shellRenderingLaunched*: bool
    shellRenderingCacheHit*: bool
    shellRenderingSkipped*: bool

  DevEnvEdgeConfig* = object
    modulePath*: string
    projectRoot*: string
    outDir*: string
    workDir*: string
    publicCliPath*: string
    monitorCliPath*: string
    # Argument vector prepended to ``monitorCliPath`` for monitored actions
    # (Executable-Consolidation M1). When ``monitorCliPath`` is the ``repro``
    # executable itself, this carries ``internal fs-snoop`` so the dev-env
    # monitor self-spawns instead of locating a standalone ``repro-fs-snoop``.
    monitorCliArgs*: seq[string]
    monitorShimLibPath*: string
    entryPointId*: string
    activity*: string
    lockSliceId*: string
    developOverridesPath*: string
    renderShell*: bool
    statsEnabled*: bool

  DevEnvEdgeResult* = object
    artifactPath*: string
    shellFragmentPath*: string
    shellNavigatorStatsPath*: string
    providerArtifactPath*: string
    providerBinaryPath*: string
    providerArtifactId*: string
    providerCompileResult*: BuildRunResult
    devEnvResult*: BuildRunResult
    providerCompileAction*: ActionResult
    introspectionAction*: ActionResult
    shellRenderAction*: ActionResult
    stats*: DevEnvEdgeStats

proc raiseDevEnvEdge(message: string) {.noreturn.} =
  raise newException(DevEnvEdgeError, message)

proc hexDigest(digest: ContentDigest): string =
  toHex(digest.bytes).toLowerAscii()

proc hasFailedActions(run: BuildRunResult): bool =
  for item in run.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc actionById(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  ActionResult(id: id)

proc providerCompileFailure(run: BuildRunResult): string =
  for item in run.results:
    if item.status in {asFailed, asBlocked}:
      var parts = @[item.id & " " & $item.status]
      if item.stderr.len > 0:
        parts.add(item.stderr)
      if item.stdout.len > 0:
        parts.add(item.stdout)
      return parts.join("\n")
  "provider compile failed"

proc providerCompileBuildAction(plan: ProviderCompilePlan;
                                modulePath, interfacePath, artifactPath,
                                publicCliPath, workDir: string;
                                scratchDir = ""): BuildAction =
  var inputs = plan.inputSources
  if inputs.find(interfacePath) < 0:
    inputs.add(interfacePath)
  var command = @[
    publicCliPath,
    "__repro-compile-provider",
    "--module", modulePath,
    "--out", plan.outputBinaryPath,
    "--artifact", artifactPath,
    "--interface", interfacePath,
    "--work-dir", workDir
  ]
  if scratchDir.len > 0:
    command.add("--scratch-dir")
    command.add(scratchDir)
  action("__repro_provider_compile", command,
    cwd = workDir,
    inputs = inputs,
    outputs = @[plan.outputBinaryPath, artifactPath],
    commandStatsId = "repro provider compile edge",
    cacheable = true,
    weakFingerprint = plan.compileEdge.actionFingerprint,
    dependencyPolicy = declaredOnlyPolicy())

proc invalidateStaleProviderCompileArtifact(plan: ProviderCompilePlan;
                                            artifactPath: string) =
  if artifactPath.len == 0 or not fileExists(extendedPath(artifactPath)):
    return
  if providerCompileArtifactFresh(artifactPath, plan.outputBinaryPath,
      plan.interfaceFingerprint, plan.providerFingerprint):
    return
  removeFile(extendedPath(artifactPath))

proc engineConfig(config: DevEnvEdgeConfig): BuildEngineConfig =
  result = BuildEngineConfig(
    cacheRoot: config.outDir / "build-engine-cache",
    runQuotaCliPath: config.publicCliPath,
    monitorCliPath: config.monitorCliPath,
    monitorCliArgs: config.monitorCliArgs,
    maxParallelism: 1'u32,
    stdoutLimit: 1024 * 1024,
    stderrLimit: 1024 * 1024,
    rebuildMissingOutputsOnCacheHit: true,
    deferLocalOutputBlobs: true,
    bypassRunQuota: false,
    fallbackToRunQuotaBypass: true,
    inlineRunQuota: true,
    suppressTrace: false,
    skipCacheHitEvidence: false)
  result.statsEnabled = config.statsEnabled

proc commonMonitorEnv(config: DevEnvEdgeConfig): seq[string] =
  const inherited = [
    "PATH", "HOME", "TMPDIR", "TEMP", "TMP", "LD_LIBRARY_PATH",
    "DYLD_LIBRARY_PATH", "NIX_SSL_CERT_FILE", "SSL_CERT_FILE"
  ]
  for name in inherited:
    if existsEnv(name):
      result.add(name & "=" & getEnv(name))
  if config.monitorShimLibPath.len > 0:
    result.add("REPRO_MONITOR_SHIM_LIB=" & config.monitorShimLibPath)
  if config.developOverridesPath.len > 0:
    result.add("REPRO_DEVELOP_OVERRIDES_FILE=" &
      config.developOverridesPath)

proc fingerprintText(parts: openArray[string]): ContentDigest =
  weakFingerprintFromText(parts.join("\n"))

proc fileFingerprintPart(path: string): string =
  if path.len == 0:
    return ""
  if not fileExists(extendedPath(path)):
    return path & "\n<missing>"
  path & "\n" & readFile(extendedPath(path))

# ---------------------------------------------------------------------
# M77 — fast-path cache-key computation.
#
# ``computeDevEnvEdgeCacheKey`` is the public surface the shell hook's
# per-prompt fast path calls BEFORE walking the build graph. It MUST
# produce a key that is identical to the one the engine's normal
# cache-hit path would use for the same ``DevEnvEdgeConfig`` — otherwise
# the user sees flapping where the hook says "cached" but the next
# prompt's full walk recomputes a different fingerprint.
#
# The key is a deterministic hash of:
#
# * an in-document schema string (``reprobuild.dev-env.cache-key.v1``)
#   so a future change to the inputs invalidates every existing key
#   without us having to migrate or version anything in the manifest.
# * the project root path
# * the project file's content (whichever of
#   ``reprobuild.nim`` / ``repro.nim`` exists; the canonical
#   ``reprobuild.nim`` wins when both are present, matching the rest of
#   the engine)
# * the develop-overrides file content (if present)
# * the activity selector
# * the lock-slice id (when the caller passed one) PLUS the contents of
#   ``<projectRoot>/.repro/dev-env.lock`` when present (so a manual edit
#   to the lock file invalidates the fast path)
# * the small subset of env vars the dev-env edge consumes:
#   ``REPRO_DEVELOP_OVERRIDES_FILE``, ``REPRO_MONITOR_SHIM_LIB``,
#   ``REPRO_FS_SNOOP``
#
# The implementation deliberately walks NO build graph and spawns NO
# subprocess. It reads at most three small files (the project file, the
# develop-overrides file, the dev-env lock file) which the kernel page
# cache holds hot after the first prompt. The microbench in
# ``tests/e2e/dev-env/t_e2e_shell_hook_noop_latency.nim`` asserts the
# wall-clock budget (< 15 ms p50 on Windows, < 5 ms p50 elsewhere).
#
# The cache key is intentionally LOOSER than the build-engine's internal
# weak-fingerprint for the introspection action: the engine includes the
# provider binary path and the provider artifact ID (which the hook
# cannot know without spawning the provider compile), so a fast-path
# match is a STRONG signal that nothing the user can observe changed,
# but the build engine remains authoritative when the fast path falls
# through. Practically: if the user replaces ``nim`` on PATH between
# prompts, the fast path may say "cached" while the underlying provider
# compile would invalidate; that is the same trade-off the engine's
# action-cache layer already makes for declared inputs vs. environment
# tools, so consistency wins over paranoia here.

const CacheKeySchema = "reprobuild.dev-env.cache-key.v1"

proc canonicalProjectFilePath(projectRoot: string): string =
  ## Mirror ``resolveProjectFile`` from ``repro_core`` without taking the
  ## dependency: prefer ``reprobuild.nim`` over ``repro.nim``. Returns
  ## the empty string when no project file is present (which the caller
  ## can use to short-circuit "no cache key possible").
  let canonical = projectRoot / "reprobuild.nim"
  if fileExists(extendedPath(canonical)):
    return canonical
  let legacy = projectRoot / "repro.nim"
  if fileExists(extendedPath(legacy)):
    return legacy
  ""

proc lockSliceFilePart(projectRoot: string): string =
  ## ``.repro/dev-env.lock`` content (or ``<missing>`` marker when the
  ## file does not exist). Walked into the cache key so a user-level
  ## edit to the lock file invalidates the fast path.
  let lockPath = projectRoot / ".repro" / "dev-env.lock"
  fileFingerprintPart(lockPath)

proc envVarPart(name: string): string =
  if existsEnv(name):
    name & "=" & getEnv(name)
  else:
    name & "=<unset>"

proc computeDevEnvEdgeCacheKey*(config: DevEnvEdgeConfig): string =
  ## See module-level note. Returns a 32-char lowercase hex digest.
  let projectFile = canonicalProjectFilePath(config.projectRoot)
  let projectFilePart =
    if projectFile.len == 0:
      config.projectRoot & "\n<no project file>"
    else:
      fileFingerprintPart(projectFile)
  let activity =
    if config.activity.len > 0: config.activity else: "default"
  let parts = @[
    CacheKeySchema,
    "projectRoot=" & config.projectRoot,
    "projectFile=" & projectFilePart,
    "activity=" & activity,
    "lockSliceId=" & config.lockSliceId,
    "lockSliceFile=" & lockSliceFilePart(config.projectRoot),
    "developOverrides=" & fileFingerprintPart(config.developOverridesPath),
    # ``REPRO_DEVELOP_OVERRIDES_FILE`` is the only edge-consumed env
    # variable that materially changes the activation — overriding the
    # overrides file path swaps the develop-overrides resolution. The
    # rest (``REPRO_MONITOR_SHIM_LIB``, ``REPRO_FS_SNOOP``) are
    # infrastructure for the build engine and do not change the
    # dev-env contract; including them would burn cache-key matches
    # whenever the user wraps ``repro`` under fs-snoop or runs from a
    # different host with a different shim path.
    envVarPart("REPRO_DEVELOP_OVERRIDES_FILE")
  ]
  let digest = weakFingerprintFromText(parts.join("\n"))
  result = newStringOfCap(32)
  # 16-byte prefix is plenty for cache-key equality at this layer; full
  # 32-byte digest would only add bytes to the env block without
  # narrowing the false-collision probability into anything the user
  # can observe (a hypothetical 2^-64 collision triggers a stale env at
  # the next prompt and is corrected on the prompt after that when the
  # full walk runs).
  for i in 0 ..< 16:
    result.add(toHex(int(digest.bytes[i]), 2).toLowerAscii())

proc devEnvIntrospectionAction(config: DevEnvEdgeConfig;
                               provider: ProviderCompileArtifact;
                               providerArtifactPath, providerArtifactId,
                               artifactPath: string): BuildAction =
  let protocolRoot = config.outDir / "dev-env-protocol"
  let weak = fingerprintText([
    "reprobuild.dev-env.introspection.v1",
    providerArtifactId,
    provider.outputBinaryPath,
    hexDigest(provider.outputBinaryFingerprint),
    config.projectRoot,
    config.entryPointId,
    config.activity,
    config.lockSliceId,
    fileFingerprintPart(config.developOverridesPath)
  ])
  var argv = @[
    config.publicCliPath,
    "__repro-dev-env-introspect",
    "--provider-binary", provider.outputBinaryPath,
    "--provider-artifact-id", providerArtifactId,
    "--project-root", config.projectRoot,
    "--out", artifactPath,
    "--protocol-root", protocolRoot
  ]
  if config.entryPointId.len > 0:
    argv.add("--entry-point")
    argv.add(config.entryPointId)
  if config.activity.len > 0:
    argv.add("--activity")
    argv.add(config.activity)
  if config.lockSliceId.len > 0:
    argv.add("--lock-slice")
    argv.add(config.lockSliceId)
  if config.developOverridesPath.len > 0:
    argv.add("--develop-overrides")
    argv.add(config.developOverridesPath)
  var inputs = @[provider.outputBinaryPath, providerArtifactPath]
  if config.developOverridesPath.len > 0 and
      fileExists(extendedPath(config.developOverridesPath)):
    inputs.add(config.developOverridesPath)
  action("__repro_dev_env_introspection", argv,
    cwd = config.workDir,
    inputs = inputs,
    outputs = @[artifactPath],
    env = config.commonMonitorEnv(),
    commandStatsId = "repro dev-env introspection edge",
    cacheable = true,
    weakFingerprint = weak,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgAutomaticMonitor,
      completeness: decComplete))

proc shellRenderAction(config: DevEnvEdgeConfig; artifactPath,
                       shellFragmentPath, navigatorStatsPath: string): BuildAction =
  let weak = fingerprintText([
    "reprobuild.dev-env.shell-render.v2",
    artifactPath
  ])
  action("__repro_dev_env_shell_render", @[
    config.publicCliPath,
    "__repro-render-dev-env-shell",
    "--artifact", artifactPath,
    "--out", shellFragmentPath,
    "--navigator-stats", navigatorStatsPath
  ],
    cwd = config.workDir,
    inputs = @[artifactPath],
    outputs = @[shellFragmentPath, navigatorStatsPath],
    commandStatsId = "repro dev-env shell render edge",
    cacheable = true,
    weakFingerprint = weak,
    dependencyPolicy = declaredOnlyPolicy())

proc computeDevEnvEdge*(config: DevEnvEdgeConfig): DevEnvEdgeResult =
  if config.modulePath.len == 0:
    raiseDevEnvEdge("modulePath is required")
  if config.projectRoot.len == 0:
    raiseDevEnvEdge("projectRoot is required")
  if config.outDir.len == 0:
    raiseDevEnvEdge("outDir is required")
  if config.publicCliPath.len == 0:
    raiseDevEnvEdge("publicCliPath is required")
  if config.monitorCliPath.len == 0:
    raiseDevEnvEdge("monitorCliPath is required")

  createDir(extendedPath(config.outDir))
  let workDir =
    if config.workDir.len > 0: config.workDir else: getCurrentDir()
  var active = config
  active.workDir = workDir
  let compileScratchDir = active.outDir / "provider-work"

  let interfacePath = active.outDir / "project-interface.rbsz"
  let stubPath = active.outDir / "project-interface.nim"
  let interfaceArtifact = extractInterfaceFromModule(active.modulePath,
    interfacePath, stubPath, workDir, compileScratchDir)

  result.providerBinaryPath = active.outDir / "provider" / "project-provider"
  result.providerArtifactPath = active.outDir / "provider-compile.rbsz"
  result.artifactPath = active.outDir / "dev-env.rbde"
  result.shellFragmentPath = active.outDir / "dev-env.env"
  result.shellNavigatorStatsPath = active.outDir / "dev-env.env.navigator.json"

  var provider: ProviderCompileArtifact
  let cachedProvider = readFreshProviderCompileArtifact(
    result.providerArtifactPath, active.modulePath, result.providerBinaryPath,
    interfaceArtifact.interfaceFingerprint)
  if cachedProvider.isSome:
    provider = cachedProvider.get()
    result.stats.providerBuildSkippedFresh = true
  else:
    let providerPlan = providerCompilePlan(active.modulePath,
      result.providerBinaryPath, interfaceArtifact.interfaceFingerprint, workDir,
      compileScratchDir)
    invalidateStaleProviderCompileArtifact(providerPlan,
      result.providerArtifactPath)
    let providerAction = providerCompileBuildAction(providerPlan,
      active.modulePath, interfacePath, result.providerArtifactPath,
      active.publicCliPath, workDir, compileScratchDir)
    var compileConfig = active.engineConfig()
    result.providerCompileResult = runBuild(graph([providerAction]),
      compileConfig)
    result.providerCompileAction = result.providerCompileResult.actionById(
      "__repro_provider_compile")
    result.stats.providerBuildLaunched =
      result.providerCompileAction.launched
    result.stats.providerBuildCacheHit =
      result.providerCompileAction.status == asCacheHit
    if result.providerCompileResult.hasFailedActions():
      raiseDevEnvEdge(providerCompileFailure(result.providerCompileResult))
    if not fileExists(extendedPath(result.providerArtifactPath)):
      raiseDevEnvEdge("provider compile edge did not write artifact: " &
        result.providerArtifactPath)
    provider = readProviderCompileArtifact(result.providerArtifactPath)
    if not providerCompileArtifactFresh(result.providerArtifactPath,
        providerPlan.outputBinaryPath, providerPlan.interfaceFingerprint,
        providerPlan.providerFingerprint):
      raiseDevEnvEdge("provider compile artifact is stale after edge execution")

  result.providerBinaryPath = provider.outputBinaryPath
  result.providerArtifactId = hexDigest(provider.providerFingerprint)

  var actions = @[active.devEnvIntrospectionAction(provider,
    result.providerArtifactPath, result.providerArtifactId, result.artifactPath)]
  if active.renderShell:
    actions.add(active.shellRenderAction(result.artifactPath,
      result.shellFragmentPath, result.shellNavigatorStatsPath))
  var devEnvConfig = active.engineConfig()
  result.devEnvResult = runBuild(graph(actions), devEnvConfig)
  result.introspectionAction = result.devEnvResult.actionById(
    "__repro_dev_env_introspection")
  result.shellRenderAction = result.devEnvResult.actionById(
    "__repro_dev_env_shell_render")
  result.stats.providerIntrospectionLaunched =
    result.introspectionAction.launched
  result.stats.providerIntrospectionCacheHit =
    result.introspectionAction.status == asCacheHit
  result.stats.artifactWriteLaunched =
    result.stats.providerIntrospectionLaunched
  result.stats.artifactWriteSkipped =
    not result.stats.artifactWriteLaunched
  if active.renderShell:
    result.stats.shellRenderingLaunched = result.shellRenderAction.launched
    result.stats.shellRenderingCacheHit =
      result.shellRenderAction.status == asCacheHit
    result.stats.shellRenderingSkipped =
      not result.stats.shellRenderingLaunched
  else:
    result.stats.shellRenderingSkipped = true
  if result.devEnvResult.hasFailedActions():
    for item in result.devEnvResult.results:
      if item.status in {asFailed, asBlocked}:
        raiseDevEnvEdge(item.id & " " & $item.status & ": " & item.stderr)
    raiseDevEnvEdge("dev-env edge failed")
  if not fileExists(extendedPath(result.artifactPath)):
    raiseDevEnvEdge("dev-env edge did not write artifact: " &
      result.artifactPath)
