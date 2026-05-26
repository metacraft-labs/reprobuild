#requires -Version 5
# Tries to enumerate what time-attribution data we can currently extract
# from a single zlib configure under the Reprobuild generator. The script:
#   1. Configures zlib with Reprobuild and a per-process timing trace
#   2. Walks the CMake scratch dirs after the configure to see what state
#      survived (and could be used by an aggregator script we'd write)
#   3. Prints what is and isn't recoverable from existing telemetry

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$cmakeExe   = Join-Path $repoRoot '..\reprobuild-cmake\build\bin\cmake.exe'
$reproExe   = Join-Path $repoRoot 'build\bin\repro.exe'
$source     = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\cmake-driver\source'
$workRoot   = Join-Path $repoRoot 'build\profile-trycompile'
$store      = Join-Path $workRoot 'store'
$buildDir   = Join-Path $workRoot 'project'
$tracePath  = Join-Path $workRoot 'provider-trace.txt'

if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
New-Item -ItemType Directory -Force -Path $store    | Out-Null
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$env:REPROBUILD_STORE_ROOT = $store
$env:REPROBUILD_REPRO      = $reproExe
$env:REPRO_PROVIDER_TRACE  = $tracePath
$env:CMAKE_TRYCOMPILE_NO_CLEAN = '1'  # keep TryCompile scratch dirs so we can inspect them

$gcc = (Get-Command gcc.exe).Source
$args = @(
  '-S', $source, '-B', $buildDir, '-G', 'Reprobuild',
  "-DCMAKE_C_COMPILER=$($gcc -replace '\\','/')",
  "-DCMAKE_MAKE_PROGRAM=$($reproExe -replace '\\','/')",
  '-DCMAKE_BUILD_TYPE=Release'
)

Write-Host "==> Configuring zlib"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $cmakeExe -ArgumentList $args -NoNewWindow -PassThru -Wait `
  -RedirectStandardOutput "$workRoot\cmake.stdout.log" `
  -RedirectStandardError  "$workRoot\cmake.stderr.log"
$sw.Stop()
Write-Host ("    exit={0,-3} wall={1,8:F1} ms" -f $proc.ExitCode, $sw.Elapsed.TotalMilliseconds)

if ($proc.ExitCode -ne 0) {
  Write-Host "==> stderr tail"
  Get-Content "$workRoot\cmake.stderr.log" -Tail 30 | ForEach-Object { "    $_" } | Write-Host
  exit 1
}

Write-Host ""
Write-Host "==> What telemetry we have today"

Write-Host ""
Write-Host "1. REPRO_PROVIDER_TRACE — one line per provider invocation:"
if (Test-Path -LiteralPath $tracePath) {
  $lines = Get-Content -LiteralPath $tracePath
  Write-Host ("   {0} provider invocations recorded" -f $lines.Count)
  Write-Host "   sample: $($lines[0])"
} else {
  Write-Host "   (none recorded)"
}

Write-Host ""
Write-Host "2. Per-probe provider snapshots (provider-graph/provider-fragments.rbsz):"
$snapshots = Get-ChildItem -LiteralPath $buildDir -Recurse -Filter 'provider-fragments.rbsz' -ErrorAction SilentlyContinue
Write-Host ("   {0} snapshot files written" -f @($snapshots).Count)
foreach ($s in $snapshots) {
  Write-Host ("   {0,8} bytes  {1}" -f $s.Length, $s.FullName.Substring($buildDir.Length + 1))
}

Write-Host ""
Write-Host "3. Per-probe trycompile.rbsz metadata:"
$metas = Get-ChildItem -LiteralPath $buildDir -Recurse -Filter 'trycompile.rbsz' -ErrorAction SilentlyContinue
Write-Host ("   {0} metadata files written" -f @($metas).Count)

Write-Host ""
Write-Host "4. CMake's own per-probe timing (CMakeOutput.log / CMakeError.log):"
$cmakeOutput = Join-Path $buildDir 'CMakeFiles\CMakeOutput.log'
if (Test-Path -LiteralPath $cmakeOutput) {
  $sz = (Get-Item $cmakeOutput).Length
  Write-Host ("   CMakeOutput.log = {0:N0} bytes" -f $sz)
  Write-Host "   (no per-action wall-time fields — CMake records exit codes + stdout but not durations)"
} else {
  Write-Host "   (none)"
}

Write-Host ""
Write-Host "5. Per-repro-build-invocation --stats output:"
Write-Host "   Each TryCompile spawns its own 'repro build' process. Those processes were"
Write-Host "   launched WITHOUT --stats by CMake, so no per-invocation tables exist on disk."
Write-Host "   To capture them we'd have to set REPROBUILD_DEFAULT_STATS=text or similar."

Write-Host ""
Write-Host "==> What we are MISSING for a precise breakdown"
Write-Host "    a) Configure-level aggregation of repro-build stats across all N probes"
Write-Host "    b) Per-probe wall time + which sub-phase ate which fraction"
Write-Host "    c) cmake-self vs repro-build vs gcc time split"
Write-Host ""
Write-Host "    To get (a) + (b) we would add a REPRO_STATS_DIR env var that each"
Write-Host "    'repro build' invocation appends a JSON record to, then a small"
Write-Host "    aggregator script computes the breakdown."
Write-Host "    To get (c) we would also wrap the cmake invocation with a process-tree"
Write-Host "    timer (e.g. Procmon or a Nim-side child-process accounting hook)."
