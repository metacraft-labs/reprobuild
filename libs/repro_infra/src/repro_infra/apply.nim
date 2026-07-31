## `repro infra apply` — the system-scope apply orchestration (M69).
##
## Per System-Profile-And-Infra-Apply.md "repro infra apply" and
## Elevation-And-Privileged-Operations.md:
##
##   * an apply with a plan id re-checks staleness (`EPlanStale`)
##     BEFORE any mutation;
##   * an apply without a plan id computes a fresh plan and proceeds
##     without preview (`--no-preview`);
##   * the privileged operations run through the M81 single broker —
##     the already-elevated fast path runs them in-process, otherwise
##     ONE broker / ONE prompt; `--no-elevate` applies the
##     non-privileged subset and reports the privileged ones skipped;
##   * the generation / manifest commit is done by the NON-elevated
##     parent, after the privileged phase, exactly as for a
##     non-privileged apply.
##
## M69 Phase A operates on a hand-authored `system.nim` profile; the
## profile-editing command family is deferred.
##
## The broker orchestration itself is M81's `launchAndDriveBroker` /
## `applyPrivilegedSetInProcess` / `reportPrivilegedSetSkipped` — M69
## supplies the typed drivers the broker dispatches and does NOT
## re-implement the elevation mechanism.

import std/[os, strutils, times]

import repro_elevation
import repro_profile

import ./apply_lock
import ./audit_log
import ./errors
import ./gen_envelope
import ./plan_envelope
import ./planner
import ./profile
import ./state_dir

export apply_lock

