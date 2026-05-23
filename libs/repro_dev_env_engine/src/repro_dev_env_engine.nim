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
                                publicCliPath, workDir: string): BuildAction =
  var inputs = plan.inputSources
  if inputs.find(interfacePath) < 0:
    inputs.add(interfacePath)
  action("__repro_provider_compile", @[
    publicCliPath,
    "__repro-compile-provider",
    "--module", modulePath,
    "--out", plan.outputBinaryPath,
    "--artifact", artifactPath,
    "--interface", interfacePath,
    "--work-dir", workDir
  ],
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

  let interfacePath = active.outDir / "project-interface.rbsz"
  let stubPath = active.outDir / "project-interface.nim"
  let interfaceArtifact = extractInterfaceFromModule(active.modulePath,
    interfacePath, stubPath, workDir)

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
      result.providerBinaryPath, interfaceArtifact.interfaceFingerprint, workDir)
    invalidateStaleProviderCompileArtifact(providerPlan,
      result.providerArtifactPath)
    let providerAction = providerCompileBuildAction(providerPlan,
      active.modulePath, interfacePath, result.providerArtifactPath,
      active.publicCliPath, workDir)
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
