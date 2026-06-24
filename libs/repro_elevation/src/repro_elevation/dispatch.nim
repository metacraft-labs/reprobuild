## Broker-side dispatch (M81 deliverable 5; extended by M69; apply-
## time contract reshaped by M82 Phase A).
##
## Per Elevation-And-Privileged-Operations.md "The Broker Executes A
## Closed, Typed Operation Set": the broker dispatches each decoded
## `PrivilegedOperation` to a typed driver — never a parent-supplied
## arbitrary command — and, before mutating, **re-observes** the
## resource's current state. The live observation is the apply-time
## baseline; the planner's recorded baseline is NOT consulted here.
##
## The apply-time pipeline (M82 Phase A — see
## Planner-Apply-Refresh-Model.md):
##
##   - observed absent           -> create (apply runs)
##   - observed == desired       -> cache-hit (no-op); confirmed by a
##                                  second observation a short delay
##                                  later to defeat CBS-finalization
##                                  transients (see `dispatchOperation`)
##   - observed != desired       -> update (apply runs against the
##                                  observed state); the per-driver
##                                  post-apply re-probe is the
##                                  integrity check that the mutation
##                                  achieved the desired state
##
## The plan-time-baseline drift gate that pre-M82-Phase-A raised
## `EBrokerDrift` whenever observed matched neither the recorded
## baseline nor the desired digest was REMOVED: it conflated external
## drift (a third party modified state out of band — the legitimate
## fail-closed case) with intra-batch evolution (a preceding op in the
## same apply caused the change — the legitimate proceed case). The
## M69 `openssh-capability-and-sshd-service` REAL scenario surfaced
## this; see `dispatchOperation`'s step-3 comment for the full
## rationale. External-drift detection moves to plan time (M82 Phase
## B/C — `repro infra plan` / `repro home plan` compare observed
## state against the previously-applied generation's recorded state).
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
import ./inline_exec_driver
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
     pokWindowsCapability, pokWindowsService,
     pokWindowsScheduledTask,
     pokWindowsFirewallRule, pokWindowsAcl:
    systemDesiredDigestHex(op)
  of pokWindowsVsInstaller:
    vsInstallerDesiredDigestHex(op)
  of pokMacosSystemDefault, pokSystemdSystemUnit, pokLaunchdSystemDaemon,
     pokFsSystemFile, pokFsSystemDirectory, pokEnvSystemVariable,
     pokPasswdUser,
     pokLinuxSysctl, pokLinuxUdevRule, pokLinuxPolkitRule,
     pokLinuxTmpfilesRule, pokLinuxSudoersRule, pokPasswdGroup,
     pokLinuxNixDaemonSetting, pokSystemdSystemTimer,
     pokLinuxFirewallRule, pokLinuxNixosSystemModule,
     pokMacosDarwinSystemModule, pokLinuxFhsSandbox:
    posixSystemDesiredDigestHex(op)
  of pokInlineExecCall:
    # Windows-System-Resources Phase E: an inline-exec edge has no
    # observable steady state — `dispatchOperation` special-cases the
    # kind before calling `desiredDigest`. This branch keeps the
    # `case` exhaustive so the compiler enforces wiring; reaching it
    # is a programming error.
    raise newException(ValueError,
      "desiredDigest: pokInlineExecCall has no observable steady " &
        "state; dispatch must take the inline-exec spawn path before " &
        "this proc is called")
  of pokOsTimezone, pokOsHostname:
    # Cross-platform: every platform's desired digest is the canonical
    # IANA / lowercase-hostname rendering. Both `systemDesiredDigest
    # Hex` (Windows side, in `windows_system_driver`) and
    # `posixSystemDesiredDigestHex` (POSIX side) produce the SAME
    # canonical bytes for the same desired state, so the broker's
    # drift gate compares uniformly regardless of where the apply
    # runs. We pick the platform-resident impl deterministically:
    # Windows uses the windows-side digest, POSIX uses the posix
    # digest — both produce the same canonical string by construction.
    when defined(windows):
      systemDesiredDigestHex(op)
    else:
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
  of pokWindowsScheduledTask:
    observeWindowsScheduledTask(op)
  of pokWindowsVsInstaller:
    observeWindowsVsInstaller(op)
  of pokWindowsFirewallRule:
    observeWindowsFirewallRule(op)
  of pokWindowsAcl:
    observeWindowsAcl(op)
  of pokMacosSystemDefault:
    observeMacosSystemDefault(op)
  of pokSystemdSystemUnit:
    observeSystemdSystemUnit(op)
  of pokLaunchdSystemDaemon:
    observeLaunchdSystemDaemon(op)
  of pokFsSystemFile:
    observeFsSystemFile(op)
  of pokFsSystemDirectory:
    observeFsSystemDirectory(op)
  of pokEnvSystemVariable:
    observeEnvSystemVariable(op)
  of pokPasswdUser:
    observePasswdUser(op)
  of pokOsTimezone:
    when defined(windows):
      observeWindowsOsTimezone(op)
    else:
      observePosixOsTimezone(op)
  of pokOsHostname:
    when defined(windows):
      observeWindowsOsHostname(op)
    else:
      observePosixOsHostname(op)
  of pokLinuxSysctl:
    observeLinuxSysctl(op)
  of pokLinuxUdevRule:
    observeLinuxUdevRule(op)
  of pokLinuxPolkitRule:
    observeLinuxPolkitRule(op)
  of pokLinuxTmpfilesRule:
    observeLinuxTmpfilesRule(op)
  of pokLinuxSudoersRule:
    observeLinuxSudoersRule(op)
  of pokPasswdGroup:
    observePasswdGroup(op)
  of pokLinuxNixDaemonSetting:
    observeLinuxNixDaemonSetting(op)
  of pokSystemdSystemTimer:
    observeSystemdSystemTimer(op)
  of pokLinuxFirewallRule:
    observeLinuxFirewallRule(op)
  of pokLinuxNixosSystemModule:
    observeLinuxNixosSystemModule(op)
  of pokMacosDarwinSystemModule:
    observeMacosDarwinSystemModule(op)
  of pokLinuxFhsSandbox:
    observeLinuxFhsSandbox(op)
  of pokInlineExecCall:
    # Windows-System-Resources Phase E: an inline-exec edge has no
    # observable steady state. Dispatch special-cases the kind before
    # this point; reaching this branch is a programming error.
    raise newException(ValueError,
      "reobserve: pokInlineExecCall has no observable steady state; " &
        "dispatch must take the inline-exec spawn path before this " &
        "proc is called")

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
  of pokWindowsScheduledTask:
    result = applyWindowsScheduledTask(op)
  of pokWindowsVsInstaller:
    let r = applyWindowsVsInstaller(op)
    result = r.state
    result.restartNeeded = r.restartNeeded
  of pokWindowsFirewallRule:
    result = applyWindowsFirewallRule(op)
  of pokWindowsAcl:
    result = applyWindowsAcl(op)
  of pokMacosSystemDefault:
    result = applyMacosSystemDefault(op)
  of pokSystemdSystemUnit:
    result = applySystemdSystemUnit(op)
  of pokLaunchdSystemDaemon:
    result = applyLaunchdSystemDaemon(op)
  of pokFsSystemFile:
    result = applyFsSystemFile(op)
  of pokFsSystemDirectory:
    result = applyFsSystemDirectory(op)
  of pokEnvSystemVariable:
    result = applyEnvSystemVariable(op)
  of pokPasswdUser:
    result = applyPasswdUser(op)
  of pokOsTimezone:
    when defined(windows):
      result = applyWindowsOsTimezone(op)
    else:
      result = applyPosixOsTimezone(op)
  of pokOsHostname:
    when defined(windows):
      result = applyWindowsOsHostname(op)
      # `applyWindowsOsHostname` surfaces `restartNeeded` directly on
      # the returned `ObservedOperationState`; the dispatch layer
      # mirrors it onto the result for the apply-log record.
    else:
      result = applyPosixOsHostname(op)
  of pokLinuxSysctl:
    result = applyLinuxSysctl(op)
  of pokLinuxUdevRule:
    result = applyLinuxUdevRule(op)
  of pokLinuxPolkitRule:
    result = applyLinuxPolkitRule(op)
  of pokLinuxTmpfilesRule:
    result = applyLinuxTmpfilesRule(op)
  of pokLinuxSudoersRule:
    result = applyLinuxSudoersRule(op)
  of pokPasswdGroup:
    result = applyPasswdGroup(op)
  of pokLinuxNixDaemonSetting:
    result = applyLinuxNixDaemonSetting(op)
  of pokSystemdSystemTimer:
    result = applySystemdSystemTimer(op)
  of pokLinuxFirewallRule:
    result = applyLinuxFirewallRule(op)
  of pokLinuxNixosSystemModule:
    result = applyLinuxNixosSystemModule(op)
  of pokMacosDarwinSystemModule:
    result = applyMacosDarwinSystemModule(op)
  of pokLinuxFhsSandbox:
    result = applyLinuxFhsSandbox(op)
  of pokInlineExecCall:
    # Windows-System-Resources Phase E: an inline-exec edge does not
    # converge a resource — `dispatchOperation` special-cases it via
    # `runInlineExecCall` before reaching `applyOne`. Reaching this
    # branch would be a programming error.
    raise newException(ValueError,
      "applyOne: pokInlineExecCall is dispatched via runInlineExecCall " &
        "in dispatchOperation; this proc is never called for the kind")

