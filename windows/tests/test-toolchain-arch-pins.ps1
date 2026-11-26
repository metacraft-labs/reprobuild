Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# test-toolchain-arch-pins.ps1 -- the per-architecture pin conventions of
# windows/toolchain-versions.env (reprobuild-pm Distribution-And-Packaging.md
# §7.1, "windows/toolchain-versions.env conventions").
#
# Pure logic over the real pin file and in-memory tables: no download, no
# install, no host state, so it runs on any PowerShell 5.1+ or 7 host,
# including Linux pwsh. No mocks.
#
# The release closure audit is also tested here, on any host, against PE
# images this file writes (New-TestPeImage). They are fixtures, not mocks:
# real files in the PE/COFF layout, read by the same readers the release uses.
# They exist because the cases the audit must refuse (a delay-loaded DLL the
# archive does not carry, a DLL of the wrong machine) cannot be produced from
# a host's own system images, and because Linux pwsh has no system images at
# all. The Windows-only block below still runs the audit on real images.

$windowsDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $windowsDir "toolchain-utils.ps1")

$failures = New-Object System.Collections.Generic.List[string]
function Check {
  param([string]$Name, [scriptblock]$Body)
  try {
    & $Body
    Write-Host "  ok    $Name"
  } catch {
    $failures.Add("$Name -- $($_.Exception.Message)")
    Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
  }
}
function Assert-Throws {
  param([scriptblock]$Body, [string]$Pattern)
  try { & $Body | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Pattern) {
      throw "threw '$($_.Exception.Message)', which does not match '$Pattern'"
    }
    return
  }
  throw "did not throw (expected '$Pattern')"
}

$pins = Read-KeyValueFile -Path (Join-Path $windowsDir "toolchain-versions.env")

Write-Host "toolchain-versions.env conventions"
Check "the real pin file keeps every convention" {
  $violations = Get-ToolchainPinConventionViolations -Toolchain $pins
  if ($violations.Count -ne 0) { throw ($violations -join "; ") }
}
Check "every shared version key is present" {
  foreach ($key in $SharedToolchainVersionKeys) {
    if ([string]::IsNullOrWhiteSpace($pins[$key])) { throw "$key missing" }
  }
}
Check "the arm64 C toolchain is pinned" {
  foreach ($key in @("LLVM_MINGW_WIN_ARM64_RELEASE", "LLVM_MINGW_WIN_ARM64_SHA256")) {
    if ([string]::IsNullOrWhiteSpace($pins[$key])) { throw "$key missing" }
  }
}
Check "the arm64 clingo is pinned" {
  foreach ($key in @("CLINGO_WIN_ARM64_URL", "CLINGO_WIN_ARM64_SHA256")) {
    if ([string]::IsNullOrWhiteSpace($pins[$key])) { throw "$key missing" }
  }
}
# §7.1: CLINGO_VERSION is shared by both legs, so the arm64 asset must be a
# build of exactly that version. The producer encodes it in the release tag
# and in the asset name; ensure-clingo.ps1 refuses a mismatched name at
# install time, and this catches it before a host ever downloads.
Check "the arm64 clingo asset is a producer build of CLINGO_VERSION" {
  $version = [regex]::Escape($pins["CLINGO_VERSION"])
  $pattern = ('^https://github\.com/metacraft-labs/reprobuild/releases/download/' +
              'producer/clingo-windows-arm64/v' + $version + '-[1-9][0-9]*/' +
              'clingo-' + $version + '-windows-arm64-[0-9a-f]{12}\.zip$')
  if ($pins["CLINGO_WIN_ARM64_URL"] -notmatch $pattern) {
    throw "CLINGO_WIN_ARM64_URL '$($pins['CLINGO_WIN_ARM64_URL'])' does not match $pattern"
  }
}
Check "the arm64 Nim is pinned" {
  foreach ($key in @("NIM_WIN_ARM64_URL", "NIM_WIN_ARM64_SHA256")) {
    if ([string]::IsNullOrWhiteSpace($pins[$key])) { throw "$key missing" }
  }
}
# NIM_VERSION is shared by both legs (the two legs never differ), so the
# arm64 cold-start prefix must be the metacraft-labs/nim factory's build of
# exactly that version. ensure-nim.ps1 refuses a mismatched asset
# name at install time; this catches it before a host ever downloads. The
# factory's other prefix, the 2.2.10 vccexe build, is the engine's bootstrap
# Nim (packages/nim.nim) and must never land in these keys.
Check "the arm64 Nim asset is a factory prefix of NIM_VERSION" {
  $version = [regex]::Escape($pins["NIM_VERSION"])
  $pattern = ('^https://github\.com/metacraft-labs/nim/releases/download/' +
              'producer/nim-windows-arm64-prefixes/build-[1-9][0-9]*/' +
              'nim-' + $version + '-[0-9a-f]{12}-windows-arm64\.zip$')
  if ($pins["NIM_WIN_ARM64_URL"] -notmatch $pattern) {
    throw "NIM_WIN_ARM64_URL '$($pins['NIM_WIN_ARM64_URL'])' does not match $pattern"
  }
}

