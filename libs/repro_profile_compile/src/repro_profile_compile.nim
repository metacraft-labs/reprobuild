## Reprobuild profile-compile build-graph edge (M83 Phase C).
##
## Profile compilation is a normal build-graph edge: source discovery,
## fingerprint, action-cache lookup, then a `BuildAction` of kind
## `bakProcess` submitted to `runBuild`. The CLI exposes NO user-facing
## `repro profile build` command; apply (Phase D) calls
## `compileProfileToRbpi` automatically when it needs a fresh
## `ProfileIntent`.
##
## Submodules:
##
##   - `repro_profile_compile/sources` — source discovery, sibling-import
##     walk, BLAKE3 digest, cache-layout helpers.
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
import ./repro_profile_compile/adapter_home
import ./repro_profile_compile/adapter_system
import ./repro_profile_compile/infra_apply_broker
import ./repro_profile_compile/apply_build_actions

# Source-discovery + digest + paths.
export sources.CompiledRepoRoot
export sources.RepoRootEnvVar
export sources.ProfileNimPathLibs
export sources.HomeProfileAnchor
export sources.SystemProfileAnchor
export sources.ProfileCacheDirName
export sources.ProfileDigest
export sources.reprobuildRepoRoot
export sources.profileNimPaths
export sources.resolveProfileRoot
export sources.parseSiblingImports
export sources.discoverProfileSources
export sources.computeProfileDigest
export sources.profileCacheDir
export sources.cachedRbpiPath
export sources.cachedSourcesPath
export sources.cachedNimcacheDir
export sources.pruneStaleProfileCache

# Direct nim invocation + JSON->RBPI bridge.
export compile.CompileFailure
export compile.requireNimOnPath
export compile.compileProfileBinary
export compile.rbpiBytesFromJson
export compile.writeBytesAtomic
export compile.readBytes
export compile.cachedArtifactIsValid

# Build-graph edge + public entry point.
export edge.ProfileCompileArtifact
export edge.ProfileCompileOptions
export edge.ProfileCompileError
export edge.profileCompileBuildAction
export edge.profileCompileEngineConfig
export edge.compileProfileToRbpi

# Internal helper subcommand body.
export helper.runProfileCompileHelper

# Phase D adapters: ProfileIntent -> apply-pipeline IRs.
export adapter_home.profileIntentToHomeProfile
export adapter_system.profileIntentToSystemProfile
export adapter_system.renderSystemProfileToText

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
