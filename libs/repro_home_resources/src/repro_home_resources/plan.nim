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

import std/[os, strutils, tables]

import ./drivers/dconf_key
import ./drivers/defaults
import ./drivers/env_user
import ./drivers/gsettings
import ./drivers/kde_config_key
import ./drivers/launchd_user
import ./drivers/managed_block
import ./drivers/registry
import ./drivers/shell_integration
import ./drivers/systemd_user
import ./drivers/user_file
import ./drivers/vscode_extension
import ./drivers/windows_startup
import repro_homebrew_adapter/formula as homebrew_formula
import ./lifecycle
import ./manifest_record
import ./types

type
  PlanReport* = object
    actions*: seq[ResourceAction]
    changedCount*: int       ## create + update + destroy + replace + adopt
    noOpCount*: int
    driftCount*: int

proc userPathHostFromIdentity(resourceId: string): string =
  when defined(windows):
    ""
  else:
    let hash = resourceId.rfind('#')
    if hash > 0:
      resourceId[0 ..< hash]
    else:
      ""

proc parseGsettingsIdentity(resourceId: string): tuple[schema, path, key: string] =
  const prefix = "gsettings:"
  if not resourceId.startsWith(prefix):
    return ("", "", "")
  let body = resourceId[prefix.len .. ^1]
  if '|' in body:
    let parts = body.split('|')
    if parts.len >= 3:
      return (parts[0], parts[1], parts[2])
  let colon = body.rfind(':')
  if colon > 0:
    return (body[0 ..< colon], "", body[colon + 1 .. ^1])
  ("", "", "")

