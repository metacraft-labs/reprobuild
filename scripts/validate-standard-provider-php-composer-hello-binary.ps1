#requires -Version 5
# End-to-end M57 verification: build the php-composer/hello-binary
# example via the Tier 2b dispatch path and run the produced wrapper.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for php AND composer. SKIP exit 0 if either is missing. On
#      Windows, attempt to lift them from a managed install under
#      ``D:/metacraft-dev-deps/php/`` or from a Composer-Setup install
#      under ``%LOCALAPPDATA%/Composer/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (PHP Windows binary from https://windows.php.net/downloads/
#      + Composer-Setup.exe from https://getcomposer.org/).
#   3. Wipe any prior .repro/ scratch AND ``vendor/`` dir under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced launcher ``hello.cmd`` under
#      ``.repro/build/hello/`` and run it; assert stdout contains
#      ``hello from php-composer-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M57.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\php-composer\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$vendorInsideFixture  = Join-Path $fixture 'vendor'
$expectedGreeting = 'hello from php-composer-hello-binary'

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'reprobuild.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'composer.json'))) {
  Write-Host "FAIL: fixture missing composer.json at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'composer.lock'))) {
  Write-Host "FAIL: fixture missing composer.lock at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'bin\hello.php'))) {
  Write-Host "FAIL: fixture missing bin\hello.php at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed PHP + Composer install into PATH when
# php/composer don't resolve directly. The dev-deps tree may carry a
# PHP install under ``D:\metacraft-dev-deps\php\``; system-wide
# Composer-Setup.exe installs land under ``%LOCALAPPDATA%\Composer\``
# (Composer binary) and PHP via the Windows binary may land in
# ``%LOCALAPPDATA%\Programs\php\`` or ``C:\php\``.
function Try-LiftPhp {
  $candidates = @()
  foreach ($phpRoot in @(
    'D:\metacraft-dev-deps\php',
    'C:\php',
    (Join-Path $env:LOCALAPPDATA 'Programs\php'))) {
    if (-not $phpRoot) { continue }
    if (-not (Test-Path -LiteralPath $phpRoot)) { continue }
    foreach ($candidate in @(
      (Join-Path $phpRoot 'php.exe'))) {
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  if ($candidates.Count -gt 0) {
    $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
    if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
      $env:PATH = "$binDir;$env:PATH"
    }
  }
  # Composer's installer drops the launcher under
  # ``%LOCALAPPDATA%\Composer\composer.bat`` plus the phar under
  # ``%LOCALAPPDATA%\Composer\composer.phar``.
  foreach ($composerRoot in @(
    'D:\metacraft-dev-deps\composer',
    (Join-Path $env:LOCALAPPDATA 'Composer'),
    (Join-Path $env:APPDATA 'Composer'))) {
    if (-not $composerRoot) { continue }
    if (-not (Test-Path -LiteralPath $composerRoot)) { continue }
    foreach ($candidate in @(
      (Join-Path $composerRoot 'composer.bat'),
      (Join-Path $composerRoot 'composer.phar'))) {
      if (Test-Path -LiteralPath $candidate) {
        $binDir = Split-Path -Parent $candidate
        if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
          $env:PATH = "$binDir;$env:PATH"
        }
      }
    }
  }
}

$phpCmd = Get-Command php -ErrorAction SilentlyContinue
$composerCmd = Get-Command composer -ErrorAction SilentlyContinue
if (-not $phpCmd -or -not $composerCmd) {
  Try-LiftPhp
  $phpCmd = Get-Command php -ErrorAction SilentlyContinue
  $composerCmd = Get-Command composer -ErrorAction SilentlyContinue
}
if (-not $phpCmd) {
  Write-Host "SKIP: 'php' not on PATH (M57 php-composer convention needs the PHP toolchain; install PHP Windows binary from https://windows.php.net/downloads/ -- M57 pins PHP 8.3.13)"
  exit 0
}
if (-not $composerCmd) {
  Write-Host "SKIP: 'composer' not on PATH (M57 php-composer convention needs Composer; install via Composer-Setup.exe from https://getcomposer.org/Composer-Setup.exe -- M57 pins Composer 2.8.1)"
  exit 0
}

Write-Host "==> using php=$($phpCmd.Source)"
Write-Host "==> using composer=$($composerCmd.Source)"

# --- step 1: clean prior scratch + vendor dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $vendorInsideFixture) {
  Write-Host "wiping prior vendor dir $vendorInsideFixture"
  Remove-Item -LiteralPath $vendorInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-php-composer-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-php-composer-hello-binary.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $stdoutCapture) | Out-Null

Write-Host "==> launching repro.exe build $reproTarget"
$proc = Start-Process -FilePath $reproExe -ArgumentList @(
    'build', $reproTarget,
    '--tool-provisioning=path',
    '--log=actions'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutCapture `
  -RedirectStandardError  $stderrCapture
$exitCode = $proc.ExitCode

Write-Host "--- repro exit code: $exitCode"
if (Test-Path $stdoutCapture) {
  Write-Host "--- repro stdout (last 20 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 20 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 20
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 20 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- step 3: locate produced wrapper ---
$wrapper = Join-Path $fixture '.repro\build\hello\hello.cmd'
if (-not (Test-Path -LiteralPath $wrapper)) {
  Write-Host "FAIL: expected wrapper not found at $wrapper"
  $scratch = Join-Path $fixture '.repro'
  if (Test-Path $scratch) {
    Write-Host "--- contents of ${scratch}:"
    Get-ChildItem -LiteralPath $scratch -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no .repro scratch dir)"
  }
  exit 1
}
Write-Host "produced wrapper: $wrapper"
Write-Host "  size: $((Get-Item $wrapper).Length) bytes"

# --- step 4: run wrapper and assert greeting ---
Write-Host "==> running $wrapper"
$output = & $wrapper 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- wrapper exit code: $runExit"
Write-Host "--- wrapper stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: wrapper exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: wrapper stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: php-composer/hello-binary built via standard provider; greeting matched"
exit 0
