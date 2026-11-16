Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-clingo.ps1 — provision the clingo ASP solver's Windows shared library.
#
# `repro` and every helper binary reprobuild compiles for itself (the
# interface-extract runner, the project provider) link `repro_solver`, whose
# `{.dynlib: "clingo.dll".}` FFI in
# `libs/repro_solver/src/repro_solver/clingo_bindings.nim` is resolved EAGERLY
# at module-init time. Without `clingo.dll` on the DLL search path the process
# aborts before `main` with `could not load: clingo.dll` — there is no
# degraded mode.
#
# On Linux/macOS the flake devShell supplies clingo (`flake.nix`, `pkgs.clingo`).
# Windows has no such source, which is why this script exists: it is the
# Windows counterpart of that flake input, and it is what makes
# `scripts/build_apps.sh`'s staging step able to put `clingo.dll` next to
# `repro.exe` in a release build.
#
# It is sourced by this repo's `env.ps1` after the cold-start toolchain
# bootstrap (windows/bootstrap-toolchain.ps1).
#
# Why the conda-forge package: potassco/clingo's GitHub releases ship source
# tarballs only — no prebuilt Windows binaries — and the PyPI wheel statically
# links the C library into `_clingo.cp312-win_amd64.pyd`, hiding it behind a
# Python entry point. conda-forge's package bundles a standalone
# `Library\bin\clingo.dll` next to the CLI tools: a plain C library, ABI-stable
# across the `pyXXX` build variants (the suffix only affects the bundled
# `_clingo.cpython-XXX.pyd`, which we discard).
#
# Package format: a `.conda` file is a ZIP holding two `.tar.zst` payloads
# (`info-*` and `pkg-*`). Expand the outer ZIP, then decompress the `pkg-`
# payload with the Windows-bundled `tar.exe` (Win10 22H2+ handles .zst
# natively). This mirrors the provisioning proven in
# `infra/machines/server/_windows-runner-001/system_windows_runner.nim`, with
# one deliberate difference: nothing is copied into `C:\Windows\System32` and
# no machine-wide PATH entry is created. Both of those are what let a missing
# `clingo.dll` in a release archive go undetected — see `scripts/verify_release.sh`.
# ─────────────────────────────────────────────────────────────────────────────

function Get-ClingoInstallDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Version
  )
  return (Join-Path $Root "clingo/$Version")
}

function Ensure-ClingoWindowsArm64 {
  ## windows-aarch64: the producer-built clingo (reprobuild-pm
  ## Distribution-And-Packaging.md §7.1, W3; windows/build-clingo-windows-arm64.ps1
  ## and .github/workflows/clingo-windows-arm64.yml). A ZIP with one top-level
  ## directory holding clingo.dll, clingo.exe, clingo.h, LICENSE.md and
  ## BUILDINFO.txt; built with llvm-mingw -static, so it needs no runtime DLL.
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["CLINGO_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "ensure-clingo: CLINGO_VERSION is missing from windows/toolchain-versions.env."
  }
  $url = Get-ToolchainArchPin -Toolchain $Toolchain -Arch "arm64" `
    -X64Key "CLINGO_URL" -Arm64Key "CLINGO_WIN_ARM64_URL" -Consumer "ensure-clingo"
  $expectedSha = Get-ToolchainArchPin -Toolchain $Toolchain -Arch "arm64" `
    -X64Key "CLINGO_SHA256" -Arm64Key "CLINGO_WIN_ARM64_SHA256" -Consumer "ensure-clingo"
  $assetName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
  if ($assetName -notmatch ("^clingo-" + [regex]::Escape($version) + "-windows-arm64-[0-9a-f]{12}\.zip$")) {
    throw ("ensure-clingo: CLINGO_WIN_ARM64_URL names '$assetName', which is not a " +
           "windows-arm64 build of CLINGO_VERSION $version. The two legs share one " +
           "clingo version.")
  }

  $installDir = Get-ClingoInstallDir -Root $Root -Version $version
  $clingoDll = Join-Path $installDir "clingo.dll"
  $installMetaFile = Join-Path $installDir "clingo.install.meta"
  $expectedMetadata = @{
    clingo_version = $version
    clingo_arch = "arm64"
    clingo_asset = $assetName
    clingo_archive_sha256 = $expectedSha.ToLowerInvariant()
  }
  if ((Test-Path -LiteralPath $clingoDll -PathType Leaf) -and
      (Test-Path -LiteralPath $installMetaFile -PathType Leaf) -and
      (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual (Read-KeyValueFile -Path $installMetaFile))) {
    Assert-PeMachine -Path $clingoDll -Arch "arm64" -Consumer "ensure-clingo"
    Write-Host "clingo $version (arm64) already installed at $installDir"
    return $installDir
  }

  $cacheDir = Join-Path $Root "clingo/_downloads"
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
    Write-Host "Downloading clingo $version for arm64 ($assetName)..."
    Download-File -Url $url -OutFile $archivePath
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  }

  $staging = Join-Path $cacheDir "staging-$version-arm64"
  Ensure-CleanDirectory -Path $staging
  try {
    Expand-ZipArchive -ArchivePath $archivePath -Destination $staging
    $top = Join-Path $staging ([IO.Path]::GetFileNameWithoutExtension($assetName))
    foreach ($member in @("clingo.dll", "clingo.exe")) {
      $path = Join-Path $top $member
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "ensure-clingo: '$assetName' has no $member under its top-level directory."
      }
      Assert-PeMachine -Path $path -Arch "arm64" -Consumer "ensure-clingo"
    }
    Ensure-CleanDirectory -Path $installDir
    Copy-Item -Path (Join-Path $top "*") -Destination $installDir -Recurse -Force
    Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  } finally {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Write-Host "Installed clingo $version (arm64) at $installDir"
  return $installDir
}

