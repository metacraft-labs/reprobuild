# package_windows_release.ps1 -- assemble the Windows release archive tree.
#
# Usage (from the reprobuild checkout root, after the build):
#
#   ./scripts/release/package_windows_release.ps1 [-OutDir <dir>] [-Zip]
#       [-Platform windows] [-Arch x86_64]
#
# Produces <OutDir>\reprobuild-<version>-<platform>-<arch>\ holding
#
#   bin\     build\bin\* (repro.exe, reprobuild.exe, the other images and the
#            runtime DLLs windows\stage-release-dlls.ps1 stages beside them)
#   lib\     build\lib\*
#   share\repro\{source,src,reprobuild-packages}
#            the sources an installed reprobuild compiles against, staged by
#            scripts/release/stage_release_sources.sh
#
# and, with -Zip, <OutDir>\reprobuild-<version>-<platform>-<arch>.zip whose one
# top-level entry is that directory. Prints the package directory, then the
# zip path when one was made, one per line, as its only output.
#
# WHY ONE SCRIPT. These steps were inline in .github/workflows/release.yml.
# The Gradual-Nix-To-Reprobuild-Migration GM1w gate
# (tests/e2e/m83/t_e2e_windows_bundle_compiles_profile.nim) has to test the
# archive the release ships, not a layout of its own invention, so the release
# job and the test both run THIS script. A packaging change that only one of
# them saw would make the test prove something about a different archive.
#
# Requires the reprobuild Windows environment (`. .\env.ps1`, or the release
# job's equivalent): stage-release-dlls.ps1 reads the toolchain locations it
# exports, and stage_release_sources.sh resolves the source-only inputs from
# the variables it sets and the sibling checkouts beside this repository.
# Windows PowerShell 5.1 compatible.

param(
  [string]$OutDir = "",
  [string]$Platform = "windows",
  [string]$Arch = "x86_64",
  [switch]$Zip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Get-Location).Path
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "reprobuild.nimble")) -or
    -not (Test-Path -LiteralPath (Join-Path $repoRoot "libs\repro_project_dsl\src\repro_project_dsl.nim"))) {
  throw "package_windows_release: run from the reprobuild checkout root (cwd is $repoRoot)"
}
foreach ($required in @("build\bin\repro.exe", "build\bin\reprobuild.exe")) {
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required))) {
    throw "package_windows_release: $required is missing; build first (bash ./scripts/build_apps.sh)"
  }
}
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = $repoRoot }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# Git for Windows' bash, never the WSL launcher: the shared resolution in
# windows\toolchain-utils.ps1 (the release job used a `shell: bash` step for
# the same reason).
. (Join-Path $repoRoot "windows\toolchain-utils.ps1")
$bash = Resolve-UsableBashExe
if (-not $bash) {
  throw "package_windows_release: no usable bash (Git for Windows) found; stage_release_sources.sh cannot run"
}

# Every non-system DLL the images load must sit beside them in bin\ --
# Win32 LoadLibrary searches the exe's own directory first and PATH last.
# Writes into build\bin, which is what the release has always packaged.
& (Join-Path $repoRoot "windows\stage-release-dlls.ps1") | Out-Host

$versionMatch = Select-String -LiteralPath (Join-Path $repoRoot "reprobuild.nimble") `
  -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1
if ($null -eq $versionMatch) {
  throw "package_windows_release: no version line in reprobuild.nimble"
}
$version = $versionMatch.Matches[0].Groups[1].Value
$pkgName = "reprobuild-$version-$Platform-$Arch"
$pkgDir = Join-Path $OutDir $pkgName

if (Test-Path -LiteralPath $pkgDir) {
  Remove-Item -LiteralPath $pkgDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $pkgDir "bin") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkgDir "lib") | Out-Null
Copy-Item -Path (Join-Path $repoRoot "build\bin\*") -Destination (Join-Path $pkgDir "bin") -Recurse
$libSrc = Join-Path $repoRoot "build\lib"
if (Test-Path -LiteralPath $libSrc) {
  Copy-Item -Path (Join-Path $libSrc "*") -Destination (Join-Path $pkgDir "lib") -Recurse
}

# The sources an installed reprobuild compiles every project against
# (share\repro\source + share\repro\src). v0.2.0 shipped without them, and
# every `repro exec` / `dev-exec` from the unpacked zip died at its first
# compile: cannot open file: repro_interface_artifacts. The path is handed to
# bash with forward slashes, which Git for Windows' bash accepts as-is.
& $bash ./scripts/release/stage_release_sources.sh ($pkgDir -replace '\\', '/') | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "package_windows_release: stage_release_sources.sh failed (exit $LASTEXITCODE)"
}

Write-Output $pkgDir
if ($Zip) {
  $zipPath = Join-Path $OutDir "$pkgName.zip"
  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -LiteralPath $pkgDir -DestinationPath $zipPath -Force
  Write-Output $zipPath
}
