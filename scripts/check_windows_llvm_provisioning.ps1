Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'windows/toolchain-utils.ps1')
. (Join-Path $repoRoot 'windows/ensure-llvm.ps1')
$pins = Read-KeyValueFile -Path (Join-Path $repoRoot 'windows/toolchain-versions.env')
$installed = $env:REPRO_WINDOWS_LLVM_DIR
if ([string]::IsNullOrWhiteSpace($installed)) {
  throw 'Enable WINDOWS_DIY_HCR_TESTS=1 and source env.ps1 before this gate.'
}
foreach ($name in @('clang.exe', 'clang-cl.exe')) {
  $expected = Join-Path $installed "bin/$name"
  $resolved = (Get-Command $name -CommandType Application | Select-Object -First 1).Source
  if ([IO.Path]::GetFullPath($resolved) -ne [IO.Path]::GetFullPath($expected)) {
    throw "$name does not resolve to the declared LLVM installation."
  }
}
if (-not (Test-LlvmCompilers -Directory $installed -Version $pins['LLVM_VERSION'])) {
  throw 'The active compilers do not match their pin.'
}
$installRoot = Split-Path -Parent (Split-Path -Parent $installed)
$script:archive = Join-Path $installRoot "llvm/_downloads/clang+llvm-$($pins['LLVM_VERSION'])-x86_64-pc-windows-msvc.tar.xz"
Assert-FileSha256 -Path $script:archive -Expected $pins['LLVM_WIN_X64_SHA256']
$script:downloads = 0
function Download-File {
  param([string]$Url, [string]$OutFile)
  $script:downloads++
  Copy-Item -LiteralPath $script:archive -Destination $OutFile
}
function Assert-Rejected {
  param([scriptblock]$Operation, [string]$Pattern)
  try { & $Operation | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Pattern) { throw }
    return
  }
  throw "Expected rejection matching '$Pattern'."
}
$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('repro-llvm-check-' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $before = $script:downloads
  Assert-Rejected { Ensure-Llvm -Root (Join-Path $tempRoot 'unsupported') -Arch arm64 -Toolchain $pins } 'requires x64'
  Assert-Rejected { Ensure-Llvm -Root (Join-Path $tempRoot 'unpinned') -Arch x64 -Toolchain @{} } 'pins are required'
  if ($script:downloads -ne $before) { throw 'An invalid request downloaded an archive.' }
  Write-Output 'PASS: unsupported architecture and missing pins fail before download'

  $badPins = $pins.Clone()
  $badPins['LLVM_WIN_X64_SHA256'] = '0' * 64
  $badRoot = Join-Path $tempRoot 'bad-checksum'
  Assert-Rejected { Ensure-Llvm -Root $badRoot -Arch x64 -Toolchain $badPins } 'Checksum mismatch'
  if (@(Get-ChildItem -LiteralPath $badRoot -Recurse -Filter clang.exe).Count -ne 0) {
    throw 'A mismatched archive was extracted.'
  }
  Write-Output 'PASS: checksum rejection before extraction'

  $fresh = Join-Path $tempRoot 'fresh'
  $runtime = Ensure-Llvm -Root $fresh -Arch x64 -Toolchain $pins
  $exe = Join-Path $runtime 'bin/clang-cl.exe'
  $stamp = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
  $before = $script:downloads
  $again = Ensure-Llvm -Root $fresh -Arch x64 -Toolchain $pins
  if ($again -ne $runtime -or $script:downloads -ne $before -or
      (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ne $stamp) {
    throw 'Warm provisioning did not reuse the pinned compilers without another download.'
  }
  Write-Output 'PASS: fresh install and warm reuse of both compilers'

  Remove-Item -LiteralPath $exe
  $repaired = Ensure-Llvm -Root $fresh -Arch x64 -Toolchain $pins
  if (-not (Test-LlvmCompilers -Directory $repaired -Version $pins['LLVM_VERSION']) -or
      $script:downloads -ne $before) { throw 'Partial install repair failed to reuse the checked archive.' }
  Write-Output 'PASS: incomplete install is repaired from the checked archive'

  $badPins = $pins.Clone()
  $badPins['LLVM_VERSION'] = '0.0.1'
  $badRoot = Join-Path $tempRoot 'wrong-version'
  Assert-Rejected { Ensure-Llvm -Root $badRoot -Arch x64 -Toolchain $badPins } 'do not match version'
  if (Test-Path -LiteralPath (Join-Path $badRoot 'llvm/0.0.1-x64')) {
    throw 'The wrong compiler version was published as a successful install.'
  }
  Write-Output 'PASS: compiler versions are checked before publishing an install'

  $script:archive = Join-Path $tempRoot 'invalid.tar.xz'
  [IO.File]::WriteAllText($script:archive, 'Not an LLVM archive')
  $badPins = $pins.Clone()
  $badPins['LLVM_WIN_X64_SHA256'] = (Get-FileHash -LiteralPath $script:archive -Algorithm SHA256).Hash
  $badRoot = Join-Path $tempRoot 'bad-archive'
  Assert-Rejected { Ensure-Llvm -Root $badRoot -Arch x64 -Toolchain $badPins } 'archive extraction failed|tar.exe'
  if (Test-Path -LiteralPath (Join-Path $badRoot "llvm/$($pins['LLVM_VERSION'])-x64")) {
    throw 'Failed extraction was published as a successful install.'
  }
  Write-Output 'PASS: corrupt archives fail without publishing a partial install'
} finally {
  ConvertTo-InstallRelativePath -AbsolutePath $tempRoot -Root ([IO.Path]::GetTempPath()) | Out-Null
  Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
