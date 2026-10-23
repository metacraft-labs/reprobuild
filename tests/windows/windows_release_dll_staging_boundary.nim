## Required Windows release-DLL selection/provenance boundary.
##
## PE fixtures contain only the headers this stager inspects. They are format
## and file-selection fixtures, not executable DLLs or proof of loader/ABI
## compatibility. A real .NET ZIP supplies a private same-job archive. The
## production PowerShell functions read/hash/extract/copy the real files.
## Invoke-WebRequest is replaced only by a refusal: these permanent tests may
## not fetch fixture inputs, and cached-source success must need no network.
## No Windows process, filesystem or DLL-loader API is replaced with success.
##
## Like windows_expand_archive_execution_boundary.nim, this is directly
## enrolled in the required native Windows CI job, not advertised as soAny.
## Off-Windows compilation is a hard error. Missing OS PowerShell is a failure.
## Complete release/default-build/native DLL-load acceptance remains separate.
when not defined(windows):
  {.fatal: "windows_release_dll_staging_boundary requires native Windows".}

import std/[os, osproc, streams, strtabs, strutils, unittest]
from std/sysrand import urandom
import repro_test_support/process_fixtures

const Controls = r"""
param([string]$Source, [string]$Utils, [string]$Fixture)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$processImage = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
Write-Host ('POWERSHELL_IMAGE=' + $processImage)
Write-Host ('POWERSHELL_SHA256=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $processImage).Hash)
Write-Host ('POWERSHELL_VERSION=' + $PSVersionTable.PSVersion.ToString())
Write-Host ('CLR_VERSION=' + [Environment]::Version.ToString())
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Required OS PowerShell5.1 was not selected.' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
. $Utils
foreach ($name in @('Get-VerifiedReleaseArchive', 'Download-Zip', 'Copy-IntoBin')) {
    $fn = $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object Name -eq $name
    if (@($fn).Count -ne 1) { throw "Expected one production function $name" }
    . ([ScriptBlock]::Create($fn.Extent.Text))
}
$script:networkRequested = $false
function Invoke-WebRequest {
    $script:networkRequested = $true
    throw 'Permanent release-DLL controls must not download.'
}
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host ('CONTROL=' + $Message)
}
function Write-PeFixture([string]$Path, [uint16]$Machine) {
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4d; $bytes[1] = 0x5a
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes, 0x3c)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes, 0x80)
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
$binDir = Join-Path $Fixture 'bin'
New-Item -ItemType Directory -Path $binDir | Out-Null
$x64 = Join-Path $Fixture 'selected-x64.dll'; $x86 = Join-Path $Fixture 'other-x86.dll'
Write-PeFixture $x64 0x8664; Write-PeFixture $x86 0x14c
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $x64).Hash
Set-Content -LiteralPath (Join-Path $binDir 'selected.dll') -Value 'old output'
Copy-IntoBin -SrcPath $x64 -DestName 'selected.dll' -ExpectedSha256 $sha
Require ((Get-FileHash -Algorithm SHA256 (Join-Path $binDir 'selected.dll')).Hash -eq $sha) 'selected x64 bytes replace stale output'
$certificate = Join-Path $Fixture 'cacert-source.pem'
Set-Content -LiteralPath $certificate -Value 'certificate-copy fixture; no TLS assertion'
Copy-IntoBin -SrcPath $certificate -DestName 'cacert.pem'
Require ((Get-FileHash -Algorithm SHA256 (Join-Path $binDir 'cacert.pem')).Hash -eq (Get-FileHash -Algorithm SHA256 $certificate).Hash) 'non-DLL certificate staging remains intact'
$refused = $false
try { Copy-IntoBin -SrcPath $x64 -DestName 'changed.dll' -ExpectedSha256 ('0' * 64) } catch { $refused = $true }
Require $refused 'wrong preferred hash is refused'
$refused = $false
try { Copy-IntoBin -SrcPath $x86 -DestName 'x86.dll' } catch { $refused = $true }
Require $refused 'x86 PE source is refused'

# A genuine self-contained ZIP; no network or external fixture corpus.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$work = Join-Path $Fixture 'archive'
New-Item -ItemType Directory -Path $work | Out-Null
$archive = Join-Path $work 'pkg.zip'
$stream = [IO.File]::Open($archive, [IO.FileMode]::CreateNew)
$zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
try {
    $entry = $zip.CreateEntry('sqlite3.dll')
    $body = $entry.Open()
    try { $bytes = [IO.File]::ReadAllBytes($x64); $body.Write($bytes, 0, $bytes.Length) }
    finally { $body.Dispose() }
} finally { $zip.Dispose(); $stream.Dispose() }
Copy-Item -LiteralPath $archive -Destination (Join-Path $Fixture 'archive-saved.zip')
$archiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
$a = Download-Zip -Url 'http://127.0.0.1:1/must-not-be-used' -Sha256 $archiveSha -OutDir $work
Set-Content (Join-Path $a 'stale') 'old extraction'
$b = Download-Zip -Url 'http://127.0.0.1:1/must-not-be-used' -Sha256 $archiveSha -OutDir $work
Require ($a -ne $b -and -not (Test-Path (Join-Path $b 'stale'))) 'same-job archive reuse has fresh extraction scratch'
Set-Content -LiteralPath $archive -Value 'corrupt cache'
$refused = $false
try { $null = Download-Zip -Url 'http://127.0.0.1:1/must-not-be-used' -Sha256 $archiveSha -OutDir $work } catch { $refused = $true }
Require $refused 'cached archive hash is checked on every use'
Copy-Item -LiteralPath (Join-Path $Fixture 'archive-saved.zip') -Destination $archive -Force
Require ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -eq $archiveSha) 'empty-hash control starts with a valid archive'
$script:networkRequested = $false
$refused = $false
try {
    $null = Get-VerifiedReleaseArchive -Url 'http://127.0.0.1:1/must-not-be-used' -Sha256 '' -ArchivePath $archive
} catch { $refused = $true }
Require ($refused -and -not $script:networkRequested) 'empty archive hash is refused before extraction or network'

# Execute the actual selected-prefix and SQLite staging blocks. A source-mode
# prefix intentionally contains NO SQLite; the fixed fallback must succeed.
$text = Get-Content -LiteralPath $Source -Raw -Encoding UTF8
$toolchainRoot = Join-Path $Fixture 'toolchain'
$toolchain = @{ NIM_VERSION='2.2.8'; NIM_SQLITE_DLL_SHA256=$sha; SQLITE_RUNTIME_ARCHIVE_SHA256=$archiveSha }
$versionRoot = Join-Path $toolchainRoot 'nim/2.2.8'
New-Item -ItemType Directory -Force -Path $versionRoot | Out-Null
$relative = 'nim/2.2.8/source/selected'
Set-Content (Join-Path $versionRoot 'nim.install.relative-path') $relative
Set-Content (Join-Path $versionRoot 'nim.install.meta') "nim_version=2.2.8`ninstall_relative_path=$relative`neffective_mode=source"
$first = $text.IndexOf('$nimVersionRoot ='); $last = $text.IndexOf('$opensslRoot =', $first)
if ($first -lt 0 -or $last -lt 0) { throw 'Production Nim selection block missing.' }
. ([ScriptBlock]::Create($text.Substring($first, $last-$first)))
Require ($nimDir -eq (Join-Path $toolchainRoot "$relative/bin")) 'source-mode selected prefix is preserved'
$tmp = Join-Path $Fixture 'tmp'
$fallback = Join-Path $tmp 'sqlite-3460100'
New-Item -ItemType Directory -Force -Path $fallback | Out-Null
# Restore the actual verified fixture ZIP into the existing same-job location.
Copy-Item -LiteralPath (Join-Path $Fixture 'archive-saved.zip') -Destination (Join-Path $fallback 'pkg.zip')
$first = $text.IndexOf('$sqliteSrc ='); $last = $text.IndexOf('# ── 5.', $first)
if ($first -lt 0 -or $last -lt 0) { throw 'Production SQLite staging block missing.' }
$sqliteBlock = [ScriptBlock]::Create($text.Substring($first, $last-$first))
. $sqliteBlock
Require ((Get-FileHash -Algorithm SHA256 (Join-Path $binDir 'sqlite3.dll')).Hash -eq $sha) 'source-mode missing SQLite uses authenticated fallback'
. $sqliteBlock
Require ((Get-FileHash -Algorithm SHA256 (Join-Path $binDir 'sqlite3_64.dll')).Hash -eq $sha) 'second source-mode pass reuses the same verified archive'
New-Item -ItemType Directory -Force -Path $nimDir | Out-Null
$changed = [IO.File]::ReadAllBytes($x64); $changed[$changed.Length-1] = 1
[IO.File]::WriteAllBytes((Join-Path $nimDir 'sqlite3_64.dll'), $changed)
$refused = $false
try { . $sqliteBlock } catch { $refused = $true }
Require $refused 'present wrong preferred content is not fallback permission'
Write-Host 'RELEASE_DLL_STAGING_CONTROLS=PASS'
"""

