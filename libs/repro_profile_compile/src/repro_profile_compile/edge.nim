## Profile-compile build-graph edge.
##
## `compileProfileToRbpi` turns a `home.nim` / `system.nim` profile into the
## RBPI envelope the apply pipelines consume. It does exactly one thing: it
## schedules ONE monitored `bakProcess` edge through `runBuild` and returns
## what that edge published. Nothing in front of the edge, inside the child
## it spawns, or behind it decides whether a previous result is still good —
## the engine's action cache decides, from what io-mon observed the edge read.
##
## WHY NOTHING ELSE MAY DECIDE FRESHNESS. This edge used to be fronted by a
## structural fast path: an `import ./…` text walk (`discoverProfileSources`)
## was hashed into a digest, the `.rbpi` was named after that digest, and a
## valid envelope at that name was returned before `runBuild` was ever called.
## The walk cannot see what Nim actually reads — `staticRead`, `include`,
## `when`, macros, `config.nims`, and anything the profile binary reads when it
## RUNS — so a profile whose helper read `casks.txt` through `staticRead` kept
## planning the first payload after the file changed. The same defect, in the
## same shape, was removed from the interface-extraction and provider compiles
## earlier ("Compiles-Are-Normal-Edges"); the profile compile had not followed.
##
## The edge covers BOTH phases of the helper: `nim c` (so compile-time reads
## are evidence) AND the run of the produced binary whose stdout is the
## `ProfileIntent` (so run-time reads are evidence too — the envelope is the
## binary's BEHAVIOUR, not the binary). Splitting the run out of the edge, or
## running it where the monitor cannot see it, reintroduces a stale intent;
## `t_e2e_profile_compile_runtime_read_tracked` pins that.
##
## The only declared identity the edge carries is what monitoring cannot
## supply (see `profileCompileWeakFingerprint`): which compiler and helper are
## doing the work, and where the declared output lands.

import std/[os, strutils]
from repro_core/paths import extendedPath

import blake3
import repro_core
from repro_core/source_root import resolveReprobuildSourceRoot
import repro_hash
import repro_build_engine
import repro_profile_intent/envelope as profile_envelope

import ./sources
import ./compile
import ./platforms

# ---------------------------------------------------------------------------
# Public types.
# ---------------------------------------------------------------------------

type
  ProfileCompileArtifact* = object
    ## Result of a successful profile compile.
    ##
    ## `rbpiBytes` is the RBPI envelope ready to feed into the apply pipeline;
    ## `rbpiPath` is where the edge published it. `digestHex` is the BLAKE3
    ## of those bytes — the identity of the produced INTENT, not of any
    ## source set (no source set is enumerated any more).
    ##
    ## The remaining fields report the engine's own decision about the edge,
    ## so a caller (and a test) can tell a cache answer from an execution
    ## without inferring it from timestamps:
    ##
    ## * `edgeLaunched` — the helper process was spawned this call (so `nim`
    ##   ran). False on an action-cache hit.
    ## * `cacheDecision` / `cacheMissReason` / `cachePublishSkipReason` —
    ##   copied verbatim from the engine's `ActionResult`.
    ## * `observedInputs` — the files io-mon observed the edge READ. When the
    ##   edge executed this call, the reads of that execution; on a cache hit
    ##   they are reconstructed from the action-cache record only when the
    ##   caller set `ProfileCompileOptions.reportObservedInputs` (otherwise
    ##   empty: the engine is configured not to reconstruct them, which keeps
    ##   the apply path's warm hit cheap). This is the dependency record the
    ##   action cache keys on; it is exposed so callers can see what a profile
    ##   actually depends on.
    profileRoot*: string
    rbpiPath*: string
    rbpiBytes*: seq[byte]
    digestHex*: string
    edgeLaunched*: bool
    cacheDecision*: CacheDecision
    cacheMissReason*: string
    cachePublishSkipReason*: string
    observedInputs*: seq[string]

  ProfileCompileOptions* = object
    ## Caller-tunable knobs. `stateDir` is the per-user state directory
    ## that hosts the `<state-dir>/profile-cache/` tree. `publicCliPath`
    ## is the absolute path to the `repro` binary that hosts the
    ## `__repro-compile-profile` internal helper subcommand.
    ## `repoRoot` is the reprobuild source tree, passed to the helper as
    ## `--repo-root`; empty resolves it through `resolveReprobuildSourceRoot()`
    ## and refuses with `missingReprobuildSourcesMessage()` when none holds
    ## reprobuild's libs.
    ## `workDir` is the cwd to run the helper in (defaults to the
    ## profile's parent directory). `verbose` and `forceRebuild` are
    ## debug knobs; `forceRebuild` removes the published envelope so the
    ## engine must re-execute the edge rather than answer from its cache.
    ## `reportObservedInputs` asks for `ProfileCompileArtifact.observedInputs`
    ## on a cache hit too (reconstructed from the record the hit was served
    ## from). It does not change the cache decision or the action's identity;
    ## `repro home export` sets it to report the profile files its intent was
    ## compiled from.
    stateDir*: string
    publicCliPath*: string
    repoRoot*: string
    workDir*: string
    verbose*: bool
    forceRebuild*: bool
    reportObservedInputs*: bool

  ProfileCompileError* = object of CatchableError

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

