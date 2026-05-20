## `repro home plan` — non-mutating preview.
##
## Per the spec ("Lifecycle Decision Algorithm" + the M68 deliverable):
## the planner consumes the same DesiredSet + recorded bindings the
## apply pipeline does, computes the per-resource decision, and
## renders a human-readable diff. It must NOT touch the filesystem
## or the registry beyond the read-only observation pass.
##
## Output format (stable; gate 1 asserts the first line and the
## per-resource lines):
##
##   repro home plan: <N> resource(s) planned, <K> drift(s)
##     create   <address> (<kind>)
##     update   <address> (<kind>)
##     destroy  <address> (<kind>)
##     no-op    <address> (<kind>)
##     DRIFT    <address> (<kind>)   expected=<12hex> observed=<12hex>
##
## Exit code (computed by the caller): 0 if no changes / no drift;
## 0 if changes; non-zero if drift detected and `--allow-drift` was
## not passed.

import std/[strutils, tables]

import ./drivers/env_user
import ./drivers/managed_block
import ./drivers/registry
import ./drivers/shell_integration
import ./drivers/windows_startup
import ./lifecycle
import ./manifest_record
import ./types

type
  PlanReport* = object
    actions*: seq[ResourceAction]
    changedCount*: int       ## create + update + destroy + replace + adopt
    noOpCount*: int
    driftCount*: int

# ---------------------------------------------------------------------------
# Observation: ask each driver about the current real-world state.
# ---------------------------------------------------------------------------

proc observeResource*(r: Resource): ObservedState =
  case r.kind
  of rkFsManagedBlock:
    return observeManagedBlock(r.hostFilePath, r.managedBlockId)
  of rkWindowsRegistryValue:
    return observeRegistryValue(r.registryKey, r.registryName)
  of rkEnvUserVariable:
    return observeUserVariable(r.envVarName)
  of rkEnvUserPath:
    return observeUserPath(r.pathEntries)
  of rkWindowsStartup:
    return observeStartup(r.startupName)
  of rkShellIntegration:
    return observeManagedBlock(r.shellHostFilePath, r.shellBlockId)
  of rkLinuxGsettings:
    # Phase B observation; the Phase A planner platform-skips the
    # Linux resources upstream. The stub returns "absent".
    result.present = false
    result.digest = zeroDigest()
  of rkSystemdUserUnit, rkMacosUserDefault, rkLaunchdUserAgent:
    result.present = false
    result.digest = zeroDigest()

proc observeRecorded*(address: string; binding: RecordedBinding):
    ObservedState =
  ## Refresh observation for an address that's recorded but no
  ## longer in the desired set (destroy candidate). The recorded
  ## binding tells us which driver to ask.
  case binding.kind
  of rkFsManagedBlock:
    # The recorded resourceId is "<hostFile>#<blockId>" per
    # types.realWorldIdentity. Split it back.
    let hash = binding.resourceId.rfind('#')
    if hash <= 0:
      result.present = false
      return
    return observeManagedBlock(binding.resourceId[0 ..< hash],
      binding.resourceId[hash + 1 .. ^1])
  of rkWindowsRegistryValue:
    let bs = binding.resourceId.rfind('\\')
    if bs <= 0:
      result.present = false
      return
    return observeRegistryValue(binding.resourceId[0 ..< bs],
      binding.resourceId[bs + 1 .. ^1])
  of rkEnvUserVariable:
    let bs = binding.resourceId.rfind('\\')
    if bs <= 0:
      result.present = false
      return
    return observeUserVariable(binding.resourceId[bs + 1 .. ^1])
  of rkEnvUserPath:
    # Without a desired contribution we can't compute "the
    # entries we added"; treat as absent (observation will fail
    # gracefully).
    result.present = false
    result.digest = zeroDigest()
  of rkWindowsStartup:
    let bs = binding.resourceId.rfind('\\')
    if bs <= 0:
      result.present = false
      return
    return observeStartup(binding.resourceId[bs + 1 .. ^1])
  of rkShellIntegration:
    let hash = binding.resourceId.rfind('#')
    if hash <= 0:
      result.present = false
      return
    return observeManagedBlock(binding.resourceId[0 ..< hash],
      binding.resourceId[hash + 1 .. ^1])
  else:
    result.present = false
    result.digest = zeroDigest()
  discard address

# ---------------------------------------------------------------------------
# Plan composition.
# ---------------------------------------------------------------------------

proc composePlan*(desired: DesiredSet;
                 recorded: OrderedTable[string, RecordedBinding];
                 options: DecisionOptions = DecisionOptions(
                   reconcile: rpFailClosed,
                   enforcePreventDestroy: false)): PlanReport =
  ## The core planner. For each address in either the desired set
  ## or the recorded set, compute the action via
  ## `lifecycle.decideAction` and aggregate counts.
  result.actions = @[]
  var seen = initOrderedTable[string, bool]()

  # First pass: every desired address.
  for addr1, res in desired.resources:
    var state: ResourceState
    state.address = addr1
    state.desired = res
    state.hasDesired = true
    state.observed = observeResource(res)
    if addr1 in recorded:
      state.recorded = recorded[addr1]
      state.hasRecorded = true
    let action = decideAction(state, options)
    result.actions.add(action)
    seen[addr1] = true

  # Second pass: addresses recorded but no longer desired (destroy).
  for addr1, binding in recorded:
    if addr1 in seen:
      continue
    var state: ResourceState
    state.address = addr1
    state.hasDesired = false
    state.recorded = binding
    state.hasRecorded = true
    state.observed = observeRecorded(addr1, binding)
    let action = decideAction(state, options)
    result.actions.add(action)

  for a in result.actions:
    case a.kind
    of rakNoOp: inc result.noOpCount
    of rakDriftBlocked: inc result.driftCount
    else: inc result.changedCount

# ---------------------------------------------------------------------------
# Rendering.
# ---------------------------------------------------------------------------

proc renderPlan*(report: PlanReport): string =
  ## Render the plan to a stable, line-oriented format. Used by
  ## the `repro home plan` CLI; also useful for the gate's stdout
  ## assertions.
  result = "repro home plan: " & $report.actions.len &
    " resource(s) planned, " & $report.driftCount & " drift(s)\n"
  for a in report.actions:
    var line = "  " & a.summary
    if a.kind == rakDriftBlocked:
      let expectedShort =
        if a.driftExpectedHex.len >= 12: a.driftExpectedHex[0 ..< 12]
        else: a.driftExpectedHex
      let observedShort =
        if a.driftObservedHex.len >= 12: a.driftObservedHex[0 ..< 12]
        else: a.driftObservedHex
      line.add("   expected=" & expectedShort & " observed=" & observedShort)
    result.add(line & "\n")
