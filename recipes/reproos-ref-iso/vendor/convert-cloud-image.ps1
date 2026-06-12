<#
  convert-cloud-image.ps1 -- Convert the vendored Debian cloud qcow2
  to a dynamic VHDX for Hyper-V Gen-2 UEFI boot.

  Idempotent: if the VHDX already exists AND a sibling sentinel file
  records the source qcow2's sha256, the conversion is skipped. This
  matters because `qemu-img convert` of a 334 MB image takes ~10-30s
  even on fast NVMe.

  Inputs:
    Qcow2Path    -- path to debian-12-genericcloud-amd64.qcow2 (default:
                    sibling of this script).
    VhdxPath     -- path to write VHDX to (default: same dir, .vhdx
                    extension; gitignored).
    Force        -- re-convert even if a valid VHDX already exists.

  Output: emits the absolute VHDX path on stdout (one line). Non-zero
  exit on any verification failure.
#>

[CmdletBinding()]
param(
  [string] $Qcow2Path = '',
  [string] $VhdxPath  = '',
  [switch] $Force
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }

if (-not $Qcow2Path) {
  $Qcow2Path = Join-Path $here 'debian-12-genericcloud-amd64.qcow2'
}
if (-not $VhdxPath) {
  $VhdxPath = Join-Path $here 'debian-12-genericcloud-amd64.vhdx'
}
$sentinelPath = "$VhdxPath.src-sha256"

if (-not (Test-Path -LiteralPath $Qcow2Path)) {
  Write-Error "Source qcow2 missing: $Qcow2Path. Run fetch.ps1 first."
  exit 2
}

$qemuImg = (Get-Command qemu-img.exe -ErrorAction SilentlyContinue).Source
if (-not $qemuImg) {
  $qemuImg = (Get-Command qemu-img -ErrorAction SilentlyContinue).Source
}
if (-not $qemuImg) {
  Write-Error @"
qemu-img not on PATH.

Install via:
  scoop install qemu
or:
  winget install QEMU.QEMU

Then refresh PATH in this shell:
  `$env:PATH = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
"@
  exit 3
}

$srcSha = (Get-FileHash -LiteralPath $Qcow2Path -Algorithm SHA256).Hash.ToLowerInvariant()

# Idempotent skip: VHDX present, sentinel records same source sha.
if (-not $Force -and (Test-Path -LiteralPath $VhdxPath) -and (Test-Path -LiteralPath $sentinelPath)) {
  $recorded = (Get-Content -LiteralPath $sentinelPath -Raw).Trim().ToLowerInvariant()
  if ($recorded -eq $srcSha) {
    Write-Host "[convert] VHDX already exists for source sha256=$srcSha; skipping"
    Write-Output (Resolve-Path -LiteralPath $VhdxPath).Path
    exit 0
  }
  Write-Host "[convert] stale VHDX (sentinel sha mismatch); re-converting"
}

# Remove a stale VHDX so qemu-img doesn't refuse-to-overwrite.
if (Test-Path -LiteralPath $VhdxPath) {
  Remove-Item -Force -LiteralPath $VhdxPath
}
if (Test-Path -LiteralPath $sentinelPath) {
  Remove-Item -Force -LiteralPath $sentinelPath
}

Write-Host "[convert] qemu-img convert -O vhdx -o subformat=dynamic"
Write-Host "  src: $Qcow2Path"
Write-Host "  dst: $VhdxPath"
$t0 = Get-Date
& $qemuImg convert -p -O vhdx -o 'subformat=dynamic' $Qcow2Path $VhdxPath
if ($LASTEXITCODE -ne 0) {
  Write-Error "qemu-img convert failed (rc=$LASTEXITCODE)"
  exit 4
}
$elapsed = (Get-Date) - $t0
Write-Host ("[convert] OK in {0:F1}s; vhdx size {1:F1} MiB" -f `
  $elapsed.TotalSeconds, ((Get-Item -LiteralPath $VhdxPath).Length / 1MB))

# Sentinel records the source sha256 so we can skip on re-runs.
[IO.File]::WriteAllText($sentinelPath, "$srcSha`n", [Text.UTF8Encoding]::new($false))

Write-Output (Resolve-Path -LiteralPath $VhdxPath).Path
