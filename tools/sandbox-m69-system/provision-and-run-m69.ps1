<#
  provision-and-run-m69.ps1 - runs INSIDE the Windows Sandbox at logon.

  M69 system-scope destructive-gate harness. Provisions a clean Windows
  environment, stages the pre-built `repro.exe` + the two gate test
  binaries the host built, sets the VM-only env vars, runs each gate,
  and captures its full output to the host-visible OUTPUT folder.

  Stages:
    A. Copy repro-bin (repro.exe + DLLs) + test-bin (the two gate exes)
       to writable sandbox paths.
    B. Deliver the Visual C++ 2015-2022 runtime DLLs into System32
       (same M70/M76 fidelity step the dotfiles-migration harness uses).
    C. Download the VS Build Tools bootstrapper (vs_BuildTools.exe) from
       Microsoft and stage it at C:\Program Files (x86)\Microsoft Visual
       Studio\Installer\vs_installer.exe + vswhere.exe alongside, so the
       windows.vsInstaller driver's `resolveVsInstaller` /
       `resolveVsWhere` find them. (The Sandbox image starts with
       NEITHER installed; the bootstrapper handles the first install of
       BOTH the resident vs_installer AND the requested workloads.)
    D. Run e2e_windows_optional_feature_and_capability with
       REPRO_M69_FEATURE_VM=1 set. Capture full stdout+stderr+exit.
    E. Run e2e_windows_vs_installer with REPRO_M69_VSINSTALLER_VM=1 set.
       Capture full stdout+stderr+exit. Bounded by a long timeout (VS
       install can take 30-60 minutes).
    F. Write RESULT.txt with per-step exit codes + verdict, then DONE
       LAST (the host runner waits on DONE).

  ROBUSTNESS: every stage is wrapped so a failure still records
  diagnostics and still writes DONE - the host never polls forever. A
  top-level watchdog writes DONE after 110 min if the run wedges.

  ASCII-ONLY: this file is decoded as the system ANSI codepage by
  Windows PowerShell 5.1 (no BOM); a non-ASCII byte in a string
  literal can decode to a stray quote and break parsing of the whole
  script. Keep this file pure ASCII.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'

# --- Paths -----------------------------------------------------------------
$Out          = 'C:\harness\out'
$ReproBinSrc  = 'C:\harness\repro-bin'
$TestBinSrc   = 'C:\harness\test-bin'
$VcRuntimeSrc = 'C:\harness\vcruntime'

# Writable destinations.
$ReproDir     = 'C:\harness\repro'                  # writable repro.exe location
$ReproExe     = Join-Path $ReproDir 'repro.exe'
$TestBinDir   = 'C:\harness\gate-bin'               # writable gate binaries

# --- Immediate heartbeat ---------------------------------------------------
# Prove the script itself started, BEFORE anything that could be slow.
try {
  if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
  Set-Content -Path (Join-Path $Out '_script-started.txt') `
    -Value ("provision-and-run-m69.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') as $env:USERNAME") `
    -Encoding ascii
} catch { Write-Host "heartbeat write failed: $_" }

# --- Logging ---------------------------------------------------------------
$LogFile = Join-Path $Out '00-provision.log'
function Log($msg) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
  Write-Host $line
  try { Add-Content -Path $LogFile -Value $line -Encoding utf8 } catch {}
}
function Section($name) { Log ''; Log ("=" * 60); Log $name; Log ("=" * 60) }

# Step exit codes + verdicts, accumulated for RESULT.txt.
$Results = [ordered]@{}
function Record($key, $val) { $Results[$key] = $val; Log ("RESULT  {0} = {1}" -f $key, $val) }

