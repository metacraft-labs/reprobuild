import std/[options, os, sets, strutils, times]

import repro_build_engine
import repro_core
import repro_dev_env_artifacts
import repro_dev_env_engine/cache_key as devEnvCacheKey
export devEnvCacheKey.PromptWatchEntry, devEnvCacheKey.promptWatchManifestPathFor,
  devEnvCacheKey.writePromptWatchManifest,
  devEnvCacheKey.unsettledPromptWatchPaths,
  devEnvCacheKey.PromptWatchBaseline,
  devEnvCacheKey.snapshotPromptWatchBaseline, devEnvCacheKey.PromptWatchFileName
import repro_hash
import repro_interface_artifacts
import repro_local_store/pattern_scoped_enumeration
import repro_runquota
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
    progressCallback*: BuildProgressCallback
      ## Interactive-UX-And-Progress.md Principle 1 ("Live progress, never
      ## silence"). The dev-env edge is the one engine invocation a user does
      ## not type: the shell hook runs it on `cd`, and before this field
      ## existed it had no way to say anything at all, so a cold activation
      ## was tens of seconds of a shell that looked hung. The engine already
      ## reports per-action state through this callback for `repro build`;
      ## the dev-env path was simply never given one. ``nil`` keeps the old
      ## silent behaviour, which is what every non-interactive caller
      ## (tests, `repro shell --print-env=json`) wants.

  DevEnvEdgeResult* = object
    artifactPath*: string
      ## Where the edge's ``DevEnvArtifact`` lives. Shared by every activation
      ## of this project and activity, so a concurrent activation may replace
      ## it the moment ``computeDevEnvEdge`` returns: read ``artifact`` instead
      ## of this file. The path stays for what needs a NAME (the activation
      ## metadata, stats, diagnostics).
    artifact*: DevEnvArtifact
      ## The artifact this computation produced, decoded while the edge lock
      ## was still held (``devEnvEdgeLockPath``). This is the copy consumers
      ## activate from.
    shellFragment*: string
      ## The rendered shell fragment, read while the edge lock was still held.
      ## Empty unless ``renderShell`` was requested. The same rule as
      ## ``artifact``: ``shellFragmentPath`` is shared, this copy is not.
    interfacePath*: string
      ## The ``ProjectInterfaceArtifact`` this edge extracted, on disk.
      ##
      ## Exposed because the activation surfaces need the recipe's ``uses:``
      ## declarations to realize the toolchain, and re-extracting the
      ## interface to get them would run the provider compile a second time.
      ## The path is deterministic (``<outDir>/project-interface.rbsz``) but
      ## deriving it at each call site is how two spellings of one location
      ## drift apart.
    interfaceArtifact*: ProjectInterfaceArtifact
      ## The interface this computation extracted, decoded while the edge lock
      ## was still held. Valid when ``interfaceDecoded`` is set. The same rule
      ## as ``artifact``: ``interfacePath`` is shared, so a concurrent
      ## activation may replace it once the lock is released.
    interfaceDecoded*: bool
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
    promptWatch*: seq[PromptWatchEntry]
      ## The paths the shell hook's prompt-time key watches for an activation
      ## built from this edge (``devEnvPromptWatchEntries``). The full
      ## ``dev-env export`` writes them as the prompt watch manifest.
    promptWatchComplete*: bool
      ## False when the introspection result carried path COUNTS instead of
      ## paths, so ``promptWatch`` is missing observed inputs. An activation
      ## must then emit a marker no prompt matches rather than a key that
      ## watches only part of what it depends on.
    introspectionStartedAt*: float
      ## Seconds since the epoch, taken immediately BEFORE the build that
      ## runs (or cache-checks) the introspection edge. The prompt watch race
      ## guard (``cache_key.unsettledPromptWatchPaths``) compares watched
      ## paths against this moment: an edit before it was already visible to
      ## the edge, so only one at or after it can have slipped between the
      ## edge reading a file and the activation stat'ing it. Taking the time
      ## at process start instead -- before the provider compile -- made a
      ## project whose files were written just before `repro` was launched
      ## look unsettled on its first activation, every time.
    promptWatchOwnWrites*: seq[string]
      ## Absolute paths the introspection edge itself wrote or created, when
      ## it ran (`evidence.monitorWrites`). The race guard treats a current
      ## entry these explain -- one the edge created, or a directory it wrote
      ## into -- as the edge's own doing rather than a change it might have
      ## missed. Empty for a cache hit: nothing ran, so nothing is explained.
    promptWatchOwnRemovals*: seq[string]
      ## Absolute paths the introspection edge itself removed, when it ran
      ## (`evidence.monitorRemovals`). Kept apart from the writes because only
      ## a removal explains an ABSENCE, and only a write a PRESENT entry: an
      ## entry the edge wrote and somebody else then deleted, or one it
      ## removed and somebody else then created again, must still be reported
      ## (``cache_key.unsettledPromptWatchPaths``). Empty for a cache hit.

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
    # Named-Lock-Files §7.2. The provider-compile edge runs before any solve
    # in this path, so no solved package instance governs it; see
    # `lockIdentityOutsideSolvedGraph`'s doc comment for why that is stated
    # here rather than defaulted.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = compilerCwd,
    inputs = inputs,
    outputs = providerCompileOutputs(artifactPath, plan.outputBinaryPath),
    commandStatsId = "repro provider compile edge",
    # Same monitor-injectability gate the CLI edge uses: on Linux a static-ELF
    # compiler cannot be LD_PRELOAD-injected, so its evidence is incomplete and
    # the edge must not publish. This was hard-coded ``true`` here.
    cacheable = providerCompileCacheable(plan),
    weakFingerprint = plan.compileEdge.actionFingerprint,
    # THE SAME EDGE, SO THE SAME DECLARATION. This runs byte-for-byte the
    # argv the CLI's own provider-compile edge runs — the ``repro`` helper
    # invoking ``nim c`` on the recipe's provider — so it must carry the same
    # environment contract and the same determinism claim. It did not, and
    # both omissions were silent:
    #
    #   * WITHOUT ``envPassthrough`` the two edges disagree about their own
    #     identity. The passthrough NAMES are mixed into the action key, so
    #     the same compile keyed differently depending on which entry point
    #     reached it, and the compiler / C toolchain / scratch-location
    #     variables were resolved by plain inheritance rather than declared.
    #   * WITHOUT the blessing the edge never publishes. A monitored ``nim c``
    #     reads entropy (measured on this edge's own capture: 167
    #     ``mrNonDeterministic`` records, ``arc4random`` + ``getrandom``, a
    #     complete capture with no event loss), and an unblessed action that
    #     reads entropy has its action-cache hits disabled. So the provider
    #     recompiled on EVERY activation, which surfaced as a dev-env that
    #     reported a rebuild each time it was entered.
    #
    # The justification is the one already stated for the identical command:
    # this helper only compiles: it never runs what it produced, so the
    # compiler's randomness has no path to an output.
    envPassthrough = @ProviderCompileEnvironmentPassthrough &
      @ProviderCompileIsolatedPassthrough,
    # Declared, so the caller's shell does not decide the edge's key; see
    # `providerCompileLaunchEnv`.
    env = providerCompileLaunchEnv(compilerCwd / "home"),
    # Dev-Env-Warm-Entry.md §2: the compile starts from the environment
    # declared above and nothing else, so no caller variable can be an input.
    isolateHostEnvironment = true,
    nonDeterminism = ndpEntropyBlessed,
    nonDeterminismJustification = ProviderCompilerEntropyJustification,
    dependencyPolicy = automaticMonitorGatheringPolicy(
      providerCompileIgnoredInputPrefixes(scratchDir)))

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
    # A dev-env activation is a person (or a ``just`` recipe) waiting to run
    # one command, and its graph is one small recipe compile. When another
    # workspace's build holds the whole RunQuota budget that compile used to
    # queue with no word and no end -- the 2026-09-24 ``repro exec`` hang.
    # Ask to be served first when capacity frees, and give up with a
    # diagnosis rather than waiting silently forever.
    runQuotaInteractive: true,
    runQuotaQueueTimeoutMs: devEnvRunQuotaQueueTimeoutMsDefault,
    suppressTrace: false,
    skipCacheHitEvidence: false)
  # The root classification this activation declares, for
  # `Incremental-Invalidation.md` §"Validation Criteria"'s second mandatory
  # exemption: an enumerated directory in an UNTRACKED scope carries no
  # membership digest.
  #
  # THIS EDGE IS THE ONE THE EXEMPTION WAS MEASURED ON. The provider compile
  # is a `nim c`, and Nim's upward module and config search enumerates every
  # ancestor of its working directory: 449 recorded enumerations on one
  # activation, among them `/`, `/Users/`, `$HOME`, `$HOME/.cache/` and
  # `/nix/` (see
  # `issues/2026-09-24-dev-env-never-converges-on-a-fresh-project.md`, the
  # fifth cause). So the edge's key carried the immediate membership of the
  # filesystem root and of the user's home directory, and could not converge
  # across processes at all — which relinked the provider binary, made it
  # non-bit-reproducible, and left the introspection edge reporting "no cache
  # record for weak fingerprint" downstream of it.
  #
  # No `repositoryRoot`: finding one is a `.git` walk (the CLI's
  # `repositoryRootOf`), and an activation runs on every `cd`. Omitting a
  # root leaves more directories membership-tracked, which is the safe
  # direction.
  result.filesystemRoots = declaredFilesystemRoots(config.projectRoot,
    config.workDir, resolvedStoreRootOrEmpty(), outRoot = config.outDir)
  result.statsEnabled = config.statsEnabled
  result.progressCallback = config.progressCallback
  # A warm activation must stay on the no-op fast path even while it renders
  # progress; see `BuildEngineConfig.fastNoopReportsProgress`.
  result.fastNoopReportsProgress = true

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