function Ensure-Clingo {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  if ($Arch -eq "arm64") {
    return (Ensure-ClingoWindowsArm64 -Root $Root -Toolchain $Toolchain)
  }

  $version = $Toolchain["CLINGO_VERSION"]
  $buildString = $Toolchain["CLINGO_BUILD_STRING"]
  $expectedSha = $Toolchain["CLINGO_SHA256"]

  foreach ($pair in @(
    @{ name = "CLINGO_VERSION"; value = $version },
    @{ name = "CLINGO_BUILD_STRING"; value = $buildString },
    @{ name = "CLINGO_SHA256"; value = $expectedSha }
  )) {
    if ([string]::IsNullOrWhiteSpace($pair.value)) {
      throw "ensure-clingo: $($pair.name) is missing from windows/toolchain-versions.env."
    }
  }

  # conda-forge publishes clingo for `win-64` only; arm64 returned above with
  # the producer-built DLL. Any other arch is refused rather than handed an x64
  # clingo.dll that its repro.exe could not load.
  if ($Arch -ne "x64") {
    throw ("ensure-clingo: no clingo is pinned for Windows architecture " +
           "'$Arch' (x64: conda-forge win-64; arm64: CLINGO_WIN_ARM64_*).")
  }

  $assetName = "clingo-$version-$buildString.conda"
  $assetUrl = ("https://anaconda.org/conda-forge/clingo/$version" +
               "/download/win-64/$assetName")

  $installDir = Get-ClingoInstallDir -Root $Root -Version $version
  $clingoDll = Join-Path $installDir "clingo.dll"
  $installMetaFile = Join-Path $installDir "clingo.install.meta"

  $expectedMetadata = @{
    clingo_version = $version
    clingo_build_string = $buildString
    clingo_archive_sha256 = $expectedSha.ToLowerInvariant()
  }

  # Idempotence: the marker DLL plus a metadata match. Re-provision whenever
  # the pin moves so a version bump is not silently ignored on a host that
  # already has the old DLL.
  if ((Test-Path -LiteralPath $clingoDll -PathType Leaf) -and
      (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      Write-Host "clingo $version already installed at $installDir"
      return $installDir
    }
  }

  $cacheDir = Join-Path $Root "clingo/_downloads"
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
    Write-Host "Downloading clingo $version ($assetName)..."
    Download-File -Url $assetUrl -OutFile $archivePath
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  }

  # A .conda file is a zip; Expand-ZipArchive reads it under its own name.
  $staging = Join-Path $cacheDir "staging-$version"
  Ensure-CleanDirectory -Path $staging
  try {
    Expand-ZipArchive -ArchivePath $archivePath -Destination $staging

    $pkgZst = Get-ChildItem -LiteralPath $staging -Filter "pkg-*.tar.zst" |
      Select-Object -First 1
    if ($null -eq $pkgZst) {
      throw "ensure-clingo: no pkg-*.tar.zst payload inside '$assetName'."
    }

    $pkgOut = Join-Path $staging "pkg"
    New-Item -ItemType Directory -Force -Path $pkgOut | Out-Null
    $tarExe = Get-WindowsTarExe
    & $tarExe -xf $pkgZst.FullName -C $pkgOut | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "ensure-clingo: tar.exe failed with exit code $LASTEXITCODE while extracting '$($pkgZst.Name)'."
    }

    $srcBin = Join-Path $pkgOut "Library/bin"
    $srcDll = Join-Path $srcBin "clingo.dll"
    if (-not (Test-Path -LiteralPath $srcDll -PathType Leaf)) {
      throw "ensure-clingo: clingo.dll not found at '$srcDll' in the extracted package."
    }

    Ensure-CleanDirectory -Path $installDir
    # `Library\bin` also carries clingo.exe / gringo.exe / clasp.exe. Keep them:
    # `scripts/build_apps.sh` locates the DLL by way of `command -v clingo.exe`,
    # and the CLI tools are useful for debugging solver output by hand.
    Copy-Item -Path (Join-Path $srcBin "*") -Destination $installDir -Recurse -Force

    if (-not (Test-Path -LiteralPath $clingoDll -PathType Leaf)) {
      throw "ensure-clingo: install completed but '$clingoDll' is missing."
    }

    Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  } finally {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
  }

  Write-Host "Installed clingo $version at $installDir"
  return $installDir
}
