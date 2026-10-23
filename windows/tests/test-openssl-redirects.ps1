# Deterministic real HTTPS redirect/deadline controls. The owned origin uses
# SslStream and ephemeral in-memory CertificateRequest certificates (.NET
# Framework 4.7.2+ / current .NET). Only the production handler constructor is
# replaced: real HttpClientHandler, or inbox Framework WebRequestHandler, uses
# exact certificate pinning plus hostname, validity and chain-error checks.
# No trust store, global TLS callback, HTTP success adapter or platform guard is
# changed. Default system trust is tested before and after the scoped override.
# Each timed request clears its own transaction evidence and must authenticate,
# request the exact URI, receive headers and progress its body. Prior successful
# traffic cannot qualify the no-TLS or no-body fault controls.
# Native Windows PowerShell 5.1 execution is a separate qualification arm.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../toolchain-utils.ps1')
Add-Type -AssemblyName System.Net.Http
$fixtureSource = Join-Path $PSScriptRoot 'HttpsDownloadFixture.cs'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
  # Desktop's C# compiler needs an explicit reference to the inbox HTTP
  # assembly; current PowerShell supplies its reference-assembly set itself.
  Add-Type -Path $fixtureSource -ReferencedAssemblies @('System.dll', 'System.Core.dll', [Net.Http.HttpClient].Assembly.Location)
} else {
  Add-Type -Path $fixtureSource
}

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
function Assert-NoOutput {
  Require (-not (Test-Path -LiteralPath $script:output)) 'A refused request published output.'
  Require (@(Get-ChildItem -LiteralPath $script:work -Filter '*.partial').Count -eq 0) 'A refused request retained partial output.'
}
function Set-Transaction([string]$Mode = 'normal', [string]$Id = ([Guid]::NewGuid().ToString('N'))) {
  $script:fixture.Reset($Id, $Mode)
  $script:pin.Reset()
  return $Id
}
function Invoke-TimedTransaction([string]$Mode, [string]$Id) {
  Set-Transaction -Mode $Mode -Id $Id | Out-Null
  $source = "http://127.0.0.1:$($script:fixture.HttpPort)/delay/$Id"
  $target = "https://localhost:$($script:fixture.HttpsPort)/body/$Id"
  $refused = $false
  $timer = [Diagnostics.Stopwatch]::StartNew()
  try {
    Download-VerifiedFileFromMirrors -Urls @($source) -OutFile $script:output -ExpectedSha256 $script:payloadSha -TimeoutSeconds 5
  } catch {
    if ($_.Exception.Message -notmatch 'Source deadline exceeded') { throw }
    $refused = $true
  }
  $timer.Stop()
  $evidence = $script:fixture.Current
  Require ($evidence.Failure -eq '') "The TLS fixture failed: $($evidence.Failure)"
  Require ($evidence.Id -eq $Id -and $evidence.Redirects -eq 1) 'The timed request did not follow its own redirect.'
  Require ($evidence.Handshakes -eq 1 -and $script:pin.AcceptedUri -eq $target) 'Timed transaction did not complete authenticated TLS.'
  Require ($evidence.Requests -eq 1 -and $evidence.RequestedPath -eq "/body/$Id" -and $evidence.Headers -eq 1) 'Timed transaction did not receive its HTTP response.'
  Require ($evidence.BodyChunks -ge 2 -and $evidence.BodyBytes -ge 8 -and $evidence.ProgressSeconds -ge 0.2) 'Timed transaction did not progress its response body.'
  Write-Host "CONTROL: actual transaction $Id authenticated and progressed $($evidence.BodyChunks) body chunks"
  if (-not $refused) {
    Assert-FileSha256 -Path $script:output -Expected $script:payloadSha
    Write-Host 'CONTROL: reset deadline completed the valid redirected payload hash'
  }
  Require ($timer.Elapsed.TotalSeconds -lt 6) 'Redirects reset the whole-source deadline.'
  Require $refused 'The timed redirect chain was accepted after its deadline.'
  Assert-NoOutput
}

