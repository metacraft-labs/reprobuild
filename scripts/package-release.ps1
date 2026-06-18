# package-release.ps1 — Windows-native packaging entrypoint.
#
# Mirrors scripts/package-release.sh but emits a .zip archive using
# PowerShell's built-in Compress-Archive (no MSYS dependency). Designed
# to run on `windows-latest` in .github/workflows/release.yml.
#
# Usage:
#   pwsh -File scripts/package-release.ps1 -Version 1.4.0 -OutDir dist
#
# Required:
#   -Version  <ver>     Release version (e.g. 1.4.0, 0.0.1-dev).
#   -OutDir   <dir>     Destination directory for the .zip + .sha256.
# Optional:
#   -Triple   <triple>  Defaults to "x86_64-pc-windows-msvc".
#   -BuildDir <dir>     Directory holding bin/ and lib/ (default ./build).
#   -RepoRoot <dir>     Reprobuild source root (default cwd).

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Triple   = "x86_64-pc-windows-msvc",
  [string]$BuildDir = "",
  [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

# Strip a leading `v` so `v1.4.0` and `1.4.0` both work.
$Version = $Version -replace '^v', ''

if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$BinDir = Join-Path $BuildDir 'bin'
if (-not (Test-Path $BinDir)) {
  throw "package-release.ps1: $BinDir does not exist; run 'just build' first"
}

$StageName = "reprobuild-$Version-$Triple"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$StageDir = Join-Path $OutDir $StageName
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir 'lib') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $StageDir 'docs') | Out-Null

Write-Host "staging $StageDir"

# bin/ — copy everything from build/bin (includes clingo.dll on Windows).
Copy-Item -Recurse -Force -Path (Join-Path $BinDir '*') `
  -Destination (Join-Path $StageDir 'bin')

# lib/ — copy artefacts excluding *.old.* backups (build_apps.sh keeps a
# rolling backup of the monitor-shim DLL).
$LibDir = Join-Path $BuildDir 'lib'
if (Test-Path $LibDir) {
  Get-ChildItem -File -Path $LibDir |
    Where-Object { $_.Name -notlike '*.old.*' } |
    ForEach-Object {
      Copy-Item -Force -Path $_.FullName `
        -Destination (Join-Path $StageDir 'lib')
    }
}

# Top-level metadata.
foreach ($f in @('README.md', 'LICENSE')) {
  $src = Join-Path $RepoRoot $f
  if (Test-Path $src) {
    Copy-Item -Force -Path $src -Destination (Join-Path $StageDir $f)
  } else {
    Write-Warning "package-release.ps1: $src is missing"
  }
}

$PackagingDoc = Join-Path $RepoRoot 'docs\PACKAGING.md'
if (Test-Path $PackagingDoc) {
  Copy-Item -Force -Path $PackagingDoc `
    -Destination (Join-Path $StageDir 'docs\PACKAGING.md')
}

Set-Content -Encoding ASCII -Path (Join-Path $StageDir 'VERSION') -Value @(
  "reprobuild $Version",
  "triple $Triple"
)

# --- Archive ---------------------------------------------------------------
$ArchivePath = Join-Path $OutDir "$StageName.zip"
if (Test-Path $ArchivePath) { Remove-Item -Force $ArchivePath }

Write-Host "building $ArchivePath"
Compress-Archive -Path $StageDir -DestinationPath $ArchivePath -Force

# --- Checksum --------------------------------------------------------------
$ShaPath = "$ArchivePath.sha256"
$hash = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLower()
$ZipName = Split-Path -Leaf $ArchivePath
Set-Content -Encoding ASCII -Path $ShaPath -Value "$hash  $ZipName"

Write-Host "wrote $ArchivePath"
Write-Host "wrote $ShaPath"

# Emit step outputs for the release workflow.
if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Value "archive_path=$ArchivePath"
  Add-Content -Path $env:GITHUB_OUTPUT -Value "sha256_path=$ShaPath"
  Add-Content -Path $env:GITHUB_OUTPUT -Value "stage_name=$StageName"
  Add-Content -Path $env:GITHUB_OUTPUT -Value "triple=$Triple"
}
