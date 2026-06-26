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

import ./operations

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
  ServiceRecoveryActionObservation* = object
    ## One observed `sc qfailure` slot: the action token (lower-case,
    ## matching the spec wire vocabulary `restart` / `runcommand` /
    ## `reboot` / `none`) and the slot's delay in milliseconds.
    action*: string
    delayMs*: int

  ServiceObservation* = object
    ## What an observation of a Windows service reports. `present`
    ## false means the service is not installed (a `windows.service`
    ## resource manages an EXISTING service — it never installs one).
    present*: bool
    startType*: string              ## Automatic / Manual / Disabled / ""
    running*: bool
    displayName*: string            ## Phase B: `DISPLAY_NAME` from sc qc.
    binPath*: string                ## Phase B: `BINARY_PATH_NAME` from sc qc.
    recoveryActions*: seq[ServiceRecoveryActionObservation]
      ## Phase B: the 1st/2nd/subsequent-failure slots from sc qfailure.
      ## `RESTART` / `RUN PROCESS` / `REBOOT` / blank map to the
      ## lower-case canonical tokens.
    recoveryResetSeconds*: int      ## Phase B: failure-count reset window.

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
  ##
  ## Windows-System-Resources Phase B: an extended probe additionally
  ## emits `DisplayName=` and `BinPath=` lines so the same parser shape
  ## covers both the legacy two-field probe and the Phase B four-field
  ## probe. Absent lines collapse to empty strings (the Phase B fields'
  ## "leave unmanaged" sentinel).
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
    of "displayname":
      result.displayName = val
      sawAnyField = true
    of "binpath", "binary_path_name", "binarypathname":
      result.binPath = val
      sawAnyField = true
    else: discard
  if not sawAnyField:
    result.present = false

proc normalizeServiceRecoveryActionToken*(raw: string): string =
  ## Map the various `sc qfailure` action-name spellings to the lower-
  ## case wire vocabulary. `sc qfailure` prints `RESTART` / `RUN PROCESS`
  ## / `REBOOT` / `NO_ACTION` (or blank); the wire tokens are `restart`
  ## / `runcommand` / `reboot` / `none`. An unrecognized spelling
  ## collapses to `none` so a malformed probe does NOT pose as a
  ## meaningful policy.
  let u = raw.strip().toUpperAscii()
  if u.len == 0 or u == "NO_ACTION" or u == "NONE":
    return "none"
  if u == "RESTART":
    return "restart"
  if u.startsWith("RUN"):              # RUN PROCESS / RUN_COMMAND
    return "runcommand"
  if u == "REBOOT":
    return "reboot"
  return "none"

proc parseSingleFailureActionLine*(text: string):
    tuple[present: bool; action: string; delayMs: int] =
  ## Parse a single `<ACTION> -- Delay = <ms> milliseconds.` line from
  ## `sc qfailure` output. Returns `present=false` when the line does
  ## not match (e.g. the `REBOOT_MESSAGE :` empty placeholder). The
  ## action half is normalised to the lower-case wire token via
  ## `normalizeServiceRecoveryActionToken`; the delay half is parsed
  ## as an integer (the literal `milliseconds.` suffix is stripped
  ## before the parse).
  result.present = false
  let t = text.strip()
  if t.len == 0:
    return
  # The action token is the substring up to the FIRST "--" separator;
  # the delay value is the substring after `Delay = ` to the next
  # whitespace.
  let sepIdx = t.find("--")
  if sepIdx <= 0:
    return
  let actionRaw = t[0 ..< sepIdx].strip()
  let actionTok = normalizeServiceRecoveryActionToken(actionRaw)
  let after = t[sepIdx + 2 .. ^1]
  let dEq = after.toUpperAscii().find("DELAY")
  if dEq < 0:
    return
  let eqIdx = after.find('=', dEq)
  if eqIdx < 0:
    return
  var delayStr = after[eqIdx + 1 .. ^1].strip()
  # Strip trailing `milliseconds.` / `milliseconds` / `ms.` etc.
  for stop in [" milliseconds.", " milliseconds", " ms.", " ms"]:
    let pos = delayStr.toLowerAscii().find(stop)
    if pos >= 0:
      delayStr = delayStr[0 ..< pos].strip()
      break
  # Also drop a trailing `.` from the last token on the line.
  if delayStr.endsWith("."):
    delayStr = delayStr[0 ..< delayStr.len - 1].strip()
  var delayMs: int
  try:
    delayMs = parseInt(delayStr)
  except ValueError:
    return
  result.present = true
  result.action = actionTok
  result.delayMs = delayMs

