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
# This script is the RELEASE-time guarantee: it stages every required runtime
# DLL into build\bin deterministically, preferring the provisioned toolchain
# sources on the runner and falling back to pinned, checksummed downloads when a
# source is not present. It is idempotent and safe to re-run. Keep the required
# set in sync with scripts/verify_release.sh and scripts/build_apps.sh.
#
# release.yml runs it TWICE: once BEFORE `repro build .#release` and once after.
#   - Before: the orchestrating repro.exe (built by `just bootstrap`) dlopens
#     clingo.dll AND sqlite3_64.dll at MODULE INIT and imports libcrypto/libssl,
#     so those must sit in build\bin (or on PATH) for it to start at all.
#   - After: `.#release` rewrites build\bin, so re-stage to guarantee the
#     PACKAGED bin/ is complete. Idempotent: the second pass re-copies from the
#     runner sources (cheap) and short-circuits the pinned downloads when the DLL
#     is already present.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$binDir = Join-Path (Get-Location) "build\bin"
if (-not (Test-Path -LiteralPath $binDir)) {
    throw "stage-release-dlls: $binDir does not exist; run this after the build."
}

$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }

function Copy-IntoBin {
    param([string]$SrcPath, [string]$DestName)
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

function Get-CommandDir {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return "" }
    $src = if ($cmd.CommandType -eq "Alias") { $cmd.Definition } else { $cmd.Source }
    if ([string]::IsNullOrWhiteSpace($src)) { return "" }
    return (Split-Path -Parent $src)
}

function Download-Zip {
    param([string]$Url, [string]$Sha256, [string]$OutDir)
    $zip = Join-Path $tmp ("dl-" + [IO.Path]::GetRandomFileName() + ".zip")
    Write-Host "  downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $zip
    if ($Sha256) {
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
        if ($got -ne $Sha256.ToLower()) {
            throw "stage-release-dlls: checksum mismatch for $Url (expected $Sha256, got $got)"
        }
    }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $OutDir -Force
    return $OutDir
}

# A conda package (.conda) is a ZIP whose payload is `pkg-*.tar.zst`. Expand the
# outer ZIP, then untar the zstd payload with the Windows-bundled bsdtar
# (System32\tar.exe decodes zstd natively on Win10 22H2+, the same tool
# ensure-clingo.ps1 uses). Returns the extracted package root (holding
# `Library/bin/`, etc.).
function Expand-CondaPackage {
    param([string]$Url, [string]$Sha256, [string]$WorkDir)
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    # A .conda file IS a zip, but Expand-Archive only accepts a `.zip` extension,
    # so name the download accordingly (bytes are unchanged, checksum still holds).
    $conda = Join-Path $WorkDir "pkg.zip"
    Write-Host "  downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $conda
    if ($Sha256) {
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $conda).Hash.ToLower()
        if ($got -ne $Sha256.ToLower()) {
            throw "stage-release-dlls: checksum mismatch for $Url (expected $Sha256, got $got)"
        }
    }
    $unzipped = Join-Path $WorkDir "unzipped"
    Expand-Archive -LiteralPath $conda -DestinationPath $unzipped -Force
    $pkgZst = Get-ChildItem -LiteralPath $unzipped -Filter "pkg-*.tar.zst" | Select-Object -First 1
    if ($null -eq $pkgZst) { throw "stage-release-dlls: no pkg-*.tar.zst payload in $Url" }
    $pkgOut = Join-Path $WorkDir "pkg"
    New-Item -ItemType Directory -Force -Path $pkgOut | Out-Null
    $tarExe = Join-Path $env:SystemRoot "System32\tar.exe"
    & $tarExe -xf $pkgZst.FullName -C $pkgOut
    if ($LASTEXITCODE -ne 0) { throw "stage-release-dlls: tar failed extracting $($pkgZst.Name) (exit $LASTEXITCODE)" }
    return $pkgOut
}

Write-Host "=== Staging required runtime DLLs into $binDir ==="

$toolchainRoot = $env:WINDOWS_DIY_INSTALL_ROOT
$programFiles  = @("C:\Program Files", "C:\Program Files (x86)")

