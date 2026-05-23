<#
  run-sandbox-m69-system.ps1 - HOST-SIDE runner for the M69 system-scope
  destructive-gate Sandbox harness.

  Pre-flight: stages the host's VC++ 2015-2022 runtime DLLs into the
  harness's vcruntime\ directory (so a pristine Sandbox image gets a
  System32 that faithfully replicates the real developer host - see the
  M70/M76 fidelity pattern).

  Launches Windows Sandbox with m69-system.wsb, polls the OUTPUT
  directory for the DONE sentinel, then closes the sandbox and reports
  where the per-gate results landed.

  HOST SAFETY: this script only ever writes inside
  D:\metacraft\sandbox-m69-system-out (plus the harness's vcruntime\
  subdir). It NEVER touches the real OS state (no DISM, no
  Add-WindowsCapability, no Set-Service, no VS install) - the gates'
  REAL mutations happen INSIDE the sandbox only.

  FAST-FAIL: a parse failure of the in-sandbox provision script (no
  _script-started.txt within ~6 min of LogonCommand firing AND
  _logon-powershell.log shows parser-error text) aborts the poll
  early instead of waiting the full timeout.

  Wall-clock budget: a real VS Build Tools install can take 30-60 min
  depending on workloads and network; the default poll timeout is 120
  minutes to leave headroom for both gates plus their setup.

  Usage:  pwsh -File run-sandbox-m69-system.ps1 [-TimeoutMinutes 120]
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WsbFile     = Join-Path $ScriptDir 'm69-system.wsb'
$OutDir      = 'D:\metacraft\sandbox-m69-system-out'
$SandboxExe  = 'C:\Windows\System32\WindowsSandbox.exe'

function Info($m)  { Write-Host "[run] $m" }
function Warn($m)  { Write-Host "[run] WARNING: $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[run] ERROR: $m" -ForegroundColor Red }

# --- Pre-flight ------------------------------------------------------------
if (-not (Test-Path $SandboxExe)) {
  Fail "Windows Sandbox not found at $SandboxExe. Enable the 'Windows Sandbox' optional feature."
  exit 1
}
if (-not (Test-Path $WsbFile)) {
  Fail "m69-system.wsb not found at $WsbFile"
  exit 1
}

# Verify the mapped repro + gate binaries are present.
$reproBin = 'D:\metacraft\reprobuild\build\bin'
foreach ($need in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
  $p = Join-Path $reproBin $need
  if (-not (Test-Path $p)) {
    Fail "expected repro artifact missing: $p"
    Fail "build first (in the dev shell):"
    Fail "  nim c --out:build/bin/repro apps/repro/repro.nim"
    Fail "  Copy-Item build/repro-launcher.exe build/bin/repro-launcher.exe"
    exit 1
  }
}
$testBin = 'D:\metacraft\reprobuild\build\test-bin'
foreach ($need in @('e2e_windows_optional_feature_and_capability.exe',
                    'e2e_windows_vs_installer.exe')) {
  $p = Join-Path $testBin $need
  if (-not (Test-Path $p)) {
    Fail "expected gate binary missing: $p"
    Fail "build first (in the dev shell):"
    Fail "  just e2e_windows_optional_feature_and_capability"
    Fail "  just e2e_windows_vs_installer"
    exit 1
  }
}

# --- VC++ runtime fidelity prep -------------------------------------------
# Same pattern as the M70 dotfiles-migration harness: a pristine Sandbox
# image lacks the MSVC 2015-2022 runtime; the real developer host has it
# system-wide; copy the host's own runtime DLLs into the harness's
# vcruntime\ directory so the in-sandbox script can deliver them to
# System32. This is a faithful replica of the host's existing runtime -
# NOT installing anything the host lacks.
$vcDstDir = Join-Path $ScriptDir 'vcruntime'
$vcRequired = @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll')
$vcOptional = @('msvcp140_1.dll','msvcp140_2.dll','concrt140.dll','vccorlib140.dll')
$vcSys32    = Join-Path $env:WINDIR 'System32'
Info "preparing VC++ runtime DLLs for sandbox fidelity -> $vcDstDir"
if (-not (Test-Path $vcDstDir)) { New-Item -ItemType Directory -Path $vcDstDir -Force | Out-Null }
$vcCopied  = @()
$vcMissing = @()
foreach ($dll in ($vcRequired + $vcOptional)) {
  $src = Join-Path $vcSys32 $dll
  if (Test-Path $src) {
    try {
      Copy-Item -LiteralPath $src -Destination (Join-Path $vcDstDir $dll) -Force
      $vcCopied += $dll
    } catch {
      Warn "failed to copy VC++ DLL ${dll}: $_"
      $vcMissing += $dll
    }
  } else {
    $vcMissing += $dll
  }
}
Info "  VC++ DLLs copied: $($vcCopied -join ', ')"
if (@($vcMissing).Count -gt 0) { Info "  VC++ DLLs not on host (skipped): $($vcMissing -join ', ')" }
$vcMandatoryMissing = @($vcRequired | Where-Object { $_ -notin $vcCopied })
if ($vcMandatoryMissing.Count -gt 0) {
  Fail "mandatory VC++ runtime DLL(s) not found in ${vcSys32}: $($vcMandatoryMissing -join ', ')"
  exit 1
}

