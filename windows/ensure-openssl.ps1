Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-openssl.ps1 — provision OpenSSL's LINK-TIME artefacts (import
# libraries, headers, runtime DLLs) for the Windows dev environment.
#
# Why this exists
# ---------------
# Three app entry points are compiled with `--define:ssl` — `repro`,
# `repro-binary-cache` and `repro-harvest-apt` (the last talks HTTPS to
# snapshot.debian.org). For any such entry point the builtin catalog's nim
# typed-tool appends the PORTABLE linker names `-lssl -lcrypto`
# (`libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/nim.nim`,
# `opensslPassLForSsl`) and DELIBERATELY does not bake a search path into
# them: `libs/repro_dsl_stdlib/tests/t_nim_ssl_dependency.nim` asserts that an
# ambient path never leaks into `passL`, which is what keeps the catalog
# hermetic and its actions reproducible.
#
# That design makes supplying the search directory the TOOLCHAIN
# ENVIRONMENT's job. On Linux/macOS the flake devShell does it: OpenSSL's
# `-L/nix/store/<hash>-openssl-<ver>/lib` rides in on `NIX_LDFLAGS`. On
# Windows there was no counterpart, and the WinLibs mingw toolchain ships no
# OpenSSL of its own, so `just test` failed to build 3 of its 18 apps with
#
#     ld.exe: cannot find -lssl: No such file or directory
#     ld.exe: cannot find -lcrypto: No such file or directory
#
# — a message that reads like a broken checkout rather than a missing
# dependency. This script is the Windows counterpart of that flake input; it
# is the reason `env.ps1` can claim to provide what `just test` needs.
#
# How the search directory reaches the linker
# -------------------------------------------
# `env.ps1` exports the installed `lib` directory through `LIBRARY_PATH`, NOT
# through a `--passL`. gcc consults `LIBRARY_PATH` natively when resolving
# `-l<name>`, so this works for BOTH build routes without either of them
# knowing about it:
#
#   * `bash scripts/build_apps.sh` — the shell route, and
#   * `repro build .#apps`         — the graph route, whose actions are
#     spawned by the build engine and never see build_apps.sh's variables.
#
# A `--passL` would have had to be threaded through the catalog, which is
# exactly what the hermeticity test above forbids. Keeping the mechanism in
# the environment leaves the catalog byte-identical on every platform.
#
# Why the MSYS2 ucrt64 package
# ----------------------------
# OpenSSL publishes no prebuilt Windows artefacts for mingw, and the
# `openssl` entry in the builtin catalog is a nix-only `nixPackage` providing
# `bin/openssl` — the CLI, not the `libssl.dll.a` a linker needs. MSYS2's
# mingw-w64 build ships import libraries, static archives, headers and the
# runtime DLLs in one signed, versioned, hash-pinnable asset.
#
# It MUST be the `ucrt64` variant rather than `mingw64`: the gcc this repo
# pins is WinLibs POSIX **UCRT**. Linking a UCRT gcc against an MSVCRT-built
# libcrypto is the sort of mismatch that links cleanly and then misbehaves at
# runtime around anything touching FILE*, errno or locale — far worse than a
# link error, because nothing points back here.
#
# The package is a `.pkg.tar.zst`; the Windows-bundled `tar.exe`
# (Win10 22H2+) decompresses zstd natively, same as the clingo step. Nothing
# is installed machine-wide and no PATH entry is created outside the calling
# shell, for the same reason ensure-clingo.ps1 avoids it: a machine-wide
# install is what lets a missing dependency in a release archive go
# undetected.
# ─────────────────────────────────────────────────────────────────────────────

function Get-OpenSslInstallDir {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Version
  )
  return (Join-Path $Root "openssl/$Version")
}