proc parseTwoPartIdentity(resourceId, prefix: string): tuple[a, b: string] =
  if not resourceId.startsWith(prefix):
    return ("", "")
  let body = resourceId[prefix.len .. ^1]
  let colon = body.rfind(':')
  if colon > 0:
    (body[0 ..< colon], body[colon + 1 .. ^1])
  else:
    ("", "")

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
    return observeUserPath(r.pathEntries, r.pathHostFilePath)
  of rkWindowsStartup:
    return observeStartup(r.startupName)
  of rkShellIntegration:
    return observeManagedBlock(r.shellHostFilePath, r.shellBlockId)
  of rkLinuxGsettings:
    return observeGsettings(r.gsettingsSchema, r.gsettingsPath, r.gsettingsKey)
  of rkSystemdUserUnit:
    return observeUserUnit(getHomeDir(), r.unitName)
  of rkMacosUserDefault:
    return observeUserDefault(r.defaultsDomain, r.defaultsKey)
  of rkLaunchdUserAgent:
    return observeLaunchAgent(getHomeDir(), r.launchdLabel)
  of rkFsUserFile:
    return observeUserFile(r.userFileHostPath)
  of rkVscodeExtension:
    return observeVscodeExtensions(r.vscodeExtensions, r.vscodeRemoveUnknown)
  of rkLinuxDconfKey:
    return observeDconfKey(r.dconfKey)
  of rkLinuxKdeConfigKey:
    return observeKdeConfigKey(r.kdeFile, r.kdeGroup, r.kdeKey,
      r.kdeVersion)
  of rkHomebrewFormula:
    return observeHomebrewFormula(r.formulaName, r.formulaVersion)

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
    let entries = parseRecordedPathEntries(binding.payloadBytes)
    return observeUserPath(entries, userPathHostFromIdentity(binding.resourceId))
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
  of rkLinuxGsettings:
    let parsed = parseGsettingsIdentity(binding.resourceId)
    if parsed.schema.len > 0 and parsed.key.len > 0:
      return observeGsettings(parsed.schema, parsed.path, parsed.key)
    result.present = false
    result.digest = zeroDigest()
  of rkSystemdUserUnit:
    const prefix = "systemd:user:"
    if binding.resourceId.startsWith(prefix):
      return observeUserUnit(getHomeDir(), binding.resourceId[prefix.len .. ^1])
    result.present = false
    result.digest = zeroDigest()
  of rkMacosUserDefault:
    let parsed = parseTwoPartIdentity(binding.resourceId, "defaults:")
    if parsed.a.len > 0 and parsed.b.len > 0:
      return observeUserDefault(parsed.a, parsed.b)
    result.present = false
    result.digest = zeroDigest()
  of rkLaunchdUserAgent:
    const prefix = "launchd:user:"
    if binding.resourceId.startsWith(prefix):
      return observeLaunchAgent(getHomeDir(), binding.resourceId[prefix.len .. ^1])
    result.present = false
    result.digest = zeroDigest()
  of rkFsUserFile:
    # The resourceId IS the resolved host path verbatim (no suffix),
    # per `realWorldIdentity`. Probe the file directly.
    return observeUserFile(binding.resourceId)
  of rkVscodeExtension:
    # The destroy path has no live "desired set" to compare against;
    # observe with an empty desired + removeUnknown=false so the
    # canonical-observed form is the empty intersection (zero digest
    # against an empty desired digest). A subsequent destroy
    # uninstalls every declared extension via the binding's payload.
    return observeVscodeExtensions(@[], false)
  of rkLinuxDconfKey:
    # The resourceId is `dconf:<key>`. Strip the prefix and re-probe.
    const prefix = "dconf:"
    if binding.resourceId.startsWith(prefix):
      return observeDconfKey(binding.resourceId[prefix.len .. ^1])
    result.present = false
    result.digest = zeroDigest()
  of rkHomebrewFormula:
    # The resourceId is `homebrew:formula:<name>`. The recorded
    # binding does not carry the original `formulaVersion` field
    # verbatim, but the recorded `payloadBytes` is exactly the
    # `name + 0x1e + (encoded-version)` produced at apply time —
    # so we can recover the encoded-version (which is either ""
    # for track-latest or the installed-version literal) and pass
    # it back as the `desiredVersion` argument so the observed
    # encoding matches what was recorded.
    const prefix = "homebrew:formula:"
    if binding.resourceId.startsWith(prefix):
      let formulaName = binding.resourceId[prefix.len .. ^1]
      # Decode the recorded payload: bytes after the 0x1e are the
      # encoded-version (possibly empty for track-latest).
      var encodedVersion = ""
      for i, b in binding.payloadBytes:
        if char(b) == '\x1e':
          if i + 1 < binding.payloadBytes.len:
            for j in i + 1 ..< binding.payloadBytes.len:
              encodedVersion.add(char(binding.payloadBytes[j]))
          break
      # If the recorded encoded-version is non-empty, pass it as
      # the desired pin so observe re-encodes the same shape; if
      # empty, the desired was track-latest and observe should
      # likewise emit name+0x1e+"".
      return observeHomebrewFormula(formulaName, encodedVersion)
    result.present = false
    result.digest = zeroDigest()
  of rkLinuxKdeConfigKey:
    # The resourceId is `kde:<file>:<group>:<key>`. Split on `:`.
    # The recorded binding does not carry `kdeVersion`; default to
    # 6 (the modern Plasma 6 binary). If the host only has the v5
    # toolchain, `kreadconfig6` will fail to launch and the
    # observation surfaces as absent — the lifecycle algorithm
    # then plans no destroy and the operator can re-declare with
    # the matching kdeVersion to converge.
    const prefix = "kde:"
    if binding.resourceId.startsWith(prefix):
      let body = binding.resourceId[prefix.len .. ^1]
      let parts = body.split(':')
      if parts.len >= 3:
        # Reassemble the trailing key parts in case the key name
        # itself contains a `:` — `kde:<file>:<group>:<key>` uses
        # FIRST-SEPARATOR semantics for the file and group, and
        # JOIN semantics for whatever follows.
        let kdeFile = parts[0]
        let kdeGroup = parts[1]
        let kdeKey = parts[2 .. ^1].join(":")
        return observeKdeConfigKey(kdeFile, kdeGroup, kdeKey, 6)
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
