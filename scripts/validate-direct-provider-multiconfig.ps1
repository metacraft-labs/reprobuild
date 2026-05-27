#requires -Version 5
# M10 verification gate: e2e_cmake_multiconfig_via_direct_provider.
#
# Configure a multi-config CMake project (CMAKE_CROSS_CONFIGS +
# CMAKE_DEFAULT_CONFIGS) under the Reprobuild generator, then build
# both Debug and Release. Assert the configure emits a v3
# trycompile.rbsz envelope, that PrimeProviderMetadata routes through
# tier2c-direct-prepare (the direct provider), and that no slow-path /
# providerCompile fallback fired during configure or build.
#
# Per Provider-Compile-Tiering.md §"2c" and
# Standard-Provider-Implementation.milestones.org M10.
#
# Two fixtures are exercised:
#
# 1. A minimal hand-written multi-config CMake project (no try_compile
#    probes). This is the gate the milestone is greppable against — it
#    proves the direct provider's lowering of cross-config descriptors
#    works end-to-end with a real CMake configure + build.
#
# 2. (Optional) The pre-staged zlib fixture with multi-config flags.
#    zlib invokes CMake's check_type_size / check_function_exists, which
#    triggers ``try_compile(... COPY_FILE ...)`` probes. The Reprobuild
#    generator's multi-config support for those inner probes pre-dates
#    M10 and is independent — when the inner probe build path fails the
#    block emits an INFO line and continues. The hand-written fixture is
#    sufficient to validate the M10 code path on its own.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$cmakeExe   = Join-Path $repoRoot '..\reprobuild-cmake\build\bin\cmake.exe'
$reproExe   = Join-Path $repoRoot 'build\bin\repro.exe'
$workRoot   = Join-Path $repoRoot 'build\validate-direct-provider-multiconfig'

if (-not (Test-Path -LiteralPath $cmakeExe)) {
  Write-Host "SKIP: reprobuild-cmake's cmake.exe missing at $cmakeExe"
  Write-Host "      build it via:  cd ../reprobuild-cmake && cmake --build build --target cmake"
  exit 0
}
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "SKIP: repro.exe missing at $reproExe — run scripts\build_apps.sh first"
  exit 0
}

