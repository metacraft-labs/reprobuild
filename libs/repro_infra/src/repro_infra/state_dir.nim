## Per-host SYSTEM state directory resolution (M69 —
## System-Profile-And-Infra-Apply.md "State Directory").
##
## The privileged sibling of the M62 home state dir
## (`repro_home_generations/state_dir.nim`). The system state
## directory is owned by root/Administrator and is per-host (never
## synced through the user's dotfiles).
##
## Precedence:
##
##   1. `$REPRO_INFRA_STATE_DIR` (operator / test override, always wins)
##   2. CLI `--state-dir` override
##   3. OS default:
##        - Linux:   `/var/lib/repro/system/`
##        - macOS:   `/Library/Application Support/repro/system/`
##        - Windows: `%PROGRAMDATA%\repro\system\`
##
## On-disk layout (mirrors home scope, plus the M69-specific
## `plans/` and per-generation `log/`):
##
##   <system-state-dir>/
##     generations/<gen-id>/
##       pointer.bin
##       log/apply.log              # RBSL append-only audit log
##     plans/<plan-id>.rbip         # RBIP plan envelopes
##     current / current.txt
##     locks/apply.lock
##     system.nim                   # Windows intent layer lives here

import std/[os]
when defined(posix):
  import std/posix
from repro_core/paths import extendedPath

import ./errors

const
  StateDirEnvVar* = "REPRO_INFRA_STATE_DIR"
  GenerationsDirName* = "generations"
  PlansDirName* = "plans"
  LocksDirName* = "locks"
  LogDirName* = "log"
  ApplyLockName* = "apply.lock"
  ApplyLogName* = "apply.log"
  CurrentSymlinkName* = "current"
  CurrentFileNameWindows* = "current.txt"
  PointerFileName* = "pointer.bin"
  PlanFileSuffix* = ".rbip"
  SystemProfileName* = "system.nim"

var cliStateDirOverride: string

proc setStateDirOverride*(path: string) =
  ## CLI-side setter for `--state-dir <path>`. Empty string clears.
  cliStateDirOverride = path

proc clearStateDirOverride*() =
  cliStateDirOverride = ""

proc osDefaultSystemStateDir*(): string =
  when defined(windows):
    let programData = getEnv("PROGRAMDATA")
    if programData.len > 0:
      return programData / "repro" / "system"
    raiseSystemStateDirInvalid(
      "PROGRAMDATA is not set; cannot resolve the per-host system " &
      "state directory on Windows")
  elif defined(macosx):
    return "/Library/Application Support/repro/system"
  else:
    return "/var/lib/repro/system"

proc resolveSystemStateDir*(): string =
  ## Resolve the system state directory in the documented precedence.
  if cliStateDirOverride.len > 0:
    return cliStateDirOverride
  let env = getEnv(StateDirEnvVar)
  if env.len > 0:
    return env
  result = osDefaultSystemStateDir()

# ---------------------------------------------------------------------------
# Sub-path helpers.
# ---------------------------------------------------------------------------

proc generationsRoot*(stateDir: string): string =
  stateDir / GenerationsDirName

proc generationDir*(stateDir, generationId: string): string =
  stateDir / GenerationsDirName / generationId

proc pointerPath*(stateDir, generationId: string): string =
  generationDir(stateDir, generationId) / PointerFileName

proc generationLogDir*(stateDir, generationId: string): string =
  generationDir(stateDir, generationId) / LogDirName

proc applyLogPath*(stateDir, generationId: string): string =
  generationLogDir(stateDir, generationId) / ApplyLogName

proc plansRoot*(stateDir: string): string =
  stateDir / PlansDirName

proc planPath*(stateDir, planId: string): string =
  plansRoot(stateDir) / (planId & PlanFileSuffix)

proc locksDir*(stateDir: string): string =
  stateDir / LocksDirName

proc applyLockPath*(stateDir: string): string =
  locksDir(stateDir) / ApplyLockName

