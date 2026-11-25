<#
The Windows half of the signed-installer tests (the Linux half is
tests/unit/test_release_signed_installers.py): the MSI signed by the release
leg's own driver, scripts/release/build_signed_installer.sh, with signtool and
a stand-in Authenticode certificate generated for the run, then checked with
scripts/release-signing/verify-authenticode.ps1 and Get-AuthenticodeSignature.

  powershell -NoProfile -ExecutionPolicy Bypass -File tools\multi-distro-harness\tests\m8e_signed_msi_windows.ps1 [-Archive <reprobuild-<v>-windows-x86_64.zip>]

Run it from a reprobuild checkout as an ordinary user. It needs no
administrator rights, and writes only under one scratch directory (-Work,
default a new directory under %TEMP%): WiX v3.14.1 and signtool are
provisioned there by windows/ensure-installer-tools.ps1 from their pinned
downloads (windows/toolchain-versions.env); the stand-in certificate lives
there and is never imported into any certificate store. The check records
every certificate store it could plausibly touch (CurrentUser and
LocalMachine: My, Root, CA, TrustedPublisher, Disallowed) before and after,
and fails if any changed.

With -Archive, the MSI is the release packager's (the driver's --archive path,
as the leg runs it); without, a one-file MSI is built with the same WiX from a
fixture authoring and signed through the driver's --package path, which is the
same signing code.

What it asserts, and why each is the right expectation for a stand-in that
Windows does not trust:
  * the driver exits 0 in stand-in mode, signing with signtool;
  * verify-authenticode.ps1 -StandInCertificate accepts it: status
    UnknownError or NotTrusted (signed, hash intact, untrusted root), the
    signer's thumbprint is the stand-in's, the chain built with the stand-in
    as the only extra certificate ends at it, code-signing usage;
  * verify-authenticode.ps1 -RequireValid (the production check) REFUSES it;
  * controls: a copy with one byte changed is refused (HashMismatch); a
    second, different stand-in is refused (thumbprint); the unsigned MSI is
    refused (NotSigned);
  * the publish job's refusal (refuse_stand_in_signed_assets.sh) finds the
    stand-in certificate in the signtool-signed MSI's bytes, with no marker
    file beside it;
  * a publishing run (REPRO_RELEASE_PUBLISHING=1) refuses the stand-in mode.

Exit status: 0 when every check passed and nothing was NOT RUN, 1 on a
failure, 3 when all passed but a leg was NOT RUN.
#>
[CmdletBinding()]
param(
  [string]$Work = '',
  [string]$Archive = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'm8c_common.ps1')
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
. (Join-Path $RepoRoot 'windows/toolchain-utils.ps1')
. (Join-Path $RepoRoot 'windows/ensure-installer-tools.ps1')

