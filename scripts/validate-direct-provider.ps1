#requires -Version 5
# Standalone smoke test of the repro-cmake-trycompile-provider binary.
# Hand-crafts a minimal TryCompile metadata + provider-protocol request,
# launches the direct provider, and verifies it emits a manifest and a
# graph fragment without going through CMake.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
$providerExe = Join-Path $repoRoot 'build\bin\repro-cmake-trycompile-provider.exe'
$workRoot   = Join-Path $repoRoot 'build\validate-direct-provider'
$projectDir = Join-Path $workRoot 'project'
$protocolDir = Join-Path $workRoot 'protocol'

if (-not (Test-Path -LiteralPath $providerExe)) {
  throw "missing $providerExe — run scripts\build_apps.sh first"
}

if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null
New-Item -ItemType Directory -Force -Path $protocolDir | Out-Null

# Build the metadata via the same Nim encoder the production CMake generator
# uses (compile a tiny helper that writes a fixture). This keeps the test
# independent of the C++ emitter so we can validate the Nim decoder + provider
# logic in isolation.
$fixtureSource = Join-Path $workRoot 'fixture_writer.nim'
@'
import std/[os]
import repro_cmake_trycompile

let projectDir = paramStr(1)
var meta = TryCompileMetadata(
  usedTools: @["gcc"],
  pools: @[],
  actions: @[
    TryCompileActionDef(
      id: "compile-check-include-file",
      inline: true,
      inlineArgv: @["gcc", "-c", "test.c", "-o", "test.o"],
      inlineCwd: "",
      args: @[],
      deps: @[],
      inputs: @["test.c"],
      outputs: @["test.o"],
      pool: "compile",
      poolUnits: 1'u32,
      depfile: "",
      dynamicDepsFile: "",
      cacheable: true,
      commandStatsId: "trycompile fixture")
  ],
  targetName: "cmTC_tryCompile",
  targetActionIds: @["compile-check-include-file"])

writeFile(projectDir / "trycompile.rbsz",
  cast[string](encodeTryCompileMetadata(meta)))
'@ | Out-File -FilePath $fixtureSource -Encoding ascii

# Compile the fixture writer.
$fixtureExe = Join-Path $workRoot 'fixture_writer.exe'
& nim c --hints:off --warnings:off --define:reproProviderMode `
  --nimcache:"$workRoot\nimcache-fixture" `
  --out:"$fixtureExe" `
  --path:"$repoRoot\libs\repro_cmake_trycompile\src" `
  --path:"$repoRoot\libs\repro_core\src" `
  $fixtureSource 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "fixture writer compile failed"
}
& $fixtureExe $projectDir
if (-not (Test-Path -LiteralPath (Join-Path $projectDir 'trycompile.rbsz'))) {
  throw "fixture writer did not produce trycompile.rbsz"
}
Write-Host "wrote fixture metadata: $(Join-Path $projectDir 'trycompile.rbsz')"

# Compose a manifest request and ask the provider to emit it.
$manifestRequestNim = @'
import std/[os]
import repro_cmake_trycompile
import repro_provider_runtime

let requestPath  = paramStr(1)
let request = ProviderGraphRequest(
  kind: prkManifest,
  providerArtifactId: TryCompileProviderArtifactId,
  reason: girExplicitUserRequest)
writeProviderRequestFile(requestPath, request)
'@
$manifestRequestSrc = Join-Path $workRoot 'manifest_request_writer.nim'
$manifestRequestNim | Out-File -FilePath $manifestRequestSrc -Encoding ascii
$manifestRequestExe = Join-Path $workRoot 'manifest_request_writer.exe'
& nim c --hints:off --warnings:off `
  --nimcache:"$workRoot\nimcache-mfx" `
  --out:"$manifestRequestExe" `
  --path:"$repoRoot\libs\repro_cmake_trycompile\src" `
  --path:"$repoRoot\libs\repro_core\src" `
  --path:"$repoRoot\libs\repro_hash\src" `
  --path:"$repoRoot\libs\repro_platform\src" `
  --path:"$repoRoot\libs\repro_provider_runtime\src" `
  --path:"$repoRoot\libs\blake3\src" `
  --path:"$repoRoot\libs\xxh3\src" `
  $manifestRequestSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "manifest-request writer compile failed"
}
$manifestRequestPath = Join-Path $protocolDir 'manifest.request.rbpg'
$manifestResponsePath = Join-Path $protocolDir 'manifest.response.rbpg'
& $manifestRequestExe $manifestRequestPath

Write-Host "==> launching direct provider for manifest request"
& $providerExe --repro-provider-request $manifestRequestPath --repro-provider-response $manifestResponsePath
if ($LASTEXITCODE -ne 0) {
  throw "direct provider failed manifest request: exit $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $manifestResponsePath)) {
  throw "direct provider did not write manifest response"
}
Write-Host "    manifest response: $((Get-Item $manifestResponsePath).Length) bytes"

# Build a graph-invocation request pointing at the project dir as arguments.
$graphRequestNim = @'
import std/[os]
import repro_cmake_trycompile
import repro_provider_runtime

let requestPath = paramStr(1)
let projectDir  = paramStr(2)
let request = ProviderGraphRequest(
  kind: prkGraphInvocation,
  providerArtifactId: TryCompileProviderArtifactId,
  entryPointId: TryCompileProviderRootEntryPointId,
  entryPointBodyHash: TryCompileProviderRootBodyHash,
  reason: girExplicitUserRequest,
  arguments: projectDir,
  namespace: TryCompileProviderNamespace,
  lockSliceId: "",
  activity: "build")
writeProviderRequestFile(requestPath, request)
'@
$graphRequestSrc = Join-Path $workRoot 'graph_request_writer.nim'
$graphRequestNim | Out-File -FilePath $graphRequestSrc -Encoding ascii
$graphRequestExe = Join-Path $workRoot 'graph_request_writer.exe'
& nim c --hints:off --warnings:off `
  --nimcache:"$workRoot\nimcache-grf" `
  --out:"$graphRequestExe" `
  --path:"$repoRoot\libs\repro_cmake_trycompile\src" `
  --path:"$repoRoot\libs\repro_core\src" `
  --path:"$repoRoot\libs\repro_hash\src" `
  --path:"$repoRoot\libs\repro_platform\src" `
  --path:"$repoRoot\libs\repro_provider_runtime\src" `
  --path:"$repoRoot\libs\blake3\src" `
  --path:"$repoRoot\libs\xxh3\src" `
  $graphRequestSrc 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "graph-request writer compile failed"
}
$graphRequestPath = Join-Path $protocolDir 'graph.request.rbpg'
$graphResponsePath = Join-Path $protocolDir 'graph.response.rbpg'
& $graphRequestExe $graphRequestPath $projectDir

Write-Host "==> launching direct provider for graph request"
& $providerExe --repro-provider-request $graphRequestPath --repro-provider-response $graphResponsePath
if ($LASTEXITCODE -ne 0) {
  throw "direct provider failed graph request: exit $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $graphResponsePath)) {
  throw "direct provider did not write graph response"
}
Write-Host "    graph response: $((Get-Item $graphResponsePath).Length) bytes"

Write-Host ""
Write-Host "PASS: direct provider responds to both manifest and graph requests"
