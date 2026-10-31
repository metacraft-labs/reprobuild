# Real socket/filesystem/hash/provisioning integration controls. The loopback
# HTTP server is a deliberately controlled origin: public mirrors cannot be
# made to truncate, stall, return corrupt bytes or report an outage on demand.
# Only Get-OpenSslArchiveUrls is substituted for provisioning controls, to select
# that origin. Ensure-OpenSsl, the downloader, SHA256, tar extraction and metadata
# are the production implementations. No success adapter replaces any of them.
# A small real tar contains layout fixtures, not executable DLLs; this does not
# qualify OpenSSL's ABI or native Windows loading. The live test separately
# fetches the exact pinned .pkg.tar.zst from the official HTTPS mirrors.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../toolchain-utils.ps1')
. (Join-Path $PSScriptRoot '../ensure-openssl.ps1')

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Operation, [string]$Pattern) {
  try { & $Operation | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Pattern) { throw }
    return
  }
  throw "Expected rejection matching '$Pattern'."
}
function Assert-NoPartials([string]$Directory) {
  Require (@(Get-ChildItem -LiteralPath $Directory -Recurse -Filter '*.partial').Count -eq 0) 'A failed transfer retained partial output.'
}

$work = Join-Path ([IO.Path]::GetTempPath()) "repro-openssl-controls-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$server = $null
$savedSystemRoot = $env:SystemRoot
try {
  # Get-WindowsTarExe first checks SystemRoot, then the real tar on PATH. On
  # POSIX supply a nonexistent System32 location so its existing fallback runs.
  if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { $env:SystemRoot = $work }
  $tar = Get-WindowsTarExe
  $payload = Join-Path $work 'payload'
  foreach ($relative in @('lib/libssl.dll.a', 'lib/libcrypto.dll.a',
                         'include/openssl/ssl.h', 'bin/libssl-3-x64.dll',
                         'bin/libcrypto-3-x64.dll')) {
    $file = Join-Path $payload "ucrt64/$relative"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
    [IO.File]::WriteAllText($file, "fixture $relative")
  }
  $archive = Join-Path $work 'fixture.tar'
  & $tar -cf $archive -C $payload ucrt64
  if ($LASTEXITCODE -ne 0) { throw 'Could not build the real tar fixture.' }
  $sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
  $requests = Join-Path $work 'requests.log'
  $completed = Join-Path $work 'completed.log'
  $portFile = Join-Path $work 'port'
  $server = Start-Job -ArgumentList $archive, $requests, $completed, $portFile -ScriptBlock {
    param($Archive, $Requests, $Completed, $PortFile)
    $ErrorActionPreference = 'Stop'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
      [IO.File]::WriteAllText($PortFile, [string]$listener.LocalEndpoint.Port)
      while ($true) {
        # Keep the job stoppable while idle; synchronous AcceptTcpClient alone
        # would hold Stop-Job inside a native blocking call during cleanup.
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
        $client = $listener.AcceptTcpClient()
        $path = ''
        try {
          $stream = $client.GetStream()
          $stream.ReadTimeout = 5000
          $stream.WriteTimeout = 5000
          $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
          try {
            $request = $reader.ReadLine()
            if ($null -eq $request) { continue }
            $path = ($request -split ' ')[1]
            while (-not [string]::IsNullOrEmpty($reader.ReadLine())) { }
          } finally { $reader.Dispose() }
          [IO.File]::AppendAllText($Requests, "$path`n")
          if ($path.StartsWith('/redirect-')) {
            $location = ''
            if ($path.StartsWith('/redirect-http/')) { $location = "Location: http://127.0.0.1:$($listener.LocalEndpoint.Port)/good/redirect-target`r`n" }
            if ($path.StartsWith('/redirect-relative/')) { $location = "Location: /good/redirect-target`r`n" }
            if ($path.StartsWith('/redirect-malformed/')) { $location = "Location: https://[invalid`r`n" }
            $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 302 Found`r`n${location}Content-Length: 0`r`nConnection: close`r`n`r`n")
            $stream.Write($header, 0, $header.Length)
            continue
          }
          $code = '200 OK'
          $bytes = [IO.File]::ReadAllBytes($Archive)
          if ($path.StartsWith('/missing/')) { $code = '503 Service Unavailable'; $bytes = [byte[]]@(1) }
          if ($path.StartsWith('/bad/')) { $bytes = [Text.Encoding]::ASCII.GetBytes('wrong archive') }
          $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
          $stream.Write($header, 0, $header.Length)
          if ($path.StartsWith('/stall/')) { Start-Sleep -Seconds 4; continue }
          if ($path.StartsWith('/trickle/')) {
            # Progress every quarter second defeats an idle-only timeout; the
            # production whole-response deadline must still cancel the read.
            # Without that deadline the complete archive and hash are valid.
            for ($index = 0; $index -lt 16; $index++) {
              $offset = [int][Math]::Floor($index * $bytes.Length / 16)
              $end = [int][Math]::Floor(($index + 1) * $bytes.Length / 16)
              try { $stream.Write($bytes, $offset, $end - $offset) } catch [IO.IOException] { break }
              Start-Sleep -Milliseconds 250
            }
            continue
          }
          $length = if ($path.StartsWith('/partial/')) { 7 } else { $bytes.Length }
          $stream.Write($bytes, 0, $length)
        } finally {
          $client.Dispose()
          [IO.File]::AppendAllText($Completed, "$path`n")
        }
      }
    } finally { $listener.Stop() }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath $portFile)) {
    if ($server.State -eq 'Failed') { Receive-Job $server; throw 'HTTP fixture failed.' }
    if ([DateTime]::UtcNow -gt $deadline) { throw 'HTTP fixture did not start.' }
    Start-Sleep -Milliseconds 50
  }
  $base = "http://127.0.0.1:$([IO.File]::ReadAllText($portFile))"
  $output = Join-Path $work 'download.tar'
  Download-VerifiedFileFromMirrors -Urls @("$base/missing/a", "$base/good/a") -OutFile $output -ExpectedSha256 $sha
  Assert-FileSha256 -Path $output -Expected $sha
  Require (([IO.File]::ReadAllText($requests)) -eq "/missing/a`n/good/a`n") 'Sources were not tried in order exactly once.'
  Write-Host 'PASS: primary HTTP failure falls through to the verified mirror'

  Download-VerifiedFileFromMirrors -Urls @("$base/bad/b", "$base/partial/b", "$base/good/b") -OutFile $output -ExpectedSha256 $sha
  Assert-FileSha256 -Path $output -Expected $sha
  Assert-NoPartials $work
  Write-Host 'PASS: corrupt and truncated sources fall through without retaining partials'

  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @("$base/good/c") -OutFile $output -ExpectedSha256 ('0' * 64) } 'Checksum mismatch'
  Assert-FileSha256 -Path $output -Expected $sha
  Assert-NoPartials $work
  Write-Host 'PASS: wrong checksum refuses replacement of an existing verified archive'

  Remove-Item -LiteralPath $output
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @("$base/bad/d", "$base/partial/d", "$base/missing/d") -OutFile $output -ExpectedSha256 $sha } 'No mirror supplied'
  Require (-not (Test-Path -LiteralPath $output)) 'Exhausted sources published an archive.'
  Assert-NoPartials $work
  Write-Host 'PASS: exhausted sources fail without publishing an archive'

  $timer = [Diagnostics.Stopwatch]::StartNew()
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @("$base/stall/e") -OutFile $output -ExpectedSha256 $sha -TimeoutSeconds 1 } 'No mirror supplied'
  $timer.Stop()
  Require ($timer.Elapsed.TotalSeconds -lt 3.5) 'A stalled response body exceeded its request bound.'
  Require (-not (Test-Path -LiteralPath $output)) 'A stalled source published an archive.'
  Assert-NoPartials $work
  Write-Host 'PASS: stalled response bodies time out and leave no archive or partial'

  # Do not let the preceding stalled connection hold the single-threaded
  # origin: the next control must actually receive its progressing body.
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not ([IO.File]::ReadAllText($completed)).Contains("/stall/e`n")) {
    if ([DateTime]::UtcNow -gt $deadline) {
      # Say why. The origin is single-threaded, so reaching here means it never
      # finished that connection -- but Receive-Job and $server.State are
      # consulted on the startup path alone, so a fixture that faults HERE
      # reported as this timeout and nothing else. That is how this failure
      # stayed reproducible and undiagnosed across two runs.
      $fixtureState = $server.State
      $fixtureOutput = Receive-Job $server | Out-String
      $requestsSeen = [IO.File]::ReadAllText($requests)
      $completedSeen = [IO.File]::ReadAllText($completed)
      Write-Host "FIXTURE STATE: $fixtureState"
      Write-Host "FIXTURE OUTPUT: $fixtureOutput"
      Write-Host "REQUESTS SEEN: $requestsSeen"
      Write-Host "COMPLETED SEEN: $completedSeen"
      throw 'HTTP fixture did not finish the stalled connection.'
    }
    Start-Sleep -Milliseconds 20
  }
  $timer.Restart()
  $refused = $false
  try {
    Download-VerifiedFileFromMirrors -Urls @("$base/trickle/f") -OutFile $output -ExpectedSha256 $sha -TimeoutSeconds 1
  } catch {
    if ($_.Exception.Message -notmatch 'No mirror supplied') { throw }
    $refused = $true
  }
  $timer.Stop()
  Require (([IO.File]::ReadAllText($requests)).EndsWith("/trickle/f`n")) 'The progressing-body control did not reach the origin.'
  if (-not $refused) {
    Assert-FileSha256 -Path $output -Expected $sha
    Write-Host 'CONTROL: progressing response completed with the valid payload hash'
  }
  Require ($timer.Elapsed.TotalSeconds -lt 3.5) 'A progressing response body exceeded its whole-response bound.'
  Require $refused 'A progressing response was accepted after its deadline.'
  Require (-not (Test-Path -LiteralPath $output)) 'A progressing timed-out source published an archive.'
  Assert-NoPartials $work
  Write-Host 'PASS: continuous body progress cannot extend the whole-response deadline'

  foreach ($source in @('redirect-http', 'redirect-relative')) {
    $refused = $false
    try {
      Download-VerifiedFileFromMirrors -Urls @("$base/$source/g") -OutFile $output -ExpectedSha256 $sha
    } catch {
      if ($_.Exception.Message -notmatch 'must preserve HTTPS') { throw }
      $refused = $true
    }
    if (-not $refused) {
      Assert-FileSha256 -Path $output -Expected $sha
      Write-Host 'CONTROL: insecure redirect delivered a valid payload hash'
    }
    Require $refused 'An insecure redirect was accepted.'
    Require (-not ([IO.File]::ReadAllText($requests)).Contains('/good/redirect-target')) 'An insecure redirected request reached its target.'
    Require (-not (Test-Path -LiteralPath $output)) 'An insecure redirect published an archive.'
  }
  Assert-NoPartials $work
  Write-Host 'PASS: absolute and relative HTTP redirect targets are refused before acquisition'

  foreach ($source in @('redirect-missing', 'redirect-malformed')) {
    Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @("$base/$source/h") -OutFile $output -ExpectedSha256 $sha } 'missing or invalid Location'
    Require (-not (Test-Path -LiteralPath $output)) 'An invalid redirect published an archive.'
  }
  Assert-NoPartials $work
  Write-Host 'PASS: missing and malformed redirect locations fail without output or partials'

  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @("$base/redirect-http/i", "$base/redirect-missing/i") -OutFile $output -ExpectedSha256 $sha } 'No mirror supplied'
  Require (-not (Test-Path -LiteralPath $output)) 'Exhausted redirects published an archive.'
  Download-VerifiedFileFromMirrors -Urls @("$base/redirect-http/i", "$base/good/i") -OutFile $output -ExpectedSha256 $sha
  Assert-FileSha256 -Path $output -Expected $sha
  Remove-Item -LiteralPath $output
  Assert-NoPartials $work
  Write-Host 'PASS: unusable redirects exhaust cleanly or fall through to a verified source'

  # Verify the production origin policy before replacing only URL selection.
  $actualUrls = @(Get-OpenSslArchiveUrls -AssetName 'pin.pkg.tar.zst')
  $expectedUrls = @(
    'https://repo.msys2.org/mingw/ucrt64/pin.pkg.tar.zst',
    'https://mirror.umd.edu/msys2/mingw/ucrt64/pin.pkg.tar.zst',
    'https://mirror.accum.se/mirror/msys2.org/mingw/ucrt64/pin.pkg.tar.zst'
  )
  Require (($actualUrls -join "`n") -eq ($expectedUrls -join "`n")) 'OpenSSL sources differ from the reviewed official HTTPS mirrors.'
  $script:origins = @("$base/missing", "$base/good")
  function Get-OpenSslArchiveUrls {
    param([string]$AssetName)
    foreach ($origin in $script:origins) { "$origin/$AssetName" }
  }
  $pins = @{ OPENSSL_VERSION = 'fixture'; OPENSSL_MSYS2_RELEASE = '1'; OPENSSL_SHA256 = $sha }
  $asset = 'mingw-w64-ucrt-x86_64-openssl-fixture-1-any.pkg.tar.zst'
  $root = Join-Path $work 'fresh'
  $installed = Ensure-OpenSsl -Root $root -Arch x64 -Toolchain $pins
  foreach ($relative in @('lib/libssl.dll.a', 'lib/libcrypto.dll.a', 'include/openssl/ssl.h', 'bin/libssl-3-x64.dll', 'bin/libcrypto-3-x64.dll')) {
    Require ([IO.File]::ReadAllText((Join-Path $installed $relative)) -eq "fixture $relative") "Installed bytes differ: $relative"
  }
  $metadata = Read-KeyValueFile -Path (Join-Path $installed 'openssl.install.meta')
  Require ($metadata.openssl_archive_sha256 -eq $sha.ToLowerInvariant()) 'Install metadata did not retain the verified hash.'
  $log = [IO.File]::ReadAllText($requests)
  Require ($log.EndsWith("/missing/$asset`n/good/$asset`n")) 'Ensure-OpenSsl did not use the fallback downloader.'
  Write-Host 'PASS: Ensure-OpenSsl uses fallback, extracts verified bytes and writes pinned metadata'

  $stamp = (Get-Item -LiteralPath (Join-Path $installed 'lib/libssl.dll.a')).LastWriteTimeUtc
  $again = Ensure-OpenSsl -Root $root -Arch x64 -Toolchain $pins
  Require ($again -eq $installed -and [IO.File]::ReadAllText($requests) -eq $log -and (Get-Item -LiteralPath (Join-Path $installed 'lib/libssl.dll.a')).LastWriteTimeUtc -eq $stamp) 'Warm installation was not reused without a request.'
  Remove-Item -LiteralPath $installed -Recurse -Force
  $again = Ensure-OpenSsl -Root $root -Arch x64 -Toolchain $pins
  Require ([IO.File]::ReadAllText($requests) -eq $log) 'A validated cached archive was downloaded again.'
  Write-Host 'PASS: matching installs and validated archive caches need no network'

  Remove-Item -LiteralPath $installed -Recurse -Force
  [IO.File]::WriteAllText((Join-Path $root "openssl/_downloads/$asset"), 'invalid cache')
  $script:origins = @("$base/bad", "$base/missing")
  Assert-Rejected { Ensure-OpenSsl -Root $root -Arch x64 -Toolchain $pins } 'No mirror supplied'
  Require (-not (Test-Path -LiteralPath (Join-Path $root "openssl/_downloads/$asset"))) 'Invalid cached archive survived source exhaustion.'
  Require (-not (Test-Path -LiteralPath $installed)) 'Failed verification published an install.'
  Assert-NoPartials $work
  Write-Host 'PASS: invalid caches are removed and failed verification cannot publish an install'
} finally {
  if ($null -ne $server) { Stop-Job $server; Remove-Job $server -Force }
  $env:SystemRoot = $savedSystemRoot
  Remove-Item -LiteralPath $work -Recurse -Force
}
