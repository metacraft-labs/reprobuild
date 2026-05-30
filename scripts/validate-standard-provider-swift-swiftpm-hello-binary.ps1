#requires -Version 5
# End-to-end M43 verification: build the swift-swiftpm/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for swift. SKIP exit 0 if missing. On Windows, attempt to
#      lift swift from a managed install under
#      ``D:/metacraft-dev-deps/swift/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (download Swift 5.10 from swift.org into
#      ``D:/metacraft-dev-deps/swift/5.10/`` or use ``winget install
#      Swift.Toolchain``).
#   3. Wipe any prior .repro/ scratch AND ``.build/`` dir under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``.build/release/hello[.exe]`` and run it;
#      assert stdout contains ``hello from swift-swiftpm-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M43.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\swift-swiftpm\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$buildInsideFixture   = Join-Path $fixture '.build'
$expectedGreeting = 'hello from swift-swiftpm-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'Package.swift'))) {
  Write-Host "FAIL: fixture missing Package.swift at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'Sources\hello\main.swift'))) {
  Write-Host "FAIL: fixture missing Sources/hello/main.swift at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed Swift toolchain into PATH when swift doesn't
# resolve directly. The dev-deps tree carries one or more Swift versions
# as subdirs (e.g. ``D:\metacraft-dev-deps\swift\5.10\``); look under
# ``<ver>\usr\bin\swift.exe`` (the swift.org Windows installer layout)
# first, then under ``<ver>\bin\swift.exe`` as a fallback, then accept
# ``D:\metacraft-dev-deps\swift\swift.exe`` directly.
$swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
if (-not $swiftCmd) {
  $swiftRoot = 'D:\metacraft-dev-deps\swift'
  if (Test-Path -LiteralPath $swiftRoot) {
    $candidates = @()
    $direct = Join-Path $swiftRoot 'swift.exe'
    if (Test-Path -LiteralPath $direct) { $candidates += $direct }
    foreach ($verDir in Get-ChildItem -LiteralPath $swiftRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($candidate in @(
        (Join-Path $verDir.FullName 'usr\bin\swift.exe'),
        (Join-Path $verDir.FullName 'bin\swift.exe'))) {
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
      }
    }
    if ($candidates.Count -gt 0) {
      $picked = $candidates | Sort-Object | Select-Object -Last 1
      $binDir = Split-Path -Parent $picked
      if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
        $env:PATH = "$binDir;$env:PATH"
      }
      $swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
    }
  }
}
if (-not $swiftCmd) {
  Write-Host "SKIP: 'swift' not on PATH (M43 swift-swiftpm convention needs the Swift toolchain; install Swift 5.10 from swift.org into D:/metacraft-dev-deps/swift/5.10/ or 'winget install Swift.Toolchain')"
  exit 0
}

Write-Host "==> using swift=$($swiftCmd.Source)"

# M51 honest-scope: Swift on Windows uses the MSVC ABI, so ``swift
# build`` shells out to ``link.exe`` from VS 2022 Build Tools at link
# time. The swift.org installer does NOT bundle that — it's a separate
# Microsoft installer. Probe for VS via vswhere (the canonical
# Microsoft-supported VS-install discovery tool); a bare ``Get-Command
# link.exe`` won't work because MSYS2 / Git-bash ship a POSIX
# ``link.exe`` (hard-link coreutil) that shadows the MSVC linker
# without satisfying Swift's MSVC-toolchain probe.
$vsLink = $null
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vsWhere) {
  $vsInstall = (& $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
  if ($vsInstall) {
    $vsLink = "vswhere:$vsInstall"
  }
}
if (-not $vsLink) {
  Write-Host "SKIP: Swift toolchain is present but VS 2022 Build Tools (MSVC link.exe + Windows SDK) is missing — Swift on Windows uses the MSVC ABI and shells out to MSVC link.exe at link time. Install via 'winget install Microsoft.VisualStudio.2022.BuildTools --override `"--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`"' and re-run. (MSYS2 / Git-bash ship a POSIX link.exe that does NOT satisfy Swift's MSVC-toolchain probe.)"
  exit 0
}
Write-Host "==> using vs-build-tools=$vsLink"

# --- step 1: clean prior scratch + .build dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $buildInsideFixture) {
  Write-Host "wiping prior SwiftPM .build dir $buildInsideFixture"
  Remove-Item -LiteralPath $buildInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-swift-swiftpm-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-swift-swiftpm-hello-binary.stderr.txt'
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

# --- step 3: locate produced exe ---
# Try the symlink path first (``.build/release/hello[.exe]``) then
# fall back to the triple-specific subdir SwiftPM sometimes uses
# directly (when the platform doesn't support symlinks the release
# subdir contains the build artefacts directly under a triple subdir).
$exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.exe' } else { 'hello' }
$producedExe = Join-Path $fixture (".build\release\" + $exeName)
if (-not (Test-Path -LiteralPath $producedExe)) {
  # Walk .build for the produced binary as a fallback.
  $candidates = Get-ChildItem -LiteralPath $buildInsideFixture -Filter $exeName -Recurse -ErrorAction SilentlyContinue
  if ($candidates -and $candidates.Count -gt 0) {
    $producedExe = $candidates[0].FullName
  }
}
if (-not (Test-Path -LiteralPath $producedExe)) {
  Write-Host "FAIL: expected exe not found at $producedExe"
  if (Test-Path $buildInsideFixture) {
    Write-Host "--- contents of ${buildInsideFixture}:"
    Get-ChildItem -LiteralPath $buildInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no SwiftPM .build dir)"
  }
  exit 1
}
Write-Host "produced exe: $producedExe"
Write-Host "  size: $((Get-Item $producedExe).Length) bytes"

# --- step 4: run exe and assert greeting ---
Write-Host "==> running $producedExe"
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
Write-Host "PASS: swift-swiftpm/hello-binary built via standard provider; greeting matched"
exit 0
