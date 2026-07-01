## M83 Phase C profile-compile build-graph edge.
##
## The public entry point `compileProfileToRbpi` mirrors the shape of
## `compileProviderBinary` from `libs/repro_interface_artifacts/`:
##
##   1. Discover sources + compute the profile fingerprint.
##   2. Look up the cached `.rbpi` envelope; fast-path return on a
##      structural cache hit.
##   3. On miss: build a `BuildAction` of kind `bakProcess` whose argv
##      invokes the public CLI's internal `__repro-compile-profile`
##      helper. The action is submitted to `runBuild(graph([action]),
##      config)` so the existing action-cache + CAS pipeline kicks in
##      automatically.
##   4. Read the resulting `.rbpi` bytes back and return a
##      `ProfileCompileArtifact` to the caller.
##
## Profile compilation is therefore a normal build-graph edge: the
## scheduler, action cache, output CAS, and dependency-policy machinery
## all apply unchanged. There is no user-facing `repro profile build`
## command — apply (Phase D) calls this proc automatically.

import std/[os, strutils]
from repro_core/paths import extendedPath

import repro_core
import repro_hash
import repro_build_engine

import ./sources
import ./compile

# ---------------------------------------------------------------------------
# Public types.
# ---------------------------------------------------------------------------

type
  ProfileCompileArtifact* = object
    ## Result of a successful profile compile. The bytes are the RBPI
    ## envelope ready to feed into the apply pipeline; the path is where
    ## the action-cache CAS published them.
    profileRoot*: string
    inputSources*: seq[string]
    rbpiPath*: string
    rbpiBytes*: seq[byte]
    digestHex*: string

  ProfileCompileOptions* = object
    ## Caller-tunable knobs. `stateDir` is the per-user state directory
    ## that hosts the `<state-dir>/profile-cache/` tree. `publicCliPath`
    ## is the absolute path to the `repro` binary that hosts the
    ## `__repro-compile-profile` internal helper subcommand.
    ## `repoRoot` is forwarded to the helper as `$REPROBUILD_REPO_ROOT`.
    ## `workDir` is the cwd to run the helper in (defaults to the
    ## profile's parent directory). `verbose` and `forceRebuild` are
    ## debug knobs.
    stateDir*: string
    publicCliPath*: string
    repoRoot*: string
    workDir*: string
    verbose*: bool
    forceRebuild*: bool

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

# ---------------------------------------------------------------------------
# BuildAction construction (mirror of providerCompileBuildAction).
# ---------------------------------------------------------------------------