function Remove-Tree([string]$p) {
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Remove-Tree $workRoot
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$gcc = (Get-Command gcc.exe).Source

function Invoke-Fixture {
  param(
    [string]$Label,
    [string]$Source,
    [bool]$Optional = $false
  )
  $caseRoot  = Join-Path $workRoot $Label
  $store     = Join-Path $caseRoot 'store'
  $buildDir  = Join-Path $caseRoot 'project'
  $statsDir  = Join-Path $caseRoot 'stats'
  New-Item -ItemType Directory -Force -Path $store, $buildDir, $statsDir | Out-Null

  $env:REPROBUILD_STORE_ROOT = $store
  $env:REPROBUILD_REPRO      = $reproExe
  $env:REPRO_STATS_DIR       = $statsDir

  $configureArgs = @(
    '-S', $Source,
    '-B', $buildDir,
    '-G', 'Reprobuild',
    "-DCMAKE_C_COMPILER=$($gcc -replace '\\','/')",
    "-DCMAKE_MAKE_PROGRAM=$($reproExe -replace '\\','/')",
    '-DCMAKE_CONFIGURATION_TYPES=Debug;Release',
    '-DCMAKE_CROSS_CONFIGS=Debug;Release',
    '-DCMAKE_DEFAULT_CONFIGS=Debug;Release',
    '-DCMAKE_DEFAULT_BUILD_TYPE=Debug'
  )

  Write-Host ""
  Write-Host ("==> [{0}] configure" -f $Label)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process -FilePath $cmakeExe -ArgumentList $configureArgs `
    -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput "$caseRoot\configure.stdout.log" `
    -RedirectStandardError  "$caseRoot\configure.stderr.log"
  $sw.Stop()
  Write-Host ("    exit={0,-3} wall={1,8:F1} ms" -f $proc.ExitCode, $sw.Elapsed.TotalMilliseconds)
  if ($proc.ExitCode -ne 0) {
    if ($Optional) {
      Write-Host ("    INFO [{0}]: configure failed (optional fixture); recording but not failing" -f $Label)
      Write-Host "--- configure.stderr.log tail ---"
      Get-Content "$caseRoot\configure.stderr.log" -Tail 20 | ForEach-Object { "    $_" } | Write-Host
      return [pscustomobject]@{ Label = $Label; Passed = $true; Optional = $true; Skipped = $true }
    }
    Write-Host "FAIL: $Label configure exited $($proc.ExitCode)"
    Write-Host "--- configure.stderr.log tail ---"
    Get-Content "$caseRoot\configure.stderr.log" -Tail 40 | ForEach-Object { "    $_" } | Write-Host
    Write-Host "--- configure.stdout.log tail ---"
    Get-Content "$caseRoot\configure.stdout.log" -Tail 40 | ForEach-Object { "    $_" } | Write-Host
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }

  # Verify trycompile.rbsz emitted and v3.
  $tcFile = Join-Path $buildDir 'trycompile.rbsz'
  if (-not (Test-Path -LiteralPath $tcFile)) {
    Write-Host "FAIL: $Label configure did not emit trycompile.rbsz"
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }
  $bytes = [System.IO.File]::ReadAllBytes($tcFile)
  $magic = -join ($bytes[0..3] | ForEach-Object { [char]$_ })
  $version = $bytes[4] -bor ($bytes[5] -shl 8)
  Write-Host ("    trycompile.rbsz magic={0} version={1} size={2} bytes" -f $magic, $version, $bytes.Length)
  if ($magic -ne 'RBCT') {
    Write-Host "FAIL: $Label unexpected trycompile.rbsz magic '$magic'"
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }
  if ($version -ne 3) {
    Write-Host "FAIL: $Label expected v3 envelope, got v$version"
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }

  function Read-Stats([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Filter '*.json' | ForEach-Object {
      try {
        Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
      } catch {
        $null
      }
    } | Where-Object { $_ -ne $null })
  }

  $records = Read-Stats $statsDir
  Write-Host ("    captured {0} stats records during configure" -f $records.Count)
  $tier2c = 0
  $slow   = 0
  foreach ($r in $records) {
    if ($r.fastPath -eq 'tier2c-direct-prepare') { $tier2c++ }
    elseif (-not $r.fastPath -or $r.fastPath -eq 'slow-path') { $slow++ }
  }
  $counts = @{}
  foreach ($r in $records) {
    $t = if ($r.fastPath) { $r.fastPath } else { 'slow-path' }
    if ($counts.ContainsKey($t)) { $counts[$t]++ } else { $counts[$t] = 1 }
  }
  foreach ($k in ($counts.Keys | Sort-Object)) {
    Write-Host ("        {0,4} {1}" -f $counts[$k], $k)
  }
  if ($tier2c -lt 1) {
    Write-Host "FAIL: $Label captured 0 tier2c-direct-prepare records (main project did not route through the direct provider)"
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }
  if ($slow -gt 0) {
    Write-Host "FAIL: $Label captured $slow slow-path records during configure (providerCompile fallback fired)"
    return [pscustomobject]@{ Label = $Label; Passed = $false }
  }

  # Build both configs.
  foreach ($config in 'Debug', 'Release') {
    Write-Host ("==> [{0}] build config={1}" -f $Label, $config)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $cmakeExe `
      -ArgumentList @('--build', $buildDir, '--config', $config) `
      -NoNewWindow -PassThru -Wait `
      -RedirectStandardOutput "$caseRoot\build-$config.stdout.log" `
      -RedirectStandardError  "$caseRoot\build-$config.stderr.log"
    $sw.Stop()
    Write-Host ("    exit={0,-3} wall={1,8:F1} ms" -f $proc.ExitCode, $sw.Elapsed.TotalMilliseconds)
    if ($proc.ExitCode -ne 0) {
      if ($Optional) {
        Write-Host ("    INFO [{0}]: build $config failed (optional fixture); continuing" -f $Label)
        Get-Content "$caseRoot\build-$config.stderr.log" -Tail 20 | ForEach-Object { "    $_" } | Write-Host
        continue
      }
      Write-Host "FAIL: $Label build $config exited $($proc.ExitCode)"
      Get-Content "$caseRoot\build-$config.stderr.log" -Tail 30 | ForEach-Object { "    $_" } | Write-Host
      Get-Content "$caseRoot\build-$config.stdout.log" -Tail 30 | ForEach-Object { "    $_" } | Write-Host
      return [pscustomobject]@{ Label = $Label; Passed = $false }
    }
  }

  $records = Read-Stats $statsDir
  $slow = 0
  foreach ($r in $records) {
    if (-not $r.fastPath -or $r.fastPath -eq 'slow-path') { $slow++ }
  }
  Write-Host ("    post-build records: {0} (slow-path: {1})" -f $records.Count, $slow)
  if ($slow -gt 0) {
    if ($Optional) {
      Write-Host "    INFO: slow-path observed post-build but fixture is optional"
    } else {
      Write-Host "FAIL: $Label observed $slow slow-path records after build"
      return [pscustomobject]@{ Label = $Label; Passed = $false }
    }
  }

  return [pscustomobject]@{ Label = $Label; Passed = $true }
}

# Fixture A: minimal hand-written multi-config project. No try_compile
# probes — the focus is exclusively the M10 cross-config aggregate path.
$miniSrc = Join-Path $workRoot 'mini-src'
New-Item -ItemType Directory -Force -Path $miniSrc | Out-Null
@'
cmake_minimum_required(VERSION 3.20)
project(reprobuild_m10_mini C)
# Two independent targets (no inter-target link dependency) so we
# exercise the multi-config per-config aggregate fanout without
# tripping over orthogonal multi-config target-output-path issues.
add_library(libgreet STATIC greet.c)
add_executable(standalone main.c)
'@ | Out-File "$miniSrc\CMakeLists.txt" -Encoding ascii
@'
int greet(void) { return 42; }
'@ | Out-File "$miniSrc\greet.c" -Encoding ascii
@'
int main(void) { return 0; }
'@ | Out-File "$miniSrc\main.c" -Encoding ascii

$miniResult = Invoke-Fixture -Label 'mini' -Source $miniSrc -Optional:$false

# Fixture B (optional): zlib if the bench fixture has staged a source.
# zlib uses check_type_size which triggers ``try_compile(COPY_FILE)``.
# The Reprobuild generator's TryCompile-in-multi-config probe path is
# orthogonal to M10 (the inner probe's build phase has issues with
# COPY_FILE-style probes that pre-date the schema bump). If the zlib
# fixture path exists we still attempt it for coverage, but the gate
# does not require it to pass.
$zlibSrc = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\direct\source'
if (Test-Path -LiteralPath (Join-Path $zlibSrc 'CMakeLists.txt')) {
  Write-Host ""
  Write-Host "==> Optional zlib multi-config fixture detected"
  $null = Invoke-Fixture -Label 'zlib' -Source $zlibSrc -Optional:$true
} else {
  Write-Host ""
  Write-Host "INFO: zlib fixture missing at $zlibSrc — skipping optional zlib coverage"
}

Write-Host ""
if (-not $miniResult.Passed) {
  Write-Host "FAIL: primary multi-config fixture did not pass"
  exit 1
}
Write-Host "PASS: multi-config CMake routes through Tier 2c direct provider (no provider-compile fallback)"
exit 0
