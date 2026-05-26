<#
  run-hyperv-m69-system.ps1 - HOST-SIDE per-test runner for the M69
  Hyper-V destructive-gate harness.

  Reverts the harness VM to the named snapshot, starts it, stages the
  gate binary + repro.exe + dependencies via Copy-VMFile, runs the gate
  inside the VM via Invoke-Command -VMName with the appropriate
  REPRO_M69_*_VM env var set, captures stdout / stderr / exit, writes
  artifacts to a per-test output dir, and stops the VM in a `finally`.

  HOST SAFETY:
    * Touches exactly ONE VM: `repro-m69-hyperv`. No other VM on the
      host is queried, started, stopped, or altered.
    * Never `Save-VM`s (a saved-state revert would desync the
      snapshot). Always `Stop-VM -TurnOff`.
    * The per-test output dir is cleared on entry; only this dir is
      ever modified on the host.
    * The gates' real DISM / capability / service / VS mutations happen
      INSIDE the VM only; they evaporate on the next snapshot revert.

  Usage:
    pwsh -File run-hyperv-m69-system.ps1
                -Gate <feature-capability|vs-installer>
                [-Scenario <base-clean|base-with-vs>]
                [-OutDir D:\metacraft\hyperv-m69-system-out]
                [-GateTimeoutMinutes <int>]
                [-KeepVmRunning]    # debug: skip Stop-VM in finally
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('feature-capability','vs-installer')]
  [string]$Gate,

  [ValidateSet('base-clean','base-with-vs')]
  [string]$Scenario = '',

  [string]$OutDir = 'D:\metacraft\hyperv-m69-system-out',

  [int]$GateTimeoutMinutes = 0,

  [switch]$KeepVmRunning
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$VmName        = 'repro-m69-hyperv'
$CredCachePath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'

# Per-gate parameters: which env var, which exe, which default
# scenario (snapshot), default timeout.
$GateConfig = @{
  'feature-capability' = @{
    Exe        = 'e2e_windows_optional_feature_and_capability.exe'
    EnvVar     = 'REPRO_M69_FEATURE_VM'
    DefaultScenario = 'base-clean'
    DefaultTimeoutMin = 30
  }
  'vs-installer' = @{
    Exe        = 'e2e_windows_vs_installer.exe'
    EnvVar     = 'REPRO_M69_VSINSTALLER_VM'
    DefaultScenario = 'base-clean'     # current gate has only fresh-install
    DefaultTimeoutMin = 90              # VS install is multi-GB
  }
}

$cfg = $GateConfig[$Gate]
if (-not $Scenario) { $Scenario = $cfg.DefaultScenario }
if ($GateTimeoutMinutes -le 0) { $GateTimeoutMinutes = $cfg.DefaultTimeoutMin }

$ReproBinHost  = 'D:\metacraft\reprobuild\build\bin'
$TestBinHost   = 'D:\metacraft\reprobuild\build\test-bin'
$PerTestOut    = Join-Path $OutDir "$Gate-$Scenario"

$VmHarness     = 'C:\harness'
$VmReproDir    = "$VmHarness\repro"
$VmGateBinDir  = "$VmHarness\gate-bin"
$VmGateExe     = "$VmGateBinDir\$($cfg.Exe)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Info($m) { Write-Host "[run] $m" }
function Warn($m) { Write-Host "[run] WARNING: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[run] ERROR: $m"   -ForegroundColor Red }

function Get-VmOrNull([string]$name) {
  try { return Get-VM -Name $name -ErrorAction Stop } catch { return $null }
}

