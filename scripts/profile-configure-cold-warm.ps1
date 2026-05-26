#requires -Version 5
# Run two zlib configures against the same shared store: cold then warm.
# Aggregate each separately and print the delta. The warm run should
# benefit from the Phase 1 user-level action cache + the per-project
# provider-artifact freshness check.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$cmakeExe   = Join-Path $repoRoot '..\reprobuild-cmake\build\bin\cmake.exe'
$reproExe   = Join-Path $repoRoot 'build\bin\repro.exe'
$source     = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\cmake-driver\source'
$workRoot   = Join-Path $repoRoot 'build\profile-configure-cold-warm'
$store      = Join-Path $workRoot 'store'

if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path $store    | Out-Null

$env:REPROBUILD_STORE_ROOT = $store
$env:REPROBUILD_REPRO      = $reproExe
$gcc = (Get-Command gcc.exe).Source

function Run-Configure([string]$tag, [string]$buildSub) {
  $buildDir = Join-Path $workRoot $buildSub
  $statsDir = Join-Path $workRoot "stats-$buildSub"
  New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
  New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
  $env:REPRO_STATS_DIR = $statsDir

  $args = @(
    '-S', $source, '-B', $buildDir, '-G', 'Reprobuild',
    "-DCMAKE_C_COMPILER=$($gcc -replace '\\','/')",
    "-DCMAKE_MAKE_PROGRAM=$($reproExe -replace '\\','/')",
    '-DCMAKE_BUILD_TYPE=Release'
  )

  Write-Host ""
  Write-Host ("==> [{0}] configuring zlib (REPRO_STATS_DIR={1})" -f $tag, $statsDir)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process -FilePath $cmakeExe -ArgumentList $args -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput "$buildDir\cmake.stdout.log" `
    -RedirectStandardError  "$buildDir\cmake.stderr.log"
  $sw.Stop()
  $wall = $sw.Elapsed.TotalMilliseconds
  Write-Host ("    exit={0,-3} wall={1,8:F1} ms" -f $proc.ExitCode, $wall)
  if ($proc.ExitCode -ne 0) {
    Get-Content "$buildDir\cmake.stderr.log" -Tail 20 | ForEach-Object { "    $_" } | Write-Host
    throw "configure failed"
  }

  Write-Host "    aggregating $(@(Get-ChildItem -LiteralPath $statsDir).Count) records"
  & python "$PSScriptRoot\aggregate-stats.py" $statsDir --outer-wall-ms $wall | ForEach-Object { "    $_" } | Write-Host
  return $wall
}

$cold = Run-Configure 'cold' 'projectA'
$warm = Run-Configure 'warm' 'projectB'

Write-Host ""
Write-Host "==> Cold vs warm summary"
Write-Host ("    cold outer wall : {0,8:F1} ms" -f $cold)
Write-Host ("    warm outer wall : {0,8:F1} ms" -f $warm)
if ($cold -gt 0) {
  $deltaMs  = $warm - $cold
  $deltaPct = ($warm - $cold) / $cold * 100
  $deltaMsStr  = ('{0,9:F1}' -f $deltaMs)
  $deltaPctStr = ('{0,6:F1}' -f $deltaPct)
  Write-Host "    delta           : $deltaMsStr ms ($deltaPctStr %)"
}
