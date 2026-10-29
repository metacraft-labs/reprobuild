## Each computation of a recipe compile keeps its own output directory —
## Hermetic-Builds-And-Path-Independence.md §"Per-computation output
## directories" (owner decision 2026-10-29).
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess
## against a real recipe in a real temporary directory, with real Nim
## compiles of a real provider, a real action cache and a real store. The
## defect is an interaction between the CLI's edge layout, the engine's
## publish and the cache's in-place output check; only the production path
## exercises all three.
##
## The defect, as measured 2026-10-29 at reprobuild ``3f5a229979``: the
## provider compile wrote every computation of one recipe identity into ONE
## directory (``recipe-compiles/provider/<identity>/``). Its records are
## metadata-only, so a record is a hit only if the files on disk are the ones
## it describes. Building the recipe as computation X, then Y (same recipe
## bytes, different observed input), then X again recompiled X on the third
## build: "output metadata changed", although none of X's inputs had.
##
## Here the two computations differ only in a ``nim.cfg`` comment in the
## recipe's PARENT directory. The provider compile's ``nim c`` reads it (Nim
## loads the config files of every ancestor of the project), so the monitor
## records it as an input, but it is not part of the edge's identity, which
## names only what lies in the recipe's own directory. That is exactly the
## shape of the develop-versus-lock-pinned and sibling-set cases, without a
## workspace.
##
## Out-of-band corroboration: "recompiled" is read from the filesystem (the
## computation directory's binary keeps its mtime and inode), not from the
## CLI's own report.

import std/[algorithm, os, osproc, strtabs, strutils, times, unittest]

const RecipeSource = """
import repro_project_dsl

package percomputationprobe:
  build:
    discard
"""

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc runBuildCli(reproBin, projectRoot, actionCacheRoot: string):
    tuple[output: string; exitCode: int] =
  let res = execCmdEx(quoteShellCommand([
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    "--log=actions",
    projectRoot]))
  (output: res.output, exitCode: res.exitCode)

proc computationDirs(actionCacheRoot, kind: string): seq[string] =
  ## Every computation directory of every identity of `kind`: the
  ## directories under `<identity>/` other than `staging/`.
  let root = actionCacheRoot / "recipe-compiles" / kind
  if not dirExists(root):
    return
  for identityKind, identity in walkDir(root):
    if identityKind != pcDir:
      continue
    for entryKind, entry in walkDir(identity):
      if entryKind == pcDir and extractFilename(entry) != "staging":
        result.add(entry)
  result.sort()

type BinaryStamp = object
  present: bool
  mtime: times.Time
  inode: int64

proc stampOf(path: string): BinaryStamp =
  if not fileExists(path):
    return BinaryStamp(present: false)
  let info = getFileInfo(path)
  BinaryStamp(present: true, mtime: info.lastWriteTime,
    inode: int64(info.id.file))

proc recordFileFor(actionCacheRoot, computationDir: string): string =
  ## The `.rec` whose record owns `computationDir`: records are filed under
  ## the hex of their strong fingerprint, and the directory is named by its
  ## first 32 hex digits.
  let name = extractFilename(computationDir).toLowerAscii
  for path in walkDirRec(actionCacheRoot / "action-cache" / "hot-records"):
    if path.endsWith(".rec") and
        extractFilename(path).toLowerAscii.startsWith(name):
      return path
  ""

