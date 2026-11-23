# stage-release-dlls.ps1 -- make the Windows release archive self-contained.
#
# Every non-system library reprobuild uses on Windows is either dlopen'd by leaf
# name (clingo, libzstd, sqlite3) or imported through the PE import table
# (libcrypto/libssl, via the --define:ssl entry points). Win32's LoadLibrary
# searches the .exe's OWN directory first and PATH last, so the only thing that
# makes a downloaded archive run on a machine that never built reprobuild is the
# DLLs sitting in bin/ next to the executables.
#
# scripts/build_apps.sh already stages these during `just bootstrap` -- BUT only
# from sources that happen to be on the dev-env PATH (clingo via
# REPRO_WINDOWS_CLINGO_DIR, libzstd via `command -v zstd.exe`, sqlite via
# `command -v nim.exe`, ...). On the `windows-diy` CI runner several of those
# sources are absent (no zstd.exe is provisioned; the prebuilt Nim may not carry
# sqlite3_64.dll/cacert.pem), so that best-effort staging silently no-ops and the
# release archive ships incomplete. scripts/verify_release.sh then fails the leg
# on the missing manifest -- correctly, but after an hour of build time.
#
# The release consumes the exact sources selected by this checkout's bootstrap.
# It never searches other versions or keeps an unqualified DLL from a prior build.
# The pinned conda VC runtime is already this script's supported fallback; use
# that same archive consistently rather than host System32 contents.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$binDir = Join-Path (Get-Location) "build\bin"
if (-not (Test-Path -LiteralPath $binDir)) {
    throw "stage-release-dlls: $binDir does not exist; run this after the build."
}

$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }

