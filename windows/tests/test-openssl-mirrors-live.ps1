# Live HTTPS qualification of the unchanged OpenSSL archive pin. No downloader,
# TLS, hashing or filesystem mocks. A closed loopback port forces the first
# request to fail; the official fallback mirrors must supply verified bytes.
# This complements test-openssl-mirrors.ps1's deterministic fault controls.
# Linux/macOS runs qualify PowerShell transport, not native Windows provisioning.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../toolchain-utils.ps1')
. (Join-Path $PSScriptRoot '../ensure-openssl.ps1')
$pins = Read-KeyValueFile -Path (Join-Path $PSScriptRoot '../toolchain-versions.env')
$asset = "mingw-w64-ucrt-x86_64-openssl-$($pins.OPENSSL_VERSION)-$($pins.OPENSSL_MSYS2_RELEASE)-any.pkg.tar.zst"
$urls = @(Get-OpenSslArchiveUrls -AssetName $asset)
$work = Join-Path ([IO.Path]::GetTempPath()) "repro-openssl-live-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$unavailable = "http://127.0.0.1:$port/unavailable"
$output = Join-Path $work 'archive.pkg.tar.zst'
try {
  Download-VerifiedFileFromMirrors -Urls (@($unavailable) + $urls[1..($urls.Count - 1)]) -OutFile $output -ExpectedSha256 $pins.OPENSSL_SHA256
  Assert-FileSha256 -Path $output -Expected $pins.OPENSSL_SHA256
  Write-Host 'PASS: a refused primary falls through to live verified mirror bytes'

  $rejected = $false
  try {
    Download-VerifiedFileFromMirrors -Urls $urls -OutFile $output -ExpectedSha256 ('0' * 64)
  } catch {
    if ($_.Exception.Message -notmatch 'Checksum mismatch') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw 'Wrong checksum was accepted' }
  Assert-FileSha256 -Path $output -Expected $pins.OPENSSL_SHA256
  if (@(Get-ChildItem -LiteralPath $work -Filter '*.partial').Count -ne 0) {
    throw 'A failed download left partial files'
  }
  Write-Host 'PASS: live wrong-checksum refusal preserves verified bytes and leaves no partials'
  $pins = Read-KeyValueFile -Path (Join-Path $PSScriptRoot '../toolchain-versions.env')
  $asset = "mingw-w64-ucrt-x86_64-openssl-$($pins.OPENSSL_VERSION)-$($pins.OPENSSL_MSYS2_RELEASE)-any.pkg.tar.zst"
  $acc = @(Get-OpenSslArchiveUrls -AssetName $asset)[2]
  $handler = New-Object Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $false
  $client = New-Object Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(20)
  try {
    $response = $client.GetAsync($acc, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
      if ([int]$response.StatusCode -notin @(301, 302, 303, 307, 308)) { throw 'ACC did not exercise a real redirect.' }
      if ($null -eq $response.Headers.Location) { throw 'ACC redirect has no Location.' }
      $target = [Uri]::new([Uri]$acc, $response.Headers.Location.OriginalString)
      if ($target.Scheme -ne 'https') { throw 'ACC redirect no longer preserves HTTPS.' }
    } finally { $response.Dispose() }
  } finally { $client.Dispose() }
  Download-VerifiedFileFromMirrors -Urls @($acc) -OutFile $output -ExpectedSha256 $pins.OPENSSL_SHA256
  Assert-FileSha256 -Path $output -Expected $pins.OPENSSL_SHA256
  Remove-Item -LiteralPath $output
  Write-Host 'PASS: the official ACC HTTPS redirect supplies the unchanged pinned archive'

} finally {
  Remove-Item -LiteralPath $work -Recurse -Force
}