proc raiseProfileCompile(message: string) {.noreturn.} =
  raise newException(ProfileCompileError, message)

proc hasFailedActions(run: BuildRunResult): bool =
  for item in run.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc actionFailureDiagnostic(run: BuildRunResult): string =
  for item in run.results:
    if item.status in {asFailed, asBlocked}:
      var parts = @[item.id & " " & $item.status]
      if item.stderr.len > 0:
        parts.add(item.stderr)
      if item.stdout.len > 0:
        parts.add(item.stdout)
      return parts.join("\n")
  "profile compile failed"

const ProfileCompileActionId* = "__repro_profile_compile"

proc profileCompileActionResult(run: BuildRunResult): ActionResult =
  for item in run.results:
    if item.id == ProfileCompileActionId:
      return item
  ActionResult(id: ProfileCompileActionId)

proc profileCompileKey*(absProfile: string): string =
  ## The stable name of one profile's compile outputs under
  ## `<state-dir>/profile-cache/`: the BLAKE3 of the profile root's absolute
  ## path.
  ##
  ## DECLARED OUTPUT IDENTITY, NOT A FRESHNESS KEY. It names WHERE the edge
  ## publishes, and it deliberately does not move when the profile's content
  ## changes: an output path that moved with the content would be a second,
  ## hand-written cache key in front of the action cache — the defect this
  ## module exists not to have. Content changes are the action cache's
  ## business. The path is hashed rather than embedded so it stays a single
  ## short component on every filesystem.
  blake3.toHex(blake3.digest(absolutePath(absProfile).replace('\\', '/')))

proc profileCompileWeakFingerprint*(nimExe, publicCliPath,
                                    rbpiPath: string;
                                    cCompiler = ""): ContentDigest =
  ## The weak fingerprint — the one part of the action key that is DECLARED
  ## rather than observed — reduced to what monitoring cannot supply:
  ##
  ## * compiler identity: the `nim` and the C compiler the helper will
  ##   resolve, and the helper binary itself (whose embedded encoder decides
  ##   the envelope bytes);
  ## * declared output identity: the published envelope's path and the RBPI
  ##   schema version it is written in.
  ##
  ## It carries NO source digest. What the profile reads — its modules, data
  ## files pulled in with `staticRead`, `config.nims`, reprobuild's libraries,
  ## files the profile binary opens at run time — is recorded by the monitor
  ## and revalidated by the action cache on every lookup. Adding a source
  ## enumeration here would re-create the import-scan key that served stale
  ## intents.
  weakFingerprintFromText(
    "repro.profile.compile.v2\n" &
    "compiler=" & nimExe & "\n" &
    "c-compiler=" & cCompiler & "\n" &
    "helper=" & publicCliPath & "\n" &
    "output=" & rbpiPath & "\n" &
    "rbpi-schema=" & $profile_envelope.RbpiSchemaVersion & "\n")

