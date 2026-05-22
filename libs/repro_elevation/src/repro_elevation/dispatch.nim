## Broker-side dispatch (M81 deliverable 5; extended by M69).
##
## Per Elevation-And-Privileged-Operations.md "The Broker Executes A
## Closed, Typed Operation Set": the broker dispatches each decoded
## `PrivilegedOperation` to a typed driver — never a parent-supplied
## arbitrary command — and, before mutating, **re-observes** the
## resource's current state and runs the plan-apply-record drift
## check. State can change between the non-elevated plan and the
## elevated execution; the broker re-validates rather than blindly
## trusting the parent's plan.
##
## The drift contract here mirrors M68's `decideAction`:
##
##   - observed absent                                  -> create
##   - observed digest == desired digest                -> no-op (cache-hit)
##   - observed digest == the plan's expected baseline   -> safe update
##   - observed digest is neither                        -> DRIFT (fail-closed)
##
## The "expected baseline" is the digest the non-elevated plan saw
## when it last observed the resource — carried alongside each
## operation. A broker-side observation that matches NEITHER the
## desired value NOR that baseline means the world changed out of
## band: fail closed, do not overwrite.
##
## M81 shipped this with the two fixture kinds; M69 wires the four
## real Windows system-scope kinds into the same closed `case`
## statements — `reobserve`, `applyOne`, and `desiredDigest` each gain
## an exhaustive branch per kind so the compiler enforces the wiring.
##
## The dispatch result feeds both an `OperationResult` and an
## `ApplyLogRecord` so the parent writes the unified apply log.

import ./errors
import ./fixture_driver
import ./operations
import ./protocol
import ./windows_system_driver

type
  DispatchOutcome* = enum
    doApplied = "applied"               ## mutated the resource
    doNoOp = "no-op"                    ## already at desired state
    doDrift = "drift"                   ## fail-closed: drifted, not overwritten
    doError = "error"                   ## driver failure

  DispatchResult* = object
    address*: string
    kind*: PrivilegedOperationKind
    outcome*: DispatchOutcome
    detail*: string
    preWriteDigestHex*: string
    postWriteDigestHex*: string
    restartNeeded*: bool
      ## Set when a `windows.optionalFeature` / `windows.capability`
      ## mutation reports a pending reboot. Surfaced, never acted on.

  PlannedOperation* = WireOperation
    ## What the parent sends the broker (and the in-process fast
    ## path): the typed operation plus the digest the non-elevated
    ## planner observed for the target. Same shape as the on-wire
    ## `WireOperation` — aliased for call-site readability.

# ---------------------------------------------------------------------------
# Per-kind desired-state digest. The fixture kinds keep their
# `fixture_driver.desiredDigestHex`; the M69 system kinds use
# `windows_system_driver.systemDesiredDigestHex`.
# ---------------------------------------------------------------------------

proc desiredDigest(op: PrivilegedOperation): string =
  case op.kind
  of pokFixtureFile, pokFixtureRegistry:
    desiredDigestHex(op)
  of pokWindowsRegistryValue, pokWindowsOptionalFeature,
     pokWindowsCapability, pokWindowsService:
    systemDesiredDigestHex(op)

# ---------------------------------------------------------------------------
# Re-observe one operation's current real-world state.
# ---------------------------------------------------------------------------

proc reobserve*(ctx: FixtureContext;
                op: PrivilegedOperation): ObservedOperationState =
  ## Re-observe the operation's target. Dispatched on the closed
  ## kind set; an unknown kind cannot reach here (the protocol
  ## decoder already rejected it), but the `case` is exhaustive so
  ## the compiler enforces a branch per kind.
  case op.kind
  of pokFixtureFile:
    observeFixtureFile(ctx, op)
  of pokFixtureRegistry:
    observeFixtureRegistry(op)
  of pokWindowsRegistryValue:
    observeWindowsRegistryValue(op)
  of pokWindowsOptionalFeature:
    observeWindowsOptionalFeature(op)
  of pokWindowsCapability:
    observeWindowsCapability(op)
  of pokWindowsService:
    observeWindowsService(op)

