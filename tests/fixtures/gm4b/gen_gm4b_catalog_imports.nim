## Runs `generateCatalogImportsFixture`
## (`tests/e2e/gm4b/gm4b_catalog_imports_fixture.nim`) for edge
## `reprobuild.test_fixtures.gm4b_catalog_imports` (`repro.nim`).
##
## Usage: gen_gm4b_catalog_imports <output dir>
##
## Run from the reprobuild checkout: the current directory is the work
## directory the extractor compiles recipes against.

import std/os

import ../../e2e/gm4b/gm4b_catalog_imports_fixture

when isMainModule:
  if paramCount() != 1:
    quit("usage: gen_gm4b_catalog_imports <output dir>", 2)
  let root = absolutePath(paramStr(1))
  generateCatalogImportsFixture(root, getCurrentDir())
  stdout.writeLine("wrote " & root)