function Ensure-OpenSsl {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["OPENSSL_VERSION"]
  $release = $Toolchain["OPENSSL_MSYS2_RELEASE"]
  $expectedSha = $Toolchain["OPENSSL_SHA256"]

  foreach ($pair in @(
    @{ name = "OPENSSL_VERSION"; value = $version },
    @{ name = "OPENSSL_MSYS2_RELEASE"; value = $release },
    @{ name = "OPENSSL_SHA256"; value = $expectedSha }
  )) {
    if ([string]::IsNullOrWhiteSpace($pair.value)) {
      throw "ensure-openssl: $($pair.name) is missing from windows/toolchain-versions.env."
    }
  }

  # MSYS2 publishes the ucrt64 tree for x86_64 only. Fail loudly rather than
  # installing import libraries whose machine type the linker will reject with
  # a far less obvious message than this one.
  if ($Arch -ne "x64") {
    throw ("ensure-openssl: MSYS2 publishes the ucrt64 OpenSSL package for " +
           "x86_64 only, but this host resolved to '$Arch'. Build OpenSSL " +
           "from source for ARM64, or set WINDOWS_DIY_ARCH_OVERRIDE=x64 when " +
           "targeting an emulated x64 toolchain.")
  }

  $assetName = "mingw-w64-ucrt-x86_64-openssl-$version-$release-any.pkg.tar.zst"
  $assetUrl = "https://repo.msys2.org/mingw/ucrt64/$assetName"

  $installDir = Get-OpenSslInstallDir -Root $Root -Version $version
  $libDir = Join-Path $installDir "lib"
  $binDir = Join-Path $installDir "bin"
  $includeDir = Join-Path $installDir "include"
  # The import library for libssl is the marker: it is the exact file whose
  # absence produces `cannot find -lssl`.
  $sslImportLib = Join-Path $libDir "libssl.dll.a"
  $installMetaFile = Join-Path $installDir "openssl.install.meta"

  $expectedMetadata = @{
    openssl_version = $version
    openssl_msys2_release = $release
    openssl_archive_sha256 = $expectedSha.ToLowerInvariant()
  }

  # Idempotence: marker file plus a metadata match, so a pin bump
  # re-provisions instead of being silently satisfied by the old install.
  if ((Test-Path -LiteralPath $sslImportLib -PathType Leaf) -and
      (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      Write-Host "openssl $version already installed at $installDir"
      return $installDir
    }
  }

  $cacheDir = Join-Path $Root "openssl/_downloads"
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
    Write-Host "Downloading openssl $version ($assetName)..."
    Download-File -Url $assetUrl -OutFile $archivePath
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  }

  $staging = Join-Path $cacheDir "staging-$version"
  Ensure-CleanDirectory -Path $staging
  try {
    $tarExe = Get-WindowsTarExe
    & $tarExe -xf $archivePath -C $staging | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "ensure-openssl: tar.exe failed with exit code $LASTEXITCODE while extracting '$assetName'."
    }

    # The package lays its payload out under the MSYS2 prefix it was built
    # for. Flatten that prefix away so the installed tree is a plain
    # lib/ + bin/ + include/ triple and callers never encode "ucrt64".
    $prefixDir = Join-Path $staging "ucrt64"
    if (-not (Test-Path -LiteralPath $prefixDir -PathType Container)) {
      throw ("ensure-openssl: expected a 'ucrt64' prefix inside '$assetName' " +
             "but it is not there. The asset layout changed; re-check the pin.")
    }

    foreach ($required in @("lib/libssl.dll.a", "lib/libcrypto.dll.a",
                            "include/openssl/ssl.h")) {
      $probe = Join-Path $prefixDir $required
      if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        throw "ensure-openssl: '$required' is missing from '$assetName'."
      }
    }

    Ensure-CleanDirectory -Path $installDir
    foreach ($sub in @("lib", "bin", "include")) {
      $src = Join-Path $prefixDir $sub
      if (Test-Path -LiteralPath $src -PathType Container) {
        Copy-Item -Path $src -Destination $installDir -Recurse -Force
      }
    }

    if (-not (Test-Path -LiteralPath $sslImportLib -PathType Leaf)) {
      throw "ensure-openssl: install completed but '$sslImportLib' is missing."
    }
    # The runtime DLLs are a separate failure mode from the import libraries:
    # without them every ssl binary links and then dies at startup with a
    # loader error naming libcrypto-3-x64.dll.
    foreach ($dll in @("libssl-3-x64.dll", "libcrypto-3-x64.dll")) {
      $probe = Join-Path $binDir $dll
      if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        throw ("ensure-openssl: install completed but the runtime library " +
               "'$dll' is missing from '$binDir'. Every --define:ssl binary " +
               "would link and then fail to start.")
      }
    }

    Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  } finally {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
  }

  Write-Host "Installed openssl $version at $installDir"
  return $installDir
}