# Retry wrapper for the public-CDN downloads below. This script runs on the
# critical release-staging path and pulls from conda-forge / curl.se, which
# flake (transient `no healthy upstream` 503s). Without a retry a single blip
# fails the whole ~2h Windows release leg. 6 attempts with capped linear
# backoff (~45s total) rides out a minute-long outage, then fails for real.
# Keep this release-CDN retry policy unchanged. The toolchain helpers loaded
# below supply pin-file and hash verification, not a different retry policy.
function Invoke-DownloadWithRetry {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $attempts = 6
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return & $Script
        } catch {
            if ($attempt -ge $attempts) { throw }
            $wait = [Math]::Min(3 * $attempt, 30)
            Write-Host ("  download attempt {0}/{1} failed ({2}); retrying in {3}s..." -f `
                $attempt, $attempts, $_.Exception.Message, $wait)
            Start-Sleep -Seconds $wait
        }
    }
}

function Copy-IntoBin {
    param([string]$SrcPath, [string]$DestName, [string]$ExpectedSha256 = "")
    if (-not (Test-Path -LiteralPath $SrcPath -PathType Leaf)) {
        throw "stage-release-dlls: required source is missing: $SrcPath"
    }
    if ($DestName.EndsWith(".dll", [StringComparison]::OrdinalIgnoreCase)) {
        # This release leg produces x64 images. Do not stage a same-named x86 DLL.
        $stream = [IO.File]::OpenRead($SrcPath)
        $reader = [IO.BinaryReader]::new($stream)
        try {
            if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid DOS header: $SrcPath" }
            $stream.Position = 0x3c
            $peOffset = $reader.ReadUInt32()
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
                throw "stage-release-dlls: expected an x64 PE image: $SrcPath"
            }
        } finally { $reader.Dispose() }
    }
    if ($ExpectedSha256) { Assert-FileSha256 -Path $SrcPath -Expected $ExpectedSha256 }
    $dest = Join-Path $binDir $DestName
    Copy-Item -LiteralPath $SrcPath -Destination $dest -Force
    Write-Host "  staged $DestName  <-  $SrcPath"
}

# Return the first existing file named $Name under any of $Roots (recursive),
# skipping empty/nonexistent roots. Recurse is bounded by the toolchain trees,
# which are small.
function Find-FirstFile {
    param([string]$Name, [string[]]$Roots)
    foreach ($root in $Roots) {
        if ([string]::IsNullOrEmpty($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter $Name -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $hit) { return $hit.FullName }
    }
    return $null
}

# Both archive formats reuse only the existing same-job archive path. Every
# use rechecks content; this is not a host store or shared-prefix cache.
function Get-VerifiedReleaseArchive {
    param([string]$Url, [string]$Sha256, [string]$ArchivePath)
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "stage-release-dlls: a complete archive SHA-256 is required for $Url"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArchivePath) | Out-Null
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        Write-Host "  downloading $Url"
        Invoke-DownloadWithRetry { Invoke-WebRequest -Uri $Url -OutFile $ArchivePath }
    }
    Assert-FileSha256 -Path $ArchivePath -Expected $Sha256
    return $ArchivePath
}

function Download-Zip {
    param([string]$Url, [string]$Sha256, [string]$OutDir)
    $zip = Get-VerifiedReleaseArchive -Url $Url -Sha256 $Sha256 `
        -ArchivePath (Join-Path $OutDir "pkg.zip")
    $stage = Join-Path $OutDir ("stage-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $stage
        return $stage
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force
        throw
    }
}

# A conda package (.conda) is a ZIP whose payload is `pkg-*.tar.zst`. Expand the
# outer ZIP, then untar the zstd payload with the Windows-bundled bsdtar
# (System32\tar.exe decodes zstd natively on Win10 22H2+, the same tool
# ensure-clingo.ps1 uses). Returns the extracted package root (holding
# `Library/bin/`, etc.).
function Expand-CondaPackage {
    param([string]$Url, [string]$Sha256, [string]$WorkDir)
    # Keep the existing pkg.zip location, without trusting prior extracted files.
    $conda = Get-VerifiedReleaseArchive -Url $Url -Sha256 $Sha256 `
        -ArchivePath (Join-Path $WorkDir "pkg.zip")
    $stage = Join-Path $WorkDir ("stage-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $unzipped = Join-Path $stage "unzipped"
    try {
        Expand-Archive -LiteralPath $conda -DestinationPath $unzipped -Force
        $pkgZst = Get-ChildItem -LiteralPath $unzipped -Filter "pkg-*.tar.zst" | Select-Object -First 1
        if ($null -eq $pkgZst) { throw "stage-release-dlls: no pkg-*.tar.zst payload in $Url" }
        $pkgOut = Join-Path $stage "pkg"
        New-Item -ItemType Directory -Force -Path $pkgOut | Out-Null
        $tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
        & $tarExe -xf $pkgZst.FullName -C $pkgOut
        if ($LASTEXITCODE -ne 0) { throw "stage-release-dlls: tar failed extracting $($pkgZst.Name) (exit $LASTEXITCODE)" }
        return $pkgOut
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force
        throw
    }

}

Write-Host "=== Staging required runtime DLLs into $binDir ==="
. (Join-Path $PSScriptRoot "toolchain-utils.ps1")
$toolchain = Read-KeyValueFile -Path (Join-Path $PSScriptRoot "toolchain-versions.env")
$toolchainRoot = $env:WINDOWS_DIY_INSTALL_ROOT
if ([string]::IsNullOrWhiteSpace($toolchainRoot)) {
    throw "stage-release-dlls: WINDOWS_DIY_INSTALL_ROOT is required; source env.ps1 first."
}
$gccRoot = Join-Path $toolchainRoot ("gcc/" + $toolchain["GCC_VERSION"])
$gccDir = Join-Path $gccRoot "bin"
$nimVersionRoot = Join-Path $toolchainRoot ("nim/" + $toolchain["NIM_VERSION"])
$nimRelative = (Get-Content -LiteralPath (Join-Path $nimVersionRoot "nim.install.relative-path") -Raw).Trim()
$nimMetadata = Read-KeyValueFile -Path (Join-Path $nimVersionRoot "nim.install.meta")
if ($nimMetadata["nim_version"] -ne $toolchain["NIM_VERSION"] -or
    $nimMetadata["install_relative_path"] -ne $nimRelative -or
    $nimMetadata["effective_mode"] -notin @("prebuilt", "source")) {
    throw "stage-release-dlls: Nim selection metadata does not match the declared version."
}
$nimRoot = [IO.Path]::GetFullPath((Join-Path $toolchainRoot $nimRelative))
$rootPrefix = [IO.Path]::GetFullPath($toolchainRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $nimRoot.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "stage-release-dlls: selected Nim prefix escapes the toolchain root."
}
$nimDir = Join-Path $nimRoot "bin"
$opensslRoot = Join-Path $toolchainRoot ("openssl/" + $toolchain["OPENSSL_VERSION"])
$clingoRoot = Join-Path $toolchainRoot ("clingo/" + $toolchain["CLINGO_VERSION"])
foreach ($binding in @(
    @{ name = "REPRO_WINDOWS_OPENSSL_DIR"; actual = $env:REPRO_WINDOWS_OPENSSL_DIR; expected = $opensslRoot },
    @{ name = "REPRO_WINDOWS_CLINGO_DIR"; actual = $env:REPRO_WINDOWS_CLINGO_DIR; expected = $clingoRoot }
)) {
    if ([string]::IsNullOrWhiteSpace($binding.actual) -or
        [IO.Path]::GetFullPath($binding.actual) -ine [IO.Path]::GetFullPath($binding.expected)) {
        throw "stage-release-dlls: $($binding.name) does not name the declared toolchain root."
    }
}
foreach ($binding in @(
    @{ path = (Join-Path $gccRoot "gcc.install.meta"); expected = @{
        gcc_version = $toolchain["GCC_VERSION"]
        gcc_winlibs_release = $toolchain["GCC_WINLIBS_RELEASE"]
        gcc_archive_sha256 = $toolchain["GCC_WINLIBS_SHA256"].ToLowerInvariant() } },
    @{ path = (Join-Path $opensslRoot "openssl.install.meta"); expected = @{
        openssl_version = $toolchain["OPENSSL_VERSION"]
        openssl_msys2_release = $toolchain["OPENSSL_MSYS2_RELEASE"]
        openssl_archive_sha256 = $toolchain["OPENSSL_SHA256"].ToLowerInvariant() } },
    @{ path = (Join-Path $clingoRoot "clingo.install.meta"); expected = @{
        clingo_version = $toolchain["CLINGO_VERSION"]
        clingo_build_string = $toolchain["CLINGO_BUILD_STRING"]
        clingo_archive_sha256 = $toolchain["CLINGO_SHA256"].ToLowerInvariant() } }
)) {
    $actual = Read-KeyValueFile -Path $binding.path
    if (-not (Test-KeyValueFileMatches -Expected $binding.expected -Actual $actual)) {
        throw "stage-release-dlls: source metadata does not match the declared pin: $($binding.path)"
    }
}

# Exact exported OpenSSL and clingo roots; no recursive host search or old output reuse.
foreach ($dll in @("libcrypto-3-x64.dll", "libssl-3-x64.dll")) {
    Copy-IntoBin -SrcPath (Join-Path $opensslRoot "bin/$dll") -DestName $dll
}
Copy-IntoBin -SrcPath (Join-Path $clingoRoot "clingo.dll") -DestName "clingo.dll"

# ── 2b. clingo.dll's MSVC runtime dependencies ───────────────────────────────
# The conda-forge clingo.dll is MSVC-built. Its import table needs the VC++
# redistributable -- MSVCP140.dll, VCRUNTIME140.dll and VCRUNTIME140_1.dll (the
# UCRT api-ms-win-crt-* it also imports are OS components already in System32).
# The VC++ redist is NOT guaranteed on a minimal windows-diy image --
# VCRUNTIME140_1.dll in particular is frequently absent -- so
# `LoadLibrary("clingo.dll")` returns NULL and repro.exe aborts at module init
# with "could not load: clingo.dll" EVEN THOUGH clingo.dll is present. (This is
# exactly what the 2026-08-30 release dry-run hit: clingo.dll staged, load still
# failed.) Bundle the redist beside clingo.dll -- needed at build time (the
# orchestrating repro.exe loads clingo at module init) AND in the archive
# (verify_release.sh scrubs PATH to the system dirs, so PATH cannot help).
#
# Source: the existing pinned conda-forge vc14_runtime package (the loose, redistributable MSVC
# runtime). msvcp140.dll pulls in msvcp140_1/2/atomic_wait + concrt140, so stage
# the whole set to close the transitive class.
$vcDlls = @(
    "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll",
    "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "concrt140.dll"
)
$pkg = Expand-CondaPackage `
    -Url "https://anaconda.org/conda-forge/vc14_runtime/14.44.35208/download/win-64/vc14_runtime-14.44.35208-h818238b_41.conda" `
    -Sha256 "ec706fe9368b837fbd05af4851f5ebef12bef8c471a273f4805f7af788407317" `
    -WorkDir (Join-Path $tmp "vc14_runtime")
$vcSrcDir = Join-Path $pkg "Library/bin"
try {
    foreach ($dll in $vcDlls) {
        $src = Join-Path $vcSrcDir $dll
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            Copy-IntoBin -SrcPath $src -DestName $dll
        } elseif ($dll -in @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")) {
            throw "stage-release-dlls: required MSVC runtime DLL $dll missing from pinned archive."
        } elseif (Test-Path -LiteralPath (Join-Path $binDir $dll)) {
            Remove-Item -LiteralPath (Join-Path $binDir $dll) -Force
        }
    }
} finally {
    Remove-Item -LiteralPath (Split-Path -Parent $pkg) -Recurse -Force
}

# These exact preferred members are authenticated against the existing archive pins.
foreach ($key in @("GCC_LIBZSTD_DLL_SHA256", "NIM_SQLITE_DLL_SHA256")) {
    if ($toolchain[$key] -notmatch '^[0-9a-fA-F]{64}$') {
        throw "stage-release-dlls: required DLL content pin is missing: $key"
    }
}
# The declared compiler carries zstd; do not substitute another compiler tree.
Copy-IntoBin -SrcPath (Join-Path $gccDir "libzstd.dll") -DestName "libzstd.dll" `
    -ExpectedSha256 $toolchain["GCC_LIBZSTD_DLL_SHA256"]
$sqliteSrc = @(
    (Join-Path $nimDir "sqlite3_64.dll"),
    (Join-Path $nimRoot "dist/sqlite3_64.dll"),
    (Join-Path $nimRoot "dlls/sqlite3_64.dll")
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
$sqliteStage = $null
$sqliteHash = $toolchain["NIM_SQLITE_DLL_SHA256"]
try {
    if (-not $sqliteSrc) {
        # Ensure-Nim source mode does not carry SQLite. Preserve the existing
        # 3.46.1 runtime fallback, authenticated before extraction.
        $sqliteStage = Download-Zip `
            -Url "https://www.sqlite.org/2024/sqlite-dll-win-x64-3460100.zip" `
            -Sha256 $toolchain["SQLITE_RUNTIME_ARCHIVE_SHA256"] `
            -OutDir (Join-Path $tmp "sqlite-3460100")
        $sqliteSrc = Join-Path $sqliteStage "sqlite3.dll"
        $sqliteHash = "" # The complete fixed archive was verified above.
    }
    foreach ($dll in @("sqlite3_64.dll", "sqlite3.dll")) {
        Copy-IntoBin -SrcPath $sqliteSrc -DestName $dll -ExpectedSha256 $sqliteHash
    }
} finally {
    if ($sqliteStage) { Remove-Item -LiteralPath $sqliteStage -Recurse -Force }
}

