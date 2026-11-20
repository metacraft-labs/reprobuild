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
## * ``rdmEval`` (``-d:reproEvalMode``, or a DSL file as the main module):
##   the whole DSL, registering packages and running their ``build:`` bodies
##   in process.
## * ``rdmThin`` (otherwise): every top-level DSL form name and nothing of
##   the engine (``repro_project_dsl/thin``).
##
## The first rule in that order wins: a provider compile that also sees
## ``reproEvalMode`` (reprobuild's own ``config.nims`` defines it for every
## compile in its tree) is a provider compile.
##
## The thin mode is the default so that a program can import its project's
## ``repro.nim`` without compiling the engine. Each of the engine's own
## compilations passes the define of the mode it needs. Code that exists only
## in the full modes goes under ``when reproDslMode != rdmThin:``; the
## umbrellas export this module in every mode, so that test always compiles.
##
## Editors. A compilation whose main file is a DSL file (``isReproDslMainFile``:
## ``repro.nim``, ``reprobuild.nim``, ``home.nim`` or ``system.nim``) is in
## ``rdmEval`` with no define, so ``nim check repro.nim``, and ``nimsuggest``
## or a language server with ``repro.nim`` as its project, type-check the
## ``build:`` bodies and resolve every DSL symbol without a private flag. A
## program that imports its ``repro.nim`` has its own main file and stays
## thin. A helper module that uses the full DSL is checked on its own by
## putting a ``<helper>.nims`` beside it, which Nim reads only when that
## module is the main file:
##
## .. code-block:: nim
##   switch("define", "reproEvalMode")
##
## A program whose main module carries one of those names compiles the full
## DSL if it imports one; that is the price of the rule.
##
## Imports ``std/compilesettings`` only.

import std/compilesettings

const ReproDslMainFileNames* = ["repro.nim", "reprobuild.nim", "home.nim",
                                "system.nim"]
  ## The file names of the DSL files an editor opens: a project's
  ## ``repro.nim`` (``reprobuild.nim`` is its older name), a home profile's
  ## ``home.nim`` and a system profile's ``system.nim``.

func lastPathComponent(path: string): string =
  ## What follows the last ``/`` or ``\`` of ``path``. Both separators,
  ## whatever the target: the path is the host's, and a cross compile
  ## (``--os:windows`` on Linux, or the reverse) does not change it.
  result = path
  for i in countdown(path.len - 1, 0):
    if path[i] in {'/', '\\'}:
      return path[i + 1 .. ^1]

const isReproDslMainFile*: bool =
  lastPathComponent(querySetting(SingleValueSetting.projectFull)) in
    ReproDslMainFileNames
  ## Whether this compilation's main file is a DSL file. Read here, the
  ## setting names the compilation's main file, not this module.

type
  ReproDslMode* = enum
    rdmThin       ## no define, no DSL main file: the form names only
    rdmEval       ## ``-d:reproEvalMode`` or a DSL main file: in-process
                  ## evaluation
    rdmInterface  ## ``-d:reproInterfaceMode``: interface extraction
    rdmProvider   ## ``-d:reproProviderMode``: the provider binary

const reproDslMode*: ReproDslMode =
  when defined(reproProviderMode): rdmProvider
  elif defined(reproInterfaceMode): rdmInterface
  elif defined(reproEvalMode) or isReproDslMainFile: rdmEval
  else: rdmThin
  ## The mode of this compilation, decided once from its defines and its
  ## main file.
