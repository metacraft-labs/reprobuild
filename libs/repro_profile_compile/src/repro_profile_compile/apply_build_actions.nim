## Windows-System-Resources Phase G — build-action dispatcher that
## ``repro infra apply`` injects into ``ApplyOptions`` to drive the
## action-edge half of the apply through ``repro_build_engine.runBuild``.
##
## Architecture (spec § "Part 2: runInfraApply -> runBuild routing"):
##
##   1. The profile macro emits action-edge intent items (typed-tool
##      ``.build(...)`` and bare ``inlineExecCall(...)`` calls inside
##      a ``resources:`` block) as ``ProfileBuildAction`` records on
##      ``ProfileIntent.buildActions``.
##   2. ``runInfraApply`` calls the injected dispatcher closure BEFORE
##      the live-state dispatch. The dispatcher assembles a
##      ``BuildGraph``, attaches the elevation broker hook
##      (``mkInfraApplyBrokerSpawn(ctx)``), and runs ``runBuild``.
##   3. Per-edge ``ActionResult`` values are projected onto
##      ``BuildActionApplyOutcome``s the apply driver folds into the
##      ``ApplyResult`` tallies (applied / no-op / error).
##
## Failure handling:
##   * A failed ``runBuild`` call (any thrown exception, including
##     ``BuildEngineError``) is caught and projected onto a per-edge
##     failure outcome for EACH action in the input — the apply driver
##     surfaces the failure through ``ApplyResult.diagnostics`` so the
##     audit log captures which edges did not run. The closure does
##     NOT re-raise: the live-state half should still get a chance to
##     observe drift (the failure-mode posture matches the spec's
##     "the audit log should capture which action edge failed").
##   * A successful ``runBuild`` whose individual edges include
##     ``asFailed`` produces per-edge failure outcomes with the
##     engine-side stderr embedded; non-failed edges land as either
##     applied (asSucceeded) or no-op (asCacheHit / asUpToDate).
##
## Wiring at the CLI:
##
##   let dispatcher = mkBuildActionDispatcher(
##     cacheRoot = stateDir / "build-cache",
##     ctx = FixtureContext(filePrefix: stateDir))
##   opts.buildActionDispatcher = dispatcher
##   opts.buildActions = compiledProfile.buildActions
##   runInfraApply(profileText, opts)

import std/strutils

import repro_build_engine
import repro_core
import repro_elevation
import repro_hash
import repro_infra
import repro_local_store
import repro_profile

import ./infra_apply_broker

# ---------------------------------------------------------------------------
# ProfileBuildAction -> BuildAction conversion.
# ---------------------------------------------------------------------------

proc weakFingerprintForProfileBuildAction(action: ProfileBuildAction):
    ContentDigest =
  ## Weak fingerprint for a profile-scope action edge. Mixes the
  ## action id + argv + outputs + the elevation flag so a sibling
  ## edge that differs in any input rebuilds. Mirrors the home-style
  ## fingerprint shape used by ``profileCompileBuildAction``.
  ##
  ## We deliberately do NOT include the inputs in the fingerprint
  ## (the engine's input-fingerprint policy reads input mtimes /
  ## digests directly), only the argv and outputs the engine cannot
  ## reach through file metadata alone.
  var parts = @[
    "reprobuild.profileBuildAction.v1",
    action.id,
    action.cwd,
    (if action.requiresElevation: "elevated" else: "direct"),
    action.commandStatsId]
  for a in action.argv:
    parts.add("argv:" & a)
  for o in action.outputs:
    parts.add("out:" & o)
  for t in action.toolIdentityRefs:
    parts.add("tool:" & t)
  weakFingerprintFromText(parts.join("\n"))

