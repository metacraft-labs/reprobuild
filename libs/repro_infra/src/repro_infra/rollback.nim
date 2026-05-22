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

import ./errors
import ./profile

type
  RollbackSafetyDecision* = object
    ## The outcome of screening a rollback for destructive operations.
    requiresFeatureDestroyFlag*: bool
    destructiveAddresses*: seq[string]
      ## The resources whose rollback would disable a feature /
      ## uninstall a capability.

proc screenRollback*(reverted: openArray[SystemResource]):
    RollbackSafetyDecision =
  ## Screen the resources a rollback would revert. A
  ## `windows.optionalFeature` / `windows.capability` revert is
  ## destructive (it disables / uninstalls); everything else
  ## (registry value, service config) is non-destructive — the
  ## rollback restores the recorded pre-write value.
  for r in reverted:
    if isDestructiveRollback(r):
      result.requiresFeatureDestroyFlag = true
      result.destructiveAddresses.add(r.address)

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
