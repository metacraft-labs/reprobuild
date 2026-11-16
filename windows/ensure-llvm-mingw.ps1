Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-llvm-mingw.ps1 -- provision the pinned llvm-mingw toolchain, the
# windows-aarch64 C compiler.
#
# reprobuild-pm spec/Distribution-And-Packaging.md §7.1, decision W1 (approved
# by Zahary Karadjov, 2026-11-16): no maintained Windows-on-Arm-hosted GCC
# exists, so the native arm64 leg builds with llvm-mingw
# (https://github.com/mstorsjo/llvm-mingw), aarch64-hosted, UCRT. x64 keeps
# the WinLibs GCC of ensure-gcc.ps1.
#
# The toolchain is recorded as itself, `llvm-mingw@<release>`, never as gcc.
# It ships `gcc.exe`/`cc.exe` driver names (clang target wrappers), so Nim's
# default `--cc:gcc` and every gcc-spelled build script drive it unchanged;
# what they run is clang, and nothing here pretends otherwise.
#
# Same shape as ensure-gcc.ps1: the archive is the pin (release + sha256 in
# windows/toolchain-versions.env, verified before extraction), and the
# installed tree must prove itself -- an ARM64 compiler image, a driver that
# targets aarch64-w64-windows-gnu, and provenance metadata matching the pin --
# before it is reused.
# ─────────────────────────────────────────────────────────────────────────────

function Get-LlvmMingwAssetName {
  ## The aarch64-hosted UCRT asset for a release. Only this variant: the
  ## OpenSSL/zstd DLLs of the arm64 leg are MSYS2 clangarm64 builds, which use
  ## the UCRT, and a msvcrt toolchain against them would mix C runtimes.
  param([Parameter(Mandatory = $true)][string]$Release)
  if ($Release -notmatch '^[0-9]{8}$') {
    throw "ensure-llvm-mingw: LLVM_MINGW_WIN_ARM64_RELEASE='$Release' is not an llvm-mingw release tag (YYYYMMDD)."
  }
  return "llvm-mingw-$Release-ucrt-aarch64.zip"
}

function Get-LlvmMingwInstallDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Release
  )
  return (Join-Path $Root "llvm-mingw/$Release")
}

function Get-LlvmMingwDriverTarget {
  ## The target the `gcc.exe` driver reports, or "" when it does not run.
  param([Parameter(Mandatory = $true)][string]$GccExe)
  try {
    $output = & $GccExe -dumpmachine 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { return "$output".Trim() }
  } catch {}
  return ""
}

function Test-LlvmMingwInstall {
  ## Whether $InstallDir is a complete, native, pin-matching llvm-mingw.
  param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][hashtable]$ExpectedMetadata
  )
  $gccExe = Join-Path $InstallDir "bin/gcc.exe"
  $clangExe = Join-Path $InstallDir "bin/clang.exe"
  $metaFile = Join-Path $InstallDir "llvm-mingw.install.meta"
  foreach ($path in @($gccExe, $clangExe, $metaFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  }
  if (-not (Test-KeyValueFileMatches -Expected $ExpectedMetadata -Actual (Read-KeyValueFile -Path $metaFile))) {
    return $false
  }
  return ((Get-LlvmMingwDriverTarget -GccExe $gccExe) -eq "aarch64-w64-windows-gnu")
}

