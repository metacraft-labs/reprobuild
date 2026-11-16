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

import std/[monotimes, os, strutils, tables, times]

import repro_core/host_apply_lock
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
import ./systemd_syntax
when defined(posix):
  import std/tables
  import ./carried_state
  import ./start_holds

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
    rebootRequired*: bool
      ## True when this edge RAN and its effect does not take hold until
      ## the machine restarts. Folded into ``ApplyResult.restartNeeded``
      ## below, which is the flag the apply's reboot notice reads.
      ##
      ## This field exists because the notice had no reachable input off
      ## Windows. ``restartNeeded`` has one write site, fed by one record
      ## type, fed by four driver-level originators, and all four are
      ## behind ``when defined(windows)``. The build-action half could not
      ## contribute at all -- not because nothing chose to, but because
      ## this type had no such field and ``dispatchBuildActions`` had no
      ## such fold, while the build-action audit writer put a literal
      ## ``false`` in every record it wrote. A rule whose input cannot be
      ## constructed is not a conservative rule; it is dead code that
      ## reads like a live one.
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

  ApplyPhaseHooks* = object
    ## Hooks a layered apply attaches around the privileged set. The
    ## ReproOS add-on switch (ReproOS-Add-On-Mode §7.2) uses them: its
    ## steps 1-3 (realise, pre-stop, flip) run after the plan is resolved
    ## and before the first write, its steps 6-8 (fragment tools, start,
    ## confirm) and its ledger run after the last write and before the
    ## generation is committed. Every field is optional.
    beforePrivilegedSet*: proc(planId: string) {.gcsafe.}
      ## Called once the plan is resolved and persisted, before any
      ## privileged operation is dispatched. A raise aborts the apply
      ## with nothing written by it.
    afterPrivilegedSet*: proc(generationId: string; clean: bool):
      seq[string] {.gcsafe.}
      ## Called after the privileged set with the generation id the
      ## commit would use (its directory and audit log exist by then) and
      ## whether the set ran without an error or drift finding. Returns
      ## diagnostics: a non-empty result is an error, counted and
      ## withholding the commit under `commitOnlyWhenClean`.
    commitPoint*: proc(point: string) {.gcsafe.}
      ## Told at the commit's crash-relevant points (``commit-envelope``:
      ## the envelope is durable, `current` not moved yet; and inside the
      ## move). A test seam for the add-on's crash gate; nil otherwise.
    commitOnlyWhenClean*: bool
      ## Move `current` and write the generation envelope only when the
      ## privileged set and the after-hook reported no error and no
      ## drift. Otherwise the attempt's audit log stays under the
      ## generation's directory (no envelope, so `history` and `rollback`
      ## never see it as a state the host reached) and `current` keeps
      ## naming the previous generation: a failed switch is not a
      ## generation (spec §7.2 step 9, §7.5; reprobuild-pm issue
      ## 2026-10-30-infra-apply-commits-a-generation-whose-privileged-set-failed).

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
    destroysFirst*: bool
      ## Dispatch the `extraDestroyResources` before the profile's own
      ## operations instead of after them. The add-on switch needs it: its
      ## flip leaves the link of a removed drop-in dangling, and systemd
      ## refuses to load (or `enable`) a unit with a dangling drop-in, so
      ## the removal must happen before the unit it modifies is written.
    extraDestroyResources*: seq[SystemResource]
      ## `repro system rollback` seam: resources the rollback must
      ## actively REVERT (a feature disable / capability uninstall /
      ## registry-value delete / VS uninstall / user removal /
      ## system-file delete) because the target generation no longer
      ## declares them. They are folded into the SAME apply as the
      ## target-profile convergence, so a rollback still raises at
      ## most one elevation prompt.
    preWriteGuard*: PreWriteGuard
      ## Consulted before every privileged operation on the in-process
      ## (already-elevated) path; see `repro_elevation.PreWriteGuard`. The
      ## ReproOS add-on re-runs its collision observer here. `nil` (the
      ## default) checks nothing extra. The broker path does not carry
      ## it: the add-on applies as root, in process.
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
    phases*: ApplyPhaseHooks
      ## See ``ApplyPhaseHooks``; all-nil (the default) applies as before.
    carriedStateDir*: string
      ## Where a conversion left carried state (ReproOS Add-On Mode
      ## §11.1); "" is ``carried_state.CarriedStateDir``. A test seam,
      ## like ``carriedStateRoot`` (the root the carried directories are
      ## looked for under; "" is ``/``).
    carriedStateRoot*: string
    carriedStateChecked*: bool
      ## The caller (the add-on's ``runAddonApply``) already refused this
      ## apply's profile against carried state and holds, before its own
      ## first write; the composed profile it hands over carries the
      ## add-on's own objects as well, which are not the operator's.
    addOnDispatch*: AddOnDispatchPolicy
      ## The add-on switch's per-operation materialisation policy
      ## (`repro_elevation.AddOnDispatchPolicy`), carried to the drivers
      ## through the in-process dispatch context. `nil` outside add-on
      ## mode.

  ApplyResult* = object
    generationId*: string
    planId*: string
    committed*: bool
      ## `current` names `generationId` now. False only under
      ## `ApplyPhaseHooks.commitOnlyWhenClean` for an apply that failed.
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
      ## when no cache is configured (no ``caches.conf`` entry and no
      ## ``REPRO_BINARY_CACHE_URL``)
      ## or every edge missed the cache and built locally. The apply
      ## summary reports "N substituted from cache, M built locally"
      ## where N == this count and M == the number of applied edges
      ## that were NOT substituted.
    locallyBuiltActionCount*: int
      ## M4 companion to ``substitutedFromCacheCount``: build-action
      ## edges that ran a local process this apply (not a cache hit /
      ## substitute). This is the "M built locally" number.
    auditLogPath*: string
    liveJudged*: seq[string]
      ## The units the carried-state live check read from systemd, by the
      ## name it read them under (``carried_state.liveJudgedNames``: a
      ## template through its instances, §13 decision 135); empty when the
      ## check did not run. Reported so an operator, and a gate, can see
      ## what the check covered.
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
# host + commit timestamp + the generation that was current at commit.
# ---------------------------------------------------------------------------

proc deriveGenerationId*(profileDigestHex, hostIdentity: string;
                         ts: int64; previousGenerationId: string): string =
  ## A system generation is history, not a disposable proposal: every
  ## commit must name a distinct generation. The timestamp has whole-second
  ## resolution and the digest is of the RENDERED profile (the empty text
  ## for every action-edge-only profile), so digest + host + second alone
  ## collide for two commits within one second, and the second overwrote
  ## the first (reprobuild-pm issue
  ## 2026-10-18-system-generation-ids-collide-within-one-second). Chaining
  ## the previously current generation makes consecutive commits distinct:
  ## each commit moves `current` to its own id, so the next commit's input
  ## differs. Every input is recorded in the generation's envelope
  ## (`profileDigestHex`, `hostIdentity`, `activationTimestamp`,
  ## `previousGenerationId`), so the id is recomputable from it. The digest
  ## is fixed-width hex, so joining it with the predecessor is unambiguous.
  computePlanId(profileDigestHex & ".generation:" & previousGenerationId,
    hostIdentity, ts)

proc allocateGenerationId(stateDir, profileDigestHex, hostIdentity: string;
                          previousGenerationId: string;
                          ts: var int64): string =
  ## The id the commit will use, never one whose directory already exists.
  ## The chain above already separates every completed commit; what is
  ## left is a directory left behind by an apply that died between
  ## creating it and moving `current` (the apply lock serializes live
  ## applies). Rather than overwrite that directory, the commit takes the
  ## next second: `ts` is advanced and is what the envelope records as the
  ## activation time, so the id stays recomputable from the envelope.
  result = deriveGenerationId(profileDigestHex, hostIdentity, ts,
    previousGenerationId)
  while dirExists(generationDir(stateDir, result)):
    inc ts
    result = deriveGenerationId(profileDigestHex, hostIdentity, ts,
      previousGenerationId)

# ---------------------------------------------------------------------------
# Convert plan operation records into the broker's PlannedOperation
# (typed op + plan baseline digest).
# ---------------------------------------------------------------------------

const
  ApplyMutation {.strdefine: "reproAddonMutation".} = ""
    ## ``plan-ignores-profile-digest``, ``full-apply-keeps-undeclared-dropins``
    ## (falsifying builds, ``repro_addon/mutations``).
  LiveCheckSkipped = ApplyMutation in [
    "infra-live-reach-skipped",
    "reach-values-as-text-without-live-check",
    "reach-alias-dropins-unread-without-live-check",
    "account-dynamic-name-from-stem-without-live-check"]
    ## The builds whose full apply does not run the carried-state cross-check
    ## (§13 decision 59): ``infra-live-reach-skipped``, its falsifier, and the
    ## three that break a static reading of the reach analysis besides. The
    ## live check judges the unit as systemd loaded it, so it refuses the
    ## conversion gate's probe of each of those readings too; with it on,
    ## the probe never runs and the gate's red is the live check's, not the
    ## static reading's (A13 review round 7).

proc undeclaredDropIns*(stateDir, profileText: string): seq[SystemResource] =
  ## The ``systemd.systemDropIn`` resources the active generation declares
  ## and ``profileText`` does not: a host realised in full removes them
  ## (A13 review round 5, finding 3), as the add-on's switch removes what
  ## its ledger no longer owns. Otherwise a drop-in written by an earlier
  ## generation -- the carried-state requirement among them -- would stay
  ## loaded by systemd though no profile declares it. Empty when there is
  ## no active generation.
  when ApplyMutation == "full-apply-keeps-undeclared-dropins":
    return
  if stateDir.len == 0: return
  let activeId = readCurrentGenerationId(stateDir)
  if activeId.len == 0: return
  let active = readGenerationEnvelope(pointerPath(stateDir, activeId))
  var wanted: seq[string]
  for r in parseSystemProfile(profileText).resources: wanted.add(r.address)
  var old: SystemProfile
  try:
    old = parseSystemProfile(active.profileText)
  except CatchableError:
    # A generation this build cannot read: nothing is removed for it. The
    # carried-state reach analysis still reads every such file on the host
    # (``carried_state.unitTexts``), so a stale drop-in is judged, not
    # trusted.
    return
  for r in old.resources:
    if r.kind == srkSystemdSystemDropIn and r.address notin wanted:
      # The carried-state requirement goes only with its unit: a host
      # realised in full keeps a unit file the profile no longer declares,
      # and that unit must still not start at a boot whose restore failed.
      when defined(posix):
        if r.diName == RequirementDropInName and
            fileExists("/etc/systemd/system" / r.diUnit):
          continue
      result.add(r)