proc parseScQfailureOutput*(rawOutput: string):
    tuple[resetSeconds: int;
          actions: seq[ServiceRecoveryActionObservation]] =
  ## Parse the `sc qfailure <name>` text output. `sc qfailure` prints a
  ## block of the form:
  ##
  ##   [SC] QueryServiceConfig2 SUCCESS
  ##
  ##   SERVICE_NAME: foo
  ##           RESET_PERIOD (in seconds)    : 86400
  ##           REBOOT_MESSAGE               :
  ##           COMMAND_LINE                 :
  ##           FAILURE_ACTIONS              : RESTART -- Delay = 5000 milliseconds.
  ##                                          RESTART -- Delay = 10000 milliseconds.
  ##                                          REBOOT -- Delay = 60000 milliseconds.
  ##
  ## The pure parser extracts the `RESET_PERIOD` integer and walks the
  ## `FAILURE_ACTIONS` continuation lines (indented after the colon)
  ## for `<ACTION_TOKEN> -- Delay = <ms> milliseconds.` triples.
  ## Missing / blank fields yield zero / empty seq (the Phase B
  ## "no policy" sentinel).
  result.resetSeconds = 0
  result.actions = @[]
  var inActions = false
  for rawLine in rawOutput.splitLines():
    let stripped = rawLine.strip()
    if stripped.len == 0:
      continue
    let upper = stripped.toUpperAscii()
    # RESET_PERIOD line.
    if upper.startsWith("RESET_PERIOD") or
       upper.startsWith("RESET PERIOD"):
      let idx = stripped.find(':')
      if idx >= 0:
        let valStr = stripped[idx + 1 .. ^1].strip()
        try:
          result.resetSeconds = parseInt(valStr)
        except ValueError:
          result.resetSeconds = 0
      inActions = false
      continue
    # FAILURE_ACTIONS marker — the first action token may share the
    # line (after the `:`), subsequent actions continue on indented
    # lines.
    if upper.startsWith("FAILURE_ACTIONS") or
       upper.startsWith("FAILURE ACTIONS"):
      inActions = true
      let idx = stripped.find(':')
      if idx >= 0:
        let tail = stripped[idx + 1 .. ^1].strip()
        if tail.len > 0:
          let act = parseSingleFailureActionLine(tail)
          if act.present:
            result.actions.add(ServiceRecoveryActionObservation(
              action: act.action, delayMs: act.delayMs))
      continue
    # Skip other top-level fields.
    if not inActions:
      continue
    # Continuation lines inside FAILURE_ACTIONS. The shape is
    # `<TOKEN> -- Delay = <ms> milliseconds.` — `sc` may also print a
    # secondary line for `REBOOT_MESSAGE` etc; those bail.
    if upper.startsWith("REBOOT_MESSAGE") or
       upper.startsWith("COMMAND_LINE"):
      inActions = false
      continue
    let act = parseSingleFailureActionLine(stripped)
    if act.present:
      result.actions.add(ServiceRecoveryActionObservation(
        action: act.action, delayMs: act.delayMs))