# ---------------------------------------------------------------------------
# BuildAction construction.
#
# The edge mirrors the provider-compile edge's SHAPE (a monitored `bakProcess`
# running the public CLI's internal helper) and deliberately stops short of
# that edge's determinism claim. Do not finish the symmetry:
#
#   * The provider edge blesses compiler entropy because that helper only
#     ever compiles. THIS helper does not stop at compiling — it runs the
#     binary it just built and re-encodes that run's stdout into the published
#     envelope, so the produced program's behaviour IS the output. A blessing
#     here would cover the profile binary too, and that is exactly the
#     property this edge lacks.
#   * The provider edge's environment passthrough names the compiler and C
#     toolchain it is handed (`REPRO_NIM_COMPILER`, `REPRO_BOOTSTRAP_CC`, the
#     provider nimcache session) and the temp-directory variables. This edge
#     names the compiler variable and the temp-directory variables only
#     (`ProfileCompileEnvPassthrough`): the helper picks its Nim with
#     `resolveProfileNimCompiler` (`$REPRO_NIM_COMPILER`, then `PATH`) and
#     takes its nimcache from argv. Its C compiler comes from
#     `resolveProfileCCompiler` (an explicit choice, else Nim's default, else
#     the recipe compile's fallback); the variables it reads stay OBSERVED
#     (keyed by value), and the resolved path is in the weak fingerprint. Do
#     NOT make it prefer a `cc` that is clang: the `arc4random` clang draws
#     to name its temporary object file is entropy this unblessed edge
#     cannot carry, so its first run would go unpublished.
# ---------------------------------------------------------------------------

const ProfileCompileScratchEnvNames* = ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
  ## Variables that only choose where the compile's disposable files go.
  ## `nim` and the C toolchain read them (io-mon records the reads), and an
  ## observed read is keyed on its VALUE. `nix develop` gives every shell a
  ## fresh `/tmp/nix-shell.XXXXXX`, so keyed by value they made the first
  ## profile compile in every new shell a miss ("input metadata changed:
  ## TEMP") on an unchanged profile -- a full ~7 s recompile. As passthrough
  ## they are keyed by name only (`actionEnvironmentKeyText`) and dropped from
  ## the observed-environment key (`cacheEnvInputs`), exactly as the provider
  ## compile treats them (`ProviderCompileEnvironmentPassthrough`).
  ##
  ## The cost of the rule: a profile whose INTENT embeds its temp directory
  ## (`getTempDir()` in a resource's content) would be served the intent of
  ## the run that published the record. Nothing that describes a home should
  ## depend on a per-shell scratch path, and the alternative is a recompile
  ## in every shell for every profile.

const ProfileCompileEnvPassthrough* =
  @[ProfileNimCompilerEnvVar] & @ProfileCompileScratchEnvNames
  ## The edge's `envPassthrough`: the compiler override the helper reads
  ## (a value from the ambient environment, so PASSTHROUGH by the
  ## classification rule in `repro_cli_support`) and the scratch-location
  ## variables above.

proc profileCompileBuildAction*(profileRoot, rbpiPath, nimcacheDir,
                                publicCliPath, workDir, repoRoot: string;
                                weak: ContentDigest;
                                verbose = false): BuildAction =
  ## Build the `BuildAction` that drives one profile compile via the internal
  ## `__repro-compile-profile` helper.
  ##
  ## Declared inputs: none. The dependency record is whatever io-mon observes
  ## the helper, `nim`, the C toolchain and the profile binary read
  ## (`automaticMonitorGatheringPolicy`). There is no hand-written depfile:
  ## everything such a file could list, the monitor observes, and a list
  ## somebody maintains is only correct until a profile reads something its
  ## author did not anticipate. Do NOT pass `depfile =` to `action()` here
  ## either: it rewrites a depfile next to an automatic-monitor policy into
  ## the UNMONITORED `dgRecognizedFormat` policy, which is how this edge used
  ## to be unmonitored while every comment said otherwise.
  ##
  ## Declared output: the published RBPI envelope.
  ##
  ## Ignored input prefix: the per-profile nimcache. It is derived state the
  ## compile writes and reads back (Nim's incremental C/object cache and the
  ## profile binary itself); recording it would key the edge on its own
  ## scratch. The real inputs — profile sources, payloads, reprobuild's
  ## libraries, the toolchain — live elsewhere and stay recorded. Mirrors
  ## `providerCompileIgnoredInputPrefixes`.
  var argv = @[
    publicCliPath,
    "__repro-compile-profile",
    "--profile", profileRoot,
    "--rbpi", rbpiPath,
    "--nimcache", nimcacheDir,
    "--repo-root", repoRoot
  ]
  if verbose:
    argv.add("--verbose")
  let cwd =
    if workDir.len > 0: workDir
    else: profileRoot.parentDir
  action(ProfileCompileActionId, argv,
    # Named-Lock-Files §7.2. No solved package instance reaches this edge.
    # See `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = cwd,
    outputs = @[rbpiPath],
    commandStatsId = "repro profile compile edge",
    cacheable = true,
    weakFingerprint = weak,
    envPassthrough = ProfileCompileEnvPassthrough,
    dependencyPolicy = automaticMonitorGatheringPolicy(
      @[absolutePath(nimcacheDir)]))

