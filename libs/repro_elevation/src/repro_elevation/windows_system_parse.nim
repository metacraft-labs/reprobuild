## Pure output-parsing + drift-comparison logic for the M69 Windows
## system-scope drivers (`windows.optionalFeature`,
## `windows.capability`, `windows.service`).
##
## Per the M68 Phase-A precedent: every real Win32 / shell-out call
## lives behind `when defined(windows)` in `windows_system_driver.nim`;
## the PURE logic — parsing DISM / capability / service output and the
## drift comparison — is isolated here so it is unit-tested
## cross-platform without touching the host. No `import std/os`, no
## `osproc`, no Win32 — this module is platform-pure by construction.

import std/[strutils]

# ===========================================================================
# windows.optionalFeature — DISM `Get-WindowsOptionalFeature` parsing.
# ===========================================================================

type
  OptionalFeatureState* = enum
    ## The lifecycle-relevant states of a Windows Optional Feature.
    ## `Get-WindowsOptionalFeature` reports `State` as one of
    ## Enabled / Disabled / EnablePending / DisablePending; the two
    ## `*Pending` states mean a reboot is required to finish the
    ## transition.
    ofsAbsent = "absent"            ## feature name not recognized at all
    ofsEnabled = "enabled"
    ofsDisabled = "disabled"
    ofsEnablePending = "enablePending"
    ofsDisablePending = "disablePending"

proc parseOptionalFeatureState*(rawOutput: string): OptionalFeatureState =
  ## Parse the `State : <value>` line out of `Get-WindowsOptional
  ## Feature -Online -FeatureName <name>` (or `dism /Get-FeatureInfo`)
  ## output. An output that names no `State` line at all means the
  ## feature is not recognized -> `ofsAbsent`.
  for line in rawOutput.splitLines():
    let t = line.strip()
    # Both the PowerShell cmdlet ("State : Enabled") and dism
    # ("State : Enabled") render the field as `State : <value>`.
    if t.toLowerAscii().startsWith("state"):
      let idx = t.find(':')
      if idx >= 0:
        let v = t[idx + 1 .. ^1].strip().toLowerAscii()
        case v
        of "enabled": return ofsEnabled
        of "disabled": return ofsDisabled
        of "enablepending": return ofsEnablePending
        of "disablepending": return ofsDisablePending
        else: discard
  return ofsAbsent

proc optionalFeatureRestartNeeded*(rawApplyOutput: string): bool =
  ## True when DISM's apply output signals a reboot is required. DISM
  ## prints `Restart Needed : Yes` (cmdlet: `RestartNeeded : True`);
  ## Reprobuild never auto-reboots — it surfaces this to the operator.
  let lo = rawApplyOutput.toLowerAscii()
  for line in lo.splitLines():
    let t = line.strip()
    if t.startsWith("restart needed") or t.startsWith("restartneeded"):
      let idx = t.find(':')
      if idx >= 0:
        let v = t[idx + 1 .. ^1].strip()
        if v in ["yes", "true", "1"]:
          return true
  # DISM also prints the bare sentence in some code paths.
  return lo.contains("restart needed to complete") or
    lo.contains("the operation completed successfully") and false

proc optionalFeatureStateMatchesDesired*(state: OptionalFeatureState;
                                         wantEnabled: bool): bool =
  ## A feature is "at the desired state" when its observed `State`
  ## matches the requested enable/disable. A `*Pending` state counts
  ## as the post-reboot target so a re-apply after a pending change
  ## is a cache-hit, not a redundant DISM call.
  if wantEnabled:
    state in {ofsEnabled, ofsEnablePending}
  else:
    state in {ofsDisabled, ofsDisablePending}

# ===========================================================================
# windows.capability — `Get-WindowsCapability` parsing.
# ===========================================================================

type
  CapabilityState* = enum
    ## States `Get-WindowsCapability -Online` reports: Installed,
    ## NotPresent, Staged, plus the install/uninstall pending forms.
    capsAbsent = "absent"           ## capability name not recognized
    capsInstalled = "installed"
    capsNotPresent = "notPresent"
    capsStaged = "staged"
    capsInstallPending = "installPending"
    capsUninstallPending = "uninstallPending"

proc parseCapabilityState*(rawOutput: string): CapabilityState =
  ## Parse the `State : <value>` line of `Get-WindowsCapability
  ## -Online -Name <name>` output.
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.toLowerAscii().startsWith("state"):
      let idx = t.find(':')
      if idx >= 0:
        let v = t[idx + 1 .. ^1].strip().toLowerAscii()
        case v
        of "installed": return capsInstalled
        of "notpresent": return capsNotPresent
        of "staged": return capsStaged
        of "installpending": return capsInstallPending
        of "uninstallpending": return capsUninstallPending
        else: discard
  return capsAbsent