type
  ElevationMode* = enum
    ## How the apply handles privileged operations.
    emBroker = "broker"               ## default: one broker, one prompt
    emNoElevate = "noElevate"         ## --no-elevate: skip privileged ops

  BuildActionApplyOutcome* = object
    ## Windows-System-Resources Phase G: per-edge result reported by
    ## the build-action dispatcher closure injected into
    ## ``ApplyOptions.buildActionDispatcher`` (see below).
    ##
    ## ``ok`` is the load-bearing success flag. Failure paths populate
    ## ``diagnostic`` with the engine-side diagnostic (e.g. the broker
    ## hook's error message); the apply driver folds the diagnostic
    ## into ``ApplyResult.diagnostics`` so the operator sees the same
    ## failure-reporting shape as a live-state driver failure.
    id*: string
    address*: string
      ## Mirrors the build-graph action id; surfaces in the
      ## ``ApplyResult.diagnostics`` line as the apply-log "address"
      ## column so a failed edge is greppable by id.
    ok*: bool
      ## Per-edge success flag. ``true`` on a clean cache hit OR a
      ## fresh successful execution; ``false`` on any failed action
      ## (engine launch failure, broker dispatch failure, non-zero
      ## exit code outside the accept set, ...).
    requiresElevation*: bool
    cacheHit*: bool
      ## True when the engine's cache short-circuited the launch (the
      ## edge produced the same outputs as a previous apply). Counted
      ## in ``ApplyResult.noOpCount`` for the apply summary so a
      ## repeat-apply prints "no-op" rather than "applied" for an
      ## already-converged action edge.
    substitutedFromCache*: bool
      ## Windows-Runner-Binary-Cache-Deploy M4: true when this edge's
      ## outputs were FETCHED FROM THE BINARY CACHE
      ## (``bakBinaryCacheSubstitute``) rather than produced by a local
      ## build. A substituted edge is a cache HIT (``cacheHit = true``
      ## as well) — it produced no local process. Counted separately in
      ## ``ApplyResult.substitutedFromCacheCount`` so the apply summary
      ## can report "N substituted from cache, M built locally" and the
      ## M4 gate can assert hits > 0 / locally-built == 0.
    fingerprintHex*: string
      ## The edge's cache fingerprint (hex), as computed by the
      ## dispatcher that keyed the edge. Written verbatim into the
      ## edge's RBSL audit record (`AuditRecord.fingerprintHex`) so a
      ## PERMANENTLY-missing edge is diagnosable from the on-disk log
      ## alone: comparing the value across consecutive generations
      ## separates "the edge re-keys every apply" from "the edge keys
      ## stably and misses for some other reason".
      ##
      ## A dispatcher that cannot compute a fingerprint leaves this
      ## empty; the audit record then still identifies the edge by
      ## address and verdict, it just cannot explain a miss.
    diagnostic*: string

  BuildActionDispatcher* = proc(actions: seq[ProfileBuildAction];
                                onProgress: ApplyProgressHook):
      seq[BuildActionApplyOutcome] {.gcsafe.}
    ## Windows-System-Resources Phase G: caller-supplied closure that
    ## drives the action-edge half of the apply. The dispatcher takes
    ## the profile's ``buildActions`` seq, assembles a ``BuildGraph``,
    ## attaches the elevation broker hook (constructed via
    ## ``repro_profile_compile.mkInfraApplyBrokerSpawn(ctx)``), runs
    ## ``runBuild`` against it, and projects each per-edge
    ## ``ActionResult`` into a ``BuildActionApplyOutcome``.
    ##
    ## ``onProgress`` MUST be invoked once per resolved action edge (it
    ## may be ``nil``). The action-edge half is otherwise a single
    ## opaque call across every edge in the profile, and the apply lock
    ## would fall silent for its whole duration — see
    ## ``apply_lock.nim``. Reporting per edge is what makes "no beat
    ## for N seconds" mean STUCK rather than BUSY.
    ##
    ## Living the dispatcher behind a typed closure (rather than
    ## hard-coding ``runBuild`` here) keeps ``repro_infra`` from
    ## depending on ``repro_build_engine``. The production seam wires
    ## ``repro_profile_compile.mkBuildActionDispatcher(...)``; tests
    ## inject a recording mock to assert the engine-edge translation
    ## without spawning real processes.
    ##
    ## ``nil`` (the default) means "no action-edge dispatcher
    ## attached". When ``nil`` AND the profile carries non-empty
    ## ``buildActions``, the apply driver FAILS CLOSED with
    ## ``EProtocol`` — silently skipping action edges would produce a
    ## misleading "success" that the spec's fail-closed posture
    ## explicitly forbids (see ``Windows-System-Resources.md`` § "What
    ## NOT to do — silent fallbacks").

  ApplyOptions* = object
    stateDir*: string
    hostIdentity*: string
    reproExe*: string                 ## the `repro` binary, for broker launch
    planId*: string                   ## empty => compute a fresh plan
    elevationMode*: ElevationMode
    forceBroker*: bool                ## REPRO_FORCE_BROKER test seam
    noPreview*: bool                  ## scripted: converge without preview
    acceptPasswdDestroy*: bool
      ## The M69 Phase-C `--accept-passwd-destroy` flag. A
      ## `passwd.user` destroy in `extraDestroyResources` REMOVES a
      ## user account; the apply fails closed with `EPasswdDestroy`
      ## BEFORE any mutation unless this flag is set. The symmetric
      ## counterpart of the `--accept-feature-destroy` rollback gate.
    extraDestroyResources*: seq[SystemResource]
      ## `repro system rollback` seam: resources the rollback must
      ## actively REVERT (a feature disable / capability uninstall /
      ## registry-value delete / VS uninstall / user removal /
      ## system-file delete) because the target generation no longer
      ## declares them. They are folded into the SAME apply as the
      ## target-profile convergence, so a rollback still raises at
      ## most one elevation prompt.
    buildActions*: seq[ProfileBuildAction]
      ## Windows-System-Resources Phase G: the action-edge intent
      ## items the profile macro emitted from inside the
      ## ``resources:`` block. Each entry lowers to a build-graph
      ## ``BuildAction`` in the dispatcher closure and crosses the
      ## elevation broker when ``requiresElevation = true``. The
      ## live-state half of the apply (``resources`` ->
      ## ``PlannedOperation`` -> ``dispatchOperation``) is unchanged
      ## by Phase G — these two halves are dispatched independently
      ## by ``runInfraApply``.
      ##
      ## Phase-G ordering: action edges run BEFORE the live-state
      ## convergence. A profile-shaped example: extract the runner
      ## zip (action edge) -> register the service (live state).
      ## Interleaved dependency support (live-state depending on
      ## action-edge outputs and vice versa) is a follow-up — for the
      ## production windows-runner-001 profile the all-edges-first
      ## ordering matches the natural dependency direction.
    buildActionDispatcher*: BuildActionDispatcher
      ## See ``BuildActionDispatcher``. ``nil`` is the default;
      ## non-nil enables the action-edge half of the apply.

  ApplyResult* = object
    generationId*: string
    planId*: string
    appliedCount*: int
    noOpCount*: int
    skippedCount*: int
    driftCount*: int
    errorCount*: int
    restartNeeded*: bool
    usedBroker*: bool
    brokerLaunchCount*: int
    substitutedFromCacheCount*: int
      ## Windows-Runner-Binary-Cache-Deploy M4: how many build-action
      ## edges had their outputs SERVED FROM THE BINARY CACHE this
      ## apply (``BuildActionApplyOutcome.substitutedFromCache``). Zero
      ## when no cache is configured (``REPRO_BINARY_CACHE_URL`` unset)
      ## or every edge missed the cache and built locally. The apply
      ## summary reports "N substituted from cache, M built locally"
      ## where N == this count and M == the number of applied edges
      ## that were NOT substituted.
    locallyBuiltActionCount*: int
      ## M4 companion to ``substitutedFromCacheCount``: build-action
      ## edges that ran a local process this apply (not a cache hit /
      ## substitute). This is the "M built locally" number.
    auditLogPath*: string
    diagnostics*: seq[string]
    buildActionResults*: seq[BuildActionApplyOutcome]
      ## Windows-System-Resources Phase G. Per-edge outcomes reported
      ## by the build-action dispatcher closure, kept around for the
      ## CLI's apply-summary print + the e2e test's assertion path.
      ## Empty when the profile declared no action edges OR the
      ## dispatcher was not wired (the latter case raises ``EProtocol``
      ## at apply time so this seq stays empty only for genuine no-op
      ## cases).