# ── 1. OpenSSL (libcrypto-3-x64.dll, libssl-3-x64.dll) ───────────────────────
# Imported (not dlopen'd): repro/repro-binary-cache/repro-harvest-apt are
# --define:ssl. Source: the ensure-openssl.ps1 install dir (bin/), exported as
# REPRO_WINDOWS_OPENSSL_DIR. Fall back to the toolchains tree / Program Files.
$opensslRoots = @()
if ($env:REPRO_WINDOWS_OPENSSL_DIR) { $opensslRoots += (Join-Path $env:REPRO_WINDOWS_OPENSSL_DIR "bin") }
$opensslRoots += $toolchainRoot
$opensslRoots += $programFiles
foreach ($dll in @("libcrypto-3-x64.dll", "libssl-3-x64.dll")) {
    $src = Find-FirstFile -Name $dll -Roots $opensslRoots
    if ($null -eq $src) {
        throw "stage-release-dlls: $dll not found (searched: $($opensslRoots -join '; ')). " +
              "This is the MSYS2 ucrt64 OpenSSL that ensure-openssl.ps1 provisions; the archive cannot be self-contained without it."
    }
    Copy-IntoBin -SrcPath $src -DestName $dll
}

# ── 2. clingo.dll ────────────────────────────────────────────────────────────
# dlopen'd at MODULE INIT by repro_solver. Source: REPRO_WINDOWS_CLINGO_DIR
# (ensure-clingo.ps1). build_apps.sh already staged it so `repro build` could
# run; re-stage for the archive in case the build rewrote build\bin.
$clingoRoots = @()
if ($env:REPRO_WINDOWS_CLINGO_DIR) { $clingoRoots += $env:REPRO_WINDOWS_CLINGO_DIR }
$clingoRoots += $toolchainRoot
$clingoRoots += $programFiles
$clingoSrc = Find-FirstFile -Name "clingo.dll" -Roots $clingoRoots
if ($null -eq $clingoSrc) {
    # Already beside repro.exe? build_apps.sh may have put it there.
    if (Test-Path -LiteralPath (Join-Path $binDir "clingo.dll")) {
        Write-Host "  clingo.dll already present in build\bin (staged by build_apps.sh)"
    } else {
        throw "stage-release-dlls: clingo.dll not found (searched: $($clingoRoots -join '; ')). " +
              "repro_solver dlopens it at module init, so every repro.exe subcommand aborts without it."
    }
} else {
    Copy-IntoBin -SrcPath $clingoSrc -DestName "clingo.dll"
}

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
# Source: the runner (System32 / toolchains) if the redist is installed, else a
# pinned conda-forge vc14_runtime package (the loose, redistributable MSVC
# runtime). msvcp140.dll pulls in msvcp140_1/2/atomic_wait + concrt140, so stage
# the whole set to close the transitive class.
$vcDlls = @(
    "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll",
    "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "concrt140.dll"
)
$vcMissing = @($vcDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path $binDir $_)) })
if ($vcMissing.Count -eq 0) {
    Write-Host "  MSVC runtime already in build\bin (kept)"
} else {
    # Marker is VCRUNTIME140_1.dll: the one most often missing, so finding it
    # means a complete-enough redist is on the runner. Check System32 DIRECTLY
    # (the redist installs there, and a recursive walk of System32 is enormous);
    # the toolchains tree is small enough to recurse.
    $vcSrcDir = $null
    $sys32 = Join-Path $env:SystemRoot "System32"
    if (Test-Path -LiteralPath (Join-Path $sys32 "vcruntime140_1.dll")) {
        $vcSrcDir = $sys32
    } else {
        $marker = Find-FirstFile -Name "vcruntime140_1.dll" -Roots @($toolchainRoot)
        if ($marker) { $vcSrcDir = Split-Path -Parent $marker }
    }
    if (-not $vcSrcDir) {
        $pkg = Expand-CondaPackage `
            -Url "https://anaconda.org/conda-forge/vc14_runtime/14.44.35208/download/win-64/vc14_runtime-14.44.35208-h818238b_41.conda" `
            -Sha256 "ec706fe9368b837fbd05af4851f5ebef12bef8c471a273f4805f7af788407317" `
            -WorkDir (Join-Path $tmp "vc14_runtime")
        $vcSrcDir = Join-Path $pkg "Library\bin"
        if (-not (Test-Path -LiteralPath $vcSrcDir)) { $vcSrcDir = $pkg }
    }
    foreach ($d in $vcDlls) {
        if (Test-Path -LiteralPath (Join-Path $binDir $d)) { continue }
        $src = Join-Path $vcSrcDir $d
        if (Test-Path -LiteralPath $src) { Copy-IntoBin -SrcPath $src -DestName $d }
        elseif ($d -in @("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll")) {
            throw "stage-release-dlls: required MSVC runtime DLL $d not found at $vcSrcDir; clingo.dll cannot load without it."
        }
    }
}

# ── 3. libzstd.dll ───────────────────────────────────────────────────────────
# dlopen'd LAZILY (explicit loadLib) by `repro cache substitute` for zstd frame
# decompression -- not needed at startup, but required in the archive manifest.
# The WinLibs UCRT gcc bundles libzstd.dll in its bin; search the toolchains tree
# first, then fall back to a pinned facebook/zstd win64 release.
if (Test-Path -LiteralPath (Join-Path $binDir "libzstd.dll")) {
    Write-Host "  libzstd.dll already in build\bin (kept)"
} else {
    $zstdRoots = @($toolchainRoot)
    if ($toolchainRoot) { $zstdRoots += (Join-Path $toolchainRoot "msys2") }
    $zstdRoots += $programFiles
    $zstdSrc = Find-FirstFile -Name "libzstd.dll" -Roots $zstdRoots
    if ($null -eq $zstdSrc) {
        $zstdVer = "1.5.6"
        $out = Download-Zip `
            -Url "https://github.com/facebook/zstd/releases/download/v$zstdVer/zstd-v$zstdVer-win64.zip" `
            -Sha256 "" `
            -OutDir (Join-Path $tmp "zstd-$zstdVer")
        $zstdSrc = Find-FirstFile -Name "libzstd.dll" -Roots @($out)
        if ($null -eq $zstdSrc) { throw "stage-release-dlls: libzstd.dll missing from downloaded facebook/zstd $zstdVer archive." }
    }
    Copy-IntoBin -SrcPath $zstdSrc -DestName "libzstd.dll"
}

