<#
  provision-and-migrate.ps1 - runs INSIDE the Windows Sandbox at logon.

  M70 dotfiles-migration test harness. Provisions a realistic, pre-populated
  $HOME inside a disposable sandbox, then runs the real `repro home apply`
  migration against the user's dotfiles and captures every artifact for the
  host to diagnose.

  Stages:
    A. Copy the read-only mapped dotfiles to a writable sandbox path.
    B. Install Scoop, add the `extras` bucket, pre-seed the download cache.
    C. `scoop install` the 14 packages the migration profile declares.
    D. Replicate the pre-existing-symlink state `bin/home-switch.ps1` creates
       (so the migration hits the "existing correct symlink -> cache-hit" path).
    E. Copy repro.exe (+ sqlite3_64.dll + repro-launcher.exe) to a writable path.
    F. Run `repro home apply --plan` / `apply` / `--plan` (idempotency).
    G. Capture post-apply $HOME + %LOCALAPPDATA%\repro state, `scoop list`.
    H. Write RESULT.txt, then the DONE sentinel LAST.

  ROBUSTNESS: every stage is wrapped so a failure still records diagnostics
  and still writes DONE - the host never polls forever. A top-level timeout
  guard (a background watchdog job) writes DONE and exits if the run wedges.

  NOTE: this file MUST be pure ASCII. Windows Sandbox runs powershell.exe
  (Windows PowerShell 5.1), which decodes a no-BOM file as the system ANSI
  codepage (CP-1252), not UTF-8. A non-ASCII byte in a string literal can
  decode to a stray double-quote and break parsing of the whole script.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference     = 'SilentlyContinue'

# --- Paths -----------------------------------------------------------------
$Out          = 'C:\harness\out'
$ReproBinSrc  = 'C:\harness\repro-bin'
$DotfilesSrc  = 'C:\harness\dotfiles-src'
$ScoopCacheSrc= 'C:\harness\scoop-cache'
$ScoopBktSrc  = 'C:\harness\scoop-buckets'             # host buckets (main+extras), RO
$ScoopAppsSrc = 'C:\harness\scoop-apps'                # host apps trees, RO (fallback)
$VcRuntimeSrc = 'C:\harness\vcruntime'                 # host VC++ runtime DLLs, RO
$Home_        = $env:USERPROFILE                       # C:\Users\WDAGUtilityAccount
$DotfilesDst  = Join-Path $Home_ 'dotfiles'            # writable copy
$ReproDir     = 'C:\harness\repro'                     # writable repro.exe location
$ReproExe     = Join-Path $ReproDir 'repro.exe'

# --- Immediate heartbeat ---------------------------------------------------
# Prove the script itself started, BEFORE anything that could be slow
# (Start-Job, network). The host watches for this file to distinguish
# "LogonCommand never ran the script" from "script ran but wedged later".
# This MUST be the very first work the script does, so a parse-failure
# (no checkpoint) is cleanly distinguishable from a slow-but-running script.
try {
  if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out -Force | Out-Null }
  Set-Content -Path (Join-Path $Out '_script-started.txt') `
    -Value ("provision-and-migrate.ps1 started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') as $env:USERNAME") `
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

# Step exit codes, accumulated for RESULT.txt.
$Results = [ordered]@{}
function Record($key, $val) { $Results[$key] = $val; Log ("RESULT  {0} = {1}" -f $key, $val) }