proc effectiveToolProvisioning*(requested: ToolProvisioningMode;
                                artifact: ProjectInterfaceArtifact):
    ToolProvisioningMode =
  ## The provisioning mode an activation of ``artifact`` runs under.
  ##
  ## Precedence: an explicitly requested mode, then
  ## ``REPRO_TOOL_PROVISIONING``, then the recipe's own
  ## ``defaultToolProvisioning``. Taking a bare mode rather than a whole
  ## ``DevEnvEdgeConfig`` is what lets the CLI's activation surfaces resolve
  ## the SAME mode the edge ran under without rebuilding the config — two
  ## spellings of this precedence is exactly how an activation ends up
  ## realizing tools under one mode and reporting another.
  if requested != tpmUnspecified:
    return requested
  let envMode = getEnv("REPRO_TOOL_PROVISIONING").strip()
  if envMode.len > 0:
    return parseDevEnvToolProvisioning(envMode)
  let defaultMode = artifact.projectInterface.defaultToolProvisioning.strip()
  if defaultMode.len > 0:
    return parseDevEnvToolProvisioning(defaultMode)
  tpmUnspecified

proc effectiveToolProvisioning*(config: DevEnvEdgeConfig;
                                artifact: ProjectInterfaceArtifact):
    ToolProvisioningMode =
  effectiveToolProvisioning(config.toolProvisioning, artifact)

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
# per-prompt fast path calls BEFORE walking the build graph. The full
# ``dev-env export`` emits this same key as the ``__REPRO_APPLIED`` marker,
# and the next prompt re-derives it from disk and compares; both sides MUST
# compute it identically for the same ``DevEnvEdgeConfig`` and watch
# manifest — otherwise the user sees flapping where every prompt falls
# through to the full walk. The implementation is
# ``repro_dev_env_engine/cache_key``, which the thin client links on its own;
# this wrapper only unpacks the config.
#
# It is a prompt-time key ONLY. ``computeDevEnvEdge`` does not consult it:
# it reads the project file and none of the modules that file imports, so
# it cannot say whether an extracted interface or a compiled provider is
# still current. Using it for that once served a stale interface after a
# stdlib package edit; see the interface step in ``computeDevEnvEdge``.
#
# The key is a deterministic hash of (``cache_key.nim`` holds the ordered
# list, and ``tests/unit/t_dev_env_cache_key_frame.nim`` pins it):
#
# * an in-document schema string (``reprobuild.dev-env.cache-key.v2``)
#   so a change to the inputs invalidates every existing key without us
#   having to migrate or version anything in the manifest.
# * the project root path
# * the project file's content (``repro.nim`` or the legacy
#   ``reprobuild.nim``; when both exist the key names neither and the full
#   CLI reports the ambiguity), or the synthesised NF-4 auto-load project
#   file when the project has none of its own
# * the activity selector
# * the lock-slice id (when the caller passed one) PLUS the contents of
#   ``<projectRoot>/.repro/dev-env.lock`` when present (so a manual edit
#   to the lock file invalidates the fast path)
# * the develop-overrides file content (if present)
# * the env vars the edge consumes that the CLI can name up front:
#   ``REPRO_DEVELOP_OVERRIDES_FILE``, ``REPRO_TOOL_PROVISIONING``,
#   ``REPRO_STORE_ROOT``, ``REPROBUILD_LIBS_DIR``, ``REPROBUILD_REPO_ROOT``
# * the PROMPT WATCH MANIFEST of the activation being compared against:
#   the ``lstat`` metadata of every path that activation's introspection
#   edge was observed to depend on (``devEnvPromptWatchEntries`` below),
#   plus ``flake.nix`` / ``flake.lock`` unconditionally. Without it, an
#   edit to ``flake.nix`` or to an override sibling's working tree was
#   answered as a no-op on every prompt after it (``reprobuild-pm``
#   ``issues/2026-09-28-dev-env-prompt-key-ignores-flake-inputs.md``;
#   ``Nix-Flake-Coexistence.md`` §2b requires re-entry to be decided against
#   the OBSERVED manifest).
#
# The implementation deliberately walks NO build graph, spawns NO
# subprocess and hashes no observed file's content. It reads at most four
# small files (the project file, the develop-overrides file, the dev-env
# lock file, the watch manifest) and ``lstat``s each watched path, which the
# kernel holds hot after the first prompt. The microbench in
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