if (-not $Work) { $Work = Join-Path ([IO.Path]::GetTempPath()) ('m8e-signed-msi-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Work = (Resolve-Path -LiteralPath $Work).Path
$Tmp = Join-Path $Work 'tmp'
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
Set-Location -LiteralPath $RepoRoot

$Stores = @('CurrentUser\My', 'CurrentUser\Root', 'CurrentUser\CA', 'CurrentUser\TrustedPublisher', 'CurrentUser\Disallowed',
            'LocalMachine\My', 'LocalMachine\Root', 'LocalMachine\CA', 'LocalMachine\TrustedPublisher', 'LocalMachine\Disallowed')
function Get-StoreState {
  foreach ($s in $Stores) {
    $items = @(Get-ChildItem -LiteralPath "Cert:\$s" -ErrorAction SilentlyContinue | ForEach-Object { $_.Thumbprint } | Sort-Object)
    "$s=" + ($items -join ',')
  }
}

# The repository scripts run under Git for Windows' bash, with the
# environment this process sets; the signing secrets are cleared so the
# driver takes the stand-in mode.
$SecretVars = @('REPRO_AUTHENTICODE_PFX_BASE64', 'REPRO_AUTHENTICODE_PFX_PASSWORD', 'REPRO_SIGNING_ALLOW_TEST_KEY',
                'REPRO_RELEASE_PUBLISHING', 'REPRO_AUTHENTICODE_TOOL', 'REPRO_AUTHENTICODE_TRUST_BUNDLE')
function Invoke-Script {
  param([string[]]$Arguments, [hashtable]$Environment = @{})
  $saved = @{}
  foreach ($k in $SecretVars + @($Environment.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
  foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
  try { return Invoke-NativeCommand -FilePath $script:Bash -ArgumentList $Arguments }
  finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}
function Invoke-Verify {
  param([string]$Msi, [string[]]$Mode)
  $ps = (Get-Command powershell.exe -CommandType Application).Source
  return Invoke-NativeCommand -FilePath $ps -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      (Join-Path $RepoRoot 'scripts\release-signing\verify-authenticode.ps1'), '-Path', $Msi) + $Mode)
}

$storesBefore = @(Get-StoreState)
try {
  Write-Step 'preconditions'
  $script:Bash = Get-ScriptBash -RepoRoot $RepoRoot
  if (-not $script:Bash) { throw 'no Git for Windows bash for the repository scripts' }
  $toolchain = Read-KeyValueFile -Path (Join-Path $RepoRoot 'windows\toolchain-versions.env')
  $tools = Ensure-InstallerTools -Root (Join-Path $Work 'tools') -Toolchain $toolchain
  Pass "WiX $($toolchain['WIX3_VERSION']) and signtool ($($toolchain['WINDOWS_SDK_BUILDTOOLS_VERSION'])) provisioned from their pinned SHA-256"
  $common = @{ TMPDIR = (ConvertTo-ScriptPath $Tmp); REPRO_SIGNTOOL = $tools.SignTool;
               REPRO_WIX3_BIN = (ConvertTo-ScriptPath $tools.Wix3Bin); REPRO_MSI_TOOLSET = 'wix3' }

  Write-Step 'the MSI, signed in stand-in mode'
  $out = Join-Path $Work 'out'
  if ($Archive) {
    $m = [regex]::Match((Split-Path -Leaf $Archive), '^reprobuild-(.+)-windows-x86_64\.zip$')
    if (-not $m.Success) { throw "-Archive must be a reprobuild-<version>-windows-x86_64.zip" }
    $unsigned = $null
    $source = @('--version', $m.Groups[1].Value, '--archive', (ConvertTo-ScriptPath $Archive))
    $name = "reprobuild-$($m.Groups[1].Value)-windows-x86_64.msi"
  } else {
    $src = Join-Path $Work 'fixture'
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'hello.txt') -Value ('hello from the fixture' * 50) -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $src 'fixture.wxs') -Encoding UTF8 -Value @'
<?xml version="1.0"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
 <Product Id="*" Name="Fixture" Language="1033" Version="1.0.0" Manufacturer="Fixture" UpgradeCode="{6F2D8C1E-4B7A-4E39-9C55-2A1B3C4D5E6F}">
  <Package InstallerVersion="200" Compressed="yes" InstallScope="perMachine"/>
  <MediaTemplate EmbedCab="yes"/>
  <Directory Id="TARGETDIR" Name="SourceDir"><Directory Id="ProgramFilesFolder"><Directory Id="D" Name="Fixture">
   <Component Id="C" Guid="{6F2D8C1E-4B7A-4E39-9C55-2A1B3C4D5E70}"><File Id="F" Source="hello.txt"/></Component>
  </Directory></Directory></Directory>
  <Feature Id="Main" Level="1"><ComponentRef Id="C"/></Feature>
 </Product>
</Wix>
'@
    $name = 'reprobuild-0.0.0-windows-x86_64.msi'
    $unsigned = Join-Path $src $name
    Push-Location $src
    try {
      $c = Invoke-NativeCommand -FilePath (Join-Path $tools.Wix3Bin 'candle.exe') -ArgumentList @('-nologo', '-arch', 'x64', '-out', 'fixture.wixobj', 'fixture.wxs')
      $l = Invoke-NativeCommand -FilePath (Join-Path $tools.Wix3Bin 'light.exe') -ArgumentList @('-nologo', '-sval', '-out', $unsigned, 'fixture.wixobj')
    } finally { Pop-Location }
    Assert-Equal "$($c.Code)/$($l.Code)" '0/0' 'fixture MSI built with WiX (candle/light exit codes)'
    $source = @('--package', (ConvertTo-ScriptPath $unsigned))
  }
  $r = Invoke-Script -Arguments (@('./scripts/release/build_signed_installer.sh', '--ecosystem', 'msi', '--out', (ConvertTo-ScriptPath $out)) + $source) -Environment $common
  Assert-Equal $r.Code 0 'build_signed_installer.sh --ecosystem msi (stand-in mode) exit code'
  $msi = Join-Path $out $name
  $root = "$msi.stand-in-root.pem"
  if (-not (Test-Path -LiteralPath $msi)) { throw "the driver produced no $msi" }
  $report = Get-Content -LiteralPath "$msi.signing-report.txt" -Raw
  Write-Host $report
  Assert-True ($report -match 'mode: standin') 'the report says stand-in mode'
  Assert-True ($report -match 'signing: class=test tool=signtool') 'signed with signtool, as a test certificate'
  Assert-True (Test-Path -LiteralPath "$msi.SIGNED-WITH-A-TEST-CERTIFICATE") 'the stand-in marker is beside the MSI'

  Write-Step 'verification of the stand-in signature, store-free'
  $sig = Get-AuthenticodeSignature -LiteralPath $msi
  Write-Host "Get-AuthenticodeSignature: $($sig.Status): $($sig.StatusMessage)"
  Assert-True ($sig.Status -in @('UnknownError', 'NotTrusted')) "Get-AuthenticodeSignature reports an intact signature from an untrusted root ($($sig.Status))"
  Assert-Equal (Invoke-Verify $msi @('-StandInCertificate', $root)).Code 0 'verify-authenticode.ps1 -StandInCertificate accepts it'
  Assert-Equal (Invoke-Verify $msi @('-RequireValid')).Code 1 'verify-authenticode.ps1 -RequireValid (the production check) refuses a stand-in'

  Write-Step 'controls'
  $tampered = Join-Path $Work 'tampered.msi'
  Copy-Item -LiteralPath $msi -Destination $tampered
  $bytes = [IO.File]::ReadAllBytes($tampered)
  $cab = -1
  for ($i = 0; $i -lt $bytes.Length - 4; $i++) { if ($bytes[$i] -eq 0x4D -and $bytes[$i+1] -eq 0x53 -and $bytes[$i+2] -eq 0x43 -and $bytes[$i+3] -eq 0x46) { $cab = $i; break } }
  if ($cab -lt 0) { throw 'no embedded cabinet (MSCF) in the signed MSI' }
  $bytes[$cab + 200] = $bytes[$cab + 200] -bxor 1
  [IO.File]::WriteAllBytes($tampered, $bytes)
  Write-Host "tampered: $((Get-AuthenticodeSignature -LiteralPath $tampered).Status)"
  Assert-Equal (Invoke-Verify $tampered @('-StandInCertificate', $root)).Code 1 'a copy with one cabinet byte changed is refused'
  $other = Join-Path $Work 'other-standin'
  $g = Invoke-Script -Arguments @('./scripts/release-signing/make-test-installer-certs.sh', '--dir', (ConvertTo-ScriptPath $other)) -Environment $common
  Assert-Equal $g.Code 0 'a second stand-in generated'
  Assert-Equal (Invoke-Verify $msi @('-StandInCertificate', (Join-Path $other 'authenticode.pem'))).Code 1 'a different stand-in is refused'
  if ($unsigned) {
    Write-Host "unsigned: $((Get-AuthenticodeSignature -LiteralPath $unsigned).Status)"
    Assert-Equal (Invoke-Verify $unsigned @('-StandInCertificate', $root)).Code 1 'the unsigned MSI is refused'
  } else { NotRun 'the unsigned control (with -Archive the unsigned MSI stays inside the driver)' }
  # The publish job's last refusal reads the signer certificate's marker in
  # the package's bytes; signtool writes the DigitalSignature stream itself,
  # so it is checked on signtool's output here, with the marker file left out.
  $staging = Join-Path $Work 'staging'
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  Copy-Item -LiteralPath $msi -Destination $staging
  $f = Invoke-Script -Arguments @('./scripts/release/refuse_stand_in_signed_assets.sh', (ConvertTo-ScriptPath $staging)) -Environment $common
  Assert-Equal $f.Code 1 'the publish refusal finds the stand-in in the signtool-signed MSI without its marker file'
  $p = Invoke-Script -Arguments (@('./scripts/release/build_signed_installer.sh', '--ecosystem', 'msi', '--out', (ConvertTo-ScriptPath (Join-Path $Work 'out-publishing'))) + $source) `
    -Environment ($common + @{ REPRO_RELEASE_PUBLISHING = '1' })
  Assert-True ($p.Code -ne 0) "a publishing run refuses the stand-in mode (exit $($p.Code))"
} catch {
  Fail "harness error: $($_.Exception.Message)"
} finally {
  $storesAfter = @(Get-StoreState)
  Assert-Equal (Compare-Object $storesBefore $storesAfter | Measure-Object).Count 0 'no certificate store changed'
}
exit (Complete-Run -Name 'm8e_signed_msi_windows' -Work $Work)