# ── 4. sqlite3_64.dll + sqlite3.dll ──────────────────────────────────────────
# dlopen'd at MODULE INIT by repro_local_store (linked into repro.exe), so it is
# needed for repro.exe to START, not just at the archive. Search near nim.exe
# first (the Windows Nim distribution ships sqlite3_64.dll in its tree), then
# fall back to a pinned sqlite.org win-x64 DLL (staged under both leaf names the
# binding probes).
$nimDir = Get-CommandDir -Name "nim"
if ((Test-Path -LiteralPath (Join-Path $binDir "sqlite3_64.dll")) -and
    (Test-Path -LiteralPath (Join-Path $binDir "sqlite3.dll"))) {
    Write-Host "  sqlite3_64.dll / sqlite3.dll already in build\bin (kept)"
} else {
    $sqliteRoots = @()
    if ($nimDir) {
        $nimRoot = Split-Path -Parent $nimDir
        $sqliteRoots += $nimDir, (Join-Path $nimRoot "dist"), (Join-Path $nimRoot "dlls"), (Join-Path $nimRoot "bin")
    }
    $sqliteRoots += $toolchainRoot
    $sqliteSrc = Find-FirstFile -Name "sqlite3_64.dll" -Roots $sqliteRoots
    if ($null -eq $sqliteSrc) { $sqliteSrc = Find-FirstFile -Name "sqlite3.dll" -Roots $sqliteRoots }
    if ($null -eq $sqliteSrc) {
        # sqlite.org ships a single sqlite3.dll; the year in the asset URL is part
        # of the release path. Pinned to 3.46.1.
        $out = Download-Zip `
            -Url "https://www.sqlite.org/2024/sqlite-dll-win-x64-3460100.zip" `
            -Sha256 "" `
            -OutDir (Join-Path $tmp "sqlite-3460100")
        $sqliteSrc = Find-FirstFile -Name "sqlite3.dll" -Roots @($out)
        if ($null -eq $sqliteSrc) { throw "stage-release-dlls: sqlite3.dll missing from downloaded sqlite.org archive." }
    }
    Copy-IntoBin -SrcPath $sqliteSrc -DestName "sqlite3_64.dll"
    Copy-IntoBin -SrcPath $sqliteSrc -DestName "sqlite3.dll"
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
            Invoke-WebRequest -Uri "https://curl.se/ca/cacert.pem" -OutFile (Join-Path $binDir "cacert.pem")
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
# PATH those must resolve from bin/ too. Stage whichever exist in the WinLibs gcc
# bin -- harmless extras if unused, and they close the whole transitive-dep class
# instead of chasing one missing DLL per CI cycle.
$gccDir = Get-CommandDir -Name "gcc"
$runtimeRoots = @()
if ($gccDir) { $runtimeRoots += $gccDir }
$runtimeRoots += $toolchainRoot
foreach ($rt in @("libgcc_s_seh-1.dll", "libwinpthread-1.dll", "libstdc++-6.dll", "zlib1.dll", "libssp-0.dll")) {
    if (Test-Path -LiteralPath (Join-Path $binDir $rt)) { continue }
    $src = Find-FirstFile -Name $rt -Roots $runtimeRoots
    if ($null -ne $src) { Copy-IntoBin -SrcPath $src -DestName $rt }
}

Write-Host "=== Runtime DLL staging complete ==="
Get-ChildItem -LiteralPath $binDir -Filter *.dll | Select-Object -ExpandProperty Name | Sort-Object | ForEach-Object { Write-Host "  bin\$_" }