proc computeDevEnvEdgeCacheKey*(config: DevEnvEdgeConfig;
                                watchManifestPath = ""): string =
  ## See module-level note. Returns a 32-char lowercase hex digest.
  ## ``watchManifestPath``: see ``cache_key.computeDevEnvEdgeCacheKey``.
  devEnvCacheKey.computeDevEnvEdgeCacheKey(config.projectRoot, config.activity,
    config.lockSliceId, config.developOverridesPath, watchManifestPath)

proc devEnvIntrospectionIgnoredInputPrefixes*(projectRoot: string;
    protocolRoot = ""): seq[string] =
  ## Prefixes the dev-env introspection edge's monitor must NOT record as
  ## inputs. The same shape as `providerCompileIgnoredInputPrefixes`, and for
  ## the same reason: derived state a tool writes and reads back is not an
  ## input, and recording it makes a warm entry miss its cache for no reason a
  ## user can act on.
  ##
  ## Two entries, and both are MEASURED — from the `.iomon` of a real
  ## `useFlakeDevShell()` edge, not from what a foreign tool might plausibly
  ## do. Each one is a licence for a cached dev shell to survive a change it
  ## was built from, so the set is kept to what an edge demonstrably rewrites
  ## and reads back, and it is asserted in
  ## `tests/integration/t_nf4_foreign_env_contract.nim`.
  ##
  ##   * `<projectRoot>/.repro/foreign-env` — Reprobuild's own scratch for this
  ##     edge: the script the foreign command produced, the profile gcroot, the
  ##     two stdout/stderr side-channels. Written by the edge and read back by
  ##     it, exactly like the provider compile's scratch tree. Scoped to THIS
  ##     project, because a sibling project's scratch is somebody else's state.
  ##   * `nix`'s own cache directory. NF-4's `useFlakeDevShell` runs
  ##     `nix print-dev-env` inside this edge, and the depfile carried
  ##
  ##       ~/.cache/nix/eval-cache-v6/<flake-fingerprint>.sqlite{,-shm,-wal}
  ##       ~/.cache/nix/fetcher-cache-v4.sqlite{,-shm,-wal}
  ##
  ##     which `nix` opens read-write on every invocation, so every entry into
  ##     the shell invalidated the previous one and the cached artifact was
  ##     never once reused. That is the whole value of §2b's observed manifest
  ##     lost to a file that describes `nix`'s memory of its own past runs.
  ##
  ## *Deliberately NOT the user cache directory as a whole, and this is the
  ## load-bearing part.* Reprobuild's OWN content-addressed store and action
  ## cache live under it — `repro_local_store.defaultUserStoreRoot()` is
  ## `$XDG_CACHE_HOME/repro/store` and `resolveActionCacheRoot` puts the action
  ## cache in its sibling `repro/action-cache` — so a `getCacheDir()`-wide
  ## prefix would make this edge blind to the artifacts Reprobuild itself
  ## materialises for it. The usual defence of a broad ignore ("a dev
  ## environment that depends on `~/.cache` was never reproducible anyway")
  ## does not apply to those: the store is content-addressed, it is exactly
  ## what a binary cache ships, and it IS reproducible on another machine.
  ## The user STATE directory is likewise absent, and that one is not a
  ## precaution either: the same depfile records
  ## `~/.local/state/nix/profile/etc/xdg/nix/nix.conf` — the `nix.conf` the
  ## user's nix PROFILE supplies, which decides what `nix` evaluates. It does
  ## not churn and it is a real input, so a `~/.local/state` prefix would drop
  ## it and let a cached dev shell survive a change to the configuration it
  ## was built under. That is the failure this campaign exists to stop, just
  ## reached from the ignore list instead of from a `watch_file` list.
  ##
  ## The two are resolved the way `nix` resolves them (`$XDG_CACHE_HOME/nix`,
  ## else `$HOME/.cache/nix`) rather than through Nim's `getCacheDir()`, which
  ## answers `~/Library/Caches` on macOS while `nix` keeps using `~/.cache`
  ## there.
  ##   * the edge's OWN protocol directory (`<outDir>/dev-env-protocol`).
  ##     The introspection edge talks to the provider binary by writing a
  ##     request file and reading the response back out of this directory,
  ##     so every one of its files is state this action produced in THIS
  ##     run. They are rewritten on every invocation, which means their
  ##     metadata is new every time: recording them made the edge depend on
  ##     its own transcript and miss on every warm run, forever, on a
  ##     project nothing had touched. Measured with the paths otherwise
  ##     identical between two consecutive runs -- same names, same sizes,
  ##     only the mtimes moved. This is the same rule S5 applies to an
  ##     action's declared outputs (`selfWrittenOutputKeys`), reached from
  ##     the ignore list because the transcript is scratch rather than a
  ##     declared product.
  if protocolRoot.len > 0:
    result.add(absolutePath(protocolRoot))
  if projectRoot.len > 0:
    result.add(absolutePath(projectRoot) / ".repro" / "foreign-env")
  let xdgCache = getEnv("XDG_CACHE_HOME")
  if xdgCache.len > 0:
    result.add(absolutePath(xdgCache) / "nix")
  else:
    let home = getEnv("HOME")
    if home.len > 0:
      result.add(absolutePath(home) / ".cache" / "nix")

