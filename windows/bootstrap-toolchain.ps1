#Requires -Version 5.1
<#
.SYNOPSIS
    Cold-start provisioning of nim + gcc for a Windows checkout of reprobuild.

.DESCRIPTION
    This is the ONLY provisioning reprobuild cannot express in its own
    builtin catalog, and the reason is structural rather than incidental.

    `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/` already describes
    every tool here declaratively, with Windows coverage and integrity
    hashes — `nim.nim` carries `scoopApp(main/nim)` plus a windows `tarball`
    entry with a sha256 and a `lockIdentity`; `gcc_winlibs.nim` carries a
    `PlatformBinary(poWindows, ...)` for the WinLibs mingw archive. Those
    entries remain the authority once a `repro` exists: they are lockable,
    which this script is not.

    But executing them requires a working `repro`, and `just bootstrap`
    exists precisely for the case where there is not one. So the cold start
    — get nim and a C compiler onto a bare Windows box with no repro — has
    to be plain PowerShell. Everything after it should go through the
    catalog.

    What the cold start does NOT get to skip is pinning. Both steps name a
    version and a sha256 in `toolchain-versions.env`, fetch from a fixed URL
    and verify the archive before extracting it — the same contract the flake
    devShell gives Linux/macOS. A step that "finds" a tool on the host instead
    is not a bootstrap, it is a coin flip.

    Provenance: `toolchain-utils.ps1`, `ensure-nim.ps1` and `ensure-gcc.ps1`
    beside this file were moved here from the `repo-workspaces` framework
    (an archived tool superseded by `repro ws`), which reprobuild's
    `env.ps1` used to require as a sibling checkout. The two helpers below
    (`Get-ReproToolchainInstallRoot`, `Add-PathEntry`) lived in that
    framework's `env.ps1` rather than in its `windows/` directory, so they are
    restated here.

    Deliberately NOT carried over: the framework's gh / gpg / python3 /
    git-repo steps. None is needed to build `repro`, and the gpg step
    triggers a UAC elevation prompt.

.NOTES
    Knobs (unchanged from the framework, so existing muscle memory works):
      $env:WINDOWS_DIY_SYNC = "0"           skip all downloads
      $env:WINDOWS_DIY_SKIP_NIM = "1"       skip the nim step
      $env:WINDOWS_DIY_SKIP_GCC = "1"       skip the gcc step
      $env:WINDOWS_DIY_INSTALL_ROOT = ...   where toolchains are installed
      $env:NIM_WINDOWS_SOURCE_MODE = ...    prebuilt | source | auto
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reproWindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

. (Join-Path $reproWindowsDir "toolchain-utils.ps1")
. (Join-Path $reproWindowsDir "ensure-nim.ps1")
. (Join-Path $reproWindowsDir "ensure-gcc.ps1")

function Get-ReproToolchainInstallRoot {
  ## Where cold-start toolchains land.
  ##
  ## The default is deliberately still `%LOCALAPPDATA%\repo-workspaces\
  ## toolchains`, not a reprobuild-branded path: that is where existing
  ## checkouts already have nim and gcc installed, and renaming it would
  ## force every machine to re-download ~500 MB for no benefit. The name is
  ## legacy; the directory is just a cache.
  $fromEnv = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv.Trim() }

  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw "Could not resolve %LOCALAPPDATA%. Set WINDOWS_DIY_INSTALL_ROOT explicitly."
  }
  return (Join-Path $localAppData "repo-workspaces\toolchains")
}

function Add-PathEntry {
  ## Idempotent process-PATH prepend. `toolchain-utils.ps1` ships no PATH
  ## mutator by design, so this stays with the driver.
  param([Parameter(Mandatory = $true)][string]$Dir)
  if ([string]::IsNullOrWhiteSpace($Dir)) { return }
  if (-not (Test-Path -LiteralPath $Dir)) { return }
  $resolved = (Resolve-Path -LiteralPath $Dir).Path
  $current = [Environment]::GetEnvironmentVariable("PATH")
  foreach ($entry in ($current -split ';')) {
    if ($entry.TrimEnd('\') -ieq $resolved.TrimEnd('\')) { return }
  }
  [Environment]::SetEnvironmentVariable("PATH", "$resolved;$current", "Process")
}

function Invoke-ReproToolchainBootstrap {
  ## Ensure nim + gcc exist and are on PATH. Idempotent: both ensure steps
  ## no-op when the pinned version is already installed.
  ##
  ## Returns the install root so the caller can reuse it for reprobuild's
  ## own steps (clingo, nim-bearssl), which expect the same layout.
  $installRoot = Get-ReproToolchainInstallRoot
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT", $installRoot, "Process")

  $syncRaw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_SYNC")
  $doSync = -not (-not [string]::IsNullOrWhiteSpace($syncRaw) -and
                  ($syncRaw.Trim().ToLowerInvariant() -in @("0", "false", "no", "off")))

  $toolchain = Read-KeyValueFile -Path (Join-Path $reproWindowsDir "toolchain-versions.env")
  $arch = Get-WindowsArch

  if ($doSync -and (Test-BootstrapStepEnabled "NIM")) {
    # Default to the prebuilt zip; the source bootstrap is much heavier.
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("NIM_WINDOWS_SOURCE_MODE"))) {
      [Environment]::SetEnvironmentVariable("NIM_WINDOWS_SOURCE_MODE", "prebuilt", "Process")
    }
    try {
      Ensure-Nim -Root $installRoot -Arch $arch -Toolchain $toolchain
    } catch {
      Write-Warning "reprobuild bootstrap: nim provisioning failed: $($_.Exception.Message)"
    }
  }

  # gcc — `nim c` shells out to a C compiler for every module it emits, so
  # this is a hard dependency of the whole build rather than a convenience.
  #
  # Two things here used to be wrong, and together they produced an
  # environment that reported itself ready with no compiler in it:
  #
  #   * The step was skipped whenever ANY sane gcc was already on PATH. That
  #     made the build depend on whatever the host happened to carry — the
  #     opposite of a pin, and how a pinned GCC_VERSION came to sit over a
  #     differently-versioned compiler. The pinned toolchain is now always
  #     provisioned and always PATH-prepended (which also puts it ahead of a
  #     stale gcc such as the 2.95 that FPC ships in its i386-Win32 dir);
  #     WINDOWS_DIY_SKIP_GCC=1 remains for hosts that deliberately supply
  #     their own.
  #   * A failure was downgraded to a warning. The next error then came out of
  #     `nim c` as `Requested command not found: 'gcc.exe ...'`, which names
  #     neither the environment nor the missing pin. Fatal now, for the reason
  #     clingo and nim-bearssl are fatal in env.ps1: a build that proceeds past
  #     this point cannot succeed, and every message it prints afterwards
  #     points somewhere else.
  if ($doSync -and (Test-BootstrapStepEnabled "GCC")) {
    Ensure-Gcc -Root $installRoot -Arch $arch -Toolchain $toolchain | Out-Null
  }

  $nimVersion = $toolchain["NIM_VERSION"]
  if (-not [string]::IsNullOrWhiteSpace($nimVersion)) {
    Add-PathEntry -Dir (Join-Path $installRoot "nim/$nimVersion/prebuilt/nim-$nimVersion/bin")
  }
  $gccVersion = $toolchain["GCC_VERSION"]
  if (-not [string]::IsNullOrWhiteSpace($gccVersion)) {
    Add-PathEntry -Dir (Join-Path $installRoot "gcc/$gccVersion/bin")
  }

  return $installRoot
}
