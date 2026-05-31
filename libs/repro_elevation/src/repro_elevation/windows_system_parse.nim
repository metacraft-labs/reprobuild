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

import std/[algorithm, strutils]

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

# ===========================================================================
# windows.acl — `icacls` output parsing.
#
# `icacls <path>` prints the ACL in a stable shape:
#
#     C:\ProgramData\Reprobuild-Tests\acl-test BUILTIN\Administrators:(F)
#                                              NT AUTHORITY\SYSTEM:(F)
#                                              CREATOR OWNER:(OI)(CI)(IO)(F)
#                                              BUILTIN\Users:(OI)(CI)(RX)
#
#     Successfully processed 1 files; Failed processing 0 files
#
# An absent file yields `<path>: The system cannot find the file
# specified.`; a present file's first non-empty line begins with the
# canonical path, optionally followed by the FIRST ACE on the same
# line. Subsequent ACE lines are indented and contain only
# `<principal>:<perms>`. The trailer (`Successfully processed ...`)
# is ignored.
#
# The PURE parser cares about three things:
#
#   1. Is the file present?
#   2. The set of explicit ACE specs the OS reports (the bare
#      `<principal>:<perms>` text per line, with inheritance flags
#      preserved as-is — they ARE part of the spec).
#   3. Whether inheritance is enabled. icacls does NOT print a direct
#      "inherited: yes/no" flag; instead, inherited entries have a
#      bare permission rendering (no synthesizing of `(I)` flags),
#      while explicitly-set entries do. Reprobuild's canonical
#      comparison is on the SET of desired entries (additive-only,
#      per the design), so we don't need an exact inheritance flag
#      to detect drift on the entries themselves. We expose a
#      lightweight `inheritanceDisabled` heuristic based on whether
#      any entry carries the `(I)` flag — `disabled-replace` /
#      `disabled-convert` modes strip the `(I)` flag from inherited
#      entries that ARE re-emitted as explicit, so the heuristic is
#      sufficient for the post-apply re-probe contract.
# ===========================================================================

type
  AclObservation* = object
    ## What an `icacls <path>` observation reports. `present` is true
    ## when the file/directory exists; an absent target has an empty
    ## entries list and the absent-sentinel digest.
    present*: bool
    entries*: seq[string]
      ## Each entry is a single `<principal>:<perms>` token as printed
      ## by `icacls`. The principal half is read up to (but not
      ## including) the FIRST `:` that is followed by `(` — that
      ## matches both `NT AUTHORITY\SYSTEM:(F)` (no colon in the
      ## principal) and the SID form `S-1-5-...:(F)` (no colon in
      ## the SID).
    inheritanceDisabled*: bool
      ## True when the OBSERVED ACL appears to have inheritance
      ## disabled — no entry carries the `(I)` flag. icacls does not
      ## print this flag directly; the heuristic is sufficient for the
      ## driver's `disabled-replace` / `disabled-convert` post-apply
      ## probe.

proc parseSingleAclEntry(text: string): string =
  ## Extract a single `<principal>:<perms>` ACE token from a string
  ## that may contain leading path, leading whitespace, and trailing
  ## whitespace. Returns "" if the line does not appear to be an ACE.
  ## The principal is matched up to the first `:` that is followed by
  ## a `(` (the icacls perm-group opener).
  let t = text.strip()
  if t.len == 0:
    return ""
  # Find a `:(` separator (the icacls perm-group opener follows the
  # principal-perm separator).
  let sep = t.find(":(")
  if sep <= 0:
    return ""
  result = t

proc aceContainsInheritanceFlag(ace: string): bool =
  ## True when the ACE spec contains the `(I)` inherited-marker flag.
  ## icacls prints `(I)` (capital I, parens) to mark an entry as
  ## inherited from the parent; `disabled-replace` / `disabled-convert`
  ## clear that flag on any entry the apply re-emits as explicit.
  ace.contains("(I)")

