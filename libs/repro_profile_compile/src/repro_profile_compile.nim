## Reprobuild profile-compile build-graph edge (M83 Phase C).
##
## Profile compilation is a normal build-graph edge: a monitored
## `BuildAction` of kind `bakProcess` submitted to `runBuild`, whose re-runs
## the action cache decides from what io-mon observed it read. The CLI exposes NO user-facing
## `repro profile build` command; apply (Phase D) calls
## `compileProfileToRbpi` automatically when it needs a fresh
## `ProfileIntent`.
##
## Submodules:
##
##   - `repro_profile_compile/sources` — repo-root / Nim-path discovery,
##     profile-root resolution, cache-layout helpers.
##   - `repro_profile_compile/compile` — direct `nim c` invocation and
##     the JSON->RBPI bridge. Used by the internal helper subcommand and
##     by tests.
##   - `repro_profile_compile/edge` — `BuildAction` construction +
##     `compileProfileToRbpi` public entry point.
##   - `repro_profile_compile/helper` — body of the
##     `__repro-compile-profile` internal helper subcommand. Imported by
##     `libs/repro_cli_support/` so the dispatcher can route to it.

import ./repro_profile_compile/sources
import ./repro_profile_compile/compile
import ./repro_profile_compile/edge
import ./repro_profile_compile/helper
import ./repro_profile_compile/platforms
import ./repro_profile_compile/adapter_home
import ./repro_profile_compile/adapter_system
import ./repro_profile_compile/resource_scope
import ./repro_profile_compile/data_expansion
import ./repro_profile_compile/infra_apply_broker
import ./repro_profile_compile/apply_build_actions

# Repo-root / Nim-path discovery + cache layout.
export sources.CompiledRepoRoot
export sources.RepoRootEnvVar
export sources.LibsDirName
export sources.HomeProfileAnchor
export sources.SystemProfileAnchor
export sources.ProfileCacheDirName
export sources.reprobuildRepoRoot
export sources.missingReprobuildSourcesMessage
export sources.profileNimPaths
export sources.resolveProfileRoot
export sources.profileCacheDir
export sources.cachedRbpiPath
export sources.cachedNimcacheDir
export sources.pruneStaleProfileCache

# Direct nim invocation + JSON->RBPI bridge.
export compile.CompileFailure
export compile.ProfileNimCompilerEnvVar
export compile.resolveProfileNimCompiler
export compile.resolveProfileCCompiler
export compile.NimDefaultCCompilerExe
export compile.profileCompileCFlags
export compile.ProfileDepfileTarget
export compile.requireReprobuildSources
export compile.profileCompileChildEnv
export compile.profileCompileArgv
export compile.ProfileCompileDefines
export compile.compileProfileBinary
export compile.rbpiBytesFromJson
export compile.writeBytesAtomic
export compile.readBytes
export compile.rbpiEnvelopeIsValid
export compile.StagedProfilePackageName
export compile.StagedProfilePackageFile
export compile.stageProfileFiles
export compile.unstageProfileFiles
export compile.startProfileNim
export compile.finishProfileNim
# Target platforms and the platform probe (GM3).
export platforms.ProfileTargetPlatform
export platforms.ProfileTargetPlatforms
export platforms.ProfilePlatformProbeVersion
export platforms.findTargetPlatform
export platforms.targetSystemNames
export platforms.compilingPlatformSystem
export platforms.targetHostContext
export platforms.ProfileNimConfig
export platforms.resolveProfileNimConfig
export platforms.profileProbeArgv
export platforms.ProbeOutcome
export platforms.runProfilePlatformProbes
export platforms.encodeProbeOutcomes
export platforms.decodeProbeOutcomes

# Build-graph edge + public entry point.
export edge.ProfileCompileArtifact
export edge.ProfileCompileOptions
export edge.ProfileCompileError
export edge.ProfileCompileActionId
export edge.profileCompileKey
export edge.profileCompileWeakFingerprint
export edge.profileCompileBuildAction
export edge.ProfileCompileScratchEnvNames
export edge.ProfileCompileEnvPassthrough
export edge.profileCompileEngineConfig
export edge.compileProfileToRbpi
export edge.ProfilePlatformProbeActionId
export edge.ProfilePlatformProbeArtifact
export edge.cachedPlatformProbePath
export edge.cachedPlatformProbeScratch
export edge.profilePlatformProbeWeakFingerprint
export edge.probeProfilePlatforms

# Internal helper subcommand body.
export helper.runProfileCompileHelper
export helper.runProfilePlatformProbeHelper

# Phase D adapters: ProfileIntent -> apply-pipeline IRs.
export adapter_home.profileIntentToHomeProfile
export adapter_system.profileIntentToSystemProfile
export adapter_system.renderSystemProfileToText

# One resource-scope classification for both adapters.
export resource_scope.ResourceScope
export resource_scope.resourceScope

# GM4: plan-time expansion of the profile's data files.
export data_expansion.ExpandedHomeIntent
export data_expansion.dataRowElement
export data_expansion.mergeDataRows
export data_expansion.expandProfileData
export data_expansion.toLoadedDataFiles
export data_expansion.expandedHomeProfile

# Phase E CLI seam: build the engine's ``brokerSpawn`` closure that
# wires ``BuildEngineConfig.brokerSpawn`` to
# ``repro_elevation.dispatchOperation`` for ``repro infra apply``.
export infra_apply_broker.InfraApplyBrokerFailureExitCode
export infra_apply_broker.elevatedExecRequestToPrivilegedOperation
export infra_apply_broker.dispatchResultToElevatedExecResult
export infra_apply_broker.mkInfraApplyBrokerSpawn

# Windows-System-Resources Phase G integration seam: dispatcher
# closure that ``runInfraApply`` injects to drive the action-edge
# half of the apply through ``runBuild`` with the elevation broker
# hook attached.
export apply_build_actions.ApplyBuildActionsCacheDirName
export apply_build_actions.profileBuildActionToBuildAction
export apply_build_actions.buildActionsToBuildGraph
export apply_build_actions.applyBuildActionsEngineConfig
export apply_build_actions.mkBuildActionDispatcher
export apply_build_actions.buildActionFingerprintHex
