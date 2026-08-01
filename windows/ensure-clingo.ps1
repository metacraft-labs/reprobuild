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
# This lives in reprobuild rather than the shared repo-workspaces framework
# because clingo is a reprobuild-specific dependency — repo-workspaces owns the
# generic toolchain (nim, gcc, just, gh, python, git-repo, gpg). It is sourced
# by this repo's `env.ps1` after the framework bootstrap.
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

function Ensure-Clingo {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

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

  # conda-forge publishes clingo for `win-64` only. A native ARM64 `repro.exe`
  # cannot load an x64 `clingo.dll` — the loader rejects the machine type — so
  # fail loudly instead of installing a DLL that will abort at module init.
  # (x64 repro.exe running under ARM64 emulation is a different case and is
  # served by the win-64 package; set WINDOWS_DIY_ARCH_OVERRIDE=x64 for that.)
  if ($Arch -ne "x64") {
    throw ("ensure-clingo: conda-forge publishes clingo for win-64 only, but " +
           "this host resolved to '$Arch'. A native ARM64 repro.exe cannot " +
           "load an x64 clingo.dll. Build clingo from source for ARM64, or " +
           "set WINDOWS_DIY_ARCH_OVERRIDE=x64 when targeting an emulated x64 " +
           "toolchain.")
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

  # Expand-Archive only accepts a `.zip` extension, so stage a renamed copy.
  $staging = Join-Path $cacheDir "staging-$version"
  Ensure-CleanDirectory -Path $staging
  try {
    $zipPath = Join-Path $staging "clingo.zip"
    Copy-Item -LiteralPath $archivePath -Destination $zipPath -Force
    Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force

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