proc capabilityRestartNeeded*(rawApplyOutput: string): bool =
  ## True when `Add-WindowsCapability` / `Remove-WindowsCapability`
  ## signals a reboot is required (`RestartNeeded : True`).
  for line in rawApplyOutput.toLowerAscii().splitLines():
    let t = line.strip()
    if t.startsWith("restart needed") or t.startsWith("restartneeded"):
      let idx = t.find(':')
      if idx >= 0 and t[idx + 1 .. ^1].strip() in ["yes", "true", "1"]:
        return true
  return false

proc capabilityStateMatchesDesired*(state: CapabilityState;
                                    wantInstalled: bool): bool =
  if wantInstalled:
    state in {capsInstalled, capsInstallPending}
  else:
    state in {capsNotPresent, capsAbsent, capsUninstallPending}

# ===========================================================================
# windows.service — `Get-Service` / `sc.exe qc` parsing.
# ===========================================================================

type
  ServiceObservation* = object
    ## What an observation of a Windows service reports. `present`
    ## false means the service is not installed (a `windows.service`
    ## resource manages an EXISTING service — it never installs one).
    present*: bool
    startType*: string              ## Automatic / Manual / Disabled / ""
    running*: bool

proc normalizeServiceStartType*(raw: string): string =
  ## Map the various spellings of a service start-type to the three
  ## canonical values a `windows.service` resource accepts. Win32
  ## `sc.exe qc` prints `AUTO_START` / `DEMAND_START` / `DISABLED`;
  ## the `Get-Service` `.StartType` property prints `Automatic` /
  ## `Manual` / `Disabled`. `AUTO_START` with `(DELAYED)` collapses
  ## to `Automatic` — delayed-start is still an automatic service.
  let u = raw.strip().toUpperAscii()
  if u.contains("AUTO") or u.contains("AUTOMATIC"):
    return "Automatic"
  if u.contains("DEMAND") or u.contains("MANUAL"):
    return "Manual"
  if u.contains("DISABLED"):
    return "Disabled"
  return raw.strip()

proc parseServiceQuery*(rawOutput: string): ServiceObservation =
  ## Parse a service observation from a deterministic two-line probe
  ## of the form:
  ##
  ##   StartType=Automatic
  ##   Status=Running
  ##
  ## The driver emits exactly these two `key=value` lines from the
  ## `Get-Service` properties (or a sentinel `Missing=1` line when the
  ## service does not exist) so the parse is unambiguous and pure.
  result.present = true
  result.startType = ""
  result.running = false
  var sawAnyField = false
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let idx = t.find('=')
    if idx < 0: continue
    let key = t[0 ..< idx].strip().toLowerAscii()
    let val = t[idx + 1 .. ^1].strip()
    case key
    of "missing":
      if val in ["1", "true", "yes"]:
        result.present = false
        return
    of "starttype":
      result.startType = normalizeServiceStartType(val)
      sawAnyField = true
    of "status":
      result.running = val.toLowerAscii() in ["running", "startpending"]
      sawAnyField = true
    else: discard
  if not sawAnyField:
    result.present = false

proc serviceMatchesDesired*(obs: ServiceObservation;
                            wantStartType: string;
                            wantRunning: bool): bool =
  ## A service is at the desired state when it exists, its start-type
  ## matches, and its runtime state matches.
  obs.present and obs.startType == wantStartType and
    obs.running == wantRunning

# ===========================================================================
# Canonical-state digests. The broker's re-observe / drift gate
# compares a digest of the OBSERVED state against a digest of the
# DESIRED state and the plan's recorded baseline. For the
# feature/capability/service drivers the "state" is a small typed
# tuple, not a byte payload — these helpers render that tuple to a
# stable canonical string the digest covers.
# ===========================================================================

proc canonicalOptionalFeatureState*(state: OptionalFeatureState): string =
  ## Pending states collapse to their post-reboot target so a
  ## re-apply after a pending transition is a cache-hit.
  case state
  of ofsEnabled, ofsEnablePending: "feature:enabled"
  of ofsDisabled, ofsDisablePending, ofsAbsent: "feature:disabled"

proc canonicalOptionalFeatureDesired*(wantEnabled: bool): string =
  if wantEnabled: "feature:enabled" else: "feature:disabled"

proc canonicalCapabilityState*(state: CapabilityState): string =
  case state
  of capsInstalled, capsInstallPending, capsStaged: "capability:installed"
  of capsNotPresent, capsAbsent, capsUninstallPending: "capability:absent"

proc canonicalCapabilityDesired*(wantInstalled: bool): string =
  if wantInstalled: "capability:installed" else: "capability:absent"

proc canonicalServiceState*(obs: ServiceObservation): string =
  if not obs.present:
    return "service:absent"
  "service:" & obs.startType & ":" &
    (if obs.running: "running" else: "stopped")

proc canonicalServiceDesired*(wantStartType: string;
                              wantRunning: bool): string =
  "service:" & wantStartType & ":" &
    (if wantRunning: "running" else: "stopped")