proc serviceMatchesDesired*(obs: ServiceObservation;
                            wantStartType: string;
                            wantRunning: bool;
                            wantDisplayName = "";
                            wantBinPath = "";
                            wantRecoveryActions:
                              seq[ServiceRecoveryActionObservation] = @[];
                            wantRecoveryResetSeconds = 0): bool =
  ## A service is at the desired state when it exists, its start-type
  ## matches, its runtime state matches, and — Windows-System-Resources
  ## Phase B — each MANAGED Phase B field (non-empty desired) matches
  ## the observation. An empty desired displayName / binPath / empty
  ## recoveryActions / zero recoveryResetSeconds means "leave
  ## unmanaged", and the observation's value is not compared.
  if not obs.present:
    return false
  if obs.startType != wantStartType:
    return false
  if obs.running != wantRunning:
    return false
  if wantDisplayName.len > 0 and obs.displayName != wantDisplayName:
    return false
  if wantBinPath.len > 0 and obs.binPath != wantBinPath:
    return false
  if wantRecoveryActions.len > 0:
    if obs.recoveryActions.len != wantRecoveryActions.len:
      return false
    for i, slot in wantRecoveryActions:
      if obs.recoveryActions[i].action != slot.action:
        return false
      if obs.recoveryActions[i].delayMs != slot.delayMs:
        return false
  if wantRecoveryResetSeconds > 0 and
     obs.recoveryResetSeconds != wantRecoveryResetSeconds:
    return false
  return true

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

proc renderRecoveryDigestPart(actions: seq[ServiceRecoveryActionObservation];
                              resetSeconds: int): string =
  result = ":recovery="
  for i, a in actions:
    if i > 0:
      result.add(',')
    result.add(a.action)
    result.add('/')
    result.add($a.delayMs)
  result.add(":reset=")
  result.add($resetSeconds)

proc canonicalServiceState*(obs: ServiceObservation;
                            wantDisplayName = "";
                            wantBinPath = "";
                            includeRecovery = false): string =
  ## Stable canonical rendering used for the broker's drift-digest.
  ## The legacy two-argument call (`canonicalServiceState(obs)`) stays
  ## backward-compatible by leaving the Phase B fields at their empty
  ## defaults — the digest then matches the legacy three-field digest
  ## byte-for-byte. When the Phase B fields are non-empty the digest
  ## extends with their values so a drift on any of them triggers an
  ## apply.
  if not obs.present:
    return "service:absent"
  result = "service:" & obs.startType & ":" &
    (if obs.running: "running" else: "stopped")
  # Only include displayName / binPath when the operation declared a
  # non-empty desired value — a profile that doesn't manage these
  # fields stays on the legacy digest.
  if wantDisplayName.len > 0:
    result.add(":displayName=")
    result.add(obs.displayName)
  if wantBinPath.len > 0:
    result.add(":binPath=")
    result.add(obs.binPath)
  if includeRecovery:
    result.add(renderRecoveryDigestPart(obs.recoveryActions,
      obs.recoveryResetSeconds))

# ===========================================================================
# windows.scheduledTask — `Get-ScheduledTask` parsing + drift comparator.
#
# Windows-System-Resources Phase C: the driver emits a deterministic
# `key=value` block from a single `Get-ScheduledTask` probe so the pure
# parser stays Linux-runnable. The same probe shape covers all five
# trigger variants — kind-specific fields collapse to empty when absent.
# ===========================================================================

type
  ScheduledTaskObservation* = object
    ## What an observation of a Windows scheduled task reports.
    ## `present` false means the task does not exist under that
    ## `taskName`. Empty strings on present tasks mean the field was
    ## not surfaced by the probe.
    present*: bool
    taskName*: string
    executable*: string
    arguments*: seq[string]
    workingDirectory*: string
    runAsUser*: string
    runWithHighestPrivileges*: bool
    enabled*: bool
    schedule*: ScheduledTaskScheduleSpec
      ## The trigger reconstructed from the probe lines. A probe that
      ## could not name a recognisable schedule kind collapses to a
      ## `wstskOnBoot` with `delaySeconds = 0` — the most conservative
      ## "no special schedule" form; the drift comparator surfaces it
      ## as a mismatch against any non-onBoot desired spec.

