#requires -Version 5
# End-to-end M56 verification: build the ruby-bundler/hello-binary
# example via the Tier 2b dispatch path and run the produced wrapper.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for ruby AND bundle. SKIP exit 0 if either is missing. On
#      Windows, attempt to lift them from a managed install under
#      ``D:/metacraft-dev-deps/ruby/`` or from a RubyInstaller install
#      under ``C:/Ruby*/bin`` when ``Get-Command`` doesn't resolve
#      via PATH alone — this is the documented provisioning path
#      (RubyInstaller from https://rubyinstaller.org/).
#   3. Wipe any prior .repro/ scratch AND ``vendor/`` dir under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced launcher ``hello.cmd`` under
#      ``.repro/build/hello/`` and run it; assert stdout contains
#      ``hello from ruby-bundler-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M56.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\ruby-bundler\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$vendorInsideFixture  = Join-Path $fixture 'vendor'
$expectedGreeting = 'hello from ruby-bundler-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'Gemfile'))) {
  Write-Host "FAIL: fixture missing Gemfile at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'Gemfile.lock'))) {
  Write-Host "FAIL: fixture missing Gemfile.lock at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'bin\hello.rb'))) {
  Write-Host "FAIL: fixture missing bin\hello.rb at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed Ruby install into PATH when ruby/bundle don't
# resolve directly. The dev-deps tree may carry a Ruby install under
# ``D:\metacraft-dev-deps\ruby\``; system-wide RubyInstaller installs
# land under ``C:\Ruby<version>\`` or ``%LOCALAPPDATA%\Programs\Ruby\``.
function Try-LiftRuby {
  $candidates = @()
  foreach ($rubyRoot in @(
    'D:\metacraft-dev-deps\ruby',
    (Join-Path $env:LOCALAPPDATA 'Programs\Ruby'))) {
    if (-not $rubyRoot) { continue }
    if (-not (Test-Path -LiteralPath $rubyRoot)) { continue }
    foreach ($candidate in @(
      (Join-Path $rubyRoot 'bin\ruby.exe'),
      (Join-Path $rubyRoot 'bin\bundle.bat'))) {
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  # Also scan ``C:\Ruby<version>\bin\``.
  foreach ($cRubyDir in @(Get-ChildItem -Path 'C:\' -Directory -Filter 'Ruby*' -ErrorAction SilentlyContinue)) {
    $binDir = Join-Path $cRubyDir.FullName 'bin'
    foreach ($candidate in @(
      (Join-Path $binDir 'ruby.exe'),
      (Join-Path $binDir 'bundle.bat'))) {
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  if ($candidates.Count -gt 0) {
    $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
    if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
      $env:PATH = "$binDir;$env:PATH"
    }
  }
}

$rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
$bundleCmd = Get-Command bundle -ErrorAction SilentlyContinue
if (-not $rubyCmd -or -not $bundleCmd) {
  Try-LiftRuby
  $rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
  $bundleCmd = Get-Command bundle -ErrorAction SilentlyContinue
}
if (-not $rubyCmd) {
  Write-Host "SKIP: 'ruby' not on PATH (M56 ruby-bundler convention needs the Ruby toolchain; install Ruby via RubyInstaller from https://rubyinstaller.org/ -- M56 pins Ruby 3.3.5)"
  exit 0
}
if (-not $bundleCmd) {
  Write-Host "SKIP: 'bundle' not on PATH (M56 ruby-bundler convention needs Bundler; Bundler ships with Ruby >= 2.6, so re-install Ruby via RubyInstaller from https://rubyinstaller.org/)"
  exit 0
}

Write-Host "==> using ruby=$($rubyCmd.Source)"
Write-Host "==> using bundle=$($bundleCmd.Source)"

# --- step 1: clean prior scratch + vendor dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $vendorInsideFixture) {
  Write-Host "wiping prior vendor dir $vendorInsideFixture"
  Remove-Item -LiteralPath $vendorInsideFixture -Recurse -Force
}
# Bundler may also leave a ``.bundle/`` config dir at the fixture root.
$bundleConfigDir = Join-Path $fixture '.bundle'
if (Test-Path -LiteralPath $bundleConfigDir) {
  Write-Host "wiping prior .bundle/ config dir $bundleConfigDir"
  Remove-Item -LiteralPath $bundleConfigDir -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-ruby-bundler-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-ruby-bundler-hello-binary.stderr.txt'
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
Write-Host "PASS: ruby-bundler/hello-binary built via standard provider; greeting matched"
exit 0
