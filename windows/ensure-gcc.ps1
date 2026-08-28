Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# ensure-gcc.ps1 — provision the pinned WinLibs GCC toolchain for the Windows
# dev environment.
#
# Why this is a download and not a package-manager call
# -----------------------------------------------------
# gcc is a toolchain dependency exactly like nim, clingo or openssl, and it is
# pinned the same way they are: a version, a release tag and a sha256 in
# `windows/toolchain-versions.env`, fetched from a fixed URL and verified
# before anything is extracted. On Linux/macOS the flake devShell supplies the
# C compiler; this is that guarantee's Windows counterpart.
#
# It used to be `winget install BrechtSanders.WinLibs.POSIX.UCRT`, which failed
# both halves of that contract:
#
#   * winget accepts no version argument, so the "pin" selected nothing — it
#     installed whatever release was current and this script junctioned
#     `<root>/gcc/<pinned-version>` at it. `GCC_VERSION=15.2.0` while
#     `gcc -dumpversion` said 16.1.0 was a real observed outcome.
#   * winget is not present on every Windows host. On an ephemeral CI runner
#     (no App Installer, service account, no MSIX stack) the step raised
#     "winget is not available", which the caller downgraded to a WARNING —
#     so the environment reported itself ready with no C compiler, and the
#     first real error arrived half a minute later from a `nim c` invocation
#     as `Requested command not found: 'gcc.exe ...'`. That message names
#     neither the environment nor the missing pin.
#
# Both are gone: the archive is the pin, and provisioning either produces the
# pinned compiler or throws.
#
# Which WinLibs build, and why the release tag encodes it
# -------------------------------------------------------
# The pinned release tag has the shape `<gcc>posix-<mingw-w64>-ucrt-r<n>`, and
# `Get-WinLibsAssetName` parses it rather than trusting a hand-written file
# name. That regex is load-bearing: it structurally rejects the `msvcrt` and
# `mcf` variants of the same GCC version.
#
#   * **ucrt**, because `windows/ensure-openssl.ps1` installs the MSYS2
#     `ucrt64` OpenSSL. A UCRT gcc against an MSVCRT-built libcrypto links
#     cleanly and then misbehaves at runtime around `FILE*`, `errno` and
#     locale — strictly worse than a link error, because nothing points back
#     at the cause.
#   * **posix** threads, because Nim's `--threads:on` builds use std::thread
#     via the mingw pthreads layer.
#
# Keep the pin in step with the builtin catalog's gcc-winlibs entry
# (`libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/gcc_winlibs.nim`),
# which describes the same release declaratively for the post-bootstrap path.
# ─────────────────────────────────────────────────────────────────────────────

function Get-WinLibsAssetName {
  ## Derive the x86_64 archive name from the pinned release tag.
  ##
  ## Deriving rather than pinning the file name separately keeps one fact in
  ## one place, and makes the ucrt/posix requirement a parse failure instead
  ## of a runtime surprise: `16.1.0posix-14.0.0-msvcrt-r2` simply does not
  ## match.
  ##
  ## The `.zip` is chosen over the (smaller) `.7z` deliberately — 7-Zip is not
  ## present on a stock Windows host, and a bootstrap step may not depend on a
  ## tool the bootstrap is supposed to provide.
  param(
    [Parameter(Mandatory = $true)][string]$Release,
    [Parameter(Mandatory = $true)][string]$Version
  )

  if ($Release -notmatch '^(?<gcc>[0-9]+(\.[0-9]+)*)posix-(?<mingw>[0-9]+(\.[0-9]+)*)-ucrt-(?<rev>r[0-9]+)$') {
    throw ("ensure-gcc: GCC_WINLIBS_RELEASE='$Release' is not a POSIX/UCRT " +
           "WinLibs release tag (expected '<gcc>posix-<mingw-w64>-ucrt-r<n>'). " +
           "The msvcrt and mcf variants are rejected on purpose: the pinned " +
           "OpenSSL is the MSYS2 ucrt64 build, and mixing C runtimes links " +
           "cleanly and then misbehaves at runtime.")
  }

  if ($Matches.gcc -ne $Version) {
    throw ("ensure-gcc: GCC_VERSION pins $Version but GCC_WINLIBS_RELEASE " +
           "'$Release' carries gcc $($Matches.gcc). Bump both together.")
  }

  return "winlibs-x86_64-posix-seh-gcc-$($Matches.gcc)-mingw-w64ucrt-$($Matches.mingw)-$($Matches.rev).zip"
}

