## The C file Nim generates for a sibling-import shim has a short name under a
## LONG action-cache root.
##
## The second form of the "generated C file name exceeds NAME_MAX" defect
## (a newer compiler does not fix it, 2026-11-15): a recipe-relative
## interface extraction writes a recipe's sibling-import shims under its
## identity's scratch directory,
## `<action-cache root>/recipe-compiles/interface/<64-hex>/staging/work/sibling-shims/`.
## No project, `--path` or nimble root lay near it, so Nim named the shim's C
## file after the whole path from the runner: 283 bytes at a 120-character
## root on macOS, past NAME_MAX, and `cannot open`. Requiring Nim 2.2.10 does
## not close that form, because the name does not depend on the compiler
## version but on which roots the compile passes.
##
## The fix passes the owned shim directory itself as a `--path` root, so the
## shim is named relative to its own directory: `@prepro_sib_<selector>.nim.c`
## whatever the root's length.
##
## NO MOCKS. The real `build/bin/repro`, real recipes, real compiles. The
## positive control is that the shim's C file must exist; the check cannot
## pass by finding nothing.

import std/[os, osproc, strtabs, strutils, unittest]

const ProducerName = "shimrootprod"

const ProducerSource = """
import repro_project_dsl

package shimrootprod:
  build:
    discard
"""

const ConsumerSource = """
import repro_project_dsl

package shimrootconsumer:
  uses:
    "shimrootprod"
  build:
    discard
"""

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc shimCFiles(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    let name = extractFilename(path)
    if ("repro_sib_" & ProducerName) in name and name.endsWith(".nim.c"):
      result.add(path)

suite "sibling shim C names do not grow with the action-cache root":
  test "a 130-character action-cache root leaves the shim's name short":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tempRoot = getTempDir() / ("rb-shimroot-" & $getCurrentProcessId())
      removeDir(tempRoot)
      defer: removeDir(tempRoot)
      let cacheHome = tempRoot / "cache"
      createDir(cacheHome)
      # About 130 characters of action-cache root above the identity.
      var actionCacheRoot = tempRoot / "ac"
      var i = 0
      while actionCacheRoot.len - tempRoot.len < 130:
        actionCacheRoot = actionCacheRoot / ("long-root-component-" & $i)
        inc i
      createDir(actionCacheRoot)
      let ws = tempRoot / "ws"
      createDir(ws / ProducerName)
      writeFile(ws / ProducerName / "repro.nim", ProducerSource)
      createDir(ws / "consumer")
      writeFile(ws / "consumer" / "repro.nim", ConsumerSource)
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
      env["XDG_CACHE_HOME"] = cacheHome
      env["LOCALAPPDATA"] = cacheHome
      # Recipe-relative extraction is the default on POSIX; leave it alone.
      env.del("REPRO_RECIPE_RELATIVE_COMPILES")
      let res = execCmdEx(quoteShellCommand([reproBin, "build",
        "--no-runquota", "--daemon=off", "--tool-provisioning=path",
        "--action-cache-root=" & actionCacheRoot, "--progress=quiet",
        "--log=actions", ws / "consumer" / "repro.nim"]), env = env)
      if res.exitCode != 0: checkpoint(res.output)
      check res.exitCode == 0
      check "cannot open" notin res.output
      let cFiles = shimCFiles(cacheHome / "repro-nimcache-interface")
      checkpoint("shim C files: " & $cFiles)
      # Positive control: the extraction compiled the shim.
      check cFiles.len >= 1
      # `@prepro_sib_shimrootprod.nim.c` plus any suffix a collision adds:
      # far below the 255-byte limit, and with none of the root in it.
      for path in cFiles:
        let name = extractFilename(path)
        check name.len <= 64
        check "long-root-component" notin name
