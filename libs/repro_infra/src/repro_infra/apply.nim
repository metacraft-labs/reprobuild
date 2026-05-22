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

import ./audit_log
import ./errors
import ./gen_envelope
import ./plan_envelope
import ./planner
import ./profile
import ./state_dir

type
  ElevationMode* = enum
    ## How the apply handles privileged operations.
    emBroker = "broker"               ## default: one broker, one prompt
    emNoElevate = "noElevate"         ## --no-elevate: skip privileged ops

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
    auditLogPath*: string
    diagnostics*: seq[string]

# ---------------------------------------------------------------------------
# A trivial per-host apply lock (file presence). Concurrent system
# applies are serialized through `<state-dir>/locks/apply.lock` per
# the spec's validation criterion.
# ---------------------------------------------------------------------------

proc acquireApplyLock*(stateDir: string): bool =
  ## Returns true when the lock was acquired. The lock file holds the
  ## PID; a stale lock from a dead process is reclaimed.
  ensureSystemStateDir(stateDir)
  let lockPath = applyLockPath(stateDir)
  if fileExists(lockPath):
    return false
  writeFile(lockPath, $getCurrentProcessId())
  true

proc releaseApplyLock*(stateDir: string) =
  let lockPath = applyLockPath(stateDir)
  if fileExists(lockPath):
    try: removeFile(lockPath) except OSError: discard

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

proc writeAuditRecords(logPath: string;
                       applyLog: seq[ApplyLogRecord];
                       noOps: seq[PlannedOperationRecord]) =
  let ts = getTime().toUnix()
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
      restartNeeded: false))
  for rec in applyLog:
    appendAuditRecord(logPath, AuditRecord(
      timestamp: ts,
      operationKind: rec.operationKind,
      resourceAddress: rec.operationAddress,
      outcome: rec.outcome,
      diagnostic: (if rec.outcome in ["drift", "error"]: rec.detail else: ""),
      preDigestHex: rec.preWriteDigestHex,
      postDigestHex: rec.postWriteDigestHex,
      restartNeeded: rec.restartNeeded))

# ---------------------------------------------------------------------------
# The apply.
# ---------------------------------------------------------------------------

proc runInfraApply*(profileText: string; opts: ApplyOptions): ApplyResult =
  ## Drive a full `repro infra apply`. The caller has already loaded
  ## the `system.nim` text and resolved `opts`.
  ##
  ## Steps:
  ##   1. resolve the plan — by id (with stale-detection) or fresh.
  ##   2. partition the effective operations.
  ##   3. apply: already-elevated fast path | one broker | skip.
  ##   4. write the RBSL audit log + commit the generation pointer.
  resetBrokerLaunchCount()

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
    let fresh = producePlan(profileText, opts.hostIdentity)
    env = fresh.envelope
    # Persist the fresh plan so the apply is auditable by id.
    writePlanFile(planPath(opts.stateDir, env.planId), env)
  result.planId = env.planId

  # --- 2. Partition the effective operations. ---
  var planned = plannedOperationsFor(profileText, env)
  var noOps: seq[PlannedOperationRecord]
  for rec in env.operations:
    if rec.action == "no-op":
      noOps.add(rec)
  result.noOpCount = noOps.len

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

  # --- 3. Apply the privileged set. ---
  var outcome: PrivilegedApplyOutcome
  if not partition.hasPrivilegedWork():
    # Nothing privileged: no broker, no prompt.
    result.usedBroker = false
  elif opts.elevationMode == emNoElevate:
    # --no-elevate: apply the non-privileged subset (none, for a
    # pure-Windows profile) and report every privileged op skipped.
    outcome = reportPrivilegedSetSkipped(planned)
    result.usedBroker = false
  else:
    let alreadyElevated = isProcessElevated()
    if alreadyElevated and not opts.forceBroker:
      # Already-elevated fast path: run the privileged set in-process,
      # no broker, no prompt.
      outcome = applyPrivilegedSetInProcess(
        FixtureContext(), planned)
      result.usedBroker = false
    else:
      # Launch EXACTLY ONE broker. A declined prompt is equivalent to
      # --no-elevate (a clean partial result, not a crash).
      try:
        let brokerApply = launchAndDriveBroker(opts.reproExe, planned)
        outcome = brokerApply.outcome
        result.usedBroker = true
      except EElevationDeclined:
        outcome = reportPrivilegedSetSkipped(planned)
        result.diagnostics.add(
          "the elevation prompt was declined; privileged operations " &
          "were skipped (equivalent to --no-elevate)")
        result.usedBroker = false
  result.brokerLaunchCount = brokerLaunchCount()

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
  writeAuditRecords(logPath, outcome.applyLog, noOps)
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
  for d in outcome.results:
    if d.driftDetected or (not d.ok and "requires elevation" notin
        d.diagnostic):
      result.diagnostics.add(d.operationAddress & ": " & d.diagnostic)
