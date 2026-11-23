## `recipeSourceName` is asked once per DSL source site (every `uses:`
## entry, target and variant), within one `package` expansion that the Nim
## VM runs under a fixed loop budget (`--maxLoopIterationsVM`, 10 million by
## default). Its cost must not repeat the anchor work for every site: with
## the 147 anchors of a CI job that builds reprobuild in its workspace that
## was about 118,000 VM iterations per site, and a consumer folding a large
## sibling recipe in through `uses:` failed its provider compile with
## "interpretation requires too many iterations".
##
## This file's `.nim.cfg` makes the compile recipe-relative with 44 long
## anchors and lowers the budget to 2 million. 2,000 sites in one macro
## expansion then fit only if the anchors are prepared once per compile.

import std/[macros, os, unittest]

import repro_core/relocation

const sites = 2000

macro askForEverySite(file: static string): untyped =
  ## The names `recipeSourceName` gives `file` and a file under an anchor,
  ## each asked `sites` times in this one expansion, as `lineFile` asks.
  var recipe, anchored = ""
  let underAnchor = "/nix/store/x-source/src/m.nim"
  for _ in 0 ..< sites:
    recipe = recipeSourceName(file)
    anchored = recipeSourceName(underAnchor)
  result = newTree(nnkTupleConstr, newLit(recipe), newLit(anchored))

suite "recipe source names":
  test "a site beside the recipe is relative, one under an anchor absolute":
    const names = askForEverySite(currentSourcePath().parentDir / "repro.nim")
    check names[0] == "repro.nim"
    check names[1] == "/nix/store/x-source/src/m.nim"

  test "each site is answered alike when asked again":
    const again = askForEverySite(currentSourcePath().parentDir / "sub" / "a.nim")
    check again[0] == "sub/a.nim"