Write-Host "Get-ToolchainArchPin"
$table = @{
  OPENSSL_SHA256 = "x64-value"
  OPENSSL_WIN_ARM64_SHA256 = "arm64-value"
  ONLY_X64_SHA256 = "x64-only"
}
Check "x64 reads the unsuffixed key" {
  $v = Get-ToolchainArchPin -Toolchain $table -Arch x64 -X64Key OPENSSL_SHA256 -Arm64Key OPENSSL_WIN_ARM64_SHA256 -Consumer t
  if ($v -ne "x64-value") { throw "got '$v'" }
}
Check "arm64 reads the _WIN_ARM64 key" {
  $v = Get-ToolchainArchPin -Toolchain $table -Arch arm64 -X64Key OPENSSL_SHA256 -Arm64Key OPENSSL_WIN_ARM64_SHA256 -Consumer t
  if ($v -ne "arm64-value") { throw "got '$v'" }
}
Check "arm64 never falls back to the x64 key, and names the missing key" {
  Assert-Throws { Get-ToolchainArchPin -Toolchain $table -Arch arm64 -X64Key ONLY_X64_SHA256 -Arm64Key ONLY_WIN_ARM64_SHA256 -Consumer ensure-t } 'ensure-t: ONLY_WIN_ARM64_SHA256 is missing'
}
Check "an arm64 key without the _WIN_ARM64 form is a caller bug" {
  Assert-Throws { Get-ToolchainArchPin -Toolchain $table -Arch arm64 -X64Key OPENSSL_SHA256 -Arm64Key OPENSSL_ARM64_SHA256 -Consumer t } 'not an arm64 pin key'
}
Check "an unknown architecture is refused" {
  Assert-Throws { Get-ToolchainArchPin -Toolchain $table -Arch x86 -X64Key OPENSSL_SHA256 -Arm64Key OPENSSL_WIN_ARM64_SHA256 -Consumer t } "unsupported Windows architecture 'x86'"
}

Write-Host "Get-ToolchainPinConventionViolations (negative controls)"
Check "an arm64 variant of a shared version key is a violation" {
  $bad = @{ NIM_VERSION = "1"; CLINGO_VERSION = "1"; OPENSSL_VERSION = "1"; CLINGO_WIN_ARM64_VERSION = "2" }
  $v = Get-ToolchainPinConventionViolations -Toolchain $bad
  if (-not ($v -match 'CLINGO_WIN_ARM64_VERSION must not exist')) { throw "not reported: $($v -join '; ')" }
}
Check "a malformed sha256 is a violation" {
  $bad = @{ NIM_VERSION = "1"; CLINGO_VERSION = "1"; OPENSSL_VERSION = "1"; ZSTD_WIN_ARM64_SHA256 = "abc" }
  $v = Get-ToolchainPinConventionViolations -Toolchain $bad
  if (-not ($v -match 'ZSTD_WIN_ARM64_SHA256 is not a 64-digit hex sha256')) { throw "not reported: $($v -join '; ')" }
}
Check "an arm64 key in another spelling is a violation" {
  $bad = @{ NIM_VERSION = "1"; CLINGO_VERSION = "1"; OPENSSL_VERSION = "1"; ZSTD_ARM64_URL = "u" }
  $v = Get-ToolchainPinConventionViolations -Toolchain $bad
  if (-not ($v -match 'ZSTD_ARM64_URL names arm64')) { throw "not reported: $($v -join '; ')" }
}
Check "a missing shared version key is a violation" {
  $v = Get-ToolchainPinConventionViolations -Toolchain @{ CLINGO_VERSION = "1"; OPENSSL_VERSION = "1" }
  if (-not ($v -match 'NIM_VERSION is missing')) { throw "not reported: $($v -join '; ')" }
}

Write-Host "windows/release-os-dlls.txt"
Check "every allowlisted OS DLL has a name and a reason" {
  $os = Get-WindowsReleaseOsDlls
  if ($os.Count -lt 1) { throw "the allowlist is empty" }
  foreach ($k in $os.Keys) {
    if ($k -notmatch '^[A-Za-z0-9_]+\.dll$') { throw "not a DLL name: $k" }
    if ([string]::IsNullOrWhiteSpace($os[$k])) { throw "$k has no reason" }
  }
}
Check "no Visual C++ or other redistributable runtime is allowlisted" {
  foreach ($k in (Get-WindowsReleaseOsDlls).Keys) {
    if ($k -match '^(?i)(vcruntime|msvcp|concrt|vccorlib|vcomp|vcamp|mfc|ucrtbased|libgcc|libstdc|libwinpthread|libc\+\+|libunwind)') {
      throw "$k is a redistributable, not part of Windows"
    }
  }
}
Check "a line without a reason is refused" {
  $bad = Join-Path ([IO.Path]::GetTempPath()) ("os-dlls-" + [Guid]::NewGuid().ToString("N") + ".txt")
  Set-Content -LiteralPath $bad -Value @("# comment", "KERNEL32.dll") -Encoding ascii
  try {
    Assert-Throws { Get-WindowsReleaseOsDlls -Path $bad } 'KERNEL32\.dll has no reason'
  } finally {
    Remove-Item -LiteralPath $bad
  }
}

