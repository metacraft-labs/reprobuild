## DSL-port M9.R.14d.6 — assert no source recipe pre-prefixes meson
## options with ``-D`` or includes ``--buildtype`` in its opts seq.
##
## ## Context
##
## ``meson.setup``'s ``options`` flag (libs/repro_dsl_stdlib/src/
## repro_dsl_stdlib/packages/meson.nim) carries ``alias = "-D"`` +
## ``format = concat``. The wrapper PREPENDS ``-D`` to every element
## at emit time. Recipes that ship pre-prefixed options
## (``"-Dfoo=bar"``) end up invoking meson with ``-D-Dfoo=bar``,
## which meson rejects with ``Unknown option``.
##
## Likewise ``--buildtype`` has its own typed flag on the wrapper
## (``meson_package(buildtype = "release", ...)``); duplicating it in
## the opts seq creates a ``-D--buildtype=release`` invocation.
##
## This test pins the convention. Any new recipe that re-introduces
## either bug breaks the build immediately rather than wedging only
## at smoke-iteration time.

import std/[os, strutils, unittest]

const RecipeRoot = "recipes/packages/source"

proc collectViolations(): seq[string] =
  ## Walk every ``recipes/packages/source/*/repro.nim`` and return
  ## the ``<recipe>:<lineNo>: <reason>`` of any non-comment line
  ## carrying a meson option string that starts with ``-D`` or
  ## ``--buildtype``. Returns the empty seq when the tree is clean.
  for kind, path in walkDir(RecipeRoot):
    if kind != pcDir and kind != pcLinkToDir: continue
    let manifest = path / "repro.nim"
    if not fileExists(manifest): continue
    let body = readFile(manifest)
    var lineNo = 0
    var inOpts = false
    for line in body.splitLines():
      inc lineNo
      let stripped = line.strip()
      if stripped.startsWith("#"): continue
      if "let opts" in line and "@[" in line:
        inOpts = true
        continue
      if inOpts and stripped.startsWith("]"):
        inOpts = false
        continue
      if not inOpts: continue
      # Inside the meson options seq.
      if stripped.startsWith("\"-D"):
        result.add(manifest & ":" & $lineNo & ": pre-prefixed -D option (" &
          stripped & ")")
      elif stripped.startsWith("\"--buildtype"):
        result.add(manifest & ":" & $lineNo &
          ": --buildtype belongs as a typed flag, not in opts seq (" &
          stripped & ")")

suite "DSL-port M9.R.14d.6 — meson options sanity":

  test "no source recipe pre-prefixes options with -D or includes --buildtype":
    let violations = collectViolations()
    if violations.len > 0:
      echo "BUG: ", violations.len, " meson option violation(s):"
      for v in violations:
        echo "  ", v
    check violations.len == 0
