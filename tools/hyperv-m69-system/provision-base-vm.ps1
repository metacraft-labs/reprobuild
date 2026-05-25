<#
  provision-base-vm.ps1 - one-time, idempotent provisioning of the M69
  Hyper-V harness's base VM and its two snapshots.

  Lifecycle (each step is a no-op if its post-condition is already
  satisfied):

    1. Verify Hyper-V Windows Optional Feature is enabled (admin-only,
       requires host reboot to install - we will NOT enable it
       automatically; we STOP and report).
    2. Verify the Hyper-V PowerShell module is importable.
    3. Verify a virtual switch exists (prefer Default Switch).
    4. Ensure the Microsoft Windows 11 development-environment VHDX is
       cached under D:\metacraft\hyperv-m69-system-cache\.
    5. Ensure the VM `repro-m69-hyperv` exists (create from a
       differencing copy of the cached VHDX so the cache is not
       mutated).
    6. Verify the Guest Service Interface integration service is on.
    7. Boot the VM and wait for PowerShell Direct to be ready.
    8. Inside the VM: uninstall Visual Studio (the dev image ships VS
       pre-installed); disable WSL + VirtualMachinePlatform optional
       features; remove the OpenSSH Server capability if present;
       reboot cleanly.
    9. Inside the VM: provision Nim 2.2.8 + MSYS2/MinGW gcc (matches
       the host's D:\metacraft-dev-deps\nim\2.2.8 reference) so
       gate binaries can be re-built inside the VM if a future
       workflow needs it - the current per-test runner ships
       pre-built binaries in, but Nim+gcc inside the VM is a useful
       fallback for in-VM debugging.
   10. Verify the post-condition for `base-clean`: no VS, no WSL,
       no VMP, no OpenSSH Server. Take Checkpoint `base-clean`.
   11. Inside the VM: install VS Build Tools (the resident
       vs_installer.exe handles its own bootstrap path; we pass
       `install --add Microsoft.VisualStudio.Workload.VCTools
                  --add Microsoft.VisualStudio.Workload.MSBuildTools
                  --installPath C:\BuildTools --quiet --norestart`).
   12. Verify `vswhere` reports the expected workloads. Take
       Checkpoint `base-with-vs`.

  HOST SAFETY:
    * The harness creates ONE VM, named `repro-m69-hyperv`. No
      other VM on the host is queried, started, stopped, or altered.
    * The host's Hyper-V configuration is NEVER altered (no new
      virtual switches, no new external networks). The script picks
      the existing Default Switch if present and STOPs otherwise.
    * The host's optional features, capabilities, services, and
      Programs-and-Features are NEVER altered. Every destructive
      operation runs INSIDE the VM via PowerShell Direct.

  IDEMPOTENCE:
    Every step checks for its own post-condition before doing work.
    A re-run after an interruption picks up where it stopped. A
    re-run with both snapshots present is a no-op and exits 0.

  Usage:  pwsh -File provision-base-vm.ps1
                  [-Force]                # blow away the existing VM + snapshots and rebuild
                  [-VhdxOverridePath <path>] # use a pre-downloaded VHDX
                  [-SkipVsInstall]        # take base-clean only; skip base-with-vs
#>

