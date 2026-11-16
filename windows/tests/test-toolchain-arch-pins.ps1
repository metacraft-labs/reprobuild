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

if ($failures.Count -ne 0) {
  throw "test-toolchain-arch-pins: $($failures.Count) failure(s):`n  " + ($failures -join "`n  ")
}
Write-Host "test-toolchain-arch-pins: all checks passed"