proc profileCompileBuildAction*(profileRoot, rbpiPath, manifestPath,
                                nimcacheDir, publicCliPath, workDir,
                                repoRoot: string;
                                inputSources: openArray[string];
                                weak: ContentDigest;
                                verbose = false): BuildAction =
  ## Build the `BuildAction` that drives one cache-miss profile compile
  ## via the internal `__repro-compile-profile` helper.
  ##
  ## Inputs: the discovered source set. Outputs: the published RBPI
  ## envelope + the source-manifest sidecar.
  var inputs: seq[string] = @[]
  for path in inputSources:
    inputs.add path
  var argv = @[
    publicCliPath,
    "__repro-compile-profile",
    "--profile", profileRoot,
    "--rbpi", rbpiPath,
    "--manifest", manifestPath,
    "--nimcache", nimcacheDir,
    "--repo-root", repoRoot
  ]
  if verbose:
    argv.add("--verbose")
  let cwd =
    if workDir.len > 0: workDir
    else: profileRoot.parentDir
  action("__repro_profile_compile", argv,
    cwd = cwd,
    inputs = inputs,
    outputs = @[rbpiPath, manifestPath],
    commandStatsId = "repro profile compile edge",
    cacheable = true,
    weakFingerprint = weak,
    dependencyPolicy = automaticMonitorGatheringPolicy())

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
  ## Compile `profileRoot` (a `home.nim` / `system.nim` path) to the
  ## RBPI binary envelope and return both the published path and the
  ## bytes. The first call for a given source-set is a cache miss and
  ## drives a `BuildAction` through `runBuild`; subsequent calls
  ## fast-path on the structural envelope check.
  ##
  ## Required `opts` fields: `stateDir`, `publicCliPath`. `repoRoot`
  ## defaults to `reprobuildRepoRoot()` when empty.
  if opts.stateDir.len == 0:
    raiseProfileCompile("compileProfileToRbpi: stateDir is required")
  if opts.publicCliPath.len == 0:
    raiseProfileCompile("compileProfileToRbpi: publicCliPath is required")

  let absProfile = absolutePath(profileRoot)
  if not fileExists(extendedPath(absProfile)):
    raiseProfileCompile("compileProfileToRbpi: profile root does not " &
      "exist: " & absProfile)

  let repoRoot =
    if opts.repoRoot.len > 0: opts.repoRoot
    else: reprobuildRepoRoot()

  createDir(extendedPath(profileCacheDir(opts.stateDir)))

  # Sweep stale-schema-version cache entries from any previous
  # reprobuild build. The sweep is bounded by the per-profile cache
  # footprint (typically 1-3 files); on a clean dir it's a no-op.
  # Without this, a reprobuild upgrade that bumps RbpiSchemaVersion
  # would leave the previous version's `.rbpi` files lying around;
  # they'd be cache-missed (because the digest now includes the
  # schema version, and the strict reader rejects the old version),
  # but they'd accumulate on disk over many upgrades.
  discard pruneStaleProfileCache(opts.stateDir)

  let inputSources = discoverProfileSources(absProfile)
  let anchorDir = absProfile.parentDir
  let digest = computeProfileDigest(inputSources, anchorDir)
  let rbpiPath = cachedRbpiPath(opts.stateDir, digest.digestHex)
  let manifestPath = cachedSourcesPath(opts.stateDir, digest.digestHex)
  let nimcacheDir = cachedNimcacheDir(opts.stateDir, digest.digestHex)

  # Structural cache hit: return without invoking the build engine.
  if not opts.forceRebuild and cachedArtifactIsValid(rbpiPath):
    return ProfileCompileArtifact(
      profileRoot: absProfile,
      inputSources: inputSources,
      rbpiPath: rbpiPath,
      rbpiBytes: readBytes(rbpiPath),
      digestHex: digest.digestHex)

  # On force-rebuild remove the previous artifact + manifest so the
  # downstream helper sees a clean slate. (The action cache will
  # short-circuit anyway on an unchanged source set; the user asked
  # for forced execution, honour it.)
  if opts.forceRebuild:
    if fileExists(extendedPath(rbpiPath)):
      removeFile(extendedPath(rbpiPath))
    if fileExists(extendedPath(manifestPath)):
      removeFile(extendedPath(manifestPath))

  # Submit through the build engine. The weak fingerprint binds the
  # action-cache record to the source-set digest; the action's
  # declared inputs cover live-file invalidation. Nim-version drift
  # is covered indirectly via the published `.rbpi` bytes (a different
  # Nim might emit different macro expansions; the action cache then
  # repopulates because the output payload differs).
  let weak = weakFingerprintFromText(
    "repro.profile.compile.v1\n" & digest.digestHex)

  let buildAction = profileCompileBuildAction(absProfile, rbpiPath,
    manifestPath, nimcacheDir, opts.publicCliPath, opts.workDir, repoRoot,
    inputSources, weak, opts.verbose)
  var config = profileCompileEngineConfig(opts.stateDir, opts.publicCliPath)
  let runResult = runBuild(graph(@[buildAction]), config)
  if runResult.hasFailedActions():
    raiseProfileCompile(actionFailureDiagnostic(runResult))
  if not fileExists(extendedPath(rbpiPath)):
    raiseProfileCompile("profile compile edge did not write artifact: " &
      rbpiPath)
  if not cachedArtifactIsValid(rbpiPath):
    raiseProfileCompile("profile compile edge wrote a structurally " &
      "invalid RBPI envelope: " & rbpiPath)
  result = ProfileCompileArtifact(
    profileRoot: absProfile,
    inputSources: inputSources,
    rbpiPath: rbpiPath,
    rbpiBytes: readBytes(rbpiPath),
    digestHex: digest.digestHex)
