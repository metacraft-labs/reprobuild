## Reprobuild project DSL umbrella module.
##
## Every generated and hand-authored ``repro.nim`` consumes this module via
## ``import repro_project_dsl`` (or through ``reprobuild`` and
## ``reprobuild/dsl``, which re-export it). What it provides depends on the
## compilation's mode (``repro_project_dsl/mode``):
##
## * with ``-d:reproProviderMode``, ``-d:reproInterfaceMode`` or
##   ``-d:reproEvalMode``, the whole DSL: ``repro_project_dsl/full``, which
##   holds what this module held before the modes existed and documents how
##   it is split up;
## * with none of them, the thin mode: ``repro_project_dsl/thin``, every DSL
##   form name as an ``untyped`` macro and nothing of the engine, so that a
##   program can import its project's ``repro.nim``.
##
## The engine passes the define of the mode each of its compilations needs,
## and reprobuild's own ``config.nims`` defines ``reproEvalMode`` for every
## compile in its tree. ``reproDslMode`` is exported in every mode.

import repro_project_dsl/mode
export mode

when reproDslMode == rdmThin:
  import repro_project_dsl/thin
  export thin
else:
  import repro_project_dsl/full
  export full