# ---------------------------------------------------------------------------
# BuildEngineConfig defaults appropriate for a single profile compile.
# ---------------------------------------------------------------------------

## Selector args that turn ``<publicCliPath>`` into the in-process
## ``repro internal io monitor`` driver. ``monitoredAction`` prepends
## ``monitorCliPath & monitorCliArgs`` ahead of ``--depfile <path> --``
## and the real command, so WITHOUT these args the monitored argv
## degenerates to ``repro --depfile <path> -- <cmd>`` — an invalid
## invocation that exits non-zero and makes every profile-compile action
## fail under ``automaticMonitorGatheringPolicy``. Every production build
## config in ``repro_cli_support`` (``internalIoMonitorArgs``) sets the same
## triple; we mirror the literal here because ``repro_profile_compile``
## sits below ``repro_cli_support`` in the dependency graph and cannot
## import it without a cycle.
##
## NOTE: The canonical CLI recognizes the full ``internal io monitor`` triple.
## Omitting the middle ``io`` category falls through to the unknown-subcommand
## path and exits 2 with ``renderInternalUsage``, which surfaces from the build
## engine as
## ``__repro_profile_compile asFailed`` with the internal-namespace
## usage as the diagnostic body.
const ProfileCompileMonitorCliArgs* = @["internal", "io", "monitor"]

proc profileCompileEngineConfig*(stateDir, publicCliPath: string):
    BuildEngineConfig =
  ## A `BuildEngineConfig` tuned for a one-off profile compile. We park
  ## the action-cache under `<state-dir>/profile-cache/build-engine-cache`
  ## so the cache is per-user and lives alongside the published `.rbpi`
  ## artifacts.
  result = BuildEngineConfig(
    cacheRoot: stateDir / ProfileCacheDirName / "build-engine-cache",
    runQuotaCliPath: publicCliPath,
    monitorCliPath: publicCliPath,
    monitorCliArgs: ProfileCompileMonitorCliArgs,
    maxParallelism: 1'u32,
    stdoutLimit: 1024 * 1024,
    stderrLimit: 1024 * 1024,
    rebuildMissingOutputsOnCacheHit: true,
    deferLocalOutputBlobs: true,
    bypassRunQuota: true,
    fallbackToRunQuotaBypass: true,
    inlineRunQuota: false,
    suppressTrace: true,
    skipCacheHitEvidence: true)

# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------