proc profileBuildActionToBuildAction*(pba: ProfileBuildAction):
    BuildAction =
  ## Lower one ``ProfileBuildAction`` to the engine-side ``BuildAction``
  ## that ``runBuild`` consumes. Always emits a ``bakProcess`` action
  ## with the argv the profile macro decoded from the inline-exec call.
  ##
  ## Cache policy: ``ffpChecksum`` (digest-based) so a profile that
  ## extracts the same archive bytes twice (different mtimes, same
  ## content) gets a cache hit on the second apply. The engine's
  ## "skip if outputs exist and inputs haven't changed" path is the
  ## load-bearing idempotency anchor for the action-edge half of the
  ## apply — without it, every re-apply would re-extract every zip.
  ##
  ## (Parameter is named ``pba`` rather than ``action`` so the shadowed
  ## ``repro_build_engine.action`` proc remains callable inside the
  ## body.)
  if pba.argv.len == 0:
    raise newException(ValueError,
      "profileBuildActionToBuildAction: action id '" & pba.id &
      "' has empty argv (the profile-macro extractor would have " &
      "raised earlier; this means the codec drift-corrupted the " &
      "intent)")
  # Profile-scope action edges declare their inputs + outputs explicitly.
  # The action uses the spec-baseline automatic-monitor policy — the removed
  # ``dgNoRuntimeDependencies`` declared-only mode MUST NOT be re-added
  # (Reprobuild-Development M17, Monitor-Hook-Shim.md:501). The apply driver's
  # engine config (``applyBuildActionsEngineConfig``) wires NO ``monitorCliPath``,
  # so ``monitorEvidenceRequired`` is false for these edges: the engine emits its
  # "requires repro-fs-snoop" diagnostic and falls back to the statically
  # declared inputs/outputs rather than claiming complete monitor evidence. That
  # preserves the declared-input idempotency this apply path needs WITHOUT the
  # unsound "mark complete/cacheable on declared inputs while silently dropping
  # runtime read-set discovery" hole the old declared-only kind opened.
  result = action(
    id = pba.id,
    argv = pba.argv,
    cwd = pba.cwd,
    deps = pba.deps,
    inputs = pba.inputs,
    outputs = pba.outputs,
    commandStatsId =
      (if pba.commandStatsId.len > 0: pba.commandStatsId
       else: pba.id),
    cacheable = pba.cacheable,
    weakFingerprint = weakFingerprintForProfileBuildAction(pba),
    actionCachePolicy = ffpChecksum,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    requiresElevation = pba.requiresElevation)

proc buildActionsToBuildGraph*(actions: seq[ProfileBuildAction]): BuildGraph =
  ## Assemble a ``BuildGraph`` from the profile's ``buildActions``
  ## seq. The graph carries the actions in declaration order; the
  ## engine's own dependency-graph builder threads them through the
  ## ``deps`` field on each action.
  var ba: seq[BuildAction] = @[]
  for a in actions:
    ba.add profileBuildActionToBuildAction(a)
  graph(ba)

# ---------------------------------------------------------------------------
# Engine config for the action-edge half of an apply.
# ---------------------------------------------------------------------------

const ApplyBuildActionsCacheDirName* = "infra-apply-build-cache"
  ## Sub-directory under the system state dir where the engine's
  ## action-cache + CAS live for the action-edge half of the apply.
  ## Distinct from ``ProfileCacheDirName`` (profile-compile cache) and
  ## from the home-scope build cache so a cache-clean for one half
  ## doesn't perturb the other.

proc applyBuildActionsEngineConfig*(cacheRoot: string;
                                    spawner: ElevatedExecSpawner):
    BuildEngineConfig =
  ## Engine config tuned for a one-shot action-edge dispatch.
  ## Sequential (``maxParallelism = 1``) so the action ordering matches
  ## the profile's declared order on Phase G's first cut; the engine's
  ## own dependency-graph topo-sort still applies, but two independent
  ## actions don't race each other on the single-threaded path.
  ##
  ## ``bypassRunQuota = true`` because the apply driver runs outside
  ## a daemon context — there's no run-quota client to consult.
  ##
  ## ``brokerSpawn = spawner`` is the load-bearing wiring: when an
  ## edge carries ``requiresElevation = true``, the engine's pre-
  ## launch decision point hands the request to the closure instead
  ## of forking directly. The closure (constructed via
  ## ``mkInfraApplyBrokerSpawn(ctx)``) packages the request into a
  ## ``pokInlineExecCall`` ``PrivilegedOperation`` and dispatches via
  ## ``repro_elevation.dispatchOperation``.
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true
  result.suppressTrace = true
  result.brokerSpawn = spawner

