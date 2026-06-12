# fetch-r6.ps1 -- re-materialise R6 (gcc -> glibc) vendored sources from
# upstream.  All sources are gitignored; this script fetches them and
# sha256-verifies against SHA256SUMS-r6.txt.
#
# Pins match nixpkgs at the reference commit (06a4933d0):
#   - linux 6.18.7  (pkgs/os-specific/linux/kernel-headers/default.nix)
#   - glibc 2.42    (pkgs/development/libraries/glibc/common.nix)
#
# Usage: pwsh recipes/bootstrap/tcc-chain/vendor/fetch-r6.ps1

$ErrorActionPreference = 'Stop'
$vendorDir = $PSScriptRoot

$urls = @(
  @{ name = 'linux-6.18.7.tar.xz';
     url  = 'https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.7.tar.xz' },
  @{ name = 'glibc-2.42.tar.xz';
     url  = 'https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz' }
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

  Write-Host '[fetch] verifying sha256s against SHA256SUMS-r6.txt'
  $sumsFile = Join-Path $vendorDir 'SHA256SUMS-r6.txt'
  if (-not (Test-Path $sumsFile)) {
    Write-Host "[fetch] WARNING: no SHA256SUMS-r6.txt yet; printing sha256s for capture"
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
      Write-Host "[fetch] WARN: $($entry.name) not in SHA256SUMS-r6.txt; got $h"
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
