Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LlvmCompilerVersion {
  param([Parameter(Mandatory)][string]$Executable)
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return '' }
  try {
    $output = & $Executable --version
    if ($LASTEXITCODE -eq 0 -and "$output" -match 'clang version ([0-9]+\.[0-9]+\.[0-9]+)') {
      return $Matches[1]
    }
  } catch {}
  return ''
}

function Test-LlvmCompilers {
  param([string]$Directory, [string]$Version)
  foreach ($name in @('clang.exe', 'clang-cl.exe')) {
    if ((Get-LlvmCompilerVersion -Executable (Join-Path $Directory "bin/$name")) -ne $Version) {
      return $false
    }
  }
  return $true
}

function Ensure-Llvm {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][hashtable]$Toolchain
  )
  $version = $Toolchain['LLVM_VERSION']
  $expectedSha = $Toolchain['LLVM_WIN_X64_SHA256']
  if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $expectedSha -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'ensure-llvm: LLVM version and SHA256 pins are required.'
  }
  if ($Arch -ne 'x64') {
    throw "ensure-llvm: the Windows HCR test environment requires x64, got '$Arch'."
  }
  $Root = [IO.Path]::GetFullPath($Root)
  $installDir = Join-Path $Root "llvm/$version-$Arch"
  $metadataPath = Join-Path $installDir 'llvm.install.meta'
  $metadata = @{ llvm_version = $version; llvm_arch = $Arch; llvm_sha256 = $expectedSha.ToLowerInvariant() }
  if ((Test-KeyValueFileMatches -Expected $metadata -Actual (Read-KeyValueFile -Path $metadataPath)) -and
      (Test-LlvmCompilers -Directory $installDir -Version $version)) {
    Write-Host "LLVM $version already installed at $installDir"
    return $installDir
  }

  # Use Windows' libarchive, not an unrelated tar from Git Bash or MSYS2.
  $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
  if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
    throw 'ensure-llvm: Windows tar.exe (Windows 10 1803 or newer) is required.'
  }
  $asset = "clang+llvm-$version-x86_64-pc-windows-msvc.tar.xz"
  $cacheDir = Join-Path $Root 'llvm/_downloads'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $archive = Join-Path $cacheDir $asset
  if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    Download-File -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/$asset" -OutFile $archive
  }
  Assert-FileSha256 -Path $archive -Expected $expectedSha

  $staging = Join-Path $cacheDir ('staging-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  try {
    & $tar -xf $archive -C $staging --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw "ensure-llvm: archive extraction failed with exit $LASTEXITCODE." }
    if (-not (Test-LlvmCompilers -Directory $staging -Version $version)) {
      throw "ensure-llvm: the extracted compilers do not match version $version."
    }
    Write-KeyValueFile -Path (Join-Path $staging 'llvm.install.meta') -Values $metadata
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
  Write-Host "Installed LLVM $version at $installDir"
  return $installDir
}