# ===========================================================================
# windows.firewallRule — `Get-NetFirewallRule` parsing.
#
# Like the service driver, the firewall driver emits a deterministic
# block of `key=value` lines (or a sentinel `Missing=1`) from a
# PowerShell probe so the pure parser sees an unambiguous shape:
#
#   StartType-style probe shape (rendered by `firewallProbeScript`):
#     Name=OpenSSH-Server-In-TCP
#     DisplayName=OpenSSH Server (sshd)
#     Protocol=TCP
#     Direction=Inbound
#     Action=Allow
#     LocalPort=22
#     Enabled=True
#
# Get-NetFirewallRule + Get-NetFirewallPortFilter return separate
# objects (the port lives on the PortFilter object). The probe script
# stitches them into the single block above so the parser stays pure.
# ===========================================================================

type
  FirewallRuleObservation* = object
    ## What a `Get-NetFirewallRule` observation reports. `present`
    ## false means the rule does not exist by that `Name`. Empty
    ## strings on present rules mean the field was not surfaced
    ## (e.g. a rule with no port filter prints `LocalPort=Any`).
    present*: bool
    name*: string
    displayName*: string
    protocol*: string             ## TCP / UDP / ICMPv4 / ICMPv6 / Any
    direction*: string            ## Inbound / Outbound
    action*: string               ## Allow / Block
    localPort*: string            ## "22", "Any", "22,2222", "8000-9000"
    enabled*: bool

proc normalizeFirewallEnabled*(raw: string): bool =
  ## `Get-NetFirewallRule.Enabled` prints `True` / `False` in the
  ## PowerShell `Format-List` view but the underlying CIM type renders
  ## as `1` / `0` in some builds. Accept both spellings.
  case raw.strip().toLowerAscii()
  of "true", "1", "yes", "on", "enabled": true
  of "false", "0", "no", "off", "disabled": false
  else: false

proc parseFirewallRuleQuery*(rawOutput: string): FirewallRuleObservation =
  ## Parse a firewall-rule observation from a deterministic block of
  ## `key=value` lines as emitted by `firewallProbeScript` (see the
  ## section banner). A `Missing=1` line short-circuits to an absent
  ## observation; an output with no recognized field becomes absent
  ## too (defensive default — a malformed PowerShell run cannot pose
  ## as a present rule).
  result.present = true
  result.enabled = false
  var sawAnyField = false
  for line in rawOutput.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let idx = t.find('=')
    if idx < 0: continue
    let key = t[0 ..< idx].strip().toLowerAscii()
    let val = t[idx + 1 .. ^1].strip()
    case key
    of "missing":
      if val in ["1", "true", "yes"]:
        result.present = false
        return
    of "name":
      result.name = val
      sawAnyField = true
    of "displayname":
      result.displayName = val
      sawAnyField = true
    of "protocol":
      result.protocol = val
      sawAnyField = true
    of "direction":
      result.direction = val
      sawAnyField = true
    of "action":
      result.action = val
      sawAnyField = true
    of "localport":
      result.localPort = val
      sawAnyField = true
    of "enabled":
      result.enabled = normalizeFirewallEnabled(val)
      sawAnyField = true
    else: discard
  if not sawAnyField:
    result.present = false

proc canonicalFirewallRuleState*(obs: FirewallRuleObservation): string =
  ## Stable canonical rendering used for the broker's drift-digest.
  ## A `displayName` field is INCLUDED so a profile that updates only
  ## the display label still triggers an apply. `localPort` is
  ## case-normalised so `any` and `Any` collapse to the same digest.
  if not obs.present:
    return "firewallRule:absent"
  let port =
    if obs.localPort.len == 0: "Any"
    elif obs.localPort.toLowerAscii() == "any": "Any"
    else: obs.localPort
  "firewallRule:" & obs.name & ":" & obs.displayName & ":" &
    obs.protocol & ":" & obs.direction & ":" & obs.action & ":" &
    port & ":" & (if obs.enabled: "enabled" else: "disabled")

proc canonicalFirewallRuleDesired*(name, displayName, protocol,
                                   direction, action, localPort: string;
                                   enabled: bool): string =
  let port =
    if localPort.len == 0: "Any"
    elif localPort.toLowerAscii() == "any": "Any"
    else: localPort
  let label = if displayName.len > 0: displayName else: name
  "firewallRule:" & name & ":" & label & ":" & protocol & ":" &
    direction & ":" & action & ":" & port & ":" &
    (if enabled: "enabled" else: "disabled")

proc firewallRuleMatchesDesired*(obs: FirewallRuleObservation;
                                 desiredName, desiredDisplayName,
                                 desiredProtocol, desiredDirection,
                                 desiredAction, desiredLocalPort: string;
                                 desiredEnabled: bool): bool =
  ## True when the observed rule matches the desired declaration on
  ## every field that the driver writes — name, display name (after
  ## the default-to-name substitution), protocol, direction, action,
  ## local port (after the empty-or-`any` normalization), and enabled
  ## state.
  if not obs.present:
    return false
  let observedDigest = canonicalFirewallRuleState(obs)
  let desiredDigest = canonicalFirewallRuleDesired(
    desiredName, desiredDisplayName, desiredProtocol, desiredDirection,
    desiredAction, desiredLocalPort, desiredEnabled)
  observedDigest == desiredDigest