function Wait-VmPSDirectReady {
  param(
    [string]$Name,
    [System.Management.Automation.PSCredential]$Credential,
    [int]$TimeoutSec
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $startedAt = Get-Date
  $lastReport = $startedAt
  while ((Get-Date) -lt $deadline) {
    $vm = Get-VmOrNull $Name
    if ($vm -and $vm.State -eq 'Running') {
      try {
        $hostnameRaw = Invoke-Command -VMName $Name -Credential $Credential `
          -ScriptBlock { hostname } -ErrorAction Stop
        if ($hostnameRaw) {
          Info "  PowerShell Direct ready - guest hostname: $hostnameRaw"
          return $true
        }
      } catch { }
    }
    if (((Get-Date) - $lastReport).TotalSeconds -ge 15) {
      $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
      $st = if ($vm) { $vm.State } else { 'absent' }
      Info ("  waiting for PowerShell Direct ... ${elapsed}s elapsed (state=" + $st + ")")
      $lastReport = Get-Date
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Wait-VmGuestServiceInterfaceReady {
  param(
    [string]$Name,
    [int]$TimeoutSec
  )
  # The Guest Service Interface integration service is what
  # `Copy-VMFile` rides on. It is INDEPENDENT of PowerShell Direct
  # (PSDirect goes over VMBus; Copy-VMFile goes over GSI). On a
  # freshly-reverted VM, PSDirect can come up several seconds before
  # the GSI integration service reaches `PrimaryStatusDescription =
  # 'OK'`. If `Copy-VMFile` is invoked while GSI is still in
  # `No Contact`, the cmdlet REPORTS SUCCESS but silently no-ops —
  # nothing is actually copied. The subsequent in-VM gate invocation
  # then fails with "Hyper-V socket target process has ended" because
  # the staged directory is empty.
  #
  # Poll until GSI reports `OK` (or the timeout elapses). Both
  # readiness signals must be green before we begin staging binaries.
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $startedAt = Get-Date
  $lastReport = $startedAt
  $lastStatus = ''
  while ((Get-Date) -lt $deadline) {
    try {
      $gsi = Get-VMIntegrationService -VMName $Name `
        -Name 'Guest Service Interface' -ErrorAction Stop
      $lastStatus = "$($gsi.PrimaryStatusDescription)"
      if ($gsi.Enabled -and $lastStatus -eq 'OK') {
        Info "  Guest Service Interface ready (PrimaryStatusDescription=OK)"
        return $true
      }
    } catch {
      $lastStatus = "query-error: $_"
    }
    if (((Get-Date) - $lastReport).TotalSeconds -ge 10) {
      $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
      Info ("  waiting for Guest Service Interface ... ${elapsed}s elapsed " +
            "(PrimaryStatusDescription=" + $lastStatus + ")")
      $lastReport = Get-Date
    }
    Start-Sleep -Seconds 2
  }
  Warn ("  Guest Service Interface did not reach 'OK' within ${TimeoutSec}s " +
        "(last status='$lastStatus')")
  return $false
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Info ("=" * 70)
Info "M69 Hyper-V destructive-gate runner"
Info ("=" * 70)
Info "gate:        $Gate"
Info "scenario:    $Scenario"
Info "vm:          $VmName"
Info "out dir:     $PerTestOut"
Info "gate exe:    $($cfg.Exe)"
Info "env var:     $($cfg.EnvVar)=1"
Info "timeout:     $GateTimeoutMinutes min"

# Hyper-V module
try {
  Import-Module Hyper-V -ErrorAction Stop
} catch {
  Fail "Hyper-V module not importable: $_"
  Fail "Is the Microsoft-Hyper-V Windows Optional Feature enabled?"
  exit 1
}

# VM exists
$vm = Get-VmOrNull $VmName
if (-not $vm) {
  Fail "VM '$VmName' does not exist. Run provision-base-vm.ps1 first."
  exit 1
}

# Snapshot exists
try {
  $snap = Get-VMSnapshot -VMName $VmName -Name $Scenario -ErrorAction Stop
  Info "  snapshot '$Scenario' present (created $($snap.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')))"
} catch {
  Fail "snapshot '$Scenario' does not exist on VM '$VmName'. Run provision-base-vm.ps1 first."
  exit 1
}

# Credential
if (-not (Test-Path $CredCachePath)) {
  Fail "guest credential cache missing: $CredCachePath"
  Fail "Run provision-base-vm.ps1 first - it will prompt for the guest credential."
  exit 1
}
$cred = $null
try { $cred = Import-Clixml -Path $CredCachePath } catch {
  Fail "could not load credential from $CredCachePath : $_"
  exit 1
}

# Host-side binaries
foreach ($f in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
  $p = Join-Path $ReproBinHost $f
  if (-not (Test-Path $p)) {
    Fail "missing host-side repro artifact: $p"
    Fail "Build first (in the dev shell):"
    Fail "  nim c --out:build/bin/repro apps/repro/repro.nim"
    Fail "  Copy-Item build/repro-launcher.exe build/bin/repro-launcher.exe"
    exit 1
  }
}
$gateBinHost = Join-Path $TestBinHost $cfg.Exe
if (-not (Test-Path $gateBinHost)) {
  Fail "missing host-side gate binary: $gateBinHost"
  Fail "Build first (in the dev shell):"
  Fail "  just e2e_$($Gate -replace '-','_')"
  exit 1
}

# Per-test out dir
if (Test-Path $PerTestOut) {
  Info "clearing per-test out dir $PerTestOut"
  Get-ChildItem -LiteralPath $PerTestOut -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
  New-Item -ItemType Directory -Path $PerTestOut -Force | Out-Null
}

# Started-checkpoint, written FIRST so we can distinguish run-started vs.
# pre-existing artifacts on disk.
$startedAt = Get-Date
Set-Content -Path (Join-Path $PerTestOut '_run-started.txt') `
  -Value ("run-hyperv-m69-system.ps1 started $($startedAt.ToString('yyyy-MM-dd HH:mm:ss')); gate=$Gate scenario=$Scenario") `
  -Encoding ascii

# Snapshot before
$beforeLog = Join-Path $PerTestOut '00-vm-state.log'
"=== VM state BEFORE run ($($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))) ===" | Set-Content -Path $beforeLog -Encoding utf8
Get-VM -Name $VmName | Format-List Name,State,Generation,ProcessorCount,Status,Uptime | Out-String | Add-Content -Path $beforeLog
Get-VMSnapshot -VMName $VmName | Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName | Out-String | Add-Content -Path $beforeLog
Get-VMIntegrationService -VMName $VmName | Format-Table Name,Enabled,PrimaryStatusDescription | Out-String | Add-Content -Path $beforeLog

# ---------------------------------------------------------------------------
# Per-test step accumulator (RESULT.txt)
# ---------------------------------------------------------------------------
$steps = [ordered]@{}
function Record($k, $v) {
  $steps[$k] = $v
  Info ("  step '$k' -> $v")
}

# ---------------------------------------------------------------------------
# Main lifecycle - try/finally so Stop-VM always runs
# ---------------------------------------------------------------------------
$gateExitCode = $null
$gateVerdict  = 'UNKNOWN'

try {
  # ---- Step 1: revert to snapshot ----------------------------------------
  # If the VM is running, stop first - Restore-VMCheckpoint will refuse a
  # running VM.
  if ($vm.State -ne 'Off') {
    Info "VM was in state $($vm.State); stopping before snapshot revert"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  }
  Info "Restore-VMCheckpoint -VMName $VmName -Name $Scenario"
  Restore-VMCheckpoint -VMName $VmName -Name $Scenario -Confirm:$false
  Record 'revert' 'OK'

  # ---- Step 2: start VM ---------------------------------------------------
  Info "Start-VM"
  Start-VM -Name $VmName
  $ready = Wait-VmPSDirectReady -Name $VmName -Credential $cred -TimeoutSec 300
  if (-not $ready) {
    Record 'boot' 'TIMEOUT'
    throw "VM did not come up on PowerShell Direct within 5 min"
  }
  Record 'boot' 'OK'

  # Separately wait for the Guest Service Interface (GSI) integration
  # service. Copy-VMFile rides on GSI, not on VMBus/PSDirect, and the
  # two readiness signals are NOT coupled. On a freshly-reverted VM,
  # PSDirect can be green while GSI is still in 'No Contact', which
  # makes the first few `Copy-VMFile` calls silently no-op (report
  # success, copy nothing). Skipping this wait is the race that left
  # the gate directory empty in the M69 Hyper-V runs.
  $gsiReady = Wait-VmGuestServiceInterfaceReady -Name $VmName -TimeoutSec 60
  if (-not $gsiReady) {
    Record 'gsi-ready' 'TIMEOUT'
    throw "Guest Service Interface did not report 'OK' within 60 s"
  }
  Record 'gsi-ready' 'OK'

  # ---- Step 3: prepare harness dirs inside VM ----------------------------
  Info "preparing $VmHarness inside the VM"
  Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    param($root, $reproDir, $gateBinDir)
    foreach ($d in @($root, $reproDir, $gateBinDir)) {
      if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
      } else {
        # Wipe pre-existing contents (so a re-revert that didn't actually
        # touch the harness dir doesn't leave a stale exe in place).
        Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
          Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  } -ArgumentList @($VmHarness, $VmReproDir, $VmGateBinDir) | Out-Null
  Record 'prep-harness-dirs' 'OK'

  # ---- Step 4: Copy-VMFile the binaries in -------------------------------
  Info "Copy-VMFile: staging repro binaries into $VmReproDir"
  foreach ($f in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
    $src = Join-Path $ReproBinHost $f
    $dst = "$VmReproDir\$f"
    Info "  $src -> $dst"
    Copy-VMFile -Name $VmName -SourcePath $src -DestinationPath $dst -CreateFullPath -FileSource Host -Force
  }
  Info "Copy-VMFile: staging gate binary into $VmGateBinDir"
  Copy-VMFile -Name $VmName -SourcePath $gateBinHost -DestinationPath $VmGateExe -CreateFullPath -FileSource Host -Force
  Record 'stage-binaries' 'OK'

  # ---- Step 4b: stage vs_buildtools.exe next to repro.exe ----------------
  # The M69 vsInstaller driver dispatches a FRESH install through the
  # edition-specific bootstrapper `vs_<edition>.exe` (the resident
  # `vs_installer.exe` cannot perform a true fresh install on a clean
  # machine). The driver looks for the bootstrapper next to the running
  # `repro` binary, in `%TEMP%`, and in `%LOCALAPPDATA%\Repro\`. The
  # provisioning script (`provision-base-vm.ps1` Step 12) downloads
  # `vs_buildtools.exe` to the GUEST's `$env:TEMP` AT PROVISIONING TIME
  # ONLY — that copy lives in the diff disk that gets discarded on
  # snapshot revert, so by the time the runner reverts to a snapshot the
  # bootstrapper is gone. We therefore stage a host-side copy beside
  # `repro.exe` here, every run.
  #
  # Host path choice: `D:\metacraft\hyperv-m69-system-cache\
  # vs_buildtools.exe`. The cache dir is documented as the harness's
  # caching location (alongside the dev VHDX) in
  # `reprobuild-specs/Destructive-Gate-Test-Environments.md` §4. The
  # provisioning script does NOT pre-populate it with the bootstrapper
  # — it downloads in-VM — so the user must drop the binary there once
  # (via `Invoke-WebRequest https://aka.ms/vs/17/release/vs_buildtools.exe`)
  # for the vs-installer gate to be runnable. Absence here is non-fatal:
  # the feature-capability gate doesn't need it, and the vs-installer
  # gate's driver will surface a clear "bootstrapper not staged" error.
  $VsBootstrapHostPath = 'D:\metacraft\hyperv-m69-system-cache\vs_buildtools.exe'
  if (Test-Path $VsBootstrapHostPath) {
    $dst = "$VmReproDir\vs_buildtools.exe"
    Info "Copy-VMFile: staging vs_buildtools.exe into $dst"
    try {
      Copy-VMFile -Name $VmName -SourcePath $VsBootstrapHostPath -DestinationPath $dst -CreateFullPath -FileSource Host -Force
      Record 'stage-vs-bootstrapper' 'OK'
    } catch {
      Warn "  Copy-VMFile of vs_buildtools.exe failed: $_"
      Record 'stage-vs-bootstrapper' "FAILED: $_"
    }
  } else {
    Warn "  vs_buildtools.exe not found at $VsBootstrapHostPath"
    Warn "  vs-installer gate will fail with bootstrapper-not-staged"
    Warn "  (drop it there via: Invoke-WebRequest https://aka.ms/vs/17/release/vs_buildtools.exe -OutFile $VsBootstrapHostPath)"
    Record 'stage-vs-bootstrapper' "SKIPPED: $VsBootstrapHostPath missing"
  }

  # ---- Step 5: run the gate ----------------------------------------------
  $envVarName = $cfg.EnvVar
  Info "running gate: $VmGateExe with $envVarName=1"
  $gateScript = {
    param($gateExe, $envVar, $reproDir)
    Set-Item -Path "Env:$envVar" -Value '1'
    Set-Item -Path 'Env:REPRO_TEST_BIN_DIR' -Value $reproDir
    $stdoutF = Join-Path $env:TEMP "gate-out.txt"
    $stderrF = Join-Path $env:TEMP "gate-err.txt"
    if (Test-Path $stdoutF) { Remove-Item $stdoutF -Force }
    if (Test-Path $stderrF) { Remove-Item $stderrF -Force }
    $p = Start-Process -FilePath $gateExe -NoNewWindow -PassThru `
           -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
    $null = $p.Handle
    $p.WaitForExit()
    $stdout = if (Test-Path $stdoutF) { Get-Content $stdoutF -Raw } else { '' }
    $stderr = if (Test-Path $stderrF) { Get-Content $stderrF -Raw } else { '' }
    Remove-Item $stdoutF, $stderrF -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      Stdout   = $stdout
      Stderr   = $stderr
    }
  }
  $gateTimeoutSec = $GateTimeoutMinutes * 60
  $job = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock $gateScript `
           -ArgumentList @($VmGateExe, $envVarName, $VmReproDir) -AsJob
  $waited = Wait-Job -Job $job -Timeout $gateTimeoutSec
  if (-not $waited) {
    Warn "gate run TIMED OUT after $GateTimeoutMinutes min"
    try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $gateExitCode = 'TIMEOUT'
    $gateVerdict  = "TIMEOUT after $GateTimeoutMinutes min"
    Record 'gate-run' $gateVerdict
  } else {
    $result = Receive-Job -Job $job -ErrorAction Continue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($result) {
      $gateExitCode = $result.ExitCode
      $body = @()
      $body += "GATE: $($cfg.Exe)"
      $body += "ENV : $envVarName=1  REPRO_TEST_BIN_DIR=$VmReproDir"
      $body += "EXIT CODE: $gateExitCode"
      $body += ""
      $body += "----- STDOUT -----"
      $body += ($result.Stdout -split "`r?`n")
      $body += "----- STDERR -----"
      $body += ($result.Stderr -split "`r?`n")
      $outFile = Join-Path $PerTestOut "02-$Gate-run.txt"
      Set-Content -Path $outFile -Value ($body -join "`r`n") -Encoding utf8
      Info "wrote $outFile (exit $gateExitCode)"
      $gateVerdict = if ("$gateExitCode" -eq '0') { 'PASS' } else { "FAIL exit=$gateExitCode" }
      Record 'gate-run' $gateVerdict
    } else {
      $gateVerdict = 'NO-OUTPUT'
      Record 'gate-run' $gateVerdict
    }
  }

  # ---- Step 6: harvest VM-side diagnostic logs --------------------------
  # Runs AFTER the gate command completes (success OR failure) and
  # BEFORE the `finally` block stops the VM. The VM is still up here
  # and the logs that the gate produced (vs_buildtools dd_*.log,
  # ProgramData VS install logs, DISM/CBS log tails, event-log
  # slices) are STATIC at this point — perfect time to scoop them.
  # Wrapped in a try/catch so a harvest failure cannot prevent the
  # Stop-VM in `finally` from firing.
  try {
    Info "harvesting VM-side diagnostic logs"
    $harvestScript = {
      $diagDir = "C:\Users\User\AppData\Local\Temp\m69-diag"
      New-Item -ItemType Directory -Force -Path $diagDir | Out-Null

      # vs_buildtools logs (issue 2 evidence)
      Get-ChildItem 'C:\Users\User\AppData\Local\Temp' -Filter 'dd_*.log' -ErrorAction SilentlyContinue |
          Copy-Item -Destination $diagDir -Force -ErrorAction SilentlyContinue
      # also check ProgramData VS install logs
      if (Test-Path 'C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances') {
        Get-ChildItem 'C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances' -Recurse -Filter '*.log' -ErrorAction SilentlyContinue |
            Copy-Item -Destination $diagDir -Force -ErrorAction SilentlyContinue
      }

      # DISM file log (issue 1 evidence; tail last ~5MB to avoid huge transfers)
      $dism = 'C:\Windows\Logs\DISM\dism.log'
      if (Test-Path $dism) {
        $bytes = [System.IO.File]::ReadAllBytes($dism)
        $tail  = if ($bytes.Length -gt 5MB) { $bytes[($bytes.Length - 5MB)..($bytes.Length-1)] } else { $bytes }
        [System.IO.File]::WriteAllBytes((Join-Path $diagDir 'dism-tail.log'), $tail)
      }

      # CBS.log tail (Component Based Servicing — what's under DISM)
      $cbs = 'C:\Windows\Logs\CBS\CBS.log'
      if (Test-Path $cbs) {
        $bytes = [System.IO.File]::ReadAllBytes($cbs)
        $tail  = if ($bytes.Length -gt 5MB) { $bytes[($bytes.Length - 5MB)..($bytes.Length-1)] } else { $bytes }
        [System.IO.File]::WriteAllBytes((Join-Path $diagDir 'cbs-tail.log'), $tail)
      }

      # Event log slices (last 200 events from the channels most likely to record DISM/installer activity)
      try { Get-WinEvent -LogName 'Microsoft-Windows-DISM/Operational' -MaxEvents 200 -ErrorAction Stop |
              Export-Clixml -Path (Join-Path $diagDir 'evt-dism.xml') } catch { }
      try { Get-WinEvent -LogName 'System' -MaxEvents 200 -ErrorAction Stop |
              Export-Clixml -Path (Join-Path $diagDir 'evt-system.xml') } catch { }
      try { Get-WinEvent -LogName 'Setup' -MaxEvents 200 -ErrorAction Stop |
              Export-Clixml -Path (Join-Path $diagDir 'evt-setup.xml') } catch { }

      # Compress the whole diagDir so we transfer one file out
      $zip = "C:\Users\User\AppData\Local\Temp\m69-diag.zip"
      if (Test-Path $zip) { Remove-Item $zip -Force }
      Compress-Archive -Path "$diagDir\*" -DestinationPath $zip -CompressionLevel Fastest -ErrorAction SilentlyContinue
      if (Test-Path $zip) { (Get-Item $zip).FullName } else { '' }
    }
    $zipPathInGuest = Invoke-Command -VMName $VmName -Credential $cred `
                                     -ScriptBlock $harvestScript -ErrorAction Stop
    if ($zipPathInGuest -and $zipPathInGuest.Trim().Length -gt 0) {
      $hostZip = Join-Path $PerTestOut 'm69-vm-diag.zip'
      Info "Copy-VMFile (Guest->Host): $zipPathInGuest -> $hostZip"
      Copy-VMFile -VMName $VmName -SourcePath $zipPathInGuest `
                  -DestinationPath $hostZip -FileSource Guest `
                  -CreateFullPath -Force -ErrorAction Stop
      if (Test-Path $hostZip) {
        Record 'harvest-vm-diag' "OK ($hostZip)"
      } else {
        Record 'harvest-vm-diag' 'SKIPPED: Copy-VMFile reported success but the destination is missing'
      }
    } else {
      Record 'harvest-vm-diag' 'SKIPPED: in-VM harvest produced no zip (no logs found?)'
    }
  } catch {
    Warn "  diag-harvest failed (non-fatal): $_"
    Record 'harvest-vm-diag' "SKIPPED: $_"
  }

}
catch {
  Fail "lifecycle threw: $_"
  Fail $_.ScriptStackTrace
  $gateVerdict = "ERROR: $_"
  Record 'lifecycle' "EXCEPTION: $_"
}
finally {
  # ---- Always Stop-VM (never Save-VM) -----------------------------------
  if ($KeepVmRunning) {
    Warn "  -KeepVmRunning set: leaving '$VmName' running for debugging"
    Warn "  When done, stop with: Stop-VM -Name $VmName -TurnOff -Force"
  } else {
    $vmFinal = Get-VmOrNull $VmName
    if ($vmFinal -and $vmFinal.State -ne 'Off') {
      Info "Stop-VM -TurnOff (never Save-VM)"
      try { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop } catch {
        Warn "  Stop-VM failed: $_"
      }
    } else {
      Info "VM already stopped"
    }
  }

  # ---- Always write RESULT.txt + DONE ------------------------------------
  $elapsedMin = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 2)
  $resultLines = @()
  $resultLines += "M69 Hyper-V destructive-gate run - RESULT"
  $resultLines += "generated:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $resultLines += "host:           $env:COMPUTERNAME  user: $env:USERNAME"
  $resultLines += "vm:             $VmName"
  $resultLines += "gate:           $Gate"
  $resultLines += "scenario:       $Scenario"
  $resultLines += "wall-clock min: $elapsedMin"
  $resultLines += ""
  foreach ($k in $steps.Keys) {
    $resultLines += ("{0,-24} {1}" -f $k, $steps[$k])
  }
  $resultLines += ""
  $resultLines += "VERDICT: $gateVerdict"
  Set-Content -Path (Join-Path $PerTestOut 'RESULT.txt') -Value $resultLines -Encoding utf8

  # Append the "after" VM-state to 00-vm-state.log
  "" | Add-Content -Path $beforeLog
  "=== VM state AFTER run ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ===" | Add-Content -Path $beforeLog
  Get-VM -Name $VmName -ErrorAction SilentlyContinue | Format-List Name,State,Status,Uptime | Out-String | Add-Content -Path $beforeLog
  Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue |
    Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName |
    Out-String | Add-Content -Path $beforeLog

  # DONE sentinel - written LAST
  Set-Content -Path (Join-Path $PerTestOut 'DONE') -Value "done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding ascii
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Info ("=" * 70)
Info "Results in: $PerTestOut"
Get-ChildItem -LiteralPath $PerTestOut -File -ErrorAction SilentlyContinue |
  Sort-Object Name |
  ForEach-Object { Info ("  {0,-40} {1,10} bytes" -f $_.Name, $_.Length) }
$rt = Join-Path $PerTestOut 'RESULT.txt'
if (Test-Path $rt) {
  Write-Host ""
  Info "----- RESULT.txt -----"
  Get-Content $rt | ForEach-Object { Write-Host "  $_" }
}
$gt = Join-Path $PerTestOut "02-$Gate-run.txt"
if (Test-Path $gt) {
  Write-Host ""
  Info "----- 02-$Gate-run.txt (tail 50) -----"
  Get-Content $gt -Tail 50 | ForEach-Object { Write-Host "  $_" }
}
Info ("=" * 70)

if ("$gateExitCode" -eq '0') { exit 0 }
elseif ("$gateExitCode" -eq 'TIMEOUT') { exit 2 }
else { exit 1 }
