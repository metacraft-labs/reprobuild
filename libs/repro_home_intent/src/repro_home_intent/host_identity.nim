## Host identity resolution and profile-directory discovery for the
## home profile intent layer.
##
## Per `Home-Profile-Intent-Layer.md`:
##
##   - Profile directory: `--profile-dir <path>` (CLI override) >
##     `$REPRO_HOME_PROFILE_DIR` > OS default
##     (`$XDG_CONFIG_HOME/repro/home/` on Linux/macOS,
##      `%APPDATA%\repro\home\` on Windows).
##   - Host identity: `$REPRO_HOST` > `--host <name>` (CLI override) >
##     lowercased OS hostname.

import std/[nativesockets, os, strutils]

import ./errors

const
  HomeProfileEnvVar* = "REPRO_HOME_PROFILE_DIR"
  HomeHostEnvVar* = "REPRO_HOST"
  HomeProfileAnchor* = "home.nim"

when defined(windows):
  proc getComputerNameW(buf: WideCString; size: ptr int32): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetComputerNameW".}

# ---------------------------------------------------------------------------
# CLI-override state. The CLI layer (M61) calls these setters once it has
# parsed argv; everything else in this library reads through the resolver.
# ---------------------------------------------------------------------------

var
  cliProfileDirOverride: string
  cliHostOverride: string

proc setProfileDirOverride*(path: string) =
  ## CLI-side setter for the `--profile-dir <path>` flag. Pass the empty
  ## string to clear.
  cliProfileDirOverride = path

proc setHostOverride*(name: string) =
  ## CLI-side setter for the `--host <name>` flag. Pass the empty string
  ## to clear.
  cliHostOverride = name

proc clearOverrides*() =
  ## Reset all CLI overrides. Tests use this to keep test cases isolated.
  cliProfileDirOverride = ""
  cliHostOverride = ""

# ---------------------------------------------------------------------------
# Profile directory discovery.
# ---------------------------------------------------------------------------

proc osDefaultProfileDir*(): string =
  ## OS-default profile directory per the spec:
  ##   Linux/macOS: `$XDG_CONFIG_HOME/repro/home/` (XDG_CONFIG_HOME
  ##                defaults to `$HOME/.config` when unset).
  ##   Windows:     `%APPDATA%\repro\home\`.
  when defined(windows):
    let appData = getEnv("APPDATA")
    if appData.len > 0:
      return appData / "repro" / "home"
    let userProfile = getEnv("USERPROFILE")
    if userProfile.len > 0:
      return userProfile / "AppData" / "Roaming" / "repro" / "home"
    return getHomeDir() / "AppData" / "Roaming" / "repro" / "home"
  else:
    let xdg = getEnv("XDG_CONFIG_HOME")
    if xdg.len > 0:
      return xdg / "repro" / "home"
    return getHomeDir() / ".config" / "repro" / "home"

proc resolveProfileDir*(): string =
  ## Resolve the profile directory in the documented precedence:
  ##
  ## 1. CLI override (set via `setProfileDirOverride`)
  ## 2. `$REPRO_HOME_PROFILE_DIR`
  ## 3. OS default
  if cliProfileDirOverride.len > 0:
    return cliProfileDirOverride
  let env = getEnv(HomeProfileEnvVar)
  if env.len > 0:
    return env
  result = osDefaultProfileDir()

proc resolveProfilePath*(): string =
  ## Path to the anchor file `home.nim` inside the resolved profile
  ## directory. The file itself need not exist yet — see
  ## `loadProfilePath` for the existence check.
  result = resolveProfileDir() / HomeProfileAnchor

proc loadProfilePath*(): string =
  ## Return the absolute path of the profile's `home.nim`, raising
  ## `ENoProfile` if it is not present. The caller decides whether to
  ## scaffold a new profile in that case.
  let dir = resolveProfileDir()
  let path = dir / HomeProfileAnchor
  if not fileExists(path):
    raiseNoProfile(dir, path)
  result = path

# ---------------------------------------------------------------------------
# Host identity.
# ---------------------------------------------------------------------------

proc systemHostname*(): string =
  ## OS hostname, lowercased. On Windows uses `COMPUTERNAME` (or
  ## `GetComputerNameW` as a fallback); on POSIX uses `gethostname()`
  ## via `std/nativesockets.getHostname`.
  when defined(windows):
    let env = getEnv("COMPUTERNAME")
    if env.len > 0:
      return env.toLowerAscii()
    var size: int32 = 256
    var buf = newWideCString("", int(size))
    if getComputerNameW(buf, addr size) != 0:
      return ($buf).toLowerAscii()
    return ""
  else:
    try:
      result = getHostname().toLowerAscii()
    except OSError:
      result = ""

proc currentHost*(): string =
  ## Resolve the current host identity per the documented precedence:
  ##
  ## 1. `$REPRO_HOST`
  ## 2. CLI `--host <name>` override (set via `setHostOverride`)
  ## 3. Lowercased system hostname
  let env = getEnv(HomeHostEnvVar)
  if env.len > 0:
    return env
  if cliHostOverride.len > 0:
    return cliHostOverride
  result = systemHostname()