proc scratchRoot(): string =
  var nonce: string
  for value in urandom(8): nonce.add(toHex(value, 2))
  result = getTempDir() / ("release-dll-boundary-" & $getCurrentProcessId() & "-" & nonce)
  doAssert not dirExists(result) and not fileExists(result) and not symlinkExists(result)
  releaseDirAtProcessExit(result)
  createDir(result)

suite "Windows release DLL staging":
  test "selected DLLs and authenticated source-mode fallback":
    let root = scratchRoot()
    let source = getCurrentDir() / "windows/stage-release-dlls.ps1"
    let utils = getCurrentDir() / "windows/toolchain-utils.ps1"
    doAssert fileExists(source) and fileExists(utils)
    let script = root / "controls.ps1"
    # Windows PowerShell5.1 must decode the script's UTF-8 marker text exactly.
    writeFile(script, "\xEF\xBB\xBF" & Controls)
    let executable = getEnv("SystemRoot") / "System32/WindowsPowerShell/v1.0/powershell.exe"
    doAssert executable.isAbsolute and fileExists(executable)
    var environment = newStringTable(modeCaseInsensitive)
    for key, value in envPairs():
      if cmpIgnoreCase(key, "PSModulePath") != 0: environment[key] = value
    let process = startProcess(executable,
      args = @["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
        "-Source", source, "-Utils", utils, "-Fixture", root],
      env = environment, options = {poStdErrToStdOut})
    defer: process.close()
    var output: string
    while not process.outputStream.atEnd(): output.add(process.outputStream.readAll())
    let code = process.waitForExit()
    var witnessCount = 0
    for line in output.splitLines():
      if line.startsWith("POWERSHELL_IMAGE=") or
          line.startsWith("POWERSHELL_SHA256=") or
          line.startsWith("POWERSHELL_VERSION=") or line.startsWith("CLR_VERSION="):
        check line.len <= 2048
        if line.len <= 2048: echo line
        inc witnessCount
    checkpoint output
    check witnessCount == 4
    check code == 0
    check output.contains("RELEASE_DLL_STAGING_CONTROLS=PASS")
    check output.contains("POWERSHELL_IMAGE=") and output.contains("POWERSHELL_SHA256=")
