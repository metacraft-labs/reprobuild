## Interface extraction succeeds for a recipe at a very deep path.
##
## The first form of reprobuild-pm
## `issues/2026-10-20-interface-extraction-nimcache-name-exceeds-name-max-for-deep-recipe-paths.md`:
## Nim 2.2.4 named the generated C file of a recipe after its path relative
## to the project only, so a recipe about 300 characters deep got a file name
## over NAME_MAX (255) and the extraction died with `cannot open`. Recipe
## compilation now requires Nim 2.2.10 (operator decision of 2026-11-24),
## which weighs the `--path` roots and keeps the name short. This test holds
## the outcome: a recipe whose absolute path is over 300 characters is
## extracted (`repro build --list-targets`) and lists its target.
##
## NO MOCKS. The real `build/bin/repro`, a real recipe, a real compile with
## whichever compiler the run provisions. On a compiler below the floor the
## command is refused (see `t_recipe_compile_requires_nim_2_2_10`), so this
## test cannot pass on one. The positive control is the target list: it must
## name the recipe's package, so success cannot be an empty answer.

import std/[os, osproc, strtabs, strutils, unittest]

const Recipe = """
import repro_project_dsl

package deeppathrecipe:
  build:
    discard
"""

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

suite "interface extraction at a deep recipe path":
  test "a recipe over 300 characters deep is extracted":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      let tempRoot = getTempDir() / ("rb-deeprecipe-" & $getCurrentProcessId())
      removeDir(tempRoot)
      defer: removeDir(tempRoot)
      var dir = tempRoot
      # Components of 40 characters: past 300 characters in total on any
      # ordinary temporary root, each far under NAME_MAX.
      var i = 0
      while dir.len < 330:
        dir = dir / ("deeper-directory-component-number-" & align($i, 4, '0'))
        inc i
      createDir(dir)
      writeFile(dir / "repro.nim", Recipe)
      doAssert (dir / "repro.nim").len > 300
      var env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
      env["XDG_CACHE_HOME"] = tempRoot / "cache"
      createDir(tempRoot / "cache")
      let res = execCmdEx(quoteShellCommand([reproBin, "build",
        "--list-targets", "--no-runquota", "--daemon=off",
        "--tool-provisioning=path", dir / "repro.nim"]), env = env)
      if res.exitCode != 0: checkpoint(res.output)
      check res.exitCode == 0
      check "cannot open" notin res.output