# ---------------------------------------------------------------------------
# Generation-id derivation. A 32-hex-char id over the profile digest +
# host + commit timestamp — the same shape as the home generation id.
# ---------------------------------------------------------------------------

proc deriveGenerationId(profileDigestHex, hostIdentity: string;
                        ts: int64): string =
  computePlanId(profileDigestHex & ".generation", hostIdentity, ts)

# ---------------------------------------------------------------------------
# Convert plan operation records into the broker's PlannedOperation
# (typed op + plan baseline digest).
# ---------------------------------------------------------------------------

proc plannedOperationsFor(profileText: string;
                          env: PlanEnvelope): seq[PlannedOperation] =
  ## Build the typed `PlannedOperation` list for the EFFECTIVE
  ## (non-no-op) operations of a plan. Each carries the plan's
  ## recorded baseline digest so the broker's drift gate can tell a
  ## safe update from a mid-flight drift.
  let profile = parseSystemProfile(profileText)
  for rec in env.operations:
    if rec.action == "no-op":
      continue
    for r in profile.resources:
      if r.address == rec.address:
        result.add(PlannedOperation(
          operation: toPrivilegedOperation(r),
          baselineDigestHex: rec.baselineDigestHex))
        break

# ---------------------------------------------------------------------------
# Write the streamed broker / fast-path apply-log records into the
# RBSL audit log of the new generation.
# ---------------------------------------------------------------------------

proc buildActionOperationKind(o: BuildActionApplyOutcome): string =
  ## The `operationKind` of a build-action audit record names WHERE the
  ## edge's outputs came from, because that — not a state transition —
  ## is what happened to the edge:
  ##
  ##   * `cache-substitute` — outputs fetched from the binary cache;
  ##   * `cache-hit`        — the engine's own action cache short-
  ##                          circuited the launch;
  ##   * `build`            — a local process ran (or was attempted and
  ##                          failed; the `outcome` field carries the
  ##                          verdict).
  if o.ok and o.cacheHit:
    if o.substitutedFromCache: "cache-substitute" else: "cache-hit"
  else:
    "build"