proc applyOne(ctx: FixtureContext;
              op: PrivilegedOperation): ObservedOperationState =
  case op.kind
  of pokFixtureFile:
    result = applyFixtureFile(ctx, op)
  of pokFixtureRegistry:
    result = applyFixtureRegistry(op)
  of pokWindowsRegistryValue:
    result = applyWindowsRegistryValue(op)
  of pokWindowsOptionalFeature:
    let r = applyWindowsOptionalFeature(op)
    result = r.state
    result.restartNeeded = r.restartNeeded
  of pokWindowsCapability:
    let r = applyWindowsCapability(op)
    result = r.state
    result.restartNeeded = r.restartNeeded
  of pokWindowsService:
    result = applyWindowsService(op)

# ---------------------------------------------------------------------------
# Dispatch one planned operation with the re-observe / drift gate.
# ---------------------------------------------------------------------------

proc dispatchOperation*(ctx: FixtureContext;
                        planned: PlannedOperation): DispatchResult =
  ## Execute one privileged operation through its typed driver, with
  ## the mandated re-observe / drift-check BEFORE any mutation.
  ##
  ## Raises `EBrokerDrift` when the broker-observed state matches
  ## neither the desired value nor the plan's baseline — fail-closed,
  ## the caller turns it into a structured `OperationResult`.
  ## `EProtocol` is raised for an out-of-policy (sandbox-escape)
  ## operation; the broker validates the closed set up front, but
  ## `reobserve` re-checks as defence in depth.
  let op = planned.operation
  result.address = op.address
  result.kind = op.kind

  # Closed-set / policy re-validation (defence in depth — the
  # protocol decoder + the broker's up-front validator already ran).
  let policyErr = operationValidationError(op)
  if policyErr.len > 0:
    raiseProtocol(policyErr)

  # 1. Re-observe.
  let observed = reobserve(ctx, op)
  result.preWriteDigestHex =
    if observed.present: observed.digestHex else: ZeroDigestHex
  let desiredHex = desiredDigest(op)

  # 2. Cache-hit: the live state already matches the desired value.
  #    For a destroy op (`hklmDestroy`) the desired digest is the
  #    absent sentinel — an already-absent target is a no-op.
  let destroyOp = op.kind == pokWindowsRegistryValue and op.hklmDestroy
  if destroyOp:
    if not observed.present:
      result.outcome = doNoOp
      result.detail = "already absent (destroy is a no-op)"
      result.postWriteDigestHex = ZeroDigestHex
      return
  elif observed.present and observed.digestHex == desiredHex:
    result.outcome = doNoOp
    result.detail = "already at desired state"
    result.postWriteDigestHex = observed.digestHex
    return

  # 3. Drift gate. If the target is present and its observed digest
  #    matches NEITHER the desired value NOR the baseline the plan
  #    recorded, the world changed out of band — fail closed.
  if observed.present:
    let baseline =
      if planned.baselineDigestHex.len > 0: planned.baselineDigestHex
      else: ZeroDigestHex
    if observed.digestHex != baseline and observed.digestHex != desiredHex:
      raiseBrokerDrift(op.address, $op.kind, baseline, observed.digestHex)

  # 4. Safe to mutate (create when absent, update when observed
  #    matches the baseline; destroy when a destroy op reaches here).
  let post = applyOne(ctx, op)
  result.outcome = doApplied
  result.restartNeeded = post.restartNeeded
  result.detail =
    if destroyOp: "destroyed"
    elif observed.present: "updated"
    else: "created"
  if post.restartNeeded:
    result.detail.add("; a reboot is required to finish the change " &
      "(Reprobuild does not auto-reboot)")
  result.postWriteDigestHex =
    if post.present: post.digestHex else: ZeroDigestHex

# ---------------------------------------------------------------------------
# Result -> wire-frame projections.
# ---------------------------------------------------------------------------

proc toApplyLogRecord*(r: DispatchResult): ApplyLogRecord =
  ApplyLogRecord(
    operationAddress: r.address,
    operationKind: $r.kind,
    outcome: $r.outcome,
    detail: r.detail,
    preWriteDigestHex: r.preWriteDigestHex,
    postWriteDigestHex: r.postWriteDigestHex,
    restartNeeded: r.restartNeeded)

proc toOperationResult*(r: DispatchResult): OperationResultFrame =
  OperationResultFrame(
    operationAddress: r.address,
    ok: r.outcome == doApplied or r.outcome == doNoOp,
    driftDetected: r.outcome == doDrift,
    diagnostic: r.detail)
