<#
  run-hyperv-dotfiles-fullprofile.ps1 - HOST-SIDE runner for the full
  reprobuild profile validation harness. Stages the user's REAL
  ~/dotfiles repo into a fresh `base-clean` Windows 11 dev VM and
  runs `repro home apply` + `repro infra apply` end-to-end, then
  captures post-apply verification artifacts.

  Mirrors the lifecycle of run-hyperv-m69-system.ps1 (snapshot revert,
  Wait-VmPSDirectReady, Wait-VmGuestServiceInterfaceReady, Copy-VMFile,
  Invoke-Command -VMName, Stop-VM -TurnOff in a try/finally). Helper
  bodies are copied INLINE here rather than dot-sourced from the M69
  script because the M69 script declares mandatory parameters at the
  top, so sourcing it would prompt for $Gate before any function gets
  defined.

  Staging strategy:
    - Repro binaries (3 files): per-file Copy-VMFile -FileSource Host.
    - Dotfiles tree (~31 MB sans .git): zip on host, Copy-VMFile the
      single zip, Expand-Archive inside. Per-file Copy-VMFile across
      ~thousands of stow/ files would take 30+ min; zip + expand is
      sub-minute.

  HOST SAFETY:
    * Touches exactly ONE VM: 'repro-m69-hyperv'. No other VM on the
      host is queried, started, stopped, or altered.
    * Never Save-VMs. Always Stop-VM -TurnOff.
    * Reads dotfiles read-only from C:\Users\zahary\dotfiles; never
      writes back. The host-side zip is built in $OutDir, not in the
      dotfiles tree.
    * Output dir is cleared on entry; only $OutDir and the host-side
      zip cache under $OutDir\_stage are ever modified on the host.

  Usage:
    pwsh -File run-hyperv-dotfiles-fullprofile.ps1
                [-OutDir D:\metacraft\hyperv-dotfiles-fullprofile-out]
                [-DotfilesSrc C:\Users\zahary\dotfiles]
                [-TimeoutMinutes 60]
                [-KeepVmRunning]    # debug: skip Stop-VM in finally
#>