# ── 5. cacert.pem (best-effort; not in the verify manifest) ──────────────────
# Nim's net.newContext(CVerifyPeer) reads cacert.pem beside the exe on Windows,
# so every HTTPS fetch (cache substitute, deploy-agent poll) needs it. Not
# required for --version/--help/capabilities, so a miss only warns.
if (Test-Path -LiteralPath (Join-Path $binDir "cacert.pem")) {
    Write-Host "  cacert.pem already in build\bin (kept)"
} else {
    $cacertRoots = @()
    if ($nimDir) {
        $nimRoot = Split-Path -Parent $nimDir
        $cacertRoots += $nimDir, (Join-Path $nimRoot "dist"), (Join-Path $nimRoot "bin")
    }
    $cacertSrc = Find-FirstFile -Name "cacert.pem" -Roots $cacertRoots
    if ($null -eq $cacertSrc) {
        try {
            Invoke-DownloadWithRetry { Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -OutFile (Join-Path $binDir "cacert.pem") }
            Write-Host "  staged cacert.pem  <-  https://curl.se/ca/cacert.pem"
        } catch {
            Write-Warning "stage-release-dlls: cacert.pem not found near nim and download failed ($($_.Exception.Message)); HTTPS at runtime will fail until one is beside repro.exe."
        }
    } else {
        Copy-IntoBin -SrcPath $cacertSrc -DestName "cacert.pem"
    }
}

