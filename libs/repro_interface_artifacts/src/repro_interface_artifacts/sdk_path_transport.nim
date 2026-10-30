## Internal transport for the SDK-owned path reset of a generated Nim helper.
## This is not a response-file implementation: caller exclusions and every
## --path remain on argv, including the paths needed by first-pass config.nims.

import std/[os, osproc, sequtils, sets, strutils, tempfiles, unicode]
import repro_core/file_lock
from repro_core/paths import extendedPath

const
  WindowsCommandLineLimit* = 32767 # CreateProcessW includes the terminating NUL.
  OwnedSdkConfigHeader* = "# reprobuild-generated interface SDK path reset\n"

type
  OwnedSdkPathReset* = object
    selected: seq[string] # Only protectCompilerSdkPaths can tag these roots.

  SdkPathTransportPlan* = object
    command*: seq[string]
    configText*: string
    originalUnits*: int
    physicalUnits*: int

proc protectCompilerSdkPaths*(command: var seq[string]; moduleArg: string;
    protectedFlags: HashSet[string]): OwnedSdkPathReset =
  ## Preserve the existing SDK namespace assembly, retaining its ownership tag
  ## rather than later guessing which --excludePath switches belong to us.
  var remaining: seq[string]
  var beforeModule = true
  for arg in command:
    if arg == moduleArg: beforeModule = false
    if beforeModule and arg in protectedFlags:
      if arg notin result.selected: result.selected.add(arg)
    else:
      remaining.add(arg)
  if result.selected.len == 0: return
  var priority: seq[string]
  for flag in result.selected:
    priority.add("--excludePath:" & flag["--path:".len .. ^1])
  priority.add(result.selected)
  let moduleAt = remaining.find(moduleArg)
  doAssert moduleAt >= 0
  remaining.insert(priority, moduleAt)
  command = remaining

proc windowsCommandLineUnits*(command: openArray[string]): int =
  ## Count the SAME Windows quoting used by runCommand, in UTF-16 code units.
  result = 1
  for i, arg in command:
    if '\0' in arg:
      raise newException(ValueError, "compiler argv contains an unresolved NUL")
    if i > 0: inc result
    for rune in quoteShellWindows(arg).runes:
      result += (if int(rune) > 0xffff: 2 else: 1)

proc projectConfigDisabled(command: openArray[string]): bool =
  for arg in command:
    let pair = arg.split({':', '='}, maxsplit = 1)
    let name = pair[0].toLowerAscii().replace("-", "").replace("_", "")
    if name == "skipprojcfg":
      result = pair.len == 1 or pair[1].toLowerAscii() != "off"

proc comparablePath(value, base: string): string =
  # This comparison never rewrites an argument. Conservatively retaining a
  # reset is safe; missing an alias could change a first-pass config import.
  result = normalizedPath(absolutePath(value.replace("$$", "$"), base))
  when defined(windows): result = result.toLowerAscii()

