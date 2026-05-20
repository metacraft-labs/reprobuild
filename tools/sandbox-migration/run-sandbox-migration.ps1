<#
  run-sandbox-migration.ps1 - HOST-SIDE runner for the M70 sandbox harness.

  Clears the OUTPUT directory, launches Windows Sandbox with migration.wsb,
  polls the OUTPUT directory for the DONE sentinel, then closes the sandbox
  and reports where the results landed.

  HOST SAFETY: this script only ever writes inside
  D:\metacraft\sandbox-migration-out. It never deletes/moves anything else.
  The sandbox itself is disposable and cannot touch the host outside the one
  read-write mapped OUTPUT folder.

  FAST-FAIL: a parse failure of the in-sandbox provision script (the script
  never runs, so no _script-started.txt and no DONE) is detected early - if
  the provision script has not checkpointed within ~6 min of the LogonCommand
  firing AND _logon-powershell.log shows parser-error text, the poll aborts
  instead of burning the full 40-min timeout. The 40-min hard cap still
  applies to the legitimate long-provisioning case.

  Usage:   pwsh -File run-sandbox-migration.ps1 [-TimeoutMinutes 40]
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 40
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WsbFile     = Join-Path $ScriptDir 'migration.wsb'
$OutDir      = 'D:\metacraft\sandbox-migration-out'
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
  Fail "migration.wsb not found at $WsbFile"
  exit 1
}

# Verify the mapped repro binary directory has what the sandbox needs.
$reproBin = 'D:\metacraft\reprobuild\build\bin'
foreach ($need in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
  $p = Join-Path $reproBin $need
  if (-not (Test-Path $p)) {
    Warn "expected build artifact missing: $p"
    Warn "build repro first:  nim c --out:build/bin/repro apps/repro/repro.nim"
    Warn "and copy build/repro-launcher.exe -> build/bin/repro-launcher.exe"
  }
}

# --- VC++ runtime fidelity prep -------------------------------------------
# A pristine Windows Sandbox image ships WITHOUT the Visual C++ 2015-2022
# redistributable runtime DLLs. The user's REAL host has them system-wide in
# C:\Windows\System32 (every developer machine with VS / the redistributable
# does), so MSVC-linked tools like codex.exe / nvim.exe run there. To make the
# sandbox faithfully replicate the host we copy the host's own runtime DLLs
# into tools\sandbox-migration\vcruntime\; migration.wsb maps that directory
# into the sandbox read-only, and provision-and-migrate.ps1 Stage B copies the
# DLLs into the sandbox's C:\Windows\System32 (a few small DLLs - seconds, not
# the 600s the prior `scoop install vcredist` took).
#
# This is a legitimate fidelity step: it reproduces the host's existing
# system-wide runtime, it is NOT installing anything the host lacks.
$vcDstDir = Join-Path $ScriptDir 'vcruntime'
# VC++ 2015-2022 x64 runtime set. The first three are mandatory (codex.exe /
# nvim.exe need them); the rest are copied if present for completeness.
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
# Force array context with @(...) so .Count is StrictMode-safe even when the
# collection is empty or $null (the dev shell enables Set-StrictMode).
if (@($vcMissing).Count -gt 0) { Info "  VC++ DLLs not on host (skipped): $($vcMissing -join ', ')" }
# The three mandatory DLLs must be present or the in-sandbox MSVC tools fail.
$vcMandatoryMissing = @($vcRequired | Where-Object { $_ -notin $vcCopied })
if ($vcMandatoryMissing.Count -gt 0) {
  Fail "mandatory VC++ runtime DLL(s) not found in ${vcSys32}: $($vcMandatoryMissing -join ', ')"
  Fail "the sandbox migration's MSVC-linked tools (codex, neovim) will fail without these."
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
# A stale WindowsSandboxRemoteSession process from a prior run can keep the
# mapped folders pinned, causing the next launch's mapped-folder mounts to
# fail silently (no heartbeat reaches the OUTPUT folder). Kill every sandbox
# process name, RemoteSession included.
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

# Fast-fail tuning: once the LogonCommand has fired, the provision script
# must checkpoint (_script-started.txt) within this grace window. A parse
# failure produces neither the checkpoint nor DONE - so if the grace window
# lapses with no checkpoint AND the in-sandbox PowerShell log shows parser
# errors, the migration cannot run and there is no point polling further.
$ScriptGraceMinutes = 6
$ParserErrorPatterns = @('ParserError','Unexpected token','missing its Catch',
                         'Missing closing','Not all parse errors')

while ((Get-Date) -lt $deadline) {
  if (Test-Path $DoneFile) { $done = $true; break }

  # Heartbeat checkpoints - distinguish "LogonCommand never fired" from
  # "script ran but wedged".
  if (-not $sawLogon -and (Test-Path (Join-Path $OutDir '_logon-heartbeat.txt'))) {
    $sawLogon = $true; $logonAt = Get-Date
    Info "  checkpoint: LogonCommand fired."
  }
  if (-not $sawScript -and (Test-Path (Join-Path $OutDir '_script-started.txt'))) {
    $sawScript = $true; Info "  checkpoint: provision script started."
  }

  # Fast-fail: LogonCommand fired, grace window elapsed, no script checkpoint,
  # and the PowerShell log shows parser errors -> the script failed to PARSE.
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

  Start-Sleep -Seconds 15
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
# Give the in-sandbox script a few seconds to flush the last files, then
# tear the sandbox down.
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
  foreach ($f in $files) { Info ("  {0,-26} {1,8} bytes" -f $f.Name, $f.Length) }
} else {
  Warn "  (no artifact files - the sandbox may have failed to launch or run the script)"
}
$resultTxt = Join-Path $OutDir 'RESULT.txt'
if (Test-Path $resultTxt) {
  Write-Host ""
  Info "----- RESULT.txt -----"
  Get-Content $resultTxt | ForEach-Object { Write-Host "  $_" }
}
Info "=================================================================="

if ($done) { exit 0 }
elseif ($abortReason) { exit 3 }
else { exit 2 }