# --- Clear the OUTPUT directory -------------------------------------------
# Scoped strictly to $OutDir. Created fresh if absent.
if (Test-Path $OutDir) {
  Info "clearing OUTPUT dir $OutDir"
  Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Info "creating OUTPUT dir $OutDir"
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$DoneFile = Join-Path $OutDir 'DONE'

# --- Make sure no stale sandbox is running --------------------------------
$SandboxProcNames = @('WindowsSandbox','WindowsSandboxClient','WindowsSandboxServer','WindowsSandboxRemoteSession')
foreach ($pn in $SandboxProcNames) {
  Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
    Warn "stopping pre-existing $pn (pid $($_.Id))"
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}
Start-Sleep -Seconds 3

# --- Launch ----------------------------------------------------------------
Info "launching Windows Sandbox: $WsbFile"
$startedAt = Get-Date
try {
  Start-Process -FilePath $SandboxExe -ArgumentList "`"$WsbFile`"" | Out-Null
} catch {
  Fail "failed to launch WindowsSandbox.exe: $_"
  exit 1
}

# --- Poll for DONE ---------------------------------------------------------
$deadline = $startedAt.AddMinutes($TimeoutMinutes)
Info "polling $DoneFile (timeout $TimeoutMinutes min, deadline $($deadline.ToString('HH:mm:ss')))"
$done = $false
$abortReason = $null
$lastReport = Get-Date
$sawLogon   = $false
$sawScript  = $false
$logonAt    = $null

$ScriptGraceMinutes = 6
$ParserErrorPatterns = @('ParserError','Unexpected token','missing its Catch',
                         'Missing closing','Not all parse errors')

while ((Get-Date) -lt $deadline) {
  if (Test-Path $DoneFile) { $done = $true; break }

  if (-not $sawLogon -and (Test-Path (Join-Path $OutDir '_logon-heartbeat.txt'))) {
    $sawLogon = $true; $logonAt = Get-Date
    Info "  checkpoint: LogonCommand fired."
  }
  if (-not $sawScript -and (Test-Path (Join-Path $OutDir '_script-started.txt'))) {
    $sawScript = $true; Info "  checkpoint: provision script started."
  }

  if ($sawLogon -and -not $sawScript -and
      ((Get-Date) - $logonAt).TotalMinutes -ge $ScriptGraceMinutes) {
    $psLog = Join-Path $OutDir '_logon-powershell.log'
    if (Test-Path $psLog) {
      $logText = ''
      try { $logText = Get-Content -LiteralPath $psLog -Raw -ErrorAction SilentlyContinue } catch {}
      $hit = $null
      foreach ($pat in $ParserErrorPatterns) {
        if ($logText -and $logText -like "*$pat*") { $hit = $pat; break }
      }
      if ($hit) {
        $abortReason = "provision script failed to PARSE - '$hit' in _logon-powershell.log; " +
                       "no _script-started.txt after ${ScriptGraceMinutes} min. Aborting poll early."
        break
      }
    }
  }

  Start-Sleep -Seconds 30
  if (((Get-Date) - $lastReport).TotalMinutes -ge 2) {
    $elapsed = [int]((Get-Date) - $startedAt).TotalMinutes
    $artifacts = (Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Info "  ... still running (${elapsed} min elapsed, $artifacts artifact file(s) so far)"
    $lastReport = Get-Date
  }
}

if ($done) {
  Info "DONE sentinel detected after $([int]((Get-Date) - $startedAt).TotalMinutes) min."
} elseif ($abortReason) {
  Fail "FAST-FAIL: $abortReason"
} else {
  Warn "timeout - DONE sentinel never appeared after $TimeoutMinutes min."
}

# --- Close the sandbox -----------------------------------------------------
Start-Sleep -Seconds 5
Info "closing the sandbox"
foreach ($pn in $SandboxProcNames) {
  Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
    Info "  stopping $pn (pid $($_.Id))"
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# --- Report ----------------------------------------------------------------
Write-Host ""
Info "=================================================================="
Info "Results landed in: $OutDir"
$files = Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue | Sort-Object Name
if ($files) {
  foreach ($f in $files) { Info ("  {0,-40} {1,10} bytes" -f $f.Name, $f.Length) }
} else {
  Warn "  (no artifact files - the sandbox may have failed to launch or run the script)"
}
$resultTxt = Join-Path $OutDir 'RESULT.txt'
if (Test-Path $resultTxt) {
  Write-Host ""
  Info "----- RESULT.txt -----"
  Get-Content $resultTxt | ForEach-Object { Write-Host "  $_" }
}
foreach ($gate in @('01-feature-capability-gate.txt','02-vs-installer-gate.txt')) {
  $gp = Join-Path $OutDir $gate
  if (Test-Path $gp) {
    Write-Host ""
    Info ("----- " + $gate + " (tail) -----")
    Get-Content $gp -Tail 50 | ForEach-Object { Write-Host "  $_" }
  }
}
Info "=================================================================="

if ($done) { exit 0 }
elseif ($abortReason) { exit 3 }
else { exit 2 }
