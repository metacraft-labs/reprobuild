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

import std/[os, strutils, sysrand, times]
from repro_core/paths import extendedPath
import repro_core/durable_replace

import ./errors

const
  StateDirEnvVar* = "REPRO_HOME_STATE_DIR"
  GenerationsDirName* = "generations"
  LocksDirName* = "locks"
  ApplyLockName* = "apply.lock"
  CurrentSymlinkName* = "current"
  CurrentFileNameWindows* = "current.txt"
  PointerFileName* = "pointer.bin"
  StoreRootKeyFileName* = "store-root-key"
    ## `<state-dir>/store-root-key`: what names this state directory in the
    ## ids of the store roots it registers (`stateDirRootKey`).
  StoreRootKeyHexLen* = 32

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
# The key this state directory's store roots are named by.
# ---------------------------------------------------------------------------

proc storeRootKeyPath*(stateDir: string): string =
  stateDir / StoreRootKeyFileName

proc readStoreRootKey(stateDir: string): tuple[present: bool; key: string] =
  ## `present` with an empty `key`: the file is there and is not
  ## `StoreRootKeyHexLen` lowercase hex digits. A file that is there and
  ## cannot be read raises: an unreadable key is not a missing one.
  let path = storeRootKeyPath(stateDir)
  if not fileExists(extendedPath(path)):
    return (false, "")
  result.present = true
  let key = readFile(extendedPath(path)).strip()
  if key.len != StoreRootKeyHexLen:
    return
  for ch in key:
    if ch notin {'0'..'9', 'a'..'f'}:
      return
  result.key = key

proc existingStateDirRootKey*(stateDir: string): string =
  ## The key in `<state-dir>/store-root-key`, or "" when the file is
  ## missing or malformed. Never creates or replaces it: a state directory
  ## without a key has registered no root under one. Raises when the file
  ## is there and cannot be read.
  readStoreRootKey(stateDir).key

proc stateDirRootKey*(stateDir: string): string =
  ## The key that tells this state directory's store roots from those of
  ## every other state directory using the same store. Created when the
  ## file is missing: `StoreRootKeyHexLen` hex digits from the system's
  ## random source, written durably (a synced temporary file renamed into
  ## place).
  ##
  ## The key is an identity the directory carries, not its path. Two
  ## containers that mount one store and each keep their state under the
  ## same path are two state directories; a directory that is moved, or
  ## reached under another spelling, is still one. Generation ids are
  ## content-addressed and name no run-environment fact, so without the
  ## key two state directories that apply the same profile would register
  ## one root between them (reprobuild-pm
  ## `spec/Home-Profile-Generations-And-State.md` §"Store GC Interaction").
  ##
  ## The key is authoritative operational state: nothing regenerates it,
  ## and the roots registered under it are found by it alone. So it is
  ## replaced only when the file is missing. A file that cannot be read
  ## raises. A malformed one is moved aside, with its bytes, to
  ## `store-root-key.malformed-<unix-time>` and reported, and a new key is
  ## created; the roots under the old key then stay until someone removes
  ## them.
  ##
  ## Callers that create it hold `apply.lock`, as every writer of a
  ## generation does, so two processes never create it at once.
  let existing = readStoreRootKey(stateDir)
  if existing.key.len > 0:
    return existing.key
  let path = storeRootKeyPath(stateDir)
  if existing.present:
    let aside = path & ".malformed-" & $getTime().toUnix
    moveFile(extendedPath(path), extendedPath(aside))
    stderr.writeLine("warning: " & path & " did not hold a store root " &
      "key; it was moved to " & aside & " and a new key was created. " &
      "Store roots registered under the old key are not released.")
  var bytes: array[StoreRootKeyHexLen div 2, byte]
  if not urandom(bytes):
    raise newException(IOError,
      "could not read the system random source to create " & path)
  for b in bytes:
    result.add(toHex(b.int, 2).toLowerAscii)
  createDir(extendedPath(stateDir))
  replaceFileDurably(path, result & "\n")

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
  ## Move the `current` marker to `generationId`, atomically and durably
  ## (`repro_core/durable_replace`). On POSIX a fresh symlink is renamed
  ## over the old one; on Windows a synced `current.txt` replaces the old one
  ## with a write-through rename. The old marker is never removed first: a
  ## crash between a removal and the new marker would leave no current
  ## generation at all, and `current` is authoritative operational state
  ## that nothing regenerates (reprobuild-pm
  ## `spec/Configuration-Storage-Principles.md` §"Authoritative Operational
  ## State"). The generation directory itself MUST exist before the marker
  ## is updated; callers (the apply pipeline) are responsible for that.
  ensureStateDir(stateDir)
  let p = currentPath(stateDir)
  # A write that died before its rename left its temporary file behind;
  # sweep the ones too old to belong to a write in progress.
  discard removeStaleDurableTemps(p)
  when defined(windows):
    replaceFileDurably(p, generationId)
  else:
    try:
      replaceSymlinkDurably(p, generationDir(stateDir, generationId))
    except OSError:
      # A filesystem that cannot hold a symlink gets the Windows form of the
      # marker, a file naming the generation; `readCurrentGenerationId`
      # reads either.
      replaceFileDurably(p, generationId)
