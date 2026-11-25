<#
.SYNOPSIS
  Verify the Authenticode signature of a signed file (the MSI) on Windows,
  without adding anything to any certificate store.

.DESCRIPTION
  verify-authenticode.ps1 -Path <file> -StandInCertificate <cert.pem>
  verify-authenticode.ps1 -Path <file> -RequireValid

  Windows decides whether an Authenticode signature is trusted from its
  certificate stores (Get-AuthenticodeSignature, WinVerifyTrust). A stand-in
  certificate made for one run is in none of them, and adding it to one would
  change the trust of the machine and the profile the check runs under, which
  a test must never do. So for a stand-in this script asserts what CAN be
  established without trusting it, and nothing more:

  1. Get-AuthenticodeSignature reports the file SIGNED and its hash INTACT:
     the status is UnknownError or NotTrusted, the two statuses Windows gives
     a signature whose chain ends in a root it does not trust
     (CERT_E_UNTRUSTEDROOT, "terminated in a root certificate which is not
     trusted"; https://learn.microsoft.com/dotnet/api/system.management.automation.signaturestatus).
     NotSigned (no signature), HashMismatch (the file changed after it was
     signed) and every other status are refused. `Valid` is refused too: a
     stand-in that Windows trusts means someone trusted it in a store.
  2. The signer certificate is the stand-in: its SHA-1 thumbprint equals the
     one of -StandInCertificate.
  3. The signer chains to the stand-in when the stand-in is supplied as the
     only extra certificate, with an unknown root allowed and revocation not
     checked (X509Chain with ExtraStore and AllowUnknownCertificateAuthority;
     https://learn.microsoft.com/dotnet/api/system.security.cryptography.x509certificates.x509chainpolicy),
     the chain's root is the stand-in, and no chain status other than
     UntrustedRoot is reported. Building a chain does not write to a store.
  4. The signer certificate carries the code-signing extended key usage
     (1.3.6.1.5.5.7.3.3).

  -RequireValid is the production check: Get-AuthenticodeSignature must report
  `Valid`, which only a certificate that chains to a root Windows trusts, with
  an intact hash, gets.

  Prints one line per check and exits 0 when all pass, 1 otherwise.
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$StandInCertificate,
  [switch]$RequireValid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Refuse([string]$Message) {
  [Console]::Error.WriteLine("verify-authenticode: REFUSED ${Path}: $Message")
  exit 1
}

if ($RequireValid -eq [bool]$StandInCertificate) {
  Refuse 'pass exactly one of -StandInCertificate <cert> and -RequireValid'
}
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Refuse 'no such file' }

$sig = Get-AuthenticodeSignature -LiteralPath $Path
$status = [string]$sig.Status
Write-Host "status: $status ($($sig.StatusMessage))"
if ($null -eq $sig.SignerCertificate) { Refuse "the file carries no signer certificate (status $status)" }
$signer = $sig.SignerCertificate
Write-Host "signer: $($signer.Subject) thumbprint $($signer.Thumbprint)"

if ($RequireValid) {
  if ($status -ne 'Valid') { Refuse "Get-AuthenticodeSignature reports $status, not Valid" }
  Write-Host 'ok: Valid (the signature verifies and chains to a root Windows trusts)'
  exit 0
}

if (-not (Test-Path -LiteralPath $StandInCertificate -PathType Leaf)) { Refuse "no stand-in certificate at $StandInCertificate" }
if ($status -notin @('UnknownError', 'NotTrusted')) {
  Refuse "status ${status}: a stand-in signature must be intact and untrusted (UnknownError or NotTrusted)"
}
Write-Host "ok: signed, hash intact, root not trusted by Windows ($status), as a stand-in must be"

# The .NET Framework loader reads a PEM (Base64 with headers) certificate file.
$standIn = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $StandInCertificate
if ($signer.Thumbprint -ne $standIn.Thumbprint) {
  Refuse "the signer $($signer.Thumbprint) is not the stand-in $($standIn.Thumbprint)"
}
Write-Host "ok: the signer is the stand-in certificate ($($standIn.Thumbprint))"

$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
$chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
[void]$chain.ChainPolicy.ExtraStore.Add($standIn)
$built = $chain.Build($signer)
$elements = @($chain.ChainElements)
$root = $elements[$elements.Count - 1].Certificate
$other = @($chain.ChainStatus | Where-Object { $_.Status -ne [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot })
if (-not $built -or $other.Count -gt 0) {
  Refuse ("the signer does not chain to the stand-in: " + (($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', '))
}
if ($root.Thumbprint -ne $standIn.Thumbprint) {
  Refuse "the chain ends at $($root.Subject), not the stand-in"
}
Write-Host "ok: chains to the stand-in root ($($elements.Count) element(s); no status but UntrustedRoot)"

$eku = @($signer.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
$codeSigning = $eku | ForEach-Object { $_.EnhancedKeyUsages } | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }
if (-not $codeSigning) { Refuse 'the signer certificate lacks the code-signing extended key usage' }
Write-Host 'ok: code-signing extended key usage'
exit 0
