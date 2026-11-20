## Which mode the project DSL compiles in.
##
## The umbrellas (``reprobuild``, ``reprobuild/dsl``, ``repro_project_dsl``,
## ``repro_dsl_stdlib``) read ``reproDslMode`` and export a different DSL in
## each mode:
##
## * ``rdmProvider`` (``-d:reproProviderMode``): the whole DSL, built into a
##   provider binary whose main module is the recipe.
## * ``rdmInterface`` (``-d:reproInterfaceMode``): the whole DSL without the
##   procedures that run ``build:`` bodies; the engine extracts a project's
##   interface with it.
## * ``rdmEval`` (``-d:reproEvalMode``): the whole DSL, registering packages
##   and running their ``build:`` bodies in process.
## * ``rdmThin`` (no define): every top-level DSL form name and nothing of the
##   engine (``repro_project_dsl/thin``).
##
## The first define in that order wins: a provider compile that also sees
## ``reproEvalMode`` (reprobuild's own ``config.nims`` defines it for every
## compile in its tree) is a provider compile.
##
## The thin mode is the default so that a program can import its project's
## ``repro.nim`` without compiling the engine. Each of the engine's own
## compilations passes the define of the mode it needs. Code that exists only
## in the full modes goes under ``when reproDslMode != rdmThin:``; the
## umbrellas export this module in every mode, so that test always compiles.
##
## This module imports nothing.

type
  ReproDslMode* = enum
    rdmThin       ## no define: the form names only
    rdmEval       ## ``-d:reproEvalMode``: in-process evaluation
    rdmInterface  ## ``-d:reproInterfaceMode``: interface extraction
    rdmProvider   ## ``-d:reproProviderMode``: the provider binary

const reproDslMode*: ReproDslMode =
  when defined(reproProviderMode): rdmProvider
  elif defined(reproInterfaceMode): rdmInterface
  elif defined(reproEvalMode): rdmEval
  else: rdmThin
  ## The mode of this compilation, decided once from its defines.
