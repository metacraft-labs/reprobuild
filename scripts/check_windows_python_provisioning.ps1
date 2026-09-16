Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'windows/toolchain-utils.ps1')
. (Join-Path $repoRoot 'windows/ensure-python.ps1')
$pins = Read-KeyValueFile -Path (Join-Path $repoRoot 'windows/toolchain-versions.env')
$installed = $env:REPRO_WINDOWS_PYTHON_DIR
if ([string]::IsNullOrWhiteSpace($installed)) {
  throw 'Enable WINDOWS_DIY_HCR_TESTS=1 and source env.ps1 before this gate.'
}
$expectedExe = Join-Path $installed 'python.exe'
$resolvedExe = (Get-Command python -CommandType Application | Select-Object -First 1).Source
if ([IO.Path]::GetFullPath($resolvedExe) -ne [IO.Path]::GetFullPath($expectedExe)) {
  throw 'The declared Python runtime is not the python executable on PATH.'
}
if ((Get-PythonRuntimeVersion -Executable $expectedExe) -ne $pins['PYTHON_VERSION']) {
  throw 'The active runtime does not match its pin.'
}
$installRoot = Split-Path -Parent (Split-Path -Parent $installed)
$script:archive = Join-Path $installRoot "python/_downloads/python-$($pins['PYTHON_VERSION'])-embed-amd64.zip"
Assert-FileSha256 -Path $script:archive -Expected $pins['PYTHON_WIN_X64_SHA256']
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
$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('repro-python-check-' + [Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $fresh = Join-Path $tempRoot 'fresh'
  $runtime = Ensure-Python -Root $fresh -Arch x64 -Toolchain $pins
  $exe = Join-Path $runtime 'python.exe'
  $stamp = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
  $again = Ensure-Python -Root $fresh -Arch x64 -Toolchain $pins
  if ($again -ne $runtime -or $script:downloads -ne 1 -or
      (Get-Item -LiteralPath $exe).LastWriteTimeUtc -ne $stamp) {
    throw 'Warm provisioning did not reuse the pinned runtime without another download.'
  }
  Write-Output 'PASS: fresh install and warm reuse'

  $imports = Join-Path $tempRoot 'imports'
  New-Item -ItemType Directory -Path $imports | Out-Null
  [IO.File]::WriteAllText((Join-Path $imports 'sibling.py'), 'VALUE = 287')
  [IO.File]::WriteAllText((Join-Path $imports 'driver.py'), 'import ctypes, json, sibling; print(sibling.VALUE)')
  $result = & $exe (Join-Path $imports 'driver.py')
  if ($LASTEXITCODE -ne 0 -or "$result".Trim() -ne '287') { throw 'Sibling-module import failed.' }
  Write-Output 'PASS: standard-library and sibling-module imports'

  $badPins = $pins.Clone()
  $badPins['PYTHON_WIN_X64_SHA256'] = '0' * 64
  $badRoot = Join-Path $tempRoot 'bad-checksum'
  Assert-Rejected { Ensure-Python -Root $badRoot -Arch x64 -Toolchain $badPins } 'Checksum mismatch'
  if (@(Get-ChildItem -LiteralPath $badRoot -Recurse -Filter python.exe).Count -ne 0) {
    throw 'A mismatched archive was extracted.'
  }
  Write-Output 'PASS: checksum rejection before extraction'

  $badPins = $pins.Clone()
  $badPins['PYTHON_VERSION'] = '3.0.0'
  Assert-Rejected { Ensure-Python -Root (Join-Path $tempRoot 'wrong-version') -Arch x64 -Toolchain $badPins } 'does not match version'
  Write-Output 'PASS: runtime version is checked, not inferred from the directory'

  $before = $script:downloads
  Assert-Rejected { Ensure-Python -Root (Join-Path $tempRoot 'unsupported') -Arch arm64 -Toolchain $pins } 'requires x64'
  Assert-Rejected { Ensure-Python -Root (Join-Path $tempRoot 'unpinned') -Arch x64 -Toolchain @{} } 'pins are required'
  if ($script:downloads -ne $before) { throw 'An invalid request downloaded an archive.' }
  Write-Output 'PASS: unsupported architecture and missing pins fail before download'

  Remove-Item -LiteralPath $exe
  $repaired = Ensure-Python -Root $fresh -Arch x64 -Toolchain $pins
  if ((Get-PythonRuntimeVersion -Executable (Join-Path $repaired 'python.exe')) -ne $pins['PYTHON_VERSION'] -or
      $script:downloads -ne $before) { throw 'Partial install repair failed to reuse the checked archive.' }
  Write-Output 'PASS: incomplete install is repaired from the checked archive'
} finally {
  ConvertTo-InstallRelativePath -AbsolutePath $tempRoot -Root ([IO.Path]::GetTempPath()) | Out-Null
  Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