# ── 6. mingw / UCRT runtime DLLs (best-effort insurance) ─────────────────────
# repro.exe is asserted to statically import only ADVAPI32/KERNEL32/msvcrt, but
# the OpenSSL DLLs above come from MSYS2 ucrt64 and may carry transitive deps
# (libgcc_s, libwinpthread, zlib1, libssp). Under verify_release.sh's scrubbed
# PATH those must resolve from bin/ too. Stage whichever exist in the selected WinLibs gcc
# bin -- harmless extras if unused, and they close the whole transitive-dep class
# instead of chasing one missing DLL per CI cycle.
foreach ($rt in @("libgcc_s_seh-1.dll", "libwinpthread-1.dll", "libstdc++-6.dll", "zlib1.dll", "libssp-0.dll")) {
    $src = Join-Path $gccDir $rt
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-IntoBin -SrcPath $src -DestName $rt
    } elseif (Test-Path -LiteralPath (Join-Path $binDir $rt)) {
        # An optional DLL absent from this selected compiler cannot survive from
        # an older compiler's build directory.
        Remove-Item -LiteralPath (Join-Path $binDir $rt) -Force
    }
}

Write-Host "=== Runtime DLL staging complete ==="
Get-ChildItem -LiteralPath $binDir -Filter *.dll | Select-Object -ExpandProperty Name | Sort-Object | ForEach-Object { Write-Host "  bin\$_" }