function Ensure-LlvmMingw {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  if ($Arch -ne "arm64") {
    throw ("ensure-llvm-mingw: llvm-mingw is the windows-aarch64 C toolchain; " +
           "this host resolved to '$Arch', whose C toolchain is the WinLibs GCC " +
           "of ensure-gcc.ps1.")
  }
  $release = Get-ToolchainArchPin -Toolchain $Toolchain -Arch $Arch `
    -X64Key "LLVM_MINGW_RELEASE" -Arm64Key "LLVM_MINGW_WIN_ARM64_RELEASE" -Consumer "ensure-llvm-mingw"
  $expectedSha = Get-ToolchainArchPin -Toolchain $Toolchain -Arch $Arch `
    -X64Key "LLVM_MINGW_SHA256" -Arm64Key "LLVM_MINGW_WIN_ARM64_SHA256" -Consumer "ensure-llvm-mingw"

  $assetName = Get-LlvmMingwAssetName -Release $release
  $assetUrl = "https://github.com/mstorsjo/llvm-mingw/releases/download/$release/$assetName"
  $installDir = Get-LlvmMingwInstallDir -Root $Root -Release $release
  $expectedMetadata = @{
    llvm_mingw_release = $release
    llvm_mingw_asset = $assetName
    llvm_mingw_archive_sha256 = $expectedSha.ToLowerInvariant()
  }

  if (Test-LlvmMingwInstall -InstallDir $installDir -ExpectedMetadata $expectedMetadata) {
    Assert-PeMachine -Path (Join-Path $installDir "bin/clang.exe") -Arch $Arch -Consumer "ensure-llvm-mingw"
    Write-Host "llvm-mingw $release already installed at $installDir"
    return $installDir
  }

  $cacheDir = Join-Path $Root "llvm-mingw/_downloads"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $archivePath = Join-Path $cacheDir $assetName
  $haveCachedArchive = $false
  if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    try {
      Assert-FileSha256 -Path $archivePath -Expected $expectedSha
      $haveCachedArchive = $true
    } catch {
      Remove-Item -LiteralPath $archivePath -Force
    }
  }
  if (-not $haveCachedArchive) {
    Write-Host "Downloading llvm-mingw $release ($assetName)..."
    Download-File -Url $assetUrl -OutFile $archivePath
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  }

  # Staging is a sibling of the install directory so the install is a rename,
  # not a copy of ~10k files, and extracted paths stay short.
  $staging = Join-Path $Root "llvm-mingw/_staging"
  Ensure-CleanDirectory -Path $staging
  try {
    $extracted = $false
    try {
      $tarExe = Get-WindowsTarExe
      & $tarExe -xf $archivePath -C $staging | Out-Host
      $extracted = ($LASTEXITCODE -eq 0)
    } catch {
      $extracted = $false
    }
    if (-not $extracted) {
      Write-Host "tar.exe could not read the archive; falling back to .NET's zip reader..."
      Ensure-CleanDirectory -Path $staging
      Expand-ZipArchive -ArchivePath $archivePath -Destination $staging
    }

    # The archive carries one top-level directory named after the asset.
    $prefixDir = Join-Path $staging ([IO.Path]::GetFileNameWithoutExtension($assetName))
    if (-not (Test-Path -LiteralPath (Join-Path $prefixDir "bin/gcc.exe") -PathType Leaf)) {
      throw ("ensure-llvm-mingw: '$assetName' does not hold " +
             "'$([IO.Path]::GetFileNameWithoutExtension($assetName))/bin/gcc.exe'. " +
             "The asset layout changed; re-check the pin.")
    }

    if (Test-Path -LiteralPath $installDir) {
      Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installDir) | Out-Null
    Move-Item -LiteralPath $prefixDir -Destination $installDir

    # Native, not emulated: the compiler image itself must be ARM64.
    Assert-PeMachine -Path (Join-Path $installDir "bin/clang.exe") -Arch $Arch -Consumer "ensure-llvm-mingw"
    $target = Get-LlvmMingwDriverTarget -GccExe (Join-Path $installDir "bin/gcc.exe")
    if ($target -ne "aarch64-w64-windows-gnu") {
      throw ("ensure-llvm-mingw: the installed gcc.exe driver targets '$target', " +
             "not aarch64-w64-windows-gnu.")
    }
    Write-KeyValueFile -Path (Join-Path $installDir "llvm-mingw.install.meta") -Values $expectedMetadata
  } finally {
    # Best-effort for the reason ensure-gcc.ps1 gives: a failing cleanup must
    # not replace the real error.
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Host "Installed llvm-mingw $release at $installDir"
  return $installDir
}