proc pathIsAtOrUnder(path, prefix: string): bool =
  ## ``path`` is ``prefix`` or lies beneath it, on a component boundary.
  if prefix.len == 0 or not path.startsWith(prefix):
    return false
  path.len == prefix.len or path[prefix.len] in {'/', '\\'} or
    prefix[^1] in {'/', '\\'}

proc spellingsOf(path: string): seq[string] =
  ## A directory as the CALLER spells it and as the KERNEL reports it. The
  ## monitor records resolved paths -- on macOS `/private/var/folders/...`
  ## for a `$TMPDIR` the caller knows as `/var/folders/...` -- so a prefix
  ## comparison against only one spelling silently misses.
  if path.len == 0:
    return @[]
  result = @[absolutePath(path)]
  try:
    let resolved = expandFilename(path)
    if resolved notin result:
      result.add(resolved)
  except OSError:
    discard

proc devEnvPromptWatchEntries*(action: BuildAction;
                               introspection: ActionResult;
                               projectRoot, outDir: string;
                               trackedRoots: openArray[string];
                               complete: var bool): seq[PromptWatchEntry] =
  ## The paths the shell hook's prompt-time key must watch for this
  ## activation: the introspection edge's OBSERVED inputs, plus
  ## ``flake.nix`` / ``flake.lock`` declared unconditionally. Written by the
  ## full ``dev-env export`` as the prompt watch manifest
  ## (``cache_key.writePromptWatchManifest``); see the prompt watch section
  ## of ``repro_dev_env_engine/cache_key`` for how the key folds it in, and
  ## ``reprobuild-pm`` ``issues/2026-09-28-dev-env-prompt-key-ignores-flake-
  ## inputs.md`` for why it exists.
  ##
  ## THE ENGINE'S OWN RULES DECIDE THE SET, so it is the set the action
  ## cache keys this edge on (`Nix-Flake-Coexistence.md` §2b: re-entry is
  ## decided against the observed manifest):
  ##
  ##   * the paths are ``cacheInputPaths`` -- exactly the input list a cache
  ##     record of this execution is published with. That already drops what
  ##     the engine has measured is not an input: the edge's ignored prefixes
  ##     (`nix`'s cache, ``.repro/foreign-env``), the monitor's per-run
  ##     sandbox tool directory, the action's own outputs and the
  ##     directories it created for them;
  ##   * an entry tracks MEMBERSHIP exactly when ``cacheEnumeratedDirectories``
  ##     says the record fingerprints that directory's membership -- an
  ##     enumerated directory inside a tracked root -- and existence
  ##     otherwise.
  ##
  ## WHY NOT THE RAW EVIDENCE. A cache hit's evidence is the RECORD replayed
  ## (``evidenceFromRecord``), and the record is the filtered set. Built
  ## from raw evidence, an activation that ran the edge and a later one that
  ## hit its record listed different paths for the same unchanged project,
  ## so they emitted different markers -- measured, as a failure of
  ## `t_e2e_shell_hook_cd_activate_deactivate.nim`'s cd-out/cd-back
  ## assertion -- and the launched manifest carried the monitor's
  ## `repro-fs-snoop-sandbox-tools-<pid>-<time>` directory, a name no
  ## other run ever repeats. Applying the record's rules to both makes the
  ## two the same set by construction: the replay carries the record's
  ## inputs, and its membership-tracked directories as enumerations.
  ##
  ## Three further filters, applied identically to both:
  ##
  ##   * ``/nix/store/`` -- content-addressed and immutable: a valid store
  ##     path's bytes never change, so its metadata carries no news. (It is
  ##     also most of a flake's observed set.)
  ##   * the edge's own ``outDir`` -- derived scratch the engine re-keys
  ##     itself (the provider binary, the protocol transcript, the
  ##     artifacts). Every activation that recompiles the provider rewrites
  ##     it, so keeping it would trip the race guard after every such
  ##     activation.
  ##   * ``devEnvIntrospectionIgnoredInputPrefixes`` again, under every
  ##     spelling of each prefix. The record does not reliably drop all of
  ##     it: measured on a `useFlakeDevShell()` edge on macOS, the record
  ##     kept `<projectRoot>/.repro/foreign-env/flake-profile`, the nix
  ##     profile gcroot the edge itself rewrites on every run, so its ctime
  ##     always postdated the edge's start and the race guard made every
  ##     activation's marker unmatchable -- no prompt was a no-op again.
  ##     A path filter, so it removes the same entries from a launched set
  ##     and from a replayed one.
  ##
  ## If a caller ever elides a hit's evidence paths, or skips rebuilding a
  ## hit's evidence altogether, ``complete`` is set false and the caller
  ## must not emit a matchable key.
  complete = not introspection.evidencePathsElided
  # `skipCacheHitEvidence` leaves a hit with a ZERO `PathSetEvidence`, which
  # is not elided and so reads exactly like "observed nothing": the set below
  # would shrink to the flake floor and an override sibling's edit would be
  # a no-op again. `engineConfig` turns the skip off for this edge today;
  # this keeps a future change to that from failing silently. Every hit
  # whose evidence WAS rebuilt carries `evcReplayedCacheRecord`
  # (`evidenceFromRecord` sets it unconditionally).
  if introspection.cacheDecision == cdHit and
      evcReplayedCacheRecord notin introspection.evidence.evidenceProvenance:
    complete = false
  var excludedPrefixes = @["/nix/store/"]
  for prefix in spellingsOf(outDir):
    excludedPrefixes.add(prefix)
  for ignored in devEnvIntrospectionIgnoredInputPrefixes(projectRoot):
    for prefix in spellingsOf(ignored):
      excludedPrefixes.add(prefix)

  let evidence = introspection.evidence
  var membership = initHashSet[string]()
  for dir in action.cacheEnumeratedDirectories(evidence, trackedRoots):
    membership.incl(dir)
  var watched: seq[PromptWatchEntry]
  proc consider(recorded: string) =
    # A pattern-scoped enumeration (`patternScopedEnumerationPath`) is
    # watched as its whole directory: the manifest's `d` comparison has no
    # pattern, and watching the full membership notices every change the
    # scoped one could, so it errs toward an extra activation, never a
    # missed change.
    let path = recorded.patternScopedBase()
    if path.len == 0:
      return
    for prefix in excludedPrefixes:
      if path.pathIsAtOrUnder(prefix):
        return
    watched.add(PromptWatchEntry(path: path,
      enumerated: recorded in membership))
  for path in action.cacheInputPaths(evidence):
    consider(path)
  # The floor, for the case the monitor saw nothing at all (no monitor on
  # this host, or a capture that lost its records): the two files every
  # `useFlakeDevShell()` activation reads. Declared whether or not they
  # exist, so that one appearing is seen too.
  if projectRoot.len > 0:
    consider(absolutePath(projectRoot) / "flake.nix")
    consider(absolutePath(projectRoot) / "flake.lock")
  watched