[CmdletBinding()]
param(
  [string]$OutDir = 'D:\metacraft\hyperv-dotfiles-fullprofile-out',
  [string]$DotfilesSrc = 'C:\Users\zahary\dotfiles',
  [int]$TimeoutMinutes = 60,
  [switch]$KeepVmRunning
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$VmName        = 'repro-m69-hyperv'
$Snapshot      = 'base-clean'
$CredCachePath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'

$ReproBinHost  = 'D:\metacraft\reprobuild\build\bin'
$ReproFiles    = @('repro.exe','sqlite3_64.dll','repro-launcher.exe')

# Reprobuild lib source tree needed for `nim c` to find `repro_profile`
# during apply (Phase F3 compile-then-apply path). The list MUST match
# `ProfileNimPathLibs` in libs/repro_profile_compile/src/repro_profile_compile/sources.nim
# -- both sides reference the same closure of libraries a profile can
# legitimately import.
$ReproRepoRoot = 'D:\metacraft\reprobuild'
$ReproProfileLibs = @(
  'repro_core', 'repro_platform', 'repro_diagnostics', 'blake3', 'xxh3',
  'gxhash', 'repro_hash', 'cbor', 'repro_domain_types',
  'repro_profile', 'repro_profile_intent'
)

# Guest paths
$VmHarness     = 'C:\harness'
$VmDotfilesDir = "$VmHarness\dotfiles"
$VmReproDir    = "$VmHarness\repro"
$VmReproRoot   = "$VmHarness\reprobuild-libs"   # set as $REPROBUILD_REPO_ROOT
$VmDotfilesZip = "$VmHarness\dotfiles.zip"
$VmReproLibsZip = "$VmHarness\reprobuild-libs.zip"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Info($m) { Write-Host "[run] $m" }
function Warn($m) { Write-Host "[run] WARNING: $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[run] ERROR: $m"   -ForegroundColor Red }

function Get-VmOrNull([string]$name) {
  try { return Get-VM -Name $name -ErrorAction Stop } catch { return $null }
}

# Body copied INLINE from run-hyperv-m69-system.ps1 (see file header).
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

# Body copied INLINE from run-hyperv-m69-system.ps1.
# Critical: PSDirect-ready does NOT imply Copy-VMFile-ready.
# Copy-VMFile rides on the Guest Service Interface integration service
# (not VMBus / PSDirect). On a freshly-reverted VM the GSI can stay in
# 'No Contact' several seconds after PSDirect is green, during which
# Copy-VMFile silently no-ops (reports success, copies nothing). Wait
# for GSI to report 'OK' before any Copy-VMFile call.
function Wait-VmGuestServiceInterfaceReady {
  param(
    [string]$Name,
    [int]$TimeoutSec
  )
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
Info "Hyper-V full-profile dotfiles harness"
Info ("=" * 70)
Info "vm:          $VmName"
Info "snapshot:    $Snapshot"
Info "dotfiles:    $DotfilesSrc"
Info "out dir:     $OutDir"
Info "timeout:     $TimeoutMinutes min"

# Hyper-V module
try {
  Import-Module Hyper-V -ErrorAction Stop
} catch {
  Fail "Hyper-V module not importable: $_"
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
  $snap = Get-VMSnapshot -VMName $VmName -Name $Snapshot -ErrorAction Stop
  Info "  snapshot '$Snapshot' present (created $($snap.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')))"
} catch {
  Fail "snapshot '$Snapshot' does not exist on VM '$VmName'. Run provision-base-vm.ps1 first."
  exit 1
}

# Credential
if (-not (Test-Path $CredCachePath)) {
  Fail "guest credential cache missing: $CredCachePath"
  Fail "Run provision-base-vm.ps1 first."
  exit 1
}
$cred = $null
try { $cred = Import-Clixml -Path $CredCachePath } catch {
  Fail "could not load credential from $CredCachePath : $_"
  exit 1
}

# Host-side dotfiles
if (-not (Test-Path -LiteralPath $DotfilesSrc -PathType Container)) {
  Fail "dotfiles source not found: $DotfilesSrc"
  exit 1
}
foreach ($req in @('home.nim','system.nim','stow')) {
  if (-not (Test-Path -LiteralPath (Join-Path $DotfilesSrc $req))) {
    Fail "dotfiles missing required entry: $req"
    exit 1
  }
}

# Host-side binaries
foreach ($f in $ReproFiles) {
  $p = Join-Path $ReproBinHost $f
  if (-not (Test-Path $p)) {
    Fail "missing host-side repro artifact: $p"
    Fail "Build first (in the dev shell): just build"
    exit 1
  }
}

# Out dir
if (Test-Path $OutDir) {
  Info "clearing out dir $OutDir"
  Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$startedAt = Get-Date
Set-Content -Path (Join-Path $OutDir '_run-started.txt') `
  -Value ("run-hyperv-dotfiles-fullprofile.ps1 started $($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))") `
  -Encoding ascii

# Snapshot before
$beforeLog = Join-Path $OutDir '00-vm-state.log'
"=== VM state BEFORE run ($($startedAt.ToString('yyyy-MM-dd HH:mm:ss'))) ===" | Set-Content -Path $beforeLog -Encoding utf8
Get-VM -Name $VmName | Format-List Name,State,Generation,ProcessorCount,Status,Uptime | Out-String | Add-Content -Path $beforeLog
Get-VMSnapshot -VMName $VmName | Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName | Out-String | Add-Content -Path $beforeLog
Get-VMIntegrationService -VMName $VmName | Format-Table Name,Enabled,PrimaryStatusDescription | Out-String | Add-Content -Path $beforeLog

# ---------------------------------------------------------------------------
# Step accumulator (RESULT.txt)
# ---------------------------------------------------------------------------
$steps = [ordered]@{}
function Record($k, $v) {
  $steps[$k] = $v
  Info ("  step '$k' -> $v")
}

# ---------------------------------------------------------------------------
# Stage A pre-step: build the host-side dotfiles zip
# ---------------------------------------------------------------------------
# Excludes .git (~30 MB of unused git history) so the staged tree is
# ~31 MB instead of ~61 MB. The exclusion is non-destructive: the apply
# pipeline reads home.nim / system.nim / stow/, none of which need git
# history. Compress via .NET ZipFile so we can exclude .git cleanly
# without `Compress-Archive`'s glob limitations.
$StageDir       = Join-Path $OutDir '_stage'
$HostDotfilesZip = Join-Path $StageDir 'dotfiles.zip'
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
Info "building host-side dotfiles zip at $HostDotfilesZip (excluding .git)"
$zipBuildStart = Get-Date
Add-Type -AssemblyName 'System.IO.Compression'
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
if (Test-Path $HostDotfilesZip) { Remove-Item $HostDotfilesZip -Force }
$zip = [System.IO.Compression.ZipFile]::Open(
  $HostDotfilesZip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  $rootLen = $DotfilesSrc.TrimEnd('\').Length + 1
  $skipPrefix = (Join-Path $DotfilesSrc '.git').ToLowerInvariant() + '\'
  $entryCount = 0
  $totalBytes = 0
  Get-ChildItem -LiteralPath $DotfilesSrc -Recurse -File -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
      $full = $_.FullName
      if ($full.ToLowerInvariant().StartsWith($skipPrefix)) { return }
      $rel = $full.Substring($rootLen).Replace('\','/')
      $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Fastest)
      $stream = $null
      $reader = $null
      try {
        $stream = $entry.Open()
        $reader = [System.IO.File]::OpenRead($full)
        $reader.CopyTo($stream)
      } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
      }
      $entryCount++
      $totalBytes += $_.Length
    }
} finally {
  $zip.Dispose()
}
$zipBuildSec = [int]((Get-Date) - $zipBuildStart).TotalSeconds
$zipBytes = (Get-Item $HostDotfilesZip).Length
Info ("  zip built: $entryCount entries, source $totalBytes b, zip $zipBytes b, ${zipBuildSec}s")
Record 'stageA0_zip_build' "OK ($entryCount entries, $zipBytes bytes in ${zipBuildSec}s)"

# Build the reprobuild-libs zip alongside the dotfiles zip. Only the
# `libs/<name>/src` subtrees from `$ReproProfileLibs` are included; tests/
# and other non-imported tree are excluded to keep the staged archive
# small (~2 MB end-to-end vs ~30+ MB for the full libs tree).
$HostReproLibsZip = Join-Path $StageDir 'reprobuild-libs.zip'
Info "building reprobuild-libs zip at $HostReproLibsZip"
$libsZipStart = Get-Date
if (Test-Path $HostReproLibsZip) { Remove-Item $HostReproLibsZip -Force }
$libsZip = [System.IO.Compression.ZipFile]::Open(
  $HostReproLibsZip, [System.IO.Compression.ZipArchiveMode]::Create)
$libsEntries = 0
$libsBytes = 0
try {
  foreach ($libName in $ReproProfileLibs) {
    $libSrcRoot = Join-Path $ReproRepoRoot ("libs\$libName\src")
    if (-not (Test-Path -LiteralPath $libSrcRoot -PathType Container)) {
      throw "reprobuild lib src missing on host: $libSrcRoot"
    }
    $rootLen = $libSrcRoot.TrimEnd('\').Length + 1
    Get-ChildItem -LiteralPath $libSrcRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
      ForEach-Object {
        $full = $_.FullName
        $rel = "libs/$libName/src/" + $full.Substring($rootLen).Replace('\','/')
        $entry = $libsZip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Fastest)
        $stream = $null
        $reader = $null
        try {
          $stream = $entry.Open()
          $reader = [System.IO.File]::OpenRead($full)
          $reader.CopyTo($stream)
        } finally {
          if ($reader) { $reader.Dispose() }
          if ($stream) { $stream.Dispose() }
        }
        $libsEntries++
        $libsBytes += $_.Length
      }
  }
} finally {
  $libsZip.Dispose()
}
$libsZipSec = [int]((Get-Date) - $libsZipStart).TotalSeconds
$libsZipBytes = (Get-Item $HostReproLibsZip).Length
Info ("  reprobuild-libs zip built: $libsEntries entries, source $libsBytes b, zip $libsZipBytes b, ${libsZipSec}s")
Record 'stageA1_libs_zip_build' "OK ($libsEntries entries, $libsZipBytes bytes in ${libsZipSec}s)"

# ---------------------------------------------------------------------------
# Main lifecycle - try/finally so Stop-VM always runs
# ---------------------------------------------------------------------------
$homeApplyExit  = $null
$infraApplyExit = $null
$scoopOk        = $false
$verdict        = 'UNKNOWN'

try {
  # ---- Stage A: revert to snapshot ---------------------------------------
  if ($vm.State -ne 'Off') {
    Info "VM was in state $($vm.State); stopping before snapshot revert"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  }
  Info "Restore-VMCheckpoint -VMName $VmName -Name $Snapshot"
  Restore-VMCheckpoint -VMName $VmName -Name $Snapshot -Confirm:$false
  Record 'stageA_vm_revert' 'OK'

  # The base-clean snapshot was created with MemoryStartup=8 GB (sized
  # for the VS Build Tools gate). Snapshot revert restores that
  # MemoryStartup, and on a host that is already memory-pressured
  # (other workloads consuming most of 125 GB) the 8 GB startup
  # allocation can fail with 0x8007000E "Not enough memory resources
  # are available". The full-profile harness needs FAR less RAM than
  # the VS gate (no MSBuild / VS install), so reduce MemoryStartup to
  # 2 GB here. Dynamic memory is enabled with a 16 GB ceiling, so the
  # VM can still grow on demand if more RAM is available. The change
  # affects only the next boot; the next snapshot revert restores the
  # original 8 GB. Both must be set together or Hyper-V refuses
  # Minimum >= Startup; we keep Min = 1 GB so the VM can be balanced
  # down.
  $desiredStartup = 2GB
  $vmNow = Get-VmOrNull $VmName
  if ($vmNow -and $vmNow.MemoryStartup -gt $desiredStartup) {
    Info "  resizing MemoryStartup $($vmNow.MemoryStartup) -> $desiredStartup (host RAM pressure mitigation)"
    Set-VMMemory -VMName $VmName -StartupBytes $desiredStartup -MinimumBytes 1GB -DynamicMemoryEnabled $true
  }

  # ---- Stage B: start VM --------------------------------------------------
  Info "Start-VM"
  Start-VM -Name $VmName
  $ready = Wait-VmPSDirectReady -Name $VmName -Credential $cred -TimeoutSec 300
  if (-not $ready) {
    Record 'stageB_vm_start' 'TIMEOUT'
    throw "VM did not come up on PowerShell Direct within 5 min"
  }
  Record 'stageB_vm_start' 'OK'

  # ---- Stage C: Guest Service Interface ready -----------------------------
  $gsiReady = Wait-VmGuestServiceInterfaceReady -Name $VmName -TimeoutSec 120
  if (-not $gsiReady) {
    Record 'stageC_gsi_ready' 'TIMEOUT'
    throw "Guest Service Interface did not report 'OK' within 120 s"
  }
  Record 'stageC_gsi_ready' 'OK'

  # ---- Stage D: prepare harness dirs inside VM ----------------------------
  Info "preparing $VmHarness inside the VM"
  Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    param($root, $dotfilesDir, $reproDir)
    foreach ($d in @($root, $reproDir)) {
      if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
      } else {
        Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
          Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    # dotfilesDir is the expansion target - remove it entirely; Expand-Archive will recreate it.
    if (Test-Path $dotfilesDir) {
      Remove-Item $dotfilesDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  } -ArgumentList @($VmHarness, $VmDotfilesDir, $VmReproDir) | Out-Null

  # ---- Stage D1: Copy-VMFile the dotfiles zip into the VM -----------------
  Info "Copy-VMFile: staging dotfiles zip into $VmDotfilesZip"
  $copyStart = Get-Date
  Copy-VMFile -Name $VmName -SourcePath $HostDotfilesZip -DestinationPath $VmDotfilesZip `
              -CreateFullPath -FileSource Host -Force
  $copySec = [int]((Get-Date) - $copyStart).TotalSeconds
  Info ("  Copy-VMFile of $zipBytes b dotfiles.zip completed in ${copySec}s")

  # Expand-Archive inside the VM, then verify a few sentinel paths.
  Info "Expand-Archive inside VM -> $VmDotfilesDir"
  $expandResult = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    param($zip, $dest)
    $err = $null
    try {
      Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop
    } catch { $err = "Expand-Archive failed: $_" }
    $homeNim   = Test-Path (Join-Path $dest 'home.nim')
    $sysNim    = Test-Path (Join-Path $dest 'system.nim')
    $stowDir   = Test-Path (Join-Path $dest 'stow')
    $gitCfg    = Test-Path (Join-Path $dest 'stow\git\.gitconfig')
    $fileCount = (Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object).Count
    return [pscustomobject]@{
      Error      = $err
      HomeNim    = $homeNim
      SystemNim  = $sysNim
      StowDir    = $stowDir
      GitConfig  = $gitCfg
      FileCount  = $fileCount
    }
  } -ArgumentList @($VmDotfilesZip, $VmDotfilesDir)
  if ($expandResult.Error) {
    Record 'stageD_copy_dotfiles' "FAILED: $($expandResult.Error)"
    throw "dotfiles expand failed: $($expandResult.Error)"
  }
  if (-not ($expandResult.HomeNim -and $expandResult.SystemNim -and $expandResult.StowDir -and $expandResult.GitConfig)) {
    Record 'stageD_copy_dotfiles' ("INCOMPLETE: home.nim=$($expandResult.HomeNim) system.nim=$($expandResult.SystemNim) stow=$($expandResult.StowDir) gitconfig=$($expandResult.GitConfig) files=$($expandResult.FileCount)")
    throw "dotfiles expand incomplete inside VM"
  }
  Record 'stageD_copy_dotfiles' "OK ($($expandResult.FileCount) files staged)"

  # ---- Stage D2: Copy-VMFile the reprobuild-libs zip + expand -----------
  # Phase F3 compile-then-apply path needs `nim c` to resolve
  # `import repro_profile` inside the dotfiles' home.nim / system.nim.
  # reproot resolves either $REPROBUILD_REPO_ROOT (operator override) OR
  # a compile-time-baked anchor, which on the host points at the
  # reprobuild build dir -- nonsense inside the VM. We stage the closure
  # of `ProfileNimPathLibs` and point the env var at the staged root.
  Info "Copy-VMFile: staging reprobuild-libs zip into $VmReproLibsZip"
  $libsCopyStart = Get-Date
  Copy-VMFile -Name $VmName -SourcePath $HostReproLibsZip -DestinationPath $VmReproLibsZip `
              -CreateFullPath -FileSource Host -Force
  $libsCopySec = [int]((Get-Date) - $libsCopyStart).TotalSeconds
  Info ("  Copy-VMFile of $libsZipBytes b reprobuild-libs.zip completed in ${libsCopySec}s")

  Info "Expand-Archive inside VM -> $VmReproRoot"
  $libsExpandResult = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    param($zip, $dest, $sentinelLib)
    $err = $null
    try {
      if (Test-Path $dest) {
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
      }
      Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop
    } catch { $err = "Expand-Archive failed: $_" }
    $sentinel = Test-Path (Join-Path $dest "libs\$sentinelLib\src\$sentinelLib.nim")
    $fileCount = (Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object).Count
    return [pscustomobject]@{
      Error      = $err
      Sentinel   = $sentinel
      FileCount  = $fileCount
    }
  } -ArgumentList @($VmReproLibsZip, $VmReproRoot, 'repro_profile')
  if ($libsExpandResult.Error) {
    Record 'stageD2_copy_libs' "FAILED: $($libsExpandResult.Error)"
    throw "reprobuild-libs expand failed: $($libsExpandResult.Error)"
  }
  if (-not $libsExpandResult.Sentinel) {
    Record 'stageD2_copy_libs' "INCOMPLETE: sentinel libs\repro_profile\src\repro_profile.nim missing (files=$($libsExpandResult.FileCount))"
    throw "reprobuild-libs expand incomplete inside VM"
  }
  Record 'stageD2_copy_libs' "OK ($($libsExpandResult.FileCount) files staged)"

  # ---- Stage E: Copy-VMFile the repro binaries ----------------------------
  Info "Copy-VMFile: staging repro binaries into $VmReproDir"
  foreach ($f in $ReproFiles) {
    $src = Join-Path $ReproBinHost $f
    $dst = "$VmReproDir\$f"
    Info "  $src -> $dst"
    Copy-VMFile -Name $VmName -SourcePath $src -DestinationPath $dst `
                -CreateFullPath -FileSource Host -Force
  }
  # Sanity-verify the staged files inside the VM (Copy-VMFile can no-op
  # silently if GSI is in a degraded state - we already waited for GSI
  # but a paranoid extra check is cheap).
  $stagedOk = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    param($dir, $files)
    $missing = @()
    foreach ($f in $files) {
      $p = Join-Path $dir $f
      if (-not (Test-Path $p)) { $missing += $f }
    }
    return ,$missing
  } -ArgumentList @($VmReproDir, $ReproFiles)
  if ($stagedOk.Count -gt 0) {
    Record 'stageE_copy_repro' "INCOMPLETE: missing $($stagedOk -join ',')"
    throw "repro binaries missing after Copy-VMFile: $($stagedOk -join ',')"
  }
  Record 'stageE_copy_repro' 'OK'

  # ---- Stage F: install Scoop (with extras bucket) inside VM --------------
  Info "installing Scoop inside the VM (with extras bucket)"
  $scoopScript = {
    $log = @()
    function L($m) { $script:log += "[$(Get-Date -Format HH:mm:ss)] $m" }
    $ok = $false
    try {
      L "setting TLS 1.2 + downloading get.scoop.sh"
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      # The fresh-OOBE Win11 dev VM ships with the default LocalMachine
      # ExecutionPolicy = Restricted, which blocks `& script.ps1`. The
      # first-attempt failure was:
      #   "scoop-install.ps1 cannot be loaded because running scripts
      #    is disabled on this system."
      # Set Process-scope bypass for this PSDirect session ONLY (no
      # registry write, no host-wide side effect; the value evaporates
      # when the Invoke-Command session ends).
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
      L "ExecutionPolicy (Process) set to Bypass"
      $bootstrap = "$env:TEMP\scoop-install.ps1"
      Invoke-WebRequest -UseBasicParsing -Uri 'https://get.scoop.sh' -OutFile $bootstrap -TimeoutSec 120
      L "running bootstrap (RunAsAdmin)"
      # The VM's auto-created OOBE account is a member of the local
      # Administrators group, so -RunAsAdmin is correct here. Without it
      # the bootstrap refuses to proceed on an admin token.
      & $bootstrap -RunAsAdmin *>&1 | ForEach-Object { L ([string]$_) }
      Remove-Item $bootstrap -Force -ErrorAction SilentlyContinue
      # User-scope scoop bootstrap puts the shim under
      # %USERPROFILE%\scoop\shims. Refresh PATH for THIS session so the
      # follow-up `scoop bucket add extras` works.
      $env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
      $shim = "$env:USERPROFILE\scoop\shims\scoop.cmd"
      if (-not (Test-Path $shim)) { $shim = "$env:USERPROFILE\scoop\shims\scoop.ps1" }
      if (-not (Test-Path $shim)) { throw "scoop shim missing after bootstrap" }
      L "scoop shim present at $shim"
      # Chicken-and-egg: `scoop bucket add extras` shells out to `git
      # clone` and refuses with "Git is required for buckets" if git
      # is not yet installed. The fresh scoop install ships ONLY the
      # main bucket, which contains `git` itself, so a one-shot
      # `scoop install git` here unblocks the bucket-add. We do NOT
      # install the full home.nim package set here -- that is `repro
      # home apply`'s job -- only the single git prerequisite.
      L "installing git from main bucket (prerequisite for bucket add)"
      & scoop install git *>&1 | ForEach-Object { L ([string]$_) }
      # Refresh PATH so the newly-installed git is visible to this
      # session's `scoop bucket add` invocation.
      $env:Path = "$env:USERPROFILE\scoop\apps\git\current\bin;$env:Path"
      L "adding extras bucket"
      & scoop bucket add extras *>&1 | ForEach-Object { L ([string]$_) }
      L "scoop bucket list:"
      & scoop bucket list *>&1 | ForEach-Object { L ([string]$_) }
      # M83 Phase E: Nim's `nim c` shells out to a C backend (gcc.exe by
      # default). The fresh Win11 dev VM has neither gcc nor cl.exe;
      # rather than dragging in winget+WinLibs, install gcc via scoop's
      # `main` bucket -- same machinery that just bootstrapped git.
      # This puts `gcc.exe` under `~\scoop\apps\gcc\current\bin\`, and
      # the apply ScriptBlock further down already prepends the user
      # PATH (which includes scoop shims) so the compile step finds it.
      L "installing gcc from main bucket (Nim backend C compiler)"
      & scoop install gcc *>&1 | ForEach-Object { L ([string]$_) }
      $env:Path = "$env:USERPROFILE\scoop\apps\gcc\current\bin;$env:Path"
      $ok = $true
    } catch {
      L "EXCEPTION: $_"
    }
    return [pscustomobject]@{
      Ok  = $ok
      Log = ($log -join "`r`n")
    }
  }
  # 15 minutes for Scoop bootstrap + extras bucket clone.
  $scoopJob = Invoke-Command -VMName $VmName -Credential $cred `
                             -ScriptBlock $scoopScript -AsJob
  $scoopWaited = Wait-Job -Job $scoopJob -Timeout 900
  $scoopRes = $null
  if ($scoopWaited) {
    $scoopRes = Receive-Job -Job $scoopJob -ErrorAction Continue
  } else {
    Warn "scoop bootstrap timed out after 15 min"
    Stop-Job $scoopJob -ErrorAction SilentlyContinue
  }
  Remove-Job $scoopJob -Force -ErrorAction SilentlyContinue
  if ($scoopRes) {
    Set-Content -Path (Join-Path $OutDir '10-scoop-bootstrap.log') `
                -Value $scoopRes.Log -Encoding utf8
    $scoopOk = [bool]$scoopRes.Ok
  }
  if ($scoopOk) {
    Record 'stageF_scoop_install' 'OK (bootstrap + extras bucket)'
  } else {
    Record 'stageF_scoop_install' 'FAILED'
    Warn "scoop bootstrap failed - continuing so we can capture artifacts"
  }

  # ---- Stage F2: ensure Nim compiler ------------------------------------
  # Phase F3 of M83 (reprobuild commit 9f03144) made compile-then-apply
  # the ONLY apply path: `repro home apply` / `repro infra apply` shell
  # out to `nim c` to materialize each profile and HARD-ERROR when nim
  # is not on PATH. The fresh-OOBE Win11 dev VM ships without Nim, so
  # we run the dotfiles' own per-user installer here. The script is
  # idempotent + uses LOCALAPPDATA, so re-runs on a warm VM fast-path
  # to a no-op.
  Info "ensuring Nim compiler inside the VM (bin/ensure-nim.ps1)"
  $nimScript = {
    param($profileDir)
    $log = @()
    function L($m) { $script:log += "[$(Get-Date -Format HH:mm:ss)] $m" }
    $ok = $false
    try {
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
      L "ExecutionPolicy (Process) set to Bypass"
      $ensureNim = Join-Path $profileDir 'bin\ensure-nim.ps1'
      if (-not (Test-Path $ensureNim)) {
        L "ERROR: ensure-nim.ps1 not found at $ensureNim"
        return [pscustomobject]@{ Ok = $false; Log = ($log -join "`r`n") }
      }
      L "running $ensureNim -Quiet"
      & $ensureNim -Quiet *>&1 | ForEach-Object { L ([string]$_) }
      if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        L "ensure-nim.ps1 exit code $LASTEXITCODE"
        return [pscustomobject]@{ Ok = $false; Log = ($log -join "`r`n") }
      }
      # ensure-nim.ps1 writes to HKCU\Environment Path; the apply
      # invocation downstream uses a fresh Invoke-Command session that
      # WILL inherit the HKCU change. Verify by resolving nim.exe via
      # the user-scope PATH from the registry (the same path the next
      # session sees).
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $env:Path = ($userPath + ';' + $env:Path)
      $nim = Get-Command nim -ErrorAction SilentlyContinue
      if ($nim) {
        $ver = (& $nim.Source --version 2>&1 | Select-Object -First 1)
        L "nim on PATH: $($nim.Source)  ($ver)"
        $ok = $true
      } else {
        L "ERROR: nim still not resolvable after ensure-nim.ps1 ran"
      }
    } catch {
      L "EXCEPTION: $_"
    }
    return [pscustomobject]@{
      Ok  = $ok
      Log = ($log -join "`r`n")
    }
  }
  # 10 minutes covers download (~30 MB) + extract; usually under 1 min.
  $nimJob = Invoke-Command -VMName $VmName -Credential $cred `
                           -ScriptBlock $nimScript `
                           -ArgumentList @($VmDotfilesDir) -AsJob
  $nimWaited = Wait-Job -Job $nimJob -Timeout 600
  $nimRes = $null
  if ($nimWaited) {
    $nimRes = Receive-Job -Job $nimJob -ErrorAction Continue
  } else {
    Warn "ensure-nim timed out after 10 min"
    Stop-Job $nimJob -ErrorAction SilentlyContinue
  }
  Remove-Job $nimJob -Force -ErrorAction SilentlyContinue
  $nimOk = $false
  if ($nimRes) {
    Set-Content -Path (Join-Path $OutDir '00-nim-bootstrap.log') `
                -Value $nimRes.Log -Encoding utf8
    $nimOk = [bool]$nimRes.Ok
  }
  if ($nimOk) {
    Record 'stageF2_ensure_nim' 'OK (nim on user PATH)'
  } else {
    Record 'stageF2_ensure_nim' 'FAILED'
    Warn "ensure-nim failed - apply will likely hard-error; continuing to capture artifacts"
  }

  # ---- Stage G: repro home apply -----------------------------------------
  Info "running repro home apply --profile-dir $VmDotfilesDir"
  $homeScript = {
    param($reproDir, $profileDir, $outRoot, $reproRepoRoot)
    $exe = Join-Path $reproDir 'repro.exe'
    $stdoutF = Join-Path $env:TEMP 'home-apply-out.txt'
    $stderrF = Join-Path $env:TEMP 'home-apply-err.txt'
    Remove-Item $stdoutF, $stderrF -Force -ErrorAction SilentlyContinue
    # Ensure scoop's shims are on PATH for the apply (its scoop driver
    # shells out to `scoop install <pkg>`).
    $env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
    # M83 Phase F3: the apply path shells out to `nim c` to compile the
    # profile. bin/ensure-nim.ps1 wrote the nim bin dir to HKCU PATH in
    # the previous stage; merge user-scope PATH in here so this fresh
    # PSDirect session picks it up regardless of session-init timing.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $env:Path = "$userPath;$env:Path" }
    # M83 Phase F3: the compile step needs to find the `repro_profile`
    # Nim module (and its dep closure). reprobuildRepoRoot() consults
    # $REPROBUILD_REPO_ROOT first, then falls back to a compile-time
    # anchor baked into repro.exe -- the latter points at the build
    # host's filesystem, which doesn't exist inside the VM. Pin the
    # env var to the staged libs root from stageD2.
    $env:REPROBUILD_REPO_ROOT = $reproRepoRoot
    $p = Start-Process -FilePath $exe -ArgumentList @('home','apply','--profile-dir', $profileDir) `
           -NoNewWindow -PassThru `
           -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
    $null = $p.Handle
    $p.WaitForExit()
    $so = if (Test-Path $stdoutF) { Get-Content $stdoutF -Raw } else { '' }
    $se = if (Test-Path $stderrF) { Get-Content $stderrF -Raw } else { '' }
    Remove-Item $stdoutF, $stderrF -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      Stdout   = $so
      Stderr   = $se
    }
  }
  # Timeout: 35 min for full home apply (incl. scoop install of ~14 packages).
  $homeJob = Invoke-Command -VMName $VmName -Credential $cred `
                            -ScriptBlock $homeScript `
                            -ArgumentList @($VmReproDir, $VmDotfilesDir, $OutDir, $VmReproRoot) -AsJob
  $homeWaited = Wait-Job -Job $homeJob -Timeout (35 * 60)
  $homeRes = $null
  if ($homeWaited) {
    $homeRes = Receive-Job -Job $homeJob -ErrorAction Continue
  } else {
    Warn "repro home apply timed out after 35 min"
    Stop-Job $homeJob -ErrorAction SilentlyContinue
  }
  Remove-Job $homeJob -Force -ErrorAction SilentlyContinue
  if ($homeRes) {
    $homeApplyExit = $homeRes.ExitCode
    $body = @()
    $body += "COMMAND: repro home apply --profile-dir $VmDotfilesDir"
    $body += "EXIT CODE: $homeApplyExit"
    $body += ""
    $body += "----- STDOUT -----"
    $body += ($homeRes.Stdout -split "`r?`n")
    $body += "----- STDERR -----"
    $body += ($homeRes.Stderr -split "`r?`n")
    Set-Content -Path (Join-Path $OutDir '20-home-apply.txt') -Value ($body -join "`r`n") -Encoding utf8
    Record 'stageG_home_apply_exit' "$homeApplyExit"
  } else {
    $homeApplyExit = 'TIMEOUT'
    Record 'stageG_home_apply_exit' 'TIMEOUT'
  }

  # ---- Stage H: repro infra apply ----------------------------------------
  Info "running repro infra apply --no-preview --profile $VmDotfilesDir\system.nim"
  $infraScript = {
    param($reproDir, $profileDir, $reproRepoRoot)
    $exe = Join-Path $reproDir 'repro.exe'
    $profilePath = Join-Path $profileDir 'system.nim'
    $stdoutF = Join-Path $env:TEMP 'infra-apply-out.txt'
    $stderrF = Join-Path $env:TEMP 'infra-apply-err.txt'
    Remove-Item $stdoutF, $stderrF -Force -ErrorAction SilentlyContinue
    # `repro infra apply` requires EITHER a precomputed plan id (`--plan
    # <id>` from a prior `repro infra plan`) OR `--no-preview` to
    # compute + apply a fresh plan in one shot. The harness is a
    # one-shot validation, so --no-preview is the right form.
    # M83 Phase F3: as with home-apply above, merge the user-scope PATH
    # so the nim install from bin/ensure-nim.ps1 is reachable, AND set
    # REPROBUILD_REPO_ROOT so the profile compile finds `repro_profile`.
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) { $env:Path = "$userPath;$env:Path" }
    $env:REPROBUILD_REPO_ROOT = $reproRepoRoot
    $p = Start-Process -FilePath $exe -ArgumentList @('infra','apply','--no-preview','--profile', $profilePath) `
           -NoNewWindow -PassThru `
           -RedirectStandardOutput $stdoutF -RedirectStandardError $stderrF
    $null = $p.Handle
    $p.WaitForExit()
    $so = if (Test-Path $stdoutF) { Get-Content $stdoutF -Raw } else { '' }
    $se = if (Test-Path $stderrF) { Get-Content $stderrF -Raw } else { '' }
    Remove-Item $stdoutF, $stderrF -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      Stdout   = $so
      Stderr   = $se
    }
  }
  # Timeout: 20 min for infra apply (capability install can take 5-10 min).
  $infraJob = Invoke-Command -VMName $VmName -Credential $cred `
                             -ScriptBlock $infraScript `
                             -ArgumentList @($VmReproDir, $VmDotfilesDir, $VmReproRoot) -AsJob
  $infraWaited = Wait-Job -Job $infraJob -Timeout (20 * 60)
  $infraRes = $null
  if ($infraWaited) {
    $infraRes = Receive-Job -Job $infraJob -ErrorAction Continue
  } else {
    Warn "repro infra apply timed out after 20 min"
    Stop-Job $infraJob -ErrorAction SilentlyContinue
  }
  Remove-Job $infraJob -Force -ErrorAction SilentlyContinue
  if ($infraRes) {
    $infraApplyExit = $infraRes.ExitCode
    $body = @()
    $body += "COMMAND: repro infra apply --no-preview --profile $VmDotfilesDir\system.nim"
    $body += "EXIT CODE: $infraApplyExit"
    $body += ""
    $body += "----- STDOUT -----"
    $body += ($infraRes.Stdout -split "`r?`n")
    $body += "----- STDERR -----"
    $body += ($infraRes.Stderr -split "`r?`n")
    Set-Content -Path (Join-Path $OutDir '21-infra-apply.txt') -Value ($body -join "`r`n") -Encoding utf8
    Record 'stageH_infra_apply_exit' "$infraApplyExit"
  } else {
    $infraApplyExit = 'TIMEOUT'
    Record 'stageH_infra_apply_exit' 'TIMEOUT'
  }

  # ---- Stage I: harvest verification artifacts ---------------------------
  Info "harvesting verification artifacts from VM"
  try {
    $harvestScript = {
      # The fresh Win11 VHDX ships with ExecutionPolicy=Restricted; the
      # scoop bootstrap set Process-scope Bypass in its own PSDirect
      # session, but a NEW Invoke-Command session does not inherit
      # that, so `scoop list` (which resolves via the `scoop.ps1`
      # shim) gets ExecutionPolicy-blocked. Re-apply here so every
      # harvest step has the same policy.
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
      $diagDir = Join-Path $env:TEMP 'fullprofile-diag'
      New-Item -ItemType Directory -Force -Path $diagDir | Out-Null
      $summary = @()
      function S($m) { $script:summary += $m }

      # 1. HKLM AppModelUnlock dwords (system.nim §1)
      try {
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        $devLic = (Get-ItemProperty -Path $rk -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
        $trusted = (Get-ItemProperty -Path $rk -Name 'AllowAllTrustedApps' -ErrorAction Stop).AllowAllTrustedApps
        "AllowDevelopmentWithoutDevLicense=$devLic" | Out-File (Join-Path $diagDir 'appmodelunlock.txt') -Encoding utf8
        "AllowAllTrustedApps=$trusted" | Out-File (Join-Path $diagDir 'appmodelunlock.txt') -Encoding utf8 -Append
        S "appmodelunlock: devLic=$devLic trusted=$trusted"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'appmodelunlock.txt') -Encoding utf8
        S "appmodelunlock: ERROR $_"
      }

      # 2. OpenSSH.Server capability (system.nim §2)
      try {
        Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop |
          Format-List | Out-File (Join-Path $diagDir 'openssh-capability.txt') -Encoding utf8
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
        S "openssh-capability: $($cap.State)"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'openssh-capability.txt') -Encoding utf8
        S "openssh-capability: ERROR $_"
      }

      # 3. sshd service
      try {
        Get-Service sshd -ErrorAction Stop |
          Format-List Status, StartType, Name, DisplayName |
          Out-File (Join-Path $diagDir 'sshd-service.txt') -Encoding utf8
        $svc = Get-Service sshd -ErrorAction Stop
        S "sshd-service: Status=$($svc.Status) StartType=$($svc.StartType)"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'sshd-service.txt') -Encoding utf8
        S "sshd-service: ERROR $_"
      }

      # 4. sshd_config full content
      try {
        $cfg = 'C:\ProgramData\ssh\sshd_config'
        if (Test-Path $cfg) {
          Get-Content $cfg | Out-File (Join-Path $diagDir 'sshd-config.txt') -Encoding utf8
          # Check the three Test-OpenSshServerReady invariants
          $content = Get-Content $cfg -Raw
          $hasPubkey = $content -match '(?im)^\s*PubkeyAuthentication\s+yes\s*$'
          $hasUserKeys = $content -match '(?im)^\s*AuthorizedKeysFile\s+\.ssh/authorized_keys\s*$'
          $hasAdminBlock = $content -match '(?im)^\s*Match\s+Group\s+administrators'
          S "sshd-config: pubkey=$hasPubkey userKeys=$hasUserKeys adminBlock(absent-required)=$(-not $hasAdminBlock)"
        } else {
          "MISSING: $cfg" | Out-File (Join-Path $diagDir 'sshd-config.txt') -Encoding utf8
          S "sshd-config: MISSING"
        }
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'sshd-config.txt') -Encoding utf8
        S "sshd-config: ERROR $_"
      }

      # 5. HKCU\Environment user PATH (home.nim env.userPath).
      # The M68 env.userPath driver writes either the token form
      # (%LOCALAPPDATA%\...) when the existing HKCU Path is
      # REG_EXPAND_SZ, or the RESOLVED-ABSOLUTE form when the
      # existing Path is REG_SZ. A fresh Win11 VHDX ships HKCU
      # Path as REG_SZ (no expand-string), so on a clean VM the
      # driver writes the resolved form. The host check below
      # accepts EITHER form so it works against both fresh-VM and
      # real-host states.
      try {
        $envPath = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction Stop).Path
        $envPath | Out-File (Join-Path $diagDir 'hkcu-env-path.txt') -Encoding utf8
        $launcherToken = '%LOCALAPPDATA%\repro\home\bin'
        $launcherResolved = Join-Path $env:LOCALAPPDATA 'repro\home\bin'
        $gitBashToken = '%USERPROFILE%\scoop\apps\git\current\usr\bin'
        $gitBashResolved = Join-Path $env:USERPROFILE 'scoop\apps\git\current\usr\bin'
        $hasLauncher = ($envPath -match [regex]::Escape($launcherToken)) -or
                       ($envPath -match [regex]::Escape($launcherResolved))
        $hasGitBash  = ($envPath -match [regex]::Escape($gitBashToken)) -or
                       ($envPath -match [regex]::Escape($gitBashResolved))
        S "hkcu-env-path: launcherDir=$hasLauncher gitBash=$hasGitBash"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'hkcu-env-path.txt') -Encoding utf8
        S "hkcu-env-path: ERROR $_"
      }

      # 6. HKCU\Environment XDG variables (home.nim env.userVariable)
      try {
        $envProps = Get-ItemProperty -Path 'HKCU:\Environment' -ErrorAction Stop
        $lines = @()
        foreach ($n in @('XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','DIRENV_CONFIG')) {
          $v = $envProps.$n
          $lines += "$n=$v"
        }
        $lines | Out-File (Join-Path $diagDir 'hkcu-env-xdg.txt') -Encoding utf8
        $havAll = $true
        foreach ($n in @('XDG_CONFIG_HOME','XDG_CACHE_HOME','XDG_DATA_HOME','DIRENV_CONFIG')) {
          if (-not $envProps.$n) { $havAll = $false }
        }
        S "hkcu-env-xdg: all-set=$havAll"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'hkcu-env-xdg.txt') -Encoding utf8
        S "hkcu-env-xdg: ERROR $_"
      }

      # 7. ~/.gitconfig symlink check (stow auto-discovery)
      try {
        $gc = Join-Path $env:USERPROFILE '.gitconfig'
        if (Test-Path $gc) {
          $item = Get-Item $gc -Force
          $linkType = $item.LinkType
          $tgt = if ($item.Target) { ($item.Target -join ';') } else { '' }
          "Path=$gc`nLinkType=$linkType`nTarget=$tgt" | Out-File (Join-Path $diagDir 'gitconfig-symlink.txt') -Encoding utf8
          S "gitconfig: present linkType=$linkType target=$tgt"
        } else {
          "MISSING: $gc" | Out-File (Join-Path $diagDir 'gitconfig-symlink.txt') -Encoding utf8
          S "gitconfig: MISSING"
        }
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'gitconfig-symlink.txt') -Encoding utf8
        S "gitconfig: ERROR $_"
      }

      # 8. PowerShell profile managed block (home.nim shell.integration)
      try {
        $profilePath = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
        if (Test-Path $profilePath) {
          Get-Content $profilePath | Out-File (Join-Path $diagDir 'pwsh-profile.txt') -Encoding utf8
          $content = Get-Content $profilePath -Raw
          $hasBlock = $content -match 'repro-home-direnv'
          S "pwsh-profile: present managed-block=$hasBlock"
        } else {
          "MISSING: $profilePath" | Out-File (Join-Path $diagDir 'pwsh-profile.txt') -Encoding utf8
          S "pwsh-profile: MISSING"
        }
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'pwsh-profile.txt') -Encoding utf8
        S "pwsh-profile: ERROR $_"
      }

      # 9. scoop list (home.nim packages)
      try {
        $env:Path = "$env:USERPROFILE\scoop\shims;$env:Path"
        $listRaw = & scoop list 2>&1
        $listRaw | Out-File (Join-Path $diagDir 'scoop-list.txt') -Encoding utf8
        # Parse `scoop list` output - first column is package name.
        # `scoop list` returns a PSObject array; -match against the array
        # tests element-membership, which doesn't intersect well with the
        # multiline (?m) regex semantics. Read the just-written text back
        # as a single string so the (?m)^ anchor works per physical line.
        $listText = Get-Content (Join-Path $diagDir 'scoop-list.txt') -Raw
        $expected = @('age','gnupg','git','gh','windows-terminal','vscode','neovim','pwsh','direnv','ripgrep','firefox','googlechrome','codex','claude-code')
        $installed = @()
        foreach ($pkg in $expected) {
          if ($listText -match ('(?m)^\s*' + [regex]::Escape($pkg) + '\s')) { $installed += $pkg }
        }
        S "scoop-list: $($installed.Count)/$($expected.Count) expected installed ($($installed -join ','))"
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'scoop-list.txt') -Encoding utf8
        S "scoop-list: ERROR $_"
      }

      # 10. Repro state dir tree
      try {
        $reproState = Join-Path $env:LOCALAPPDATA 'repro'
        if (Test-Path $reproState) {
          Get-ChildItem -Path $reproState -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object FullName, Length, LinkType |
            Format-Table -AutoSize | Out-String |
            Out-File (Join-Path $diagDir 'repro-state-tree.txt') -Encoding utf8
        } else {
          "(does not exist)" | Out-File (Join-Path $diagDir 'repro-state-tree.txt') -Encoding utf8
        }
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'repro-state-tree.txt') -Encoding utf8
      }

      # 11. Home dir top-level listing (catch stow symlinks)
      try {
        Get-ChildItem -Path $env:USERPROFILE -Force -ErrorAction SilentlyContinue |
          Select-Object Name, LinkType, Target |
          Format-Table -AutoSize | Out-String |
          Out-File (Join-Path $diagDir 'home-top.txt') -Encoding utf8
      } catch {
        "ERROR: $_" | Out-File (Join-Path $diagDir 'home-top.txt') -Encoding utf8
      }

      # 12. Active windows.registryValue resources cross-check
      try {
        $lines = @()
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        $devLic = $null; $trusted = $null
        try {
          $devLic = (Get-ItemProperty -Path $rk -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
        } catch { $lines += "AllowDevelopmentWithoutDevLicense: ERROR $_" }
        try {
          $trusted = (Get-ItemProperty -Path $rk -Name 'AllowAllTrustedApps' -ErrorAction Stop).AllowAllTrustedApps
        } catch { $lines += "AllowAllTrustedApps: ERROR $_" }
        $lines += "devLic=$devLic"
        $lines += "trusted=$trusted"
        $lines | Out-File (Join-Path $diagDir 'system-registry-summary.txt') -Encoding utf8
      } catch { }

      # Summary file
      $summary | Out-File (Join-Path $diagDir '_summary.txt') -Encoding utf8

      # Compress to a single zip and return as bytes.
      $zip = Join-Path $env:TEMP 'fullprofile-diag.zip'
      if (Test-Path $zip) { Remove-Item $zip -Force }
      Compress-Archive -Path "$diagDir\*" -DestinationPath $zip -CompressionLevel Fastest -ErrorAction Stop
      [byte[]]$bytes = [System.IO.File]::ReadAllBytes($zip)
      $fileList = Get-ChildItem -LiteralPath $diagDir | Select-Object Name, Length
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
      return [pscustomobject]@{
        Bytes   = $bytes
        Length  = $bytes.Length
        Files   = $fileList
        Summary = ($summary -join "`r`n")
      }
    }
    $harvest = Invoke-Command -VMName $VmName -Credential $cred `
                              -ScriptBlock $harvestScript -ErrorAction Stop
    if ($harvest -and $harvest.Length -gt 0) {
      $hostZip = Join-Path $OutDir 'vm-diag.zip'
      [System.IO.File]::WriteAllBytes($hostZip, $harvest.Bytes)
      Set-Content -Path (Join-Path $OutDir '30-verification-summary.txt') `
                  -Value $harvest.Summary -Encoding utf8
      # Also expand the zip on the host for direct inspection.
      $hostExpand = Join-Path $OutDir 'vm-diag'
      if (Test-Path $hostExpand) { Remove-Item $hostExpand -Recurse -Force -ErrorAction SilentlyContinue }
      Expand-Archive -Path $hostZip -DestinationPath $hostExpand -Force
      $count = (Get-ChildItem -Path $hostExpand -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
      Record 'stageI_artifacts' "OK ($count files captured, $($harvest.Length) bytes zipped)"
    } else {
      Record 'stageI_artifacts' 'EMPTY: harvest produced no bytes'
    }
  } catch {
    Warn "  artifact harvest failed (non-fatal): $_"
    Record 'stageI_artifacts' "FAILED: $_"
  }

}
catch {
  Fail "lifecycle threw: $_"
  Fail $_.ScriptStackTrace
  $verdict = "ERROR: $_"
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

  # ---- Compute verdict + write RESULT.txt -------------------------------
  if ($verdict -eq 'UNKNOWN') {
    if (("$homeApplyExit" -eq '0') -and ("$infraApplyExit" -eq '0')) {
      $verdict = 'PASS - home + system applied; check 30-verification-summary.txt for resource invariants'
    } elseif ("$homeApplyExit" -ne '0' -and "$infraApplyExit" -ne '0') {
      $verdict = "FAIL - both apply phases non-zero (home=$homeApplyExit infra=$infraApplyExit)"
    } elseif ("$homeApplyExit" -ne '0') {
      $verdict = "FAIL - home apply exit=$homeApplyExit"
    } else {
      $verdict = "FAIL - infra apply exit=$infraApplyExit"
    }
  }

  $elapsedMin = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 2)
  $resultLines = @()
  $resultLines += "Hyper-V full-profile dotfiles harness - RESULT"
  $resultLines += "generated:      $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
  $resultLines += "host:           $env:COMPUTERNAME  user: $env:USERNAME"
  $resultLines += "vm:             $VmName"
  $resultLines += "snapshot:       $Snapshot"
  $resultLines += "wall-clock min: $elapsedMin"
  $resultLines += ""
  foreach ($k in $steps.Keys) {
    $resultLines += ("{0,-28} {1}" -f $k, $steps[$k])
  }
  $resultLines += ""
  $resultLines += "VERDICT: $verdict"
  Set-Content -Path (Join-Path $OutDir 'RESULT.txt') -Value $resultLines -Encoding utf8

  # Append "after" VM-state
  "" | Add-Content -Path $beforeLog
  "=== VM state AFTER run ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ===" | Add-Content -Path $beforeLog
  Get-VM -Name $VmName -ErrorAction SilentlyContinue | Format-List Name,State,Status,Uptime | Out-String | Add-Content -Path $beforeLog
  Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue |
    Format-Table Name,SnapshotType,CreationTime,ParentSnapshotName |
    Out-String | Add-Content -Path $beforeLog

  # DONE sentinel - written LAST
  Set-Content -Path (Join-Path $OutDir 'DONE') -Value "done $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding ascii
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ""
Info ("=" * 70)
Info "Results in: $OutDir"
Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
  Sort-Object Name |
  ForEach-Object { Info ("  {0,-40} {1,10} bytes" -f $_.Name, $_.Length) }
$rt = Join-Path $OutDir 'RESULT.txt'
if (Test-Path $rt) {
  Write-Host ""
  Info "----- RESULT.txt -----"
  Get-Content $rt | ForEach-Object { Write-Host "  $_" }
}
Info ("=" * 70)

if (("$homeApplyExit" -eq '0') -and ("$infraApplyExit" -eq '0')) { exit 0 }
elseif ("$homeApplyExit" -eq 'TIMEOUT' -or "$infraApplyExit" -eq 'TIMEOUT') { exit 2 }
else { exit 1 }
