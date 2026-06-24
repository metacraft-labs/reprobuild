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
#       - nim-stackable-hooks/         (framework primitives the monitor shim builds on)
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
#   $env:STACKABLE_HOOKS_SRC = <path>  override `../nim-stackable-hooks/src`.
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
$stackableHooksDir = Test-SiblingRepo -Name "nim-stackable-hooks" -Marker "stackable_hooks.nimble"

if ([string]::IsNullOrEmpty($codetracerDir)) {
    Write-Warning "reprobuild env.ps1: ../codetracer sibling missing -- nimcrypto/nim-stew/nim-faststreams/nim-serialization come from there. Clone it and run 'git submodule update --init libs/nimcrypto libs/nim-stew libs/nim-faststreams libs/nim-serialization' before building."
}
if ([string]::IsNullOrEmpty($runquotaDir)) {
    Write-Warning "reprobuild env.ps1: ../runquota sibling missing -- the runquota_* libraries are required by config.nims. Clone metacraft-labs/runquota and run 'git checkout dev'."
}
if ([string]::IsNullOrEmpty($stackableHooksDir)) {
    Write-Warning "reprobuild env.ps1: ../nim-stackable-hooks sibling missing -- the monitor shim's hook_registry, reentrancy guard, and inline-detour primitive all come from there. Clone metacraft-labs/nim-stackable-hooks if you plan to build the Windows monitor shim."
}

# Re-export the resolved sibling paths so `config.nims` doesn't have to
# walk relative-path candidates. Only the entries that have no vendored
# fallback inside `reprobuild/libs/` are exported here:
#
#   * RUNQUOTA_SRC / STACKABLE_HOOKS_SRC -- no vendored fallback, must
#     point at the sibling checkout.
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
if ($stackableHooksDir) {
    $env:STACKABLE_HOOKS_SRC = Join-Path $stackableHooksDir "src"
}

# --- io-mon live interpose snoop wiring (Incremental-Test-Runner M8) ----------
# Make io-mon's standalone `io-mon-snoop` CLI + interpose shim discoverable on
# PATH / via env when the io-mon sibling is present and built, so the CodeTracer
# incremental test runner's live read-file capture can resolve them
# out-of-process. Mirrors codetracer/.envrc + .envrc (POSIX) on the Windows DIY
# path.
#
# TODO(io-mon live interpose, Windows): the Windows capture path uses the
# CreateRemoteThread + LoadLibraryW injector (io_mon/windows_injector.nim), NOT
# the POSIX DYLD/LD_PRELOAD env var. This block only seeds discovery of the
# already-built artifacts; the Windows interpose path itself still needs
# end-to-end validation under the DIY toolchain (build the shim DLL via
# `nimble buildShim`, build io-mon-snoop.exe via `nimble buildSnoop`, then
# confirm a user-binary capture writes a non-empty depfile). Until validated,
# the runner fails safe to a re-run when the capture is empty/failed.
$ioMonDir = Test-SiblingRepo -Name "io-mon" -Marker "io_mon.nimble"
if ($ioMonDir) {
    $ioMonSnoopExe = Join-Path $ioMonDir "build\bin\io-mon-snoop.exe"
    if (Test-Path -LiteralPath $ioMonSnoopExe) {
        $env:IO_MON_SNOOP = $ioMonSnoopExe
        $env:PATH = (Join-Path $ioMonDir "build\bin") + [IO.Path]::PathSeparator + $env:PATH
    }
    $ioMonShimDll = Join-Path $ioMonDir "build\lib\librepro_monitor_shim.dll"
    if (Test-Path -LiteralPath $ioMonShimDll) {
        $env:REPRO_MONITOR_SHIM_LIB = $ioMonShimDll
    }
    $env:IO_MON_SRC = Join-Path $ioMonDir "src"
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
Write-Host "  stackable-hooks = $(if ($stackableHooksDir) { $stackableHooksDir } else { '(missing -- see warning)' })"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  bash scripts/build_apps.sh      # compile every app entry point under build/bin/"
Write-Host "  bash scripts/run_tests.sh       # compile + run the local test suite"
