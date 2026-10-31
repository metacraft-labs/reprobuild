## ``repro system rollback`` on an add-on host (ReproOS Add-On Mode §7.5).
##
## A rollback re-applies a retained generation through the same switch as
## any apply (§7.2): the generation's own copies of the profiles it
## applied (``generations/<id>/addon-{own,user}.profile``) are applied as
## a new generation, with the system-scope conservatism every add-on apply
## already has -- an object that changed out of band is drift and refuses
## the rollback unless ``--reconcile-drift`` is given. Because it is an
## ordinary switch, a rollback is itself crash-consistent, confirmed by
## the target's health checks, and reverted if it cannot complete.
##
## The rollback floor of §7.5 (a signed manifest naming the oldest
## generation an automatic revert may return to) belongs to the deploy
## agent's manifest format and is not part of this operator command.

import std/os

import repro_infra

import ./addon_apply
import ./collision
import ./static_tree

type
  AddonRollbackOptions* = object
    stateDir*: string
    hostIdentity*: string
    target*: string            ## "" = the generation before `current`
    reconcileDrift*: bool
    driver*: CollisionDriver

  AddonRollbackResult* = object
    fromGeneration*: string
    toGeneration*: string
    apply*: AddonApplyResult

proc previousCommittedGeneration*(stateDir: string): string =
  ## The generation `current` was switched from, as its envelope records.
  let current = readCurrentGenerationId(stateDir)
  if current.len == 0: return ""
  try:
    readGenerationEnvelope(pointerPath(stateDir, current)).previousGenerationId
  except CatchableError:
    ""

proc runAddonRollback*(opts: AddonRollbackOptions): AddonRollbackResult =
  let stateDir = if opts.stateDir.len > 0: opts.stateDir else: DefaultStateDir
  if hasPendingMarker(stateDir):
    raise newException(AddonApplyError, "an interrupted switch is pending " &
      "(" & pendingMarkerPath(stateDir) & "); run `repro system addon " &
      "recover` before rolling back")
  result.fromGeneration = readCurrentGenerationId(stateDir)
  result.toGeneration = if opts.target.len > 0: opts.target
                        else: previousCommittedGeneration(stateDir)
  if result.toGeneration.len == 0:
    raise newException(AddonApplyError, "there is no generation before " &
      (if result.fromGeneration.len > 0: result.fromGeneration
       else: "the current one") & " to roll back to")
  if result.toGeneration == result.fromGeneration:
    raise newException(AddonApplyError, result.toGeneration &
      " is already the current generation")
  if not fileExists(pointerPath(stateDir, result.toGeneration)):
    raise newException(AddonApplyError, result.toGeneration &
      " is not a committed generation of this host (no " &
      pointerPath(stateDir, result.toGeneration) & ")")
  let g = generationProfiles(stateDir, result.toGeneration)
  if not g.found:
    raise newException(AddonApplyError, result.toGeneration &
      " predates the per-generation profile copies a rollback re-applies " &
      "(" & generationDir(stateDir, result.toGeneration) & "/" &
      AddonUserProfileName & "); re-apply its profile with `repro infra " &
      "apply --profile` instead")
  result.apply = runAddonApply(AddonApplyOptions(stateDir: stateDir,
    hostIdentity: opts.hostIdentity, ownProfileText: g.own,
    userProfileText: g.user, reconcileDrift: opts.reconcileDrift,
    driver: opts.driver, purpose: "rollback",
    # Its secrets come from the target generation's own envelope copy; a
    # copy that no longer opens refuses the rollback before anything is
    # written (spec §10.3).
    secretsFromGeneration: result.toGeneration))
