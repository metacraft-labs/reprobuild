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
        # Every DLL staged is of the leg's own machine (0x8664 on x64, 0xAA64
        # on windows-aarch64). Do not stage a same-named DLL of another one.
        # A caller that loads only this function (the staging boundary test)
        # has no $script:releaseArch; the host's architecture is then the leg's.
        $legArch = if (Get-Variable -Name releaseArch -Scope Script -ErrorAction SilentlyContinue) {
            $script:releaseArch } else { Get-WindowsArch }
        Assert-PeMachine -Path $SrcPath -Arch $legArch -Consumer "stage-release-dlls"
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
$script:releaseArch = Get-WindowsArch
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
if ($script:releaseArch -eq "arm64") {
    # ── windows-aarch64 (reprobuild-pm Distribution-And-Packaging.md §7.1) ──
    # Every input is the arm64 pin the cold start installed or a pinned
    # archive fetched here; nothing is searched for. clingo is built with
    # llvm-mingw -static, so no MSVC runtime is staged, and the best-effort
    # WinLibs runtime list below is replaced by the closure audit (W5).
    $names = Get-WindowsArchRuntimeNames -Arch arm64
    foreach ($binding in @(
        @{ path = (Join-Path (Join-Path $toolchainRoot ("llvm-mingw/" + $toolchain["LLVM_MINGW_WIN_ARM64_RELEASE"])) "llvm-mingw.install.meta"); expected = @{
            llvm_mingw_release = $toolchain["LLVM_MINGW_WIN_ARM64_RELEASE"]
            llvm_mingw_archive_sha256 = $toolchain["LLVM_MINGW_WIN_ARM64_SHA256"].ToLowerInvariant() } },
        @{ path = (Join-Path $opensslRoot "openssl.install.meta"); expected = @{
            openssl_version = $toolchain["OPENSSL_VERSION"]
            openssl_arch = "arm64"
            openssl_msys2_release = $toolchain["OPENSSL_WIN_ARM64_MSYS2_RELEASE"]
            openssl_archive_sha256 = $toolchain["OPENSSL_WIN_ARM64_SHA256"].ToLowerInvariant() } },
        @{ path = (Join-Path $clingoRoot "clingo.install.meta"); expected = @{
            clingo_version = $toolchain["CLINGO_VERSION"]
            clingo_arch = "arm64"
            clingo_archive_sha256 = $toolchain["CLINGO_WIN_ARM64_SHA256"].ToLowerInvariant() } }
    )) {
        $actual = Read-KeyValueFile -Path $binding.path
        if (-not (Test-KeyValueFileMatches -Expected $binding.expected -Actual $actual)) {
            throw "stage-release-dlls: source metadata does not match the declared pin: $($binding.path)"
        }
    }
    foreach ($dll in $names.OpenSslDlls) {
        Copy-IntoBin -SrcPath (Join-Path $opensslRoot "bin/$dll") -DestName $dll
    }
    Copy-IntoBin -SrcPath (Join-Path $clingoRoot "clingo.dll") -DestName "clingo.dll"

    # sqlite and zstd: the pinned arm64 DLLs the cold start installed
    # (windows/ensure-runtime-dlls.ps1), checked against their pins.
    . (Join-Path $PSScriptRoot "ensure-runtime-dlls.ps1")
    $runtimeDir = Get-WindowsRuntimeDllDir -Root $toolchainRoot -Toolchain $toolchain
    $runtimeMeta = Read-KeyValueFile -Path (Join-Path $runtimeDir "runtime-dlls.install.meta")
    if (-not (Test-KeyValueFileMatches -Expected (Get-WindowsRuntimeDllMetadata -Toolchain $toolchain) -Actual $runtimeMeta)) {
        throw "stage-release-dlls: source metadata does not match the declared pin: $runtimeDir"
    }
    foreach ($dll in @("libzstd.dll", "sqlite3_64.dll", "sqlite3.dll")) {
        Copy-IntoBin -SrcPath (Join-Path $runtimeDir $dll) -DestName $dll
    }

    # cacert.pem: as on x64 (best effort, not in the verify manifest).
    if (-not (Test-Path -LiteralPath (Join-Path $binDir "cacert.pem"))) {
        $cacertSrc = Find-FirstFile -Name "cacert.pem" -Roots @($nimDir, (Join-Path $nimRoot "dist"))
        if ($null -ne $cacertSrc) {
            Copy-IntoBin -SrcPath $cacertSrc -DestName "cacert.pem"
        } else {
            try {
                Invoke-DownloadWithRetry { Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -OutFile (Join-Path $binDir "cacert.pem") }
            } catch {
                Write-Warning "stage-release-dlls: no cacert.pem staged ($($_.Exception.Message)); HTTPS at runtime will fail until one is beside repro.exe."
            }
        }
    }

    Assert-WindowsDllClosure -BinDir $binDir -Arch arm64
    Write-Host "=== Runtime DLL staging complete (arm64) ==="
    Get-ChildItem -LiteralPath $binDir -Filter *.dll | Select-Object -ExpandProperty Name | Sort-Object | ForEach-Object { Write-Host "  bin\$_" }
    return
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

# ── 2b. clingo.dll's MSVC runtime dependencies: see section 6 ───────────────
# The conda-forge clingo.dll is MSVC-built and imports the VC++ redistributable
# (MSVCP140.dll, VCRUNTIME140.dll, VCRUNTIME140_1.dll), which a minimal Windows
# image does not carry: the 2026-08-30 release dry run had clingo.dll staged
# and still failed "could not load: clingo.dll". Those DLLs are staged in
# section 6, from the pinned conda-forge vc14_runtime package, by the import
# walk -- exactly the ones an image imports, not a list.

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

# ── 6. The import closure: the VC++ and WinLibs runtime DLLs bin/ needs ─────
# Every DLL an image in bin/ imports or delay-loads, and that is neither in
# bin/ nor part of Windows (windows/release-os-dlls.txt), is copied from the
# pinned sources: the conda-forge vc14_runtime package (clingo.dll's C++
# runtime) and the selected WinLibs compiler's bin/ (libgcc_s and
# libwinpthread for the MSYS2 OpenSSL DLLs), transitively, and nothing else.
# This replaces the best-effort lists that staged the whole VC++ set and five
# WinLibs DLLs "in case". A DLL an earlier build
# staged and no image imports any more is removed. An import that no source
# holds fails here; verify_release.sh then audits the packaged archive.
$pkg = Expand-CondaPackage `
    -Url "https://anaconda.org/conda-forge/vc14_runtime/14.44.35208/download/win-64/vc14_runtime-14.44.35208-h818238b_41.conda" `
    -Sha256 "ec706fe9368b837fbd05af4851f5ebef12bef8c471a273f4805f7af788407317" `
    -WorkDir (Join-Path $tmp "vc14_runtime")
$vcSrcDir = Join-Path $pkg "Library/bin"
try {
    $staged = @(Copy-WindowsImportClosure -BinDir $binDir -SourceDirs @($vcSrcDir, $gccDir) -Arch $script:releaseArch `
        -KeepNames @("libcrypto-3-x64.dll", "libssl-3-x64.dll", "clingo.dll", "libzstd.dll", "sqlite3_64.dll", "sqlite3.dll"))
    Write-Host "  import closure staged: $(if ($staged.Count) { $staged -join ', ' } else { '(nothing)' })"
} finally {
    Remove-Item -LiteralPath (Split-Path -Parent $pkg) -Recurse -Force
}

Write-Host "=== Runtime DLL staging complete ==="
Get-ChildItem -LiteralPath $binDir -Filter *.dll | Select-Object -ExpandProperty Name | Sort-Object | ForEach-Object { Write-Host "  bin\$_" }