proc planOwnedSdkPathTransport*(command: openArray[string]; moduleArg, cwd: string;
    owned: OwnedSdkPathReset): SdkPathTransportPlan =
  ## Only the exact, paired SDK suffix may travel in the owned project cfg.
  ## All other flags keep their positions. A reset needed to undo an earlier
  ## alias stays on argv too, preserving first-pass namespace selection.
  result.command = @command
  result.originalUnits = windowsCommandLineUnits(command)
  result.physicalUnits = result.originalUnits
  if result.originalUnits <= WindowsCommandLineLimit: return
  if projectConfigDisabled(command):
    raise newException(ValueError,
      "oversized interface compiler argv disables its owned project configuration")
  let moduleAt = result.command.find(moduleArg)
  let count = owned.selected.len
  let first = moduleAt - 2 * count
  if count == 0 or first < 2 or moduleAt != command.high:
    raise newException(ValueError, "oversized interface compiler argv has no owned SDK reset suffix")
  for i, path in owned.selected:
    if command[first + i] != "--excludePath:" & path["--path:".len .. ^1] or
        command[first + count + i] != path:
      raise newException(ValueError, "owned SDK reset suffix no longer matches compiler argv")
  var keep = newSeq[bool](count)
  let moduleDir = parentDir(absolutePath(moduleArg, cwd))
  for arg in command.toOpenArray(0, first - 1):
    let pair = arg.split({':', '='}, maxsplit = 1)
    let option = pair[0].toLowerAscii().replace("-", "").replace("_", "")
    if option notin ["path", "p"]: continue
    if pair.len != 2:
      for i in 0 ..< count: keep[i] = true
      continue
    let value = pair[1]
    # Unknown Nim substitutions cannot safely be interpreted by the engine.
    if '$' in value.replace("$$", ""):
      for i in 0 ..< count: keep[i] = true
      continue
    for i, path in owned.selected:
      let root = path["--path:".len .. ^1]
      for base in [cwd, moduleDir]:
        if comparablePath(value, base) == comparablePath(root, base):
          keep[i] = true
  result.command.setLen(0)
  result.configText = OwnedSdkConfigHeader
  for i, arg in command:
    if i >= first and i < first + count and not keep[i - first]:
      result.configText.add("excludePath = " &
        arg["--excludePath:".len .. ^1].escape() & "\n")
    else:
      result.command.add(arg)
  result.physicalUnits = windowsCommandLineUnits(result.command)
  if result.physicalUnits > WindowsCommandLineLimit:
    raise newException(ValueError,
      "interface compiler argv still exceeds Windows limit after owned SDK reset transport (" &
      $result.physicalUnits & " UTF-16 units)")

type OwnedSdkPathConfig* = object
  lock: ReproFileLock
  path, text: string

proc stageOwnedSdkPathConfig*(runner: string; plan: SdkPathTransportPlan): OwnedSdkPathConfig =
  ## Call only for a generated helper in engine-owned scratch. The existing
  ## nimcache slot lock remains outermost; this lock also serializes the
  ## per-binary mode's shared runner directory. Never replace caller config.
  if not runner.isAbsolute or not fileExists(extendedPath(runner)):
    raise newException(ValueError, "SDK transport requires an existing absolute generated helper")
  result.path = runner & "cfg" # Nim prefers .nimcfg over .nim.cfg.
  result.text = plan.configText
  result.lock = acquireExclusiveFileLock(result.path & ".lock")
  var stagePath = ""
  try:
    if fileExists(extendedPath(runner & ".cfg")):
      raise newException(IOError, "refusing a foreign generated-helper project configuration")
    if fileExists(extendedPath(result.path)):
      if not readFile(extendedPath(result.path)).startsWith(OwnedSdkConfigHeader):
        raise newException(IOError, "refusing a foreign generated-helper project configuration")
      # A process killed during compilation can leave only our owned sidecar.
      removeFile(extendedPath(result.path))
    if result.text.len == 0: return
    let (stage, path) = createTempFile("sdk_path_reset_", ".tmp", parentDir(runner))
    stagePath = path
    try: stage.write(result.text)
    finally: stage.close()
    moveFile(extendedPath(stagePath), extendedPath(result.path))
    stagePath = ""
  except:
    try:
      if stagePath.len > 0 and fileExists(extendedPath(stagePath)):
        removeFile(extendedPath(stagePath))
    finally:
      releaseExclusiveFileLock(result.lock)
    raise

proc releaseOwnedSdkPathConfig*(config: var OwnedSdkPathConfig) =
  ## Keep the sidecar for the entire existing compiler/retry lifetime, then
  ## remove exactly the bytes we published before unlocking the runner.
  if config.path.len == 0: return
  try:
    if fileExists(extendedPath(config.path)):
      if readFile(extendedPath(config.path)) != config.text:
        raise newException(IOError, "generated-helper project configuration changed while locked")
      removeFile(extendedPath(config.path))
  finally:
    releaseExclusiveFileLock(config.lock)
    config.path = ""
