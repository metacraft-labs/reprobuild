# Shared helpers for repro-multi-distro provisioning scripts.
#
# Dot-source from each provision-<distro>.ps1:
#   . "$PSScriptRoot\_common.ps1"
#
# Constraints (see milestone spec Linux-Distro-Recipe-Validation M0):
# - Never touch a WSL instance whose name doesn't begin with "repro-".
# - Cache rootfs tarballs under $env:LOCALAPPDATA\repro-multi-distro-cache\.
# - Skip re-download if the cached file's sha256 matches the expected value.
# - Stop on first error; surface non-zero exit codes.

$ErrorActionPreference = 'Stop'

$script:ReproDistroCacheDir = Join-Path $env:LOCALAPPDATA 'repro-multi-distro-cache'
$script:ReproDistroInstanceRoot = 'D:\wsl-instances'

function Get-ReproDistroCacheDir {
  if (-not (Test-Path $script:ReproDistroCacheDir)) {
    New-Item -ItemType Directory -Force -Path $script:ReproDistroCacheDir | Out-Null
  }
  $script:ReproDistroCacheDir
}

function Get-ReproDistroInstanceDir {
  param([Parameter(Mandatory)] [string] $InstanceName)
  if (-not $InstanceName.StartsWith('repro-')) {
    throw "Instance name must start with 'repro-' (got '$InstanceName')."
  }
  Join-Path $script:ReproDistroInstanceRoot $InstanceName
}

function Assert-ReproInstanceName {
  param([Parameter(Mandatory)] [string] $InstanceName)
  if (-not $InstanceName.StartsWith('repro-')) {
    throw "SAFETY: refusing to operate on WSL instance '$InstanceName' (must start with 'repro-')."
  }
}

function Get-ReproWslInstanceState {
  # Returns 'Missing', 'Stopped', or 'Running' for a given WSL instance name.
  param([Parameter(Mandatory)] [string] $InstanceName)
  $raw = & wsl.exe --list --verbose 2>$null
  if ($null -eq $raw) { return 'Missing' }
  # wsl --list --verbose emits UTF-16; PowerShell receives a string array.
  # Normalize whitespace and look for the name.
  foreach ($line in $raw) {
    $clean = ($line -replace "`0", '').Trim()
    if ($clean -match "^\*?\s*$([Regex]::Escape($InstanceName))\s+(\S+)\s") {
      return $matches[1]
    }
  }
  'Missing'
}

function Invoke-ReproWebDownload {
  param(
    [Parameter(Mandatory)] [string] $Url,
    [Parameter(Mandatory)] [string] $DestPath,
    [Parameter(Mandatory)] [string] $ExpectedSha256
  )
  if (Test-Path $DestPath) {
    $actual = (Get-FileHash -Path $DestPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $ExpectedSha256.ToLower()) {
      Write-Host "[cache] hit $DestPath (sha256 ok)"
      return
    }
    Write-Host "[cache] miss $DestPath (sha256 mismatch: $actual != $($ExpectedSha256.ToLower())); re-downloading"
    Remove-Item -Force $DestPath
  }
  Write-Host "[download] $Url -> $DestPath"
  $ua = 'Mozilla/5.0 repro-multi-distro-harness'
  # Use BITS-style progress-less invocation; show only timing.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # Suppress Invoke-WebRequest's slow per-byte progress bar.
  $progPref = $ProgressPreference
  try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $DestPath -UserAgent $ua -UseBasicParsing -TimeoutSec 600
  } finally {
    $ProgressPreference = $progPref
  }
  $sw.Stop()
  $sizeMb = [math]::Round((Get-Item $DestPath).Length / 1MB, 1)
  Write-Host "[download] done in $($sw.Elapsed.TotalSeconds.ToString('F1'))s ($sizeMb MB)"
  $actual = (Get-FileHash -Path $DestPath -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $ExpectedSha256.ToLower()) {
    throw "sha256 mismatch for $DestPath`n  expected: $($ExpectedSha256.ToLower())`n  got:      $actual"
  }
  Write-Host "[download] sha256 verified"
}