const NixDevEnvEntropyJustification* =
  "`nix` draws randomness in two places while evaluating a flake dev shell, " &
  "measured with strace on `nix print-dev-env` (nix 2.32, 2026-09-29): " &
  "five small getrandom calls at process start, before any evaluation " &
  "(runtime and library seeding), and one 4-byte draw that names " &
  "/tmp/nix-dev-env-<pid>-<random>, a directory the same process creates " &
  "and deletes. Neither reaches the output: two runs produced " &
  "byte-identical `print-dev-env` scripts, and with nix-shell's scratch " &
  "variables left out of the capture the dev-env artifact is byte-identical " &
  "across entries. This blesses ENTROPY from the `nix` image on the dev-env " &
  "introspection edge only."

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
    # Named-Lock-Files §7.2 — see `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = config.workDir,
    inputs = inputs,
    outputs = @[artifactPath],
    env = config.commonMonitorEnv(),
    commandStatsId = "repro dev-env introspection edge",
    cacheable = true,
    weakFingerprint = weak,
    # Dev-Env-Warm-Entry.md §4. Scoped to this edge AND to the `nix` image:
    # entropy from anything else in the tree (recipe code in the provider
    # included) still withholds the entry.
    entropyBlessedImages = [EntropyBlessedTool(image: "nix",
      spec: "Dev-Env-Warm-Entry.md §4",
      justification: NixDevEnvEntropyJustification)],
    dependencyPolicy = automaticMonitorGatheringPolicy(
      devEnvIntrospectionIgnoredInputPrefixes(config.projectRoot,
        protocolRoot)))

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
    # Named-Lock-Files §7.2 — see `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = config.workDir,
    inputs = @[artifactPath],
    outputs = @[shellFragmentPath, navigatorStatsPath],
    commandStatsId = "repro dev-env shell render edge",
    cacheable = true,
    weakFingerprint = weak,
    dependencyPolicy = automaticMonitorGatheringPolicy())

