#Requires -Version 5.1
<#
.SYNOPSIS
    Reprobuild installer for Windows (x86_64).

.DESCRIPTION
    Meant to be run the CodeTracer/rustup way:

        $env:REPROBUILD_DOWNLOAD_BASE = 'https://downloads.reprobuild.com'  # optional
        irm https://downloads.reprobuild.com/install.ps1 | iex

    It downloads reprobuild-<channel>-windows-x86_64.zip from the download base,
    verifies its .sha256 sidecar, unpacks the bin/+lib/ tree into a prefix, adds
    bin/ to the user PATH, and asserts the runtime DLLs that repro.exe dlopen's
    by leaf name are present next to it (mirrors scripts/verify_release.sh).

    Parameters mirror the POSIX installer's environment variables:
      -Channel      / REPROBUILD_CHANNEL         (default: latest)
      -Prefix       / REPROBUILD_INSTALL_PREFIX  (default: %LOCALAPPDATA%\Programs\Reprobuild)
      -DownloadBase / REPROBUILD_DOWNLOAD_BASE   (default: https://downloads.reprobuild.com)

    TODO(installer/windows-service): this installs the CLI only. `repro --version`
    needs no daemon and release builds run with `--daemon=off`, so a service is
    out of scope here. A future MSI + Windows service (auto-start repro daemon,
    Add/Remove Programs entry, machine-wide PATH) is tracked with the daemon
    packaging work; do NOT bolt a Register-ScheduledTask hack on here.
#>
[CmdletBinding()]
param(
    [string]$Channel = $(if ($env:REPROBUILD_CHANNEL) { $env:REPROBUILD_CHANNEL } else { 'latest' }),
    [string]$Prefix = $(if ($env:REPROBUILD_INSTALL_PREFIX) { $env:REPROBUILD_INSTALL_PREFIX } else { Join-Path $env:LOCALAPPDATA 'Programs\Reprobuild' }),
    [string]$DownloadBase = $(if ($env:REPROBUILD_DOWNLOAD_BASE) { $env:REPROBUILD_DOWNLOAD_BASE } else { 'https://downloads.reprobuild.com' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Enable TLS 1.2 for Windows PowerShell 5.1, whose default may predate it. A
# no-op on PowerShell 7+, and irrelevant to the plain-http local server the CI
# integration test points this at.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "TLS 1.2 not configurable on this runtime: $_"
}

# Write-Host is the right tool for an interactive installer's progress, but the
# analyzer flags it by default; route ALL console output through this one
# suppressed helper.
function Write-Note {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Tag = '[Reprobuild installer] ',
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Cyan
    )
    Write-Host "$Tag$Message" -ForegroundColor $Color
}

# The runtime libraries repro.exe loads by leaf name (LoadLibrary searches the
# exe's own directory first), so a downloaded archive only works if these sit in
# bin/ next to repro.exe. Kept in sync with scripts/verify_release.sh.
$RequiredDlls = @(
    'clingo.dll',            # repro_solver ASP bindings -- dlopen'd at MODULE INIT
    'libcrypto-3-x64.dll',   # OpenSSL, --define:ssl entry points
    'libssl-3-x64.dll',
    'libzstd.dll',           # repro cache substitute, zstd frame decompression
    'sqlite3_64.dll',        # repro_local_store
    'sqlite3.dll'
)

# --- Detect platform ---------------------------------------------------------
# The release carries windows-x86_64 only. windows-aarch64 is deliberately
# absent (.github/release-platforms.json): conda-forge publishes clingo for
# win-64 only and clingo is dlopen'd at module init, so an ARM64 repro.exe is
# fatal, not merely degraded. Refuse rather than download an x64 zip that will
# not load.
$archRaw = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $archRaw = $env:PROCESSOR_ARCHITEW6432 }
if ($archRaw -ne 'AMD64') {
    throw ("Unsupported Windows architecture '$archRaw'. Reprobuild publishes windows-x86_64 only " +
           "(a native ARM64 repro.exe cannot load the x64-only clingo.dll it dlopen's at startup).")
}
$platform = 'windows-x86_64'

$asset = "reprobuild-$Channel-$platform.zip"
$url = "$DownloadBase/$asset"

# --- Download ----------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("reprobuild-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $zipPath = Join-Path $tmp $asset
    Write-Note "Downloading $asset from $DownloadBase"
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

    # --- Verify sha256 (sidecar is optional but expected) --------------------
    $shaUrl = "$url.sha256"
    $shaPath = "$zipPath.sha256"
    $haveSha = $false
    try {
        Invoke-WebRequest -Uri $shaUrl -OutFile $shaPath -UseBasicParsing
        $haveSha = $true
    } catch {
        Write-Warning "No $asset.sha256 published; skipping checksum verification."
    }
    if ($haveSha) {
        $expected = ((Get-Content -Path $shaPath -TotalCount 1) -split '\s+')[0].Trim().ToLowerInvariant()
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            throw "Checksum mismatch for ${asset}: expected $expected, got $actual"
        }
        Write-Note "Checksum OK ($actual)"
    }

    # --- Unpack --------------------------------------------------------------
    $unpacked = Join-Path $tmp 'unpacked'
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    Write-Note "Extracting $asset"
    Expand-Archive -Path $zipPath -DestinationPath $unpacked -Force

    # The archive is a bin/+lib/ tree nested one directory deep
    # (reprobuild-<ver>-windows-x86_64\bin, ...\lib).
    $binDirSrc = Get-ChildItem -Path $unpacked -Recurse -Directory -Filter 'bin' |
        Select-Object -First 1
    if (-not $binDirSrc) {
        throw "Unexpected archive layout: no bin\ directory found in $asset"
    }
    $rootSrc = $binDirSrc.Parent.FullName

    # --- Install into the prefix ---------------------------------------------
    $binDst = Join-Path $Prefix 'bin'
    $libDst = Join-Path $Prefix 'lib'
    foreach ($d in @($binDst, $libDst)) {
        if (Test-Path -Path $d) { Remove-Item -Path $d -Recurse -Force }
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Write-Note "Installing binaries into $binDst"
    Copy-Item -Path (Join-Path $rootSrc 'bin\*') -Destination $binDst -Recurse -Force
    $libSrc = Join-Path $rootSrc 'lib'
    if (Test-Path -Path $libSrc) {
        Write-Note "Installing runtime libraries into $libDst"
        Copy-Item -Path (Join-Path $libSrc '*') -Destination $libDst -Recurse -Force
    }

    # --- Assert the archive is self-contained --------------------------------
    $reproExe = Join-Path $binDst 'repro.exe'
    if (-not (Test-Path -Path $reproExe)) {
        throw "repro.exe not found at $reproExe after install"
    }
    Write-Note "Checking required runtime DLLs in $binDst"
    $missing = @()
    foreach ($dll in $RequiredDlls) {
        if (Test-Path -Path (Join-Path $binDst $dll)) {
            Write-Note "  ok      $dll"
        } else {
            Write-Warning "  MISSING $dll"
            $missing += $dll
        }
    }
    if ($missing.Count -gt 0) {
        throw ("$asset is not self-contained; missing from bin\: $($missing -join ', '). " +
               "These are dlopen'd by leaf name, so repro.exe would fail with 'could not load: <dll>' " +
               "on a clean machine. This is a defect in the release archive, not this installer.")
    }

    # --- Add bin\ to the user PATH -------------------------------------------
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ -ne '' } }
    if ($parts -notcontains $binDst) {
        $newPath = (@($parts + $binDst) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Note "Added $binDst to your user PATH (open a new terminal to pick it up)."
    }
    # Make repro runnable in THIS session without a restart.
    $env:Path = "$binDst;$env:Path"

    # --- Smoke test ----------------------------------------------------------
    Write-Note "Verifying installation: repro --version"
    & $reproExe --version
    if ($LASTEXITCODE -ne 0) {
        throw "repro.exe --version exited with code $LASTEXITCODE"
    }

    Write-Note -Tag '' -Color Green `
        -Message "Successfully installed Reprobuild into $Prefix. Run 'repro --help' to get started."
} finally {
    if (Test-Path -Path $tmp) { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