proc compileProfileToRbpi*(profileRoot: string;
                           opts: ProfileCompileOptions):
    ProfileCompileArtifact =
  ## Compile `profileRoot` (a `home.nim` / `system.nim` path) to the RBPI
  ## binary envelope and return both the published path and the bytes.
  ##
  ## Every call schedules the edge through `runBuild`; the engine's action
  ## cache answers a call whose observed inputs are unchanged without
  ## spawning the helper (and therefore without spawning `nim`).
  ##
  ## Required `opts` fields: `stateDir`, `publicCliPath`. An empty `repoRoot`
  ## is resolved through `resolveReprobuildSourceRoot()`, and the call is
  ## refused with `missingReprobuildSourcesMessage()` when nothing resolves.
  if opts.stateDir.len == 0:
    raiseProfileCompile("compileProfileToRbpi: stateDir is required")
  if opts.publicCliPath.len == 0:
    raiseProfileCompile("compileProfileToRbpi: publicCliPath is required")

  let absProfile = absolutePath(profileRoot)
  if not fileExists(extendedPath(absProfile)):
    raiseProfileCompile("compileProfileToRbpi: profile root does not " &
      "exist: " & absProfile)

  # No explicit root: resolve one, and refuse HERE when nothing holds
  # reprobuild's libs, with the list of every place that was looked at. The
  # alternative -- handing the helper a root nobody chose -- surfaced as a
  # nim `cannot open file` (or a `setCurrentDir` failure) deep inside the
  # monitored edge, naming neither the missing tree nor its remedy.
  let repoRoot =
    if opts.repoRoot.len > 0: opts.repoRoot
    else:
      let resolved = resolveReprobuildSourceRoot()
      if resolved.len == 0:
        raiseProfileCompile(missingReprobuildSourcesMessage())
      resolved

  createDir(extendedPath(profileCacheDir(opts.stateDir)))

  # Remove envelopes written in a previous RBPI schema version. This is
  # disk hygiene, not a freshness decision: a schema bump also changes the
  # weak fingerprint, so the action cache would never serve such a file.
  discard pruneStaleProfileCache(opts.stateDir)

  let key = profileCompileKey(absProfile)
  let rbpiPath = cachedRbpiPath(opts.stateDir, key)
  let nimcacheDir = cachedNimcacheDir(opts.stateDir, key)

  # The compiler identity the weak fingerprint names. Resolved here with the
  # helper's own resolver (`$REPRO_NIM_COMPILER`, then `PATH`), in the same
  # environment the helper inherits, so a missing or mis-named compiler is
  # reported before an edge is scheduled at all.
  let nimExe =
    try:
      resolveProfileNimCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)
  # The C compiler, likewise: the helper resolves the same one in the same
  # environment, and a mis-named `$REPRO_BOOTSTRAP_CC` is refused here.
  let cCompiler =
    try:
      resolveProfileCCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)

  # On force-rebuild remove the published envelope. The engine configuration
  # sets `rebuildMissingOutputsOnCacheHit`, so a record whose declared output
  # is missing is re-executed rather than restored — which is what the
  # caller asked for.
  if opts.forceRebuild and fileExists(extendedPath(rbpiPath)):
    removeFile(extendedPath(rbpiPath))

  let weak = profileCompileWeakFingerprint(nimExe, opts.publicCliPath,
    rbpiPath, cCompiler)
  let buildAction = profileCompileBuildAction(absProfile, rbpiPath,
    nimcacheDir, opts.publicCliPath, opts.workDir, repoRoot, weak,
    opts.verbose)
  var config = profileCompileEngineConfig(opts.stateDir, opts.publicCliPath)
  if opts.reportObservedInputs:
    # Reconstruct a hit's evidence from its record. Serving consequences are
    # none: the same record is loaded and revalidated either way.
    config.skipCacheHitEvidence = false
  let runResult = runBuild(graph(@[buildAction]), config)
  if runResult.hasFailedActions():
    raiseProfileCompile(actionFailureDiagnostic(runResult))
  # Self-consistency of what the edge produced, NOT a freshness re-check: the
  # envelope must exist and decode. Nothing here compares the result against
  # the profile's sources — that question was answered by the action cache,
  # and asking it a second time with a weaker key is the gate this module
  # removed.
  if not fileExists(extendedPath(rbpiPath)):
    raiseProfileCompile("profile compile edge did not write artifact: " &
      rbpiPath)
  if not rbpiEnvelopeIsValid(rbpiPath):
    raiseProfileCompile("profile compile edge wrote a structurally " &
      "invalid RBPI envelope: " & rbpiPath)
  let edge = runResult.profileCompileActionResult()
  let bytes = readBytes(rbpiPath)
  result = ProfileCompileArtifact(
    profileRoot: absProfile,
    rbpiPath: rbpiPath,
    rbpiBytes: bytes,
    digestHex: blake3.toHex(blake3.digest(bytes)),
    edgeLaunched: edge.launched,
    cacheDecision: edge.cacheDecision,
    cacheMissReason: edge.cacheMissReason,
    cachePublishSkipReason: edge.cachePublishSkipReason,
    observedInputs: edge.evidence.monitorReads.paths())

# ---------------------------------------------------------------------------
# The platform-probe edge.
#
# A second monitored edge beside the compile, run only by `repro home
# export`: it evaluates the profile for every target platform
# (`platforms.nim`) and publishes the outcomes. It is its own edge, not a
# step of the compile, because only the export needs it -- `repro home
# apply` would otherwise pay six `nim check`s on every cold compile -- and
# like the compile it decides nothing about freshness itself: the action
# cache answers from what io-mon observed the checks read.
# ---------------------------------------------------------------------------

const ProfilePlatformProbeActionId* = "__repro_profile_platform_probe"

type
  ProfilePlatformProbeArtifact* = object
    ## Result of a platform probe: one outcome per `ProfileTargetPlatforms`
    ## entry, plus the engine's decision about the edge (as for
    ## `ProfileCompileArtifact`).
    path*: string
    outcomes*: seq[ProbeOutcome]
    edgeLaunched*: bool
    cacheDecision*: CacheDecision
    cacheMissReason*: string

proc cachedPlatformProbePath*(stateDir, profileKey: string): string =
  profileCacheDir(stateDir) / profileKey & ".platforms.json"