# ---------------------------------------------------------------------------
# Dispatch one planned operation with the re-observe / drift gate.
# ---------------------------------------------------------------------------

proc dispatchOperation*(ctx: FixtureContext;
                        planned: PlannedOperation): DispatchResult =
  ## Execute one privileged operation through its typed driver, with
  ## the mandated re-observe BEFORE any mutation.
  ##
  ## M82 Phase A: the apply-time plan-time-baseline drift gate was
  ## removed (see the module docstring and the step-3 comment below).
  ## `EBrokerDrift` is no longer raised from this proc — the typed
  ## exception is retained in `errors.nim` for the Phase B/C planner
  ## migration of external-drift detection. The per-driver post-apply
  ## re-probe is the integrity check that the apply achieved the
  ## desired state; a disagreement raises `EProtocol`.
  ##
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

  # Windows-System-Resources Phase E: `pokInlineExecCall` does NOT
  # converge a resource — there is no observable steady state. The
  # build engine already decided (via input hashing + output caching)
  # that the edge needs to run; the broker's role is purely to fork
  # the process under elevation. The reobserve/drift contract that
  # gates every other kind doesn't apply here, so we short-circuit
  # before calling `reobserve` / `desiredDigest`.
  if op.kind == pokInlineExecCall:
    let outcome = runInlineExecCall(op)
    result.outcome = doApplied
    result.detail = inlineExecCallAuditDetail(op, outcome)
    # The pre/post-write digests are not meaningful for a one-shot
    # spawn; the audit-log "outcome=applied" + the rendered argv is
    # the diagnostic the parent stores. Leave the digest fields at
    # the absent sentinel so a downstream consumer can distinguish
    # "side-effecting edge that ran" from "steady-state resource
    # whose digest was recorded".
    result.preWriteDigestHex = ZeroDigestHex
    result.postWriteDigestHex = ZeroDigestHex
    return

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
    (op.kind == pokWindowsScheduledTask and op.wstDestroy) or
    (op.kind == pokWindowsVsInstaller and op.vsDestroy) or
    (op.kind == pokWindowsFirewallRule and op.fwDestroy) or
    (op.kind == pokWindowsAcl and op.aclDestroy) or
    (op.kind == pokMacosSystemDefault and op.sdDestroy) or
    (op.kind == pokSystemdSystemUnit and op.suDestroy) or
    (op.kind == pokLaunchdSystemDaemon and op.sdaDestroy) or
    (op.kind == pokFsSystemFile and op.sfDestroy) or
    (op.kind == pokFsSystemDirectory and op.fsdDestroy) or
    (op.kind == pokEnvSystemVariable and op.evDestroy) or
    (op.kind == pokPasswdUser and op.puDestroy) or
    (op.kind == pokLinuxSysctl and op.sysctlDestroy) or
    (op.kind == pokLinuxUdevRule and op.udevDestroy) or
    (op.kind == pokLinuxPolkitRule and op.polkitDestroy) or
    (op.kind == pokLinuxTmpfilesRule and op.tmpfilesDestroy) or
    (op.kind == pokLinuxSudoersRule and op.sudoersDestroy) or
    (op.kind == pokPasswdGroup and op.pgDestroy) or
    (op.kind == pokLinuxNixDaemonSetting and op.nixDestroy) or
    (op.kind == pokSystemdSystemTimer and op.stDestroy) or
    (op.kind == pokLinuxFirewallRule and op.lfwDestroy) or
    (op.kind == pokLinuxNixosSystemModule and op.nixosModuleDestroy) or
    (op.kind == pokMacosDarwinSystemModule and op.darwinModuleDestroy) or
    (op.kind == pokLinuxFhsSandbox and op.fsbDestroy)
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

  # 3. (M82 Phase A) The plan-time-baseline drift gate USED TO LIVE
  #    HERE and would `raiseBrokerDrift` whenever `observed.digestHex`
  #    matched neither the recorded plan-time baseline nor the desired
  #    digest. It was removed because the contract it implemented —
  #    "refuse to act if the world differs from what the plan thought
  #    it would be" — conflated EXTERNAL drift (a third party modified
  #    state out of band, the legitimate fail-closed case) with
  #    INTRA-BATCH evolution (a preceding op in the SAME apply caused
  #    the change, the legitimate proceed case). The M69
  #    `openssh-capability-and-sshd-service` REAL scenario surfaced
  #    this: baseline_service=absent recorded at plan time before the
  #    capability installs sshd; observed Manual/Stopped at dispatch
  #    time after the capability registered the service; dispatch
  #    treated this as drift and refused to act, Set-Service never
  #    ran. See Planner-Apply-Refresh-Model.md for the full design
  #    rationale and the Terraform-inspired layering. The integrity
  #    check now lives in each driver's post-apply re-probe (the
  #    `applyWindowsService` precedent from `f19a0ed`, extended in
  #    M82 Phase A Deliverable 1 to every other system-scope driver):
  #    "did my apply actually achieve the desired state?" External
  #    drift detection moves to plan time per M82 Phase B/C —
  #    `repro infra plan` / `repro home plan` will compare observed
  #    state against the previously-applied generation's recorded
  #    state and surface drift with a user-confirmation flow.
  #
  #    `preWriteDigestHex` is still set above for audit-record
  #    completeness; it no longer gates the apply decision.

  # 4. Safe to mutate (create when absent, otherwise overwrite the
  #    observed state; destroy when a destroy op reaches here). Live
  #    observation is the baseline for the delta computation; the
  #    planner's recorded baseline is not consulted here.
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
