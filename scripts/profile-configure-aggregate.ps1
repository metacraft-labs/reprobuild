#requires -Version 5
# Runs a zlib configure with REPRO_STATS_DIR enabled, then aggregates
# per-invocation records into a configure-level breakdown.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$cmakeExe   = Join-Path $repoRoot '..\reprobuild-cmake\build\bin\cmake.exe'
$reproExe   = Join-Path $repoRoot 'build\bin\repro.exe'
$source     = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\cmake-driver\source'
$workRoot   = Join-Path $repoRoot 'build\profile-configure-aggregate'
$store      = Join-Path $workRoot 'store'
$buildDir   = Join-Path $workRoot 'project'
$statsDir   = Join-Path $workRoot 'stats'

if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path $store    | Out-Null
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
New-Item -ItemType Directory -Force -Path $statsDir | Out-Null

$env:REPROBUILD_STORE_ROOT = $store
$env:REPROBUILD_REPRO      = $reproExe
$env:REPRO_STATS_DIR       = $statsDir

$gcc = (Get-Command gcc.exe).Source
$args = @(
  '-S', $source, '-B', $buildDir, '-G', 'Reprobuild',
  "-DCMAKE_C_COMPILER=$($gcc -replace '\\','/')",
  "-DCMAKE_MAKE_PROGRAM=$($reproExe -replace '\\','/')",
  '-DCMAKE_BUILD_TYPE=Release'
)

Write-Host "==> Configuring zlib with REPRO_STATS_DIR=$statsDir"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $cmakeExe -ArgumentList $args -NoNewWindow -PassThru -Wait `
  -RedirectStandardOutput "$workRoot\cmake.stdout.log" `
  -RedirectStandardError  "$workRoot\cmake.stderr.log"
$sw.Stop()
$outerWallMs = $sw.Elapsed.TotalMilliseconds
Write-Host ("    exit={0,-3} wall={1,8:F1} ms" -f $proc.ExitCode, $outerWallMs)

if ($proc.ExitCode -ne 0) {
  Write-Host "==> stderr tail"
  Get-Content "$workRoot\cmake.stderr.log" -Tail 30 | ForEach-Object { "    $_" } | Write-Host
  exit 1
}

Write-Host ""
Write-Host "==> Aggregating $((Get-ChildItem -LiteralPath $statsDir).Count) stats records"
Write-Host ""

# To enable individual repro build invocations to emit a stats record we
# also need them to actually populate their internal BuildStats — i.e. run
# with --stats=text. The bench harness sets this via REPROBUILD_DEFAULT_STATS
# but vanilla CMake invocations don't, so the metrics array on each record
# will be empty until we add a knob for that. The wall-time + fastPath
# fields are populated regardless.

& python "$PSScriptRoot\aggregate-stats.py" $statsDir --outer-wall-ms $outerWallMs --per-invocation