proc parseScheduledTaskQuery*(rawOutput: string): ScheduledTaskObservation =
  ## Parse a scheduled-task observation from a deterministic
  ## `key=value` probe. `Missing=1` -> absent. The probe shape (emitted
  ## by `scheduledTaskProbeScript` in the driver):
  ##
  ##   TaskName=\Reprobuild\Foo
  ##   Executable=C:\bin\foo.exe
  ##   Arguments=--flag
  ##   WorkingDirectory=
  ##   RunAsUser=SYSTEM
  ##   RunWithHighestPrivileges=True
  ##   Enabled=True
  ##   ScheduleKind=daily
  ##   ScheduleTimeOfDay=08:30
  ##
  ## Per kind, the schedule payload uses these field names:
  ##   * onBoot   -> ScheduleDelaySeconds
  ##   * onLogon  -> ScheduleForUser
  ##   * once     -> ScheduleRunAt
  ##   * daily    -> ScheduleTimeOfDay
  ##   * interval -> ScheduleEveryMinutes + ScheduleStartAt
  result.present = true
  var sawAnyField = false
  var scheduleKindTok = ""
  var schDelay = 0
  var schForUser = ""
  var schRunAt = ""
  var schTimeOfDay = ""
  var schEveryMinutes = 0
  var schStartAt = ""
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
    of "taskname":
      result.taskName = val
      sawAnyField = true
    of "executable":
      result.executable = val
      sawAnyField = true
    of "arguments":
      if val.len > 0:
        for piece in val.split('\x1f'):       # split on US (\037)
          result.arguments.add(piece)
      sawAnyField = true
    of "workingdirectory":
      result.workingDirectory = val
      sawAnyField = true
    of "runasuser":
      result.runAsUser = val
      sawAnyField = true
    of "runwithhighestprivileges":
      result.runWithHighestPrivileges =
        val.toLowerAscii() in ["true", "1", "yes", "highest"]
      sawAnyField = true
    of "enabled":
      result.enabled = val.toLowerAscii() in ["true", "1", "yes", "ready"]
      sawAnyField = true
    of "schedulekind":
      scheduleKindTok = val
      sawAnyField = true
    of "scheduledelayseconds":
      try: schDelay = parseInt(val)
      except ValueError: schDelay = 0
    of "scheduleforuser":
      schForUser = val
    of "schedulerunat":
      schRunAt = val
    of "scheduletimeofday":
      schTimeOfDay = val
    of "scheduleeveryminutes":
      try: schEveryMinutes = parseInt(val)
      except ValueError: schEveryMinutes = 0
    of "schedulestartat":
      schStartAt = val
    else: discard
  if not sawAnyField:
    result.present = false
    return
  # Reconstruct the schedule. An unrecognised tag collapses to the
  # conservative onBoot:0 — the drift comparator treats it as a
  # mismatch against any non-onBoot desired spec.
  if isKnownScheduledTaskScheduleKindToken(scheduleKindTok):
    let kind = scheduledTaskScheduleKindFromToken(scheduleKindTok)
    case kind
    of wstskOnBoot:
      result.schedule = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
        delaySeconds: schDelay)
    of wstskOnLogon:
      result.schedule = ScheduledTaskScheduleSpec(kind: wstskOnLogon,
        forUser: schForUser)
    of wstskOnce:
      result.schedule = ScheduledTaskScheduleSpec(kind: wstskOnce,
        runAt: schRunAt)
    of wstskDaily:
      result.schedule = ScheduledTaskScheduleSpec(kind: wstskDaily,
        timeOfDay: schTimeOfDay)
    of wstskInterval:
      result.schedule = ScheduledTaskScheduleSpec(kind: wstskInterval,
        everyMinutes: schEveryMinutes, startAt: schStartAt)
  else:
    result.schedule = ScheduledTaskScheduleSpec(kind: wstskOnBoot,
      delaySeconds: 0)

