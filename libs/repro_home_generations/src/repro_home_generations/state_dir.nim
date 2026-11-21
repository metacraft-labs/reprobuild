## OS-XDG-style per-user state directory resolution for the home
## profile generation registry (M62 — Home-Profile-Generations-And-State.md
## "State Directory").
##
## Precedence:
##
##   1. `$REPRO_HOME_STATE_DIR` (operator override, always wins)
##   2. OS default:
##        - Linux:   `$XDG_STATE_HOME/repro/home/`
##                   or `~/.local/state/repro/home/`
##        - macOS:   `~/Library/Application Support/repro/home/`
##        - Windows: `%LOCALAPPDATA%\repro\home\`
##
## The state directory is per-user operational data, never synced. The
## spec layout it contains is:
##
##   <state-dir>/
##     generations/<gen-id>/pointer.bin
##     current                    # symlink on POSIX; current.txt on Windows
##     locks/apply.lock

import std/[os]
from repro_core/paths import extendedPath

import ./errors

const
  StateDirEnvVar* = "REPRO_HOME_STATE_DIR"
  GenerationsDirName* = "generations"
  LocksDirName* = "locks"
  ApplyLockName* = "apply.lock"
  CurrentSymlinkName* = "current"
  CurrentFileNameWindows* = "current.txt"
  PointerFileName* = "pointer.bin"

# ---------------------------------------------------------------------------
# CLI-override state. M62 has no CLI of its own; the M63 apply pipeline
# will call these setters from its --state-dir flag.
# ---------------------------------------------------------------------------

var cliStateDirOverride: string

proc setStateDirOverride*(path: string) =
  ## CLI-side setter for an explicit `--state-dir <path>` override.
  ## Pass the empty string to clear.
  cliStateDirOverride = path

proc clearStateDirOverride*() =
  cliStateDirOverride = ""

# ---------------------------------------------------------------------------
# OS-default resolution.
# ---------------------------------------------------------------------------

type
  StateDirBase* = enum
    ## The per-user directory a default state directory is relative to.
    ## The string form is what `repro home export` publishes
    ## (`concerns.profileBin`), so a consumer that knows the user's
    ## directories (a Home Manager configuration) resolves the same path
    ## Reprobuild resolves on that host.
    sdbHome = "home"
      ## `$HOME`.
    sdbXdgStateHome = "xdgStateHome"
      ## `$XDG_STATE_HOME`, or `$HOME/.local/state` when it is unset.
    sdbLocalAppData = "localAppData"
      ## `%LOCALAPPDATA%`, or `%USERPROFILE%\AppData\Local` when it is unset.

  StateDirLocation* = object
    ## A per-user path, as a base directory and the components below it.
    base*: StateDirBase
    components*: seq[string]

proc defaultStateDirLocation*(platform: string): StateDirLocation =
  ## The OS-default home state directory of `platform` (`linux`, `macos`
  ## or `windows`: the `platform` names of `ProfileTargetPlatforms`) --
  ## the one table behind `osDefaultStateDir` and behind the location
  ## `repro home export` publishes for a target it is not running on.
  ## Raises `ValueError` for any other name.
  case platform
  of "linux":
    StateDirLocation(base: sdbXdgStateHome, components: @["repro", "home"])
  of "macos":
    StateDirLocation(base: sdbHome,
      components: @["Library", "Application Support", "repro", "home"])
  of "windows":
    StateDirLocation(base: sdbLocalAppData, components: @["repro", "home"])
  else:
    raise newException(ValueError, "unknown platform '" & platform &
      "' (known: linux, macos, windows)")

const HostStatePlatform* =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  else: "linux"
    ## The `defaultStateDirLocation` row of the platform this binary runs
    ## on (every other POSIX system uses the XDG layout).

proc osDefaultStateDir*(): string =
  let location = defaultStateDirLocation(HostStatePlatform)
  case location.base
  of sdbLocalAppData:
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      result = local
    else:
      let userProfile = getEnv("USERPROFILE")
      if userProfile.len == 0:
        raiseStateDirInvalid(
          "neither LOCALAPPDATA nor USERPROFILE is set; cannot resolve a " &
          "per-user home state directory on Windows")
      result = userProfile / "AppData" / "Local"
  of sdbHome:
    let home = getEnv("HOME")
    if home.len == 0:
      raiseStateDirInvalid(
        "HOME is not set; cannot resolve a per-user home state directory " &
        "on macOS")
    result = home
  of sdbXdgStateHome:
    let xdg = getEnv("XDG_STATE_HOME")
    if xdg.len > 0:
      result = xdg
    else:
      let home = getEnv("HOME")
      if home.len == 0:
        raiseStateDirInvalid(
          "neither XDG_STATE_HOME nor HOME is set; cannot resolve a per-user " &
          "home state directory")
      result = home / ".local" / "state"
  for component in location.components:
    result = result / component

