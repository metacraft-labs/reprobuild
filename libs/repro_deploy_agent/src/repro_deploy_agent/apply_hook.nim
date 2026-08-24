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

import std/[os, strutils]

import repro_elevation
import repro_infra
import repro_profile_compile
# For `ProfileBuildAction`, which the resolver signature below names
# explicitly. It was previously reachable only implicitly, through the typed
# `ApplyOptions.buildActions` field.
import repro_profile

import ./manifest
import ./agent

type
  ProfileResolver* = proc(profileText: string; outText: var string;
                          outBuildActions: var seq[ProfileBuildAction]):
                       bool {.gcsafe.}
    ## Turn a manifest's ``profileText`` into the canonical resource text
    ## ``runInfraApply`` consumes, returning ``false`` (with a diagnostic
    ## already emitted) when the profile does not compile.
    ##
    ## Injected rather than imported: the Phase-F3 implementation
    ## (``resolveSystemProfileText``) lives in ``repro_cli_support``, and
    ## ``repro_cli_support`` already depends on THIS library, so importing it
    ## here would close a cycle. The CLI wires it in
    ## ``repro_cli_support/deploy_agent.nim``, which is in the same library as
    ## the implementation.

proc mkRunInfraApplyHook*(stateDir: string;
                          cacheRoot: string;
                          hostIdentity = "reprobuild-deploy-agent";
                          reproExe = "";
                          profileResolver: ProfileResolver = nil): ApplyHook =
  ## Build the production apply hook. Each converged manifest is applied
  ## via ``runInfraApply`` with the M4 ``mkBuildActionDispatcher`` closure
  ## injected — the SAME closure ``repro infra apply`` uses.
  ##
  ## ``cacheRoot`` is the apply-scoped engine/action cache root (the M4
  ## substitute scratch lives under ``cacheRoot/binary-cache-substitute``).
  ## ``stateDir`` is the durable infra state directory.
  ##
  ## ON ``profileResolver`` — WHY THE HOOK CANNOT JUST PASS ``m.profileText``
  ## STRAIGHT TO ``runInfraApply``.
  ##
  ## ``repro infra apply`` does NOT do that. It calls
  ## ``resolveSystemProfileText`` first — the M83 Phase-F3 compile-then-adapt
  ## step that turns a ``system.nim`` into canonical resource text — and only
  ## then calls ``runInfraApply``. This hook used to skip that step, so the
  ## canonical-text parser met ``import repro_profile`` on line 1 of any real
  ## profile and raised ``unknown system resource kind 'import repro_profile'``.
  ##
  ## Measured on win-ci-bare-001, 2026-08-18: the SAME binary applied the SAME
  ## profile successfully via ``repro infra apply --profile`` and could not
  ## parse it via ``deploy-agent``. Two paths that must agree did not.
  ##
  ## The resolver is optional so the hermetic gates — which inject canonical
  ## text directly and must not drag in a compiler — keep working unchanged;
  ## production passes one. A nil resolver preserves the old behaviour exactly.
  let capturedStateDir = stateDir
  let capturedCacheRoot = cacheRoot
  let capturedHost = hostIdentity
  let capturedReproExe = if reproExe.len > 0: reproExe else: getAppFilename()
  let capturedResolver = profileResolver
  result = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      try:
        let ctx = FixtureContext(filePrefix: capturedStateDir)

        # Compile the manifest's profile the way the CLI does, when a resolver
        # was injected. `resolvedActions` is only consulted below.
        #
        # A BLANK `profileText` is NOT a profile, and must not reach the
        # compiler. It is the ordinary shape of a manifest that carries only
        # build actions (or nothing at all) — every hermetic gate in this
        # library uses it, and so does the renderer whose `--profile` is
        # optional. Handing it to the resolver stages an empty `.nim`, which
        # compiles and links perfectly happily, runs, and prints nothing;
        # the profile compiler then meets an empty string where it expects a
        # JSON object and fails the whole tick with
        #
        #   failed to encode RBPI envelope from compiled profile output:
        #   input(1, 0) Error: { expected
        #
        # — a message that names neither the manifest nor the emptiness, and
        # so reads like a compiler or toolchain fault. Observed as a hard
        # convergence failure in the nixos-modules HTTPS deploy-agent gate
        # from 2026-08-18 (when this hook began resolving unconditionally)
        # onward; before that the empty text flowed through as canonical
        # resource text and correctly described zero resources.
        #
        # Zero resources is exactly what it still means, so say so directly
        # instead of asking a compiler to rediscover it.
        var applyText = m.profileText
        var resolvedActions: seq[ProfileBuildAction] = @[]
        if capturedResolver != nil and m.profileText.strip().len > 0:
          if not capturedResolver(m.profileText, applyText, resolvedActions):
            return (ok: false,
              message: "profile did not compile; see the diagnostic above")

        # WHICH buildActions win, decided on purpose rather than by accident.
        #
        # A compiled profile carries its own action edges, and the manifest has
        # a `buildActions` field of its own for producers that pre-compiled.
        # Taking the manifest's unconditionally would mean that a producer which
        # ships none — which is every producer today, since the renderer's
        # `--build-actions` is optional and unset — silently reduces the apply
        # to LIVE-STATE ONLY: no downloads, no extracts, no registration. That
        # failure reports success, which is the worst shape a failure can take.
        #
        # So: an explicit producer-supplied set wins (it is a deliberate act),
        # and otherwise the compiled profile speaks for its own edges.
        let effectiveActions =
          if m.buildActions.len > 0: m.buildActions else: resolvedActions

        # `emBroker`, NOT `emNoElevate`, and the difference is the whole value
        # of the agent on Windows.
        #
        # `emNoElevate` does not mean "do not prompt" — apply.nim implements it
        # as `reportPrivilegedSetSkipped`, i.e. SKIP every privileged operation,
        # with its own comment noting the non-privileged remainder is "none, for
        # a pure-Windows profile". So a hardcoded `emNoElevate` made the agent
        # structurally incapable of applying live state: services, ACLs,
        # timezone, registry values and scheduled tasks were all skipped.
        #
        # And it did so SILENTLY. Skipped operations are not errors, so
        # `res.errorCount` stayed 0 and the tick returned `aoApplied` with a
        # healthy-looking "applied N" — where N counted only build actions.
        # Measured on win-ci-bare-001, 2026-08-19: a tick reported
        # `aoApplied ... applied 8` while the apply log recorded
        # `windows.scheduledTask deployAgentTimer skipped` and the task did not
        # exist afterwards. A pull-model box was reporting convergence it had
        # not performed.
        #
        # `emBroker` is the CLI's default and degrades correctly rather than
        # prompting an unattended box: apply.nim takes the already-elevated
        # fast path in-process when `isProcessElevated()`, which is the normal
        # case here since the converge loop runs as SYSTEM from Task Scheduler;
        # and if a broker is genuinely needed but elevation is declined,
        # `EElevationDeclined` is handled as a clean partial result rather than
        # a crash.
        var opts = ApplyOptions(
          stateDir: capturedStateDir,
          hostIdentity: capturedHost,
          reproExe: capturedReproExe,
          elevationMode: emBroker,
          noPreview: true,
          buildActions: effectiveActions,
          buildActionDispatcher:
            mkBuildActionDispatcher(capturedCacheRoot, ctx))
        let res = runInfraApply(applyText, opts)
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