$script:work = Join-Path ([IO.Path]::GetTempPath()) "repro-https-controls-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:work | Out-Null
$script:output = Join-Path $script:work 'download'
$savedFactory = (Get-Item Function:New-VerifiedDownloadHttpHandler).ScriptBlock
$goodCertificate = $null
$otherCertificate = $null
$expiredCertificate = $null
$script:fixture = $null
$wrongFixture = $null
$expiredFixture = $null
try {
  $goodCertificate = [VerifiedDownloadTests.Certificates]::Create($false)
  $otherCertificate = [VerifiedDownloadTests.Certificates]::Create($false)
  $expiredCertificate = [VerifiedDownloadTests.Certificates]::Create($true)
  $script:fixture = [VerifiedDownloadTests.HttpsFixture]::new($goodCertificate)
  $script:pin = [VerifiedDownloadTests.CertificatePin]::new($goodCertificate)
  $payload = Join-Path $script:work 'expected-payload'
  [IO.File]::WriteAllText($payload, ('*' * 64), [Text.Encoding]::ASCII)
  $script:payloadSha = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
  $id = Set-Transaction
  $uri = "https://localhost:$($script:fixture.HttpsPort)/good/$id"
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'SSL|TLS|trust|certificate|secure channel'
  Require ($script:fixture.Current.TcpConnections -gt 0) 'System-trust refusal did not reach the TLS origin.'
  Assert-NoOutput
  Write-Host 'PASS: unchanged default system trust refuses the private fixture certificate'

  # Only construction is replaced. Redirect policy, requests, cancellation,
  # hashing, cleanup and publication still run in the production downloader.
  Set-Item Function:New-VerifiedDownloadHttpHandler -Value {
    $handler = New-Object Net.Http.HttpClientHandler
    $property = $handler.GetType().GetProperty('ServerCertificateCustomValidationCallback')
    $method = 'Core'
    if ($null -eq $property) {
      $handler.Dispose()
      # .NET Framework's inbox assembly and API; no NuGet/package fallback.
      # https://learn.microsoft.com/dotnet/api/system.net.http.webrequesthandler.servercertificatevalidationcallback
      Add-Type -AssemblyName System.Net.Http.WebRequest
      $handler = New-Object Net.Http.WebRequestHandler
      $property = $handler.GetType().GetProperty('ServerCertificateValidationCallback')
      $method = 'Desktop'
    }
    if ($null -eq $property) { $handler.Dispose(); throw 'No supported per-handler certificate validation API is available.' }
    $callback = [Delegate]::CreateDelegate($property.PropertyType, $script:pin, $method)
    $property.SetValue($handler, $callback, $null)
    return $handler
  }

  $id = Set-Transaction
  $uri = "https://localhost:$($script:fixture.HttpsPort)/good/$id"
  Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha
  Assert-FileSha256 -Path $script:output -Expected $script:payloadSha
  Require ($script:pin.AcceptedUri -eq $uri -and $script:fixture.Current.BodyBytes -eq 64) 'Pinned trust did not authenticate the actual fixture request.'
  Remove-Item -LiteralPath $script:output
  Write-Host 'PASS: exact ephemeral certificate trust authenticates real TLS and verified bytes'

  $wrongFixture = [VerifiedDownloadTests.HttpsFixture]::new($otherCertificate)
  $script:pin = [VerifiedDownloadTests.CertificatePin]::new($goodCertificate)
  $uri = "https://localhost:$($wrongFixture.HttpsPort)/good/$($wrongFixture.Current.Id)"
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'SSL|TLS|trust|certificate|secure channel'
  Require ($script:pin.LastFailure -eq 'identity') 'The wrong-certificate control did not reach the identity refusal.'
  Assert-NoOutput
  Write-Host 'PASS: a different untrusted certificate is refused even with the same hostname'

  $script:pin = [VerifiedDownloadTests.CertificatePin]::new($goodCertificate)
  $id = Set-Transaction
  $uri = "https://127.0.0.1:$($script:fixture.HttpsPort)/good/$id"
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'SSL|TLS|trust|certificate|secure channel'
  Require ($script:pin.LastFailure -eq 'hostname') 'The hostname control did not reach the name refusal.'
  Assert-NoOutput
  Write-Host 'PASS: pin equality does not bypass hostname validation'

  $expiredFixture = [VerifiedDownloadTests.HttpsFixture]::new($expiredCertificate)
  $script:pin = [VerifiedDownloadTests.CertificatePin]::new($expiredCertificate)
  $uri = "https://localhost:$($expiredFixture.HttpsPort)/good/$($expiredFixture.Current.Id)"
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'SSL|TLS|trust|certificate|secure channel'
  Require ($script:pin.LastFailure -eq 'validity') 'The expired-certificate control did not reach the validity refusal.'
  Assert-NoOutput
  Write-Host 'PASS: pin equality does not bypass certificate validity dates'

  $script:pin = [VerifiedDownloadTests.CertificatePin]::new($goodCertificate)
  $id = Set-Transaction
  $uri = "https://localhost:$($script:fixture.HttpsPort)/relative/$id"
  Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha
  Assert-FileSha256 -Path $script:output -Expected $script:payloadSha
  Require ($script:fixture.Current.Redirects -eq 1 -and $script:fixture.Current.RequestedPath -eq "/good/$id") 'The relative HTTPS redirect did not reach the actual target.'
  Remove-Item -LiteralPath $script:output
  Write-Host 'PASS: a relative HTTPS redirect reaches and verifies its actual destination'

  foreach ($route in @('loop', 'chain')) {
    $id = Set-Transaction
    $suffix = if ($route -eq 'chain') { '/20' } else { '' }
    $uri = "https://localhost:$($script:fixture.HttpsPort)/$route/$id$suffix"
    Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'Redirect limit exceeded'
    Require ($script:fixture.Current.Redirects -eq 6) 'The redirect limit control did not exercise the exact allowed hop count.'
    Assert-NoOutput
  }
  Write-Host 'PASS: actual HTTPS loops and excessive chains stop at the finite redirect limit'

  # Each fault retains the exact HTTPS URI of a successful direct request, but
  # Reset replaces all evidence and the trust validator clears AcceptedUri.
  foreach ($mode in @('no-tls', 'no-body')) {
    $id = Set-Transaction
    $uri = "https://localhost:$($script:fixture.HttpsPort)/body/$id"
    Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha -TimeoutSeconds 10
    Assert-FileSha256 -Path $script:output -Expected $script:payloadSha
    Require ($script:pin.AcceptedUri -eq $uri -and $script:fixture.Current.BodyBytes -eq 64) 'The same-URI positive control did not complete its real TLS payload.'
    Write-Host "CONTROL: same-URI $mode preflight $uri completed the valid payload hash"
    Remove-Item -LiteralPath $script:output
    $oracle = if ($mode -eq 'no-tls') { 'Timed transaction did not complete authenticated TLS.' } else { 'Timed transaction did not progress its response body.' }
    Assert-Rejected { Invoke-TimedTransaction -Mode $mode -Id $id } ([Regex]::Escape($oracle))
    Assert-NoOutput
    Write-Host "PASS: same-URI $mode fault fails its actual-transaction progress oracle"
  }

  Invoke-TimedTransaction -Mode normal -Id ([Guid]::NewGuid().ToString('N'))
  Write-Host 'PASS: one deadline spans the redirect and the authenticated progressing body of this transaction'

  Set-Item Function:New-VerifiedDownloadHttpHandler -Value $savedFactory
  $id = Set-Transaction
  $uri = "https://localhost:$($script:fixture.HttpsPort)/good/$id"
  Assert-Rejected { Download-VerifiedFileFromMirrors -Urls @($uri) -OutFile $script:output -ExpectedSha256 $script:payloadSha } 'SSL|TLS|trust|certificate|secure channel'
  Assert-NoOutput
  Write-Host 'PASS: restoring the factory restores unchanged default system trust'
} finally {
  Set-Item Function:New-VerifiedDownloadHttpHandler -Value $savedFactory
  if ($null -ne $script:fixture) { $script:fixture.Dispose() }
  if ($null -ne $wrongFixture) { $wrongFixture.Dispose() }
  if ($null -ne $expiredFixture) { $expiredFixture.Dispose() }
  foreach ($certificate in @($goodCertificate, $otherCertificate, $expiredCertificate)) {
    if ($null -ne $certificate) { $certificate.Dispose() }
  }
  Remove-Item -LiteralPath $script:work -Recurse -Force
}
