# R2 vendored-blob fetcher.
#
# Pulls the upstream Debian netinst ISO used as the source of the
# kernel + initramfs that R2's typed reprobuild recipe consumes as
# inputs. Verifies the netinst ISO's sha256 against the upstream
# SHA256SUMS pin, then extracts:
#   /install.amd/vmlinuz  -> vmlinuz-debian-netinst
#   /install.amd/initrd.gz -> initrd.img-debian-netinst
#
# These two blobs ARE the R2 inputs for the typed action. The full
# netinst ISO is too large to commit (~660 MB); the kernel is ~7 MB
# (committable), the initrd is ~30 MB (gitignored, regenerated via
# this script on demand). MANIFEST.md records both.
#
# Source-of-truth: the Debian project publishes SHA256SUMS at
# https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS.
# We pin the netinst ISO sha256 against that file.
#
# Idempotent: re-running with the file present + matching digest is
# a no-op. The script reads the cached netinst ISO from
# $env:LOCALAPPDATA\repro-boot-harness-cache if present (shared with
# R1's cache convention), otherwise downloads to the cache.
#
# Run from anywhere; paths are computed from $PSScriptRoot:
#   pwsh recipes/reproos-iso/vendor/fetch.ps1
#
# LF line endings per project convention.

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# Pinned Debian netinst release. The sha256 is reproduced verbatim
# from https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS
# (snapshot taken 2026-06-12 -- 'current' resolved to 13.5.0).
$NetinstName = 'debian-13.5.0-amd64-netinst.iso'
$NetinstUrl  = 'https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso'
$NetinstSha256 = '95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a'

# Extracted blobs the recipe consumes. The names are deliberately
# upstream-version-stripped so a future re-pin to a different netinst
# release does NOT require renaming inputs across the codebase.
$KernelName    = 'vmlinuz-debian-netinst'
$InitramfsName = 'initrd.img-debian-netinst'

# Cache the upstream ISO under LOCALAPPDATA per R1's convention so
# multiple recipes (R1, R2, future) can share the same vendored ISO.
$cacheDir = Join-Path $env:LOCALAPPDATA 'repro-boot-harness-cache'
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
$cachedIso = Join-Path $cacheDir $NetinstName

function Fetch-HttpsBlob {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutPath
    )
    # Prefer curl.exe -- Invoke-WebRequest times out on slow https
    # mirrors, and the netinst ISO is ~660 MB. curl.exe ships in
    # System32 on Win10+.
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if ($curl) {
        & $curl -fsSL --retry 3 --max-time 1800 -o $OutPath $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed (rc=$LASTEXITCODE) fetching $Url"
        }
        return
    }
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -TimeoutSec 1800
    } finally {
        $ProgressPreference = $oldPref
    }
}

Write-Host "[fetch] $NetinstName"
if (Test-Path -LiteralPath $cachedIso) {
    $sha = (Get-FileHash -LiteralPath $cachedIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne $NetinstSha256.ToLowerInvariant()) {
        Write-Host "  cached sha256 mismatch; re-downloading"
        Remove-Item -LiteralPath $cachedIso -Force
    } else {
        Write-Host "  cached sha256 OK"
    }
}
if (-not (Test-Path -LiteralPath $cachedIso)) {
    Write-Host "  fetching $NetinstUrl ..."
    Fetch-HttpsBlob -Url $NetinstUrl -OutPath $cachedIso
    $sha = (Get-FileHash -LiteralPath $cachedIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne $NetinstSha256.ToLowerInvariant()) {
        throw "sha256 mismatch for ${NetinstName}: got $sha, expected $NetinstSha256"
    }
    Write-Host "  sha256 OK ($sha)"
}

# Extract kernel + initramfs by mounting the ISO via WSL (the host
# host doesn't ship 7-zip/xorriso reliably; repro-debian does).
# Convert Windows paths to WSL paths so wsl-side bash can read.
function ToWslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $abs = (Resolve-Path -LiteralPath $WinPath).Path
    $drive = $abs.Substring(0, 1).ToLowerInvariant()
    $rest = $abs.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$wslIsoPath = ToWslPath $cachedIso
$wslVendorDir = ToWslPath $here
$wslKernel = "$wslVendorDir/$KernelName"
$wslInitramfs = "$wslVendorDir/$InitramfsName"

Write-Host "[fetch] extracting kernel + initramfs from netinst ISO via repro-debian..."
$bashScript = @"
set -euo pipefail
work=`$(mktemp -d -t r2-vendor-XXXXXX)
trap 'rm -rf "`$work"' EXIT
# xorriso -osirrox extracts files from an ISO without mounting it
# (no loopback, no root required).
xorriso -osirrox on -indev '$wslIsoPath' -extract /install.amd/vmlinuz "`$work/vmlinuz" 2>/dev/null
xorriso -osirrox on -indev '$wslIsoPath' -extract /install.amd/initrd.gz "`$work/initrd.gz" 2>/dev/null
cp "`$work/vmlinuz" '$wslKernel'
cp "`$work/initrd.gz" '$wslInitramfs'
echo "kernel-bytes=`$(stat -c %s '$wslKernel')"
echo "initramfs-bytes=`$(stat -c %s '$wslInitramfs')"
"@

$bashScript | wsl -d repro-debian -u root -- bash -s

if ($LASTEXITCODE -ne 0) {
    throw "wsl xorriso extraction failed (rc=$LASTEXITCODE)"
}

# Record the resulting sha256s.
$kernelPath = Join-Path $here $KernelName
$initramfsPath = Join-Path $here $InitramfsName
$kernelSha = (Get-FileHash -LiteralPath $kernelPath -Algorithm SHA256).Hash.ToLowerInvariant()
$initramfsSha = (Get-FileHash -LiteralPath $initramfsPath -Algorithm SHA256).Hash.ToLowerInvariant()
$kernelBytes = (Get-Item -LiteralPath $kernelPath).Length
$initramfsBytes = (Get-Item -LiteralPath $initramfsPath).Length

Write-Host "[fetch] $KernelName sha256=$kernelSha bytes=$kernelBytes"
Write-Host "[fetch] $InitramfsName sha256=$initramfsSha bytes=$initramfsBytes"

$sumsLines = @(
    "$NetinstSha256  $NetinstName"
    "$kernelSha  $KernelName"
    "$initramfsSha  $InitramfsName"
)
$sumsPath = Join-Path $here 'SHA256SUMS'
$sumsContent = ($sumsLines -join "`n") + "`n"
[IO.File]::WriteAllText($sumsPath, $sumsContent, [Text.UTF8Encoding]::new($false))
Write-Host "[fetch] wrote $sumsPath"
Write-Host "[fetch] OK"