suite "recipe compiles keep one output directory per computation":

  test "X, then Y, then X: the third build is served from X's own directory":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      # A short root: the provider compile's argv is part of its key.
      let tempRoot = "/tmp/rb-percomp-" & $getCurrentProcessId()
      removeDir(tempRoot)
      createDir(tempRoot)
      defer: removeDir(tempRoot)
      let projectRoot = tempRoot / "project"
      createDir(projectRoot)
      writeFile(projectRoot / "repro.nim", RecipeSource)
      let actionCacheRoot = tempRoot / "ac"
      createDir(actionCacheRoot)
      let parentCfg = tempRoot / "nim.cfg"

      # --- X: cold. -----------------------------------------------------
      writeFile(parentCfg, "# computation X\n")
      let x1 = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if x1.exitCode != 0: checkpoint(x1.output)
      check x1.exitCode == 0
      let afterX = computationDirs(actionCacheRoot, "provider")
      checkpoint("after X: " & $afterX)
      check afterX.len == 1
      check computationDirs(actionCacheRoot, "interface").len >= 1
      let dirX = if afterX.len > 0: afterX[0] else: ""
      let binaryX = dirX / "provider" / "project-provider"
      let stampX = stampOf(binaryX)
      check stampX.present
      # The record names the directory it owns.
      check recordFileFor(actionCacheRoot, dirX).len > 0

      # --- Y: the same recipe bytes, another computation. ----------------
      writeFile(parentCfg, "# computation Y\n")
      let y = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if y.exitCode != 0: checkpoint(y.output)
      check y.exitCode == 0
      let afterY = computationDirs(actionCacheRoot, "provider")
      checkpoint("after Y: " & $afterY)
      # Y really was a different computation of the same identity...
      check afterY.len == 2
      check afterY.len > 0 and afterY.find(dirX) >= 0
      var dirY = ""
      for dir in afterY:
        if dir != dirX:
          dirY = dir
      check parentDir(dirY) == parentDir(dirX)
      # ... and it left X's outputs alone.
      let stampXAfterY = stampOf(binaryX)
      check stampXAfterY.present
      check stampXAfterY.mtime == stampX.mtime
      check stampXAfterY.inode == stampX.inode

      # --- X again: served from X's directory, nothing recompiled. -------
      writeFile(parentCfg, "# computation X\n")
      let x2 = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if x2.exitCode != 0: checkpoint(x2.output)
      check x2.exitCode == 0
      let afterX2 = computationDirs(actionCacheRoot, "provider")
      checkpoint("after X again: " & $afterX2)
      check afterX2 == afterY
      check dirExists(dirX)
      check dirExists(dirY)
      let stampX2 = stampOf(binaryX)
      check stampX2.present
      # A recompile would have promoted a fresh staging directory over X's:
      # a new inode and a new mtime.
      check stampX2.mtime == stampX.mtime
      check stampX2.inode == stampX.inode

      # --- X once more, straight after X: the warm path. ------------------
      # Consecutive builds of one computation are served by the newest
      # record's metadata projection, which carries no strong fingerprint;
      # the computation directory must still be found (from the record's
      # own outputs), or the owned-outputs guard refuses the record and the
      # provider recompiles on every warm build.
      let x2b = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if x2b.exitCode != 0: checkpoint(x2b.output)
      check x2b.exitCode == 0
      check computationDirs(actionCacheRoot, "provider") == afterY
      check stampOf(binaryX).inode == stampX.inode
      check stampOf(binaryX).mtime == stampX.mtime

      # --- GC: a directory whose record is gone is collected. ------------
      let recordY = recordFileFor(actionCacheRoot, dirY)
      check recordY.len > 0
      if recordY.len > 0:
        removeFile(recordY)
      # Outside `tempRoot`: the provider compile observes the listing of the
      # recipe's ancestors, so a new entry there is a new computation.
      let storeRoot = tempRoot & "-store"
      defer: removeDir(storeRoot)
      let gcRun = execCmdEx(quoteShellCommand([
        reproBin, "store", "gc",
        "--store-root=" & storeRoot,
        "--grace-seconds=0"]),
        env = newStringTable({
          "REPROBUILD_ACTION_CACHE_ROOT": actionCacheRoot,
          "PATH": getEnv("PATH"), "HOME": getEnv("HOME")}))
      checkpoint(gcRun.output)
      check gcRun.exitCode == 0
      check gcRun.output.contains(
        "recipe-compile directories without a record: 1 ")
      check not dirExists(dirY)
      # The live record's directory is untouched, and still serves X.
      check dirExists(dirX)
      check stampOf(binaryX).mtime == stampX.mtime
      let x3 = runBuildCli(reproBin, projectRoot, actionCacheRoot)
      if x3.exitCode != 0: checkpoint(x3.output)
      check x3.exitCode == 0
      check stampOf(binaryX).inode == stampX.inode
      check computationDirs(actionCacheRoot, "provider") == @[dirX]
