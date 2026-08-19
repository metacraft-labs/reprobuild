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
    entries are strictly better than this script: pinned, hashed, lockable.

    But executing them requires a working `repro`, and `just bootstrap`
    exists precisely for the case where there is not one. So the cold start
    — get nim and a C compiler onto a bare Windows box with no repro — has
    to be plain PowerShell. Everything after it should go through the
    catalog.

    Provenance: `toolchain-utils.ps1`, `ensure-nim.ps1` and `ensure-gcc.ps1`
    beside this file were moved here from the `repo-workspaces` framework
    (an archived tool superseded by `repro ws`), which reprobuild's
    `env.ps1` used to require as a sibling checkout. They are byte-identical
    copies; the three helpers below (`Get-ReproToolchainInstallRoot`,
    `Add-PathEntry`, `Test-CompilerOnPath`) lived in that framework's
    `env.ps1` rather than in its `windows/` directory, so they are restated
    here.

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

function Test-CompilerOnPath {
  ## A stale gcc is worse than none: it shadows real ones and produces
  ## cryptic failures. FPC ships gcc 2.95 in its `i386-Win32` dir, which
  ## chokes on modern headers with "Invalid argument". Require a sane major
  ## version; otherwise report false so Ensure-Gcc installs WinLibs and
  ## PATH-prepends it ahead of the stale one.
  $minMajor = 5
  $cmd = Get-Command "gcc" -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { return $false }
  try {
    $verLine = & $cmd.Source --version 2>&1 | Select-Object -First 1
    if ("$verLine" -match '([0-9]+)\.[0-9]+') {
      return ([int]$Matches[1] -ge $minMajor)
    }
  } catch {}
  return $false
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

  # gcc — `nim c` needs a C compiler. Skip when a sane one is already on
  # PATH (MSYS2, a system mingw, ...); provision WinLibs otherwise.
  if ($doSync -and (Test-BootstrapStepEnabled "GCC") -and -not (Test-CompilerOnPath)) {
    try {
      Ensure-Gcc -Root $installRoot -Toolchain $toolchain
    } catch {
      Write-Warning "reprobuild bootstrap: gcc provisioning failed: $($_.Exception.Message)"
    }
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