Write-Host "PE readers and the release closure audit (synthetic images, any host)"

function New-TestPeImage {
  ## Write a minimal PE32+ image: the DOS stub pointer, the COFF header for
  ## $Machine, an optional header with 16 data directories, and one section
  ## holding an import directory (data directory 1) for $Imports and a
  ## delay-load import directory (data directory 13) for $DelayImports.
  ## Layout per https://learn.microsoft.com/windows/win32/debug/pe-format
  ## ("Optional Header Data Directories", "The .idata Section", "Delay-Load
  ## Import Tables"). Delay descriptors use the RVA form (Attributes = 1)
  ## unless $DelayVaForm, which writes the old VA form (Attributes = 0).
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int]$Machine,
    [string[]]$Imports = @(),
    [string[]]$DelayImports = @(),
    [switch]$DelayVaForm
  )
  $imageBase = [uint64]0x140000000
  $sectionRva = 0x1000
  $sectionRaw = 0x200
  $importDir = 0
  $importSize = 20 * ($Imports.Count + 1)
  $delayDir = $importSize
  $delaySize = 32 * ($DelayImports.Count + 1)
  $namesAt = $delayDir + $delaySize
  $data = New-Object System.Collections.Generic.List[byte]
  $data.AddRange([byte[]]::new($namesAt))
  $nameRvas = @{}
  foreach ($n in @($Imports + $DelayImports)) {
    if ($nameRvas.ContainsKey($n)) { continue }
    $nameRvas[$n] = $sectionRva + $data.Count
    $data.AddRange([Text.Encoding]::ASCII.GetBytes($n))
    $data.Add(0)
  }
  $buf = $data.ToArray()
  for ($i = 0; $i -lt $Imports.Count; $i++) {
    [BitConverter]::GetBytes([uint32]$nameRvas[$Imports[$i]]).CopyTo($buf, $importDir + 20 * $i + 12)
  }
  for ($i = 0; $i -lt $DelayImports.Count; $i++) {
    $at = $delayDir + 32 * $i
    $rva = [uint32]$nameRvas[$DelayImports[$i]]
    if ($DelayVaForm) {
      [BitConverter]::GetBytes([uint32]0).CopyTo($buf, $at)
      # The VA form is 32 bits wide, so it can only name a 32-bit address.
      [BitConverter]::GetBytes([uint32]($rva + 0x400000)).CopyTo($buf, $at + 4)
    } else {
      [BitConverter]::GetBytes([uint32]1).CopyTo($buf, $at)
      [BitConverter]::GetBytes($rva).CopyTo($buf, $at + 4)
    }
  }
  $rawSize = [int]([Math]::Ceiling($buf.Length / 512.0) * 512)
  $file = [byte[]]::new($sectionRaw + $rawSize)
  $file[0] = 0x4d; $file[1] = 0x5a
  [BitConverter]::GetBytes([uint32]0x40).CopyTo($file, 0x3c)
  $pe = 0x40
  [BitConverter]::GetBytes([uint32]0x4550).CopyTo($file, $pe)
  [BitConverter]::GetBytes([uint16]$Machine).CopyTo($file, $pe + 4)
  [BitConverter]::GetBytes([uint16]1).CopyTo($file, $pe + 6)
  [BitConverter]::GetBytes([uint16]240).CopyTo($file, $pe + 20)
  [BitConverter]::GetBytes([uint16]0x22).CopyTo($file, $pe + 22)
  $opt = $pe + 24
  [BitConverter]::GetBytes([uint16]0x20b).CopyTo($file, $opt)
  $base = if ($DelayVaForm) { [uint64]0x400000 } else { $imageBase }
  [BitConverter]::GetBytes($base).CopyTo($file, $opt + 24)
  [BitConverter]::GetBytes([uint32]16).CopyTo($file, $opt + 108)
  $dirs = $opt + 112
  if ($Imports.Count -gt 0) {
    [BitConverter]::GetBytes([uint32]($sectionRva + $importDir)).CopyTo($file, $dirs + 8 * 1)
    [BitConverter]::GetBytes([uint32]$importSize).CopyTo($file, $dirs + 8 * 1 + 4)
  }
  if ($DelayImports.Count -gt 0) {
    [BitConverter]::GetBytes([uint32]($sectionRva + $delayDir)).CopyTo($file, $dirs + 8 * 13)
    [BitConverter]::GetBytes([uint32]$delaySize).CopyTo($file, $dirs + 8 * 13 + 4)
  }
  $sec = $opt + 240
  [Text.Encoding]::ASCII.GetBytes(".idata").CopyTo($file, $sec)
  [BitConverter]::GetBytes([uint32]$buf.Length).CopyTo($file, $sec + 8)
  [BitConverter]::GetBytes([uint32]$sectionRva).CopyTo($file, $sec + 12)
  [BitConverter]::GetBytes([uint32]$rawSize).CopyTo($file, $sec + 16)
  [BitConverter]::GetBytes([uint32]$sectionRaw).CopyTo($file, $sec + 20)
  $buf.CopyTo($file, $sectionRaw)
  [IO.File]::WriteAllBytes($Path, $file)
}