proc buildActionOutcomeTag(o: BuildActionApplyOutcome): string =
  ## The verdict, using the SAME vocabulary the live-state half uses so
  ## the log's per-verdict record counts reconcile with the printed
  ## apply summary. The mapping mirrors `dispatchBuildActions` exactly:
  ## failed -> error (errorCount), cache hit -> no-op (noOpCount),
  ## everything else -> applied (appliedCount).
  if not o.ok: "error"
  elif o.cacheHit: "no-op"
  else: "applied"

proc writeBuildActionAuditRecords(logPath: string; ts: int64;
                                  outcomes: seq[BuildActionApplyOutcome]) =
  ## Audit the build-action half of the apply.
  ##
  ## These records are deliberately NOT shaped like live-state records:
  ## `preDigestHex` / `postDigestHex` stay EMPTY because a build edge
  ## has no observed pre/post system state, and `recordClass` is
  ## `AuditClassBuildAction` so no reader can mistake the two
  ## populations for one. Before this existed the apply summary counted
  ## edges that the audit log never mentioned, so a generation's log
  ## described a strict subset of the resources the summary tallied.
  for o in outcomes:
    appendAuditRecord(logPath, AuditRecord(
      timestamp: ts,
      operationKind: buildActionOperationKind(o),
      resourceAddress: (if o.address.len > 0: o.address else: o.id),
      outcome: buildActionOutcomeTag(o),
      diagnostic: (if o.ok: "" else: o.diagnostic),
      preDigestHex: "",
      postDigestHex: "",
      restartNeeded: false,
      recordClass: AuditClassBuildAction,
      fingerprintHex: o.fingerprintHex))

proc writeAuditRecords(logPath: string;
                       applyLog: seq[ApplyLogRecord];
                       noOps: seq[PlannedOperationRecord];
                       buildActions: seq[BuildActionApplyOutcome] = @[]) =
  let ts = getTime().toUnix()
  # The action-edge half runs FIRST (see `runInfraApply` step 0), so its
  # records lead the log — the log reads in execution order.
  writeBuildActionAuditRecords(logPath, ts, buildActions)
  # No-op records first — the audit log captures the full apply,
  # including the resources that needed no change (the spec's
  # "observe" outcome).
  for rec in noOps:
    appendAuditRecord(logPath, AuditRecord(
      timestamp: ts,
      operationKind: rec.kindTag,
      resourceAddress: rec.address,
      outcome: "no-op",
      diagnostic: "",
      preDigestHex: rec.baselineDigestHex,
      postDigestHex: rec.desiredDigestHex,
      restartNeeded: false,
      recordClass: AuditClassLiveState,
      fingerprintHex: ""))
  for rec in applyLog:
    appendAuditRecord(logPath, AuditRecord(
      timestamp: ts,
      operationKind: rec.operationKind,
      resourceAddress: rec.operationAddress,
      outcome: rec.outcome,
      diagnostic: (if rec.outcome in ["drift", "error"]: rec.detail else: ""),
      preDigestHex: rec.preWriteDigestHex,
      postDigestHex: rec.postWriteDigestHex,
      restartNeeded: rec.restartNeeded,
      recordClass: AuditClassLiveState,
      fingerprintHex: ""))

# ---------------------------------------------------------------------------
# The apply.
# ---------------------------------------------------------------------------

proc applyLockBeat(stateDir: string): ApplyProgressHook =
  ## The per-unit-of-work progress hook the apply hands to the broker /
  ## in-process dispatcher / build-action dispatcher. Each call refreshes
  ## the apply lock's heartbeat, which is what proves to a LATER acquirer
  ## that this apply is moving rather than hung (``apply_lock.nim``).
  ##
  ## `refreshApplyLock` is a no-op when this process does not hold the
  ## lock (library tests, in-process drivers), so the hook is always safe
  ## to install.
  let dir = stateDir
  result = proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      discard refreshApplyLock(dir)