proc resolveStateDir*(): string =
  ## Resolve the home state directory in the documented precedence:
  ##
  ## 1. CLI override (set via `setStateDirOverride`)
  ## 2. `$REPRO_HOME_STATE_DIR`
  ## 3. OS default (`osDefaultStateDir`)
  if cliStateDirOverride.len > 0:
    return cliStateDirOverride
  let env = getEnv(StateDirEnvVar)
  if env.len > 0:
    return env
  result = osDefaultStateDir()

# ---------------------------------------------------------------------------
# Sub-path helpers.
# ---------------------------------------------------------------------------

proc generationsRoot*(stateDir: string): string =
  stateDir / GenerationsDirName

proc generationDir*(stateDir, generationId: string): string =
  stateDir / GenerationsDirName / generationId

proc pointerPath*(stateDir, generationId: string): string =
  generationDir(stateDir, generationId) / PointerFileName

proc locksDir*(stateDir: string): string =
  stateDir / LocksDirName

proc applyLockPath*(stateDir: string): string =
  locksDir(stateDir) / ApplyLockName

proc currentPath*(stateDir: string): string =
  ## Path to the `current` marker. On POSIX this is a symlink target;
  ## on Windows we store a regular file `current.txt` with the
  ## generation id as its contents.
  when defined(windows):
    stateDir / CurrentFileNameWindows
  else:
    stateDir / CurrentSymlinkName

proc ensureStateDir*(stateDir: string) =
  ## Create the on-disk layout for the state directory if missing.
  createDir(extendedPath(stateDir))
  createDir(extendedPath(generationsRoot(stateDir)))
  createDir(extendedPath(locksDir(stateDir)))

# ---------------------------------------------------------------------------
# `current` reader / writer.
# ---------------------------------------------------------------------------

proc readCurrentGenerationId*(stateDir: string): string =
  ## Returns the active generation id or the empty string if `current`
  ## is not present. On POSIX, dereferences the symlink and returns
  ## its target's basename. On Windows, returns the contents of
  ## `current.txt` with surrounding whitespace stripped.
  let p = currentPath(stateDir)
  when defined(windows):
    if not fileExists(extendedPath(p)):
      return ""
    var raw = readFile(extendedPath(p))
    while raw.len > 0 and raw[^1] in {'\r', '\n', ' ', '\t'}:
      raw.setLen(raw.len - 1)
    return raw
  else:
    if not symlinkExists(extendedPath(p)) and not fileExists(extendedPath(p)):
      return ""
    try:
      let target = expandSymlink(extendedPath(p))
      return extractFilename(target)
    except OSError:
      if fileExists(extendedPath(p)):
        var raw = readFile(extendedPath(p))
        while raw.len > 0 and raw[^1] in {'\r', '\n', ' ', '\t'}:
          raw.setLen(raw.len - 1)
        return raw
      return ""

proc writeCurrentGenerationId*(stateDir, generationId: string) =
  ## Update the `current` marker to point at `generationId`. On POSIX
  ## this writes a symlink atomically (via remove + create); on
  ## Windows it overwrites `current.txt` with the id text. The
  ## generation directory itself MUST exist before the marker is
  ## updated — callers (apply pipeline) are responsible for that.
  ensureStateDir(stateDir)
  let p = currentPath(stateDir)
  when defined(windows):
    let tmpPath = p & ".tmp"
    writeFile(extendedPath(tmpPath), generationId)
    if fileExists(extendedPath(p)): removeFile(extendedPath(p))
    moveFile(extendedPath(tmpPath), extendedPath(p))
  else:
    let target = generationDir(stateDir, generationId)
    if symlinkExists(extendedPath(p)) or fileExists(extendedPath(p)):
      try: removeFile(extendedPath(p)) except OSError: discard
    try:
      createSymlink(extendedPath(target), extendedPath(p))
    except OSError:
      writeFile(extendedPath(p), generationId)