# --- Finalizer: always writes RESULT.txt then DONE -------------------------
function Finalize($verdict) {
  try {
    $lines = @()
    $lines += "M69 system-scope sandbox harness - RESULT"
    $lines += "generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ("sandbox host: {0}  user: {1}" -f $env:COMPUTERNAME, $env:USERNAME)
    $lines += ""
    foreach ($k in $Results.Keys) { $lines += ("{0,-32} {1}" -f $k, $Results[$k]) }
    $lines += ""
    $lines += "VERDICT: $verdict"
    Set-Content -Path (Join-Path $Out 'RESULT.txt') -Value $lines -Encoding utf8
  } catch { Write-Host "Finalize RESULT.txt failed: $_" }
  try {
    Set-Content -Path (Join-Path $Out 'DONE') `
      -Value ("done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')") -Encoding ascii
  } catch { Write-Host "Finalize DONE failed: $_" }
  Log "FINALIZED: $verdict"
}

# --- Top-level timeout watchdog -------------------------------------------
# If the main run wedges, this background job writes DONE after 110 min so
# the host-side runner never hangs. A real VS-Build-Tools install commonly
# takes 30-60 min; we give the full sequence ample headroom.
$WatchdogMinutes = 110
$watchdog = Start-Job -ScriptBlock {
  param($out, $mins)
  Start-Sleep -Seconds ($mins * 60)
  $done = Join-Path $out 'DONE'
  if (-not (Test-Path $done)) {
    Set-Content -Path (Join-Path $out 'RESULT.txt') `
      -Value "VERDICT: TIMEOUT - watchdog fired after $mins min; main run wedged." `
      -Encoding utf8
    Set-Content -Path $done -Value "watchdog-timeout" -Encoding ascii
  }
} -ArgumentList $Out, $WatchdogMinutes

# ===========================================================================
# MAIN
# ===========================================================================
try {
  if (Test-Path $Out) {
    Get-ChildItem $Out -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notin @('_script-started.txt','_logon-heartbeat.txt','_logon-powershell.log') } |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  } else { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
  Log "M69 system-scope sandbox harness starting."
  Log "USERPROFILE = $env:USERPROFILE"
  Log "LOCALAPPDATA = $env:LOCALAPPDATA"
  Log "COMPUTERNAME = $env:COMPUTERNAME"

  # ---- Stage A: stage binaries -------------------------------------------
  Section 'Stage A - stage repro.exe + gate test binaries'
  $stagedRepro = $false
  $stagedGates = @()
  try {
    New-Item -ItemType Directory -Path $ReproDir -Force | Out-Null
    foreach ($f in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
      $s = Join-Path $ReproBinSrc $f
      if (Test-Path $s) {
        Copy-Item $s (Join-Path $ReproDir $f) -Force
        Log "  copied repro-bin/$f"
      } else { Log "  MISSING repro-bin/$f" }
    }
    $stagedRepro = Test-Path $ReproExe
    Record 'stageA_repro_staged' ($(if ($stagedRepro) { 'OK' } else { 'FAIL' }))

    New-Item -ItemType Directory -Path $TestBinDir -Force | Out-Null
    foreach ($f in @('e2e_windows_optional_feature_and_capability.exe',
                     'e2e_windows_vs_installer.exe')) {
      $s = Join-Path $TestBinSrc $f
      if (Test-Path $s) {
        Copy-Item $s (Join-Path $TestBinDir $f) -Force
        $stagedGates += $f
        Log "  copied test-bin/$f"
      } else { Log "  MISSING test-bin/$f" }
    }
    Record 'stageA_gates_staged' ($stagedGates -join ',')
  } catch {
    Log "Stage A FAILED: $_"
    Record 'stageA_repro_staged' "FAILED: $_"
  }

  # ---- Stage B: deliver VC++ runtime DLLs --------------------------------
  Section 'Stage B - deliver VC++ runtime DLLs'
  $vcOk = $false
  try {
    $sys32 = Join-Path $env:WINDIR 'System32'
    if (Test-Path (Join-Path $sys32 'vcruntime140.dll')) {
      Log "vcruntime140.dll already in System32"
      $vcOk = $true
    } elseif (-not (Test-Path $VcRuntimeSrc)) {
      Log "mapped VC++ runtime dir missing: $VcRuntimeSrc"
    } else {
      $vcDlls = Get-ChildItem $VcRuntimeSrc -Filter '*.dll' -File -ErrorAction SilentlyContinue
      Log ("copying {0} VC++ runtime DLL(s) into System32 ..." -f $vcDlls.Count)
      foreach ($d in $vcDlls) {
        try {
          Copy-Item $d.FullName (Join-Path $sys32 $d.Name) -Force -ErrorAction Stop
          Log ("  copied {0}" -f $d.Name)
        } catch { Log ("  FAILED {0}: {1}" -f $d.Name, $_) }
      }
      $vcOk = Test-Path (Join-Path $sys32 'vcruntime140.dll')
    }
  } catch { Log "VC++ delivery EXCEPTION: $_" }
  Record 'stageB_vcruntime' ($(if ($vcOk) { 'OK' } else { 'FAIL' }))

  # ---- Stage C: download VS Build Tools bootstrapper ---------------------
  # The windows.vsInstaller driver invokes `vs_installer.exe` from the
  # well-known path:
  #   C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe
  # On a pristine Windows Sandbox image NEITHER vs_installer.exe NOR
  # vswhere.exe exist. The Microsoft VS bootstrapper (vs_BuildTools.exe)
  # IS the first-install entry point: invoked with `install --add
  # <workload>` it installs the workloads AND the resident
  # vs_installer.exe. Stage it AS vs_installer.exe so the driver's
  # resolution path finds it. The bootstrapper accepts the SAME argv
  # (install / modify) as the resident installer; the driver's argv
  # construction is identical for either.
  Section 'Stage C - stage VS Build Tools bootstrapper as vs_installer.exe'
  $vsBootstrapOk = $false
  try {
    $installerDir = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer'
    if (-not (Test-Path $installerDir)) {
      New-Item -ItemType Directory -Path $installerDir -Force | Out-Null
    }
    $vsInstallerExe = Join-Path $installerDir 'vs_installer.exe'
    $vsWhereExe     = Join-Path $installerDir 'vswhere.exe'

    # Wait for networking to come up - Sandbox runs the LogonCommand
    # before the network stack is necessarily ready.
    $netOk = $false
    for ($i = 0; $i -lt 48; $i++) {
      try {
        if (Test-Connection -ComputerName 'aka.ms' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
          $netOk = $true; break
        }
      } catch {}
      Start-Sleep -Seconds 5
    }
    Log "network reachable: $netOk"
    Record 'stageC_network' ($(if ($netOk) { 'OK' } else { 'NO-NETWORK' }))

    if ($netOk) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      # Microsoft publishes a stable aka.ms shortlink for the Build
      # Tools bootstrapper. The bootstrapper handles its own version
      # negotiation against the configured channel.
      $bootstrapUrl = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
      Log "downloading $bootstrapUrl -> $vsInstallerExe"
      try {
        Invoke-WebRequest -Uri $bootstrapUrl -OutFile $vsInstallerExe -TimeoutSec 300
        $vsBootstrapOk = Test-Path $vsInstallerExe
        if ($vsBootstrapOk) {
          $sz = (Get-Item $vsInstallerExe).Length
          Log "  staged vs_installer.exe ($sz bytes)"
        }
      } catch {
        Log "vs_buildtools.exe download FAILED: $_"
      }
      # vswhere.exe - separate stable download (3 MB).
      $vsWhereUrl = 'https://github.com/microsoft/vswhere/releases/latest/download/vswhere.exe'
      Log "downloading $vsWhereUrl -> $vsWhereExe"
      try {
        Invoke-WebRequest -Uri $vsWhereUrl -OutFile $vsWhereExe -TimeoutSec 120
        if (Test-Path $vsWhereExe) {
          $sz = (Get-Item $vsWhereExe).Length
          Log "  staged vswhere.exe ($sz bytes)"
        }
      } catch {
        Log "vswhere.exe download FAILED: $_"
      }
    }
  } catch {
    Log "Stage C EXCEPTION: $_"
  }
  Record 'stageC_vs_bootstrap' ($(if ($vsBootstrapOk) { 'OK' } else { 'FAIL' }))

  # ---- Helper: run a gate with full output capture -----------------------
  function Invoke-Gate {
    param(
      [Parameter(Mandatory)][string]$Name,
      [Parameter(Mandatory)][string]$Exe,
      [Parameter(Mandatory)][hashtable]$EnvVars,
      [Parameter(Mandatory)][int]$TimeoutSec,
      [Parameter(Mandatory)][string]$OutFile
    )
    Section ("Stage - run gate: " + $Name)
    if (-not (Test-Path $Exe)) {
      Log "  MISSING gate binary: $Exe"
      Record ("gate_" + $Name + "_exit") 'MISSING'
      return 'MISSING'
    }
    # Apply env vars for this process and propagate via Start-Process
    # (Start-Process inherits the current process env on Windows).
    foreach ($k in $EnvVars.Keys) {
      Log ("  setting $k = " + $EnvVars[$k])
      Set-Item -Path ("Env:" + $k) -Value $EnvVars[$k]
    }

    $stdoutF = Join-Path $env:TEMP ("gate-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrF = Join-Path $env:TEMP ("gate-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $exit = $null
    Log ("RUN: $Exe  (timeout ${TimeoutSec}s)")
    try {
      $p = Start-Process -FilePath $Exe -NoNewWindow -PassThru `
             -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
      # Windows PowerShell 5.1 quirk: touch .Handle so ExitCode survives.
      $null = $p.Handle
      if ($p.WaitForExit($TimeoutSec * 1000)) {
        $p.WaitForExit()
        $exit = $p.ExitCode
      } else {
        Log "  TIMEOUT after $TimeoutSec s - killing gate process tree"
        try { taskkill /PID $p.Id /T /F | Out-Null } catch {}
        $exit = 'TIMEOUT'
      }
    } catch {
      Log "  Start-Process FAILED: $_"
      $exit = "SPAWN-FAILED: $_"
    }
    $so = if (Test-Path $stdoutF) { Get-Content $stdoutF -Raw } else { '' }
    $se = if (Test-Path $stderrF) { Get-Content $stderrF -Raw } else { '' }
    $body = @()
    $body += "COMMAND: $Exe"
    $envSummary = ($EnvVars.Keys | ForEach-Object { "$_=$($EnvVars[$_])" }) -join ' '
    $body += "ENV: $envSummary"
    $body += "EXIT CODE: $exit"
    $body += ""
    $body += "----- STDOUT -----"
    $body += $so
    $body += "----- STDERR -----"
    $body += $se
    Set-Content -Path (Join-Path $Out $OutFile) -Value ($body -join "`r`n") -Encoding utf8
    Remove-Item $stdoutF,$stderrF -Force -ErrorAction SilentlyContinue
    Log ("  -> $OutFile (exit $exit)")
    Record ("gate_" + $Name + "_exit") $exit
    return $exit
  }

  # ---- Common gate env: point repro lookup at the writable bin dir ------
  # The gates call reproBinary() which honors REPRO_TEST_BIN_DIR; the
  # M81 broker is launched via this binary.
  $commonEnv = @{
    'REPRO_TEST_BIN_DIR' = $ReproDir
  }

  # ---- Stage D: run the optionalFeature/capability/service gate ----------
  $featureEnv = $commonEnv.Clone()
  $featureEnv['REPRO_M69_FEATURE_VM'] = '1'
  $featureExit = Invoke-Gate `
    -Name 'feature_capability' `
    -Exe (Join-Path $TestBinDir 'e2e_windows_optional_feature_and_capability.exe') `
    -EnvVars $featureEnv `
    -TimeoutSec 1200 `
    -OutFile '01-feature-capability-gate.txt'
  # Clear those env vars so they don't leak into the next gate.
  Remove-Item Env:REPRO_M69_FEATURE_VM -ErrorAction SilentlyContinue

  # ---- Stage E: run the VS-installer gate --------------------------------
  $vsEnv = $commonEnv.Clone()
  $vsEnv['REPRO_M69_VSINSTALLER_VM'] = '1'
  $vsExit = Invoke-Gate `
    -Name 'vs_installer' `
    -Exe (Join-Path $TestBinDir 'e2e_windows_vs_installer.exe') `
    -EnvVars $vsEnv `
    -TimeoutSec 3600 `
    -OutFile '02-vs-installer-gate.txt'
  Remove-Item Env:REPRO_M69_VSINSTALLER_VM -ErrorAction SilentlyContinue

  # ---- Stage F: verdict + finalize ---------------------------------------
  $verdict =
    if ("$featureExit" -eq '0' -and "$vsExit" -eq '0') {
      "PASS - both gates exited 0."
    } elseif ("$featureExit" -ne '0' -and "$vsExit" -ne '0') {
      "FAIL - both gates failed (feature=$featureExit vs=$vsExit)."
    } elseif ("$featureExit" -ne '0') {
      "FAIL - feature/capability gate failed (exit=$featureExit); see 01-feature-capability-gate.txt"
    } else {
      "FAIL - vsInstaller gate failed (exit=$vsExit); see 02-vs-installer-gate.txt"
    }
  Finalize $verdict
}
catch {
  Log "TOP-LEVEL EXCEPTION: $_"
  Log $_.ScriptStackTrace
  Finalize "ERROR - top-level exception: $_"
}
finally {
  try { Stop-Job $watchdog -ErrorAction SilentlyContinue; Remove-Job $watchdog -Force -ErrorAction SilentlyContinue } catch {}
}
