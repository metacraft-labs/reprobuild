# reprobuild Windows DIY dev environment (PowerShell).
#
# Usage:
#     . .\env.ps1
#
# The Linux/macOS dev shell comes from `.envrc` (`use flake`) -- this
# script is the equivalent on Windows, providing the toolchain
# `bash scripts/build_apps.sh` and `just test` need:
#
#   * Nim 2.2.x + a working C compiler (gcc/clang/cl)         -- via
#     ../repo-workspaces/env.ps1 (Ensure-Nim + Ensure-Gcc).
#   * just + gh + python + gpg + git-repo                     -- same.
#   * Sibling repos checked out alongside `reprobuild/`:
#       - codetracer/                  (libs/nim-stew, libs/nim-faststreams,
#                                       libs/nim-serialization, libs/nimcrypto
#                                       submodules under it)
#       - runquota/                    (Nim libs under libs/runquota_*)
#       - codetracer-native-recorder/  (ct_interpose/src for the monitor shim)
#
#   Once the sibling layout is satisfied, `config.nims` resolves every
#   third-party package without touching `nimble install`.
#
# Knobs (shared with repo-workspaces/env.ps1):
#   $env:WINDOWS_DIY_SYNC = "0"            skip all toolchain downloads
#   $env:WINDOWS_DIY_SKIP_NIM = "1"        skip the nim step
#   $env:WINDOWS_DIY_SKIP_GCC = "1"        skip the gcc step
#   $env:WINDOWS_DIY_SKIP_JUST = "1"       skip the just step
#   $env:WINDOWS_DIY_SKIP_GH = "1"         skip the gh step
#   $env:WINDOWS_DIY_SKIP_PYTHON = "1"     skip the python step
#   $env:WINDOWS_DIY_SKIP_REPO = "1"       skip the git-repo step
#   $env:WINDOWS_DIY_SKIP_GPG = "1"        skip the gpg step
#   $env:WINDOWS_DIY_INSTALL_ROOT = <dir>  where toolchains land
#
# Knobs specific to reprobuild:
#   $env:CT_INTERPOSE_SRC = <path>  override `../codetracer-native-recorder/ct_interpose/src`.
#   $env:RUNQUOTA_SRC     = <path>  override `../runquota`.
#   $env:NIMCRYPTO_SRC    = <path>  override `../codetracer/libs/nimcrypto`.
#   $env:NIM_STEW_SRC     = <path>  override `../codetracer/libs/nim-stew`.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- 1. Shared repo-workspaces bootstrap -------------------------------------
$repoWorkspacesEnv = Join-Path (Split-Path -Parent $scriptDir) "repo-workspaces\env.ps1"
if (-not (Test-Path $repoWorkspacesEnv)) {
    throw "reprobuild env.ps1: cannot find $repoWorkspacesEnv -- check out the repo-workspaces framework as a sibling of this repo."
}
. $repoWorkspacesEnv -Quiet

# --- 2. Sibling repo discovery -----------------------------------------------
$parentDir = Split-Path -Parent $scriptDir

function Test-SiblingRepo {
    param([string]$Name, [string]$Marker)
    $candidate = Join-Path $parentDir $Name
    if (Test-Path -LiteralPath (Join-Path $candidate $Marker)) {
        return $candidate
    }
    return ""
}

$codetracerDir = Test-SiblingRepo -Name "codetracer" -Marker "libs"
$runquotaDir = Test-SiblingRepo -Name "runquota" -Marker "libs"
$nativeRecorderDir = Test-SiblingRepo -Name "codetracer-native-recorder" -Marker "ct_interpose"

if ([string]::IsNullOrEmpty($codetracerDir)) {
    Write-Warning "reprobuild env.ps1: ../codetracer sibling missing -- nimcrypto/nim-stew/nim-faststreams/nim-serialization come from there. Clone it and run 'git submodule update --init libs/nimcrypto libs/nim-stew libs/nim-faststreams libs/nim-serialization' before building."
}
if ([string]::IsNullOrEmpty($runquotaDir)) {
    Write-Warning "reprobuild env.ps1: ../runquota sibling missing -- the runquota_* libraries are required by config.nims. Clone metacraft-labs/runquota and run 'git checkout dev'."
}
if ([string]::IsNullOrEmpty($nativeRecorderDir)) {
    Write-Warning "reprobuild env.ps1: ../codetracer-native-recorder sibling missing -- the monitor shim's hook_registry comes from ct_interpose/src. Clone metacraft-labs/codetracer-native-recorder if you plan to build the Windows monitor shim."
}

# Re-export the resolved sibling paths so `config.nims` doesn't have to
# walk relative-path candidates. Only the entries that have no vendored
# fallback inside `reprobuild/libs/` are exported here:
#
#   * RUNQUOTA_SRC / CT_INTERPOSE_SRC -- no vendored fallback, must point
#     at the sibling checkout.
#
# `NIMCRYPTO_SRC` / `NIM_STEW_SRC` / `NIM_FASTSTREAMS_SRC` are
# DELIBERATELY NOT exported, even though their codetracer-side copies
# exist: `config.nims` already searches `reprobuild/libs/` FIRST, and
# the vendored copies under `reprobuild/libs/` are newer than the
# pinned submodule snapshots under `codetracer/libs/`. Setting an
# override would force the older copy and miss API additions
# (notably `stew/ptrops.baseAddr` which the vendored
# `nim-faststreams/buffers.nim` depends on).
if ($runquotaDir) { $env:RUNQUOTA_SRC = $runquotaDir }
if ($nativeRecorderDir) {
    $env:CT_INTERPOSE_SRC = Join-Path $nativeRecorderDir "ct_interpose\src"
}

# --- 3. Status summary -------------------------------------------------------
function Get-CommandSource {
    # `repo-workspaces/env.ps1` exposes nim / just / python / gh / repo as
    # PowerShell *aliases* (CommandType -ne Application), so the canonical
    # `.Source` property is empty. Resolve through the alias' `Definition`
    # when present and fall back to the application source otherwise.
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return "(not on PATH)" }
    if ($cmd.CommandType -eq "Alias") {
        return $cmd.Definition
    }
    return $cmd.Source
}

Write-Host ""
Write-Host "reprobuild dev environment ready."
Write-Host "  nim          = $(Get-CommandSource 'nim')"
Write-Host "  gcc          = $(Get-CommandSource 'gcc')"
Write-Host "  just         = $(Get-CommandSource 'just')"
Write-Host "  codetracer   = $(if ($codetracerDir) { $codetracerDir } else { '(missing -- see warning)' })"
Write-Host "  runquota     = $(if ($runquotaDir) { $runquotaDir } else { '(missing -- see warning)' })"
Write-Host "  ct_interpose = $(if ($nativeRecorderDir) { $nativeRecorderDir } else { '(missing -- see warning)' })"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  bash scripts/build_apps.sh      # compile every app entry point under build/bin/"
Write-Host "  bash scripts/run_tests.sh       # compile + run the local test suite"
