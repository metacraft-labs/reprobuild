#requires -Version 5
# Validate cross-project TryCompile cache hits via canonical source paths.
# Run two zlib configures against the same shared action cache from distinct
# binary dirs and report (a) presence of the canonical-source mirror, (b)
# wall-time delta between cold and warm configure, (c) action-cache hits.

$ErrorActionPreference = 'Stop'

# Source the workspace env.ps1 so nim, gcc, and friends are on PATH.
# The reprobuild provider compile inside CMake's TryCompile shells out to
# nim directly, so the parent shell must already have nim resolved.
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot     = (Resolve-Path "$PSScriptRoot\..").Path
$source       = Join-Path $repoRoot 'build\cmake-generator-competitiveness\projects\zlib\cmake-driver\source'
$buildA       = Join-Path $repoRoot 'build\validate-canonical-source\projectA'
$buildB       = Join-Path $repoRoot 'build\validate-canonical-source\projectB'
$store        = Join-Path $repoRoot 'build\validate-canonical-source\store'
$cmakeExe     = Join-Path $repoRoot '..\reprobuild-cmake\build\bin\cmake.exe'
$reproExe     = Join-Path $repoRoot 'build\bin\repro.exe'
$runquotadExe = Join-Path $repoRoot '..\runquota\build\bin\runquotad.exe'
$ninjaExe     = (Get-Command ninja).Source

function Remove-Tree([string]$p) {
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "==> Resetting store and project build dirs"
Remove-Tree $store
Remove-Tree $buildA
Remove-Tree $buildB
New-Item -ItemType Directory -Force -Path $store    | Out-Null
New-Item -ItemType Directory -Force -Path $buildA   | Out-Null
New-Item -ItemType Directory -Force -Path $buildB   | Out-Null

$env:REPROBUILD_STORE_ROOT = $store
$env:REPROBUILD_REPRO      = $reproExe

# Resolve a plain mingw gcc on PATH for the configure.
$gcc = (Get-Command gcc.exe).Source
$compilerFlags = @(
  "-DCMAKE_C_COMPILER=$($gcc -replace '\\','/')",
  "-DCMAKE_MAKE_PROGRAM=$($reproExe -replace '\\','/')",
  '-DCMAKE_BUILD_TYPE=Release'
)

function Invoke-Configure([string]$buildDir, [string]$tag) {
  Write-Host ""
  Write-Host "==> [$tag] configure: $buildDir"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $args = @('-S', $source, '-B', $buildDir, '-G', 'Reprobuild') + $compilerFlags
  $proc = Start-Process -FilePath $cmakeExe -ArgumentList $args -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput "$buildDir\configure.stdout.log" `
            -RedirectStandardError  "$buildDir\configure.stderr.log"
  $sw.Stop()
  $ok = ($proc.ExitCode -eq 0)
  Write-Host ("    exit={0,-3} wall={1,7:F1} ms" -f $proc.ExitCode, $sw.Elapsed.TotalMilliseconds)
  if (-not $ok) {
    Write-Host "    --- stderr tail ---"
    Get-Content "$buildDir\configure.stderr.log" -Tail 40 | ForEach-Object { "    $_" } | Write-Host
  }
  return [pscustomobject]@{ Tag = $tag; Ok = $ok; WallMs = $sw.Elapsed.TotalMilliseconds; BuildDir = $buildDir }
}

$a = Invoke-Configure $buildA 'cold (project A)'
$b = Invoke-Configure $buildB 'warm (project B, shared store)'

Write-Host ""
Write-Host "==> Canonical TryCompile sources observed under $store\cmake-trycompile-sources"
if (Test-Path -LiteralPath "$store\cmake-trycompile-sources") {
  Get-ChildItem -LiteralPath "$store\cmake-trycompile-sources" -Recurse -File |
    Select-Object FullName, Length |
    Format-Table -AutoSize | Out-String | Write-Host
} else {
  Write-Host "    (none — change did not fire)"
}

Write-Host "==> Action-cache content snapshot"
if (Test-Path -LiteralPath "$store\action-cache") {
  $entries = Get-ChildItem -LiteralPath "$store\action-cache" -Recurse -File -ErrorAction SilentlyContinue
  Write-Host ("    files: {0}; bytes: {1:N0}" -f $entries.Count, (($entries | Measure-Object Length -Sum).Sum))
} else {
  Write-Host "    (none)"
}

Write-Host ""
Write-Host "==> Wall-time comparison"
Write-Host ("    project A cold: {0,8:F1} ms" -f $a.WallMs)
Write-Host ("    project B warm: {0,8:F1} ms" -f $b.WallMs)
if ($a.WallMs -gt 0) {
  $delta = ($b.WallMs / $a.WallMs)
  Write-Host ("    ratio B/A    : {0,8:F3}" -f $delta)
}

if (-not ($a.Ok -and $b.Ok)) {
  Write-Host "==> One or more configures failed"
  exit 1
}
exit 0
