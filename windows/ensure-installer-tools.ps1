Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The tools the Windows release leg builds and signs the MSI with, provisioned
# from pinned downloads (windows/toolchain-versions.env), like the rest of the
# Windows toolchain:
#
#   WiX Toolset v3 (candle.exe, light.exe and WixUtilExtension, which carries
#   the quiet-exec custom action the MSI runs): the wix314-binaries.zip of the
#   WiX v3.14.1 release, https://github.com/wixtoolset/wix3/releases.
#   signtool.exe: the x64 signtool of the Microsoft.Windows.SDK.BuildTools
#   NuGet package, https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools,
#   so the leg does not depend on a Windows SDK being installed on the runner.
#   The package is a zip; the tool and the DLLs beside it are kept together.
#
# Requires windows/toolchain-utils.ps1 to be dot-sourced first (Download-File,
# Assert-FileSha256, Expand-ZipArchive, the key-value helpers).
#
# Returns @{ Wix3Bin = <dir with candle.exe/light.exe>; SignTool = <signtool.exe> }.
# Installs nothing outside $Root and touches no certificate store.

function Ensure-InstallerTools {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][hashtable]$Toolchain
  )
  foreach ($key in @('WIX3_VERSION', 'WIX3_URL', 'WIX3_SHA256',
                     'WINDOWS_SDK_BUILDTOOLS_VERSION', 'WINDOWS_SDK_BUILDTOOLS_SHA256',
                     'WINDOWS_SDK_BUILDTOOLS_SIGNTOOL')) {
    if (-not $Toolchain.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Toolchain[$key])) {
      throw "ensure-installer-tools: $key is not pinned in windows/toolchain-versions.env."
    }
  }
  foreach ($key in @('WIX3_SHA256', 'WINDOWS_SDK_BUILDTOOLS_SHA256')) {
    if ($Toolchain[$key] -notmatch '^[a-fA-F0-9]{64}$') { throw "ensure-installer-tools: $key is not a SHA-256." }
  }
  $Root = [IO.Path]::GetFullPath($Root)

  $wix = Install-PinnedZip -Root $Root -Name 'wix3' -Version $Toolchain['WIX3_VERSION'] `
    -Url $Toolchain['WIX3_URL'] -Sha256 $Toolchain['WIX3_SHA256'] -Probe 'light.exe'
  foreach ($f in @('candle.exe', 'light.exe', 'WixUtilExtension.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $wix $f) -PathType Leaf)) { throw "ensure-installer-tools: WiX at $wix has no $f." }
  }

  $btVersion = $Toolchain['WINDOWS_SDK_BUILDTOOLS_VERSION']
  $btUrl = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/$btVersion/microsoft.windows.sdk.buildtools.$btVersion.nupkg"
  $sdk = Install-PinnedZip -Root $Root -Name 'windows-sdk-buildtools' -Version $btVersion `
    -Url $btUrl -Sha256 $Toolchain['WINDOWS_SDK_BUILDTOOLS_SHA256'] -Probe $Toolchain['WINDOWS_SDK_BUILDTOOLS_SIGNTOOL']
  $signtool = Join-Path $sdk $Toolchain['WINDOWS_SDK_BUILDTOOLS_SIGNTOOL']

  return @{ Wix3Bin = $wix; SignTool = $signtool }
}

# Download <Url> (once, into <Root>\<Name>\_downloads), check its SHA-256,
# unpack it into <Root>\<Name>\<Version>, and return that directory. A
# directory whose install record names the same pin, and that holds <Probe>,
# is reused.
function Install-PinnedZip {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Probe
  )
  $installDir = Join-Path $Root "$Name/$Version"
  $metadataPath = Join-Path $installDir "$Name.install.meta"
  $metadata = @{ version = $Version; sha256 = $Sha256.ToLowerInvariant(); url = $Url }
  if ((Test-Path -LiteralPath (Join-Path $installDir $Probe) -PathType Leaf) -and
      (Test-KeyValueFileMatches -Expected $metadata -Actual (Read-KeyValueFile -Path $metadataPath))) {
    Write-Host "$Name $Version already installed at $installDir"
    return $installDir
  }
  $cacheDir = Join-Path $Root "$Name/_downloads"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $archive = Join-Path $cacheDir ("$Name-$Version" + [IO.Path]::GetExtension(([Uri]$Url).AbsolutePath))
  if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    Download-File -Url $Url -OutFile $archive
  }
  Assert-FileSha256 -Path $archive -Expected $Sha256
  $staging = Join-Path $cacheDir ("staging-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    Expand-ZipArchive -ArchivePath $archive -Destination $staging
    if (-not (Test-Path -LiteralPath (Join-Path $staging $Probe) -PathType Leaf)) {
      throw "ensure-installer-tools: $Url holds no $Probe."
    }
    Write-KeyValueFile -Path (Join-Path $staging "$Name.install.meta") -Values $metadata
    ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root | Out-Null
    ConvertTo-InstallRelativePath -AbsolutePath $staging -Root $Root | Out-Null
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installDir) | Out-Null
    Move-Item -LiteralPath $staging -Destination $installDir
  } finally {
    if (Test-Path -LiteralPath $staging) {
      ConvertTo-InstallRelativePath -AbsolutePath $staging -Root $Root | Out-Null
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
  }
  Write-Host "Installed $Name $Version at $installDir"
  return $installDir
}