proc plannedOperationsFor*(profileText: string;
                           env: PlanEnvelope): seq[PlannedOperation] =
  ## Build the typed `PlannedOperation` list for the EFFECTIVE
  ## (non-no-op) operations of a plan. Each carries the plan's
  ## recorded baseline digest on the wire; the broker does not consult
  ## it (M82 Phase A removed the drift gate that did, see
  ## `dispatch.dispatchOperation` step 3), and diffs against its own
  ## live re-observation instead.
  ##
  ## A record the planner marked `DependencyRestartAction` (a unit whose
  ## own bytes are unchanged but whose `depends_on` resource changes in
  ## this plan, Add-On spec §7.3) is dispatched with `suRestartRequested`,
  ## which makes the dispatch loop skip its no-op short-circuit and the
  ## driver restart the running instance.
  let profile = parseSystemProfile(profileText)
  for rec in env.operations:
    if rec.action == "no-op":
      continue
    for r in profile.resources:
      if r.address == rec.address:
        var op = toPrivilegedOperation(r)
        if rec.action == DependencyRestartAction and
            op.kind == pokSystemdSystemUnit:
          op.suRestartRequested = true
        result.add(PlannedOperation(
          operation: op,
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
      # Was a literal ``false``. A constant here meant the on-disk log
      # disagreed with the summary the same apply printed, and no reader
      # could tell which edge owed the reboot.
      restartNeeded: o.rebootRequired,
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
    # The fold is OUTSIDE the ok/cacheHit partition below, and
    # deliberately so. A partially-applied edge that failed can still
    # have left the system in a state a restart completes, and an
    # operator who is told nothing about that is worse off than one told
    # about a reboot they turn out not to need. The dispatcher decides
    # whether an edge earned the flag; this loop only propagates it.
    if o.rebootRequired:
      result.restartNeeded = true
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

type
  PendingSwitchGuard* = proc (applyStateDir: string; target: SystemProfile;
                              hasTarget: bool):
    tuple[ok: bool; why: string] {.closure, gcsafe.}
  PendingSwitchCommitted* = proc (applyStateDir: string; target: SystemProfile;
                                  clean: bool) {.closure, gcsafe.}
  PendingSwitchStartResolved* = proc (applyStateDir: string;
                                      target: SystemProfile): seq[string]
    {.closure, gcsafe.}

var pendingSwitchGuard*: PendingSwitchGuard = nil
  ## Installed by the add-on layer (`repro_addon/reassert`), which owns the
  ## switch and its pending marker; nil where that layer is not linked.
  ## `runInfraApply` calls it with the host apply lock held: ok when no
  ## interrupted switch is pending (or it was just recovered), otherwise
  ## why not. ``target`` is the generation the apply realises
  ## (``hasTarget``): an apply whose generation removes or changes every
  ## trigger a revert left on record goes through (§13 decision 160 as
  ## amended by the round-10 owner decision "allow the fixing apply").

var pendingSwitchCommitted*: PendingSwitchCommitted = nil
  ## Installed with the guard: called once a full apply has committed its
  ## generation, so the entries of the record of triggers to restart that
  ## generation resolves are cleared (the same decision) -- only when the
  ## apply is ``clean``: no entry is cleared while it has an error (A13
  ## review round 12, M2).

var pendingSwitchStartResolved*: PendingSwitchStartResolved = nil
  ## Installed with the guard: called by a full apply before its commit, it
  ## starts what the apply's generation resolves of the record of triggers
  ## to restart, each confirmed through systemd, and returns the problems
  ## -- each an error of the apply (the owner decision "yes, same as 175",
  ## A13 review round 12, M2: a full apply that resolves an entry starts
  ## it, as the fixing add-on switch does).

proc driverStartJobs*(planned: openArray[PlannedOperation];
                      isActive: proc (unit: string): bool): seq[string] =
  ## The units whose start or restart job the drivers issue in this
  ## privileged set (§13 decision 79), in plan order, for every driver that
  ## starts a unit:
  ## - every ``systemd.systemUnit`` the plan writes that is enabled (its
  ##   driver runs ``enable --now``, whatever its type: a target, a socket, a
  ##   timer or a service) and every one that is running before the set and
  ##   whose restart the profile does not hold (its driver restarts it after
  ##   its change);
  ## - every ``systemd.unitState`` that is to run and was not running before
  ##   the set (its driver runs ``systemctl start`` only then), a unit the
  ##   profile does not own such as ``multi-user.target``;
  ## - every ``systemd.systemTimer`` that is to run (its driver runs
  ##   ``systemctl start`` unconditionally).
  ## ``isActive`` is asked before anything is written. A held unit a start
  ## pulls in through its dependencies is skipped by its hold; after the
  ## carried-state check passes, these jobs are issued again so systemd
  ## brings it up through the same dependencies.
  for p in planned:
    let op = p.operation
    case op.kind
    of pokSystemdSystemUnit:
      if op.suDestroy: continue
      if not (op.suEnabled or (not op.suRestartHeld and isActive(op.suName))):
        continue
      when ApplyMutation == "reissue-skips-targets":
        # FALSIFYING MUTATION: a target's job is not issued again.
        if op.suName.endsWith(".target"): continue
      when ApplyMutation == "reissue-skips-sockets":
        # FALSIFYING MUTATION: a socket's job is not issued again.
        if op.suName.endsWith(".socket"): continue
      if op.suName notin result: result.add(op.suName)
    of pokSystemdUnitState:
      when ApplyMutation == "reissue-skips-unit-state":
        # FALSIFYING MUTATION: a unitState start is not issued again.
        continue
      if op.usDestroy or not op.usRunning or isActive(op.usName): continue
      if op.usName notin result: result.add(op.usName)
    of pokSystemdSystemTimer:
      when ApplyMutation == "reissue-skips-timers":
        # FALSIFYING MUTATION: a timer's start is not issued again.
        continue
      if op.stDestroy or not op.stRunning: continue
      if op.stName notin result: result.add(op.stName)
    else:
      continue

proc refusedUnits*(units, problems: openArray[string]): seq[string] =
  ## The judged units the check's ``problems`` name (a problem reads
  ## ``... : <unit> ...`` or ``... : <unit>: ...``). A problem that names
  ## none of them (the refusal decided again over the host as the reload
  ## left it) cannot be attributed, so it holds every unit: a refusal that
  ## cannot say whom it concerns lets nothing start (§11.1). A template's
  ## problems name its instances (§13 decision 135), so a problem naming
  ## any ``<stem>@...`` refuses the template, whose hold holds them all.
  if problems.len == 0: return
  for u in units:
    let stem = if isTemplateUnit(u): u[0 .. u.find('@')] else: ""
    for pr in problems:
      let named = if stem.len > 0: (": " & stem) in pr
                  else: (": " & u & " ") in pr or (": " & u & ":") in pr
      if named and u notin result: result.add(u)
  when ApplyMutation == "refusal-holds-every-unit":
    # FALSIFYING MUTATION: one refused unit holds them all.
    if result.len > 0: result = @units
  if result.len == 0: result = @units

proc triggeredUnits*(show: Table[string, string]): seq[string] =
  ## The units a timer or path unit triggers: ``Triggers=`` of
  ## ``systemctl show``.
  for u in show.getOrDefault("Triggers").splitWhitespace():
    if u notin result: result.add(u)

proc skippedUnderHold*(show: Table[string, string];
                       holdStampUsec: int64): bool =
  ## Whether a start of the unit whose ``systemctl show`` is ``show`` was
  ## skipped by a ``Condition…=`` hold written at ``holdStampUsec`` (a
  ## ``CLOCK_MONOTONIC`` reading, microseconds): its last condition test
  ## failed, at or after the hold. A timer's or path unit's trigger that
  ## fired under the hold leaves exactly this behind, and no other state:
  ## the one-shot elapse of a monotonic timer is spent, and ``start`` of a
  ## trigger unit that is already active adds no job for what it triggers.
  if show.getOrDefault("ConditionResult") != "no": return false
  let ts = show.getOrDefault("ConditionTimestampMonotonic", "0")
  try: parseBiggestInt(ts) >= holdStampUsec and parseBiggestInt(ts) > 0
  except ValueError: false

type
  LiveHost* = object
    ## The systemd reads and starts of the carried-state check's release,
    ## as closures so the order of the starts can be tested without a
    ## running systemd.
    isActive*: proc (unit: string): bool
    show*: proc (unit: string): Table[string, string]
    start*: proc (unit: string): tuple[ok: bool, output: string]
    stop*: proc (unit: string): tuple[ok: bool, output: string]
      ## nil where the caller stops nothing (the release alone).
    resetFailed*: proc (unit: string)
      ## nil where the caller resets nothing.
    list*: proc (pattern: string): seq[string]
      ## The units systemd has loaded, of any state, whose names match
      ## ``pattern`` (``systemctl list-units --all``); nil where the caller
      ## lists nothing.
    startNoBlock*: proc (unit: string): tuple[ok: bool, output: string]
      ## ``systemctl start --no-block``: the start job is queued and not
      ## waited for (at boot, A13 review round 12, M4); nil where the
      ## caller never queues.

proc unitId*(host: LiveHost; u: string): string =
  ## The name systemd knows ``u`` by: its ``Id=`` (A13 review round 12,
  ## M1, the owner's "all three"). An alias -- an ``[Install] Alias=`` or a
  ## symlink such as ``dbus-org.freedesktop.login1.service`` -- resolves to
  ## the unit it names (``systemd-logind.service``), so a unit is matched,
  ## held and judged essential by one name whatever name a file used. A
  ## template, which systemd will not show, and a unit systemd cannot be
  ## asked about keep their own name.
  when ApplyMutation == "alias-names-unresolved":
    # FALSIFYING MUTATION: names are matched as written.
    return u
  if isTemplateUnit(u) or host.show == nil: return u
  try:
    let id = host.show(u).getOrDefault("Id").strip()
    if id.len > 0: return id
  except CatchableError: discard
  u

proc unitIds*(host: LiveHost; names: openArray[string]): seq[string] =
  ## ``unitId`` of each of ``names``, each once.
  for n in names:
    let id = unitId(host, n)
    if id notin result: result.add(id)

proc heldBy*(u: string; units: openArray[string]): bool =
  ## Whether ``u`` is one of ``units`` or an instance of a template among
  ## them (§13 decision 152: ``tpl@daily.service`` is held by the judged
  ## ``tpl@.service``).
  when ApplyMutation == "fired-instance-unmapped":
    # FALSIFYING MUTATION: an instance is not mapped to its template.
    u in units
  else:
    u in units or templateOfUnit(u) in units

proc firedUnderHold*(driverStarts, units, refused: openArray[string];
                     host: LiveHost; holdStampUsec: int64): seq[string] =
  ## The judged, passed, inactive units that a timer or path unit the
  ## drivers started triggered while the hold was in place (§13 decision
  ## 79 as amended 2026-11-14). Read before the holds are lifted.
  for t in driverStarts:
    if not (t.endsWith(".timer") or t.endsWith(".path")): continue
    var triggers: seq[string]
    try: triggers = triggeredUnits(host.show(t))
    except CatchableError: continue
    for u in triggers:
      if not heldBy(u, units) or heldBy(u, refused) or u in result: continue
      if host.isActive(u): continue
      var st: Table[string, string]
      try: st = host.show(u)
      except CatchableError: continue
      when ApplyMutation == "trigger-fired-under-hold-not-started":
        # FALSIFYING MUTATION: a trigger that fired under the hold is
        # not noticed.
        continue
      if skippedUnderHold(st, holdStampUsec): result.add(u)

proc releaseStarts*(p: SystemProfile; units, passed, refused, wasActive,
                    driverStarts, fired: openArray[string];
                    host: LiveHost): seq[string] =
  ## What a full apply starts once its check has judged ``units``, after
  ## the holds of the ``passed`` ones are lifted: the problems that
  ## reports. Nothing is started for a ``refused`` unit, which stays held;
  ## the rest of the units start whatever the refusal (§11.1).
  # What the drivers would have started: every unit the profile enables,
  # and every unit that was running before (its restart was skipped).
  var started: seq[string]
  for r in p.resources:
    if r.kind != srkSystemdSystemUnit or r.suName notin passed: continue
    if isTemplateUnit(r.suName):
      # A template is not started by name (systemd refuses it): the
      # instances that were running before start again (§13 decision 135).
      let stem = r.suName[0 .. r.suName.find('@')]
      for i in wasActive:
        if i.startsWith(stem) and i notin started:
          started.add(i)
          let s = host.start(i)
          if not s.ok:
            result.add("systemctl start " & i & " after the " &
              "carried-state check: " & s.output.strip())
      continue
    if r.suEnabled or r.suName in wasActive:
      started.add(r.suName)
      let s = host.start(r.suName)
      if not s.ok:
        result.add("systemctl start " & r.suName & " after the " &
          "carried-state check: " & s.output.strip())
  # And what their jobs pulled in (§13 decision 79, decided 2026-11-08 by
  # the owner): a held unit another unit's start wants -- a static
  # service an enabled target or socket pulls in -- was skipped by its
  # hold. Each start or restart job the drivers issued is issued again,
  # as a start: systemd adds the jobs of its dependencies as it did for
  # the driver, so the held units come up as on a host without carried
  # state, and a unit already running is not restarted a second time
  # (its restart's stop half ran in the drivers' job).
  for u in driverStarts:
    if u in started or u in refused or isTemplateUnit(u): continue
    # Not a unit that ran and exited, or failed, in the drivers' job (a
    # one-shot service): issuing its start again would run it twice.
    # Its pulled-in units were queued by that job and stay as the hold
    # left them (spec §11.1, the residual of decision 79).
    if u notin units and not host.isActive(u): continue
    started.add(u)
    let s = host.start(u)
    if not s.ok:
      result.add("systemctl start " & u & " (re-issued after the " &
        "carried-state check, §13 decision 79): " & s.output.strip())
  # A trigger that fired under the hold: its service's start was skipped
  # and the trigger will not fire it again (§13 decision 79, 2026-11-14).
  for u in fired:
    if u in started or u in refused: continue
    let s = host.start(u)
    if not s.ok:
      result.add("systemctl start " & u & " (its timer or path unit " &
        "fired while the carried-state check held it, §13 decision 79): " &
        s.output.strip())

const TriggerSuffixes = [".socket", ".path", ".timer"]

proc isTriggerUnit*(u: string): bool =
  for s in TriggerSuffixes:
    if u.endsWith(s): return true

proc loadedTriggersOf*(names: openArray[string]; host: LiveHost): seq[string] =
  ## The socket, path and timer units systemd has loaded that trigger any
  ## of ``names`` (each one's ``TriggeredBy=``; §13 decisions 151 and 152):
  ## the held units' triggers that are not the profile's own, a host's
  ## socket for a profile service, and an instance's own timer.
  for n in names:
    var props: Table[string, string]
    try: props = host.show(n)
    except CatchableError: continue
    for t in props.getOrDefault("TriggeredBy").splitWhitespace():
      if isTriggerUnit(t) and t notin result: result.add(t)

proc fireSources*(driverStarts, heldTriggers: openArray[string]): seq[string] =
  ## The triggers whose activations the release looks at (§13 decision
  ## 152): every trigger of a held unit, not only those the drivers
  ## started -- an unchanged timer whose ``OnCalendar=`` elapsed during a
  ## long privileged set is one of them.
  result = @driverStarts
  when ApplyMutation == "fired-from-driver-starts-only":
    # FALSIFYING MUTATION: only the drivers' starts are looked at.
    return
  for t in heldTriggers:
    if t notin result: result.add(t)

proc profileTriggersOf*(p: SystemProfile; units: openArray[string]): seq[string] =
  ## The profile's own socket, path and timer units whose triggered unit
  ## is held (an instance by its template): known before any of them is
  ## written or loaded, so the apply can hold them with their unit.
  for (trigger, target) in triggerTargets(p):
    if heldBy(target, units) and trigger notin result: result.add(trigger)

proc triggersToStop*(triggers, stopping: openArray[string];
                     host: LiveHost;
                     profileTargets: openArray[tuple[trigger, target: string]] = []):
    seq[string] =
  ## Of the active ``triggers``, those that could fire at a held unit
  ## during the hold (§13 decision 151), which are stopped for it: a trigger
  ## whose units are all running cannot -- an active service serves its own
  ## socket (with ``Accept=no`` it holds the listening descriptor, so a
  ## stop and start of the socket would fail to bind again), and a path or
  ## timer start of an active unit adds no job -- unless one of them is
  ## among ``stopping``, the running units the hold's apply restarts.
  ## A trigger's units are those systemd reports now and those the
  ## generation points it at (``profileTargets``, ``planner.triggerTargets``:
  ## a profile drop-in that re-points a running socket at a held unit makes
  ## it fire at that unit after the drivers' reload; A13 review round 10).
  for t in triggers:
    if not host.isActive(t): continue
    var targets: seq[string]
    try: targets = triggeredUnits(host.show(t))
    except CatchableError: discard
    when ApplyMutation != "trigger-repointing-ignored":
      # FALSIFYING MUTATION (when absent): only the live Triggers= is read.
      for (pt, target) in profileTargets:
        if pt == t and target notin targets: targets.add(target)
    var canFire = targets.len == 0
    for u in targets:
      if u in stopping or not host.isActive(u): canFire = true
    when ApplyMutation == "triggers-of-running-units-stopped":
      # FALSIFYING MUTATION: every active trigger is stopped.
      canFire = true
    if canFire and t notin result: result.add(t)

proc rememberedTriggers*(triggers: openArray[string]; host: LiveHost):
    seq[string] =
  ## Every active trigger of a held unit (§13 decision 151): those the hold
  ## stops, and those it leaves alone because their units run. A trigger
  ## left alone is down by the release when its service stopped during the
  ## hold and it then fired at the held unit (or failed with it); the
  ## release starts every remembered trigger that is not active (A13 review
  ## round 10, finding 2).
  for t in triggers:
    if host.isActive(t) and t notin result: result.add(t)

proc triggersToRelease*(remembered, stopped, driverStarts,
                        triggers: openArray[string]): seq[string] =
  ## The triggers the release starts again (§13 decision 151): every one
  ## remembered as active before the hold, and every one the drivers
  ## started under it (an enabled trigger's ``enable --now``, skipped by its
  ## hold), of the hold's own triggers. ``triggerRestarts`` starts those
  ## that are not active.
  when ApplyMutation == "left-alone-triggers-forgotten":
    # FALSIFYING MUTATION: only the triggers the hold stopped come back.
    for t in @stopped & @driverStarts:
      if t in triggers and t notin result: result.add(t)
    return
  for t in @remembered & @stopped & @driverStarts:
    if t in triggers and t notin result: result.add(t)

proc templateTriggerInstances*(p: SystemProfile; units: openArray[string];
                               list: proc (pattern: string): seq[string]):
    seq[string] =
  ## The loaded instances of the trigger templates of the held templates
  ## (§13 decision 152): ``tpl@daily.timer`` of the profile's
  ## ``tpl@.timer`` triggering a held ``tpl@.service``, found by asking
  ## systemd (``list``: ``systemctl list-units --all`` over a pattern), not
  ## from what runs or what the generation names -- an idle instance timer
  ## of a template is neither (A13 review round 10, finding 3). Patterns:
  ## the held template's own stem with each trigger suffix, and each
  ## profile trigger template whose target is the held template.
  when ApplyMutation == "template-trigger-instances-unlisted":
    # FALSIFYING MUTATION: no instance trigger is looked for.
    return
  var patterns: seq[string]
  for u in units:
    if not isTemplateUnit(u): continue
    let stem = u[0 .. u.find('@')]
    for sfx in TriggerSuffixes:
      let pat = stem & "*" & sfx
      if pat notin patterns: patterns.add(pat)
  for (trigger, target) in triggerTargets(p):
    if isTemplateUnit(trigger) and heldBy(target, units):
      let pat = trigger[0 .. trigger.find('@')] & "*" & trigger[trigger.rfind('.') .. ^1]
      if pat notin patterns: patterns.add(pat)
  for pat in patterns:
    var names: seq[string]
    try: names = list(pat)
    except CatchableError: continue
    let stem = pat[0 ..< pat.find('*')]
    for n in names:
      if n.startsWith(stem) and not isTemplateUnit(n) and isTriggerUnit(n) and
          n notin result:
        result.add(n)

const LiveCheckTriggersFile* = "live-check-triggers"
  ## §13 decision 151 on the full apply (A13 review round 10, finding 5):
  ## the triggers a full apply's hold stopped or left alone, one per line,
  ## in its state directory, written before any is stopped and removed once
  ## the release has started them. An apply that dies between the two
  ## leaves it; the next apply, and `repro system addon recover`, start
  ## them again (``restartRecordedLiveCheckTriggers``).

proc recordLiveCheckTriggers*(stateDir: string; triggers: openArray[string]) =
  ## Record ``triggers`` (durably), or remove the record when none.
  let p = stateDir / LiveCheckTriggersFile
  when ApplyMutation == "live-check-triggers-in-memory":
    # FALSIFYING MUTATION: the full apply keeps them in memory only.
    return
  if triggers.len == 0:
    when defined(posix): removeDurably(p)
    else:
      if fileExists(p): removeFile(p)
    return
  createDir(stateDir)
  when defined(posix):
    # Durable (A13 review round 10, L4): written in full to a temporary
    # file, fsync'd, renamed into place and the directory fsync'd
    # (``start_holds.writeHoldFile``), so a crash after the apply stopped a
    # trigger cannot leave a record that names none.
    writeHoldFile(p, triggers.join("\n") & "\n")
  else:
    let tmp = p & ".tmp"
    writeFile(tmp, triggers.join("\n") & "\n")
    moveFile(tmp, p)

proc readLiveCheckTriggers*(stateDir: string): seq[string] =
  let p = stateDir / LiveCheckTriggersFile
  if not fileExists(p): return
  for l in readFile(p).splitLines():
    let t = l.strip()
    if t.len > 0 and t notin result: result.add(t)

const LiveCheckUnitsFile* = "live-check-units"
  ## The units a full apply holds for its carried-state check -- the judged
  ## units and their requirers -- one per line, ``<unit>`` or
  ## ``<unit><TAB>was-active`` for one that ran before the hold, written
  ## (durably) before the first hold and removed once the release is done.
  ## An apply that dies between the two leaves it, with its holds: the next
  ## full apply adopts both (``deadApplyHeld``) and starts them only after
  ## its own check (§13 decision 180: the owner decision "re-hold, start
  ## after check", A13 review round 12, M3).

when defined(posix):
  proc recordLiveCheckUnits*(stateDir: string;
                             units: openArray[tuple[unit: string; wasActive: bool]]) =
    ## Record ``units`` (durably), or remove the record when none.
    let p = stateDir / LiveCheckUnitsFile
    if units.len == 0:
      removeDurably(p)
      return
    createDir(stateDir)
    var text = ""
    var seen: seq[string]
    for (u, a) in units:
      if u in seen: continue
      seen.add(u)
      text.add(u & (if a: "\twas-active" else: "") & "\n")
    writeHoldFile(p, text)

  proc readLiveCheckUnits*(stateDir: string):
      seq[tuple[unit: string; wasActive: bool]] =
    let p = stateDir / LiveCheckUnitsFile
    if not fileExists(p): return
    var seen: seq[string]
    for l in readFile(p).splitLines():
      let f = l.split('\t')
      let u = f[0].strip()
      if u.len == 0 or u in seen: continue
      seen.add(u)
      result.add((unit: u, wasActive: f.len > 1 and f[1].strip() == "was-active"))

  proc deadApplyHeld*(stateDir: string; holdDir = RuntimeUnitDir):
      tuple[units: seq[tuple[unit: string; wasActive: bool]];
            triggers: seq[string]] =
    ## What a full apply that died between its hold and its release still
    ## holds: the units and triggers on its records (``LiveCheckUnitsFile``,
    ## ``LiveCheckTriggersFile``) and every unit a carried-check hold in
    ## ``holdDir`` names (an older build's apply recorded no units). The
    ## next full apply adopts them into its own held set and keeps their
    ## holds -- it never lifts a dead apply's hold on a judged service
    ## before its own check (the owner decision "re-hold, start after
    ## check", A13 review round 12, M3) -- and starts them after its check:
    ## each trigger, and each unit that ran before the dead apply's hold.
    when ApplyMutation == "dead-apply-holds-lifted":
      # FALSIFYING MUTATION: round 11's order -- the dead apply's holds are
      # all cleared and nothing is adopted.
      try: discard clearStaleHolds(CarriedCheckHoldName, holdDir)
      except OSError: discard
      return
    result.units = readLiveCheckUnits(stateDir)
    for t in readLiveCheckTriggers(stateDir):
      if t notin result.triggers: result.triggers.add(t)
    var named: seq[string]
    for (u, _) in result.units: named.add(u)
    for h in staleHolds(CarriedCheckHoldName, holdDir):
      let u = heldUnitOf(h)
      if u.len == 0: continue
      if isTriggerUnit(u):
        if u notin result.triggers: result.triggers.add(u)
      elif u notin named:
        named.add(u)
        result.units.add((unit: u, wasActive: false))

proc startConfirmed*(host: LiveHost; unit: string; mustStayActive: bool):
    tuple[ok: bool; why: string] =
  ## Start ``unit`` and confirm through systemd that it really started (A13
  ## review round 11, H1): ``systemctl start`` of a unit whose condition a
  ## hold fails exits 0 and leaves it inactive ("skipped"), so the exit
  ## code alone says nothing. After the start, systemd's own view decides:
  ## the unit is active, activating or reloading; or -- only when
  ## ``mustStayActive`` is false, for a service that runs and exits -- it
  ## is inactive with ``Result=success`` and its last condition and assert
  ## checks passed. A socket, path or timer unit must stay active.
  if host.resetFailed != nil: host.resetFailed(unit)
  let s = host.start(unit)
  if not s.ok: return (false, s.output.strip())
  when ApplyMutation == "restart-success-by-exit-code":
    # FALSIFYING MUTATION: the exit code is taken as the outcome.
    return (true, "")
  var props: Table[string, string]
  try: props = host.show(unit)
  except CatchableError as e: return (false, "systemd could not be asked: " & e.msg)
  let st = props.getOrDefault("ActiveState")
  if st in ["active", "activating", "reloading"]: return (true, "")
  let skipped = props.getOrDefault("ConditionResult") == "no" or
                props.getOrDefault("AssertResult") == "no"
  if not mustStayActive and st == "inactive" and not skipped and
      props.getOrDefault("Result", "success") == "success":
    return (true, "")
  (false, "the start exited 0 but systemd reports ActiveState=" & st &
    " Result=" & props.getOrDefault("Result") & " ConditionResult=" &
    props.getOrDefault("ConditionResult") & " AssertResult=" &
    props.getOrDefault("AssertResult") &
    (if skipped: " (its start was skipped: a hold or condition)" else: ""))

proc triggerRestarts*(triggers, refusedTriggers: openArray[string];
                      host: LiveHost): seq[string] =
  ## Start again each of ``triggers`` once its hold is gone, after a
  ## ``reset-failed`` (§13 decision 151): every trigger comes back up. One
  ## systemd no longer loads (the generation removed it) is left alone,
  ## and so is a trigger of a refused unit, which stays held with it.
  ## Returns the problems.
  for t in triggers:
    if t in refusedTriggers: continue
    # One already up -- a trigger the hold left alone that still runs --
    # needs nothing.
    if host.isActive != nil and host.isActive(t): continue
    var props: Table[string, string]
    try: props = host.show(t)
    except CatchableError: continue
    if props.getOrDefault("LoadState") != "loaded": continue
    let s = startConfirmed(host, t, mustStayActive = true)
    if not s.ok:
      result.add("systemctl start " & t & " (a trigger stopped for the " &
        "carried-state check's hold, §13 decision 151): " & s.why)

proc isTargetUnit*(u: string): bool = u.endsWith(".target")

proc heldAsRequirer*(u: string): bool =
  ## Whether a unit found requiring a judged one is held with it: never a
  ## ``.target`` (the owner decision "never hold .target units", A13 review
  ## round 12). A target is followed through to the units that require IT
  ## -- its real requirers -- and is not itself held: a judged unit with
  ## ``[Install] RequiredBy=multi-user.target`` must not hold
  ## ``multi-user.target`` or ``graphical.target``, which would stop the
  ## boot's own goal.
  when ApplyMutation == "target-units-held":
    # FALSIFYING MUTATION: a target is held like any requirer.
    return true
  not isTargetUnit(u)

proc unitRequirements*(texts: openArray[string]): seq[string] =
  ## The units a unit's ``[Unit]`` section ``Requires=`` or ``BindsTo=``,
  ## read from its file and then its drop-ins as systemd reads them
  ## (``systemd_syntax.systemdLogicalLines``). An empty assignment is NOT
  ## a reset: systemd's ``config_parse_unit_deps`` (src/core/load-fragment.c,
  ## https://github.com/systemd/systemd/blob/v257/src/core/load-fragment.c)
  ## adds each word it finds and nothing else, so ``Requires=`` with no
  ## value leaves the earlier dependencies in place (measured by the A13
  ## review on systemd 260, round 11).
  for text in texts:
    var section = ""
    for line in systemdLogicalLines(text):
      let t = line.strip()
      if t.len == 0 or t[0] in {'#', ';'}: continue
      if t[0] == '[':
        section = if t.endsWith("]"): t[1 ..< t.len - 1] else: ""
        continue
      if section != "Unit": continue
      let eq = t.find('=')
      if eq <= 0: continue
      let k = t[0 ..< eq].strip()
      if k notin ["Requires", "BindsTo"]: continue
      let v = t[eq + 1 .. ^1].strip()
      when ApplyMutation == "empty-requires-resets":
        # FALSIFYING MUTATION: an empty assignment resets the list.
        if v.len == 0:
          result.setLen(0)
          continue
      for u in v.splitWhitespace():
        if u notin result: result.add(u)

proc profileRequirersOf*(p: SystemProfile; units: openArray[string]): seq[string] =
  ## The units of the generation ``p``, outside ``units`` (the judged ones),
  ## that ``Requires=`` or ``BindsTo=`` one of ``units``, directly or
  ## through another such unit (§13 decision 153 as the owner decided it
  ## in A13 review round 10, every requirer): a refused unit's start is
  ## skipped by its condition hold, which systemd counts as satisfied, so
  ## such a unit would start without it. The full apply holds them with
  ## the judged units and keeps held those that require a refused one.
  when ApplyMutation in ["unjudged-requirers-released", "requirer-files-unread"]:
    # FALSIFYING MUTATIONS: no unit outside the judged set is held as a
    # requirer by any path (``unjudged-requirers-released``), or only this
    # layer -- the generation's files -- is not read
    # (``requirer-files-unread``).
    return
  # Every unit the generation writes a file or a drop-in for: its own
  # units (a template's hold covers its instances, so a template that
  # requires a judged unit is held as a template and judged through its
  # instances, as decision 153 judges one; A13 review round 11, M3), and
  # the units it only drops in on.
  var names: seq[string]
  var texts = initTable[string, seq[string]]()
  for r in p.resources:
    if r.kind == srkSystemdSystemUnit and r.suCollision != "dropIn":
      if r.suName notin names: names.add(r.suName)
      texts.mgetOrPut(r.suName, @[]).insert(renderedSystemUnitContent(r), 0)
    elif r.kind == srkSystemdSystemDropIn:
      if r.diUnit notin names: names.add(r.diUnit)
  for n in names:
    discard texts.mgetOrPut(n, @[])
    for d in profileDropInsOf(p, n): texts[n].add(d)
  var reached = @units
  var changed = true
  while changed:
    changed = false
    for n in names:
      when ApplyMutation == "template-requirers-skipped":
        # FALSIFYING MUTATION: a template requirer is not held.
        if isTemplateUnit(n): continue
      if heldBy(n, reached): continue
      for d in unitRequirements(texts[n]):
        if heldBy(d, reached):
          reached.add(n)
          # A target is followed through, not held (``heldAsRequirer``).
          if heldAsRequirer(n): result.add(n)
          changed = true
          break

proc shownNamesOf*(u: string; host: LiveHost): seq[string] =
  ## The names systemd shows a judged unit under: a unit by its own name; a
  ## template, which ``systemctl show`` refuses by name, through its
  ## observation instance and every instance systemd has loaded or running
  ## (``host.list``), as ``requiringRefused`` reads one (A13 review round
  ## 12, M1: a host drop-in on ``pg@main.service`` that another unit binds
  ## to is a requirer of the judged ``pg@.service``).
  when ApplyMutation == "judged-template-shown-by-name":
    # FALSIFYING MUTATION: a template is shown by its own name.
    return @[u]
  if not isTemplateUnit(u): return @[u]
  when defined(posix):
    result.add(observationInstanceOf(u))
  if host.list != nil:
    let stem = u[0 .. u.find('@')]
    let sfx = u[u.rfind('.') .. ^1]
    var names: seq[string]
    try: names = host.list(stem & "*" & sfx)
    except CatchableError: discard
    for n in names:
      if n.startsWith(stem) and not isTemplateUnit(n) and n notin result:
        result.add(n)

proc systemdRequirersOf*(units: openArray[string]; host: LiveHost): seq[string] =
  ## The units systemd has loaded that ``Requires=`` or ``BindsTo=`` one of
  ## ``units``, directly or through another such unit, as systemd's
  ## effective dependencies say: each unit's reverse properties
  ## ``RequiredBy=`` and ``BoundBy=`` (which cover a unit file's lines, a
  ## host drop-in, a ``.requires/`` link and an enabled ``[Install]
  ## RequiredBy=``; every requirer, by the owner decision on decision 171, A13 review round
  ## 11). Names are systemd's ``Id=`` (``unitId``); a judged template is
  ## read through its loaded and running instances (``shownNamesOf``), never
  ## by its own name, which systemd refuses to show; a ``.target`` is
  ## followed through, not returned (``heldAsRequirer``).
  var queue: seq[string]
  var seen: seq[string]
  for u in units:
    let id = unitId(host, u)
    if id notin seen: seen.add(id)
    for n in shownNamesOf(id, host):
      if n notin queue: queue.add(n)
  while queue.len > 0:
    let u = queue.pop()
    var props: Table[string, string]
    try: props = host.show(u)
    except CatchableError: continue
    for key in ["RequiredBy", "BoundBy"]:
      for d in props.getOrDefault(key).splitWhitespace():
        if d in seen or heldBy(d, units): continue
        seen.add(d)
        if heldAsRequirer(d): result.add(d)
        queue.add(d)

const EssentialUnits* = [
  # Remote access (the management path: §7.5's list of units an agent apply
  # may not touch) -- sshd, the console and serial logins, logind and the
  # system bus, which every login needs.
  "ssh.service", "sshd.service", "ssh.socket", "sshd.socket", "ssh@.service",
  "sshd@.service", "getty@.service", "serial-getty@.service",
  "console-getty.service", "container-getty@.service", "autovt@.service",
  "getty.target", "systemd-logind.service", "dbus.service", "dbus.socket",
  "dbus-broker.service", "systemd-user-sessions.service", "user@.service",
  "user-runtime-dir@.service",
  # The network and firewall the management path runs over.
  "systemd-networkd.service", "systemd-networkd.socket",
  "systemd-networkd-wait-online.service", "NetworkManager.service",
  "NetworkManager-wait-online.service", "networking.service", "nftables.service",
  "netfilter-persistent.service", "iptables.service", "ip6tables.service",
  "ufw.service", "firewalld.service",
  # The add-on itself: re-assertion and its boot hold and confirm, the
  # deploy agent's fetch and apply.
  "repro-addon-reassert.service", "repro-addon-boot-hold.service",
  "repro-addon-boot-confirm.service", "repro-agent-apply.service",
  "repro-agent-fetch.service", "repro-agent-fetch.timer"]
  ## The units a full apply refuses to hold for the carried-state check:
  ## an essential requirer is never held (the owner decision on decision
  ## 171, A13 review round 11): holding one
  ## could cut remote access to the host or stop the add-on from repairing
  ## it. A template stands for its instances.

proc isEssentialUnit*(u: string): bool =
  u in EssentialUnits or (u.find('@') > 0 and templateOfUnit(u) in EssentialUnits)

proc essentialHeld*(held: openArray[string]): seq[string] =
  ## Those of ``held`` that are essential (``EssentialUnits``).
  when ApplyMutation == "essential-requirers-held":
    # FALSIFYING MUTATION: an essential unit is held like any other.
    return
  for u in held:
    if isEssentialUnit(u) and u notin result: result.add(u)

proc preWriteRequirers*(p: SystemProfile; units: openArray[string];
                        host: LiveHost): seq[string] =
  ## The units held with the judged ``units`` before anything is written
  ## (§13 decisions 171 and 177): the generation's requirers read from its
  ## files (``profileRequirersOf``), and the loaded units systemd's
  ## effective dependencies name (``systemdRequirersOf``); each by the name
  ## systemd knows it by (``unitId``), so a drop-in a generation writes on
  ## an alias is matched to the unit the alias names.
  let judged = unitIds(host, units)
  for u in unitIds(host, profileRequirersOf(p, units)):
    if not heldBy(u, judged) and u notin result: result.add(u)
  when ApplyMutation in ["requirers-from-files-only",
                         "unjudged-requirers-released"]:
    # FALSIFYING MUTATION: systemd's view is not read before the writes.
    return
  for u in systemdRequirersOf(units, host):
    if not heldBy(u, judged) and u notin result: result.add(u)

proc essentialInHoldSet*(units, requirers, triggers: openArray[string];
                         host: LiveHost): seq[string] =
  ## The essential units (``EssentialUnits``) of what a full apply would
  ## hold for its carried-state check -- the judged ``units`` themselves,
  ## their ``requirers`` and their ``triggers`` alike (A13 review round 12,
  ## M1, the owner's "all three") -- each by its systemd ``Id=``
  ## (``unitId``), so an alias of an essential unit is one. Any refuses the
  ## apply before it stops or holds anything.
  var names: seq[string]
  when ApplyMutation != "essential-judged-units-held":
    # FALSIFYING MUTATION (when absent): a judged unit is not looked at.
    names.add(unitIds(host, units))
  names.add(unitIds(host, requirers))
  when ApplyMutation != "essential-triggers-held":
    # FALSIFYING MUTATION (when absent): a trigger is not looked at.
    names.add(unitIds(host, triggers))
  essentialHeld(names)

proc postReloadRequirers*(refused, held: openArray[string]; host: LiveHost):
    tuple[hold, essential: seq[string]] =
  ## After the drivers' reload: the units systemd's effective dependencies
  ## name as requiring a refused unit (``systemdRequirersOf``) that were not
  ## held with the judged units -- a requirer only the generation's writes
  ## made one, which neither its files as read before the writes nor
  ## systemd's view before them could name (§13 decision 177). Each is held
  ## now (``hold``), but an essential one, which is reported (``essential``).
  when ApplyMutation in ["post-reload-requirers-released",
                         "unjudged-requirers-released"]:
    # FALSIFYING MUTATION: the post-reload layer holds nothing.
    return
  for u in systemdRequirersOf(refused, host):
    if u in held or u in refused: continue
    if isEssentialUnit(u):
      if u notin result.essential: result.essential.add(u)
    elif u notin result.hold:
      result.hold.add(u)

proc restartRecordedLiveCheckTriggers*(stateDir: string; host: LiveHost):
    seq[string] =
  ## Start again the triggers an earlier full apply recorded and never
  ## released (``LiveCheckTriggersFile``): those that do not start stay on
  ## record and are returned as problems.
  var left: seq[string]
  for t in readLiveCheckTriggers(stateDir):
    let failed = triggerRestarts([t], [], host)
    if failed.len > 0:
      left.add(t)
      result.add(failed)
  recordLiveCheckTriggers(stateDir, left)

when defined(posix):
  proc releaseRecordedTriggers*(stateDir: string; host: LiveHost;
                                holdDir = RuntimeUnitDir;
                                reload: proc () = nil):
      tuple[left: seq[string]; problems: seq[string]] =
    ## `repro system addon recover`'s part in a full apply that died
    ## between its hold and its release (the owner decision "re-hold, start
    ## after check", A13 review round 12, M3): only the recorded triggers'
    ## own holds are lifted, never a judged service's. A trigger whose
    ## unit is still held by the dead apply is left on record, with its
    ## hold, for the next full apply, which starts it after its own check:
    ## started now, a socket with a pending connection would fire at a held
    ## service until systemd's trigger limit failed it. Every other
    ## recorded trigger has its own hold lifted (``reload`` then runs:
    ## ``systemctl daemon-reload``) and is started, confirmed through
    ## systemd (``triggerRestarts``). ``left``: the triggers still on
    ## record; ``problems``: those that did not start.
    when ApplyMutation == "recover-lifts-unit-holds":
      # FALSIFYING MUTATION: round 11's clearing -- every hold the dead
      # apply left is lifted, a judged service's included.
      if clearStaleHolds(CarriedCheckHoldName, holdDir).len > 0 and
          reload != nil:
        reload()
    var free: seq[string]
    for t in readLiveCheckTriggers(stateDir):
      var targets: seq[string]
      try: targets = triggeredUnits(host.show(t))
      except CatchableError: discard
      var stillHeld = ""
      for u in targets:
        if fileExists(holdPath(u, CarriedCheckHoldName, holdDir)):
          stillHeld = u
      when ApplyMutation == "recover-starts-trigger-of-held-unit":
        # FALSIFYING MUTATION: a trigger whose unit is still held is lifted
        # and started like any other.
        stillHeld = ""
      if stillHeld.len > 0:
        result.left.add(t)
      else:
        free.add(t)
    var lifted: seq[string]
    when ApplyMutation != "recover-keeps-trigger-holds":
      # FALSIFYING MUTATION (when absent): the trigger's own hold stays,
      # and its start is skipped by it.
      for t in free:
        let h = holdPath(t, CarriedCheckHoldName, holdDir)
        if fileExists(h): lifted.add(h)
      removeHolds(lifted)
    if lifted.len > 0 and reload != nil: reload()
    for t in free:
      let failed = triggerRestarts([t], [], host)
      if failed.len > 0:
        result.left.add(t)
        result.problems.add(failed)
    recordLiveCheckTriggers(stateDir, result.left)

proc targetLeadsTo(t: string; held: openArray[string]; host: LiveHost;
                   visited: var seq[string]): bool =
  ## Whether the ``.target`` ``t`` requires or binds to one of ``held``,
  ## directly or through other targets: a target is never held itself (the
  ## owner decision "never hold .target units", A13 review round 12), so a
  ## unit that requires a refused one through a target is found through it.
  when ApplyMutation == "target-units-held":
    # Under the mutation a target is held and judged like any requirer.
    return false
  if not isTargetUnit(t) or t in visited: return false
  visited.add(t)
  var props: Table[string, string]
  try: props = host.show(t)
  except CatchableError: return false
  for key in ["Requires", "BindsTo"]:
    for d in props.getOrDefault(key).splitWhitespace():
      if heldBy(d, held) or targetLeadsTo(d, held, host, visited): return true

proc requiringRefused*(passed, refused: openArray[string]; host: LiveHost;
                       instancesOf: proc (tmpl: string): seq[string] = nil):
    seq[tuple[unit, because: string]] =
  ## The passed units that ``Requires=`` or ``BindsTo=`` a refused unit,
  ## directly or through another such unit (§13 decision 153): each stays
  ## held with the unit it requires, which the apply reports. A refused
  ## template refuses the instances it holds. A passed template is read
  ## through its instances (``instancesOf``: its observation instance and
  ## those systemd runs), never by its own name, which systemd refuses to
  ## show (A13 review round 10, finding 8): one instance that requires a
  ## refused unit keeps the template held.
  when ApplyMutation == "requirers-of-refused-released":
    # FALSIFYING MUTATION: a unit that requires a refused one is released.
    return
  var held = @refused
  var changed = true
  while changed:
    changed = false
    for u in passed:
      if heldBy(u, held): continue
      var names = @[u]
      when ApplyMutation != "template-requirer-shown-by-name" and
          defined(posix):
        # FALSIFYING MUTATION (when absent): a template is shown by name.
        if isTemplateUnit(u):
          names = @[observationInstanceOf(u)]
          if instancesOf != nil:
            for i in instancesOf(u):
              if i notin names: names.add(i)
      var hit = ""
      for n in names:
        var props: Table[string, string]
        try: props = host.show(n)
        except CatchableError: continue
        for key in ["Requires", "BindsTo"]:
          for d in props.getOrDefault(key).splitWhitespace():
            var visited: seq[string]
            if heldBy(d, held) or targetLeadsTo(d, held, host, visited):
              hit = d
        if hit.len > 0: break
      if hit.len > 0:
        result.add((unit: u, because: hit))
        held.add(u)
        changed = true

when defined(posix):
  proc liftableHolds*(passed, refused: openArray[string]; name: string;
                      dir = RuntimeUnitDir): seq[string] =
    ## The hold files of the ``passed`` units that may be removed: not one a
    ## ``refused`` unit still needs. A template's instances share one hold
    ## file (``holdPath``), so a passed instance must not lift the hold of a
    ## refused sibling.
    var kept: seq[string]
    when ApplyMutation != "shared-hold-lifted-by-passed-instance":
      # FALSIFYING MUTATION (when absent): a passed instance lifts the
      # shared hold of a refused sibling.
      for u in refused: kept.add(holdPath(u, name, dir))
    for u in passed:
      let h = holdPath(u, name, dir)
      if h notin kept and h notin result: result.add(h)

when defined(posix):
  type LiveCheck = object
    ## The carried-state cross-check of a full apply (spec §11.1, §13
    ## decision 59): the units it judges, held from before the first write
    ## until they pass, whether each was running before, and the start and
    ## restart jobs the drivers issue (§13 decision 79).
    units: seq[string]
    holds: seq[string]
    wasActive: seq[string]
    driverStarts: seq[string]
    holdStampUsec: int64   ## CLOCK_MONOTONIC (us) just before the holds
    triggers: seq[string]
      ## The socket, path and timer units of the held units, held with
      ## them (§13 decision 151): none fires while its unit is held.
    triggersActive: seq[string]
      ## Those the hold stopped (``triggersToStop``).
    requirers: seq[string]
      ## The generation's units outside ``units`` that require one of them
      ## (``profileRequirersOf``), held with them: one that requires a
      ## refused unit stays held (§13 decision 153, extended to every
      ## requirer in A13 review round 10).
    remembered: seq[string]
      ## Every one active before the hold, stopped or left alone
      ## (``rememberedTriggers``), on record in ``stateDir`` until released.
    adopted: seq[string]
      ## The units a full apply that died before its release still held
      ## (``deadApplyHeld``), adopted into this apply's held set and
      ## released after its check (the owner decision "re-hold, start after
      ## check", A13 review round 12, M3).
    adoptedActive: seq[string]
      ## Those of ``adopted`` that ran before the dead apply's hold: started
      ## after this apply's check.
    stateDir: string

  proc liveHost(): LiveHost =
    LiveHost(
      isActive: proc (u: string): bool =
        runSystemctlArgs(["is-active", "--quiet", "--", u]).exitCode == 0,
      show: proc (u: string): Table[string, string] = systemctlShow(u),
      start: proc (u: string): tuple[ok: bool, output: string] =
        let r = runSystemctlArgs(["start", "--", u])
        (r.exitCode == 0, r.output),
      stop: proc (u: string): tuple[ok: bool, output: string] =
        let r = runSystemctlArgs(["stop", "--", u])
        (r.exitCode == 0, r.output),
      resetFailed: proc (u: string) =
        discard runSystemctlArgs(["reset-failed", "--", u]),
      list: proc (pattern: string): seq[string] =
        let r = runSystemctlArgs(["list-units", "--all", "--plain",
                                  "--no-legend", "--no-pager", "--", pattern])
        if r.exitCode == 0:
          for l in r.output.splitLines():
            let w = l.splitWhitespace()
            if w.len > 0 and w[0] notin result: result.add(w[0]),
      startNoBlock: proc (u: string): tuple[ok: bool, output: string] =
        let r = runSystemctlArgs(["start", "--no-block", "--", u])
        (r.exitCode == 0, r.output))

  proc stopTriggers(c: var LiveCheck; triggers, stopping: openArray[string];
                    host: LiveHost; p: SystemProfile) =
    ## Remember every active trigger of a held unit, on record before any is
    ## stopped, and stop each that could fire at a held unit (§13 decision
    ## 151; ``rememberedTriggers``, ``triggersToStop``): a socket with a
    ## pending connection, or a path unit whose path exists, would otherwise
    ## fire at a held unit until systemd's trigger rate limit fails it for
    ## good.
    for t in rememberedTriggers(triggers, host):
      if t notin c.remembered: c.remembered.add(t)
    if c.stateDir.len > 0:
      recordLiveCheckTriggers(c.stateDir,
        readLiveCheckTriggers(c.stateDir) & c.remembered)
    for t in triggersToStop(triggers, stopping, host, triggerTargets(p)):
      if t in c.triggersActive: continue
      c.triggersActive.add(t)
      discard host.stop(t)

  proc liveCheckHoldText(): string =
    holdText(hmCondition, "Written by repro infra apply: the unit may not " &
      "start until its loaded configuration has been checked against the " &
      "carried-state reach (ReproOS Add-On Mode spec §11.1).")

  proc hostRunningInstances(tmpl: string): seq[string] =
    ## The instances of ``tmpl`` systemd has running or starting.
    let r = runSystemctlArgs(runningInstancesArgs(tmpl))
    if r.exitCode == 0: result = parseRunningInstances(tmpl, r.output)

  proc hostLoadedInstances*(pattern: string): seq[string] =
    ## The units systemd has loaded, of any state, whose names match
    ## ``pattern`` (``systemctl list-units --all``).
    let r = runSystemctlArgs(["list-units", "--all", "--plain", "--no-legend",
                              "--no-pager", "--", pattern])
    if r.exitCode != 0: return
    for l in r.output.splitLines():
      let w = l.splitWhitespace()
      if w.len > 0 and w[0] notin result: result.add(w[0])

  proc recordInterruptedLiveCheck(c: LiveCheck) =
    ## The record an interrupted full apply leaves (see ``runInfraApply``).
    if c.stateDir.len == 0 or
        (c.units.len == 0 and c.adopted.len == 0 and c.triggers.len == 0):
      return
    var all = readLiveCheckTriggers(c.stateDir)
    for t in c.remembered & c.triggersActive & c.driverStarts:
      if t in c.triggers and t notin all: all.add(t)
    try: recordLiveCheckTriggers(c.stateDir, all)
    except CatchableError: discard

  proc requirersToHold(p: SystemProfile; units: openArray[string];
                       host: LiveHost): seq[string] =
    ## The units held with the judged ``units`` (§13 decision 171): the
    ## generation's requirers, read from its files, and the loaded units
    ## systemd's effective dependencies name (``systemdRequirersOf``).
    preWriteRequirers(p, units, host)

  proc triggersToHold(p: SystemProfile; units: openArray[string];
                      host: LiveHost): seq[string] =
    ## The triggers of the held units (§13 decision 151): the profile's
    ## own, known before they are written, whatever systemd has loaded that
    ## triggers a held unit or one of a held template's instances, and a
    ## held template's loaded instance triggers, idle ones included (§13
    ## decision 152; ``templateTriggerInstances``).
    when ApplyMutation == "triggers-left-running":
      return
    if units.len == 0: return
    let names = liveJudgedNames(units, p,
      proc (t: string): seq[string] = hostRunningInstances(t))
    result = profileTriggersOf(p, units)
    for t in loadedTriggersOf(names, host):
      if t notin result: result.add(t)
    for t in templateTriggerInstances(p, units, hostLoadedInstances):
      if t notin result: result.add(t)

  proc essentialRefusal(ess: openArray[string]): ref ECarriedStatePending =
    newException(ECarriedStatePending, "ECarriedStatePending: " &
      ess.join(", ") & " would be held for the carried-state check (it is " &
      "judged, requires or binds to a unit the check judges, or triggers " &
      "one), and holding an essential unit could cut remote access to the " &
      "host or stop the add-on from repairing it; nothing was stopped or " &
      "held (§13 decisions 171 and 177 as the owner decided them)")

  proc essentialRefusalBeforeWrites*(profileText: string; dir, root: string):
      seq[string] =
    ## The essential units the carried-state check of an apply of
    ## ``profileText`` would hold, judged before the apply does anything:
    ## before the pending-switch recovery, any action edge and its plan file
    ## (A13 review round 12). ``beginLiveCheck`` judges the set it actually
    ## holds again, before it stops a trigger or writes a hold.
    let p = parseSystemProfile(profileText)
    let units = liveReachUnits(p, dir, root)
    if units.len == 0: return
    let host = liveHost()
    essentialInHoldSet(units, requirersToHold(p, units, host),
                       triggersToHold(p, units, host), host)

  proc beginLiveCheck(p: SystemProfile; dir, root, stateDir: string;
                      planned: openArray[PlannedOperation]): LiveCheck =
    ## Hold every unit ``liveReachUnits`` names before the drivers write
    ## and start anything: under the hold their ``enable --now`` and
    ## ``restart`` jobs succeed without running the unit. A full apply that
    ## died before its release left its holds: they are kept and its units
    ## and triggers adopted into this check's held set (``deadApplyHeld``;
    ## the owner decision "re-hold, start after check", A13 review round 12,
    ## M3), released after this check. A refused unit's persistent hold
    ## stays until this check passes for it. Before any trigger is stopped
    ## or hold written, the set actually held is checked for an essential
    ## unit, which refuses the apply (``essentialInHoldSet``).
    result.stateDir = stateDir
    let host = liveHost()
    # Only an elevated apply can hold anything: an unelevated one (which
    # judges nothing, or it would have been refused) leaves a dead apply's
    # holds and records for the next elevated apply.
    let dead = if isProcessElevated(): deadApplyHeld(stateDir)
               else: (units: newSeq[tuple[unit: string; wasActive: bool]](),
                      triggers: newSeq[string]())
    result.units = liveReachUnits(p, dir, root)
    for (u, a) in dead.units:
      if heldBy(u, result.units) or u in result.adopted: continue
      result.adopted.add(u)
      if a: result.adoptedActive.add(u)
    if result.units.len == 0 and result.adopted.len == 0 and
        dead.triggers.len == 0:
      return
    if result.units.len > 0:
      result.requirers = requirersToHold(p, result.units, host)
    var adopted: seq[string]
    for u in result.adopted:
      if u notin result.requirers: adopted.add(u)
    result.adopted = adopted
    result.triggers = triggersToHold(p, result.units, host)
    for t in dead.triggers:
      if t notin result.triggers: result.triggers.add(t)
    # The set actually held -- after any recovery the guard ran, and with
    # what a dead apply left -- checked before anything is stopped or held.
    let ess = essentialInHoldSet(result.units & result.adopted,
                                 result.requirers, result.triggers, host)
    if ess.len > 0: raise essentialRefusal(ess)
    for u in result.adoptedActive:
      if u notin result.wasActive: result.wasActive.add(u)
    for u in result.requirers & result.adopted:
      if isTemplateUnit(u):
        for i in hostRunningInstances(u):
          if i notin result.wasActive: result.wasActive.add(i)
      elif runSystemctlArgs(["is-active", "--quiet", "--", u]).exitCode == 0:
        if u notin result.wasActive: result.wasActive.add(u)
    for u in result.units:
      if isTemplateUnit(u):
        # A template never runs; its running instances do (§13 decision
        # 135). Their restarts are skipped under the template's hold too.
        for i in hostRunningInstances(u):
          if i notin result.wasActive: result.wasActive.add(i)
        continue
      let r = runSystemctlArgs(["is-active", "--quiet", "--", u])
      if r.exitCode == 0: result.wasActive.add(u)
    result.driverStarts = driverStartJobs(planned,
      proc (u: string): bool =
        runSystemctlArgs(["is-active", "--quiet", "--", u]).exitCode == 0)
    # The units held, on record before the first hold (``LiveCheckUnitsFile``):
    # an apply that dies before its release leaves them for the next one.
    var onRecord: seq[tuple[unit: string; wasActive: bool]]
    for u in result.units & result.requirers & result.adopted:
      onRecord.add((unit: u, wasActive: u in result.wasActive))
    recordLiveCheckUnits(stateDir, onRecord)
    # The dead apply's triggers it stopped are down now: remembered, so the
    # release starts them after this check.
    for t in dead.triggers:
      if t notin result.remembered: result.remembered.add(t)
    # Each trigger is stopped if it runs and could fire at a held unit, and
    # held with its unit, so the drivers' ``enable --now`` of a trigger does
    # not start it either.
    when ApplyMutation != "triggers-left-running":
      # The running units this apply restarts under the hold: their
      # triggers could fire once the restart's stop half has run.
      var stopping: seq[string]
      for u in result.driverStarts:
        if host.isActive(u): stopping.add(u)
      stopTriggers(result, result.triggers, stopping, host, p)
    result.holdStampUsec = getMonoTime().ticks div 1000
    result.holds = writeHolds(result.units & result.requirers &
                              result.adopted & result.triggers,
                              CarriedCheckHoldName, liveCheckHoldText())
    systemctlOrRaise(["daemon-reload"])

  proc finishLiveCheck(c: var LiveCheck; p: SystemProfile; dir, root: string;
                       judged: var seq[string]): seq[string] =
    ## After the privileged set: reload, judge each held unit as systemd
    ## loaded it (``liveReachProblems``, the add-on switch's own check), and
    ## either release and start what should run, or keep the refused units
    ## held -- in ``/etc`` too, so a reboot does not start them -- and
    ## report each as a problem of this apply. ``c`` is the caller's own,
    ## so a trigger this release stops is in what an interruption records
    ## (A13 review round 12: a copy hid them).
    if c.units.len == 0 and c.adopted.len == 0 and c.triggers.len == 0:
      return
    systemctlOrRaise(["daemon-reload"])
    let host = liveHost()
    when ApplyMutation != "triggers-left-running":
      # A trigger systemd loaded only now (a host unit the generation's
      # writes linked to a held unit) is stopped too, unheld: it is
      # started again with the others once the check passes.
      let names = liveJudgedNames(c.units, p,
        proc (t: string): seq[string] = hostRunningInstances(t))
      for t in loadedTriggersOf(names, host):
        if t notin c.triggers:
          c.triggers.add(t)
          stopTriggers(c, [t], [], host, p)
    var problems: seq[string]
    when not LiveCheckSkipped:
      # One reading of each template's running instances serves both the
      # check and the report of what it judged.
      var runningSeen = initTable[string, seq[string]]()
      let running = proc (t: string): seq[string] =
        if t notin runningSeen: runningSeen[t] = hostRunningInstances(t)
        runningSeen[t]
      judged = liveJudgedNames(c.units, p, running)
      problems = liveReachProblems(c.units, p,
        proc (u: string): Table[string, string] = systemctlShow(u), root,
        running)
      # And the refusal again over the host as the reload left it: a
      # drop-in a generator made at a reload of this apply is read now.
      when ApplyMutation != "post-reload-refusal-skipped":
        let why = carriedStateRefusal(p, dir, root)
        if why.len > 0: problems.add(why & " (decided again after the reload)")
    var refused = refusedUnits(c.units, problems)
    var passed: seq[string]
    for u in c.units:
      if u notin refused: passed.add(u)
    # The generation's units that require a judged one were held with them
    # and one that requires a refused unit stays held (§13 decision 153,
    # every requirer): they go with the units they require.
    for u in c.requirers:
      if u notin passed: passed.add(u)
    # A dead apply's units, adopted (M3), go with them: one that requires a
    # refused unit stays held with it.
    for u in c.adopted:
      if u notin passed: passed.add(u)
    # §13 decision 153: a passed unit that requires a refused one stays
    # held with it, and is reported so.
    if refused.len > 0:
      for (u, because) in requiringRefused(passed, refused, host,
          proc (t: string): seq[string] = hostRunningInstances(t)):
        refused.add(u)
        problems.add("ECarriedStatePending: " & u & " requires " & because &
          ", which the carried-state check refused; held because of it")
      # And a unit systemd's effective dependencies name as requiring a
      # refused one that was not held with the judged units -- one the
      # generation's writes made a requirer (§13 decision 171): held now,
      # in /etc, and stopped if a driver started it; an essential one is
      # reported, not held.
      let late = postReloadRequirers(refused, c.units & c.requirers, host)
      for u in late.essential:
        problems.add("ECarriedStatePending: " & u & " requires a unit " &
          "the carried-state check refused, and is essential, so it is " &
          "not held; the apply reports it")
      for u in late.hold:
        refused.add(u)
        discard writeHolds([u], CarriedCheckHoldName, liveCheckHoldText(),
                           RuntimeUnitDir)
        if host.isActive(u) and host.stop != nil: discard host.stop(u)
        problems.add("ECarriedStatePending: " & u & " requires a unit the " &
          "carried-state check refused; held because of it")
      var still: seq[string]
      for u in passed:
        if u notin refused: still.add(u)
      passed = still
    # The triggers of a refused unit stay held with it; the rest go.
    var refusedTriggers: seq[string]
    for t in c.triggers:
      var targets: seq[string]
      try: targets = triggeredUnits(host.show(t))
      except CatchableError: discard
      for (pt, target) in triggerTargets(p):
        if pt == t and target notin targets: targets.add(target)
      for u in targets:
        if heldBy(u, refused) and t notin refusedTriggers:
          refusedTriggers.add(t)
    # A refused unit stays held -- in ``/etc`` too, so a reboot does not
    # start it -- and is reported as a problem of this apply. The units
    # that passed are released and started all the same: one refusal does
    # not keep the rest down until the next apply or boot (§11.1).
    if refused.len > 0:
      discard writeHolds(refused & refusedTriggers, CarriedCheckHoldName,
                         liveCheckHoldText(), PersistentUnitDir)
      for pr in problems:
        result.add(pr & "; the unit is held (not started) until an apply " &
          "whose check it passes")
    # Read before the holds are lifted: which triggers fired under them.
    # §13 decision 152: every trigger of a held unit, not only those the
    # drivers started.
    let fired = firedUnderHold(fireSources(c.driverStarts, c.triggers),
                               c.units, refused, host, c.holdStampUsec)
    # One hold covers every instance of a template: it stays while any
    # instance it covers is refused, in ``/run`` and in ``/etc`` alike.
    var passedTriggers: seq[string]
    for t in c.triggers:
      if t notin refusedTriggers: passedTriggers.add(t)
    var lifted: seq[string]
    for h in liftableHolds(passed & passedTriggers, refused & refusedTriggers,
                           CarriedCheckHoldName):
      if h in c.holds: lifted.add(h)
    removeHolds(lifted)
    # A unit this check did not judge -- adopted from a dead apply, not one
    # of this generation's requirers -- keeps a hold in ``/etc`` an earlier
    # check's refusal wrote: only a check that passes it lifts that.
    var judgedPassed: seq[string]
    for u in passed:
      if u notin c.adopted or u in c.requirers: judgedPassed.add(u)
    var persistent: seq[string]
    for h in liftableHolds(judgedPassed & passedTriggers,
                           refused & refusedTriggers,
                           CarriedCheckHoldName, PersistentUnitDir):
      if fileExists(h): persistent.add(h)
    removeHolds(persistent)
    systemctlOrRaise(["daemon-reload"])
    # §13 decision 151: every trigger of a passed unit comes back up --
    # those stopped for the hold, and those the drivers started (an enabled
    # trigger's ``enable --now``, skipped by its hold) -- before the units
    # start, so a socket-activated service is handed its socket.
    # Every trigger remembered as active, a trigger left alone that went
    # down during the hold included, and each that does not start again
    # stays on record for the next apply or `recover` (finding 5).
    let restart = triggersToRelease(c.remembered, c.triggersActive,
                                    c.driverStarts, c.triggers)
    var unstarted: seq[string]
    for t in restart:
      let failed = triggerRestarts([t], refusedTriggers, host)
      if failed.len > 0:
        unstarted.add(t)
        result.add(failed)
    if c.stateDir.len > 0:
      var left: seq[string]
      for t in readLiveCheckTriggers(c.stateDir):
        if t in unstarted or t notin c.remembered:
          left.add(t)
      recordLiveCheckTriggers(c.stateDir, left)
    result.add(releaseStarts(p, c.units, passed, refused, c.wasActive,
                             c.driverStarts, fired, host))
    # A dead apply's unit that ran before its hold starts now, after this
    # check, confirmed through systemd (M3; ``startConfirmed``).
    for u in c.adoptedActive:
      if u notin passed or u in refused or host.isActive(u): continue
      let s = startConfirmed(host, u, mustStayActive = false)
      if not s.ok:
        result.add("systemctl start " & u & " (held by a full apply that " &
          "died before its release, started after this apply's carried-" &
          "state check): " & s.why)
    if c.stateDir.len > 0: recordLiveCheckUnits(c.stateDir, [])
    for t in refusedTriggers:
      result.add("ECarriedStatePending: " & t & " stays stopped: it " &
        "triggers a unit the carried-state check refused")

proc recordComparisonProfile*(writtenText, appliedText: string): SystemProfile =
  ## What a full apply's generation is compared with the record of triggers
  ## to restart as, at its fixing starts and its commit (§13 decision 175
  ## as amended in A13 review round 12): the generation as its author wrote
  ## it (``writtenText``), never the text the apply runs (``appliedText``),
  ## which ``withCarriedRequirements`` extends with a drop-in on every unit
  ## that reaches carried state -- that drop-in alone would "change" the
  ## unit and resolve its entry. The guard compares the written text too.
  when ApplyMutation == "full-apply-renders-full-profile":
    # FALSIFYING MUTATION: the applied text, carried-state requirements
    # included, is compared.
    return parseSystemProfile(appliedText)
  parseSystemProfile(writtenText)

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
  ##
  ## The whole apply holds the host-wide apply lock
  ## (``repro_core/host_apply_lock``): the per-state-directory lock above
  ## does not stop a second apply that uses another state directory, and
  ## the deploy agent's tick reaches this proc without taking it at all.
  var hostLock = acquireHostApplyLock("repro infra apply (state " &
    opts.stateDir & ")", privileged = isProcessElevated())
  defer: hostLock.release()
  # Before anything at all -- the pending-switch recovery, any action edge,
  # the plan file: an essential unit the carried-state check would hold --
  # judged, a trigger, or a requirer held with the judged units (§13
  # decisions 171 and 177 as the owner decided them; A13 review round 12)
  # -- refuses the apply. ``beginLiveCheck`` checks the set it actually
  # holds again, before it stops or holds anything.
  when defined(posix):
    let essDir = if opts.carriedStateDir.len > 0: opts.carriedStateDir
                 else: CarriedStateDir
    let essRoot = if opts.carriedStateRoot.len > 0: opts.carriedStateRoot
                  else: "/"
    if not opts.carriedStateChecked and opts.elevationMode != emNoElevate and
        essRoot == "/" and isProcessElevated():
      let ess = essentialRefusalBeforeWrites(
        withCarriedRequirements(profileText, essDir, essRoot), essDir, essRoot)
      if ess.len > 0: raise essentialRefusal(ess)
  # Before any mutation: an add-on switch interrupted on this host (its
  # pending marker present, its owner gone) is recovered first, under the
  # lock this apply already holds, and the apply refuses if it cannot be.
  # Applying on top of a half switch would bury it; the deploy agent would
  # otherwise keep doing exactly that until the next boot.
  if pendingSwitchGuard != nil:
    let g = pendingSwitchGuard(opts.stateDir, parseSystemProfile(profileText),
                               not opts.carriedStateChecked)
    if not g.ok:
      raise newException(EPendingSwitch, "an interrupted add-on switch " &
        "is pending on this host and recovery did not resolve it; " &
        "refusing to apply on top of it: " & g.why)
  # Before any mutation: carried state a conversion brought must be
  # restored before anything that can reach it is applied, nothing is
  # applied while a state backup holds the host, and carried owners must
  # keep their ids (ReproOS Add-On Mode §11.1). Here, in the library every
  # apply path reaches (`repro infra apply`, `repro system sync`, `repro
  # system rollback`, the engine's deploy agent), so no entry point skips
  # it.
  when defined(posix):
    if not opts.carriedStateChecked:
      requireCarriedStateReady(parseSystemProfile(profileText),
        (if opts.carriedStateDir.len > 0: opts.carriedStateDir
         else: CarriedStateDir),
        (if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"))
  # While carried state is installed, every unit that reaches it requires
  # the first-boot restore through a drop-in this generation writes
  # (spec §11.1; A13 review round 4, finding 4). An add-on apply has added
  # them to its own profile already (``carriedStateChecked``).
  # The generation as its author wrote it, before the carried-state
  # requirements: what the record of triggers to restart is compared with,
  # at the guard, the fixing starts and the commit alike (A13 review round
  # 12, M2) -- the requirements' drop-ins alone would otherwise "change" a
  # unit that reaches carried state and resolve its entry.
  let recordText = profileText
  let profileText =
    when defined(posix):
      if opts.carriedStateChecked: profileText
      else: withCarriedRequirements(profileText,
        (if opts.carriedStateDir.len > 0: opts.carriedStateDir
         else: CarriedStateDir),
        (if opts.carriedStateRoot.len > 0: opts.carriedStateRoot else: "/"))
    else: profileText
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

  # Drop-ins an earlier generation declared and this profile does not: the
  # apply removes them (planned as destroys, dispatched below).
  # An add-on apply (``carriedStateChecked``) removes what its ledger no
  # longer owns in its own switch, so it is not asked here.
  let undeclared = if opts.carriedStateChecked: newSeq[SystemResource]()
                   else: undeclaredDropIns(opts.stateDir, profileText)
  # --- 1. Resolve the plan. ---
  var env: PlanEnvelope
  if opts.planId.len > 0:
    env = readPlanFile(planPath(opts.stateDir, opts.planId))
    # The plan is one host's: its id and the generation this apply commits
    # derive from the host identity, so applying another host's plan -- or
    # one recorded under the pre-unification identity rule -- would commit a
    # generation whose plan names a different host. Refused before anything
    # is touched; a fresh plan is cheap.
    if env.hostIdentity != opts.hostIdentity:
      raisePlanHostMismatch(opts.planId, env.hostIdentity, opts.hostIdentity)
    # The plan must be of the very text this apply runs: the carried-state
    # requirements are added at apply time (``withCarriedRequirements``),
    # so a host whose reach changed since the plan -- install-unit, a host
    # drop-in -- applies a different text, which a stored plan would
    # silently not write (A13 review round 5, finding 4).
    when ApplyMutation != "plan-ignores-profile-digest":
      if env.profileDigestHex != digestProfileText(profileText):
        raisePlanProfileChanged(opts.planId, "the profile text this apply " &
          "runs (with the carried-state requirements this host needs now) " &
          "is not the text the plan was made from")
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
                            destroyResources: undeclared,
                            acceptDrift: false))
    env = fresh.envelope
    # Persist the fresh plan so the apply is auditable by id.
    writePlanFile(planPath(opts.stateDir, env.planId), env)
  result.planId = env.planId
  refreshApplyLock(opts.stateDir)
  # A layered apply's work between the plan and the first write (the
  # add-on switch's realise, pre-stop and flip steps). A raise here leaves
  # the plan on disk and nothing else touched.
  if opts.phases.beforePrivilegedSet != nil:
    opts.phases.beforePrivilegedSet(env.planId)
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
  # digest is the resource's live observed state, so it travels the
  # same wire shape as a planned operation (the broker does not consult
  # the baseline). An already-reverted resource
  # (observe says absent) is dispatched as a destroy no-op.
  var destroys: seq[PlannedOperation]
  var destroyed: seq[string]
  for r in opts.extraDestroyResources & undeclared:
    if r.address in destroyed: continue
    destroyed.add(r.address)
    let obs = observeResource(r)
    destroys.add(PlannedOperation(
      operation: toPrivilegedOperation(r, destroy = true),
      baselineDigestHex: obs.observedDigestHex))
  if opts.destroysFirst:
    planned = destroys & planned
  else:
    planned.add(destroys)

  let partition = partitionApply(
    block:
      var ops: seq[PrivilegedOperation]
      for p in planned: ops.add(p.operation)
      ops,
    nonPrivilegedOperationCount = 0)
  refreshApplyLock(opts.stateDir)

  # The carried-state cross-check (§13 decision 59): the units it judges
  # are held from here until they pass it, as in the add-on's switch.
  # An add-on apply runs it in its own switch (``carriedStateChecked``).
  when defined(posix):
    let liveDir = if opts.carriedStateDir.len > 0: opts.carriedStateDir
                  else: CarriedStateDir
    let liveRoot = if opts.carriedStateRoot.len > 0: opts.carriedStateRoot
                   else: "/"
    var liveCheck: LiveCheck
    var liveCheckFinished = false
    # An apply that dies between its hold and its release (a driver or the
    # broker raises) leaves on record every trigger the release would have
    # started -- those remembered before the hold and those the drivers
    # started under it -- for the next apply or `recover` (A13 review round
    # 11, H1), with the units it held (``LiveCheckUnitsFile``). The holds
    # stay: the next full apply adopts them (round 12, M3).
    defer:
      if not liveCheckFinished:
        recordInterruptedLiveCheck(liveCheck)
    # The triggers and units an earlier full apply held and never released
    # -- it died between the two -- are adopted by this apply's check
    # (``beginLiveCheck``) and started after it, their holds kept (the owner
    # decision "re-hold, start after check", A13 review round 12, M3). An
    # add-on apply runs no such check: it releases only the recorded
    # triggers whose units are not held, as `recover` does
    # (``releaseRecordedTriggers``); a held unit waits for a full apply.
    if opts.elevationMode != emNoElevate and liveRoot == "/" and
        fileExists(opts.stateDir / LiveCheckTriggersFile) and
        isProcessElevated():
      when ApplyMutation == "dead-apply-holds-lifted":
        # FALSIFYING MUTATION: round 11's order -- every hold the dead apply
        # left is cleared and its triggers started before this apply's
        # check (``deadApplyHeld`` adopts nothing under it).
        try:
          if clearStaleHolds(CarriedCheckHoldName).len > 0:
            systemctlOrRaise(["daemon-reload"])
        except OSError: discard
        for pr in restartRecordedLiveCheckTriggers(opts.stateDir, liveHost()):
          result.diagnostics.add(pr)
      else:
        if opts.carriedStateChecked:
          let r = releaseRecordedTriggers(opts.stateDir, liveHost(),
            reload = proc () = systemctlOrRaise(["daemon-reload"]))
          for pr in r.problems: result.diagnostics.add(pr)
    # Only on the live host: a scratch root (a library test) has no systemd
    # of its own to ask.
    if not opts.carriedStateChecked and opts.elevationMode != emNoElevate and
        liveRoot == "/":
      let pLive = parseSystemProfile(profileText)
      if not isProcessElevated() and
          liveReachUnits(pLive, liveDir, liveRoot).len > 0:
        raise newException(ECarriedStatePending, "ECarriedStatePending: " &
          "carried state is on this host, so the units that can reach it " &
          "are held and checked as systemd loads them before they start " &
          "(spec §11.1); that needs the apply itself to run as root")
      liveCheck = beginLiveCheck(pLive, liveDir, liveRoot, opts.stateDir,
                                 planned)

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
        FixtureContext(addOn: opts.addOnDispatch), planned, onProgress = beat,
        preWriteGuard = opts.preWriteGuard)
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

  for d in outcome.results:
    if d.driftDetected or (not d.ok and "requires elevation" notin
        d.diagnostic):
      result.diagnostics.add(d.operationAddress & ": " & d.diagnostic)

  when defined(posix):
    for pr in finishLiveCheck(liveCheck, parseSystemProfile(profileText),
                              liveDir, liveRoot, result.liveJudged):
      inc result.errorCount
      result.diagnostics.add(pr)
    liveCheckFinished = true

  # The fixing path of a full apply (the owner decision "yes, same as 175",
  # A13 review round 12, M2): what its generation resolves of the record of
  # triggers to restart is started, each confirmed through systemd, before
  # the commit; one that does not start is an error of the apply, and the
  # record keeps it. An add-on apply starts them in its own switch.
  # (Its falsifier, ``full-apply-fixing-skips-starts``, is in the add-on
  # layer's ``fullApplyStartResolved``.)
  if pendingSwitchStartResolved != nil and not opts.carriedStateChecked and
      opts.elevationMode != emNoElevate:
    for pr in pendingSwitchStartResolved(opts.stateDir,
                                         recordComparisonProfile(recordText,
                                                                 profileText)):
      inc result.errorCount
      result.diagnostics.add(pr)

  # --- 4. Commit the generation + write the audit log. ---
  var commitTs = getTime().toUnix()
  let previousGenerationId = readCurrentGenerationId(opts.stateDir)
  let generationId = allocateGenerationId(opts.stateDir,
    env.profileDigestHex, opts.hostIdentity, previousGenerationId, commitTs)
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
  # A layered apply's work between the last write and the commit (the
  # add-on switch's fragment tools, service starts, confirmation and
  # ledger). Its diagnostics are errors of this apply.
  var clean = result.errorCount == 0 and result.driftCount == 0
  if opts.phases.afterPrivilegedSet != nil:
    let problems = opts.phases.afterPrivilegedSet(generationId, clean)
    for p in problems:
      inc result.errorCount
      result.diagnostics.add(p)
    clean = clean and problems.len == 0
    refreshApplyLock(opts.stateDir)
  if opts.phases.commitOnlyWhenClean and not clean:
    # The attempt is on disk for audit (its log, under its id) but it is
    # not a generation: no envelope, and `current` stays where it was.
    result.committed = false
    result.diagnostics.add("generation " & generationId & " was NOT " &
      "committed: the apply did not complete cleanly, so `current` still " &
      "names " & (if previousGenerationId.len > 0: previousGenerationId
                  else: "no generation"))
    refreshApplyLock(opts.stateDir)
    return
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
      noOpCount: result.noOpCount,
      previousGenerationId: previousGenerationId))
  # The generation pointer / `current` marker is updated by the
  # NON-elevated parent (this proc), never the broker.
  if opts.phases.commitPoint != nil:
    opts.phases.commitPoint("commit-envelope")
  writeCurrentGenerationId(opts.stateDir, generationId,
    onPoint = (if opts.phases.commitPoint != nil:
                 proc(p: string) = opts.phases.commitPoint(p)
               else: nil))
  result.committed = true
  discard refreshApplyLock(opts.stateDir)
  # An add-on switch clears what it resolves at its own commit; any other
  # committed apply here.
  if pendingSwitchCommitted != nil and not opts.carriedStateChecked:
    pendingSwitchCommitted(opts.stateDir,
      recordComparisonProfile(recordText, profileText),
      clean = result.errorCount == 0 and result.driftCount == 0)