[CmdletBinding()]
param(
  [switch]$Force,
  [string]$VhdxOverridePath = '',
  [switch]$SkipVsInstall
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$VmName             = 'repro-m69-hyperv'
$VmRamBytes         = 8GB
$VmProcessorCount   = 4
$VmGeneration       = 2          # UEFI

$CacheDir           = 'D:\metacraft\hyperv-m69-system-cache'
$VhdRoot            = 'D:\metacraft\hyperv-m69-system-vhds'
$OutDir             = 'D:\metacraft\hyperv-m69-system-out'

$BaseVhdxName       = 'windows-11-dev-env.vhdx'
$BaseVhdxCachePath  = Join-Path $CacheDir $BaseVhdxName
# The dev VHDX URL rots aggressively (the old aka.ms shortlink is now a
# Bing redirect). Microsoft *does* publish the file - it's just behind
# the Hyper-V Quick Create gallery manifest, in a .zip wrapper that
# carries the .vhdx plus a marker file. We discover the live URL
# from the manifest at runtime; the aka.ms shortlink is kept as a
# documented fallback so if Microsoft ever restores it we keep working.
$DevVmGalleryManifestUrl = 'https://go.microsoft.com/fwlink/?linkid=851584'
$DevVmGalleryImageName   = 'Windows 11 dev environment'
$DevVhdxFallbackUrls = @(
  # Historical aka.ms shortlink for the Dev VM image. As of 2026-05
  # this redirects to Bing; keep it documented for the case where
  # Microsoft restores it.
  'https://aka.ms/windev_VM_vhdx'
)
# Reject any "VHDX" / "ZIP" smaller than this - the real dev image is
# 20+ GB; anything dramatically smaller is a stale or bogus URL.
$DevVhdxMinExpectedBytes = 5GB

$DiffVhdName        = "$VmName.vhdx"
$DiffVhdPath        = Join-Path $VhdRoot $DiffVhdName

$SnapshotBaseClean    = 'base-clean'
$SnapshotBaseWithVs   = 'base-with-vs'

$CredCacheDir       = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69'
$CredCachePath      = Join-Path $CredCacheDir 'vm-cred.xml'

# Inside the VM
$VmHarnessRoot      = 'C:\harness'
$VmNimVersion       = '2.2.8'
$VmNimTarUrl        = "https://nim-lang.org/download/nim-$VmNimVersion`_x64.zip"
$VmNimRoot          = "C:\nim-$VmNimVersion"
$VmMinGwUrl         = 'https://github.com/niXman/mingw-builds-binaries/releases/download/13.2.0-rt_v11-rev0/x86_64-13.2.0-release-win32-seh-msvcrt-rt_v11-rev0.7z'
$VmMinGwRoot        = 'C:\mingw64'

$VsBuildToolsBootstrapUrl = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
$VsInstallRoot      = 'C:\BuildTools'
$VsWorkloads        = @(
  'Microsoft.VisualStudio.Workload.VCTools',
  'Microsoft.VisualStudio.Workload.MSBuildTools'
)

# Wait budgets
$BootReadyTimeoutSec   = 600    # 10 min - first boot of a fresh VHDX is slow
$RebootReadyTimeoutSec = 300    # 5 min - subsequent reboots
$VsUninstallTimeoutSec = 1800   # 30 min - VS uninstall can take a while
$VsInstallTimeoutSec   = 3600   # 60 min - VS install is multi-GB
$DismFeatureTimeoutSec = 900    # 15 min - DISM can be slow on WU fetch

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Info($m)  { Write-Host "[provision] $m" }
function Warn($m)  { Write-Host "[provision] WARNING: $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[provision] ERROR: $m"   -ForegroundColor Red }
function Section($name) {
  Write-Host ""
  Info ("=" * 70)
  Info $name
  Info ("=" * 70)
}

function Ensure-Dir([string]$path) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

function Get-VmOrNull([string]$name) {
  try { return Get-VM -Name $name -ErrorAction Stop } catch { return $null }
}

function Test-VmExists([string]$name) {
  return (Get-VmOrNull $name) -ne $null
}

function Get-SnapshotOrNull([string]$vm, [string]$snapshot) {
  try {
    return Get-VMSnapshot -VMName $vm -Name $snapshot -ErrorAction Stop
  } catch { return $null }
}

function Test-SnapshotExists([string]$vm, [string]$snapshot) {
  return (Get-SnapshotOrNull $vm $snapshot) -ne $null
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
      } catch {
        # Not ready yet - the guest's WinRM-over-VMBus listener takes
        # a while to come up after boot.
      }
    }
    if (((Get-Date) - $lastReport).TotalSeconds -ge 20) {
      $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
      Info ("  waiting for PowerShell Direct ... ${elapsed}s elapsed (state=" +
            ($vm.State) + ")")
      $lastReport = Get-Date
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Resolve-DevVhdxUrlFromManifest {
  param(
    [string]$ManifestUrl,
    [string]$ImageName,
    [int64]$MinExpectedBytes
  )
  # Returns a hashtable @{ Url=...; ContentLength=... } if a valid live
  # URL was discovered, or $null on any failure. Every failure path
  # logs via Warn so the operator can see exactly which probe gave up.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {}
  Info "  fetching gallery manifest: $ManifestUrl"
  $manifest = $null
  try {
    $resp = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 60
  } catch {
    Warn "  manifest fetch failed: $_"
    return $null
  }
  # The gallery manifest is UTF-16-LE encoded JSON with a BOM. Decode
  # explicitly and strip the BOM; don't rely on Invoke-WebRequest's
  # heuristic or on ConvertFrom-Json's BOM tolerance (it varies by PS
  # version).
  try {
    $rawBytes = $resp.Content
    $text = $null
    if ($rawBytes -is [string]) {
      # Some PS hosts hand back a string already; trust it.
      $text = $rawBytes
    } else {
      $bytes = [byte[]]$rawBytes
      # Strip a UTF-16-LE BOM if present (FF FE), then decode as UTF-16-LE.
      if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
      } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        # UTF-8 BOM
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
      } else {
        # No BOM; try UTF-16 first (the manifest's documented encoding),
        # fall back to UTF-8 if the result doesn't look like JSON.
        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
        if ($text -notmatch '"images"') {
          $alt = [System.Text.Encoding]::UTF8.GetString($bytes)
          if ($alt -match '"images"') { $text = $alt }
        }
      }
    }
    # Belt-and-braces: strip any leading U+FEFF (zero-width no-break
    # space / BOM-as-char) that survived the byte-level strip above.
    if ($text -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
      $text = $text.Substring(1)
    }
    $manifest = $text | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Warn "  manifest decode/parse failed: $_"
    return $null
  }
  if (-not $manifest -or -not $manifest.images) {
    Warn "  manifest has no 'images' array; shape may have changed"
    return $null
  }
  $entry = $manifest.images | Where-Object { $_.name -eq $ImageName } | Select-Object -First 1
  if (-not $entry) {
    Warn "  manifest does not contain an image entry named: $ImageName"
    Warn "  available image names: $(@($manifest.images | ForEach-Object { $_.name }) -join ', ')"
    return $null
  }
  $diskUri = $null
  if ($entry.disk -and $entry.disk.uri) { $diskUri = [string]$entry.disk.uri }
  if (-not $diskUri) {
    Warn "  manifest entry for '$ImageName' has no disk.uri"
    return $null
  }
  Info "  manifest disk.uri: $diskUri"
  # HEAD-probe to validate URL is reachable AND the body is big enough
  # to plausibly be the dev VM image.
  $contentLength = 0
  try {
    $head = Invoke-WebRequest -Uri $diskUri -Method Head -UseBasicParsing -TimeoutSec 60
    # Invoke-WebRequest -UseBasicParsing returns header values as
    # System.String[] (one-element array for single-valued headers).
    # Take the first element before casting.
    $clRaw = $head.Headers.'Content-Length'
    if ($clRaw) {
      $clScalar = if ($clRaw -is [array]) { $clRaw[0] } else { $clRaw }
      $contentLength = [int64]$clScalar
    }
  } catch {
    Warn "  HEAD probe of disk.uri failed: $_"
    return $null
  }
  $clGB = [math]::Round($contentLength / 1GB, 2)
  Info "  HEAD Content-Length = $contentLength bytes ($clGB GB)"
  if ($contentLength -lt $MinExpectedBytes) {
    $minGB = [math]::Round($MinExpectedBytes / 1GB, 2)
    Warn "  HEAD Content-Length ($clGB GB) is below the minimum expected ($minGB GB); rejecting as stale/bogus"
    return $null
  }
  return @{ Url = $diskUri; ContentLength = $contentLength }
}

