## `shell.integration` driver.
##
## On Windows: writes a managed block into the user's PowerShell
## profile (`$PROFILE\Microsoft.PowerShell_profile.ps1` or
## equivalent), reusing the `fs.managedBlock` driver.
##
## On Linux / macOS (Phase B): writes the managed block into the
## detected shell rc (`~/.zshrc`, `~/.bashrc`, ...). The Phase A
## fixture exercises the Windows path; the cross-platform
## interface lives here so the lifecycle layer doesn't need to
## branch.

import std/[os, strutils]
from repro_core/paths import extendedPath

import ./managed_block
import ./../types

proc observeShellIntegration*(hostFile, blockId: string): ObservedState =
  observeManagedBlock(hostFile, blockId)

proc applyShellIntegration*(hostFile, blockId, content: string):
    seq[byte] =
  if hostFile.len == 0:
    return @[]
  applyManagedBlockResource(hostFile, blockId, content)

proc destroyShellIntegration*(hostFile, blockId: string) =
  if hostFile.len == 0:
    return
  destroyManagedBlockResource(hostFile, blockId)

proc defaultPowerShellProfilePath*(homeDir: string): string =
  ## Best-effort resolution of `$PROFILE` for the current user.
  ## Real PowerShell honours `Documents` folder redirection; for
  ## the gate we use the conventional path under `homeDir`.
  homeDir / "Documents" / "PowerShell" / "Microsoft.PowerShell_profile.ps1"

proc legacyPowerShellProfilePath*(homeDir: string): string =
  ## The Windows PowerShell 5.1 profile path; fallback when the
  ## PowerShell 7+ path doesn't exist.
  homeDir / "Documents" / "WindowsPowerShell" /
    "Microsoft.PowerShell_profile.ps1"

proc resolveShellIntegrationHost*(homeDir: string): string =
  ## Pick the shell startup file for managed shell integration.
  when defined(windows):
    let modern = defaultPowerShellProfilePath(homeDir)
    if fileExists(extendedPath(modern)):
      return modern
    let legacy = legacyPowerShellProfilePath(homeDir)
    if fileExists(extendedPath(legacy)):
      return legacy
    # Neither exists yet — create the modern one.
    modern
  else:
    let shellName = extractFilename(getEnv("SHELL")).toLowerAscii()
    case shellName
    of "zsh":
      homeDir / ".zshrc"
    of "bash":
      homeDir / ".bashrc"
    of "fish":
      homeDir / ".config" / "fish" / "config.fish"
    else:
      homeDir / ".profile"