proc dispatchBuildActions(opts: ApplyOptions; result: var ApplyResult) =
  ## Windows-System-Resources Phase G: action-edge half of the apply.
  ## Runs BEFORE the live-state dispatch so a profile that extracts an
  ## archive then registers a service against the extracted directory
  ## sees the directory in place when the live-state driver fires.
  ##
  ## Dispatcher contract:
  ##   * empty ``buildActions`` -> no-op (dispatcher is not invoked,
  ##     even if it's wired).
  ##   * non-empty ``buildActions`` AND ``buildActionDispatcher == nil``
  ##     -> raise ``EProtocol``. The fail-closed posture matches the
  ##     spec's "no silent fallback" rule for any apply path that
  ##     reaches an action-edge intent without a build engine attached.
  ##   * non-empty ``buildActions`` AND non-nil dispatcher -> dispatch
  ##     all, fold per-edge results into the apply tallies. A failed
  ##     edge increments ``errorCount`` and surfaces its diagnostic
  ##     via ``ApplyResult.diagnostics``; a cache-hit edge increments
  ##     ``noOpCount``; everything else increments ``appliedCount``.
  ##
  ## The proc deliberately does NOT abort the apply on a failed
  ## action edge — the live-state half still runs so the operator
  ## sees the full picture (which lives-state resources also drifted)
  ## in the audit log. A non-zero ``errorCount`` makes the CLI exit
  ## non-zero so the failure is visible at the shell level.
  if opts.buildActions.len == 0:
    return
  if opts.buildActionDispatcher == nil:
    raise newException(EProtocol,
      "repro infra apply: profile carries " & $opts.buildActions.len &
      " build-action intent item(s) but no buildActionDispatcher was " &
      "wired in ApplyOptions. The action-edge half of the apply " &
      "cannot run without a dispatcher (no silent fallback). Construct " &
      "one via repro_profile_compile.mkBuildActionDispatcher(...) " &
      "before calling runInfraApply.")
  # The dispatcher beats the apply lock once per resolved edge, so a
  # profile with a long action-edge half never falls silent.
  let outcomes = opts.buildActionDispatcher(
    opts.buildActions, applyLockBeat(opts.stateDir))
  result.buildActionResults = outcomes
  for o in outcomes:
    if not o.ok:
      inc result.errorCount
      result.diagnostics.add("build-action " & o.id & ": " & o.diagnostic)
    elif o.cacheHit:
      inc result.noOpCount
      # M4: a cache hit that came from the BINARY CACHE (substitute)
      # rather than the engine's local action-cache is counted
      # separately so the apply can report the substitute tally.
      if o.substitutedFromCache:
        inc result.substitutedFromCacheCount
    else:
      inc result.appliedCount
      # M4: a non-cache-hit edge ran a local process this apply.
      inc result.locallyBuiltActionCount

