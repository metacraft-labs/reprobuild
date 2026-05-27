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
import ./system_value
import ./windows_system_parse

when defined(windows):
  import std/[osproc]

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
  when defined(windows):
    if op.hklmDestroy:
      deleteHklmRegistryValue(op)
    else:
      writeHklmRegistryValue(op)
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
    result.state = observeWindowsOptionalFeature(op)
  else:
    raiseNotImplementedPlatform("windows.optionalFeature apply")

# ===========================================================================
# windows.capability — Add/Get/Remove-WindowsCapability via PowerShell.
# ===========================================================================

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
    result.state = observeWindowsCapability(op)
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