proc parseIcaclsOutput*(rawOutput: string; targetPath: string):
    AclObservation =
  ## Parse an `icacls <path>` invocation's output. `targetPath` is the
  ## path icacls was invoked on — the parser uses it to peel the path
  ## prefix off the first line (icacls prints the path inline with the
  ## first ACE). An "absent target" output (`The system cannot find
  ## the file specified` / `cannot find the path`) yields an absent
  ## observation; anything else with at least one parseable ACE yields
  ## a present observation.
  result.present = false
  result.inheritanceDisabled = true
  if rawOutput.strip().len == 0:
    return
  let lowered = rawOutput.toLowerAscii()
  if lowered.contains("cannot find the file") or
     lowered.contains("cannot find the path") or
     lowered.contains("could not find") or
     lowered.contains("the system cannot find"):
    return
  var foundAnyAce = false
  let pathLen = targetPath.len
  for rawLine in rawOutput.splitLines():
    let line = rawLine
    var workingLine = line
    # The first line begins with the path (no leading whitespace).
    # Strip it so the ACE parser sees the same `<principal>:(...)`
    # shape on every line.
    if pathLen > 0 and workingLine.len >= pathLen and
       workingLine.startsWith(targetPath):
      workingLine = workingLine[pathLen .. ^1]
    let entry = parseSingleAclEntry(workingLine)
    if entry.len == 0:
      continue
    # `Successfully processed N files; Failed processing M files`
    # contains a `:` but no `(` — `parseSingleAclEntry` already
    # rejects it. Defensive double-check below skips any line whose
    # principal half is suspicious (contains digits + `processed`).
    let lowerEntry = entry.toLowerAscii()
    if lowerEntry.contains("processed") or
       lowerEntry.contains("successfully"):
      continue
    result.entries.add(entry)
    foundAnyAce = true
    if aceContainsInheritanceFlag(entry):
      result.inheritanceDisabled = false
  result.present = foundAnyAce
  if not foundAnyAce:
    result.inheritanceDisabled = true

proc normalizeAclEntry*(ace: string): string =
  ## Stable rendering of an ACE: trim outer whitespace + collapse all
  ## internal whitespace runs to single spaces. icacls is permitted
  ## extra whitespace inside the perm groups; the canonical form
  ## collapses these so two visually-equivalent ACE strings hash to
  ## the same digest.
  var collapsed = ""
  var prevWasSpace = false
  for ch in ace.strip():
    if ch in {' ', '\t'}:
      if not prevWasSpace:
        collapsed.add(' ')
        prevWasSpace = true
    else:
      collapsed.add(ch)
      prevWasSpace = false
  collapsed

proc canonicalAclDesired*(path, owner: string;
                          entries: seq[string];
                          inheritanceMode: string): string =
  ## Stable canonical rendering used for the broker's desired-digest.
  ## The entries are normalized + SORTED so a re-ordering of the
  ## operator's declaration does NOT trigger a drift apply. The owner
  ## is omitted from the digest when unset (the apply does not change
  ## ownership, so the observation should not gate the cache-hit on
  ## it).
  var normalized: seq[string] = @[]
  for e in entries:
    normalized.add(normalizeAclEntry(e))
  normalized.sort()
  let mode = if inheritanceMode.len > 0: inheritanceMode else: "enabled"
  result = "acl:" & path & ":owner=" & owner & ":mode=" & mode &
    ":entries="
  for i, e in normalized:
    if i > 0:
      result.add(',')
    result.add(e)

proc canonicalAclState*(obs: AclObservation; path, owner: string;
                        desiredEntries: seq[string];
                        desiredInheritanceMode: string): string =
  ## Canonical rendering of the OBSERVED state, projected onto the
  ## desired-entries set. Additive-only semantics: only entries the
  ## operator declared are compared; extra ACEs already on disk are
  ## NOT considered drift. The projection digests the observed ACE
  ## that MATCHES the desired ACE's principal+perms (after
  ## normalization), or the empty string when the desired ACE is not
  ## present on disk — that asymmetric digest collapses to the
  ## desired digest iff every desired ACE was actually observed.
  if not obs.present:
    return "acl:absent"
  var normalizedDesired: seq[string] = @[]
  for e in desiredEntries:
    normalizedDesired.add(normalizeAclEntry(e))
  normalizedDesired.sort()
  var normalizedObserved: seq[string] = @[]
  for e in obs.entries:
    normalizedObserved.add(normalizeAclEntry(e))
  var matched: seq[string] = @[]
  for d in normalizedDesired:
    var found = ""
    for o in normalizedObserved:
      if o == d:
        found = d
        break
    matched.add(found)
  let mode =
    if desiredInheritanceMode.len > 0: desiredInheritanceMode
    else: "enabled"
  result = "acl:" & path & ":owner=" & owner & ":mode=" & mode &
    ":entries="
  for i, e in matched:
    if i > 0:
      result.add(',')
    result.add(e)

proc aclMatchesDesired*(obs: AclObservation;
                        path, owner: string;
                        desiredEntries: seq[string];
                        desiredInheritanceMode: string): bool =
  ## True when every desired ACE is present in the observed ACL, the
  ## inheritance-mode constraint is satisfied (a `disabled-*` mode
  ## requires `obs.inheritanceDisabled`), and the file is present.
  ## Additive-only on the entries — extra observed ACEs are ignored.
  if not obs.present:
    return false
  let mode =
    if desiredInheritanceMode.len > 0: desiredInheritanceMode
    else: "enabled"
  if mode != "enabled" and not obs.inheritanceDisabled:
    return false
  let observedDigest = canonicalAclState(obs, path, owner,
    desiredEntries, mode)
  let desiredDigest = canonicalAclDesired(path, owner,
    desiredEntries, mode)
  observedDigest == desiredDigest