# --- Finalizer: always writes RESULT.txt then DONE -------------------------
function Finalize($verdict) {
  try {
    $lines = @()
    $lines += "M70 sandbox migration harness - RESULT"
    $lines += "generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ("sandbox host: {0}  user: {1}" -f $env:COMPUTERNAME, $env:USERNAME)
    $lines += ""
    foreach ($k in $Results.Keys) { $lines += ("{0,-28} {1}" -f $k, $Results[$k]) }
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
# If the main run wedges, this background job writes DONE after 35 min so the
# host-side runner (40 min poll) never hangs.
$WatchdogMinutes = 35
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
  Log "M70 sandbox migration harness starting."
  Log "USERPROFILE = $Home_"
  Log "LOCALAPPDATA = $env:LOCALAPPDATA"

  # ---- Stage A: copy dotfiles to a writable path --------------------------
  Section 'Stage A - copy dotfiles to writable sandbox path'
  try {
    if (-not (Test-Path $DotfilesSrc)) { throw "mapped dotfiles source missing: $DotfilesSrc" }
    Copy-Item -Path $DotfilesSrc -Destination $DotfilesDst -Recurse -Force -ErrorAction Stop
    # Drop the copied .git to keep it light; the migration only needs the
    # working tree (home.nim + stow/).
    $g = Join-Path $DotfilesDst '.git'
    if (Test-Path $g) { Remove-Item $g -Recurse -Force -ErrorAction SilentlyContinue }
    $haveHome = Test-Path (Join-Path $DotfilesDst 'home.nim')
    $haveStow = Test-Path (Join-Path $DotfilesDst 'stow')
    Log "dotfiles copied to $DotfilesDst (home.nim=$haveHome stow=$haveStow)"
    $stageA = if ($haveHome -and $haveStow) { 'OK' } else { 'INCOMPLETE' }
    Record 'stageA_dotfiles_copy' $stageA
  } catch {
    Log "Stage A FAILED: $_"
    Record 'stageA_dotfiles_copy' "FAILED: $_"
  }

  # ---- Stage B: install Scoop + extras bucket + seed cache ----------------
  Section 'Stage B - install Scoop, add extras bucket, seed cache'
  $scoopOk = $false
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Set-ExecutionPolicy can THROW a terminating error when the policy is
    # already overridden at a more specific scope (Windows Sandbox sets the
    # process scope to Bypass). -ErrorAction SilentlyContinue does not catch
    # a terminating error, so wrap it in its own try/catch - we already run
    # via `-ExecutionPolicy Bypass` so the effective policy is fine either way.
    try {
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    } catch { Log "Set-ExecutionPolicy note (non-fatal): $_" }
    $env:SCOOP = Join-Path $Home_ 'scoop'
    [Environment]::SetEnvironmentVariable('SCOOP', $env:SCOOP, 'User')

    # Wait for networking to come up - Windows Sandbox runs the LogonCommand
    # before the network stack is necessarily ready. Bounded: up to 4 min.
    $netOk = $false
    for ($i = 0; $i -lt 48; $i++) {
      try {
        if (Test-Connection -ComputerName 'raw.githubusercontent.com' -Count 1 -Quiet -ErrorAction SilentlyContinue) {
          $netOk = $true; break
        }
      } catch {}
      Start-Sleep -Seconds 5
    }
    Log "network reachable: $netOk (after $($i*5)s)"
    $netState = if ($netOk) { 'OK' } else { 'NO-NETWORK' }
    Record 'stageB_network' $netState

    Log "installing Scoop into $env:SCOOP ..."
    $bootLog = Join-Path $Out 'scoop-bootstrap.log'
    # The official bootstrap. WDAGUtilityAccount is an admin account, so
    # use -RunAsAdmin to silence the non-admin warning path. The whole
    # bootstrap is bounded by a background job with a 5-min ceiling so a
    # stuck download cannot wedge the run.
    $bootJob = Start-Job -ScriptBlock {
      param($scoopRoot)
      $env:SCOOP = $scoopRoot
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      try {
        Invoke-RestMethod -Uri 'https://get.scoop.sh' -TimeoutSec 90 |
          Out-File -FilePath C:\scoop-install.ps1 -Encoding utf8
        & C:\scoop-install.ps1 -RunAsAdmin *>&1
      } catch { "BOOTSTRAP EXCEPTION: $_" }
    } -ArgumentList $env:SCOOP
    if (Wait-Job $bootJob -Timeout 300) {
      Receive-Job $bootJob *>&1 | Tee-Object -FilePath $bootLog | Out-Null
    } else {
      Log "Scoop bootstrap exceeded 5 min - stopping the bootstrap job"
      "BOOTSTRAP TIMEOUT after 300s" | Tee-Object -FilePath $bootLog -Append | Out-Null
      Stop-Job $bootJob -ErrorAction SilentlyContinue
    }
    Remove-Job $bootJob -Force -ErrorAction SilentlyContinue
    # Make scoop visible on PATH for this process.
    $env:Path = "$env:SCOOP\shims;$env:Path"
    $scoopShim = Join-Path $env:SCOOP 'shims\scoop.cmd'
    if (-not (Test-Path $scoopShim)) { $scoopShim = Join-Path $env:SCOOP 'shims\scoop.ps1' }
    $scoopOk = Test-Path $scoopShim
    Log "scoop shim present: $scoopOk ($scoopShim)"

    if ($scoopOk) {
      # M75 FIDELITY FIX: copy the host's Scoop bucket directories
      # (main + extras) DIRECTLY into the sandbox Scoop's buckets\ dir
      # instead of `scoop bucket add` over the network. The prior run's
      # `scoop bucket add extras` was flaky (the git clone took only ~5s
      # and was incomplete), leaving the 5 extras-bucket apps - age,
      # windows-terminal, vscode, firefox, googlechrome - with no
      # manifest, so `repro home apply` aborted at step 7. The manifests
      # are small JSON files; a direct copy is fast and guarantees EVERY
      # manifest the host has is present in the sandbox.
      $bucketLog = Join-Path $Out 'scoop-bucket.log'
      $bucketsDst = Join-Path $env:SCOOP 'buckets'
      if (-not (Test-Path $bucketsDst)) { New-Item -ItemType Directory -Path $bucketsDst -Force | Out-Null }
      $bucketsCopied = @()
      if (Test-Path $ScoopBktSrc) {
        foreach ($bk in @('main','extras')) {
          $src = Join-Path $ScoopBktSrc $bk
          $dst = Join-Path $bucketsDst $bk
          if (-not (Test-Path $src)) { Log "  bucket source missing: $src"; continue }
          try {
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue }
            # robocopy /E (incl empty dirs) /XJ (exclude junction points -
            # bucket dirs have none, but /XJ is defensive). /XD .git skips
            # the bucket's git history (~140 MB across both buckets) - Scoop
            # enumerates buckets by DIRECTORY PRESENCE and resolves a
            # manifest by a filesystem scan of buckets\<name>\bucket\*.json
            # (lib\buckets.ps1 Get-LocalBucket; lib\manifest.ps1
            # manifest_path), so a directory-only copy with NO .git is fully
            # functional for `scoop install` / `scoop list`. /NFL /NDL /NJH
            # /NJS /NP keep the log terse; /R:1 /W:1 keep retries short.
            $rc = robocopy $src $dst /E /XJ /XD '.git' /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
            $rcExit = $LASTEXITCODE
            "robocopy bucket $bk -> exit $rcExit" | Add-Content $bucketLog -Encoding utf8
            # robocopy exit codes 0-7 are success (8+ is failure).
            $manifestDir = Join-Path $dst 'bucket'
            $mcount = 0
            if (Test-Path $manifestDir) {
              $mcount = (Get-ChildItem $manifestDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Measure-Object).Count
            }
            Log "  copied bucket '$bk' ($mcount manifests, robocopy exit $rcExit)"
            if ($rcExit -lt 8 -and $mcount -gt 0) { $bucketsCopied += $bk }
          } catch { Log "  bucket '$bk' copy FAILED: $_" }
        }
      } else {
        Log "no mapped scoop buckets at $ScoopBktSrc"
      }
      # The buckets are now physically present under buckets\<name>\;
      # Scoop discovers them by directory presence (no `scoop bucket add`
      # / git clone needed - that is exactly the flaky network step the
      # M75 fix removes). Confirm Scoop sees them.
      try {
        & scoop bucket list *>&1 | Tee-Object -FilePath $bucketLog -Append | Out-Null
      } catch { Log "  scoop bucket list note: $_" }
      Record 'stageB_buckets_copied' (($bucketsCopied -join ',') + " (of main,extras)")

      # Seed the download cache so installs are fast local extracts.
      $cacheDst = Join-Path $env:SCOOP 'cache'
      if (-not (Test-Path $cacheDst)) { New-Item -ItemType Directory -Path $cacheDst -Force | Out-Null }
      if (Test-Path $ScoopCacheSrc) {
        $n = 0
        Get-ChildItem $ScoopCacheSrc -File -ErrorAction SilentlyContinue | ForEach-Object {
          try { Copy-Item $_.FullName (Join-Path $cacheDst $_.Name) -Force; $n++ } catch {}
        }
        Log "seeded $n files into Scoop cache from $ScoopCacheSrc"
        Record 'stageB_cache_seeded' $n
      } else {
        Log "no mapped scoop cache at $ScoopCacheSrc - installs will download"
        Record 'stageB_cache_seeded' 0
      }

    }

    # M76 FIDELITY FIX: deliver the Visual C++ 2015-2022 runtime DLLs.
    # A pristine Windows Sandbox image ships WITHOUT the MSVC runtime
    # (vcruntime140.dll, vcruntime140_1.dll, msvcp140.dll, ...). The user's
    # REAL host HAS those DLLs system-wide in C:\Windows\System32 (every
    # developer machine does), so MSVC-linked Scoop apps - notably codex.exe
    # and nvim.exe - run there. In the bare sandbox the Scoop adapter's
    # post-install probe (`<tool> --version`) aborts with exit -1073741515
    # (0xC0000135 = STATUS_DLL_NOT_FOUND), failing `repro home apply` step 7.
    #
    # The PRIOR fix ran `scoop install vcredist`, which downloads and runs
    # Microsoft's official redistributable installers - it timed out at 600s
    # (x2 attempts). This fix instead copies the HOST's own runtime DLLs
    # (mapped read-only at C:\harness\vcruntime by migration.wsb, populated
    # from the host's System32 by run-sandbox-migration.ps1) directly into
    # the sandbox's C:\Windows\System32. The sandbox user (WDAGUtilityAccount)
    # is an admin, so System32 is writable. This is a copy of ~5 small DLLs -
    # seconds, not minutes - and it faithfully replicates the host's existing
    # system-wide runtime. This is a sandbox-fidelity gap, NOT a Reprobuild
    # bug: the real host already has these DLLs; the sandbox just lacked them.
    $vcOk = $false
    try {
      $sys32 = Join-Path $env:WINDIR 'System32'
      # Already present? (e.g. a future sandbox image ships the runtime.)
      if (Test-Path (Join-Path $sys32 'vcruntime140.dll')) {
        Log "vcruntime140.dll already present in System32 - VC++ runtime OK"
        $vcOk = $true
      }
      if (-not $vcOk) {
        if (-not (Test-Path $VcRuntimeSrc)) {
          Log "mapped VC++ runtime dir missing: $VcRuntimeSrc"
        } else {
          $vcDlls = Get-ChildItem $VcRuntimeSrc -Filter '*.dll' -File -ErrorAction SilentlyContinue
          Log ("copying {0} VC++ runtime DLL(s) from {1} into {2} ..." -f `
               $vcDlls.Count, $VcRuntimeSrc, $sys32)
          $vcN = 0
          foreach ($d in $vcDlls) {
            try {
              Copy-Item $d.FullName (Join-Path $sys32 $d.Name) -Force -ErrorAction Stop
              $vcN++
              Log ("  copied {0} ({1} bytes)" -f $d.Name, $d.Length)
            } catch {
              Log ("  FAILED to copy {0}: {1}" -f $d.Name, $_)
            }
          }
          Log "copied $vcN VC++ runtime DLL(s) into System32"
        }
        # Verify the mandatory runtime DLL is now resolvable in System32.
        if (Test-Path (Join-Path $sys32 'vcruntime140.dll')) {
          $vcOk = $true
          Log "vcruntime140.dll present in System32 - VC++ runtime OK"
        } else {
          Log "vcruntime140.dll NOT present in System32 after copy - VC++ runtime FAIL"
        }
      }
    } catch {
      Log "VC++ runtime delivery EXCEPTION: $_"
    }
    Record 'stageB_vcredist' ($(if ($vcOk) { 'OK' } else { 'FAIL' }))
    $scoopState = if ($scoopOk) { 'OK' } else { 'FAILED' }
    Record 'stageB_scoop_install' $scoopState
  } catch {
    Log "Stage B FAILED: $_"
    Record 'stageB_scoop_install' "FAILED: $_"
  }

  # ---- Stage C: install the 14 migration-profile packages -----------------
  # M75 FIDELITY FIX: the sandbox must end with ALL 14 migration packages
  # genuinely installed and `scoop list`-visible - exactly as on the real
  # host - so `repro home apply` step 7 sees every package as a cache-hit.
  #
  # Primary method: `scoop install` each app. With the host buckets copied
  # in (Stage B) every manifest is present, and with the host cache seeded
  # in every archive is a fast local extract. Each install runs under a
  # per-app timeout; a genuine network download failure is retried once.
  #
  # Fallback: if `scoop install` of an app still leaves no install tree,
  # copy the host's already-installed apps\<app>\<version>\ tree in with
  # robocopy /E /XJ (junction-aware: /XJ excludes the `current` junction
  # so a recursive copy never traverses it), recreate the `current`
  # junction, and `scoop reset` to fix the shims.
  Section 'Stage C - install the 14 migration packages (target: 14/14)'
  $pkgs = @('age','gnupg','git','gh','windows-terminal','vscode','neovim',
            'pwsh','direnv','ripgrep','firefox','googlechrome','codex','claude-code')
  $installLog = Join-Path $Out 'scoop-install.log'
  $installed = 0; $failed = @(); $viaFallback = @()

  # Run one `scoop install <app>` under a bounded background job so a
  # stuck download cannot wedge the whole run. Returns $true if the
  # on-disk install tree appeared.
  function Install-OneScoop($app, $timeoutSec) {
    "==== scoop install $app (timeout ${timeoutSec}s) ====" | Add-Content $installLog -Encoding utf8
    $job = Start-Job -ScriptBlock {
      param($scoopRoot, $appName)
      $env:SCOOP = $scoopRoot
      $env:Path  = "$scoopRoot\shims;$env:Path"
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      & scoop install $appName *>&1
    } -ArgumentList $env:SCOOP, $app
    if (Wait-Job $job -Timeout $timeoutSec) {
      Receive-Job $job *>&1 | Tee-Object -FilePath $installLog -Append | Out-Null
    } else {
      "  TIMEOUT after ${timeoutSec}s installing $app" | Add-Content $installLog -Encoding utf8
      Stop-Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $appDir = Join-Path $env:SCOOP "apps\$app"
    return (Test-Path $appDir)
  }

  # Junction-aware fallback: copy the host's installed app tree in.
  function Install-OneFromHostTree($app) {
    $srcApp = Join-Path $ScoopAppsSrc $app
    if (-not (Test-Path $srcApp)) { Log "  [fallback] no host app tree for $app"; return $false }
    # Pick the single non-`current` version directory.
    $verDir = Get-ChildItem $srcApp -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -ne 'current' } | Select-Object -First 1
    if (-not $verDir) { Log "  [fallback] no version dir for $app"; return $false }
    $ver = $verDir.Name
    $dstApp = Join-Path $env:SCOOP "apps\$app"
    $dstVer = Join-Path $dstApp $ver
    try {
      if (-not (Test-Path $dstApp)) { New-Item -ItemType Directory -Path $dstApp -Force | Out-Null }
      "==== [fallback] robocopy host tree $app\$ver ====" | Add-Content $installLog -Encoding utf8
      # /E recurse incl empty; /XJ EXCLUDE junction points - critical so
      # the copy never traverses the `current` junction. /COPY:DAT skips
      # ACLs (sandbox account differs). /R:1 /W:1 short retries.
      robocopy $verDir.FullName $dstVer /E /XJ /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP |
        Add-Content $installLog -Encoding utf8
      $rcExit = $LASTEXITCODE
      "  robocopy $app exit $rcExit" | Add-Content $installLog -Encoding utf8
      if ($rcExit -ge 8) { Log "  [fallback] robocopy FAILED for $app (exit $rcExit)"; return $false }
      # Recreate the `current` junction -> the version dir.
      $cur = Join-Path $dstApp 'current'
      if (Test-Path $cur) { cmd /c rmdir "$cur" 2>&1 | Out-Null }
      cmd /c mklink /J "$cur" "$dstVer" 2>&1 | Add-Content $installLog -Encoding utf8
      # `scoop reset` fixes the shims + PATH/env for the copied app.
      & scoop reset $app *>&1 | Add-Content $installLog -Encoding utf8
      $ok = Test-Path $dstVer
      if ($ok) { Log "  [fallback] $app installed from host tree ($ver)" }
      return $ok
    } catch {
      Log "  [fallback] $app host-tree copy FAILED: $_"
      return $false
    }
  }

  if ($scoopOk) {
    foreach ($p in $pkgs) {
      $appDir = Join-Path $env:SCOOP "apps\$p"
      $ok = $false
      try {
        Log "scoop install $p ..."
        # GUI apps are large; give them a generous ceiling. Cached apps
        # extract in seconds regardless.
        $tmo = if ($p -in @('vscode','firefox','googlechrome','pwsh','claude-code','codex','git')) { 600 } else { 240 }
        $ok = Install-OneScoop $p $tmo
        if (-not $ok) {
          Log "  $p not installed on first try - retrying once ..."
          $ok = Install-OneScoop $p $tmo
        }
      } catch {
        Log "  $p scoop install EXCEPTION: $_"
        "INSTALL EXCEPTION ${p}: $_" | Add-Content $installLog -Encoding utf8
      }
      # Fallback to copying the host's installed tree.
      if (-not $ok) {
        Log "  $p still not installed - trying host-tree fallback ..."
        if (Install-OneFromHostTree $p) { $ok = $true; $viaFallback += $p }
      }
      if ($ok -and (Test-Path $appDir)) { $installed++; Log "  $p OK" }
      else { $failed += $p; Log "  $p NOT INSTALLED" }
    }
  } else {
    Log "Scoop not available - skipping package installs."
  }
  Record 'stageC_packages_installed' ("{0}/14" -f $installed)
  if ($viaFallback.Count -gt 0) { Record 'stageC_via_host_tree' ($viaFallback -join ',') }
  if ($failed.Count -gt 0) { Record 'stageC_packages_failed' ($failed -join ',') }
  else { Record 'stageC_packages_failed' '(none - all 14 installed)' }

  # Capture `scoop list` for the host.
  try {
    if ($scoopOk) { & scoop list *>&1 | Out-File (Join-Path $Out 'scoop-list.txt') -Encoding utf8 }
  } catch { "scoop list failed: $_" | Out-File (Join-Path $Out 'scoop-list.txt') -Encoding utf8 }

  # ---- Stage D: replicate pre-existing stow symlinks ----------------------
  # Mirrors the file/junction links bin/home-switch.ps1 New-StowLink creates.
  # The links point at the WRITABLE dotfiles copy ($DotfilesDst) so the
  # migration's stow source matches -> "existing correct symlink" cache-hit.
  Section 'Stage D - replicate pre-existing stow symlinks'
  $stow = Join-Path $DotfilesDst 'stow'
  function New-HarnessLink($target, $link, [switch]$Directory) {
    try {
      if (-not (Test-Path $target)) { Log "  skip (no target): $target"; return $false }
      $parent = Split-Path $link -Parent
      if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      if (Test-Path $link) { Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue }
      if ($Directory) {
        # Directory junction (matches New-StowLink -Directory).
        cmd /c mklink /J "$link" "$target" | Out-Null
      } else {
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
      }
      $ok = Test-Path $link
      $okText = if ($ok) { 'OK' } else { 'FAIL' }
      Log ("  link {0} -> {1} : {2}" -f $link, $target, $okText)
      return $ok
    } catch { Log "  link FAILED ($link): $_"; return $false }
  }
  $linksMade = 0
  try {
    # ~/.gitconfig -> stow/git/.gitconfig
    if (New-HarnessLink (Join-Path $stow 'git\.gitconfig') (Join-Path $Home_ '.gitconfig')) { $linksMade++ }
    # org *.gitconfig files -> ~/<name>.gitconfig
    foreach ($cfg in @('blockdaemon.gitconfig','blocksense.gitconfig','eli.gitconfig',
                       'metacraft.gitconfig','stakefish.gitconfig','status.gitconfig',
                       'agent-harbor.gitconfig')) {
      $t = Join-Path $stow ("git\" + $cfg)
      if (Test-Path $t) { if (New-HarnessLink $t (Join-Path $Home_ $cfg)) { $linksMade++ } }
    }
    # ~/.ssh/config -> stow/ssh/.ssh/config  (file symlink)
    if (New-HarnessLink (Join-Path $stow 'ssh\.ssh\config') (Join-Path $Home_ '.ssh\config')) { $linksMade++ }
    # ~/.ssh/config.d -> stow/ssh/.ssh/config.d (directory junction)
    if (New-HarnessLink (Join-Path $stow 'ssh\.ssh\config.d') (Join-Path $Home_ '.ssh\config.d') -Directory) { $linksMade++ }
    Record 'stageD_symlinks_created' $linksMade
  } catch {
    Log "Stage D FAILED: $_"
    Record 'stageD_symlinks_created' "FAILED: $_"
  }

  # ---- Stage E: copy repro.exe (+DLLs) to a writable path -----------------
  Section 'Stage E - copy repro binary to writable sandbox path'
  try {
    New-Item -ItemType Directory -Path $ReproDir -Force | Out-Null
    foreach ($f in @('repro.exe','sqlite3_64.dll','repro-launcher.exe')) {
      $s = Join-Path $ReproBinSrc $f
      if (Test-Path $s) { Copy-Item $s (Join-Path $ReproDir $f) -Force; Log "  copied $f" }
      else { Log "  MISSING in mapped repro-bin: $f" }
    }
    $reproOk = Test-Path $ReproExe
    if ($reproOk) {
      $ver = & $ReproExe --version 2>&1
      Log "repro.exe runs: $ver"
    }
    $reproCopyState = if ($reproOk) { 'OK' } else { 'FAILED' }
    Record 'stageE_repro_copy' $reproCopyState
  } catch {
    Log "Stage E FAILED: $_"
    Record 'stageE_repro_copy' "FAILED: $_"
  }

  # ---- Stage F: run the migration -----------------------------------------
  Section 'Stage F - run repro home apply (plan / apply / re-plan)'
  # Helper: run repro home apply with a step kind, capture stdout+stderr+exit.
  function Invoke-Repro($outFile, [string[]]$applyArgs, $timeoutSec) {
    $full = @('home','apply','--profile-dir', $DotfilesDst) + $applyArgs
    Log ("RUN: repro {0}  (timeout {1}s)" -f ($full -join ' '), $timeoutSec)
    $stdoutF = Join-Path $env:TEMP ("repro-out-" + [guid]::NewGuid().ToString('N') + '.txt')
    $stderrF = Join-Path $env:TEMP ("repro-err-" + [guid]::NewGuid().ToString('N') + '.txt')
    $exit = $null
    try {
      $p = Start-Process -FilePath $ReproExe -ArgumentList $full -NoNewWindow -PassThru `
             -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
      # Windows PowerShell 5.1 quirk: Start-Process -PassThru with redirected
      # streams returns a Process object whose OS handle is released once the
      # process exits, leaving .ExitCode $null. Touching .Handle here forces
      # .NET to cache the handle so .ExitCode stays valid after WaitForExit.
      $null = $p.Handle
      if ($p.WaitForExit($timeoutSec * 1000)) {
        # No-arg WaitForExit() ensures the redirected stdout/stderr async
        # readers have fully drained and the exit code is materialized.
        $p.WaitForExit()
        $exit = $p.ExitCode
      } else {
        Log "  TIMEOUT after $timeoutSec s - killing repro process tree"
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
    $body += "COMMAND: repro $($full -join ' ')"
    $body += "EXIT CODE: $exit"
    $body += ""
    $body += "----- STDOUT -----"
    $body += $so
    $body += "----- STDERR -----"
    $body += $se
    Set-Content -Path (Join-Path $Out $outFile) -Value ($body -join "`r`n") -Encoding utf8
    Remove-Item $stdoutF,$stderrF -Force -ErrorAction SilentlyContinue
    Log ("  -> {0} (exit {1})" -f $outFile, $exit)
    return $exit
  }

  $planExit = 'SKIPPED'; $applyExit = 'SKIPPED'; $replanExit = 'SKIPPED'
  if (Test-Path $ReproExe) {
    # 01 - plan (non-mutating). --allow-drift so drift does not flip exit code;
    # we want the full preview regardless.
    $planExit = Invoke-Repro '01-plan.txt' @('--plan','--allow-drift') 600
    Record 'stageF_01_plan_exit' $planExit

    # 02 - apply (mutating). Real scoop installs already done in Stage C, so
    # the package step should be cache-hits.
    $applyExit = Invoke-Repro '02-apply.txt' @() 1200
    Record 'stageF_02_apply_exit' $applyExit

    # 03 - re-plan (idempotency check).
    $replanExit = Invoke-Repro '03-replan.txt' @('--plan','--allow-drift') 600
    Record 'stageF_03_replan_exit' $replanExit
  } else {
    Log "repro.exe missing - skipping Stage F"
    Record 'stageF_01_plan_exit' 'SKIPPED'
    Record 'stageF_02_apply_exit' 'SKIPPED'
    Record 'stageF_03_replan_exit' 'SKIPPED'
  }

  # ---- Stage G: capture post-apply state ----------------------------------
  Section 'Stage G - capture post-apply state'
  try {
    # Recursive $HOME listing with symlink/junction + target annotation.
    $homeListing = @()
    $homeListing += "Recursive listing of `$HOME = $Home_"
    $homeListing += "(L=symlink/junction, F=file, D=dir)"
    $homeListing += ""
    Get-ChildItem -Path $Home_ -Recurse -Force -ErrorAction SilentlyContinue |
      Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Home_.Length).TrimStart('\')
        $tag = if ($_.LinkType) { 'L' } elseif ($_.PSIsContainer) { 'D' } else { 'F' }
        $extra = if ($_.LinkType) {
          $tgt = $_.Target
          if ($tgt -is [array]) { $tgt = $tgt -join ';' }
          "  [$($_.LinkType) -> $tgt]"
        } else { '' }
        $homeListing += ("{0}  {1}{2}" -f $tag, $rel, $extra)
      }
    Set-Content -Path (Join-Path $Out '04-home-tree.txt') -Value $homeListing -Encoding utf8
    Log "wrote 04-home-tree.txt ($($homeListing.Count) lines)"
  } catch { Log "home tree capture failed: $_" }

  try {
    # %LOCALAPPDATA%\repro tree (state dir + store, the apply's default home).
    $reproState = Join-Path $env:LOCALAPPDATA 'repro'
    $stateListing = @()
    $stateListing += "Recursive listing of $reproState"
    $stateListing += ""
    if (Test-Path $reproState) {
      Get-ChildItem -Path $reproState -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName | ForEach-Object {
          $rel = $_.FullName.Substring($reproState.Length).TrimStart('\')
          $tag = if ($_.LinkType) { 'L' } elseif ($_.PSIsContainer) { 'D' } else { 'F' }
          $sz  = if ($_.PSIsContainer) { '' } else { " ($($_.Length) b)" }
          $stateListing += ("{0}  {1}{2}" -f $tag, $rel, $sz)
        }
    } else {
      $stateListing += "(does not exist - no generation was committed)"
    }
    Set-Content -Path (Join-Path $Out '05-repro-state-tree.txt') -Value $stateListing -Encoding utf8
    Log "wrote 05-repro-state-tree.txt"
  } catch { Log "repro state capture failed: $_" }

  # Dump any home.nim that got authored, plus the managed bin dir contents.
  try {
    $binProbe = @()
    foreach ($cand in @((Join-Path $Home_ '.local\bin'), (Join-Path $Home_ 'bin'),
                        (Join-Path $env:LOCALAPPDATA 'repro\home'))) {
      if (Test-Path $cand) {
        $binProbe += "--- $cand ---"
        Get-ChildItem $cand -Recurse -Force -ErrorAction SilentlyContinue |
          ForEach-Object { $binProbe += "  $($_.FullName)" }
      }
    }
    if ($binProbe.Count -gt 0) {
      Set-Content -Path (Join-Path $Out '06-launchers-probe.txt') -Value $binProbe -Encoding utf8
    }
  } catch {}

  # Overall verdict.
  $verdict =
    if ("$applyExit" -eq '0' -and "$replanExit" -eq '0') {
      "PASS - apply succeeded (exit 0), re-plan exit 0."
    } elseif ("$applyExit" -eq '0') {
      "PARTIAL - apply succeeded but re-plan exit=$replanExit (idempotency suspect)."
    } elseif ("$applyExit" -eq 'SKIPPED') {
      "ABORTED - apply never ran (provisioning failed); see RESULT.txt steps."
    } else {
      "FAIL - apply exit=$applyExit; see 02-apply.txt for the failing step."
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
