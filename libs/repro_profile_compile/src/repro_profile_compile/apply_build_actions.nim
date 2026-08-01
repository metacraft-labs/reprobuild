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

import std/[os, strutils, tables]

import repro_build_engine
import repro_core
import repro_elevation
import repro_hash
import repro_infra
import repro_local_store
import repro_profile

import ./infra_apply_broker
import ./binary_cache_build_actions

proc sanitizeForPath(value: string): string =
  ## Reduce an action id to a filesystem-safe scratch-dir component so
  ## the M4 per-action substitute/publish scratch dirs never collide or
  ## escape ``cacheRoot``. Non-alphanumerics collapse to ``_``.
  result = newStringOfCap(value.len)
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "action"

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
  # engine config (``applyBuildActionsEngineConfig``) can wire an io-monitor
  # command when the caller has one available. Without one, the engine emits its
  # "requires an io-monitor driver" diagnostic rather than claiming complete
  # monitor evidence. That preserves the declared-input idempotency this apply
  # path needs WITHOUT the unsound "mark complete/cacheable on declared inputs
  # while silently dropping runtime read-set discovery" hole the old
  # declared-only kind opened.
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
                                    spawner: ElevatedExecSpawner;
                                    monitorCliPath = "";
                                    monitorCliArgs: openArray[string] = []):
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
  ## ``rebuildMissingOutputsOnCacheHit = true`` makes a cache hit whose
  ## declared outputs are already on disk a no-op: the engine serves it
  ## from the whole-graph fast no-op scan (``asCacheHit``) or, failing
  ## that, the per-action outputs-present branch (``asUpToDate``), and
  ## leaves the files untouched either way. With the default
  ## (``false``) the engine instead calls ``restoreOutputs``, which
  ## rewrites every declared output via a temp-file + ``removeFile`` +
  ## ``moveFile`` dance — even when the bytes on disk are already the
  ## bytes the cache would write.
  ##
  ## That rewrite is destructive rather than merely wasteful. When a
  ## declared output is an executable image that some other process on
  ## the host currently has mapped, the platform can refuse to unlink
  ## it, ``restoreOutputs`` raises, and the exception escapes ``runBuild``
  ## and fails the whole dispatch (see the ``engineFailedAll`` path
  ## below). Every other engine consumer in the tree already sets this
  ## flag; the apply driver was the lone caller still taking the
  ## rewrite-on-hit path.
  ##
  ## Trade-off, stated explicitly: the outputs-present short-circuit
  ## tests output *presence*, not output *content*. The always-restore
  ## path therefore had an incidental self-healing property — it would
  ## overwrite an output that had been corrupted or truncated in place
  ## by something outside the build. That property is not preserved
  ## here. It is the same contract every other consumer already runs
  ## under, and re-running with ``--force-rebuild`` still repairs a
  ## damaged tree.
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true
  result.suppressTrace = true
  result.brokerSpawn = spawner
  result.monitorCliPath = monitorCliPath
  result.monitorCliArgs = @monitorCliArgs

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
                              ctx: FixtureContext;
                              monitorCliPath = "";
                              monitorCliArgs: openArray[string] = []):
    BuildActionDispatcher =
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
  let capturedMonitorCliPath = monitorCliPath
  let capturedMonitorCliArgs = @monitorCliArgs
  result = proc(actions: seq[ProfileBuildAction]):
      seq[BuildActionApplyOutcome] {.gcsafe.} =
    {.cast(gcsafe).}:
      if actions.len == 0:
        return @[]

      # ---- M4: binary-cache substitute-first / publish-on-miss. ----
      # When ``REPRO_BINARY_CACHE_URL`` is set we PREFER fetching each
      # edge's outputs from the cache instead of building locally. Edges
      # substituted from the cache are removed from the engine's
      # build-graph; only the misses (and edges with no substitutable
      # outputs) go through ``runBuild``. On a successful local build we
      # publish the freshly-built outputs back so a later fresh apply
      # hits. Off-by-default: an unset URL yields ``configured = false``
      # and the whole block is a no-op — the local-build path below is
      # byte-identical to pre-M4 behaviour.
      let cacheCfg = resolveBuildActionCacheConfig()
      # The M4 CAS + scratch lives beside the engine's action-cache
      # under the same apply-scoped cache root so a cache sweep of the
      # action-edge half removes both.
      let m4ScratchRoot = capturedCacheRoot / "binary-cache-substitute"
      # Cache a substituted-outcome per action id so the final result
      # ordering matches the input ordering.
      var substituted = initTable[string, BuildActionApplyOutcome]()
      var toBuild: seq[ProfileBuildAction] = @[]
      for a in actions:
        if cacheCfg.configured:
          let attempt = trySubstituteBuildAction(
            a, cacheCfg, m4ScratchRoot / sanitizeForPath(a.id))
          if attempt.hit:
            substituted[a.id] = BuildActionApplyOutcome(
              id: a.id,
              address: a.id,
              ok: true,
              requiresElevation: a.requiresElevation,
              cacheHit: true,
              substitutedFromCache: true)
            continue
        toBuild.add(a)

      # Map from action id -> engine ActionResult for the local-build
      # subset. Empty when every edge was substituted.
      var byId = newSeq[ActionResult](0)
      var engineFailedAll = false
      var engineFailDetail = ""
      if toBuild.len > 0:
        let g = buildActionsToBuildGraph(toBuild)
        let cfg = applyBuildActionsEngineConfig(capturedCacheRoot, spawner,
          capturedMonitorCliPath, capturedMonitorCliArgs)
        try:
          let runRes = runBuild(g, cfg)
          for r in runRes.results: byId.add(r)
        except CatchableError as err:
          engineFailedAll = true
          # ATTRIBUTION: when runBuild raises, the engine returns no
          # per-action results at all, so there is genuinely nothing to
          # attribute this failure to a specific edge with. A single
          # edge's exception aborts the whole dispatch and every edge in
          # the batch is then reported with this same text.
          #
          # Say that explicitly. The unqualified per-edge phrasing this
          # replaced made N identical diagnostics look like N
          # independent faults — which reads as a systemic failure (bad
          # permissions, broken host) and sends diagnosis in exactly the
          # wrong direction. The wording below is the only honest
          # statement available at this layer; see the note above
          # ``engineFailedAll``'s use below for the real fix.
          engineFailDetail =
            "build engine aborted the whole batch of " & $toBuild.len &
            " action edge(s) before reporting per-edge results; this " &
            "edge is not necessarily the one that failed. Underlying " &
            "error: " & $err.name & ": " & err.msg

      # ---- Assemble the per-edge outcomes in INPUT order. ----
      for a in actions:
        if substituted.hasKey(a.id):
          result.add(substituted[a.id])
          continue
        if engineFailedAll:
          # NOT-FIXED-HERE: real per-edge attribution requires the engine
          # to stop letting one action's exception escape the scheduler
          # loop. The fix belongs in repro_build_engine's per-action
          # handling (mark that action asFailed and continue) rather than
          # in this caller, which by construction has no per-action data
          # once runBuild has raised. Deliberately left out of this
          # change: it alters shared engine semantics for every consumer
          # and wants its own review.
          result.add(BuildActionApplyOutcome(
            id: a.id, address: a.id, ok: false,
            requiresElevation: a.requiresElevation,
            cacheHit: false, diagnostic: engineFailDetail))
          continue
        var matched = false
        for r in byId:
          if r.id == a.id:
            let outcome = projectActionResult(a, r)
            result.add(outcome)
            # Publish-on-miss: after a genuinely-fresh local build
            # (asSucceeded), publish the outputs so a later fresh apply
            # substitutes them. Best-effort — a publish failure never
            # perturbs the (already-converged) apply outcome. A cache
            # HIT from the engine's OWN action-cache (asCacheHit /
            # asUpToDate) is NOT re-published: the bytes are unchanged
            # and were published on the run that produced them.
            if cacheCfg.configured and outcome.ok and not outcome.cacheHit:
              discard publishBuildActionOutputs(
                a, cacheCfg, m4ScratchRoot / sanitizeForPath(a.id))
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