proc systemProfilePath*(stateDir: string): string =
  ## The Windows intent layer (`system.nim`) lives in the system
  ## state dir; on POSIX it lives at `/etc/repro/system.nim` (the
  ## POSIX surface is deferred — Phase A is Windows-first).
  when defined(windows):
    stateDir / SystemProfileName
  else:
    "/etc/repro" / SystemProfileName

proc currentPath*(stateDir: string): string =
  when defined(windows):
    stateDir / CurrentFileNameWindows
  else:
    stateDir / CurrentSymlinkName

proc ensureSystemStateDir*(stateDir: string) =
  ## Create the on-disk layout if missing.
  createDir(extendedPath(stateDir))
  createDir(extendedPath(generationsRoot(stateDir)))
  createDir(extendedPath(plansRoot(stateDir)))
  createDir(extendedPath(locksDir(stateDir)))

# ---------------------------------------------------------------------------
# `current` reader / writer (file form on Windows, symlink on POSIX).
# ---------------------------------------------------------------------------

proc readCurrentGenerationId*(stateDir: string): string =
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
      return extractFilename(expandSymlink(extendedPath(p)))
    except OSError:
      if fileExists(extendedPath(p)):
        var raw = readFile(extendedPath(p))
        while raw.len > 0 and raw[^1] in {'\r', '\n', ' ', '\t'}:
          raw.setLen(raw.len - 1)
        return raw
      return ""

const InfraMutation {.strdefine: "reproAddonMutation".} = ""
  ## The add-on's compile-time falsifying mutations
  ## (``repro_addon/mutations``); ``current-remove-then-create`` is the one
  ## that lives here. A build without the define contains none of it.

when defined(posix):
  var ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

  proc fsyncDirPath*(dir: string) =
    ## Make a rename or unlink in ``dir`` durable: a rename is atomic but
    ## not durable until its directory is synced.
    let fd = posix.open(dir.cstring, O_RDONLY or ODirectory or O_CLOEXEC)
    if fd < 0:
      raiseOSError(osLastError(), "open directory " & dir)
    try:
      if fsync(fd) != 0:
        raiseOSError(osLastError(), "fsync directory " & dir)
    finally:
      discard posix.close(fd)

proc writeCurrentGenerationId*(stateDir, generationId: string;
                               onPoint: proc(point: string) = nil) =
  ## Move `current` to ``generationId`` -- the commit point of a system
  ## generation. On POSIX it is one ``rename(2)`` of a fresh symlink over
  ## the old one, followed by an fsync of the state directory: a crash
  ## leaves the old `current` or the new one, never none, and once this
  ## returns the new one survives a power cut. ``onPoint`` is a test seam
  ## (the add-on's crash gate); production callers pass nothing.
  ensureSystemStateDir(stateDir)
  let p = currentPath(stateDir)
  when defined(windows):
    let tmpPath = p & ".tmp"
    writeFile(extendedPath(tmpPath), generationId)
    if fileExists(extendedPath(p)): removeFile(extendedPath(p))
    moveFile(extendedPath(tmpPath), extendedPath(p))
  else:
    let target = generationDir(stateDir, generationId)
    when InfraMutation == "current-remove-then-create":
      # The falsifying mutation: the pre-A5 commit, which removed the old
      # link (durably) before creating the new one -- a crash between leaves
      # no `current` at all, whatever the writeback.
      if symlinkExists(extendedPath(p)) or fileExists(extendedPath(p)):
        try: (removeFile(extendedPath(p)); fsyncDirPath(stateDir)) except OSError: discard
      if onPoint != nil: onPoint("commit-current-removed")
      createSymlink(extendedPath(target), extendedPath(p))
      fsyncDirPath(stateDir)
    else:
      let tmp = p & ".tmp-" & $getCurrentProcessId()
      if symlinkExists(tmp) or fileExists(tmp): removeFile(tmp)
      createSymlink(extendedPath(target), extendedPath(tmp))
      moveFile(tmp, p)              # rename(2): atomic replacement
      fsyncDirPath(stateDir)
