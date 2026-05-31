## The four M69 real Windows system-scope privileged-operation
## drivers: `windows.registryValue` (HKLM), `windows.optionalFeature`,
## `windows.capability`, `windows.service`.
##
## Each driver is the typed counterpart of an M68 home-scope driver
## and implements the SAME contract the M81 fixture drivers do:
##
##   * `observe<X>`  re-observes the resource's current real-world
##     state and returns an `ObservedOperationState` (present +
##     canonical-bytes digest);
##   * `apply<X>`    mutates the resource and returns the post-write
##     observed state.
##
## The broker (`dispatch.nim`) calls `observe` then drift-checks then
## `apply`, exactly as for the fixture kinds. Every real Win32 call
## (`Reg*`) and every shell-out (DISM, capability, service) lives
## behind `when defined(windows)`; the PURE parsing / drift logic is
## in `windows_system_parse.nim` and is unit-tested cross-platform.
##
## `windows.optionalFeature` may set `RestartNeeded`; per the spec the
## driver NEVER auto-reboots — it surfaces the requirement in the
## `ObservedOperationState.restartNeeded` flag and the apply-log
## detail.

import std/[strutils]

import blake3

import ./errors
import ./fixture_driver
import ./operations
import ./os_system_parse
import ./producer_consumer_map
import ./system_value
import ./windows_system_parse

when defined(windows):
  import std/[monotimes, os, osproc, times]

# ---------------------------------------------------------------------------
# Digest helper, shared with the fixture-driver canonical-bytes model.
# ---------------------------------------------------------------------------

proc digestHexOfBytes*(bytes: openArray[byte]): string =
  let d = blake3.digest(bytes)
  result = newStringOfCap(64)
  for b in d:
    result.add(toHex(int(b), 2).toLowerAscii())

proc digestHexOfText*(text: string): string =
  var buf = newSeq[byte](text.len)
  for i, ch in text:
    buf[i] = byte(ord(ch))
  digestHexOfBytes(buf)

# ===========================================================================
# Desired-state digest for every M69 system-scope operation. The
# non-elevated planner computes this; the broker compares its
# re-observed state against the value the plan EXPECTED.
# ===========================================================================

proc systemDesiredDigestHex*(op: PrivilegedOperation): string =
  ## Canonical desired-state digest. Dispatched on the closed kind
  ## set; the fixture kinds keep their `fixture_driver` digest.
  case op.kind
  of pokWindowsRegistryValue:
    if op.hklmDestroy:
      ZeroDigestHex
    else:
      digestHexOfBytes(encodeSystemRegistryPayload(
        op.hklmValueKind, op.hklmValueLiteral))
  of pokWindowsOptionalFeature:
    digestHexOfText(canonicalOptionalFeatureDesired(op.featureEnable))
  of pokWindowsCapability:
    digestHexOfText(canonicalCapabilityDesired(op.capabilityInstall))
  of pokWindowsService:
    digestHexOfText(canonicalServiceDesired(
      op.serviceStartType, op.serviceRunning))
  of pokWindowsFirewallRule:
    if op.fwDestroy:
      ZeroDigestHex
    else:
      digestHexOfText(canonicalFirewallRuleDesired(
        op.fwName,
        (if op.fwDisplayName.len > 0: op.fwDisplayName else: op.fwName),
        op.fwProtocol, op.fwDirection, op.fwAction,
        op.fwLocalPort, op.fwEnabled))
  of pokWindowsAcl:
    if op.aclDestroy:
      ZeroDigestHex
    else:
      digestHexOfText(canonicalAclDesired(
        op.aclPath, op.aclOwner, op.aclEntries,
        op.aclInheritanceMode))
  of pokOsTimezone:
    digestHexOfText(canonicalTimezoneDesired(op.tzIana))
  of pokOsHostname:
    digestHexOfText(canonicalHostnameDesired(op.hostnameName))
  else:
    raise newException(ValueError,
      "systemDesiredDigestHex called on a non-system kind " & $op.kind)

# ===========================================================================
# windows.registryValue (HKLM) — typed value write via Win32 Reg*.
# ===========================================================================