proc scheduledTaskMatchesDesired*(obs: ScheduledTaskObservation;
                                  wantTaskName: string;
                                  wantExecutable: string;
                                  wantArguments: seq[string];
                                  wantWorkingDirectory: string;
                                  wantRunAsUser: string;
                                  wantRunWithHighestPrivileges: bool;
                                  wantSchedule: ScheduledTaskScheduleSpec;
                                  wantEnabled: bool): bool =
  ## Drift comparator. A task is at the desired state when every
  ## load-bearing field matches. Empty desired strings + empty seqs
  ## represent "leave at the driver default" — the observation's value
  ## is not compared for those slots, mirroring the `windows.service`
  ## "leave unmanaged" convention.
  if not obs.present:
    return false
  if obs.taskName != wantTaskName:
    return false
  if obs.executable != wantExecutable:
    return false
  if obs.arguments != wantArguments:
    return false
  if wantWorkingDirectory.len > 0 and
     obs.workingDirectory != wantWorkingDirectory:
    return false
  if obs.runAsUser != wantRunAsUser:
    return false
  if obs.runWithHighestPrivileges != wantRunWithHighestPrivileges:
    return false
  if obs.enabled != wantEnabled:
    return false
  if obs.schedule != wantSchedule:
    return false
  true

proc canonicalScheduledTaskState*(obs: ScheduledTaskObservation): string =
  ## Stable canonical rendering used for the broker's drift-digest. A
  ## present task digests as `scheduledTask:<taskName>:<executable>:<schedule>:<runAsUser>:<enabled>`
  ## with the schedule encoded as its canonical wire token.
  if not obs.present:
    return "scheduledTask:absent"
  var argv = ""
  for i, a in obs.arguments:
    if i > 0:
      argv.add(' ')
    argv.add(a)
  "scheduledTask:" & obs.taskName & ":" & obs.executable & ":" &
    argv & ":" & obs.workingDirectory & ":" & obs.runAsUser & ":" &
    (if obs.runWithHighestPrivileges: "highest" else: "limited") &
    ":" & encodeScheduledTaskScheduleSpec(obs.schedule) & ":" &
    (if obs.enabled: "enabled" else: "disabled")

proc canonicalScheduledTaskDesired*(taskName, executable: string;
                                    arguments: seq[string];
                                    workingDirectory, runAsUser: string;
                                    runWithHighestPrivileges: bool;
                                    schedule: ScheduledTaskScheduleSpec;
                                    enabled: bool): string =
  ## Canonical desired-state digest input. Same shape as
  ## `canonicalScheduledTaskState` so an observed-matches-desired
  ## comparison reduces to a byte-equality check on the rendered
  ## strings.
  var argv = ""
  for i, a in arguments:
    if i > 0:
      argv.add(' ')
    argv.add(a)
  "scheduledTask:" & taskName & ":" & executable & ":" & argv & ":" &
    workingDirectory & ":" & runAsUser & ":" &
    (if runWithHighestPrivileges: "highest" else: "limited") & ":" &
    encodeScheduledTaskScheduleSpec(schedule) & ":" &
    (if enabled: "enabled" else: "disabled")

proc canonicalServiceDesired*(wantStartType: string;
                              wantRunning: bool;
                              wantDisplayName = "";
                              wantBinPath = "";
                              wantRecoveryActions:
                                seq[ServiceRecoveryActionObservation] = @[];
                              wantRecoveryResetSeconds = 0): string =
  result = "service:" & wantStartType & ":" &
    (if wantRunning: "running" else: "stopped")
  if wantDisplayName.len > 0:
    result.add(":displayName=")
    result.add(wantDisplayName)
  if wantBinPath.len > 0:
    result.add(":binPath=")
    result.add(wantBinPath)
  if wantRecoveryActions.len > 0 or wantRecoveryResetSeconds > 0:
    result.add(renderRecoveryDigestPart(wantRecoveryActions,
      wantRecoveryResetSeconds))

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
