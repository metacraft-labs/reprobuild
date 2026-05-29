#requires -Version 5
# End-to-end M42 verification: build the csharp-dotnet/hello-binary
# example via the Tier 2b dispatch path and run the produced .exe.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for dotnet. SKIP exit 0 if missing. On Windows, attempt
#      to lift dotnet from a managed install under
#      ``D:/metacraft-dev-deps/dotnet/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (download .NET SDK 8.0 LTS from microsoft.com into
#      ``D:/metacraft-dev-deps/dotnet/8.0/`` or use ``winget install
#      Microsoft.DotNet.SDK.8``).
#   3. Wipe any prior .repro/ scratch AND ``bin/`` + ``obj/`` dirs
#      under the fixture so the build runs cold.
#   4. Run a non-fatal ``dotnet restore --use-lock-file`` warm step
#      (network-touching, BEFORE the offline build) to materialise
#      ``obj/project.assets.json`` and pre-populate
#      ``~/.nuget/packages/`` with the implicit framework reference.
#      The M42 ``--no-restore`` contract requires this; the warm step
#      is non-fatal because some hosts have already warmed.
#   5. Wipe ``bin/`` once more so the offline build runs cold (we
#      keep ``obj/`` because it carries the assets the restore step
#      wrote — those are the input the ``--no-restore`` build needs).
#   6. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   7. Assert exit code 0.
#   8. Locate the produced ``bin/Release/net8.0/hello.exe`` and run it;
#      assert stdout contains ``hello from csharp-dotnet-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M42.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\csharp-dotnet\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$binInsideFixture     = Join-Path $fixture 'bin'
$objInsideFixture     = Join-Path $fixture 'obj'
$expectedGreeting = 'hello from csharp-dotnet-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'hello.csproj'))) {
  Write-Host "FAIL: fixture missing hello.csproj at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'packages.lock.json'))) {
  Write-Host "FAIL: fixture missing packages.lock.json at $fixture (M42 HARD precondition)"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed .NET SDK into PATH when dotnet doesn't resolve directly.
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnetCmd) {
  $dotnetRoot = 'D:\metacraft-dev-deps\dotnet'
  if (Test-Path -LiteralPath $dotnetRoot) {
    $candidates = @()
    $direct = Join-Path $dotnetRoot 'dotnet.exe'
    if (Test-Path -LiteralPath $direct) { $candidates += $direct }
    foreach ($verDir in Get-ChildItem -LiteralPath $dotnetRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'dotnet.exe'
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
    if ($candidates.Count -gt 0) {
      $picked = $candidates | Sort-Object | Select-Object -Last 1
      $binDir = Split-Path -Parent $picked
      if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
        $env:PATH = "$binDir;$env:PATH"
      }
      $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    }
  }
}
if (-not $dotnetCmd) {
  Write-Host "SKIP: 'dotnet' not on PATH (M42 csharp-dotnet convention needs the .NET SDK; install .NET SDK 8.0 LTS into D:/metacraft-dev-deps/dotnet/8.0/ or 'winget install Microsoft.DotNet.SDK.8')"
  exit 0
}

Write-Host "==> using dotnet=$($dotnetCmd.Source)"

# --- warm-step provisioning (network-touching, BEFORE the offline build) ---
# The M42 convention's ``--no-restore`` mode requires
# ``obj/project.assets.json`` to already exist (MSBuild's
# restore-output marker) and the implicit framework-pack reference to
# already be cached in ``~/.nuget/packages/``. Run ``dotnet restore
# --use-lock-file`` ONCE here — outside the action graph — so the
# convention's hermetic offline build has everything it needs. This is
# the provisioning-time warm step the M42 spec calls for. We tolerate
# failure because some hosts have already warmed (and a network-less
# environment will fail the build explicitly downstream).
Write-Host "==> warming NuGet packages cache (dotnet restore --use-lock-file)"
$warmStdout = Join-Path $repoRoot 'build\validate-standard-provider-csharp-dotnet-hello-binary.warm.stdout.txt'
$warmStderr = Join-Path $repoRoot 'build\validate-standard-provider-csharp-dotnet-hello-binary.warm.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $warmStdout) | Out-Null
$warmProc = Start-Process -FilePath $dotnetCmd.Source -ArgumentList @(
    'restore',
    '--use-lock-file',
    '--nologo',
    '--verbosity', 'quiet',
    (Join-Path $fixture 'hello.csproj')
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $fixture `
  -RedirectStandardOutput $warmStdout `
  -RedirectStandardError  $warmStderr
$warmExit = $warmProc.ExitCode
Write-Host "--- warm-step exit code: $warmExit (non-fatal — proceeding to build)"

# --- step 1: clean prior scratch + bin dir ---
# IMPORTANT: keep ``obj/`` intact — it carries the
# ``project.assets.json`` the warm step generated, which the
# ``--no-restore`` build needs as its input. Wiping ``obj/`` would
# require a full restore at build time, defeating the offline-mode
# contract.
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $binInsideFixture) {
  Write-Host "wiping prior dotnet bin dir $binInsideFixture"
  Remove-Item -LiteralPath $binInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-csharp-dotnet-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-csharp-dotnet-hello-binary.stderr.txt'

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

# --- step 3: locate produced exe ---
$producedExe = Join-Path $fixture 'bin\Release\net8.0\hello.exe'
if (-not (Test-Path -LiteralPath $producedExe)) {
  Write-Host "FAIL: expected exe not found at $producedExe"
  if (Test-Path $binInsideFixture) {
    Write-Host "--- contents of ${binInsideFixture}:"
    Get-ChildItem -LiteralPath $binInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no dotnet bin dir)"
  }
  exit 1
}
Write-Host "produced exe: $producedExe"
Write-Host "  size: $((Get-Item $producedExe).Length) bytes"

# --- step 4: run exe and assert greeting ---
# The .NET SDK 5+ produces an apphost .exe that searches for the
# matching ``hostfxr.dll`` (the runtime resolver) via, in order:
#   1. the ``DOTNET_ROOT`` env var (or ``DOTNET_ROOT_<arch>``)
#   2. the Windows registry's documented dotnet install location
#   3. ``%ProgramFiles%\dotnet\``
# On the M42 review host the .NET SDK is provisioned under
# ``D:\metacraft-dev-deps\dotnet\9.0.310\`` and none of (2)/(3) point
# at it. Set ``DOTNET_ROOT`` so the apphost can find ``hostfxr.dll``.
# The ``<RollForward>Major</RollForward>`` knob in hello.csproj then
# lets the apphost accept the 9.0 runtime when the 8.0 runtime isn't
# installed.
$dotnetRoot = Split-Path -Parent $dotnetCmd.Source
$env:DOTNET_ROOT = $dotnetRoot
Write-Host "==> running $producedExe (DOTNET_ROOT=$dotnetRoot)"
$output = & $producedExe 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- exe exit code: $runExit"
Write-Host "--- exe stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced exe exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced exe stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: csharp-dotnet/hello-binary built via standard provider; greeting matched"
exit 0