proc devEnvNixProvisioningActions*(toolUses: openArray[InterfaceToolUse];
    effectiveProvisioning: ToolProvisioningMode;
    outDir, workDir: string; projectRoot = ""): seq[BuildAction] =
  ## ``workDir`` is the engine's compiler/library directory. A relative Nix
  ## selector belongs to the caller's project, whose root must travel to the
  ## provisioner independently of that compilation directory.
  let selectorRoot = absolutePath(if projectRoot.len > 0: projectRoot else: workDir)
  var seen: seq[string]
  for useDef in toolUses:
    if effectiveProvisioning in {tpmUnspecified, tpmNix} and
        useDef.nixProvisioning.len > 0 and
        nixServesTarget(hostRealizationTarget()):
      # Use the same acquisition edges as build-time tool resolution. Their
      # metadata binds selector ownership, their checksum inputs invalidate
      # edited flake files, and expression-file acquisitions stay uncacheable.
      # The foreign edge's cwd is its tool store for GC-root accounting; the
      # provider compilation keeps its separate workDir below.
      let plan = nixAcquisitionPlan(useDef)
      # Expression-file builders deliberately draw a new nonce per request.
      # Coalesce equal acquisitions before creating them, while preserving
      # their uncacheable disposition across separate activations.
      let acquisition = selectorRoot & "\0" & plan.nixSelector & "\0" &
        plan.nixExpressionFile
      if acquisition in seen:
        continue
      seen.add(acquisition)
      let provision = nixToolProvisioningEdges(useDef, outDir / "tool-store",
        selectorRoot)
      # Build-time acquisition deliberately replaces one tool request's
      # receipt when its selector changes. An activation can request several
      # selectors for that package together, so retain its per-acquisition
      # namespace while sharing the builder's execution and cache contract.
      let identity = hexDigest(fingerprintText([
        "reprobuild.dev-env.nix-provision.v3", acquisition]))
      var edge = provision.actions[0]  # Nix acquisition has one foreign edge.
      edge.id = "nix-provision." & identity
      edge.outputs = @[outDir / "tool-store" / "nix-provision" /
        (identity & ".receipt")]
      result.add(edge)


proc devEnvEdgeLockPath*(outDir: string): string =
  ## The lock that serialises computations of the dev-env edge sharing
  ## ``outDir``. See ``computeDevEnvEdge``.
  outDir / "dev-env.lock"

