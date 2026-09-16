Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PythonRuntimeVersion {
  param([Parameter(Mandatory)][string]$Executable)
  $version = & $Executable -I -c 'import ctypes, json, sys; print(sys.version.split()[0])'
  if ($LASTEXITCODE -ne 0) { throw "Python runtime probe failed: $Executable" }
  return "$version".Trim()
}

function Ensure-Python {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][hashtable]$Toolchain
  )
  $version = $Toolchain["PYTHON_VERSION"]
  $expectedSha = $Toolchain["PYTHON_WIN_X64_SHA256"]
  if ($version -notmatch '^3\.[0-9]+\.[0-9]+$' -or $expectedSha -notmatch '^[a-fA-F0-9]{64}$') {
    throw "ensure-python: Python version and SHA256 pins are required."
  }
  if ($Arch -ne "x64") {
    throw "ensure-python: the Windows HCR test environment requires x64, got '$Arch'."
  }
  $Root = [IO.Path]::GetFullPath($Root)
  $installDir = Join-Path $Root "python/$version-$Arch"
  $pythonExe = Join-Path $installDir "python.exe"
  $metadataPath = Join-Path $installDir "python.install.meta"
  $metadata = @{ python_version = $version; python_arch = $Arch; python_sha256 = $expectedSha.ToLowerInvariant() }
  if ((Test-Path -LiteralPath $pythonExe -PathType Leaf) -and
      (Test-KeyValueFileMatches -Expected $metadata -Actual (Read-KeyValueFile -Path $metadataPath))) {
    if ((Get-PythonRuntimeVersion -Executable $pythonExe) -eq $version) {
      Write-Host "Python $version already installed at $installDir"
      return $installDir
    }
  }

  $asset = "python-$version-embed-amd64.zip"
  $cacheDir = Join-Path $Root "python/_downloads"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $archive = Join-Path $cacheDir $asset
  if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    Download-File -Url "https://www.python.org/ftp/python/$version/$asset" -OutFile $archive
  }
  Assert-FileSha256 -Path $archive -Expected $expectedSha

  $staging = Join-Path $cacheDir ("staging-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    Expand-Archive -LiteralPath $archive -DestinationPath $staging
    $stagedExe = Join-Path $staging "python.exe"
    if ((Get-PythonRuntimeVersion -Executable $stagedExe) -ne $version) {
      throw "ensure-python: the extracted runtime does not match version $version."
    }
    # HCR drivers import sibling modules. Restore normal script-directory lookup;
    # no unpinned pip bootstrap or third-party package installation is needed.
    $majorMinor = ($version -split '\.')[0..1] -join ''
    Remove-Item -LiteralPath (Join-Path $staging "python$majorMinor._pth")
    Copy-Item -LiteralPath $stagedExe -Destination (Join-Path $staging "python3.exe")
    Write-KeyValueFile -Path (Join-Path $staging "python.install.meta") -Values $metadata
    # Check both resolved targets before replacing anything under the install root.
    ConvertTo-InstallRelativePath -AbsolutePath $installDir -Root $Root | Out-Null
    ConvertTo-InstallRelativePath -AbsolutePath $staging -Root $Root | Out-Null
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $installDir
  } finally {
    if (Test-Path -LiteralPath $staging) {
      ConvertTo-InstallRelativePath -AbsolutePath $staging -Root $Root | Out-Null
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
  }
  Write-Host "Installed Python $version at $installDir"
  return $installDir
}