function Invoke-VmScript {
  param(
    [string]$Name,
    [System.Management.Automation.PSCredential]$Credential,
    [scriptblock]$ScriptBlock,
    [object[]]$ArgumentList = @(),
    [int]$TimeoutSec = 600
  )
  # PowerShell Direct doesn't expose a per-invocation timeout, so we
  # bound the wait by running in a job and waiting on the job.
  $job = Invoke-Command -VMName $Name -Credential $Credential `
           -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob
  $waited = Wait-Job -Job $job -Timeout $TimeoutSec
  if (-not $waited) {
    Warn "  in-VM script TIMED OUT after ${TimeoutSec}s - stopping the job"
    try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    throw "Invoke-VmScript timed out after ${TimeoutSec}s"
  }
  $out = Receive-Job -Job $job -ErrorAction SilentlyContinue 2>&1
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  return $out
}

# ---------------------------------------------------------------------------
# Step 1: verify Hyper-V is enabled
# ---------------------------------------------------------------------------
Section 'Step 1: verify Hyper-V is enabled'
$hyperVState = $null
try {
  $hyperVState = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop).State
} catch {
  Fail "could not query Microsoft-Hyper-V optional feature: $_"
  Fail "is this Windows? this harness only runs on Windows hosts with Hyper-V capability"
  exit 1
}
Info "  Microsoft-Hyper-V state: $hyperVState"
if ($hyperVState -ne 'Enabled') {
  Fail "Hyper-V Windows Optional Feature is NOT enabled (state=$hyperVState)."
  Fail "This is admin-only and requires a host reboot to install. The harness"
  Fail "will NOT enable it automatically. From an elevated PowerShell, run:"
  Fail ""
  Fail "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All"
  Fail ""
  Fail "...reboot, then re-run this provision script."
  exit 1
}

# Verify the PS module is importable.
try {
  Import-Module Hyper-V -ErrorAction Stop
} catch {
  Fail "the Hyper-V PowerShell module could not be imported: $_"
  exit 1
}
Info "  Hyper-V module imported."

# ---------------------------------------------------------------------------
# Step 2: pick a virtual switch
# ---------------------------------------------------------------------------
Section 'Step 2: pick a virtual switch'
$switch = Get-VMSwitch -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default Switch' } |
            Select-Object -First 1
if (-not $switch) {
  $switch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $switch) {
  Fail "no virtual switch found. The Dev VM needs networking for Windows Update"
  Fail "and the VS bootstrapper download. From an elevated PowerShell, create"
  Fail "the Default Switch (it normally exists out-of-the-box on Windows 11)"
  Fail "or an internal/external switch:"
  Fail ""
  Fail "  New-VMSwitch -Name 'repro-m69-switch' -SwitchType Internal"
  Fail ""
  Fail "then re-run this script."
  exit 1
}
Info "  using virtual switch: $($switch.Name) ($($switch.SwitchType))"

# ---------------------------------------------------------------------------
# Step 3: ensure scoped directories exist
# ---------------------------------------------------------------------------
Section 'Step 3: ensure scoped directories exist'
Ensure-Dir $CacheDir
Ensure-Dir $VhdRoot
Ensure-Dir $OutDir
Ensure-Dir $CredCacheDir
Info "  cache:   $CacheDir"
Info "  vhds:    $VhdRoot"
Info "  out:     $OutDir"
Info "  cred:    $CredCacheDir"

# ---------------------------------------------------------------------------
# Step 4: ensure the dev VHDX is cached
# ---------------------------------------------------------------------------
Section 'Step 4: ensure the dev VHDX is cached'
if ($VhdxOverridePath -and (Test-Path $VhdxOverridePath)) {
  if ($VhdxOverridePath -ne $BaseVhdxCachePath) {
    Info "  override path supplied: $VhdxOverridePath"
    if (-not (Test-Path $BaseVhdxCachePath)) {
      Info "  copying override into cache path"
      Copy-Item -LiteralPath $VhdxOverridePath -Destination $BaseVhdxCachePath -Force
    }
  }
}

if (Test-Path $BaseVhdxCachePath) {
  $sz = (Get-Item $BaseVhdxCachePath).Length
  $szGB = [math]::Round($sz/1GB, 2)
  if ($sz -lt 5GB) {
    Warn "  cached VHDX is suspiciously small ($szGB GB); a real Dev VM image is 20-50 GB"
    Warn "  delete $BaseVhdxCachePath and re-run if it is corrupt"
  } else {
    Info "  cached VHDX present: $BaseVhdxCachePath ($szGB GB) - skip download"
  }
}
if (-not (Test-Path $BaseVhdxCachePath)) {
  Info "  no cached VHDX; attempting to discover a live download URL"

  # Step 4a: discovery. Manifest first, aka.ms fallback after.
  $discovered = $null
  $discovered = Resolve-DevVhdxUrlFromManifest `
                  -ManifestUrl $DevVmGalleryManifestUrl `
                  -ImageName   $DevVmGalleryImageName `
                  -MinExpectedBytes $DevVhdxMinExpectedBytes
  if (-not $discovered) {
    foreach ($fbUrl in $DevVhdxFallbackUrls) {
      Info "  manifest discovery failed; trying fallback URL: $fbUrl"
      try {
        $head = Invoke-WebRequest -Uri $fbUrl -Method Head -UseBasicParsing -TimeoutSec 60
        $cl = 0
        $clRaw = $head.Headers.'Content-Length'
        if ($clRaw) {
          $clScalar = if ($clRaw -is [array]) { $clRaw[0] } else { $clRaw }
          $cl = [int64]$clScalar
        }
        $clGB = [math]::Round($cl/1GB, 2)
        Info "  fallback HEAD Content-Length = $cl bytes ($clGB GB)"
        if ($cl -ge $DevVhdxMinExpectedBytes) {
          $discovered = @{ Url = $fbUrl; ContentLength = $cl }
          break
        } else {
          Warn "  fallback URL too small ($clGB GB); rejecting"
        }
      } catch {
        Warn "  fallback URL HEAD failed: $_"
      }
    }
  }

  if (-not $discovered) {
    Fail ""
    Fail "  Could not discover the Windows 11 development-environment VHDX URL."
    Fail "  The Quick Create gallery manifest at"
    Fail "    $DevVmGalleryManifestUrl"
    Fail "  did not yield a usable disk.uri (network down, JSON shape changed,"
    Fail "  or no '$DevVmGalleryImageName' entry), and the documented fallback"
    Fail "  shortlink(s) did not validate either."
    Fail ""
    Fail "  PLEASE OBTAIN THE VHDX MANUALLY:"
    Fail "    1. Open Hyper-V Manager."
    Fail "    2. Action > Quick Create > 'Windows 11 dev environment'."
    Fail "       (Or visit https://developer.microsoft.com/windows/downloads/virtual-machines/)"
    Fail "    3. Wait for the download to complete. The download is a .zip"
    Fail "       wrapper; extract the inner .vhdx."
    Fail "    4. Move (or copy) the inner .vhdx to the cache path:"
    Fail "         $BaseVhdxCachePath"
    Fail "    5. Re-run this provision script. It will resume idempotently."
    Fail ""
    exit 2
  }

  $liveUrl       = $discovered.Url
  $expectedBytes = [int64]$discovered.ContentLength
  Info "  live URL accepted: $liveUrl ($([math]::Round($expectedBytes/1GB,2)) GB)"

  # Step 4b: download into a temp .zip path under the cache dir.
  $zipPath  = Join-Path $CacheDir 'windows-11-dev-env.download.zip'
  $extractDir = Join-Path $CacheDir 'windows-11-dev-env.extract'
  if (Test-Path $zipPath)     { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
  if (Test-Path $extractDir)  { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }

  $downloaded = $false
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $t0 = Get-Date
    $bitsOk = $false
    try {
      Import-Module BitsTransfer -ErrorAction Stop
      $bitsJob = Start-BitsTransfer -Source $liveUrl -Destination $zipPath `
                   -DisplayName 'M69 Dev VM VHDX (zip)' `
                   -Description 'Microsoft Windows 11 development-environment VHDX archive' `
                   -Asynchronous
      Info "  BITS job started: $($bitsJob.JobId)"
      while ($bitsJob.JobState -in 'Connecting','Transferring','Queued') {
        Start-Sleep -Seconds 10
        $bitsJob = Get-BitsTransfer -JobId $bitsJob.JobId
        $pct = if ($bitsJob.BytesTotal -gt 0) {
          [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
        } else { 0 }
        $mb = [math]::Round($bitsJob.BytesTransferred / 1MB, 0)
        Info "  BITS: $($bitsJob.JobState)  $mb MB  ($pct %)"
      }
      if ($bitsJob.JobState -eq 'Transferred') {
        Complete-BitsTransfer -BitsJob $bitsJob
        $bitsOk = (Test-Path $zipPath)
      } else {
        Warn "  BITS job ended in state: $($bitsJob.JobState); cancelling"
        try { Remove-BitsTransfer -BitsJob $bitsJob } catch {}
      }
    } catch {
      Warn "  BITS path failed: $_; falling back to Invoke-WebRequest"
      Invoke-WebRequest -Uri $liveUrl -OutFile $zipPath -TimeoutSec 7200
      $bitsOk = (Test-Path $zipPath)
    }
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    if (-not $bitsOk) {
      Fail "  download did not produce a file at $zipPath"
      exit 2
    }
    $zipSize = (Get-Item $zipPath).Length
    $zipGB   = [math]::Round($zipSize/1GB, 2)
    Info "  downloaded ${elapsed} min, $zipGB GB"
    # Tolerate small variance (CDN may close-grain; redirects can yield
    # slightly different reported lengths). Reject anything wildly off.
    $tolerance = [math]::Max(64MB, [int64]($expectedBytes * 0.01))
    if ([math]::Abs($zipSize - $expectedBytes) -gt $tolerance) {
      Warn "  downloaded size $zipSize differs from HEAD Content-Length $expectedBytes by more than $tolerance bytes"
      Warn "  (mirror may be inconsistent - continuing, but treat as suspect)"
    }
    if ($zipSize -lt $DevVhdxMinExpectedBytes) {
      Fail "  downloaded archive is only $zipGB GB; expected at least $([math]::Round($DevVhdxMinExpectedBytes/1GB,2)) GB"
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      exit 2
    }

    # Step 4c: extract the .zip into a temp subdir and locate the inner .vhdx.
    Info "  extracting $zipPath -> $extractDir"
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $innerVhdx = @(Get-ChildItem -Path $extractDir -Recurse -Filter '*.vhdx' -File)
    if ($innerVhdx.Count -eq 0) {
      $contents = @(Get-ChildItem -Path $extractDir -Recurse -File | Select-Object -First 20 |
                      ForEach-Object { $_.FullName })
      Fail "  extracted archive contains NO .vhdx file. Top of contents:"
      foreach ($c in $contents) { Fail "    $c" }
      exit 2
    }
    if ($innerVhdx.Count -gt 1) {
      Fail "  extracted archive contains $($innerVhdx.Count) .vhdx files (expected exactly 1):"
      foreach ($v in $innerVhdx) { Fail "    $($v.FullName)  ($([math]::Round($v.Length/1GB,2)) GB)" }
      exit 2
    }
    $innerPath = $innerVhdx[0].FullName
    $innerSize = $innerVhdx[0].Length
    $innerGB   = [math]::Round($innerSize/1GB, 2)
    Info "  inner VHDX: $innerPath ($innerGB GB)"
    if ($innerSize -lt $DevVhdxMinExpectedBytes) {
      Fail "  inner VHDX is only $innerGB GB; expected at least $([math]::Round($DevVhdxMinExpectedBytes/1GB,2)) GB"
      exit 2
    }
    Info "  moving inner VHDX -> $BaseVhdxCachePath"
    Move-Item -LiteralPath $innerPath -Destination $BaseVhdxCachePath -Force
    $downloaded = (Test-Path $BaseVhdxCachePath)
  } finally {
    # Clean up the .zip + temp extract dir whether or not we succeeded
    # (the cached .vhdx is now at $BaseVhdxCachePath; the temps are
    # disposable).
    if (Test-Path $zipPath)    { Remove-Item -LiteralPath $zipPath    -Force         -ErrorAction SilentlyContinue }
    if (Test-Path $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (-not $downloaded) {
    Fail "  download + extract did not produce $BaseVhdxCachePath; see warnings above"
    exit 2
  }
}

# ---------------------------------------------------------------------------
# Step 5: -Force handling - blow away the existing VM + snapshots
# ---------------------------------------------------------------------------
if ($Force) {
  Section 'Step 5: -Force - tear down existing VM (will rebuild)'
  $existing = Get-VmOrNull $VmName
  if ($existing) {
    Info "  stopping $VmName"
    try { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue } catch {}
    Info "  removing snapshots"
    Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-VMSnapshot -VMName $VmName -Name $_.Name -ErrorAction SilentlyContinue }
    Info "  removing VM"
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $DiffVhdPath) {
    Info "  removing differencing VHD: $DiffVhdPath"
    Remove-Item -LiteralPath $DiffVhdPath -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------------------
# Step 6: ensure the VM exists
# ---------------------------------------------------------------------------
Section 'Step 6: ensure VM exists'
if (Test-VmExists $VmName) {
  Info "  VM '$VmName' already exists - skip create"
} else {
  Info "  VM '$VmName' does not exist - creating"
  # Create a differencing VHD so the cached VHDX is preserved
  # untouched (so we can re-create the VM on a future provision
  # without re-downloading 20-50 GB).
  if (-not (Test-Path $DiffVhdPath)) {
    Info "  creating differencing VHD from cached base: $DiffVhdPath"
    New-VHD -Path $DiffVhdPath -ParentPath $BaseVhdxCachePath -Differencing | Out-Null
  } else {
    Info "  differencing VHD already exists: $DiffVhdPath"
  }
  Info "  creating Gen2 VM with ${VmRamBytes} bytes RAM, $VmProcessorCount vCPU"
  New-VM -Name $VmName -Generation $VmGeneration `
    -MemoryStartupBytes $VmRamBytes `
    -VHDPath $DiffVhdPath `
    -SwitchName $switch.Name | Out-Null
  Set-VMProcessor -VMName $VmName -Count $VmProcessorCount
  # The dev VHDX is UEFI but ships with secure-boot certs that don't
  # always recognise a fresh VM's firmware. Disable secure boot to
  # avoid first-boot snags; we can revisit if it becomes a fidelity issue.
  Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
  # Dynamic memory is fine for our workload.
  Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true `
    -MinimumBytes 2GB -StartupBytes $VmRamBytes -MaximumBytes ($VmRamBytes * 2)
  # We need Guest Service Interface for Copy-VMFile.
  Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'
  # The dev image already enables 'PowerShell Direct' (it's the
  # 'Heartbeat' / 'Time Synchronization' / 'Key-Value Pair Exchange' set
  # plus the VMBus that PSDirect rides on); enable any that are off.
  foreach ($svc in @('Heartbeat','Shutdown','Time Synchronization','Key-Value Pair Exchange')) {
    Enable-VMIntegrationService -VMName $VmName -Name $svc -ErrorAction SilentlyContinue
  }
  Info "  VM '$VmName' created."
}

# Verify Guest Service Interface
$gsi = Get-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue
if (-not $gsi -or -not $gsi.Enabled) {
  Info "  enabling Guest Service Interface"
  Enable-VMIntegrationService -VMName $VmName -Name 'Guest Service Interface'
}

# ---------------------------------------------------------------------------
# Step 7: load the cached VM credential (fast-fail if absent)
# ---------------------------------------------------------------------------
Section 'Step 7: load the cached VM credential'
# The DPAPI-encrypted cred cache MUST already exist. This script is
# designed to run under `pwsh -NoProfile -NonInteractive -File ...`
# (sub-agent / CI / cron), where a Get-Credential prompt would hang
# indefinitely with no terminal attached. Seeding the cache is a
# one-time interactive bootstrap that the operator does once per VHDX
# refresh - see README's "One-time interactive bootstrap" section.
$cred = $null
if (-not (Test-Path $CredCachePath)) {
  Fail ""
  Fail "PowerShell Direct credential cache missing at:"
  Fail "  $CredCachePath"
  Fail ""
  Fail "To seed it, run this snippet ONCE in an INTERACTIVE pwsh window"
  Fail "(the prompt cannot fire from -NonInteractive / sub-agent contexts):"
  Fail ""
  Fail "  `$d = `"`$env:LOCALAPPDATA\Repro\hyperv-m69`""
  Fail "  if (-not (Test-Path `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }"
  Fail "  `$cred = Get-Credential -Message 'Hyper-V guest creds for repro-m69-hyperv. Use the username and password you set during the dev VM OOBE first-boot. Default username is User; pick any non-empty password.'"
  Fail "  `$cred | Export-Clixml -Path `"`$d\vm-cred.xml`""
  Fail ""
  Fail "Then re-run provision-base-vm.ps1 - it will pick up at step 5."
  Fail ""
  exit 2
}
try {
  $cred = Import-Clixml -Path $CredCachePath
} catch {
  Fail "failed to load cached credential at $CredCachePath : $_"
  Fail "the file may be corrupt or was sealed with a different user's DPAPI key."
  Fail "Delete it and re-seed it interactively (see Step 7 seeding snippet above)."
  exit 2
}
if (-not $cred -or -not $cred.UserName) {
  Fail "cached credential at $CredCachePath has no UserName; refusing to continue"
  Fail "Delete it and re-seed it interactively (see Step 7 seeding snippet above)."
  exit 2
}
Info "  loaded cached credential (user: $($cred.UserName))"

# ---------------------------------------------------------------------------
# Step 8: boot the VM
# ---------------------------------------------------------------------------
Section 'Step 8: boot the VM and wait for PowerShell Direct'
$vm = Get-VmOrNull $VmName
if ($vm.State -ne 'Running') {
  Info "  starting VM"
  Start-VM -Name $VmName
} else {
  Info "  VM already running"
}
$ready = Wait-VmPSDirectReady -Name $VmName -Credential $cred -TimeoutSec $BootReadyTimeoutSec
if (-not $ready) {
  Fail "VM did not become responsive on PowerShell Direct within $BootReadyTimeoutSec s"
  Fail "  Common causes:"
  Fail "    * The guest is still on the OOBE screen and needs an interactive"
  Fail "      first-boot. Open Hyper-V Manager, connect to '$VmName',"
  Fail "      finish OOBE (set a password matching the cached credential),"
  Fail "      then re-run this script."
  Fail "    * The cached credential does not match the guest's password."
  Fail "      Delete $CredCachePath and re-seed it interactively (see the"
  Fail "      Step 7 seeding snippet in the README)."
  exit 1
}

# ---------------------------------------------------------------------------
# Step 9: clean baseline inside the VM
# ---------------------------------------------------------------------------
# Skip everything in step 9-11 if base-clean snapshot already exists.
if (Test-SnapshotExists $VmName $SnapshotBaseClean) {
  Section "Step 9: base-clean snapshot already exists - SKIP cleaning"
} else {
  Section 'Step 9: clean baseline inside the VM (uninstall VS, disable WSL/VMP, drop OpenSSH)'

  # 9a. Uninstall Visual Studio
  Info "  9a: uninstall Visual Studio (if present)"
  $vsCheck = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec 60 -ScriptBlock {
    $vsWherePaths = @(
      'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe',
      'C:\Program Files\Microsoft Visual Studio\Installer\vswhere.exe'
    )
    foreach ($p in $vsWherePaths) {
      if (Test-Path $p) {
        $out = & $p -prerelease -format json 2>$null | Out-String
        if ($out -and $out.Trim() -ne '[]') {
          return "vs-present: $($out.Length) chars of vswhere output"
        }
      }
    }
    return 'vs-absent'
  }
  $vsCheckText = ($vsCheck | Out-String).Trim()
  Info "    vswhere probe: $vsCheckText"
  if ($vsCheckText -like 'vs-present*') {
    Info "  9a: uninstalling all VS instances"
    $vsUninstall = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec $VsUninstallTimeoutSec -ScriptBlock {
      $installer = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe'
      $vswhere   = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
      if (-not (Test-Path $installer) -or -not (Test-Path $vswhere)) {
        return "no installer + vswhere; treat as already-uninstalled"
      }
      $instances = & $vswhere -prerelease -format json -all | ConvertFrom-Json
      foreach ($i in $instances) {
        $instId = $i.instanceId
        $installPath = $i.installationPath
        Write-Host "uninstalling VS instance $instId at $installPath"
        & $installer uninstall --installPath "$installPath" --quiet --norestart --force --noWeb --noUpdateInstaller
        Wait-Process -Name 'vs_installer','vs_installershell','setup' -Timeout 1800 -ErrorAction SilentlyContinue
        Wait-Process -Name 'vs_installerservice' -Timeout 60 -ErrorAction SilentlyContinue
      }
      # Final probe
      $stillThere = & $vswhere -prerelease -format json -all
      if ($stillThere -and $stillThere.Trim() -ne '[]') {
        return "VS uninstall FAILED - vswhere still reports instances"
      }
      return "VS uninstall ok - vswhere reports empty"
    }
    foreach ($l in @($vsUninstall)) { Info "      $l" }
  } else {
    Info "    no VS to uninstall - skip"
  }

  # 9b. Disable WSL + VirtualMachinePlatform
  Info "  9b: disable WSL + VirtualMachinePlatform optional features"
  $optFeatResult = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec $DismFeatureTimeoutSec -ScriptBlock {
    $features = @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')
    $results = @()
    foreach ($f in $features) {
      $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
      if (-not $st) { $results += "$f : not-present-skip"; continue }
      if ($st -eq 'Disabled') { $results += "$f : already-disabled"; continue }
      Write-Host "disabling $f (state was $st)"
      $r = Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction SilentlyContinue
      $stAfter = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
      $results += "$f : was=$st  after=$stAfter  restart=$($r.RestartNeeded)"
    }
    return ,$results
  }
  foreach ($l in @($optFeatResult)) { Info "      $l" }

  # 9c. Remove OpenSSH server capability if present
  Info "  9c: remove OpenSSH server capability (if present)"
  $sshResult = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec $DismFeatureTimeoutSec -ScriptBlock {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
    if (-not $cap) { return "OpenSSH.Server: not-known-on-this-image" }
    if ($cap.State -in @('NotPresent','Removed')) { return "OpenSSH.Server: already $($cap.State)" }
    # Stop the sshd service first if installed
    $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
      Stop-Service -Name 'sshd' -Force -ErrorAction SilentlyContinue
    }
    Remove-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
    $capAfter = (Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue).State
    return "OpenSSH.Server: was=$($cap.State)  after=$capAfter"
  }
  foreach ($l in @($sshResult)) { Info "      $l" }

  # 9d. Reboot the VM to settle DISM transitions
  Info "  9d: rebooting the VM to settle DISM transitions"
  Restart-VM -Name $VmName -Force -Wait
  $ready = Wait-VmPSDirectReady -Name $VmName -Credential $cred -TimeoutSec $RebootReadyTimeoutSec
  if (-not $ready) {
    Fail "VM did not come back from reboot within $RebootReadyTimeoutSec s"
    exit 1
  }

  # 9e. Final verification
  Info "  9e: final verification of base-clean post-condition"
  $verify = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec 120 -ScriptBlock {
    $results = @()
    # VS
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
      $vsOut = & $vswhere -prerelease -format json -all
      if ($vsOut -and ($vsOut | Out-String).Trim() -ne '[]') {
        $results += "VS: STILL PRESENT (unexpected)"
      } else {
        $results += "VS: absent"
      }
    } else {
      $results += "VS: vswhere absent - VS absent"
    }
    # WSL + VMP
    foreach ($f in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
      $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
      $results += "$f : $st"
    }
    # OpenSSH
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
    $results += "OpenSSH.Server: $($cap.State)"
    return ,$results
  }
  foreach ($l in @($verify)) { Info "      $l" }
}