proc cachedPlatformProbeScratch*(stateDir, profileKey: string): string =
  ## The probe's per-platform `--nimcache` directories: derived state,
  ## excluded from the edge's recorded inputs like the compile's nimcache.
  profileCacheDir(stateDir) / "platform-probe" / profileKey

proc profilePlatformProbeWeakFingerprint*(nimExe, publicCliPath,
                                          outPath: string): ContentDigest =
  ## Declared identity only, as for `profileCompileWeakFingerprint`: which
  ## compiler and helper, where the output lands, which document version
  ## and which platforms. Everything the profile reads is observed.
  weakFingerprintFromText(
    "repro.profile.platform-probe.v1\n" &
    "compiler=" & nimExe & "\n" &
    "helper=" & publicCliPath & "\n" &
    "output=" & outPath & "\n" &
    "probe-version=" & $ProfilePlatformProbeVersion & "\n" &
    "platforms=" & targetSystemNames().join(",") & "\n")

proc probeProfilePlatforms*(profileRoot: string;
                            opts: ProfileCompileOptions):
    ProfilePlatformProbeArtifact =
  ## Run (or answer from the action cache) the platform-probe edge for
  ## `profileRoot`. Uses the compile's `stateDir`, `publicCliPath`,
  ## `repoRoot` and `workDir`; `forceRebuild` removes the published
  ## document first. Raises `ProfileCompileError` when the edge fails.
  if opts.stateDir.len == 0:
    raiseProfileCompile("probeProfilePlatforms: stateDir is required")
  if opts.publicCliPath.len == 0:
    raiseProfileCompile("probeProfilePlatforms: publicCliPath is required")
  let absProfile = absolutePath(profileRoot)
  if not fileExists(extendedPath(absProfile)):
    raiseProfileCompile("probeProfilePlatforms: profile root does not " &
      "exist: " & absProfile)
  let repoRoot =
    if opts.repoRoot.len > 0: opts.repoRoot
    else: reprobuildRepoRoot()
  createDir(extendedPath(profileCacheDir(opts.stateDir)))
  let key = profileCompileKey(absProfile)
  let outPath = cachedPlatformProbePath(opts.stateDir, key)
  let scratch = cachedPlatformProbeScratch(opts.stateDir, key)
  let nimExe =
    try:
      resolveProfileNimCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)
  if opts.forceRebuild and fileExists(extendedPath(outPath)):
    removeFile(extendedPath(outPath))
  let weak = profilePlatformProbeWeakFingerprint(nimExe, opts.publicCliPath,
    outPath)
  let argv = @[
    opts.publicCliPath,
    "__repro-probe-profile-platforms",
    "--profile", absProfile,
    "--out", outPath,
    "--nimcache", scratch,
    "--repo-root", repoRoot
  ]
  let cwd =
    if opts.workDir.len > 0: opts.workDir
    else: absProfile.parentDir
  let buildAction = action(ProfilePlatformProbeActionId, argv,
    # Named-Lock-Files §7.2: no solved package instance reaches this edge.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = cwd,
    outputs = @[outPath],
    commandStatsId = "repro profile platform probe edge",
    cacheable = true,
    weakFingerprint = weak,
    envPassthrough = ProfileCompileEnvPassthrough,
    dependencyPolicy = automaticMonitorGatheringPolicy(
      @[absolutePath(scratch)]))
  let config = profileCompileEngineConfig(opts.stateDir, opts.publicCliPath)
  let runResult = runBuild(graph(@[buildAction]), config)
  if runResult.hasFailedActions():
    raiseProfileCompile(actionFailureDiagnostic(runResult))
  if not fileExists(extendedPath(outPath)):
    raiseProfileCompile("platform probe edge did not write its output: " &
      outPath)
  var edge = ActionResult(id: ProfilePlatformProbeActionId)
  for item in runResult.results:
    if item.id == ProfilePlatformProbeActionId:
      edge = item
  let outcomes =
    try:
      decodeProbeOutcomes(readFile(extendedPath(outPath)))
    except CatchableError as err:
      raiseProfileCompile("platform probe edge wrote an unreadable " &
        "document " & outPath & ": " & err.msg)
  ProfilePlatformProbeArtifact(path: outPath, outcomes: outcomes,
    edgeLaunched: edge.launched, cacheDecision: edge.cacheDecision,
    cacheMissReason: edge.cacheMissReason)
