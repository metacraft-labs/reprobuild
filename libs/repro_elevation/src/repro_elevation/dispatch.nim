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

import std/os

import ./errors
import ./fixture_driver
import ./operations
import ./posix_system_driver
import ./protocol
import ./windows_system_driver
import ./windows_vs_installer_driver

const
  CacheHitConfirmDelayMs* = 1000
    ## Delay between the two cache-hit observations. See the cache-hit
    ## confirmation comment in `dispatchOperation` for the rationale.
    ## One second matches the per-sample cadence the windows.capability
    ## driver uses for its post-install service-stability loop, so a
    ## confirmation sample taken here lands a full cadence later than
    ## the driver's last steady-state read.

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
  of pokWindowsVsInstaller:
    vsInstallerDesiredDigestHex(op)
  of pokMacosSystemDefault, pokSystemdSystemUnit, pokLaunchdSystemDaemon,
     pokFsSystemFile, pokEnvSystemVariable, pokPasswdUser:
    posixSystemDesiredDigestHex(op)

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
  of pokWindowsVsInstaller:
    observeWindowsVsInstaller(op)
  of pokMacosSystemDefault:
    observeMacosSystemDefault(op)
  of pokSystemdSystemUnit:
    observeSystemdSystemUnit(op)
  of pokLaunchdSystemDaemon:
    observeLaunchdSystemDaemon(op)
  of pokFsSystemFile:
    observeFsSystemFile(op)
  of pokEnvSystemVariable:
    observeEnvSystemVariable(op)
  of pokPasswdUser:
    observePasswdUser(op)

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
  of pokWindowsVsInstaller:
    let r = applyWindowsVsInstaller(op)
    result = r.state
    result.restartNeeded = r.restartNeeded
  of pokMacosSystemDefault:
    result = applyMacosSystemDefault(op)
  of pokSystemdSystemUnit:
    result = applySystemdSystemUnit(op)
  of pokLaunchdSystemDaemon:
    result = applyLaunchdSystemDaemon(op)
  of pokFsSystemFile:
    result = applyFsSystemFile(op)
  of pokEnvSystemVariable:
    result = applyEnvSystemVariable(op)
  of pokPasswdUser:
    result = applyPasswdUser(op)

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
  var observed = reobserve(ctx, op)
  result.preWriteDigestHex =
    if observed.present: observed.digestHex else: ZeroDigestHex
  let desiredHex = desiredDigest(op)

  # 2. Cache-hit: the live state already matches the desired value.
  #    For a destroy op the desired digest is the absent sentinel —
  #    an already-absent target is a no-op.
  let destroyOp =
    (op.kind == pokWindowsRegistryValue and op.hklmDestroy) or
    (op.kind == pokWindowsVsInstaller and op.vsDestroy) or
    (op.kind == pokMacosSystemDefault and op.sdDestroy) or
    (op.kind == pokSystemdSystemUnit and op.suDestroy) or
    (op.kind == pokLaunchdSystemDaemon and op.sdaDestroy) or
    (op.kind == pokFsSystemFile and op.sfDestroy) or
    (op.kind == pokEnvSystemVariable and op.evDestroy) or
    (op.kind == pokPasswdUser and op.puDestroy)
  let firstSampleLooksLikeCacheHit =
    if destroyOp: not observed.present
    else: observed.present and observed.digestHex == desiredHex

  # Confirm an apparent cache-hit with a second observation taken
  # `CacheHitConfirmDelayMs` later. M69 root-caused a sshd test
  # failure to this very point: after the windows.capability driver
  # finished installing OpenSSH.Server it waited for the sshd
  # service to stabilize at its post-install steady state
  # (Manual/Stopped), then returned. The dispatch loop's NEXT op was
  # the windows.service op that flips sshd to Automatic/Running.
  # That op's initial re-observe here had a small but real chance
  # of sampling a transient CBS-finalization read in which sshd
  # briefly appeared Automatic/Running — the cache-hit predicate
  # matched, the apply was skipped, CBS then reset sshd back to
  # Manual/Stopped, and the gate failed. Confirming with a second
  # observation closes that race: a true cache-hit is a steady-state
  # property and survives a one-second hold; a transient read does
  # not. If the two samples disagree, the second (later) read is
  # used as the source of truth for the drift gate and apply path
  # since it is closer to the actual settled state. The cost of a
  # ~1 s pause on every legitimate cache-hit is acceptable for the
  # privileged-operations workload (low op-count, high stakes per
  # op); see the accompanying smoke test for the contract.
  if firstSampleLooksLikeCacheHit:
    sleep(CacheHitConfirmDelayMs)
    let confirm = reobserve(ctx, op)
    let confirmAgrees =
      if destroyOp: not confirm.present
      else: confirm.present and confirm.digestHex == desiredHex
    if confirmAgrees:
      result.outcome = doNoOp
      if destroyOp:
        result.detail = "already absent (destroy is a no-op)"
        result.postWriteDigestHex = ZeroDigestHex
      else:
        result.detail = "already at desired state"
        result.postWriteDigestHex = confirm.digestHex
      return
    # Samples disagree => the first read was a transient. Treat the
    # second observation as ground truth from here on.
    observed = confirm
    result.preWriteDigestHex =
      if observed.present: observed.digestHex else: ZeroDigestHex

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
