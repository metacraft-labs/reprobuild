#requires -Version 5
# Standalone smoke test of the repro-standard-provider binary (M0 scaffold).
#
# The M0 scaffold answers manifest requests with a single placeholder
# entry point and graph requests with an empty fragment. This script
# proves that contract end-to-end:
#
#   1. compiles a tiny Nim helper that writes a `prkManifest` request
#      file (using the shared `repro_standard_provider_protocol`
#      constants so the engine/provider can't drift on a single edit)
#   2. launches `build/bin/repro-standard-provider.exe` with the
#      protocol arguments
#   3. compiles a second Nim helper that decodes the response file and
#      asserts the returned providerArtifactId + entry point match the
#      M0 contract
#
# Patterned after scripts/validate-direct-provider.ps1.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
$providerExe = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$workRoot    = Join-Path $repoRoot 'build\validate-standard-provider'
$protocolDir = Join-Path $workRoot 'protocol'

if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}

if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $protocolDir | Out-Null

# Shared --path flags for every Nim helper compile below.
$pathArgs = @(
  '--path:' + (Join-Path $repoRoot 'libs\repro_standard_provider_protocol\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_provider_runtime\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_core\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_hash\src'),
  '--path:' + (Join-Path $repoRoot 'libs\repro_platform\src'),
  '--path:' + (Join-Path $repoRoot 'libs\blake3\src'),
  '--path:' + (Join-Path $repoRoot 'libs\xxh3\src')
)

# --- step 1: build the request-writer helper -------------------------------
$manifestRequestNim = @'
import std/[os]
import repro_provider_runtime
import repro_standard_provider_protocol

let requestPath = paramStr(1)
let request = ProviderGraphRequest(
  kind: prkManifest,
  providerArtifactId: StandardProviderArtifactId,
  reason: girExplicitUserRequest)
writeProviderRequestFile(requestPath, request)
'@
$manifestRequestSrc = Join-Path $workRoot 'manifest_request_writer.nim'
$manifestRequestNim | Out-File -FilePath $manifestRequestSrc -Encoding ascii
$manifestRequestExe = Join-Path $workRoot 'manifest_request_writer.exe'
& nim c --hints:off --warnings:off `
  --nimcache:"$workRoot\nimcache-req" `
  --out:"$manifestRequestExe" `
  @pathArgs `
  $manifestRequestSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: manifest-request writer compile failed"
  exit 1
}

$manifestRequestPath  = Join-Path $protocolDir 'manifest.request.rbpg'
$manifestResponsePath = Join-Path $protocolDir 'manifest.response.rbpg'
& $manifestRequestExe $manifestRequestPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $manifestRequestPath)) {
  Write-Host "FAIL: request writer did not produce $manifestRequestPath"
  exit 1
}
Write-Host "wrote manifest request: $manifestRequestPath"

# --- step 2: invoke the provider -------------------------------------------
Write-Host "==> launching repro-standard-provider for manifest request"
& $providerExe --repro-provider-request $manifestRequestPath `
               --repro-provider-response $manifestResponsePath
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: standard provider exited with code $LASTEXITCODE"
  exit 1
}
if (-not (Test-Path -LiteralPath $manifestResponsePath)) {
  Write-Host "FAIL: standard provider did not write $manifestResponsePath"
  exit 1
}
Write-Host "    manifest response: $((Get-Item $manifestResponsePath).Length) bytes"

# --- step 3: compile + run a verifier that inspects the response ----------
$verifierNim = @'
import std/[os, strutils]
import repro_provider_runtime
import repro_standard_provider_protocol

let responsePath = paramStr(1)
let response = readProviderResponseFile(responsePath)
if response.kind != pskManifest:
  echo "VERIFY-FAIL: expected manifest response, got ", response.kind
  quit 2
if response.manifest.providerArtifactId != StandardProviderArtifactId:
  echo "VERIFY-FAIL: providerArtifactId mismatch: got ",
    response.manifest.providerArtifactId,
    ", expected ", StandardProviderArtifactId
  quit 3
if response.manifest.protocolVersion != ProviderProtocolVersion:
  echo "VERIFY-FAIL: protocolVersion mismatch: got ",
    response.manifest.protocolVersion,
    ", expected ", ProviderProtocolVersion
  quit 4
if response.manifest.entryPoints.len == 0:
  echo "VERIFY-FAIL: manifest exposes no entry points"
  quit 5
var placeholderFound = false
for descriptor in response.manifest.entryPoints:
  if descriptor.id == "standardProvider.placeholder":
    placeholderFound = true
    break
if not placeholderFound:
  echo "VERIFY-FAIL: manifest is missing the M0 placeholder entry point"
  quit 6
echo "VERIFY-OK: providerArtifactId=", response.manifest.providerArtifactId,
  " entryPoints=", response.manifest.entryPoints.len
'@
$verifierSrc = Join-Path $workRoot 'manifest_response_verifier.nim'
$verifierNim | Out-File -FilePath $verifierSrc -Encoding ascii
$verifierExe = Join-Path $workRoot 'manifest_response_verifier.exe'
& nim c --hints:off --warnings:off `
  --nimcache:"$workRoot\nimcache-verify" `
  --out:"$verifierExe" `
  @pathArgs `
  $verifierSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: response verifier compile failed"
  exit 1
}
& $verifierExe $manifestResponsePath
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: response verifier reported a contract violation (exit $LASTEXITCODE)"
  exit 1
}

Write-Host ""
Write-Host "PASS: repro-standard-provider M0 scaffold responds to manifest request"
exit 0
