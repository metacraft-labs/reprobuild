## System-scope rollback safety checks (M69 — the
## `--accept-feature-destroy` gate).
##
## Per System-Profile-And-Infra-Apply.md "Rollback", system-scope
## rollback is extra-conservative:
##
##   * a rollback that would disable a Windows Optional Feature or
##     uninstall a Capability requires `--accept-feature-destroy`
##     (symmetric with `--accept-passwd-destroy` for `passwd.user`);
##   * drift on rollback always requires explicit confirmation.
##
## M69 Phase A applies a hand-authored `system.nim`; the full
## generation-rollback engine (mirroring home rollback) is part of
## the deferred `repro system rollback` family. What Phase A pins
## down — and what this module provides — is the SAFETY GATE: given a
## set of resources a rollback would revert, decide whether
## `--accept-feature-destroy` is required and, if it is and the flag
## is absent, fail closed with `EFeatureDestroy` BEFORE any mutation.

import ./apply
import ./errors
import ./gen_envelope
import ./planner
import ./profile
import ./state_dir

type
  RollbackSafetyDecision* = object
    ## The outcome of screening a rollback for destructive operations.
    requiresFeatureDestroyFlag*: bool
    destructiveAddresses*: seq[string]
      ## The resources whose rollback would disable a feature /
      ## uninstall a capability.
    requiresPasswdDestroyFlag*: bool
    passwdDestroyAddresses*: seq[string]
      ## The `passwd.user` resources whose rollback would REMOVE a
      ## user account — gated by `--accept-passwd-destroy`.

proc screenRollback*(reverted: openArray[SystemResource]):
    RollbackSafetyDecision =
  ## Screen the resources a rollback would revert. A
  ## `windows.optionalFeature` / `windows.capability` /
  ## `windows.vsInstaller` revert is destructive (it disables /
  ## uninstalls) — `--accept-feature-destroy`. A `passwd.user` revert
  ## REMOVES a user account — the separate `--accept-passwd-destroy`
  ## gate. Everything else (registry value, service config, a
  ## system-file delete, an env-var contribution withdrawal) is
  ## non-destructive in this sense.
  for r in reverted:
    if isDestructiveRollback(r):
      result.requiresFeatureDestroyFlag = true
      result.destructiveAddresses.add(r.address)
    if requiresPasswdDestroy(r):
      result.requiresPasswdDestroyFlag = true
      result.passwdDestroyAddresses.add(r.address)

proc enforceFeatureDestroyGate*(decision: RollbackSafetyDecision;
                                acceptFeatureDestroy: bool) =
  ## Fail closed when the rollback is destructive and the operator
  ## did not pass `--accept-feature-destroy`. Raises `EFeatureDestroy`
  ## naming the FIRST destructive operation. Called BEFORE any
  ## mutation, so a refused rollback touches nothing.
  if decision.requiresFeatureDestroyFlag and not acceptFeatureDestroy:
    raiseFeatureDestroy(
      if decision.destructiveAddresses.len > 0:
        decision.destructiveAddresses[0]
      else:
        "<unknown>")

proc enforcePasswdDestroyGate*(decision: RollbackSafetyDecision;
                               acceptPasswdDestroy: bool) =
  ## Fail closed when the rollback would remove a user account and
  ## the operator did not pass `--accept-passwd-destroy`. Raises
  ## `EPasswdDestroy` naming the FIRST `passwd.user` destroy. Called
  ## BEFORE any mutation — the symmetric counterpart of
  ## `enforceFeatureDestroyGate`.
  if decision.requiresPasswdDestroyFlag and not acceptPasswdDestroy:
    raisePasswdDestroy(
      if decision.passwdDestroyAddresses.len > 0:
        decision.passwdDestroyAddresses[0]
      else:
        "<unknown>")

# ===========================================================================
# `repro system rollback` — the M64 home-rollback analogue at system
# scope (M69 Phase B).
#
# A system rollback re-applies a PRIOR generation's `system.nim`. The
# RBSG generation envelope embeds the profile text the generation
# applied (the system state dir has no CAS), so rollback is: resolve
# the target generation, screen the revert for destructive operations
# (`--accept-feature-destroy`), screen for live drift (system-scope
# rollback ALWAYS confirms drift, per the spec), then drive the same
# `runInfraApply` path with the target profile text.
#
# This is parameterized by the SYSTEM state dir. The M62/M64 home
# machinery is NOT reused: it is wired to the home CAS, the
# `PointerEnvelope`/`ActivationManifest` pair, launchers and stow —
# none of which exist at system scope (the system state dir is the
# deliberately slim shape the spec mandates). A small system-scope
# implementation on the RBSG envelope is the honest fit.
# ===========================================================================