$arm64 = 0xAA64
$x64 = 0x8664
$synth = Join-Path ([IO.Path]::GetTempPath()) ("closure-synth-" + [Guid]::NewGuid().ToString("N"))
$synthSys = Join-Path $synth "system"
$synthBin = Join-Path $synth "bin"
New-Item -ItemType Directory -Path $synthSys, $synthBin | Out-Null
try {
  # The stand-in system directory holds the OS DLLs the fixtures import, all
  # on windows/release-os-dlls.txt, and one redistributable that is not: a
  # Visual C++ runtime DLL sits in System32 on any host that installed the
  # VC++ redistributable or Visual Studio, but Windows does not ship it.
  foreach ($n in @("KERNEL32.dll", "ADVAPI32.dll", "USER32.dll", "vcruntime140.dll")) {
    New-TestPeImage -Path (Join-Path $synthSys $n) -Machine $arm64
  }
  $tool = Join-Path $synth "tool.exe"
  New-TestPeImage -Path $tool -Machine $arm64 -Imports @("KERNEL32.dll", "libfoo.dll") -DelayImports @("USER32.dll", "libbar.dll")
  Check "the import directory is read" {
    $names = @(Get-PeImportNames -Path $tool)
    if (($names -join ",") -ne "KERNEL32.dll,libfoo.dll") { throw "got '$($names -join ",")'" }
  }
  Check "the delay-load import directory is read" {
    $names = @(Get-PeDelayImportNames -Path $tool)
    if (($names -join ",") -ne "USER32.dll,libbar.dll") { throw "got '$($names -join ",")'" }
  }
  Check "a delay-load descriptor in the old VA form is read" {
    $old = Join-Path $synth "old.exe"
    New-TestPeImage -Path $old -Machine $arm64 -DelayImports @("libold.dll") -DelayVaForm
    $names = @(Get-PeDelayImportNames -Path $old)
    if (($names -join ",") -ne "libold.dll") { throw "got '$($names -join ",")'" }
  }
  Check "an image without a delay-load directory has no delay imports" {
    $plain = Join-Path $synth "plain.exe"
    New-TestPeImage -Path $plain -Machine $arm64 -Imports @("KERNEL32.dll")
    $names = @(Get-PeDelayImportNames -Path $plain)
    if ($names.Count -ne 0) { throw "got '$($names -join ",")'" }
  }

  Copy-Item -LiteralPath $tool -Destination (Join-Path $synthBin "tool.exe")
  New-TestPeImage -Path (Join-Path $synthBin "libfoo.dll") -Machine $arm64 -Imports @("KERNEL32.dll", "api-ms-win-crt-runtime-l1-1-0.dll")
  Check "a delay-loaded DLL the bin/ does not carry fails the audit" {
    Assert-Throws { Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys } `
      'tool\.exe delay-loads libbar\.dll, which is neither in bin/ nor an operating-system DLL'
  }
  New-TestPeImage -Path (Join-Path $synthBin "libbar.dll") -Machine $arm64 -Imports @("ADVAPI32.dll")
  Check "a closed bin/ passes the audit, delay-loads included" {
    Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys
  }
  Check "a DLL in bin/ is itself audited: its own missing import fails" {
    New-TestPeImage -Path (Join-Path $synthBin "libbar.dll") -Machine $arm64 -Imports @("libbaz.dll")
    try {
      Assert-Throws { Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys } `
        'libbar\.dll imports libbaz\.dll, which is neither in bin/ nor an operating-system DLL'
    } finally {
      New-TestPeImage -Path (Join-Path $synthBin "libbar.dll") -Machine $arm64 -Imports @("ADVAPI32.dll")
    }
  }
  Check "an x64 DLL staged in an arm64 bin/ fails the audit" {
    New-TestPeImage -Path (Join-Path $synthBin "libfoo.dll") -Machine $x64 -Imports @("KERNEL32.dll")
    try {
      Assert-Throws { Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys } `
        'libfoo\.dll is a PE image for machine 0x8664, not the arm64 machine 0xAA64'
    } finally {
      New-TestPeImage -Path (Join-Path $synthBin "libfoo.dll") -Machine $arm64 -Imports @("KERNEL32.dll")
    }
  }

  Check "a redistributable in System32 is not an operating-system DLL: it fails the audit" {
    $vc = Join-Path $synthBin "uses-vcrt.dll"
    New-TestPeImage -Path $vc -Machine $arm64 -Imports @("KERNEL32.dll", "vcruntime140.dll")
    try {
      Assert-Throws { Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys } `
        'uses-vcrt\.dll imports vcruntime140\.dll, which the system directory holds but which is not a Windows component on windows/release-os-dlls\.txt'
    } finally {
      Remove-Item -LiteralPath $vc
    }
  }
  Check "an allowlisted OS DLL missing from the system directory fails the audit" {
    $ws = Join-Path $synthBin "uses-ws2.dll"
    New-TestPeImage -Path $ws -Machine $arm64 -Imports @("WS2_32.dll")
    try {
      Assert-Throws { Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys } `
        'uses-ws2\.dll imports WS2_32\.dll, which is neither in bin/ nor an operating-system DLL'
    } finally {
      Remove-Item -LiteralPath $ws
    }
  }
  Check "an operating-system DLL is matched by name without regard to case" {
    $lc = Join-Path $synthBin "lowercase.dll"
    New-TestPeImage -Path $lc -Machine $arm64 -Imports @("kernel32.dll")
    try {
      Assert-WindowsDllClosure -BinDir $synthBin -Arch arm64 -SystemDir $synthSys `
        -OsDlls @("KERNEL32.dll", "ADVAPI32.dll", "USER32.dll")
    } finally {
      Remove-Item -LiteralPath $lc
    }
  }

  # The entry point verify_release.sh runs over an extracted archive. It runs
  # in a child process, as the release runs it, and answers by exit code.
  $auditScript = Join-Path $windowsDir "audit-release-dll-closure.ps1"
  $shell = (Get-Process -Id $PID).Path
  function Invoke-AuditScript {
    ## Run the entry point in a child shell; return its output as strings.
    ## The child reports a refusal on stderr. Windows PowerShell 5.1 turns
    ## each redirected stderr line into an error record, which this file's
    ## "Stop" preference would raise before the exit code could be checked.
    param([string]$Bin)
    $ErrorActionPreference = "Continue"
    $out = & $shell -NoProfile -NonInteractive -File $auditScript -BinDir $Bin -Arch arm64 -SystemDir $synthSys 2>&1
    return @($out | ForEach-Object { "$_" })
  }
  Check "the archive audit entry point accepts a closed bin/" {
    $out = Invoke-AuditScript -Bin $synthBin
    if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE`n$($out -join "`n")" }
    if (-not (($out -join "`n") -match 'closure audit: 3 image\(s\)')) { throw "no audit summary in:`n$($out -join "`n")" }
  }
  Check "the archive audit entry point refuses an open bin/ with exit 1" {
    Remove-Item -LiteralPath (Join-Path $synthBin "libbar.dll")
    $out = Invoke-AuditScript -Bin $synthBin
    if ($LASTEXITCODE -ne 1) { throw "exit $LASTEXITCODE, expected 1`n$($out -join "`n")" }
    if (-not (($out -join "`n") -match 'delay-loads libbar\.dll')) { throw "violation not named in:`n$($out -join "`n")" }
  }
  Check "the archive audit entry point refuses a bin/ with no images" {
    $empty = Join-Path $synth "empty"
    New-Item -ItemType Directory -Path $empty | Out-Null
    $out = Invoke-AuditScript -Bin $empty
    if ($LASTEXITCODE -ne 1) { throw "exit $LASTEXITCODE, expected 1`n$($out -join "`n")" }
  }

  # The archive audit: every PE image anywhere in an extracted archive, not
  # only bin/. Images outside bin/ (lib/ today) resolve their imports from
  # bin/ or from Windows, like bin/'s own.
  $pkg = Join-Path $synth "pkg"
  $pkgBin = Join-Path $pkg "bin"
  $pkgLib = Join-Path $pkg "lib"
  $pkgShare = Join-Path $pkg "share"
  New-Item -ItemType Directory -Path $pkgBin, $pkgLib, $pkgShare | Out-Null
  New-TestPeImage -Path (Join-Path $pkgBin "repro.exe") -Machine $arm64 -Imports @("KERNEL32.dll", "libfoo.dll")
  New-TestPeImage -Path (Join-Path $pkgBin "libfoo.dll") -Machine $arm64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $pkgLib "shim.dll") -Machine $arm64 -Imports @("KERNEL32.dll", "libfoo.dll") -DelayImports @("ADVAPI32.dll")
  Set-Content -LiteralPath (Join-Path $pkgShare "notes.txt") -Value "not an image" -Encoding ascii
  Check "a closed archive passes the archive audit, lib/ included" {
    Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys
  }
  Check "a lib/ image with a non-system import fails the archive audit" {
    $bad = Join-Path $pkgLib "bad.dll"
    New-TestPeImage -Path $bad -Machine $arm64 -Imports @("KERNEL32.dll", "libmissing.dll")
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'lib/bad\.dll imports libmissing\.dll, which is neither in bin/ nor an operating-system DLL'
    } finally { Remove-Item -LiteralPath $bad }
  }
  Check "a lib/ image importing a DLL that only lib/ holds fails: imports resolve to bin/ or Windows" {
    $helper = Join-Path $pkgLib "libhelper.dll"
    $user = Join-Path $pkgLib "user.dll"
    New-TestPeImage -Path $helper -Machine $arm64 -Imports @("KERNEL32.dll")
    New-TestPeImage -Path $user -Machine $arm64 -Imports @("libhelper.dll")
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'lib/user\.dll imports libhelper\.dll, which is neither in bin/ nor an operating-system DLL'
    } finally { Remove-Item -LiteralPath $helper, $user }
  }
  Check "a lib/ image with a wrong-machine import fails the archive audit" {
    $x64Dll = Join-Path $pkgBin "libx64.dll"
    $user = Join-Path $pkgLib "uses-x64.dll"
    New-TestPeImage -Path $x64Dll -Machine $x64 -Imports @("KERNEL32.dll")
    New-TestPeImage -Path $user -Machine $arm64 -Imports @("libx64.dll")
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'lib/uses-x64\.dll imports libx64\.dll, which is an image for machine 0x8664, not the arm64 machine 0xAA64'
    } finally { Remove-Item -LiteralPath $x64Dll, $user }
  }
  Check "a lib/ image of the wrong machine fails the archive audit" {
    $wrong = Join-Path $pkgLib "wrong.dll"
    New-TestPeImage -Path $wrong -Machine $x64 -Imports @("KERNEL32.dll")
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'lib.wrong\.dll is a PE image for machine 0x8664, not the arm64 machine 0xAA64'
    } finally { Remove-Item -LiteralPath $wrong }
  }
  Check "an image in any other directory is audited too" {
    $other = Join-Path $pkg "libexec"
    New-Item -ItemType Directory -Path $other | Out-Null
    New-TestPeImage -Path (Join-Path $other "tool.exe") -Machine $arm64 -Imports @("libnowhere.dll")
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'libexec/tool\.exe imports libnowhere\.dll'
    } finally { Remove-Item -LiteralPath $other -Recurse }
  }
  Check "a file that starts like an image but is not a well-formed PE fails the archive audit" {
    $fake = Join-Path $pkgShare "looks-like.bin"
    [IO.File]::WriteAllBytes($fake, [byte[]](0x4d, 0x5a) + [byte[]]::new(126))
    try {
      Assert-Throws { Assert-WindowsArchiveClosure -Root $pkg -Arch arm64 -SystemDir $synthSys } `
        'share/looks-like\.bin starts with MZ but is not a readable PE image'
    } finally { Remove-Item -LiteralPath $fake }
  }
  Check "an archive with no image in bin/ fails the archive audit" {
    $nobin = Join-Path $synth "nobin"
    New-Item -ItemType Directory -Path (Join-Path $nobin "lib") | Out-Null
    New-TestPeImage -Path (Join-Path (Join-Path $nobin "lib") "shim.dll") -Machine $arm64 -Imports @("KERNEL32.dll")
    Assert-Throws { Assert-WindowsArchiveClosure -Root $nobin -Arch arm64 -SystemDir $synthSys } 'no \.exe or \.dll image in bin'
  }
  Check "the archive audit entry point audits -ArchiveRoot and refuses a lib/ violation with exit 1" {
    $ErrorActionPreference = "Continue"
    $out = @(& $shell -NoProfile -NonInteractive -File $auditScript -ArchiveRoot $pkg -Arch arm64 -SystemDir $synthSys 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "closed archive: exit $LASTEXITCODE`n$($out -join "`n")" }
    if (-not (($out -join "`n") -match 'closure audit: 3 image\(s\) in')) { throw "no 3-image summary in:`n$($out -join "`n")" }
    $bad = Join-Path $pkgLib "bad.dll"
    New-TestPeImage -Path $bad -Machine $arm64 -Imports @("libmissing.dll")
    try {
      $out = @(& $shell -NoProfile -NonInteractive -File $auditScript -ArchiveRoot $pkg -Arch arm64 -SystemDir $synthSys 2>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -ne 1) { throw "open archive: exit $LASTEXITCODE, expected 1`n$($out -join "`n")" }
      if (-not (($out -join "`n") -match 'lib/bad\.dll imports libmissing\.dll')) { throw "violation not named in:`n$($out -join "`n")" }
    } finally { Remove-Item -LiteralPath $bad }
  }

  # Copy-WindowsImportClosure: x64 staging copies only what the import walk
  # finds, from the pinned sources, instead of a best-effort list.
  $ic = Join-Path $synth "importclosure"
  $icBin = Join-Path $ic "bin"
  $icVc = Join-Path $ic "vc"
  $icGcc = Join-Path $ic "gcc"
  New-Item -ItemType Directory -Path $icBin, $icVc, $icGcc | Out-Null
  $icSys = Join-Path $ic "system"
  New-Item -ItemType Directory -Path $icSys | Out-Null
  foreach ($n in @("KERNEL32.dll", "vcruntime140.dll")) { New-TestPeImage -Path (Join-Path $icSys $n) -Machine $x64 }
  # Sources: the VC++ runtime package and the compiler's bin/.
  New-TestPeImage -Path (Join-Path $icVc "vcruntime140.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $icVc "msvcp140.dll") -Machine $x64 -Imports @("vcruntime140.dll")
  New-TestPeImage -Path (Join-Path $icVc "concrt140.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $icGcc "libgcc_s_seh-1.dll") -Machine $x64 -Imports @("KERNEL32.dll", "libwinpthread-1.dll")
  New-TestPeImage -Path (Join-Path $icGcc "libwinpthread-1.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $icGcc "libstdc++-6.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $icGcc "libzstd.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  New-TestPeImage -Path (Join-Path $icGcc "KERNEL32.dll") -Machine $x64
  # bin/: clingo imports the C++ runtime, libcrypto delay-loads libgcc_s.
  New-TestPeImage -Path (Join-Path $icBin "clingo.dll") -Machine $x64 -Imports @("KERNEL32.dll", "msvcp140.dll")
  New-TestPeImage -Path (Join-Path $icBin "libcrypto-3-x64.dll") -Machine $x64 -Imports @("KERNEL32.dll") -DelayImports @("libgcc_s_seh-1.dll")
  New-TestPeImage -Path (Join-Path $icBin "libzstd.dll") -Machine $x64 -Imports @("KERNEL32.dll")
  # A stale copy from an earlier build: in a source, imported by nothing.
  Copy-Item -LiteralPath (Join-Path $icGcc "libstdc++-6.dll") -Destination (Join-Path $icBin "libstdc++-6.dll")
  $icArgs = @{ BinDir = $icBin; SourceDirs = @($icVc, $icGcc); Arch = "x64"; SystemDir = $icSys; OsDlls = @("KERNEL32.dll"); KeepNames = @("libzstd.dll") }
  Check "the import walk stages exactly the imported closure, transitively and through delay-loads" {
    $copied = @(Copy-WindowsImportClosure @icArgs)
    $want = @("libgcc_s_seh-1.dll", "libwinpthread-1.dll", "msvcp140.dll", "vcruntime140.dll")
    if ((($copied | Sort-Object) -join ",") -ne ($want -join ",")) { throw "copied '$(($copied | Sort-Object) -join ",")'" }
    $have = @(Get-ChildItem -LiteralPath $icBin -File | ForEach-Object Name | Sort-Object)
    $wantBin = @("clingo.dll", "libcrypto-3-x64.dll", "libgcc_s_seh-1.dll", "libwinpthread-1.dll", "libzstd.dll", "msvcp140.dll", "vcruntime140.dll")
    if (($have -join ",") -ne ($wantBin -join ",")) { throw "bin/ holds '$($have -join ",")'" }
  }
  Check "a redistributable in System32 is staged from its source, not taken as Windows" {
    if (-not (Test-Path -LiteralPath (Join-Path $icBin "vcruntime140.dll"))) { throw "vcruntime140.dll was not staged" }
  }
  Check "an unimported DLL from a source is not staged, and a stale copy is removed" {
    foreach ($n in @("concrt140.dll", "libstdc++-6.dll")) {
      if (Test-Path -LiteralPath (Join-Path $icBin $n)) { throw "$n is in bin/" }
    }
  }
  Check "an operating-system DLL is never staged, even when a source holds one" {
    if (Test-Path -LiteralPath (Join-Path $icBin "KERNEL32.dll")) { throw "KERNEL32.dll was staged" }
  }
  Check "a name staged on purpose (KeepNames) is not removed as stale" {
    if (-not (Test-Path -LiteralPath (Join-Path $icBin "libzstd.dll"))) { throw "libzstd.dll was removed" }
  }
  Check "the staged bin/ passes the closure audit" {
    Assert-WindowsDllClosure -BinDir $icBin -Arch x64 -SystemDir $icSys -OsDlls @("KERNEL32.dll")
  }
  Check "an import that no source holds is refused, by name" {
    $u = Join-Path $icBin "needs-missing.dll"
    New-TestPeImage -Path $u -Machine $x64 -Imports @("libnowhere.dll")
    try {
      Assert-Throws { Copy-WindowsImportClosure @icArgs } 'needs-missing\.dll imports libnowhere\.dll, which no source holds'
    } finally { Remove-Item -LiteralPath $u }
  }
  Check "a source DLL of the wrong machine is refused" {
    $w = Join-Path $icBin "needs-arm.dll"
    New-TestPeImage -Path (Join-Path $icGcc "libarm.dll") -Machine $arm64
    New-TestPeImage -Path $w -Machine $x64 -Imports @("libarm.dll")
    try {
      Assert-Throws { Copy-WindowsImportClosure @icArgs } 'libarm\.dll is a PE image for machine 0xAA64, not the x64 machine 0x8664'
    } finally { Remove-Item -LiteralPath $w, (Join-Path $icGcc "libarm.dll") -ErrorAction SilentlyContinue }
  }
  Check "an image that ships from lib/ has its imports staged into bin/" {
    $l = Join-Path $ic "lib"
    New-Item -ItemType Directory -Path $l | Out-Null
    # As librepro_project_dsl_runtime.dll does on x64: it imports libgcc_s,
    # which nothing in bin/ imports, and it reaches the archive at packaging.
    New-TestPeImage -Path (Join-Path $l "librepro_project_dsl_runtime.dll") -Machine $x64 -Imports @("KERNEL32.dll", "libgcc_s_seh-1.dll")
    $lb = Join-Path $ic "libbin"
    New-Item -ItemType Directory -Path $lb | Out-Null
    New-TestPeImage -Path (Join-Path $lb "repro.exe") -Machine $x64 -Imports @("KERNEL32.dll")
    try {
      $copied = @(Copy-WindowsImportClosure -BinDir $lb -SourceDirs @($icVc, $icGcc) -Arch x64 -SystemDir $icSys -OsDlls @("KERNEL32.dll") -ExtraImageDirs @($l))
      if ((($copied | Sort-Object) -join ",") -ne "libgcc_s_seh-1.dll,libwinpthread-1.dll") { throw "copied '$(($copied | Sort-Object) -join ",")'" }
      if (Test-Path -LiteralPath (Join-Path $l "libgcc_s_seh-1.dll")) { throw "staged into lib/ instead of bin/" }
    } finally { Remove-Item -LiteralPath $l, $lb -Recurse }
  }
  Check "the first source that holds a DLL wins" {
    $both = Join-Path $ic "both"
    New-Item -ItemType Directory -Path $both | Out-Null
    $b = Join-Path $both "bin"; $s1 = Join-Path $both "s1"; $s2 = Join-Path $both "s2"
    New-Item -ItemType Directory -Path $b, $s1, $s2 | Out-Null
    New-TestPeImage -Path (Join-Path $s1 "libdup.dll") -Machine $x64 -Imports @("KERNEL32.dll")
    New-TestPeImage -Path (Join-Path $s2 "libdup.dll") -Machine $x64 -Imports @("KERNEL32.dll", "libextra.dll")
    New-TestPeImage -Path (Join-Path $b "user.exe") -Machine $x64 -Imports @("libdup.dll")
    $copied = @(Copy-WindowsImportClosure -BinDir $b -SourceDirs @($s1, $s2) -Arch x64 -SystemDir $icSys -OsDlls @("KERNEL32.dll"))
    if (($copied -join ",") -ne "libdup.dll") { throw "copied '$($copied -join ",")' (s2's copy would also need libextra.dll)" }
  }
} finally {
  Remove-Item -LiteralPath $synth -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PE readers and the release closure audit"
$onWindows =[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($onWindows) {
  # Real images: the host's own cmd.exe, which imports only system DLLs.
  $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
  $hostArch = Get-WindowsArch
  Check "a system image is this host's machine" {
    Assert-PeMachine -Path $cmdExe -Arch $hostArch -Consumer t
  }
  $cmdImports = @(Get-PeImportNames -Path $cmdExe)
  $cmdOsDlls = @($cmdImports) + @(Get-PeDelayImportNames -Path $cmdExe)
  Check "a system image's imports are read, one name each" {
    if ($cmdImports.Count -lt 2) { throw "expected several imports, got $($cmdImports.Count)" }
    foreach ($name in $cmdImports) {
      if ($name -isnot [string] -or $name -notmatch '^[A-Za-z0-9_.-]+\.dll$') { throw "not a DLL name: $name" }
    }
  }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ("closure-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $dir | Out-Null
  try {
    Copy-Item -LiteralPath $cmdExe -Destination (Join-Path $dir "ok.exe")
    Check "a bin/ of system-only imports passes the closure audit" {
      # cmd.exe is a Windows image, so what it imports and delay-loads is an OS
      # DLL by construction; that stands in for the allowlist, which names only
      # what reprobuild uses.
      Assert-WindowsDllClosure -BinDir $dir -Arch $hostArch -OsDlls $cmdOsDlls
    }
    # Negative control: the same image with one import renamed to a DLL that
    # exists nowhere. Same length, so the PE stays well formed.
    # Rename cmd.exe's first import, in place and to the same length, to a
    # DLL that exists nowhere (Q...Q.dll).
    $victim = $cmdImports[0]
    $fakeName = ('Q' * ($victim.Length - 4)) + '.dll'
    $bytes = [IO.File]::ReadAllBytes($cmdExe)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $at = $text.IndexOf($victim + [char]0, [StringComparison]::Ordinal)
    Check "the negative control found the import name to rename" {
      if ($at -lt 0) { throw "$victim not found in $cmdExe" }
    }
    if ($at -ge 0) {
      $fake = [Text.Encoding]::ASCII.GetBytes($fakeName)
      [Array]::Copy($fake, 0, $bytes, $at, $fake.Length)
      [IO.File]::WriteAllBytes((Join-Path $dir "bad.exe"), $bytes)
      Check "an import that is neither in bin/ nor in System32 fails the audit" {
        Assert-Throws { Assert-WindowsDllClosure -BinDir $dir -Arch $hostArch -OsDlls $cmdOsDlls } ("bad\.exe imports " + [regex]::Escape($fakeName))
      }
    }
    Check "an image of another machine fails the audit" {
      $other = if ($hostArch -eq "arm64") { "x64" } else { "arm64" }
      Assert-Throws { Assert-WindowsDllClosure -BinDir $dir -Arch $other -OsDlls $cmdOsDlls } 'not the .* machine'
    }
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
} else {
  Write-Host "  (PE checks run on Windows only)"
}

if ($failures.Count -ne 0) {
  throw "test-toolchain-arch-pins: $($failures.Count) failure(s):`n  " + ($failures -join "`n  ")
}
Write-Host "test-toolchain-arch-pins: all checks passed"
# The audit entry-point checks leave $LASTEXITCODE at 1 (a refusal they
# expected). Windows PowerShell 5.1 reports a -File script's last native exit
# code as its own, so without this a passing run would exit 1.
exit 0
