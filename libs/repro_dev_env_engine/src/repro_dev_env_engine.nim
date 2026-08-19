import std/[options, os, strutils]

import repro_build_engine
import repro_core
import repro_dev_env_engine/cache_key as devEnvCacheKey
import repro_hash
import repro_interface_artifacts
import repro_tool_profiles

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
    # executable itself, this carries ``internal io monitor`` so the dev-env
    # monitor self-spawns instead of locating a standalone monitor binary.
    monitorCliArgs*: seq[string]
    monitorShimLibPath*: string
    entryPointId*: string
    activity*: string
    lockSliceId*: string
    developOverridesPath*: string
    toolProvisioning*: ToolProvisioningMode
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
                                helperCliPath, workDir: string;
                                scratchDir = ""): BuildAction =
  var inputs = plan.inputSources
  if inputs.find(interfacePath) < 0:
    inputs.add(interfacePath)
  var command = @[
    helperCliPath,
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
  let compilerCwd =
    if scratchDir.len > 0:
      scratchDir
    else:
      parentDir(plan.outputBinaryPath)
  createDir(extendedPath(compilerCwd))
  action("__repro_provider_compile", command,
    cwd = compilerCwd,
    inputs = inputs,
    outputs = @[plan.outputBinaryPath, artifactPath],
    commandStatsId = "repro provider compile edge",
    cacheable = true,
    weakFingerprint = plan.compileEdge.actionFingerprint,
    dependencyPolicy = automaticMonitorGatheringPolicy())

proc providerCompileCliPath(config: DevEnvEdgeConfig): string =
  ## Dev-env tests may call this library from a test binary, so
  ## ``getAppFilename()`` is not a reliable repro helper path here. Since the
  ## single-`repro` consolidation there is no ``repro-full`` companion, so the
  ## monitor/public CLI path is already the full ``repro`` image to run the
  ## monitored provider-compile edge with. When the monitor is the consolidated
  ## ``repro internal io monitor`` driver, reuse its image; otherwise fall back
  ## to the public CLI path.
  let internalMonitorArgs = @["internal", "io", "monitor"]
  if config.monitorCliArgs == internalMonitorArgs and
      config.monitorCliPath.len > 0:
    return os.normalizedPath(config.monitorCliPath)
  config.publicCliPath

proc invalidateStaleProviderCompileArtifact(plan: ProviderCompilePlan;
                                            artifactPath: string) =
  if artifactPath.len == 0 or not fileExists(extendedPath(artifactPath)):
    return
  if providerCompileArtifactFresh(artifactPath, plan.outputBinaryPath,
      plan.interfaceFingerprint, plan.providerFingerprint, plan.workDir):
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

proc parseDevEnvToolProvisioning(value: string): ToolProvisioningMode =
  case value.normalize()
  of "path":
    tpmPathOnly
  of "nix":
    tpmNix
  of "tarball":
    tpmTarball
  of "scoop":
    tpmScoop
  of "from-source", "fromsource", "source":
    tpmFromSource
  else:
    raiseDevEnvEdge("unsupported dev-env tool provisioning mode: " & value)

proc effectiveToolProvisioning(config: DevEnvEdgeConfig;
                               artifact: ProjectInterfaceArtifact):
    ToolProvisioningMode =
  if config.toolProvisioning != tpmUnspecified:
    return config.toolProvisioning
  let envMode = getEnv("REPRO_TOOL_PROVISIONING").strip()
  if envMode.len > 0:
    return parseDevEnvToolProvisioning(envMode)
  let defaultMode = artifact.projectInterface.defaultToolProvisioning.strip()
  if defaultMode.len > 0:
    return parseDevEnvToolProvisioning(defaultMode)
  tpmUnspecified

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
#   monitor CLI selection
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
  devEnvCacheKey.computeDevEnvEdgeCacheKey(config.projectRoot, config.activity,
    config.lockSliceId, config.developOverridesPath)

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
    dependencyPolicy = automaticMonitorGatheringPolicy())

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

  let candidateKey = devEnvCacheKey.computeDevEnvEdgeCacheKey(
    config.projectRoot, config.activity, config.lockSliceId, config.developOverridesPath
  )

  result.artifactPath = config.outDir / "dev-env.rbde"
  result.shellFragmentPath = config.outDir / "dev-env.env"
  result.shellNavigatorStatsPath = config.outDir / "dev-env.env.navigator.json"

  let cacheKeyPath = config.outDir / "dev-env.rbde.cache-key"

  createDir(extendedPath(config.outDir))
  let workDir =
    if config.workDir.len > 0: config.workDir else: getCurrentDir()
  var active = config
  active.workDir = workDir
  let compileScratchDir = active.outDir / "provider-work"

  let interfacePath = active.outDir / "project-interface.rbsz"
  let stubPath = active.outDir / "project-interface.nim"

  var interfaceArtifact: ProjectInterfaceArtifact
  var useCachedInterface = false
  if fileExists(extendedPath(interfacePath)) and
     fileExists(extendedPath(cacheKeyPath)):
    try:
      let cachedKey = readFile(extendedPath(cacheKeyPath)).strip()
      if cachedKey == candidateKey:
        interfaceArtifact = readInterfaceArtifact(interfacePath)
        useCachedInterface = true
    except CatchableError:
      discard

  if not useCachedInterface:
    # ``consumerRoot`` is the recipe's OWN project root. Left implicit it
    # would be the process cwd, which is only incidentally the same thing —
    # and is baked into the compiled recipe, so a wrong value is silent.
    interfaceArtifact = extractInterfaceFromModule(active.modulePath,
      interfacePath, stubPath, workDir, compileScratchDir,
      consumerRoot = parentDir(absolutePath(active.modulePath)))
  let effectiveProvisioning =
    active.effectiveToolProvisioning(interfaceArtifact)

  result.providerBinaryPath = active.outDir / "provider" / "project-provider"
  result.providerArtifactPath = active.outDir / "provider-compile.rbsz"

  # Construct bakForeignProvision actions for Nix tool uses
  var provisioningActions: seq[BuildAction] = @[]
  var provisioningReceipts: seq[string] = @[]
  for useDef in interfaceArtifact.projectInterface.toolUses:
    if effectiveProvisioning in {tpmUnspecified, tpmNix} and
        useDef.nixProvisioning.len > 0:
      let plan = nixAcquisitionPlan(useDef)
      let receiptDir = active.outDir / "tool-store" / "nix-provision"
      let receiptFile = receiptDir / (safeStoreSegment(useDef.packageSelector, "nix-package") & ".receipt")

      let provAction = BuildAction(
        kind: bakForeignProvision,
        id: "nix-provision." & useDef.packageSelector,
        argv: @["nix", plan.nixSelector],
        outputs: @[receiptFile],
        cwd: workDir,
        commandStatsId: "repro dev-env nix provision edge",
        cacheable: true,
        weakFingerprint: fingerprintText([
          "reprobuild.dev-env.nix-provision.v1",
          useDef.packageSelector,
          plan.nixSelector
        ]),
        dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor)
      )
      provisioningActions.add(provAction)
      provisioningReceipts.add(receiptFile)

  var provider: ProviderCompileArtifact
  let cachedProvider = readFreshProviderCompileArtifact(
    result.providerArtifactPath, active.modulePath, result.providerBinaryPath,
    interfaceArtifact.interfaceFingerprint, workDir)
  if cachedProvider.isSome:
    provider = cachedProvider.get()
    result.stats.providerBuildSkippedFresh = true
  else:
    let providerPlan = providerCompilePlan(active.modulePath,
      result.providerBinaryPath, interfaceArtifact.interfaceFingerprint, workDir,
      compileScratchDir)
    invalidateStaleProviderCompileArtifact(providerPlan,
      result.providerArtifactPath)
    var providerAction = providerCompileBuildAction(providerPlan,
      active.modulePath, interfacePath, result.providerArtifactPath,
      providerCompileCliPath(active), workDir, compileScratchDir)

    # Wire the provisioning receipts as inputs to the compiler action
    for receipt in provisioningReceipts:
      if providerAction.inputs.find(receipt) < 0:
        providerAction.inputs.add(receipt)

    var compileConfig = active.engineConfig()
    result.providerCompileResult = runBuild(graph(@[providerAction] & provisioningActions),
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
        providerPlan.providerFingerprint, providerPlan.workDir):
      raiseDevEnvEdge("provider compile artifact is stale after edge execution")

  result.providerBinaryPath = provider.outputBinaryPath
  result.providerArtifactId = hexDigest(provider.providerFingerprint)

  var introspectionAction = active.devEnvIntrospectionAction(provider,
    result.providerArtifactPath, result.providerArtifactId, result.artifactPath)

  # Wire the provisioning receipts as inputs to the introspection action
  for receipt in provisioningReceipts:
    if introspectionAction.inputs.find(receipt) < 0:
      introspectionAction.inputs.add(receipt)

  var actions = @[introspectionAction]
  if active.renderShell:
    var renderAction = active.shellRenderAction(result.artifactPath,
      result.shellFragmentPath, result.shellNavigatorStatsPath)
    # Wire the provisioning receipts as inputs to the shell render action
    for receipt in provisioningReceipts:
      if renderAction.inputs.find(receipt) < 0:
        renderAction.inputs.add(receipt)
    actions.add(renderAction)

  var devEnvConfig = active.engineConfig()
  result.devEnvResult = runBuild(graph(actions & provisioningActions), devEnvConfig)
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

  try:
    writeFile(extendedPath(cacheKeyPath), candidateKey & "\n")
  except CatchableError:
    discard
