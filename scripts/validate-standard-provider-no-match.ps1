#requires -Version 5
# Integration test for M1: provider exits non-zero with a "no convention
# matched" diagnostic when no registered convention recognises the
# project root.
#
# Mechanics mirror scripts/validate-standard-provider-smoke.ps1:
#
#   1. Set up a temporary project containing a minimal reprobuild.nim
#      that declares `uses: dummy-language` (so the diagnostic has a
#      `uses:` hint to surface).
#   2. Compile a tiny Nim helper (using the shared
#      repro_standard_provider_protocol constants) that writes a
#      prkGraphInvocation request file pointing at the temporary
#      project root.
#   3. Launch `build/bin/repro-standard-provider.exe` with the
#      --repro-provider-request / --repro-provider-response args and
#      capture stdout/stderr.
#   4. Assert exit code is non-zero, stderr contains "no convention
#      matched", and the diagnostic mentions both the project root and
#      `dummy-language`.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
$providerExe = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$workRoot    = Join-Path $repoRoot 'build\validate-standard-provider-no-match'
$protocolDir = Join-Path $workRoot 'protocol'
$projectDir  = Join-Path $workRoot 'fake-project'

if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}

if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $protocolDir | Out-Null
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

# --- step 1: write the project's reprobuild.nim with a uses: hint --------
$projectReprobuildNim = @'
# Minimal package definition for the no-match validation script. The
# standard provider's M1 dispatch should fail loudly because the
# `dummy-language` token does NOT correspond to any registered
# convention.
package "no_match_example":
  uses: dummy-language
'@
$projectReprobuildPath = Join-Path $projectDir 'reprobuild.nim'
$projectReprobuildNim | Out-File -FilePath $projectReprobuildPath -Encoding ascii
Write-Host "wrote $projectReprobuildPath"

# --- step 2: compile a graph-request writer ------------------------------
$pathArgs = @(
  '--path:' + (Join-Path $repoRoot 'libs\repro_standard_provider_protocol\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_provider_runtime\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_core\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_hash\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_platform\src'),
  '--path:' + (Join-Path $repoRoot 'libs\blake3\src'),
  '--path:' + (Join-Path $repoRoot 'libs\xxh3\src')
)

$graphRequestNim = @'
import std/[os]
import repro_provider_runtime
import repro_standard_provider_protocol

let requestPath = paramStr(1)
let projectRoot = paramStr(2)
let request = ProviderGraphRequest(
  kind: prkGraphInvocation,
  providerArtifactId: StandardProviderArtifactId,
  entryPointId: StandardProviderRootEntryPointId,
  entryPointBodyHash: StandardProviderRootBodyHash,
  reason: girExplicitUserRequest,
  arguments: projectRoot,
  namespace: StandardProviderNamespace)
writeProviderRequestFile(requestPath, request)
'@
$graphRequestSrc = Join-Path $workRoot 'graph_request_writer.nim'
$graphRequestNim | Out-File -FilePath $graphRequestSrc -Encoding ascii
$graphRequestExe = Join-Path $workRoot 'graph_request_writer.exe'
& nim c --hints:off --warnings:off `
  --nimcache:"$workRoot\nimcache-req" `
  --out:"$graphRequestExe" `
  @pathArgs `
  $graphRequestSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: graph-request writer compile failed"
  exit 1
}

$graphRequestPath  = Join-Path $protocolDir 'graph.request.rbpg'
$graphResponsePath = Join-Path $protocolDir 'graph.response.rbpg'
& $graphRequestExe $graphRequestPath $projectDir
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $graphRequestPath)) {
  Write-Host "FAIL: request writer did not produce $graphRequestPath"
  exit 1
}
Write-Host "wrote graph request: $graphRequestPath"

# --- step 3: invoke the provider, capture exit + stderr ------------------
Write-Host "==> launching repro-standard-provider for graph request"
$stderrCapture = Join-Path $workRoot 'provider.stderr.txt'
$stdoutCapture = Join-Path $workRoot 'provider.stdout.txt'
$proc = Start-Process -FilePath $providerExe -ArgumentList @(
    '--repro-provider-request', $graphRequestPath,
    '--repro-provider-response', $graphResponsePath
  ) -NoNewWindow -PassThru -Wait `
  -RedirectStandardError $stderrCapture `
  -RedirectStandardOutput $stdoutCapture
$exitCode = $proc.ExitCode

$stderrText = ""
if (Test-Path -LiteralPath $stderrCapture) {
  $raw = Get-Content -LiteralPath $stderrCapture -Raw
  if ($raw) { $stderrText = $raw }
}
$stdoutText = ""
if (Test-Path -LiteralPath $stdoutCapture) {
  $raw = Get-Content -LiteralPath $stdoutCapture -Raw
  if ($raw) { $stdoutText = $raw }
}

Write-Host ""
Write-Host "--- provider exit code: $exitCode"
Write-Host "--- provider stderr ---"
Write-Host $stderrText
if ($stdoutText.Length -gt 0 -and $stdoutText.Trim().Length -gt 0) {
  Write-Host "--- provider stdout ---"
  Write-Host $stdoutText
}
Write-Host "---"

# --- step 4: assertions --------------------------------------------------
$failures = @()
if ($exitCode -eq 0) {
  $failures += "expected non-zero exit, got $exitCode"
}
if ($stderrText -notmatch 'no convention matched') {
  $failures += "stderr missing 'no convention matched' substring"
}
# The diagnostic must name the project root. Compare normalising slashes
# because PowerShell hands the helper a backslash path on Windows and the
# Nim runtime echoes it back verbatim.
$projectRootNormalised = $projectDir
if ($stderrText -notmatch [regex]::Escape($projectRootNormalised) -and
    $stderrText -notmatch [regex]::Escape($projectRootNormalised.Replace('\','/'))) {
  $failures += "stderr does not mention the project root '$projectRootNormalised'"
}
if ($stderrText -notmatch 'dummy-language') {
  $failures += "stderr does not mention the package's uses: entry 'dummy-language'"
}

if ($failures.Count -gt 0) {
  Write-Host ""
  foreach ($f in $failures) {
    Write-Host "FAIL: $f"
  }
  exit 1
}

Write-Host ""
Write-Host "PASS: repro-standard-provider M1 reports 'no convention matched' with project root + uses hint"
exit 0