type
  SystemRollbackOptions* = object
    stateDir*: string
    hostIdentity*: string
    reproExe*: string
    targetGenerationId*: string        ## "" => the immediately-previous one
    acceptFeatureDestroy*: bool
    acceptPasswdDestroy*: bool
    reconcileDrift*: bool
    forceBroker*: bool

  SystemRollbackOutcome* = object
    fromGenerationId*: string
    toGenerationId*: string
    appliedCount*: int
    noOpCount*: int
    driftedAddresses*: seq[string]
    apply*: ApplyResult

proc resourcesRemovedByRollback*(activeProfileText,
                                 targetProfileText: string):
    seq[SystemResource] =
  ## The resources the active generation declares that the rollback
  ## target does NOT — rolling back reverts (destroys) them. Used to
  ## screen for the `--accept-feature-destroy` gate.
  let active = parseSystemProfile(activeProfileText)
  let target = parseSystemProfile(targetProfileText)
  var targetAddrs: seq[string]
  for r in target.resources:
    targetAddrs.add(r.address)
  for r in active.resources:
    if r.address notin targetAddrs:
      result.add(r)

proc detectRollbackDrift*(targetProfileText: string): seq[string] =
  ## Re-observe every resource the target generation declares and
  ## return the addresses whose LIVE state matches neither absent nor
  ## the target's desired value — i.e. the world drifted out of band
  ## since the target generation was applied. System-scope rollback
  ## ALWAYS requires explicit confirmation on drift (the spec's extra
  ## conservatism), so the caller surfaces this list.
  let target = parseSystemProfile(targetProfileText)
  for r in target.resources:
    let obs = observeResource(r)
    let op = toPrivilegedOperation(r)
    let desired = desiredDigestForKind(op)
    # Absent or already-at-desired is consistent; anything else is
    # drift the operator must acknowledge.
    if obs.present and obs.observedDigestHex != desired:
      result.add(r.address)

proc runSystemRollback*(opts: SystemRollbackOptions): SystemRollbackOutcome =
  ## Roll the system profile back to a prior generation. Re-applies
  ## the target generation's embedded `system.nim` through the Phase-A
  ## `runInfraApply` path.
  ##
  ## Safety, per System-Profile-And-Infra-Apply.md "Rollback":
  ##   * a rollback that would disable a feature / uninstall a
  ##     capability / uninstall VS needs `--accept-feature-destroy`;
  ##   * drift on rollback ALWAYS needs explicit confirmation, even
  ##     with `--reconcile-drift` — without `--reconcile-drift` the
  ##     rollback refuses, naming the drifted resources.
  let activeId = readCurrentGenerationId(opts.stateDir)
  if activeId.len == 0:
    raiseSystemStateDirInvalid(
      "no active system generation to roll back from")
  result.fromGenerationId = activeId
  let targetId = resolveGenerationId(opts.stateDir, opts.targetGenerationId)
  result.toGenerationId = targetId
  if targetId == activeId:
    raiseSystemStateDirInvalid(
      "the rollback target generation '" & targetId &
      "' is already the active generation")
  let targetEnv = readGenerationEnvelope(
    pointerPath(opts.stateDir, targetId))
  let activeEnv = readGenerationEnvelope(
    pointerPath(opts.stateDir, activeId))

  # --- Destructive-revert screening (`--accept-feature-destroy` +
  #     `--accept-passwd-destroy`). Both gates run BEFORE any
  #     mutation; a refused rollback touches nothing. ---
  let reverted = resourcesRemovedByRollback(
    activeEnv.profileText, targetEnv.profileText)
  let decision = screenRollback(reverted)
  enforceFeatureDestroyGate(decision, opts.acceptFeatureDestroy)
  enforcePasswdDestroyGate(decision, opts.acceptPasswdDestroy)

  # --- Drift screening — system-scope rollback always confirms. ---
  let drifted = detectRollbackDrift(targetEnv.profileText)
  result.driftedAddresses = drifted
  if drifted.len > 0 and not opts.reconcileDrift:
    raisePlanStale(targetId, drifted)

  # --- Re-apply the target generation's profile, AND actively revert
  #     every resource the active generation added that the target
  #     does not declare. Both halves run in ONE apply so the rollback
  #     raises at most one elevation prompt. ---
  var applyOpts: ApplyOptions
  applyOpts.stateDir = opts.stateDir
  applyOpts.hostIdentity = opts.hostIdentity
  applyOpts.reproExe = opts.reproExe
  applyOpts.planId = ""                 # fresh plan of the target profile
  applyOpts.elevationMode = emBroker
  applyOpts.forceBroker = opts.forceBroker
  applyOpts.noPreview = true
  applyOpts.extraDestroyResources = reverted
  result.apply = runInfraApply(targetEnv.profileText, applyOpts)
  result.appliedCount = result.apply.appliedCount
  result.noOpCount = result.apply.noOpCount