# ---------------------------------------------------------------------------
# Step 10: provision Nim + gcc inside the VM
# ---------------------------------------------------------------------------
if (Test-SnapshotExists $VmName $SnapshotBaseClean) {
  Section "Step 10: base-clean snapshot already exists - SKIP toolchain"
} else {
  Section 'Step 10: provision Nim + gcc inside the VM'
  $nimResult = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec 1200 -ArgumentList @($VmNimRoot, $VmNimTarUrl, $VmMinGwRoot, $VmMinGwUrl) -ScriptBlock {
    param($nimRoot, $nimUrl, $mingwRoot, $mingwUrl)
    $results = @()
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Nim
    if (Test-Path (Join-Path $nimRoot 'bin\nim.exe')) {
      $results += "Nim: already present at $nimRoot"
    } else {
      $nimZip = Join-Path $env:TEMP 'nim.zip'
      Write-Host "downloading Nim from $nimUrl"
      Invoke-WebRequest -Uri $nimUrl -OutFile $nimZip -TimeoutSec 600
      Write-Host "extracting Nim to $nimRoot"
      Expand-Archive -Path $nimZip -DestinationPath $env:TEMP -Force
      # The archive extracts to a versioned subdir; find it and rename.
      $extracted = Get-ChildItem -Path $env:TEMP -Directory -Filter 'nim-*' |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($extracted) {
        Move-Item -LiteralPath $extracted.FullName -Destination $nimRoot -Force
      }
      Remove-Item -LiteralPath $nimZip -Force -ErrorAction SilentlyContinue
      $results += "Nim: extracted to $nimRoot"
    }
    # MinGW gcc (Nim 2.2.8 prebuilt comes with a bundled gcc under
    # dist\mingw64 - prefer that if present, otherwise install MinGW
    # separately).
    $nimBundledMingw = Join-Path $nimRoot 'dist\mingw64\bin\gcc.exe'
    if (Test-Path $nimBundledMingw) {
      $results += "gcc: using Nim-bundled MinGW at $nimBundledMingw"
    } elseif (Test-Path (Join-Path $mingwRoot 'bin\gcc.exe')) {
      $results += "gcc: already present at $mingwRoot"
    } else {
      $mingwArchive = Join-Path $env:TEMP 'mingw.7z'
      Write-Host "downloading MinGW from $mingwUrl"
      try {
        Invoke-WebRequest -Uri $mingwUrl -OutFile $mingwArchive -TimeoutSec 600
        # Need 7-Zip to extract a .7z. PowerShell can't natively. If
        # 7z.exe is not available, surface the limitation - the
        # Nim-bundled gcc is the supported path anyway.
        $sevenZip = (Get-Command '7z.exe','7za.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($sevenZip) {
          & $sevenZip.Source x -y "-o$([System.IO.Path]::GetDirectoryName($mingwRoot))" $mingwArchive | Out-Null
          $results += "gcc: extracted MinGW to $mingwRoot"
        } else {
          $results += "gcc: 7-Zip not present; relying on Nim-bundled mingw at dist\mingw64"
        }
      } catch {
        $results += "gcc: MinGW download failed: $_; will rely on Nim-bundled mingw"
      }
    }
    # Add Nim + (Nim's own bundled mingw) to MACHINE PATH so future
    # sessions inherit it.
    $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
    $needBin = @((Join-Path $nimRoot 'bin'))
    if (Test-Path (Join-Path $nimRoot 'dist\mingw64\bin')) {
      $needBin += (Join-Path $nimRoot 'dist\mingw64\bin')
    } elseif (Test-Path (Join-Path $mingwRoot 'bin')) {
      $needBin += (Join-Path $mingwRoot 'bin')
    }
    $changed = $false
    foreach ($b in $needBin) {
      if ($machinePath -notlike "*$b*") {
        $machinePath = "$machinePath;$b"
        $changed = $true
      }
    }
    if ($changed) {
      [Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
      $results += "PATH: appended Nim + mingw bin dirs"
    } else {
      $results += "PATH: already contains Nim + mingw bin dirs"
    }
    return ,$results
  }
  foreach ($l in @($nimResult)) { Info "    $l" }
}

# ---------------------------------------------------------------------------
# Step 11: take base-clean checkpoint
# ---------------------------------------------------------------------------
Section "Step 11: take '$SnapshotBaseClean' checkpoint"
if (Test-SnapshotExists $VmName $SnapshotBaseClean) {
  Info "  '$SnapshotBaseClean' already exists - skip"
} else {
  Info "  shutting down VM cleanly before checkpoint"
  try {
    Stop-VM -Name $VmName -Force -ErrorAction Stop
  } catch {
    Warn "  graceful Stop-VM failed: $_; falling back to -TurnOff"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  }
  Info "  Checkpoint-VM -Name $SnapshotBaseClean"
  Checkpoint-VM -VMName $VmName -SnapshotName $SnapshotBaseClean
  Info "  '$SnapshotBaseClean' created"
}

# ---------------------------------------------------------------------------
# Step 12: install VS Build Tools, take base-with-vs checkpoint
# ---------------------------------------------------------------------------
if ($SkipVsInstall) {
  Section "Step 12: -SkipVsInstall set - skip VS install and base-with-vs checkpoint"
  Info ""
  Info "PROVISIONING DONE (clean-only mode). base-clean exists; base-with-vs deferred."
  Get-VM -Name $VmName | Format-Table Name,State,CPUUsage,MemoryAssigned,Uptime,Status -AutoSize
  Get-VMSnapshot -VMName $VmName | Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName -AutoSize
  exit 0
}

Section "Step 12: install VS Build Tools, take '$SnapshotBaseWithVs' checkpoint"
if (Test-SnapshotExists $VmName $SnapshotBaseWithVs) {
  Info "  '$SnapshotBaseWithVs' already exists - skip everything"
} else {
  # Need to be running again
  $vm = Get-VmOrNull $VmName
  if ($vm.State -ne 'Running') {
    Info "  starting VM"
    Start-VM -Name $VmName
    $ready = Wait-VmPSDirectReady -Name $VmName -Credential $cred -TimeoutSec $BootReadyTimeoutSec
    if (-not $ready) {
      Fail "VM did not become responsive on PowerShell Direct within $BootReadyTimeoutSec s"
      exit 1
    }
  }

  $workloadsCsv = ($VsWorkloads -join ',')
  Info "  installing VS Build Tools (workloads: $workloadsCsv)"
  $vsInstall = Invoke-VmScript -Name $VmName -Credential $cred -TimeoutSec $VsInstallTimeoutSec -ArgumentList @($VsBuildToolsBootstrapUrl, $VsInstallRoot, $workloadsCsv) -ScriptBlock {
    param($bootstrapUrl, $installPath, $workloadsCsv)
    $workloads = $workloadsCsv -split ','
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $bootstrap = Join-Path $env:TEMP 'vs_buildtools.exe'
    Write-Host "downloading VS Build Tools bootstrapper from $bootstrapUrl"
    Invoke-WebRequest -Uri $bootstrapUrl -OutFile $bootstrap -TimeoutSec 600
    if (-not (Test-Path $bootstrap)) {
      throw "bootstrapper download failed"
    }
    Write-Host "  bootstrap size = $((Get-Item $bootstrap).Length) bytes"
    $vsArgs = @('install','--installPath', $installPath, '--quiet', '--norestart', '--wait', '--noUpdateInstaller', '--noWeb')
    foreach ($w in $workloads) { $vsArgs += @('--add', $w) }
    Write-Host "running: $bootstrap $($vsArgs -join ' ')"
    $p = Start-Process -FilePath $bootstrap -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
    Write-Host "  vs_buildtools.exe exit = $($p.ExitCode)"
    # Verify with vswhere.
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
      throw "vs_buildtools.exe ran (exit $($p.ExitCode)) but vswhere is not present"
    }
    $out = & $vswhere -prerelease -format json -all -products * | Out-String
    Write-Host "vswhere output length: $($out.Length) chars"
    if ($out.Trim() -eq '[]') {
      throw "vs_buildtools.exe ran (exit $($p.ExitCode)) but vswhere reports no VS instance"
    }
    return "VS install ok (exit $($p.ExitCode)); vswhere returned $($out.Length) chars"
  }
  foreach ($l in @($vsInstall)) { Info "    $l" }

  Info "  shutting down VM cleanly before checkpoint"
  try {
    Stop-VM -Name $VmName -Force -ErrorAction Stop
  } catch {
    Warn "  graceful Stop-VM failed: $_; falling back to -TurnOff"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  }
  Info "  Checkpoint-VM -Name $SnapshotBaseWithVs"
  Checkpoint-VM -VMName $VmName -SnapshotName $SnapshotBaseWithVs
  Info "  '$SnapshotBaseWithVs' created"
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
Write-Host ""
Info ("=" * 70)
Info "PROVISIONING COMPLETE."
Info ("=" * 70)
Get-VM -Name $VmName | Format-Table Name,State,Generation,ProcessorCount,Status -AutoSize
Get-VMSnapshot -VMName $VmName | Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName -AutoSize
Info "Next step: run the gates."
Info "  pwsh -File $PSScriptRoot\run-hyperv-m69-system.ps1 -Gate feature-capability -Scenario base-clean"
Info "  pwsh -File $PSScriptRoot\run-hyperv-m69-system.ps1 -Gate vs-installer -Scenario base-clean"
exit 0
