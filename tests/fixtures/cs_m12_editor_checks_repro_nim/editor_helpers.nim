## A helper module of the fixture project that uses the full DSL. Its name is
## not a DSL file's, so ``editor_helpers.nims`` beside it selects the full
## DSL when it is checked on its own; a program never imports it.

import reprobuild/dsl

static:
  doAssert reproDslMode == rdmEval,
    "editor_helpers.nim compiled in " & $reproDslMode

proc csm12HelperStep*(): BuildActionDef =
  ## ``BuildActionDef`` exists only in the full DSL.
  discard
