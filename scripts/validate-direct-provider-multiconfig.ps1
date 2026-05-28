#requires -Version 5
# M10 + M19 verification gate: e2e_cmake_multiconfig_via_direct_provider.
#
# Configure a multi-config CMake project (CMAKE_CROSS_CONFIGS +
# CMAKE_DEFAULT_CONFIGS) under the Reprobuild generator, then build
# both Debug and Release. Assert the configure emits a v3
# trycompile.rbsz envelope, that PrimeProviderMetadata routes through
# tier2c-direct-prepare (the direct provider), and that no slow-path /
# providerCompile fallback fired during configure or build.
#
# Per Provider-Compile-Tiering.md §"2c" and
# Standard-Provider-Implementation.milestones.org M10 + M19.
#
# Three fixtures are exercised:
#
# 1. A minimal hand-written multi-config CMake project (no try_compile
#    probes). This is the gate the M10 milestone is greppable against — it
#    proves the direct provider's lowering of cross-config descriptors
#    works end-to-end with a real CMake configure + build.
#
# 2. A hand-written multi-config CMake project that calls
#    ``check_type_size`` (a CMake check that uses
#    ``try_compile(... COPY_FILE ...)`` internally). This is the M19 gate:
#    it proves the Reprobuild generator's inner-build COPY_FILE path
#    populates the per-config ``<NAME>_loc`` location file the outer
#    cmake's ``FindOutputFile`` looks for. Before M19 this configure step
#    failed with "Unable to find the recorded try_compile output location:
#    cmTC_<hash>_DEBUG_loc".
#
# 3. (Optional) The pre-staged zlib fixture with multi-config flags.
#    zlib invokes ``check_type_size(off64_t HAVE_OFF64_T)``, which
#    exercises exactly the same COPY_FILE inner-build path as fixture 2.
#    Build of the zlib SHARED target itself currently trips an orthogonal
#    Reprobuild generator bug (``add_custom_command`` output paths for the
#    MinGW ``zlib1rc.obj`` resource are config-prefixed in the link line
#    but written to the binary dir without a config prefix), so this
#    fixture's build step remains optional even after M19 fixes the
#    configure step. The hand-written ``check_type_size`` fixture is the
#    load-bearing M19 PASS case.

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
    [bool]$Optional = $false,
    [hashtable]$AssertCacheEntries = $null,
    [bool]$OptionalBuild = $false
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

  # M19 hook: validate that any caller-supplied CMakeCache entries are set
  # (e.g. ``HAVE_OFF64_T = TRUE`` for the check_type_size fixtures). This
  # is the load-bearing assertion that the inner-build COPY_FILE probe
  # actually populated CMake's check result variables — a configure that
  # silently treats COPY_FILE probes as "not found" would otherwise still
  # exit 0 with the cache showing FALSE.
  if ($AssertCacheEntries -and $AssertCacheEntries.Count -gt 0) {
    $cachePath = Join-Path $buildDir 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $cachePath)) {
      Write-Host "FAIL: $Label CMakeCache.txt missing at $cachePath"
      return [pscustomobject]@{ Label = $Label; Passed = $false }
    }
    $cacheLines = Get-Content -LiteralPath $cachePath
    foreach ($key in $AssertCacheEntries.Keys) {
      $expected = $AssertCacheEntries[$key]
      $pattern = "^$([regex]::Escape($key)):[^=]+=(.*)$"
      $line = $cacheLines | Where-Object { $_ -match $pattern } | Select-Object -First 1
      if (-not $line) {
        Write-Host "FAIL: $Label CMakeCache missing entry $key (expected $expected)"
        return [pscustomobject]@{ Label = $Label; Passed = $false }
      }
      $matched = [regex]::Match($line, $pattern)
      $actual = $matched.Groups[1].Value
      if ($actual -ne $expected) {
        Write-Host ("FAIL: {0} CMakeCache {1} = '{2}' (expected '{3}')" -f $Label, $key, $actual, $expected)
        return [pscustomobject]@{ Label = $Label; Passed = $false }
      }
      Write-Host ("    cache assert {0} = {1}  (ok)" -f $key, $actual)
    }
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
      if ($Optional -or $OptionalBuild) {
        Write-Host ("    INFO [{0}]: build $config failed (optional build); continuing" -f $Label)
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

# Fixture B (M19 PASS): hand-written multi-config project that calls
# ``check_type_size`` — the smallest possible exercise of the
# ``try_compile(... COPY_FILE ...)`` inner-build path. Before M19 the
# configure step here failed with "Unable to find the recorded
# try_compile output location: cmTC_<hash>_DEBUG_loc" because the
# inner project (single-config under Reprobuild) wrote the file(GENERATE)
# location file at ``cmTC_<hash>__loc`` (empty config) while the outer
# multi-config cmake's ``FindOutputFile`` looked for the
# ``_<UPPER_CONFIG>_loc`` variant.
#
# The fixture also asserts ``HAVE_INT`` / ``HAVE_LONG`` got populated in
# CMakeCache.txt — without that the configure can exit 0 while silently
# treating the COPY_FILE probe as "not found", which would defeat the
# whole purpose of the gate.
$checkSizeSrc = Join-Path $workRoot 'check-type-size-src'
New-Item -ItemType Directory -Force -Path $checkSizeSrc | Out-Null
@'
cmake_minimum_required(VERSION 3.20)
project(reprobuild_m19_check_type_size C)
include(CheckTypeSize)
check_type_size(int  HAVE_INT)
check_type_size(long HAVE_LONG)
add_library(libgreet STATIC greet.c)
add_executable(standalone main.c)
'@ | Out-File "$checkSizeSrc\CMakeLists.txt" -Encoding ascii
@'
int greet(void) { return 42; }
'@ | Out-File "$checkSizeSrc\greet.c" -Encoding ascii
@'
int main(void) { return 0; }
'@ | Out-File "$checkSizeSrc\main.c" -Encoding ascii

$checkSizeResult = Invoke-Fixture `
  -Label 'check_type_size' `
  -Source $checkSizeSrc `
  -Optional:$false `
  -AssertCacheEntries @{ HAVE_INT = '4'; HAVE_LONG = '4' }

# Fixture C (optional configure pass-through): zlib if the bench fixture
# has staged a source. zlib's ``check_type_size(off64_t HAVE_OFF64_T)``
# exercises exactly the same COPY_FILE inner-build path as fixture B and
# is the original M10/M19 motivating regression. Before M19 this fixture's
# configure step failed at ``check_type_size``; after M19 the configure
# passes and ``HAVE_OFF64_T`` lands in CMakeCache.
#
# M27 (closed): the ``add_custom_command`` config-prefix bug that blocked
# zlib's MinGW ``zlib1rc.obj`` resource-compile path is fixed —
# ``cmGlobalReprobuildGenerator.cxx`` no longer config-prefixes
# custom-command OUTPUT/BYPRODUCTS or the link-line external-object
# input, so the file the COMMAND writes and the path the link line
# references are now in agreement. Build of zlib's SHARED target still
# trips a separate, orthogonal bug: the import library ``libzlib.dll.a``
# is written at ``<config>/libzlib.dll.a`` but the link-line text
# computed by ``cmComputeLinkInformation`` references it unprefixed.
# That second bug is tracked under M27 Outstanding Tasks; it is not in
# scope for the M19/M27 deliverable.
$zlibSrc = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\direct\source'
$zlibResult = $null
if (Test-Path -LiteralPath (Join-Path $zlibSrc 'CMakeLists.txt')) {
  Write-Host ""
  Write-Host "==> zlib multi-config fixture detected (M19 configure-side pass case)"
  $zlibResult = Invoke-Fixture `
    -Label 'zlib' `
    -Source $zlibSrc `
    -Optional:$false `
    -OptionalBuild:$true `
    -AssertCacheEntries @{ HAVE_OFF64_T = 'TRUE' }
} else {
  Write-Host ""
  Write-Host "INFO: zlib fixture missing at $zlibSrc — skipping zlib coverage (M19 still gated by the check_type_size fixture)"
}

Write-Host ""
if (-not $miniResult.Passed) {
  Write-Host "FAIL: mini multi-config fixture did not pass"
  exit 1
}
if (-not $checkSizeResult.Passed) {
  Write-Host "FAIL: check_type_size multi-config fixture did not pass (M19)"
  exit 1
}
if ($zlibResult -and -not $zlibResult.Passed) {
  Write-Host "FAIL: zlib multi-config configure did not pass (M19)"
  exit 1
}
Write-Host "PASS: multi-config CMake routes through Tier 2c direct provider; check_type_size COPY_FILE probes resolve per-config _loc files (M10 + M19)"
exit 0
