Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# test-toolchain-arch-pins.ps1 -- the per-architecture pin conventions of
# windows/toolchain-versions.env (reprobuild-pm Distribution-And-Packaging.md
# §7.1, "windows/toolchain-versions.env conventions").
#
# Pure logic over the real pin file and in-memory tables: no download, no
# install, no host state, so it runs on any PowerShell 5.1+ or 7 host,
# including Linux pwsh. No mocks.

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

Write-Host "PE readers and the release closure audit"
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if ($onWindows) {
  # Real images: the host's own cmd.exe, which imports only system DLLs.
  $cmdExe = Join-Path $env:SystemRoot "System32\cmd.exe"
  $hostArch = Get-WindowsArch
  Check "a system image is this host's machine" {
    Assert-PeMachine -Path $cmdExe -Arch $hostArch -Consumer t
  }
  $cmdImports = @(Get-PeImportNames -Path $cmdExe)
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
      Assert-WindowsDllClosure -BinDir $dir -Arch $hostArch
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
        Assert-Throws { Assert-WindowsDllClosure -BinDir $dir -Arch $hostArch } ("bad\.exe imports " + [regex]::Escape($fakeName))
      }
    }
    Check "an image of another machine fails the audit" {
      $other = if ($hostArch -eq "arm64") { "x64" } else { "arm64" }
      Assert-Throws { Assert-WindowsDllClosure -BinDir $dir -Arch $other } 'not the .* machine'
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