proc runInfraApply*(profileText: string; opts: ApplyOptions): ApplyResult =
  ## Drive a full `repro infra apply`. The caller has already loaded
  ## the `system.nim` text and resolved `opts`.
  ##
  ## Steps:
  ##   0. Windows-System-Resources Phase G: dispatch any action-edge
  ##      build intents (extract this zip, run this config script,
  ##      ...) via the injected ``buildActionDispatcher`` closure. The
  ##      closure wraps ``runBuild`` with the elevation broker hook;
  ##      runs BEFORE the live-state half so a profile that extracts
  ##      a runner zip then registers a service against the extracted
  ##      directory sees the side effects in order.
  ##   1. resolve the plan — by id (with stale-detection) or fresh.
  ##   2. partition the effective operations.
  ##   3. apply: already-elevated fast path | one broker | skip.
  ##   4. write the RBSL audit log + commit the generation pointer.
  ##
  ## Throughout, the apply refreshes the lock's progress heartbeat —
  ## once per step boundary AND, crucially, once per UNIT OF WORK inside
  ## the two unbounded steps: every action edge in step 0 and every
  ## privileged operation in step 3. Step boundaries alone are not
  ## enough: a profile with a large privileged set would run for hours
  ## between beat 4 and beat 5 and look exactly like a hung apply to the
  ## next acquirer. See ``apply_lock.nim``.
  ##
  ## `refreshApplyLock` is a no-op when this process does not hold the
  ## lock (library tests, in-process drivers), so every beat is safe to
  ## issue unconditionally.
  resetBrokerLaunchCount()
  refreshApplyLock(opts.stateDir)

  # --- 0. Action-edge half (Windows-System-Resources Phase G). ---
  # Per spec § 2.3, action edges and live-state resources share one
  # ``resources:`` block in the profile source but route through
  # different engines at apply time. The action-edge dispatch runs
  # FIRST so a downstream live-state resource (a service that points
  # at an extracted binary) sees the extraction side effect.
  dispatchBuildActions(opts, result)
  refreshApplyLock(opts.stateDir)

  # --- 1. Resolve the plan. ---
  var env: PlanEnvelope
  if opts.planId.len > 0:
    env = readPlanFile(planPath(opts.stateDir, opts.planId))
    # Stale-detection: the live world must still be consistent with
    # the plan's recorded observations.
    let stale = detectStaleResources(env.operations, profileText)
    if stale.len > 0:
      raisePlanStale(opts.planId, stale)
  else:
    # No plan id: compute a fresh plan and proceed without preview.
    # M82 Phase C: pass the state dir so the planner can detect
    # plan-time external drift. The drift findings are advisory at
    # apply time — the per-driver post-apply re-probe (M82 Phase A)
    # is the integrity check.
    let fresh = producePlan(profileText, opts.hostIdentity,
      opts = PlannerOptions(stateDir: opts.stateDir,
                            acceptDrift: false))
    env = fresh.envelope
    # Persist the fresh plan so the apply is auditable by id.
    writePlanFile(planPath(opts.stateDir, env.planId), env)
  result.planId = env.planId
  refreshApplyLock(opts.stateDir)

  # --- 2. Partition the effective operations. ---
  var planned = plannedOperationsFor(profileText, env)
  var noOps: seq[PlannedOperationRecord]
  for rec in env.operations:
    if rec.action == "no-op":
      noOps.add(rec)
  # Windows-System-Resources Phase G: ADD the live-state no-op count
  # rather than overwriting; ``dispatchBuildActions`` may have
  # already incremented ``noOpCount`` for cache-hit action edges.
  # The two halves of the apply contribute independently.
  result.noOpCount += noOps.len

  # `--accept-passwd-destroy` gate: a `passwd.user` destroy in the
  # fold-in set REMOVES a real user account. Fail closed BEFORE any
  # mutation unless the operator accepted it — the symmetric
  # counterpart of the `--accept-feature-destroy` rollback gate.
  for r in opts.extraDestroyResources:
    if requiresPasswdDestroy(r) and not opts.acceptPasswdDestroy:
      raisePasswdDestroy(r.address)

  # Fold in any `repro system rollback` destroy operations: each
  # removed resource becomes a typed destroy operation whose baseline
  # digest is the resource's live observed state, so the broker's
  # drift gate treats it uniformly. An already-reverted resource
  # (observe says absent) is dispatched as a destroy no-op.
  for r in opts.extraDestroyResources:
    let obs = observeResource(r)
    planned.add(PlannedOperation(
      operation: toPrivilegedOperation(r, destroy = true),
      baselineDigestHex: obs.observedDigestHex))

  let partition = partitionApply(
    block:
      var ops: seq[PrivilegedOperation]
      for p in planned: ops.add(p.operation)
      ops,
    nonPrivilegedOperationCount = 0)
  refreshApplyLock(opts.stateDir)

  # --- 3. Apply the privileged set. ---
  # The privileged set is the longest unbounded stretch of the apply: a
  # profile that installs a Visual Studio workload plus its siblings can
  # run for hours in here. Both dispatch paths therefore beat the lock
  # once per COMPLETED operation, so the silence a later acquirer has to
  # interpret is bounded by ONE operation rather than the whole set.
  let beat = applyLockBeat(opts.stateDir)
  var outcome: PrivilegedApplyOutcome
  if not partition.hasPrivilegedWork():
    # Nothing privileged: no broker, no prompt.
    result.usedBroker = false
  elif opts.elevationMode == emNoElevate:
    # --no-elevate: apply the non-privileged subset (none, for a
    # pure-Windows profile) and report every privileged op skipped.
    outcome = reportPrivilegedSetSkipped(planned, onProgress = beat)
    result.usedBroker = false
  else:
    let alreadyElevated = isProcessElevated()
    if alreadyElevated and not opts.forceBroker:
      # Already-elevated fast path: run the privileged set in-process,
      # no broker, no prompt.
      outcome = applyPrivilegedSetInProcess(
        FixtureContext(), planned, onProgress = beat)
      result.usedBroker = false
    else:
      # Launch EXACTLY ONE broker. A declined prompt is equivalent to
      # --no-elevate (a clean partial result, not a crash).
      try:
        let brokerApply = launchAndDriveBroker(opts.reproExe, planned,
          onProgress = beat)
        outcome = brokerApply.outcome
        result.usedBroker = true
      except EElevationDeclined:
        outcome = reportPrivilegedSetSkipped(planned, onProgress = beat)
        result.diagnostics.add(
          "the elevation prompt was declined; privileged operations " &
          "were skipped (equivalent to --no-elevate)")
        result.usedBroker = false
  result.brokerLaunchCount = brokerLaunchCount()
  refreshApplyLock(opts.stateDir)

  # --- Tally the outcome. ---
  for r in outcome.results:
    if r.driftDetected:
      inc result.driftCount
    elif not r.ok:
      if "requires elevation" in r.diagnostic:
        inc result.skippedCount
      else:
        inc result.errorCount
  for rec in outcome.applyLog:
    if rec.outcome == "applied":
      inc result.appliedCount
    elif rec.outcome == "no-op":
      inc result.noOpCount
    if rec.restartNeeded:
      result.restartNeeded = true

  # --- 4. Commit the generation + write the audit log. ---
  let commitTs = getTime().toUnix()
  let generationId = deriveGenerationId(
    env.profileDigestHex, opts.hostIdentity, commitTs)
  result.generationId = generationId
  let genDir = generationDir(opts.stateDir, generationId)
  createDir(genDir)
  let logPath = applyLogPath(opts.stateDir, generationId)
  # Every resource the apply summary counts — BOTH halves — lands in
  # this one log, so a generation's audit trail accounts for the same
  # population the printed `applied / no-op` counters do.
  writeAuditRecords(logPath, outcome.applyLog, noOps,
    result.buildActionResults)
  result.auditLogPath = logPath
  # Write the per-generation RBSG envelope. It embeds the applied
  # `system.nim` text so `repro system history` can enumerate this
  # generation and `repro system rollback` can re-apply a prior
  # generation's profile (the system state dir has no CAS, so the
  # small profile text is embedded directly).
  writeGenerationEnvelope(pointerPath(opts.stateDir, generationId),
    GenerationEnvelope(
      schemaVersion: GenSchemaVersion,
      generationId: generationId,
      activationTimestamp: commitTs,
      hostIdentity: opts.hostIdentity,
      planId: env.planId,
      profileDigestHex: env.profileDigestHex,
      profileText: profileText,
      appliedCount: result.appliedCount,
      noOpCount: result.noOpCount))
  # The generation pointer / `current` marker is updated by the
  # NON-elevated parent (this proc), never the broker.
  writeCurrentGenerationId(opts.stateDir, generationId)
  refreshApplyLock(opts.stateDir)
  for d in outcome.results:
    if d.driftDetected or (not d.ok and "requires elevation" notin
        d.diagnostic):
      result.diagnostics.add(d.operationAddress & ": " & d.diagnostic)