# ---------------------------------------------------------------------------
# Dispatcher closure construction.
# ---------------------------------------------------------------------------

proc projectActionResult(action: ProfileBuildAction;
                         res: ActionResult): BuildActionApplyOutcome =
  ## Project one engine-side ``ActionResult`` onto the apply-side
  ## ``BuildActionApplyOutcome`` shape.
  result = BuildActionApplyOutcome(
    id: action.id,
    address: action.id,
    requiresElevation: action.requiresElevation)
  case res.status
  of asSucceeded:
    result.ok = true
    result.cacheHit = false
  of asCacheHit, asUpToDate:
    result.ok = true
    result.cacheHit = true
  of asFailed, asBlocked:
    result.ok = false
    result.cacheHit = false
    var detail = "engine reported " & $res.status
    if res.stderr.len > 0:
      detail.add(": ")
      detail.add(res.stderr)
    elif res.stdout.len > 0:
      detail.add(": ")
      detail.add(res.stdout)
    result.diagnostic = detail
  else:
    # Any future status enum value (asSkipped, ...) lands here. We
    # treat the unknown as failure so a silent regression surfaces
    # at apply time rather than at audit-log review time.
    result.ok = false
    result.diagnostic = "engine returned unrecognised status " & $res.status

proc mkBuildActionDispatcher*(cacheRoot: string;
                              ctx: FixtureContext): BuildActionDispatcher =
  ## Build the dispatcher closure ``repro infra apply`` injects into
  ## ``ApplyOptions.buildActionDispatcher``. The closure captures the
  ## cache root and a pre-built ``ElevatedExecSpawner`` constructed
  ## via ``mkInfraApplyBrokerSpawn(ctx)``.
  ##
  ## Why pre-build the spawner here (rather than at every dispatcher
  ## invocation): the spawner closes over ``ctx``, and a single apply
  ## reuses the same ``FixtureContext`` for every action edge it
  ## dispatches. Re-constructing the spawner per call would discard
  ## the closure invariant.
  let spawner = mkInfraApplyBrokerSpawn(ctx)
  let capturedCacheRoot = cacheRoot
  result = proc(actions: seq[ProfileBuildAction]):
      seq[BuildActionApplyOutcome] {.gcsafe.} =
    {.cast(gcsafe).}:
      if actions.len == 0:
        return @[]
      let g = buildActionsToBuildGraph(actions)
      let cfg = applyBuildActionsEngineConfig(capturedCacheRoot, spawner)
      var runRes: BuildRunResult
      try:
        runRes = runBuild(g, cfg)
      except CatchableError as err:
        # Catastrophic engine failure — project onto a per-edge
        # failure outcome for EVERY input so the audit log records
        # which actions did not run. The diagnostic is the same
        # across the seq so the operator can grep for the root cause.
        let detail = "build engine raised " & $err.name & ": " & err.msg
        for a in actions:
          result.add(BuildActionApplyOutcome(
            id: a.id,
            address: a.id,
            ok: false,
            requiresElevation: a.requiresElevation,
            cacheHit: false,
            diagnostic: detail))
        return result
      # Project per-edge ActionResult onto BuildActionApplyOutcome.
      # The engine's result order matches the graph's action order
      # (validateGraph rejects duplicate ids).
      var byId = newSeq[ActionResult](0)
      for r in runRes.results: byId.add(r)
      for a in actions:
        var matched = false
        for r in byId:
          if r.id == a.id:
            result.add(projectActionResult(a, r))
            matched = true
            break
        if not matched:
          # The engine dropped the action (validateGraph filter, e.g.
          # an unknown dep). Surface as a failure outcome so the apply
          # driver tallies it correctly.
          result.add(BuildActionApplyOutcome(
            id: a.id,
            address: a.id,
            ok: false,
            requiresElevation: a.requiresElevation,
            cacheHit: false,
            diagnostic: "engine produced no ActionResult for this " &
              "action edge (likely filtered by validateGraph)"))
