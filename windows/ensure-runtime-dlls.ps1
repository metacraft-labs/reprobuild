Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-runtime-dlls.ps1 -- the windows-aarch64 sqlite and zstd runtime DLLs.
#
# reprobuild-pm spec/Distribution-And-Packaging.md §7.1, W4 (approved by
# Zahary Karadjov, 2026-11-16). On x64 these DLLs come with tools the cold
# start installs anyway: sqlite3_64.dll ships in the official Nim zip and
# libzstd.dll in the WinLibs gcc tree. Neither the arm64 Nim prefix nor
# llvm-mingw carries them, so on arm64 they are their own pinned inputs:
#
#   * sqlite.org's arm64 DLL (SQLITE_WIN_ARM64_*), which imports only
#     KERNEL32.dll, installed under both names Nim's binding tries
#     (sqlite3_64.dll, sqlite3.dll);
#   * MSYS2 clangarm64's zstd (ZSTD_WIN_ARM64_*), the same environment and CRT
#     as the arm64 OpenSSL.
#
# Without them every image that links repro_local_store aborts at start-up
# with `could not load: (sqlite3_64|sqlite3|sqlite3_32).dll` -- measured on the
# hosted Windows 11 Arm image, 2026-11-16. The install directory goes on PATH
# (env.ps1) and is what scripts/build_apps.sh and stage-release-dlls.ps1 stage
# from, so a release and a dev build carry the same bytes.
# ─────────────────────────────────────────────────────────────────────────────

function Get-WindowsRuntimeDllDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )
  return (Join-Path $Root ("runtime-dlls/arm64-sqlite-" + $Toolchain["SQLITE_WIN_ARM64_VERSION"] +
    "-zstd-" + $Toolchain["ZSTD_WIN_ARM64_VERSION"] + "-" + $Toolchain["ZSTD_WIN_ARM64_MSYS2_RELEASE"]))
}

function Get-WindowsRuntimeDllMetadata {
  param([Parameter(Mandatory = $true)][hashtable]$Toolchain)
  return @{
    sqlite_version = $Toolchain["SQLITE_WIN_ARM64_VERSION"]
    sqlite_archive_sha256 = $Toolchain["SQLITE_WIN_ARM64_ARCHIVE_SHA256"].ToLowerInvariant()
    zstd_version = $Toolchain["ZSTD_WIN_ARM64_VERSION"]
    zstd_msys2_release = $Toolchain["ZSTD_WIN_ARM64_MSYS2_RELEASE"]
    zstd_archive_sha256 = $Toolchain["ZSTD_WIN_ARM64_SHA256"].ToLowerInvariant()
  }
}

function Ensure-WindowsRuntimeDlls {
  ## Install the arm64 sqlite and zstd DLLs and return their directory. On x64
  ## there is nothing to install (see the header) and the result is "".
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )
  if ($Arch -ne "arm64") { return "" }

  foreach ($key in @("SQLITE_WIN_ARM64_VERSION", "SQLITE_WIN_ARM64_ARCHIVE_PATH",
                     "SQLITE_WIN_ARM64_ARCHIVE_SHA256", "ZSTD_WIN_ARM64_VERSION",
                     "ZSTD_WIN_ARM64_MSYS2_RELEASE", "ZSTD_WIN_ARM64_SHA256")) {
    if ([string]::IsNullOrWhiteSpace($Toolchain[$key])) {
      throw "ensure-runtime-dlls: $key is missing from windows/toolchain-versions.env."
    }
  }
  $installDir = Get-WindowsRuntimeDllDir -Root $Root -Toolchain $Toolchain
  $metaFile = Join-Path $installDir "runtime-dlls.install.meta"
  $expected = Get-WindowsRuntimeDllMetadata -Toolchain $Toolchain
  $members = @("sqlite3_64.dll", "sqlite3.dll", "libzstd.dll")
  if ((Test-Path -LiteralPath $metaFile -PathType Leaf) -and
      (Test-KeyValueFileMatches -Expected $expected -Actual (Read-KeyValueFile -Path $metaFile)) -and
      @($members | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installDir $_) -PathType Leaf) }).Count -eq 0) {
    Write-Host "arm64 runtime DLLs already installed at $installDir"
    return $installDir
  }

  $cacheDir = Join-Path $Root "runtime-dlls/_downloads"
  $staging = Join-Path $Root "runtime-dlls/_staging"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  Ensure-CleanDirectory -Path $staging
  try {
    $names = Get-WindowsArchRuntimeNames -Arch arm64

    $sqliteZip = Join-Path $cacheDir ([IO.Path]::GetFileName($Toolchain["SQLITE_WIN_ARM64_ARCHIVE_PATH"]))
    if (-not (Test-Path -LiteralPath $sqliteZip -PathType Leaf)) {
      Download-File -Url ("https://www.sqlite.org/" + $Toolchain["SQLITE_WIN_ARM64_ARCHIVE_PATH"]) -OutFile $sqliteZip
    }
    Assert-FileSha256 -Path $sqliteZip -Expected $Toolchain["SQLITE_WIN_ARM64_ARCHIVE_SHA256"]
    $sqliteOut = Join-Path $staging "sqlite"
    Expand-ZipArchive -ArchivePath $sqliteZip -Destination $sqliteOut
    $sqliteDll = Join-Path $sqliteOut "sqlite3.dll"
    Assert-PeMachine -Path $sqliteDll -Arch arm64 -Consumer "ensure-runtime-dlls"

    $zstdAsset = "$($names.Msys2PackagePrefix)-zstd-$($Toolchain['ZSTD_WIN_ARM64_VERSION'])-$($Toolchain['ZSTD_WIN_ARM64_MSYS2_RELEASE'])-any.pkg.tar.zst"
    $zstdPkg = Join-Path $cacheDir $zstdAsset
    if (-not (Test-Path -LiteralPath $zstdPkg -PathType Leaf)) {
      Download-File -Url "https://repo.msys2.org/mingw/$($names.Msys2Env)/$zstdAsset" -OutFile $zstdPkg
    }
    Assert-FileSha256 -Path $zstdPkg -Expected $Toolchain["ZSTD_WIN_ARM64_SHA256"]
    $zstdOut = Join-Path $staging "zstd"
    New-Item -ItemType Directory -Force -Path $zstdOut | Out-Null
    & (Get-WindowsTarExe) -xf $zstdPkg -C $zstdOut | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "ensure-runtime-dlls: tar.exe failed extracting $zstdAsset (exit $LASTEXITCODE)" }
    $zstdDll = Join-Path $zstdOut "$($names.Msys2Env)/bin/libzstd.dll"
    Assert-PeMachine -Path $zstdDll -Arch arm64 -Consumer "ensure-runtime-dlls"

    Ensure-CleanDirectory -Path $installDir
    Copy-Item -LiteralPath $sqliteDll -Destination (Join-Path $installDir "sqlite3_64.dll")
    Copy-Item -LiteralPath $sqliteDll -Destination (Join-Path $installDir "sqlite3.dll")
    Copy-Item -LiteralPath $zstdDll -Destination (Join-Path $installDir "libzstd.dll")
    Write-KeyValueFile -Path $metaFile -Values $expected
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host "Installed arm64 runtime DLLs at $installDir"
  return $installDir
}
