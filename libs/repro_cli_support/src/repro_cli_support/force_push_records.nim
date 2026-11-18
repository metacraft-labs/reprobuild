## Durable storage for `.repro/workspace/force-pushes.json`, the recovery
## record for a rewritten remote.
##
## The records cannot be reconstructed once dropped, so this module's job is
## to make every failure mode lose NOTHING:
##
##   * a write goes to a temporary file in the same directory, is fsynced and
##     renamed over the target, so a crash leaves the old file or the new
##     one, never a torn one;
##   * the read-modify-write cycle runs under an exclusive file lock, so two
##     concurrent `sync` runs cannot lose each other's appends;
##   * an unparsable file is QUARANTINED (renamed aside, kept byte for byte)
##     instead of being degraded to "no records" and replaced by the next
##     write.
##
## Specified in Workspace-And-Develop-Mode.md §"Remote history was rewritten
## under the checkout" (the durability paragraph).
import std/[json, os, times]
import repro_core/file_lock
when not defined(windows):
  import std/posix

const forcePushesRelPath* = ".repro" / "workspace" / "force-pushes.json"

proc forcePushesPath*(workspaceRoot: string): string =
  workspaceRoot / forcePushesRelPath

proc quarantinePath(path: string): string =
  ## A name that does not collide with an earlier quarantine.
  let stamp = getTime().utc.format("yyyyMMdd'T'HHmmss")
  result = path & ".corrupt-" & stamp
  var n = 1
  while fileExists(result):
    result = path & ".corrupt-" & stamp & "-" & $n
    inc n

proc quarantineForcePushes*(path: string; reason: string): string =
  ## Move an unreadable record file aside, preserving its bytes, and say so.
  result = quarantinePath(path)
  moveFile(path, result)
  stderr.writeLine("workspace: could not read " & path & " (" & reason &
    "); quarantined it as " & result & " and proceeding with no recorded " &
    "force-push. That file is the recovery record for a rewritten remote: " &
    "repair it from the quarantined copy and merge it back by hand.")

proc readForcePushesNode*(path: string): JsonNode =
  ## The parsed file, or nil when absent. An unparsable file is quarantined
  ## and reported as absent, so the next write cannot replace it.
  if not fileExists(path):
    return nil
  try:
    return parseFile(path)
  except CatchableError as err:
    discard quarantineForcePushes(path, err.msg)
    return nil

proc fsyncPath(path: string) =
  when not defined(windows):
    let fd = posix.open(path.cstring, O_RDONLY)
    if fd >= 0:
      discard fsync(fd)
      discard posix.close(fd)

proc writeForcePushesAtomic*(path, content: string) =
  ## Temp file + fsync + rename (+ directory fsync): all-or-nothing.
  let dir = parentDir(path)
  createDir(dir)
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  try:
    var f = open(tmp, fmWrite)
    try:
      f.write(content)
      f.flushFile()
      when not defined(windows):
        discard fsync(getFileHandle(f))
    finally:
      f.close()
    moveFile(tmp, path)
  except CatchableError:
    if fileExists(tmp):
      try: removeFile(tmp)
      except CatchableError: discard
    raise
  fsyncPath(dir)

template withForcePushesLock*(workspaceRoot: string; body: untyped) =
  ## Hold the exclusive lock across a whole load-modify-save cycle.
  var forcePushesLock = acquireExclusiveFileLock(
    forcePushesPath(workspaceRoot) & ".lock")
  try:
    body
  finally:
    releaseExclusiveFileLock(forcePushesLock)