proc computeDevEnvEdge*(config: DevEnvEdgeConfig): DevEnvEdgeResult =
  ## Bring the project's development environment up to date and return it.
  ##
  ## CONCURRENT ACTIVATIONS OF ONE PROJECT ARE SERIALISED HERE
  ## (`Development-Environments-And-Control-API.md`, "Concurrent Activations
  ## Of One Project"). Everything this edge keeps lives in ``config.outDir``,
  ## at fixed paths: the extracted interface, the provider binary and its
  ## compile artifact, the introspection edge's protocol transcript
  ## (``dev-env-protocol/``, whose request and response names are fixed so the
  ## edge's identity and evidence are stable), the edge's declared
  ## ``DevEnvArtifact`` output and the rendered shell fragment. Two processes
  ## computing the edge at once used to interleave over those paths; measured
  ## (reprobuild-pm issue 2026-10-25, concurrent `repro exec` racing on the
  ## provider response file), one run's helper removed the response file the
  ## other run's provider had just written, and that run failed with
  ## "provider did not write response".
  ##
  ## Per-run protocol file names would have repaired that one file and none
  ## of the others, so the whole computation holds an exclusive lock on
  ## ``devEnvEdgeLockPath(outDir)``, from before the interface extraction
  ## until the artifact (and the shell fragment, when rendered) has been read
  ## into the result. A concurrent activation waits, and then normally finds
  ## a cache hit on the record the holder published. The lock is not
  ## inherited by anything the edge spawns, and it is released before this
  ## returns, so the activated command itself never holds it: a command that
  ## activates the same project again does not wait on its parent.
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

  result.artifactPath = config.outDir / "dev-env.rbde"
  result.shellFragmentPath = config.outDir / "dev-env.env"
  result.shellNavigatorStatsPath = config.outDir / "dev-env.env.navigator.json"

  createDir(extendedPath(config.outDir))
  var edgeLock = acquireExclusiveFileLock(devEnvEdgeLockPath(config.outDir))
  defer: releaseExclusiveFileLock(edgeLock)
  # This process is the activation itself (`repro exec`, the shell hook), not
  # a monitored action, so it may keep a stamp-validated memo of the library
  # source fingerprint: re-hashing reprobuild's whole libs tree was most of
  # the cost of a warm entry. Project-scoped, beside the edge's other scratch.
  setReproLibFingerprintMemoDir(config.outDir / "lib-source-fingerprint")
  # One walk and one stat pass of reprobuild's libs tree per computation,
  # shared by the fingerprint and the provider freshness check.
  beginReproLibSourcesScope()
  defer: endReproLibSourcesScope()
  let workDir =
    if config.workDir.len > 0: config.workDir else: getCurrentDir()
  var active = config
  active.workDir = workDir
  let compileScratchDir = active.outDir / "provider-work"

  let interfacePath = active.outDir / "project-interface.rbsz"
  let stubPath = active.outDir / "project-interface.nim"
  result.interfacePath = interfacePath

  # Whether the interface on disk can be reused is decided by
  # ``extractInterfaceFromModule``'s own warm check and by nothing in front of
  # it. That check is keyed on what the extraction actually compiles: the
  # recipe's source closure (every module it imports, its own directory's
  # sources included), the reprobuild library sources and their ``--path``
  # set, the selected catalog and the compiler. A warm entry costs one stamp
  # pass over those files, with no hashing and no compile.
  #
  # There used to be a second, cheaper gate here: reuse the interface whenever
  # ``dev-env.rbde.cache-key`` equalled ``computeDevEnvEdgeCacheKey``. That is
  # the PROMPT-TIME key, and it reads the project file and nothing it
  # imports, so it vetoed the warm check in exactly the cases the warm check
  # exists for. Editing a stdlib package the recipe compiles in
  # (``repro_dsl_stdlib/packages/gh.nim``), or a module beside the project
  # file, left every later activation replaying an interface extracted from
  # the old source until the dev-env directory was deleted by hand
  # (reprobuild-specs issue
  # 2026-09-24-dev-env-reuses-interface-after-stdlib-package-change). Its file
  # had no other reader and is no longer written.
  #
  # ``consumerRoot`` is the recipe's OWN project root. Left implicit it would
  # be the process cwd, which is only incidentally the same thing — and is
  # baked into the compiled recipe, so a wrong value is silent.
  let interfaceArtifact = extractInterfaceFromModule(active.modulePath,
    interfacePath, stubPath, workDir, compileScratchDir,
    consumerRoot = parentDir(absolutePath(active.modulePath)))
  # Shared-Development-Services §4.3's stale-lift precondition: record what
  # this artifact was lifted from, beside it, so a CONSUMER of a shared
  # service this recipe declares can establish whether it still corresponds
  # to this recipe.
  #
  # Stamped after every call, warm or not. While the prompt-time key gated
  # reuse, a reused interface could be older than its import closure, and
  # stamping it would have recorded the current closure against older bytes.
  # ``extractInterfaceFromModule`` returns an interface only after checking
  # it against that closure (or after re-extracting it), so the closure
  # recorded here is the one those bytes were extracted from.
  writeInterfaceArtifactProvenance(interfacePath, active.modulePath)
  result.interfaceArtifact = interfaceArtifact
  result.interfaceDecoded = true
  let effectiveProvisioning =
    active.effectiveToolProvisioning(interfaceArtifact)

  result.providerBinaryPath = active.outDir / "provider" / "project-provider"
  result.providerArtifactPath = active.outDir / "provider-compile.rbsz"

  let provisioningActions = devEnvNixProvisioningActions(
    interfaceArtifact.projectInterface.toolUses, effectiveProvisioning,
    active.outDir, workDir, active.projectRoot)
  var provisioningReceipts: seq[string]
  for provision in provisioningActions:
    provisioningReceipts.add(provision.outputs)

  var provider: ProviderCompileArtifact
  let providerPlan = providerCompilePlan(active.modulePath,
    result.providerBinaryPath, interfaceArtifact.interfaceFingerprint, workDir,
    compileScratchDir)
  let cachedProvider = staticFreshnessFallbackProvider(providerPlan,
    result.providerArtifactPath, active.modulePath, result.providerBinaryPath,
    interfaceArtifact.interfaceFingerprint, workDir)
  if cachedProvider.isSome:
    provider = cachedProvider.get()
    result.stats.providerBuildSkippedFresh = true
  else:
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
    # ``asCacheHit`` and ``asUpToDate`` BOTH mean the cache satisfied this edge
    # and no compile ran; they differ only in whether the outputs had to be
    # restored from the CAS or were already on disk. A consumer reading
    # ``cacheHit`` wants to know whether work was avoided, so it must accept
    # both. Comparing against ``asCacheHit`` alone under-reports every warm
    # reuse -- see ``repro_cli_support``'s ``providerCompileCacheHit``, which
    # has always used the set form for this same concept.
    result.stats.providerBuildCacheHit =
      result.providerCompileAction.status in {asCacheHit, asUpToDate}
    # ``providerBuildSkippedFresh`` used to mean "the hand-written freshness
    # gate said the artifact was fresh, so we never entered the engine". With
    # the gate gone it is re-derived from the engine's own decision: the edge
    # was scheduled and the engine decided not to launch a compile, either by
    # restoring the outputs from the CAS (``asCacheHit``) or by accepting the
    # already-present outputs against a revalidated action-cache record
    # (``asUpToDate``, which is what ``rebuildMissingOutputsOnCacheHit`` turns
    # a hit into when the outputs are still on disk).
    result.stats.providerBuildSkippedFresh =
      result.providerCompileAction.status in {asCacheHit, asUpToDate}
    if result.providerCompileResult.hasFailedActions():
      raiseDevEnvEdge(providerCompileFailure(result.providerCompileResult))
    if not fileExists(extendedPath(result.providerArtifactPath)):
      raiseDevEnvEdge("provider compile edge did not write artifact: " &
        result.providerArtifactPath)
    provider = readProviderCompileArtifact(result.providerArtifactPath)
    let providerConsistency = providerCompileConsistencyAfterExecution(
      providerPlan, result.providerArtifactPath)
    if not providerConsistency.fresh:
      raiseDevEnvEdge("provider compile artifact is stale after edge " &
        "execution: " & result.providerArtifactPath & "\n" &
        providerConsistency.detail)

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
  result.introspectionStartedAt = epochTime()
  result.devEnvResult = runBuild(graph(actions & provisioningActions), devEnvConfig)
  result.introspectionAction = result.devEnvResult.actionById(
    "__repro_dev_env_introspection")
  result.promptWatch = devEnvPromptWatchEntries(introspectionAction,
    result.introspectionAction, active.projectRoot, active.outDir,
    trackedFilesystemRootPaths(devEnvConfig.filesystemRoots),
    result.promptWatchComplete)
  if result.introspectionAction.launched:
    # The race guard's own-changes list (see the field). Only from an edge
    # that RAN: a hit's evidence is the record replayed, and wrote nothing.
    let evidence = result.introspectionAction.evidence
    proc absolute(path: string): string =
      if path.isAbsolute: path else: active.workDir / path
    for path in evidence.monitorWrites:
      result.promptWatchOwnWrites.add(absolute(path))
    for path in evidence.monitorRemovals:
      result.promptWatchOwnRemovals.add(absolute(path))
  result.shellRenderAction = result.devEnvResult.actionById(
    "__repro_dev_env_shell_render")
  result.stats.providerIntrospectionLaunched =
    result.introspectionAction.launched
  result.stats.providerIntrospectionCacheHit =
    result.introspectionAction.status in {asCacheHit, asUpToDate}
  result.stats.artifactWriteLaunched =
    result.stats.providerIntrospectionLaunched
  result.stats.artifactWriteSkipped =
    not result.stats.artifactWriteLaunched
  if active.renderShell:
    result.stats.shellRenderingLaunched = result.shellRenderAction.launched
    result.stats.shellRenderingCacheHit =
      result.shellRenderAction.status in {asCacheHit, asUpToDate}
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
  # Read while the lock is held: once it is released, the next activation
  # may replace these files, and a reader would see a torn one.
  result.artifact = readDevEnvArtifact(result.artifactPath)
  if active.renderShell:
    result.shellFragment = readFile(extendedPath(result.shellFragmentPath))
