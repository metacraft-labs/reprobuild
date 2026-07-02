## Windows-Runner-Binary-Cache-Deploy M5 — production apply hook.
##
## Wires the deploy agent's injected ``ApplyHook`` to the M4
## ``runInfraApply`` path so a converged manifest applies its desired
## state with build-action outputs SUBSTITUTED FROM THE BINARY CACHE
## (when ``REPRO_BINARY_CACHE_URL`` is set) instead of built locally.
##
## Kept in its own module (separate from ``agent.nim``) so the poll/verify/
## monotonic core stays free of the heavyweight ``repro_infra`` +
## ``repro_profile_compile`` apply dependency tree — the hermetic gates
## import only ``agent`` + a lightweight recording hook, while the
## production path imports THIS.

import std/os

import repro_elevation
import repro_infra
import repro_profile_compile

import ./manifest
import ./agent

proc mkRunInfraApplyHook*(stateDir: string;
                          cacheRoot: string;
                          hostIdentity = "reprobuild-deploy-agent";
                          reproExe = ""): ApplyHook =
  ## Build the production apply hook. Each converged manifest is applied
  ## via ``runInfraApply`` with the M4 ``mkBuildActionDispatcher`` closure
  ## injected — the SAME closure ``repro infra apply`` uses. The manifest's
  ## ``profileText`` is the desired ``system.nim`` text and its
  ## ``buildActions`` are the action-edge intent items the dispatcher
  ## substitutes from / publishes to the binary cache.
  ##
  ## ``cacheRoot`` is the apply-scoped engine/action cache root (the M4
  ## substitute scratch lives under ``cacheRoot/binary-cache-substitute``).
  ## ``stateDir`` is the durable infra state directory.
  let capturedStateDir = stateDir
  let capturedCacheRoot = cacheRoot
  let capturedHost = hostIdentity
  let capturedReproExe = if reproExe.len > 0: reproExe else: getAppFilename()
  result = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      try:
        let ctx = FixtureContext(filePrefix: capturedStateDir)
        var opts = ApplyOptions(
          stateDir: capturedStateDir,
          hostIdentity: capturedHost,
          reproExe: capturedReproExe,
          elevationMode: emNoElevate,
          noPreview: true,
          buildActions: m.buildActions,
          buildActionDispatcher:
            mkBuildActionDispatcher(capturedCacheRoot, ctx))
        let res = runInfraApply(m.profileText, opts)
        if res.errorCount > 0 or res.driftCount > 0:
          return (ok: false,
            message: "apply reported " & $res.errorCount & " errors, " &
              $res.driftCount & " drift (generation " & res.generationId & ")")
        return (ok: true,
          message: "generation " & res.generationId & ", applied " &
            $res.appliedCount & ", substituted-from-cache " &
            $res.substitutedFromCacheCount)
      except CatchableError as e:
        return (ok: false, message: "runInfraApply raised: " & e.msg)
