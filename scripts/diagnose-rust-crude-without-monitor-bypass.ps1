#requires -Version 5
# M11 diagnostic: re-run the M6 Rust crude E2E build (binary-with-build-rs)
# with REPRO_MONITOR_BYPASS unset, to confirm whether cargo's
# std::process::Command panic with `AlreadyExists (os error 183)` still
# reproduces against current reprobuild/main.
#
# Background:
#
#   The M6 e2e gate (scripts/validate-standard-provider-rust-crude.ps1)
#   sets REPRO_MONITOR_BYPASS=1 to work around a cargo-on-Windows panic
#   that surfaces when reprobuild's monitor shim (libs/repro_monitor_shim,
#   own windows_iat_patcher.nim) is loaded into cargo's process. cargo's
#   `std::process::Command::spawn` panics with `AlreadyExists (os error
#   183)` — ERROR_ALREADY_EXISTS — which is the Win32 error returned by
#   `CreateProcess` when a duplicate-handle / job-object / mapping name
#   collides.
#
#   ct_interpose has since landed deeper Windows hooking primitives that
#   reprobuild's shim doesn't yet consume:
#
#     * M49-Corpus #1 — ordinal-aware IAT patcher (catches bare-ordinal
#       imports that the current name-only loop skips). Lives in
#       ct_gfx_capture_autohook.c, NOT iat_patcher.nim — so this fix is
#       NOT directly applicable to reprobuild's IAT path until the
#       ct_interpose Nim patcher catches up.
#     * M50.2 — Windows inline-hook install/uninstall API
#       (ct_inline_hook/install_windows.{c,h}). Allows hooking at the
#       function-body level via a 5-byte JMP rel32 prologue patch, which
#       is invisible to IAT-cache consumers like the .NET CLR.
#     * M50.4 — 20 NTDLL syscall stubs inline-detoured at the canonical
#       OS boundary (NtCreateFile / NtReadFile / NtWriteFile / NtClose /
#       NtCreateThreadEx / etc). This is structurally cleaner than IAT
#       patching: a single inline detour catches every caller, including
#       direct-NTDLL callers that bypass kernel32 entirely.
#     * M50.5 — LdrLoadDll + CLR-safe GetProcAddress inline detours.
#       Closes the "newly-loaded module has unpatched IAT" gap and
#       avoids the IAT-cache invalidation hazard that Approach 1 +
#       Approach 2 both hit on the .NET CLR.
#     * hook_registry (ct_interpose/src/ct_interpose/hook_registry.nim) —
#       stackable hook chain with priority ordering. Multiple consumers
#       (recorder + monitor shim) can co-exist on the same Win32 API.
#
# This script:
#
#   1. Sources env.ps1 (managed nim/gcc on PATH).
#   2. Wipes any prior .repro/build and target/ from the fixture.
#   3. Invokes repro.exe build on the same fixture as the M6 gate but
#      explicitly UNSETS REPRO_MONITOR_BYPASS so FS-snoop is active.
#   4. Captures stdout + stderr to build/diagnose-rust-crude-no-bypass.*.
#   5. Reports exit code + a short summary of any cargo panic markers
#      found in the stderr stream.
#
# This is a M11 diagnostic ARTIFACT — committed alongside the audit
# note at reprobuild-specs/Notes/m11-fs-snoop-audit.md. It is NOT a
# verification gate (its exit code does not gate CI), it is a probe
# that the audit can re-run when ct_interpose / the IAT patcher land
# further fixes.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\binary-with-build-rs'
$scratchInsideFixture = Join-Path $fixture '.repro'
$cargoTargetDir = Join-Path $fixture 'target'

# --- ensure rustc + cargo are available somewhere ---
$rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
$cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $rustcCmd -or -not $cargoCmd) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    Write-Host "rustc/cargo not on PATH; falling back to rustup stable at $rustupStableBin"
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
  }
}
if (-not $rustcCmd -or -not $cargoCmd) {
  Write-Host "SKIP: rustc/cargo not available — the diagnostic needs both on PATH."
  exit 0
}
Write-Host "rustc = $((Get-Command rustc).Source)"
Write-Host "cargo = $((Get-Command cargo).Source)"

