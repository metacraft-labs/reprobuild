## DSL-port M9.R.14d.2 — assert that no source recipe still pins its
## ``fetch:`` URL to a ``file:///metacraft/...`` host-absolute path.
##
## ## Context
##
## The from-source recipe campaign initially staged tarballs under
## ``recipes/packages/source/<pkg>/vendor/<tarball>`` and referenced
## them via ``url: "file:///metacraft/reprobuild/recipes/packages/source/<pkg>/vendor/..."``.
## That worked on the development machine but fails on every other
## host (the absolute file path doesn't exist).
##
## M9.R.14d.2 transformed all 61 affected recipes to use the upstream
## URL recorded in their ``versions:`` block's ``sourceUrl`` field.
## This test guards against regressions: a developer who adds a new
## recipe (or updates an existing one) MUST point ``fetch:`` at an
## upstream-resolvable URL, never at a host-local file path.
##
## A grep that lands in the recipe BODY (after stripping comments)
## catches the regression case while permitting documentation /
## doc-comment mentions of the ``file://`` URL shape (e.g. the meson
## recipe's `## v1 of this recipe ships` paragraph).

import std/[os, strutils, unittest]

const RecipeRoot = "recipes/packages/source"

proc isCommentLine(line: string): bool =
  let stripped = line.strip()
  stripped.startsWith("##") or stripped.startsWith("#")

proc collectFileUrlOffenders(): seq[string] =
  ## Walk every ``recipes/packages/source/*/repro.nim`` and return the
  ## ``<recipe>:<lineNo>`` of any non-comment line carrying
  ## ``file:///``. Returns the empty seq when the tree is clean.
  for kind, path in walkDir(RecipeRoot):
    if kind != pcDir and kind != pcLinkToDir: continue
    let manifest = path / "repro.nim"
    if not fileExists(manifest): continue
    let body = readFile(manifest)
    var lineNo = 0
    for line in body.splitLines():
      inc lineNo
      if "file:///" notin line: continue
      if isCommentLine(line): continue
      result.add(manifest & ":" & $lineNo)

suite "DSL-port M9.R.14d.2 — no host-local file:/// URLs in recipes":

  test "all source recipes use upstream URLs in fetch blocks":
    let offenders = collectFileUrlOffenders()
    if offenders.len > 0:
      echo "BUG: recipes still using file:/// URLs:"
      for o in offenders:
        echo "  ", o
    check offenders.len == 0
