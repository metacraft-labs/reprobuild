<#
  run-wsl-m69-posix.ps1 - HOST-SIDE runner for the M69 POSIX
  destructive-gate WSL harness.

  Creates a THROWAWAY Ubuntu 22.04 WSL distro (imported from the
  official cloud-image rootfs tarball), runs all FOUR M69 Linux
  destructive gates inside it sequentially in ONE distro session
  (provision once, build + run each gate with its own
  REPRO_M69_*_VM=1 env var, capture per-gate stdout/stderr/exit),
  copies the output to D:\metacraft\wsl-m69-posix-out\, and
  **unregisters the distro in a finally block** so a gate failure
  does NOT leak a stale distro.

  Gates exercised (all in one distro session):
    - passwd.user             (REPRO_M69_PASSWD_VM=1)
    - fs.systemFile           (REPRO_M69_FS_VM=1)
    - env.systemVariable      (REPRO_M69_ENV_VM=1)
    - systemd.systemUnit      (REPRO_M69_SYSTEMD_VM=1)

  HOST SAFETY: this script only ever writes inside three scoped dirs:
      D:\metacraft\wsl-m69-posix-cache\  (rootfs + Nim tarball cache)
      D:\metacraft\wsl-m69-posix-out\    (gate output)
      D:\metacraft\wsl-m69-posix-state\<distro-name>\
                                          (the throwaway distro's VHD)
  The user's primary WSL distribution (eli-wsl) is NEVER touched.
  Every useradd / usermod / userdel / /etc write / systemctl
  daemon-reload the gates perform runs inside the disposable distro
  and disappears with wsl --unregister.

  Idempotence: at start, any stale distro matching `repro-m69-posix-*`
  is unregistered, and any corresponding stale state dir is removed.

  Usage:  pwsh -File run-wsl-m69-posix.ps1 [-TimeoutMinutes 45]
                                           [-KeepDistro]
                                           [-Verbose]

  -KeepDistro is for debugging: skips the finally-unregister so you can
  `wsl -d <distro> bash` into the failed distro to investigate. The
  warning lines tell you exactly which `wsl --unregister` to run by
  hand afterwards.
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 45,
  [switch]$KeepDistro
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# Constants + paths
# ----------------------------------------------------------------------------
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProvisionSh     = Join-Path $ScriptDir 'provision-and-run-m69-posix.sh'

$CacheDir        = 'D:\metacraft\wsl-m69-posix-cache'
$OutDir          = 'D:\metacraft\wsl-m69-posix-out'
$StateRoot       = 'D:\metacraft\wsl-m69-posix-state'

$RootfsName      = 'ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz'
$RootfsUrl       = "https://cloud-images.ubuntu.com/wsl/jammy/current/$RootfsName"
$RootfsCachePath = Join-Path $CacheDir $RootfsName

# Matched to the host's D:\metacraft-dev-deps\nim\2.2.8\.
$NimVersion      = '2.2.8'
$NimTarName      = "nim-$NimVersion-linux_x64.tar.xz"
$NimTarUrl       = "https://nim-lang.org/download/$NimTarName"
$NimTarCachePath = Join-Path $CacheDir $NimTarName

# Unique, namespaced distro name so we never collide with the user's
# real distros. The name is bounded by Windows registry key length
# constraints; `repro-m69-posix-<pid>` is well under any limit.
$DistroName      = "repro-m69-posix-$PID"
$DistroPattern   = 'repro-m69-posix-*'
$DistroStateDir  = Join-Path $StateRoot $DistroName

$RepoHostDir     = 'D:\metacraft\reprobuild'
$RunquotaHostDir = 'D:\metacraft\runquota'

# Cap the in-distro run on a generous timeout: even a cold first run
# (rootfs install + apt-get update + tarball extract + nim compile)
# fits in single-digit minutes; 30 min is plenty of headroom.
$DoneFile        = Join-Path $OutDir 'DONE'

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
function Info($m)  { Write-Host "[run] $m" }
function Warn($m)  { Write-Host "[run] WARNING: $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[run] ERROR: $m"   -ForegroundColor Red }

# ----------------------------------------------------------------------------
# WSL helpers
#
# wsl.exe is bi-modal on stdout encoding:
#   * Management commands (--list, --status, --terminate, --unregister,
#     --import, --help) emit UTF-16 LE.
#   * --exec / -e forwards the Linux child's stdout/stderr UNCHANGED
#     (UTF-8 typically).
#
# So we need TWO wrappers. Invoke-WslMgmt forces UTF-16 just for the
# duration of the call; Invoke-WslExec uses UTF-8 forwarding.
#
# CRITICAL: do NOT use [Parameter(ValueFromRemainingArguments)] on the
# wrappers. PowerShell would silently steal `-d` / `-e` arguments as the
# automatic -Debug / -ErrorAction switches, leaving wsl.exe with a
# garbled argv. Pass an explicit string[] of args instead.
# ----------------------------------------------------------------------------
function Invoke-WslMgmt {
  param([Parameter(Mandatory=$true)][string[]]$WslArgs)
  $prev = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
  try {
    & wsl.exe @WslArgs 2>&1
  } finally {
    [Console]::OutputEncoding = $prev
  }
}

function Invoke-WslExec {
  param([Parameter(Mandatory=$true)][string[]]$WslArgs)
  # Force UTF-8 decoding of the in-distro Linux stdout. (wsl.exe forwards
  # the child stdout/stderr unchanged.)
  $prev = [Console]::OutputEncoding
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  try {
    & wsl.exe @WslArgs 2>&1
  } finally {
    [Console]::OutputEncoding = $prev
  }
}

function Get-WslDistros {
  # Returns array of distro names. `wsl --list --quiet` is the most
  # reliable parse: one name per line, no decorations.
  $raw = Invoke-WslMgmt -WslArgs @('--list','--quiet')
  $names = @()
  foreach ($line in ($raw -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -ne '') { $names += $t }
  }
  return ,$names
}

function Test-WslDistroExists {
  param([string]$Name)
  $all = Get-WslDistros
  return ($all -contains $Name)
}

# ----------------------------------------------------------------------------
# Pre-flight: WSL present + provision script present + rootfs URL reachable
# ----------------------------------------------------------------------------
Info "============================================================"
Info "M69 POSIX destructive-gate WSL harness"
Info "============================================================"
Info "host:        $env:COMPUTERNAME / $env:USERNAME"
Info "throwaway distro: $DistroName"
Info "rootfs:      $RootfsUrl"
Info "Nim:         $NimTarUrl"
Info "out dir:     $OutDir"
Info "cache dir:   $CacheDir"
Info "state dir:   $DistroStateDir"

# WSL availability
try {
  $statusRaw = Invoke-WslMgmt -WslArgs @('--status')
  if (-not $statusRaw) {
    Fail "wsl --status returned nothing. Is WSL installed?"
    exit 1
  }
} catch {
  Fail "wsl.exe failed: $_"
  exit 1
}

if (-not (Test-Path $ProvisionSh)) {
  Fail "provision script missing: $ProvisionSh"
  exit 1
}

# Quick path test that the runner can write to its scoped dirs.
foreach ($d in @($CacheDir, $OutDir, $StateRoot)) {
  if (-not (Test-Path $d)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
}

# ----------------------------------------------------------------------------
# Idempotence: clean up any stale distros + state from prior runs
# ----------------------------------------------------------------------------
Info ""
Info "--- Idempotence: clean up any stale repro-m69-posix-* distros ---"
$existing = Get-WslDistros
$stale = @($existing | Where-Object { $_ -like $DistroPattern })
if ($stale.Count -gt 0) {
  foreach ($s in $stale) {
    Warn "found stale distro '$s' - unregistering"
    Invoke-WslMgmt -WslArgs @('--terminate', $s) | Out-Null
    Invoke-WslMgmt -WslArgs @('--unregister', $s) | Out-Null
  }
} else {
  Info "no stale distros (existing: $($existing -join ', '))"
}
# Sweep stale state dirs (a distro registered but state dir gone, or
# state dir present but distro gone - either way clean up).
if (Test-Path $StateRoot) {
  Get-ChildItem -LiteralPath $StateRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $DistroPattern } |
    ForEach-Object {
      $stillRegistered = Test-WslDistroExists $_.Name
      if (-not $stillRegistered) {
        Warn "removing orphaned state dir: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force `
          -ErrorAction SilentlyContinue
      }
    }
}

# ----------------------------------------------------------------------------
# Clear OUTPUT dir (scoped strictly to $OutDir)
# ----------------------------------------------------------------------------
Info ""
Info "--- Clear OUTPUT dir: $OutDir ---"
if (Test-Path $OutDir) {
  Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# ----------------------------------------------------------------------------
# Snapshot wsl --list before, for the leak-check report
# ----------------------------------------------------------------------------
$distrosBefore = Get-WslDistros
Info ""
Info "--- WSL distros BEFORE: $($distrosBefore -join ', ') ---"

# ----------------------------------------------------------------------------
# Download rootfs + Nim tarball (cached)
# ----------------------------------------------------------------------------
Info ""
Info "--- Download cache: rootfs + Nim tarball (cached under $CacheDir) ---"
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ensure-CachedFile {
  param([string]$Url, [string]$Path, [int]$MinBytes = 1024)
  if (Test-Path $Path) {
    $sz = (Get-Item $Path).Length
    if ($sz -ge $MinBytes) {
      Info "  cached: $Path ($([math]::Round($sz/1MB,1)) MB)"
      return
    }
    Warn "  cached file too small ($sz B), re-downloading: $Path"
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  }
  Info "  downloading $Url"
  Info "             -> $Path"
  $t0 = Get-Date
  Invoke-WebRequest -Uri $Url -OutFile $Path -TimeoutSec 600
  $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $sz = (Get-Item $Path).Length
  Info "  downloaded ${elapsed}s, $([math]::Round($sz/1MB,1)) MB"
}

try {
  Ensure-CachedFile -Url $RootfsUrl -Path $RootfsCachePath -MinBytes (50 * 1024 * 1024)
  Ensure-CachedFile -Url $NimTarUrl -Path $NimTarCachePath -MinBytes (5  * 1024 * 1024)
} catch {
  Fail "cache download failed: $_"
  exit 1
}

# ----------------------------------------------------------------------------
# Main run, wrapped in try/finally so the distro is ALWAYS unregistered.
# ----------------------------------------------------------------------------
$startedAt = Get-Date
$importedOk = $false
$gateVerdict = 'UNKNOWN'
$gateExitCode = $null
$importExit = $null

try {
  # -- Stage 1: wsl --import the throwaway distro --------------------------
  Info ""
  Info "--- wsl --import $DistroName <- $RootfsName ---"
  Info "    install location: $DistroStateDir"
  if (-not (Test-Path $DistroStateDir)) {
    New-Item -ItemType Directory -Path $DistroStateDir -Force | Out-Null
  }
  $t0 = Get-Date
  # `wsl --import` accepts UTF-16 input arguments transparently.
  & wsl.exe --import $DistroName $DistroStateDir $RootfsCachePath 2>&1 |
    ForEach-Object { Write-Host "  [wsl-import] $_" }
  $importExit = $LASTEXITCODE
  $importElapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  Info "  import exit=$importExit  (${importElapsed}s)"
  if ($importExit -ne 0) {
    throw "wsl --import failed with exit $importExit"
  }
  if (-not (Test-WslDistroExists $DistroName)) {
    throw "wsl --import claimed success but distro '$DistroName' not in --list"
  }
  $importedOk = $true

  # -- Stage 2: run the provision script directly from its /mnt/ path.
  #             The .sh file is LF-only on disk (written by the Write tool
  #             and verified by `file`); no in-distro CRLF translation is
  #             required. Running via `bash <path>` (rather than copying
  #             into /root first) keeps the stage simple and lets the
  #             script see its own host path for diagnostics.
  Info ""
  Info "--- Stage provision script path (resolve /mnt/ form) ---"
  $shHostPath = $ProvisionSh
  $shInDistroHostPath = '/mnt/' +
    $shHostPath.Substring(0,1).ToLower() +
    ($shHostPath.Substring(2) -replace '\\', '/')
  Info "  in-distro script path: $shInDistroHostPath"

  # Quick smoke-test the distro can read the .sh from /mnt/.
  $smoke = Invoke-WslExec -WslArgs @('-d', $DistroName, '--user', 'root', '--exec', '/bin/bash', '-c', "test -r '$shInDistroHostPath' && head -n 1 '$shInDistroHostPath'")
  foreach ($l in @($smoke)) { Write-Host "  [smoke] $l" }

  # -- Stage 3: run the provision script ----------------------------------
  Info ""
  Info "--- Run gate inside distro ---"
  $envPrefix = @(
    "REPRO_HOST_OUT_DIR='/mnt/d/metacraft/wsl-m69-posix-out'",
    "REPRO_HOST_REPO_DIR='/mnt/d/metacraft/reprobuild'",
    "REPRO_HOST_RUNQUOTA='/mnt/d/metacraft/runquota'",
    "REPRO_HOST_NIM_TAR='/mnt/d/metacraft/wsl-m69-posix-cache/$NimTarName'"
  ) -join ' '
  # Invoke via bash explicitly so we don't depend on the .sh having
  # exec bits set on the NTFS mount.
  $runCmd = "$envPrefix bash '$shInDistroHostPath'"

  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  Info "  command:  bash <provision> with REPRO_* env"
  Info "  deadline: $($deadline.ToString('HH:mm:ss')) (in $TimeoutMinutes min)"

  # Run via Start-Process so we can wait with a timeout AND capture
  # stdout/stderr to host files. wsl.exe forwards the in-distro stdout
  # as UTF-8; the temp files therefore want UTF-8 decoding when we
  # read them back.
  #
  # IMPORTANT: -ArgumentList ARRAY does NOT properly quote elements
  # that contain spaces or quotes for native exes - PowerShell joins
  # them naively, so wsl.exe sees a corrupted argv (the entire $runCmd
  # gets re-tokenised). Pass a SINGLE pre-quoted string instead; this
  # is the documented escape hatch for Windows-style native arg lines.
  $stdoutF = Join-Path $env:TEMP "wsl-m69-stdout-$PID.txt"
  $stderrF = Join-Path $env:TEMP "wsl-m69-stderr-$PID.txt"
  $argLine = "-d $DistroName --user root --exec /bin/bash -c `"$runCmd`""
  $proc = Start-Process -FilePath 'wsl.exe' `
    -ArgumentList $argLine `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
  $null = $proc.Handle

  $waitMs = $TimeoutMinutes * 60 * 1000
  if (-not $proc.WaitForExit($waitMs)) {
    Warn "  TIMEOUT after $TimeoutMinutes min - killing in-distro process"
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    # Make sure the distro itself is also terminated so the next
    # `wsl --unregister` is not blocked by a stuck VM.
    Invoke-WslMgmt -WslArgs @('--terminate', $DistroName) | Out-Null
    $gateVerdict = "TIMEOUT after $TimeoutMinutes min"
  } else {
    $proc.WaitForExit()
    $gateExitCode = $proc.ExitCode
    Info "  wsl.exe exit=$gateExitCode  (provision script's own exit)"
  }

  # Emit captured stdout/stderr to the console (and persist into OutDir
  # for the record). The bash script also writes its own logs in OutDir.
  if (Test-Path $stdoutF) {
    $stdoutBytes = (Get-Item $stdoutF).Length
    Copy-Item -LiteralPath $stdoutF -Destination (Join-Path $OutDir '_wsl-stdout.txt') -Force
    if ($stdoutBytes -gt 0) {
      $stdoutText = [System.IO.File]::ReadAllText($stdoutF, [System.Text.Encoding]::UTF8)
      $lines = $stdoutText -split "`r?`n"
      $tail = if ($lines.Length -gt 200) { $lines[($lines.Length-200)..($lines.Length-1)] } else { $lines }
      Info "----- in-distro stdout ($stdoutBytes bytes, last $($tail.Length) lines) -----"
      foreach ($l in $tail) { Write-Host "  $l" }
    } else {
      Warn "----- in-distro stdout: EMPTY (the script may have failed before producing output) -----"
    }
  }
  if (Test-Path $stderrF) {
    $stderrBytes = (Get-Item $stderrF).Length
    if ($stderrBytes -gt 0) {
      $errText = [System.IO.File]::ReadAllText($stderrF, [System.Text.Encoding]::UTF8)
      Warn "----- in-distro stderr ($stderrBytes bytes) -----"
      Write-Host $errText
      Copy-Item -LiteralPath $stderrF -Destination (Join-Path $OutDir '_wsl-stderr.txt') -Force
    }
  }
  Remove-Item -Force -LiteralPath $stdoutF, $stderrF -ErrorAction SilentlyContinue

  # -- Stage 4: confirm DONE sentinel -------------------------------------
  if (Test-Path $DoneFile) {
    Info "  DONE sentinel detected at $DoneFile"
  } else {
    Warn "  no DONE sentinel - the in-distro script did not finalize"
  }
}
catch {
  Fail "main run threw: $_"
  $gateVerdict = "ERROR: $_"
}
finally {
  # ---- ALWAYS unregister the distro --------------------------------------
  Info ""
  Info "--- Cleanup (finally): unregister throwaway distro ---"
  if ($KeepDistro) {
    Warn "  -KeepDistro set: leaving distro '$DistroName' registered"
    Warn "  Inspect with:    wsl -d $DistroName --user root"
    Warn "  Then clean up with:"
    Warn "    wsl --terminate $DistroName"
    Warn "    wsl --unregister $DistroName"
    Warn "    Remove-Item -Recurse -Force $DistroStateDir"
  } else {
    if (Test-WslDistroExists $DistroName) {
      Info "  wsl --terminate $DistroName"
      Invoke-WslMgmt -WslArgs @('--terminate', $DistroName) | Out-Null
      Info "  wsl --unregister $DistroName"
      Invoke-WslMgmt -WslArgs @('--unregister', $DistroName) | Out-Null
    } else {
      if ($importedOk) {
        Warn "  distro '$DistroName' not in --list anymore - already gone?"
      } else {
        Info "  distro was never imported - nothing to unregister"
      }
    }
    # Sometimes the state dir lingers a moment after --unregister; sweep.
    if (Test-Path $DistroStateDir) {
      try {
        Remove-Item -LiteralPath $DistroStateDir -Recurse -Force `
          -ErrorAction Stop
      } catch {
        # Some VHD locks need a moment; retry once.
        Start-Sleep -Seconds 2
        Remove-Item -LiteralPath $DistroStateDir -Recurse -Force `
          -ErrorAction SilentlyContinue
      }
    }
  }
}

# ----------------------------------------------------------------------------
# Post-run report
# ----------------------------------------------------------------------------
$distrosAfter = Get-WslDistros
$elapsedMin = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 2)

Write-Host ""
Info "=================================================================="
Info "Wall-clock: ${elapsedMin} min"
Info ""
Info "--- WSL distros AFTER: $($distrosAfter -join ', ') ---"
if ($distrosAfter -contains $DistroName) {
  if ($KeepDistro) {
    Warn "  -KeepDistro: '$DistroName' INTENTIONALLY left registered."
  } else {
    Fail "  LEAK: throwaway distro '$DistroName' is STILL registered!"
  }
} else {
  Info "  no leak: throwaway distro '$DistroName' is GONE."
}
Info ""
Info "Results landed in: $OutDir"
$files = Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
           Sort-Object Name
if ($files) {
  foreach ($f in $files) {
    Info ("  {0,-32} {1,10} bytes" -f $f.Name, $f.Length)
  }
} else {
  Warn "  (no artifact files - the distro may have failed before writing any)"
}

$resultTxt = Join-Path $OutDir 'RESULT.txt'
if (Test-Path $resultTxt) {
  Write-Host ""
  Info "----- RESULT.txt -----"
  Get-Content $resultTxt | ForEach-Object { Write-Host "  $_" }
}
$perGateRunFiles = @(
  Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '02-*-run.txt' } |
    Sort-Object Name
)
foreach ($f in $perGateRunFiles) {
  Write-Host ""
  Info "----- $($f.Name) (tail 40) -----"
  Get-Content $f.FullName -Tail 40 | ForEach-Object { Write-Host "  $_" }
}
Info "=================================================================="

# Decide the host script's exit code. The in-distro RESULT.txt VERDICT
# line is the authoritative result.
$hostExit = 1
if (Test-Path $resultTxt) {
  $verdictLine = (Get-Content $resultTxt | Where-Object { $_ -like 'VERDICT:*' } | Select-Object -Last 1)
  if ($verdictLine -like '*PASS*') { $hostExit = 0 }
  elseif ($verdictLine -like '*TIMEOUT*') { $hostExit = 2 }
  else { $hostExit = 1 }
}
exit $hostExit