function Invoke-ReproWslImport {
  param(
    [Parameter(Mandatory)] [string] $InstanceName,
    [Parameter(Mandatory)] [string] $TarPath,
    [string] $ImportArgs = ''
  )
  Assert-ReproInstanceName $InstanceName
  $state = Get-ReproWslInstanceState $InstanceName
  if ($state -ne 'Missing') {
    Write-Host "[wsl] instance '$InstanceName' already exists (state=$state); unregistering for a clean import"
    & wsl.exe --terminate $InstanceName 2>$null | Out-Null
    & wsl.exe --unregister $InstanceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "wsl --unregister $InstanceName failed (exit $LASTEXITCODE)"
    }
  }
  $instanceDir = Get-ReproDistroInstanceDir $InstanceName
  if (Test-Path $instanceDir) {
    Write-Host "[wsl] removing stale instance dir $instanceDir"
    Remove-Item -Recurse -Force $instanceDir
  }
  New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
  Write-Host "[wsl] importing $InstanceName from $TarPath into $instanceDir"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if ($ImportArgs) {
    & wsl.exe --import $InstanceName $instanceDir $TarPath $ImportArgs.Split(' ')
  } else {
    & wsl.exe --import $InstanceName $instanceDir $TarPath
  }
  $sw.Stop()
  if ($LASTEXITCODE -ne 0) {
    throw "wsl --import $InstanceName failed (exit $LASTEXITCODE)"
  }
  Write-Host "[wsl] import done in $($sw.Elapsed.TotalSeconds.ToString('F1'))s"
}

function Invoke-ReproWslExec {
  param(
    [Parameter(Mandatory)] [string] $InstanceName,
    [Parameter(Mandatory)] [string] $BashScript,
    [string] $User = 'root',
    # Default to '/bin/sh' for maximum portability (Alpine minirootfs has no
    # bash). Override to '/bin/bash' for distros that need bashisms; the
    # canonical bootstrap script must be POSIX-sh-compatible.
    [string] $Shell = '/bin/sh'
  )
  Assert-ReproInstanceName $InstanceName
  $tmp = New-TemporaryFile
  try {
    # Strip BOM and normalize line endings to LF so the shell inside WSL is
    # happy with the heredocs in our prereq blobs.
    [System.IO.File]::WriteAllText(
      $tmp.FullName,
      ($BashScript -replace "`r`n", "`n"),
      (New-Object System.Text.UTF8Encoding $false))
    # Translate the host path. Use --exec so the binary doesn't go through
    # any login shell that might be missing.
    $wslTmp = & wsl.exe -d $InstanceName -u root --exec /bin/wslpath -a "$($tmp.FullName)"
    if ($LASTEXITCODE -ne 0) {
      throw "wslpath failed (exit $LASTEXITCODE) - WSL distro may be missing /bin/wslpath"
    }
    $wslTmp = $wslTmp.Trim()
    & wsl.exe -d $InstanceName -u $User --exec $Shell $wslTmp
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
      throw "wsl exec in '$InstanceName' as '$User' failed (exit $rc)"
    }
  } finally {
    Remove-Item -Force $tmp.FullName -ErrorAction SilentlyContinue
  }
}

function Invoke-ReproSmokeProbe {
  param(
    [Parameter(Mandatory)] [string] $InstanceName,
    [Parameter(Mandatory)] [string] $DistroLabel
  )
  # POSIX sh body - no bashisms (Alpine minirootfs has no bash).
  $script = @"
set -eu
cat >/tmp/hello.c <<EOF
#include <stdio.h>
int main(void) { printf("hello %s\n", "$DistroLabel"); return 0; }
EOF
gcc -O0 -o /tmp/hello /tmp/hello.c
out=`$(/tmp/hello)
expected="hello $DistroLabel"
if [ "`$out" != "`$expected" ]; then
  echo "smoke: FAIL - got '`$out', expected '`$expected'" >&2
  exit 1
fi
echo "smoke: OK (`$out)"
"@
  Invoke-ReproWslExec -InstanceName $InstanceName -BashScript $script
}

function Write-ReproProvisionSummary {
  param(
    [Parameter(Mandatory)] [string] $InstanceName,
    [Parameter(Mandatory)] [string] $RootfsUrl,
    [Parameter(Mandatory)] [string] $RootfsSha256,
    [Parameter(Mandatory)] [System.TimeSpan] $Elapsed
  )
  # Force flush of preceding native-tool output before printing the summary.
  [Console]::Out.Flush()
  Write-Output ''
  Write-Output '========================================================================'
  Write-Output "repro multi-distro: provisioned $InstanceName"
  Write-Output "  rootfs:  $RootfsUrl"
  Write-Output "  sha256:  $RootfsSha256"
  Write-Output "  elapsed: $($Elapsed.TotalSeconds.ToString('F1'))s"
  Write-Output '========================================================================'
}