when defined(windows):
  type
    HKEY = distinct pointer
    DWORD = uint32
    LSTATUS = clong
    LPCWSTR = ptr UncheckedArray[uint16]
    LPDWORD = ptr DWORD
    PHKEY = ptr HKEY
    REGSAM = DWORD
    LPBYTE = ptr UncheckedArray[uint8]
    LPCVOID = pointer

  const
    HKEY_LOCAL_MACHINE_INT = cast[int](0x80000002'u32)
    KEY_READ: REGSAM = 0x20019
    KEY_WRITE: REGSAM = 0x20006
    ERROR_SUCCESS: LSTATUS = 0
    ERROR_FILE_NOT_FOUND: LSTATUS = 2
    ERROR_MORE_DATA: LSTATUS = 234
    REG_OPTION_NON_VOLATILE: DWORD = 0

  proc hklm(): HKEY = cast[HKEY](cast[pointer](HKEY_LOCAL_MACHINE_INT))

  proc RegOpenKeyExW(hKey: HKEY; lpSubKey: LPCWSTR; ulOptions: DWORD;
                     samDesired: REGSAM; phkResult: PHKEY): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegCreateKeyExW(hKey: HKEY; lpSubKey: LPCWSTR; Reserved: DWORD;
                       lpClass: LPCWSTR; dwOptions: DWORD;
                       samDesired: REGSAM; lpSecurityAttributes: pointer;
                       phkResult: PHKEY; lpdwDisposition: LPDWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegCloseKey(hKey: HKEY): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegQueryValueExW(hKey: HKEY; lpValueName: LPCWSTR; lpReserved: LPDWORD;
                        lpType: LPDWORD; lpData: LPBYTE;
                        lpcbData: LPDWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegSetValueExW(hKey: HKEY; lpValueName: LPCWSTR; Reserved: DWORD;
                      dwType: DWORD; lpData: LPCVOID; cbData: DWORD): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc RegDeleteValueW(hKey: HKEY; lpValueName: LPCWSTR): LSTATUS
    {.importc, stdcall, dynlib: "advapi32".}

  proc toWideZ(s: string): seq[uint16] = toUtf16Z(s)

  proc observeHklmRegistryValue(op: PrivilegedOperation):
      ObservedOperationState =
    ## Read the HKLM value; `present == false` when the value (or its
    ## subkey) is absent. `digestHex` covers the raw value bytes —
    ## the same canonical-bytes model the fixture registry driver
    ## uses, so the broker's drift gate is uniform.
    var hk: HKEY
    var sub = toWideZ(op.hklmSubkey)
    let openStatus = RegOpenKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      KEY_READ, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    if openStatus != ERROR_SUCCESS:
      raiseProtocol("RegOpenKeyExW(HKLM\\" & op.hklmSubkey & ") status " &
        $openStatus)
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(op.hklmValueName)
    var regType: DWORD = 0
    var cb: DWORD = 0
    var status = RegQueryValueExW(hk, cast[LPCWSTR](addr nameW[0]), nil,
      addr regType, nil, addr cb)
    if status == ERROR_FILE_NOT_FOUND:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    if status != ERROR_SUCCESS and status != ERROR_MORE_DATA:
      raiseProtocol("RegQueryValueExW(size) status " & $status)
    var buf = newSeq[byte](int(cb))
    if cb > 0:
      status = RegQueryValueExW(hk, cast[LPCWSTR](addr nameW[0]), nil,
        addr regType, cast[LPBYTE](addr buf[0]), addr cb)
      if status != ERROR_SUCCESS:
        raiseProtocol("RegQueryValueExW(data) status " & $status)
    result.present = true
    result.digestHex = digestHexOfBytes(buf)

  proc deleteHklmRegistryValue(op: PrivilegedOperation):
      ObservedOperationState =
    var hk: HKEY
    var sub = toWideZ(op.hklmSubkey)
    let openStatus = RegOpenKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      KEY_WRITE, addr hk)
    if openStatus == ERROR_FILE_NOT_FOUND:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    if openStatus != ERROR_SUCCESS:
      raiseProtocol("RegOpenKeyExW(HKLM\\" & op.hklmSubkey &
        ", delete) status " & $openStatus)
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(op.hklmValueName)
    let status = RegDeleteValueW(hk, cast[LPCWSTR](addr nameW[0]))
    if status != ERROR_SUCCESS and status != ERROR_FILE_NOT_FOUND:
      raiseProtocol("RegDeleteValueW(HKLM\\" & op.hklmSubkey & "\\" &
        op.hklmValueName & ") status " & $status)
    result.present = false
    result.digestHex = ZeroDigestHex

  proc writeHklmRegistryValue(op: PrivilegedOperation):
      ObservedOperationState =
    let payload = encodeSystemRegistryPayload(
      op.hklmValueKind, op.hklmValueLiteral)
    var hk: HKEY
    var sub = toWideZ(op.hklmSubkey)
    var disposition: DWORD = 0
    let status = RegCreateKeyExW(hklm(), cast[LPCWSTR](addr sub[0]), 0,
      nil, REG_OPTION_NON_VOLATILE, KEY_WRITE, nil, addr hk,
      addr disposition)
    if status != ERROR_SUCCESS:
      raiseProtocol("RegCreateKeyExW(HKLM\\" & op.hklmSubkey & ") status " &
        $status & " — the broker may lack Administrator rights")
    defer: discard RegCloseKey(hk)
    var nameW = toWideZ(op.hklmValueName)
    let dataPtr =
      if payload.len > 0: cast[LPCVOID](unsafeAddr payload[0])
      else: cast[LPCVOID](nil)
    let setStatus = RegSetValueExW(hk, cast[LPCWSTR](addr nameW[0]), 0,
      systemRegistryValueKindToRegType(op.hklmValueKind),
      dataPtr, DWORD(payload.len))
    if setStatus != ERROR_SUCCESS:
      raiseProtocol("RegSetValueExW(HKLM\\" & op.hklmSubkey & "\\" &
        op.hklmValueName & ") status " & $setStatus)
    result.present = true
    result.digestHex = digestHexOfBytes(payload)

# ---------------------------------------------------------------------------
# windows.registryValue public entry points (cross-platform signature;
# the non-Windows form fails closed).
# ---------------------------------------------------------------------------

proc observeWindowsRegistryValue*(op: PrivilegedOperation):
    ObservedOperationState =
  when defined(windows):
    observeHklmRegistryValue(op)
  else:
    raiseNotImplementedPlatform("windows.registryValue observe")

proc applyWindowsRegistryValue*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Write or delete an HKLM registry value via the Win32 `Reg*` API.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. The Win32 `Reg*` calls are synchronous,
  ## but a system-policy GPO or another agent could clobber a write
  ## between `RegSetValueExW` and our return; re-reading via the same
  ## `RegQueryValueExW` path `observeHklmRegistryValue` uses and
  ## comparing the canonical-bytes digest closes that gap. Raises
  ## `EProtocol` on a genuine disagreement.
  when defined(windows):
    if op.hklmDestroy:
      result = deleteHklmRegistryValue(op)
    else:
      result = writeHklmRegistryValue(op)
    # Post-apply re-probe — see the contract comment above.
    let post = observeHklmRegistryValue(op)
    let desiredHex =
      if op.hklmDestroy: ZeroDigestHex
      else: digestHexOfBytes(encodeSystemRegistryPayload(
        op.hklmValueKind, op.hklmValueLiteral))
    let observedHex =
      if post.present: post.digestHex else: ZeroDigestHex
    if observedHex != desiredHex:
      raiseProtocol("windows.registryValue HKLM\\" & op.hklmSubkey & "\\" &
        op.hklmValueName & " post-apply observation disagrees with " &
        "desired state: observed digest " &
        (if observedHex.len >= 12: observedHex[0 ..< 12] else: observedHex) &
        ", desired digest " &
        (if desiredHex.len >= 12: desiredHex[0 ..< 12] else: desiredHex) &
        ". The Reg* call returned ERROR_SUCCESS but a re-read shows " &
        "a different value — the driver fails closed rather than " &
        "reporting a spurious success.")
    result = post
  else:
    raiseNotImplementedPlatform("windows.registryValue apply")

# ===========================================================================
# Shell-out helper. The feature/capability/service drivers shell out
# to PowerShell DISM cmdlets / `sc.exe`. The command STRINGS are
# composed from typed operation fields — never a parent-supplied raw
# command — so the closed-set guarantee holds: the broker still
## executes only a fixed, audited instruction shape.
# ===========================================================================

when defined(windows):
  proc runPowerShell(script: string): tuple[output: string; code: int] =
    ## Run a PowerShell one-liner and capture combined output. The
    ## script text is built only from typed operation fields by the
    ## callers below.
    let cmd = "powershell -NoProfile -NonInteractive -ExecutionPolicy " &
      "Bypass -Command \"" & script.replace("\"", "\\\"") & "\""
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc psQuote(s: string): string =
    ## Single-quote a value for a PowerShell argument. A feature /
    ## capability / service name is a closed identifier, but quoting
    ## is defence-in-depth.
    "'" & s.replace("'", "''") & "'"

  proc wrapCmdletTerminating(invocation: string): string =
    ## Wrap a DISM-style PowerShell cmdlet invocation so the script's
    ## EXIT CODE reflects the cmdlet's terminating-error outcome only,
    ## NOT the noisy `$?`/`$LASTEXITCODE` semantics PowerShell uses by
    ## default.
    ##
    ## Default PowerShell behavior: a cmdlet that writes ANY object to
    ## the error stream sets `$?` to false, which in turn makes
    ## `powershell.exe -Command` exit with 1 — even though the cmdlet
    ## itself succeeded and the operation is in flight. The M69 Hyper-V
    ## runs surfaced this against `Add-WindowsCapability -Online -Name
    ## 'OpenSSH.Server~~~~0.0.1.0'`: the cmdlet kicked off the FoD
    ## install (post-call polls observed `InstallPending`) but wrote a
    ## non-terminating warning/error to the error stream, so PowerShell
    ## exited 1 and the driver `raiseProtocol`'d a spurious failure.
    ##
    ## This wrapper:
    ##   * raises `$ErrorActionPreference = 'Stop'` so any cmdlet error
    ##     is converted to a terminating exception;
    ##   * runs the invocation under `try { ... } catch { ... }`;
    ##   * captures the returned object's `Format-List` rendering so
    ##     the existing `restartNeeded` / state parsers still see the
    ##     `RestartNeeded : ...` line they expect;
    ##   * exits 0 on success, 1 only on a TRUE terminating cmdlet
    ##     error (with the error message on the output stream so the
    ##     diagnostic survives).
    "$ErrorActionPreference = 'Stop'; try { $r = " & invocation &
      "; if ($null -ne $r) { $r | Format-List | Out-String | Write-Output } " &
      "; exit 0 } catch { Write-Output ('ERROR: ' + " &
      "$_.Exception.Message); exit 1 }"

# ===========================================================================
# windows.optionalFeature — DISM via PowerShell.
# ===========================================================================

proc observeWindowsOptionalFeature*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe a feature's `State`. `present` is true whenever the
  ## feature name is recognized; `digestHex` covers the canonical
  ## enabled/disabled state so the drift gate is uniform.
  when defined(windows):
    let (output, _) = runPowerShell(
      "Get-WindowsOptionalFeature -Online -FeatureName " &
      psQuote(op.featureName) & " | Format-List State")
    let state = parseOptionalFeatureState(output)
    result.present = state != ofsAbsent
    result.digestHex =
      if state == ofsAbsent: ZeroDigestHex
      else: digestHexOfText(canonicalOptionalFeatureState(state))
  else:
    raiseNotImplementedPlatform("windows.optionalFeature observe")

proc applyWindowsOptionalFeature*(op: PrivilegedOperation):
    tuple[state: ObservedOperationState; restartNeeded: bool] =
  ## Enable or disable the feature via DISM. NEVER auto-reboots —
  ## `-NoRestart` is always passed and `restartNeeded` is surfaced.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. When this proc returns without raising,
  ## the observed feature state matches what the operation asked for —
  ## OR `restartNeeded` is true and the feature is at its post-reboot
  ## pending target (DISM's `*Pending` states count as "at the desired
  ## state" per `optionalFeatureStateMatchesDesired`). A genuine
  ## disagreement raises `EProtocol`.
  when defined(windows):
    let verb =
      if op.featureEnable: "Enable-WindowsOptionalFeature"
      else: "Disable-WindowsOptionalFeature"
    let extra = if op.featureEnable: " -All" else: ""
    let invocation = verb & " -Online -NoRestart" & extra & " -FeatureName " &
      psQuote(op.featureName)
    # Run the cmdlet under explicit terminating-error semantics so the
    # script exit code reflects the operation's outcome, not a
    # `$?`-from-a-non-terminating-warning. See wrapCmdletTerminating.
    let (output, code) = runPowerShell(wrapCmdletTerminating(invocation))
    if code != 0:
      raiseProtocol("windows.optionalFeature " &
        (if op.featureEnable: "enable" else: "disable") & " of '" &
        op.featureName & "' failed: " & output.strip())
    result.restartNeeded = optionalFeatureRestartNeeded(output)
    # Post-apply re-probe — see the contract comment above. The same
    # `Get-WindowsOptionalFeature` query `observeWindowsOptionalFeature`
    # parses; a `*Pending` state on a restart-required apply still
    # canonicalizes to the desired bucket via
    # `optionalFeatureStateMatchesDesired`.
    let (postOutput, _) = runPowerShell(
      "Get-WindowsOptionalFeature -Online -FeatureName " &
      psQuote(op.featureName) & " | Format-List State")
    let postState = parseOptionalFeatureState(postOutput)
    if not optionalFeatureStateMatchesDesired(postState, op.featureEnable):
      raiseProtocol("windows.optionalFeature '" & op.featureName &
        "' post-apply observation disagrees with desired state: " &
        "observed State=" & $postState &
        "; desired " & (if op.featureEnable: "enabled" else: "disabled") &
        ". The DISM cmdlet returned exit 0 but the feature state does " &
        "not reflect the change — the driver fails closed rather than " &
        "reporting a spurious success.")
    result.state.present = postState != ofsAbsent
    result.state.digestHex =
      if postState == ofsAbsent: ZeroDigestHex
      else: digestHexOfText(canonicalOptionalFeatureState(postState))
  else:
    raiseNotImplementedPlatform("windows.optionalFeature apply")

# ===========================================================================
# windows.capability — Add/Get/Remove-WindowsCapability via PowerShell.
#
# CBS-finalization race (M69, the OpenSSH.Server symptom):
# `Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'`
# returns once `Get-WindowsCapability` reports `State=Installed`, but
# CBS continues a finalization pass AFTER that point. During the tail
# of finalization CBS may RESET a service the capability has just
# registered (`sshd`) back to its default `StartType=Manual` /
# `Status=Stopped`. A `windows.service` operation applied in the same
# elevated batch immediately after the capability driver returns
# therefore sees Set-Service / Start-Service exit 0 but the SCM
# database snap back to defaults — exactly the M69 sshd gate failure.
#
# `applyWindowsCapability` therefore polls the capability's registered
# service (if known) for STABILITY before returning: N consecutive
# observations with the same `StartType` + `Status` over a short
# interval. For capabilities whose service mapping is not in the table
# below, a small blanket safety pause is taken instead. Cost is paid
# only on the apply path; observe / drift-gate is untouched.
# ===========================================================================

## The `CapabilityServiceMap` constant that USED to live here is now
## the producer -> consumer table in `producer_consumer_map.nim`. M82
## Phase B promoted it from a driver-private const into a planner-
## visible declarative fact (the planner inserts implicit
## dependency-graph edges from a `windows.capability` to every
## `windows.service` it registers, so the planner topologically orders
## a capability+service pair WITHOUT the user writing `depends_on`).
## This file now consults the SAME map through
## `lookupCapabilityRegisteredService` (re-exported from
## `producer_consumer_map`) so the driver-side CBS-finalization wait
## and the planner-side edge inference can never disagree.

const
  CapabilityServiceStableObservations = 5
    ## N consecutive equal observations needed before the stability
    ## loop exits — chosen so CBS's last reset (if any) has time to
    ## land before we declare stability.

  CapabilityServiceStableIntervalMs = 1000
    ## Per-observation interval (milliseconds) inside the stability
    ## loop. Five 1 s samples => ~5 s steady-state hold before exit.

  CapabilityServiceStableTimeoutSec = 30
    ## Overall deadline (seconds) for the stability loop. If CBS is
    ## still oscillating the service's state after this, the driver
    ## fails closed with a diagnostic naming the observed history.

  UnknownCapabilityPostInstallPauseMs = 3000
    ## Blanket safety wait (milliseconds) taken AFTER `State=Installed`
    ## for any capability whose service mapping is not in the shared
    ## `ProducerConsumerMap` (see `producer_consumer_map.nim`). Short
    ## enough not to bloat every capability install; long enough to
    ## dodge most micro-races. If a real capability later proves to
    ## need a longer tail, add a `ProducerConsumerEntry` instead of
    ## growing this constant — the same entry then becomes visible to
    ## the planner's dependency-graph inference, so both the
    ## stability-wait and the implicit `producer -> consumer` edge stay
    ## in sync.

when defined(windows):
  type
    CapabilityServiceSampleRun = object
      ## One entry in the stability-loop's observed-state history:
      ## a canonical service-state string and the number of
      ## consecutive samples that observed it.
      sample: string
      count: int

  proc serviceProbeScript(name: string): string
    ## Forward-declared so the capability-finalization wait below can
    ## reuse the same deterministic `Get-Service` probe `observeWindows
    ## Service` parses. The definition lives in the windows.service
    ## section further down.

  proc awaitCapabilityServiceStable(capName, svcName: string) =
    ## Poll `svcName`'s (StartType, Status) until it has been
    ## observed unchanged for `CapabilityServiceStableObservations`
    ## consecutive samples taken `CapabilityServiceStableInterval`
    ## apart, OR until the overall deadline elapses. The
    ## observation pair is taken with the same `serviceProbeScript`
    ## the public `observeWindowsService` uses, so a parser
    ## regression flags both call sites.
    ##
    ## On state CHANGE the run counter resets and the most-recent
    ## sample becomes the new reference — the loop never declares
    ## stability across a transition. On overall deadline the proc
    ## raises `EProtocol` with the observed (sample, count) history
    ## so the apply log records exactly what CBS was doing.
    let deadline = getMonoTime() +
      initDuration(seconds = CapabilityServiceStableTimeoutSec)
    var reference: string = ""           ## last sample (canonical form)
    var runCount = 0
    var history: seq[CapabilityServiceSampleRun] = @[]
    while true:
      let (output, _) = runPowerShell(serviceProbeScript(svcName))
      let obs = parseServiceQuery(output)
      let sample = canonicalServiceState(obs)
      if sample == reference:
        inc runCount
        if history.len > 0:
          history[^1].count = runCount
      else:
        reference = sample
        runCount = 1
        history.add(CapabilityServiceSampleRun(sample: sample, count: 1))
      if runCount >= CapabilityServiceStableObservations:
        return
      if getMonoTime() >= deadline:
        var trace = ""
        for i, run in history:
          if i > 0: trace.add(" -> ")
          trace.add(run.sample & " x" & $run.count)
        raiseProtocol("windows.capability '" & capName &
          "' installed but its associated service '" & svcName &
          "' state is still oscillating after " &
          $CapabilityServiceStableTimeoutSec & " s: " & trace &
          " (the broker fails closed rather than returning a " &
          "transient post-install observation a same-apply " &
          "windows.service operation would race against)")
      sleep(CapabilityServiceStableIntervalMs)

  proc awaitCapabilityFinalization(op: PrivilegedOperation;
                                   restartNeeded: bool) =
    ## Wait for CBS post-install finalization to settle before the
    ## driver returns. Only runs on the INSTALL path AND only when
    ## the apply did not require a reboot (a `RestartNeeded` install
    ## has not yet completed in-place; further work happens after the
    ## operator reboots, so there is nothing to wait on here).
    if not op.capabilityInstall or restartNeeded:
      return
    # Re-observe the capability state directly — the result-shape of
    # `observeWindowsCapability` is a digest, which collapses
    # `Installed` / `InstallPending` / `Staged` into one bucket. Only
    # a true `Installed` triggers the finalization wait; a still-
    # pending install means CBS has not even reached the race yet.
    let (probe, _) = runPowerShell(
      "Get-WindowsCapability -Online -Name " &
      psQuote(op.capabilityName) & " | Format-List State")
    if parseCapabilityState(probe) != capsInstalled:
      return
    let svc = lookupCapabilityRegisteredService(op.capabilityName)
    if svc.len > 0:
      awaitCapabilityServiceStable(op.capabilityName, svc)
    else:
      # No registered-service entry for this capability — take the
      # blanket safety pause. See the constant's doc comment for the
      # rationale.
      sleep(UnknownCapabilityPostInstallPauseMs)

proc observeWindowsCapability*(op: PrivilegedOperation):
    ObservedOperationState =
  when defined(windows):
    let (output, _) = runPowerShell(
      "Get-WindowsCapability -Online -Name " &
      psQuote(op.capabilityName) & " | Format-List State")
    let state = parseCapabilityState(output)
    result.present = state != capsAbsent
    result.digestHex =
      if state == capsAbsent: ZeroDigestHex
      else: digestHexOfText(canonicalCapabilityState(state))
  else:
    raiseNotImplementedPlatform("windows.capability observe")

proc applyWindowsCapability*(op: PrivilegedOperation):
    tuple[state: ObservedOperationState; restartNeeded: bool] =
  ## Install or remove a Windows Capability via DISM. NEVER
  ## auto-reboots — `restartNeeded` is surfaced.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): once the dispatch-layer
  ## plan-time-baseline drift gate is removed (per
  ## Planner-Apply-Refresh-Model.md), the per-driver post-apply re-probe
  ## is the integrity check. When this proc returns without raising,
  ## the observed capability state matches what the operation asked for
  ## — OR `restartNeeded` is true and the capability is at its
  ## post-reboot pending target (DISM's `InstallPending` /
  ## `UninstallPending` states count as "at the desired state" per
  ## `capabilityStateMatchesDesired`). A genuine disagreement raises
  ## `EProtocol`.
  when defined(windows):
    let verb =
      if op.capabilityInstall: "Add-WindowsCapability"
      else: "Remove-WindowsCapability"
    let invocation = verb & " -Online -Name " & psQuote(op.capabilityName)
    # Run the cmdlet under explicit terminating-error semantics so the
    # script exit code reflects the operation's outcome, not a
    # `$?`-from-a-non-terminating-warning. The M69 Hyper-V runs
    # showed `Add-WindowsCapability -Online -Name 'OpenSSH.Server...'`
    # successfully kicked off the FoD install (post-call polls observed
    # `InstallPending`) but PowerShell exited 1 because the cmdlet wrote
    # a non-terminating warning to the error stream. See
    # wrapCmdletTerminating for the rationale.
    let (output, code) = runPowerShell(wrapCmdletTerminating(invocation))
    if code != 0:
      raiseProtocol("windows.capability " &
        (if op.capabilityInstall: "install" else: "uninstall") & " of '" &
        op.capabilityName & "' failed: " & output.strip())
    result.restartNeeded = capabilityRestartNeeded(output)
    # CBS post-install finalization wait. See the section banner above
    # for the OpenSSH.Server symptom and the design rationale. Only
    # the install path on a non-reboot apply enters this — uninstall
    # cannot clobber a registered service, and a `RestartNeeded`
    # install has not yet completed in-place.
    awaitCapabilityFinalization(op, result.restartNeeded)
    # Post-apply re-probe — see the contract comment above. The same
    # `Get-WindowsCapability` query `observeWindowsCapability` parses;
    # a `*Pending` state on a restart-required apply still canonicalizes
    # to the desired bucket via `capabilityStateMatchesDesired`.
    let (postOutput, _) = runPowerShell(
      "Get-WindowsCapability -Online -Name " &
      psQuote(op.capabilityName) & " | Format-List State")
    let postState = parseCapabilityState(postOutput)
    if not capabilityStateMatchesDesired(postState, op.capabilityInstall):
      raiseProtocol("windows.capability '" & op.capabilityName &
        "' post-apply observation disagrees with desired state: " &
        "observed State=" & $postState &
        "; desired " & (if op.capabilityInstall: "installed" else: "absent") &
        ". The DISM cmdlet returned exit 0 but the capability state " &
        "does not reflect the change — the driver fails closed rather " &
        "than reporting a spurious success.")
    result.state.present = postState != capsAbsent
    result.state.digestHex =
      if postState == capsAbsent: ZeroDigestHex
      else: digestHexOfText(canonicalCapabilityState(postState))
  else:
    raiseNotImplementedPlatform("windows.capability apply")

# ===========================================================================
# windows.service — Get-Service / Set-Service / Start/Stop-Service.
# ===========================================================================

when defined(windows):
  proc serviceProbeScript(name: string): string =
    ## A deterministic two-line `key=value` probe of a service so the
    ## pure parser (`parseServiceQuery`) sees an unambiguous shape.
    "$s = Get-Service -Name " & psQuote(name) &
      " -ErrorAction SilentlyContinue; " &
      "if ($null -eq $s) { 'Missing=1' } else { " &
      "'StartType=' + $s.StartType; 'Status=' + $s.Status }"

proc observeWindowsService*(op: PrivilegedOperation):
    ObservedOperationState =
  when defined(windows):
    let (output, _) = runPowerShell(serviceProbeScript(op.serviceName))
    let obs = parseServiceQuery(output)
    result.present = obs.present
    result.digestHex =
      if not obs.present: ZeroDigestHex
      else: digestHexOfText(canonicalServiceState(obs))
  else:
    raiseNotImplementedPlatform("windows.service observe")

proc applyWindowsService*(op: PrivilegedOperation): ObservedOperationState =
  ## Configure the service's start-type, then converge its runtime
  ## state. Does NOT install or remove the service — a missing
  ## service is a hard error (the capability/package owns install).
  ##
  ## CONTRACT (tightened after the M69 sshd gate failure): when this
  ## proc returns without raising, the post-apply `Get-Service` probe
  ## has been re-read and its `StartType` + `Status` match what the
  ## operation asked for. Set-Service / Start-Service / Stop-Service
  ## each shell out to PowerShell, and each returns exit-0 even when
  ## the SCM-visible state has not yet caught up to the cmdlet (the
  ## sshd scenario observed exactly this: `Set-Service -StartupType
  ## Automatic` returned 0, the SCM event log recorded the start-type
  ## change, but the immediate next `Get-Service` read `StartType=
  ## Manual Status=Stopped`). Rather than paper over the transient
  ## with a sleep-and-retry, the driver now re-probes after the
  ## cmdlets and raises `EProtocol` if the observed state disagrees
  ## with the desired state. Downstream consumers therefore see
  ## either `errorCount > 0` with an actionable diagnostic OR a fully
  ## converged service — never a silent disagreement between exit-0
  ## and the SCM database.
  when defined(windows):
    let probe = runPowerShell(serviceProbeScript(op.serviceName))
    let before = parseServiceQuery(probe.output)
    if not before.present:
      raiseProtocol("windows.service '" & op.serviceName &
        "' is not installed — windows.service configures an existing " &
        "service; install it via windows.capability or a package")
    # Start-type.
    let (stOut, stCode) = runPowerShell(
      "Set-Service -Name " & psQuote(op.serviceName) &
      " -StartupType " & op.serviceStartType)
    if stCode != 0:
      raiseProtocol("windows.service Set-Service(StartupType) of '" &
        op.serviceName & "' failed: " & stOut.strip())
    # Runtime state.
    if op.serviceRunning:
      let (rsOut, rsCode) = runPowerShell(
        "Start-Service -Name " & psQuote(op.serviceName))
      if rsCode != 0:
        raiseProtocol("windows.service Start-Service of '" &
          op.serviceName & "' failed: " & rsOut.strip())
    else:
      let (rsOut, rsCode) = runPowerShell(
        "Stop-Service -Name " & psQuote(op.serviceName) & " -Force")
      if rsCode != 0:
        raiseProtocol("windows.service Stop-Service of '" &
          op.serviceName & "' failed: " & rsOut.strip())
    # Post-apply re-probe — see the contract comment above. Uses the
    # same deterministic `key=value` shape `observeWindowsService`
    # parses, so a parser regression flags both paths.
    let (postOutput, _) = runPowerShell(serviceProbeScript(op.serviceName))
    let after = parseServiceQuery(postOutput)
    if not serviceMatchesDesired(after, op.serviceStartType, op.serviceRunning):
      raiseProtocol("windows.service '" & op.serviceName &
        "' post-apply observation disagrees with desired state: " &
        "observed StartType=" & after.startType &
        " Status=" & (if after.running: "Running" else: "Stopped") &
        " present=" & $after.present &
        "; desired StartType=" & op.serviceStartType &
        " Status=" & (if op.serviceRunning: "Running" else: "Stopped") &
        ". The Set-Service / Start-Service / Stop-Service cmdlets all " &
        "returned exit 0 but the SCM database does not reflect the " &
        "change — the driver fails closed rather than reporting a " &
        "spurious success.")
    result.present = after.present
    result.digestHex =
      if not after.present: ZeroDigestHex
      else: digestHexOfText(canonicalServiceState(after))
  else:
    raiseNotImplementedPlatform("windows.service apply")

# ===========================================================================
# windows.firewallRule — Get/New/Set/Remove-NetFirewallRule via PowerShell.
#
# A Windows Firewall rule is fully described by the (Name, DisplayName,
# Protocol, Direction, Action, LocalPort, Enabled) tuple. `Get-NetFirewall
# Rule` exposes most fields directly; `LocalPort` lives on the rule's
# associated `NetFirewallPortFilter`. The probe script stitches the two
# objects into a single deterministic `key=value` block so the parser in
# `windows_system_parse.nim` stays pure.
#
# The driver is the typed counterpart to `applyWindowsService`: on apply
# it reads current state, no-ops on a match, creates a new rule when
# absent, and updates fields in place when the rule exists but differs.
# A `Remove-NetFirewallRule` path implements the destroy direction.
# Defence-in-depth: every interpolated field is closed-set validated
# upstream (`operations.operationValidationError`) and `psQuote`d at the
# call site.
# ===========================================================================

when defined(windows):
  proc firewallProbeScript(name: string): string =
    ## Render the deterministic `key=value` probe for a firewall rule.
    ## Uses `-ErrorAction SilentlyContinue` so an absent rule yields a
    ## `Missing=1` sentinel; the rule's `LocalPort` is read via the
    ## associated `NetFirewallPortFilter`.
    "$r = Get-NetFirewallRule -Name " & psQuote(name) &
      " -ErrorAction SilentlyContinue; " &
      "if ($null -eq $r) { 'Missing=1' } else { " &
      "'Name=' + $r.Name; 'DisplayName=' + $r.DisplayName; " &
      "'Direction=' + $r.Direction; 'Action=' + $r.Action; " &
      "'Enabled=' + $r.Enabled; " &
      "$pf = $r | Get-NetFirewallPortFilter; " &
      "'Protocol=' + $pf.Protocol; 'LocalPort=' + $pf.LocalPort }"

  proc firewallEnabledArg(enabled: bool): string =
    ## `New-NetFirewallRule` / `Set-NetFirewallRule` accept `-Enabled
    ## True/False` (NOT `$true` / `$false`). Centralised so the driver
    ## stays consistent across the two cmdlets.
    if enabled: "True" else: "False"

  proc firewallLocalPortArg(port: string): string =
    ## Normalize the localPort field for the `-LocalPort` argument:
    ## an empty string substitutes `Any` (the cmdlet default).
    if port.strip().len == 0: "Any" else: port

  proc firewallDisplayNameArg(displayName, name: string): string =
    ## Default the display name to the internal name when the operator
    ## omitted it. Mirrors `canonicalFirewallRuleDesired`'s default.
    if displayName.len > 0: displayName else: name

proc observeWindowsFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-read the rule via `Get-NetFirewallRule -Name <name>`.
  ## `present` is true whenever the rule exists by that name;
  ## `digestHex` covers the canonical (Name, DisplayName, Protocol,
  ## Direction, Action, LocalPort, Enabled) tuple so an in-place
  ## drift (e.g. an operator flipped Enabled) shows up in the broker's
  ## drift gate.
  when defined(windows):
    let (output, _) = runPowerShell(firewallProbeScript(op.fwName))
    let obs = parseFirewallRuleQuery(output)
    result.present = obs.present
    result.digestHex =
      if not obs.present: ZeroDigestHex
      else: digestHexOfText(canonicalFirewallRuleState(obs))
  else:
    raiseNotImplementedPlatform("windows.firewallRule observe")

proc applyWindowsFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Reconcile the rule to the desired state. Creates it via
  ## `New-NetFirewallRule` when absent, updates it via
  ## `Set-NetFirewallRule` when present-but-differing, and is a no-op
  ## when present-and-matching. The destroy direction (`op.fwDestroy
  ## == true`) calls `Remove-NetFirewallRule`.
  ##
  ## POST-APPLY RE-PROBE CONTRACT (M82 Phase A): the per-driver
  ## post-apply re-probe is the integrity check. When this proc
  ## returns without raising, the observed rule matches the desired
  ## state (or, on the destroy path, no rule by that name exists). A
  ## genuine disagreement raises `EProtocol`.
  when defined(windows):
    let probe = runPowerShell(firewallProbeScript(op.fwName))
    let before = parseFirewallRuleQuery(probe.output)

    if op.fwDestroy:
      if before.present:
        let (rmOut, rmCode) = runPowerShell(wrapCmdletTerminating(
          "Remove-NetFirewallRule -Name " & psQuote(op.fwName)))
        if rmCode != 0:
          raiseProtocol("windows.firewallRule Remove-NetFirewallRule of '" &
            op.fwName & "' failed: " & rmOut.strip())
      # Post-apply re-probe.
      let (postOutput, _) = runPowerShell(firewallProbeScript(op.fwName))
      let after = parseFirewallRuleQuery(postOutput)
      if after.present:
        raiseProtocol("windows.firewallRule '" & op.fwName &
          "' post-apply observation reports the rule is still present " &
          "after Remove-NetFirewallRule returned exit 0 — the driver " &
          "fails closed rather than reporting a spurious success.")
      result.present = false
      result.digestHex = ZeroDigestHex
      return

    let displayName = firewallDisplayNameArg(op.fwDisplayName, op.fwName)
    let localPort = firewallLocalPortArg(op.fwLocalPort)
    let enabledArg = firewallEnabledArg(op.fwEnabled)

    if not before.present:
      # Create.
      let createInvocation =
        "New-NetFirewallRule -Name " & psQuote(op.fwName) &
        " -DisplayName " & psQuote(displayName) &
        " -Protocol " & psQuote(op.fwProtocol) &
        " -Direction " & psQuote(op.fwDirection) &
        " -Action " & psQuote(op.fwAction) &
        " -LocalPort " & psQuote(localPort) &
        " -Enabled " & enabledArg
      let (cOut, cCode) = runPowerShell(wrapCmdletTerminating(createInvocation))
      if cCode != 0:
        raiseProtocol("windows.firewallRule New-NetFirewallRule of '" &
          op.fwName & "' failed: " & cOut.strip())
    elif not firewallRuleMatchesDesired(before, op.fwName, displayName,
        op.fwProtocol, op.fwDirection, op.fwAction, localPort, op.fwEnabled):
      # Update fields in place. CRITICAL: Set-NetFirewallRule uses
      # `-Name` as the IDENTIFIER (selecting the by-Name parameter set);
      # the new display name is set via `-NewDisplayName`, NOT
      # `-DisplayName` (which is itself a SECOND IDENTIFIER in a
      # different parameter set, so combining `-Name` and `-DisplayName`
      # fails with "Parameter set cannot be resolved"). `-Direction`,
      # `-Action`, and `-Enabled` flow in as ordinary property updates.
      # Set-NetFirewallRule does NOT update the port filter directly;
      # the matching Set-NetFirewallPortFilter call is needed to flip
      # Protocol or LocalPort.
      let setInvocation =
        "Set-NetFirewallRule -Name " & psQuote(op.fwName) &
        " -NewDisplayName " & psQuote(displayName) &
        " -Direction " & psQuote(op.fwDirection) &
        " -Action " & psQuote(op.fwAction) &
        " -Enabled " & enabledArg
      let (sOut, sCode) = runPowerShell(wrapCmdletTerminating(setInvocation))
      if sCode != 0:
        raiseProtocol("windows.firewallRule Set-NetFirewallRule of '" &
          op.fwName & "' failed: " & sOut.strip())
      let portInvocation =
        "Get-NetFirewallRule -Name " & psQuote(op.fwName) &
        " | Set-NetFirewallPortFilter" &
        " -Protocol " & psQuote(op.fwProtocol) &
        " -LocalPort " & psQuote(localPort)
      let (pOut, pCode) = runPowerShell(wrapCmdletTerminating(portInvocation))
      if pCode != 0:
        raiseProtocol("windows.firewallRule Set-NetFirewallPortFilter of '" &
          op.fwName & "' failed: " & pOut.strip())

    # Post-apply re-probe.
    let (postOutput, _) = runPowerShell(firewallProbeScript(op.fwName))
    let after = parseFirewallRuleQuery(postOutput)
    if not firewallRuleMatchesDesired(after, op.fwName, displayName,
        op.fwProtocol, op.fwDirection, op.fwAction, localPort, op.fwEnabled):
      raiseProtocol("windows.firewallRule '" & op.fwName &
        "' post-apply observation disagrees with desired state: " &
        "observed " & canonicalFirewallRuleState(after) &
        "; desired " & canonicalFirewallRuleDesired(op.fwName, displayName,
          op.fwProtocol, op.fwDirection, op.fwAction, localPort,
          op.fwEnabled) &
        ". The New-/Set-NetFirewallRule cmdlets returned exit 0 but the " &
        "firewall ruleset does not reflect the change — the driver fails " &
        "closed rather than reporting a spurious success.")
    result.present = after.present
    result.digestHex =
      if not after.present: ZeroDigestHex
      else: digestHexOfText(canonicalFirewallRuleState(after))
  else:
    raiseNotImplementedPlatform("windows.firewallRule apply")

proc destroyWindowsFirewallRule*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Remove the named firewall rule. Convenience wrapper used by the
  ## rollback engine; the dispatcher itself goes through
  ## `applyWindowsFirewallRule` with `fwDestroy = true`.
  when defined(windows):
    let destroyOp = PrivilegedOperation(kind: pokWindowsFirewallRule,
      address: op.address,
      fwName: op.fwName,
      fwDisplayName: op.fwDisplayName,
      fwProtocol: op.fwProtocol,
      fwDirection: op.fwDirection,
      fwAction: op.fwAction,
      fwLocalPort: op.fwLocalPort,
      fwEnabled: op.fwEnabled,
      fwDestroy: true)
    result = applyWindowsFirewallRule(destroyOp)
  else:
    raiseNotImplementedPlatform("windows.firewallRule destroy")

# ===========================================================================
# windows.acl — `icacls` + `takeown` for NTFS Discretionary Access
# Control List management.
#
# `icacls` is a plain Win32 console tool, NOT a PowerShell cmdlet — it
# parses argv via the standard cmd-shell rules. The driver therefore
# uses `quoteShell` (double-quote semantics) for every interpolated
# value, NOT `psQuote`. The closed-set validator
# (`operationValidationError` for `pokWindowsAcl`) is layer 1;
# `quoteShell` here is layer 2.
#
# The driver is additive-only on the ACE set: a re-apply that finds
# every desired ACE present + the inheritance-mode constraint
# satisfied is a no-op. Extra ACEs ALREADY on disk are NOT considered
# drift (the operator may have local additions; the driver does not
# strip them unless a `disabled-replace` inheritance mode is set). On
# destroy, `icacls /reset` re-inherits from the parent.
# ===========================================================================

when defined(windows):
  proc icaclsQuery(path: string): tuple[output: string; code: int] =
    ## Run `icacls <path>` and return combined stdout+stderr + exit
    ## code. `quoteShell` handles spaces in the path (e.g.
    ## `C:\Program Files\...`).
    let cmd = "icacls " & quoteShell(path)
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc takeownOf(path, owner: string): tuple[output: string; code: int] =
    ## Take ownership of `path` to `owner`. The driver issues two
    ## calls: `takeown /F <path> /A` to seize ownership (always to
    ## the Administrators group when `/A` is set; without `/A` the
    ## current Administrator user takes ownership) and then `icacls
    ## <path> /setowner <owner>` to pin it to the declared principal.
    ## The driver returns the second call's output; the first call's
    ## failure is non-fatal (the file may already be owned by an
    ## Administrator-group account, in which case `takeown` is a
    ## no-op).
    let takeownCmd = "takeown /F " & quoteShell(path) & " /A"
    discard execCmdEx(takeownCmd)
    let setownerCmd = "icacls " & quoteShell(path) &
      " /setowner " & quoteShell(owner)
    let (output, code) = execCmdEx(setownerCmd)
    (output, code)

  proc icaclsInheritanceCmd(path, mode: string):
      tuple[output: string; code: int] =
    ## Apply the inheritance-mode change. `disabled-replace` calls
    ## `icacls /inheritance:r` (disable + remove inherited entries);
    ## `disabled-convert` calls `icacls /inheritance:d` (disable +
    ## convert inherited entries to explicit). `enabled` is a no-op
    ## from the driver's perspective — icacls has no "re-enable
    ## inheritance" verb that does not destroy the current ACL, and
    ## the cache-hit path keeps the live state.
    let flag =
      case mode
      of "disabled-replace": "r"
      of "disabled-convert": "d"
      else: ""
    if flag.len == 0:
      return ("", 0)
    let cmd = "icacls " & quoteShell(path) & " /inheritance:" & flag
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc icaclsGrant(path, entry: string):
      tuple[output: string; code: int] =
    ## `icacls /grant` is the idempotent add — it REPLACES any
    ## existing ACE for the principal at the SAME inheritance level
    ## with the new spec. The entry is passed as ONE argument so the
    ## spec's parentheses don't get parsed as cmd-shell groups.
    let cmd = "icacls " & quoteShell(path) & " /grant " &
      quoteShell(entry)
    let (output, code) = execCmdEx(cmd)
    (output, code)

  proc icaclsReset(path: string): tuple[output: string; code: int] =
    ## `icacls /reset` clears any explicit ACEs and re-inherits the
    ## parent's ACL. Used by the destroy path.
    let cmd = "icacls " & quoteShell(path) & " /reset"
    let (output, code) = execCmdEx(cmd)
    (output, code)

proc observeWindowsAcl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the file/directory's ACL via `icacls <path>`. The
  ## observation digest projects onto the DESIRED entry set — only
  ## ACEs the operator declared appear in the digest, so a third
  ## party's extra ACE does NOT register as drift. An absent target
  ## yields the absent sentinel.
  when defined(windows):
    let (output, _) = icaclsQuery(op.aclPath)
    let obs = parseIcaclsOutput(output, op.aclPath)
    result.present = obs.present
    result.digestHex =
      if not obs.present: ZeroDigestHex
      else: digestHexOfText(canonicalAclState(obs, op.aclPath,
        op.aclOwner, op.aclEntries, op.aclInheritanceMode))
  else:
    raiseNotImplementedPlatform("windows.acl observe")

proc applyWindowsAcl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Reconcile the file/directory's ACL to the desired state:
  ##
  ##   1. If `aclOwner` is set, take ownership (`takeown /F /A` +
  ##      `icacls /setowner`).
  ##   2. If `aclInheritanceMode != enabled`, apply
  ##      `icacls /inheritance:r` / `/inheritance:d` once. The
  ##      cache-hit predicate already short-circuits the no-op case.
  ##   3. For every desired ACE that is missing on disk (or differs),
  ##      invoke `icacls /grant <ACE>`. icacls's grant verb is
  ##      idempotent — re-running with the same `<principal>:<perms>`
  ##      replaces the existing entry.
  ##   4. Post-apply re-probe via `icacls <path>` to assert the
  ##      observed ACL contains every desired ACE; a disagreement
  ##      raises `EProtocol`.
  ##
  ## The destroy direction (`op.aclDestroy == true`) calls
  ## `icacls /reset` to re-inherit from the parent.
  when defined(windows):
    if op.aclDestroy:
      let (rmOut, rmCode) = icaclsReset(op.aclPath)
      if rmCode != 0:
        raiseProtocol("windows.acl `icacls /reset` of '" &
          op.aclPath & "' failed: " & rmOut.strip())
      # Post-apply re-probe — confirm the path is still observable
      # (a reset does not remove the file, just re-inherits the ACL).
      let (postOutput, _) = icaclsQuery(op.aclPath)
      let after = parseIcaclsOutput(postOutput, op.aclPath)
      result.present = after.present
      result.digestHex = ZeroDigestHex
      return

    # 1. Owner change (optional).
    if op.aclOwner.len > 0:
      let (ownOut, ownCode) = takeownOf(op.aclPath, op.aclOwner)
      if ownCode != 0:
        raiseProtocol("windows.acl `icacls /setowner " &
          op.aclOwner & "` of '" & op.aclPath & "' failed: " &
          ownOut.strip())

    # 2. Inheritance-mode change (optional).
    let mode =
      if op.aclInheritanceMode.len > 0: op.aclInheritanceMode
      else: "enabled"
    if mode != "enabled":
      let (inhOut, inhCode) = icaclsInheritanceCmd(op.aclPath, mode)
      if inhCode != 0:
        raiseProtocol("windows.acl `icacls /inheritance` (mode=" &
          mode & ") of '" & op.aclPath & "' failed: " &
          inhOut.strip())

    # 3. Grant every declared ACE. icacls's grant is idempotent so
    #    we don't need to check absence first — but re-emitting
    #    unchanged entries triggers a no-op print, not a state
    #    change, so the live-state cache-hit branch handles the true
    #    no-op case higher up the dispatch.
    let (preOutput, _) = icaclsQuery(op.aclPath)
    let before = parseIcaclsOutput(preOutput, op.aclPath)
    for ace in op.aclEntries:
      # Skip if the desired ACE is already present (additive
      # semantics — re-emitting an unchanged ACE is safe but wastes
      # a process spawn).
      let normalized = normalizeAclEntry(ace)
      var alreadyPresent = false
      for o in before.entries:
        if normalizeAclEntry(o) == normalized:
          alreadyPresent = true
          break
      if alreadyPresent:
        continue
      let (gOut, gCode) = icaclsGrant(op.aclPath, ace)
      if gCode != 0:
        raiseProtocol("windows.acl `icacls /grant " & ace &
          "` of '" & op.aclPath & "' failed: " & gOut.strip())

    # 4. Post-apply re-probe.
    let (postOutput, _) = icaclsQuery(op.aclPath)
    let after = parseIcaclsOutput(postOutput, op.aclPath)
    if not aclMatchesDesired(after, op.aclPath, op.aclOwner,
        op.aclEntries, mode):
      raiseProtocol("windows.acl '" & op.aclPath &
        "' post-apply observation disagrees with desired state: " &
        "observed " & canonicalAclState(after, op.aclPath,
          op.aclOwner, op.aclEntries, mode) &
        "; desired " & canonicalAclDesired(op.aclPath, op.aclOwner,
          op.aclEntries, mode) &
        ". The `icacls /grant` invocations returned exit 0 but the " &
        "ACL does not contain every declared ACE — the driver " &
        "fails closed rather than reporting a spurious success.")
    result.present = after.present
    result.digestHex =
      if not after.present: ZeroDigestHex
      else: digestHexOfText(canonicalAclState(after, op.aclPath,
        op.aclOwner, op.aclEntries, mode))
  else:
    raiseNotImplementedPlatform("windows.acl apply")

proc destroyWindowsAcl*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Reset the ACL to its inherited defaults. Convenience wrapper
  ## used by the rollback engine; the dispatcher itself goes through
  ## `applyWindowsAcl` with `aclDestroy = true`.
  when defined(windows):
    let destroyOp = PrivilegedOperation(kind: pokWindowsAcl,
      address: op.address,
      aclPath: op.aclPath,
      aclOwner: op.aclOwner,
      aclEntries: op.aclEntries,
      aclInheritanceMode: op.aclInheritanceMode,
      aclDestroy: true)
    result = applyWindowsAcl(destroyOp)
  else:
    raiseNotImplementedPlatform("windows.acl destroy")

# ===========================================================================
# os.timezone — `tzutil /g` / `tzutil /s <windowsName>` on Windows.
#
# The IANA -> Windows mapping lives in `os_system_parse.IanaToWindows
# TzTable`; an unmapped IANA value is refused at the closed-set validator
# (`operationValidationError`) so the driver only ever sees a mapped
# value when it gets called. Defence-in-depth: the driver `psQuote`s the
# Windows name as well.
# ===========================================================================

proc observeWindowsOsTimezone*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the active Windows timezone via `tzutil /g`. The probe
  ## returns the Windows-flavoured name (e.g. `FLE Standard Time`); we
  ## reverse-map it to the canonical IANA digest so observe and apply
  ## compare on the same scale. An unmapped Windows name (e.g. an
  ## operator-installed custom zone) digests to the absent sentinel so
  ## any apply against a known IANA value triggers a write.
  ##
  ## Many-to-one disambiguation: the Windows-to-IANA mapping is many-
  ## to-one (e.g. `FLE Standard Time` covers Helsinki, Kiev, Sofia,
  ## Kyiv). `reverseLookupIanaTimezoneName` consults `op.tzIana` as the
  ## preferred IANA name so the post-apply re-probe of an
  ## `Europe/Sofia` apply on a system whose live Windows tz is now
  ## `FLE Standard Time` returns `Europe/Sofia` (the operator's stated
  ## intent) instead of the first-table-match `Europe/Helsinki` — which
  ## would have produced a spurious "post-apply observation disagrees
  ## with desired state" error.
  when defined(windows):
    let (output, _) = execCmdEx("tzutil /g")
    let observedWin = parseTzutilOutput(output)
    let observedIana = reverseLookupIanaTimezoneName(observedWin, op.tzIana)
    result.present = observedIana.len > 0
    result.digestHex =
      if not result.present: ZeroDigestHex
      else: digestHexOfText(canonicalTimezoneState(observedIana))
  else:
    raiseNotImplementedPlatform("os.timezone observe (Windows path)")

proc applyWindowsOsTimezone*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Set the Windows timezone via `tzutil /s <windowsName>`. The
  ## Windows name is looked up from the embedded mapping table at apply
  ## time (the closed-set validator already gated on it). Post-apply
  ## re-probe via `tzutil /g`.
  when defined(windows):
    let windowsName = lookupWindowsTimezoneName(op.tzIana)
    if windowsName.len == 0:
      raiseProtocol("os.timezone IANA name '" & op.tzIana &
        "' is not in the embedded IANA -> Windows mapping table " &
        "(should have been caught by operationValidationError)")
    # `tzutil` is a plain Windows console tool, NOT a PowerShell
    # cmdlet — it parses argv via the standard cmd-shell rules where
    # single quotes are LITERAL characters and double quotes are the
    # only argument-quoting mechanism. `psQuote` would emit a value
    # like `'FLE Standard Time'`, which tzutil sees as three separate
    # arguments and rejects with `TZUTIL: Invalid number of arguments
    # for /s`. Use `quoteShell` (double-quote semantics) so the
    # multi-word Windows tz name reaches tzutil as ONE argument.
    let cmd = "tzutil /s " & quoteShell(windowsName)
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      raiseProtocol("os.timezone tzutil /s of '" & op.tzIana &
        "' (Windows name '" & windowsName & "') failed: " &
        output.strip())
    # Post-apply re-probe.
    let post = observeWindowsOsTimezone(op)
    let desiredHex = digestHexOfText(canonicalTimezoneDesired(op.tzIana))
    if not post.present or post.digestHex != desiredHex:
      raiseProtocol("os.timezone '" & op.tzIana &
        "' post-apply observation disagrees with desired state. " &
        "`tzutil /s` returned exit 0 but a re-probe via `tzutil /g` " &
        "shows a different timezone — the driver fails closed.")
    result = post
  else:
    raiseNotImplementedPlatform("os.timezone apply (Windows path)")

# ===========================================================================
# os.hostname — `hostname` / `Rename-Computer` on Windows.
#
# `Rename-Computer` always requires a reboot to take effect; the driver
# surfaces `RestartNeeded = true` in the post-apply observation and
# NEVER auto-reboots. The observe path uses the `hostname` CLI (which
# returns the current effective hostname, not the pending rename
# target) so a cache-hit re-apply against the live hostname is a no-op.
# ===========================================================================

proc observeWindowsOsHostname*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Re-observe the current effective hostname via the `hostname` CLI.
  when defined(windows):
    let (output, code) = execCmdEx("hostname")
    if code != 0:
      result.present = false
      result.digestHex = ZeroDigestHex
      return
    let observed = parseHostnameOutput(output)
    result.present = observed.len > 0
    result.digestHex =
      if not result.present: ZeroDigestHex
      else: digestHexOfText(canonicalHostnameState(observed))
  else:
    raiseNotImplementedPlatform("os.hostname observe (Windows path)")

proc applyWindowsOsHostname*(op: PrivilegedOperation):
    ObservedOperationState =
  ## Rename the computer via `Rename-Computer -NewName <name> -Force`.
  ## On success the host needs a reboot to finalize the change; the
  ## driver surfaces `RestartNeeded = true` and the live `hostname`
  ## still returns the OLD name until the reboot. The desired digest
  ## therefore won't match the post-apply observation until after the
  ## reboot — we accept that and surface RestartNeeded so the dispatch
  ## layer reports a pending-reboot apply rather than failing closed.
  when defined(windows):
    let invocation =
      "Rename-Computer -NewName " & psQuote(op.hostnameName) & " -Force"
    let (output, code) = runPowerShell(wrapCmdletTerminating(invocation))
    if code != 0:
      raiseProtocol("os.hostname Rename-Computer to '" &
        op.hostnameName & "' failed: " & output.strip())
    # Post-apply re-probe. The new name is staged for the next reboot;
    # the live `hostname` still reports the old one. Surface
    # RestartNeeded so the operator knows to schedule the reboot. The
    # digest reflects the LIVE (old) hostname so the dispatch layer's
    # post-apply integrity check does not raise a spurious mismatch.
    let post = observeWindowsOsHostname(op)
    let desiredHex = digestHexOfText(canonicalHostnameDesired(op.hostnameName))
    result = post
    if post.digestHex != desiredHex:
      result.restartNeeded = true
  else:
    raiseNotImplementedPlatform("os.hostname apply (Windows path)")