function Get-GccReportedVersion {
  ## The version the binary itself claims. Never read a gcc version off the
  ## path it happens to sit in — that is how the winget-era skew went
  ## unnoticed for months.
  param([Parameter(Mandatory = $true)][string]$GccExe)

  try {
    $versionOutput = & $GccExe --version 2>&1 | Select-Object -First 1
    if ("$versionOutput" -match '([0-9]+\.[0-9]+\.[0-9]+)') {
      return $Matches[1]
    }
  } catch {}
  return ""
}

function Expand-WinLibsArchive {
  ## Extract the WinLibs zip into $Destination.
  ##
  ## `tar.exe` (bsdtar, shipped with Windows 10 1803+) reads zip and is several
  ## times faster than `Expand-Archive` on a tree this size (~30k files).
  ## `Expand-Archive` is kept as the fallback for hosts whose bundled
  ## libarchive was built without zip support.
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $extracted = $false
  try {
    $tarExe = Get-WindowsTarExe
    & $tarExe -xf $ArchivePath -C $Destination | Out-Host
    $extracted = ($LASTEXITCODE -eq 0)
  } catch {
    $extracted = $false
  }

  if (-not $extracted) {
    Write-Host "tar.exe could not read the archive; falling back to Expand-Archive..."
    # Start from empty. A tar that failed PART WAY leaves a partial tree, and
    # `Expand-Archive -Force` overwrites what it writes but removes nothing —
    # so a stale file from the first attempt would survive into the install.
    Ensure-CleanDirectory -Path $Destination
    Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
  }
}

