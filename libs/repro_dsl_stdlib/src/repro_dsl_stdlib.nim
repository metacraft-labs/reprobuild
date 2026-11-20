## The project DSL with its standard prelude (``reprobuild`` re-exports this
## module). Like ``repro_project_dsl``, it follows the compilation's mode
## (``repro_project_dsl/mode``): the prelude in the full modes, the thin
## mode's form names when no mode define is given. ``reproDslMode`` is
## exported in every mode.

import repro_project_dsl/mode
export mode

when reproDslMode == rdmThin:
  import repro_project_dsl/thin
  export thin
else:
  import repro_dsl_stdlib/prelude
  export prelude