if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $cargoTargetDir) {
  Write-Host "wiping prior cargo target dir $cargoTargetDir"
  Remove-Item -LiteralPath $cargoTargetDir -Recurse -Force
}

# --- step 2: invoke `repro build` with REPRO_MONITOR_BYPASS UNSET ---
if (Test-Path Env:REPRO_MONITOR_BYPASS) {
  Write-Host "diagnostic: clearing pre-existing REPRO_MONITOR_BYPASS=$($env:REPRO_MONITOR_BYPASS)"
  Remove-Item Env:REPRO_MONITOR_BYPASS
}

# Diagnostic env: ask the monitor shim to log to a fixed path so we can
# see whether it actually loaded into cargo's child processes (separate
# from cargo's own panic — the shim may load fine but cargo's panic
# upstream of any specific hook).
$shimDebugLog = Join-Path $repoRoot 'build\diagnose-rust-crude-no-bypass.shim-debug.log'
if (Test-Path -LiteralPath $shimDebugLog) { Remove-Item -LiteralPath $shimDebugLog -Force }
$env:REPRO_MONITOR_SHIM_DEBUG_LOG = $shimDebugLog

$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\diagnose-rust-crude-no-bypass.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\diagnose-rust-crude-no-bypass.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $stdoutCapture) | Out-Null

Write-Host "==> launching repro.exe build $reproTarget (REPRO_MONITOR_BYPASS UNSET)"
$proc = Start-Process -FilePath $reproExe -ArgumentList @(
    'build', $reproTarget,
    '--tool-provisioning=path',
    '--log=actions'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutCapture `
  -RedirectStandardError  $stderrCapture
$exitCode = $proc.ExitCode

Write-Host "--- repro exit code: $exitCode"
if (Test-Path $stdoutCapture) {
  Write-Host "--- repro stdout (last 30 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 30 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  Write-Host "--- repro stderr (last 30 lines):"
  Get-Content -LiteralPath $stderrCapture -Tail 30 | ForEach-Object { Write-Host $_ }
}
if (Test-Path -LiteralPath $shimDebugLog) {
  Write-Host "--- shim debug log (last 30 lines):"
  Get-Content -LiteralPath $shimDebugLog -Tail 30 | ForEach-Object { Write-Host $_ }
}

# --- step 3: classify outcome ---
$stderrText = if (Test-Path $stderrCapture) { Get-Content -LiteralPath $stderrCapture -Raw } else { '' }
# Cargo formats the error as either `Os { code: 183, kind: AlreadyExists, ... }`
# (Rust 1.85+) or the older `AlreadyExists (os error 183)` form. Match both.
$panicOs183  = ($stderrText -match 'code:\s*183.*AlreadyExists') -or
               ($stderrText -match 'AlreadyExists.*code:\s*183') -or
               ($stderrText -match 'AlreadyExists.*os error 183')
$panicGeneric = $stderrText -match 'thread .* panicked'

Write-Host ""
Write-Host "=== DIAGNOSTIC SUMMARY ==="
Write-Host "exit code           : $exitCode"
Write-Host "cargo os-error-183  : $panicOs183"
Write-Host "any cargo panic     : $panicGeneric"
Write-Host "stderr capture      : $stderrCapture"
Write-Host "stdout capture      : $stdoutCapture"
Write-Host "shim debug log      : $shimDebugLog"
Write-Host "=========================="

if ($exitCode -eq 0) {
  Write-Host "OUTCOME: build SUCCEEDED with the bypass unset — the M6 workaround can be dropped."
  exit 0
} elseif ($panicOs183) {
  Write-Host "OUTCOME: build FAILED with the original os-error-183 panic still reproducing."
  Write-Host "         The IAT patcher still interferes with cargo's process spawn."
  exit 2
} else {
  Write-Host "OUTCOME: build FAILED with a different failure than the M6 report."
  Write-Host "         Inspect the captures to determine the new failure mode."
  exit 3
}
