Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Gcc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["GCC_VERSION"]
  $gccRoot = Join-Path $Root "gcc/$version"
  $gccBinDir = Join-Path $gccRoot "bin"
  $gccExe = Join-Path $gccBinDir "gcc.exe"

  if (Test-Path -LiteralPath $gccExe -PathType Leaf) {
    $currentVersion = ""
    try {
      $versionOutput = & $gccExe --version 2>&1 | Select-Object -First 1
      if ($versionOutput -match '([0-9]+\.[0-9]+\.[0-9]+)') {
        $currentVersion = $Matches[1]
      }
    } catch {}

    if ($currentVersion -eq $version) {
      Write-Host "gcc $version already installed at $gccRoot"
      return
    }
  }

  # Locate the WinLibs installation from winget.
  $winlibsPackageDir = ""
  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $wingetRoot = Join-Path $localAppData "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot -PathType Container) {
      $candidate = Get-ChildItem -LiteralPath $wingetRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
        Select-Object -First 1
      if ($null -ne $candidate) {
        $mingw64 = Join-Path $candidate.FullName "mingw64"
        if (Test-Path -LiteralPath $mingw64 -PathType Container) {
          $winlibsPackageDir = $mingw64
        }
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
    # Try installing via winget.
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
      throw "WinLibs GCC is not installed and winget is not available. Install WinLibs manually or via: winget install BrechtSanders.WinLibs.POSIX.UCRT"
    }

    Write-Host "Installing WinLibs (GCC $version) via winget..."
    & winget install BrechtSanders.WinLibs.POSIX.UCRT --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install WinLibs via winget."
    }

    $candidate = Get-ChildItem -LiteralPath (Join-Path $localAppData "Microsoft\WinGet\Packages") -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "BrechtSanders.WinLibs.POSIX.UCRT*" } |
      Select-Object -First 1
    if ($null -ne $candidate) {
      $mingw64 = Join-Path $candidate.FullName "mingw64"
      if (Test-Path -LiteralPath $mingw64 -PathType Container) {
        $winlibsPackageDir = $mingw64
      }
    }

    if ([string]::IsNullOrWhiteSpace($winlibsPackageDir)) {
      throw "WinLibs winget install completed but could not locate the mingw64 directory."
    }
  }

  # Create a junction from the managed install root to the WinLibs directory.
  $parentDir = Split-Path -Parent $gccRoot
  New-Item -ItemType Directory -Force -Path $parentDir | Out-Null

  if (Test-Path -LiteralPath $gccRoot) {
    Remove-Item -LiteralPath $gccRoot -Recurse -Force
  }
  New-Item -ItemType Junction -Path $gccRoot -Target $winlibsPackageDir | Out-Null

  $gccExeCheck = Join-Path $gccBinDir "gcc.exe"
  if (-not (Test-Path -LiteralPath $gccExeCheck -PathType Leaf)) {
    throw "WinLibs junction created at '$gccRoot' but gcc.exe not found at '$gccExeCheck'."
  }

  Write-Host "Installed GCC $version (WinLibs) at $gccRoot"
}
