# fetch-r8.ps1 -- re-materialise R8 (linux kernel) vendored sources from
# upstream.  All sources are gitignored; this script fetches them and
# sha256-verifies against SHA256SUMS-r8.txt.
#
# Pin matches nixpkgs at the reference commit (06a4933d0):
#   - linux 6.6.142 LTS  (pkgs/os-specific/linux/kernel/kernels-org.json,
#                         entry "6.6")
#
# This is the kernel that R8 builds into a Hyper-V Gen-2 UEFI bzImage,
# and that R10's final ISO recipe will consume in place of the R2
# vendored Debian netinst kernel.
#
# Usage: pwsh recipes/bootstrap/tcc-chain/vendor/fetch-r8.ps1

$ErrorActionPreference = 'Stop'
$vendorDir = $PSScriptRoot

$urls = @(
  @{ name = 'linux-6.6.142.tar.xz';
     url  = 'https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz' }
)

Push-Location $vendorDir
try {
  foreach ($entry in $urls) {
    $target = Join-Path $vendorDir $entry.name
    if (Test-Path $target) {
      Write-Host "[fetch] skip (exists): $($entry.name)"
      continue
    }
    Write-Host "[fetch] downloading $($entry.name) ..."
    Invoke-WebRequest -Uri $entry.url -OutFile $target -UseBasicParsing
    Write-Host "[fetch] OK: $($entry.name) ($((Get-Item $target).Length) bytes)"
  }

  Write-Host '[fetch] verifying sha256s against SHA256SUMS-r8.txt'
  $sumsFile = Join-Path $vendorDir 'SHA256SUMS-r8.txt'
  if (-not (Test-Path $sumsFile)) {
    Write-Host "[fetch] WARNING: no SHA256SUMS-r8.txt yet; printing sha256s for capture"
    foreach ($entry in $urls) {
      $target = Join-Path $vendorDir $entry.name
      if (Test-Path $target) {
        $h = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLower()
        Write-Host "$h  $($entry.name)"
      }
    }
    return
  }
  $expected = @{}
  Get-Content $sumsFile | ForEach-Object {
    if ($_ -match '^([0-9a-f]{64})\s+(\S+)\s*$') {
      $expected[$Matches[2]] = $Matches[1]
    }
  }
  foreach ($entry in $urls) {
    $target = Join-Path $vendorDir $entry.name
    if (-not (Test-Path $target)) {
      throw "missing: $($entry.name)"
    }
    $h = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLower()
    if (-not $expected.ContainsKey($entry.name)) {
      Write-Host "[fetch] WARN: $($entry.name) not in SHA256SUMS-r8.txt; got $h"
      continue
    }
    if ($h -ne $expected[$entry.name]) {
      throw ("sha256 mismatch for {0}: got {1}, expected {2}" `
             -f $entry.name, $h, $expected[$entry.name])
    }
    Write-Host "[fetch] OK: $($entry.name) sha256 = $h"
  }
}
finally {
  Pop-Location
}