function Ensure-Gcc {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Arch,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $version = $Toolchain["GCC_VERSION"]
  $release = $Toolchain["GCC_WINLIBS_RELEASE"]
  $expectedSha = $Toolchain["GCC_WINLIBS_SHA256"]

  foreach ($pair in @(
    @{ name = "GCC_VERSION"; value = $version },
    @{ name = "GCC_WINLIBS_RELEASE"; value = $release },
    @{ name = "GCC_WINLIBS_SHA256"; value = $expectedSha }
  )) {
    if ([string]::IsNullOrWhiteSpace($pair.value)) {
      throw "ensure-gcc: $($pair.name) is missing from windows/toolchain-versions.env."
    }
  }

  # WinLibs publishes x86_64 and i686 builds only — there is no aarch64 mingw
  # toolchain in that project. Say so here rather than 404ing on a URL nobody
  # will recognise as the cause.
  if ($Arch -ne "x64") {
    throw ("ensure-gcc: WinLibs publishes x86_64 (and i686) builds only, but " +
           "this host resolved to '$Arch'. Provision an ARM64 C toolchain " +
           "separately, or set WINDOWS_DIY_ARCH_OVERRIDE=x64 when targeting " +
           "an emulated x64 toolchain.")
  }

  $assetName = Get-WinLibsAssetName -Release $release -Version $version
  $assetUrl = "https://github.com/brechtsanders/winlibs_mingw/releases/download/$release/$assetName"
  $shaUrl = "$assetUrl.sha256"

  $installDir = Join-Path $Root "gcc/$version"
  $gccExe = Join-Path $installDir "bin/gcc.exe"
  $installMetaFile = Join-Path $installDir "gcc.install.meta"

  $expectedMetadata = @{
    gcc_version = $version
    gcc_winlibs_release = $release
    gcc_archive_sha256 = $expectedSha.ToLowerInvariant()
  }

  # Idempotence: the binary must exist, the recorded provenance must match the
  # current pin, AND the compiler must report the pinned version. The third
  # check is what the winget path lacked — a directory named after a version
  # is not evidence of anything.
  if ((Test-Path -LiteralPath $gccExe -PathType Leaf) -and
      (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $installMetaFile
    if ((Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) -and
        ((Get-GccReportedVersion -GccExe $gccExe) -eq $version)) {
      Write-Host "gcc $version (WinLibs $release) already installed at $installDir"
      return $installDir
    }
  }

  $cacheDir = Join-Path $Root "gcc/_downloads"
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
    Write-Host "Downloading gcc $version (WinLibs $release, $assetName)..."
    Download-File -Url $assetUrl -OutFile $archivePath
    # Cross-check the pin against the checksum upstream publishes beside the
    # asset, the way ensure-nim.ps1 does: a mistyped pin then fails as a pin
    # disagreement rather than as an unexplained checksum mismatch.
    #
    # The fetch and the comparison are separated on purpose. A best-effort
    # `catch` around both would swallow the mismatch this exists to report, and
    # narrowing the catch to one exception type is guesswork across PowerShell
    # versions (5.1 raises WebException, 7 raises HttpRequestException). So:
    # an unreachable sidecar downgrades to a warning; a sidecar that disagrees
    # with the pin is fatal. Either way `Assert-FileSha256` below still holds
    # the archive to the pin — that is the check that cannot be skipped.
    $expectedFromSidecar = ""
    try {
      $shaText = Download-String -Url $shaUrl
      $expectedFromSidecar = Get-ExpectedSha256 -ShaSource $shaText -AssetName $assetName
    } catch {
      Write-Warning ("ensure-gcc: could not read '$shaUrl' for cross-checking " +
                     "($($_.Exception.Message)); verifying against the pin alone.")
    }
    if ($expectedFromSidecar -and
        ($expectedFromSidecar.ToLowerInvariant() -ne $expectedSha.ToLowerInvariant())) {
      throw ("ensure-gcc: GCC_WINLIBS_SHA256 '$expectedSha' does not match " +
             "upstream's published '$expectedFromSidecar' for '$assetName'.")
    }
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  }

  # Staging sits directly under gcc/ rather than inside the install directory:
  # the payload is ~1.5 GB across ~30k files, so the install is a rename of the
  # extracted `mingw64` tree, not a recursive copy of it. That also keeps the
  # extracted paths short enough to stay clear of MAX_PATH.
  $staging = Join-Path $Root "gcc/_staging"
  Ensure-CleanDirectory -Path $staging
  try {
    Expand-WinLibsArchive -ArchivePath $archivePath -Destination $staging

    # WinLibs archives carry a single `mingw64/` prefix. Flatten it so the
    # installed tree is a plain bin/ + lib/ + include/ triple and
    # `gcc/<version>/bin` — the directory bootstrap-toolchain.ps1 puts on PATH
    # — resolves without callers encoding "mingw64".
    $prefixDir = Join-Path $staging "mingw64"
    if (-not (Test-Path -LiteralPath $prefixDir -PathType Container)) {
      throw ("ensure-gcc: expected a 'mingw64' prefix inside '$assetName' but " +
             "it is not there. The asset layout changed; re-check the pin.")
    }
    $stagedGcc = Join-Path $prefixDir "bin/gcc.exe"
    if (-not (Test-Path -LiteralPath $stagedGcc -PathType Leaf)) {
      throw "ensure-gcc: 'bin/gcc.exe' is missing from '$assetName'."
    }

    if (Test-Path -LiteralPath $installDir) {
      Remove-Item -LiteralPath $installDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installDir) | Out-Null
    Move-Item -LiteralPath $prefixDir -Destination $installDir

    if (-not (Test-Path -LiteralPath $gccExe -PathType Leaf)) {
      throw "ensure-gcc: install completed but '$gccExe' is missing."
    }

    # The linker is a separate failure mode from the compiler driver: without
    # it every build gets through the compile stage and dies in a link step
    # that names no toolchain.
    $ldExe = Join-Path $installDir "bin/ld.exe"
    if (-not (Test-Path -LiteralPath $ldExe -PathType Leaf)) {
      throw "ensure-gcc: install completed but the linker '$ldExe' is missing."
    }

    $installedVersion = Get-GccReportedVersion -GccExe $gccExe
    if ($installedVersion -ne $version) {
      $reported = if ($installedVersion) { $installedVersion } else { "unknown" }
      throw ("ensure-gcc: GCC_VERSION pins $version but the WinLibs release " +
             "'$release' installed a compiler reporting $reported. Fix the " +
             "pins in windows/toolchain-versions.env — and keep them in step " +
             "with the gcc-winlibs entry in the builtin catalog, " +
             "libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/gcc_winlibs.nim.")
    }

    Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  } finally {
    # Best-effort, and deliberately so. A failure while extracting leaves a
    # half-written staging tree, and a recursive delete over one can itself
    # fail; with $ErrorActionPreference = "Stop" that cleanup error becomes
    # the terminating one and buries the real failure (an out-of-space
    # extraction reported as "cannot find path ...\_staging\mingw64\bin").
    # The next run starts with Ensure-CleanDirectory, so leftovers cost
    # nothing; a lost diagnosis costs an afternoon.
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Host "Installed gcc $version (WinLibs $release) at $installDir"
  return $installDir
}
