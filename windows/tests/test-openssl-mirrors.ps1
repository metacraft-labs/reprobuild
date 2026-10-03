# Real HTTP/filesystem integration test; no download, hashing or filesystem
# mocks. A closed loopback port supplies a real connection refusal, followed
# by an official mirror serving the pinned OpenSSL archive. A wrong hash and
# exhausted source list must fail without publishing or retaining partials.
# This test runs under PowerShell on macOS as well as Windows. It qualifies
# downloading; native Windows extraction is exercised by Ensure-OpenSsl in CI.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "../toolchain-utils.ps1")
$pins = Read-KeyValueFile -Path (Join-Path $PSScriptRoot "../toolchain-versions.env")
$asset = "mingw-w64-ucrt-x86_64-openssl-$($pins.OPENSSL_VERSION)-$($pins.OPENSSL_MSYS2_RELEASE)-any.pkg.tar.zst"
$mirror = "https://mirror.umd.edu/msys2/mingw/ucrt64/$asset"
$work = Join-Path ([IO.Path]::GetTempPath()) "repro-openssl-mirrors-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$unavailable = "http://127.0.0.1:$port/unavailable"
$output = Join-Path $work "archive.pkg.tar.zst"
try {
  Download-VerifiedFileFromMirrors -Urls @($unavailable, $mirror) -OutFile $output -ExpectedSha256 $pins.OPENSSL_SHA256 -TimeoutSeconds 60
  Assert-FileSha256 -Path $output -Expected $pins.OPENSSL_SHA256
  Write-Host "PASS: a refused primary falls through to verified mirror bytes"

  $rejected = $false
  try {
    Download-VerifiedFileFromMirrors -Urls @($mirror) -OutFile $output -ExpectedSha256 ('0' * 64) -TimeoutSeconds 60
  } catch {
    if ($_.Exception.Message -notmatch 'Checksum mismatch') { throw }
    $rejected = $true
  }
  if (-not $rejected) { throw "Wrong checksum was accepted" }
  Assert-FileSha256 -Path $output -Expected $pins.OPENSSL_SHA256
  Write-Host "PASS: wrong checksum is rejected without replacing verified bytes"

  Remove-Item -LiteralPath $output
  $rejected = $false
  try {
    Download-VerifiedFileFromMirrors -Urls @($unavailable) -OutFile $output -ExpectedSha256 $pins.OPENSSL_SHA256 -TimeoutSeconds 5
  } catch {
    if ($_.Exception.Message -notmatch 'No mirror supplied') { throw }
    $rejected = $true
  }
  if (-not $rejected -or (Test-Path -LiteralPath $output)) {
    throw "An exhausted mirror list published an archive"
  }
  if (@(Get-ChildItem -LiteralPath $work -Filter '*.partial').Count -ne 0) {
    throw "A failed download left partial files"
  }
  Write-Host "PASS: exhausted mirrors fail and leave no partial archive"
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force
}
