## Fixture project of
## ``tests/integration/test_cs_m12_editor_checks_repro_nim.nim``.
##
## Opened as the main file (``nim check repro.nim``, ``nimsuggest`` with this
## file as its project) it compiles in the full DSL with no mode define,
## because its name is a DSL file's. Its program (``src/``) imports it and
## compiles it thin. The ``build:`` body is deliberately broken: it names an
## identifier nothing declares, which only a check of the full DSL reports.
## Line and column numbers below are asserted by the test.

import reprobuild

when reproDslMode != rdmThin:
  proc csm12EditorStep*(): BuildActionDef =
    ## A declaration only the full DSL can type: ``BuildActionDef`` (line
    ## 14, column 28) is the engine's.
    discard

const fixtureDslMode* = reproDslMode
  ## The mode this file compiled in, for the program to report.

package csm12editor:
  executable "csm12-editor-prog":
    name: "csm12editorprog"

  build:
    csm12EditorPlantedError(42)
