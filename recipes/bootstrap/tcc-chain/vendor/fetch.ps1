# fetch.ps1 — re-materialise minimal-bootstrap-sources.tar.gz from upstream.
#
# Runs entirely inside the repro-debian WSL distro (we need git +
# tar + GNU find + bash). Output goes to this script's parent dir as
# `minimal-bootstrap-sources.tar.gz` and is sha256-checked against
# `SHA256SUMS`.
#
# Usage: pwsh recipes/bootstrap/tcc-chain/vendor/fetch.ps1
#
# Build-env determinism flags (must match recipes/bootstrap/tcc-chain/scripts/*):
#   SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC
# Tar flags (must match):
#   --sort=name --mtime=@1735689600 --owner=0 --group=0 --numeric-owner

$ErrorActionPreference = 'Stop'
$vendorDir = $PSScriptRoot
$wslVendorDir = ($vendorDir -replace '^([A-Za-z]):','/mnt/$1' -replace '\\','/' ).ToLower() `
  -replace '^/mnt/([a-z])','/mnt/$1'
# pwsh-side translate, then re-case the drive letter so wsl is happy:
$drive = $vendorDir.Substring(0,1).ToLower()
$rest  = $vendorDir.Substring(2) -replace '\\','/'
$wslVendorDir = "/mnt/$drive$rest"

Write-Host "Vendor dir (windows): $vendorDir"
Write-Host "Vendor dir (wsl):     $wslVendorDir"

$wslScript = @"
set -e
TMP=/tmp/r4snap-fetch
rm -rf `$TMP
mkdir `$TMP
cd `$TMP
echo '[fetch] cloning stage0-posix Release_1.9.1...'
git clone -q --depth 1 --branch Release_1.9.1 https://github.com/oriansj/stage0-posix.git stage0-posix
cd stage0-posix
echo '[fetch] updating submodules (recursive, depth 1)...'
git submodule update --init --depth 1 --recursive 2>&1 | tail -5
echo '[fetch] stripping .git*'
find . -name '.git' -prune -exec rm -rf {} + 2>/dev/null || true
find . -name '.gitmodules' -delete 2>/dev/null || true
find . -name '.gitignore' -delete 2>/dev/null || true
cd ..
echo '[fetch] producing reproducible tarball'
SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC tar --sort=name --mtime='@1735689600' \
  --owner=0 --group=0 --numeric-owner \
  -czf '$wslVendorDir/minimal-bootstrap-sources.tar.gz' stage0-posix
echo '[fetch] sha256:'
sha256sum '$wslVendorDir/minimal-bootstrap-sources.tar.gz'
rm -rf `$TMP
"@

wsl -d repro-debian -- bash -lc $wslScript
if ($LASTEXITCODE -ne 0) {
  throw "WSL clone/tar failed (exit $LASTEXITCODE)"
}

# Verify
Push-Location $vendorDir
try {
  $expected = (Get-Content SHA256SUMS | Where-Object { $_ -match 'minimal-bootstrap-sources.tar.gz' }).Split(' ')[0]
  $actualLine = wsl -d repro-debian -- bash -lc "sha256sum '$wslVendorDir/minimal-bootstrap-sources.tar.gz'"
  $actual = $actualLine.Split(' ')[0]
  if ($actual -ne $expected) {
    throw "sha256 mismatch: got $actual, expected $expected"
  }
  Write-Host "OK: minimal-bootstrap-sources.tar.gz sha256 = $actual"
}
finally {
  Pop-Location
}
